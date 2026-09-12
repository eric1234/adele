# ADELE Architecture Overview

## Status

ADELE's maintained Linux x64 foundation includes source compilation, generated unary and server-streaming/cancellation transport, interpreted frontend execution, active capability routing, configured provider contexts, bounded agent/source-inspection, conditional Environment mutation, foreground-process execution, and create/delete tooling. It includes the real OpenAI `ModelProvider`, an explicitly experimental ChatGPT configured instance, initial Project/Task/Environment lifecycle, canonical strategy-bound Session creation with separate Environment authority, generic extension/model-tool composition, executable strategy contributions, a Git Environment provider, and independent stock Filesystem Tools, Search Tools, and Command Tools that own Session-authorized `read_file`, `apply_patch`, `create_file`, `delete_file`, `search`, and `run_command`. Headless stock Chat owns conversation state and sequencing through a narrow public execution facade backed internally by the kernel.

The maintained source-inspection topology routes the canonical Session through core strategy resolution and Chat materialization, generic model-tool extension composition, plugin-owned Search, Session-authorized Environment access, plugin-owned Read File, maintained ADELE source, and model continuation. Search is bounded native Dart traversal over authorized Environment directory/file reads, not an Environment provider method. Focused deterministic validation passes for public orchestration, kernel model/run/tool mechanics, Chat, and maintained application lifecycle, model-tool hosting, self-hosting, Environment, OpenAI fixture, and provider-adapter integration. This implements neither ADELE's complete product/domain model nor the general recursive extension system.

Environment exposes provider-neutral opaque file revisions and conditional replacement of existing bounded UTF-8 text files. The Git Worktree provider serializes ADELE replacements within each live Environment and detects practical out-of-band changes immediately before promotion, but cannot provide portable atomic compare-and-replace against arbitrary external processes. Coherent read and mutation facets share one Session-authorized filesystem authority. Filesystem Tools' exact-unique `apply_patch` lowers localized model edits to complete-file conditional replacement. Deterministic real-Git integration covers Read-to-Revision-to-Patch continuation. Opt-in OpenAI API-key and experimental ChatGPT tests cover real-model revision flow, Task-worktree-only mutation, post-write observation, and continuation; recorded live results remain bounded interoperability evidence rather than a stable contract.

Filesystem Tools owns the model patch grammar, not `EnvironmentProvider`. It
preflights the original opaque revision once and applies the non-empty `edits`
array of `{search, replace}` objects in list order to a working string. Each
non-empty search must be an exact, case-sensitive, literal unique match,
including overlapping candidate starts; replacement text may be empty. Later
edits see earlier replacements. A failed edit reports its zero-based
`failedEditIndex` and total `editCount` with no writes; a final result identical
to the original reports `no_change` with no writes. Only after all edits pass
does the tool request one conditional whole-file replacement using the unchanged
original expected revision.

The Environment provider contract supports foreground process execution through one Session-authorized process view over the existing Environment authority. The stock Git Worktree provider supplies bounded stdout/stderr streaming, timeout and cancellation cleanup, confined cwd resolution, direct argv execution, and practical Linux x64 process-group ownership. Stock `run_command` projects that surface through structured stdout/stderr progress, bounded terminal model output, and the allow/deny/ask policy path. Deterministic real-Git integration covers source edit -> direct `git diff --check` -> model continuation in the Task worktree. Opt-in OpenAI API-key and experimental ChatGPT tests cover the same real-model sequence with revision provenance and Task/Project/checkout isolation. Fine-grained command classification, implicit shell syntax, background process resources, general build/test success, sandboxing, and complete self-hosting remain unproven.

The Environment mutation facet and generated transport also support create-new and revision-conditional delete operations. Filesystem Tools projects them as `create_file` and `delete_file` with exact `sourceMutation` targets. The Git provider serializes create/replace/delete together, rejects indirect paths, never intentionally overwrites on create, and rechecks revisions immediately before delete. Deterministic real-Git integration covers model-visible create -> read -> delete revision provenance, policy/effect ordering, and final Task/Project/checkout isolation. General whole-file overwrite, directory/move/copy/binary mutation, portable filesystem transactions, and full self-hosting remain unimplemented.

