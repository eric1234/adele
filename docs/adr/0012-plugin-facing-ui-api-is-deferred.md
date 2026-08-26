# ADR 0012: Plugin-facing UI API is deferred

## Status

Deferred

**ADR 0030 subsequently accepts the semantic direction for recursive plugin UI/extension composition, but it does not select a concrete plugin-facing UI API. This ADR therefore remains in force for API implementation.**

## Context

A plugin-facing UI surface requires decisions about composition, navigation,
theming, lifecycle, state ownership, compatibility, and the boundary between
host-rendered descriptors and plugin-rendered widgets. Those decisions were not
needed to define the initial non-UI runtime boundaries.

ADELE now has higher-level direction that plugin-facing UI extension points
should be semantic rather than tied to physical coordinates, that plugins may
define nested extension points inside their own surfaces, and that the host
retains broad workbench-shell composition. The exact API remains intentionally
unselected until concrete product UI work requires it.

## Decision

No concrete plugin-facing UI API is selected at this time. Its exact Dart
surface, registration mechanism, lifecycle, descriptor/widget split, and
compatibility model remain deferred to a later implementation decision.

Current generated contracts/capability APIs must not be treated as though they
already implement general UI contribution merely because the long-term
architecture permits it.

## Consequences

Future UI support may add new typed extension boundaries without changing the
distinction between plugin identity and package identity or requiring plugins to
claim fixed workbench coordinates.

Implementation should follow ADR 0030 and
`docs/architecture/plugin-extension-model.md` when the first concrete
plugin-facing UI vertical is designed, while still introducing only the minimum
API needed by that vertical.
