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

For maintained implementation scope, code paths, and validation, see
[`overview.md`](overview.md). This document describes likely ownership and
collaboration, not an inventory of packages, artifacts, or completed phases.

---

# 1. Probable stock composition

A useful default installation could look approximately like:

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

Stock context-source plugins
└── AGENTS.md

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

Names below describe semantic roles; concrete public contracts and current limits
are maintained in [`overview.md`](overview.md) and the owning package documentation.

## 2.1 Workbench/UI semantics

Session presentation, activity grouping, and timeline placement belong to the
strategy. Tool and provider-specific compact activity and rich Inspection bodies
belong to the owning plugins. Compact and rich presentation are distinct semantic
roles, not size variants. The common host owns inspect interactions, retained card
order, collapse/dismiss chrome, and view lifetime, not plugin field interpretation.
Run/core owns evidence identity, order, and lifecycle. Read-only presentation does
not grant execution or approval authority, and unavailable rich UI must not
invalidate execution or erase safe
activity. Concrete Session/tool/native presentation contracts live in
[`plugin-extension-model.md`](plugin-extension-model.md#122-implemented-presentation-boundaries),
separately from the broader workbench hypotheses below.

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

## 2.3 Selection and callable interfaces

Expected broad interfaces include concepts such as:

```text
ProjectSelectorContribution (selection, not a callable capability)
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

Project selection returns a source URI or cancellation; see section 3.1.
Selectors may use a recent-project list, GitHub, database, or cloud catalog without
making one implementation intrinsic to Project identity.

`EnvironmentProvider` owns the implementation lifecycle rather than only creation. Git Worktree, Docker, and future remote providers can coexist.

`DisplaySourceFile` means make a source file visible/focused through a provider. It may focus an existing in-app editor, create a view, or launch an external editor.

`ConsoleService` is broader than an `OpenTerminal` action. Depending on the resource it may create, display/focus, attach output, send input, or expose other console operations.

The minimal `OrchestrationStrategy` registry/binding contract belongs to core/public APIs because core Session creation/restoration must authoritatively validate and retain the bound strategy identity. Strategy implementations remain plugins. Optional strategy-selection or presentation UI consumes this registry; it does not own it.

A strategy plugin must not import internal `agent_kernel`. It consumes the public
provider-neutral orchestration facade; core retains model/tool materialization,
policy, exact binding validation, and approval authority. Strategy sequencing and
Session meaning remain plugin-owned.

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

Context sources should contribute captured material through public orchestration
composition rather than mutate arbitrary provider requests. Source identity,
freshness, failure policy, and immutable capture are distinct from strategy history
and executable binding lifetime. Deterministic ordering is not semantic authority.

The AGENTS.md source owns repository-instruction interpretation through
Session-authorized Environment reads, with explicit user requests taking
precedence. Chat should neither activate nor know that source. Skills, Agent
Roles, repository maps, memory, and other mechanisms remain independent plugin
concerns, not responsibilities absorbed by AGENTS.md. Current source scope is
maintained in its [README](../../plugins/agents_md/README.md).

---

# 3. Project and task plugins

## 3.1 Local Directory Project Selector

**Role:** native directory selection, returning only a source URI or cancellation.

The selector owns selection behavior and path-to-source-URI semantics, not native
picker plumbing, Project identity, or lifecycle. The maintained Local Directory
implementation is `local_directory_project_selector_frontend` under
`plugins/local_directory_project_selector/packages/frontend`, replacing the retired
root package. It is a frontend-only prepared installation, not an AOT backend or
static `AdeleRuntime` activation. EVC calls the narrow public interpreted picker
stub and normalizes the result to an absolute `file:` URI string or cancellation;
the app supplies one asynchronous native picker call per operation through a
revocable bridge. The generic adapter validates URI shape without owning path rules.
The app invokes the contribution and separately calls core lifecycle after exact
binding and window-lifetime validation, as section 12.1 describes.
Directory selection must not imply Git validation or Environment creation; the
selected Environment provider owns source suitability for its own operations.

The selector does **not** own Task, Environment, Git, editing, persisted
associations, or deduplication. Zero selectors should be unavailable; multiple
selectors can be independent choices rather than a priority competition. Future
GitHub/cloud/catalog or recent-Project selectors can supply the same semantic
boundary. Public contract ownership follows [`dependency-rules.md`](dependency-rules.md).
Retirement rejects late native results without forcibly closing dialogs; semantic
selection failures stay operation-local. The selector receives no backend RPC or
Session/Environment authority. Headless self-hosting remains selector-free and uses
an explicitly known source URI directly.

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

Selecting a Project, Task, or Session in Task Browser triggers core window navigation/selection. Core owns which Project/Task/Session a window is currently presenting and the surrounding workbench state; replacing Task Browser must not redefine those semantics.

It does **not** orchestrate Environment creation. `New Task` sends Task intent to core; core Task lifecycle independently resolves the applicable/default Environment provider.

Agent-created child Sessions are not normal peers in the Task Browser Session list. They are primarily surfaced inside the parent Session/orchestration experience.

---

# 4. Git and Environment direction

## 4.1 Git plugin

**Role:** Git-specific development behavior without making Git intrinsic to Task, Environment, review, or source-editing semantics.

One Git plugin may legitimately provide several independent extensions.

### Git Worktree Environment provider

Git should participate through `EnvironmentProvider`, not direct Git calls from
Task presentation. Git is the expected stock default because of composition, not
a Task identity rule. Core owns provider selection and lifecycle; the selected
provider owns source validation, including rejecting a non-Git directory after it
has legitimately been opened as a Project.

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

**Role:** conversational model/tool/model orchestration with strategy-owned
history, message/activity presentation, and composer semantics.

Chat should drive the public orchestration facade rather than import the kernel
or redefine Run semantics. It owns conversation state, history projection,
sequencing, and its invocation budget; core owns exact executable bindings,
policy, approval, and Environment authority. Instructions and model/tool choices
must be captured at their appropriate Run or inference boundaries, not inferred
from mutable widgets. Context sources are independent contributions, not
Chat-activated dependencies.

Canonical user/final assistant history remains distinct from intermediate model
output, proposals, tool results, and Run-local replay. Safe display presentation
must never become replay input or a new canonical history entry. Activity
retention is a presentation concern; durable restoration requires an explicit
persistence design rather than inferring history from current widgets.

Chat owns compact activity placement and narration. Related operations should
remain lightweight between messages, with drill-down into common Inspection.
Tool-batch narration should express shared purpose, respect explicit user
instructions, and require no extra inference; tool evidence, not prose,
establishes effects. Heading precedence is tool-batch narration when tools are
present, then provider-supplied safe compact text, then a structural tool count.
Reasoning-only activity belongs before canonical final assistant text, without
repurposing that final text as batch narration.

Provider backends own interpretation and safe projection of native activity;
provider frontends own its rich presentation. Chat should consume safe compact
data without knowing OpenAI fields or depending on a rich presenter being active.
Raw items without safe presentation remain opaque. Missing rich Inspection must
not erase safe activity, and encrypted/private reasoning must never be recovered
or shown. Compact and full text still need display-control escaping at their
respective rendering boundaries.

The common Inspection host owns window-local selection, group framing, and
interleaving tool/native activity in authoritative output order, including
unprepared or rejected tool placeholders. Tool/provider frontends own read-only
detail bodies, not Chat group composition or approval decisions. Changing the
presented Session clears selection; Close removes the view, not evidence or
history. View resources follow exact registration liveness, without turning an
eval-runtime allocation choice into a permanent plugin-instance model.

Expected Chat functionality includes:

- Chat-specific persistent Session state;
- a common execution timeline and richer Draft Request/composer integration;
- operation-group and richer message presentation;
- child-Session activity/inspection when delegated work is created;
- Chat-specific events such as `ChatTurnCompleted` where useful.

Likely defines Chat-specific extension points such as:

```text
ChatPromptAccessory
ChatSessionHeaderContribution
ChatTurnAction
ChatTimelineDecoration / ChatOperationPresentation
```

Headless Chat consumes the public execution facade and opaque tool snapshots, not
kernel catalogs. UI and state features may consume structured inference
composition, Session persistence, child-Session query/creation, common
timeline/composer components, and optional tool/review presentation interfaces.
These are ownership expectations, not claims that the full integration exists.

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
- model-callable tools for changing selected Agent state;
- structured inference context containing Agent instructions/persona/stock context;
- Agent-associated tool/policy constraints;
- display metadata and Commands.

Chat does not call an `AgentSelector`; the Agent plugin independently participates wherever its state matters.

In the expected stock workflow, a model-callable `set_agent`/selection tool routes the user to the Agent used for the **next user invocation**. It does not implicitly change the Agent for a model continuation that still belongs to the current user turn. A future orchestration strategy may deliberately define an explicit intra-Run Agent handoff, but that is separate orchestration behavior rather than an accidental consequence of changing the selected Agent.

The proposed stock Agent integration distinguishes selected Agent state from the effective Agent for an already-started user turn. In that design, Chat snapshots/binds the effective Agent for the turn's model/tool continuations. The Agent plugin owns selected-Agent state; `set_agent` changes that selection for a later user-submitted turn rather than replacing the current turn binding. This integration and its storage/API remain directional. User input that merely resolves an interruption would not retroactively replace an effective-Agent binding; treatment of queued/new-turn input remains strategy-specific.

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

Model/reasoning changes can affect a subsequent inference after the current resolved invocation settles. This timing is intentionally distinct from the stock Agent-selection workflow above.

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

Filesystem Tools should own model-facing file-operation grammars and their
read-only Inspection details, while Environment supplies authorized filesystem
primitives and core policy authorizes effects. Frontend field interpretation must
not require importing the headless implementation or granting mutation authority.

Tool direction may resemble:

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

Search should own search semantics, resource bounds, result structure, and partial
failure reporting while respecting Session-authorized Environment scope. Missing,
unreadable, stale, or unavailable scopes must not silently become a root search or
successful empty result. Truncation from resource limits and incompleteness from
skipped failures should remain distinguishable.

Possible implementations include native text search, command-backed `rg`/`grep`, semantic/vector search, and future language-aware search.

Likely provides model search tools, structured results, inspection UI, optional `NavigationView`, and explicit user Commands/keybindings.

It consumes Environment filesystem/search or process execution and optional `DisplaySourceFile` for result navigation.

## 8.3 Command Tool

**Role:** universal model-callable external-program escape hatch.

Command Tool should own its model-facing command representation, effect
description, bounded model output, and read-only Inspection details. Environment
owns process execution; core policy owns authorization. Tool-result delivery is
distinct from process exit success. Progress, bounded previews, and full console
output are different presentation needs, not one flattened data stream.

Tool frontends should remain independently replaceable. Missing or failed
Inspection must not fail execution, authorize an invocation, or cause a native
fallback. Only common host approval UI resolves the exact retained interruption.

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

Plan is a plugin-owned concept rather than a core ADELE identity. The stock Plan plugin is expected to own durable model-editable plan state associated with a Session and expose the tooling/presentation needed to work with it.

Expected functionality includes plan read/write/update tools, Session-associated plan persistence, Main Content presentation, Commands, and optional inspection summaries.

---

# 9. Review and editing plugins

## 9.1 Diff / Review Viewer

**Role:** rich review experience without embedding Git or editor assumptions.

Likely provides a Diff/Review `MainContentView`, review scope controls, hunk rendering, comments, and plugin-defined interfaces for reviewable changes and review operations. The word "Review" here names the Diff plugin's workflow; it is not a separate core Review domain identity.

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

Provider-specific authentication, request policy, raw response interpretation,
and native replay belong to OpenAI, not the shared backend host or Chat. Provider
failure must not invalidate unrelated product identities or Environment support.
Exact supported request options and evidence belong in the
[backend README](../../plugins/openai/packages/backend/README.md), not this topology.

The ownership split is Contract/Backend/Frontend: Contract shares identities and
payload schema only, Backend classifies raw Responses and produces bounded safe
presentation while preserving native data, and Frontend renders that safe payload.
No additional projection component or app-owned provider algorithm is needed.

OpenAI should own the meaning and rich presentation of legitimately supplied
reasoning summaries. Chat owns compact placement; the common Inspection host owns
selection, framing, and ordered composition. Generic consumers must not parse
OpenAI fields, and rich frontend absence must not hide already-safe activity.
Missing/failed rich presentation affects the view, not execution or exact replay.
Replacement uses fresh bindings rather than retargeting stale resources.

Raw native metadata remains the only native replay source. Safe presentation must
never be replayed. Encrypted/private reasoning is not user-facing content and must
not be decoded or presented as hidden chain of thought. Summary availability does
not imply support for reasoning deltas, compaction UI, or every provider/model.

---

# 12. Concrete default flows

These flows illustrate ownership and collaboration, not an implemented sequence.
Core resolves a Session's strategy and retains exact executable bindings;
strategies drive the public facade. Retired active work must not silently migrate,
while later work may freshly resolve a replacement under the same semantic identity.

## 12.1 Select a Project

```text
user invokes a Project selector (stock: native directory picker)
    -> selector returns a source URI or cancellation
    -> app validates window lifetime and the retained selector binding
    -> core lifecycle creates/resolves the canonical Project
    -> window navigation presents the Project
```

Cancellation should be a no-op; selector/lifecycle failure should not silently
replace the presented Project or choose another provider. Late results must not
change a closed window, and retired bindings cannot substitute replacements after
selection. Opening a Project is distinct from creating a Task, Environment,
Session, or Run and does not define plugin activation. Command surfacing and Task
Browser may replace temporary host controls without changing that boundary.

## 12.2 Create a Task

Task Browser or another caller submits Task intent to core lifecycle:

```text
opened Project: user submits Task intent
    -> caller invokes core Task creation
    -> core resolves the applicable/default EnvironmentProvider
    -> core allocates Task and provisional primary Environment identities
    -> selected provider establishes Environment (stock: Git worktree)
    -> provider success publishes Task + finalized primary Environment together
    -> core records the exact establishment-time materialization
    -> lifecycle returns canonical values; window navigation presents them
```

Presentation calls no Git API and never parses opaque provider state. Failure
must not replace presented values, and window disposal prevents late updates.
Readiness comes from a live exact materialization binding, not inferred provider
fields. Retained successful product state and current provider availability are
distinct, without silent rollback or migration after retirement.

Task creation does not itself start a Session or model Run. Missing model support
must not disable independent Task/Environment lifecycle. An explicit generic
provider-selection control remains possible presentation, not a Git-specific
requirement on Task Browser.

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

Session creation and presentation are separate: missing, ambiguous, or failed
presentation must not undo a valid canonical Session. The expected flow is:

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
user submits Chat turn
    -> Chat snapshots the currently selected Agent as this turn's effective Agent
    -> Chat strategy calls public orchestration/execution service
    -> core structured composition gathers
        Chat strategy/history material
        Agent instructions/tool constraints from the turn binding
        Model routing/reasoning preferences
        context/compaction material
        materialized tools
        other typed contributions
    -> host resolves stable inference snapshot
    -> selected ModelProvider generation executes
```

The public service is backed by `agent_kernel` internally; Chat does not import the kernel package.

Each model continuation may still receive a newly resolved inference snapshot, but stock Chat uses the same turn-scoped effective Agent until that user-submitted turn ends. Prompt widgets and model-callable controls modify plugin-owned state according to that plugin's lifecycle semantics. Model/reasoning changes may affect a later inference once the current invocation settles; stock Agent selection normally routes a later user invocation rather than changing the bound Agent inside the current turn.

## 12.6 Model changes model/Agent

```text
model invokes model/reasoning control tool
    -> plugin-owned state changes
    -> current resolved inference remains unchanged
    -> a subsequent inference may use the new model/reasoning state

model invokes set_agent / Agent-selection tool
    -> selected Agent for a later user invocation changes
    -> current Chat turn retains its snapshotted effective Agent
```

An orchestration strategy could later define an explicit intra-Run Agent handoff, but that is separate from the stock selection tool. Exact handling of queued or steering input at turn boundaries remains strategy-specific rather than being fixed here.

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

Inspection should distinguish lifecycle and bounded previews from full Console
output; tool progress history should not be flattened into one detail payload.

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
| `ProjectSelectorContribution` | `adele_core_extensions` | Core-owned URI selection contract with no natural existing public domain package; lifecycle stays in core |
| ModelProvider | Core/public capability | Provider-neutral kernel boundary |
| EnvironmentProvider | Core/public | Task lifecycle needs interchangeable Environment implementations |
| Environment filesystem/process APIs | Core/public | Tools/editors must be Environment-independent |
| DisplaySourceFile | Probably core/public | Diff, Search, diagnostics, navigation may all consume it |
| ConsoleService | Probably core/public | Commands, user shells, inspectors, future integrations may consume it |
| Task creation | Core | Task identity/lifecycle is core-owned |
| Session creation | Core | Session identity/lifecycle is core-owned |
| OrchestrationStrategy registration/binding | Core/public | Session creation/restoration must validate permanent strategy binding independent of optional UI |
| `SessionPresentationContribution` | `adele_ui` | Generic host presents an existing Session through exact strategy matching without owning strategy-specific UI |
| `ToolActivityInspectionContribution` | `adele_ui` | Exact Tool ID selects read-only individual invocation presentation; group composition stays host-owned and field interpretation stays plugin-owned |
| `ModelNativeActivityPresentationContribution` | `adele_ui` | Exact safe presentation kind selects rich read-only Inspection; Backend owns raw interpretation, safe activity survives frontend absence, and replay remains separate |
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
- zero Project selectors (unavailable), or multiple independent selector actions;
- strategy registered with no Agent Interaction UI consumer;
- Session with no matching presentation contribution, reported as unavailable without invalidating execution;
- tool invocation with no matching Inspection contribution, reported as unavailable without invalidating execution;
- raw native output without safe presentation, retained opaquely without invalidating execution;
- safe native activity with no matching rich presentation contribution, retaining compact activity while rich Inspection is unavailable;
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
- Does state belong to Project, Task, Session, Environment, strategy-owned state, plugin-owned Session/Task state, or an external authoritative system?
- Is a UI extension named for its semantic role or accidentally coupled to today's layout?
- Is presentation improperly coordinating domain lifecycle that core or another provider should own?

Do not implement every interface listed here in advance. Introduce the smallest real boundaries required by each vertical and use this topology as a convergence target rather than a speculative framework checklist.
