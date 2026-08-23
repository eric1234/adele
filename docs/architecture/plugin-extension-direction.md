# Plugin and Extension Architecture Direction

## Status and purpose

**Guiding long-term product/architecture direction; not a frozen public API or implementation plan.**

ADELE is intended to remain useful and evolvable for years by making substantial parts of the product replaceable and composable through plugins. Configuration provides important flexibility, but configuration alone cannot provide the degree of substitution and experimentation ADELE is intended to support.

The existing repository has deliberately focused first on proving foundations: source plugins, frontend/backend runtime boundaries, generated typed transport, capability discovery and binding, provider-neutral agent-kernel semantics, and a minimal self-inspection agent vertical. Most existing plugins remain proofs, fixtures, or provisional implementations rather than a settled catalog of product plugins.

This document records the current direction for what should remain in ADELE core, what should normally live in plugins, how plugins may extend both ADELE and one another, and how the default development experience should be understood as one concrete composition rather than the definition of the platform.

It is intentionally broader than the immediate self-hosting implementation. The near-term implementation should build only what it needs, but it should avoid boundaries that make the longer-term model unnecessarily difficult. Conversely, this document should not cause speculative APIs to be implemented before a concrete use requires them.

Names in this document are descriptive. Plugin names, interface names, extension-point names, and exact package boundaries remain subject to change.

This document should be read alongside:

- [`principles.md`](principles.md), for durable repository-wide architecture constraints;
- [`contracts-and-capabilities.md`](contracts-and-capabilities.md), for the currently implemented contract/capability distinction and provider binding model;
- [`plugin-layout.md`](plugin-layout.md), for source-plugin packaging and frontend/backend structure;
- [`agent-kernel-semantic-model.md`](agent-kernel-semantic-model.md), for provider-neutral Run, model, tool, policy, interruption, and execution semantics;
- [`agent-tooling-direction.md`](agent-tooling-direction.md), for tool and execution presentation direction;
- [`profiles-and-configuration.md`](profiles-and-configuration.md), for activation, configuration, provider preference, and workbench-state direction;
- [`../mockups/README.md`](../mockups/README.md), for the default software-development UX direction.

The mockups should be interpreted as the experience produced by ADELE plus an expected stock development-plugin set. They do not, by themselves, identify which concepts are intrinsic to core and which are concrete plugin-provided realizations.

---

# 1. Architectural thesis

The intended system is not merely:

```text
ADELE
    -> plugins
```

It is recursively extensible:

```text
ADELE core
    -> typed extension points
        -> plugins
            -> plugin-defined typed extension points
                -> other plugins
```

Core provides a relatively small durable substrate. Plugins provide much of the concrete product behavior and may themselves define more specific concepts that remain further extensible.

Examples:

```text
ADELE center workbench
    -> Agent Interaction plugin
        -> orchestration-strategy extension point
            -> Chat strategy plugin
            -> Goal strategy plugin
            -> other strategies

Chat strategy plugin
    -> prompt-accessory extension point
        -> agent-control plugin UI
        -> model-control plugin UI
        -> reasoning-control plugin UI
```

ADELE core does not need to understand a chat prompt accessory merely because the Chat plugin exposes such a concept.

The primary architectural goal is therefore:

> Keep durable host/domain invariants in core while allowing concrete behavior, presentation, policy input, provider choice, workflow, tooling, and progressively more specific product concepts to be supplied and composed by plugins.

---

# 2. What belongs in core

Core should remain comparatively small, but some concepts need stable ownership so plugins can cooperate around them.

Directionally, core owns the following categories.

## 2.1 Plugin/runtime substrate

Core owns infrastructure such as:

- plugin installation/build/runtime lifecycle;
- frontend/backend hosting;
- generated transport infrastructure;
- activation contexts and generation safety;
- typed extension registration/discovery infrastructure;
- host-owned default-provider resolution where appropriate;
- profile activation and general configuration infrastructure;
- host persistence facilities;
- diagnostics around unavailable, stale, or failed registrations.

Plugins should not need to understand transport details or import internal host implementations.

## 2.2 Durable product identities and lifecycle

Core owns general domain concepts whose identities need to be shared across otherwise independent plugins, including at least:

```text
Project
Task
Session
Run
Environment
```

Owning the concept does not imply core supplies most of its useful behavior.

For example, Task is core-owned, while a Git plugin may provision the Task's primary Environment, an Accounting plugin may associate usage data with it, a TODO plugin may associate progress data with it, and a Task Browser plugin may present all of that information.

