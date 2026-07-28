# ADR 0009

## Title

Resource identity is URI-based

## Status

Accepted

## Context

Plugins need to refer to resources across contract and provider boundaries without assuming that every resource is a local file or an HTTP location.

## Decision

In Phase 0, resource identity is represented by a URI. Each URI scheme defines its resource semantics; a resource URI is an identifier and is not necessarily a directly dereferenceable URL or filesystem path.

## Consequences

Contracts gain a uniform identity form that can accommodate provider-specific and future resource kinds. ADELE must define supported schemes, ownership, normalization, equality, and resolution behavior; this decision does not claim those runtime mechanisms are already implemented.
