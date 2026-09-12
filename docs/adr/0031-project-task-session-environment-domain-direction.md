# ADR 0031: Project, Task, Session, and Environment domain direction

## Status

Accepted; B1 Project opening, B2 normal Task/primary Environment creation, in-memory Session-bound execution, headless stock Chat, Environment-authorized tools, and instruction-context capture implemented, broader lifecycle deferred

Partially supersedes ADR 0022 for long-term Session semantics.

Resolves Project/Workspace identity questions left deferred by ADR 0029.

## Context

ADELE's Phase IV execution proof intentionally used a chat-shaped `Session` containing canonical user/assistant entries and separately discussed `Workspace` as source-mutation scope versus `ExecutionEnvironment` as broader effect/process scope. Those boundaries were useful while proving the agent kernel, but later product design clarified that they are too specific or speculative for the long-term application model.

Different orchestration strategies may define materially different Session state. A conventional Chat strategy may own messages, reasoning/tool activity, drafts, forks, and compaction state. A Goal strategy may instead own goals, iterations, evaluations, and strategy-specific progress. Canonical chat history therefore cannot be the universal definition of Session.

Likewise, ADELE currently has concrete need for one practical execution/source context but does not yet have concrete semantics for independently isolating every process, port, database, cache, credential, or external service. Keeping separate first-class Workspace and ExecutionEnvironment product concepts would prematurely encode isolation distinctions that have not yet been demonstrated by real product needs.

Project also needs to remain more general than the stock local-directory UX, and Task needs a stable identity that plugins can enrich without owning.

Because Session-to-strategy binding is a core lifecycle invariant, core must also be able to create and restore Sessions without depending on an optional UI plugin being active. Strategy implementations may remain plugins, but the minimal strategy registration/discovery/binding contract cannot itself belong only to a presentation plugin.

## Decision

ADELE adopts the following long-term product-domain direction.

### Project

`Project` is a core ADELE identity/lifecycle concept. It is not intrinsically a filesystem directory.

Plugins provide ways to select/associate concrete Projects. B1 supplies a stock
local-directory `ProjectSelectorContribution` that returns only a source URI;
the app invokes core lifecycle to create the canonical Project. Future selectors
may use recent-project lists, GitHub, databases/catalogs, cloud services, or other
sources without changing Project identity.

### Task

`Task` is a core ADELE-owned durable unit of user intent.

Plugins may associate state and behavior with a Task without redefining Task identity. The Task/Session browsing UI is itself expected to be a plugin.

Task workflow category/status remains user/domain-owned and must not be inferred automatically from Run success or TODO completion.

### Environment

ADELE uses one core `Environment` concept for the practical source/execution context in which Task work occurs.

The initial useful Environment surface is expected to include filesystem/source access and process execution. Stronger or additional isolation concepts should be added only when concrete application needs make their semantics clear.

ADELE does not claim that every Environment isolates all runtime resources. A Git worktree-backed Environment isolates source state but does not inherently isolate ports, databases, caches, credentials, or external services. Docker or remote-VM providers may provide different isolation properties.

The earlier separate first-class `Workspace` concept is therefore not retained as required product architecture at this time.

A Task normally has one primary Environment. It may own additional Environments for delegated/parallel child Session work.

Environment implementations are expected to be supplied by interchangeable providers whose lifecycle may include establishing, validating/reconnecting, releasing live resources, restoring when possible, and explicit destruction as concrete providers require.

Core Task lifecycle—not presentation such as Task Browser—coordinates establishment/association of the Task's primary Environment through the selected/default Environment provider.

### Session

`Session` is a core ADELE identity/lifecycle container permanently bound to one orchestration strategy.

Core must not define Session as inherently chat history. The bound strategy owns the semantic structure of strategy-specific Session state.

Changing orchestration strategy means creating another Session rather than converting an existing Session into another semantic type.

Permanent binding is to a semantic `OrchestrationStrategyId`, not to an `ExtensionId` or one activation generation. Creation requires exactly one current contribution for that semantic ID. Zero matches produce an explicit unavailable error; multiple matches produce an explicit ambiguous error even if their extension IDs differ. There is no default or fallback strategy selection in this binding path.

