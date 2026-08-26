# Plugin and Extension Architecture Direction

## Status and purpose

**Guiding long-term product/architecture direction; not a frozen public API or implementation plan.**

ADELE is intended to remain useful and evolvable for years by making substantial parts of the product replaceable and composable through plugins. Configuration provides important flexibility, but configuration alone cannot provide the degree of substitution and experimentation ADELE is intended to support.

The existing repository has deliberately focused first on proving foundations: source plugins, frontend/backend runtime boundaries, generated typed transport, capability discovery and binding, provider-neutral agent-kernel semantics, and a minimal self-inspection agent vertical. Most existing plugins remain proofs, fixtures, or provisional implementations rather than a settled catalog of product plugins.

This document records the current direction for what should remain in ADELE core, what should normally live in plugins, how plugins may extend both ADELE and one another, and how the default development experience should be understood as one concrete composition rather than the definition of the platform.

It has two intentionally different levels of confidence:

1. **Architectural direction** describes boundaries and composition principles that currently appear durable.
2. **Expected stock plugin topology** applies those principles to a concrete, deliberately speculative plugin set so future implementation has a direction to converge toward rather than only abstract rules.

The concrete topology is useful precisely because it can be challenged. Plugin names, ownership boundaries, extension-point names, and even whether two proposed plugins remain separate may change as ADELE becomes self-hosting and real use exposes better boundaries.

This document is intentionally broader than the immediate self-hosting implementation. The near-term implementation should build only what it needs, but it should avoid boundaries that make the longer-term model unnecessarily difficult. Conversely, this document should not cause speculative APIs to be implemented before a concrete use requires them.

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
ADELE Main Content
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

For example, Task is core-owned, while a Git plugin may provide the Task's primary Environment implementation, Accounting may associate usage aggregates with the Task and its Sessions, TODO/Progress may associate progress state with individual Sessions, and a Task Browser plugin may provide semantic summary extension points through which those plugins enrich Task/Session presentation.

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

## 2.4 Workbench shell, commands, and input routing

The host owns the broad application shell and its current physical layout, including the title/chrome area, main work area, optional auxiliary areas, status/inspection space, and stream-oriented console space.

Those physical placements are **not** intended to become the semantic names of plugin extension points. The layout may evolve, become configurable, or move one semantic surface to another physical region without changing what a plugin says it contributes.

For example, a Session-status extension should remain a Session-status extension whether the stock UI currently renders it at the top of the right side, later moves it to the left, or allows the user to choose its location.

Core also owns application command and keyboard-input infrastructure:

- stable application Command identities and registration;
- command enablement/applicability plumbing;
- the Command Palette and command search/presentation;
- keybinding registration and resolution;
- plugin-suggested/default keybindings;
- user/profile/project keybinding overrides where supported;
- dispatch from menus, buttons, keybindings, or other UI affordances into the same Command operation.

Plugins may register Commands and suggested keybindings. The host owns how commands are discovered, displayed, rebound, and invoked.

Application Commands are not the same concept as the model-callable **Command Tool** that launches external programs. A UI Command is a host/controller trigger that should ordinarily invoke underlying domain functionality rather than define that functionality itself.

Plugins may fill host surfaces and may define more-specific semantic regions inside their own surfaces. Plugins do not normally invent new peer-level top-level workbench geometry outside the host shell.

## 2.5 Security authority

Plugins often know far more than core about the semantics of an operation. They may validate arguments, interpret configuration, derive effect descriptions, classify targets, or provide specialized policy inputs.

The authoritative allow/deny/ask decision remains host/core-owned.

A plugin may describe authority requirements; it must not grant itself authority merely because it understands the operation.

---

# 3. What normally belongs in plugins

The default rule remains that provider-specific, tool-specific, workflow-specific, integration-specific, and specialized UI behavior belongs in plugins.

Likely examples include:

- local-directory Project selection;
- Git-backed Environment lifecycle;
- Docker- or remote-backed Environment lifecycle;
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
- accounting/usage/quota aggregation;
- context monitoring/compaction behavior;
- Git integration;
- diff/review UI;
- source editors;
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

Examples may include an implementation answering `supports(resource)`, returning no contribution for an irrelevant inference, or always participating in a specific semantic UI surface.

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
DisplaySourceFile
    providers:
        Internal Source Editor
        VS Code Launcher

EnvironmentProvider
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

For example, Diff should not depend on the Internal Source Editor plugin.

Instead:

```text
Diff understands DisplaySourceFile

Current providers:
    none
        -> file remains visible but cannot be displayed through that action

    Internal Source Editor
        -> click displays/focuses internally

    Internal Source Editor + VS Code Launcher
        -> configured default may handle normal click
        -> alternate action may expose both
```

`DisplaySourceFile` intentionally does not imply that a new view must be opened. A provider may focus an already-visible editor, reveal a line in an existing view, create a new editor view, or delegate to an external editor as appropriate.

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

For example, a new source-display provider may become available to future clicks immediately, while an already-started model or tool invocation continues against the exact generation it was resolved against.

---

# 8. Host-owned default provider selection

A common ADELE convention is expected for interchangeable providers:

> The host owns contextual default-provider resolution; consumers may expose explicit alternatives when useful.

Configuration may influence the default based on profile, project, or other applicable context.

Examples:

```text
DisplaySourceFile
    default: Internal Source Editor
    alternate: VS Code

EnvironmentProvider
    default: Git Worktree
    alternate: Docker
```

A UI may invoke the configured default on its primary action while exposing alternatives through a menu, split button, context action, Command Palette, or other affordance.

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
- A selected Environment provider failing to establish an Environment means that lifecycle operation failed.
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
- keyboard Command;
- Command Palette;
- LLM tool;
- another plugin.

Likewise, the Internal Source Editor and an external-editor launcher may provide the same `DisplaySourceFile` functionality with very different UI behavior.

This separation should keep UI replaceable and prevent workbench widgets from becoming hidden domain APIs.

---

# 14. UI composition is recursive and semantically named

Core owns the current physical workbench geometry. Plugin-facing extension points should normally describe **what a contribution means**, not where today's layout happens to render it.

Conceptually:

```text
MainContentView
    -> Agent Interaction
        -> selected Chat strategy surface
            -> session header region
            -> timeline
            -> turn-action region
            -> prompt area
                -> prompt-accessory extension point

SessionStatusContribution
    -> TODO progress
    -> context usage
    -> usage/cost/quota where appropriate

InspectionPresentation
    -> tool detail
    -> resource detail
    -> structured operation detail

StreamView / Console presentation
    -> interactive shell
    -> full command output
```

The stock mockups currently render Main Content in the center, Session Status at the top of the right side, Inspection below it, and stream/console views in the bottom area. Those placements are implementation/UI direction rather than semantic API names.

A future layout may move those surfaces or allow user configuration without changing the extensions that plugins provide.

ADELE does not need to understand Chat prompt accessories or other plugin-defined nested regions merely because the Chat plugin exposes them.

## 14.1 Host-rendered versus plugin-rendered UI

Host rendering is desirable for small structural pieces when it provides:

- native compiled performance;
- visual consistency;
- accessibility consistency;
- simpler plugin APIs;
- reusable default/alternate provider controls.

Examples may include Command entries, simple status items, actions, separators, provider-selection controls, or keybinding editors.

Plugins may render arbitrary/bespoke UI when richer domain-specific presentation is valuable, including Chat, Diff, source editing, inspection bodies, artifact views, and consoles.

---

# 15. Project is an abstract core concept

Project is a core ADELE identity/lifecycle concept. A Project is **not intrinsically a local directory**.

The expected stock development installation will initially make local-directory projects the common experience, but that is one plugin-provided realization.

Conceptually:

```text
Project
    core identity/lifecycle

ProjectSelector implementations
    Local Directory
    Recent Projects
    future database/catalog-backed selector
    future cloud/remote selector
```

A `ProjectSelector` is about how a user or operation identifies the Project to work with, not about assuming every Project is created by a local filesystem picker.

