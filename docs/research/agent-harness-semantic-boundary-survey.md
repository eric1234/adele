# Agent Harness Semantic Boundary Survey

## Status

**Research / non-normative**

This document records the research that informed ADELE's agent-execution architecture before the next Phase IV design pass. It is evidence and analysis, not an accepted API specification.

The purpose of the survey was not to copy another harness or predesign every future feature. The purpose was to identify semantic distinctions that repeatedly become important once an agent harness supports persistence, tools, approvals, background work, model providers, delegation, rich results, and isolated execution environments.

Accepted ADELE conclusions derived from this research belong in [`../architecture/agent-kernel-semantic-model.md`](../architecture/agent-kernel-semantic-model.md).

## Why this survey was done

ADELE's original roadmap intentionally placed the agent kernel after the plugin runtime, generated contracts, and capability fabric. The first Phase IV implementation attempt proved a small deterministic model/tool/approval loop, but it also made several convenient assumptions:

- one run begins with one user request;
- one run owns its model-message list;
- one run retains one model and a fixed tool map;
- every proposed tool call requires approval;
- one pending tool call is the run's waiting state;
- model and tool results are primarily strings;
- model invocation is unary;
- model/tool activity is represented through one run state machine and a nullable-field event record.

Before hardening those assumptions, the project surveyed existing agent harnesses and then ran narrower source and ADELE-specific pressure tests.

The central research question was:

> Which concepts need independent identity, state, lifecycle, ownership, or projection boundaries in a mature agent harness, even if ADELE does not implement all corresponding features yet?

## Method

The work used three evidence passes.

### Pass 1 — broad source survey

Seven current open-source agent systems were inspected deeply, with Aider used as a narrower counterexample:

| Project | Repository | Inspected revision |
| --- | --- | --- |
| OpenAI Codex | `openai/codex` | `646f7c0a91b8e327d263335da68ae8ef212895ce` |
| OpenAI Agents Python | `openai/openai-agents-python` | `e3d7c1727bf43761afbb7954651b7f908a973a3b` |
| Gemini CLI | `google-gemini/gemini-cli` | `cf22ac7e86f3dcf528e3ae591fec1c03090a49f8` |
| OpenHands Software Agent SDK | `OpenHands/software-agent-sdk` | `be6cd3b80b706bb14c91e604581a8de75cad61cc` |
| Goose | `aaif-goose/goose` | `064244e6bddf641876676f054a006b7da1da5182` |
| Cline | `cline/cline` | `b3cee3f973ffe9d023a10c5c414deba68cd6e09d` |
| OpenCode | `anomalyco/opencode` | `38e10eb1408feb700021b8e8766fb0ab41bf84e2` |
| Aider, narrow pass | `Aider-AI/aider` | `5dc9490bb35f9729ef2c95d00a19ccd30c26339c` |

Inspection occurred on 2026-08-09. Source was pinned to exact commits. Current executable code, schemas, migrations, and tests were preferred over documentation. Repository history was used to identify architectural evolution and pressure, not to infer functionality absent from current source.

The survey traced ownership and lifecycle rather than merely comparing names. Terms such as `session`, `conversation`, `thread`, `run`, `turn`, `task`, and `agent` mean materially different things across these projects.

### Pass 2 — targeted provider and execution-identity research

A second source pass focused on two unresolved high-risk questions:

1. What can safely belong to a common model-provider boundary, and what must remain provider/model-specific?
2. Which identities are actually needed across model invocation, provider retry, tool proposal, approval, execution, result, cancellation, and resume?

The targeted pass reused the exact revisions from Pass 1.

### Pass 3 — ADELE tool-semantics pressure test

A disposable branch, `experiment/tool-semantics`, was created from ADELE `main` at `ce92f8ad2fad6f92fceb8d7f875b7b2acd666bd0`.

The experiment did not modify production APIs. It built compileable Dart scratch types and tests for six representative tool cases:

