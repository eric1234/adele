# ADR 0031: Project, Task, Session, and Environment domain direction

## Status

Accepted as architectural direction; product-domain implementation largely deferred

Partially supersedes ADR 0022 for long-term Session semantics.

Resolves Project/Workspace identity questions left deferred by ADR 0029.

## Context

ADELE's Phase IV execution proof intentionally used a chat-shaped `Session` containing canonical user/assistant entries and separately discussed `Workspace` as source-mutation scope versus `ExecutionEnvironment` as broader effect/process scope. Those boundaries were useful while proving the agent kernel, but later product design clarified that they are too specific or speculative for the long-term application model.

Different orchestration strategies may define materially different Session state. A conventional Chat strategy may own messages, reasoning/tool activity, drafts, forks, and compaction state. A Goal strategy may instead own goals, iterations, evaluations, and strategy-specific progress. Canonical chat history therefore cannot be the universal definition of Session.

Likewise, ADELE currently has concrete need for one practical execution/source context but does not yet have concrete semantics for independently isolating every process, port, database, cache, credential, or external service. Keeping separate first-class Workspace and ExecutionEnvironment product concepts would prematurely encode isolation distinctions that have not yet been demonstrated by real product needs.

Project also needs to remain more general than the stock local-directory UX, and Task needs a stable identity that plugins can enrich without owning.

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

- `agent_kernel` has Session/Run identifiers and a chat-shaped development Session history used by the Phase IV proof.
- The provisional application strategy remains a bounded chat/tool loop.
- Core Project/Task/Environment persistence/lifecycle services do not yet exist.
- Environment providers, Task Browser, orchestration-strategy registration, child Session lifecycle, and parent Session presentation are not implemented.
- The DevelopmentSource plugin currently provides a bounded read-only root for the self-inspection vertical; it does not establish final Environment semantics.

The current implementation remains valid evidence for the narrower vertical. Future APIs should migrate toward this accepted direction as concrete features are built.

## Consequences

- Stock local-directory Project behavior is a plugin/default-composition choice, not a core identity rule.
- Plugins can contribute Task summaries, Environment implementations, accounting, TODO progress, SCM state, and other behavior without owning Task identity.
- Chat history becomes strategy-owned state rather than the universal Session model.
- Orchestration strategies can define substantially different Session semantics while sharing core Session/Run lifecycle.
- Child agent work uses parent/child Sessions rather than introducing a speculative Subtask domain object.
- One Environment abstraction can initially cover filesystem/source and process context without claiming stronger isolation guarantees than the provider supplies.
- A separate Workspace concept can be reintroduced later if concrete requirements demonstrate an independent semantic identity that Environment cannot represent cleanly.

## Supersession notes

ADR 0022 remains authoritative for the Phase IV-A execution semantics it implemented, including Run lifecycle, context assembly boundaries, tool materialization, policy/approval, generation binding, outcomes, and execution observation. This ADR supersedes only its long-term claim that every Session fundamentally owns canonical user/assistant entries/conversational history.

ADR 0029 remains authoritative for ordered profile/configuration direction. This ADR resolves the Project/Workspace identity uncertainty ADR 0029 explicitly left deferred.