# Agent Kernel Semantic Model

## Status

**Guiding architecture; bounded execution/Environment verticals, Session-bound strategy execution, headless stock Chat, and instruction-only inference context composition are implemented.**

ADR 0031 defines Session as a core container permanently bound to one orchestration strategy; strategy-specific state defines its semantic contents. Environment is the practical filesystem/source + process context. The Chat-shaped kernel Session/history/context types and separate Workspace discussion in ADR 0022 describe the historical Phase IV proof, not the current kernel API or universal product semantics.

This document records the semantic boundaries ADELE intends to preserve while implementing its agent execution substrate. It is more specific than the non-normative research survey, but it is **not** a stable public extension API and does not freeze exact Dart type names, persistence schemas, or extension APIs.

The current implementation, accepted ADRs, and external harness survey in [`../research/agent-harness-semantic-boundary-survey.md`](../research/agent-harness-semantic-boundary-survey.md) inform these boundaries. The architecture remains guiding and experimental rather than a stable public extension API.

Existing architecture principles remain in force, especially the distinctions among plugins, contracts, capabilities, extension points, configured capability instances, provider generations, and runtime resources.

## Scope

This document covers:

- Task, Environment, Session, and Run boundaries relevant to execution;
- the narrow responsibility of `agent_kernel`;
- model invocation and provider boundaries;
- tool discovery, materialization, invocation, policy, approval, execution, and result semantics;
- strategy input projection and per-inference instruction context capture;
- execution events;
- runtime-resource references;
- orchestration boundaries;
- generation safety;
- foundational versus reserved versus deferred concepts.

It does not define final UI layouts, stable plugin APIs, persistence formats, a complete policy language, a complete provider protocol, plugin-defined document/content APIs, SCM implementation details, remote execution, multi-agent scheduling, durable task graphs, or strong sandboxing.

# Core product concepts

ADELE's product model is broader than the agent kernel. The shared core identities relevant here are:

```text
Profile
Project
└── Task
    ├── Environment(s)
    └── Session(s)
        ├── Run(s)
        └── child Session(s)
```

The key meanings are:

> A Task is the unit of durable user intent.  
> An Environment is the practical filesystem/source + process context used for Task work.  
> A Session is the durable orchestration container, permanently bound to one strategy.  
> A Run is the unit of execution.

These are product/domain concepts. The agent kernel operates within them; it does not own the entire domain model. Plugins may associate their own durable concepts with these identities—for example a Plan plugin may own plan state and a Diff plugin may own pending review comments—without those concepts becoming additional core domain identities.

## Task

A Task is a durable goal-oriented product object. It may own goal/background/acceptance criteria, user-defined status, Sessions, one primary Environment plus additional Environments, and plugin-associated state.

The user or an external system owns Task workflow state. The agent kernel must not equate a successful Run with a completed Task.

## Environment

An Environment identifies the practical source/filesystem and process context used by execution.

The initial architecture intentionally does **not** claim that Environment means complete isolation of every process, port, database, cache, credential, or external service. A Git worktree-backed Environment can isolate source mutations while still sharing many host resources. Docker, VMs, or remote providers may provide different isolation properties.

The earlier separate first-class Workspace/source-mutation abstraction is not required long-term architecture unless future concrete requirements demonstrate an independent semantic identity that Environment cannot represent cleanly.

The kernel must not assume filesystem paths, processes, ports, or credentials are always local.

## Session

A Session is a durable orchestration container permanently bound to one orchestration strategy.

Core does not define every Session as conversation/chat history. The bound strategy owns the semantic structure of strategy-specific Session state. A Chat strategy may own canonical user/assistant messages, tool/reasoning timeline state, drafts, compaction, and forks; a Goal strategy may own iterations/evaluations or a substantially different structure.

`adele_product` owns the final immutable `Session(id, taskId, strategyId)` and the
semantic `OrchestrationStrategyId`. Keeping that ID in product preserves the
dependency direction: product does not depend on orchestration. The canonical
Session stores no live extension binding, Environment authority, or Chat state.
Application lifecycle creation validates an existing Task, exactly one current
strategy, and the primary or explicitly selected same-Task Environment, then
allocates `SessionId` and atomically publishes the Session and separate authority.
`store.session(id)` reads the product value; `requireSessionAuthority` remains the
Environment authority read path. This lifecycle is in memory, not disk persistence.

Headless stock `chat_strategy_plugin` owns `ChatSessionStore`, whose
`obtain(SessionId)` retains `ChatSessionState` across Runs. Its immutable
`ChatSessionSnapshot` contains canonical `ChatEntry` values:
`ChatUserMessage` and `ChatAssistantMessage`. Only user and final assistant
messages enter canonical history. Intermediate assistant/native output,
proposals, and tool results remain Run-local replay; they are not promoted to
canonical Session meaning. Chat owns instructions and a positive invocation
budget, snapshotted when each Run is materialized.

