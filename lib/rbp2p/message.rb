module RbP2P
  # Message between RubyP2P Servents.
  class Message
    attr_reader :waitReaction

    @@version = 2
    @@count   = 0
    @@names   = ["Message"]
    @template = "C C a16 N "

    ID         = @@count

    VERSION    = 0
    IDENTIFIER = 1
    SOURCE     = 2
    DATE       = 3
    
    LAST  = 3

    PORT = 0
    HOST = 1

    def self.inherited(subclass)
      @@count += 1
      @@names.push(subclass.to_s)
    end

    def self.num
      @@count
    end

    def self.name_of(id)
      @@names[id]
    end

    def self.names
      @@names
    end

    def initialize(profile)
      @source = [profile.port, profile.addr]
      @creation_time = Time.now
      
      @waitReaction = true
    end
    
    def store=(val)
      if Hash === val
        @store = val
      else
        raise MessageError, "can't set store."
      end
    end

    def encode(data = nil)
      data ||= Array.new
      data.unshift(@creation_time.to_i)
      data.unshift(pack_sockaddr_in(@source[0], @source[1]))
      data.unshift(eval("#{self.class}::ID"))
      data.unshift(@@version)

      template = eval("#{self.class.to_s}.template")
      "#{data.pack(template)}\n\n"
    end

    def self.decode(str)
      data = str.unpack(@template)
      data[SOURCE] = unpack_sockaddr_in(data[SOURCE])
      data[DATE] = Time.at(data[DATE])

      data
    end

    def pack_sockaddr_in(port, host)
      # IPv4 only
      if !port then
        raise MessageError, "can't pack sockaddr_in.(port is nil)"
      elsif !host
        raise MessageError, "can't pack sockaddr_in.(host is nil)"
      else
        tmp = host.split(".").collect{|c| c.to_i}
        tmp.push(port.to_i)
        tmp.pack("C4n")
      end
    end

    def self.unpack_sockaddr_in(addr)
      # IPv4 only
      if !addr then
        raise MessageError, "can't unpack sockaddr_in.(addr is nil)"
        nil
      else
        tmp = addr.unpack("C4n")
        port = tmp.pop
        host = tmp.join(".")
        [port, host]
      end
    end

    def self.template
      @template
    end

    def recvHandler
      # not define in this class.
      nil
    end
  end

  class Ticket < Message
    ID = @@count # don't forget!
    @template = Message.template + "a16 a40 N"

    NODE_INFO     = LAST + 1
    SERVENT_ID    = LAST + 2
    SERVENT_BIRTH = LAST + 3

    def initialize(profile)
      super(profile)

      @node_info     = [profile.port, profile.addr]
      @servent_id    = profile.id
      @servent_birth = profile.creation_time
    end

    def encode(data = nil)
      data ||= Array.new
      data.unshift(@servent_birth.to_i)
      data.unshift(@servent_id)
      data.unshift(pack_sockaddr_in(@node_info[0], @node_info[1]))
      super(data)
    end

    def self.decode(str)
      data = super
      data[NODE_INFO]     = unpack_sockaddr_in(data[NODE_INFO])
      data[SERVENT_BIRTH] = Time.at(data[SERVENT_BIRTH])

      data
    end

    def recvHandler(profile, recvmes)
      nil
    end
  end

  class ReturnTicket < Ticket
    ID = @@count # don't forget!
    @template = Ticket.template

    def recvHandler(profile, recvdata)
      nil
    end
  end

  class NodeListTransfer < Message
    ID = @@count # don't forget!

    NODEINFO_DATA = LAST + 1

    NODENUM = 10
    @template = Message.template + " a16 a40 N" * NODENUM

    def initialize(profile, nodeinfo)
      super(profile)

      @nodeinfo = nodeinfo
    end

    def encode(data = nil)
      data ||= Array.new

      (NodeListTransfer::NODENUM - @nodeinfo.size).times do
        data.unshift("", "", 0)
      end

      @nodeinfo.each do |n|
        data.unshift(n.creation_time.to_i)
        data.unshift(n.id)
        data.unshift(pack_sockaddr_in(n.port, n.addr))
      end

      if data.size < 3 * NodeListTransfer::NODENUM
        data[3 * NodeListTransfer::NODENUM - 1] = nil
      end

      super(data)
    end

    def self.decode(str)
      data = super

      nodeinfo = []
      for i in 0...NODENUM
        nodeinfo << [data[NODEINFO_DATA + i * 3], data[NODEINFO_DATA + i * 3 + 1], data[NODEINFO_DATA + i * 3 + 2]]
      end

      nodeinfo.map!{ |node|
        port, addr = unpack_sockaddr_in(node[0])
        id = node[1] != [nil].pack("a40") ? node[1] : nil
        birth = Time.at(node[2])

        [port, addr, id, birth]
      }

      nodeinfo.delete_if { |node|
        node[0] == 0
      }

      data[0..3].push(nodeinfo)
    end

    def recvHandler(profile, recvdata)
      nil
    end
  end

  class ReturnNodeListTransfer < NodeListTransfer
    ID = @@count # don't forget!
    @template = NodeListTransfer.template

    def recvHandler(profile, recvdata)
      nil
    end
  end

  class MessageError < StandardError; end

end
