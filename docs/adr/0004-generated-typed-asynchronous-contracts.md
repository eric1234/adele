# ADR 0004

## Title

Generated typed asynchronous contracts

## Status

Proposed

## Context

Plugin communication crosses the frontend/backend boundary and cannot assume
in-process synchronous calls. Hand-maintained bindings may eventually duplicate
contract details and allow the two sides to diverge.

## Decision

Generated typed, asynchronous frontend and backend APIs from a shared plugin
contract definition remain proposed. Phase 0 does not validate the contract
definition shape, generated API shape, compatibility rules, or runtime
dispatch. Phase 1 will initially use a manually implemented proxy, dispatcher,
and codec. Evidence from that walking skeleton should inform future generation
design.

## Consequences

Generated bindings could eventually give callers and providers compile-time
guidance while preserving an asynchronous boundary. Code generation,
compatibility rules, streams, cancellation, and structured transport errors
remain future work.
