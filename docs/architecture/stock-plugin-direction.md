# Expected Stock Plugin Direction

## Status and purpose

**Directional product/architecture hypothesis; mostly unimplemented and explicitly subject to change.**

This document applies ADELE's accepted extension architecture to a concrete default software-development composition. Its purpose is to make the intended plugin boundaries specific enough to guide implementation and expose bad abstractions early.

It is not a committed package list, activation dependency graph, or implementation sequence. Plugins may be merged, split, renamed, or replaced as real self-hosting use reveals better boundaries. Interfaces described here are provisional unless another architecture document or ADR says otherwise.

The expected stock composition should be read alongside:

- [`plugin-extension-model.md`](plugin-extension-model.md), which defines the durable recursive extension model;
- [`agent-kernel-semantic-model.md`](agent-kernel-semantic-model.md), which defines provider-neutral execution semantics;
- [`agent-tooling-direction.md`](agent-tooling-direction.md), which describes model tools and execution presentation;
- [`../mockups/README.md`](../mockups/README.md), which shows the default development UX produced by a stock plugin/configuration set.

The maintained codebase currently implements only a small subset of this topology: source-plugin runtime/build infrastructure, generated contracts, active capability routing, the common ModelProvider, OpenAI provider work, a bounded DevelopmentSource capability, and a provisional application orchestration strategy. Most stock plugins below do not yet exist.

---

# 1. Probable stock composition

A useful default installation currently looks approximately like:

```text
Core ADELE
│
├── Project / Task / Session / Run / Environment identities
├── workbench shell + settings
├── Command registry + Command Palette + keybinding system
├── plugin/extension runtime + default-provider selection
├── core orchestration-strategy registry/binding
├── public provider-neutral orchestration/execution facade
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

Some responsibilities may ultimately share one plugin. Session Forking may stay inside Chat; Search may share implementation with Filesystem Tools; smaller presentation integrations may live with their domain plugin. They are listed separately when reasoning about them independently clarifies replaceability.

---

# 2. Likely core/public extension surfaces

These names are provisional. The important point is the semantic role.

## 2.1 Workbench/UI semantics

```text
MainContentView
    substantial active work content
    stock placement: center work area

NavigationView
    contextual browsing/results/navigation
    stock placement: optional left auxiliary area

SessionStatusContribution
    compact active-Session/work status
    stock placement: upper right area

InspectionPresentation
    structured detail for an inspected operation/resource
    stock placement: lower right area

StreamView / ConsolePresentation
    wide stream/terminal-like content
    stock placement: bottom area

ContextStatusContribution
    compact Project/Task/Environment/profile status
    stock placement may include title/chrome

Settings contributions
    declarative settings and bespoke editors
```

Physical placement is not part of the semantic interface. The stock layout may evolve or become user-configurable.

## 2.2 Commands and input

Core should eventually provide:

```text
Command registration
Command Palette/search
Command applicability/enabled state
suggested/default keybindings
user/profile/project keybinding overrides
```

Plugins register Commands and suggested bindings; core owns discovery, conflict handling, rebinding, and dispatch.

## 2.3 General callable interfaces

Expected broad interfaces include concepts such as:

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
core OrchestrationStrategy registration/discovery/binding
public orchestration/execution service
```

`ProjectSelector` may use an OS picker, recent-project list, database, or cloud catalog.

`EnvironmentProvider` owns the implementation lifecycle rather than only creation. Git Worktree, Docker, and future remote providers can coexist.

`DisplaySourceFile` means make a source file visible/focused through a provider. It may focus an existing in-app editor, create a view, or launch an external editor.

`ConsoleService` is broader than an `OpenTerminal` action. Depending on the resource it may create, display/focus, attach output, send input, or expose other console operations.

The minimal `OrchestrationStrategy` registry/binding contract belongs to core/public APIs because core Session creation/restoration must authoritatively validate and retain the bound strategy identity. Strategy implementations remain plugins. Optional strategy-selection or presentation UI consumes this registry; it does not own it.

A strategy plugin must not import the internal `agent_kernel`. Core exposes a narrow provider-neutral orchestration/execution API backed by the kernel so strategy plugins can create/drive Runs, request model/tool execution, observe execution state, and otherwise use the concrete execution semantics they need without depending on internal implementation packages. Exact methods/types remain deferred until implementation makes them concrete.

## 2.4 Agent/tool composition

Core is expected to define broad provider-neutral inference/tool buckets such as:

```text
model tool registration/materialization
structured inference context/material
agent-related instructions/constraints
model/provider preference and constraint buckets
reasoning/provider-option preferences
tool availability/policy input
provider-neutral model invocation
core execution events
```

Plugins may define more specific extension points inside their own ecosystems.

---

# 3. Project and task plugins

## 3.1 Local Directory Project Selector

**Role:** stock way to select a development Project from a local directory.

Likely provides:

- `ProjectSelector` implementation;
- OS directory picker UI;
- resolution/creation of a core Project associated with the selected root;
- Project display metadata and persistence of the local-root association where needed.

Likely consumes core Project lifecycle and host desktop picker integration.

It does **not** own Task identity, Environment lifecycle, Git semantics, or editing.

Future alternative selectors may show Recent Projects, a database/catalog, or cloud-hosted Projects without changing Project identity.

## 3.2 Task Browser

**Role:** Project/Task/Session selection and management experience represented by the stock mockups.

The Task Browser is not assumed to be a `MainContentView`. Before a Task/Session is selected there may be no normal active-session workbench. The plugin may own a dedicated Project-level screen/window/shell, similar to a selector launching an OS-native picker. A future UI could embed the same experience in the normal workbench without changing semantic contracts.

Likely provides/defines:

```text
TaskSummaryContribution
SessionSummaryContribution
TaskAction
SessionAction
```

and UI for:

- Task selection;
- `New Task` and Task-owned input such as title/description;
- top-level/user Session listing/selection/creation.

Summary contributions are plugin-supplied fragments. Accounting can contribute usage/cost, TODO/Progress can contribute Session progress, Git/Environment integrations can contribute relevant status, and future plugins can add other compact state. The Task Browser composes those fragments; it should not directly query every plugin-specific domain.

Task Browser consumes core Task/Session query and mutation services, core Task creation, core Session creation, and registered summary/action extensions.

It does **not** orchestrate Environment creation. `New Task` sends Task intent to core; core Task lifecycle independently resolves the applicable/default Environment provider.

Agent-created child Sessions are not normal peers in the Task Browser Session list. They are primarily surfaced inside the parent Session/orchestration experience.

---

# 4. Git and Environment direction

## 4.1 Git plugin

**Role:** Git-specific development behavior without making Git intrinsic to Task, Environment, review, or source-editing semantics.

One Git plugin may legitimately provide several independent extensions.

### Git Worktree Environment provider

For the stock local-development configuration, core Task creation normally resolves Git Worktree as the default applicable `EnvironmentProvider`.

The provider approximately:

- creates/manages a worktree and usually a branch;
- exposes Environment filesystem/process access;
- validates/reconnects to retained worktrees;
- releases ADELE-held live resources when appropriate;
- destroys worktree/branch resources only under explicit conservative lifecycle rules.

Task/environment/worktree/branch names may match by convention but are not one identity.

### Review/change provider

Git is the expected stock implementation of whatever typed interface Diff/Review uses to obtain change sets and change content. That interface may initially belong to the Diff ecosystem rather than core.

### Approval/unapproval provider

Git maps review approval to staging/index state:

```text
approve hunk/file -> stage corresponding change
unapprove         -> unstage corresponding change
```

The Diff UI invokes review-domain operations without knowing Git staging is authoritative storage.

### Other Git extensions

Git may also provide status summaries, Commands, commit operations, model tools, inspectors, and Task/context summary contributions.

Git remains useful if Diff is disabled, and Git review extensions can remain registered with no consumer.

## 4.2 Docker Environment example

A Docker plugin demonstrates substitution:

- provides another `EnvironmentProvider`;
- exposes filesystem access inside the container;
- exposes process execution inside the container;
- owns concrete container lifecycle/reconnect/release/destroy behavior;
- may expose PTY/runtime-resource support.

Filesystem Tools, Search, Command Tool, and Internal Source Editor should continue working without knowing Docker is involved.

---

# 5. Agent interaction and orchestration

## 5.1 Agent Interaction

**Role:** primary agent-interaction selection/hosting/presentation experience over core-owned Session and orchestration facilities.

Likely provides/defines:

- an agent-interaction `MainContentView` or equivalent hosting surface;
- strategy-selection UX when a user creates a Session;
- common strategy-hosting/presentation framing;
- navigation/commands for entering or switching among user-facing Sessions where useful.

