# ADELE Product

`adele_product` defines the canonical immutable `Project`, `Task`, `Environment`,
and `Session` values. `Project` retains a typed source `Uri`; `Task` owns only
its Project relationship; and `Environment` owns its Task relationship, role,
generic `ProviderId`, and an opaque immutable provider-state snapshot.

`Session` is deliberately minimal: it contains only `id: SessionId`,
`taskId: TaskId`, and `strategyId: OrchestrationStrategyId`. It has no
strategy-owned state, Environment relationship, or parent Session relationship.

## Strategy Identity

Product owns the canonical `SessionId` and `OrchestrationStrategyId` types.
`OrchestrationStrategyId` is a stable semantic identity for a strategy, not the
generic `ExtensionId` used to register a contribution. Registration replacement
does not change the product identity. Like other product IDs, it has typed value
equality and rejects empty values and outer whitespace without normalization.

Product has no extension dependency. `adele_orchestration` reexports this same
strategy ID for convenience and resolves it against current extension metadata;
it does not define another identity type.

## Boundaries

This strategy-bound Session is an experimental, metadata-only seam, not a Chat
model or an execution contract. Product has no Chat or execution API and no
kernel import. Session lifecycle, Session-to-Environment authority, persistence,
provider behavior, filesystem access, and plugin-generation routing remain
outside this package.