- `read_file`
- `search_text`
- `apply_patch`
- `run_command`
- `start_process`
- a dynamically discovered MCP tool

The point was to discover where candidate semantic types became awkward when exercised against current ADELE capability and generation-binding behavior.

The separate first Phase IV prototype, `phase-4-agent-run` at `9457bfa4c737dc3d7cbaf828815e7145ea6e123f`, was treated as provisional evidence rather than accepted architecture.

## Evidence cautions

The surveyed projects evolve quickly. Several inspected revisions were ahead of their latest published release tags, and OpenCode contained two coexisting runtime generations. Findings therefore describe the pinned source revisions, not every released binary or hosted service.

Hosted provider internals, proprietary clients, external MCP servers, external workspace services, and application-specific idempotency mechanisms were outside repository-defined evidence unless represented by a source contract.

The survey did not assume that a successful implementation's internal architecture should be copied. Counterexamples and architectural awkwardness were specifically sought.

# Cross-project recurring separations

## Durable interaction state versus active execution

The strongest recurring boundary is that conversational continuity and current work are not the same thing.

Examples include:

- Codex durable thread/session state versus submitted turns and model sampling steps;
- OpenAI Agents session history versus a `Runner.run` execution versus serialized `RunState`;
- Cline `sessionId` versus `runId`;
- OpenCode durable Session versus process-local execution drain;
- Goose durable Session/Conversation versus live agent loop;
- OpenHands Conversation as the lifecycle aggregate while repeated agent steps remain execution operations.

The exact owner differs. OpenHands is an important counterexample to a universal "durable Run object": its Conversation is the dominant lifecycle aggregate. The recurring requirement is separation of persistent interaction history from transient execution machinery, not one mandatory class hierarchy.

## Canonical history versus model-visible context

Every deeply surveyed harness builds model input as a projection rather than blindly replaying its UI or persistence representation.

Examples:

- Codex builds a `Prompt` from selected `ResponseItem`s and typed context fragments.
- OpenHands derives an LLM-facing `View` from immutable events and condensation records.
- Gemini reconstructs provider history while separately injecting hierarchical context, skills, and compacted state.
- Cline's `prepareTurn` produces provider input without rewriting canonical history.
- OpenCode selects active history after compaction and conditionally retains provider metadata.
- Aider's repository map is generated relevance-ranked context rather than a conversation participant.

This boundary is particularly important for ADELE because project instructions, task knowledge, skills, workspace state, repository maps, reviews, and pinned files may all affect one model request without becoming ordinary conversation messages.

## Agent definition versus execution lifecycle

Reusable agent definitions/configurations repeatedly remain distinct from the object that owns mutable execution.

Examples:

- OpenAI Agents Python: reusable `Agent` versus Runner/RunState.
- OpenHands: frozen declarative Agent versus Conversation lifecycle.
- OpenCode: declarative Agent overlay versus Session runner.
- Cline: stateless/configured agent runtime layered under session orchestration.
- Gemini: registered agent definitions versus isolated subagent sessions/schedulers.

This supports treating "who performs work" separately from "how work is orchestrated" and from "what is currently executing."

## Tool availability versus permission versus approval

Mature harnesses repeatedly separate:

1. whether a tool is registered/available;
2. whether it is shown to the selected model in the current context;
3. whether policy allows a concrete invocation;
4. whether a human decision is required;
5. whether the external environment can actually perform the operation.

Gemini explicitly separates registry visibility, policy, confirmation, and sandboxing. Cline separates registration, mode/availability filtering, enablement, and host approval. OpenCode separates provider-facing materialization from leaf authorization. Goose separates dynamic MCP catalog visibility from tool policy.

A model-visible tool list is therefore not an authorization model.

## Tool proposal versus authorized external effect

Across all full surveys, a model tool proposal passes through additional boundaries before an external effect occurs:

