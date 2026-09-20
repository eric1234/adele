# ADELE Orchestration

`adele_orchestration` is the experimental public provider-neutral registration,
binding, execution, live activity observation, and inference-context boundary for orchestration. It is pure
Dart and depends only on public `adele_contract`, `adele_product`, `adele_plugin_api`, and
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
before and after the callback settles. Contributions return
`FutureOr<OrchestrationExecution>` so local materializers may remain synchronous;
resolved materialization is awaited by the application. Retirement during that
await closes the newly constructed execution before surfacing the stale binding.
It returns one `OrchestrationExecution`, whose
`start()` and `resolveApproval(ToolApprovalResolution)` methods drive that Run's
strategy sequencing.

Idempotent async `OrchestrationExecution.close()` releases execution-owned
resources, not strategy-specific Session state. `SessionOrchestrationRun` owns
forwarding cleanup after active advancement drains, including terminal cleanup.
Closing a quiescent waiting execution does not resolve its approval, create a tool
outcome, or change Run evidence. This is not Run cancellation.

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

Proposal processing awaits the internal `ToolInvocationResolver.resolve`, including
`ToolExecutable.validateAndNormalize`'s `FutureOr<CanonicalToolArguments>` result.
Synchronous local validators and remote validators use the same path, with exact
binding checks around validation. Unknown alias, invalid arguments, stale binding,
and unavailable binding remain separate proposal failures; remote protocol failures
are not treated as invalid arguments. Remote tool transport belongs to
`adele_model_tool`, not this strategy facade.

Application composition in `app/lib/core/orchestration_host.dart` resolves a
canonical Session by `SessionId`, resolves its stored strategy exactly once per
Run, and materializes it against `KernelOrchestrationHost`.
`SessionOrchestrationRun` retains that execution and exact binding, exposing
internal Run/journal/tool evidence only to application callers. Host operations
validate the retained strategy on subsequent operations, approval resume, and
asynchronous settlement. A retired strategy cannot advance an old active Run;
that Run fails explicitly rather than migrating. A later Run in the same Session
may freshly resolve replacement B under the unchanged semantic strategy ID.

### Remote Strategies

`remote_orchestration.dart` declares data-only generated transport, separate from
the native strategy facade. `RemoteOrchestrationService` provides unary
`materialize`, `start`, `resolveApproval`, and `release`. Materialization receives
only the implementation route and immutable Session/Task/strategy/Run identities,
never an invocation token or host execution authority. It returns an opaque
backend execution route; actual strategy configuration is captured then, not
deferred until start.

The app's `RemoteOrchestrationStrategyAdapter` registers an exact-generation
contribution in `orchestrationStrategyContributions`. Readiness requires exactly
nonblank `strategyId` and `routeId` metadata and the supported generated service.
The existing resolver still owns unavailable/one/ambiguous results, without
priority or fallback. Plugin identity is connection-owned; readiness includes no
Session, Run, Environment, or provider selectors.

`remote_orchestration_backend.dart` supplies `RemoteOrchestrationBackend`, a
reusable adapter for native contributions. Its host proxy mirrors the current
operation's lifecycle synchronously, flushing transitions through unary host calls
before model/tool work and before returning from an advance. It reconstructs
semantic model inputs/outputs, native metadata and safe presentation, settlements,
usage, and tool results without provider interpretation. Bounded
`RemoteOrchestrationFailure` data represents strategy-requested failure and
already-collected model-turn failures, including partial model output. A failure
of the orchestration RPC itself remains infrastructure failure, not an intentional
Run failure; no arbitrary Dart causes cross the boundary.
The support library remains in this pure-Dart public package; generic
`adele_plugin_backend_support` has no orchestration dependency.

Each start/resume creates a fresh `PluginHostInvocation` allowlisting only
`RemoteOrchestrationHostService`: lifecycle transition, collected model invocation,
proposal processing, and no-argument `applyCurrentApproval`. Settlement or
retirement revokes it. No model-provider, Environment, policy, tool executable,
catalog, kernel Run, or journal authority is given to the backend.

The app retains each exact host tool snapshot and original proposal occurrence in
private execution-scoped tables. Opaque snapshot/proposal handles may survive an
approval pause as data identity, but cannot make calls without a fresh authorized
invocation. Tables never resolve another execution or replacement generation;
fabricated, foreign, and consumed handles fail. The backend proxy separately maps
reconstructed proposals by object identity, not alias/call ID/structural equality.
Strategies still choose proposal order; the host never drains a batch for them.

On resume, the app captures the real host-issued approval for that operation.
The backend proxy accepts only the exact reconstructed object supplied to its
current resume, then calls `applyCurrentApproval()` without fields. The host
applies its captured real resolution exactly once. Authorization disappears on
settlement, unlike retained snapshot data; a backend cannot approve during start,
substitute approval for rejection, or reuse authorization in another operation.