Agent Interaction consumes core Session lifecycle, the **core-owned orchestration-strategy registry**, core create-Session functionality, and Main Content hosting.

It does **not** own the `OrchestrationStrategy` registration/binding extension point. Core must be able to create/restore/validate a Session's bound strategy without Agent Interaction being active, including programmatically created child Sessions.

Agent Interaction does not need to understand Chat prompt widgets, Agent policy, Model routing, TODOs, Git, or Goal-specific data.

A strategy may register and execute through core facilities even if no Agent Interaction consumer is active.

## 5.2 Chat Strategy

**Role:** expected initial orchestration strategy: conversational model/tool/model work with a rich Chat Session surface.

It is the likely long-term home of the sequencing behavior currently represented by the provisional application `DevelopmentToolLoopStrategy`. The strategy registers against the core/public `OrchestrationStrategy` contract and uses a public provider-neutral orchestration/execution API backed by `agent_kernel`; it **does not import `agent_kernel`** and does not redefine Run semantics.

Likely provides:

- orchestration strategy registration into the core registry;
- Chat-specific durable Session state;
- timeline and Draft Request/composer UI;
- user/agent message and operation-group presentation;
- child-Session activity/inspection when delegated work is created;
- strategy-specific continuation behavior;
- Chat-specific events such as `ChatTurnCompleted` where useful.

Likely defines Chat-specific extension points such as:

```text
ChatPromptAccessory
ChatSessionHeaderContribution
ChatTurnAction
ChatTimelineDecoration / ChatOperationPresentation
```

Likely consumes the core/public Run/model/tool execution facade, structured inference composition, tool catalogs, Session persistence, child-Session query/creation, common timeline/composer components, and optional tool/review presentation interfaces.

Expected stock integrations:

- Agent Configuration contributes prompt/header UI plus inference instructions/constraints;
- Model Routing contributes prompt controls plus model preferences;
- Context Monitoring contributes status and compaction actions;
- Accounting contributes usage/cost/quota displays;
- Session Forking contributes Chat-specific fork behavior;
- Diff/Review can send structured review feedback when Chat exposes a compatible target.

Chat remains valid with no prompt accessories and even with no model tools, though the stock installation should not normally be configured that way.

## 5.3 Session Forking

**Role:** optional Chat-compatible conversation fork creation/navigation.

Likely provides Chat turn actions, fork navigation UI, lineage metadata, Commands, and keybindings.

It consumes Chat-specific APIs. Forks are not required to be core Sessions; if Chat can represent them more cleanly in strategy state, that is preferable until another strategy demonstrates common semantics.

---

# 6. Agent and model policy plugins

## 6.1 Agent Configuration / Policy

The name is provisional; "Agent Selection" is too narrow.

Likely provides:

- persistent Agent definitions/configuration;
- settings UI;
- optional Chat prompt/header control;
- model-callable tools for changing active Agent state;
- structured inference context containing Agent instructions/persona/stock context;
- Agent-associated tool/policy constraints;
- display metadata and Commands.

Chat does not call an `AgentSelector`; the Agent plugin independently participates wherever its state matters.

An LLM tool call can change Agent state for **subsequent** inference. It does not mutate the current resolved invocation.

## 6.2 Model Routing / Control

The name is provisional; "Model Selection" is too narrow.

Likely provides:

- semantic model types such as `Fast` or `Powerful`;
- mapping from those types to concrete ModelProvider/configured instance/model choices;
- reasoning/thinking preference configuration;
- settings UI;
- optional Chat prompt control;
- model-callable tools for changing model/reasoning state;
- structured inference preference/constraint contributions.

It consumes active ModelProviders/configured instances and provider metadata/catalogs.

Without this plugin, a strategy can still invoke a configured provider using that provider's own default model/options.

LLMs can choose semantic model/agent state through tools. Strategies can provide guidance in stock context rather than hard-code every workflow-to-model transition.

---

# 7. Context and accounting plugins

## 7.1 Context Monitoring / Compaction

Likely provides:

- Session context-window usage/status;
- `SessionStatusContribution`;
- Chat turn actions for compaction/summarization;
- Commands/tools for explicit compaction;
- structured inference material representing retained compaction state;
- optional Inspection presentation explaining effective context.

It consumes context/inference preview facilities, selected model context-window metadata, Chat extension points, Session persistence, and model invocation when compaction itself requires inference.

## 7.2 Accounting / Usage / Quota

Likely tracks three related but distinct concerns:

```text
usage
    tokens / requests / measured consumption

cost
    price estimate/actual where provider/model pricing is known

quota / allowance
    provider/account limits, subscription allowance, rate limits,
    remaining capacity, reset time, or analogous live provider state
```

Likely provides usage/cost queries/aggregates, provider/account quota queries, per-turn or Session display, Task/Session summary contributions, Session/Context status fragments, and settings.

It consumes model-usage events and/or retained invocation history, pricing metadata, provider/account quota/status interfaces, and Task/Session identities.

Accounting failure should not fail the inference it observes. Quota may be live provider state rather than durable local history.

---

# 8. Stock model-tool plugins

## 8.1 Filesystem Tools

Likely provides structured tools directionally resembling:

```text
list_directory
glob
read_file
apply_patch
write_file
delete_file
```

It consumes the current Environment filesystem API, tool registration/materialization, core policy, `DisplaySourceFile` when available, and tool inspection/presentation extension points.

It should never silently fall back to unrelated host filesystem access when the current Environment does not expose filesystem access.

## 8.2 Search Tools

Possible implementations include native text search, command-backed `rg`/`grep`, semantic/vector search, and future language-aware search.

Likely provides model search tools, structured results, inspection UI, optional `NavigationView`, and explicit user Commands/keybindings.

It consumes Environment filesystem/search or process execution and optional `DisplaySourceFile` for result navigation.

## 8.3 Command Tool

**Role:** universal model-callable external-program escape hatch.

Likely provides:

- `run_command`-style tool;
- structured invocation identity/state;
- streaming progress/output;
- bounded model-facing results;
- Chat summary and Inspection presentation;
- optional `ConsoleService` integration for full output;
- command-specific effect/policy interpretation.

It consumes current Environment process execution, core tool/policy infrastructure, and optional Console integration.

The plugin can parse its own command representation and provide structured effects. It does not authorize itself.

## 8.4 TODO / Progress

Expected stock semantics are **Session-scoped**, not Task-scoped.

Likely provides:

- model tools for creating/updating/completing/reordering work items;
- Session-scoped TODO/progress persistence/query;
- `SessionStatusContribution`;
- `SessionSummaryContribution` for Task Browser where useful.

Separate Sessions in one Task maintain independent lists. TODO completion does not automatically change the user-controlled Task workflow category.

## 8.5 Plan

Likely provides a durable model-editable Session artifact rather than making Plan intrinsic to every Session.

Expected functionality includes plan read/write/update tools, Session-scoped plan identity/persistence, Main Content/artifact presentation, Commands, and optional inspection summaries.

---

# 9. Review and editing plugins

## 9.1 Diff / Review Viewer

**Role:** rich review experience without embedding Git or editor assumptions.

Likely provides a Diff/Review `MainContentView`, review scope controls, hunk rendering, comments, and plugin-defined interfaces for reviewable changes and review operations.

Possible provisional contracts:

```text
DiffSource / ChangeSetSource
ReviewApprovalHandler
ReviewCommentReceiver / ReviewFeedbackTarget
```

Likely consumes a change provider (Git by default), optional approval provider, `DisplaySourceFile`, optional review-feedback target, Commands/keybindings, and Main Content hosting.

Default composition:

```text
Diff data         <- Git
Approve/Unapprove <- Git staging/index
Display file      <- Internal Source Editor
Review comment    -> active Chat feedback target when available
```

Graceful degradation:

- no source-display provider: diff still works but file navigation is unavailable;
- no approval provider: review is display/comment only;
- no feedback target: comment-to-agent affordance is absent;
- no Git but another compatible change provider: Diff can still work.

## 9.2 Internal Source Editor

**Role:** stock in-app source display **and editing** experience.

Manual editing is an intended workflow, not merely a hypothetical later feature.

Likely provides:

- `DisplaySourceFile` provider;
- source-editor Main Content/Source Group views;
- editing/save through the active Environment;
- syntax highlighting/navigation;
- Commands and keybindings;
- dirty/conflict handling;
- optional richer source-inspection/navigation APIs.

`DisplaySourceFile` may focus an existing editor rather than create a duplicate view, and may later accept a line/range/selection to reveal.

An External Editor plugin can implement the same narrow source-display capability by launching/focusing VS Code or another editor. Default selection remains host-owned.

---

# 10. Console / Terminal

**Role:** console/terminal presentation and user-created interactive shells without reducing the abstraction to `OpenTerminal`.

