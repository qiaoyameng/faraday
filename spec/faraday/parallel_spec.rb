# frozen_string_literal: true

class ParallelConstructionMiddleware < Faraday::Middleware
  def on_request(env)
    raise ArgumentError, 'construction failed' if env.url.path == '/construction-error'
  end
end

class ParallelCallbackMiddleware < Faraday::Middleware
  def on_complete(env)
    raise 'callback failed' if env.url.path == '/callback-error'
  end
end

class ParallelTestAdapter < Faraday::Adapter
  self.supports_parallel = true

  def call(env)
    super

    if env.url.path == '/transport-error'
      raise Faraday::ConnectionFailed, 'transport failed'
    end

    env.parallel_manager.enqueue(env)
    @app.call(env)
  end
end

class ParallelManagerError < StandardError; end

class FakeExecuteParallelManager
  attr_reader :enqueued, :completion_order

  def initialize(reverse: true, raise_after: nil)
    @enqueued = []
    @reverse = reverse
    @raise_after = raise_after
    @completion_order = []
  end

  def enqueue(env)
    @enqueued << env
  end

  def execute
    yield
    complete
  end

  private

  def complete
    envs = @reverse ? @enqueued.reverse : @enqueued

    envs.each_with_index do |env, index|
      raise ParallelManagerError, 'manager failed' if @raise_after && index == @raise_after

      finish(env)
    end
  end

  def finish(env)
    env.status = 200
    env.body = env.url.path
    env.response_headers = {}
    @completion_order << env.url.path
    env.response.finish(env)
  end
end

class FakeRunParallelManager < FakeExecuteParallelManager
  undef_method :execute

  def run
    complete
  end
end

