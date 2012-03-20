module RbP2P
  class Server
    include Log

    def initialize(profile, nodeman, store, logger = nil)
      @profile = profile
      @nodeman = nodeman
      @store   = store
      @logger  = logger
      @serv    = nil
    end

    def run
      @serv = TCPServer.open(@profile.port)
      logInfo("Server is running.")

      Thread.start do
        loop do
          proc = ServerProcess.new(@profile, @serv.accept, @nodeman, @store, @logger)
          proc.run
        end
      end
    end
  end

  class ServerProcess
    include Log

    def initialize(profile, sock, nodeman, store, logger = nil)
      @profile     = profile
      @sock        = sock
      @nodeman     = nodeman
      @store       = store
      @logger      = logger
      @recvQueue   = Queue.new
      @interpreted = Queue.new
      @sendQueue   = Queue.new
      @node        = nil
      @threads     = ThreadGroup.new
    end

    def run
      addr = @sock.peeraddr[3]
      port = @sock.peeraddr[1]
      
      # receive
      recvThr = Thread.start do
        # XXX Thread Error
        # logInfo("connection request is accepted.[#{addr}:#{port}]")
        loop do
          str = ""
          while @sock.gets do
            str << $_
            break if $_ == "\n"
          end
          break if str == ""
          @recvQueue.enq(str.chomp) if str != "\n"
        end

        (@threads.list - [Thread.current]).each do |thr|
          thr.kill
        end
        
        # XXX Thread Error
        # logInfo("disconnected.[#{addr}:#{port}]")
        @sock.close unless @sock.closed?

        # for node search link
        if @node
          @node.lock
          begin
            @node.stat        = :STAT_EXIST
            @node.type        = :TYPE_WAIT
            @node.expire_time = Time.now + Node::LEASETIME
            @node.touch
          ensure
            @node.unlock
          end
        end
      end

      # decode
      decThr = Thread.start do
        while recvmes = @recvQueue.deq
          begin
            basicinfo = Message.decode(recvmes.chomp)
            mestype   = Message.name_of(basicinfo[Message::IDENTIFIER])
            data      = eval("#{mestype}.decode(recvmes.chomp)")

            raise ServerError, "invalid message received." unless mestype

            @interpreted.enq([mestype, data])
          rescue ServerError
            logWarn($!)
            interrupt
          rescue
            logError("illegal message received.[#{$!}]")
            interrupt
          end
        end
      end

      # receive action
      recvActThr = Thread.start do
        while mes = @interpreted.deq
          mestype, data = mes

          m = eval("#{mestype}.allocate")
          m.store = @store
          res = m.recvHandler(@profile, data)

          # internal special action
          case data[Message::IDENTIFIER]
          when Ticket::ID
            @node = Node.new(data[Ticket::NODE_INFO][Ticket::PORT], data[Ticket::NODE_INFO][Ticket::HOST], data[Ticket::SERVENT_ID], data[Ticket::SERVENT_BIRTH])

            @node.lock
            begin
              @node.stat = :STAT_CONNECTED
              @node.type = :TYPE_CLIENT
              @node.touch
            ensure
              @node.unlock
            end

            unless @nodeman.connect?(@node)
              begin
                @nodeman.addNode(@node, data[Message::DATE])
              rescue NodeError
                #
              end
            else
              logWarn("this node is connected.")
              interrupt
            end

            @sendQueue.enq(["ReturnTicket", @profile])
          when NodeListTransfer::ID
            list = data[NodeListTransfer::NODEINFO_DATA]

            list.each do |node|
              n = Node.new(*node)
              unless @nodeman.connect?(n)
                begin
                  @nodeman.addNode(n, data[Message::DATE])
                rescue NodeError
                  logDebug("node is not added.[#{n.addr}:#{n.port}]")
                end
              end
            end

            @sendQueue.enq(["ReturnNodeListTransfer", @profile, @nodeman.participantNode(@node, 10)])
          else
            @sendQueue.enq(res) if res
          end
        end
      end

      # encode/send
      encThr = Thread.start do
        while sendmes = @sendQueue.deq
          mes = eval("#{sendmes.shift}.new(*sendmes)")
          begin
            @sock.write(mes.encode)
          rescue
            interrupt
          end
        end
      end

      # threads
      @threads.add(recvThr)
      @threads.add(decThr)
      @threads.add(recvActThr)
      @threads.add(encThr)
    end

    def interrupt
      (@threads.list - [Thread.current]).each do |thr|
        thr.kill
      end

      @sock.close unless @sock.closed?
      logInfo("connection interrupted.[#{@node.addr}:#{@node.port}]") if Node === @node
    end
  end

  class ServerError < StandardError; end
end