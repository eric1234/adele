# ADR 0018: Full profile behavior is deferred

## Status

Superseded by ADR 0029

## Context

Profiles are referenced as activation contexts and as scopes for optional configuration overrides. A complete profile design would also require decisions about creation, identity, switching, inheritance, persistence, selection, and lifecycle.

## Decision

Full profile behavior is deferred. Current decisions use profiles only to distinguish activation contexts and scope optional overrides; they do not define a complete profile model or user experience.

## Consequences

Installation remains independent of profile activation, shared configuration remains independent of overrides, and runtimes and configured capability instances remain scoped by resolved activation context where applicable. Future profile behavior requires a separate decision and must preserve these distinctions from temporary runtime resources.

ADR 0029 is that subsequent directional decision. This ADR remains as the historical record of why the earlier foundation intentionally avoided committing to full profile semantics.
