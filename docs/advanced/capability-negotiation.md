# Capability negotiation

Faraday options such as streaming callbacks, transfer cancellation, and parallel
execution depend on the selected adapter. Adapter gems can declare support
explicitly instead of letting the option be silently ignored.

## Required capabilities

Requests opt in with `request.required_capabilities`. Requests without
requirements keep their previous behavior.

```ruby
connection.get('/events') do |request|
  request.options.require_capabilities(:streaming_response)
  request.options.on_data = proc do |chunk, bytes_received, env|
    puts chunk
  end
end
```

Available built-in adapter capabilities are:

- `:streaming_response`
- `:cancellable_transfer`
- `:parallel_execution`

Common aliases such as `:streaming`, `:cancel`, and `:parallel` are normalized
to the canonical names above.

If a requested capability is unsupported or undeclared, Faraday raises
`Faraday::MissingCapabilitiesError` before request middleware runs, before the
request body is read, and before the adapter performs network work. The error
separates unsupported capabilities from undeclared ones and does not include
request configuration such as proxy credentials.

## Adapter declarations

Adapters use class-level declarations or instance overrides:

```ruby
class MyAdapter < Faraday::Adapter
  supports_capability :streaming_response
  does_not_support_capability :cancellable_transfer
end
```

Older adapters that do not declare a capability are treated as undeclared, not
as supported.

## Middleware declarations

Middleware may declare transformation capabilities that it provides itself:

```ruby
class CompressionMiddleware < Faraday::Middleware
  supports_capability :content_encoding
end
```

Middleware cannot claim adapter-only capabilities such as streaming, transfer
cancellation, or parallel execution.

## Test adapter

The test adapter accepts configurable capability overrides:

```ruby
stubs = Faraday::Adapter::Test::Stubs.new do |stub|
  stub.get('/events') { [200, {}, ['a', 'b']] }
end

connection = Faraday.new do |builder|
  builder.adapter :test, stubs, capabilities: {
    streaming_response: true,
    cancellable_transfer: false,
    parallel_execution: :undeclared
  }
end
```

The adapter also exposes `call_count` (aliased as `calls`) for acceptance
tests.