- name/type/schema validation;
- lookup/materialization;
- duplicate or stale-call detection;
- policy;
- optional human approval;
- executor selection;
- environment/sandbox constraints;
- actual side effect;
- result normalization.

The proposal's identity commonly remains the correlation identity through result, but the phases remain semantically distinct.

## Approval versus general user input or elicitation

Permission approval is not the same interaction as asking a user for information.

Codex has distinct operations for approvals, user input, MCP elicitation, and other responses. Gemini uses a correlated confirmation path while other user interactions remain distinct. Goose separates confirmations from MCP elicitation. The OpenAI Agents SDK's durable interruption mechanism is tool-approval-specific rather than a generic arbitrary user-question abstraction.

For ADELE this means "may I execute this operation?" and "which database should I use?" should not be forced through one undifferentiated approval protocol.

## Live progress versus durable semantic history

Live deltas and progress are frequently intentionally non-durable:

- Codex persists selected completed items while many starts, deltas, approvals, and diagnostics remain transient.
- OpenCode V2 persists full-value events transactionally but keeps token/input deltas live-only.
- Goose persists tool request/results while notifications remain live channels.
- Gemini records completed messages/tool calls rather than the whole scheduler/message-bus stream.
- Cline's CLI JSONL is a presentation envelope over runtime events, separate from canonical persisted messages.

The evidence argues strongly against assuming that the UI event stream should automatically become ADELE's durable event-sourcing format.

## Provider-neutral orchestration versus provider-native continuation

Provider abstractions normalize enough semantics to run a common loop, but important continuation data remains conditional and non-portable.

Examples include:

- Responses `previous_response_id` and server conversation IDs;
- provider response/item identifiers;
- signed or encrypted reasoning/thinking;
- provider-specific tool metadata;
- provider request parameters;
- cache and prompt-continuation identifiers.

OpenCode explicitly retains provider metadata only when provider and model remain compatible, lowering or stripping it when they change. Goose persists provider-specific thinking and can allow some providers to own context. OpenAI Agents Python exposes a pluggable model interface while its common interchange remains OpenAI-Responses-shaped.

The repeated pattern is explicit replay/projection when switching providers, not universal portability of native continuation state.

## Execution environment versus conversational and source history

Workspace/effect state is a separate authority from conversation state.

- Codex history rollback does not reverse filesystem/process/network effects.
- OpenHands Conversation can target local or remote Workspace implementations.
- Cline can restore transcript and Git-backed workspace state independently.
- Gemini distinguishes transcript rewind from inverse edit restoration and shadow-Git checkpointing.
- OpenAI Agents Python treats sandbox/session state as a separate subsystem from Runner and conversational history.

This supports keeping source workspace, execution environment, and session history conceptually separate.

## Child execution versus parent transcript

When delegated work needs independent context, persistence, inspectability, or background lifetime, mature systems create child sessions/conversations:

- OpenHands child Conversations;
- Goose child Sessions;
- OpenCode child Sessions;
- Cline delegated child sessions and durable team work;
- Gemini isolated subagent chat/scheduler/transcript.

Aider is an important limiting counterexample: its architect/editor handoff is transient role sequencing and does not require a durable child session.

The evidence supports both lightweight child execution and fully independent child conversational contexts rather than requiring all delegation to use one form.

## External server identity versus tools exposed by that server

MCP-style systems repeatedly retain external connection/server identity separately from dynamic tools:

- Goose names and owns an extension connection while exposing namespaced tools.
- OpenCode keeps MCP client lifecycle scoped separately from session-adapted tool definitions.
- Gemini registers MCP servers independently of the active model tool catalog.
- Cline projects MCP connection tools into its ordinary runtime tool layer.

This distinction becomes important when tool definitions appear, disappear, change, or collide.

## Structured results versus text

Mature harnesses preserve rich data beyond one string:

- tool inputs and outputs;
- files/resources;
- images;
- structured JSON;
- diffs/change sets;
- reasoning;
- usage;
- truncation;
- error classifications;
- generated files and artifacts.