The following remain largely or entirely unimplemented:

- Project/Task/Session/Environment disk persistence and complete lifecycle;
- Chat UI and persistent strategy-specific state;
- context sources beyond root AGENTS.md, broader Reference/Observation material, provider-aware projection/cache planning, compaction, and token budgets;
- parent/child Session lifecycle;
- plugin-defined extension ecosystems beyond registration, model tools, executable strategies, and instruction-context composition;
- production plugin-facing UI composition;
- application Command/Command Palette/keybinding infrastructure;
- profile-aware provider preference and general configuration services;
- additional Environment providers, process modes beyond the foreground surface, and broader mutable source tooling such as whole-file overwrite, directory/move/copy, and binary operations;
- the expected stock plugin topology;
- cross-platform release, packaging, and sandboxing.

Public plugin-facing APIs remain experimental.

## System shape

ADELE has one Flutter desktop application, `adele_desktop`, under `app/`. The application owns the current shell, theme, private widgets, desktop integration, and composition of host systems. It is a composition root rather than the primary home of core logic.

`app/lib/core/adele_runtime.dart` defines the application-lifetime `AdeleRuntime`.
It owns one `CapabilityRegistry`, `ExtensionRegistry`, `InMemoryProductStore`,
`ProductLifecycleCoordinator.generated` wired to those same registries and store,
`InferenceContextComposer` over the same extension registry, and retained
`ChatStrategyPlugin`. By default it statically activates Chat, root-level AGENTS.md,
Filesystem Tools, Search Tools, and Command Tools in process. This is an implicit
stock composition, not plugin discovery or a profile/configuration API.

The normal Stateful `AdeleApplication` constructs its runtime once synchronously
in `initState`, not during rebuilds. It awaits close on desktop exit requests and
initiates cleanup on detach/dispose, reporting failures through `FlutterError`.
Runtime close shares one completion across callers and retires owned activations
in reverse order. `app/lib/core/resource_cleanup.dart` supplies `closeResources`,
shared with development teardown: every action is attempted before the first
error is rethrown with its stack.

The shell displays `No Project is open`. Normal startup does not launch providers
or a backend host, compile AOT artifacts, load credentials, create a Project,
Task, Environment, or Session, build a tool catalog, or start a Run. Normal
provider/model configuration, Project selection, Task/Environment establishment,
Chat UI, and the Run product flow remain deferred.

Development/self-hosting owns an `AdeleRuntime` instance instead of duplicating
these registries, lifecycle, composer, Chat, and activations. Its surrounding
topology/runner retains AOT compilation and host ownership, provider activation,
isolated Git source, Project/Task/Environment/Session establishment, tool catalog,
model selection, development IDs, execution, and evidence. The model capability
adapter remains under `app/lib/development/agent`; normal composition has no
dependency on development code.

Host implementations are split into small pure-Dart packages where Flutter is not required:

| Package | Maintained/planned responsibility |
| --- | --- |
| `plugin_runtime` | Plugin lifecycle/runtime coordination, backend connections, and active capability routing adapters |
| `plugin_builder` | Source resolution, contract checks/generation coordination, backend/frontend builds, diagnostics, provenance, and caching |
| `plugin_backend_host` | Shared child-process entrypoint and one external AOT isolate group per active plugin backend |
| `agent_kernel` | Provider-neutral Run/model/tool semantics, interruptions, policy boundary, structured outcomes, and typed execution observation |

These are internal packages. Plugins must not import them.

The source-plugin runtime shape is:

```text
Flutter desktop host (main Flutter isolate)
  |
  +-- interpreted frontend from flutter_eval/dart_eval bytecode
  |
  +-- generated typed asynchronous transport
  |
  +-- one shared child dartaotruntime process
        |
        +-- one native Dart AOT isolate group per active plugin backend
```

