# frozen_string_literal: true

require 'forwardable'

module Faraday
  # Response represents an HTTP response from making an HTTP request.
  class Response
    extend Forwardable
    extend MiddlewareRegistry

    def initialize(env = nil)
      @env = Env.from(env) if env
      @on_complete_callbacks = []
      @parallel_result_slot = nil
    end

    attr_reader :env, :parallel_error

    def status
      finished? ? env.status : nil
    end

    def reason_phrase
      finished? ? env.reason_phrase : nil
    end

    def headers
      finished? ? env.response_headers : {}
    end

    def_delegator :headers, :[]

    def body
      finished? ? env.body : nil
    end

    def url
      finished? ? env.url : nil
    end

    def finished?
      !!env
    end

    def on_complete(&block)
      if finished?
        yield(env)
      else
        @on_complete_callbacks << block
      end
      self
    end

    def finish(env)
      raise 'response already finished' if finished?

      @env = env.is_a?(Env) ? env : Env.from(env)
      callback_error = run_on_complete_callbacks(@parallel_result_slot)

      if @parallel_result_slot
        @parallel_error = callback_error
        if callback_error
          @parallel_result_slot.complete_with_error(callback_error)
        else
          @parallel_result_slot.complete
        end
      elsif callback_error
        raise callback_error
      end

      self
    end

    # @api private
    def track_parallel_result(slot)
      @parallel_result_slot = slot
    end

    def success?
      finished? && env.success?
    end

    def to_hash
      {
        status: status, body: body,
        response_headers: headers,
        url: url
      }
    end

    # because @on_complete_callbacks cannot be marshalled
    def marshal_dump
      finished? ? to_hash : nil
    end

    def marshal_load(env)
      @env = Env.from(env)
    end

    # Expand the env with more properties, without overriding existing ones.
    # Useful for applying request params after restoring a marshalled Response.
    def apply_request(request_env)
      raise "response didn't finish yet" unless finished?

      @env = Env.from(request_env).update(@env)
      self
    end

    private

    def run_on_complete_callbacks(continue_after_error)
      callback_error = nil

      @on_complete_callbacks.each do |callback|
        callback.call(@env)
      rescue StandardError => e
        callback_error ||= e
        raise callback_error unless continue_after_error
      end

      callback_error
    end
  end
end

require 'faraday/response/json'
require 'faraday/response/logger'
require 'faraday/response/raise_error'
