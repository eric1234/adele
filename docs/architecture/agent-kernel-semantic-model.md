# Agent Kernel Semantic Model

## Status

**Guiding architecture for the next Phase IV design**

This document records the semantic boundaries ADELE intends to preserve while implementing its agent execution substrate. It is more specific than the non-normative research survey, but it is **not** a stable public extension API and does not freeze exact Dart type names, persistence schemas, or contribution APIs.

It is informed by ADELE `main` through Phase III, the provisional `phase-4-agent-run` branch, the external harness survey in [`../research/agent-harness-semantic-boundary-survey.md`](../research/agent-harness-semantic-boundary-survey.md), the disposable `experiment/tool-semantics` branch, and the current product/UX conceptual model.

Existing architecture principles remain in force, especially the distinctions among plugins, contracts, capabilities, configured capability instances, provider generations, and runtime resources.

## Scope

This document covers:

- Task, Workspace, Session, and Run boundaries;
- the narrow responsibility of `agent_kernel`;
- model invocation and provider boundaries;
- tool discovery, materialization, invocation, policy, approval, execution, and result semantics;
- context assembly;
- execution events;
- runtime-resource references;
- orchestration boundaries;
- generation safety;
- foundational versus reserved versus deferred concepts.

It does not define final UI layouts, stable plugin APIs, persistence formats, a complete policy language, a complete provider protocol, full artifact/resource APIs, SCM implementation details, remote execution, multi-agent scheduling, durable task graphs, or strong sandboxing.

# Core product concepts

ADELE's product model is broader than the agent kernel:

```text
Profile
Project
└── Task
    ├── Workspace(s)
    ├── Session(s)
    │   └── Run(s)
    ├── Artifact(s)
    └── Review(s)
```

The key meanings are:

> A Task is the unit of durable user intent.  
> A Workspace is the unit of source mutation.  
> A Session is the unit of conversational context.  
> A Run is the unit of execution.

These are product/domain concepts. The agent kernel operates within them; it does not own the entire domain model.

## Task

A Task is a durable goal-oriented product object. It may own goal/background/acceptance criteria, user-defined status, sessions, workspaces, artifacts, reviews, and progress assessments.

The user or an external system owns Task workflow state. The agent kernel must not equate a successful Run with a completed Task.

## Workspace

A Workspace identifies the source/state mutation scope used by execution.

A source workspace is not necessarily an execution environment. A Git worktree can isolate source changes without isolating processes, ports, databases, caches, credentials, or external services.

## Session

A Session owns conversational context and canonical interaction history.

Session history is **not** the model request. Context assembly derives one model request from history plus other context sources. Sessions should survive independently of workspace lifetime.

## Run

A Run is one execution episode within a Session.

A Run may include several model invocations, several tool invocations, interruptions, workflow steps, multiple agents, child Runs, optional child Sessions, cancellation, and failure handling.

A Run is not defined as one model call, one user message, one tool call, or one agent object.

A user message submitted while a Run is active may steer that Run, satisfy an interruption, queue for a safe point, cancel work, or explicitly start separate work. Workflow/product semantics decide which applies.

# Product domain versus agent kernel

| Concern | Primary owner |
| --- | --- |
| Project identity and repository association | Product/domain layer |
| Task goal, user status, archive state | Product/domain layer |
| Workspace/source state | Workspace/SCM capabilities + product layer |
| Session history | Session/domain services |
| Run execution lifecycle | `agent_kernel` |
| Agent definition | Contributions/catalog outside execution state |
| Workflow/orchestration definition | Contributions/catalog outside execution state |
| Model provider implementation | Plugin/capability provider |
| Model invocation mechanics | `agent_kernel` through provider-neutral ports |
| Provider request lowering/protocol | Provider implementation |
| Tool catalog contribution | Plugins/host composition |
| Tool invocation lifecycle | `agent_kernel` |
| Tool executor implementation | Plugin/capability adapter or host service |
| Tool policy evaluation | Host/core policy subsystem |
| Human approval interruption | `agent_kernel` + host interaction |
| Runtime resource implementation | Execution environment/resource capability |
| UI presentation | Host shell + presentation contributions |
| Artifact/review/task state | Product/domain layer |