The kernel consumes/re-exports the same product `SessionId`, but has no
`session.dart` or `context.dart`, `SessionEntry`, `UserSessionMessage`,
`AssistantSessionMessage`, `SessionSnapshot`, `SessionHistoryPort`,
`ContextAssembler`, or `ContextAssemblyInput`. These historical proof types are
not a generic history interface that non-Chat strategies must implement.

Sessions should survive independently of Environment lifetime where the product lifecycle supports retaining history after Environment resources are released.

## Run

A Run is one execution episode within a Session.

A Run may include several model invocations, several tool invocations, interruptions, workflow steps, multiple agents, child Runs, optional child Sessions, cancellation, and failure handling.

A Run is not defined as one model call, one user message, one tool call, or one agent object.

A user message submitted while a Run is active may steer that Run, satisfy an interruption, queue for a safe point, cancel work, or explicitly start separate work. Workflow/product semantics decide which applies.

# Product domain versus agent kernel

| Concern | Primary owner |
| --- | --- |
| Project identity and concrete Project association | Product/domain layer + Project-selection providers |
| Task goal, user status, archive state | Product/domain layer |
| Environment identity/association | Product/domain layer |
| Environment filesystem/process implementation | Environment provider/capabilities |
| Strategy-specific Session state/history | Bound orchestration strategy + Session/domain persistence |
| Session identity, parent linkage, strategy binding | Product/domain layer |
| Run execution lifecycle | `agent_kernel` |
| Agent definition | Extensions/catalog outside execution state |
| Workflow/orchestration definition | Extensions/catalog outside execution state |
| Model provider implementation | Plugin/capability provider |
| Model invocation mechanics | `agent_kernel` through provider-neutral ports |
| Instruction context capture | Public `adele_orchestration` composer + source-owned freshness |
| Provider request lowering/protocol | Provider implementation |
| Tool catalog extension | Plugins/host composition |
| Tool invocation lifecycle | `agent_kernel` |
| Tool executor implementation | Plugin/capability adapter or host service |
| Tool policy evaluation | Host/core policy subsystem |
| Human approval interruption | `agent_kernel` + host interaction |
| Runtime resource implementation | Environment/resource capability |
| UI presentation | Host shell + presentation extensions |
| Plan, Diff review feedback, and other plugin-defined domain state | Owning plugin/extension |

`agent_kernel` remains an internal pure-Dart package. Plugins do not import it.

# Agent definitions and workflows

An Agent and a Workflow/orchestration strategy are distinct concepts.

> Agent means **who** performs work.  
> Workflow/strategy means **how** work is orchestrated.

The kernel supplies execution primitives and invariants. A workflow/strategy decides what happens next.

The private stock Chat execution implements a bounded sequential model/tool
loop. One completed model invocation may yield multiple tool proposals;
each resolves in output order against that turn's same immutable materialized
tool set and retained executable generations. Normal proposal-resolution
failures, tool failure outcomes, and policy denial produce results and do not
skip later proposals; model invocation and Run infrastructure failures retain
their terminal semantics. An `ask` decision pauses the ordered batch at that
invocation; approval or rejection resumes the same batch with prior results
retained. Only after all proposal results are collected does one model
continuation run. A proposal batch emitted in the final allowed model-invocation
slot fails before any proposal is prepared or executed because no continuation
slot remains; a proposal-free final answer may still complete in that slot.
Host-tool execution is sequential only. This Chat algorithm does not
define what a Run fundamentally is, introduce a general Workflow framework, or
change the common model/tool contracts.

Public pure-Dart `adele_orchestration` implements executable
`OrchestrationStrategyContribution(strategyId, materialize)`, the typed
`orchestrationStrategyContributions` extension point over the existing
`ExtensionRegistry`, and thin `OrchestrationStrategyResolver.resolve(id)`.
`ResolvedOrchestrationStrategy` retains its exact `ExtensionBinding`. Zero matches
produce an explicit unavailable error; duplicate semantic IDs are ambiguous even
under distinct `ExtensionId` values. The lifecycle coordinator's
`resolveSessionStrategy(sessionId)` resolves the canonical Session's stored ID.

`ChatStrategyPlugin.activate` follows the same in-process activation convention
as stock tool plugins. It registers semantic strategy ID
`dev.adele.strategy.chat`, distinct from plugin ID
`dev.adele.plugin.chat-strategy` and extension ID
`dev.adele.plugin.chat-strategy.orchestration`. This is the first real executable
stock strategy, not identity-only metadata or production discovery. Its private
loop is extracted from the former `DevelopmentToolLoopStrategy`; the app no
longer owns the loop or temporary development strategy registration.

## Public execution and internal mechanics

`createSessionOrchestrationRun` in `app/lib/core/orchestration_host.dart` looks up
the canonical Session by `SessionId`, resolves its exact contribution once per
Run, and materializes it using `OrchestrationStrategyHostContext(session, host)`
against `KernelOrchestrationHost`. The result is `OrchestrationExecution`, with
`start` and `resolveApproval` entry points for strategy sequencing.

