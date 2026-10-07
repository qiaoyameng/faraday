# frozen_string_literal: true

module Faraday
  # Capability declaration protocol.
  #
  # Adapters and middleware can declare which optional capabilities they
  # provide (for example streaming response callbacks, cancellable
  # transfers, or parallel execution), and requests can explicitly require
  # capabilities via `RequestOptions#required_capabilities`. When a
  # requirement cannot be satisfied, the request is rejected with
  # {Faraday::CapabilityError} before the body is touched or any network
  # activity takes place.
  #
  # Every capability resolves to exactly one of three states:
  #
  # - `:supported`   - explicitly declared as provided.
  # - `:unsupported` - explicitly declared as not provided.
  # - `:undeclared`  - no declaration was made (the default for legacy
  #                    adapters/middleware). Undeclared never counts as
  #                    supported, but requests that make no requirements
  #                    remain fully compatible.
  module Capabilities
    SUPPORTED = :supported
    UNSUPPORTED = :unsupported
    UNDECLARED = :undeclared

    STATES = [SUPPORTED, UNSUPPORTED, UNDECLARED].freeze

    # Transport-level capabilities can only be truthfully provided by the
    # adapter that owns the socket. Middleware may declare transform
    # capabilities (anything not listed here) but can never claim these.
    TRANSPORT_CAPABILITIES = %i[streaming cancellable parallel].freeze

    # Normalizes a capability declaration into a Hash of
    # `{ name => :supported/:unsupported/:undeclared }`.
    #
    # Accepts a Hash (`{ streaming: true }`, `{ cancellable: :unsupported }`),
    # a single Symbol (`:streaming`) or a list of names (`[:streaming]`),
    # where bare names mean `:supported`.
    #
    # @param declarations [Hash, Symbol, Array, nil]
    # @return [Hash{Symbol => Symbol}]
    def self.normalize(declarations)
      case declarations
      when nil
        {}
      when Hash
        declarations.each_with_object({}) do |(name, value), hash|
          hash[name.to_sym] = normalize_state(name, value)
        end
      else
        Array(declarations).to_h { |name| [name.to_sym, SUPPORTED] }
      end
    end

    # @param name [Symbol] capability name (used for error messages)
    # @param value [Object] the declared value
    # @return [Symbol] one of STATES
    def self.normalize_state(name, value)
      case value
      when true, SUPPORTED then SUPPORTED
      when false, UNSUPPORTED then UNSUPPORTED
      when nil, UNDECLARED then UNDECLARED
      else
        raise ArgumentError,
              "invalid capability declaration for #{name.inspect}: #{value.inspect} " \
              "(expected true/false or one of #{STATES.map(&:inspect).join(', ')})"
      end
    end

    # Shared class-level declaration storage for adapters and middleware.
    # Declarations are inherited by subclasses and merged on re-declaration.
    module ClassMethods
      # Declares capabilities provided (or explicitly not provided) by this
      # class. Can be called multiple times; declarations are merged.
      #
      # @example
      #   declares_capabilities streaming: true, cancellable: false
      #
      # @param declarations [Hash, Symbol, Array]
      # @return [Hash] the full set of declared capabilities
      def declares_capabilities(declarations)
        normalized = Capabilities.normalize(declarations)
        forbidden = normalized.keys & Capabilities::TRANSPORT_CAPABILITIES
        unless transport_capability_declarations_allowed? || forbidden.empty?
          raise Faraday::InitializationError,
                "#{self} cannot declare transport capabilities " \
                "#{forbidden.map(&:inspect).join(', ')}: those can only be provided by an adapter"
        end

        @declared_capabilities = declared_capabilities.merge(normalized)
      end

      # @return [Hash{Symbol => Symbol}] declared capabilities, including
      #   declarations inherited from the superclass
      def declared_capabilities
        @declared_capabilities ||=
          if superclass.respond_to?(:declared_capabilities)
            superclass.declared_capabilities.dup
          else
            {}
          end
      end

      private

      # Middleware may not claim adapter-level (transport) capabilities.
      def transport_capability_declarations_allowed?
        false
      end
    end
  end
end
