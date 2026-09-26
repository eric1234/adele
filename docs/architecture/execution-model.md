# ADELE Execution Model

Role: Canonical architecture

Implementation status: Partial

This document defines provider-neutral execution across public orchestration
contracts, internal generic Run mechanics, application/core adaptation, and
plugin-owned strategies, tools, and providers. `agent_kernel` is one internal
implementation package, not the owner or name of this cross-system model.

## Execution layering

```text
canonical Session
    permanent semantic strategy ID
    strategy-owned durable/session state
        |
        | fresh Run
        v
resolve/materialize exact strategy contribution
        |
        v
bounded Run
        |
        +-- prepare inference context
        +-- invoke model
        +-- resolve proposals against materialized tools
        +-- policy / optional approval
        +-- execute tools
        +-- return semantic continuation to strategy
        |
        v
strategy decides next turn or terminal result for its Session work
```

The [product model](product-model.md) owns Session and other product semantics;
[contracts and capabilities](contracts-and-capabilities.md) owns runtime transport
and authority; the [plugin system](plugin-system.md) owns registration and liveness.
This document owns execution semantics between those boundaries, not their APIs,
stock implementations, or presentation policy.

## Ownership

| Layer | Execution responsibility |
| --- | --- |
| Product/core identity | `adele_product` owns canonical product identities and relationships, including `SessionId`, `RunId`, the Session's `OrchestrationStrategyId`, and terminal `RunRecord`/`RunTerminalState` values. It does not own the executable Run object. |
| Public orchestration | `adele_orchestration` is the provider-neutral strategy/host boundary. It owns strategy resolution/execution contracts, `RunState`, invocation/interruption identities and approval-resolution values, strategy inference material, semantic model turns/output/proposals, context contracts, and public activity snapshots. It reexports the product identities rather than redefining them. |
| Internal mechanics | `agent_kernel` implements `AgentRun`, model invocation collection, tool composition/materialization/resolution, policy gates, interruptions, outcome handling, and the deterministic journal. Public tool definitions, effects, progress, and outcome values belong to `adele_model_tool` and are reused here. |
| Application/core adapters | Compose public strategy operations with selected model-provider bindings, model-tool contributions, context sources, Session Environment authority, approval policy, and internal mechanics/evidence; atomically retain terminal Run records and public activity through lifecycle. |
| Plugins | Own strategy-specific Session state and sequencing, concrete tool behavior, provider-specific semantics/protocols, and presentation. |

Plugins and public APIs must not depend on `agent_kernel`. The kernel depends
toward public semantic values, not concrete plugin implementations. Exact package
boundaries remain in [dependency rules](dependency-rules.md).

## Session, strategy, and Run

A Session is permanently bound to one semantic `OrchestrationStrategyId`.
Changing strategy means another Session. Strategy selection is not model-provider
selection: different strategies may define materially different Session semantics
while using the same model boundary. Strategy-owned durable state means semantic
continuity across Runs, not transient execution state or a claim of disk storage.

A Run is one bounded execution episode within a Session. One Session can execute
multiple Runs; one Run can contain multiple model/tool turns and interruptions.
The strategy determines sequencing and limits, not a universal one-message,
one-model-call, or fixed-budget definition of Run.

