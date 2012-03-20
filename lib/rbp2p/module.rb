module RbP2P
  module Log
    def logDebug(message)
      @logger.debug(message){self.class.to_s} if @logger
    end

    def logInfo(message)
      @logger.info(message){self.class.to_s} if @logger
    end

    def logWarn(message)
      @logger.warn(message){self.class.to_s} if @logger
    end

    def logError(message)
      @logger.error(message){self.class.to_s} if @logger
    end

    def logFatal(message)
      @logger.fatal(message){self.class.to_s} if @logger
    end
  end
end