## 2.3 Agent execution invariants

Core owns provider-neutral agent execution mechanics and safety-critical arbitration, including the semantic invariants recorded in `agent-kernel-semantic-model.md`:

- Run lifecycle;
- stable model-invocation boundaries;
- tool materialization and exact binding;
- tool invocation lifecycle;
- interruptions/approvals;
- final authoritative policy/approval decisions;
- structured execution observation;
- generation safety.

Concrete models, tools, orchestration strategies, agent definitions, editors, SCM implementations, and most presentation do not belong in the kernel.

## 2.4 Top-level workbench geometry

The host owns the broad application shell and major regions, such as:

- title/chrome area;
- optional left auxiliary region;
- center workspace;
- right status/inspection region;
- bottom stream/console region;
- command palette and global command/keybinding infrastructure.

Plugins fill those regions. A plugin occupying one region may define its own internal regions and extension points for other plugins.

Plugins do not normally invent new peer-level top-level workbench regions outside the host shell.

## 2.5 Security authority

Plugins often know far more than core about the semantics of an operation. They may validate arguments, interpret configuration, derive effect descriptions, classify targets, or provide specialized policy inputs.

The authoritative allow/deny/ask decision remains host/core-owned.

A plugin may describe authority requirements; it must not grant itself authority merely because it understands the operation.

---

# 3. What normally belongs in plugins

The default rule remains that provider-specific, tool-specific, workflow-specific, integration-specific, and specialized UI behavior belongs in plugins.

Likely examples include:

- directory-backed Project opening;
- Git-backed Environment provisioning;
- Docker- or remote-backed Environment provisioning;
- Task/Session management UI;
- agent-interaction surfaces;
- chat, goal, loop, or other orchestration strategies;
- model providers;
- model routing/control policy;
- agent definitions/control policy;
- context contributors;
- filesystem tools;
- search tools;
- command execution tools;
- TODO/plan tools and views;
- accounting/usage aggregation;
- context monitoring/compaction behavior;
- Git integration;
- diff/review UI;
- source editors/viewers;
- external-editor launchers;
- console/terminal UI.

One plugin may provide several independent registrations to different areas of ADELE. Splitting those registrations into separate plugins should not fundamentally change the extension mechanisms involved.

---

# 4. Extension points as the general composition concept

The broad architectural concept is an **Extension Point**.

An Extension Point is a typed place where active plugins may register participation. The owner of an Extension Point may be core or another plugin.

One registered implementation/participant is referred to directionally here as an **Extension**. The final public terminology may change.

An Extension Point defines the semantics that matter for that particular interaction. Those semantics may include:

```text
interface/data shape
zero/one/many registration behavior
context supplied to implementations
applicability rules
selection/defaulting behavior
ordering/priority if meaningful
composition/merge semantics if meaningful
failure behavior
lifecycle/generation behavior
```

There should not be one magical composition algorithm for all Extension Points.

An extension generally registers broadly. The particular Extension Point determines how an implementation decides whether it applies to an operation. Core should not impose one universal declarative applicability language over every extension domain.

Examples may include an implementation answering `supports(resource)`, returning no contribution for an irrelevant inference, or always participating in a specific UI region.

---

# 5. Capabilities are callable extension semantics

The existing Capability concept remains useful, but it should be understood as a specialized semantic pattern within the broader extension architecture rather than as a completely separate plugin system.

A Capability represents functionality that can be requested from one of potentially several compatible providers.

Existing public semantics distinguish:

- **Action** — brokered one-shot request/response operation;
- **Service** — sustained typed functionality;
- **Event** — fact notification.

Actions and Services fit naturally as callable Extension Points.

For example:

```text
OpenSourceResource
    providers:
        Internal Editor
        VS Code Launcher

EnvironmentProvisioner
    providers:
        Git Worktree
        Docker
        Remote VM
```

A caller may encounter zero, one, or many providers.

Zero providers is normally a valid composition state. The corresponding operation or affordance may simply be unavailable.

A plugin should generally not require ADELE to activate another plugin merely because a complementary provider would make it more useful.

---

# 6. Avoid runtime plugin-dependency chains

ADELE should prefer runtime discovery of typed interfaces over plugin activation dependencies.

For example, Diff should not depend on the Internal Editor plugin.

Instead:

```text
Diff understands OpenSourceResource

Current providers:
    none
        -> file remains visible but not openable

    Internal Editor
        -> click opens internally

    Internal Editor + VS Code Launcher
        -> configured default may handle normal click
        -> alternate action may expose both
```

If a compatible provider appears while Diff is active, future UI/actions can begin using it. If the provider disappears, those affordances become unavailable again.

Likewise, Chat remains valid with no tools installed. It may be practically weak, but the user is allowed to configure an unhelpful composition.

The stock ADELE installation should provide a useful default plugin set rather than relying on activation dependencies to force a useful state.

## 6.1 Compile-time interface knowledge is not a runtime plugin dependency

Two independently authored plugins still need a common description of an interface they both understand.

That interface may be:

- a sufficiently general core/public ADELE interface; or
- an API/contract defined by the component that owns the more specific extension concept.

Depending on a shared interface definition is acceptable. Depending on a particular implementation plugin being installed or active should usually not be required.

For example, a Chat strategy plugin may publish a prompt-accessory API that other plugins compile against. Those plugins need not require the Chat plugin to be active; their registrations are simply unconsumed when no active component asks for that API.

This distinction should allow recursive plugin-defined extension ecosystems without requiring a complex runtime activation dependency graph.

---

# 7. Live registration and exact operation binding

Extension discovery is not merely startup-time discovery.

Future operations and visible affordances should generally respond to active registrations appearing or disappearing.

This does **not** mean in-flight operations silently migrate.

The architecture should preserve a distinction between:

```text
live composition
    current provider/contributor set may change

resolved operation
    exact selected/materialized bindings remain stable
```

For example, a new editor provider may become available to future clicks immediately, while an already-started model or tool invocation continues against the exact generation it was resolved against.

---

# 8. Host-owned default provider selection

A common ADELE convention is expected for interchangeable providers:

> The host owns contextual default-provider resolution; consumers may expose explicit alternatives when useful.

Configuration may influence the default based on profile, project, or other applicable context.

Examples:

```text
OpenSourceResource
    default: Internal Editor
    alternate: VS Code

EnvironmentProvisioner
    default: Git Worktree
    alternate: Docker
```

A UI may invoke the configured default on its primary action while exposing alternatives through a menu, split button, context action, command palette, or other affordance.

Host-rendered reusable UI for default-plus-alternatives is desirable where it provides consistency and compiled performance, but plugins may render bespoke UX when that produces a better experience.

Default selection is not the same as provider registration rank and should remain host-owned policy.

---

# 9. Events are read-only fact notifications

Events should remain semantically distinct even if they share registration/plumbing infrastructure with other Extension Points.

An Event communicates a fact that has occurred.

Examples:

```text
SessionCreated
RunStarted
ModelInvocationCompleted
ToolInvocationCompleted
ChatTurnCompleted
ReviewCommentAdded
GoalIterationCompleted
```

Core defines broadly useful domain events. Plugins may define events for their own concepts, and other plugins may subscribe when they understand those event APIs.

The important semantic guarantee is:

> An Event consumer cannot change whether the announced fact occurred.

Event-consumer failures are normally isolated from the producer and do not retroactively fail the originating operation.

Events are therefore closer to instrumentation than to a mutating callback system.

An Event does not inherently imply durable/replayable history. A domain may separately expose a query/history Service when historical inspection is useful.

For example, an Accounting plugin might:

- query retained model-invocation history when such history exists;
- subscribe to live usage events for incremental updates; or
- maintain totals from events when no historical query exists, accepting that usage before installation may be unknown.

ADELE should not create one universal durable event log merely so every notification is retrospectively queryable.

---

# 10. Structured composition extension points

Some extensions need to influence an operation before it happens. These should not be arbitrary mutable callbacks over opaque host objects.

Instead, the owner defines structured buckets into which plugins may contribute typed opinions/material.

Inference preparation is the clearest example.

The architecture should avoid APIs conceptually equivalent to:

```text
beforeInference(request) {
    mutate arbitrary request fields
}
```

Instead, inference is assembled through structured domains such as:

```text
inference intent/context

+ context material
+ agent-related state/instructions
+ model preference/routing state
+ reasoning/provider-option preferences
+ tool availability/materialization
+ policy constraints
+ strategy-specific material
+ other defined buckets

        -> host-owned resolution/composition
        -> stable resolved inference snapshot
        -> provider invocation
```

Core will define many broad inference buckets because it owns the provider-neutral invocation boundary. Plugins that host more specific ecosystems may define additional structured extension points of their own.

