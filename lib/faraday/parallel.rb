# frozen_string_literal: true

module Faraday
  # Utilities for collecting the terminal state of parallel requests.
  module Parallel
    FAILURE_PHASES = %i[construction transport on_complete batch].freeze

    @current_collector_key = :faraday_parallel_result_collector

    class << self
      # @api private
      def current_collector
        Thread.current[@current_collector_key]
      end

      # @api private
      def activate(collector)
        previous = current_collector
        Thread.current[@current_collector_key] = collector
        previous
      end

      # @api private
      def deactivate(previous)
        Thread.current[@current_collector_key] = previous
      end

      # @api private
      def track_response(response)
        current_collector&.track_response(response)
      end
    end

    # Value returned in a collected parallel result list when a request fails.
    class Failure < Faraday::Error
      # @return [Symbol] one of {FAILURE_PHASES}
      attr_reader :phase

      # @return [Faraday::Response, nil] the response associated with the
      #   failure, when one was constructed.
      attr_reader :failure_response

      def self.build(phase, error = nil, response = nil)
        klass =
          case phase
          when :construction then ConstructionFailure
          when :transport then TransportFailure
          when :on_complete then OnCompleteFailure
          when :batch then BatchFailure
          else
            raise ArgumentError, "unknown parallel failure phase: #{phase.inspect}"
          end

        klass.new(error, response)
      end

      def initialize(phase, error = nil, response = nil)
        raise ArgumentError, "unknown parallel failure phase: #{phase.inspect}" unless FAILURE_PHASES.include?(phase)

        @phase = phase
        @failure_response = response
        super(error || default_message, response)
      end

      def finished?
        true
      end

      def success?
        false
      end

      def failure?
        true
      end

      def status
        failure_response&.status
      end

      def body
        failure_response&.body
      end

      def headers
        failure_response&.headers || {}
      end

      private

      def default_message
        "parallel request failed during #{phase}"
      end
    end

    # Raised when a request cannot be built or enqueued.
    class ConstructionFailure < Failure
      def initialize(error = nil, response = nil)
        super(:construction, error, response)
      end
    end

    # Raised after a response object was created but the request could not be
    # enqueued or transmitted.
    class TransportFailure < Failure
      def initialize(error = nil, response = nil)
        super(:transport, error, response)
      end
    end

    # Raised when a response middleware or on_complete callback raises.
    class OnCompleteFailure < Failure
      def initialize(error = nil, response = nil)
        super(:on_complete, error, response)
      end
    end

    # Raised for requests left pending when a parallel batch cannot finish.
    class BatchFailure < Failure
      def initialize(error = nil, response = nil)
        super(:batch, error, response)
      end
    end

    # @api private
    class ResultSlot
      attr_reader :response

      def initialize
        @mutex = Mutex.new
        @response = nil
        @value = nil
      end

      def attach(new_response)
        @mutex.synchronize do
          return if @response

          @response = new_response
          new_response.track_parallel_result(self)
        end
      end

      def complete
        @mutex.synchronize do
          return if @value

          @value = @response
        end
      end

      def fail(error)
        @mutex.synchronize do
          return if @value

          @value = error
        end
      end

      def fail_request(error)
        @mutex.synchronize do
          return if @value

          phase = @response ? :transport : :construction
          @value = Failure.build(phase, error, @response)
        end
      end

      def complete_with_error(error)
        @mutex.synchronize do
          return if @value

          @value = Failure.build(:on_complete, error, @response)
        end
      end

      def resolved?
        @mutex.synchronize { !@value.nil? }
      end

      def value
        @mutex.synchronize { @value || @response }
      end

      def terminal_value
        @mutex.synchronize { @value }
      end
    end

    # @api private
    class ResultCollector
      attr_reader :block_error

      def initialize
        @mutex = Mutex.new
        @slots = []
        @request_slots = Hash.new { |hash, thread| hash[thread] = [] }
        @block_error = nil
      end

      def around_request
        slot = ResultSlot.new
        @mutex.synchronize { @slots << slot }
        @request_slots[Thread.current] << slot

        begin
          yield(slot)
        ensure
          @mutex.synchronize { @request_slots[Thread.current].pop }
        end
      end

      def track_response(response)
        @mutex.synchronize { @request_slots[Thread.current].last&.attach(response) }
      end

      def request_failed(slot, error)
        slot.fail_request(error)
      end

      def run_block(&block)
        yield
      rescue StandardError => e
        @block_error = e
      end

      def finish
        if @block_error
          failure = Failure.build(:construction, @block_error)
          @mutex.synchronize do
            @slots << ResultSlot.new.tap { |slot| slot.fail(failure) } if @slots.empty?
          end
          fail_pending(failure)
        else
          incomplete = Failure.build(
            :batch,
            RuntimeError.new('parallel manager returned before all requests completed')
          )
          fail_pending(incomplete)
        end
      end

      def fail_pending(error)
        @mutex.synchronize do
          @slots.each do |slot|
            slot.fail(error) unless slot.resolved?
          end
        end
      end

      def results
        @mutex.synchronize { @slots.map(&:terminal_value) }
      end
    end
  end
end
