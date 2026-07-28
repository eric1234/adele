# ADR 0003

## Title

Separate contract, frontend, and backend packages

## Status

Accepted

## Context

A source plugin contains frontend and backend implementations that need to
share typed declarations and immutable value types without depending directly
on one another.

## Decision

Each source plugin is divided into three packages:

- A shared, pure-Dart contract package.
- A backend package that depends on the contract package.
- A frontend package that depends on the contract package.

The frontend and backend packages must not depend on one another. The contract
package must not depend on Flutter, the frontend package, the backend package,
or host implementation packages.

## Consequences

- Frontend and backend share one authoritative contract definition.
- Dependency direction is explicit.
- The contract package remains usable by both runtimes.
- Runtime transport and generated bindings remain separate concerns.
- Contract evolution and compatibility will require later design.
