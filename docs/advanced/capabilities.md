# Capability requirements

Some Faraday features depend on what the adapter (and middleware stack) can
actually do: streaming response callbacks, cancellable transfers, parallel
execution, and so on. When an adapter is swapped, options that the new
adapter does not support used to be silently ignored. The capability
declaration protocol makes this explicit.

## Requiring capabilities

A request can declare the capabilities it needs. The requirement is checked
**before** the request body is read, any middleware runs, or the network is
touched:

```ruby
conn.get('/stream') do |req|
  req.require_capability(:streaming)
  req.options.on_data = proc { |chunk, *| puts chunk }
end
```

If the current stack cannot satisfy every requirement, the request raises
`Faraday::CapabilityError` listing the missing capabilities and their state.
Requests that require nothing behave exactly as before.

Every capability resolves to one of three states:

| State          | Meaning                                                        |
|----------------|----------------------------------------------------------------|
| `:supported`   | explicitly declared as provided                                |
| `:unsupported` | explicitly declared as *not* provided                          |
| `:undeclared`  | no declaration (the default for legacy adapters and middleware)|

Only `:supported` satisfies a requirement — an undeclared capability is
never assumed to work.

## Declaring capabilities

Adapters own the transport, so they can declare any capability, including
the transport-level ones (`:streaming`, `:cancellable`, `:parallel`):

```ruby
class MyAdapter < Faraday::Adapter
  declares_capabilities streaming: true, cancellable: false
end
```

Adapters that set `supports_parallel = true` automatically resolve the
`:parallel` capability to `:supported`.

Middleware can declare the *transform* capabilities it provides, but it can
never claim transport capabilities — doing so raises
`Faraday::InitializationError`:

```ruby
class Compressor < Faraday::Middleware
  declares_capabilities body_compression: true
end
```

The resolution is computed once the stack is built and cached; the cache is
invalidated whenever the adapter, the handlers, or any capability-related
configuration changes.

## Testing

The test adapter accepts configurable capabilities, which makes it easy to
verify both acceptance and rejection paths:

```ruby
conn = Faraday.new('http://example.test') do |f|
  f.adapter :test, stubs, capabilities: { streaming: true }
end
```
