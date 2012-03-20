require "thread"
require "logger"
require "socket"
require "digest"
require "yaml"

Dir.chdir("#{File.dirname(__FILE__)}/rbp2p") do
  require "module"
  require "message"
  require "node"
  require "server"
  require "client"
end

module RbP2P
  # Servent is a class which represents RubyP2P servent instance.
  class Servent
    include Log

    VERSION = "0.2"

    # Create a new RubyP2P servent instance.
    def initialize(spec = nil)
      # load config file.
      begin
        if String === spec
          config = YAML.load_file(spec)["RubyP2P"]
        elsif Hash === spec
          config = spec
        else
          config = {}
        end
      rescue
        raise ServentError, "#{$!}"
      end

      service_port = config["service_port"] || 50000
      addr         = Socket.getaddrinfo(Socket.gethostname, nil, Socket::AF_INET)[0][3]
      birth_time   = Time.now
      id           = Digest::SHA1.hexdigest("#{addr}#{service_port}#{birth_time}")

      @nodes_file  = config["nodes_file"]
      @init_nodes  = config["init_nodes"]

      begin
        @profile = Node.new(service_port, addr, id, birth_time)
      rescue
        raise ServentError, "#{$!}"
      end

      # logger
      @logger = nil
      if config["log_file"] && (String === config["log_file"] || (config["log_file"].respond_to?("write") && config["log_file"].respond_to?("close")))
        @logger = Logger.new(config["log_file"])
        
        if config["log_level"]
          begin
            @logger.level = eval("Logger::#{config["log_level"]}")
          rescue NameError
            @logger.level = Logger::INFO
          end
        else
          @logger.level = Logger::INFO
        end
        @logger.progname = "RubyP2P"
      end
      
      @store = Hash.new
      
      begin
        # make Node Manager.
        @nodeman = NodeManager.new(@nodes_file, @init_nodes, @profile, @logger)
      rescue
        raise ServentError, "#{$!}"
      end

      begin
        # make Server.
        @server = Server.new(@profile, @nodeman, @store, @logger)
      rescue
        raise ServentError, "#{$!}"
      end

      begin
        # make Client.
        @client = Client.new(@profile, @nodeman, @store, @logger)
      rescue
        raise ServentError, "#{$!}"
      end
    end

    def start
      @nodeman.run
      @server.run
      @client.run
    end

    def to_s
      str = ""
      str << "- Profile -\n"
      str << "\t#{@profile}"

      str
    end

    def inspect
      to_s
    end
    
    def [](key)
      @store[key]
    end

    def []=(key, val)
      @store[key] = val;
    end

    def broadcast(mestype, *args)
      @client.requests.enq([mestype, nil, args])
    end
    
    def send(mestype, sendto, *args)
      if sendto != nil && list.include?(sendto)
        @client.requests.enq([mestype, sendto, args])
      else
        raise ServentError, "Unknown node."
      end
    end
    
    def host
      @profile.addr
    end
    
    def port
      @profile.port
    end
    
    def id
      @profile.id
    end
    
    def list
      @nodeman.idList
    end
    
    def ipaddr_and_ports
      (@nodeman.list - [@profile]).map {|n| [n.port, n.addr]}
    end
  end

  class ServentError < StandardError; end
end