# ADR 0023: Generated server streaming and cancellation

## Status

Accepted for Phase II-B

## Context

Phase II-A implemented generated typed unary `Future<T>` transport. Phase IV-A
established a streaming-shaped kernel boundary over a temporary unary
scripted-model adapter. The deferred typed-contract work still required generic
server streaming before remaining Phase IV could use real provider streams.

## Decision

Service methods may return exact `dart:async` `Future<T>` for unary RPC or
`Stream<T>` for server-streaming RPC. The generator records an explicit method
kind; `T` remains in the existing transported-value closure. Outer aliases,
lookalikes, raw or nullable streams, `Stream<void>`, nested streams, and stream
parameters are rejected.

Generated clients expose lazy single-subscription Dart streams; a second listen
is rejected without opening another invocation. Items decode in transport order.
Existing declared failure metadata reconstructs typed failures during stream
creation or iteration. A malformed item raises `AdeleProtocolException`, cancels
the exact underlying subscription, and prevents later delivery or credit.
Secondary subscription-cleanup failures are contained so they cannot replace or
strand that primary failure, including synchronous emission during `listen()`.
All decoded-stream cancellation waiters join the same raw-subscription cleanup
operation, so cancellation cannot complete while producer cleanup is pending.

Generated dispatchers own stream iterators, credit accounting, item encoding,
terminal classification, cancellation, and idempotent shutdown. Entrypoints
supply command maps and a send callback without owning stream identifiers or
subscriptions.

Backend-host protocol version 2 extends the existing framed JSON and isolate
protocol with stream open, item, done, failure, credit, cancel, and cancellation
acknowledgement messages. Correlation identifiers remain runtime-local and are
removed exactly once. Unary framing remains intact.

Protocol v2 is an atomic runtime/backend-host artifact boundary. Startup rejects
a mismatched host before any plugin activation; deployments and rollbacks must
replace both artifacts together. Version 1 negotiation is not retained because
it cannot provide the required stream lifecycle semantics.

Flow control uses a fixed one-item window. Runtime state explicitly tracks the
single outstanding credit. Pause stops replacement credit; resume grants only a
withheld replacement and never duplicates an outstanding grant. Consumer
cancellation traverses runtime, host, plugin isolate, generated dispatcher, and
`StreamIterator.cancel()`, completing after the producer settles. At most one
granted item may advance during a race.
Errors reported by producer cancellation cleanup are contained as stream-local
lifecycle settlement and do not escape the generated dispatcher.

Generated dispatchers reserve stream-open state before asynchronous work, retain
early credit, and serialize unary requests and stream opening through one FIFO
ordinary-operation lane. Credit and cancellation commands bypass that lane, so
an already-open stream remains controllable while unary work is pending.
Cancellation of a queued open marks it immediately but acknowledges only after
the queued opening reaches admission and is skipped without invoking the backend
service.
Dispatchers track admitted ordinary and cancellation work, reject new work after
close begins, and share one cached close future among concurrent close callers.
Shutdown acknowledgement follows settlement of all admitted work.

When generated item encoding or type enforcement fails, the malformed item is
not emitted. The dispatcher sends one `backend_contract_violation`, cancels the
exact producer iterator, and includes that cancellation in close settlement.
Runtime `TypeError` checks at stream creation and item iteration are classified
the same way; unrelated undeclared producer exceptions remain `internal_error`.

If remote cancellation does not acknowledge within the bounded lifecycle
timeout, runtime retires the exact owning plugin generation through normal
stop/forced-isolate termination. Local correlation is not silently abandoned,
and a later replacement generation is not affected by stale timeout work.
If that exact generation is already stopping, cancellation joins the published
in-flight stop instead of treating active-map removal as settlement.
The producer-settlement timeout starts only after the shared host confirms that
it forwarded cancellation to the exact plugin stream; shared-host command queue
latency is not treated as producer failure.

Host lifecycle state distinguishes consumer cancellation, plugin-generation
shutdown, and host containment aborts. Only consumer cancellation produces a
silent `streamCancelled` completion. Generation shutdown fails old runtime
streams as connection disappearance; host aborts send a contained stream
failure exactly once, cancel the backend producer, and retain settlement state
independently. Any later valid backend terminal only settles that state. If the
producer does not settle within the bounded plugin lifecycle timeout, the host
retires that exact plugin generation while leaving unrelated generations alive.
Impossible cross-plugin stream correlation or item-without-credit frames emitted
by the shared backend host invalidate multiplexing trust and therefore fail all
host users while deterministically terminating and reaping that host process.
If protocol containment races an existing consumer cancellation, the consumer
origin remains authoritative: no synthetic containment terminal completes the
cancel early, and settlement still requires a real producer terminal or exact
generation retirement.

If a preferred stream terminal cannot be framed, the host sends a small
`response_too_large` or `response_encoding_failed` fallback. Failure to send
even that fallback retires the owning plugin generation rather than abandoning
runtime correlation.

Streams belong to the exact plugin/provider generation that opened them.
Disappearance terminates the stream; a replacement never inherits it. Tests
stop generation A with an active stream and start generation B with the same ID
inside the same shared host.
Lazy runtime streams revalidate the exact owning `PluginBackendConnection` by
identity at listen/open time, before allocating correlation or sending frames.

The scripted-model fixture retains its unary Phase IV-A method and application
adapter. It additionally exposes a generated stream and fixture-only probe for
AOT ordering, failure, backpressure, cancellation, and disappearance tests.

## Consequences

- Unary-only clients still require only `AdeleRequestChannel`; streaming clients
  require `AdeleStreamChannel`.
- Plugin authors and consumers do not manipulate stream IDs, credits, ports,
  frames, subscriptions, or cancellation messages.
- One stream has ordered items followed by exactly one terminal state.
- Oversized items fail only their stream; logical-value chunking is deferred.
- Unary `Future` cancellation is not introduced.
- Client/bidirectional streaming, reverse RPC, resumability, replay, durable
  stream identity, exactly-once delivery, and distributed recovery are deferred.