This shape is proven only on Linux x64 Flutter profile mode. Direct external AOT loading inside stock Flutter failed. Backend process/isolate separation is not a security sandbox.

Contract source can be shared by plugin frontend/backend packages. Generated transport hides ports, serialization, request IDs, stream protocol, cancellation, dispatch, and structured transport errors behind typed proxies/dispatchers. Values crossing runtime boundaries are reconstructed rather than shared by identity and should normally be immutable snapshots.

## Recursive plugin extension direction

ADELE's accepted long-term model is recursively extensible:

```text
ADELE core
    -> typed extension points
        -> plugins
            -> plugin-defined typed extension points
                -> other plugins
```

The broad rules are recorded in [`plugin-extension-model.md`](plugin-extension-model.md) and ADR 0030.

Core owns durable shared identities/invariants and host infrastructure. Plugins provide much of the concrete product behavior. Plugins may publish deliberately public extension APIs for concepts they own, and other plugins may implement those interfaces without depending on one specific implementation plugin being active.

Runtime composition should prefer typed interface discovery over hidden activation dependencies. Zero/one/many compatible registrations may be valid depending on the extension contract.

Capabilities remain the implemented callable-provider mechanism for Actions and Services. Events are read-only fact notifications. Other extension points may collect UI fragments or structured operation contributions without being callable capabilities.

The generic `ExtensionRegistry` supports typed registration/discovery, retirement, and exact binding liveness. Current model-tool, orchestration-strategy, and inference-context-source points reuse it with their own composition semantics; already-resolved bindings do not migrate to replacement generations. Instruction-source data becomes independent of binding liveness after safe capture, unlike executable work.

Broader recursive composition, plugin-defined UI extension APIs, generic Event subscription, Commands/keybindings, and inference composition beyond instruction material remain direction rather than implemented production systems.

## Contracts, capabilities, and providers

Contracts answer how typed communication crosses a runtime boundary. Capabilities answer which compatible provider handles a callable semantic request. Extension points are the broader architecture for typed plugin participation.

Implemented capability resolution is one-to-many. Several plugins may provide the same Action/Service, and one plugin runtime may expose multiple configured instances. The host-owned active registry implements provider discovery/enumeration, deterministic rank-based default resolution, explicit selection, exact-major matching, and exact generation-bound routing.

The rank-based default is a deterministic development fallback, not the final preference system. ADELE owns preferred-provider selection; future profile/project/user policy may select contextual defaults and expose explicit alternatives.

Configured capability instances such as `OpenAI Work` and `OpenAI Personal` are distinct from plugin installations/runtime instances. Temporary documents, terminals, browser sessions, and processes are runtime resources rather than configured providers.

See [`contracts-and-capabilities.md`](contracts-and-capabilities.md).

## Core product-domain direction

ADR 0031 accepts the following long-term shared domain identities:

```text
Project
└── Task
    ├── Environment(s)
    └── Session(s)
        ├── Run(s)
        └── child Session(s)
```

### Project

Project is an abstract core identity/lifecycle concept, not intrinsically a local directory. The expected stock development composition uses a local-directory `ProjectSelector`; future selectors may use recent projects, databases/catalogs, or remote/cloud systems.

### Task

Task is the durable ADELE-owned unit of user intent. Plugins may attach state and behavior without owning Task identity. Task workflow category/status remains user/domain-owned rather than being inferred automatically from execution success.

### Environment

Environment is initially the practical filesystem/source + process context used by Task work. A Git worktree-backed Environment may isolate source changes without isolating ports/databases/caches/etc.; Docker or remote providers may have different properties. ADELE does not claim stronger isolation than the selected provider actually supplies.

A separate first-class Workspace concept is not currently required architecture. It may return later if concrete requirements demonstrate an independent semantic identity.