Adapters may intentionally flatten some data for a particular model or parent agent, but the host representation frequently remains richer.

# Important architectural counterexamples

## OpenHands does not require a durable Run aggregate

OpenHands makes Conversation the mutable lifecycle owner and Agent a reusable declarative decision component. This demonstrates that the architectural requirement is separation of concerns, not a mandatory persistence hierarchy such as `Conversation -> durable Run`.

ADELE may still choose a Run concept for provenance, background execution, and workflow UX, but should not force all mutable state into Run merely because other systems use that word.

## Gemini's model Turn does not own the tool loop

Gemini's core Turn interprets a model stream and discovers tool requests, while an adapter-owned Scheduler performs tool execution and reinjects results.

This demonstrates that "model invocation" and "whole agent loop" are separable even when the product presents them as one interaction.

## Aider does not promote every useful mechanism to an actor

Aider's repository map is generated context, and lint/test/fix feedback returns to the same coding loop. Architect/editor are transient semantic roles rather than autonomous durable agents.

This is useful negative evidence against manufacturing lifecycle identities for every context source, validator, or role.

## Approval durability varies

OpenAI Agents Python serializes exact invocation-bound approval state. Gemini and OpenCode generally keep pending approval waits in process memory. This shows that "approval" is a semantic boundary even when its durability policy is implementation-specific.

# Targeted model-provider findings

## Repeated provider boundary

Across Codex, OpenAI Agents Python, Gemini CLI, OpenCode, and Goose, the repeated sequence is:

```text
semantic model request
    ↓
provider/model-specific lowering
    ↓
protocol / route / live client
    ↓
provider stream
    ↓
normalized model events/items
    ↓
outer orchestration
```

The names and decomposition differ, but the separation recurs.

### Smallest common semantic vocabulary

The narrow repeated vocabulary is approximately:

- provider/configured provider context;
- selected model identity;
- semantic request;
- provider-native request;
- normalized stream events/completed response;
- errors;
- usage;
- optional provider request/response correlation.

The common request generally includes:

- conversation/context content;
- instructions;
- model-visible tool definitions;
- tool choice;
- generation controls;
- optional structured-output constraints.

Provider-specific lowering handles:

- protocol roles/items;
- provider-only parameters;
- reasoning/thinking formats;
- provider tool variants;
- cache hints;
- endpoint/auth details;
- model-family quirks.

## Provider, model, route, and configured instance are distinct concerns

OpenCode makes this distinction most explicit:

- provider catalog identity;
- provider-local model identity;
- executable model;
- protocol;
- route/endpoint/auth/transport;
- live client.

Other systems embed route/client choices more tightly, but still distinguish provider/model selection from live transport resources.

For ADELE research purposes, protocol similarity is therefore evidence for implementation-library reuse, not for merging provider identity, user account/endpoint configuration, model identity, and transport into one object.

## Streaming is lifecycle-bearing

All deeply traced model implementations use streaming internally. Streams carry more than user-visible token deltas:

- completed semantic items;
- tool-call formation;
- reasoning;
- usage;
- retry/fallback notices;
- cancellation;
- provider errors;
- authoritative terminal boundaries.

Some systems can schedule a completed tool call before the provider's entire response stream closes.

A collected unary response can represent terminal model output, but the survey did not find a lossless unary abstraction for the full invocation lifecycle. This supports a streaming-capable semantic model even when a first transport adapter temporarily synthesizes a stream from a unary backend.

## Provider-native continuation is conditional

Examples:

- Codex reuses `previous_response_id` only when request properties and incremental input are compatible.
- OpenAI Agents Python supports server-owned continuation on Responses but not Chat Completions.
- OpenCode preserves provider metadata only for exact compatible continuation.
- Gemini uses explicit replay with prompt-scoped model stickiness.
- Goose generally replays canonical conversation data but allows agentic providers to own context.