The buckets must remain extensible enough to accommodate new kinds of structured material without degenerating into unrestricted request mutation.

Exact conflict-resolution semantics are domain-specific. Restrictions may compose conservatively; preferences may use profile/default/priority policy; context material may preserve ordering and provenance. There is no assumption of one universal merge rule.

---

# 11. Priority and ordering

When ordering is meaningful, numeric priority is preferred over direct `before X` / `after Y` relationships.

Direct relative ordering creates unnecessary knowledge of other extensions and can evolve into an implicit dependency graph.

A priority scheme lets implementations express approximate placement without naming one another. An Extension Point may define conventions or bands such as early/normal/late ranges when useful.

Equal priorities must have deterministic secondary ordering, such as stable extension identity.

Not every Extension Point requires ordering. Ordering, default selection, and provider preference are separate concerns and should not be conflated.

---

# 12. Failure semantics belong to the Extension Point

There is no universal extension-failure rule.

Examples:

- Event subscriber failure normally does not fail the event producer.
- Decorative UI extension failure may omit that UI while retaining the parent surface.
- A selected Environment provider failing to provision means that provisioning operation failed.
- A mandatory security/policy participant failing may make it unsafe to proceed.
- A nonessential inference-context contributor may or may not be omittable depending on that contract.

Each Extension Point must define failure behavior appropriate to the semantic role it provides.

---

# 13. MVC-style separation of UI from functionality

ADELE should preserve a model/view/controller-like separation:

> UI presents domain state and offers trigger points for functionality; the UI contribution does not define the underlying operation merely because it exposes the button.

For example:

```text
Diff UI
    [Approve]
        -> review/SCM domain action
            -> Git implementation stages the hunk
```

The same underlying domain operation might later be invoked by:

- toolbar action;
- context menu;
- keyboard command;
- command palette;
- LLM tool;
- another plugin.

Likewise, the internal source viewer and an external-editor launcher may provide the same OpenSourceResource-shaped functionality with very different UI behavior.

This separation should keep UI replaceable and prevent workbench widgets from becoming hidden domain APIs.

---

# 14. UI composition is recursive

Core owns major workbench regions. Plugins may contribute content to those regions and define more specific regions inside their own surfaces.

Conceptually:

```text
ADELE center workspace
    -> Agent Interaction surface
        -> selected Chat strategy surface
            -> session header region
            -> timeline
            -> turn-action region
            -> prompt area
                -> prompt-accessory extension point
```

ADELE does not need to understand prompt accessories.

## 14.1 Host-rendered versus plugin-rendered UI

Host rendering is desirable for small structural pieces when it provides:

- native compiled performance;
- visual consistency;
- accessibility consistency;
- simpler plugin APIs;
- reusable default/alternate provider controls.

Examples may include command entries, simple status items, toolbar actions, separators, or common provider-selection controls.

Plugins may render arbitrary/bespoke UI when richer domain-specific presentation is valuable, including Chat, Diff, source viewing/editing, inspector bodies, artifact views, and console contents.

---

# 15. Project is an abstract core concept

Project is a core ADELE identity/lifecycle concept. A Project is **not intrinsically a local directory**.

The expected stock development installation will initially make local-directory projects the common experience, but that is one plugin-provided realization.

Conceptually:

```text
Project
    core identity/lifecycle

Project-opening implementations
    Local Directory
    future cloud-backed project
    future remote/source provider
```

A directory-opening plugin can use the operating-system directory picker and associate the chosen source/resource context with the Project.

A future provider could establish a Project around cloud-hosted state without changing the meaning of the core Project identity.

The existing mockup statement that a Project is fundamentally a directory should therefore be treated as describing the stock development composition, not the long-term core abstraction. Existing documentation should be reconciled after this direction stabilizes.

---

# 16. Task is a core object with plugin-attached behavior

A Task is an ADELE-owned durable unit of user intent.

Plugins may associate behavior/state with a Task without redefining Task identity.

Example:

```text
Task
├── primary Environment
├── Sessions
├── Git integration metadata/state
├── TODO/progress state
├── accounting/usage state
├── review artifacts/state
└── other plugin-owned state
```

The Task/Session management UI itself is expected to be a plugin. That UI may gather information from other active interfaces and present cost, progress, environment state, or other decorations without core understanding those particular visual concepts.

Workflow category/status remains user/domain-owned rather than being automatically inferred from agent success.

---

