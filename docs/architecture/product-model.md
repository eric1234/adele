# ADELE Product Model

Role: Canonical architecture

Implementation status: Partial

This document defines the shared product-domain semantics and ownership that
ADELE core and unrelated plugins must agree on. It combines accepted constraints
with the current implementation, without defining a persistence API or schema.
"Durable" describes semantic lifetime across execution attempts and live resource
generations, not a claim that storage across application restarts exists today.
Current product and Chat stores are in-memory.

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

Project selectors/providers are replaceable plugin behavior. The current
`ProjectSelectorContribution` returns a source URI or cancellation; core
`ProductLifecycleCoordinator` creates the canonical Project. Local Directory
selection is stock behavior, not Project semantics. Provider-specific validation
of whether a source can support Task work belongs to the relevant provider, not
the universal definition of Project.

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
success. Subsequent generation retirement does not undo successful publication.

The immutable product `Environment` records its identity, Task relationship,
role, provider identity, and opaque provider-state snapshot. Core retains and
transports that state without interpreting its provider-specific schema. This
semantic record is distinct from `EnvironmentMaterialization`, which captures a
live provider and exact `ProviderBinding`, and from authorized live facets.
Retained provider state is not evidence that the binding is currently usable.

`EnvironmentRuntime` can restore retained state through a fresh binding to the
recorded provider identity; it does not substitute another provider merely
because that provider is available. Existing captured materializations and facets
never silently migrate to the replacement. This in-process rematerialization is
implemented, but does not establish disk persistence or application-restart
recovery. Successfully refreshed provider state is retained even if the restored
binding retires before final readiness validation; retained state and executable
readiness remain distinct. The [Environment package](../../packages/environment/README.md)
maps the provider-neutral contract and its local representations.

## Session

A Session is a stable core identity and lifecycle container, permanently bound
to one semantic `OrchestrationStrategyId`. It is not synonymous with Chat. The
bound strategy owns the semantic structure of its strategy-specific Session
state; changing strategy means creating a new Session, not converting an
existing Session into another semantic type.

For example, Chat owns conversation state, while a different strategy might own
goals and evaluations. Neither structure belongs in the universal Session value.
Other plugins can also own state associated with the same Session without that
state becoming either core Session fields or the strategy's own schema.

The current `adele_product` value is intentionally minimal:
`Session(id, taskId, strategyId)`. Canonical Session identity is distinct from
strategy-owned Session state, Environment authority, presentation state, and
execution resources. Chat currently keeps its canonical state in its backend's
in-memory store, separately from the core product store.

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
Replacement also does not imply automatic migration of plugin-owned Session
state. See [the orchestration package](../../packages/orchestration/README.md)
for the current resolution and execution contracts.

## Session and Environment authority

Semantic IDs identify product objects; they do not themselves grant execution
or filesystem authority. The canonical Session value deliberately does not
contain its live authority or Environment materialization.

Current `ProductLifecycleCoordinator.createSession` validates an existing Task
and its primary or explicitly selected same-Task Environment, then publishes the
Session and separate `SessionEnvironmentAuthority` together in memory.
`InMemoryProductStore.requireSessionAuthority` is the authoritative lookup for
that association. Environment existence and ownership are not a promise of
current provider readiness.

The host uses this lifecycle-owned relationship to capture coherent authorized
Environment facets through `EnvironmentRuntime`. A transported Session, Run, or
Environment ID cannot select an arbitrary Environment or grant a remote plugin
another authority. Live bindings, materializations, and host-issued authority are
not canonical Session identity. See [operation-scoped host calls](contracts-and-capabilities.md#operation-scoped-host-calls)
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

- `ExtensionBinding` and resolved orchestration contribution objects;
- backend connections and activation-generation handles;
- Environment materializations and live authorized facets;
- host authority tokens;
- active Run execution objects.

Restoration should resolve and validate fresh live bindings from durable semantic
identities and retained state, not serialize these executable objects. Preserving
an identity does not make a missing provider/strategy available or authorize
fallback to a different one. Re-establishing runtime authority is distinct from
loading semantic data.

Current product storage is `InMemoryProductStore`; durable product/plugin storage
and complete restoration remain future work. This boundary does not select a
storage API, database schema, migration mechanism, or plugin persistence API.

## Core-owned and plugin-owned durable state

Core shared semantics include Project and Task identities, Environment identity
and provider relationship, Session identity and permanent strategy binding, and
their core relationships. Core must preserve those invariants independently of
which optional plugins or presentations are active.

Strategy/plugin-specific durable state remains with its semantic owner. Chat
conversation and the Draft Request described by [product direction](../product/development-workflow/README.md#10-persistent-draft-request)
belong to Chat, not the core Session schema; other plugins own their own associated
state. This is ownership architecture, not a claim that persistent Draft Request
or generic plugin storage is implemented. Core must not absorb plugin schemas
merely because persistence is eventually required.

Host persistence facilities may support these owners without making plugin state
ordinary cascading configuration or window layout part of Session state. The
[plugin state boundary](plugin-system.md#plugin-owned-state-and-persistence)
and [profiles/configuration architecture](profiles-and-configuration.md) retain
those distinctions, including domains where external systems remain authoritative.

## Source map

| Concern | Primary anchors |
| --- | --- |
| Canonical immutable product values and IDs | [`packages/product/`](../../packages/product/), `Project`, `Task`, `Environment`, `Session`, `RunId` |
| Product lifecycle and Session/Environment authority | [`app/lib/core/product_lifecycle.dart`](../../app/lib/core/product_lifecycle.dart), `ProductLifecycleCoordinator`, `InMemoryProductStore.requireSessionAuthority` |
| Live Environment materialization | [`app/lib/core/product_lifecycle.dart`](../../app/lib/core/product_lifecycle.dart), `EnvironmentRuntime`, `EnvironmentMaterialization` |
| Project selection contract | [`packages/core_extensions/`](../../packages/core_extensions/), `ProjectSelectorContribution` |
| Provider-neutral Environment contract | [`packages/environment/`](../../packages/environment/), `EnvironmentProvider`, authorized read/mutation/process facets |
| Strategy identity resolution and execution facade | [`packages/orchestration/`](../../packages/orchestration/), `OrchestrationStrategyResolver`, `ResolvedOrchestrationStrategy` |
| Session-routed execution host | [`app/lib/core/orchestration_host.dart`](../../app/lib/core/orchestration_host.dart), `createSessionOrchestrationRun`, `KernelOrchestrationHost` |
| Internal Run execution mechanics | [`packages/agent_kernel/`](../../packages/agent_kernel/), `AgentRun` |
| Example strategy-owned Session state | [`plugins/chat_strategy/`](../../plugins/chat_strategy/), `ChatSessionStore` in its backend |
| Example Environment provider | [`plugins/git_environment/`](../../plugins/git_environment/) |

[ADR 0031](../adr/0031-project-task-session-environment-domain-direction.md)
records the product-domain decision rationale and history.
[ADR 0030](../adr/0030-recursive-typed-plugin-extension-model.md) records the
core/plugin extension ownership decision; [ADR 0022](../adr/0022-agent-execution-semantic-foundation.md)
retains the earlier Run execution rationale, not the current universal Session
definition.