A Task normally has one primary Environment and may own additional Environments for delegated child Session work.

### Session and Run

Session is a core identity/lifecycle container permanently bound to one orchestration strategy. Core does not assume every Session is chat history; strategy-specific state defines the Session's semantic contents.

The implemented `adele_product` value is final and immutable:
`Session(id, taskId, strategyId)`. The semantic `OrchestrationStrategyId` also lives
in product so product does not depend on orchestration. Public pure-Dart
`adele_orchestration` defines
`OrchestrationStrategyContribution(strategyId, materialize)`, the typed
`orchestrationStrategyContributions` extension point, and thin
`OrchestrationStrategyResolver.resolve(id)` over the existing `ExtensionRegistry`.
It also supplies the narrow public execution facade, not a second registry or a
new public package. Canonical Session contains no live binding, Environment
authority, or Chat history.

`ProductLifecycleCoordinator.createSession` requires `taskId` and `strategyId`
and accepts an optional `environmentId`. It validates the existing Task, exactly
one current strategy contribution, and the Task's primary or explicitly selected
same-Task Environment. It then allocates `SessionId`, atomically publishes the
canonical Session and separate Task/Environment authority, and returns `Session`.
Failed validation publishes neither value. Publication is private; there is no
public `associateSession` operation. `store.session(id)` reads the canonical value,
while `requireSessionAuthority` remains the tool-host authority read path.

`coordinator.resolveSessionStrategy(sessionId)` resolves the canonical Session's
stored strategy ID. Zero matches produce an explicit unavailable error; multiple
matches produce an explicit ambiguous error even under different `ExtensionId`
values.
`ResolvedOrchestrationStrategy` retains the exact `ExtensionBinding`; retirement
makes it fail with generic `StaleExtensionBinding`. Only fresh resolution may use
a replacement registration, with no fallback or rewrite of the stored strategy
ID. The permanent semantic binding is not a lifetime activation-generation pin.

Run remains the core unit of execution inside a Session. Stock Chat owns
`ChatSessionStore.obtain(SessionId)` and retained in-memory `ChatSessionState`.
Immutable snapshots contain `ChatEntry` values (`ChatUserMessage` and
`ChatAssistantMessage`); only user/final assistant messages are canonical and
reused across Runs. Intermediate model/native output, proposals, and tool
results are Run-local replay. Instructions and a positive invocation budget are
Chat-owned configuration snapshotted per materialized Run, not product Session
fields. Chat UI/persistence, strategy defaults/profiles, and lifecycle UI remain
deferred.

The accepted direction allows child Sessions for delegated work. They may share an Environment or use another Task-associated Environment and are primarily surfaced through the parent Session/orchestration experience. Child Session lifecycle remains deferred.

## Agent execution

`agent_kernel` remains an internal provider-neutral execution substrate. Concrete models, tools, editors, SCM integrations, terminals, orchestration strategies, and presentation belong outside the kernel.

`plugins/chat_strategy` contains the first executable stock strategy,
`chat_strategy_plugin`. `ChatStrategyPlugin.activate` follows the in-process
stock tool convention with semantic ID `dev.adele.strategy.chat`, distinct from
plugin ID `dev.adele.plugin.chat-strategy` and extension ID
`dev.adele.plugin.chat-strategy.orchestration`. The private Chat loop owns bounded
sequential proposal batches, approval/rejection continuation, and invocation
budget behavior. A final-slot proposal batch fails before preparation/execution
because it has no continuation slot. This is not concurrent tool execution or a
general workflow system.

`createSessionOrchestrationRun` in `app/lib/core/orchestration_host.dart` looks up
the canonical Session, resolves its exact contribution once for the Run, and
materializes against `KernelOrchestrationHost` via
`OrchestrationStrategyHostContext(session, host)`. The callback returns
`OrchestrationExecution` with `start` and `resolveApproval`.
`SessionOrchestrationRun` retains that exact binding/execution and exposes
internal Run/tool/journal evidence only to application callers.