# 17. Environment is the practical execution/source context

The earlier separate `Workspace` abstraction is considered too speculative for the current direction.

For now, ADELE should use one Environment concept focused on the concrete execution/source context the agent works against.

An Environment initially needs to support the practical operations demanded by development, especially:

```text
filesystem/source access
process/command execution
```

Additional resource-isolation concepts should be introduced only when real application needs make their semantics concrete.

ADELE should not imply that an Environment provides stronger isolation than its implementation actually provides.

Examples:

```text
Git Worktree Environment
    filesystem rooted in worktree
    local process execution in that context
    does not inherently isolate ports/databases/etc.

Docker Environment
    container filesystem
    process execution inside container

Remote VM Environment
    remote filesystem
    process execution on remote machine
```

A tool such as `read_file` or `run_command` should operate through the current Environment's APIs rather than directly knowing about Git worktrees, Docker, VMs, or host paths.

---

# 18. Task and Environment relationships

A Task normally has one primary Environment.

Environment provisioning is itself expected to have multiple interchangeable providers:

```text
EnvironmentProvisioner
├── Git Worktree
├── Docker
└── future remote provider
```

Profiles/configuration can establish the default provider. Task-creation UI may offer alternatives when several are active.

A Task may also own additional Environments created programmatically for child agent work.

For example, one Session could create several child Sessions to independently attempt implementations with different models. Those child Sessions may share the primary Environment or use separately provisioned Environments, while all of those Environments remain associated with the parent Task's work.

Exact cleanup/recovery lifecycle remains to be designed when this behavior is implemented.

---

# 19. Session is a core container bound to one orchestration strategy

A Session is a core ADELE identity/lifecycle concept, but core should not assume every Session fundamentally consists of chat messages.

A Session is permanently bound to the orchestration strategy that created it.

Different strategies may define substantially different durable semantics:

```text
Chat Session
    user/agent conversation
    reasoning/tool activity
    draft request
    forks/compaction state

Goal Session
    goal
    iterations
    evaluations
    accepted/rejected attempts
    strategy-specific state
```

Common packages/components may provide reusable conversation, timeline, composer, or history primitives. Those do not make conversational history the universal definition of Session.

Changing orchestration strategy means creating another Session rather than converting the existing Session into a different semantic type.

Core owns general Session metadata and lifecycle; the bound strategy owns the semantic structure of its strategy-specific state.

---

# 20. Parent/child Sessions

A Session may create child Sessions for delegated work.

This does not introduce a separate Subtask domain concept.

Conceptually:

```text
Task
├── Session A
│   ├── child Session A.1
│   ├── child Session A.2
│   └── child Session A.3
└── Session B
```

A child Session may:

- share its parent's Environment;
- use another Task-associated Environment;
- use another orchestration strategy;
- receive an initial handoff/context;
- be inspectable without being directly user-steerable;
- be presented only by drilling into its parent Session/Task.

Some explicit operation may also create a normal user-interactable Session with a handoff, but ordinary child agent work should not become top-level Task creation.

## 20.1 Core session-creation functionality

Core should provide the authoritative create-Session operation/service because Session identity, parent linkage, strategy binding, persistence, and lifecycle are core concerns.

Directionally the operation may support inputs resembling:

```text
task
orchestration strategy
initial request/handoff
optional parent Session
environment choice:
    share/default
    explicitly selected existing Environment
    provision new Environment
interaction/presentation metadata when needed
```

An orchestration plugin may expose this core functionality as a model tool without owning Session creation itself.

---

# 21. Strategy-owned agent-interaction UI

An Agent Interaction plugin may occupy the primary center-workspace agent surface and provide an orchestration-strategy extension point.

Possible providers include:

```text
Chat strategy
Goal strategy
Ralph/loop-style strategy
future specialized strategies
```

The Agent Interaction plugin may provide strategy selection/hosting behavior, while the selected strategy owns its primary interaction surface.

Strategies may use common ADELE UI packages for timeline/composer/document behavior to reduce implementation complexity and preserve consistency where concepts overlap, but they remain free to present fundamentally different workflows.

A strategy plugin can register successfully even when no active Agent Interaction component consumes it. That is unhelpful but not an invalid plugin state.

---

# 22. Agent and model control are cross-cutting plugins

Names such as "Agent Selection" and "Model Selection" are too narrow if these plugins participate across configuration, UI, tools, and inference composition.

Directionally, an agent-related plugin may provide several independent extensions:

```text
agent definitions/configuration
settings UI
prompt-area UI
model-callable tools for changing active agent state
structured inference contributions
context/instructions
permission/tool constraints
presentation metadata
```

A model-policy/routing plugin may likewise provide:

```text
model-type definitions/configuration
provider/model mapping
settings UI
prompt-area UI
model-callable tools for changing model/reasoning state
structured inference preferences/constraints
```

The orchestration strategy does not need semantic knowledge of those prompt widgets.

A user UI change, an LLM tool call, configuration defaults, and other plugin logic may all update plugin-owned state that influences the next inference composition.

A plugin providing multiple related registrations may coordinate them through its own state. ADELE does not need to create special cross-links merely because those registrations originate from the same plugin.

---

# 23. LLM-directed model and agent choices

Orchestration strategies should not need hard-coded workflow stages that directly select concrete models or agents.

A strategy can contribute stock instructions recommending appropriate behavior, while model-callable tools allow the LLM to change semantic agent/model state during the workflow.

For example, a strategy may tell the model that architectural work often benefits from a stronger model type and then allow the model to invoke a model-control tool when it judges that appropriate.

The resulting state affects subsequent inference resolution.

This keeps orchestration general and lets the current agent make context-sensitive choices rather than embedding every future workflow into strategy code.

---

# 24. Stable inference snapshots

Inference composition resolves current configuration, plugin state, tool availability, context, model preferences, and other structured contributions into a stable semantic invocation snapshot.

Conceptually:

```text
current Session/plugin/configuration state
        -> structured inference composition
        -> resolved semantic inference snapshot
        -> provider invocation begins
```

Changes made after resolution affect the next appropriate inference rather than mutating an in-flight invocation.

This follows the broader ADELE direction that execution-sensitive operations retain stable resolved context where live mutation would make behavior unpredictable.

---

# 25. Tools are independent from Environment implementation

Tool plugins should consume Environment-level APIs rather than embedding environment assumptions.

For example:

```text
Filesystem Tool plugin
    -> Environment filesystem API

Command Tool plugin
    -> Environment process API

Search Tool plugin
    -> may use Environment filesystem/search primitives
       or Environment process execution depending on implementation
```

Several different search plugins may coexist:

- native structured search;
- command-backed `rg`/`grep` search;
- semantic/vector search.

A model tool is not automatically an ADELE Capability; one tool may project a broader Service into model-callable semantics, consistent with the current agent-kernel direction.

---

# 26. Tool-specific policy knowledge, core-owned authorization

A command tool illustrates the desired security layering.

Core cannot safely infer all command semantics by itself. The Command plugin may understand and describe details such as:

```text
executable/subcommand
filesystem targets
likely source mutation
network behavior
known/unknown effect scope
configured command restrictions
```

The tool/plugin supplies validated structured information needed for policy evaluation.

Core combines applicable policy/constraints and makes the authoritative allow/deny/ask decision.

Tool availability, semantic effect description, policy, human approval, environment isolation, and credential access remain distinct concerns.

---

# 27. Persistence is a host facility, not an exclusivity rule

ADELE should provide lifecycle-aware durable storage facilities for plugin-owned state scoped to domain identities such as Project, Task, Session, or Environment where appropriate.

This allows plugins to avoid inventing unrelated persistence systems merely to retain ordinary state.

However, ADELE should not insist that all authoritative state be duplicated into ADELE persistence.

Some integrations intentionally use external systems whose native persistence semantics are part of the feature.

Examples:

```text
Chat strategy state
    likely ADELE-managed durable storage

Accounting aggregates
    likely ADELE-managed durable storage

Git approved hunks
    Git index/staging is authoritative

Git branch/worktree
    Git/filesystem state is authoritative
    ADELE may retain identity/association metadata
```

The default is host-provided durability; domain-specific external authority may override that default when it is semantically appropriate.

Persisted plugin state should survive plugin deactivation where possible, consistent with profile/configuration direction.

---

# 28. Applying the model to expected stock plugins

The following examples are directional and are intended to test the extension architecture rather than freeze the final plugin catalog.

## 28.1 Local Directory Project

Provides a Project-opening/association implementation that uses an OS directory picker and associates a local source root with a core Project.

Core Project identity remains independent from the directory implementation.

## 28.2 Task Browser

Provides Task/Session management UI.

Consumes core Task/Session domain state and optional interfaces supplied by plugins to display additional information such as cost, progress, Environment status, or other decorations.