The public `OrchestrationExecutionHost` exposes only the concrete operations a
strategy needs:

- Run/Session identity, small lifecycle state, `start`, `complete`, `fail`, and `validateBinding`;
- `invokeModel(StrategyInferenceMaterial)`, returning a `StrategyModelTurn` with ordered semantic output, settlement/metadata or failure, and an opaque `StrategyToolSnapshot`;
- `processProposal` with that snapshot and `ProviderToolProposal`, returning a semantic continuation item or `StrategyToolWaiting`;
- `resolveApproval(ToolApprovalResolution)`, returning `SemanticToolOutcomeInput` after host-owned approval resolution and any authorized execution.

Minimal semantic input/output, native-envelope, proposal/failure,
settlement/metadata, and approval DTOs live in the existing public
`adele_orchestration` package and are reused by the kernel, not duplicated.
`SemanticModelRequest`, model ports/events/streams/collectors, tool catalogs and
executable materializations, policy, `AgentRun`, and the journal remain internal.
Neither public orchestration nor Chat imports `agent_kernel`. A collected public
model turn does not replace the internal streaming model boundary.

Application `SessionOrchestrationRun` retains the exact execution/binding and
exposes internal Run/tool/journal evidence only to app callers. The host, not
Chat, owns proposal preparation, effect/policy evaluation, retained approvals,
tool execution, stream collection, and evidence recording. Core model/tool/policy
and Environment selection remain unchanged.

The host accepts only unused proposals issued by its own completed model turn
against that exact snapshot. Chat can order and resume work, but it cannot replay
an already-processed proposal or replace an executable generation.

The adapter accepts approval resolution only for the exact host-issued
`ToolApprovalResolution` object forwarded during the current
`SessionOrchestrationRun.resolveApproval` call. Matching interruption/invocation
IDs alone does not authorize execution: a plugin cannot construct its own
approval or substitute approval for rejection. Authorization is consumed on
resolution and cleared when the resume call ends, so it cannot be reused later.
This is distinct from the retained invocation's exact executable-generation check.

Self-hosting activates Chat, obtains retained state, sets Chat configuration,
appends the prompt, and routes `SessionId` through lifecycle resolution and this
host. It does not construct a development loop or kernel history adapter.
Chat UI/persistence, child Sessions, strategy defaults/profiles, lifecycle UI,
and disk persistence remain deferred.

# Strategy state and context assembly

## Implemented inference composition

```text
Chat-owned canonical history projection + Run-local replay
    -> StrategyInferenceMaterial(instructions, ordered semantic input)
    -> InferenceContextComposer over the existing ExtensionRegistry
        + current inferenceContextSources instruction snapshots
    -> immutable InferenceContextSnapshot
    -> KernelOrchestrationHost adds invocation identity and materialized tools
    -> internal SemanticModelRequest(context, invocationId, tools)
    -> internal streaming ModelPort
    -> app ModelProviderCapabilityAdapter calls renderInferenceInstructions
    -> unchanged ModelProviderRequest.instructions string + ordered input
```

`StrategyInferenceMaterial` carries instructions and an immutable ordered list of
`SemanticModelInputItem` values between strategy-owned projection and internal
request construction. Chat controls the meaning and order of its
material, but does not select executable tools, allocate model invocation IDs,
or mutate a provider request. The host composes instruction context before
allocating model invocation identity, materializing tools, recording model-start
evidence, or calling the provider. Semantic input remains unchanged.
Canonical history is reused across Runs; native replay and tool continuation
items are local to the Run that produced them.

Public `adele_orchestration` owns `InferenceContextComposer` and the typed
`inferenceContextSources` point (`dev.adele.extension.inference-context-sources`)
over the same existing `ExtensionRegistry`, not another registry or runtime.
Each final `InferenceContextSourceContribution` has an explicit required
`failureMode` and `snapshot` callback. `InferenceContextSourceContext` supplies
the canonical `Session`, `runId`, and `requireHostService<T>()`. A fresh app
`SessionInferenceContextSourceContext` per inference delegates typed service
access to `SessionModelToolHostContext`: Session -> Task -> authorized Environment
-> exact provider generation. It does not accept a reconstructed Session or grant
independent Environment selection.

The sealed `InferenceContextMaterial` root currently has only final
`InferenceInstructionMaterial`: a nonblank source-local `String key`, nonblank
`text` preserved byte-for-byte, and optional opaque `String revision`. The snapshot
retains typed `instructionGroups`: `StrategyInstructionGroup.instructions` and
`SourceInstructionGroup.sourceId/materials`, plus immutable unchanged semantic
`input` and `sourceResults`. Results distinguish successful contributed or empty
output from optional omission with original diagnostics. Material keys are unique
within each source and stable across captures of the same logical material, even
when text or revision changes; they are not a global deduplication or override
mechanism. Every snapshot starts with `StrategyInstructionGroup`, even when its
instructions are empty. Empty strategy text never removes the structural group.