Explicit close, terminal settlement, retirement, and connection shutdown release
execution resources. Cleanup is authority-free and best-effort after failure;
it cannot replace primary failure evidence or retarget a replacement generation.
Installed `chat_strategy_backend` uses this boundary with a retained backend-owned
`ChatSessionStore`. Its plugin-internal Session service and strategy share that
store; the service is defined in Chat's contract, not in orchestration. Prepared
Session hosting can pin a Run to the exact resolved strategy from the same backend
connection used by its frontend, without exposing generation identities to plugins.

## Shared Semantic Values

The minimal model input/output, provider-native envelope, tool proposal/failure,
settlement, usage, and terminal-metadata DTOs live here. They are extracted from
the kernel and reused there as the same Dart types, not parallel public and
internal models. Existing public tool outcomes remain owned by
`adele_model_tool`; the minimal Run state and approval-resolution values are
also shared through this package.

`lib/src/model.dart` owns immutable
`ModelNativePresentation(kind, compactText, data)`, with recursively copied,
validated JSON-like safe data, and optional `ModelNativeOutput.presentation`.
The generic app capability adapter maps the generated
`adele_model_provider.ModelProviderNativePresentation` fields without provider
interpretation. Transport `ModelProviderOutput.nativePresentation` is required
nullable: `null` means semantic absence, while its generated key remains required.
This package needs no dependency on the transport DTO or Flutter to own its
semantic value. Raw native metadata remains exact and the only native replay
source; safe presentation is never copied into semantic replay input.

`SemanticModelRequest`, model ports/events/streams/collectors, tool catalogs and
materializations, policy machinery, `AgentRun`, and the journal remain internal.
This public boundary returns collected semantic turns; it does not make the
kernel's streaming execution or observation implementation public.

## Live Run Activity

`RunActivitySource` supplies `RunActivitySnapshot get snapshot` and
`Stream<void> get changes`. A snapshot contains ordered `ModelInvocationActivity`,
`ModelOutputActivity`, `ToolInvocationActivity`, `ToolActivityChange`,
`RunLifecycleActivity`, and `RejectedToolProposalActivity` values.
`ToolOutcomeActivity` and `ActivityFailure` are data-only outcome/failure
projections. `ModelInvocationId` is shared here with the kernel alongside the
existing Run/tool identities; output and change sequences are Run-local occurrence
identities, never list indices or globally persistent IDs.

The public activity boundary is deliberately separate from execution. A read-only
source supplies an initial immutable snapshot and change notifications; it has no
start, resume, approval, cancellation, or tool methods. The application host
projects the internal Run journal into these values without exposing the journal
or retaining executable objects in snapshots. Cancelling a subscription only
detaches observation. Terminal evidence remains readable after completion/failure.

The read model retains exact model invocation identity, ordered output occurrence
identity, and resolved tool invocation identity across lifecycle changes. Model
text, tool proposals, and provider-native outputs keep their distinct public
types and exact output order. Native envelopes and terminal metadata remain
opaque, without generic reasoning interpretation. Tools retain explicit proposal
provenance, canonical arguments, known effect/policy/approval state, progress, and
data-only outcomes including structured immutable `hostData`; arbitrary exception
objects, host diagnostics, bindings, and callable authority are not projected.

