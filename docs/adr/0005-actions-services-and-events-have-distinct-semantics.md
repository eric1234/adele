# ADR 0005

## Title

Actions services and events have distinct semantics

## Status

Accepted

## Context

Plugin contracts need to describe one-shot requests, ongoing capabilities, and notifications. Modeling all three as generic messages would obscure lifecycle, direction, completion, and error behavior.

## Decision

Phase 0 treats actions, services, and events as distinct contract concepts. An action is a one-shot request with completion; a service is an addressable capability supporting ongoing interaction; an event is a provider-emitted notification observed by subscribers and is not a request.

## Consequences

Contracts can express intent and lifecycle more clearly, but tooling and APIs must preserve these distinctions. Exact transport, dispatch, subscription, and service-lifetime mechanisms remain Phase 0 implementation work rather than proven behavior.