For each Run, application composition freshly resolves the stored strategy ID,
or validates a caller's retained exact selection against that ID and the canonical
registry. It materializes an execution and retains that strategy generation for
the Run. Starting a new Run does not refresh a stale supplied selection. Missing
or ambiguous strategy resolution fails without fallback. Replacement lifetimes
are detailed under [generation-bound execution](#generation-bound-execution).

See [product Session semantics](product-model.md#session) for durable identity and
state ownership. [ADR 0031](../adr/0031-project-task-session-environment-domain-direction.md)
supersedes the universal Chat-shaped Session in
[ADR 0022](../adr/0022-agent-execution-semantic-foundation.md); its earlier execution
separations remain relevant, not its historical history/context API.

## Strategy sequencing and host mechanics

The strategy decides what its Session state means, what input to project for
inference, when to invoke the model, how to interpret semantic turns, and whether
to continue with tool results or complete/fail its work. It decides which semantic
results become strategy-owned state. Stock Chat's conversation projection and
bounded sequential loop are one example, not universal Session/Run semantics.

The host owns Run lifecycle mechanics, model invocation identity/evidence,
executable tool snapshots, proposal validation/resolution, policy, approval,
actual tool execution, exact-binding validation, and observations. A strategy
receives semantic values and opaque handles through `OrchestrationExecutionHost`,
not internal kernel ports, executable catalogs, policies, or journal objects.
`StrategyModelTurn` is a collected turn; it does not replace streaming mechanics.

## Inference preparation

The strategy supplies `StrategyInferenceMaterial`: its semantic instructions and
ordered input, before host preparation. Each genuinely new inference, including a
continuation, follows:

```text
strategy material
    -> capture current inference-context sources
    -> immutable InferenceContextSnapshot
    -> model invocation
```

Source discovery occurs for each capture. Instruction capture finishes before
allocation of that model invocation's identity, its tool snapshot, model-start
evidence, or provider work. Earlier Run setup may already have materialized tool
contributions. Capture preserves strategy input and source provenance; deterministic
source ordering is not instruction trust or authority.

Each discovered source declares required or optional failure semantics. Required
failure aborts preparation; optional failure omits that entire source with
diagnostics. Successful empty material is not failure. Required status governs a
discovered source, not a promise that a named plugin is installed; zero sources
are valid.

Capture validates the exact source binding through callback completion and
copying/validation of its material. Safely captured immutable data can survive
source retirement, including during the model call. A later capture can discover
replacements; the current capture never silently retries through one. Freshness
is source-owned, with no universal refresh API. Capture is not an atomic snapshot
of all external state.

Maintained composition is instruction-focused. Broader Reference/Observation
material is not defined here. Exact contracts and rendering belong to the
[orchestration API map](../../packages/orchestration/README.md#inference-context).

## Model invocation

A model invocation has stable Run-local `ModelInvocationId` and consumes an
immutable semantic request containing captured context and tools. Its boundary is
streaming-capable: nonterminal observations are distinct from authoritative
ordered text, provider-native output, and tool proposals. Explicit semantic
settlement distinguishes `completed`, `incomplete`, and `refused`, separately from
invocation failure. Raw stream close without a terminal is not success; transport
cleanup after authoritative settlement does not replace that settlement.

Provider-native envelopes can accompany semantic items or occupy independent
ordered positions. Their meaning and compatibility remain provider-owned, not
common reasoning semantics or the sole representation of durable Session meaning.
Item-native data can participate in live Run-local continuation without making
protocol concepts core execution concepts. Application adaptation retains
invocation-level native terminal state as evidence but does not automatically reuse
it as input. Durably retained native envelopes are historical evidence only: they
must never be used as future continuation input or to reconstruct a live Run.

Provider request lowering, protocol, configuration, and model-specific behavior
belong behind the ModelProvider boundary. Provider/model selection remains distinct
from Session strategy identity. See [contracts and capabilities](contracts-and-capabilities.md)
and [`adele_model_provider`](../../packages/model_provider/) for that boundary;
[ADRs 0024](../adr/0024-common-model-provider-capability.md) and
[0025](../adr/0025-ordered-provider-native-model-items.md) record its rationale.

## Tools and proposals

### Identity and materialization

A tool's stable semantic `ToolId` is distinct from its model-visible alias and
from any individual invocation or executable generation. Matching aliases do not
make different tools the same semantic tool. Contribution composition rejects
duplicate semantic IDs; a model-visible snapshot requires unique aliases. A model
tool may project deeper services without becoming a separate ADELE Capability.

Materialization connects applicable contributions, executable objects, exact live
bindings/dependencies, and model-facing definitions. Before each model invocation,
the host takes an immutable `MaterializedToolSet`. Its aliases, schemas, and exact
executables remain the snapshot against which that invocation's proposals resolve.
Later registry/catalog changes do not mutate the issued request or substitute a
different executable. Snapshot immutability does not keep a retired binding live.

Current normal application setup composes a contributed `ToolCatalog` once per
new Run. Each inference snapshots that retained catalog; it does not automatically
rediscover tool extensions on continuation. A later snapshot may reflect explicit
catalog changes, and fresh Run composition can discover replacement contributions.
This cadence is distinct from per-inference context-source discovery.

### Proposal resolution

`ProviderToolProposal` is model output containing `providerCallId`, `alias`, and
proposed `arguments`. It is not execution authority, approval, proof of availability,
or already a `ToolInvocation`. Provider call IDs remain correlation data.

The host resolves the proposal against its exact tool snapshot, validates the
executable binding, awaits authoritative argument validation/normalization, and
revalidates that binding. Success constructs a local `ToolInvocation` retaining
`ToolInvocationId`, the original proposal, exact `MaterializedTool`, canonical
arguments, and `ToolExecutionContext` containing Run/Session IDs. Host evidence
separately correlates the originating model invocation and output occurrence;
Environment authority is not reconstructed from those IDs.

Unknown alias, invalid arguments, stale binding, and unavailable binding remain
distinct proposal failures, not fictitious invocations or successful executions.
The application accepts only unused proposals from its own successfully completed
model turn and exact opaque `StrategyToolSnapshot`. Matching IDs or equivalent
proposal data do not permit forgery, reuse, or substitution.

## Effects, policy, and approval

```text
resolved ToolInvocation
    -> invocation-specific EffectDescription
    -> policy decision
         allow -> execution eligibility
         deny  -> outcome without execution
         ask   -> Run interruption -> approval/rejection
    -> execute only when authorized
```

The executable describes concrete effects and targets from canonical arguments
and host context, without performing the proposed effect. `EffectUncertainty`
records uncertainty in that description. The host's policy evaluates this exact
invocation and description; availability is not authorization, and policy is not
user approval. Approval binds the invocation, canonical arguments, effects, and
executable, not merely the tool name. It does not override binding or domain
preconditions such as revision checks.

Denied or rejected work must not acquire execution authority. Remote tool
materialization, argument validation, and description receive no effectful
host-service authority; the authorized execute operation receives only its needed
services. Those grants follow the enclosing operation's lifetime, not just delivery
of a terminal tool item. Environment permissions/isolation remain distinct from
policy and approval. See [operation-scoped host calls](contracts-and-capabilities.md#operation-scoped-host-calls),
not a future general permission engine, for the authority boundary.

## Run interruptions

`RunInterruption` represents execution unable to continue without external
decision/input. The implemented concrete interruption is tool approval, with
stable interruption identity and retained invocation/effects; the Run enters
`waiting`. Broader user-input interruptions have no API defined by this slice.

Resolution must target the retained pending interruption and invocation. The host
captures the approval/rejection supplied for the current resume and permits its
application once; a strategy cannot manufacture approval from matching IDs or
replace rejection with approval. Resume uses the retained invocation and exact
bindings, not a new proposal or replacement-generation lookup. Rejection supplies
a semantic outcome without execution. Closing execution resources does not resolve
an abandoned interruption or imply Run cancellation.

## Execution, outcomes, and uncertainty

One started tool execution emits typed `ToolProgress` observations followed by
exactly one terminal `ToolOutcome` through one stream. Progress (`status`, `stdout`,
or `stderr`) is not terminal outcome. Internal dispatch guards prevent a second
start for the same invocation; they do not promise distributed exactly-once effects.

`ToolOutcome` separates disposition, optional failure kind, and `EffectCertainty`
from model-facing `modelContent`, structured `hostData`, and local diagnostics.
Current model content is a string, not a universal content-block taxonomy. The
model continuation need not contain the full host representation; provenance and
diagnostics can remain separate. Domain results such as a process exit code need
not mean infrastructure failure.

Effect certainty is independently `knownNotOccurred`, `knownOccurred`, or
`uncertain`; it is not inferred from success/failure wording or the pre-execution
effect description. Cancellation, timeout, transport/provider/tool failure, or a
lost response can occur after an external effect began. The host currently maps
unexpected failure after tool dispatch to infrastructure failure with uncertain
effects; an `indeterminate` disposition is also representable. Neither cancellation
nor binding retirement promises rollback.

Do not automatically retry side-effecting execution merely because transport
failed or a result is missing. A deliberate retry should normally be a new
`ToolInvocation` with its own identity and explicit provenance, not a hidden replay
of an approved invocation. This is a safety constraint, not an implemented retry
scheduler or retry-provenance schema.

## Generation-bound execution

**Captured executable work never silently retargets a replacement generation.**
Capture lifetimes differ:

| Binding or capture | Current lifetime |
| --- | --- |
| Strategy | One exact resolved/materialized contribution per Run. Validation at advancement, host operations, and asynchronous boundaries detects retirement. An active Run cannot continue on a replacement; a later fresh Run can resolve the same semantic ID without implying migration of plugin state. |
| Model provider | The normal application selects one exact `ProviderBinding` and adapter per new Run. Continuations reuse it and validate access through it, not a fresh provider lookup. Registration retirement is not retroactive invalidation of an already-open stream or settled evidence. |
| Tool | Each model snapshot retains exact executable objects from its catalog. Proposal validation, approval resume, and execution use those retained bindings/dependencies, never replacement lookup. Normal catalog capture is Run-scoped as described above. |
| Environment facets | A tool host context lazily captures coherent facets from one Session-authorized materialization. A fresh inference source context has its own lazy read-facet capture shared by that inference's sources. Neither context refreshes already captured facets; fresh contexts can obtain a restored provider generation. |
| Context material | Source binding is required through safe capture, not for the lifetime of the resulting immutable request data. |

Retirement is detected at relevant boundaries; it does not universally cause an
immediate Run-state transition, erase terminal evidence, or undo in-flight effects.
Later valid lifecycle boundaries may discover replacements. Generic binding
mechanics belong to the [plugin system](plugin-system.md#live-discovery-and-exact-captured-bindings)
and [contracts and capabilities](contracts-and-capabilities.md#live-discovery-and-exact-binding).

## Environment execution context

Execution may use the Session-authorized Task Environment. Application/core
composition supplies coherent authorized facets; neither strategy nor kernel
selects arbitrary Environments by transported ID. Filesystem, mutation, and
process semantics belong to the Environment/tool layers. An Environment is not
a universal sandbox. Association and lifecycle remain in the
[product model](product-model.md#session-and-environment-authority).

## Run lifecycle

The public `RunState` is:

```text
created
running
waiting
completed
failed
cancelled
```

Model streaming, tool execution, approval waits, progress, and cancellation
mechanics belong in subordinate evidence/activity, not a giant mutually exclusive
Run-state enum. The existence of `cancelled` does not imply a complete public
cancellation API; resource close, stream cancellation, and Run state are distinct.

### Terminal Run retention

Terminal product identity and execution evidence have separate semantic owners
but one retention boundary. The [product model](product-model.md#terminal-run-history)
owns the minimal record and product-store rules; [execution history](#terminal-execution-history)
owns the public snapshot and its storage. The generic application
`SessionOrchestrationRun` retains the `ProductLifecycleCoordinator` and supplies a
record mapped from actual `AgentRun.state` together with its terminal
`RunActivitySnapshot` in start/approval-resume finalization.
It does not infer terminal state from whether the outer call returned or threw.
Close also checks after draining detached host mechanics, since a deferred failure
may settle only after strategy advancement ends.

The wrapper sets `_terminalRecordAttempted` before calling lifecycle retention,
and therefore before SQL. It makes at most one recording attempt, including when
that attempt fails; subsequent cleanup/close does not retry. Created, running, and
waiting states cause no attempt. Closing a waiting Run creates no outcome, resolves
no approval, and adds no `abandoned` or invented cancellation state.

If strategy/execution advancement throws and terminal recording also throws, the
primary execution error is preserved and the secondary recording error is
suppressed. There is no multi-error diagnostic or retry mechanism. If recording is
the sole error, it surfaces without rewriting the live terminal state. Resource
cleanup is still attempted when recording fails and cannot change terminal state
or evidence. Automatic cleanup does not replace the advancement error; explicit
close can report its retained cleanup failure.

Chat's plugin-owned history SQL is a separate transaction after host completion,
not atomic with the product-record/activity transaction. If that Chat persistence
fails, the outer call surfaces the error, but the host remains completed and the terminal
record is `completed` when retention succeeds. Neither the outer error nor cleanup
rewrites it to `failed`. A persisted Chat user-entry association can locate retained
activity later; it does not serialize a presentation handle or execution object.

## Observations and activity

The internal `RunJournal` is deterministic in-memory evidence with Run-local
sequence numbers, useful for mechanics, tests, and projection. It is not durable
Run storage, event sourcing, replay/recovery, or canonical strategy history.

Application `RunActivityProjection` exposes a separate immutable public
`RunActivitySource`/`RunActivitySnapshot` read model in `adele_orchestration`.
Consumers observe Run state, model invocations and ordered outputs, proposal/tool
provenance, policy/approval, progress, and structured outcomes. Native envelopes
remain opaque evidence; provider-supplied safe presentation is retained where
represented, not used as replay input. Current public activity is not a text-delta
stream. It excludes executable authority, internal `AgentRun`/journal objects,
host-only diagnostics, and arbitrary exception objects.

Terminal public activity is retained through the explicit snapshot boundary below.
The internal journal is neither its storage input nor a persistence/replay format;
its in-memory mechanics/test/projection role is unchanged.

Observing or detaching observation does not affect execution. Presentation consumes
read-only projections and gains no execution or approval authority from them.
Strategy/plugin-specific presentation stays outside generic mechanics. Exact
activity APIs belong to [orchestration](../../packages/orchestration/README.md#live-run-activity);
current UI behavior belongs to [UI](../../packages/ui/README.md),
[application](../../app/README.md#activity-inspection),
[Chat](../../plugins/chat_strategy/README.md), and owning
[provider](../../plugins/openai/packages/frontend/README.md)/tool plugin READMEs.
Intended UX remains [product direction](../product/README.md).

### Terminal execution history

Execution owner `dev.adele.execution` has its own version-1 schema in the same
app-private per-Project SQLite connection as product owner `dev.adele.product`.
Product stays at version 1. Execution history uses normalized relational rows:

| Table | Execution-owned meaning |
| --- | --- |
| `adele_execution_run_activity` | One terminal activity header per product Run, latest Run-local sequence, and optional data-only failure. |
| `adele_execution_run_lifecycle` | Ordered Run-state observations. |
| `adele_execution_model_invocations` | Invocation identities, start/terminal occurrences, settlement, metadata, and failure. |
| `adele_execution_model_outputs` | Ordered text, native, and proposal output occurrences with their model provenance. |
| `adele_execution_tool_invocations` | Tool identity, preparation occurrence, proposal provenance, and canonical arguments. |
| `adele_execution_tool_changes` | Ordered preparation, policy, approval, execution, progress, and outcome evidence. |
| `adele_execution_rejected_proposals` | Rejected proposal provenance and failure, not fictitious tool executions. |

The private [schema](../../app/lib/core/execution_evidence_schema.dart) defines
columns and constraints. Identities, relationships, sequence values, enum names,
failure messages, metadata scalars, token counts, progress, and outcome scalars are
relational columns. JSON is limited to structured arguments, provider details,
native compatibility/data maps, safe presentation data, effect descriptions, and
outcome host data. It does not store whole semantic objects as JSON, serialize
`RunJournal`, or introduce a public database handle. Core never interprets
provider-native schemas.

Retention accepts an explicit terminal `RunActivitySnapshot` alongside `RunRecord`.
Their Run ID, Session ID, and terminal state must agree. Validation preserves
Run-local occurrence identities and order, model/output/tool provenance, and
data-only failure/outcome semantics; malformed or inconsistent history fails
explicitly rather than being truncated, reset, or published partially. Every
terminal product record requires exactly one activity root, and every root requires
its terminal record. The terminal state remains authoritative in the product row.
One SQL transaction inserts both owners' rows, then lifecycle publishes the product record
and immutable activity. A failed commit publishes neither. Explicitly volatile
Projects retain both only in memory, never as a storage-error fallback.

`ProjectDatabase.loadProductGraph` remains product-only.
`loadExecutionHistory` separately reconstructs and validates public snapshots
against terminal product records, without consulting plugin tables or resolving
strategies, model/tool providers, or Environment materializations. Both restore
sets must validate before either is published. `ProductLifecycleCoordinator` owns
the retained activity map and exposes `runActivity` and `runActivitiesForSession`;
the product store remains independent of orchestration activity types. Session
lookup returns an immutable collection without a cross-Run chronology guarantee.

Historical activity includes lifecycle, invocation/output order, proposal
rejections, policy/approval evidence, progress, outcomes, and opaque native
envelopes where present in the public snapshot. Recorded approvals are facts, not
actionable approvals. Native data is retained as historical evidence only, never
future continuation input; interpreted presentation still receives only the safe
presentation projection through existing activity/Inspection paths.

This is terminal history, not event sourcing or recovery. It retains no live
`AgentRun`, bindings, authority tokens, active/waiting Run state, Session claims,
approval restart state, or workbench state. There are no timestamps, cross-Run
ordering guarantees, pruning, development-schema upgrade migrations, automatic
resume, or Task/Session browser. The version-1 baseline requires coherent current
development storage rather than legacy readers. Before the first declared storage
compatibility commitment, further execution-schema changes rewrite/squash version 1
instead of accumulating development migrations.

## Implementation scope

The implemented foundation includes bounded strategy-driven Runs, streaming model
invocation, dynamic tool contribution/materialization, policy/approval,
interruptions, structured outcomes, instruction-context capture, public
activity projection, and terminal Run/activity retention. The [product graph and
terminal records](product-model.md#project-storage), terminal public snapshots,
and initialized plugin-owned Chat state have durable storage; live execution
remains in memory.
Persistent active Run recovery, child-Session lifecycle, broader context
material, general background scheduling, and richer multi-agent execution are not
established by this foundation.

## Execution invariants

1. Session strategy state is distinct from Run execution state.
2. A Run is not one model invocation; strategy/provider selection are distinct.
3. Strategy owns sequencing; host owns model/tool/policy/approval mechanics.
4. Provider proposals and call IDs are not execution authority.
5. Tool materialization is immutable for the model invocation that saw it.
6. Approval binds an exact invocation and effect description.
7. Captured executable bindings never silently retarget replacements.
8. Transported IDs grant neither Environment nor host-service authority.
9. Structured host outcomes/evidence remain distinct from model continuation text.
10. Uncertain effects prohibit blind retry assumptions; cancellation is not rollback.
11. Execution observation is read-only, not automatically durable strategy history.
12. Plugins and public APIs remain independent of internal `agent_kernel`.

## Source map

| Concern | Primary anchors |
| --- | --- |
| Product Session/Run identities and terminal records | [`packages/product/`](../../packages/product/), [product model](product-model.md#terminal-run-history) |
| Public strategy/execution semantics | [`packages/orchestration/`](../../packages/orchestration/), `OrchestrationExecutionHost` |
| Internal Run/model/tool mechanics | [`packages/agent_kernel/`](../../packages/agent_kernel/), `AgentRun` |
| Session orchestration host and terminal finalization | [`app/lib/core/orchestration_host.dart`](../../app/lib/core/orchestration_host.dart), `createSessionOrchestrationRun`, `SessionOrchestrationRun` |
| Inference context capture | [`context.dart`](../../packages/orchestration/lib/src/context.dart), [`inference_context_host.dart`](../../app/lib/core/inference_context_host.dart) |
| Model provider adaptation | [`model_provider_host.dart`](../../app/lib/core/model_provider_host.dart), `ModelProviderCapabilityAdapter` |
| Model-tool contracts, hosting, and policy | [`packages/model_tool/`](../../packages/model_tool/), [`model_tool_host.dart`](../../app/lib/core/model_tool_host.dart), [`approval_gated_tool_policy.dart`](../../app/lib/core/approval_gated_tool_policy.dart) |
| Normal Run composition | [`session_execution_controller.dart`](../../app/lib/ui/execution/session_execution_controller.dart) |
| Public activity projection | [`run_activity_projection.dart`](../../app/lib/core/run_activity_projection.dart), [`activity.dart`](../../packages/orchestration/lib/src/activity.dart) |
| Terminal activity storage and lookup | [`project_database.dart`](../../app/lib/core/project_database.dart), `loadExecutionHistory`, `insertTerminalRun`; [`product_lifecycle.dart`](../../app/lib/core/product_lifecycle.dart), `runActivity`, `runActivitiesForSession` |
| Private evidence validation and relational representation | [`execution_evidence.dart`](../../app/lib/core/execution_evidence.dart), [`execution_evidence_schema.dart`](../../app/lib/core/execution_evidence_schema.dart) |
| Runtime authority | [Contracts and capabilities](contracts-and-capabilities.md#operation-scoped-host-calls) |
| Product Environment authority | [Product model](product-model.md#session-and-environment-authority), [`product_lifecycle.dart`](../../app/lib/core/product_lifecycle.dart) |
