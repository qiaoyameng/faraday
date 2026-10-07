# frozen_string_literal: true

module Faraday
  # Capability names and tri-state support values used by adapters and
  # middleware to declare request features.
  module Capabilities
    SUPPORTED = :supported
    UNSUPPORTED = :unsupported
    UNDECLARED = :undeclared

    STREAMING_RESPONSE = :streaming_response
    CANCELLABLE_TRANSFER = :cancellable_transfer
    PARALLEL_EXECUTION = :parallel_execution

    ADAPTER_ONLY_CAPABILITIES = Set[
      STREAMING_RESPONSE,
      CANCELLABLE_TRANSFER,
      PARALLEL_EXECUTION
    ].freeze

    ALIASES = {
      stream: STREAMING_RESPONSE,
      streaming: STREAMING_RESPONSE,
      streaming_response: STREAMING_RESPONSE,
      streaming_responses: STREAMING_RESPONSE,
      response_streaming: STREAMING_RESPONSE,
      chunked_response: STREAMING_RESPONSE,
      response_chunk_callback: STREAMING_RESPONSE,
      on_data: STREAMING_RESPONSE,

      cancel: CANCELLABLE_TRANSFER,
      cancellation: CANCELLABLE_TRANSFER,
      cancellable: CANCELLABLE_TRANSFER,
      cancellable_transfer: CANCELLABLE_TRANSFER,
      cancelable: CANCELLABLE_TRANSFER,
      cancelable_transfer: CANCELLABLE_TRANSFER,
      abort: CANCELLABLE_TRANSFER,

      parallel: PARALLEL_EXECUTION,
      parallelism: PARALLEL_EXECUTION,
      parallel_request: PARALLEL_EXECUTION,
      parallel_requests: PARALLEL_EXECUTION,
      parallel_execution: PARALLEL_EXECUTION
    }.freeze

    class << self
      def canonical(name)
        value = name.to_s.downcase.to_sym
        ALIASES.fetch(value, value)
      end

      def normalize(*capabilities)
        values = []
        collect_capabilities(capabilities, values)
        values
          .map { |capability| canonical(capability) }
          .uniq
      end

      def collect_capabilities(values, output)
        values.each do |value|
          next if value.nil?

          case value
          when Hash
            collect_capabilities(value.keys, output)
          when Array, Set
            collect_capabilities(value.to_a, output)
          else
            output << value
          end
        end
      end

      def adapter_only?(capability)
        ADAPTER_ONLY_CAPABILITIES.include?(canonical(capability))
      end

      def state(value)
        case value
        when true, SUPPORTED
          SUPPORTED
        when false, UNSUPPORTED
          UNSUPPORTED
        when UNDECLARED, nil
          UNDECLARED
        else
          raise ArgumentError,
                "unknown capability state #{value.inspect}, expected true, false, " \
                ':supported, :unsupported, or :undeclared'
        end
      end

      def bump_declaration!
        @declaration_mutex ||= Mutex.new
        @declaration_mutex.synchronize { @declaration_version = declaration_version.next }
      end

      def declaration_version
        @declaration_version || 0
      end
    end

    # Class macros for explicitly declaring feature support.
    module Declaration
      # Class methods added by Capabilities::Declaration.
      module ClassMethods
        attr_reader :declaration_version

        # rubocop:disable Style/OptionalBooleanParameter
        def declare_capability(name, state = true)
          # rubocop:enable Style/OptionalBooleanParameter
          capability = Capabilities.canonical(name)
          reject_adapter_only_capability(capability)
          declared_capabilities[capability] = Capabilities.state(state)
          @declaration_version = Capabilities.bump_declaration!
          self
        end

        def supports_capability(name)
          declare_capability(name, true)
        end

        def supports_capabilities(*names)
          Capabilities.normalize(names).each { |name| supports_capability(name) }
          self
        end

        # rubocop:disable Naming/PredicatePrefix
        def does_not_support_capability(name)
          # rubocop:enable Naming/PredicatePrefix
          declare_capability(name, false)
        end

        def undeclare_capability(name)
          declared_capabilities.delete(Capabilities.canonical(name))
          @declaration_version = Capabilities.bump_declaration!
          self
        end

        alias capability declare_capability

        def declare_capabilities(*names)
          Capabilities.normalize(names).each { |name| declare_capability(name) }
          self
        end

        alias supports supports_capabilities
        alias does_not_support does_not_support_capability
        alias provides_capability supports_capability
        alias provides supports_capabilities

        def capability_status(name)
          declared_capabilities.fetch(Capabilities.canonical(name), Capabilities::UNDECLARED)
        end

        def supports_capability?(name)
          capability_status(name) == Capabilities::SUPPORTED
        end

        def supports_capabilities?(*names)
          Capabilities.normalize(names).all? { |name| supports_capability?(name) }
        end

        def declared_capabilities
          @declared_capabilities ||=
            if superclass.respond_to?(:declared_capabilities)
              superclass.declared_capabilities.dup
            else
              {}
            end
        end

        private

        def reject_adapter_only_capability(capability)
          return unless Capabilities.adapter_only?(capability)
          return if defined?(Faraday::Adapter) && self <= Faraday::Adapter

          raise ArgumentError,
                "#{capability} can only be provided by an adapter, not #{self}"
        end
      end

      # Instance methods added by Capabilities::Declaration.
      module InstanceMethods
        def capability_status(name)
          self.class.capability_status(name)
        end

        def supports_capability?(name)
          capability_status(name) == Capabilities::SUPPORTED
        end

        def supports_capabilities?(*names)
          Capabilities.normalize(names).all? { |name| supports_capability?(name) }
        end

        def declared_capabilities
          self.class.declared_capabilities
        end

        def capabilities_signature
          signature = [self.class, self.class.declaration_version]
          signature << options if defined?(@options) && instance_variable_defined?(:@options)
          signature
        end
      end

      def self.included(base)
        base.extend(ClassMethods)
        base.include(InstanceMethods)
      end
    end
  end
end
