module RbP2P
  class ChatTalk < Message
    ID = @@count # don't forget!
    @template = Message.template + "a16 m*"

    NAME    = LAST + 1
    MESSAGE = LAST + 2

    def initialize(profile, name, message)
      super(profile)

      @name    = name
      @message = message
    end

    def encode(data = nil)
      data ||= Array.new
      data.unshift(@message)
      data.unshift(@name)
      super(data)
    end

    def self.decode(str)
      data = super

      data
    end

    def recvHandler(profile, recvdata)
      source  = "#{recvdata[SOURCE][HOST]}:#{recvdata[SOURCE][PORT]}"
      date    = recvdata[DATE]
      name    = recvdata[NAME]
      message = recvdata[MESSAGE]
      
      puts "#{date.strftime("%X")} (#{name}) #{message}"
      
      nil
    end
  end
  
  class LookUp < Message
    ID = @@count # don't forget!
    @template = Message.template + "a16 a40"

    USERNAME = LAST + 1
    NODEID   = LAST + 2

    def initialize(profile, name, id)
      super(profile)

      @name = name
      @id   = id
    end

    def encode(data = nil)
      data ||= Array.new
      data.unshift(@id)
      data.unshift(@name)
      super(data)
    end

    def self.decode(str)
      data = super

      data
    end

    def recvHandler(profile, recvdata)
      ["NameCard", profile, @store[:clientName], profile.id]
    end
  end
  
  class NameCard < Message
    ID = @@count # don't forget!
    @template = Message.template + "a16 a40"

    USERNAME = LAST + 1
    NODEID   = LAST + 2

    def initialize(profile, name, id)
      super(profile)

      @name = name
      @id   = id
    end

    def encode(data = nil)
      data ||= Array.new
      data.unshift(@id)
      data.unshift(@name)
      super(data)
    end

    def self.decode(str)
      data = super
      
      data[USERNAME].rstrip!

      data
    end

    def recvHandler(profile, recvdata)
      @store[:members][recvdata[USERNAME]] = recvdata[NODEID]

      nil
    end
  end

end