A resolved strategy retains its exact `ExtensionBinding`. Retirement makes that binding stale; replacement registrations can be used only through fresh resolution of the same stored strategy ID. Existing resolved bindings never migrate, and availability changes never rewrite the Session's durable identity fields.

Core owns the minimal public orchestration-strategy registration/discovery/binding contract required to create, restore, and validate Sessions. Strategy implementations are plugins, but Session validity must not depend on an optional Agent Interaction or other presentation plugin being active.

A strategy plugin consumes the narrow public provider-neutral execution API in `adele_orchestration`, backed internally by ADELE's execution substrate. `OrchestrationStrategyContribution(strategyId, materialize)` materializes an `OrchestrationExecution` from `OrchestrationStrategyHostContext(session, host)`. The execution supplies `start` and `resolveApproval`; the host owns lifecycle, model invocation, proposal processing, approval authority, and exact-binding validation. Strategy implementations and public packages must not import the internal `agent_kernel` package. The first concrete consumer is headless stock Chat, not a presentation plugin or a general workflow framework.

One Run retains one exact strategy binding. Host validation covers subsequent operations, approval resume, and asynchronous settlement. If binding A retires, the old active Run fails explicitly instead of adopting B; a later Run in the same Session can freshly resolve B under the unchanged semantic strategy ID. This does not promise rollback or cancellation of effects already in flight.

A Session may create child Sessions for delegated work. A child Session:

- remains associated with the same Task;
- may share its parent's Environment or use another Task-associated Environment;
- may use another orchestration strategy;
- may receive a handoff/initial context;
- may be inspectable without being directly user-steerable;
- is primarily surfaced from its parent Session rather than flattened into normal top-level Task Browser navigation.

Core owns authoritative Session creation/parent linkage/strategy binding. Orchestration plugins may expose that core operation as a model tool.

### Run

`Run` remains the core unit of execution within a Session as established by the agent-kernel architecture. This ADR does not change generation-bound model/tool execution invariants, interruption semantics, tool outcomes, or policy boundaries.

## Implementation status

The maintained repository does **not** yet implement this complete product-domain model.

