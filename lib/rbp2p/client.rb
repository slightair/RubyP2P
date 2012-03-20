require "timeout"

module RbP2P
  class Client
    include Log

    attr_reader :requests

    def initialize(profile, nodeman, store, logger = nil)
      @profile  = profile
      @nodeman  = nodeman
      @store    = store
      @logger   = logger
      @requests = Queue.new
    end

    def run
      # node search link connection
      Thread.start do
        loop do
          cand = @nodeman.nodelist.waitNodes.sort{|a, b|a.modified_time <=> b.modified_time}.shift

          if cand
            cand.lock
            begin
              cand.type = :TYPE_TEST
              cand.touch
            ensure
              cand.unlock
            end

            nodesearch = NodeSearchConnection.new(@profile, cand, @nodeman, @store, @logger)
            nodesearch.run
          end
          sleep rand(3) + 3
        end
      end

      # information transfer link
      Thread.start do
        while req = @requests.deq
          mestype, sendto, args = req

          if sendto
            node = @nodeman.id2node(sendto)
            transfer = TransferConnection.new(@profile, node, [mestype, @profile, *args], @store, @logger)
            transfer.run
          else
            @nodeman.idList.each do |id|
              unless id == @profile.id
                node = @nodeman.id2node(id)
                transfer = TransferConnection.new(@profile, node, [mestype, @profile, *args], @store, @logger)
                transfer.run
              end
            end
          end
        end
      end
    end
  end

  class NodeSearchConnection
    include Log

    def initialize(profile, node, nodeman, store, logger = nil)
      @profile     = profile
      @node        = node
      @nodeman     = nodeman
      @store       = store
      @logger      = logger
      @sock        = nil
      @recvQueue   = Queue.new
      @interpreted = Queue.new
      @sendQueue   = Queue.new
      @threads     = ThreadGroup.new
      @fin         = false
    end

    def connect
      begin
        timeout(5, ResolvTimeoutError) do
          @sock = TCPSocket.open(@node.addr, @node.port)
        end
        logInfo("connection success.[#{@node.addr}:#{@node.port}]")
      rescue ResolvTimeoutError
        @node.lock
        begin
          @node.stat = :STAT_MISSING
          @node.type = :TYPE_WAIT
          @node.touch
        ensure
          @node.unlock
        end
        raise ClientError, "cannot find node.[#{@node.addr}:#{@node.port}]"
      rescue
        @node.lock
        begin
          @node.stat = :STAT_MISSING
          @node.type = :TYPE_WAIT
          @node.touch
        ensure
          @node.unlock
        end
        raise ClientError, "connection failed.[#{@node.addr}:#{@node.port}]"
      end
    end

    def close
      @sock.close unless @sock.closed?
      logInfo("connection termination.[#{@node.addr}:#{@node.port}]")

      Thread.exclusive do
        (@threads.list - [Thread.current]).each do |thr|
          thr.kill
        end
      end

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

    def run
      begin
        connect

        # receive
        recvThr = Thread.start do
          begin
            until @sock.closed? do
              str = ""
              while @sock.gets do
                str << $_
                break if $_ == "\n"
              end
              break if str == ""
              @recvQueue.enq(str.chomp) if str != "\n"
            end
          rescue
            logWarn($!)
            close
          end
        end

        # decode
        decThr = Thread.start do
          while recvmes = @recvQueue.deq
            begin
              basicinfo = Message.decode(recvmes.chomp)
              mestype   = Message.name_of(basicinfo[Message::IDENTIFIER])
              data      = eval("#{mestype}.decode(recvmes.chomp)")

              raise ClientError, "invalid message received." unless mestype

              @interpreted.enq([mestype, data])
            rescue ClientError
              logError($!)
              close
            rescue
              logError("illegal message received.")
              close
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
            when ReturnTicket::ID
              # if @node == Node.new(data[Ticket::NODE_INFO][Ticket::PORT], data[Ticket::NODE_INFO][Ticket::HOST], data[Ticket::SERVENT_ID], data[Ticket::SERVENT_BIRTH])
              sender = Node.new(data[Ticket::NODE_INFO][Ticket::PORT], data[Ticket::NODE_INFO][Ticket::HOST], data[Ticket::SERVENT_ID], data[Ticket::SERVENT_BIRTH])
              if @node == sender
                @node.lock
                begin
                  @node.stat          = :STAT_CONNECTED
                  @node.type          = :TYPE_SERVER
                  @node.id            = data[Ticket::SERVENT_ID]
                  @node.creation_time = data[Ticket::SERVENT_BIRTH]
                  @node.expire_time   = Time.now + Node::LEASETIME
                  @node.touch
                ensure
                  @node.unlock
                end

                @sendQueue.enq(["NodeListTransfer", @profile, @nodeman.participantNode(@node, 10)])
              else
                logError("Ticket received from illegal node.")
                close
              end
            when ReturnNodeListTransfer::ID
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

              close
            else
              if res
                @sendQueue.enq(res)
              else
                close
              end
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
              close
            end
          end
        end

        # threads
        @threads.add(recvThr)
        @threads.add(decThr)
        @threads.add(recvActThr)
        @threads.add(encThr)

        @sendQueue.enq(["Ticket", @profile])
      rescue ClientError
        logError($!)
      end
    end

    class ResolvTimeoutError < TimeoutError; end
  end

  # TODO multi thread operation.
  class TransferConnection
    include Log

    def initialize(profile, node, message, store, logger = nil)
      @profile = profile
      @node    = node
      @message = message
      @store   = store
      @logger  = logger
      @sock    = nil
      @thread  = nil
    end

    def run
      @thread = Thread.start do
        begin
          timeout(5, ResolvTimeoutError) do
            @sock = TCPSocket.open(@node.addr, @node.port)
          end
          logInfo("connection success.[#{@node.addr}:#{@node.port}]")
        
          message = eval("#{@message.shift}.new(*@message)")
          @sock.write(message.encode)
        
          if message.waitReaction
            timeout(3, ClientError) do
              #receive
              str = ""
              while @sock.gets do
                str << $_
                break if $_ == "\n"
              end
            
              if str != "\n"
                basicinfo = Message.decode(str.chomp)
                mestype   = Message.name_of(basicinfo[Message::IDENTIFIER])
                data      = eval("#{mestype}.decode(str.chomp)")

                unless mestype
                  "invalid message received."
                else
                  m = eval("#{mestype}.allocate")
                  m.store = @store
                  m.recvHandler(@profile, data)
                end
              end
            end
          end

          @sock.close
          logInfo("connection termination.[#{@node.addr}:#{@node.port}]")
        rescue ResolvTimeoutError
          logError("cannot find node.[#{@node.addr}:#{@node.port}]")
        rescue
          logError("connection failed.[#{@node.addr}:#{@node.port}]")
        end
      end
    end

    class ResolvTimeoutError < TimeoutError; end
  end

  class ClientError < StandardError; end
end