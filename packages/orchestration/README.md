# ADELE Orchestration

`adele_orchestration` is the experimental public provider-neutral registration,
binding, and execution boundary for orchestration strategies. It is pure Dart
and depends only on public `adele_product`, `adele_plugin_api`, and
`adele_model_tool`. Its API is not stable. Neither this package nor its stock
Chat consumer depends on `agent_kernel` or the application.

## Identity And Registration

`OrchestrationStrategyId` lives in `adele_product`, alongside the minimal
`Session` that retains it. This package reexports that exact type for convenience.
It is a stable semantic identity, distinct from the generic `ExtensionId` of a
registration. A replacement registration may retain both IDs, but it is still a
different exact binding even when its metadata is unchanged.

`OrchestrationStrategyContribution` contains a required `strategyId` and
`materialize` callback. Register it at the typed
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

## Materialization And Execution

`ResolvedOrchestrationStrategy.materialize(context)` invokes the retained
contribution with `OrchestrationStrategyHostContext(session, host)`. The context
contains the canonical product `Session` and an `OrchestrationExecutionHost`.
Materialization validates the exact binding and matching Session/host identities
before and after the callback. It returns one `OrchestrationExecution`, whose
`start()` and `resolveApproval(ToolApprovalResolution)` methods drive that Run's
strategy sequencing.

Materialization constructs an execution; it is not an execution entry point.
The application host keeps Run/model/tool operations disabled until it enters
the returned execution. Invalid caller starts/resolutions remain recoverable,
while invalid strategy operations escaping an active execution fail that Run
rather than leaving it running without a continuation.

The narrow host interface supplies:

| Operation | Boundary |
| --- | --- |
| `id`, `sessionId`, `state` | Execution identity and small lifecycle state, not the kernel Run object |
| `start()`, `complete()`, `fail(error)`, `validateBinding()` | Host-owned lifecycle and retained-strategy validation |
| `invokeModel(StrategyInferenceMaterial)` | Returns a `StrategyModelTurn` with ordered output, settlement/metadata or failure, and an opaque tool snapshot |
| `processProposal(tools: ..., proposal: ...)` | Processes a `ProviderToolProposal` against its exact `StrategyToolSnapshot`, including host policy and execution |
| `resolveApproval(resolution)` | Resolves the host-retained exact invocation and returns `SemanticToolOutcomeInput` for continuation |

The application host serializes execution operations and rejects overlapping
lifecycle changes, including `fail`, so active operations retain their terminal
evidence. Failure cleanup remains available after strategy retirement. Public
materialization validates the callback boundary; the application wrapper also
guards the returned execution's `start` and approval-resume entry points.

`StrategyToolContinuation` carries a semantic continuation item, including a
proposal failure or tool outcome. `StrategyToolWaiting` pauses strategy
sequencing for host-owned approval. Strategies do not receive a tool catalog,
executable objects, policy gate, or approval authority. The snapshot is an opaque
host-owned handle to one model invocation's materialization, not a mutable tool
collection or a means to select replacement generations.

The application host accepts only unused proposals issued by its own completed
model turn and tied to that exact snapshot. Approval resolution must be the exact
host-issued `ToolApprovalResolution` object forwarded during the current
`SessionOrchestrationRun.resolveApproval` call. Matching IDs or constructing an
equivalent value does not authorize a plugin-authored approval. The authorization
is consumed on resolution and cleared when the resume call ends. These checks
preserve host authority while Chat chooses proposal order and continuation timing.

Application composition in `app/lib/core/orchestration_host.dart` resolves a
canonical Session by `SessionId`, resolves its stored strategy exactly once per
Run, and materializes it against `KernelOrchestrationHost`.
`SessionOrchestrationRun` retains that execution and exact binding, exposing
internal Run/journal/tool evidence only to application callers. Host operations
validate the retained strategy on subsequent operations, approval resume, and
asynchronous settlement. A retired strategy cannot advance an old active Run;
that Run fails explicitly rather than migrating. A later Run in the same Session
may freshly resolve replacement B under the unchanged semantic strategy ID.

## Shared Semantic Values

The minimal model input/output, provider-native envelope, tool proposal/failure,
settlement, usage, and terminal-metadata DTOs live here. They are extracted from
the kernel and reused there as the same Dart types, not parallel public and
internal models. Existing public tool outcomes remain owned by
`adele_model_tool`; the minimal Run state and approval-resolution values are
also shared through this package.

`SemanticModelRequest`, model ports/events/streams/collectors, tool catalogs and
materializations, policy machinery, `AgentRun`, and the journal remain internal.
This public boundary returns collected semantic turns; it does not make the
kernel's streaming execution or observation implementation public.

## Inference Seam

`StrategyInferenceMaterial` carries instructions and an immutable ordered list of
`SemanticModelInputItem` values before host inference preparation. Stock Chat projects its own canonical
history and adds Run-local replay into this value. The host currently forwards
that material into internal `SemanticModelRequest`, supplying invocation
identity and materialized tools itself; model/tool/policy/Environment selection
remains host-owned.

General context composition is the next slice at this seam, not an implemented
framework. Context contributors, structured multi-plugin merge rules,
provenance, compaction, and token budgets are not supplied by this API.

## Boundaries

The first executable consumer is headless stock `chat_strategy_plugin` under
`plugins/chat_strategy`, registered as `dev.adele.strategy.chat` through the same
in-process activation conventions as stock tool plugins. Chat owns conversation
state and loop sequencing; this package owns neither Chat state nor Session
lifecycle/storage. No new public package is required for this boundary.
Chat's only direct production dependencies are `adele_orchestration` and
`adele_plugin_api`; `agent_kernel` is absent from both its production and
development dependencies.

There are no kernel, Flutter, app, or plugin-runtime imports. Scheduling,
production discovery, Chat UI, persistence, profiles, child Sessions, and general
context composition remain outside this implemented seam.