Provider-native continuation should therefore be treated as conditional state under a compatibility predicate, not as universal conversation content.

## Capability discovery is distributed

No surveyed implementation demonstrated one universal model-capability negotiation object.

Support is derived from combinations of:

- model catalogs/metadata;
- provider configuration;
- account/endpoint availability;
- adapter type;
- protocol validation;
- model-name/family predicates;
- runtime discovery/probes;
- dynamic tool materialization.

A model being listed does not always imply that the current executable route supports every advertised feature.

## Logical model invocation versus transport attempt

A logical model sampling operation can contain multiple transport/provider attempts. Retries may happen because of network errors, rate limits, authentication, malformed streams, context overflow, or provider-specific replay conditions.

The projects generally do not create a durable identity for each transport attempt. Retry state is usually internal to the provider/model layer or observability. A later model continuation after a tool result is a new logical model operation even if it belongs to the same user-facing run/turn.

# Targeted invocation and retry findings

## Tool invocation is the recurring execution identity

Across Codex, Agents Python, Gemini, OpenHands, OpenCode, and Cline, the principal local execution identity is the normalized provider tool-call/action identity plus surrounding scope.

Implementations enrich it differently:

- provider call ID;
- semantic tool/type;
- session/run/turn/message scope;
- lookup namespace;
- canonical arguments/fingerprint;
- selected live executor;
- registration identity.

The identity commonly spans proposal, approval, execution, and result.

## Approval must bind to the exact invocation

The strongest evidence comes from OpenAI Agents Python, which evolved from weaker name/call-ID assumptions toward canonical invocation fingerprints and nested ownership.

An approval request identifies a human interaction. The authority being approved is the exact tool invocation.

Broad "always allow" policy may affect future calls, but it is not a substitute for identifying the current suspended invocation.

## A separate execution-attempt identity is not generally present

The targeted pass explicitly searched for a distinct identity meaning:

> one particular effort to execute an already-approved local invocation.

None of the six primary paths created a general execution-attempt ID.

Examples instead use:

- one call ID plus state;
- canonical invocation with `executed`/`completed` flags;
- action ID plus observation ID;
- call ID plus registration identity;
- session/run/iteration/call scope.

This is useful negative evidence: ADELE should not introduce `ToolExecutionAttemptId` speculatively.

If a future durable retry mechanism intentionally executes one approved invocation more than once, that concrete requirement may justify attempt identity later.

## Side-effect and result commit are not atomic

Every surveyed local-tool architecture has a possible window:

```text
external effect succeeds
    ↓
process/client/transport fails
    ↓
model-visible or durable result is missing
```

No repository-visible mechanism creates a transaction spanning arbitrary external side effects and the harness's durable state.

Different systems repair this differently:

- Agents Python records an executed/completed fence and refuses transparent repeat after ambiguous execution.
- OpenCode marks interrupted tools failed rather than rerunning them.
- OpenHands may execute an unmatched durable action again on ordinary resume, exposing duplicate-effect risk.
- Gemini's live scheduler state is not durable.
- Codex reconstructs semantic history without a general side-effect attempt replay.
- Cline can rebuild session/runtime state but cannot infer unknown external truth.

Therefore missing result is not proof that an effect did not occur.

## Cancellation is not rollback

Cancellation is implemented as tokens/signals/task interruption. External work may already have crossed a side-effect boundary, and worker processes may outlive the caller.

A cancellation outcome must therefore be able to coexist with uncertainty about external effects.

## Stale executable bindings matter

OpenCode V2 explicitly captures the tool registration advertised to the model and rejects execution if that same registration was replaced before settlement.

ADELE's existing Phase III/first-Phase-IV generation-bound `ProviderBinding` already establishes a related invariant: a resolved provider generation becomes stale rather than silently moving to a replacement generation.

This research strongly supports retaining that property for model and tool execution.

# ADELE-specific tool-semantics pressure test