`agent_kernel` remains an internal pure-Dart package. Plugins do not import it.

# Agent definitions and workflows

An Agent and a Workflow are distinct concepts.

> Agent means **who** performs work.  
> Workflow means **how** work is orchestrated.

The kernel supplies execution primitives and invariants. A workflow/strategy decides what happens next.

The first implementation may use a simple chat/coding strategy, but that algorithm must not define what a Run fundamentally is.

# Canonical history and context assembly

The intended relationship is:

```text
canonical Session history
    +
Project instructions
    +
Task goal / accepted knowledge
    +
Session-specific context
    +
Workspace state
    +
Agent instructions
    +
Workflow-step instructions
    +
plugin context contributions
        ↓
Context Assembly
        ↓
semantic model request
```

Session history is only one context source.

Context assembly remains host-controlled so ADELE can later support ordering, provenance, budgeting, deduplication, compaction, caching, pinning/exclusion, explainability, provider projection, and user inspection.

Context contributors should return structured material rather than mutate one prompt string.

Canonical Session history belongs to ADELE. Provider-native continuation may be retained when useful, but it is compatibility-bound provider/model state and must not become the only representation of conversational meaning.

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

The kernel should not make unary `Future<ModelResponse>` its fundamental abstraction. A temporary unary fixture may synthesize semantic stream events until generated transport supports streams.

Provider-specific lowering handles protocol roles/items, reasoning formats, hosted tools, provider-only options, cache controls, endpoint/auth details, model-family quirks, and provider continuation identifiers.

Provider-native continuation is optional and compatibility-bound. Switching provider/model may require explicit replay or lossy projection.

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

A plugin may expose a sustained typed capability such as `WorkspaceService` and also contribute model tools such as `read_file`, `write_file`, or `search_text` whose executors project that capability into model-callable operations.

Dynamic external tools such as MCP definitions may be contributed without manufacturing a separate ADELE Capability for every external function.

Existing generated typed contracts remain the invocation mechanism wherever a tool executor calls an ADELE capability.

## Tool definitions and catalog

A provider-independent tool definition should describe semantic identity/version, description, canonical input contract/schema, conservative static effect metadata, and optional result/presentation contract metadata.

A host-owned catalog/composition subsystem collects current tool contributions. Availability may change because of plugin activation, provider lifecycle, MCP discovery, workflow stage, workspace/environment availability, agent policy, or profile configuration.

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
- Run/Session/workspace/environment context linkage;
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

Tool definitions may declare conservative effect classes such as workspace read, workspace mutation, process spawn, external/network interaction, credential access, and runtime-resource creation/use. Exact production classes are deferred.

Static metadata cannot fully describe concrete operations. Before policy/approval, the selected executable may derive a non-mutating invocation-specific effect description from canonical arguments and context.

Examples include exact file/resource targets, observed versions, cwd, runtime resource identity, likely mutation scope, network uncertainty, and resource creation.

Preflight may require bounded observation/read operations. If approval depends on observed state, material state must be revalidated immediately before execution. Effect description is an aid to policy/approval, not a guarantee that an open-ended command has no other effects; uncertainty must be representable.

A future policy engine may need semantic identity, exact binding/provider trust, canonical arguments, Run/Session/Agent/Workflow context, Workspace, Execution Environment, static effects, derived targets/effects, uncertainty, and runtime-resource information.

Availability, policy, approval, environmental isolation, and credential access remain distinct concerns.

# Run interruptions

A Run may have zero or more outstanding interruptions.

`RunInterruption` is the general semantic category for execution that cannot progress until an external decision/input is supplied.

Initial conceptual variants are:

- Tool approval;
- User input / elicitation.

Only Tool approval needs to be implemented in the earliest Phase IV slice.

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

The exact Dart API may be a stream with terminal event, an execution handle with progress stream + result future, or equivalent. It should not require separate effectful `execute()` and `outcome()` operations for the same execution.

