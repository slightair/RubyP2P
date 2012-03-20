#!/usr/bin/env ruby

require "readline"
require "shellwords"
require "yaml"

require "rbp2p"
require "messages"

def main(args)
  
  # make servernt
  servent = RbP2P::Servent.new(args[0])
  servent.start

  # disable Ctrl+C
  trap("INT", "SIG_IGN")
  
  config = YAML.load_file(args[0])["P2PChat"] if args[0]
  name = Hash === config ? config["name"] : "nameless"
  servent[:clientName] = name
  
  progname = "P2PChat"
  while buf = Readline.readline("[#{name}@#{servent.host}:#{servent.port}] > ",true)
    line = Shellwords.shellwords(buf)
    cmd  = line.shift || ""
  
    if cmd=="/quit" || cmd=="/q" then
      puts "bye!"
      break
    elsif cmd=="/tell" || cmd=="/t" then
      user = line[0] || ""
      mes  = line[1] || ""
      begin
        servent.send("ChatTalk", servent[:members][user], name, mes)
      rescue
        puts "unknown user \"#{user}\"."
      end
    elsif cmd=="/members" || cmd=="/m" then
      servent[:members] = {}
      servent.broadcast("LookUp", name, servent.id)
      sleep 3
      
      puts "- member list -"
      servent[:members].each do |n, id|
        puts n
      end
    elsif cmd=="/help" || cmd=="/h" then
      puts "#{progname} - (RubyP2P ver.#{RbP2P::Servent::VERSION}) command list"
      puts "   /t,  /tell <user> <message>  : send direct message to specified user."
      puts "   /m,  /members                : show member list."
      puts "   /q,  /quit                   : quit #{progname}."
      puts "   /h,  /help                   : show this message."
    elsif cmd=="" then
    else
      servent.broadcast("ChatTalk", name, cmd)
    end
  end
end

main(ARGV)
