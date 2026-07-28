# ADR 0005

## Title

Actions services and events have distinct semantics

## Status

Accepted

## Context

Plugin contracts need to describe one-shot requests, ongoing capabilities, and
notifications. Modeling all three as generic messages would obscure lifecycle,
direction, completion, and error behavior.

## Decision

Actions, services, and events are distinct contract concepts:

- An action is a brokered one-shot request/response operation.
- A service is a sustained typed capability.
- An event is a fact that has occurred.

## Consequences

Contracts can express intent and lifecycle more clearly, but tooling and APIs
must preserve these distinctions. Exact transport, dispatch, subscription, and
service-lifetime mechanisms remain future implementation work rather than
proven behavior.
