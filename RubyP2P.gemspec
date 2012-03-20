Gem::Specification.new do |spec|
  spec.name = "rbp2p"
  spec.version = "0.2.2"
  spec.summary = "P2P Networking Library for Ruby."
  spec.authors = ["slightair"]
  # spec.homepage = ""
  spec.files = Dir.glob("lib/rbp2p/*.rb") << "lib/rbp2p.rb" << "README"
  spec.has_rdoc = true
  spec.extra_rdoc_files << "README"
  spec.rdoc_options << "--title" << "RubyP2P" << "--charset" << "utf-8"
end 