Chat's compact grouping is a consumer rule, not a core invariant: one successfully
completed model invocation with tools or `output.presentation != null` yields one
group, independently of rich frontend activation. Chat needs no negative projection
cache or registry-change retry machinery. Headings prefer explicit tool-batch
narration only when tools are present, then safe compact text,
then a structural tool count, with no extra inference. Reasoning-only groups
precede canonical final Chat text. Activity is not canonical Chat history
and is not persisted. Completed activity retained by a current presentation cannot
be reconstructed after reopening until persistence exists. Chat groups can open
window-owned Inspection, where public Flutter `adele_ui` selects read-only
presentations by exact `ToolId` or safe presentation kind, interleaved by
`output.sequence`. Zero native presenters leave rich Inspection unavailable, not
safe activity absent; one supplies a retained binding and many are explicitly
ambiguous without priority. Filesystem and Command own tool cards; OpenAI Backend
owns raw classification and safe reasoning-summary projection, Contract owns only
identities/schema, and Frontend renders safe Inspection. Generic Chat and the
OpenAI frontend escape compact and full display controls respectively. This package
remains Flutter-free and owns neither selection nor provider/tool interpretation:
native envelopes stay
opaque here, with exact native/encrypted replay unchanged. See
[model-native activity presentation](../../docs/architecture/overview.md#model-native-activity-presentation).
Reasoning deltas and nested navigation remain deferred.

## Inference Context

`StrategyInferenceMaterial` carries instructions and an immutable ordered list of
`SemanticModelInputItem` values before host inference preparation. Stock Chat
projects its own canonical history and adds Run-local replay into this value.
`InferenceContextComposer(registry).compose(strategyMaterial: ...,
sourceContext: ...)` discovers current instruction sources over the **same existing
`ExtensionRegistry`**, not a second registry or source runtime. The host composes
before allocating model invocation identity, materializing tools, recording
model-start evidence, or calling the provider. It then constructs internal
`SemanticModelRequest(context: snapshot, invocationId: ..., tools: ...)`.
Model/tool/policy/Environment selection remains with its existing owners.

### Source Contract

Register final `InferenceContextSourceContribution` at `inferenceContextSources`,
the typed point with ID `dev.adele.extension.inference-context-sources`. Each
contribution requires explicit `failureMode` (`InferenceContextFailureMode.required`
or `.optional`) and a `snapshot` callback returning
`Future<Iterable<InferenceContextMaterial>>`.

`InferenceContextSourceContext` exposes canonical product `Session`, `RunId runId`,
and `Future<T> requireHostService<T extends Object>()`. The app's fresh-per-inference
`SessionInferenceContextSourceContext` accepts only the published canonical Session
and explicitly allowlists only `AuthorizedEnvironmentFileReadFacet`, resolving
that service through the existing `SessionModelToolHostContext`. Other service
types, including mutation/process facets and broader Environment authority or
filesystem interfaces, are rejected. Context capture inspects state; mutation and
process execution remain owned by the tool/execution/policy mechanisms. Future
services require an intentional read/query-oriented addition with a concrete use
case; the public generic source-context contract is unchanged.
Authority follows Session -> Task -> authorized Environment -> exact provider
generation. This is typed host access, not an untyped service map or permission
to select another Environment.

The sealed `InferenceContextMaterial` root has only one implemented variant,
final `InferenceInstructionMaterial`:

| Field | Contract |
| --- | --- |
| `String key` | Nonblank, source-local logical identity, stable across captures; paired with source `ExtensionId` to identify material |
| `String text` | Nonblank instruction text, preserved byte-for-byte without trimming |
| `String? revision` | Optional opaque source-owned version, not parsed or used for host cache/freshness decisions |

Duplicate keys within one source invalidate the whole capture; the same local key
may occur in different sources. There is no cross-source override or deduplication.
Reuse the same key for the same logical material across captures, even when its
text or revision changes.
No Reference/Observation variants, roles, repository maps, or placeholder public
APIs are supplied.

### Remote Source Transport

`lib/remote_inference_context.dart` owns the generated transport contract,
separate from native contribution/context types. Unary
`RemoteInferenceContextSourceService.snapshot(String sessionId, String runId,
String hostInvocationContext)` returns `List<RemoteInferenceInstruction>`, whose
required fields are `key`, `text`, and nullable `revision`. The generated key for
revision remains required even when its value is null. Source and configuration
identity come from ready advertisements, not this result.
This library declares no `@AdeleFailure` type or domain-specific failure;
the generator supports zero declared failures and preserves unrecognized remote
failures as transport failures.

The app's `RemoteInferenceContextSourceAdapter` converts those values into native
`InferenceInstructionMaterial` and registers a contribution through internal
`PluginExtensionActivation` on the same `ExtensionRegistry`. The only accepted
point metadata is `failureMode: 'required'` or `'optional'`; there is no priority or
stock identity switch. Unsupported fields and values fail activation. The
composer retains all capture, ordering, duplicate-key, and required/optional rules.

For each snapshot the host captures the canonical `InferenceContextSourceContext`,
then grants a secure opaque invocation context with only generated Environment
`AuthorizedEnvironmentReadService` allowlisted. It offers no-argument `authority()`
for the already-bound Session/Environment identity, `readFile(relativePath)`, and
`readDirectory(relativePath)`, preserving existing DTOs and declared
`EnvironmentFailure`. AGENTS.md uses only the file read.
Session/Run strings are semantic context, never authority to select or reconstruct
a Session or Environment. The read service has no authority-ID parameters,
mutation, or process surface; the app obtains its captured context's
`AuthorizedEnvironmentFileReadFacet` and validates exact binding around the read.

Unary host requests reuse the isolate ports and framed shared host, with host-stamped
exact connection generations. Invocation contexts are revoked in `finally`, on
retirement, and on termination. Public pure-Dart `adele_plugin_backend_support`
supplies the backend channel multiplexer without importing internal runtime or
Flutter. This package defines transport values, not host routing/authorization.
Both host/plugin protocols are version 1 under the
[pre-release transport policy](../../docs/architecture/contracts-and-capabilities.md#transport-version-policy).
Source capture remains unary and read-only; reverse server streaming serves
separately authorized process tools,
not inference-source effect authority. General symmetric RPC and ambient callbacks
remain deferred. See [host calls](../../docs/architecture/contracts-and-capabilities.md#operation-scoped-host-calls).

### Snapshot And Rendering

`InferenceContextSnapshot` retains immutable `input`, `instructionGroups`, and
`sourceResults`. Semantic input values and order are unchanged from strategy
material. Groups are typed as `StrategyInstructionGroup.instructions` and
`SourceInstructionGroup.sourceId/materials`, preserving source identity and each
material's key, text, and revision. `InferenceContextSnapshot.fromStrategy(material)`
constructs the zero-source case. Every snapshot starts with exactly one
`StrategyInstructionGroup`, including when its `instructions` is empty; the group
is never structurally omitted.

Composition puts strategy instructions first, then sources in lexicographic
`ExtensionId` order, preserving each source's local material order. There is no
numeric priority, registration-order dependence, or global precedence mechanism;
sorting is deterministic composition, not semantic authority or trust.

`renderInferenceInstructions(snapshot)` is the lowering helper called by the
current app `ModelProviderCapabilityAdapter`. It joins instruction text with
`\n\n` into the unchanged `ModelProviderRequest.instructions` string, without
headers, labels, or trimming. Only rendering omits empty strategy text; the
snapshot's strategy group remains present. Whitespace-only strategy text is
preserved. Successful empty and omitted sources produce no source instruction
group. With zero sources, the exact strategy instruction
bytes, including the empty-string case, are unchanged. Semantic input is not
rewritten by rendering; the ModelProvider contract and transport are unchanged.

Each `InferenceContextSourceResult` retains `sourceId`, `failureMode`, immutable
`materials`, and optional `failure`. Its `InferenceContextSourceStatus` is
`contributed`, `empty`, or `omitted`. Successful empty output is distinct from an
optional failure. `InferenceContextSourceFailed` preserves the source ID, original
`cause`, and `stackTrace`; diagnostics are not rendered as instructions.

### Capture And Lifetime

Each genuinely new inference, including Chat continuation, discovers current
sources anew. Each `snapshot` callback returns current material according to that
source's freshness semantics. Rereads, watches, caches, and version tracking are
internal source choices. There is no generic refresh API or host cache plan; a
revision is opaque metadata, not a refresh command.

Capture uses the exact discovered binding: validate -> snapshot -> copy/freeze
and validate all material, including lazy iteration and duplicate keys ->
postvalidate -> commit that source's data. No partial source material is published.
Required failure throws `InferenceContextSourceFailed` and stops composition
before invocation identity/evidence/provider work. Optional failure omits the
entire source and records the original diagnostic. Neither mode retries a
replacement registration within the same capture.

After safe capture, the immutable data has no executable-binding dependency.
Source retirement during the provider call does not invalidate that request; the
next inference discovers any replacement. Executable strategy/tool exact-binding
rules are unchanged: already-resolved executable work cannot migrate.

## Boundaries

Stock Chat uses `plugins/chat_strategy/packages/{contract,backend,frontend}`.
Its installed backend advertises `dev.adele.strategy.chat` through the generic
remote strategy adapter and owns conversation state and loop sequencing. The
root implementation package is retired. Backend and frontend share the
plugin-owned Chat contract; neither orchestration nor the production application
imports it. Backend execution depends on public orchestration and transport APIs,
not `agent_kernel`. This package owns neither Chat history nor core Session
lifecycle/storage.

Chat contributes no context source and does not discover sources
itself. It owns history, instructions (including automatic batch-narration
guidance), Run-local replay, and bounded sequencing; tools, policy, and model
controls remain separate. Normal prepared startup and explicit development/self-hosting
activate the independent stock [`agents_md_backend`](../../plugins/agents_md/README.md)
through the same generic remote-source adapter; Chat remains AGENTS-unaware.
The backend reuses pure-Dart `agents_md_plugin` semantics and rereads root `AGENTS.md`
through generated authorized reads backed by the captured Session's
`AuthorizedEnvironmentFileReadFacet` each snapshot. Missing (`not_found`) or blank
files are successful empty results; other read/service/authority errors fail the
required source. Nonblank exact text and its opaque Environment revision are
retained as `AGENTS.md` material, separate from stable `semantics` material stating
that explicit user instructions and direct requests take precedence. This is
plugin-owned guidance, not a generic precedence or repository-instructions API.

There are no kernel, Flutter, app, or plugin-runtime imports. Scheduling,
general plugin management, broader Chat UI, persistence, profiles,
and child Sessions remain deferred. The generic context contract remains instruction-only. Nested/scoped
AGENTS.md, aliases/overrides, global/home files, imports, and AGENTS.md caching are
deferred; time, Skills, roles, and repository maps remain independent, unimplemented
source concerns. Broader Reference/Observation material is directional;
provider-aware projection/cache planning, token budgets, compaction, and context
inspection/persistence are deferred.