The stock Local Directory selector can use the operating-system directory picker and establish/resolve a Project associated with the selected source root. A Recent Projects selector could present known Project identities. A future cloud provider could present Projects from a remote catalog.

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
│   └── session-owned progress/TODO state may be attached by a plugin
├── Git integration metadata/state
├── accounting/usage aggregates
├── review artifacts/state
└── other plugin-owned state
```

The Task/Session management UI itself is expected to be a plugin. It should not need to know how to query every plugin-specific domain merely to make its summaries richer. Instead, the Task Browser can define semantic extension points such as:

```text
TaskSummaryContribution
SessionSummaryContribution
TaskAction
SessionAction
```

Accounting, TODO/Progress, Git, Environment integrations, or future plugins can contribute applicable summary fragments or actions into those extension points. The browser composes the registered contributions into richer Task/Session presentation without understanding what each contribution means internally.

For example, Accounting may contribute cost/usage text, TODO/Progress may contribute a Session progress indicator, and another plugin may contribute status or warning information. Those are contributions **to** the browser's semantic summary model rather than data the browser actively gathers from each plugin.

Task-level TODO/progress is not part of the expected stock design. It may become useful later, but the near-term direction is that TODO/progress belongs to the Session whose agent is executing the work.

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

# 18. Environment providers own implementation lifecycle

A Task normally has one primary Environment.

The general extension shape should not imply creation-only behavior. Directionally, an `EnvironmentProvider` represents an implementation capable of owning the lifecycle of Environments it creates or recognizes.

That lifecycle may eventually include operations such as:

```text
create / establish
reopen / reconnect / validate
report state
release expensive live resources while preserving history
restore/reacquire when possible
destroy/delete underlying resources
```

The exact lifecycle depends on concrete needs. A Git worktree, Docker container, and cloud VM have materially different resource semantics, so core should not invent a lifecycle richer than current implementations require.

Multiple interchangeable implementations may be active:

```text
EnvironmentProvider
├── Git Worktree
├── Docker
└── future remote provider
```

Profiles/configuration can establish the contextual default. When user choice is useful, core can expose a reusable provider-selection control as part of a Task-creation or Environment-management flow without making the Task Browser semantically depend on Environment providers.

## 18.1 Task creation and Environment establishment are core-coordinated

The Task Browser may offer a `New Task` affordance and collect Task-owned data such as a title. It submits that intent to the core Task-creation operation.

The Task Browser should **not** directly orchestrate Git, Docker, or Environment creation.

Core Task creation owns the lifecycle sequence. As part of that sequence, the applicable/default `EnvironmentProvider` can establish the Task's primary Environment. The Git plugin therefore participates in Task creation through the Environment extension/lifecycle point rather than because the Task Browser calls Git.

Conceptually:

```text
Task Browser
    -> CreateTask(title, ...)

Core Task lifecycle
    -> create durable Task identity
    -> resolve applicable/default EnvironmentProvider
    -> provider establishes primary Environment
    -> associate Environment with Task
    -> publish settled Task/Environment facts
```

The exact transaction/recovery order remains deferred. For example, if Environment creation fails after a Task identity was persisted, core may retain a Task in an explicit incomplete/error state rather than pretending the Task never existed.

A Task may also own additional Environments created programmatically for child agent work.

One Session could create several child Sessions to independently attempt implementations with different models. Those child Sessions may share the primary Environment or use separately established Environments, while all of those Environments remain associated with the parent Task's work.

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
- be visible primarily from the parent Session that created it.

The ordinary Task Browser Session list should generally present user-level Sessions, not flatten agent-created children into the same navigation hierarchy. Child-session inspection belongs primarily inside the parent Session/orchestration experience, using common host components where that proves useful.

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
    share parent/default
    explicitly selected existing Environment
    establish new Environment
interaction/presentation metadata when needed
```

An orchestration plugin may expose this core functionality as a model tool without owning Session creation itself.

---

# 21. Strategy-owned agent-interaction UI

An Agent Interaction plugin may provide the primary agent-interaction `MainContentView` and an orchestration-strategy extension point.

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

Tool availability, semantic effect description, policy, human approval, Environment isolation, and credential access remain distinct concerns.

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

Session TODO/progress state
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

# 28. Expected stock plugin topology

This section deliberately becomes more concrete than the preceding architecture.

It is **not** a committed plugin catalog or implementation sequence. It is a current hypothesis for how a useful default ADELE development installation could be decomposed using the extension model above. The value of specifying it now is to expose unclear boundaries while they are still cheap to change.

A future implementation may merge plugins, split them further, rename them, move an interface from plugin-defined to core-defined, or discover that an expected extension point is unnecessary. Those changes are compatible with the purpose of this section.

## 28.1 Probable stock composition at a glance

A useful default installation currently looks approximately like:

```text
Core ADELE
│
├── Project / Task / Session / Run / Environment identities
├── workbench shell + settings
├── Command registry + Command Palette + keybinding system
├── plugin/extension runtime + default-provider selection
├── agent kernel + inference composition + policy authority
├── core Task/Session lifecycle
└── broad core extension points/capabilities/events

Stock project/task/environment plugins
├── Local Directory Project Selector
├── Task Browser
└── Git

Stock agent interaction plugins
├── Agent Interaction
├── Chat Strategy
├── Session Forking
├── Agent Configuration / Policy
├── Model Routing / Control
├── Context Monitoring / Compaction
└── Accounting / Usage / Quota

Stock model-tool plugins
├── Filesystem Tools
├── Search Tools
├── Command Tool
├── TODO / Progress
└── Plan

Stock review/presentation plugins
├── Diff / Review Viewer
├── Internal Source Editor
└── Console / Terminal

Stock model providers
└── OpenAI
```

Some of these may ultimately be combined. For example, Session Forking could remain part of Chat if no independent lifecycle is useful, and a small stock Search implementation could live with Filesystem Tools. They are shown separately here because they represent replaceable responsibilities worth reasoning about independently.

## 28.2 Likely core-defined extension surfaces used by the stock plugins

The exact names are intentionally provisional. More important than the names is that UI extension points describe semantic roles rather than current physical placement.

### Workbench/UI semantics

```text
MainContentView
    primary substantial work content
    stock placement: center work area

NavigationView
    contextual navigation/browsing/results
    stock placement: optional left auxiliary area

SessionStatusContribution
    compact state about the active Session/work
    stock placement: upper right status area

InspectionPresentation
    structured detail opened by inspecting an operation/resource
    stock placement: lower right inspection area

StreamView / ConsolePresentation
    wide stream-oriented or terminal-like content
    stock placement: bottom area

ContextStatusContribution
    compact state about active Project/Task/Environment/profile context
    stock placement may include title/chrome

Settings declaration/editor contribution
    settings metadata or bespoke editing UI
```

These semantic names should survive layout changes. For example, moving `SessionStatusContribution` from the right side to a left region does not require renaming or redefining the extension point.

Not every plugin-owned user experience must be expressed as one of these workbench surfaces. A plugin may own a higher-level selection or setup experience that temporarily replaces the normal workbench, launches a dedicated window/dialog, or otherwise presents bespoke UI before an active Task/Session exists. `ProjectSelector` and the probable Task Browser experience are examples of this distinction.

### Application commands and keybindings

Core should expose first-class infrastructure conceptually resembling:

```text
Command registration
Command Palette/search
Command applicability/enabled state
suggested/default keybinding registration
user/profile/project keybinding override resolution
```

Plugins register Commands that invoke their domain functionality and may suggest default keybindings. Core owns collision handling, rebinding, presentation, and dispatch.

A plugin-rendered button should normally invoke the same Command/domain operation that could be triggered by the Command Palette or a keybinding rather than creating a UI-only implementation path.

### General callable capabilities/services

```text
ProjectSelector
EnvironmentProvider
Environment filesystem access
Environment process execution
DisplaySourceFile
ConsoleService / console-resource operations
ModelProvider
core Task creation
core Session creation
```

