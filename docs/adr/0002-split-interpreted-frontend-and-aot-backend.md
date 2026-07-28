# ADR 0002

## Title

Split interpreted frontend and AOT backend

## Status

Proposed

## Context

Plugin frontends need to remain flexible while plugin backends may need
predictable startup and execution characteristics. Treating both sides as one
runtime would couple their deployment and execution constraints.

## Decision

Propose an interpreted plugin frontend and an ahead-of-time (AOT) compiled
plugin backend. Phase 0 records this proposed architecture and its package
boundaries only. Phase 1 will attempt to validate the interpreted frontend, AOT
backend, runtime separation, loading mechanism, communication, and reload
behavior. No interpreter, launcher, isolate-group mechanism, process fallback,
or transport is currently proven.

## Consequences

Frontend and backend code can be optimized for different constraints, but
plugins must communicate across an explicit boundary. Contract compatibility,
error propagation, lifecycle, debugging, and deployment require further design
and validation.