The public `OrchestrationExecutionHost` exposes lifecycle operations and binding
validation, `invokeModel(StrategyInferenceMaterial)`, `processProposal` using an
opaque `StrategyToolSnapshot` and `ProviderToolProposal`, and approval resolution
returning semantic continuation. Host validation covers subsequent operations,
approval resume, and asynchronous settlement. Stale active Runs fail explicitly
and do not migrate; a later Run in the same Session can freshly resolve B under
the unchanged strategy ID. Already-started effects are not rolled back by
retirement.

`invokeModel` returns a collected `StrategyModelTurn` with ordered output,
settlement/metadata or failure, and the opaque tool snapshot. The host accepts
only unused proposals from that exact completed turn. Approval continuation
applies only the current host-supplied resolution to its retained invocation;
Chat cannot manufacture approval or substitute a tool generation.

Minimal semantic input/output, native-envelope, proposal/failure,
settlement/metadata, and approval DTOs live in public `adele_orchestration` and
are reused by the kernel. `SemanticModelRequest`, model ports/streams/collectors,
tool catalogs, policy, `AgentRun`, and the journal remain internal. Neither the
public package nor Chat depends on the kernel. The kernel has no Chat history
port or generic `ContextAssembler`; the Session/context types in ADR 0022 are
historical proof details, not current kernel APIs.

Self-hosting uses its `AdeleRuntime`'s retained Chat, obtains Session state and
appends the prompt, then routes `SessionId` through lifecycle and the core host.
The app no longer has `simple_tool_loop_strategy.dart` or
`development_strategy_registration.dart`;
`development_agent_support.dart` contains only policy.

The kernel model boundary is streaming-shaped. The common ModelProvider transport supports generated streaming/cancellation, ordered semantic input/output, live observations, terminal settlement, and provider-native item metadata. Materialized model/tool bindings remain exact-generation bound.

Tool availability, materialization, policy, optional approval interruption, execution, progress, structured outcome, and effect certainty remain distinct.

The implemented inference path starts with `StrategyInferenceMaterial`, containing
instructions and ordered `SemanticModelInputItem` values from Chat history
projection plus Run-local replay. `InferenceContextComposer` in public
`adele_orchestration` discovers `inferenceContextSources` over the same existing
`ExtensionRegistry` for every new inference, including Chat continuation. It
captures instruction-only material into immutable `InferenceContextSnapshot`
groups and source results without changing semantic input. Strategy instructions
come first, then lexicographic source `ExtensionId` order with local order
preserved; sorting is not semantic authority and there is no numeric priority.

Exact source binding validation brackets snapshot/copy/validation, including
duplicate source-local keys, before data is committed. Required failure stops
before invocation identity, model-start evidence, or provider work; optional
failure omits the entire source with original diagnostics, distinct from
successful empty output. No replacement is tried in the same capture. Captured
data survives later source retirement; source freshness is source-owned without a
generic refresh API. Executable strategy/tool binding rules are unchanged.

The fresh app source context uses canonical Session and existing typed Environment
authority. The host constructs internal
`SemanticModelRequest(context, invocationId, tools)`.
The current `ModelProviderCapabilityAdapter` calls orchestration's
`renderInferenceInstructions` to lower groups to the unchanged provider instructions
string, preserving zero-source bytes. Model/tool/policy and Environment selection
are unchanged; Chat activates no source and remains AGENTS-unaware.

`AdeleRuntime` activates the first stock source, `agents_md_plugin` under
`plugins/agents_md`, in normal startup and development/self-hosting. Activation
alone does not read a file. Each snapshot rereads root `AGENTS.md`
through `AuthorizedEnvironmentFileReadFacet` in the Session-authorized Environment.
Missing (`not_found`) and blank files are successful empty results; other
read/service/authority errors abort the required source. Nonblank exact text and
its opaque Environment revision remain one material, separate from stable
plugin-owned semantics giving explicit user instructions and direct requests
precedence over AGENTS.md guidance. This adds no generic context infrastructure
or ownership over Skills, roles, or repository maps.

