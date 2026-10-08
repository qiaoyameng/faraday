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

## Collecting individual results

With `#in_parallel`, a single failed request can abort the whole batch and leave
the other responses unfinished. When you need to know the outcome of every
request, use `#collect_results` instead. It runs the same kind of block but
returns an Array with one entry per request, in the order the requests were
made. Each entry is either the finished `Faraday::Response` or a
`Faraday::ParallelFailure` describing what went wrong:

```ruby
results = conn.collect_results do
  conn.get('/delay/1')
  conn.get('/status/500')
  conn.get('/delay/1')
end

results.each do |result|
  if result.is_a?(Faraday::ParallelFailure)
    puts "failed at #{result.reason}: #{result.error}"
  else
    puts "got #{result.status}"
  end
end
```

`Faraday::ParallelFailure#reason` tells you which stage failed:

* `:construction` - the request could not be built or queued. Requests that
  were already registered are still executed, and requests that never ran are
  never reported as network failures.
* `:transport` - the request was sent but the transport failed
  (e.g. `Faraday::ConnectionFailed`, `Faraday::TimeoutError`).
* `:middleware` - a response middleware or an `on_complete` callback raised
  while the response was being finished. Only that request fails; the rest of
  the batch still completes.
* `:manager` - the parallel manager itself failed; every request that was
  still pending is closed with the same batch error.
* `:incomplete` - the manager finished without error but never completed the
  request.

`#collect_results` works with both parallel manager interfaces (`execute` and
the deprecated `run`) and always clears the connection's parallel manager when
the batch is over, even when errors are raised.

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
