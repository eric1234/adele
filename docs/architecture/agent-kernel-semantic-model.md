# Agent Kernel Semantic Model

## Status

**Guiding architecture; Phase IV execution/source-inspection vertical implemented.**

ADR 0031 subsequently refined the long-term product-domain model: Session is a core container permanently bound to one orchestration strategy, strategy-specific state defines the semantic contents of that Session, and Environment is the practical filesystem/source + process context. The earlier chat-shaped Session history and separate Workspace discussion remain valid descriptions of the Phase IV proof/history but are not universal long-term product semantics.

This document records the semantic boundaries ADELE intends to preserve while implementing its agent execution substrate. It is more specific than the non-normative research survey, but it is **not** a stable public extension API and does not freeze exact Dart type names, persistence schemas, or extension APIs.

It is informed by ADELE `main` through Phase IV, the provisional `phase-4-agent-run` branch, the external harness survey in [`../research/agent-harness-semantic-boundary-survey.md`](../research/agent-harness-semantic-boundary-survey.md), the disposable `experiment/tool-semantics` branch, and the current product/UX conceptual model. The architecture remains guiding and experimental rather than a stable public extension API.

Existing architecture principles remain in force, especially the distinctions among plugins, contracts, capabilities, extension points, configured capability instances, provider generations, and runtime resources.

## Scope

This document covers:

- Task, Environment, Session, and Run boundaries relevant to execution;
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
    ├── Environment(s)
    ├── Session(s)
    │   ├── Run(s)
    │   └── child Session(s)
    ├── Artifact(s)
    └── Review(s)
```

The key meanings are:

> A Task is the unit of durable user intent.  
> An Environment is the practical filesystem/source + process context used for Task work.  
> A Session is the durable orchestration container, permanently bound to one strategy.  
> A Run is the unit of execution.

These are product/domain concepts. The agent kernel operates within them; it does not own the entire domain model.

## Task

A Task is a durable goal-oriented product object. It may own goal/background/acceptance criteria, user-defined status, Sessions, one primary Environment plus additional Environments, artifacts, reviews, and plugin-associated state.

The user or an external system owns Task workflow state. The agent kernel must not equate a successful Run with a completed Task.

## Environment

An Environment identifies the practical source/filesystem and process context used by execution.

The initial architecture intentionally does **not** claim that Environment means complete isolation of every process, port, database, cache, credential, or external service. A Git worktree-backed Environment can isolate source mutations while still sharing many host resources. Docker, VMs, or remote providers may provide different isolation properties.

The earlier separate first-class Workspace/source-mutation abstraction is not required long-term architecture unless future concrete requirements demonstrate an independent semantic identity that Environment cannot represent cleanly.

The kernel must not assume filesystem paths, processes, ports, or credentials are always local.

## Session

A Session is a durable orchestration container permanently bound to one orchestration strategy.

Core does not define every Session as conversation/chat history. The bound strategy owns the semantic structure of strategy-specific Session state. A Chat strategy may own canonical user/assistant messages, tool/reasoning timeline state, drafts, compaction, and forks; a Goal strategy may own iterations/evaluations or a substantially different structure.

The maintained Phase IV implementation currently uses a chat-shaped `SessionHistoryPort` and canonical user/assistant entries. That representation remains valid implementation evidence for the Chat-like proof, but ADR 0031 supersedes it as the universal definition of Session.

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
| Provider request lowering/protocol | Provider implementation |
| Tool catalog extension | Plugins/host composition |
| Tool invocation lifecycle | `agent_kernel` |
| Tool executor implementation | Plugin/capability adapter or host service |
| Tool policy evaluation | Host/core policy subsystem |
| Human approval interruption | `agent_kernel` + host interaction |
| Runtime resource implementation | Environment/resource capability |
| UI presentation | Host shell + presentation extensions |
| Artifact/review/task state | Product/domain layer |

`agent_kernel` remains an internal pure-Dart package. Plugins do not import it.

# Agent definitions and workflows

An Agent and a Workflow/orchestration strategy are distinct concepts.

> Agent means **who** performs work.  
> Workflow/strategy means **how** work is orchestrated.

The kernel supplies execution primitives and invariants. A workflow/strategy decides what happens next.

The maintained `DevelopmentToolLoopStrategy` implements a bounded sequential source-inspection coding loop. That development algorithm does not define what a Run fundamentally is and is not a general Workflow framework.

The long-term product direction expects Sessions to be permanently bound to an orchestration strategy supplied through plugin extension composition. That orchestration registration system is not yet implemented.

# Strategy state and context assembly

The intended general relationship is:

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

Context/inference composition remains host-controlled at the provider-neutral boundary so ADELE can support ordering, provenance, budgeting, deduplication, compaction, caching, pinning/exclusion, explainability, provider projection, and user inspection.

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

The kernel retains each native envelope's kind, compatibility, and opaque data as one immutable value. Completed, incomplete, and refused terminals are general settled events, and typed Run observation retains their settlement and metadata. The provisional development strategy never executes proposals from incomplete or refused turns.

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

The Phase IV proof applies this distinction concretely:

```text
DevelopmentSourceService capability
    ↓ application projection