- `app/lib/core/adele_runtime.dart` owns the shared capability/extension registries, in-memory product store, generated lifecycle coordinator, inference context composer, retained Chat plugin, and six static in-process activations: Chat, AGENTS.md, Filesystem, Search, Command, and Local Directory Project Selector. All use the same extension registry and retire in reverse order; reduced composition omits only Command Tools. `AdeleRuntime()` remains synchronous and provider-free and owns pure-Dart `ApplicationPluginBootstrap` on the same capability registry, without starting it from the constructor.
- Normal `AdeleApplication` constructs one runtime and explicitly calls async `bootstrapStockBackendPlugins`. The generic bootstrap owner starts one `PluginBackendHost` and invokes composition-supplied activator callbacks, leaving room for later OpenAI on the same host boundary. Its states are `unconfigured`, `starting`, `ready`, `failed`, `closing`, and `closed`. Startup failure cleans up acquired resources before reporting the original error; the app shows unavailable/failure state without blocking Project opening. Application close immediately marks the window closing and drains pending Task establishment before `runtime.close`, even if establishment fails. Late UI updates remain ignored. This avoids bounded host shutdown interrupting real worktree creation, without cancellation or rollback. Runtime close retires backend capability registrations before closing connections, then the host, then the in-process activations, attempting every cleanup action.
- Stock bootstrap consumes only compile-time `ADELE_DARTAOTRUNTIME_EXECUTABLE`, `ADELE_BACKEND_HOST_ARTIFACT`, and `ADELE_GIT_ENVIRONMENT_ARTIFACT`; no configuration means unavailable Task Environment support. Normal Linux repository `run`/`build` prepare fresh host/Git AOT snapshots in isolated retained source-checkout directories before the Flutter run/build invocation, using `plugin_builder.compileAotSnapshot`, and pass those three defines. No source paths/compiler belong to app startup. Embedded absolute artifact/runtime paths are provisional and runnable only on that machine while artifacts and SDK remain in place, not caching, installation, portable/production packaging, discovery, or profiles.
- `app/lib/plugins/stock_git_environment.dart` owns stock plugin/provider IDs, display/service exposure, and default configuration-context registration shared by normal and self-hosting paths, without importing backend implementation code. Self-hosting owns its larger artifacts/host/provider and product/Run topology independently of normal configuration. Normal startup activates no model provider, loads no model credentials, and creates no Project/Task/Environment/Session, tool catalog, or Run.
- B1's tiny pure-Dart `adele_core_extensions` imports only `adele_plugin_api` and defines `ProjectSelectorContribution` with only `String displayName` and `Future<Uri?> Function() selectProject` at typed `projectSelectorContributions` (`dev.adele.extension.project-selectors`). Its ownership is core extension contracts with no natural existing public domain package, not a catch-all; existing registry/product/orchestration/tool/Environment and plugin-ecosystem ownership remains unchanged. `adele_product` gains no dependency or derived Project metadata.
- `AdeleApplication.build` discovers zero, one, or multiple independent selectors; the existing themed ADELE shell shows `No Project is open` and one button per contribution in deterministic registry registration order, or an unavailable state for zero. There are no priorities, defaults, categories, applicability rules, or chooser framework. Buttons are disabled during selection; `null` is cancellation and creates nothing. For a non-null URI, the app validates the retained exact binding after asynchronous selection, then calls `runtime.lifecycle.createProject`, which publishes and returns the canonical Project. Selector/lifecycle failure is inline, with no fallback or change to the presented Project; late results after disposal/exit are ignored.
- The canonical returned Project is retained in window-local `_project` on app State, never `runtime.currentProject`. The shell shows a URI-derived leaf name (fallback host/URI), source URI, `Project is open`, and initially `No Tasks yet`. These buttons are temporary presentation, not Command surfacing or Task Browser. Opening starts no Task, Environment, Session, model, tool catalog, or Run work and does not trigger backend activation. It adds no Project persistence, catalog, or deduplication. GitHub/cloud/catalog selectors remain future possibilities, not implementations.
- B2 adds private title-only inline Task presentation with Cancel/Create, blank-title validation, pending duplicate protection, and inline errors retaining input for retry. It calls `runtime.lifecycle.createTask(projectId: ..., title: ...)` with no provider ID. The existing capability registry default remains descending rank then ascending provider identity, not a new multiple-provider ambiguity rule. Selected providers own source validation, including non-Git rejection; neither Project selector nor Task form owns Git logic. Only lifecycle success presents the returned canonical Task/Environment in window-local State. Late UI completion after disposal/exit is ignored. This creates no Session, Chat state, model/tool catalog, or Run.
- B2 displays Task title, Environment identity, and live exact-binding readiness, without parsing opaque `providerState` or restoring/migrating a generation merely to render. Missing config/startup failure makes Task creation unavailable, but Project opening remains usable. General provider/model configuration, Task Browser, Session/Chat UI, and the Run product flow remain deferred.
- `adele_product` owns immutable Project, Task, and Environment values, including generic provider identity and opaque provider state. It also owns the one canonical `SessionId`, semantic `OrchestrationStrategyId`, and the final immutable `Session(id, taskId, strategyId)`. The strategy ID lives in product to keep product independent of orchestration. `Session` stores no live binding, Environment authority, or strategy-specific history.
- Public pure-Dart `adele_orchestration` owns `OrchestrationStrategyContribution(strategyId, materialize)`, the typed `orchestrationStrategyContributions` extension point, and a thin `OrchestrationStrategyResolver.resolve(id)` over the existing `ExtensionRegistry`. It extends that same package with the narrow execution facade, not a second registry, materialization cache, or new public package.
- `OrchestrationExecutionHost` supplies `start`/`complete`/`fail`/`validateBinding`, `invokeModel(StrategyInferenceMaterial)`, `processProposal` with an opaque `StrategyToolSnapshot` plus `ProviderToolProposal`, and approval resolution returning semantic continuation. Minimal semantic input/output, native-envelope, proposal/failure, settlement/metadata, and approval DTOs are extracted into this public package and reused by the kernel. Model ports/streams/collectors, tool catalogs, policy, `AgentRun`, and the journal remain internal.
- Resolution returns a `ResolvedOrchestrationStrategy` retaining the exact `ExtensionBinding`, or throws `OrchestrationStrategyUnavailable` or `AmbiguousOrchestrationStrategy`. Duplicate semantic IDs are ambiguous regardless of distinct `ExtensionId` values. Retired bindings fail with generic `StaleExtensionBinding`; a replacement is eligible only for fresh resolution, without fallback or rewriting the stored strategy ID.
- `ProductLifecycleCoordinator.createSession` requires an existing `taskId` and a currently resolvable `strategyId`, and accepts an optional `environmentId`. The selected Environment must exist and belong to that Task; omission selects the Task's primary Environment. It then allocates `SessionId`, revalidates the retained strategy binding, atomically publishes the canonical Session and separate Task/Environment authority, and returns the `Session`. Failure publishes neither Session nor authority. Publication is private; there is no public `associateSession` operation.
- `store.session(id)` reads the canonical product value, while `requireSessionAuthority` retains the existing authority read path. `coordinator.resolveSessionStrategy(sessionId)` resolves the stored canonical Session's strategy ID, not a caller-supplied replacement.
- `createSessionOrchestrationRun` in `app/lib/core/orchestration_host.dart` looks up the canonical Session, resolves its contribution once, and materializes against `KernelOrchestrationHost`. `SessionOrchestrationRun` retains that exact binding and exposes internal Run/tool/journal evidence only to application callers. Core model/tool/policy/Environment selection is unchanged.
- Headless `chat_strategy_plugin` in `plugins/chat_strategy` registers `dev.adele.strategy.chat` using `ChatStrategyPlugin.activate` and existing in-process stock tool conventions, with distinct plugin and extension identities. `ChatSessionStore.obtain(SessionId)` retains `ChatSessionState`; immutable snapshots contain canonical `ChatEntry` values (`ChatUserMessage` and `ChatAssistantMessage`). Only user/final assistant messages are canonical and reused across Runs. Intermediate model/native output, proposals, and tool results are Run-local; Chat-owned instructions and a positive invocation budget are snapshotted per materialized Run.
- Chat owns the private bounded sequential loop extracted from `DevelopmentToolLoopStrategy`, retaining ordered proposal batches, allow/deny/ask behavior, approval/rejection continuation, and final-slot budget semantics. The app's `simple_tool_loop_strategy.dart` and `development_strategy_registration.dart` are absent; `development_agent_support.dart` contains only policy. Self-hosting uses its runtime's retained Chat, obtains state/appends the prompt, and routes `SessionId` through lifecycle and the core host rather than direct loop construction.
- `agent_kernel` consumes/re-exports the canonical `SessionId` but no longer owns `session.dart`/`context.dart`, `SessionEntry`, `UserSessionMessage`, `AssistantSessionMessage`, `SessionSnapshot`, `SessionHistoryPort`, `ContextAssembler`, or `ContextAssemblyInput`. Chat projection plus Run-local replay supplies `StrategyInferenceMaterial` (instructions and ordered semantic input) before the host builds internal `SemanticModelRequest`.
- The application has an in-memory Task establishment coordinator that publishes a Task and finalized primary Environment together and records the exact establishment-time materialization only after provider success. It intentionally retains successful provider state even if the generation retires immediately afterward; stale live readiness does not undo successful publication. B2 changes neither lifecycle settlement nor generation semantics; disk persistence remains deferred.
- `adele_environment` and the stock Git worktree backend prove establishment, restoration, bounded filesystem reads, opaque observed-file revisions, create-new text files, conditional existing-text-file replacement and deletion, component-local value reification, and exact-generation rebinding. Filesystem Tools owns the model-facing create/patch/delete semantics and lowers them to those provider-neutral primitives.
- The application owns one authoritative `SessionId -> TaskId + EnvironmentId` relation, separate from the canonical Session, and uses it to materialize coherent read, mutation, and process facets for independently contributed `search`, `read_file`, `apply_patch`, `create_file`, `delete_file`, and `run_command` tools. Run and generic tool context do not independently select Environment; Search requests only the read facet and Command Tools only the process facet.
- Deterministic agent Runs prove Search-to-Read, Read-to-Patch, and Create-to-Read-to-Delete continuation against real copied ADELE source through a real Git Environment. Mutation proofs obtain opaque revisions and source content from model-visible tool results, affect only the Task worktree, and verify final create/delete isolation. Integration coverage also proves old tool bindings remain stale while fresh access restores the durable Environment through a replacement provider generation.
- `adele_orchestration` now captures instruction-only sources over the existing registry into immutable `InferenceContextSnapshot` for each new inference, including Chat continuation. The fresh app `SessionInferenceContextSourceContext` accepts only canonical Session and explicitly allowlists only `AuthorizedEnvironmentFileReadFacet` through the existing Session -> Task -> authorized Environment -> generation authority path. All other service types are rejected; mutation/process authority remains with the existing tool/policy/execution mechanisms. Semantic input and the provider instructions-string contract are unchanged.
- Required source failure stops preparation before invocation identity/evidence/provider work; optional failure omits the whole source with original diagnostics, distinct from successful empty output. Capture has no replacement fallback; captured data survives retirement without changing executable binding rules. Freshness is source-owned without a generic refresh API; deterministic source order is not semantic authority or numeric priority.
- Shared `AdeleRuntime` composition activates stock `agents_md_plugin` in normal startup and development/self-hosting; Chat activates no source and remains AGENTS-unaware. Activation alone does not read a file. Each snapshot rereads root `AGENTS.md` through the Session-authorized `AuthorizedEnvironmentFileReadFacet`, not a Project or host filesystem fallback. `not_found` and blank files are successful empty results; other read/service/authority errors fail the required source. Exact nonblank text and its Environment revision form one material, separate from stable plugin-owned explicit-user-precedence semantics. Generic instruction-only composition and independent Skills/role/map ownership are unchanged.
- Nested/scoped AGENTS.md, aliases/overrides, global/home files, imports, AGENTS.md caching, other context sources, broader Reference/Observation material, provider-aware projection/cache planning, token budgets, compaction, Chat UI/persistence, child Session lifecycle, strategy defaults, profiles, Task Browser and lifecycle UI beyond B1 Project opening/B2 Task establishment, and disk persistence remain deferred. Complete Session lifecycle and restoration are not implemented.
- OpenAI API-key and experimental ChatGPT source-coding consumers use the Session-authorized Environment tool composition, not the retired DevelopmentSource plugin.

