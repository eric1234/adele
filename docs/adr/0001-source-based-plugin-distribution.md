# ADR 0001

## Title

Source-based plugin distribution

## Status

Proposed

Evidence note, 2026-07-28: local dependency resolution, backend AOT compilation,
and frontend EVC compilation from source were demonstrated with the Phase 1
validation toolchain. Source distribution remains proposed because the Flutter
same-process backend launch gate failed before the complete vertical path.

## Context

Phase 0 needs a plugin distribution model that supports rapid iteration without committing ADELE to a binary compatibility or artifact-signing design before the plugin architecture is validated.

## Decision

For Phase 0, propose distributing plugins as source. Packaging, dependency constraints, trust policy, and the exact build or loading workflow remain to be validated; this proposal does not assert that a runtime mechanism is implemented.

## Consequences

Plugin development and inspection can remain straightforward during Phase 0, and plugins can be built for the host environment. Installation may require a toolchain and reproducible dependency handling, and a later phase may adopt additional binary distribution formats.