Broader inference preparation should use structured composition rather than
arbitrary request mutation. Agent policy, model routing, orchestration/history,
context, tool availability, and other plugins may contribute typed material into
provider-neutral buckets whose resolution produces a stable invocation snapshot.
These additional buckets remain deferred, as do Reference/Observation material,
other context sources, provider-aware projection/cache planning, budgets, and
compaction. Nested/scoped AGENTS.md, `AGENTS.override.md`, alternate names,
global/home files, imports, and AGENTS.md caching remain deferred.

See [`agent-kernel-semantic-model.md`](agent-kernel-semantic-model.md).

## Expected stock development composition

The default development UX is expected to be produced by a stock plugin/configuration set rather than by hard-coded ADELE core behavior. Directional stock responsibilities include:

- Local Directory Project Selector;
- Task Browser;
- Git/Worktree Environment provider;
- Agent Interaction + Chat strategy;
- Agent Configuration/Policy;
- Model Routing/Control;
- Context Monitoring/Compaction;
- AGENTS.md instruction source (root-only, activated by the shared runtime today);
- Accounting/Usage/Quota;
- Filesystem/Search/Command/TODO/Plan tools;
- Diff/Review;
- Internal Source Editor;
- Console/Terminal;
- OpenAI provider.

The detailed, deliberately speculative decomposition is in [`stock-plugin-direction.md`](stock-plugin-direction.md). The UX manifestation is in [`../mockups/README.md`](../mockups/README.md).

These documents are not implementation claims. The current app shell remains minimal and most listed plugins do not exist yet.

## Profiles, configuration, commands, and workbench state

Profiles are accepted as sparse named composition layers. One context may eventually use an ordered stack such as `Developer + Work`. They may contribute activation decisions, ordinary configuration overrides, provider availability, and provider preferences.

Normal startup and development/self-hosting reuse one implicit static stock composition, not a profile API. General profile/configuration persistence, UI, and provider preference resolution are not implemented.

Activation, ordinary configuration, provider preference, security/policy, workbench state, configured capability instances, and runtime state remain distinct domains.

An effectively disabled plugin should remove its normal product/settings surface without deleting dormant persisted configuration.

Core is expected to own application Commands, Command Palette/search, keybinding resolution, plugin-suggested defaults, and user rebinding. Those systems are architectural direction and are not yet a maintained production subsystem.

Workbench extension APIs should be semantic rather than physical. Concepts such as Main Content, Session Status, Inspection, Navigation, and Stream/Console presentation should remain stable if the physical layout moves or becomes configurable.

See [`profiles-and-configuration.md`](profiles-and-configuration.md) and [`plugin-extension-model.md`](plugin-extension-model.md).

## Maintained self-inspection vertical

`dev.adele.openai` implements the public OpenAI API-key Responses HTTP/SSE route with `store:false` canonical ordered replay. The same plugin generation exposes API-key and ChatGPT configured instances through separate generation-bound contexts. The ChatGPT subscription-backed route remains explicitly experimental interoperability evidence.

The stock Search Tools plugin contributes literal `search` and composes only the Session-authorized Environment filesystem's read facet; Filesystem Tools independently contributes revision-bearing `read_file`, exact-unique `apply_patch`, create-new-only `create_file`, and revision-conditional `delete_file` over coherent read and mutation facets. Command Tools contributes direct-argv `run_command` over only the Session-authorized process facet. The OpenAI API-key and experimental ChatGPT source-coding consumers use the read/search tools rather than the retired Phase IV DevelopmentSource capability, and a separate API-key smoke exercises `read_file` and `apply_patch` without relying on Search.

