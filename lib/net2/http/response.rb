require "net2/http/header"
require "net2/http/gzip"
require "net2/http/readers"

module Net2
  class HTTP
    class Response   # reopen

      class << self
        def read_new(sock)   #:nodoc: internal use only
          httpv, code, msg = read_status_line(sock)
          res = response_class(code).new(httpv, code, msg)

          each_response_header(sock) { |k,v| res.add_field k, v }
          res.socket = sock

          res
        end

      private

        def read_status_line(sock)
          str = sock.readline
          m = /\AHTTP(?:\/(\d+\.\d+))?\s+(\d\d\d)\s*(.*)\z/in.match(str)
          raise HTTPBadResponse, "wrong status line: #{str.dump}" unless m
          m.captures
        end

        def response_class(code)
          CODE_TO_OBJ[code] or
          CODE_CLASS_TO_OBJ[code[0,1]] or
          HTTPUnknownResponse
        end

        # Read the beginning of the response, looking for headers
        def each_response_header(sock)
          key = value = nil

          while true
            # read until a newline
            line = sock.readuntil("\n", true).rstrip

            # empty line means we're done with headers
            break if line.empty?

            first = line[0]
            line.strip!

            # initial whitespace means it's part of the last header
            if first == ?\s || first == ?\t && value
              value << ' ' unless value.empty?
              value << line
            else
              yield key, value if key
              key, value = line.split(/\s*:\s*/, 2)
              raise HTTPBadResponse, 'wrong header line format' if value.nil?
            end
          end

          yield key, value if key
        end
      end

      include HTTPHeader

      def initialize(httpv, code, msg)   #:nodoc: internal use only
        @http_version = httpv
        @code         = code
        @message      = msg

        initialize_http_header nil
        @body = nil
        @read = false
      end

      # The HTTP version supported by the server.
      attr_reader :http_version

      # The HTTP result code string. For example, '302'.  You can also
      # determine the response type by examining which response subclass
      # the response object is an instance of.
      attr_reader :code

      attr_accessor :socket

      attr_accessor :request

      # The HTTP result message sent by the server. For example, 'Not Found'.
      attr_reader :message
      alias msg message   # :nodoc: obsolete

      def inspect
        "#<#{self.class} #{@code} #{@message} readbody=#{@read}>"
      end

      #
      # response <-> exception relationship
      #

      def code_type   #:nodoc:
        self.class
      end

      def error!   #:nodoc:
        raise error_type().new(@code + ' ' + @message.dump, self)
      end

      def error_type   #:nodoc:
        self.class::EXCEPTION_TYPE
      end

      # Raises an HTTP error if the response is not 2xx (success).
      def value
        error! unless self.kind_of?(HTTPSuccess)
      end

      #
      # header (for backward compatibility only; DO NOT USE)
      #

      def response   #:nodoc:
        warn "#{caller(1)[0]}: warning: HTTPResponse#response is obsolete" if $VERBOSE
        self
      end

      def header   #:nodoc:
        warn "#{caller(1)[0]}: warning: HTTPResponse#header is obsolete" if $VERBOSE
        self
      end

      def read_header   #:nodoc:
        warn "#{caller(1)[0]}: warning: HTTPResponse#read_header is obsolete" if $VERBOSE
        self
      end

      def body_exist?
        request.response_body_permitted? && self.class.body_permitted?
      end

      def finished?
        @closed
      end

      # Gets the entity body returned by the remote HTTP server.
      #
      # If a block is given, the body is passed to the block, and
      # the body is provided in fragments, as it is read in from the socket.
      #
      # Calling this method a second or subsequent time for the same
      # HTTPResponse object will return the value already read.
      #
      #   http.request_get('/index.html') {|res|
      #     puts res.read_body
      #   }
      #
      #   http.request_get('/index.html') {|res|
      #     p res.read_body.object_id   # 538149362
      #     p res.read_body.object_id   # 538149362
      #   }
      #
      #   # using iterator
      #   http.request_get('/index.html') {|res|
      #     res.read_body do |segment|
      #       print segment
      #     end
      #   }
      #
      def read_body(dest = nil, &block)
        if @read
          raise IOError, "#{self.class}\#read_body called twice" if dest or block
          return @body
        end
        to = build_pipeline(dest, block)
        stream_check
        if body_exist?
          read_body_0 to
          @body = to
        else
          @body = nil
        end
        @read = @closed = true

        @body
      end

      # When using the same connection for multiple requests, a response
      # must be closed before the next request can be initiated. Closing
      # a response ensures that all of the expected body has been read
      # from the socket.
      def close
        return if @closed
        read_body
      end

      # Returns the full entity body.
      #
      # Calling this method a second or subsequent time will return the
      # string already read.
      #
      #   http.request_get('/index.html') {|res|
      #     puts res.body
      #   }
      #
      #   http.request_get('/index.html') {|res|
      #     p res.body.object_id   # 538149362
      #     p res.body.object_id   # 538149362
      #   }
      #
      def body
        read_body
        return @body if @body.is_a?(String)
        return @body.string if @body.respond_to?(:string)
      end

      # Because it may be necessary to modify the body, Eg, decompression
      # this method facilitates that.
      def body=(value)
        @body = value
      end

      def read_nonblock(len)
        @nonblock_endpoint ||= begin
          @buf = ""
          @buf.force_encoding("BINARY") if @buf.respond_to?(:force_encoding)
          build_pipeline(@buf)
        end

        @nonblock_reader ||= reader(@nonblock_endpoint)

        @nonblock_reader.read_nonblock(len)

        @closed = @nonblock_reader.eof?

        @buf.slice!(0, @buf.size)
        # if it's a regular stream
        #   is len > the amount left in Content-Length?
        #     limit it to Content-Length
        #   call read_nonblock on the socket
        # elsif it's a chunked stream
        #   if in the middle of reading a chunk
        #     is len <= the amount left in the chunk?
        #       call read_nonblock on the socket
        #       append result to any existing buffer
        #       update bookkeeping
        #     otherwise
        #       call read_nonblock(remaining) on the socket
        #         store result in the buffer
        #         read_nonblock until \n
        #         continue the process until EWOULDBLOCK or len is reached or EOF
        #
        # NOTE: some bookkeeping of the state of the chunked encoding
        # parse will be required
      end

      def wait(timeout=60)
        return unless @nonblock_reader

        @nonblock_reader.wait(timeout)
      end

      alias entity body   #:nodoc: obsolete

      private

      def read_body_0(dest)
        reader(dest).read
      end

      def reader(dest)
        if chunked?
          ChunkedBodyReader.new(@socket, dest)
        else
          # TODO: Why do Range lengths raise EOF?
          clen = content_length || range_length || nil
          BodyReader.new(@socket, dest, clen)
        end
      end

      def stream_check
        raise IOError, 'attempt to read body out of block' if @socket.closed?
      end

      class DecompressionAdapter
        attr_reader :string

        def initialize(buffer)
          @buffer = buffer
          @string = ""
        end

        def <<(chunk)
          result = inflater.inflate(chunk)
          @string << result
          @buffer << result
        end

        def close
          inflater.close
        end
      end

      class GzipAdapter < DecompressionAdapter
        def inflater
          @inflater ||= Net2::GzipInflater.new
        end
      end

      class InflateAdapter < DecompressionAdapter
        def inflater
          @inflater ||= Zlib::Inflate.new
        end
      end

      class StringAdapter
        def initialize(buffer)
          @buffer = buffer
        end

        def <<(chunk)
          @buffer << chunk
        end

        def string
          @buffer
        end
      end

      def build_pipeline(dest, block = nil)
        if dest and block
          raise ArgumentError, 'both arg and block given for HTTP method' \
        end

        if block
          endpoint = ReadAdapter.new(block)
        else
          endpoint = StringAdapter.new(dest || '')
        end

        case self["Content-Encoding"]
        when "gzip"
          endpoint = GzipAdapter.new(endpoint)
        when "deflate"
          endpoint = InflateAdapter.new(endpoint)
        end

        endpoint
      end

    end
  end
end