The current implementation remains valid evidence for the narrower vertical. Future APIs should migrate toward this accepted direction as concrete features are built.

ADR 0030 records B1's contribution and headless import boundaries. Native picker
integration, including the minimum macOS read-only user-selected-file entitlement
and generated registrants, and current validation status are maintained in
`docs/architecture/overview.md`.

B2's maintained Linux profile build passed with actual host/Git compilation
before Flutter build, and focused widget/runtime/bootstrap and real-host/Git
integration suites passed. Widget tests cover pending Task draining on application
close; normal startup reached backend readiness under Xvfb without credentials.
Bounded evidence, test/build paths, and source-checkout artifact limitations are maintained in
`app/README.md`.

## Consequences

- Stock local-directory Project behavior is a plugin/default-composition choice, not a core identity rule.
- Plugins can contribute Task summaries, Environment implementations, accounting, TODO progress, SCM state, and other behavior without owning Task identity.
- Chat history becomes strategy-owned state rather than the universal Session model.
- Orchestration strategies can define substantially different Session semantics while sharing core Session/Run lifecycle.
- Core can validate/restore a Session's bound strategy independently of optional strategy-selection/presentation UI.
- Strategy plugins use public provider-neutral execution APIs rather than depending on the internal `agent_kernel` implementation package.
- Child agent work uses parent/child Sessions rather than introducing a speculative Subtask domain object.
- One Environment abstraction can initially cover filesystem/source and process context without claiming stronger isolation guarantees than the provider supplies.
- A separate Workspace concept can be reintroduced later if concrete requirements demonstrate an independent semantic identity that Environment cannot represent cleanly.

## Supersession notes

ADR 0022 records the historical Phase IV-A proof, including its Chat-shaped Session/history port, `ContextAssembler`, and app-owned provisional loop. Those types and ownership claims are not the current kernel API. Its execution invariants remain authoritative: Run lifecycle is distinct from strategy state and input projection, tools are materialized with exact bindings, and policy/approval, outcomes, and execution observation remain separate. This ADR supersedes the universal conversational Session definition; the current implementation places canonical Chat state and sequencing in the Chat plugin and exposes only the narrow public execution/material seam described above.

ADR 0029 remains authoritative for ordered profile/configuration direction. This ADR resolves the Project/Workspace identity uncertainty ADR 0029 explicitly left deferred.