Progress is nonterminal observation. Examples include status changes, stdout/stderr, partial search matches, byte/record counts, and resource startup state. Future transport/persistence may choose which progress is durable or lossy.

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

# Structured content, resources, and artifacts

A tool outcome may need several projections:

```text
ToolOutcome
├── compact model-facing content
├── structured host data
├── truncation metadata
├── runtime-resource references
├── artifact references
└── detailed host-only diagnostics/provenance
```

Display prose is not the canonical representation of all data.

The semantic model should support structured content blocks rather than one required string. Initial implementation may support only a small subset, while leaving room for text, structured data, resource references/content, images, audio, and other media.

An Artifact is a durable/significant non-conversational output with independent identity that can be referenced, reviewed, pinned, or exported. A rich inline result is not automatically an Artifact. Artifact lifecycle belongs to the broader product/domain model.

A runtime resource is an addressable live entity whose lifetime is independent of one tool invocation. Examples include processes, terminal sessions, browser sessions, debugger sessions, remote jobs, and temporary connections.

The kernel may carry an opaque runtime-resource reference and provenance. It does not own universal process/browser/terminal behavior. The execution environment or resource capability owns identity allocation, lifecycle, observation, cleanup, leases, and restart/recovery policy.

# Generation-bound execution

ADELE's existing Phase III provider-binding behavior is a core execution invariant.

When a model or tool is materialized against one provider/connection generation:

- the exact binding is retained;
- approval refers to that binding;
- execution validates that same binding immediately before use;
- if it became stale, the operation fails explicitly;
- ADELE does not silently re-resolve the same provider ID to a replacement generation.

This applies to model continuation, model-visible tool materialization, approved tool invocation, and dynamic MCP/external connections.

A new generation can participate in a new materialization cycle.

# Execution environment

Workspace source state and execution environment remain distinct.

```text
Run
├── Session
├── Workspace?             source/mutation context
└── ExecutionEnvironment? effect/process authority
```

Initial implementation may use one local source workspace and the local host environment. Future providers may represent containers, VMs, SSH hosts, cloud sandboxes, or plugin-provided environments.

The kernel should not assume filesystem paths, processes, ports, or credentials are always local.

# Child Runs and child Sessions

The architecture reserves both concepts.

A child Run is subordinate execution that does not require an independent conversational-history object. A child Session is appropriate when delegated work needs independent context/history, persistence, inspectability, background lifetime, or later continuation.

A workflow decides which form is appropriate. Phase IV does not need to implement either fully, but must not make the model incompatible with them.

# Execution events and projections

The kernel should emit typed semantic execution events suitable for deterministic tests, live UI projection, debugging, tracing, and future persistence.

Examples may include Run lifecycle events, model invocation lifecycle, model content, tool proposal/resolution, policy evaluation, interruption creation/resolution, tool execution, progress, and tool completion.

Execution events are **not** automatically the sole durable source of truth. Future persistence may use append-only facts, snapshots, projections, specialized stores, or a hybrid. Live progress and durable semantic history may use different representations.

The deterministic in-memory journal idea from the first Phase IV prototype can be retained without claiming event-sourced crash recovery.

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

# Plugin, capability, contribution, and library boundaries

## Plugin

A Plugin is a deployment/lifecycle/configuration/permission boundary. One plugin may participate in several semantic roles.

For example, a Git plugin may eventually provide `SourceControlService`, model tools, context contributions, diff/review presentation, commands, and events. It should not be forced into one plugin category.

## Capability

A Capability is runtime interoperability: which compatible provider can satisfy a semantic action/service request. Runtime dependencies should prefer capabilities over plugin implementation identities.

## Contribution

A Contribution adds something to a host-owned composition surface. Expected examples include tool definitions/catalog sources, context sources, agent definitions, workflows, presentation renderers, commands, workbench panels, and provider configuration UI.

The exact typed contribution mechanism remains to be designed.

## Library

A Library is build-time implementation reuse without runtime identity. An OpenAI-compatible protocol/client implementation will normally be a library reused by provider plugins unless it gains independent runtime routing/policy semantics.