Strategy instructions come first; sources follow in lexicographic `ExtensionId`
order, preserving each source's returned material order. This deterministic order
does not establish semantic authority, trust, or priority. There is no numeric
priority field. `renderInferenceInstructions` in orchestration lowers these groups
at the current app provider adapter using blank-line separators. Only this rendering
omits empty strategy text, not whitespace-only strategy text; source text must
be nonblank and is not trimmed. Zero-source instruction bytes are unchanged.

### Capture and freshness

Every genuinely new inference, including Chat continuation after tool results,
discovers current sources. Each snapshot callback returns current material according
to the source's freshness semantics: reread, watch, cache, or version tracking is
an internal implementation choice. No generic refresh API,
host freshness scheduler, or provider cache plan is introduced.

One source capture is exact-binding validate -> snapshot callback -> copy/freeze
and validate all material, including duplicate local keys -> postvalidate binding
-> commit captured data. Required failure aborts composition before invocation
identity, model-start evidence, or provider work. Optional failure omits the whole
source and retains its original diagnostic; no partial source material survives.
Successful empty output is not omission. The same capture never retries against
a replacement registration.

After safe capture, source material is immutable data independent of the live
binding. Retirement during the provider call does not invalidate the captured
request; the next inference discovers any replacement. Executable strategy/tool
bindings still require their existing exact-generation checks and never migrate.
Chat owns no production source; current composition activates none. Tools,
policy, and model controls retain their existing owners.

This is a bounded instruction-only slice, not a renamed generic
`ContextAssembler`. No production repository-instruction, time, role, or
repository-map source is included. Broader Reference/Observation material remains
directional without placeholder public APIs. Provider-aware projection/cache
planning, compaction, context preview, and token budgets remain deferred. Chat's
positive invocation budget limits model-call count, not context size or token use.

## Future composition

The intended broader relationship is:

```text
strategy-owned Session state/history
    +
Project instructions
    +
Task goal / accepted knowledge
    +
Session-specific context
    +
Environment state
    +
Agent instructions
    +
strategy/workflow instructions
    +
plugin context extensions
        ↓
structured Context / Inference Composition
        ↓
semantic model request
```

For a Chat strategy, canonical conversation history is an important input. It is not the universal definition of Session and it is never itself the provider request.

Broader context/inference composition belongs at the host-controlled provider-neutral boundary. The implemented slice preserves typed instruction groups, source identity/results, and deterministic order; budgeting, cross-source deduplication, compaction, provider-aware projection/cache planning, pinning/exclusion, and user inspection remain deferred. The possible inputs above are direction, not implemented sources or public material variants.

Context extensions should return structured material rather than mutate one prompt string or an opaque provider request.

Strategy-owned canonical meaning belongs to ADELE/product state rather than being represented only by provider-native continuation. Provider-native continuation may be retained when useful, but it is compatibility-bound provider/model state and must not become the only representation of durable Session meaning.

# Model-provider semantics

ADELE should preserve the conceptual distinction among:

- provider implementation;
- configured provider capability instance/account/endpoint;
- model identity;
- model capability metadata;
- semantic model request;
- provider-native lowering;
- live protocol/route/client resources;
- provider-native continuation state.

Protocol reuse is an implementation concern, not provider identity. Several provider plugins may share an OpenAI-compatible client library while retaining distinct configuration, auth, discovery, defaults, and quirks.

One plugin runtime may expose multiple configured model-provider instances, such as Work and Personal accounts, following the existing configured-capability-instance model.

## Streaming-capable model invocation

The kernel-facing model boundary should be streaming-capable:

```text
SemanticModelRequest
    ↓
Model invocation
    ↓
ModelEvent*
    ↓
authoritative terminal completion or failure
```

Useful semantic events may eventually include content blocks/deltas, reasoning, completed semantic items, tool-call proposals, usage, retry/fallback notices, errors, and terminal completion.

The kernel does not make unary `Future<ModelResponse>` its fundamental abstraction. Generated ModelProvider transport implements server streaming and cancellation; retained unary fixture methods are regression/reference infrastructure rather than the maintained application path.

Provider-specific lowering handles protocol roles/items, reasoning formats, hosted tools, provider-only options, cache controls, endpoint/auth details, model-family quirks, and provider continuation identifiers.

Provider-native continuation is optional and compatibility-bound. Switching provider/model may require explicit replay or lossy projection.

Capability major 1 now implements distinct instructions, ordered typed message/tool input, live text-delta observations, completed text and multiple completed tool proposals, and explicit terminal settlement. Item IDs and opaque item metadata survive model/tool/model continuation without becoming canonical Session meaning. Stream EOF is not semantic success.

The shared `ModelNativeEnvelope` retains kind, compatibility, and opaque data as one immutable value. Completed, incomplete, and refused terminals are general settled events, and typed Run observation retains their settlement and metadata. Chat never executes proposals from incomplete or refused turns. Incomplete turns fail; a refusal with nonblank assistant text may become the final canonical assistant message, while a refusal without assistant output fails.

