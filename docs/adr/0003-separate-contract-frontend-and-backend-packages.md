# ADR 0003

## Title

Separate contract frontend and backend packages

## Status

Accepted

## Context

A plugin contract has consumers on both sides of the frontend/backend boundary. A single package would expose dependencies and implementation concerns that are not appropriate to every consumer.

## Decision

In Phase 0, each public plugin contract is represented by separate contract frontend and contract backend packages. The frontend package exposes the caller-facing contract surface, while the backend package exposes the provider-facing contract surface.

## Consequences

Dependency direction and ownership are explicit, and consumers depend only on their side of a contract. Package publication and compatible versioning must be coordinated, and shared contract definitions must not drift between the two packages.