search_source_text / read_source_file model tools
```

These development aliases are implementation evidence, not stable public API promises. The underlying capability is bounded and read-only and is not the final ADELE Environment filesystem/source abstraction.

Dynamic external tools such as MCP definitions may be contributed without manufacturing a separate ADELE Capability for every external function.

Existing generated typed contracts remain the invocation mechanism wherever a tool executor calls an ADELE capability.

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

Tool definitions may declare conservative effect classes such as Environment/source read, Environment/source mutation, process spawn, external/network interaction, credential access, and runtime-resource creation/use. Exact production classes are deferred.

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

The earliest Phase IV slice implemented Tool approval. User-input elicitation and durable interruption handling remain deferred.

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

The kernel may carry an opaque runtime-resource reference and provenance. It does not own universal process/browser/terminal behavior. The Environment or resource capability owns identity allocation, lifecycle, observation, cleanup, leases, and restart/recovery policy.

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

# Environment

Run execution may be associated with a Task Environment:

```text
Run
├── Session
└── Environment?      filesystem/source + process context
```

The initial Phase IV source implementation binds one local read-only source root through DevelopmentSource while execution remains on the local host. This does not establish final Environment identity, source mutation authority, process execution abstraction, or a security sandbox.

Future Environment providers may represent Git worktrees, containers, VMs, SSH hosts, cloud sandboxes, or other plugin-provided contexts.

A Task normally has one primary Environment. Child Sessions may share that Environment or use another Task-associated Environment. Environment lifecycle/provider behavior belongs to the broader product/plugin architecture rather than `agent_kernel`.

# Child Runs and child Sessions

The architecture reserves both concepts.

A child Run is subordinate execution that does not require an independent durable Session context. A child Session is appropriate when delegated work needs independent strategy-specific state/context, persistence, inspectability, background lifetime, or later continuation.

A child Session remains under the same Task, records its parent Session, may use the same or another Task-associated Environment, and may be bound to another orchestration strategy. It is primarily surfaced through the parent Session/orchestration experience rather than flattened into normal top-level Task navigation.

A workflow decides whether subordinate work needs a child Run or child Session. Phase IV did not implement either fully.

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

The exact generic extension runtime remains to be implemented; the existing capability registry should not be overloaded into a universal registry for every extension type.

## Library

A Library is build-time implementation reuse without runtime identity. An OpenAI-compatible protocol/client implementation will normally be a library reused by provider plugins unless it gains independent runtime routing/policy semantics.

## Configured capability instance

Accounts/endpoints/providers such as "OpenAI Work" and "OpenAI Personal" are configured instances exposed by one plugin runtime, not separate plugins.

## Runtime resource

Processes, terminals, browser sessions, open documents, live connections, and active executions are temporary runtime identities, not plugin installations or configured capability instances.

# Presentation extensions

ADELE always needs generic rendering for core semantic items.

Plugins may contribute specialized presentation for semantic surfaces such as ToolInvocation summary/details, approval body, progress, result, resource/artifact viewer, diff/change-set rendering, context activation, and provider configuration.

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

# First Phase IV prototype: disposition

The `phase-4-agent-run` branch is useful evidence but not accepted architecture by itself.

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
| Run begins from one `userRequest` | bound strategy owns durable Session input/state semantics |
| Run owns `_messages` | context assembly derives model input from strategy/core/plugin state |
| one fixed injected model | structured inference composition resolves model/provider preferences; exact active binding remains explicit |
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

The accepted Phase IV implementation preserves these revised execution boundaries. ADR 0022 records that semantic foundation; ADR 0031 later refines the long-term Session/Environment product semantics without invalidating the proof.

# Foundational now, reserved, and deferred

## Established in Phase IV

Phase IV established semantic structure for:

- strategy-owned/context input versus Run execution (implemented proof is Chat-shaped);
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
- typed execution observations.

This foundation does not imply a complete public API or persistence implementation for every concept. Runtime-resource references remain reserved semantic space rather than a production runtime-resource system.

## Reserve semantic space

Do not fully implement yet without concrete need:

- AgentDefinition catalog;
- child Run graph;
- child Session lifecycle;
- EnvironmentProvider integrations;
- Artifact subsystem;
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
Phase IV-A — semantic agent-execution foundation      complete
Phase II-B — generated streaming + cancellation       complete
Phase IV-B1 — scripted adapter streaming integration  complete
Phase IV-B2 — common ModelProvider scripted vertical  complete
Phase IV-B3 — ordered provider-native model items     complete
Phase IV-B4 — OpenAI API-key Responses provider       complete
Phase IV-B5a — generation-bound configuration contexts complete
Phase IV-B5b — experimental ChatGPT configured instance complete
Phase IV closeout — DevelopmentSource coding vertical complete
```

