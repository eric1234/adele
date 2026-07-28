# ADR 0016: Shared configuration with optional profile overrides

## Status

Accepted

## Context

Plugin configuration often has values shared across activation contexts, while a profile may need a limited variation. Duplicating complete configuration per profile would obscure the common baseline and make divergence harder to understand.

## Decision

Configuration has a shared baseline with optional profile-specific overrides. An activation context resolves effective configuration from the shared values and its applicable overrides.

## Consequences

An absent override inherits the shared value, while an explicit override changes only its activation context. Shared configuration and overrides do not install or activate a plugin and are not runtime state. Detailed override representation, validation, and persistence remain separate decisions.