`ProjectSelector` is intentionally broader than a Project opener. Different selectors may use an OS file picker, recent Projects, a custom catalog, a database, or a remote service.

`EnvironmentProvider` owns the lifecycle of its Environment implementation rather than only initial provisioning.

`DisplaySourceFile` means make a source file visible at an appropriate location. It may focus an existing editor, create a new editor view, or launch an external editor.

`ConsoleService` is intentionally broader than `OpenTerminal`. Depending on the resource, it may support creating a console, displaying/focusing it, attaching retained output, sending input/commands, or other console operations. Exact APIs should come from concrete use rather than treating "open" as the whole abstraction.

### Agent/tool composition

```text
model tool registration/materialization
structured inference-context contribution
model/provider preference and constraint buckets
tool availability / policy constraint input
provider-neutral model invocation
core execution events
```

The exact inference buckets remain intentionally open, but the default plugins below make it clear that one undifferentiated `modifyRequest` callback would not be sufficient.

### Common events

Likely broadly useful facts include concepts such as:

```text
ProjectSelected / ProjectOpened
TaskCreated
SessionCreated
RunStarted / RunSettled
ModelInvocationStarted / ModelInvocationSettled
ToolInvocationStarted / ToolInvocationSettled
EnvironmentCreated / EnvironmentReleased / EnvironmentDisposed
```

These names do not imply that every event must be persisted.

## 28.3 Local Directory Project Selector plugin

**Role**

Provides the stock way to select a development Project from a local directory.

**Likely provides**

- a `ProjectSelector` implementation;
- OS directory-selection UI when invoked;
- resolution/creation of a core Project associated with the chosen local source root;
- persistent association between the core Project and the chosen local source root where needed;
- Project display metadata derived from the directory when useful.

**Likely consumes**

- core Project identity/lifecycle;
- host file/directory picker integration;
- Project persistence facilities;
- general Project-selection Commands/UI.

**Does not own**

- Task identity;
- Environment lifecycle;
- Git semantics;
- source editing.

A directory Project may not be a Git repository at all. Git integration becomes applicable independently when its own conditions are satisfied.

**Future alternatives**

Other `ProjectSelector` implementations could present Recent Projects, query a custom Project database, display Projects from a cloud service, or implement another selection experience without changing core Project semantics.

## 28.4 Task Browser plugin

**Role**

Provides the Project/Task/Session selection and management experience represented by the mockups.

This is presentation over core Project/Task/Session identities rather than the implementation of those domain objects. It is also **not assumed to be a `MainContentView`**. Before a Task/Session is selected there may be no normal active-session workbench at all, so the Task Browser may own a dedicated Project-level screen/window/shell in much the same way that the Local Directory Project Selector can present an OS-native picker.

A future UI may instead embed the same Task Browser experience inside the normal workbench or make the transition configurable. The plugin API should not encode either presentation choice prematurely.

**Likely provides/defines**

- Project-level Task/Session selection experience, using whatever presentation model proves appropriate;
- Task selection UI;
- `New Task` affordance and Task-owned input such as title/description;
- top-level/user Session listing, selection, and creation UI;
- plugin-defined extension points for Task summaries, Session summaries, Task actions, and Session actions where concrete needs justify them.

Possible plugin-defined interfaces might conceptually resemble:

```text
TaskSummaryContribution
SessionSummaryContribution
TaskAction
SessionAction
```

A summary contribution is a plugin-supplied fragment of the Task/Session summary presentation—text, icon/status, compact structured value, or richer UI as that extension point allows. The Task Browser composes all applicable contributions; it does not query each contributing plugin for domain-specific state through bespoke integrations.

Numeric priority can order summary fragments/actions where necessary without one plugin naming another.

**Likely consumes**

- core Project/Task/Session query and mutation services;
- core Task-creation operation;
- core Session-creation operation;
- registered Task/Session summary and action contributions.

**Does not orchestrate Environment creation**

When the user creates a Task, Task Browser sends the Task intent to core. Core's Task lifecycle independently resolves the applicable/default `EnvironmentProvider` and establishes the primary Environment. Task Browser does not call Git or Docker and does not need to understand which Environment implementation is selected.

If the stock Task-creation experience exposes an Environment-provider choice, that can be a reusable core provider-selection control associated with the core Task-creation flow rather than Environment-specific logic inside Task Browser.

**Environment visibility while browsing**

While the user is merely browsing Tasks/Sessions there may be no active Environment at all. An Environment-related plugin can contribute Environment status to a Task summary if that is useful; Task Browser itself need not consume an active Environment or understand Environment-specific state.

**Expected stock integrations**

- Accounting contributes Task/Session cost or usage summary fragments;
- TODO/Progress contributes progress to applicable Session summaries;
- core or a general status adapter can provide active/waiting information;
- Git/Environment plugins may contribute compact Task status when useful.

Agent-created child Sessions are **not** expected to be normal peers in the Task Browser Session list. Their inspection belongs primarily within the parent Session that spawned them.

**Without complementary plugins**

The browser still shows core Tasks and top-level Sessions. Missing cost, progress, SCM, Environment, or other summary contributions simply disappear.

## 28.5 Git plugin

**Role**

Provides Git-specific development behavior without making Git part of core Task, Environment, review, or source-editing semantics.

One Git plugin may legitimately provide many independent extensions.

**Likely provides**

### Git Worktree Environment provider

For the stock local-development configuration, core Task creation normally resolves Git Worktree as the default applicable `EnvironmentProvider`.

The Git provider approximately creates/manages a worktree and usually a corresponding branch, exposes the resulting Environment through the general Environment filesystem/process interfaces, and owns lifecycle operations appropriate to that Environment.

Lifecycle may include creating/reconnecting to the worktree, validating that it still exists, releasing ADELE-held resources, and deleting the worktree/branch state when the user explicitly destroys the Environment. Exact destructive behavior must be conservative and designed with real workflows.

The equality of Task/environment/worktree/branch names may be a useful convention, not a core invariant.

### SCM/change data for review

The Git plugin is the expected stock provider of whatever typed interface the Diff/Review Viewer uses to obtain change sets and diff content.

Directionally this could be an interface defined by the Diff/Review ecosystem rather than by core:

```text
ChangeSetSource / DiffSource
```

### Approval/unapproval implementation

The Git integration implements review approval semantics by using the Git index/staging area as authoritative state.

The Diff Viewer can invoke an abstract review/change-approval interface while Git maps:

```text
approve hunk/file   -> stage corresponding change
unapprove           -> unstage corresponding change
```

The UI does not need to know that staging is the storage mechanism.

### Other Git functionality

The plugin may additionally provide:

- status information;
- SCM-oriented model tools;
- commit operations;
- Task-summary or context-status contributions;
- application Commands and suggested keybindings;
- inspectors.

Those are independent registrations rather than reasons to move Git into core.

**Likely consumes**

- local Project/source-root information where applicable;
- core Environment lifecycle contracts;
- Diff/Review plugin-defined interfaces if Diff owns those contracts;
- semantic workbench/status/Command extension points;
- Task Browser summary/action extension points when contributing Project/Task status;
- core policy for any model-callable side-effecting operations.

**Without complementary plugins**

Git Environment behavior can remain useful even if Diff is disabled. Git review interfaces can remain registered even if nobody consumes them.

## 28.6 Agent Interaction plugin

**Role**

Provides the primary agent-interaction `MainContentView` and hosts whichever orchestration strategy a Session is permanently bound to.

**Likely provides/defines**

- high-priority `MainContentView` contribution for agent interaction;
- orchestration-strategy extension point/catalog;
- Session-creation UX for selecting among available strategies when more than one applies;
- strategy-hosting lifecycle and common framing around the selected strategy surface;
- perhaps reusable parent/child Session inspection framing if experience shows that this is strategy-independent.

A strategy registration likely needs enough metadata/functionality to support concepts such as:

```text
strategy identity/version
display metadata
create/initialize strategy-owned Session state
render/host strategy interaction surface
run/continue strategy behavior
strategy-specific persistence hooks or service access
```

The exact contract should be designed from the first real strategy extraction rather than frozen here.

**Likely consumes**

- core Session identity/lifecycle;
- registered orchestration strategies;
- core create-Session operation;
- `MainContentView` host APIs.

**Does not need to understand**

- Chat prompt widgets;
- agent selection;
- model selection;
- TODO semantics;
- Git;
- the internal data model of a Goal or other future strategy.

**Without strategy providers**

The Agent Interaction plugin can be active but unable to create a useful agent Session. Conversely, a Chat strategy can be registered with no Agent Interaction consumer. Neither condition should force plugin activation changes.

## 28.7 Chat Strategy plugin

**Role**

Provides the expected initial orchestration strategy: a conventional conversational model/tool/model loop with a rich Chat-oriented Session surface.

It is the likely long-term home of the behavior currently represented by the provisional application `DevelopmentToolLoopStrategy`, using `agent_kernel` execution primitives rather than defining kernel semantics.

**Likely provides**

- an orchestration-strategy registration to Agent Interaction;
- Chat-specific durable Session state;
- Chat timeline UI;
- Draft Request/composer behavior;
- presentation of user/agent messages and operation groups;
- child-Session activity/inspection within the parent Session experience when Chat creates delegated Sessions;
- strategy-specific continuation behavior;
- Chat-specific events such as `ChatTurnCompleted` if useful.

**Likely defines plugin-facing extension points inside its surface**

Directionally these may include:

```text
ChatPromptAccessory
ChatSessionHeaderContribution
ChatTurnAction
ChatTimelineDecoration / ChatOperationPresentation
```

The exact set should remain driven by real stock integrations. The important architectural point is that Chat can define these regions without core understanding them.

**Likely consumes**

- agent-kernel Run/model/tool execution services;
- structured inference composition;
- model/tool catalogs;
- core Session persistence facilities;
- core child-Session query/creation facilities;
- common timeline/composer UI packages;
- optional tool-presentation providers;
- optional review-feedback interfaces when another plugin wants to send structured feedback into the active Chat Session.

**Expected stock integrations**

- Agent Configuration adds prompt/header UI and inference context/policy;
- Model Routing adds prompt controls and inference preferences;
- Context Monitoring adds context status/compaction actions;
- Accounting can add usage/cost/quota displays;
- TODO/Progress can show Session progress through semantic Session-status surfaces without Chat needing to understand it;
- Session Forking adds Chat-specific fork navigation/actions;
- Diff/Review can submit review feedback when Chat exposes or implements the expected feedback target.

**Without complementary plugins**

Chat remains a valid strategy with no prompt accessories and even with no model tools. The default installation should not normally be configured that way.

## 28.8 Session Forking plugin

**Role**

Adds conversation-fork navigation and creation to strategies that expose compatible branching semantics, initially Chat.

This remains more speculative than the base Chat strategy because conversation forks may turn out to be best implemented inside Chat itself.

**Likely provides**

- Chat turn action(s) for forking from a selected point;
- fork navigation UI in turn markers or another Chat-defined region;
- durable fork/lineage metadata;
- Commands for navigating branches and suggested keybindings where useful.

**Likely consumes**

- Chat-specific extension APIs;
- Chat strategy state/history cloning or branching facilities;
- perhaps core Session cloning/creation primitives if the eventual representation uses linked Sessions.

The architecture should not prematurely require forks to be represented as core Sessions. If Chat can represent them more cleanly inside strategy-owned state, that is preferable until another orchestration strategy demonstrates common semantics.

**Without Chat or another compatible strategy**

The plugin's registrations are simply unused.

## 28.9 Agent Configuration / Policy plugin

The name remains provisional because "Agent Selection" understates the responsibility.

**Role**

Defines and manages semantic agent choices and lets those choices affect UI, context assembly, tool access, and inference without requiring orchestration strategies to understand agent semantics.

**Likely provides**

- persistent Agent definitions/configuration;
- settings UI for managing Agents;
- Chat prompt/header control when Chat is active;
- model-callable tool(s) for changing the active Agent state;
- structured inference context contributions containing Agent instructions/persona/stock context;
- tool-availability or policy constraints associated with the Agent;
- display metadata such as current Agent label;
- perhaps Agent-related application Commands.

**Likely consumes**

- core configuration/persistence;
- Chat-defined prompt/header extension points, optionally;
- core model-tool registration;
- structured inference composition buckets;
- tool policy/composition inputs;
- core Session context so active Agent state can be Session-specific where appropriate.

**Important separation**

Chat does not call an `AgentSelector` and does not need to know what an Agent is. The plugin independently participates in the areas where Agent state matters.

**LLM-driven changes**

The active model may invoke a tool such as a semantic `select_agent` operation. That changes Agent plugin state for subsequent inference; it does not mutate the current model invocation.

## 28.10 Model Routing / Control plugin

The name remains provisional because "Model Selection" similarly understates its responsibility.

**Role**

Provides user-meaningful model/reasoning choices and maps them to concrete provider/model invocation preferences.

The expected UX should generally expose semantic choices such as "Fast" or "Powerful" rather than forcing users to choose provider-specific model IDs for every Session.

**Likely provides**

- semantic model-type definitions/configuration;
- mapping from semantic model type to concrete ModelProvider/configured instance/model;
- reasoning/thinking preference configuration where applicable;
- settings UI;
- Chat prompt-area controls when Chat is active;
- model-callable tools for changing model type/reasoning preference;
- structured inference contributions/preferences that participate in resolving the next invocation;
- perhaps provider/model metadata to other consumers.

**Likely consumes**

- active ModelProvider capabilities and configured instances;
- provider model catalogs/metadata where available;
- core default-provider/preference configuration;
- Chat prompt extension points, optionally;
- core tool registration;
- structured inference composition.

**Default versus explicit choice**

Configuration establishes defaults. UI and LLM tool calls can place more specific Session-level state on top. Host/inference resolution combines those structured inputs according to the eventual model-routing rules.

**Without this plugin**

A strategy could still use a configured ModelProvider's own default model/options. This plugin improves routing and UX rather than making model invocation conceptually possible.

## 28.11 Context Monitoring / Compaction plugin

**Role**

Observes or derives the effective context expected for upcoming inference, exposes context-window usage, and provides explicit compaction/summarization behavior.

**Likely provides**

- Session-level context usage/status information;
- `SessionStatusContribution` showing approximate context usage;
- Chat turn action/button for compacting history through a selected turn;
- Commands/tools for requesting compaction if useful;
- structured inference contribution representing retained compaction/summarization state;
- perhaps `InspectionPresentation` explaining context composition.

**Likely consumes**

- core context/inference-composition query or preview facilities;
- selected model metadata such as context-window limits when available;
- Chat header/turn-action extension points, optionally;
- Session persistence;
- model invocation services if compaction itself requires inference.

The exact compaction model should not be designed merely from this document. What matters directionally is that context monitoring/compaction is replaceable and does not need to be hard-coded into Chat.

## 28.12 Accounting / Usage / Quota plugin

**Role**

Tracks model usage, computes cost where sufficient pricing information exists, and presents provider/account quota or allowance consumption when providers expose enough information.

The three concepts are related but not identical:

```text
usage
    tokens / requests / other measured consumption

cost
    monetary estimate/actual based on provider/model pricing

quota / allowance
    provider/account limits, subscription allowances, rate-limit windows,
    remaining capacity, reset time, or analogous provider-specific constraints
```

**Likely provides**

- usage/cost aggregation service/query;
- provider/account quota-status aggregation/query where available;
- Session-level usage/cost display;
- optional per-turn usage/cost presentation;
- `TaskSummaryContribution` and/or `SessionSummaryContribution` for aggregate usage/cost where useful;
- `SessionStatusContribution` or `ContextStatusContribution` for quota/allowance status where appropriate;
- settings for cost/quota display and accounting policy if needed.

