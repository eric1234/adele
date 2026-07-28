# ADR 0014: Repository contains one Flutter application

## Status

Accepted

## Context

The repository needs a clear application boundary while also containing reusable support code. Multiple Flutter applications would duplicate application-level setup and obscure which application is the product host.

## Decision

The repository contains one Flutter application. Other repository components are libraries, packages, tooling, or documentation rather than additional Flutter applications.

## Consequences

Application-level composition and platform configuration have one home. Adding another Flutter application requires revisiting this decision rather than treating an example or support package as a second application.