Opaque provider-native state may either be metadata intrinsically attached to a semantic item or an independent native-only ordered item. Native-only items carry no common text, tool, reasoning, or compaction meaning; the kernel retains their exact list position for compatible model/tool/model replay.

# Tool semantic model

## Tool identity

A model tool has semantic identity independent of the name shown to a model:

```text
semantic ToolId
    ≠
model-visible alias
    ≠
executable provider/connection generation
    ≠
individual ToolInvocation
```

The exact `ToolId` encoding is deferred, but it must have a namespace, stable semantic meaning, and explicit compatibility/version boundary.

Model-visible names may be sanitized, namespaced, aliased, or changed for provider constraints. They are snapshot-local routing names, not durable identity.

## Tool versus Capability

A model-callable Tool is **not automatically an ADELE Capability**.

A plugin may expose a sustained typed Environment filesystem/source Service and also contribute model tools such as `read_file`, `write_file`, or `search_text` whose executors project that Service into model-callable operations.

Dynamic external tools such as MCP definitions may be contributed without manufacturing a separate ADELE Capability for every external function.

Existing generated typed contracts remain the invocation mechanism wherever a tool executor calls an ADELE capability.

The current stock projections apply this distinction to Session-authorized
Environment facets: Filesystem Tools owns `read_file`, `apply_patch`,
`create_file`, and `delete_file`, Search Tools owns `search`, and Command Tools
owns direct-argv `run_command` over the foreground process facet. No separate
Command or Shell capability is introduced.

## Tool definitions and catalog

A provider-independent tool definition should describe semantic identity/version, description, canonical input contract/schema, conservative static effect metadata, and optional result/presentation contract metadata.

A host-owned catalog/composition subsystem collects current tool extensions. Availability may change because of plugin activation, provider lifecycle, MCP discovery, workflow stage, Environment availability, agent policy, or profile configuration.

## Immutable materialization per model invocation

One logical model invocation receives an immutable materialization of its visible tools.

Each materialized entry retains:

```text
semantic tool identity
model-safe alias + schema
exact executable binding
relevant provider/connection generation
```

The next model invocation may rematerialize the set. A protocol requiring catalog continuity across native continuation may impose that as a provider constraint; the generic architecture does not require a Run-global immutable tool list.

## Provider proposal versus ToolInvocation

A provider may propose a tool by provider call ID, model-visible name, and arguments.

A resolved `ToolInvocation` should be created only after:

1. the proposal name resolves against the materialized set;
2. semantic tool/executable binding is known;
3. arguments are authoritatively validated/normalized.

An unknown model-visible tool is a model/protocol-correlated unavailable/invalid proposal. It must not create a fake ToolInvocation bound to an unrelated tool.

A ToolInvocation conceptually carries:

- Run-local invocation identity;
- provider call correlation;
- semantic tool identity;
- exact materialized executable binding;
- canonical validated arguments;
- Run/Session/Task/Environment context linkage;
- invocation-specific effect description;
- policy/interruption state;
- progress;
- exactly one terminal outcome.

The provider call ID remains correlation data; ADELE may assign its own invocation identity.

## No general execution-attempt identity

The architecture does not introduce a generic `ToolExecutionAttemptId`.

The working assumption is that one ToolInvocation has one execution phase and one terminal outcome. If a future durable-retry design intentionally executes one approved invocation multiple times, attempt identity can be introduced then.

A deliberate retry after an indeterminate result should normally be a **new ToolInvocation** linked by provenance rather than a hidden repeat.

# Effect description and policy

Tool definitions may declare conservative effect classes such as Environment/source read, Environment/source mutation, process execution, external/network interaction, credential access, and runtime-resource creation/use. The current minimal enum includes `processExecution`; broader production classes remain deferred.

Static metadata cannot fully describe concrete operations. Before policy/approval, the selected executable may derive a non-mutating invocation-specific effect description from canonical arguments and context.

Examples include exact file/resource targets, observed versions, cwd, runtime resource identity, likely mutation scope, network uncertainty, and resource creation.

Preflight may require bounded observation/read operations. If approval depends on observed state, material state must be revalidated immediately before execution. Effect description is an aid to policy/approval, not a guarantee that an open-ended command has no other effects; uncertainty must be representable.

A future policy engine may need semantic identity, exact binding/provider trust, canonical arguments, Run/Session/Agent/Workflow context, Environment, static effects, derived targets/effects, uncertainty, and runtime-resource information.

Availability, policy, approval, Environment isolation, and credential access remain distinct concerns.

# Run interruptions

A Run may have zero or more outstanding interruptions.

`RunInterruption` is the general semantic category for execution that cannot progress until an external decision/input is supplied.

Initial conceptual variants are:

- Tool approval;
- User input / elicitation.

Tool approval is implemented. User-input elicitation and durable interruption handling remain deferred.

Approval must bind to the exact ToolInvocation, including semantic identity, canonical arguments, effect description, and executable generation.

A broader persistent policy choice such as "always allow" may change future policy, but it is not the identity of the current interrupted invocation.

