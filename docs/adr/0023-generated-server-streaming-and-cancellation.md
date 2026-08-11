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

Generated clients expose lazy single-subscription Dart streams. Items decode in
transport order. Existing declared failure metadata reconstructs typed failures
before or after items; malformed items raise `AdeleProtocolException` and cancel
the underlying stream.

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

Flow control uses a fixed one-item window. Pause stops credit replenishment;
resume grants the next credit. Consumer cancellation traverses runtime, host,
plugin isolate, generated dispatcher, and `StreamIterator.cancel()`, completing
after the producer settles. At most one granted item may advance during a race.

Streams belong to the exact plugin/provider generation that opened them.
Disappearance terminates the stream; a replacement never inherits it.

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