**Likely consumes**

- model-invocation usage events and/or retained invocation history;
- provider/model pricing metadata where available;
- provider/account quota/rate-limit/status interfaces where available;
- core Session/Task identity;
- Chat header/turn presentation extension points, optionally;
- Task Browser summary extension points, optionally;
- semantic status surfaces;
- ADELE persistence when maintaining derived aggregates.

**Historical behavior**

If canonical invocation history retains enough usage data, Accounting can reconstruct historical totals by query. If not, an implementation may subscribe to live events and only know usage from the point it began observing. The Event abstraction itself does not promise replay.

Quota status is often inherently provider-live rather than derivable from local history. The plugin may query current provider/account information instead of persisting it as authoritative state.

**Failure isolation**

Accounting or quota-display failure should not ordinarily fail the model invocation whose usage it is observing.

## 28.13 Filesystem Tools plugin

**Role**

Provides high-value structured model tools for source/filesystem operations without binding those tools to a concrete Environment implementation.

**Likely provides**

Tools directionally resembling:

```text
list_directory
glob
read_file
apply_patch
write_file
delete_file
```

The exact catalog remains governed by `agent-tooling-direction.md` and concrete implementation needs.

The plugin may also provide tool-specific Chat summaries, `InspectionPresentation`s, and source-display actions through whatever tool-presentation extension model emerges.

**Likely consumes**

- current Run/Session Environment binding;
- Environment filesystem API;
- model-tool registration/materialization;
- core policy/approval pipeline;
- `DisplaySourceFile` for rich inspection when available;
- tool-presentation/inspection extension points.

**Policy role**

The plugin can precisely describe read/write targets and mutation intent, allowing core policy to make better decisions than it could for arbitrary commands.

**Without a usable Environment filesystem interface**

The tools are unavailable for that operation; the plugin does not fall back to unrelated host filesystem access behind the Environment abstraction.

## 28.14 Search Tools plugin(s)

**Role**

Provides structured search capabilities to the model and potentially explicit user search UI.

Several implementations may coexist because "search" is not one implementation strategy.

Possible plugins/variants include:

```text
native structured text search
command-backed rg/grep search
semantic/vector search
future language-aware search
```

The default installation likely needs only one simple structured implementation initially.

**Likely provides**

- one or more model search tools;
- structured search results;
- `InspectionPresentation` for search results;
- perhaps a `NavigationView` for explicit user search results;
- application Command(s) and suggested keybindings for explicit search.

**Likely consumes**

- Environment filesystem/search access;
- or Environment process execution for command-backed implementations;
- model-tool registration;
- `DisplaySourceFile` so result clicks can show/focus files when a provider exists;
- navigation/inspection UI extension points.

**Without a source-display provider**

Search results remain readable but file navigation/display is unavailable.

## 28.15 Command Tool plugin

**Role**

Provides the universal model-callable external-program execution escape hatch described in `agent-tooling-direction.md`.

**Likely provides**

- `run_command`-style model tool;
- structured command invocation identity/state;
- streaming progress/output observations;
- bounded model-facing results;
- Chat activity summary;
- `InspectionPresentation`;
- "show full output" integration when a Console provider is available;
- command-specific effect and policy interpretation.

**Likely consumes**

- current Environment process-execution API;
- model-tool registration;
- core policy/approval pipeline;
- inspection APIs;
- optional `ConsoleService` for full-output presentation and related console operations.

**Policy role**

The Command plugin can parse/understand its own invocation representation, configuration, executable allow/deny rules, and known command semantics. It provides structured effect information to core; it does not authorize itself.

**Without Console/Terminal**

The command tool still runs and can present bounded output in Chat/Inspection. Only the richer console projection is absent.

## 28.16 TODO / Progress plugin

**Role**

Provides the agent-managed work-item list used to communicate progress within an individual Session.

The expected stock semantics are **Session-scoped**, not Task-scoped.

A Session's orchestration may use TODOs as its visible execution checklist while another Session in the same Task maintains an independent list.

**Likely provides**

- model tools for creating/updating/completing/reordering TODO items;
- Session-scoped TODO/progress storage/query service;
- `SessionStatusContribution` showing current Session progress;
- `SessionSummaryContribution`, such as compact progress for an active Session in Task Browser;
- perhaps Chat/header progress UI if later useful.

**Likely consumes**

- core Session identity/lifecycle;
- model-tool registration;
- Session-scoped ADELE persistence;
- semantic Session-status surface;
- optional Task Browser `SessionSummaryContribution` extension point.

**Not currently expected**

- one canonical Task TODO list;
- automatic Task workflow-category changes based on TODO completion.

A Task-level TODO concept can be introduced later if real use demonstrates a need rather than making the initial plugin ambiguous between two scopes.

## 28.17 Plan plugin

**Role**

Provides a durable, model-editable plan as a Session artifact rather than making every Session intrinsically own a plan.

**Likely provides**

- model tools to read/write/update the current plan;
- Session-scoped plan persistence or artifact identity;
- `MainContentView`/artifact presentation;
- application Command(s) and suggested keybindings for displaying the plan;
- perhaps inspection summaries.

**Likely consumes**

- core Session identity;
- model-tool registration;
- host persistence/artifact facilities;
- Main Content/artifact UI extension points.

**Without the plugin**

Strategies continue to function without a formal plan tool.

## 28.18 Diff / Review Viewer plugin

**Role**

Provides the rich review experience shown in the mockups without embedding Git or editor assumptions.

**Likely provides/defines**

- singleton Diff/Review `MainContentView`;
- scope controls such as current changes, staged/approved changes, or other review sets as supported by the active change provider;
- change/hunk rendering and comment UI;
- plugin-defined typed interfaces for obtaining reviewable changes and invoking review-domain operations where those concepts are not sufficiently general for core.

Likely plugin-defined contracts may conceptually include:

```text
DiffSource / ChangeSetSource
ReviewApprovalHandler
ReviewCommentReceiver / ReviewFeedbackTarget
```

The final split should follow the actual review workflow rather than these placeholder names.

**Likely consumes**

- one or more change/diff providers, with Git expected as the stock implementation;
- optional approval/unapproval provider;
- `DisplaySourceFile` for displaying/focusing the complete source file;
- optional review-feedback receiver implemented by the active orchestration strategy;
- Main Content APIs;
- application Commands/keybindings.

**Default Git integration**

```text
Diff data             <- Git
Approve/Unapprove     <- Git staging/index implementation
Display file          <- Internal Source Editor by default
Review comment        -> active Chat strategy feedback receiver, when available
```

**Graceful degradation**

- no `DisplaySourceFile`: filename/file affordance is not navigable into a source editor;
- no approval provider: diff still displays but approval controls are absent/disabled;
- no review-feedback receiver: comment-to-agent affordance is unavailable;
- no Git but another compatible change provider: Diff can remain useful.

The Diff Viewer defines presentation and review interaction. It does not define Git staging semantics merely because the stock Git plugin supplies them.

## 28.19 Internal Source Editor plugin

**Role**

Provides ADELE's stock in-app source display **and editing** experience.

Hand-editing is an intended part of the development workflow, not merely a hypothetical later enhancement. Users should be able to inspect a file in full context and make manual edits when that is the fastest or clearest way to proceed.

**Likely provides**

- `DisplaySourceFile` provider;
- one or more source-editor `MainContentView`s / Source Group views;
- source editing and save behavior through the active Environment;
- syntax highlighting and source navigation;
- application Commands and suggested keybindings;
- dirty-state/conflict handling appropriate to Environment/source semantics;
- perhaps richer source-inspection/navigation capability to tool/diagnostic presenters.

`DisplaySourceFile` may focus an already-displayed editor rather than creating a duplicate view. Inputs may eventually include a line/range/selection to reveal.

**Likely consumes**

- current Environment filesystem/source APIs;
- Main Content/source-group hosting;
- Command/keybinding infrastructure;
- optional language/search/navigation services later.

