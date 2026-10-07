# frozen_string_literal: true

module Faraday
  # @!parse
  #   # RequestOptions contains the configurable properties for a Faraday request.
  #   #
  #   # @!attribute params_encoder
  #   #   @return [Object] the params encoder used to serialize the request params
  #   #
  #   # @!attribute proxy
  #   #   @return [ProxyOptions] proxy options for this request
  #   #
  #   # @!attribute bind
  #   #   @return [Hash] the local host and port to bind the connection to
  #   #
  #   # @!attribute timeout
  #   #   @return [Integer] time limit for the entire request (in seconds)
  #   #
  #   # @!attribute open_timeout
  #   #   @return [Integer] time limit for just the connection phase (in seconds)
  #   #
  #   # @!attribute read_timeout
  #   #   @return [Integer] time limit for the first response byte received from
  #   #           the server (in seconds)
  #   #
  #   # @!attribute write_timeout
  #   #   @return [Integer] time limit for the client to send the request to the
  #   #           server (in seconds)
  #   #
  #   # @!attribute boundary
  #   #   @return [String] the boundary used for multipart request bodies
  #   #
  #   # @!attribute oauth
  #   #   @return [Hash] OAuth options used by the OAuth middleware
  #   #
  #   # @!attribute context
  #   #   @return [Hash] free-form storage carried alongside the request
  #   #
  #   # @!attribute on_data
  #   #   @return [Proc] callback invoked with each chunk when streaming the response
  #   #
  #   # @!attribute required_capabilities
  #   #   @return [Array<Symbol>] capabilities explicitly required for this request
  #   class RequestOptions < Options
  #     include RequiredCapabilitiesOption
  #   end
  RequestOptions = Options.new(:params_encoder, :proxy, :bind,
                               :timeout, :open_timeout, :read_timeout,
                               :write_timeout, :boundary, :oauth,
                               :context, :on_data, :required_capabilities) do
    include RequiredCapabilitiesOption

    def []=(key, value)
      case key&.to_sym
      when :proxy
        super(key, value ? ProxyOptions.from(value) : nil)
      when :required_capabilities, :capabilities,
           :requires_capabilities, :requires_capability,
           :require_capabilities, :require_capability
        self.required_capabilities = value
      else
        super
      end
    end

    def stream_response?
      on_data.is_a?(Proc)
    end

    def required_capabilities
      value = self[:required_capabilities]
      value ? Capabilities.normalize(value) : []
    end
    alias_method :capabilities, :required_capabilities

    def required_capabilities=(value)
      write_required_capabilities(value)
    end
    alias_method :capabilities=, :required_capabilities=
  end
end