RSpec.describe Faraday::Parallel, 'collect_results' do
  subject(:connection) do
    Faraday.new do |builder|
      builder.use ParallelConstructionMiddleware
      builder.use ParallelCallbackMiddleware
      builder.adapter ParallelTestAdapter
    end
  end

  shared_examples 'parallel result collection' do
    it 'returns completed responses in submission order after out-of-order completion' do
      first = second = third = nil
      results = connection.collect_results(manager) do
        first = connection.get('/one')
        second = connection.get('/two')
        third = connection.get('/three')
      end

      expect(manager.enqueued.map { |env| env.url.path }).to eq(%w[/one /two /three])
      expect(manager.completion_order).to eq(%w[/three /two /one])
      expect(results).to eq([first, second, third])
      expect(results.map(&:body)).to eq(%w[/one /two /three])
      expect(results).to all(be_finished)
      expect(results.grep(Faraday::Parallel::Failure)).to be_empty
    end

    it 'keeps enqueued responses terminal after a queueing/construction failure' do
      ok = construction_failure = after_failure = nil
      results = connection.collect_results(manager) do
        ok = connection.get('/one')
        construction_failure = connection.get('/construction-error')
        after_failure = connection.get('/two')
      end

      expect(results.map(&:class)).to eq([
                                           Faraday::Response,
                                           Faraday::Parallel::ConstructionFailure,
                                           Faraday::Response
                                         ])
      expect(results[0]).to equal(ok)
      expect(results[2]).to equal(after_failure)
      expect(construction_failure.phase).to eq(:construction)
      expect(construction_failure.failure_response).to be_nil
      expect(construction_failure.wrapped_exception).to be_a(ArgumentError)
      expect(ok).to be_finished
      expect(after_failure).to be_finished
      expect(connection).not_to be_in_parallel
    end

    it 'distinguishes a transport failure from a construction failure' do
      before_request = transport_failure = after_request = nil
      results = connection.collect_results(manager) do
        before_request = connection.get('/one')
        transport_failure = connection.get('/transport-error')
        after_request = connection.get('/two')
      end

      expect(results.map(&:class)).to eq([
                                           Faraday::Response,
                                           Faraday::Parallel::TransportFailure,
                                           Faraday::Response
                                         ])
      expect(transport_failure.phase).to eq(:transport)
      expect(transport_failure.failure_response).to be_a(Faraday::Response)
      expect(transport_failure.failure_response).not_to be_finished
      expect(transport_failure.wrapped_exception).to be_a(Faraday::ConnectionFailed)
      expect(before_request).to be_finished
      expect(after_request).to be_finished
    end

    it 'does not let one on_complete error stop other accepted responses' do
      successful_before = callback_failure = successful_after = nil
      results = connection.collect_results(manager) do
        successful_before = connection.get('/one')
        callback_failure = connection.get('/callback-error')
        successful_after = connection.get('/two')
      end

      expect(manager.completion_order).to eq(%w[/two /callback-error /one])
      expect(results.map(&:class)).to eq([
                                           Faraday::Response,
                                           Faraday::Parallel::OnCompleteFailure,
                                           Faraday::Response
                                         ])
      expect(results[0]).to equal(successful_before)
      expect(results[2]).to equal(successful_after)
      expect(results[1].phase).to eq(:on_complete)
      expect(results[1].status).to eq(200)
      expect(results[1].body).to eq('/callback-error')
      expect(results[1].wrapped_exception).to be_a(RuntimeError)
      expect(successful_before).to be_finished
      expect(successful_after).to be_finished
    end

    it 'ends every pending request with the same batch reason when manager fails' do
      failing_manager = manager_class.new(raise_after: 1)
      first = second = third = nil
      results = connection.collect_results(failing_manager) do
        first = connection.get('/one')
        second = connection.get('/two')
        third = connection.get('/three')
      end

      expect(results.map(&:class)).to eq([
                                           Faraday::Parallel::BatchFailure,
                                           Faraday::Parallel::BatchFailure,
                                           Faraday::Response
                                         ])
      expect(results[0]).to equal(results[1])
      expect(results[0].phase).to eq(:batch)
      expect(results[0].wrapped_exception).to be_a(ParallelManagerError)
      expect(results).to all(be_finished)
      expect(third).to be_finished
      expect(connection).not_to be_in_parallel
    end

    it 'cleans up and completes accepted requests when the batch block raises' do
      accepted = nil
      results = connection.collect_results(manager) do
        accepted = connection.get('/one')
        raise 'unexpected batch failure'
      end

      expect(results.map(&:class)).to eq([Faraday::Response])
      expect(results.first.body).to eq('/one')

      expect(accepted).to be_finished
      expect(connection).not_to be_in_parallel
    end

    it 'returns a construction failure when the block fails before registering a request' do
      results = connection.collect_results(manager) do
        raise 'batch failed before requests'
      end

      expect(results.map(&:class)).to eq([Faraday::Parallel::ConstructionFailure])
      expect(results.first.phase).to eq(:construction)
      expect(results.first.wrapped_exception.message).to eq('batch failed before requests')
      expect(connection).not_to be_in_parallel
    end
  end

  context 'with an execute manager' do
    let(:manager) { FakeExecuteParallelManager.new }
    let(:manager_class) { FakeExecuteParallelManager }

    it_behaves_like 'parallel result collection'
  end

  context 'with a run manager' do
    let(:manager) { FakeRunParallelManager.new }
    let(:manager_class) { FakeRunParallelManager }

    it_behaves_like 'parallel result collection'
  end

  it 'passes the original manager to the adapter' do
    manager = FakeExecuteParallelManager.new
    connection.collect_results(manager) do
      connection.get('/one')
    end

    expect(manager.enqueued.first.parallel_manager).to equal(manager)
  end

  it 'collects synchronous responses when no parallel manager is available' do
    synchronous_connection = Faraday.new do |builder|
      builder.adapter :test do |stubs|
        stubs.get('/one') { [200, {}, '/one'] }
      end
    end

    warning = capture_warnings do
      @synchronous_results = synchronous_connection.collect_results do
        synchronous_connection.get('/one')
      end
    end
    results = @synchronous_results

    expect(results.map(&:class)).to eq([Faraday::Response])
    expect(results.first.body).to eq('/one')
    expect(synchronous_connection).not_to be_in_parallel
    expect(warning).to include('no parallel-capable adapter')
  end

  it 'preserves ordinary in_parallel callback error behavior' do
    manager = FakeExecuteParallelManager.new

    expect do
      connection.in_parallel(manager) do
        connection.get('/callback-error')
      end
    end.to raise_error(RuntimeError, 'callback failed')

    expect(connection).not_to be_in_parallel
  end
end
