# frozen_string_literal: true

module Faraday
  # Adds explicit required capability handling to RequestOptions.
  module RequiredCapabilitiesOption
    def each
      return super unless block_given?

      members.each do |key|
        value = key == :required_capabilities ? self[:required_capabilities] : send(key)
        yield(key.to_sym, value)
      end
    end

    def require_capabilities(*capabilities)
      write_required_capabilities(stored_required_capabilities + Capabilities.normalize(capabilities))
      required_capabilities
    end
    alias requires_capabilities require_capabilities
    alias require_capability require_capabilities
    alias requires_capability require_capabilities

    def keys
      keys = super
      keys.delete(:required_capabilities) if self[:required_capabilities].nil?
      keys
    end

    def to_hash
      hash = super
      hash.delete(:required_capabilities) if self[:required_capabilities].nil?
      hash
    end

    def to_h
      hash = super
      hash.delete(:required_capabilities) if self[:required_capabilities].nil?
      hash
    end

    def inspect
      values = []
      each do |member, value|
        values << "#{member}=#{value.inspect}" if value
      end
      values = values.empty? ? '(empty)' : values.join(', ')
      %(#<#{self.class} #{values}>)
    end

    private

    def stored_required_capabilities
      value = self[:required_capabilities]
      value ? Capabilities.normalize(value) : []
    end

    def write_required_capabilities(capabilities)
      normalized = Capabilities.normalize(capabilities)
      value = normalized.empty? ? nil : normalized
      Options.instance_method(:[]=).bind_call(self, :required_capabilities, value)
    end
  end
end