Completed Phase IV sequence and next milestone:

```text
Phase IV-A — semantic agent-execution foundation
    ↓
Phase II-B — generated typed streaming/cancellation
    ↓
Phase IV-B1 — scripted adapter streaming integration
    ↓
Phase IV-B2/B3/B4 — common provider, ordered items, real OpenAI
    ↓
Phase IV-B5a/B5b — configured contexts + experimental ChatGPT
    ↓
Phase IV closeout — read-only ADELE source search/read continuation
    ↓
Phase V — minimum self-hosting plugin set
    ↓
Phase VI — cross the self-hosting boundary
```

This sequence let Phase IV-A define the semantic stream consumer using the existing unary scripted fixture, Phase II-B implement the transport semantics required by that concrete consumer, and Phase IV-B1 connect the two before the common ModelProvider capability and real providers were added.

## Phase IV-A target (historical proof shape)

```text
Chat-shaped Session with canonical user input
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
assistant output added to Chat-shaped Session state
    ↓
Run completion
```

The simple strategy is test scaffolding, not the definition of Run or universal Session semantics.

## Phase II-B result

Phase II-B extended generated typed transport with the minimum required streaming semantics:

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

## Phase IV-B1 integration

After II-B, the application adapter switched the scripted model to true generated streaming. It maps text and tool-call items incrementally, keeps transport probe items outside the kernel, preserves exact-generation failure, and propagates outer subscription cancellation to the generated producer. The unary fixture method remains regression/reference infrastructure.

## Phase IV completion result

Phase IV now proves the provider-neutral kernel semantics, common generated streaming ModelProvider boundary, real OpenAI provider, generation-bound configured contexts, experimental ChatGPT configured instance, and a bounded development strategy. That strategy can ask a real model to search and read the ADELE checkout through the generation-bound DevelopmentSource capability and continue to a final answer. The deterministic integration scripts only remote model responses; source access uses the real shared AOT host and capability path. The explicitly opt-in live ChatGPT source-coding smoke has also run successfully.

DevelopmentSource has no mutation, indexing/watching, SCM, command execution, or sandbox claim. Its ordinary symlink confinement is not descriptor-level protection against a deliberate local path-resolution/open race. These limits keep the Phase IV result a self-inspection vertical rather than full self-hosting.

# Self-hosting remains the gate

Do not let architectural expansion delay the first meaningful product workflow:

1. select/open the ADELE Project through the stock development composition;
2. create/select a Task/Session;
3. ask an agent for a small code change;
4. read/search files through the Task Environment;
5. apply changes;
6. display the diff;
7. display/edit changed files;
8. review/approve/reject;
9. run validation;
10. show results in the Session.

Editor polish, provider breadth, sophisticated orchestration, memory, and marketplace work can evolve after ADELE crosses this boundary.

# Invariants for future design reviews

When evaluating later designs against the Phase IV foundation and ADR 0031, ask:

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
