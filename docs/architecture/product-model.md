# ADELE Product Model

Role: Canonical architecture

Implementation status: Partial

This document defines the shared product-domain semantics and ownership that
ADELE core and unrelated plugins must agree on. It combines accepted constraints
with the current implementation. Project identity/source, Tasks, Environment
records/provider-state snapshots, Sessions, their semantic Environment
associations, and terminal Run records have per-Project SQLite storage. Terminal
public activity snapshots are retained separately under the execution schema owner.
Plugin-owned relational state, including Chat conversation/configuration/plain-text
Draft Request, uses the same backing without becoming core product fields. Live
Run execution remains non-durable. Elsewhere, "durable" describes
semantic lifetime, not a claim that every product feature survives application
restart.

## Core relationship

```text
Project
    |
    v
   Task
    +-- Environment(s)
    +-- Session(s)
            |
            v
           Run(s)
```

The diagram shows relationships, not every ownership boundary, stored field, or
implemented lifecycle operation. Environments and Sessions are associated with a
Task; a Session's authorized Environment is a separate lifecycle relationship.
Shared identities belong to core even when plugins supply most concrete behavior.

## Project

A Project is a stable core product identity and lifecycle concept, not
intrinsically a local directory. Its source or association is represented
generically; the current `Project` in `adele_product` retains a typed source URI,
not a filesystem handle or a Git repository definition.

Project selectors/providers are replaceable plugin behavior. A
`ProjectSelectorContribution` names an explicit `ProviderId` and returns a source
URI or cancellation. The selected `ProjectProviderService` validates/describes
backing; core `ProductLifecycleCoordinator.openProject` loads or creates the
canonical Project. The public contract lives in pure-Dart `adele_core_extensions`,
not in product values or a concrete plugin. Local Directory selection and backing
placement are stock behavior, not Project semantics. Whether the source can
support particular Task work remains the Environment provider's responsibility.

### Project storage

Use ordinary inspectable SQLite with explicit SQL per Project, not opaque
key/value serialization or an ORM. A Project implementation supplies
`ProjectBacking(sourceLocation, databaseRelativePath)`. The relative location is
its placement policy, not a core directory convention; the stock Local Directory
backend chooses `.adele/data.db`. The backing retains the selected source, not an
unrelated location silently substituted by the provider.

The application-private `ProjectDatabase` owns one connection per open Project,
filesystem validation/confinement, migration coordination, and database lifetime. Current
backing support requires an existing absolute local `file:` directory URI
supported on the host; network authorities, query/fragment components, and
unsupported paths fail explicitly. The host resolves the source root and validates
a relative forward-slash file path, rejecting traversal, URI/absolute syntax,
unsafe components, symlinked backing parents/files, and symlinked SQLite sidecars.
Missing backing parents may be created only along that confined path. A provider's
description grants no ambient filesystem authority and exposes no database handle.

The current schema is deliberately small:

| Table | Owner and meaning |
| --- | --- |
| `adele_schema_versions(owner_id, version)` | Host migration metadata, keyed by semantic schema owner. |
| `adele_product_projects(id, source_location)` | Product owner `dev.adele.product`, schema version 1; the database holds one Project's stable ID and current source URI. |
| `adele_product_tasks(id, project_id, title)` | Task identity, Project foreign key, and title. |
| `adele_product_environments(id, task_id, role, provider_id, provider_state_json)` | Environment identity, Task foreign key, semantic role, provider identity, and opaque JSON provider-state snapshot. |
| `adele_product_sessions(id, task_id, strategy_id)` | Session identity, Task foreign key, and permanent semantic strategy ID. |
| `adele_product_session_environment_authority(session_id, environment_id)` | Exactly one same-Task Environment association per Session, with foreign keys to both records; not a live access token or facet. |
| `adele_product_runs(id, session_id, terminal_state)` | Terminal Run identity, Session foreign key, and terminal state; not a live execution or evidence record. |

All product tables belong to `dev.adele.product` schema version **1**. This is the
current pre-release baseline, not a history of development schemas. Earlier
development databases may be deleted/recreated; there are no product upgrade
steps, legacy-shape recognition, or transitional reads. Generic owner-version
coordination remains in place for a future declared storage-compatibility baseline.

