# ADR 0031: Project, Task, Session, and Environment domain direction

## Status

Accepted; in-memory Session strategy binding spine and Environment-authorized tools implemented, broader lifecycle deferred

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

Plugins provide ways to select/associate concrete Projects. The stock development composition is expected to provide a local-directory `ProjectSelector`, while future selectors may use recent-project lists, databases/catalogs, cloud services, or other sources.

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

A strategy plugin will consume a narrow public provider-neutral execution API backed internally by ADELE's execution substrate. Strategy implementations must not import the internal `agent_kernel` package directly. The identity-only registration/binding API is implemented in `adele_orchestration`; the public execution facade and its exact methods/types remain deferred until a concrete strategy implementation requires them.

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

- `adele_product` owns immutable Project, Task, and Environment values, including generic provider identity and opaque provider state. It also owns the one canonical `SessionId`, semantic `OrchestrationStrategyId`, and the final immutable `Session(id, taskId, strategyId)`. The strategy ID lives in product to keep product independent of orchestration. `Session` stores no live binding, Environment authority, or strategy-specific history.
- Public pure-Dart `adele_orchestration` owns immutable identity-only `OrchestrationStrategyContribution`, the typed `orchestrationStrategyContributions` extension point, and a thin `OrchestrationStrategyResolver.resolve(id)` over the existing `ExtensionRegistry`. It does not introduce a second registry, materialization cache, or execution API.
- Resolution returns a `ResolvedOrchestrationStrategy` retaining the exact `ExtensionBinding`, or throws `OrchestrationStrategyUnavailable` or `AmbiguousOrchestrationStrategy`. Duplicate semantic IDs are ambiguous regardless of distinct `ExtensionId` values. Retired bindings fail with generic `StaleExtensionBinding`; a replacement is eligible only for fresh resolution, without fallback or rewriting the stored strategy ID.
- `ProductLifecycleCoordinator.createSession` requires an existing `taskId` and a currently resolvable `strategyId`, and accepts an optional `environmentId`. The selected Environment must exist and belong to that Task; omission selects the Task's primary Environment. It then allocates `SessionId`, revalidates the retained strategy binding, atomically publishes the canonical Session and separate Task/Environment authority, and returns the `Session`. Failure publishes neither Session nor authority. Publication is private; there is no public `associateSession` operation.
- `store.session(id)` reads the canonical product value, while `requireSessionAuthority` retains the existing authority read path. `coordinator.resolveSessionStrategy(sessionId)` resolves the stored canonical Session's strategy ID, not a caller-supplied replacement.
- Development composition registers temporary metadata under `dev.adele.strategy.development-tool-loop` with a separate extension ID. The bounded `DevelopmentToolLoopStrategy` remains app-owned and unchanged; direct execution is not routed through registration. `agent_kernel` still consumes/re-exports the canonical `SessionId` and retains the separate Chat-shaped development history used by the Phase IV proof.
- The application has an in-memory Task establishment coordinator that publishes a Task and finalized primary Environment and records the exact establishment-time materialization only after provider success; disk persistence remains deferred.
- `adele_environment` and the stock Git worktree backend prove establishment, restoration, bounded filesystem reads, opaque observed-file revisions, create-new text files, conditional existing-text-file replacement and deletion, component-local value reification, and exact-generation rebinding. Filesystem Tools owns the model-facing create/patch/delete semantics and lowers them to those provider-neutral primitives.
- The application owns one authoritative `SessionId -> TaskId + EnvironmentId` relation, separate from the canonical Session, and uses it to materialize coherent read, mutation, and process facets for independently contributed `search`, `read_file`, `apply_patch`, `create_file`, `delete_file`, and `run_command` tools. Run and generic tool context do not independently select Environment; Search requests only the read facet and Command Tools only the process facet.
- Deterministic agent Runs prove Search-to-Read, Read-to-Patch, and Create-to-Read-to-Delete continuation against real copied ADELE source through a real Git Environment. Mutation proofs obtain opaque revisions and source content from model-visible tool results, affect only the Task worktree, and verify final create/delete isolation. Integration coverage also proves old tool bindings remain stale while fresh access restores the durable Environment through a replacement provider generation.
- The binding spine does not add a Chat plugin, public strategy execution facade, kernel redesign, strategy-specific durable state, child Session lifecycle, context redesign, strategy defaults, profiles, Task Browser or other lifecycle UI, or disk persistence. Complete Session lifecycle and restoration remain deferred.
- Phase V-A5 migrated the OpenAI API-key and experimental ChatGPT source-coding consumers to the Session-authorized Environment tool composition and retired the provisional DevelopmentSource plugin.

The current implementation remains valid evidence for the narrower vertical. Future APIs should migrate toward this accepted direction as concrete features are built.

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

ADR 0022 remains authoritative for the Phase IV-A execution semantics it implemented, including Run lifecycle, context assembly boundaries, tool materialization, policy/approval, generation binding, outcomes, and execution observation. This ADR supersedes only its long-term claim that every Session fundamentally owns canonical user/assistant entries/conversational history.

ADR 0029 remains authoritative for ordered profile/configuration direction. This ADR resolves the Project/Workspace identity uncertainty ADR 0029 explicitly left deferred.