**Multiple providers**

An External Editor plugin can provide the same `DisplaySourceFile` capability by displaying the file in VS Code or another editor. Host configuration chooses the default, while callers may expose alternatives.

The default internal provider being editable does not require every `DisplaySourceFile` provider to expose identical editing APIs; the capability's narrow responsibility is to make the requested source file visible through that provider.

## 28.20 Console / Terminal plugin

**Role**

Owns console/terminal presentation and user-created interactive shells without reducing the abstraction to a one-shot "open terminal" action.

**Likely provides**

- `StreamView` / console presentation;
- creation/management of interactive Environment-owned shell resources;
- `ConsoleService` or equivalent operations for displaying/focusing console resources;
- sending input/commands to interactive console resources when allowed;
- attaching/displaying retained command output in a read-only terminal presentation;
- `+` or similar UI for creating user shells;
- application Commands/keybindings for creating, focusing, closing, or navigating consoles.

**Likely consumes**

- Environment process/PTY facilities;
- Stream/Console host APIs;
- runtime-resource lifecycle;
- command invocation output/resource references for inspected agent commands.

**Important separation**

Interactive user shells and agent command invocations may share terminal rendering and Stream presentation but remain different semantic resources.

`ConsoleService` should not imply that every console supports every operation. A retained read-only command-output console cannot meaningfully accept arbitrary input, while an interactive shell can. The service/resource contract should expose capabilities appropriate to the specific resource.

## 28.21 OpenAI provider plugin

**Role**

Provides concrete OpenAI model inference and account/configuration behavior.

This is closest to a mature real plugin in the current repository and should continue to remain provider-specific rather than leaking OpenAI semantics into core.

**Likely provides**

- common `ModelProvider` capability;
- one or more configured provider/account instances;
- authentication/account configuration UI;
- model catalog/capability metadata where useful;
- usage metadata emitted with model results;
- provider/account quota/rate-limit/allowance information where available;
- perhaps pricing information or a pricing interface that Accounting/Model Routing can consume.

**Likely consumes**

- ADELE configured-instance/configuration infrastructure;
- credentials/secrets facilities;
- generated typed provider transport;
- core provider registration/binding.

**Does not own**

- semantic "Fast"/"Powerful" model types;
- global model default policy;
- Agent definitions;
- Chat orchestration.

Those remain separate so another provider can participate without requiring stock interaction plugins to understand OpenAI.

## 28.22 External Editor plugin example

This is useful as a concrete optional example because it tests provider substitution.

**Role**

Displays a source file in an external editor such as VS Code.

**Provides**

- another `DisplaySourceFile` provider.

**Consumes**

- source-resource/Environment path material sufficient to launch or focus the external editor;
- Environment/local-path projection only when the current Environment supports such a projection;
- process launching/desktop integration as appropriate.

With both Internal Source Editor and External Editor active, ADELE configuration can select the default while Diff/Search/etc. may expose the alternate provider.

No consumer needs to know either implementation by plugin identity.

## 28.23 Docker Environment plugin example

This is another useful substitution example even if it is not part of the first self-hosting subset.

**Role**

Provides an alternative Task Environment backed by a container rather than a Git worktree/local process context.

**Provides**

- `EnvironmentProvider` implementation;
- Environment filesystem API backed by the container;
- Environment process execution backed by the container;
- Environment lifecycle operations such as create/reconnect/release/destroy as concrete Docker behavior requires;
- perhaps PTY/resource support.

**Consumes**

- Project/source material needed to construct the container Environment;
- Docker runtime integration;
- core Environment lifecycle APIs;
- configuration for image/build/mount behavior.

Filesystem, Search, Command, and Internal Source Editor plugins continue working against the resulting Environment without knowing that Docker is involved.

---

# 29. Concrete default interaction flows

Walking the expected stock composition through normal workflows helps expose where interfaces actually need to exist.

These flows are illustrative rather than frozen sequence diagrams.

## 29.1 Select/open a Project

```text
User chooses Select/Open Project
    -> host/default routing chooses Local Directory Project Selector
    -> Local Directory selector shows OS directory picker
    -> selected directory resolves/creates core Project identity
    -> plugin associates local source root with Project
    -> Project-level selection experience becomes available
```

Another selector could instead show Recent Projects or a remote catalog. Git may independently recognize that the resulting Project is Git-backed and register applicable behavior. Project identity does not depend on that discovery.

## 29.2 Create a Task with the stock Git Environment

```text
Task Browser: New Task
    -> Task Browser gathers Task-owned input such as title
    -> calls core CreateTask
    -> core creates durable Task identity
    -> core Task lifecycle resolves applicable/default EnvironmentProvider
    -> configured default is Git Worktree
    -> Git establishes primary Task Environment
    -> core associates Environment with Task
    -> Task creation settles
    -> Task Browser may select/display the new Task
```

Task Browser never calls Git directly and does not need to know how the primary Environment is created.

If Docker is also active and the product exposes provider choice at creation time, the host can provide a generic Environment-provider choice as part of the core Task-creation flow. If the selected provider fails, Task lifecycle needs explicit recovery semantics rather than silently falling back to another provider behind the user's choice.

Destroying or releasing a Task Environment later is likewise an Environment lifecycle operation, not Task Browser behavior. A Task may retain Sessions/history even when its expensive Environment resources have been released, if the selected provider and product lifecycle support that state.

## 29.3 Browse Tasks and Sessions

```text
User enters Project-level Task Browser experience
    -> browser queries core Tasks and top-level/user Sessions
    -> registered TaskSummaryContribution / SessionSummaryContribution
       providers enrich each summary
    -> no Task/Session selection is required merely to browse
    -> therefore there may be no active Environment
```

The Task Browser may be a dedicated Project-level screen/window/shell that replaces or precedes the active-session workbench. Selecting a Task or Session can transition into the normal workbench and establish the corresponding application context. A future UI could instead embed the browser inside that workbench without changing the summary/action extension model.

Agent-created child Sessions are not normally flattened into this top-level list. The parent Session surface is the primary place to inspect them.

## 29.4 Create a Chat Session

```text
Task Browser / Agent Interaction: New Session
    -> available orchestration strategies include Chat
    -> user/default selects Chat
    -> core creates Session permanently bound to Chat strategy
    -> Session references Task primary Environment by default
    -> Chat initializes strategy-owned state
    -> Agent Interaction hosts Chat surface
```

Agent Configuration, Model Routing, Context Monitoring, Accounting, and Session Forking may all have registrations active at this point. Chat need not coordinate their semantics directly.

## 29.5 Submit a Chat turn

```text
User submits Draft Request
    -> Chat strategy starts/continues a core Run
    -> strategy requests next inference
    -> core structured inference composition gathers applicable inputs
        Agent Configuration -> agent instructions/tool constraints
        Model Routing       -> model/provider/reasoning preferences
        Context Monitoring  -> compaction/context state if applicable
        Chat strategy       -> strategy/history material
        tool subsystem      -> materialized available tools
        other contributors  -> their structured buckets
    -> host resolves stable semantic inference snapshot
    -> selected ModelProvider generation executes
```

The prompt widgets are not what perform this composition. They are simply one way to modify plugin-owned state that later participates in resolution.

## 29.6 Model changes its model/agent choice

```text
Model decides stronger model or another Agent is useful
    -> invokes model-control or agent-control tool
    -> tool updates corresponding Session/plugin state
    -> current inference is already settled/stable
    -> next inference composition observes the new state
```

The orchestration strategy can give the model guidance about when such choices are useful without hard-coding every workflow stage.

## 29.7 Model reads or modifies source

```text
Model calls read_file/apply_patch
    -> Filesystem Tools validates canonical arguments
    -> ToolInvocation binds to current Environment
    -> plugin derives structured effects/targets
    -> core policy authorizes/denies/asks
    -> tool uses Environment filesystem API
    -> progress/outcome emitted
    -> Chat renders compact tool activity
    -> Inspection/source presentation available when providers exist
```

