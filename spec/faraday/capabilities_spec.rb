# frozen_string_literal: true

RSpec.describe Faraday::Capabilities do
  let(:stubs) do
    Faraday::Adapter::Test::Stubs.new do |stub|
      stub.get('/ok') { [200, { 'Content-Type' => 'text/plain' }, 'ok'] }
      stub.post('/echo') { |env| [200, {}, env.body] }
    end
  end

  def build_connection(capabilities: nil, &block)
    Faraday.new('http://example.test') do |builder|
      block&.call(builder)
      builder.adapter :test, stubs, capabilities: capabilities
    end
  end

  describe 'resolution states' do
    it 'resolves declared capabilities to supported or unsupported' do
      conn = build_connection(capabilities: { streaming: true, cancellable: false })
      resolution = conn.builder.capability_resolution
      expect(resolution[:streaming]).to eq(:supported)
      expect(resolution[:cancellable]).to eq(:unsupported)
    end

    it 'resolves anything not declared to undeclared' do
      conn = build_connection
      expect(conn.builder.capability_resolution[:streaming]).to eq(:undeclared)
    end

    it 'does not treat undeclared capabilities of legacy adapters as supported' do
      conn = build_connection
      expect do
        conn.get('/ok') { |req| req.require_capability(:streaming) }
      end.to raise_error(Faraday::CapabilityError, /streaming \(undeclared\)/)
    end

    it 'maps supports_parallel? adapters to a supported parallel capability' do
      parallel_adapter = Class.new(Faraday::Adapter) do
        self.supports_parallel = true

        def self.name
          'ParallelAdapter'
        end
      end
      conn = Faraday.new('http://example.test') { |b| b.adapter parallel_adapter }
      expect(conn.builder.capability_resolution[:parallel]).to eq(:supported)
    end
  end

  describe 'backwards compatibility' do
    it 'runs requests without requirements on adapters that declare nothing' do
      conn = build_connection
      expect(conn.get('/ok').body).to eq('ok')
    end

    it 'runs requests without requirements on adapters declaring unsupported' do
      conn = build_connection(capabilities: { streaming: false })
      expect(conn.get('/ok').body).to eq('ok')
    end
  end

  describe 'requirement enforcement' do
    it 'satisfies requirements declared as supported' do
      conn = build_connection(capabilities: { streaming: true })
      response = conn.get('/ok') { |req| req.require_capability(:streaming) }
      expect(response.status).to eq(200)
    end

    it 'rejects explicitly unsupported capabilities' do
      conn = build_connection(capabilities: { streaming: false })
      expect do
        conn.get('/ok') { |req| req.require_capability(:streaming) }
      end.to raise_error(Faraday::CapabilityError, /streaming \(unsupported\)/)
    end

    it 'lists every missing capability in the error' do
      conn = build_connection(capabilities: { streaming: true })
      error = nil
      begin
        conn.get('/ok') { |req| req.require_capability(:streaming, :cancellable, :parallel) }
      rescue Faraday::CapabilityError => e
        error = e
      end
      expect(error).not_to be_nil
      expect(error.missing_capabilities).to contain_exactly(:cancellable, :parallel)
      expect(error.message).to include('cancellable').and include('parallel')
      expect(error.message).not_to include('streaming (')
    end

    it 'supports setting required_capabilities directly' do
      conn = build_connection
      expect do
        conn.get('/ok') { |req| req.options.required_capabilities = %i[streaming] }
      end.to raise_error(Faraday::CapabilityError)
    end

    it 'does not leak proxy credentials in the error message' do
      conn = Faraday.new('http://example.test', proxy: 'http://user:s3cret@proxy.test:8080') do |builder|
        builder.adapter :test, stubs
      end
      error = nil
      begin
        conn.get('/ok') { |req| req.require_capability(:streaming) }
      rescue Faraday::CapabilityError => e
        error = e
      end
      expect(error).not_to be_nil
      expect(error.message).not_to include('s3cret')
      expect(error.inspect).not_to include('s3cret')
    end
  end

  describe 'rejection happens before any side-effecting work' do
    let(:counting_body) do
      Class.new do
        attr_reader :reads

        def initialize
          @reads = 0
        end

        def read(*)
          @reads += 1
          nil
        end

        def to_s
          'counting-body'
        end
      end.new
    end

    let(:counting_adapter_class) do
      Class.new(Faraday::Adapter::Test) do
        class << self
          attr_accessor :calls
        end
        self.calls = 0

        def call(env)
          self.class.calls += 1
          super
        end
      end
    end

    let(:counting_middleware_class) do
      Class.new(Faraday::Middleware) do
        class << self
          attr_accessor :requests, :completes
        end
        self.requests = 0
        self.completes = 0

        def on_request(_env)
          self.class.requests += 1
        end

        def on_complete(_env)
          self.class.completes += 1
        end
      end
    end

    it 'rejects before body.read, adapter.call and middleware callbacks' do
      conn = Faraday.new('http://example.test') do |builder|
        builder.use counting_middleware_class
        builder.adapter counting_adapter_class, stubs
      end

      expect do
        conn.post('/echo', counting_body) { |req| req.require_capability(:streaming) }
      end.to raise_error(Faraday::CapabilityError)

      expect(counting_body.reads).to eq(0)
      expect(counting_adapter_class.calls).to eq(0)
      expect(counting_middleware_class.requests).to eq(0)
      expect(counting_middleware_class.completes).to eq(0)
    end

    it 'runs the whole stack when requirements are satisfied' do
      conn = Faraday.new('http://example.test') do |builder|
        builder.use counting_middleware_class
        builder.adapter counting_adapter_class, stubs, capabilities: [:streaming]
      end

      conn.post('/echo', 'plain') { |req| req.require_capability(:streaming) }

      expect(counting_adapter_class.calls).to eq(1)
      expect(counting_middleware_class.requests).to eq(1)
      expect(counting_middleware_class.completes).to eq(1)
    end
  end

  describe 'middleware declarations' do
    it 'lets middleware provide transform capabilities' do
      transform = Class.new(Faraday::Middleware) do
        declares_capabilities body_compression: true
      end
      conn = Faraday.new('http://example.test') do |builder|
        builder.use transform
        builder.adapter :test, stubs
      end
      response = conn.get('/ok') { |req| req.require_capability(:body_compression) }
      expect(response.status).to eq(200)
    end

    it 'forbids middleware from claiming transport capabilities' do
      expect do
        Class.new(Faraday::Middleware) { declares_capabilities streaming: true }
      end.to raise_error(Faraday::InitializationError, /transport capabilities/)
    end

    it 'forbids middleware from claiming cancellable or parallel' do
      expect do
        Class.new(Faraday::Middleware) { declares_capabilities cancellable: true }
      end.to raise_error(Faraday::InitializationError)
      expect do
        Class.new(Faraday::Middleware) { declares_capabilities parallel: true }
      end.to raise_error(Faraday::InitializationError)
    end
  end

  describe 'adapter declarations' do
    it 'supports class-level declarations inherited by subclasses' do
      parent = Class.new(Faraday::Adapter) { declares_capabilities streaming: true }
      child = Class.new(parent)
      expect(child.declared_capabilities).to eq(streaming: :supported)
      expect(parent.declared_capabilities).to eq(streaming: :supported)
    end

    it 'merges repeated declarations' do
      adapter = Class.new(Faraday::Adapter) do
        declares_capabilities streaming: true
        declares_capabilities cancellable: false
      end
      expect(adapter.declared_capabilities).to eq(streaming: :supported, cancellable: :unsupported)
    end

    it 'rejects invalid declaration values' do
      expect do
        Class.new(Faraday::Adapter) { declares_capabilities streaming: 'maybe' }
      end.to raise_error(ArgumentError, /invalid capability declaration/)
    end
  end

  describe 'cache invalidation' do
    it 're-resolves when the adapter instance configuration changes' do
      conn = build_connection(capabilities: [:streaming])
      conn.get('/ok') { |req| req.require_capability(:streaming) }

      adapter_instance = conn.builder.app
      adapter_instance = adapter_instance.app while adapter_instance.respond_to?(:app) &&
                                                    !adapter_instance.is_a?(Faraday::Adapter)
      adapter_instance.capabilities = {}

      expect do
        conn.get('/ok') { |req| req.require_capability(:streaming) }
      end.to raise_error(Faraday::CapabilityError)

      adapter_instance.capabilities = [:streaming]
      expect(conn.get('/ok') { |req| req.require_capability(:streaming) }).to be_a(Faraday::Response)
    end

    it 're-resolves when the adapter is swapped after the stack was built' do
      conn = build_connection(capabilities: [:streaming])
      conn.get('/ok') { |req| req.require_capability(:streaming) }

      conn.adapter :test, stubs

      expect do
        conn.get('/ok') { |req| req.require_capability(:streaming) }
      end.to raise_error(Faraday::CapabilityError)
    end

    it 're-resolves when middleware declarations change after the stack was built' do
      transform = Class.new(Faraday::Middleware)
      conn = Faraday.new('http://example.test') do |builder|
        builder.use transform
        builder.adapter :test, stubs
      end

      expect do
        conn.get('/ok') { |req| req.require_capability(:body_compression) }
      end.to raise_error(Faraday::CapabilityError)

      transform.declares_capabilities body_compression: true
      expect(conn.get('/ok') { |req| req.require_capability(:body_compression) }).to be_a(Faraday::Response)
    end
  end

  describe Faraday::Adapter::Test do
    it 'accepts capabilities via constructor options' do
      conn = build_connection(capabilities: { streaming: true })
      expect(conn.builder.capability_resolution[:streaming]).to eq(:supported)
    end

    it 'accepts capabilities as a list of names' do
      conn = build_connection(capabilities: %i[streaming cancellable])
      resolution = conn.builder.capability_resolution
      expect(resolution[:streaming]).to eq(:supported)
      expect(resolution[:cancellable]).to eq(:supported)
    end

    it 'falls back to class-level declarations when not configured per instance' do
      conn = build_connection
      expect(conn.builder.capability_resolution[:streaming]).to eq(:undeclared)
    end
  end
end