## Why the experiment was needed

The external survey established broad distinctions but did not answer whether a clean Dart semantic model could fit ADELE's existing capability/runtime architecture.

The disposable `experiment/tool-semantics` branch pressure-tested six representative tool cases against current ADELE principles.

## Findings supported by the experiment

### Semantic identity differs from model-visible name

A tool needs stable semantic meaning independent of provider naming rules, aliases, namespaces, and sanitization.

Dynamic MCP makes this unavoidable: external server identity, semantic external tool identity, model-safe alias, and live executable generation are distinct.

### Tools need not be ADELE capabilities

A capability implementation can be projected into one or more model tools.

Dynamic MCP tools demonstrate the inverse: arbitrary runtime-discovered model tools can fit the generic tool layer without manufacturing a long-lived ADELE Capability per external function.

This preserves the existing distinction:

- capabilities are semantic runtime interoperability boundaries;
- model tools are host-composed model-callable projections/contributions.

### Model-visible tools should be materialized as an immutable snapshot

For one logical model invocation, ADELE needs a stable mapping from:

- model-visible alias;
- semantic tool identity;
- schema/description;
- exact executable binding.

The next model invocation may rematerialize tools based on new availability, policy, workflow stage, provider compatibility, or dynamic discovery.

A proposal retains the exact materialized entry that produced it.

### Invocation-specific effect description is useful

Static tool metadata cannot describe concrete targets such as:

- which files a patch touches;
- which resource version was inspected;
- which cwd a command uses;
- which runtime resource an operation addresses.

The experiment therefore found value in a non-mutating preflight/effect-description step near executor knowledge.

This description feeds policy and approval. It must support uncertainty and conservative effects, especially for arbitrary commands.

Any version or state that approval depends on must still be revalidated immediately before execution.

### Structured host result and model continuation content should be separate

`search_text` demonstrated the need to retain structured matches and truncation metadata while sending compact model content.

`read_file` demonstrated resource identity/version plus textual model content.

`apply_patch` demonstrated structured change data.

The model projection is therefore one view of a richer host outcome, not the canonical form of all tool data.

### Runtime resources are a real semantic category

`start_process` demonstrated a resource that:

- is created by one invocation;
- remains addressable after that invocation finishes;
- may outlive the Run;
- belongs to an execution environment/resource authority;
- is manipulated by later operations.

The agent kernel needs to understand an opaque runtime-resource reference and provenance, but does not need to own process/terminal/browser implementation details or a universal resource registry.

### No execution-attempt identity was required

All six cases fit one invocation identity through proposal, approval, progress, execution, and terminal outcome.

A retry after indeterminate external effects should normally be a new invocation with provenance, not a hidden second attempt under the same approved invocation.

## Tool outcome dimensions

The experiment identified coarse semantic categories such as:

- success;
- invalid arguments;
- unavailable;
- stale binding;
- policy denied;
- user rejected;
- domain failure;
- infrastructure failure;
- cancelled;
- indeterminate;
- malformed external result.

The exact production taxonomy remains an architecture/API design choice.

A more important finding is that **effect certainty is orthogonal to the outcome category**.

For example:

- cancellation before effect begins;
- cancellation after effect may have begun;
- infrastructure failure known to occur before effect;
- infrastructure failure after an external effect may have occurred;
- malformed result after an effectful operation.

ADELE needs to preserve this distinction without pretending it can infer unknown external truth.

## Presentation remains separate from execution

Generic host presentation can use semantic invocation, effects, progress, outcome, structured data, resources, artifacts, and provenance.

Plugins may contribute specialized renderers keyed by semantic tool/result contracts.

The executor should not return a Flutter widget or make display text the canonical result.

# Product-model reconciliation

The external harness survey could determine that conversational state, execution, and workspace effects must be separable, but it could not decide ADELE's product hierarchy.

A separate ADELE UX/design exploration established the current product concepts:

> A task is the unit of intent.  
> A workspace is the unit of mutation.  
> A session is the unit of conversational context.  
> A run is the unit of execution.

This fits the external evidence well.

The product model currently places:

```text
Project
└── Task
    ├── Workspace(s)
    ├── Session(s)
    │   └── Run(s)
    ├── Artifact(s)
    └── Review(s)
```

with execution environments conceptually separable from source workspaces.

Two refinements follow from the research:

1. A Run should mean one execution episode/workflow execution, not necessarily exactly one model call, one agent, or one new user message.
2. Delegated work may use either a child Run or a child Session. A child Session is appropriate when independent conversational context/history is required; lightweight nested execution need not create one.

The broader Project/Task/Workspace/Artifact/Review domain belongs above the narrow agent kernel. User-defined Task state is not agent-kernel execution state.

# Architectural relevance classification

## Foundational for the next Phase IV design

The evidence is strong enough that Phase IV should preserve these distinctions:

- Session conversational history versus Run execution.
- Canonical history versus model-context assembly.
- Run lifecycle versus orchestration strategy.
- Agent definition versus workflow/orchestration.
- Streaming-capable model invocation semantics.
- Semantic model request versus provider-specific lowering.
- Configured provider instance versus model identity versus live transport resources.
- Tool semantic identity versus model-visible alias.
- Tool availability/materialization versus policy versus approval versus execution.
- Immutable tool materialization for one model invocation.
- Exact generation-bound executable binding.
- ToolInvocation as the principal resolved local-call identity.
- RunInterruption as a concept broader than tool approval.
- Structured model/host content rather than string-only results.
- Typed tool progress and terminal outcome.
- Effect certainty/indeterminate external effects.
- Typed execution events distinct from any future durable event-sourcing choice.
- Workspace versus execution environment.
- Runtime-resource references that can outlive an invocation.
- Generic host rendering plus optional plugin presentation contributions.

## Reserve semantic space, but do not fully implement yet

- Agent definitions/catalog.
- Child Run graphs and child Sessions.
- ExecutionEnvironment provider abstraction.
- Artifact/resource subsystem.
- Persistent memory/knowledge.
- Durable Run continuation/recovery.
- Provider-native continuation state.
- Model capability metadata/negotiation.
- Trace/span correlation.
- Runtime-resource leases/recovery.
- Presentation contribution API details.
- Durable approval fingerprints.
- Result-data schema/version identity.

## Existing primitives appear sufficient or plugin-level

These features do not justify new agent-kernel lifecycle identities by themselves:

- AGENTS.md/project instructions.
- skills.
- repository maps.
- lint/test feedback loops.
- architect/editor sequencing.
- multi-model voting/synthesis.
- MCP integration itself.
- Git-specific review/index/worktree mechanics.

They may use context contributors, workflow/orchestration strategies, capabilities, tools, artifacts, and presentation contributions.

## Explicitly deferred unless concrete requirements emerge

- universal ToolExecutionAttempt identity;
- pure event sourcing as the mandatory persistence model;
- generic automatic retry of side-effecting tools;
- task/work-item dependency graph in the kernel;
- durable teams/mailboxes/leases;
- distributed exactly-once execution;
- generic snapshot/rollback semantics;
- one universal provider-continuation representation;
- one capability per model tool;
- executor-owned UI widgets.

# Architectural pressure and evolution evidence

The survey found repeated cases where systems became more explicit after initially coupled designs experienced pressure:

- Codex evolved from file-centric sessions toward storage-neutral threads, explicit metadata boundaries, history modes, projections, and durable queues.
- OpenAI Agents Python rapidly strengthened invocation identity, nested approval ownership, multi-view run items, sandbox ownership, and replay safety.
- Gemini decomposed registry, policy, confirmation, scheduler, and sandbox semantics while retaining seams between model-loop and adapter tool execution.
- OpenHands was rebuilt after monolithic client assumptions leaked into core, moving lifecycle to Conversation and per-call state away from shared Agent/LLM objects.
- Goose is decomposing a recursive loop into operation/effect semantics as approvals, compaction, steering, retries, hooks, and elicitation create parity pressure.
- Cline replaced a monolithic VS Code Task with explicit session/conversation/agent/run identities and later added a separate durable team-coordination domain.
- OpenCode's coexisting V1/V2 runtimes expose pressure around durable prompt admission, event projection, provider replay, tool registration staleness, and compaction boundaries.
- Aider demonstrates the complementary lesson that not every context generator or feedback loop needs a new lifecycle-bearing object.

The recurring lesson is not "more types are always better." It is that identities and ownership become necessary where lifecycle, persistence, policy, concurrency, provider compatibility, or external effects require them.

# Remaining questions

The following remain real design/implementation questions but are not considered blockers to the next Phase IV semantic design:

- exact durable persistence strategy for Sessions/Runs;
- which execution events become durable versus live-only;
- progress buffering, ordering, truncation, and backpressure across generated streaming transport;
- exact canonical argument encoding/fingerprint for durable approvals;
- JSON Schema dialect and validation normalization for external dynamic tools;
- exact `ToolId` syntax/version representation;
- result-data contract/schema identity for specialized renderers;
- runtime-resource lease transfer, restart recovery, and garbage collection;
- provider/model capability negotiation breadth;
- reconciliation mechanisms for indeterminate external effects;
- grouped/atomic approval semantics for parallel calls;
- strong sandbox/security implementation;
- external idempotency/transaction mechanisms supplied by particular tools or services.

These questions can be resolved when a concrete implementation or self-hosting feature creates the requirement.

# What the survey does not justify

The evidence does **not** justify assuming:

- one conversation equals one run;
- one run equals one model call;
- every user input creates a new run;
- every delegated operation needs a child Session;
- every tool is an ADELE Capability;
- every tool result is text;
- every tool approval can be keyed by tool name;
- a restarted provider may receive an old approved operation;
- cancellation means rollback;
- a missing result means an external effect did not happen;
- an automatic retry of a side-effecting tool is safe;
- every local execution needs a separate execution-attempt ID;
- every live progress event belongs in durable history;
- event sourcing must be the persistence model;
- provider-native continuation state is portable across providers/models;
- source workspace state and conversation rewind are one operation.

# Roadmap implications

The original roadmap already anticipated typed streaming in the contract layer and a provider-neutral agent execution kernel. Implementation deliberately narrowed Phase II to unary generated transport.

The research therefore suggests refinement rather than replacement of the original dependency strategy:

```text
plugin runtime
    ↓
typed contracts
    ↓
capability fabric
    ↓
agent execution kernel
    ↓
self-hosting plugin set
    ↓
ADELE develops ADELE
```

The practical sequencing implication is:

1. establish the revised Phase IV semantic execution model using the existing unary fixture where useful;
2. complete the deferred generated typed streaming/cancellation work from Phase II;
3. use that streaming transport for the real model-provider vertical and minimal orchestration;
4. build the minimum self-hosting plugin set;
5. cross the self-hosting boundary.

This keeps transport work driven by a concrete semantic consumer while preserving streaming as unfinished contract-layer work rather than redefining it as an agent-only mechanism.

# Research artifacts and reproducibility

The broad source survey was performed from clean, revision-pinned local clones. The second pass reused those exact commits. The ADELE tool spike lives on the disposable `experiment/tool-semantics` branch and the original agent prototype lives on `phase-4-agent-run`.

Those branches are evidence, not architecture authorities.

Future investigators should prefer:

1. this research document for the synthesized findings;
2. current source at the recorded upstream commits when implementation evidence needs verification;
3. [`../architecture/agent-kernel-semantic-model.md`](../architecture/agent-kernel-semantic-model.md) for ADELE's accepted direction;
4. current ADELE `main` for actual implemented behavior.
