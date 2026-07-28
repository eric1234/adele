# ADR 0012: Plugin-facing UI API is deferred

## Status

Deferred

## Context

A plugin-facing UI surface would require decisions about composition, navigation, theming, lifecycle, state ownership, and compatibility. Those decisions are not needed to define the current non-UI boundaries.

## Decision

No plugin-facing UI API is selected at this time. Its design and scope are deferred to a later decision.

## Consequences

Current contracts must not imply that plugins can contribute UI. Future UI support may add new boundaries without changing the distinction between plugin identity and package identity.
