# ADR 0007

## Title

Flutter desktop is the initial host

## Status

Accepted

## Context

Phase 0 needs one concrete host in which to validate plugin contracts and host integration. Supporting several host technologies or platform classes immediately would broaden the experiment before its boundaries are established.

## Decision

Use Flutter desktop as the initial ADELE host for Phase 0. This fixes the first validation target without committing ADELE to Flutter as the only future host or claiming that the plugin runtime is complete.

## Consequences

Phase 0 can focus its host integration and developer workflow. Early findings will reflect Flutter desktop constraints, and portability to other hosts or platform classes must be assessed separately.