Likely provides:

- `StreamView` / console presentation;
- interactive Environment-owned shell resources;
- `ConsoleService` operations for create/display/focus/close where appropriate;
- input/command sending for interactive resources;
- read-only presentation of retained command output;
- Commands/keybindings and user shell creation UI.

It consumes Environment process/PTY facilities, runtime-resource lifecycle, and command-output/resource references.

Interactive shells and agent command invocations may share rendering while remaining distinct semantic resources. A retained output console need not accept input; capabilities should reflect the concrete resource.

---

# 11. OpenAI provider

The OpenAI plugin remains provider-specific.

Likely provides:

- common `ModelProvider` capability;
- configured provider/account instances;
- auth/account configuration UI;
- model catalog/capability metadata;
- usage metadata;
- provider/account quota/rate-limit/allowance information where available;
- pricing metadata where useful to Accounting/Model Routing.

It does not own semantic `Fast`/`Powerful` model types, global model preference policy, Agent definitions, or Chat orchestration.

The maintained repository already implements substantial OpenAI provider functionality; some stock integrations above remain future work.

---

# 12. Concrete default flows

## 12.1 Select a Project

```text
User chooses Select/Open Project
    -> host/default routing chooses Local Directory Project Selector
    -> selector shows OS directory picker
    -> selected directory resolves/creates core Project
    -> local-root association is retained
    -> Project-level Task/Session selection experience becomes available
```

Another selector could show Recent Projects or a cloud catalog.

## 12.2 Create a Task

```text
Task Browser: New Task
    -> gathers Task-owned input such as title
    -> calls core CreateTask
    -> core creates durable Task identity
    -> core resolves applicable/default EnvironmentProvider
    -> Git Worktree is stock default
    -> Git establishes primary Environment
    -> core associates Environment with Task
    -> Task creation settles
```

Task Browser never calls Git directly. A generic host provider selector can expose Docker or another active Environment provider if the product wants explicit choice.

Environment resources may later be released/destroyed while Task/Session history remains, subject to concrete lifecycle rules.

## 12.3 Browse Tasks and Sessions

```text
Task Browser queries core Tasks/top-level Sessions
    + Accounting summary contributions
    + TODO Session progress contributions
    + optional Git/Environment/status contributions
```

There may be no active Environment while merely browsing.

## 12.4 Create a Chat Session

```text
user chooses Chat strategy through Agent Interaction or another caller
    -> core resolves/validates Chat in the core orchestration registry
    -> core creates Session permanently bound to Chat strategy identity
    -> Session references Task primary Environment by default
    -> Chat initializes strategy-owned state through public strategy APIs
    -> Agent Interaction hosts Chat surface when that UI is active
```

Programmatic child Session creation can use the same registry/binding path without Agent Interaction participating.

## 12.5 Submit a Chat turn

```text
Chat strategy calls public orchestration/execution service
    -> core structured composition gathers
        Chat strategy/history material
        Agent instructions/tool constraints
        Model routing/reasoning preferences
        context/compaction material
        materialized tools
        other typed contributions
    -> host resolves stable inference snapshot
    -> selected ModelProvider generation executes
```

The public service is backed by `agent_kernel` internally; Chat does not import the kernel package.

Prompt widgets are merely one way to modify plugin-owned state that contributes to the **next** resolution.

## 12.6 Model changes model/Agent

```text
model invokes agent/model control tool
    -> plugin-owned Session state changes
    -> current inference remains settled
    -> next inference uses new state
```

## 12.7 Source operation

```text
model calls read_file/apply_patch
    -> Filesystem Tools validates arguments
    -> ToolInvocation binds current Environment
    -> plugin describes structured effects
    -> core policy authorizes/denies/asks
    -> tool uses Environment filesystem API
    -> Chat/Inspection receive progress/outcome
```

Git Worktree and Docker route the same tool to different concrete filesystems.

## 12.8 Command operation

```text
model calls run_command
    -> Command Tool normalizes invocation/effects
    -> core policy
    -> Environment process execution
    -> live output updates Chat/Inspection
    -> optional Show Full Output uses ConsoleService
    -> bounded result returns to model
```

## 12.9 TODO progress

```text
agent calls TODO tools
    -> Session-scoped list changes
    -> SessionStatusContribution updates
    -> Task Browser SessionSummaryContribution updates if visible
```

## 12.10 Review changes

