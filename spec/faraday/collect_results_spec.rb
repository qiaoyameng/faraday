# frozen_string_literal: true

# Fake adapter that queues envs into the parallel manager instead of
# performing requests synchronously.
class CollectResultsFakeAdapter < Faraday::Adapter
  def call(env)
    super
    if env.parallel?
      env.parallel_manager.queue(env)
    else
      save_response(env, 200, "sync #{env.url.path}")
    end
    env.response
  end
end

# Fake parallel manager using the old `run` interface. The completion
# behaviour (order, failures) is configurable through the constructor block.
class CollectResultsRunManager
  attr_reader :queued

  def initialize(&behaviour)
    @queued = []
    @behaviour = behaviour
  end

  def queue(env)
    @queued << env
  end

  def run
    instance_exec(@queued, &@behaviour) if @behaviour
  end

  def finish(env, status: 200, body: nil)
    env.status = status
    env.body = body || "response #{env.url.path}"
    env.response_headers = Faraday::Utils::Headers.new
    env.response.finish(env)
  end
end

# Fake parallel manager using the new `execute` interface.
class CollectResultsExecuteManager < CollectResultsRunManager
  def execute
    yield
    run
  end
end

RSpec.describe Faraday::Connection, '#collect_results' do
  let(:manager_class) { CollectResultsRunManager }
  let(:behaviour) { ->(queued) { queued.each { |env| finish(env) } } }
  let(:manager) { manager_class.new(&behaviour) }

  let(:conn) do
    Faraday.new('http://example.com') do |f|
      f.adapter CollectResultsFakeAdapter
    end
  end

  def get_all(*paths)
    conn.collect_results(manager) do
      paths.each { |path| conn.get(path) }
    end
  end

  it 'returns finished responses in registration order' do
    results = get_all('/first', '/second')

    expect(results).to all(be_a(Faraday::Response))
    expect(results.map(&:body)).to eq(['response /first', 'response /second'])
  end

  context 'when the manager completes requests out of order' do
    let(:behaviour) { ->(queued) { queued.reverse_each { |env| finish(env) } } }

    it 'keeps the results in submission order' do
      results = get_all('/first', '/second', '/third')

      expect(results.map(&:body)).to eq(
        ['response /first', 'response /second', 'response /third']
      )
    end
  end

  context 'with an execute-style manager' do
    let(:manager_class) { CollectResultsExecuteManager }

    it 'collects results the same way' do
      results = get_all('/first', '/second')

      expect(results.map(&:body)).to eq(['response /first', 'response /second'])
    end
  end

  context 'when a response middleware raises' do
    let(:conn) do
      Faraday.new('http://example.com') do |f|
        f.response :raise_error
        f.adapter CollectResultsFakeAdapter
      end
    end

    let(:behaviour) do
      lambda do |queued|
        queued.each do |env|
          finish(env, status: env.url.path == '/bad' ? 500 : 200)
        end
      end
    end

    it 'fails only that request and completes the others' do
      results = get_all('/ok', '/bad', '/after')

      expect(results[0]).to be_a(Faraday::Response)
      expect(results[0].body).to eq('response /ok')
      expect(results[1]).to be_a(Faraday::ParallelFailure)
      expect(results[1].reason).to eq(:middleware)
      expect(results[1]).to be_middleware
      expect(results[1].error).to be_a(Faraday::ServerError)
      expect(results[2]).to be_a(Faraday::Response)
      expect(results[2].body).to eq('response /after')
    end
  end

  context 'when an on_complete callback raises' do
    it 'records a middleware failure and completes the other requests' do
      results = conn.collect_results(manager) do
        conn.get('/ok')
        conn.get('/boom').on_complete { raise 'callback exploded' }
        conn.get('/after')
      end

      expect(results[0]).to be_a(Faraday::Response)
      expect(results[1]).to be_a(Faraday::ParallelFailure)
      expect(results[1]).to be_middleware
      expect(results[1].error.message).to eq('callback exploded')
      expect(results[2]).to be_a(Faraday::Response)
      expect(results[2].body).to eq('response /after')
    end
  end

  context 'when the manager reports a transport error' do
    let(:behaviour) do
      lambda do |queued|
        finish(queued.first)
        raise Faraday::ConnectionFailed, 'connection refused'
      end
    end

    it 'marks the remaining pending requests as transport failures' do
      results = get_all('/first', '/second', '/third')

      expect(results[0]).to be_a(Faraday::Response)
      expect(results[1]).to be_a(Faraday::ParallelFailure)
      expect(results[1]).to be_transport
      expect(results[1].error).to be_a(Faraday::ConnectionFailed)
      expect(results[2]).to be_a(Faraday::ParallelFailure)
      expect(results[2]).to be_transport
      expect(results[2].error).to equal(results[1].error)
    end
  end

  context 'when the parallel manager itself fails' do
    let(:behaviour) { ->(_queued) { raise 'manager exploded' } }

    it 'closes all pending requests with the same batch reason' do
      results = get_all('/first', '/second')

      expect(results).to all(be_a(Faraday::ParallelFailure))
      expect(results.map(&:reason)).to eq(%i[manager manager])
      expect(results.map { |result| result.error.message }).to eq(['manager exploded'] * 2)
      expect(results[0].error).to equal(results[1].error)
    end

    it 'cleans up the parallel manager' do
      get_all('/first')

      expect(conn.in_parallel?).to be_falsey
    end
  end

  context 'when the manager leaves a request unfinished' do
    let(:behaviour) { ->(queued) { finish(queued.first) } }

    it 'does not leave the request pending forever' do
      results = get_all('/first', '/second')

      expect(results[0]).to be_a(Faraday::Response)
      expect(results[1]).to be_a(Faraday::ParallelFailure)
      expect(results[1]).to be_incomplete
      expect(results[1]).not_to be_transport
    end
  end

  context 'when a request fails while being built' do
    let(:error) { ArgumentError.new('cannot build this') }

    let(:results) do
      conn.collect_results(manager) do
        conn.get('/first')
        raise error
      end
    end

    it 'still executes the already-registered requests' do
      expect(results[0]).to be_a(Faraday::Response)
      expect(results[0].body).to eq('response /first')
    end

    it 'appends a construction failure instead of a transport failure' do
      expect(results.size).to eq(2)
      expect(results[1]).to be_a(Faraday::ParallelFailure)
      expect(results[1]).to be_construction
      expect(results[1]).not_to be_transport
      expect(results[1].error).to equal(error)
    end

    it 'cleans up the parallel manager' do
      results

      expect(conn.in_parallel?).to be_falsey
    end

    context 'with an execute-style manager' do
      let(:manager_class) { CollectResultsExecuteManager }

      it 'still executes the already-registered requests' do
        expect(results[0]).to be_a(Faraday::Response)
        expect(results[0].body).to eq('response /first')
        expect(results[1]).to be_construction
      end
    end
  end

  it 'requires a block' do
    expect { conn.collect_results(manager) }.to raise_error(ArgumentError)
    expect(conn.in_parallel?).to be_falsey
  end

  it 'does not change the behaviour of #in_parallel' do
    response = nil
    conn.in_parallel(manager) do
      response = conn.get('/first')
      expect(response).not_to be_finished
    end

    expect(response).to be_finished
    expect(response.body).to eq('response /first')
    expect(conn.in_parallel?).to be_falsey
  end
end