Deterministic inspection integration uses the real shared AOT host, OpenAI
plugin, Git Environment provider, Project/Task/Environment lifecycle, Session
authority, generic extension/model-tool composition, stock tools, and
Session-routed Chat. Only remote model responses come from a local fake Responses
endpoint. Coverage exercises recursive source discovery, model-visible
Search-to-Read flow, and continuation. Separate deterministic sequences exercise
Read-to-Patch mutation, direct `git diff --check` validation through
`run_command`, and `create_file` -> `read_file` -> `delete_file` with model-visible
revision provenance and final Task/Project/checkout isolation. Generation
coverage checks that fresh tools replace retired Search-tool and
Environment-provider bindings while old tools remain stale.

Recorded opt-in live API-key and experimental ChatGPT evidence covers read/search,
real-model existing-file edit, direct-argv command validation, continuation, and
isolation. Paid live services have not been rerun against the current
deterministically validated Chat path. No paid create/delete smoke is claimed.

The bounded vertical covers self-inspection, conditional mutation, and
command-backed validation. It does not establish stable ChatGPT/OpenAI
third-party support, general filesystem mutation, production readiness, or full
self-hosting.

## Remaining runtime validation

| Risk | Current status |
| --- | --- |
| Local backend AOT compilation | Proven with the temporary matched SDK. |
| Shared process-host loading | Proven on Linux x64 profile mode. |
| Eval compilation/rendering | Proven with pinned eval dependencies and documented workarounds. |
| Generated typed communication | Proven across maintained unary and streaming plugin contracts. |
| Typed streaming/cancellation | Proven through generated transport and ModelProvider with one-item flow control. |
| Active capability/configuration routing | Proven for deterministic discovery, explicit selection, exact generations, and separate OpenAI configuration contexts. |
| Real OpenAI provider | Deterministic HTTP/SSE/shared-AOT integration proven; live network tests remain opt-in. |
| Experimental ChatGPT configured instance | Auth/routing tests, an opt-in read/search smoke, and an opt-in subscription-backed mutation/command/continuation smoke using the maintained classic Responses fallback provide interoperability evidence only. |
| Model-to-source continuation | Read/search is proven through deterministic OpenAI integration and opt-in live API-key/experimental ChatGPT evidence. Deterministic integration and opt-in API-key plus experimental ChatGPT validation smokes prove model-visible `read_file` opaque-revision-to-`apply_patch` continuation for conditional existing-file mutation in the Task worktree, direct-argv `run_command` validation, continuation from its model-visible exit result, and Task/Project/checkout isolation. Deterministic integration also proves model-visible create/read/delete revision flow and final filesystem isolation. Broader filesystem administration remains unproven. |
| Rebuild/reload | Proven for three cycles without orphan host processes. |
| General recursive extension system | Accepted architecture; not implemented. |
| Project/Task/Environment product model | Initial values, Task establishment, Git Environment materialization/restoration, Session-authorized read/mutation/process facets, bounded create/patch/delete text-file mutation, and generated foreground process streaming through the Git provider are proven; persistence and complete lifecycle remain unimplemented. |
| Session-bound strategy execution | Canonical immutable Session creation, atomic publication with separate Environment authority, executable contributions, explicit unavailable/ambiguous resolution, and exact binding validation across Run operations/resume/settlement are implemented and deterministically validated. Headless Chat uses the public facade with validated state, sequencing, and application integration. Persistent strategy state, child Sessions, and disk persistence remain deferred. |
| Inference context | Instruction-only source discovery, exact-binding capture, immutable snapshots, current adapter rendering, and the stock root AGENTS.md source activated by the shared runtime are implemented; other sources, broader material, provider-aware projection/cache planning, budgets, and compaction remain deferred. |
| Production orchestration/UI/Commands | Headless stock Chat is implemented; production UI, Commands, and discovery remain directional. |
| Cross-platform/release | Unproven on Windows, macOS, and release mode. |
| Packaging/sandboxing | Unproven; process isolation is not a sandbox. |

The long-term goal remains for ADELE to develop ADELE itself. That goal does not change the preference for small working boundaries over speculative framework implementation.