With Git Worktree Environment, the filesystem operation reaches the worktree. With Docker Environment, the same model tool reaches the container filesystem.

A user can later choose `Display Source File` from the tool result and hand-edit the same file through the Internal Source Editor without changing the tool or Environment abstraction.

## 29.8 Model runs a command

```text
Model calls run_command
    -> Command Tool parses/normalizes invocation
    -> effect description + policy evaluation
    -> Environment process API starts process
    -> live output events update host/UI
    -> Chat shows compact activity
    -> Inspection shows bounded live detail
    -> optional Show Full Output asks ConsoleService to display command output
    -> bounded result returns to model when appropriate
```

Command execution remains possible without Console/Terminal; only the richest human-facing projection disappears.

An interactive console may separately accept user/plugin input through `ConsoleService`. That is not the same as altering an already-running agent command invocation.

## 29.9 TODO progress during a Session

```text
Chat agent calls TODO tools
    -> TODO/Progress updates Session-scoped list
    -> SessionStatusContribution updates
    -> TODO/Progress's SessionSummaryContribution updates wherever
       the Task Browser currently presents that Session summary
```

Another Session in the same Task has an independent TODO list. Task workflow category remains user-controlled.

## 29.10 Review changes

```text
User displays Diff
    -> Diff Viewer asks applicable DiffSource provider for current change set
    -> Git provides stock diff data

User clicks filename
    -> Diff invokes DisplaySourceFile
    -> host default is Internal Source Editor
    -> existing editor is focused or source editor is displayed in Main Content

User chooses alternate editor
    -> host routes same interface to External Editor provider

User manually edits source
    -> Internal Source Editor writes through current Environment filesystem API
    -> Diff/Git change state updates through their normal observation paths

User approves hunk
    -> Diff invokes review approval interface
    -> Git stages hunk

User writes review comment to agent
    -> Diff invokes active review-feedback target if present
    -> Chat strategy incorporates feedback according to its own semantics
```

No step requires Diff to import Git, Internal Source Editor, External Editor, or Chat implementation code.

## 29.11 Create child Sessions

```text
Parent Session decides to delegate work
    -> model/core tool invokes Create Session
        parentSession = current Session
        strategy = selected strategy
        environment = share parent OR establish new
        handoff = generated instructions/context
    -> core creates child Session relationship
    -> optional/default EnvironmentProvider establishes additional Task Environment
    -> child runs independently
    -> parent Session surface shows/inspects child activity/results
```

The child is still a Session, not a Task. Presentation may keep it inspectable without making it a normal user-steerable top-level Session or a peer in the Task Browser.

---

# 30. Interface ownership in the expected topology

A major design choice is not only *which interfaces exist* but *who should define them*.

The current directional rule is:

> Put broadly reusable concepts in core/public ADELE APIs when several unrelated systems reasonably need them; let the component introducing a more specific ecosystem define its own extension contracts.

Likely examples:

| Interface / extension family | Likely owner | Why |
| --- | --- | --- |
| Semantic workbench surfaces (`MainContentView`, Session status, inspection, navigation, stream) | Core | Host composes global UI while placement may evolve |
| Application Commands / Command Palette / keybindings | Core | Cross-cutting input/controller infrastructure |
| Settings | Core | Cross-cutting configuration infrastructure |
| ProjectSelector | Core/public | Project is core; selection methods are interchangeable |
| ModelProvider | Core/public capability | Provider-neutral kernel boundary |
| EnvironmentProvider | Core/public | Task lifecycle needs interchangeable Environment implementations and lifecycle |
| Environment filesystem/process APIs | Core/public | Tools/editors must be Environment-independent |
| DisplaySourceFile | Probably core/public | Diff, Search, diagnostics, navigation, and others may all consume it |
| ConsoleService / console-resource operations | Probably core/public | Commands, user shells, inspectors, and future integrations may need more than open/focus |
| Task creation | Core | Task identity/lifecycle is core-owned |
| Session creation | Core | Session identity/lifecycle is core-owned |
| Inference composition buckets | Core | Core owns stable provider-neutral invocation boundary |
| Tool registration/execution semantics | Core/kernel-facing | Cross-strategy execution invariant |
| OrchestrationStrategy | Agent Interaction plugin API | Core need not understand strategy-hosting UI/product semantics |
| Chat prompt/header/turn regions | Chat plugin API | Only Chat defines those concepts |
| Task/Session summary and action contributions | Task Browser plugin API | Browser defines how Task/Session summaries are enriched without knowing contributing domains |
| Diff source/review approval/comment target | Likely Diff/Review plugin API initially | Review semantics are more specific than core and may evolve together |
| Goal iteration extensions | Future Goal plugin API | Goal-specific concept |

This table is intentionally provisional. A plugin-defined interface can later move into a more general public package if independent uses demonstrate that the abstraction is broader than its original owner.

The reverse should also be possible while APIs are experimental: a speculative core abstraction can be narrowed back into a plugin ecosystem if implementation shows it is not actually general.

---

# 31. Expected plugin-to-extension relationship matrix

The following matrix is a compact view of the same speculative topology.

`P` means the plugin primarily **provides/implements** the interface. `C` means it primarily **consumes** it. `D` means the plugin likely **defines/owns** the extension point for others. Blank cells are intentionally not dependencies.

| Plugin | Project select | Env provider | Env FS/process | Orchestration | Chat regions | Inference composition | Model tools | Display source | Diff/review | Task/Session summaries/actions | Events/usage/quota | Console |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| Local Directory Project Selector | P |  |  |  |  |  |  |  |  |  |  |  |
| Task Browser |  |  |  |  |  |  |  |  |  | D/C |  |  |
| Git |  | P | P |  |  |  | optional P |  | P | optional P | optional P |  |
| Agent Interaction |  |  |  | D/C |  |  |  |  |  |  |  |  |
| Chat Strategy |  |  |  | P | D/C | C/P | C | optional C | optional P/C |  | P |  |
| Session Forking |  |  |  |  | C/P |  |  |  |  |  |  |  |
| Agent Configuration |  |  |  |  | P | P | P |  |  | optional P |  |  |
| Model Routing |  |  |  |  | P | P | P |  |  | optional P | C |  |
| Context Monitoring |  |  |  |  | P | P | optional P |  |  | optional P | C |  |
| Accounting / Usage / Quota |  |  |  |  | optional P |  |  |  |  | P | C/P |  |
| Filesystem Tools |  |  | C |  |  |  | P | C |  |  | P |  |
| Search Tools |  |  | C |  |  |  | P | C |  |  |  |  |
| Command Tool |  |  | C |  |  |  | P |  |  |  | P | C |
| TODO / Progress |  |  |  |  | optional P |  | P |  |  | P | optional P |  |
| Plan |  |  |  |  | optional P |  | P |  |  | optional P |  |  |
| Diff / Review Viewer |  |  |  |  |  |  |  | C | D/C |  | P |  |
| Internal Source Editor |  |  | C |  |  |  |  | P |  |  |  |  |
| Console / Terminal |  |  | C |  |  |  |  |  |  |  |  | P |
| OpenAI |  |  |  |  |  | P via provider result/metadata |  |  |  |  | P |  |

The matrix should not be interpreted as a build graph. Most entries represent optional runtime composition against an interface, not a requirement that another particular plugin be active.

Notably, Task Browser does **not** consume `EnvironmentProvider`; core Task lifecycle does. This omission is intentional and preserves the UI/domain boundary.

---

# 32. Default installation versus architectural requirements

ADELE should ship with a coherent stock plugin set that produces a useful default software-development experience.

The architecture should nevertheless tolerate compositions that are technically valid but practically weak.

Examples:

- Chat active with no model tools;
- orchestration strategy registered with no consumer UI;
- Diff active with no source-display provider;
- multiple Environment providers with one configured default;
- no optional Accounting plugin;
- TODO active but no Task Browser summary consumer;
- no internal editor but an external editor provider.

This is intentional. The platform should not silently activate arbitrary plugins to manufacture usefulness.

