# ADR 0017: One plugin runtime may expose multiple configured capability instances

## Status

Accepted

## Context

An active plugin may represent several named targets of the same or different capabilities. Starting a separate plugin runtime for every target would conflate plugin execution with configuration and installation.

## Decision

The normal model is one plugin runtime per activation context. That runtime may expose multiple configured capability instances, including named providers, accounts, connections, clusters, endpoints, or devices.

Configured capability instances are not plugin installations. They are derived from the shared configuration and applicable profile overrides after activation. Temporary resources created during execution are runtime resources, not configured capability instances.

## Consequences

Installation records availability, activation determines whether the plugin runs in a context, effective configuration describes configured instances, and the runtime executes the active plugin and manages temporary resources. None of these distinctions requires one runtime per configured instance. Persistence and selection behavior for configured instances are deferred.