```text
Diff asks DiffSource -> Git provides changes
filename action -> DisplaySourceFile -> Internal Source Editor by default
manual edit -> Environment filesystem -> Git/Diff observe normal change state
Approve -> review approval interface -> Git stages hunk
Review comment -> feedback target -> Chat incorporates feedback if available
```

No consumer imports Git, Internal Source Editor, External Editor, or Chat implementation code.

## 12.11 Child Sessions

```text
parent Session delegates work
    -> requests core CreateSession(parent=current, strategy=..., environment=share/new)
    -> core resolves/validates requested strategy in orchestration registry
    -> core creates child relationship + permanent strategy binding
    -> optional EnvironmentProvider establishes additional Task Environment
    -> child strategy executes through public orchestration/execution service
    -> parent Session surface exposes activity/results
```

The child remains a Session, not a Task, and is not normally a peer in Task Browser navigation.

---

# 13. Directional interface ownership

| Interface / extension family | Likely owner | Reason |
| --- | --- | --- |
| Semantic workbench surfaces | Core | Host composes global UI while placement evolves |
| Commands / Command Palette / keybindings | Core | Cross-cutting controller/input infrastructure |
| Settings | Core | Cross-cutting configuration infrastructure |
| ProjectSelector | Core/public | Project is core; selection methods are interchangeable |
| ModelProvider | Core/public capability | Provider-neutral kernel boundary |
| EnvironmentProvider | Core/public | Task lifecycle needs interchangeable Environment implementations |
| Environment filesystem/process APIs | Core/public | Tools/editors must be Environment-independent |
| DisplaySourceFile | Probably core/public | Diff, Search, diagnostics, navigation may all consume it |
| ConsoleService | Probably core/public | Commands, user shells, inspectors, future integrations may consume it |
| Task creation | Core | Task identity/lifecycle is core-owned |
| Session creation | Core | Session identity/lifecycle is core-owned |
| OrchestrationStrategy registration/binding | Core/public | Session creation/restoration must validate permanent strategy binding independent of optional UI |
| Public orchestration/execution API | Core/public, backed internally by `agent_kernel` | Strategy plugins need Run/model/tool execution without depending on internal implementation packages |
| Inference composition buckets | Core | Core owns stable provider-neutral invocation boundary |
| Tool registration/execution semantics | Core/public facade backed by kernel | Cross-strategy execution invariant while `agent_kernel` remains internal |
| Chat prompt/header/turn regions | Chat plugin API | Chat-specific concepts |
| Task/Session summaries/actions | Task Browser plugin API | Browser-specific presentation ecosystem |
| Diff source/review interfaces | Likely Diff/Review plugin API initially | Review-specific semantics |
| Goal iteration extensions | Future Goal plugin API | Goal-specific concept |

A plugin-defined interface can later move into core/public APIs when independent uses prove it is genuinely general. While APIs remain experimental, speculative core abstractions can also move back into a plugin ecosystem—except where a core lifecycle invariant requires the minimal contract to remain core-owned, as with Session strategy binding.

---

# 14. Default installation is not an architectural requirement

The stock installation should be coherent and useful, but ADELE should tolerate technically valid weak compositions:

- Chat with no tools;
- strategy registered with no Agent Interaction UI consumer;
- Diff with no source-display provider;
- multiple Environment providers with one contextual default;
- no Accounting plugin;
- TODO with no Task Browser summary consumer;
- no internal editor but an external editor provider.

Good defaults belong in installation/profile/configuration choices, not hidden activation dependency chains.

---

# 15. Implementation guidance

This document should be used to answer practical ownership questions while implementation proceeds:

- Which plugin is the likely long-term owner of this behavior?
- Should this direct implementation dependency instead become a typed interface?
- Is the interface broad enough for core, or specific to a plugin ecosystem?
- Does a core lifecycle invariant require the minimal registration/binding contract to be core-owned even if an optional plugin owns the UI?
- Is a plugin accidentally depending on `agent_kernel` or another internal host package instead of a narrow public facade?
- What should happen when a complementary provider is absent?
- Does state belong to Project, Task, Session, Environment, strategy-owned state, or an external authoritative system?
- Is a UI extension named for its semantic role or accidentally coupled to today's layout?
- Is presentation improperly coordinating domain lifecycle that core or another provider should own?

Do not implement every interface listed here in advance. Introduce the smallest real boundaries required by each vertical and use this topology as a convergence target rather than a speculative framework checklist.