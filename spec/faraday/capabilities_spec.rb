# frozen_string_literal: true

RSpec.describe Faraday::Capabilities do
  describe '.canonical' do
    it 'normalizes common aliases to canonical capability names' do
      expect(described_class.canonical(:streaming))
        .to eq(described_class::STREAMING_RESPONSE)
      expect(described_class.canonical(:cancel))
        .to eq(described_class::CANCELLABLE_TRANSFER)
      expect(described_class.canonical(:parallel))
        .to eq(described_class::PARALLEL_EXECUTION)
    end
  end

  describe '.normalize' do
    it 'flattens arrays, sets, hashes, and duplicate aliases' do
      capabilities = described_class.normalize(
        :streaming,
        [[:on_data]],
        Set[:parallel],
        cancel: true
      )

      expect(capabilities).to eq([
                                   described_class::STREAMING_RESPONSE,
                                   described_class::PARALLEL_EXECUTION,
                                   described_class::CANCELLABLE_TRANSFER
                                 ])
    end
  end

  describe Faraday::Capabilities::Declaration do
    let(:adapter_class) do
      Class.new(Faraday::Adapter)
    end

    let(:middleware_class) do
      Class.new(Faraday::Middleware)
    end

    it 'supports adapter tri-state declarations' do
      adapter_class.does_not_support_capability(:parallel)

      expect(adapter_class.capability_status(:parallel)).to eq(
        Faraday::Capabilities::UNSUPPORTED
      )
      expect(adapter_class.supports_capability?(:parallel)).to be(false)

      adapter_class.supports_capability(:parallel)
      expect(adapter_class.capability_status(:parallel)).to eq(
        Faraday::Capabilities::SUPPORTED
      )

      adapter_class.undeclare_capability(:parallel)
      expect(adapter_class.capability_status(:parallel)).to eq(
        Faraday::Capabilities::UNDECLARED
      )
    end

    it 'keeps old adapters undeclared unless they explicitly declare a capability' do
      expect(adapter_class.capability_status(:streaming)).to eq(
        Faraday::Capabilities::UNDECLARED
      )
      expect(adapter_class.supports_capability?(:streaming)).to be(false)
    end

    it 'keeps the legacy parallel flag tri-state compatible' do
      expect(adapter_class.supports_parallel?).to be(false)
      expect(adapter_class.capability_status(:parallel)).to eq(
        Faraday::Capabilities::UNDECLARED
      )

      adapter_class.supports_parallel = true

      expect(adapter_class.supports_parallel?).to be(true)
      expect(adapter_class.capability_status(:parallel)).to eq(
        Faraday::Capabilities::SUPPORTED
      )
    end

    it 'lets middleware declare a transformation capability' do
      middleware_class.supports_capability(:content_encoding)

      expect(middleware_class.supports_capability?(:content_encoding)).to be(true)
    end

    it 'does not let middleware claim an adapter-only capability' do
      expect do
        middleware_class.supports_capability(:parallel)
      end.to raise_error(ArgumentError, /can only be provided by an adapter/)
    end
  end
end