The browser should remain functional when such optional information is absent.

## 28.3 Agent Interaction

Provides the primary center-workspace host for agent interaction and defines an orchestration-strategy extension point.

It need not understand the internal semantics of each strategy.

## 28.4 Chat Strategy

Provides a conversational orchestration strategy and its complete interaction surface.

May define more specific extension points such as:

- prompt accessories;
- session-header additions;
- turn actions;
- timeline decorations or inspectors.

Uses agent-kernel primitives without becoming part of the kernel.

## 28.5 Session Forking

Likely extends Chat or another strategy-specific API because fork navigation and visible-history semantics are strategy-specific.

Core may provide generic Session creation/parenting primitives, while Chat-specific fork behavior remains outside core.

Exact representation of conversation forks should be designed when implemented rather than prematurely promoted into universal Session semantics.

## 28.6 Accounting / Usage

May subscribe to model/inference events, query retained usage history where available, maintain aggregates, and register UI displays in Session/Task surfaces.

It should not require the orchestration strategy to call it directly.

## 28.7 TODO / Progress

Provides model-callable TODO/progress operations and UI in appropriate right-sidebar and Task/Session surfaces.

Its state may be scoped to Session and/or Task depending on the final product semantics.

## 28.8 Plan

Provides model-callable plan operations and artifact/presentation UI.

The plan is a strategy/tool-owned artifact rather than an intrinsic property of every Session.

## 28.9 Diff / Review Viewer

Provides a center-workspace review surface.

May consume optional interfaces such as:

```text
OpenSourceResource
ReviewApprovalHandler
ReviewCommentTarget/consumer
other SCM/review operations
```

If no source-opening provider exists, files remain viewable in the diff but are not linkable into a source viewer.

If multiple source-opening providers exist, normal click may use the configured default while alternate actions expose others.

The Diff UI invokes domain operations; it does not define SCM approval semantics merely because it renders Approve/Unapprove controls.

## 28.10 Internal Source Viewer

Provides an OpenSourceResource-style implementation and rich center-workspace source UI.

Another plugin may provide the same callable interface by launching VS Code or another external editor.

## 28.11 Git integration

May provide several distinct extensions from one plugin:

- Git Worktree Environment provisioning;
- SCM/review operations;
- approve/unapprove behavior backed by staging;
- status/history information;
- model tools where appropriate;
- UI contributions where useful.

Other components consume the interfaces they need rather than depending on the Git plugin implementation itself.

## 28.12 Command Tool

Provides model-callable command execution through the active Environment's process API.

Also supplies tool-specific effect/policy interpretation and structured command progress/result projections.

Interactive user terminals may use related Environment process/PTY facilities but remain distinct runtime resources from agent command tool calls.

## 28.13 Model provider plugins

Providers such as OpenAI implement the common ModelProvider capability and expose one or more configured capability instances/accounts.

Model routing/policy is separate from the concrete provider implementation even when a provider contributes metadata useful to model selection.

---

# 29. Default installation versus architectural requirements

ADELE should ship with a coherent stock plugin set that produces a useful default software-development experience.

The architecture should nevertheless tolerate compositions that are technically valid but practically weak.

Examples:

- Chat active with no model tools;
- orchestration strategy registered with no consumer UI;
- Diff active with no source opener;
- multiple Environment providers with one configured default;
- no optional accounting plugin;
- no internal editor but an external editor provider.

This is intentional. The platform should not silently activate arbitrary plugins to manufacture usefulness.

Good defaults belong in installation/profile/configuration choices, not hidden runtime dependency chains.

---

# 30. Known tensions with existing documentation

This document intentionally changes or narrows some earlier speculative direction. Existing documents should not be mass-edited until this architecture has been reviewed and stabilized.

Known reconciliation items include:

## 30.1 Project equals directory

`docs/mockups/README.md` currently describes Project as fundamentally a directory. The intended long-term direction here is that Project is an abstract core concept and local-directory Project behavior is supplied by the stock development composition.

## 30.2 Workspace versus Execution Environment

`agent-kernel-semantic-model.md` currently distinguishes Workspace/source mutation scope from Execution Environment/effect scope.

The current direction is to avoid retaining a separate first-class Workspace concept until a concrete requirement demonstrates that ADELE needs that distinction.

Environment is initially the practical filesystem/source + process execution context. Stronger isolation dimensions should be added when real needs identify their semantics.