The Run table has `id TEXT PRIMARY KEY`, `session_id TEXT NOT NULL` referencing
`adele_product_sessions(id)`, and `terminal_state TEXT NOT NULL` constrained by
`CHECK (terminal_state IN ('completed', 'failed', 'cancelled'))`. It has no JSON,
timestamps, evidence, or chronological ordering fields. States are stored by name,
not enum ordinal; [terminal Run history](#terminal-run-history) defines their scope.
The separate `dev.adele.execution` version-1 schema stores terminal public activity
without adding evidence fields or orchestration dependencies to product values.
Its relational model belongs to [execution history](execution-model.md#terminal-execution-history).

Roles are strings (`primary`, `additional`), not enum ordinals. A partial unique
index on Environment `task_id` where `role = 'primary'` prevents multiple primary
Environments. Only finalized, non-null provider state is stored, as JSON object
text rather than a serialized Environment. Core generically encodes/decodes the
snapshot and uses the ordinary immutable `Environment` validation; it does not
interpret provider-specific fields.

Private `MigrationCoordinator` applies ordered owner migrations and version
updates in a transaction. Product owns its table semantics and initialization SQL;
generic host coordination does not become the semantic owner of plugin tables.
Other owners' tables and version records remain untouched, not adopted or deleted
by product initialization. Plugins supply their own migrations through the
[Session-scoped storage service](contracts-and-capabilities.md#session-scoped-relational-storage),
not a global plugin migration registry or public SQLite handle.
Unsupported, malformed, or newer core storage must fail non-destructively,
not be reset, downgraded, assigned replacement identity, or hidden behind volatile
fallback. A failed transaction is rolled back; opening need not undo already
created backing directories or a separately committed schema initialization.

An empty initialized Project table receives a new ID. Reopening reads the existing
ID without allocating another. Moving the source together with its database,
then reopening it, preserves that ID and commits the newly selected source URI.
The historical URI must remain valid local-source data, but need not be addressable
on the current host; only the new selected location undergoes filesystem checks.
Project reopening loads Tasks, Environment records/provider-state snapshots,
Sessions, their Environment associations, and terminal Run records without
allocating replacement identities, resolving stored strategies, or invoking
Environment providers.
Their availability is not required to load these records; the explicitly selected
Project provider is still required to open the backing.
Materialization remains explicit: the stock [Git Environment](../../plugins/git_environment/README.md)
can restore the existing checkout from its retained Project-relative state after
restarting or moving the complete Project, including `.git`, the database, and
`.adele/worktrees`. Opening itself does not repair or materialize that checkout.
There is no recent-project catalog or automatic Task selection/resume.
Within one lifecycle, reopening the same backing/source returns the published
Project; a conflicting already-open location for that ID fails rather than
retargeting live state. Complete copy/move conflict management is not implied.

### Opening and publication

`resolveProjectProvider(ProviderId)` is explicit-only. `openProject` accepts
`sourceLocation`, an exact `ProviderBinding` from that lifecycle, and optional
host-owned `validateSelection`. Headless callers need no selector frontend.
`createProject` remains an explicitly volatile development/fixture path, never
the production fallback when durable opening fails.

For UI opening, the host captures the selector and provider and validates both
before picking, after picking, and after asynchronous provider preparation.
Every prepared selector also requires exact same-installation backend ownership,
as defined by the [plugin system](plugin-system.md#project-selector-ownership).
Cancellation is a no-op; missing, failed, or retired participants cannot be replaced
inside an in-flight operation. SQLite work follows the final validation
synchronously. The identity/source transaction commits first;
`ProjectDatabase.loadProductGraph` reads only core product tables and parses all
Task, Environment, Session, authority, and terminal Run rows, returning the latter
as `runRecords`. Separate `loadExecutionHistory` reads and validates terminal
activity against those records. Both restore sets are validated before either is
published; lifecycle owns the activity map, not the product store.
`InMemoryProductStore.publishRestoredProject` validates the complete
graph before any live-store mutation. Validation requires Tasks in that Project,
Environments and Sessions belonging to those Tasks, one finalized primary
Environment per Task, exactly one same-Task Environment authority per Session, and
each Run record belonging to a restored Session. Invalid IDs or values, orphan or
duplicate records/authorities, and conflicts with already published IDs publish
none of the restored graph and leave the existing live graph unchanged.
This does not undo the earlier identity/source commit. No asynchronous generation
change can interleave validation and publication. Later retirement
does not invalidate a published Project or permanently pin it to the opening
generations.

Runtime close stops new lifecycle work, joins accepted Project provider calls and
database cleanup with backend teardown, and rejects late publication after closing
starts. Backend teardown starts without waiting for preparation so normal connection
revocation can settle pending remote opens. Window-owned Task/Run draining remains
separate. Shutdown does not force
an OS picker to close or promise general cancellation or bounded completion.

### Storage scope and limits

The core graph above and initialized plugin-owned state survive Project
reopen/restart; the [plugin state boundary](plugin-system.md#plugin-owned-state-and-persistence)
defines Chat's participation. Persisted Session/Environment associations are
semantic relationships, not serialized execution authority. Live bindings,
materializations, facets, and host-issued tokens must never be serialized.

Only terminal Run records and their public activity snapshots are retained, not
active/waiting Runs, active claims, approval restart state, or continuation/replay
recovery. Restoration creates no execution or actionable approval and allocates no
Run IDs. Historical native envelopes are opaque evidence, never future continuation
input. Chat's current plain-text draft is durable plugin-owned state, not
workbench state. This adds no Task/Session browser, navigation, automatic
selection/resume, Profiles, general settings, configured-provider/credential
storage, or workbench/window persistence.

Small synchronous host operations can block on filesystem/SQLite work. Confinement
is preflight validation, not a guarantee against hostile concurrent filesystem
symlink races. Git-ignore ergonomics remain follow-up work without automatically
editing a user's root ignore rules. Cloud sync, remote SQL, and a global migration
registry are deferred; none is implicit in choosing SQLite. Native integration and
platform validation limits belong to [the app](../../app/README.md#project-opening).

## Task

A Task is the core-owned durable unit of user intent within a Project. It is not
a TODO item or a strategy's progress entry. Plugins may associate behavior and
state with a Task without owning or redefining its identity.

Task workflow status is user/domain-owned. Successful Runs, successful tools, or
completed TODO items must not automatically mean that the Task is complete. The
current immutable `Task` carries identity, Project relationship, and title; it
does not yet implement that broader workflow state.

Task Browser is replaceable presentation/plugin behavior over core identities
and lifecycle operations, not the owner of Task identity or its Environment
association.

## Environment

An Environment is the practical source/filesystem and process context associated
with Task work. A Task normally has one primary Environment; the architecture
permits additional Task-associated Environments, including for delegated work.
The current value model distinguishes primary and additional roles, while the
implemented creation lifecycle establishes the primary Environment only.

Environment providers are interchangeable implementations of a public contract.
Git worktrees are stock provider behavior, not core Environment semantics.
Environment does not imply universal sandboxing or isolation of processes,
ports, databases, caches, credentials, or external services. Guarantees depend
on the selected provider; a separate universal Workspace identity is not required
by the accepted model.

Core Task lifecycle coordinates establishment and association through the
selected provider. Presentation invokes that lifecycle; it neither creates a
Git worktree directly nor owns the Task-to-Environment relationship.
Task and finalized primary Environment publish together only after provider
success. For a lifecycle-owned durable Project, one SQLite transaction inserts
both records and commits before in-memory publication and retention of the live
materialization. The provisional Environment is never stored. Provider failure or
database failure publishes neither record; there is no volatile fallback.
`createProject` remains volatile through lifecycle-owned database membership, not
URI heuristics, and its Tasks retain the in-memory-only behavior.
Subsequent generation retirement does not undo successful publication.

Establishment can create provider-owned external resources before the database
commit. If that later commit fails, core prevents semantic publication but cannot
generically undo those external effects: no Environment release/destruction
contract exists yet. Core does not implement provider-specific cleanup.

The immutable product `Environment` records its identity, Task relationship,
role, provider identity, and opaque provider-state snapshot. Core retains and
transports that state without interpreting its provider-specific schema. This
semantic record is distinct from `EnvironmentMaterialization`, which captures a
live provider and exact `ProviderBinding`, and from authorized live facets.
Retained provider state is not evidence that the binding is currently usable.

`EnvironmentRuntime` can restore retained state through a fresh binding to the
recorded provider identity; it does not substitute another provider merely
because that provider is available. Existing captured materializations and facets
never silently migrate to the replacement. A freshly reopened Environment has no
live materialization until explicitly requested. A missing recorded provider
makes that request fail without deleting, substituting, or rewriting the semantic
record. Successful restore refreshes only provider state, preserving Environment
ID, Task ID, role, and provider ID. For durable Projects the refresh commits to
SQLite before replacing the in-memory snapshot; volatile Projects only replace
in memory. Successfully committed refreshed state is retained even if the restored
binding retires before final readiness validation; semantic progress and executable
readiness remain distinct. The [Environment package](../../packages/environment/README.md)
maps the provider-neutral contract and its local representations.

If the database refresh fails, core retains the previous snapshot and publishes no
new materialization. The provider may already have bound live state during restore;
without a release or idempotent-restore contract, retry in that same generation is
not guaranteed. Recovery can require a fresh provider generation.

## Session

A Session is a stable core identity and lifecycle container, permanently bound
to one semantic `OrchestrationStrategyId`. It is not synonymous with Chat. The
bound strategy owns the semantic structure of its strategy-specific Session
state; changing strategy means creating a new Session, not converting an
existing Session into another semantic type.

For example, Chat owns conversation, Draft Request, and configuration, while a
different strategy might own goals and evaluations. Neither structure belongs in
the universal Session value.
Other plugins can also own state associated with the same Session without that
state becoming either core Session fields or the strategy's own schema.

The current `adele_product` value is intentionally minimal:
`Session(id, taskId, strategyId)`. Canonical Session identity is distinct from
strategy-owned Session state, Environment authority, presentation state, and
execution resources. Chat owns a generation-local backend cache backed by its own
relational schema for durable Sessions, separately from the core product store.

Three kinds of identity must not be conflated:

| Concept | Meaning |
| --- | --- |
| `OrchestrationStrategyId` | Semantic strategy permanently selected by the Session. |
| `ExtensionId` | Identity used to register a contribution at an extension point. |
| Exact `ExtensionBinding` | One live registration generation retained by a resolved operation. |

Core owns the minimal public strategy registration/resolution contract required
by Session lifecycle; implementations remain plugins. Current creation requires
exactly one live contribution for the requested semantic ID. Missing or duplicate
matches fail explicitly, with no default or fallback strategy. Neither creation
nor canonical Session validity requires an optional presentation frontend or
model provider to be available.

Live resolution uses the Session's stored semantic strategy ID. Fresh resolution
may select a replacement generation under that same ID, but a captured binding
must fail when stale rather than silently migrate. Permanent semantic binding
is not a lifetime pin to one activation generation. A caller retaining an exact
selection, including a frontend bound to its owning backend, must validate that
selection; merely starting another Run does not make a stale selection fresh.
Replacement does not migrate live plugin objects: a fresh backend loads compatible
plugin-owned state from durable storage on actual access. If Chat is absent,
Project reopen still succeeds, its tables remain untouched, and Session identity
and Environment association remain explicit. Resolving the missing strategy fails;
it does not delete the Session or substitute another strategy. See
[plugin persistence](plugin-system.md#plugin-owned-state-and-persistence) and
[the orchestration package](../../packages/orchestration/README.md)
for the current resolution and execution contracts.

## Session and Environment authority

Semantic IDs identify product objects; they do not themselves grant execution
or filesystem authority. The canonical Session value deliberately does not
contain its live authority or Environment materialization.

`ProductLifecycleCoordinator.createSession` validates the existing Task, exact
strategy selection, and primary or explicitly selected same-Task Environment
before allocating an ID. It then revalidates the strategy and checks live identity
conflicts. For a durable Project, one SQL transaction commits Session identity and
its Environment association before publishing the Session and separate
`SessionEnvironmentAuthority` together in memory. SQL failure publishes neither;
there is no volatile fallback. Explicit `createProject` fixtures retain volatile
creation. Reopen restores the association without acquiring a live facet.
`InMemoryProductStore.requireSessionAuthority` is the authoritative lookup for
that association. Environment existence and ownership are not a promise of
current provider readiness.

The host uses this lifecycle-owned relationship to capture coherent authorized
Environment facets through `EnvironmentRuntime`. A transported Session, Run, or
Environment ID cannot select an arbitrary Environment or grant a remote plugin
another authority. Live bindings, materializations, and host-issued tokens are
not canonical Session identity or persisted associations. See [operation-scoped host calls](contracts-and-capabilities.md#operation-scoped-host-calls)
for the deeper authority and transport boundary; it is not an OS sandbox.

## Run

A Run is a bounded execution attempt within a Session, not its durable
strategy-specific state. A Session can have multiple Runs, and one Run may span
multiple model invocations, tool turns, and approval interruptions. The strategy
decides sequencing and limits; a Run is not defined as one message, model call,
tool call, or a universal fixed invocation budget.

Core owns generic execution lifecycle and evidence. Model invocations, tool
activity, approvals, and outcomes do not automatically become canonical strategy
state. A strategy determines what semantic results it retains across Runs;
execution observation is not itself a persistence model.

Exact executable bindings apply during a Run. Retained strategy, model, and tool
bindings must not silently switch generations on continuation or approval resume.
Binding retirement does not promise rollback of effects already in flight.
The [agent execution architecture](execution-model.md) defines the
deeper mechanics; `RunId` lives in product, while `AgentRun` is an internal
execution object rather than another immutable product value.

### Terminal Run history

The immutable product value `RunRecord` has a `const` constructor requiring exactly
`RunId id`, `SessionId sessionId`, and `RunTerminalState state`. The product-owned
`RunTerminalState` enum contains only `completed`, `failed`, and `cancelled`, not
the nonterminal states in orchestration's live `RunState`. The record retains an
actual terminal outcome, not an execution object, strategy state, or public activity
snapshot. It supplies no chronology or evidence.

`InMemoryProductStore.runRecord` looks up a record by Run ID;
`runsForSession` returns an immutable snapshot without a chronological ordering
guarantee. `publishTerminalRun` requires a published Session and an unused Run ID;
it does not replace an earlier outcome. `ProductLifecycleCoordinator.retainTerminalRun`
accepts the record and an explicit terminal public `RunActivitySnapshot`, validates
their identity, Session scope, and terminal-state agreement, then uses
`ProjectDatabase.insertTerminalRun` for a durable Project. One SQL transaction
commits the product record and execution-owned activity before either is published
in memory. Storage failure publishes neither and never falls back to memory.
Only an explicitly volatile Project retains both in memory alone. Activity lookup
and evidence validation belong to [execution history](execution-model.md#terminal-execution-history),
not `RunRecord` or `InMemoryProductStore`.

`AdeleRuntime` owns the shared seeded `RunIdSource`; the default
`SessionExecutionController` uses `runtime.runIds` rather than creating a source
per controller. Tests may inject a source. There is no durable counter, and loading
retained records allocates no identities. Neither ID shape nor store iteration
order defines historical chronology.

The generic application Run wrapper records actual terminal state under the
[execution finalization rules](execution-model.md#terminal-run-retention).
Created, running, and waiting Runs have no durable record; resource close does not
invent an outcome or an `abandoned` state. Reopening restores records only, not
strategies, Environment materializations, execution, or approvals; the separate
execution-history load restores their read-only activity. This is terminal history,
not active Run recovery or automatic resume.

## Child Sessions

**Accepted architecture; child-Session lifecycle is not implemented.**

Delegated agent work can use a child Session with independent strategy-specific
state. It remains in the same Task, may share its parent's Environment or use
another Task-associated Environment, and may use another strategy. Core owns
authoritative parent/child linkage and Session identity, while orchestration
plugins decide how delegation participates in their workflow.
Child Sessions are primarily surfaced through their parent Session/orchestration
experience, rather than flattened into normal top-level Task Browser navigation.

The current Session value has no parent field or public child-creation lifecycle.
This acceptance does not prescribe a parent-link API or storage schema. Do not
introduce a separate universal `Subtask` concept without a concrete need.

## Durable semantic data and live runtime objects

Semantic product identities, relationships, and retained provider/plugin data
are not the same as live runtime bindings. The following must not be treated as
durable product identity or state:

- `ExtensionBinding`, `ProviderBinding`, and resolved executable contributions;
- backend connections and activation-generation handles;
- Environment materializations and live authorized facets;
- host authority tokens;
- active Run execution objects.

When an operation needs runtime resources, restoration resolves and validates fresh
live bindings from durable semantic identities and retained state, not serialized
executable objects. Core graph loading itself does not resolve them. Preserving an
identity does not make a missing provider/strategy available or authorize fallback
to a different one. Re-establishing runtime authority is distinct from loading
semantic data.

`InMemoryProductStore` remains the live product graph. [Project storage](#project-storage)
loads the validated Project/Task/Environment/Session graph, terminal Run records,
and semantic Session/Environment associations, not live bindings or access tokens.
It remains the canonical runtime graph rather than a SQL facade. Lifecycle retains
execution-owned terminal activity separately, and plugin state is loaded by its
owner separately; complete runtime restoration is not implied.

## Core-owned and plugin-owned durable state

Core shared semantics include Project and Task identities, Environment identity
and provider relationship, Session identity and permanent strategy binding,
terminal Run records, and their core relationships. Core must preserve those
invariants independently of which optional plugins or presentations are active.

Strategy/plugin-specific durable state remains with its semantic owner. Chat
conversation/configuration/Draft Request belong to Chat, not the core Session
schema; other plugins own their own associated state. The Draft Request described by
[product direction](../product/development-workflow/README.md#10-persistent-draft-request)
currently persists as exact plain text, including empty and whitespace-only
editing states. Submission atomically replaces a nonblank draft with one canonical
user entry and a new empty draft; direct user-message append does not consume it.
Backend replacement and Project reopen restore this state without starting a Run.
Richer document semantics, conversation forks, and concurrent editing remain
unimplemented. The shared storage service does not transfer plugin schemas or
validation into core.

Host persistence facilities may support these owners without making plugin state
ordinary cascading configuration or window layout part of Session state. The
[plugin state boundary](plugin-system.md#plugin-owned-state-and-persistence)
and [profiles/configuration architecture](profiles-and-configuration.md) retain
those distinctions, including domains where external systems remain authoritative.

## Source map

| Concern | Primary anchors |
| --- | --- |
| Canonical immutable product values and IDs | [`packages/product/`](../../packages/product/), `Project`, `Task`, `Environment`, `Session`, `RunRecord`, `RunTerminalState`, `RunId` |
| Product lifecycle and Session/Environment authority | [`app/lib/core/product_lifecycle.dart`](../../app/lib/core/product_lifecycle.dart), `ProductLifecycleCoordinator`, `InMemoryProductStore.requireSessionAuthority` |
| Terminal Run retention and lookup | [`app/lib/core/product_lifecycle.dart`](../../app/lib/core/product_lifecycle.dart), `retainTerminalRun`, `runRecord`, `runsForSession`, `publishTerminalRun` |
| Private Project SQL and migration coordination | [`app/lib/core/project_database.dart`](../../app/lib/core/project_database.dart), `ProjectDatabase`, `MigrationCoordinator` |
| Session-scoped plugin storage | [`packages/project_storage/lib/adele_project_storage.dart`](../../packages/project_storage/lib/adele_project_storage.dart), [`app/lib/core/project_storage_host.dart`](../../app/lib/core/project_storage_host.dart) |
| Live Environment materialization | [`app/lib/core/product_lifecycle.dart`](../../app/lib/core/product_lifecycle.dart), `EnvironmentRuntime`, `EnvironmentMaterialization` |
| Project selection and backing contracts | [`packages/core_extensions/`](../../packages/core_extensions/), `ProjectSelectorContribution`, `ProjectProviderService`, `ProjectBacking` |
| Provider-neutral Environment contract | [`packages/environment/`](../../packages/environment/), `EnvironmentProvider`, authorized read/mutation/process facets |
| Strategy identity resolution and execution facade | [`packages/orchestration/`](../../packages/orchestration/), `OrchestrationStrategyResolver`, `ResolvedOrchestrationStrategy` |
| Session-routed execution host | [`app/lib/core/orchestration_host.dart`](../../app/lib/core/orchestration_host.dart), `createSessionOrchestrationRun`, `KernelOrchestrationHost` |
| Internal Run execution mechanics | [`packages/agent_kernel/`](../../packages/agent_kernel/), `AgentRun` |
| Example strategy-owned Session state | [`plugins/chat_strategy/`](../../plugins/chat_strategy/), `ChatSessionStore` in its backend |
| Example Environment provider | [`plugins/git_environment/`](../../plugins/git_environment/) |

[ADR 0031](../adr/0031-project-task-session-environment-domain-direction.md)
records the product-domain decision rationale and history.
[ADR 0033](../adr/0033-durable-project-storage-and-provider-backing.md) records
durable Project storage and provider-selected backing.
[ADR 0034](../adr/0034-plugin-owned-relational-session-storage.md) amends its
storage scope for Sessions and plugin-owned relational state.
[ADR 0030](../adr/0030-recursive-typed-plugin-extension-model.md) records the
core/plugin extension ownership decision; [ADR 0022](../adr/0022-agent-execution-semantic-foundation.md)
retains the earlier Run execution rationale, not the current universal Session
definition.
