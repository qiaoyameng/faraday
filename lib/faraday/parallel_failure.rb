# frozen_string_literal: true

module Faraday
  # Represents the failure of a single request made inside
  # Faraday::Connection#collect_results.
  #
  # Each failure carries a +reason+ that identifies which stage failed:
  #
  # * +:construction+ - the request could not be built or queued
  #   (e.g. the block raised before the request was accepted).
  # * +:transport+ - the request was accepted but the parallel manager
  #   reported a transport-level error (a Faraday::Error such as
  #   Faraday::ConnectionFailed or Faraday::TimeoutError).
  # * +:middleware+ - a response middleware or an on_complete callback
  #   raised while the response was being finished.
  # * +:manager+ - the parallel manager itself failed; every request that
  #   was still pending is closed with the same batch error.
  # * +:incomplete+ - the parallel manager finished without error but
  #   never completed this request.
  class ParallelFailure
    CONSTRUCTION = :construction
    TRANSPORT = :transport
    MIDDLEWARE = :middleware
    MANAGER = :manager
    INCOMPLETE = :incomplete

    REASONS = [CONSTRUCTION, TRANSPORT, MIDDLEWARE, MANAGER, INCOMPLETE].freeze

    # @return [Symbol] one of REASONS, identifying the failed stage.
    attr_reader :reason

    # @return [Exception, nil] the error that caused the failure, if any.
    attr_reader :error

    # @return [Faraday::Response, nil] the response, when it was finished
    #   before the failure was recorded (e.g. middleware failures).
    attr_reader :response

    def initialize(reason, error = nil, response = nil)
      unless REASONS.include?(reason)
        raise ArgumentError, "unknown parallel failure reason: #{reason.inspect}"
      end

      @reason = reason
      @error = error
      @response = response
    end

    def success?
      false
    end

    def failure?
      true
    end

    def construction?
      reason == CONSTRUCTION
    end

    def transport?
      reason == TRANSPORT
    end

    def middleware?
      reason == MIDDLEWARE
    end
    alias callback? middleware?

    def manager?
      reason == MANAGER
    end
    alias batch? manager?

    def incomplete?
      reason == INCOMPLETE
    end

    def inspect
      "#<#{self.class} reason=#{reason.inspect} error=#{error.inspect}>"
    end
  end
end
