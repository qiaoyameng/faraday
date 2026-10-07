# frozen_string_literal: true

module Faraday
  # Resolves capabilities provided by an adapter and the middleware around it.
  class StackCapabilities
    attr_reader :adapter, :middleware

    def initialize(adapter, middleware = [])
      @adapter = adapter
      @middleware = middleware
    end

    def status(name)
      capability = Capabilities.canonical(name)
      statuses =
        if Capabilities.adapter_only?(capability)
          [adapter_status(capability)]
        else
          middleware_statuses(capability) + [adapter_status(capability)]
        end

      if statuses.include?(Capabilities::SUPPORTED)
        Capabilities::SUPPORTED
      elsif statuses.include?(Capabilities::UNSUPPORTED)
        Capabilities::UNSUPPORTED
      else
        Capabilities::UNDECLARED
      end
    end

    def supported?(name)
      status(name) == Capabilities::SUPPORTED
    end

    def required_capabilities
      Capabilities::ADAPTER_ONLY_CAPABILITIES.to_a.select { |name| supported?(name) }
    end

    def missing_required(request)
      Capabilities
        .normalize(request.required_capabilities)
        .reject { |capability| supported?(capability) }
        .map { |capability| [capability, status(capability)] }
    end

    def verify!(request)
      missing = missing_required(request)
      return self if missing.empty?

      raise Faraday::MissingCapabilitiesError, build_message(missing)
    end

    def signature
      [
        Capabilities.declaration_version,
        signature_for(adapter),
        middleware.map { |app| signature_for(app) }
      ]
    end

    private

    def adapter_status(capability)
      adapter.capability_status(capability)
    end

    def middleware_statuses(capability)
      middleware.filter_map do |app|
        next unless app.respond_to?(:capability_status)

        app.capability_status(capability)
      end
    end

    def signature_for(object)
      object.respond_to?(:capabilities_signature) ? object.capabilities_signature : object.class
    end

    def build_message(missing)
      grouped = missing.group_by(&:last).transform_values { |values| values.map(&:first) }
      lines = ['Faraday stack does not satisfy required capabilities:']

      if grouped.fetch(Capabilities::UNSUPPORTED, []).any?
        lines << "  unsupported: #{grouped[Capabilities::UNSUPPORTED].join(', ')}"
      end

      if grouped.fetch(Capabilities::UNDECLARED, []).any?
        lines << "  undeclared: #{grouped[Capabilities::UNDECLARED].join(', ')}"
      end

      lines.join("\n")
    end
  end
end
