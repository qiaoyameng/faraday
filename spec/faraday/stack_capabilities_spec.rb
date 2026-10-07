# frozen_string_literal: true

RSpec.describe Faraday::StackCapabilities do
  let(:adapter) { Faraday::Adapter::Test.new(nil) }

  it 'treats adapter capabilities as undeclared by default' do
    stack = described_class.new(adapter)

    expect(stack.status(:streaming)).to eq(Faraday::Capabilities::UNDECLARED)
    expect(stack.supported?(:streaming)).to be(false)
  end

  it 'uses an explicit adapter declaration' do
    adapter.supports_capability!(:streaming, false)

    expect(described_class.new(adapter).status(:streaming)).to eq(
      Faraday::Capabilities::UNSUPPORTED
    )
  end

  it 'uses middleware declarations for transformation capabilities' do
    middleware_class = Class.new(Faraday::Middleware) do
      supports_capability(:content_encoding)
    end
    middleware = middleware_class.new(adapter)

    expect(described_class.new(adapter, [middleware]).supported?(:content_encoding)).to be(true)
  end

  it 'lets an explicit middleware unsupported declaration remain explicit' do
    middleware_class = Class.new(Faraday::Middleware) do
      does_not_support_capability(:content_encoding)
    end

    expect(described_class.new(adapter, [middleware_class.new(adapter)]).status(:content_encoding))
      .to eq(Faraday::Capabilities::UNSUPPORTED)
  end

  it 'reports both unsupported and undeclared missing capabilities' do
    adapter.does_not_support_capability!(:streaming)
    request = Faraday::RequestOptions.new(
      required_capabilities: %i[streaming parallel]
    )

    expect { described_class.new(adapter).verify!(request) }
      .to raise_error(Faraday::MissingCapabilitiesError) do |error|
      expect(error.message).to include('unsupported: streaming_response')
      expect(error.message).to include('undeclared: parallel_execution')
      expect(error.message).not_to include('password')
    end
  end
end
