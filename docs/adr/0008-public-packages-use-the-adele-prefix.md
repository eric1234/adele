# ADR 0008

## Title

Public packages use the adele_ prefix

## Status

Accepted

## Context

Phase 0 introduces multiple public packages for ADELE, including separate plugin contract frontend and backend packages. Their names need a consistent, discoverable namespace.

## Decision

Name every public ADELE package with the `adele_` prefix. The remainder of each package name describes its role using the package ecosystem's normal lowercase naming conventions.

## Consequences

ADELE packages are recognizable and less likely to collide with generic names. Package names are longer, and renaming a published package that violates the convention would require migration rather than an in-place identity change.
