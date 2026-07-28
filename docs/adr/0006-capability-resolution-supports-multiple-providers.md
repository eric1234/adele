# ADR 0006

## Title

Capability resolution supports multiple providers

## Status

Accepted

## Context

Several plugins may handle the same action or service. Binding a capability permanently to one plugin would prevent alternatives, user choice, and context-sensitive selection.

## Decision

Phase 0 adopts a multiple-provider capability model. Callers can eventually query or enumerate compatible providers. When a caller does not choose one, ADELE resolves a preferred provider according to host and user policy; callers may explicitly select an alternative. Providers cannot globally declare themselves primary. The resolution API, preference policy, persistence, and runtime implementation are deferred.

## Consequences

The model supports competing and specialized plugins without granting a provider global precedence. ADELE will need deterministic resolution, clear provider identity, and useful selection UX, but this ADR does not imply that those mechanisms are already proven or implemented.
