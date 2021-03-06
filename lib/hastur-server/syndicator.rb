require 'ffi-rzmq'
require 'yajl'
require 'multi_json'
require 'uuid'
require 'socket'
require 'termite'

require "hastur/api"
require "hastur-server/message"
require "hastur-server/util"

module Hastur
  class Syndicator
    NAME_RE = %r{\A[-\.\w]+\Z}
    attr_reader :messages_processed, :messages_forwarded, :messages_dropped

    #
    # Create a new syndicator.
    # @example syndicator = Hastur::Syndicator.new
    #
    def initialize
      @filters                = {} # filter hashes
      @sockets                = {}
      @logger                 = Termite::Logger.new
      @messages_processed     = 0
      @messages_forwarded     = 0
      @messages_dropped       = 0
    end

    #
    # Return a _copy_ of the list of filters currently registered.
    # @return [Array<Hash>]
    #
    def filters
      # make it difficult to mess with the list directly
      @filters.dup
    end

    #
    # Return the (frozen) filter for this filter ID.
    # Used for apply_one_filter.
    #
    # @param [String] id The ID of this filter
    #
    def filter_for_id(id)
      @filters[id]
    end

    FILTER_OPTIONS = [ :uuid, :type, :name, :value, :attn, :subject, :labels ]

    #
    # Create a filter rule.  Messages are forwarded when all of the filter elements match.
    #
    # @param [Hash{Symbol => String}] opts
    # @option opts [String] :uuid
    # @option opts [String] :type
    # @option opts [String] :name
    # @option opts [String] :value
    # @option opts [String] :attn
    # @option opts [String] :subject
    # @option opts [String] :labels
    # @return [String] filter ID (uuid)
    # @example F.add_filter { :uuid => uuid }
    #
    def add_filter(opts)
      non_sym_keys = opts.keys.select { |k| !k.is_a?(Symbol) }
      non_sym_keys.each do |key|
        opts[key.to_sym] = opts[key]
        opts.delete(key)
      end

      bad_keys = opts.keys - FILTER_OPTIONS
      raise "Bad keys in syndicator filter: #{bad_keys.map(&:inspect).join(", ")}!" unless bad_keys.empty?

      filter = {}
      id = UUID.generate

      if opts[:uuid]
        if Hastur::Util.valid_uuid?(opts[:uuid])
          filter[:uuid] = opts[:uuid]
        else
          raise ArgumentError.new ":uuid must be a valid 36-byte hex UUID (#{opts[:uuid]})"
        end
      end

      if opts[:type]
        if opts[:type].respond_to?(:to_i) && Hastur::Message.type_id?(opts[:type].to_i)
          filter[:type] = opts[:type].to_i
        elsif opts[:type].respond_to?(:to_sym) && Hastur::Message.symbol?(opts[:type].to_sym)
          filter[:type] = Hastur::Message.symbol_to_type_id(opts[:type].to_sym)
        else
          raise ArgumentError.new "Filter :type must be a valid Hastur::Message type, but #{opts[:type].inspect} is not!"
        end
      end

      if opts[:name]
        # only accept strings that start with word characters, specifically trying to avoid
        # people passing in regexps or anything that doesn't make sense
        if NAME_RE.match opts[:name]
          filter[:name] = opts[:name]
        else
          raise ArgumentError.new ":name must be a string and conform to #{NAME_RE}"
        end
      end

      if opts[:attn] or opts[:subject]
        if filter[:type] and filter[:type] != Hastur::Message::Event.type_id
          raise ArgumentError.new ":attn only works for events"
        end
        filter[:type] = Hastur::Message::Event.type_id
      end

      if opts[:attn]
        if opts[:attn].kind_of? Array
          filter[:attn] = opts[:attn].map do |attn|
            raise ArgumentError.new ":attn items must be strings" unless attn.kind_of? String
            attn
          end
        else
          raise ArgumentError.new ":attn must be an array"
        end
      end

      if opts[:subject]
        unless opts[:subject].kind_of? String
          raise ArgumentError.new ":subject filter must be a string"
        end
        filter[:subject] = opts[:subject]
      end

      if opts[:labels]
        if opts[:labels].kind_of? Hash
          filter[:labels] = {}
          opts[:labels].each do |key,value|
            # auto-convert symbols to strings
            key = key.to_s if key.kind_of? Symbol
            value = value.to_s if value.kind_of? Symbol

            unless key.kind_of? String
              raise ArgumentError.new "label keys must be strings"
            end
            unless [String, Numeric, TrueValue, FalseValue].include?(value.class)
              raise ArgumentError.new "label values must be string/numeric/true/false"
            end

            filter[:labels][key] = value
          end
        else
          raise ArgumentError.new ":labels must be an array"
        end
      end

      # If these are both frozen, then a simple .dup on the Hash
      # will keep callers from being able to modify @filters
      # when it gets returned.
      #
      filter.freeze
      id.freeze
      @sockets[id] = []
      @filters[id] = filter

      id
    end

    #
    # add a destination socket to a filter by ID
    # @param [ZMQ::Socket] socket
    # @param [String] filter_id 36 byte UUID of the filter
    #
    # The only method called on sockets in this class is sendmsgs, so if you
    # want to mock a socket, that's all you need. It will be given two
    # ZMQ::Message objects.  You should probably call copy_out_string on
    # them.
    #
    def add_socket(socket, filter_id)
      raise ArgumentError.new "First arg must respond to :sendmsgs." unless socket.respond_to? :sendmsgs
      unless Hastur::Util.valid_uuid? filter_id
        raise ArgumentError.new "Second arg must be a 36-byte filter ID (uuid)."
      end

      @sockets[filter_id] << socket
    end

    private

    def mkey_for(message, key_sym)
      if message.has_key?(key_sym)
        key_sym
      elsif message.has_key?(key_sym.to_s)
        key_sym.to_s
      else
        nil
      end
    end

    public

    #
    # run exactly one filter.  Return true if the filter matches, and
    # yield the message to the block if one is given.
    #
    # @param [Hash] filter
    # @param [Hash] message
    # @yield [Hash] call the block with the message if the filter passes
    #
    def apply_one_filter(filter, message)
      filter.each do |key, value|
        next if [:labels, :attn, :data].include?(key) # Special cases

        mkey = mkey_for(message, key.to_sym)

        # message does not have the key in either string or symbol form
        if mkey.nil?
          # the only way to proceed is if the filter's value is false
          return false unless filter[key] == false
          # the message has the key
        else
          # success unless the filter says the key should not be there with value of false
          return false if filter[key] == false
        end

        case filter[key]
        when true
          # filter requires the key is present, value is ignored
          return false if mkey.nil?
        when false
          # filter requires the key is NOT present, value is ignored
          return false unless mkey.nil?
        else
          # filter requires the key is present and the values match exactly
          return false if message[mkey] != filter[key]
        end
      end

      # process attn separately, make sure specified values are included
      if filter[:attn]
        mkey = mkey_for(message, :attn)

        return false if mkey.nil? && filter[:attn] == true
        return false unless (mkey ? message[mkey] : []) & filter[:attn] == filter[:attn]
      end

      # process labels separately, using a recursive call, it should only ever be one level
      if filter[:labels]
        mkey = mkey_for(message, :labels)

        return false if mkey.nil? && filter[:labels] == true
        return false unless apply_one_filter filter[:labels], mkey ? message[mkey] : {}
      end

      # TODO(noah): combine checking :labels and :data since the logic is the same
      if filter[:data]
        mkey = mkey_for(message, :data)

        return false if mkey.nil? && filter[:data] == true
        return false unless apply_one_filter filter[:data], mkey ? message[mkey] : {}
      end

      yield message if block_given?

      true
    end

    #
    # Run all of the registered filters on a message.
    # @param [Hash] message a message in hash format
    # @yield [Hash] block to call if there is an error sending on the socket
    # @return [Fixnum] number of times the message was forwarded
    #
    def apply_all_filters(message)
      times_forwarded = 0
      @messages_processed += 1

      @filters.each do |id, filter|
        apply_one_filter message, filter do
          @sockets[id].each do |socket|
            out = [
              ZMQ::Message.new(id),
              ZMQ::Message.new(message)
            ]

            rc = socket.sendmsgs out
            if ZMQ::Util.resultcode_ok?(rc)
              times_forwarded += 1
            else
              errdata = { :rc => rc, :id => id, :message => message, :filter => filter.dup, :socket => socket }
              yield errdata
            end

            out.each do |m| m.close end
          end
        end
      end

      @messages_forwarded += times_forwarded
      if times_forwarded == 0
        @messages_dropped += 1
      end

      times_forwarded
    end
  end
end