Good defaults belong in installation/profile/configuration choices, not hidden runtime dependency chains.

---

# 33. Known tensions with existing documentation

This document intentionally changes or narrows some earlier speculative direction. Existing documents should not be mass-edited until this architecture has been reviewed and stabilized.

Known reconciliation items include:

## 33.1 Project equals directory

`docs/mockups/README.md` currently describes Project as fundamentally a directory. The intended long-term direction here is that Project is an abstract core concept and local-directory Project selection/association is supplied by the stock development composition.

## 33.2 Workspace versus Execution Environment

`agent-kernel-semantic-model.md` currently distinguishes Workspace/source mutation scope from Execution Environment/effect scope.

The current direction is to avoid retaining a separate first-class Workspace concept until a concrete requirement demonstrates that ADELE needs that distinction.

Environment is initially the practical filesystem/source + process execution context. Stronger isolation dimensions should be added when real needs identify their semantics.

The kernel document should be reconciled after this direction stabilizes rather than immediately inventing replacement APIs.

## 33.3 Session history

Existing kernel wording describes Session as owning conversational context/canonical interaction history. The broader strategy model here means that conversational history should not become the universal semantic definition of Session.

Core Session identity/lifecycle remains; strategy-specific durable state defines what a particular orchestration Session consists of.

## 33.4 TODO/progress scope

Earlier directional text sometimes left TODO/progress ambiguous between Task and Session scope.

The expected stock design now treats TODO/progress as Session-scoped. Task Browser may summarize a Session's progress through `SessionSummaryContribution`, but one canonical Task TODO list is not part of the current direction.

## 33.5 Physical workbench names

Existing mockups and earlier draft wording sometimes describe extension surfaces by current placement such as center, left, right, or bottom.

The current direction is to keep plugin-facing surfaces semantic (`MainContentView`, Session status, inspection, navigation, stream/console, and similar concepts) while documenting current stock placement separately. This keeps UI layout evolvable without turning every placement change into a plugin API change.

## 33.6 Task Browser presentation

Earlier draft wording treated Task Browser as a `MainContentView` simply because the current mockups show it in the application window.

The current direction does not require that relationship. Task Browser is a Project/Task/Session selection experience and may own a dedicated pre-session screen/window/shell before the active-session workbench is shown. It can later be embedded into Main Content if that UX proves preferable without changing the browser's semantic responsibilities or summary/action extension points.

---

# 34. Design principles emerging from this direction

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
13. Plugin-facing workbench extension points should describe semantic roles rather than current physical placement.
14. Core owns application Command registration, the Command Palette, keybinding resolution, and user rebinding; plugins provide Commands and suggested bindings.
15. Project, Task, Session, Run, and Environment are core domain concepts, but their concrete useful behavior is heavily plugin-driven.
16. Project is not intrinsically a local directory; Project selection is replaceable.
17. Task is an ADELE-owned durable user-intent object.
18. Task Browser defines Task/Session summary/action extension points; domain plugins contribute summary fragments instead of Task Browser querying each plugin-specific subsystem.
19. Task Browser is a selection/management experience and is not inherently a `MainContentView`; it may precede or replace the active-session workbench until a Task/Session is selected.
20. Environment is initially the practical filesystem/source + process execution context; stronger isolation remains evidence-driven.
21. `EnvironmentProvider` is a lifecycle/provider concept, not merely a creation/provisioning action.
22. Core Task lifecycle, not Task Browser, coordinates establishment of the Task's primary Environment through the selected/default provider.
23. A Task normally has one primary Environment and may have additional Task-associated Environments for child agent work.
24. Session is permanently bound to one orchestration strategy.
25. The strategy defines the semantic structure of strategy-specific Session state.
26. Child agent work uses parent/child Sessions rather than introducing speculative Subtask semantics.
27. Child Sessions are primarily surfaced from their parent Session, not flattened into normal Task Browser navigation.
28. Core provides authoritative Session creation/parenting; orchestration plugins may expose it as a tool.
29. Agent/model controls may participate independently in settings, UI, model tools, and structured inference composition.
30. LLMs may choose agent/model state through tools rather than requiring hard-coded workflow-to-model mappings.
31. Inference resolves into a stable snapshot; state changes affect subsequent inference.
32. Tool plugins and the Internal Source Editor operate through Environment APIs rather than knowing concrete Environment implementations.
33. Plugins may supply semantic policy information; final authorization remains host-owned.
34. ADELE provides persistence facilities by default, while domain-native external systems may remain authoritative where appropriate.
35. TODO/progress in the expected stock system is Session-scoped; Task-level TODOs remain a future possibility only if concrete need appears.
36. Accounting may cover usage, cost, and provider/account quota/allowance state where data is available.
37. `DisplaySourceFile` describes making source visible/focused; the stock Internal Source Editor is intended to support manual editing rather than being a read-only viewer.
38. Console integration should support resource operations broader than a single "open terminal" action when the resource permits them.
39. The stock installation provides useful composition; architectural validity does not require every useful complementary plugin to be active.
40. Do not implement speculative extension APIs merely because this long-term direction names a possible future extension point.
41. The concrete stock plugin topology is a design hypothesis, not a dependency graph or commitment to preserve every proposed plugin boundary.

---

# 35. Deferred questions

This document intentionally does not yet settle:

- final public names for Extension Point / Extension / provider/contributor concepts;
- exact APIs for plugin-defined extension-point packages and version compatibility;
- whether some general interfaces should be moved into core public packages before multiple concrete consumers exist;
- exact generic registry infrastructure shared by Capabilities, Events, and other Extension Points;
- exact semantic workbench surface names and UI contribution descriptors versus arbitrary plugin-rendered widgets;
- exact priority ranges/metadata and deterministic ordering rules;
- exact provider-preference persistence and matching beyond the current profile/configuration direction;
- exact inference-composition bucket schemas and conflict-resolution rules;
- final Agent and model-control plugin names/responsibilities;
- final Environment API and `EnvironmentProvider` lifecycle/recovery/release semantics;
- Task-associated additional Environment cleanup and persistence;
- exact core Task-creation failure/recovery semantics when Environment establishment fails;
- exact Task Browser presentation mode and whether it shares a window/shell with the active-session workbench;
- exact Task/Session summary contribution schema and composition rules;
- exact child-Session interaction/presentation metadata;
- strategy-specific conversation forking semantics;
- generic history/query retention for model invocations, usage, and other events;
- exact provider/account quota interfaces and normalization across providers;
- exact plugin-scoped persistence APIs and schema migration;
- final review/SCM contracts;
- final `DisplaySourceFile` and richer source-editor contracts;
- exact `ConsoleService`/console-resource model and input capabilities;
- exact tool-presentation extension ownership between core, Agent Interaction, Chat, and tool plugins;
- whether Session Forking, Search, or other proposed stock responsibilities ultimately justify independent plugins;
- cross-platform plugin packaging and sandboxing.

These should be resolved from concrete implementation needs while preserving the broader boundaries above.

---

# 36. Near-term use of this document

This document is not an implementation milestone plan.

The immediate self-hosting effort should continue to implement the smallest useful verticals. When a near-term feature needs a boundary described here, implementation should choose the smallest concrete API that satisfies the current use while remaining compatible with the direction.

The concrete plugin topology in this document should help answer questions such as:

- which component is the likely long-term owner of the behavior being implemented;
- whether a current direct dependency should instead become a typed interface;
- whether an interface is broad enough to belong in core or is specific to one plugin ecosystem;
- how a stock feature should degrade if a complementary provider is absent;
- whether state belongs to Project, Task, Session, Environment, strategy-owned state, or an external authoritative system;
- whether an extension point is named for its semantic role or accidentally coupled to today's UI placement;
- whether a UI component is improperly coordinating domain lifecycle that core or another provider should own.

The purpose is to make those small choices converge toward a coherent plugin-oriented product rather than hardening provisional stock behavior into ADELE core by accident.
