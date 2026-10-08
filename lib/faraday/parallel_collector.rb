# frozen_string_literal: true

module Faraday
  # Tracks the requests made inside Faraday::Connection#collect_results and
  # builds the ordered list of results: a finished Faraday::Response for
  # each successful request, a Faraday::ParallelFailure for each failed one.
  #
  # @api private
  class ParallelCollector
    # Tracks a single registered response.
    #
    # @api private
    class Slot
      attr_reader :response, :reason, :error

      def initialize(response)
        @response = response
        @reason = nil
        @error = nil
      end

      # A slot is pending while it has neither been finished nor failed.
      def pending?
        @reason.nil? && !@response.finished?
      end

      # Records a failure reason; the first failure recorded wins.
      def fail!(reason, error = nil)
        return unless @reason.nil?

        @reason = reason
        @error = error
      end

      def result
        if @reason
          return ParallelFailure.new(@reason, @error,
                                     @response.finished? ? @response : nil)
        end
        return @response if @response.finished?

        ParallelFailure.new(ParallelFailure::INCOMPLETE)
      end
    end

    def initialize
      @slots = []
      @construction_error = nil
    end

    # Drives the parallel manager through the batch and returns the ordered
    # results. Works with both manager interfaces: +execute+ (which runs the
    # requests block itself) and the deprecated +run+ (which is called after
    # the requests block). Requests registered before an error are always
    # executed; requests that never ran are never reported as transport
    # failures. If the manager itself fails, every request that is still
    # pending is closed with the same batch error.
    #
    # @param manager [Object, nil] the parallel manager, if any
    # @yield the block making the requests
    # @return [Array<Faraday::Response, Faraday::ParallelFailure>]
    def collect(manager, &block)
      unless manager
        guard_construction(&block)
        return results
      end

      batch_error = execute_batch(manager, &block)

      if batch_error
        reason = batch_error.is_a?(Faraday::Error) ? ParallelFailure::TRANSPORT : ParallelFailure::MANAGER
        fail_pending!(reason, batch_error)
      else
        fail_pending!(ParallelFailure::INCOMPLETE)
      end

      results
    end

    # Registers a response in submission order and guards it so that an
    # error raised while finishing it (response middleware or on_complete
    # callbacks) is recorded against this single request instead of
    # aborting the rest of the batch.
    #
    # @param response [Faraday::Response]
    # @return [Faraday::Response] the registered response
    def register(response)
      slot = Slot.new(response)
      guard_finish(response, slot)
      @slots << slot
      response
    end

    # Records an error raised while building/queueing a request, before it
    # could be accepted by the parallel manager.
    def record_construction_error(error)
      @construction_error = error if @construction_error.nil?
    end

    # Closes every request that is still pending with the given reason, so
    # no accepted request is left unfinished forever.
    def fail_pending!(reason, error = nil)
      @slots.each { |slot| slot.fail!(reason, error) if slot.pending? }
    end

    # @return [Array<Faraday::Response, Faraday::ParallelFailure>] one entry
    #   per request, in the order requests were registered.
    def results
      collected = @slots.map(&:result)
      if @construction_error
        collected << ParallelFailure.new(ParallelFailure::CONSTRUCTION,
                                         @construction_error)
      end
      collected
    end

    private

    # Runs the requests block and the manager, returning any error raised by
    # the manager itself (nil when the batch completed normally).
    def execute_batch(manager, &block)
      if manager.respond_to?(:execute)
        # Execute is the new method that is responsible for executing the block.
        manager.execute { guard_construction(&block) }
      else
        # TODO: Old behaviour, deprecate and remove in 3.0
        guard_construction(&block)
        manager.run
      end
      nil
    rescue StandardError => e
      e
    end

    # Yields the requests block, recording any error raised before a request
    # could be queued as a construction failure. Already-registered requests
    # are not affected and still get executed.
    def guard_construction
      yield
    rescue StandardError => e
      record_construction_error(e)
    end

    def guard_finish(response, slot)
      response.define_singleton_method(:finish) do |env|
        super(env)
      rescue StandardError => e
        slot.fail!(ParallelFailure::MIDDLEWARE, e)
      end
    end
  end
end
