# Hastur::Input::Collectd - parse collectd UDP packets and return a hash
#
# To work on this file, you'll need the following resources handy:
#
# http://collectd.org/wiki/index.php/Binary_protocol
#
# https://github.com/octo/collectd/blob/master/src/network.h
# https://github.com/octo/collectd/blob/master/src/network.c
#
# http://ruby-doc.org/core-1.9.3/String.html#method-i-unpack
# perldoc -f pack # (the perl pack docs are more thorough)

require 'hastur/exception'

module Hastur
  module Input
    module Collectd
      # constants from collectd/src/network.h
      TYPE_HOST            = 0x0000
      TYPE_TIME            = 0x0001
      TYPE_TIME_HR         = 0x0008
      TYPE_PLUGIN          = 0x0002
      TYPE_PLUGIN_INSTANCE = 0x0003
      TYPE_TYPE            = 0x0004
      TYPE_TYPE_INSTANCE   = 0x0005
      TYPE_VALUES          = 0x0006
      TYPE_INTERVAL        = 0x0007
      TYPE_INTERVAL_HR     = 0x0009
      TYPE_MESSAGE         = 0x0100
      TYPE_SEVERITY        = 0x0101
      TYPE_SIGN_SHA256     = 0x0200
      TYPE_ENCR_AES256     = 0x0210
      DS_TYPE_COUNTER      = 0
      DS_TYPE_GAUGE        = 1
      DS_TYPE_DERIVE       = 2
      DS_TYPE_ABSOLUTE     = 3

      # Decodes a single collectd UDP packet using offset tracking, returns a hash.
      # The first argument is a binary string (your recvfrom() buffer).
      # The second argument is a boolean. When set to true, nil is returned instead of raising
      # exceptions on invalid/unparsable packets.
      def self.decode_packet(data, tolerant)
        stats = {}
        offset = 0

        begin
          while offset < data.bytesize
            key, value, offset = self.decode_part(data, offset)
            stats[key] = value
          end
        rescue
          if tolerant
            return nil
          else
            raise
          end
        end

        return stats
      end

      # Decodes a collectd "part" and returns key, value.
      # First argument is the packet string, the second is the current offset into the packet (FixNum bytes).
      def self.decode_part(data, offset)
        type, len = data.unpack('@' + offset.to_s + 'nn') # uint16_t, uint16_t

        # decoding errors usually manifest quickly as bad types or unusual lengths
        if len.nil? or len > data.bytesize or type.nil? or type > TYPE_ENCR_AES256
          err = "Out of bounds value in UDP packet at byte #{offset}. Type: #{type}, Length: #{len}"
          throw Hastur::PacketDecodingError.new(err)
        end

        case type
          when TYPE_TIME
            key = :time
            value = self.unpack_uint64(data, offset, len)
          when TYPE_TIME_HR
            key = :time_hr
            value = self.unpack_uint64(data, offset, len)
          when TYPE_INTERVAL
            key = :interval
            value = self.unpack_uint64(data, offset, len)
          when TYPE_INTERVAL_HR
            key = :interval_hr
            value = self.unpack_uint64(data, offset, len)
          when TYPE_SEVERITY
            key = :severity
            value = self.unpack_uint64(data, offset, len)
          when TYPE_HOST
            key = :host
            value = self.unpack_string(data, offset, len)
          when TYPE_PLUGIN
            key = :plugin
            value = self.unpack_string(data, offset, len)
          when TYPE_PLUGIN_INSTANCE
            key = :plugin_instance
            value = self.unpack_string(data, offset, len)
          when TYPE_TYPE
            key = :type
            value = self.unpack_string(data, offset, len)
          when TYPE_TYPE_INSTANCE
            key = :type_instance
            value = self.unpack_string(data, offset, len)
          when TYPE_MESSAGE
            key = :message
            value = self.unpack_string(data, offset, len)
          when TYPE_VALUES
            key = :values
            value = self.decode_values(data, offset, len)
          when TYPE_SIGN_SHA256
            raise Hastur::UnsupportedError.new("collectd TYPE_SIGN_SHA256")
          when TYPE_ENCR_AES256
            raise Hastur::UnsupportedError.new("collectd TYPE_SIGN_AES256")
        else
          raise Hastur::PacketDecodingError.new "Invalid packet data type: #{type}, len: #{len}."
        end

        return key, value, (offset + len)
      end

      def self.unpack_string(data, offset, len)
        offset += 4
        len    -= 4
        bytes = data.unpack('@' + offset.to_s + 'Z' + len.to_s)
        bytes.pack('a*')
      end

      def self.unpack_uint64(data, offset, len)
        offset += 4
        len    -= 4
        data.unpack('@' + offset.to_s + 'Q')[0]
      end

      # Decode a values part. These are a bit different from the other parts since they
      # contain a list of values in a slightly smaller <type><value><type><value>... format.
      def self.decode_values(data, offset, len)
        values = []
        offset += 4 # skip type|len, already decoded
        nvals = data.unpack('@' + offset.to_s + 'n')[0]
        offset += 2 # 16-bit unsigned, network (big-endian)

        # Types are a packed array of uint8_t.
        # https://github.com/octo/collectd/blob/master/src/network.c#L535
        types = data.unpack('@' + offset.to_s + 'C' + nvals.to_s) # 8-bit unsigned (unsigned char)
        offset += nvals

        0.upto(nvals - 1) do |n|
          case types[n]
            when DS_TYPE_COUNTER
              pack = 'Q>' # network (big endian) unsigned integer
            when DS_TYPE_ABSOLUTE
              pack = 'Q>' # network (big endian) unsigned integer
            when DS_TYPE_GAUGE
              pack = 'E'  # x86 (little endian) double
            when DS_TYPE_DERIVE
              pack = 'q>' # network (big endian) signed integer
            else
              raise "Unknown value type: #{types[n]}"
          end

          value = data.unpack('@' + offset.to_s + pack)[0]
          values << value

          # all four types are 64 bits, just different encodings
          offset += 8
        end

        return values
      end
    end
  end
end

