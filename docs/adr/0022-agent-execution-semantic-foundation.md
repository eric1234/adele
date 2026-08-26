# ADR 0022: Agent execution semantic foundation

## Status

Accepted for Phase IV-A

**Partially superseded by ADR 0031 for long-term Session semantics.** ADR 0022 remains authoritative for the Phase IV-A execution semantics it implemented. Its chat-shaped decision that a Session owns canonical user/assistant entries describes that proof slice but is no longer the long-term definition of every Session.

## Context

Phase III established deterministic one-to-many capability resolution and
generation-specific `ProviderBinding` objects. The first Phase IV prototype
proved that a scripted model and ResourceInspector could execute through real
AOT plugin capability bindings, but it made one simple chat/tool loop, one
transcript, one model, one fixed tool map, one pending approval, unary model
responses, and string results properties of `AgentRun` itself.

The accepted agent-kernel architecture instead requires canonical conversation,
execution lifecycle, context projection, model invocation, tool availability,
proposal resolution, policy, approval, execution, and observation to remain
separate. Phase IV-A implements the smallest vertical that proves those
boundaries without implementing generated streams or a final public model
provider contract.

## Decision

`agent_kernel` is an internal pure-Dart, provider-neutral package. Plugins do
not import it. Application composition adapts public generated capability
bindings into kernel ports; no second RPC mechanism is introduced.

Phase IV-A makes these decisions:

1. A Session owns canonical user and assistant entries. A Run references a
   `SessionId` but does not own a canonical message transcript. Tool and model
   execution events do not automatically become Session entries.
2. A `ContextAssembler` creates a `SemanticModelRequest` from a
   `SessionSnapshot`, current Run continuation items, and a materialized tool
   set. Session history is one input and is not itself a provider request.
3. A Run has only `created`, `running`, `waiting`, `completed`, `failed`, and
   `cancelled` top-level states. Model and tool activity is subordinate typed
   execution observation rather than additional Run states.
4. Run owns identity, Session linkage, lifecycle, outstanding interruptions,
   terminal failure, and an in-memory journal. It does not own model selection,
   tool selection, context policy, or the model/tool loop.
5. The provisional `DevelopmentToolLoopStrategy` lives in application
   development composition. It sequences this fixture vertical without
   defining the meaning of Run or creating a generalized workflow framework.
6. Kernel model invocation is `Stream<ModelEvent>`. Completed text and tool
   proposal items are distinct semantic outputs, and terminal completion or
   failure is authoritative.
7. The scripted model remains a fixture-specific generated unary capability.
   Its application adapter calls the unary generated client once, emits
   completed semantic output events, then emits terminal completion. It does
   not manufacture token deltas.
8. The scripted capability identity and generated service are explicitly
   fixture-specific. They are not the future common public `ModelProvider`
   contract.
9. `ToolId` is semantic identity and is independent from the model-visible
   alias. Resource inspection uses semantic identity
   `dev.adele.tool.resource-inspection` and alias `inspect_resource`.
10. A host-owned `ToolCatalog` contains current registrations. Each model
    invocation receives an immutable `MaterializedToolSet`; alias uniqueness is
    enforced within that snapshot. A later catalog replacement does not mutate
    an old snapshot.
11. A materialized tool retains its semantic definition, model alias/schema,
    and exact executable object. The ResourceInspector executable retains the
    exact Phase III `ProviderBinding` used to create it.
12. A provider proposal contains provider call correlation, alias, and raw
    arguments. `ToolInvocation` exists only after the alias resolves against the
    exact materialized set and the selected executable authoritatively validates
    and normalizes arguments. It retains immutable canonical arguments and its
    exact Run/Session execution context. Unknown aliases and invalid arguments
    use a typed failure path and do not create fake invocations.
13. ResourceInspector accepts exactly one string `uri`, parses it, requires an
    absolute URI, and stores an immutable canonical string snapshot.