# Tool execution

One underlying started execution should produce zero or more progress observations and exactly one terminal outcome:

```text
execution begins
    ↓
ToolProgress*
    ↓
exactly one ToolOutcome
```

The current internal Dart API is a stream of `ToolExecutionEvent` values with zero or more progress observations and exactly one terminal outcome. This is not a stable public API, but it preserves the invariant that one execution does not require separate effectful `execute()` and `outcome()` operations.

Progress is nonterminal observation. The current minimal `ToolProgress` shape distinguishes `status`, `stdout`, and `stderr` content while stream order supplies ordering. Future transport/persistence may choose which progress is durable or lossy.

# Tool outcomes and effect certainty

The architecture needs structured terminal classification rather than `error: String`.

Useful coarse categories include success, invalid arguments, unavailable, stale binding, policy denied, user rejected, domain failure, infrastructure failure, cancelled, indeterminate, and malformed external result. This list is guiding, not a frozen enum; domain-specific codes may refine it.

A command can execute successfully and return a nonzero exit code as domain data rather than infrastructure failure.

Effect certainty is an independent dimension. A terminal outcome must be able to express whether an external effect is known not to have begun, is known to have occurred/produced a surviving resource, or may have occurred with external truth unknown.

Examples:

```text
cancelled + no effect began
cancelled + effect may have occurred

infrastructure failure + no effect began
infrastructure failure + effect may have occurred

malformed result + effect may have occurred
```

`indeterminate` is appropriate when an external effect may have completed but ADELE cannot know the result.

ADELE must not generically retry a side-effecting invocation merely because its result is absent. Domain capabilities may provide explicit idempotency or reconciliation guarantees.

# Structured content and resources

A tool outcome may need several projections:

```text
ToolOutcome
├── compact model-facing content
├── structured host data
├── truncation metadata
├── runtime-resource references
└── detailed host-only diagnostics/provenance
```

Display prose is not the canonical representation of all data.

The semantic model should support structured content blocks rather than one required string. Initial implementation may support only a small subset, while leaving room for text, structured data, resource references/content, images, audio, and other media.

Plugins may define durable/significant non-conversational content with their own identity and lifecycle—for example a Plan plugin can own a plan document. The kernel does not require a universal core `Artifact` identity merely to carry structured tool results or plugin-owned references.

A runtime resource is an addressable live entity whose lifetime is independent of one tool invocation. Examples include processes, terminal sessions, browser sessions, debugger sessions, remote jobs, and temporary connections.

The kernel may carry an opaque runtime-resource reference and provenance. It does not own universal process/browser/terminal behavior. The Environment or resource capability owns identity allocation, lifecycle, observation, cleanup, leases, and restart/recovery policy.

# Generation-bound execution

ADELE's exact provider-binding behavior is a core execution invariant.

When a model or tool is materialized against one provider/connection generation:

- the exact binding is retained;
- approval refers to that binding;
- execution validates that same binding immediately before use;
- if it became stale, the operation fails explicitly;
- ADELE does not silently re-resolve the same provider ID to a replacement generation.

This applies to model continuation, model-visible tool materialization, approved tool invocation, and dynamic MCP/external connections.

A new generation can participate in a new materialization cycle.

Strategy execution follows the same exact-binding invariant without making the
Session's permanent semantic strategy ID a lifetime generation pin. Each
`SessionOrchestrationRun` retains one resolved/materialized contribution. The
host validates it at subsequent operations, approval resume, and asynchronous
settlement. A retired `ResolvedOrchestrationStrategy` fails with generic
`StaleExtensionBinding`: an old active Run fails explicitly and cannot advance
on replacement B. An in-flight operation may settle and retain evidence, but
retirement does not imply rollback of external effects.

A later Run in the same Session freshly resolves the stored ID and may use B;
unavailable or ambiguous resolution never falls back to another strategy or
rewrites the canonical Session. Reusing Chat history from a retained
`ChatSessionStore` across Runs is independent of migrating a live binding and
does not establish disk persistence or automatic restoration after reactivation.

# Environment

Run execution may be associated with a Task Environment:

```text
Run
├── Session
└── Environment?      filesystem/source + process context
```

Current application composition resolves one authoritative Session-to-Task/Environment relation and projects coherent read, mutation, and foreground-process facets. The kernel does not select another Environment. The historical Phase IV DevelopmentSource root binding was a read-only proof, not the current authority model or a security sandbox.

Future Environment providers may represent Git worktrees, containers, VMs, SSH hosts, cloud sandboxes, or other plugin-provided contexts.

A Task normally has one primary Environment. Child Sessions may share that Environment or use another Task-associated Environment. Environment lifecycle/provider behavior belongs to the broader product/plugin architecture rather than `agent_kernel`.

# Child Runs and child Sessions

The architecture reserves both concepts.

A child Run is subordinate execution that does not require an independent durable Session context. A child Session is appropriate when delegated work needs independent strategy-specific state/context, persistence, inspectability, background lifetime, or later continuation.

