# ADR 0004

## Title

Generated typed asynchronous contracts

## Status

Proposed

## Context

Plugin communication crosses the frontend/backend boundary and cannot assume in-process synchronous calls. Hand-maintained bindings would duplicate contract details and allow the two sides to diverge.

## Decision

Propose generating typed, asynchronous frontend and backend APIs from a shared plugin contract definition. Phase 0 will validate the contract definition, generated API shape, and compatibility rules; generation and runtime dispatch are not assumed to be implemented.

## Consequences

Callers and providers can receive compile-time guidance while preserving an asynchronous boundary. ADELE must maintain generation tooling, define evolution rules, and represent failures, cancellation, and event streams without leaking transport details.