14. The selected executable derives an invocation-specific non-mutating
    `EffectDescription` before policy. The implemented description identifies
    resource inspection and its exact URI target.
15. Availability, materialization, policy, approval, and execution are separate.
    `ToolPolicy` returns `allow`, `deny`, or `ask`. Allow can proceed without an
    interruption; deny produces a structured policy outcome without execution;
    ask creates a tool-approval interruption.
16. `RunInterruption` is the broader suspension category. Phase IV-A implements
    only `ToolApprovalInterruption`, containing its interruption identity, exact
    `ToolInvocation`, semantic tool identity, canonical arguments, and effect
    description. Resolution must match both interruption and invocation.
17. Approval remains in memory. Immediately before approved execution, ADELE
    validates the exact retained executable binding. A stale binding becomes a
    structured stale-binding outcome and is never re-resolved to a replacement
    provider generation. Approved execution requires the correlated successful
    Run resolution; Run verifies invocation ownership and enforces one start.
18. One started tool execution emits zero or more progress events and exactly
    one terminal `ToolOutcome` through one stream. A collector enforces terminal
    cardinality. ResourceInspector currently emits only its terminal outcome.
19. `ToolOutcome` independently records terminal disposition, optional failure
    kind, effect certainty, compact model-facing content, structured host data,
    and optional host diagnostic/cause. Effect certainty distinguishes known no
    effect, known effect, and uncertain effect and is not inferred from success,
    failure, or cancellation.
20. Successful ResourceInspector outcomes retain resource fields, provider
    label, and summary as structured host data while projecting only the summary
    to model continuation.
21. Model continuation retains the exact scripted-model adapter and therefore
    its exact Phase III model `ProviderBinding`. A restarted provider with the
    same ID cannot receive continuation from old work. Fresh work may resolve
    and use the replacement generation.
22. Execution observation uses typed events for Run lifecycle, model lifecycle
    and output, tool preparation and policy, interruption creation/resolution,
    invocation terminal outcomes, and started tool execution/progress/completion.
    Non-started rejection, denial, and stale-preflight outcomes are not reported
    as completed executions. `RunJournal` assigns deterministic run-local
    monotonic sequence numbers.
23. The journal is test and inspection infrastructure. It is not durable
    storage, replay, recovery, or a commitment to event-sourced persistence.

## Consequences

The maintained AOT fixture proves canonical user input, Run start, context
assembly, streaming-shaped model invocation over unary generated transport,
proposal resolution, immutable tool lookup, effect description, ask policy,
correlated approval, exact-generation ResourceInspector execution, structured
outcome continuation, canonical assistant append, and Run completion.

The same fixture proves structured rejection without parsing display prose,
stale tool and model generations without migration, fresh-generation work after
restart, deterministic journal order, and containment of a provider domain
failure to the relevant invocation.

The application strategy currently supports one provider tool proposal per
model invocation and one pending approval at a time. Those are properties of the
development fixture strategy, not Run or kernel model semantics.

## Deferred

Phase II-B remains responsible for generated `Stream<T>` transport, ordered
delivery, subscription/request cancellation, stream lifetime cleanup, and
backpressure. It should replace the scripted adapter's unary mechanics without
redesigning `SemanticModelRequest`, `ModelEvent`, Run, ToolInvocation, or
ToolOutcome.

Remaining Phase IV work includes the final common model-provider capability,
real provider integration, provider-native continuation, model capability
negotiation, production orchestration contributions, persistence/recovery,
cancellation semantics, child Runs/Sessions, parallel work, richer context
assembly, broader content and effect taxonomies, policy persistence, durable
approvals, execution environments, runtime resources, artifacts, and
presentation contributions.

No general JSON Schema engine, workflow registry, agent-definition registry,
DAG executor, execution-attempt identity, automatic side-effect retry,
distributed exactly-once mechanism, snapshot/rollback system, MCP integration,
SCM/workspace implementation, or generic multimodal system is introduced.
