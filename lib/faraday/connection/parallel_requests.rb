# frozen_string_literal: true

module Faraday
  class Connection
    # Internal helpers for collecting terminal states from parallel requests.
    module ParallelRequests
      # Makes a set of parallel requests and returns the terminal state of each
      # registered request in submission order. Successful entries are
      # {Faraday::Response} objects, while failed entries are
      # {Faraday::Parallel::Failure} objects.
      #
      # Unlike {#in_parallel}, request construction and parallel manager
      # failures do not leave accepted requests unfinished. Unexecuted requests
      # are marked as construction failures, while pending requests that were
      # already accepted end with the batch failure.
      #
      # @param manager [Object] The parallel manager that this Connection's
      #                Adapter uses.
      #
      # @yield a block to execute multiple requests.
      # @return [Array<Faraday::Response, Faraday::Parallel::Failure>]
      def collect_results(manager = nil, &block)
        manager = select_parallel_manager(manager)
        collector = Parallel::ResultCollector.new
        @parallel_manager = manager

        begin
          if manager
            run_collected_parallel(manager, collector, &block)
          else
            run_collected_block(collector, &block)
            collector.finish
          end

          collector.results
        ensure
          @parallel_manager = nil
        end
      end

      def run_request(method, url, body, headers, &request_block)
        unless METHODS.include?(method)
          raise ArgumentError, "unknown http method: #{method}"
        end

        collector = Parallel.current_collector
        return super unless collector

        collector.around_request do |slot|
          response = super
          slot.attach(response)
          slot.value
        rescue StandardError => e
          collector.request_failed(slot, e)
          slot.value
        end
      end

      private

      def select_parallel_manager(manager)
        manager || default_parallel_manager do
          warn 'Warning: `in_parallel` called but no parallel-capable adapter ' \
               'on Faraday stack'
          warn caller[3, 10].join("\n")
          nil
        end
      end

      def run_collected_parallel(manager, collector, &block)
        execute = manager.respond_to?(:execute)

        begin
          if execute
            manager.execute { run_collected_block(collector, &block) }
          else
            run_collected_block(collector, &block)
            manager.run
          end
        rescue StandardError => e
          phase = collector.block_error ? :construction : :batch
          error = collector.block_error || e
          collector.fail_pending(Parallel::Failure.build(phase, error))
        end

        collector.finish
      end

      def run_collected_block(collector, &block)
        previous_collector = Parallel.activate(collector)
        begin
          collector.run_block(&block)
        ensure
          Parallel.deactivate(previous_collector)
        end
      end
    end
  end
end
