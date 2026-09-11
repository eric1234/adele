# ADELE Orchestration

`adele_orchestration` is an experimental, metadata-only public seam for
orchestration strategies. It is pure Dart and depends only on the public
`adele_product` and `adele_plugin_api` packages. Its API is not stable.

## Identity And Registration

`OrchestrationStrategyId` lives in `adele_product`, alongside the minimal
`Session` that retains it. This package reexports that exact type for convenience.
It is a stable semantic identity, distinct from the generic `ExtensionId` of a
registration. A replacement registration may retain both IDs, but it is still a
different exact binding even when its metadata is unchanged.

`OrchestrationStrategyContribution` is immutable metadata containing only a
required `strategyId`. Register it at the typed
`orchestrationStrategyContributions` extension point using `ExtensionRegistry`.
`OrchestrationStrategyResolver(registry).resolve(strategyId)` scans the current
contributions by semantic ID; it has no separate strategy registry or cache.

No match throws `OrchestrationStrategyUnavailable` with the requested strategy
ID. Multiple matches throw `AmbiguousOrchestrationStrategy` with that ID and an
immutable `extensionIds` list sorted lexicographically by registration ID for
deterministic diagnostics. Unrelated strategy IDs do not affect resolution.

The resolved value exposes its `strategyId` and exact public
`ExtensionBinding<OrchestrationStrategyContribution> binding`. Its `contribution`
getter reads `binding.value`, and `validateBinding()` calls `binding.validate()`.
Retiring the registration makes both operations throw the generic
`StaleExtensionBinding` without wrapping it. A fresh resolution is needed after
replacement; old bindings never silently retarget the new contribution.

## Boundaries

This is not a Chat model, execution API, or Session lifecycle implementation.
Contributions have no execution methods. There are no Chat, execution, kernel,
Flutter, app, or plugin-runtime imports. Scheduling, model/tool invocation,
authority, Environment selection, persistence, and strategy execution are outside
this experimental seam.
