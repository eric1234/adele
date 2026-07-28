# ADR 0002

## Title

Split interpreted frontend and AOT backend

## Status

Proposed

## Context

Phase 0 needs plugin frontends to remain flexible while plugin backends may need predictable startup and execution characteristics. Treating both sides as one runtime would couple their deployment and execution constraints.

## Decision

Propose an interpreted plugin frontend and an ahead-of-time (AOT) compiled plugin backend. Phase 0 will validate the boundary and packaging model; no particular interpreter, process model, or loading mechanism is considered proven or implemented by this decision.

## Consequences

Frontend and backend code can be optimized for different constraints, but plugins must communicate across an explicit boundary. Contract compatibility, error propagation, lifecycle, debugging, and deployment require further design and validation.