A child Session remains under the same Task, records its parent Session, may use the same or another Task-associated Environment, and may be bound to another orchestration strategy. It is primarily surfaced through the parent Session/orchestration experience rather than flattened into normal top-level Task navigation.

A workflow decides whether subordinate work needs a child Run or child Session. Both remain deferred.

# Execution events and projections

The kernel emits typed semantic execution observations suitable for deterministic tests and an in-memory Run journal, while leaving room for live UI projection, debugging, tracing, and future persistence.

Examples may include Run lifecycle events, model invocation lifecycle, model content, tool proposal/resolution, policy evaluation, interruption creation/resolution, tool execution, progress, and tool completion.

Execution observations are **not** automatically the sole durable source of truth. Future persistence may use append-only facts, snapshots, projections, specialized stores, or a hybrid. Live progress and durable semantic history may use different representations.

The deterministic in-memory journal is implemented without claiming durable storage, event-sourced crash recovery, or replay.

Public plugin Events are a broader extension concept defined outside the kernel. A kernel observation may later be projected into a public Event, but the internal Run journal and public Event system are not assumed to be identical.

# Run lifecycle

The Run's top-level lifecycle should remain small, conceptually:

```text
created
queued?       // if scheduling exists
running
waiting
completed
failed
cancelled
```

Details such as waiting for approval, waiting for user input, waiting for a resource, tool executing, model streaming, and cancellation requested belong in subordinate state/events and may be projected to richer UX statuses.

This avoids one giant mutually exclusive Run enum that cannot represent parallel or multiple pending operations.

# Plugin, capability, extension, and library boundaries

## Plugin

A Plugin is a deployment/lifecycle/configuration/permission boundary. One plugin may participate in several semantic roles.

For example, a Git plugin may eventually provide an Environment implementation, source-control/review Services, model tools, context extensions, Task summaries, Commands, and Events. It should not be forced into one plugin category.

## Capability

A Capability is callable runtime interoperability: which compatible provider can satisfy a semantic Action/Service request. Runtime dependencies should prefer capabilities/interfaces over plugin implementation identities.

## Extension point

An Extension Point is the broader typed composition concept described in [`plugin-extension-model.md`](plugin-extension-model.md). Capabilities, UI summary regions, structured inference composition, and plugin-defined ecosystems may use different extension semantics.

Plugins may define their own public extension APIs. Depending on such an interface is distinct from requiring one implementation plugin to be active.

Generic typed registration/discovery, retirement, and binding liveness are
implemented, with model-tool and executable orchestration-strategy contribution
points and instruction-only inference-context sources. Broader recursive
composition remains deferred; neither the generic
registry nor the capability registry supplies universal composition or execution
semantics for every extension type.

## Library

A Library is build-time implementation reuse without runtime identity. An OpenAI-compatible protocol/client implementation will normally be a library reused by provider plugins unless it gains independent runtime routing/policy semantics.

## Configured capability instance

Accounts/endpoints/providers such as "OpenAI Work" and "OpenAI Personal" are configured instances exposed by one plugin runtime, not separate plugins.

## Runtime resource

Processes, terminals, browser sessions, open documents, live connections, and active executions are temporary runtime identities, not plugin installations or configured capability instances.

# Presentation extensions

ADELE always needs generic rendering for core semantic items.

Plugins may contribute specialized presentation for semantic surfaces such as ToolInvocation summary/details, approval body, progress, result, resource or plugin-defined rich-content viewing, diff/change-set rendering, context activation, and provider configuration.

Execution returns semantic data. Presentation consumes semantic data. Executors do not return Flutter widgets.

Presentation lookup should use stable semantic tool/result contracts rather than model aliases or Dart runtime types crossing plugin boundaries. Generic fallback remains mandatory where core semantics require it.

Global plugin-facing workbench surfaces should be semantic rather than tied to current physical placement. The concrete UI extension API remains deferred.

# Permissions and approval

The architecture preserves at least these distinct questions:

1. Is the capability/tool available?
2. Is it visible to this agent/model/workflow step?
3. Is this concrete invocation allowed by policy?
4. Does this concrete invocation require human approval?
5. Does the Environment actually isolate or permit the effect?
6. May the operation access credentials/secrets?

Future policy may combine profile, Environment, agent, workflow-step, user, tool, resource, and effect constraints. The UX may describe this as an intersection, but implementation should not assume policy is merely set intersection.

# Execution boundaries

- `agent_kernel` is pure Dart and provider-neutral.
- Plugins do not depend on `agent_kernel`.
- Application/core composition adapts capability bindings into kernel ports.
- Model providers are ADELE capabilities.
- Tool executors may project other ADELE capabilities.
- Resolved providers remain generation-bound.
- Old work must not silently migrate to restarted provider generations.
- Provider/tool failures are contained to relevant execution.
- Structured rejection/error semantics are preferable to display text alone.
- A deterministic in-memory execution journal is valuable for tests/inspection.

# Foundational now, reserved, and deferred

