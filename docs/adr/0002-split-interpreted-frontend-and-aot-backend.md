# ADR 0002

## Title

Split interpreted frontend and AOT backend

## Status

Accepted in principle; backend launch superseded by ADR 0019

## Context

Plugin frontends need to remain flexible while plugin backends may need
predictable startup and execution characteristics. Treating both sides as one
runtime would couple their deployment and execution constraints.

## Decision

Use an interpreted plugin frontend and an ahead-of-time compiled plugin backend.
Phase I proved persisted `dart_eval`/`flutter_eval` frontend execution and typed
asynchronous communication. Direct external AOT loading in stock Flutter
failed. ADR 0019 defines the proven shared process-hosted backend mechanism.

## Consequences

Frontend and backend code can be optimized for different constraints, but
plugins must communicate across an explicit boundary. Contract compatibility,
error propagation, lifecycle, debugging, and deployment require explicit
design. Linux x64 profile mode is proven; broader platform and packaging
validation remains outstanding.
