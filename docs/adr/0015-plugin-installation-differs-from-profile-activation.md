# ADR 0015: Plugin installation differs from profile activation

## Status

Accepted

## Context

Installation makes a plugin implementation available to the host. Activation determines whether that installed plugin participates in a particular profile's activation context. Conflating the two would prevent an installed plugin from remaining inactive or being activated differently by context.

## Decision

Plugin installation and profile activation are separate states. Installing a plugin does not activate it, deactivating it does not uninstall it, and activation does not create another installation.

## Consequences

One installation may be inactive in one activation context and active in another. Configuration and runtime state remain separate from both installation and activation. ADR 0029 subsequently defines the directional profile-composition and configuration model, including ordered sparse profile stacks and flat profiles; profile-management persistence, lifecycle, and other implementation mechanics remain deferred.