## Configured capability instance

Accounts/endpoints/providers such as "OpenAI Work" and "OpenAI Personal" are configured instances exposed by one plugin runtime, not separate plugins.

## Runtime resource

Processes, terminals, browser sessions, open documents, live connections, and active executions are temporary runtime identities, not plugin installations or configured capability instances.

# Presentation contributions

ADELE always needs generic rendering for core semantic items.

Plugins may contribute specialized presentation for semantic surfaces such as ToolInvocation summary/details, approval body, progress, result, resource/artifact viewer, diff/change-set rendering, context activation, and provider configuration.

Execution returns semantic data. Presentation consumes semantic data. Executors do not return Flutter widgets.

Presentation lookup should use stable semantic tool/result contracts rather than model aliases or Dart runtime types crossing plugin boundaries. Generic fallback remains mandatory.

# Permissions and approval

The architecture preserves at least these distinct questions:

1. Is the capability/tool available?
2. Is it visible to this agent/model/workflow step?
3. Is this concrete invocation allowed by policy?
4. Does this concrete invocation require human approval?
5. Does the execution environment actually isolate or permit the effect?
6. May the operation access credentials/secrets?

Future policy may combine profile, environment, agent, workflow-step, user, tool, resource, and effect constraints. The UX may describe this as an intersection, but implementation should not assume policy is merely set intersection.

# First Phase IV prototype: disposition

The `phase-4-agent-run` branch is useful evidence but not accepted architecture.

## Keep in principle

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

## Replace or redesign

| Prototype assumption | Revised direction |
| --- | --- |
| `AgentRun` owns complete simple-chat loop | Run owns lifecycle; workflow/strategy owns sequencing |
| Run begins from one `userRequest` | Session owns canonical conversational input/history |
| Run owns `_messages` | Context assembly derives model input |
| one fixed injected model | Workflow selects provider/model; exact active binding remains explicit |
| fixed tool map | dynamic catalog + immutable model-invocation materialization |
| every tool call requires approval | availability → policy → optional interruption → execution |
| one pending approval | zero or more Run interruptions by design |
| model call ID is central tool identity | semantic ToolId + ADELE ToolInvocation + provider correlation |
| model-visible name is identity | alias is snapshot-local projection |
| run state includes model/tool substate | subordinate operations own detailed state |
| `ToolResult(String)` | structured ToolOutcome with model projection + host data |
| `ModelResponse(String, calls)` | streaming semantic model events/items |
| unary kernel model port | streaming-capable kernel port |
| nullable-field generic run event | typed semantic execution events |
| `ScriptedModelService` is future model contract | fixture/probe only |
| generic tool failure implies safe retry | preserve effect certainty and indeterminate outcomes |
| approval can re-resolve provider later | approval retains exact executable generation |

ADR 0022 on the prototype branch should not be treated as an accepted `main` decision in its current form. Its generation-binding rationale is valuable; its single-run simple-chat state-machine decision should be replaced by narrower decisions during the new Phase IV design cycle.

# Foundational now, reserved, and deferred

## Foundational for Phase IV

Phase IV should establish enough semantic structure for:

- Session history versus Run execution;
- context assembly boundary;
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
- typed execution events;
- runtime-resource references/provenance.

"Establish" does not require a complete public API or persistence implementation for every concept.

## Reserve semantic space

Do not fully implement yet:

- AgentDefinition catalog;
- child Run graph;
- child Session lifecycle;
- ExecutionEnvironment providers;
- Artifact subsystem;
- persistent memory;
- durable Run serialization/recovery;
- provider-native continuation persistence;
- model capability negotiation;
- tracing model;
- runtime-resource lease/recovery;
- presentation contribution API.

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
- arbitrary plugin UI replacement;
- full multi-agent scheduling.

# Phase sequencing implications

The original roadmap remains directionally correct:

```text
plugin runtime
    ↓
typed contracts
    ↓
capability fabric
    ↓
agent kernel
    ↓
minimum self-hosting plugins
    ↓
self-hosting
```

