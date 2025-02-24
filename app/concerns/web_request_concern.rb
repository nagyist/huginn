require 'faraday'

module WebRequestConcern
  module DoNotEncoder
    def self.encode(params)
      params.map do |key, value|
        value.nil? ? "#{key}" : "#{key}=#{value}"
      end.join('&')
    end

    def self.decode(val)
      [val]
    end
  end

  class CharacterEncoding < Faraday::Middleware
    def initialize(app, options = {})
      super(app)
      @force_encoding   = options[:force_encoding]
      @default_encoding = options[:default_encoding]
      @unzip            = options[:unzip]
    end

    def call(env)
      @app.call(env).on_complete do |env|
        body = env[:body]

        if @unzip == 'gzip'
          begin
            body.replace(ActiveSupport::Gzip.decompress(body))
          rescue Zlib::GzipFile::Error => e
            log e.message
          end
        end

        case
        when @force_encoding
          encoding = @force_encoding
        when body.encoding == Encoding::ASCII_8BIT
          # Not all Faraday adapters support automatic charset
          # detection, so we do that.
          case env[:response_headers][:content_type]
          when /;\s*charset\s*=\s*([^()<>@,;:\\"\/\[\]?={}\s]+)/i
            encoding = begin
              Encoding.find($1)
            rescue StandardError
              @default_encoding
            end
          when /\A\s*(?:text\/[^\s;]+|application\/(?:[^\s;]+\+)?(?:xml|json))\s*(?:;|\z)/i
            encoding = @default_encoding
          else
            # Never try to transcode a binary content
            next
          end
          # Return body as binary if default_encoding is nil
          next if encoding.nil?
        end
        body.encode!(Encoding::UTF_8, encoding, invalid: :replace, undef: :replace)
      end
    end
  end

  Faraday::Response.register_middleware character_encoding: CharacterEncoding

  extend ActiveSupport::Concern

  def validate_web_request_options!
    if options['user_agent'].present?
      errors.add(:base, "user_agent must be a string") unless options['user_agent'].is_a?(String)
    end

    if options['proxy'].present?
      errors.add(:base, "proxy must be a string") unless options['proxy'].is_a?(String)
    end

    if options['disable_ssl_verification'].present? && boolify(options['disable_ssl_verification']).nil?
      errors.add(:base, "if provided, disable_ssl_verification must be true or false")
    end

    unless headers(options['headers']).is_a?(Hash)
      errors.add(:base, "if provided, headers must be a hash")
    end

    begin
      basic_auth_credentials(options['basic_auth'])
    rescue ArgumentError => e
      errors.add(:base, e.message)
    end

    if (encoding = options['force_encoding']).present?
      case encoding
      when String
        begin
          Encoding.find(encoding)
        rescue ArgumentError
          errors.add(:base, "Unknown encoding: #{encoding.inspect}")
        end
      else
        errors.add(:base, "force_encoding must be a string")
      end
    end
  end

  # The default encoding for a text content with no `charset`
  # specified in the Content-Type header.  Override this and make it
  # return nil if you want to detect the encoding on your own.
  def default_encoding
    Encoding::UTF_8
  end

  def parse_body?
    false
  end

  def faraday
    faraday_options = {
      ssl: {
        verify: !boolify(options['disable_ssl_verification'])
      }
    }

    @faraday ||= Faraday.new(faraday_options) { |builder|
      if parse_body?
        builder.response :json
      end

      builder.response :character_encoding,
                       force_encoding: interpolated['force_encoding'].presence,
                       default_encoding:,
                       unzip: interpolated['unzip'].presence

      builder.headers = headers if headers.length > 0

      builder.headers[:user_agent] = user_agent

      builder.proxy = interpolated['proxy'].presence

      unless boolify(interpolated['disable_redirect_follow'])
        require 'faraday/follow_redirects'
        builder.response :follow_redirects
      end

      builder.request :multipart
      builder.request :url_encoded

      if boolify(interpolated['disable_url_encoding'])
        builder.options.params_encoder = DoNotEncoder
      end

      builder.options.timeout = (Delayed::Worker.max_run_time.seconds - 2).to_i

      if userinfo = basic_auth_credentials
        builder.request :authorization, :basic, *userinfo
      end

      builder.request :gzip

      case backend = faraday_backend
      when :typhoeus
        require "faraday/#{backend}"
        builder.adapter backend, accept_encoding: nil
      when :httpclient, :em_http
        require "faraday/#{backend}"
        builder.adapter backend
      end
    }
  end

  def headers(value = interpolated['headers'])
    value.presence || {}
  end

  def basic_auth_credentials(value = interpolated['basic_auth'])
    case value
    when nil, ''
      return nil
    when Array
      return value if value.size == 2
    when /:/
      return value.split(/:/, 2)
    end
    raise ArgumentError.new("bad value for basic_auth: #{value.inspect}")
  end

  def faraday_backend
    ENV.fetch('FARADAY_HTTP_BACKEND') {
      case interpolated['backend']
      in 'typhoeus' | 'net_http' | 'httpclient' | 'em_http' => backend
        backend
      else
        'typhoeus'
      end
    }.to_sym
  end

  def user_agent
    interpolated['user_agent'].presence || self.class.default_user_agent
  end

  module ClassMethods
    def default_user_agent
      ENV.fetch('DEFAULT_HTTP_USER_AGENT', "Huginn - https://github.com/huginn/huginn")
    end
  end
end
