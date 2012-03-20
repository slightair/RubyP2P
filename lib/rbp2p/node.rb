module RbP2P
  # NodeManager.
  class NodeManager
    attr_reader :nodelist

    include Log

    def initialize(nodes_file, init_nodes, profile, logger = nil)
      @version    = Servent::VERSION
      @nodes_file = nodes_file
      @init_nodes = init_nodes
      @profile    = profile
      @logger     = logger

      begin
        @nodelist = NodeList.new(@profile)
      rescue
        logFatal($!)
        raise NodeManagerError, "#{$!}"
      end
    end

    # add node to nodelist.
    def addNode(node, date)
      begin
        @nodelist.add(node, date)
        logDebug("new node added.")
        node
      rescue NodeError
        logError("node adding canceled.")
        raise $!
      rescue TypeError
        logError("cannot add specified node.")
        raise $!
      end
    end

    # add nodes to nodelist.
    # argument: [[port, addr, id], ...]
    def addNodeGroup(group)
      if Array === group then
        n = 0
        group.each do |i|
          begin
            port, addr, id = *i
            addr = @profile.addr if addr == "127.0.0.1"
            
            node = Node.new(port, addr, id)
            @nodelist.add(node, Time.now)
            n += 1
          rescue NodeError, TypeError
            logError("cannot add specified node (#{i[1]}:#{i[0]}).")
          end
        end
        logInfo("#{n} nodes added.") if n > 0
      else
        logError("invalid node group.")
      end
    end

    # load nodes file.
    def load(file)
      tmp = Array.new
      begin
        open(file) do |io|
          while line = io.gets do
            line.chomp!
            if %r!^(\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}):(\d{4,5})! =~ line then
              tmp.push([$2,$1]) if $2.to_i > 1023 && $2.to_i < 65536
            end
          end
        end
      rescue => e
        logError($!)
      end
      logInfo("nodes file loaded.") if tmp.size > 0

      tmp.uniq!

      addNodeGroup(tmp)
    end

    # dump nodes file.
    def dump(file)
      begin
        open(file,"w") do |io|
          io.write("# RubyP2P node database - ver #{@version}\n")
          @nodelist.to_a.each do |node|
            unless node.type == :TYPE_SELF
              io.write("#{node.addr}:#{node.port}\n")
            end
          end
        end
      rescue => e
        logError($!)
        raise NodeManagerError, "cannot dump nodes list."
      end
    end

    # run node manager.
    def run
      Thread.start do
        logInfo("Node Manager is running.")
        load(@nodes_file) if @nodes_file
        
        if Array === @init_nodes
          tmp = Array.new
          @init_nodes.each do |n|
            if String === n
              if %r!^(\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}):(\d{4,5})! =~ n then
                tmp.push([$2,$1]) if $2.to_i > 1023 && $2.to_i < 65536
              end
            end
          end
          
          tmp.uniq!
          
          addNodeGroup(tmp)
        end
        
        loop do
          begin
            @profile.lock
            @profile.expire_time = Time.now + Node::LEASETIME
            @profile.touch
            @profile.unlock

            @nodelist.clean
            logDebug("clean node list.")
            
            if @nodes_file
              dump(@nodes_file)
              logDebug("dump node list.")
            end

            sleep 3
          rescue NodeManagerError
            raise ServentError, "#{$!}"
          end
        end
      end
    end

    def connect?(node)
      n = @nodelist.include?(node)

      if n
        [:TYPE_SERVER, :TYPE_CLIENT].include?(n.type)
      else
        false
      end
    end

    # get nodelist.
    def list
      @nodelist.to_a
    end

    def participantNode(node, num = nil)
      part = @nodelist.existingNodes - [@profile, node]
      if Integer === num
        part[0, num]
      else
        part
      end
    end

    def idList
      @nodelist.to_a.map{|n| n.id == "" ? nil : n.id}.compact
    end

    def id2node(id)
      node = nil
      @nodelist.to_a.each do |n|
        node = n if n.id == id
      end

      node
    end
  end

  # Nodelist of Servent
  class NodeList
    # initialize method
    def initialize(profile)
      @nodes = Array.new
      @profile = profile
      @m = Mutex.new

      @profile.lock
      begin
        @profile.type = :TYPE_SELF
      ensure
        @profile.unlock
      end

      add(@profile, Time.now)
    end

    # add node object.
    def add(node, date)
      if Node === node then
        unless n = include?(node) then
          @m.synchronize do
            @nodes.push(node)
          end
        else
          if n.creation_time <= node.creation_time && n.modified_time < date
            delete(n)
            @m.synchronize do
              @nodes.push(node)
            end
          else
            raise NodeError, "This node already existed (#{node})."
          end
        end
      else
        raise TypeError, "node is invalid."
      end
    end

    def include?(node)
      tmp = nil
      if node then
        each do |n|
          tmp = n if node == n
        end
      end

      tmp
    end

    # delete node from node array.
    def delete(node)
      @m.synchronize do
        @nodes.delete(node)
      end
    end

    def to_a
      @nodes
    end

    def size
      @nodes.size
    end

    def each
      @nodes.each do |node|
        yield(node)
      end
    end

    def missingNodes
      @nodes.map{|n| n.stat == :STAT_MISSING ? n : nil}.compact
    end

    def connectedNodes
      @nodes.map{|n| n.stat == :STAT_CONNECTED ? n : nil}.compact
    end

    def existingNodes
      @nodes.map{|n| n.stat != :STAT_MISSING ? n : nil}.compact
    end

    def serverNodes
      @nodes.map{|n| n.type == :TYPE_SERVER ? n : nil}.compact
    end

    def clientNodes
      @nodes.map{|n| n.type == :TYPE_CLIENT ? n : nil}.compact
    end

    def waitNodes
      @nodes.map{|n| n.type == :TYPE_WAIT ? n : nil}.compact
    end

    def clean
      @nodes.delete_if{|node| node.expire_time < Time.now}
    end
  end

  # Node of Servent.
  # 
  # status.
  #   :STAT_MISSING
  #   :STAT_EXIST
  #   :STAT_CONNECTED
  # 
  # type.
  #   :TYPE_SELF
  #   :TYPE_CLIENT
  #   :TYPE_SERVER
  #   :TYPE_WAIT
  #   :TYPE_TEST
  # 
  class Node
    include Comparable

    # accessor
    attr_reader :port, :addr, :type, :stat, :id, :creation_time, :modified_time, :expire_time
    
    # @@selfAddr = ""
    # 
    # def self.selfAddr=(addr)
    #   @selfAddr = addr
    #   p @selfAddr
    # end
    # 
    LEASETIME = 180 # sec

    # initialize method
    def initialize(port, addr, id=nil, creation_time=nil)

      #port number check.
      if(port && (port.to_i > 1023 && port.to_i < 65536)) then
        @port = port.to_s
      else
        raise NodeError, "The port number of node is invalid. (#{port} ?)"
      end

      #IP address check.
      if(addr && %r!^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}! =~ addr) then
        @addr = addr.to_s
      else
        raise NodeError, "The IP address of node is invalid. (#{addr} ?)"
      end

      #id check
      if !id then
        @id = ""
      elsif %r!^\w{40}$! =~ id then
        @id = id
      else
        raise NodeError, "The id of node is invalid. (#{id})?"
      end

      #creation_time time check
      if !creation_time then
        @creation_time = Time.at(0)
      elsif Time === creation_time then
        @creation_time = creation_time
      else
        raise NodeError, "The creation_time of node is invalid. (#{creation_time} ?)"
      end

      @type          = :TYPE_WAIT
      @stat          = id ? :STAT_EXIST : :STAT_MISSING
      @modified_time = Time.now
      @expire_time   = Time.now + LEASETIME
      @m             = Mutex.new
    end

    def ==(other)
      if other && Node === other
        if other.id != "" && other.id == @id
          true
        elsif other.port == @port && other.addr == @addr
          true
        # elsif @id == "" && other.port == @port && (@addr == "127.0.0.1" && other.addr == @@selfAddr)
        #   true
        else
          false
        end
      else
        false
      end
    end

    def <=>(other)
      if other && Node === other
        if self == other
          0
        else
          if @creation_time > other.creation_time
            1
          else 
            -1
          end
        end
      else
        nil
      end
    end

    def lock
      @m.lock
    end

    def unlock
      @m.unlock
    end

    def locked?
      @m.locked?
    end

    # set node type.
    def type=(type)
      if locked? then
        if type != @type && (type == :TYPE_WAIT || [:TYPE_WAIT, :TYPE_TEST].include?(@type))
          @type = type
        else
          raise NodeError, "can't change node type.[#{@type} -> #{type}]"
        end
      else
        raise NodeError, "node is not locked."
      end
    end

    # set node status.
    def stat=(status)
      if locked? then
        @stat = status
      else
        raise NodeError, "node is not locked."
      end
    end

    # set node id.
    def id=(id)
      if locked? then
        @id = id
      else
        raise NodeError, "node is not locked."
      end
    end

    # set node creation_time.
    def creation_time=(time)
      if locked? then
        @creation_time = time
      else
        raise NodeError, "node is not locked."
      end
    end

    # set node expire_time.
    def expire_time=(time)
      if locked? then
        @expire_time = time
      else
        raise NodeError, "node is not locked."
      end
    end

    # update modified_time.
    def touch
      if locked? then
        @modified_time = Time.now
      else
        raise NodeError, "node is not locked."
      end
    end

    def to_s
      "#{@addr}:#{@port} [#{@id}] [#{@type}] [#{@stat}] [#{@expire_time.strftime("%Y/%m/%d %X")}] [#{@creation_time.strftime("%Y/%m/%d %X")}]"
    end

    def inspect
      to_s
    end
  end

  class NodeError < StandardError; end
  class NodeManagerError < StandardError; end
end