## Implemented foundation

The current implementation supplies:

- strategy-owned Session state distinct from Run execution;
- executable strategy registration/materialization and exact-binding validation;
- headless Chat with in-memory canonical user/final assistant history;
- `StrategyInferenceMaterial` before host request construction;
- per-inference instruction-source discovery/capture and immutable `InferenceContextSnapshot`;
- Run lifecycle;
- workflow/strategy separation;
- streaming-capable model invocation semantics;
- configured model provider/model selection;
- dynamic tool catalog/materialization;
- semantic tool identity;
- ToolInvocation;
- policy versus approval;
- RunInterruption;
- generation-bound executable bindings;
- invocation-specific effect description;
- structured content/outcome;
- typed progress;
- effect certainty/indeterminate outcome;
- typed execution observations.

This foundation does not imply a complete public API or persistence implementation for every concept. Runtime-resource references remain reserved semantic space rather than a production runtime-resource system.

## Reserve semantic space

Do not fully implement yet without concrete need:

- AgentDefinition catalog;
- child Run graph;
- child Session lifecycle;
- additional EnvironmentProvider integrations;
- plugin-defined durable document/content facilities;
- persistent memory;
- durable Run serialization/recovery;
- provider-native continuation persistence;
- model capability negotiation;
- tracing model;
- runtime-resource references/provenance;
- runtime-resource lease/recovery;
- presentation extension API.

## Explicitly defer

Do not add before a concrete need:

- generic execution-attempt identity;
- pure event-sourcing requirement;
- distributed exactly-once tool execution;
- automatic replay of side-effecting tools;
- kernel task/work-item dependency graph;
- durable teams/mailboxes/leases;
- generic snapshot/rollback system;
- one capability per model tool;
- arbitrary replacement of host-owned top-level workbench geometry;
- full multi-agent scheduling.

# Current execution path

```text
canonical SessionId + retained Chat state
    -> createSessionOrchestrationRun
    -> exact contribution materialization
    -> Chat start
    -> StrategyInferenceMaterial
    -> current source capture into InferenceContextSnapshot
    -> host SemanticModelRequest(context, invocationId, tools)
    -> adapter renderInferenceInstructions + exact tool materialization lowering
    -> generated streaming ModelProvider invocation
    -> StrategyModelTurn
    -> ordered proposals through host policy / optional approval / execution
    -> semantic continuation items in Run-local replay
    -> next model turn or final canonical assistant entry
    -> Run completion
```

The application adapters consume generated typed streams with ordered items,
terminal settlement, structured failure, cancellation, and generation-bound
lifetime. The public strategy facade receives collected turns, not model ports
or transport events. Deterministic integration covers Session-authorized source
inspection, bounded text-file mutation, foreground validation, and continuation.
This current path is deterministically validated. Paid live services have not
been rerun against it; recorded opt-in live results remain bounded
interoperability evidence, not complete self-hosting.

# Self-hosting remains the gate

Do not let architectural expansion delay the first meaningful product workflow:

1. select/open the ADELE Project through the stock development composition;
2. create/select a Task/Session;
3. ask an agent for a small code change;
4. read/search files through the Task Environment;
5. apply changes;
6. display the diff;
7. display/edit changed files;
8. review/comment and approve/unapprove changes where the active SCM supports those semantics;
9. run validation;
10. show results in the Session.

Editor polish, provider breadth, sophisticated orchestration, memory, and marketplace work can evolve after ADELE crosses this boundary.

# Invariants for future design reviews

When evaluating designs against these execution boundaries and ADR 0031, ask:

1. Is strategy-owned durable Session meaning distinct from one Run and one model request?
2. Can Run support more than one model/tool step without defining simple Chat as Run itself?
3. Is model invocation streaming-capable at the kernel boundary?
4. Are provider-specific protocol/continuation details kept behind the provider boundary?
5. Are configured provider instance and model identity distinct?
6. Is one model invocation given a stable materialized tool snapshot?
7. Is model-visible tool name separate from semantic identity?
8. Does a resolved ToolInvocation retain the exact executable generation that produced it?
9. Are availability, policy, approval, execution, and Environment isolation separate?
10. Does approval bind the exact invocation/effects rather than a tool name?
11. Can results preserve structured host data separately from compact model content?
12. Can cancellation/transport failure express uncertain external effects?
13. Does the design avoid blind generic side-effect retries?
14. Can a tool return an opaque runtime resource without making the invocation its lifetime owner?
15. Can generic UI render core semantic items while optional extensions enrich presentation?
16. Are execution observations useful without committing ADELE to pure event sourcing?
17. Are plugins still independent of `agent_kernel`?
18. Are plugin-to-plugin/core operations expressed through public typed interfaces rather than implementation dependencies?
19. Has each new foundational abstraction been justified by a concrete requirement rather than hypothetical reuse?
20. Does the design preserve Environment as the practical source/process context without inventing stronger isolation semantics before they are needed?
21. Does the design keep the path to the minimal self-hosting workflow short?
