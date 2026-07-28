# ADR 0010: Plugin identity differs from Dart package identity

## Status

Accepted

## Context

A plugin needs a stable identity in the host, while a Dart package name identifies a source and distribution unit. Treating these as the same would couple plugin records and configuration to packaging decisions.

## Decision

Plugin identity is distinct from Dart package identity. Package metadata identifies an implementation artifact; it does not define the plugin's identity.

## Consequences

Packaging can change without implicitly changing plugin identity, and a package name change does not constitute a plugin migration. Any association between a plugin and its Dart package must be explicit.