Implementation history narrowed the original typed-contract phase to unary transport even though the original plan included streams and cancellation.

For clarity:

```text
Phase II-A — generated unary typed transport          complete
Phase II-B — generated streaming + cancellation       pending
```

Recommended near-term sequence:

```text
Phase IV-A — semantic agent-execution foundation
    ↓
Phase II-B — generated typed streaming/cancellation
    ↓
remaining Phase IV — streamed model vertical,
                      one real provider,
                      minimal orchestration
    ↓
Phase V — minimum self-hosting plugin set
    ↓
Phase VI — cross the self-hosting boundary
```

This lets Phase IV-A define the semantic stream consumer using the existing unary scripted fixture, then lets Phase II-B implement only transport semantics required by a concrete consumer.

## Phase IV-A target

```text
Session with canonical user input
    ↓
simple provisional strategy
    ↓
Run
    ↓
context assembly
    ↓
streaming-shaped kernel model port
    ↓
unary scripted-model adapter
    ↓
provider tool proposal
    ↓
materialized ToolInvocation
    ↓
preflight/effect description
    ↓
policy → approval interruption
    ↓
generation-bound ResourceInspector execution
    ↓
structured ToolOutcome
    ↓
context assembly
    ↓
model continuation
    ↓
assistant output added to Session
    ↓
Run completion
```

The simple strategy is test scaffolding, not the definition of Run.

## Phase II-B target

Phase II-B should extend generated typed transport with the minimum required streaming semantics:

- typed stream items;
- ordered delivery;
- normal terminal completion;
- declared/structured failure;
- transport/provider disappearance;
- consumer/subscription cancellation;
- producer/request cancellation where supported;
- generation-bound stream lifetime;
- deterministic cleanup;
- sufficient flow-control/backpressure behavior for bounded memory.

Do not predesign distributed resumable streams or arbitrary bidirectional streaming without a concrete consumer.

## Remaining Phase IV target

After II-B:

- run the scripted model through true generated streaming;
- establish the first common model-provider capability contract;
- integrate one real model provider;
- implement the first simple chat/coding workflow strategy;
- prove a model can request a workspace tool and continue from the result through the intended capability/plugin architecture.

# Self-hosting remains the gate

Do not let architectural expansion delay the first meaningful product workflow:

1. open the ADELE repository;
2. ask an agent for a small code change;
3. read/search files;
4. apply changes;
5. display the diff;
6. open changed files;
7. review/approve/reject;
8. run validation;
9. show results in the Session.

Editor polish, provider breadth, sophisticated orchestration, memory, and marketplace work can evolve after ADELE crosses this boundary.

# Invariants for future design reviews

When evaluating a Phase IV design or implementation, ask:

1. Does canonical Session history remain distinct from one Run and one model request?
2. Can Run support more than one model/tool step without defining simple chat as Run itself?
3. Is model invocation streaming-capable at the kernel boundary?
4. Are provider-specific protocol/continuation details kept behind the provider boundary?
5. Are configured provider instance and model identity distinct?
6. Is one model invocation given a stable materialized tool snapshot?
7. Is model-visible tool name separate from semantic identity?
8. Does a resolved ToolInvocation retain the exact executable generation that produced it?
9. Are availability, policy, approval, execution, and environmental isolation separate?
10. Does approval bind the exact invocation/effects rather than a tool name?
11. Can results preserve structured host data separately from compact model content?
12. Can cancellation/transport failure express uncertain external effects?
13. Does the design avoid blind generic side-effect retries?
14. Can a tool return an opaque runtime resource without making the invocation its lifetime owner?
15. Can generic UI render semantic items without plugin-specific code while optional contributions enrich presentation?
16. Are execution events useful without committing ADELE to pure event sourcing?
17. Are plugins still independent of `agent_kernel`?
18. Are plugin-to-plugin/core operations still expressed through public contracts/capabilities rather than implementation dependencies?
19. Has each new foundational abstraction been justified by a concrete requirement rather than hypothetical reuse?
20. Does the design keep the path to the minimal self-hosting workflow short?