The kernel document should be reconciled after this direction stabilizes rather than immediately inventing replacement APIs.

## 30.3 Session history

Existing kernel wording describes Session as owning conversational context/canonical interaction history. The broader strategy model here means that conversational history should not become the universal semantic definition of Session.

Core Session identity/lifecycle remains; strategy-specific durable state defines what a particular orchestration Session consists of.

---

# 31. Design principles emerging from this direction

The following principles summarize the current intended boundaries:

1. Core owns durable identities/invariants; plugins provide most concrete behavior.
2. Extension is recursive: plugins may define typed extension points consumed by other plugins.
3. Prefer typed runtime discovery over activation dependency chains.
4. Depending on a shared interface/API is different from depending on a particular implementation plugin being active.
5. Zero, one, or many providers is a normal state for callable functionality.
6. ADELE usually owns contextual default-provider selection; UI may expose explicit alternatives.
7. Registrations are live for future composition, while resolved operations retain stable exact bindings.
8. Events are read-only fact notifications; subscriber failure normally does not fail the producer.
9. Operation-modifying integration uses structured typed composition, not arbitrary object mutation callbacks.
10. Composition/merge/failure semantics are specific to each Extension Point.
11. Numeric priority is preferred over direct before/after coupling where ordering is needed.
12. UI presents and invokes domain functionality; it does not define that functionality merely by rendering controls.
13. Core owns top-level workbench geometry; plugins may define nested UI regions and extension points within their surfaces.
14. Project, Task, Session, Run, and Environment are core domain concepts, but their concrete useful behavior is heavily plugin-driven.
15. Project is not intrinsically a local directory.
16. Task is an ADELE-owned durable user-intent object.
17. Environment is initially the practical filesystem/source + process execution context; stronger isolation remains evidence-driven.
18. A Task normally has one primary Environment and may have additional Task-associated Environments for child agent work.
19. Session is permanently bound to one orchestration strategy.
20. The strategy defines the semantic structure of strategy-specific Session state.
21. Child agent work uses parent/child Sessions rather than introducing speculative Subtask semantics.
22. Core provides authoritative Session creation/parenting; orchestration plugins may expose it as a tool.
23. Agent/model controls may participate independently in settings, UI, model tools, and structured inference composition.
24. LLMs may choose agent/model state through tools rather than requiring hard-coded workflow-to-model mappings.
25. Inference resolves into a stable snapshot; state changes affect subsequent inference.
26. Tool plugins operate through Environment APIs rather than knowing concrete Environment implementations.
27. Plugins may supply semantic policy information; final authorization remains host-owned.
28. ADELE provides persistence facilities by default, while domain-native external systems may remain authoritative where appropriate.
29. The stock installation provides useful composition; architectural validity does not require every useful complementary plugin to be active.
30. Do not implement speculative extension APIs merely because this long-term direction names a possible future extension point.

---

# 32. Deferred questions

This document intentionally does not yet settle:

- final public names for Extension Point / Extension / provider/contributor concepts;
- exact APIs for plugin-defined extension-point packages and version compatibility;
- whether some general interfaces should be moved into core public packages before multiple concrete consumers exist;
- exact generic registry infrastructure shared by Capabilities, Events, and other Extension Points;
- exact UI contribution descriptors versus arbitrary plugin-rendered widgets;
- exact priority ranges/metadata and deterministic ordering rules;
- exact provider-preference persistence and matching beyond the current profile/configuration direction;
- exact inference-composition bucket schemas and conflict-resolution rules;
- final Agent and model-control plugin names/responsibilities;
- final Environment API surface and lifecycle/recovery semantics;
- Task-associated additional Environment cleanup and persistence;
- exact child-Session interaction/presentation metadata;
- strategy-specific conversation forking semantics;
- generic history/query retention for model invocations, usage, and other events;
- exact plugin-scoped persistence APIs and schema migration;
- final review/SCM contracts;
- final source-resource/editor contracts;
- cross-platform plugin packaging and sandboxing.

These should be resolved from concrete implementation needs while preserving the broader boundaries above.

---

# 33. Near-term use of this document

This document is not an implementation milestone plan.

The immediate self-hosting effort should continue to implement the smallest useful verticals. When a near-term feature needs a boundary described here, implementation should choose the smallest concrete API that satisfies the current use while remaining compatible with the direction.

The purpose of this document is to make those small choices converge toward a coherent plugin-oriented product rather than hardening provisional stock behavior into ADELE core by accident.
