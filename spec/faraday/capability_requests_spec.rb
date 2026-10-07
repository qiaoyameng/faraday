# frozen_string_literal: true

class CapabilityCountingBody
  attr_reader :read_count

  def initialize
    @read_count = 0
  end

  def read
    @read_count += 1
    'payload'
  end
end

class CapabilityCountingMiddleware < Faraday::Middleware
  @request_count = 0

  class << self
    attr_accessor :request_count
  end

  def on_request(_env)
    self.class.request_count += 1
  end
end
RSpec.describe 'request capability requirements' do
  let(:stub_calls) { { count: 0 } }

  let(:stubs) do
    calls = stub_calls
    Faraday::Adapter::Test::Stubs.new do |stub|
      stub.get('/') do
        calls[:count] += 1
        [200, {}, 'ok']
      end
      stub.get('/stream') do
        calls[:count] += 1
        [200, {}, 'abc']
      end
      stub.get('/parallel') do
        calls[:count] += 1
        [200, {}, 'parallel']
      end
      stub.get('/parallel') do
        calls[:count] += 1
        [200, {}, 'parallel']
      end
      stub.post('/') do
        calls[:count] += 1
        [200, {}, 'ok']
      end
    end
  end

  before { CapabilityCountingMiddleware.request_count = 0 }

  def connection(capabilities = nil, middleware: true)
    Faraday.new do |builder|
      builder.use(CapabilityCountingMiddleware) if middleware
      if capabilities
        builder.adapter(:test, stubs, capabilities: capabilities)
      else
        builder.adapter(:test, stubs)
      end
    end
  end

  it 'rejects undeclared capabilities before body, middleware, adapter, or stub work starts' do
    body = CapabilityCountingBody.new
    client = connection

    expect do
      client.post('/') do |request|
        request.body = body
        request.options.require_capabilities(:streaming)
      end
    end.to raise_error(
      Faraday::MissingCapabilitiesError,
      /undeclared: streaming_response/
    )

    expect(body.read_count).to eq(0)
    expect(CapabilityCountingMiddleware.request_count).to eq(0)
    expect(client.builder.adapter_instance.call_count).to eq(0)
    expect(stub_calls[:count]).to eq(0)
  end

  it 'lists explicitly unsupported capabilities separately from undeclared ones' do
    client = connection({ streaming: false, parallel: :undeclared })

    expect { connection_get(client, %i[streaming parallel]) }
      .to raise_error(Faraday::MissingCapabilitiesError) do |error|
      expect(error.message).to include('unsupported: streaming_response')
      expect(error.message).to include('undeclared: parallel_execution')
      expect(error.message).not_to include('secret-proxy-password')
    end
  end

  it 'does not inspect proxy credentials in the capability error' do
    client = Faraday.new(proxy: 'http://user:secret-proxy-password@proxy.example') do |builder|
      builder.adapter(:test, stubs)
    end

    expect { connection_get(client, :cancel) }
      .to raise_error(Faraday::MissingCapabilitiesError) do |error|
      expect(error.message).not_to include('secret-proxy-password')
      expect(error.message).not_to include('proxy.example')
    end
  end

  it 'keeps requests without explicit requirements compatible with undeclared adapters' do
    chunks = []
    response = connection.get('/stream') do |request|
      request.options.on_data = proc { |chunk, size| chunks << [chunk, size] }
    end

    expect(response.status).to eq(200)
    expect(chunks).to eq([['abc', 3]])
    expect(stub_calls[:count]).to eq(1)
  end

  it 'streams when the adapter explicitly declares streaming support' do
    chunks = []
    client = connection({ streaming: true })

    response = client.get('/stream') do |request|
      request.options.require_capabilities(:streaming)
      request.options.on_data = proc { |chunk, size| chunks << [chunk, size] }
    end

    expect(response.body).to eq(+'')
    expect(chunks).to eq([['abc', 3]])
    expect(client.builder.adapter_instance.call_count).to eq(1)
    expect(CapabilityCountingMiddleware.request_count).to eq(1)
  end

  it 'accepts middleware-provided transformation capabilities' do
    transformation = Class.new(Faraday::Middleware) do
      supports_capability(:compression)

      def call(env)
        app.call(env)
      end
    end
    client = connection(nil, middleware: false)
    client.builder.use(transformation)

    response = client.get('/') do |request|
      request.options.require_capabilities(:compression)
    end

    expect(response.status).to eq(200)
  end

  it 'invalidates cached capabilities when adapter configuration changes' do
    client = connection({ streaming: false })
    client.get('/')

    expect do
      connection_get(client, :streaming)
    end.to raise_error(Faraday::MissingCapabilitiesError)

    client.builder.adapter_instance.supports_capability!(:streaming, true)

    expect { connection_get(client, :streaming) }.not_to raise_error
  end

  it 'invalidates cached capabilities after switching adapters' do
    supported_stubs = Faraday::Adapter::Test::Stubs.new do |stub|
      stub.get('/') { [200, {}, 'switched'] }
    end
    client = connection({ streaming: false })
    client.get('/')

    client.builder.adapter(:test, supported_stubs, capabilities: { streaming: true })

    expect { connection_get(client, :streaming) }.not_to raise_error
  end

  it 'invalidates cached capabilities when a class declaration changes' do
    adapter_class = Class.new(Faraday::Adapter::Test)
    client = Faraday.new { |builder| builder.adapter(adapter_class, stubs) }
    client.get('/')

    expect do
      connection_get(client, :streaming)
    end.to raise_error(Faraday::MissingCapabilitiesError)

    adapter_class.supports_capability(:streaming)

    expect { connection_get(client, :streaming) }.not_to raise_error
  end

  it 'runs explicitly configured test adapter requests in parallel mode' do
    client = connection({ parallel: true })
    first = nil
    second = nil

    client.in_parallel do
      first = client.get('/parallel')
      second = client.get('/parallel')

      expect(first.body).to be_nil
      expect(second.body).to be_nil
      expect(client.in_parallel?).to be(true)
    end

    expect(client.in_parallel?).to be(false)
    expect(first.status).to eq(200)
    expect(second.status).to eq(200)
    expect(first.body).to eq('parallel')
    expect(second.body).to eq('parallel')
  end

  def connection_get(connection, capabilities)
    connection.get('/') do |request|
      request.options.require_capabilities(capabilities)
    end
  end
end
