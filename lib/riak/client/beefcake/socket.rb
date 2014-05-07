require 'openssl'
require 'r509/cert/validator'
require 'riak/client/beefcake/messages'
require 'riak/errors/connection_error'

module Riak
  class Client
    class BeefcakeProtobuffsBackend
      # A factory class for making sockets, whether secure or not
      # @api private
      class BeefcakeSocket
        include Client::BeefcakeMessageCodes
        # Only create class methods, don't initialize
        class << self
          def new(host, port, options={})
            return start_tcp_socket(host, port) if options[:authentication].blank?
            return start_tls_socket(host, port, options[:authentication])
          end

          private
          def start_tcp_socket(host, port)
            TCPSocket.new(host, port).tap do |sock|
              sock.setsockopt(Socket::IPPROTO_TCP, Socket::TCP_NODELAY, true)
            end
          end

          def start_tls_socket(host, port, authentication)
            raise Riak::UserConfigurationError.new if authentication[:username]

            tcp = start_tcp_socket(host, port)
            TlsInitiator.new(tcp, host, authentication).tls_socket
          end
          
          # Wrap up the logic to turn a TCP socket into a TLS socket.
          # Depends on Beefcake, which should be relatively safe.
          class TlsInitiator
            BC = ::Riak::Client::BeefcakeProtobuffsBackend
            include Util::Translation

            # Create a TLS Initiator
            #
            # @param tcp_socket [TCPSocket] the {TCPSocket} to start TLS on
            # @param authentication [Hash] a hash of authentication details
            def initialize(tcp_socket, host, authentication)
              @sock = @tcp = tcp_socket
              @host = host
              @auth = authentication
            end

            # Return the SSLSocket that has a TLS session running. (TLS is a
            # better and safer SSL).
            #
            # @return [OpenSSL::SSL::SSLSocket]
            def tls_socket
              configure_context
              start_tls
              validate_session
              send_authentication
              validate_connection
              return @tls
            end

            private
            def riak_cert
              @riak_cert ||= R509::Cert.new cert: @tls.peer_cert
            end

            # Set up an SSL context with appropriate defaults for Riak TLS
            def configure_context
              @context = OpenSSL::SSL::SSLContext.new

              # Replace insecure defaults
              @context.ssl_version = @auth[:ssl_version] || :TLSv1_2_client
              @context.verify_mode = @auth[:verify_mode] || OpenSSL::SSL::VERIFY_PEER

              # Defer to defaults
              %w{ cert key client_ca ca_file ca_path timeout }.each do |k|
                @context.send(:"#{k}=", @auth[k.to_sym]) if @auth[k.to_sym]
              end
            end

            # Attempt to exchange the TCP socket for a TLS socket.
            def start_tls
              write_message :StartTls
              expect_message :StartTls
              # Swap the tls socket in for the tcp socket, so write_message and
              # read_message continue working
              @sock = @tls = OpenSSL::SSL::SSLSocket.new @tcp, @context
              @tls.connect
            end

            # Validate the TLS session
            def validate_session
              if @auth[:verify_hostname] &&
                  !OpenSSL::SSL::verify_certificate_identity(riak_cert.cert, @host)
                raise TlsError.new t("ssl.cert_host_mismatch")
              end

              unless riak_cert.valid?
                raise TlsError.new t("ssl.cert_not_valid")
              end

              validator = R509::Cert::Validator.new riak_cert

              unless validator.validate validator_options
                raise TlsError.new t("ssl.cert_revoked")
              end
            end

            def validator_options
              o = {
                ocsp: !!@auth[:ocsp],
                crl: !!@auth[:crl]
              }
              
              if @auth[:crl_file]
                o[:crl_file] = @auth[:crl_file]
                o[:crl] = true
              end

              return o
            end

            # Send an AuthReq with the authentication data. Rely on beefcake
            # discarding message parts it doesn't understand.
            def send_authentication
              req = BC::RpbAuthReq.new @auth
              write_message :AuthReq, req.encode
              expect_message :AuthResp
            end

            # Ping the Riak node and make sure it actually works.
            def validate_connection
              write_message :PingReq
              expect_message :PingResp
            end

            # Write a protocol buffers message to whatever the current
            # socket is.
            def write_message(code, message='')
              if code.is_a? Symbol
                code = BeefcakeMessageCodes.index code
              end

              header = [message.length+1, code].pack 'NC'
              @sock.write header + message
            end

            def read_message
              header = @sock.read 5
              raise TlsError.new(t('ssl.eof_during_init')) if header.nil?
              len, code = header.unpack 'NC'
              decode = BeefcakeMessageCodes[code]
              return decode, '' if len == 1
              
              message = @sock.read(len - 1)
              return decode, message
            end

            def expect_message(expected_code)
              if expected_code.is_a? Numeric
                expected_code = BeefcakeMessageCodes[code]
              end

              candidate_code, message = read_message
              return message if expected_code == candidate_code

              raise TlsError.new(t('ssl.unexpected_during_init',
                                   expected: expected_code.inspect,
                                   actual: candidate_code.inspect,
                                   body: message.inspect
                                   ))
              
            end
          end
        end
      end
    end
  end
end