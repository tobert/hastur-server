#!/usr/bin/env ruby
require "trollop"
require "hastur-server/util"
require "hastur-server/message"
require "hastur-server/cassandra/schema"

STDOUT.sync = true # make stdout flush immediately

opts = Trollop::options do
  banner "Creates a Cassandra keyspace\n\nOptions:"
  opt :cassandra, "Cassandra URI(s)",       :default => ["127.0.0.1:9160"],        :type => :strings,
                                                                                   :multi => true
  opt :sinks,     "Router sink URI(s)",     :default => ["tcp://127.0.0.1:8127"],  :type => :strings,
                                                                                   :multi => true
  opt :acks_to,   "Router ack URI(s)",      :default => ["tcp://127.0.0.1:8134"],  :type => :strings,
                                                                                   :multi => true
  opt :keyspace,  "Keyspace",               :default => "Hastur",                  :type => String
  opt :hwm,       "ZMQ message queue size", :default => 1,                         :type => :int
end

unless opts[:sinks].flatten.all? { |uri| Hastur::Util.valid_zmq_uri? uri }
  Trollop::die :sinks, "must be in this format: protocol://hostname:port.  Sinks: #{opts[:sinks].inspect}"
end

unless opts[:acks_to].flatten.all? { |uri| Hastur::Util.valid_zmq_uri? uri }
  Trollop::die :acks_to, "must be in this format: protocol://hostname:port"
end

ctx = ZMQ::Context.new

msg_socket = Hastur::Util.connect_socket(ctx, ::ZMQ::PULL, opts[:sinks].flatten)
ack_socket = Hastur::Util.connect_socket(ctx, ::ZMQ::PUSH, opts[:acks_to].flatten)

puts "Connecting to Cassandra at #{opts[:cassandra].flatten.inspect}"
client = Cassandra.new(opts[:keyspace], opts[:cassandra].flatten)

@running = true
%w(INT TERM KILL).each do | sig |
  Signal.trap(sig) do
    @running = false
    Signal.trap(sig, "DEFAULT")
  end
end

while @running do
  begin
    message = Hastur::Message.recv(msg_socket)
    envelope = message.envelope
    uuid = message.envelope.from
    puts "[cass-sink.rb] [#{envelope.type_symbol}] - #{message.to_hash.inspect}"
    Hastur::Cassandra.insert(client, message.payload, envelope.type_symbol.to_s, :uuid => uuid)
    envelope.to_ack.send(ack_socket) if envelope.ack?
  rescue Hastur::ZMQError
    sleep 1
  rescue Exception => e
    puts e.message
    puts e.backtrace
  end
end

# client will throw backtraces if it's not closed
client.disconnect!
# clean up ZMQ sockets / context
msg_socket.close
ack_socket.close
ctx.terminate

STDERR.puts "Cassandra Sink Exited!"
