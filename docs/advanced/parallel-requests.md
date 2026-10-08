# Parallel Requests

Some adapters support running requests in parallel.
This can be achieved using the `#in_parallel` method on the connection object.

```ruby
# Install the Typhoeus adapter with `gem install faraday-typhoeus` first.
require 'faraday/typhoeus'

conn = Faraday.new('http://httpbingo.org') do |faraday|
  faraday.adapter :typhoeus
end

now = Time.now

conn.in_parallel do
  conn.get('/delay/3')
  conn.get('/delay/3')
end

# This should take about 3 seconds, not 6.
puts "Time taken: #{Time.now - now}"
```

## Collecting terminal states

Use `#collect_results` when one parallel request must not prevent callers from
inspecting the terminal state of the other accepted requests. The returned
array preserves request submission order: each entry is either a
`Faraday::Response` or a `Faraday::Parallel::Failure`.

```ruby
results = conn.collect_results do
  conn.get('/one')
  conn.get('/two')
  conn.get('/three')
end

results.each do |result|
  if result.is_a?(Faraday::Parallel::Failure)
    puts "#{result.phase}: #{result.wrapped_exception&.message}"
  else
    puts result.status
  end
end
```

Failures are classified by the phase in which they happened:

- `Faraday::Parallel::ConstructionFailure`: the request could not be built or
  queued, so it is not reported as a transport failure.
- `Faraday::Parallel::TransportFailure`: a response object was created, but
  the request could not be enqueued or transmitted.
- `Faraday::Parallel::OnCompleteFailure`: response middleware or an
  `on_complete` callback raised.
- `Faraday::Parallel::BatchFailure`: the parallel manager could not finish, so
  all pending requests end with the same batch reason.

Ordinary `#in_parallel` behavior is unchanged. Use `#collect_results` only when
callers should receive per-request failure objects instead of letting an
exception escape.

## A note on Async

You might have heard about [Async] and its native integration with Ruby 3.0.
The good news is that you can already use Async with Faraday (thanks to the [async-http-faraday] gem)
and this does not require the use of `#in_parallel` to run parallel requests.
Instead, you only need to wrap your Faraday code into an Async block:

```ruby
# Install the Async adapter with `gem install async-http-faraday` first.
require 'async/http/faraday'

conn = Faraday.new('http://httpbingo.org') do |faraday|
  faraday.adapter :async_http
end

now = Time.now

# NOTE: This is not limited to a single connection anymore!
# You can run parallel requests spanning multiple connections.
Async do
  Async { conn.get('/delay/3') }
  Async { conn.get('/delay/3') }
end

# This should take about 3 seconds, not 6.
puts "Time taken: #{Time.now - now}"

```

The big advantage of using Async is that you can now run parallel requests *spanning multiple connections*,
whereas the `#in_parallel` method only works for requests that are made through the same connection.

[Async]: https://github.com/socketry/async
[async-http-faraday]: https://github.com/socketry/async-http-faraday
