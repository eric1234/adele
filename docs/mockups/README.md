# ADELE Development Workflow UX Direction

## Status and purpose

This document captures the current UX direction for ADELE's **primary software-development workflows with the expected stock development plugin set and default configuration**.

It is intended to provide architectural and interaction context to future implementation and design agents working on ADELE. It should explain not only what the current mockups look like, but why the default UI is organized this way and which traditional IDE conventions we have deliberately chosen not to adopt.

This document is **directional rather than contractual** and is not a definition of immutable ADELE core UI or domain semantics.

The mockups should be read as one concrete composition approximately involving stock responsibilities such as:

- Local Directory Project Selector;
- Task Browser;
- Git-backed Environment provider;
- Agent Interaction + Chat strategy;
- Agent and Model configuration/policy plugins;
- Context Monitoring and Accounting;
- Filesystem/Search/Command/TODO/Plan tooling;
- Diff/Review;
- Internal Source Editor;
- Console/Terminal;
- OpenAI provider.

Other plugin/configuration sets may provide different Project selection, orchestration strategies, Environment implementations, source editors, review systems, status summaries, or presentation details while preserving ADELE's broader architecture.

The current physical layout shown here is also product direction rather than plugin API identity. A Session status contribution may currently appear on the right, for example, while a future layout could move it or make placement configurable without changing the semantic extension contract.

Some ideas in this document may not be part of the immediate implementation needed to make ADELE self-hosting. Once ADELE is used for real development, experience may show that some decisions should change. The near-term implementation may therefore be a subset of this design.

For canonical architectural boundaries, see:

- [`../architecture/plugin-extension-model.md`](../architecture/plugin-extension-model.md);
- [`../architecture/stock-plugin-direction.md`](../architecture/stock-plugin-direction.md);
- [`../architecture/agent-kernel-semantic-model.md`](../architecture/agent-kernel-semantic-model.md);
- ADR 0031 for Project/Task/Session/Environment direction.

---

# 1. Product model

ADELE is an **Agent Development Environment**, not primarily a text editor with an AI feature.

The core hierarchy relevant to this UX is:

```text
Project
    └── Task
         ├── Session
         ├── Session
         └── Session
```

Sessions operate against an **Environment**.

The common stock development case is effectively:

```text
Project
    └── Task
         └── Primary Environment
              ├── Session A
              ├── Session B
              └── Session C
```

Exceptional child Sessions may operate against additional Task-owned Environments:

```text
Task
    ├── Primary Environment
    │    ├── Session A
    │    └── Session B
    │
    └── Isolated/alternate Environment
         └── child Session C
```

## 1.1 Project

A Project is an abstract ADELE-owned identity/lifecycle concept, not intrinsically a directory.

The expected stock development composition provides a **Local Directory Project Selector** that uses the normal operating-system directory-selection UI and associates/resolves a Project from that directory.

Other selectors may later present recent Projects, a database/catalog, a cloud service, or another Project source without changing core Project semantics.

Different Projects can be open in different windows. The same Project may also be opened in multiple ADELE windows if desired.

## 1.2 Task

A Task is a durable unit of development work.

Examples:

- `SPHY-4934 — Add todo deadlines`
- `Refactor resolver API`
- `Improve terminal integration`
- `Review backend plugin loading`

A Task owns or anchors core/product state such as:

- its title and optional description;
- workflow category;
- top-level/user Sessions;
- its primary Environment association;
- Task-related artifacts and history.

Plugins may contribute additional Task/Session summary information such as usage/cost, Session progress, Environment status, SCM state, or warnings through Task Browser extension points. Task Browser does not need to understand each contributing plugin's domain.

In the normal stock workflow, a Task and its primary Environment feel closely related to the user even though Environment implementation belongs to an independent provider.

## 1.3 Session

A Session is an independent orchestration context within a Task and is permanently bound to the orchestration strategy that created it.

The mockups focus on the stock **Chat strategy**, so many examples below discuss conversation, Draft Request, timeline operations, and Chat-specific forks. Those are Chat strategy semantics, not a claim that every future orchestration strategy defines Session state the same way.

Multiple top-level Sessions may work against the same Task Environment. This allows separate contexts without unnecessarily duplicating the filesystem.

Examples of named Sessions might be:

- `Investigate circular dependency`
- `Review async resolution path`
- `Validate error propagation`
- `Address QA feedback`

Sessions should **not** normally be named `Session 1`, `Session 2`, etc. The stock strategy/UI can derive a meaningful name from the initial request, although the user may later rename it.

For the stock Chat strategy, Session-owned/strategy-owned state may include:

- conversation;
- Draft Request;
- progress/work items;
- active Chat/workbench arrangement;
- open inspections;
- active Agent/model overrides;
- conversation forks;
- Session-specific artifacts;
- child Session activity/inspection.

A different strategy may define substantially different durable state.

## 1.4 Environment

An Environment is the ADELE-level abstraction representing the practical filesystem/source and process context in which work occurs.

For the stock Git integration, the normal implementation is expected to be approximately:

```text
ADELE Environment: sphy-4934

Git implementation:
    worktree: sphy-4934
    branch:   sphy-4934
```

From the user's perspective this is simply one Environment named `sphy-4934`.

ADELE should **not** require users to routinely reason about the distinction between Git worktrees and branches.

The equality between Environment name, worktree name, and branch name is a useful default convention, not a core architectural invariant. If the branch changes independently, ADELE should tolerate/report that state rather than pretend the concepts cannot diverge.

Other Environment providers may use Docker, remote VMs, or other mechanisms. ADELE does not imply that a Git worktree Environment isolates ports, databases, caches, credentials, or every other runtime resource.

---

# 2. Core UX philosophy

ADELE should borrow useful conventions from IDEs without cargo-culting the IDE layout.

The important distinction is:

> The stock development UX is Task/Session-centric rather than editor-centric.

Primary work artifacts may include:

- conversation or other strategy content;
- code review;
- source files;
- plans;
- generated reports;
- rich tool output;
- terminals.

Source editing is important, but it is no longer assumed to be the dominant activity.

The shift created by agents is broadly:

```text
Traditional IDE
    write code → occasionally review

ADELE stock workflow
    direct agent → review work → inspect/edit manually when useful
```

The UI should therefore optimize for:

- understanding what an agent is doing;
- reviewing changes;
- giving structured feedback;
- navigating relevant code quickly;
- monitoring progress;
- inspecting tool activity;
- moving among Tasks and Sessions.

It should avoid forcing users to manage UI concepts that agents have made less important.

---

# 3. Active-session window shell

The stock Chat-oriented shell is conceptually:

```text
┌───────────────────────────────────────────────────────────────────────┐
│ ADELE   Project > Task > Session              Environment      ?  ⚙ │
├───────────────────────────────────────────────────────────────────────┤
│ optional │                                                           │
│ left aux │ Chat │ Diff │ Source 1 │ Source 2 │ ... │ Artifact │Right│
│          │                                                           │
├──────────┴─────────────────────────────────────────────────────┴──────┤
│ Shell │ Server │ inspected command output │ other console views      │
└───────────────────────────────────────────────────────────────────────┘
```

Most surfaces are optional.

A newly created stock Chat Session is intentionally simple:

```text
┌───────────────────────────────────────────────────────────────────────┐
│ ADELE   Project > Task > New Session           Environment      ? ⚙ │
├─────────────────────────────────────────────────────────┬─────────────┤
│                                                         │             │
│                         Chat                            │             │
│                                                         │             │
│                                                         │             │
└─────────────────────────────────────────────────────────┴─────────────┘
```

The application should accumulate UI only when work actually requires it.

The physical center/right/bottom arrangement is stock product direction, not the names of plugin extension APIs. The extension architecture uses semantic concepts such as Main Content, Session Status, Inspection, Navigation, and Stream/Console presentation.

---

# 4. Title bar and breadcrumb

The stock title bar provides:

- ADELE logo/identity;
- hierarchical breadcrumb;
- Environment identity when applicable;
- help;
- settings.

Example:

```text
ADELE   adele-core > SPHY-4934 > Investigate resolver failure

                                      env: sphy-4934       ?   ⚙
```

There is no user-profile/avatar UI in this default design. ADELE is a local desktop development application, not a collaborative social workspace.

## 4.1 Breadcrumb as navigation

The breadcrumb is functional navigation.

From:

```text
adele-core > Refactor resolver API > Validate error propagation
```

clicking `adele-core` returns to the Project-level Task Browser with no Task selected.

Clicking `Refactor resolver API` returns to the same Task Browser with that Task selected and its top-level Sessions visible.

This eliminates the need for a permanent Tasks navigation icon in the stock UX.

## 4.2 Environment identity is not a switcher

The Environment indicator is **status/identity**, not a routine dropdown for switching Environments.

Normally:

```text
env: sphy-4934
```

Clicking it may inspect Environment information.

It should not imply:

> Choose which Environment this Session should operate against.

Environment changes normally occur as consequences of explicit higher-level operations:

```text
switch Task
    → Task's Environment becomes active

switch Session within same Environment
    → Environment remains unchanged

switch to child/isolated Session
    → alternate Environment becomes active
```

Before any Task/Session is active, there is no Environment indicator.

## 4.3 Isolated/alternate Environment indication

An intentionally separate Environment should make that exceptional state visible:

```text
◇ Isolated · sphy-4934-debug
```

Additional Environments are not part of the default user workflow. They are expected mainly for programmatic child Session work, although explicit future user operations may expose them.

---

# 5. Left auxiliary surface

ADELE should **not** have a permanent VS Code-style activity rail in the stock development profile.

Earlier mockups included permanent icons for Tasks, Files, SCM, and Search. Further analysis showed that none justify permanent horizontal space in the default agent workflow.

Instead, ADELE has an **optional left auxiliary surface** (directionally a semantic `NavigationView`-style role).

Normally it is absent.

When useful:

```text
┌────────────────┬─────────────────────────────────────────────────────┐
│ SEARCH RESULTS │ primary work content                                │
│                │                                                     │
└────────────────┴─────────────────────────────────────────────────────┘
```

Potential auxiliary views include:

- search results;
- source outline;
- changed-file list;
- diff-file navigation;
- references;
- call hierarchy;
- test-result navigation;
- plugin-provided browsers.

The surface is generally invoked by a command/action, contextual, closable, and one view at a time initially.

## 5.1 Tasks

Tasks do not need a permanent left-nav destination in the stock layout.

Clicking the Project or Task breadcrumb provides access to the Task Browser.

## 5.2 Files

ADELE does not need a stock IDE-style filesystem explorer initially.

The primary navigation model is **Quick Open**:

```text
Ctrl/Cmd+P
```

Typing a few characters searches files:

```text
reso

lib/core/resolver.dart
lib/core/resolver_policy.dart
test/resolver_test.dart
```

A user who wants a conventional filesystem browser could install a plugin that provides one.

## 5.3 Search

Project search is an invoked operation, not a permanent destination.

For explicit search:

```text
Ctrl/Cmd+Shift+F
```

ADELE may open Search Results in the auxiliary surface.

Agent searches normally remain summarized in Chat unless the user explicitly inspects the results.

## 5.4 SCM

ADELE needs deep SCM integration but does not necessarily need to be a general graphical SCM client.

Stock Git integration should support workflow-specific operations such as understanding changes, reviewing diffs, approving/unapproving changes, Task-level comparison, and commit Commands.

Generic branch browsers, interactive rebases, stash managers, Git graphs, etc. are not default UX requirements. Plugins may provide richer graphical SCM clients.

---

# 6. Center workspace / Main Content stock layout

The stock active-session Main Content layout is intentionally **one-dimensional and horizontally ordered**, rather than an arbitrary recursive tiling system.

The current semantic order is:

```text
Chat
Diff
Source Group
Artifact
```

Visually:

```text
[ Chat ] [ Diff ] [ Source 1 | Source 2 | Source 3 ] [ Artifact ]
```

Not every region is visible at all times.

Current stock layout rules:

- Chat is singleton for the Chat strategy.
- Diff is singleton.
- Source Group contains zero or more visible editor views.
- Artifact is singleton.
- ordering is fixed;
- only vertical pane boundaries are supported initially;
- top-level panels are not arbitrarily reordered.

These are UX choices for the stock composition, not requirements that every orchestration strategy render Chat or that plugin extension APIs expose `center` coordinates.

## 6.1 Width and horizontal overflow

Each surface has a practical minimum useful width. Available space is divided/shrunk until minima are reached.

If visible panels cannot fit, the Main Content workspace becomes horizontally scrollable while title/status/stream areas remain fixed in the current layout.

Focusing an offscreen pane automatically scrolls enough to reveal it.

ADELE should not automatically hide panels merely because space becomes tight. The visible set represents explicit user state.

## 6.2 Resizing

Pane boundaries are draggable. Manual resizing redistributes space while respecting practical minima.

Pane widths are live Session/window workbench state rather than core Session semantics.

## 6.3 Focus/maximize

A temporary `Focus Current View` or equivalent Command may hide other Main Content surfaces while preserving the underlying arrangement. Restoring returns to the previous layout.

---

# 7. Chat / Session timeline

For the stock Chat orchestration strategy, Chat is the most important primary surface.

It should not visually pretend to be two people exchanging social messages. There are no fake avatars, `You`, `ADELE Agent`, or unnecessary identity labels beside every message.

Authorship is conveyed through alignment/styling:

```text
                              ┌────────────────────────┐
                              │ User message           │
                              └────────────────────────┘

┌───────────────────────────────────┐
│ Agent response                    │
└───────────────────────────────────┘
```

User messages are generally right-aligned; Agent messages left-aligned. Agent blocks remain wide enough for Markdown, code, tables, links, etc.

A different orchestration strategy may own a substantially different Main Content surface rather than a Chat timeline.

## 7.1 Chat is logically permanent but hideable

Within a Chat Session, the conversation is the strategy's home.

Chat may be hidden temporarily to reclaim width, but this is hide/show rather than destroying strategy state.

When restored it preserves transient view state such as scroll position, draft, expanded content, attachments, and other UI state.

---

# 8. Operation groups in Chat

Between visible user/Agent messages, the stock Chat strategy displays a compact summary of agent activity.

Common operation types include tool calls and provider-visible reasoning/activity traces. Individual operations should not fill the transcript with noise; contiguous operations between messages are grouped.

Example while active:

```text
⌁ Investigating resolver cycle handling…
```

Completed:

```text
⌁ Investigated resolver cycle handling · 8 operations
```

Clicking the group can create an `InspectionPresentation` in the current stock right-side inspection area:

```text
ACTIVITY · Investigated resolver cycle handling

✓ Reasoning    Examining resolver architecture
✓ Read         resolver.dart:40–160
✓ Search       "_resolving"
✓ Reasoning    Checking recursion behavior
✓ Shell        dart test ...
✓ Read         resolver_test.dart
```

Clicking a specific operation adds a separate inspection.

## 8.1 Reasoning/provider differences

ADELE should not assume every provider exposes full reasoning.

Depending on provider capabilities, ADELE may receive detailed reasoning, a reasoning summary, or no reasoning. The UI displays only what the provider legitimately exposes.

---

# 9. Progressive tool representation

A tool invocation may have several representations. This is a core product pattern even though specific renderers are plugin/extensible.

Example shell search:

```text
Chat
    ✓ Search for foo, bar, or baz
```

Click:

```text
Inspection

SHELL · Search for foo, bar, or baz

Command
grep -RnE 'foo|bar|baz' ...

Output
first lines...
...

[Show full output]
```

Then the active Console/Stream provider may show the full output.

Other examples:

```text
Shell
    Chat → Inspection → Console/Stream

File read
    Chat → Inspection → source editor

File edit
    Chat → perhaps Inspection → Diff

Search
    Chat → Inspection → optional rich result

MCP
    Chat → Inspection → optional plugin-provided result
```

Tools should not all be forced through identical presentations.

---

# 10. Persistent Draft Request

The stock Chat composer is not merely a transient text box. It is a persistent, rich, Agent-editable **Draft Request document** owned by Chat strategy state for the Session.

It should be continuously saved so partially written prompts are not lost across switching Sessions/Tasks, closing/reopening ADELE, or application restarts.

Conceptually for Chat:

```text
Session
└── Chat strategy state
    ├── conversation
    ├── Draft Request
    ├── progress references
    ├── inspections/view state
    └── artifacts
```

## 10.1 Submission

Before submission, editing Draft Request is ordinary document editing.

When submitted:

```text
Draft Request
    → immutable snapshot becomes user message
    → new empty Draft Request is created
```

Editing an already-submitted historical user message is different and creates a Chat conversation fork.

## 10.2 Rich text

Draft Request uses a rich-text/structured editor even in compact mode. It may contain Markdown-like formatting, lists, code, file references, images, and structured references.

The underlying representation should remain model/tool-friendly rather than opaque rich-text state.

---

# 11. Expanded Draft Request

Draft Request can expand into a document-oriented editing presentation.

Collapsed:

```text
┌─────────────────────────────────────────────┐
│ Add due dates to todo items...              │
├─────────────────────────────────────────────┤
│ Requirements ▾   Fast · Low         Refine │
└─────────────────────────────────────────────┘
```

Expanded:

```text
┌─────────────────────────────────────────────┐
│                 DRAFT REQUEST               │
│                                             │
│ Add an optional deadline to todo items.     │
│                                             │
│ Requirements                               │
│ - ...                                       │
│                                             │
├─────────────────────────────────────────────┤
│ document-specific instruction...            │
└─────────────────────────────────────────────┘
```

Expanded/collapsed are two views of the same document. Chat history may be temporarily hidden while Draft Request occupies the pane. The normal Main Content focus/maximize Command can provide additional space.

---

# 12. Requirements workflow

The stock development installation may ship a `Requirements` Agent configuration.

This is not hard-coded orchestration behavior. It is Agent configuration/context/tool access that can refine the Draft Request.

Example stock behavior:

> Improve the prompt based on your understanding of the application. The prompt is Markdown. Perform limited investigation only where necessary to resolve important ambiguity. This is requirements definition, not implementation planning. Use prompt tools to inspect/update the current draft. If substantial, expand it for user review.

A common stock workflow is:

```text
rough request
    ↓ Requirements
detailed requirements
    ↓ Plan
implementation plan
    ↓ Code
implementation
```

This workflow is driven by configurable Agent instructions/tools and Agent/model-control plugins rather than hard-coded Chat strategy transitions.

---

# 13. Document-specific AI editing

Both Draft Request and Plan may be Agent-editable documents.

They can expose a small document-specific instruction input such as:

```text
Rename "Due Date" to "Deadline" in the UI and data model.
                                                       Apply
```

Resulting inference counts toward Session usage/cost but need not appear as normal Chat turns. Agent document edits should be one editor transaction so they can be undone easily.

---

# 14. Agent configuration

A stock Agent Configuration/Policy plugin may define concepts resembling:

```text
Agent
    stockContext
    allowedTools
    defaultModelType
    defaultReasoningEffort
    submitLabel = "Send"
```

Examples may include Ask, Requirements, Plan, Code, and Debug.

These Agent definitions are plugin/configuration state that contributes to Chat UI and structured inference composition; Chat itself does not need to own the Agent-selection semantics.

## 14.1 Initial Agent

Configuration can define an Initial Agent, with a likely stock default of Requirements. Users may choose Plan, Code, or another Agent.

## 14.2 Agent-selection tool

The Agent plugin may provide a model-callable tool such as `set_agent`/`select_agent` that changes Agent state for the **next inference**.

Agent instructions can recommend transitions or let the model choose dynamically. The tool should target stable Agent IDs rather than display names.

The exact semantics are broader than a hard-coded workflow step: Chat does not invoke an Agent selector directly; Agent state participates independently in inference composition.

---

# 15. Commands and skills

Agents and skills/commands both package reusable context but operate at different levels.

An Agent defines persistent role/policy; a Skill defines instructions for a particular invocation type such as commit, review-api, security-review, or write-tests.

`/` can be the composer interaction for discovering/invoking skills or application Commands.

Skills must not elevate Agent permissions. An Ask Agent without SCM-write access does not gain commit authority merely because `/commit` is selected.

Commands may declare required capabilities so incompatible commands can be unavailable.

Application Command registration, Command Palette, and keybinding resolution are core host infrastructure. Plugins provide Commands and suggested bindings.

---

# 16. Agent/model controls

The Draft Request composer may expose selected Agent, provider, semantic model type, reasoning effort, and Send/Refine/etc.

Example:

```text
Code ▾        OpenAI · Cheap · High            Send
```

These controls are expected to be plugin-contributed Chat prompt accessories rather than hard-coded knowledge inside Chat.

Agent selection is relatively prominent. Provider/model/reasoning are visually secondary because defaults should normally be appropriate.

## 16.1 Persistent overrides

If the user changes model type or reasoning from the Agent default, the override can persist until changed/reset or Agent changes. The state affects subsequent inference resolution, never an already-resolved invocation.

## 16.2 Model types per provider

Model type describes intent while concrete mapping is provider-specific:

```text
Cheap
    OpenAI     → configured inexpensive OpenAI model
    Anthropic  → configured Haiku-class model
    Google     → configured inexpensive Gemini model
```

Provider and semantic model type are independent dimensions that resolve to a concrete configured model.

## 16.3 Custom model

The user can bypass semantic type mapping and select a concrete model directly for experimentation. The composer should display that concrete override honestly.

---

# 17. Context usage

A Context Monitoring/Compaction plugin may contribute Session status such as:

```text
Context 37%
```

This represents effective context expected for the next invocation given current strategy/Agent/model state.

A popover may show token usage/breakdown and a Compress Context action. Changing model can change the percentage because window capacity differs; the current Draft Request is included in the estimate.

## 17.1 Context compression

Explicit compression should not erase visible Chat history. Earlier content is summarized for future inference while complete history remains visible, with a timeline marker exposing the summary.

This behavior is replaceable/context-plugin direction rather than intrinsic Chat core semantics.

---

# 18. Cost, usage, and quota

An Accounting / Usage / Quota plugin is expected to make model consumption visible.

Sessions may mix subscription-covered models, direct API models, local/free models, and multiple providers, so accounting should be invocation-based rather than calculated from whichever model is currently selected.

Historical invocations retain the provider/model/usage basis actually used where the underlying retained history supports it.

## 18.1 Session-level cost

Chat status may show `Cost $0.42` or `Cost Included`, with a richer popover for billed spend, subscription-covered usage, API-equivalent cost/value, and provider/model breakdown.

## 18.2 Turn-level cost

A subtle turn affordance can expose provider/model, token usage, caching, billed cost, subscription coverage, and equivalent cost without cluttering the transcript.

## 18.3 Subscription usage pools / quota

When provider integrations expose quota/rate-limit/allowance information, Accounting may contribute a small usage indicator to relevant UI.

Only display information the provider can actually know. If quota exhaustion changes future billing behavior, the transition should be visible rather than silent.

---

# 19. Attachments and references

## 19.1 Images

Images can be dragged/dropped into Draft Request. If the effective model does not support images, ADELE should explain that and let the user change model/provider rather than silently changing it.

## 19.2 File references

Typing `@` can perform file completion. A selected reference is internally structured around Environment/source identity rather than merely text.

Possible future range forms include:

```text
@foo.rb:40
@foo.rb:40-80
```

Selecting code in the Source Editor should eventually allow inserting an equivalent structured reference.

---

# 20. Running, stopping, and scrolling

While the Agent runs, Send becomes Stop, active operation summary updates, and the user can interrupt execution.

Auto-scroll follows streaming activity only if the user is near the bottom. If the user scrolls upward, ADELE must not pull them back; it shows `Jump to latest`.

Approval/decision requests requiring user intervention appear as explicit actionable timeline content rather than disappearing inside an operation group.

---

# 21. Conversation forks

In the stock Chat strategy, historical user messages may be edited to create a fork while preserving the original continuation.

Lightweight navigation such as `‹ 2 / 3 ›` can appear where forks exist. The active branch determines model context; sibling branches are excluded. Session cost still includes usage incurred on all branches.

Forking normally shares the same Environment. An explicit future operation could fork into another Environment.

Fork representation belongs to Chat strategy/plugin state unless future strategies demonstrate common core semantics.

---

# 22. Session status/inspection stack

The stock layout currently shows a right-side stack that can be collapsed.

Semantically it contains Session status contributions plus explicitly opened inspection presentations; those concepts should not depend on being physically right-aligned forever.

The current stock arrangement is:

```text
SESSION PROGRESS               [status contribution]
──────────────────────────────────────────
Newest inspection
──────────────────────────────────────────
Older inspection
```

New inspections appear immediately beneath Session Progress. Manual drag/reordering is not initially needed.

---

# 23. Session Progress

Once the TODO/Progress plugin has Session work items, it contributes Session Progress automatically.

Example:

```text
SESSION PROGRESS

✓ Understand resolver architecture
✓ Reproduce cycle failure
◔ Implement resolver fix
○ Add regression tests
○ Validate test suite

Overall progress
━━━━━━━━━━━━━━━━━━────────────
```

States include complete, in progress, and not started.

Approximate internal progress estimates/weights may exist, but the stock UI avoids numeric percentages that imply false precision.

These work items belong to an individual Session. They are not one canonical Task TODO list, and completing them does not automatically move the Task between user-controlled workflow categories.

---

# 24. Inspection cards

Examples include tool-call details, grouped operation activity, file-read details, search details, MCP invocation details, change-set metadata, and plugin-provided structured inspections.

Cards are independently expandable/collapsible/removable and not manually reordered initially. Closing an inspection removes its **view**, not the tool call, output, artifact, or underlying state.

Clicking an originating item again restores/reuses the existing inspection where appropriate.

Agent activity should not automatically flood Inspection with cards. Most appear because the user explicitly requests them.

---

# 25. Console / Stream presentation

The stock bottom area is not a traditional IDE category panel. It is provided by the Console/Terminal plugin as an Environment-oriented stream/console experience.

Tabs represent concrete resources/presentations such as:

```text
>_ main
>_ server
$ dart test
$ grep CircularDependency
```

## 25.1 Interactive shells

Interactive shells are explicitly created and writable runtime resources of the current Environment.

## 25.2 Tool output

Wide/console-oriented tool output opens here only when explicitly inspected; Agent execution alone does not create tabs.

Closing a retained command-output tab removes presentation, not historical invocation data.

## 25.3 Environment ownership

Interactive shell resources are Environment-owned. If two Sessions share the same Environment, switching Sessions leaves those shell resources available. Switching to another Task/Environment changes the visible Environment resources.

A tool invocation may belong to Session history while its open Console presentation is Environment/window presentation state.

The semantic Console API should be broader than a single `OpenTerminal`: interactive resources may accept input, while retained read-only output does not.

---

# 26. Diff reviewer

The stock Diff/Review Viewer is a first-class review experience, not merely another source viewer.

The stock viewer is singleton, unified initially, continuous across files/hunks, and backed by SCM/change-provider state.

Side-by-side Diff is deliberately postponed.

## 26.1 Review scopes

The stock UX uses concepts such as:

```text
Changes to approve
Current changes
Task changes
```

The precise SCM computation belongs to the active change/SCM provider. For Git, these map approximately to working-tree/index/HEAD/Task-branch relationships.

---

# 27. SCM as source of truth

ADELE should not maintain a parallel database of SCM acceptance state where the SCM natively represents it.

For stock Git:

```text
working tree vs index
    → Changes to approve

index vs HEAD
    → approved uncommitted state

Task branch/baseline relationship
    → Task changes
```

Approve/unapprove modifies the Git index through Git's review-domain implementation. Manual/Agent edits modify the Environment filesystem. Commit modifies Git state.

Diff watches/observes relevant filesystem/SCM changes and recomputes its projection. Manual `git add` should naturally refresh the UI rather than require ADELE/Git synchronization state.

The watcher should be cross-platform in abstraction.

---

# 28. Approve / Unapprove

The stock review grammar is intentionally small.

Unapproved changes allow Comment + Approve. Approved uncommitted changes allow Comment + Unapprove. Committed Task changes allow Comment.

There is **no normal Reject button**.

Approval changes acceptance state; comments/manual edits/Agent work change code. This reduces destructive operations and fits an agent-review workflow.

Explicit discard/reset operations may exist as deliberate Commands/plugins rather than normal hunk review.

---

# 29. Diff organization

Diff is a continuous review document with File → hunks, potentially sticky headers, and a lightweight Files jump menu. A Changed Files navigation view may be opened for large reviews.

Hunk/file/change-set actions include Approve/Unapprove where applicable, Comment, Display/Open in Source, context expansion, and Submit Review.

These controls belong inside the Diff surface rather than in generic Inspection.

---

# 30. Review comments

The stock Diff workflow follows a code-review model similar to GitHub.

Users may comment on a line/range/hunk/file. Comments collect as pending review feedback and can be submitted as one coherent structured request to the active feedback target (Chat strategy in the stock composition).

A submitted review appears compactly in Chat rather than dumping every line comment into the transcript.

---

# 31. Diff comment anchors

Review comments should be structurally anchored to file/revision/change-set/hunk/side/range identity rather than raw line numbers alone.

If code changes invalidate an anchor, ADELE may mark it outdated rather than attach it to unrelated code.

Pending review comments are Diff/Session plugin state even though code/approval state comes from SCM.

---

# 32. Display in Source

Every relevant Diff location should make it easy to display the full source file through the general `DisplaySourceFile` capability.

The stock default provider is Internal Source Editor. It may focus an existing editor or create a Source view and navigate to the relevant location. An External Editor provider may be available as an alternate.

Manual edits naturally appear back in Diff because Environment filesystem + SCM remain authoritative.

Diff does not depend on the Internal Source Editor implementation; if no source-display provider is active, the file remains reviewable but the navigation affordance is unavailable.

---

# 33. Commit workflow

Diff does not have a hard-coded Save Changes/Commit implementation.

Committing is preferably a configurable application/Agent Command such as `/commit`. A visible Commit button, if added, should invoke the same underlying domain/Command path rather than a second implementation.

After commit, changes disappear from Current Changes but remain visible in Task Changes according to the SCM provider's semantics.

---

# 34. Source editor group

Source editing is a supporting interaction rather than ADELE's central product identity, but **manual editing is an intended capability**.

The stock Internal Source Editor plugin provides Source Group views with multiple visible editors:

```text
[ resolver.dart ][ graph.dart ][ resolver_test.dart ]
```

There are no hidden source tabs in this direction. A source file is visible or not open in the Source Group.

## 34.1 Vertical-only source layout

Source views are side-by-side initially. Horizontal splits are postponed. Simple ordering enables strong keyboard focus/move operations and drag/drop reordering.

---

# 35. Opening/displaying files

Quick Open is the default file-navigation mechanism.

Normal display/open can replace the active Source editor; open-to-side can append another view. The same semantic distinction should apply to links from Chat, Diff, Search, Inspection, and references.

The underlying cross-plugin capability is better thought of as `DisplaySourceFile`: a provider may focus an existing editor rather than always opening a new one.

---

# 36. Same file in multiple editors

Normally displaying an already-visible file focuses the existing view.

An explicit `Split Current Editor` operation can create two independent Editor Views over the same underlying Document with independent cursor/selection/scroll/folds and shared edits.

This distinguishes navigation to a document from creating another view of that document.

---

# 37. Editor implementation direction

`code_forge` is currently a promising Flutter editor component.

ADELE does not require the world's most sophisticated editor because manual source editing is secondary to agent-driven implementation/review, but hand-editing must still be reliable and practical.

ADELE should wrap CodeForge behind an internal editor/document abstraction rather than let a component API define the product architecture.

---

# 38. Editor save/external-change semantics

The stock Source Editor should behave approximately as an autosaving view of the real Environment filesystem.

Manual edits should become visible to Agents, terminals, SCM, and Diff without requiring an IDE-style save ritual.

Edits may flush after a short debounce, with Save forcing immediate flush if retained.

External modification is expected because Agents and shells can change open files. Reload clean external changes while preserving view state; never silently overwrite conflicting local/external edits.

---

# 39. Document versus editor view

Internally distinguish:

```text
Document
    Environment
    path/resource identity
    current content/revision

Editor View
    cursor
    selection
    scroll
    folds
```

Multiple Source views can share one Document.

---

# 40. Editor navigation history

Each Source pane may maintain browser-like Back/Forward navigation history over files/locations without introducing hidden file tabs.

---

# 41. Source intelligence

Useful inline features include syntax highlighting, line numbers, folding, local find, hover documentation, go-to-definition, inline diagnostics, basic code actions, and semantic highlighting.

Diagnostics should appear inline rather than requiring a permanent Problems panel.

ADELE should avoid a second independent editor-AI configuration system unless real need emerges; Agent/model/cost configuration should remain coherent across the product.

---

# 42. SCM decorations in Source

Subtle gutter indicators may show modified/unapproved lines. Clicking can focus Diff on the corresponding hunk.

Approval remains a Diff interaction rather than duplicated inside Source.

---

# 43. Source references into Draft Request

Selecting code should support a Command such as `Reference in Draft`, inserting a structured reference equivalent to `@lib/core/resolver.dart:72-91`.

---

# 44. Singleton Artifact viewer

The stock Main Content layout includes a singleton Artifact surface for Plan, rich MCP result, Markdown/report, structured search result, test report, generated artifact, etc.

Opening another Artifact replaces the current visual representation; the underlying artifact persists and can be reopened.

---

# 45. Plan

A Plan is distinct from Session Progress.

Plan is substantial implementation content/artifact containing phases, strategy, design decisions, dependencies, and technical approach. Session Progress is lightweight operational work-item state.

The stock Plan plugin may provide model tools and Artifact/Main Content presentation. Plan is not intrinsic to every Session.

---

# 46. Project and Task Browser

After a Project is selected, the stock **Task Browser plugin** provides the Project/Task/Session selection and management experience shown by the mockups.

The Task Browser is not assumed to be a `MainContentView` inside an already-active Session workbench. Before a Task/Session is selected there may be no normal active-session shell at all; the Task Browser may own a dedicated Project-level screen/window/shell. A future UI could embed it into the normal workbench without changing its semantic extension points.

The Task Browser also serves as the top-level/user Session selector; there is no separate dedicated Session-selection page in the stock design.

Conceptually:

```text
┌──────────────────────────────────────────────────────────────────────┐
│ ADELE   adele-core > Tasks                                      ? ⚙│
├───────────────┬───────────────────────────────────┬──────────────────┤
│ TASKS         │ Tasks                             │ TASK DETAILS     │
│               │                                   │                  │
│ All        12 │ + New Task        Search...       │ selected task    │
│ Active      5 │                                   │                  │
│ In Review   2 │ task rows...                      │ Sessions         │
│ Waiting     3 │                                   │ Usage            │
│ ...           │                                   │ Activity         │
│ Archive    47 │                                   │                  │
└───────────────┴───────────────────────────────────┴──────────────────┘
```

There is no Environment indicator merely because the Project Task Browser is open; no active Session/Environment is necessarily selected.

The browser defines semantic Task/Session summary extension points so Accounting, TODO/Progress, Git/Environment status, and future plugins can contribute compact fragments. The browser composes those contributions instead of querying each plugin-specific domain itself.

---

# 47. Task categories and Archive

Task categories are configuration-managed/user-controlled workflow states such as Active, In Review, Waiting for QA, Blocked, and On Hold.

`All` means all non-archived Tasks. Archive is special state/view separate from category. A user could still configure `Done` before archiving.

Saved Filters and task pinning are deliberately omitted for now.

---

# 48. Task list

Each Task row remains lightweight, with title, brief description, Session count, last activity, and category when useful.

Additional data such as cost, Environment/SCM status, and warnings are expected to arrive through `TaskSummaryContribution`-style extensions rather than hard-coded Task Browser dependencies.

Search is important because Tasks accumulate. Last-activity sorting is likely sufficient initially.

---

# 49. Task activity indicators

Workflow category and live execution activity are different dimensions.

Task rows may show small working/waiting indicators derived from core Session/Run status or contributed summaries. A Task can show both if different Sessions are working/waiting.

These indicators do not automatically change the user-controlled Task category.

---

# 50. Task details / Session selection

Selecting a Task populates Task Details rather than immediately entering a Session.

The stock pane lists top-level/user Sessions and `+ New Session`, plus Task summary contributions such as usage/cost or status.

Clicking a Session enters/resumes it. There is no separate ambiguous Resume button.

Agent-created child Sessions are not normal peers in this list. They are primarily inspected from the parent Session/orchestration surface that created them.

---

# 51. Task usage

Accounting may contribute Task-level aggregates across Sessions such as input/output/cache tokens, billed cost, API-equivalent cost, or other usage summary.

Detailed provider/model breakdown can remain behind hover/popover rather than dominate Task Browser.

This information belongs to the Accounting extension, not Task Browser's core domain model.

---

# 52. New Session

`+ New Session` is available from Task Browser and may also be a shortcut from an active Session surface.

Use **Session**, not `Chat`, consistently at the product level. Chat is one orchestration strategy/surface.

A normal stock path can create a Session bound to the configured/default Chat strategy, associate it with the Task's primary Environment, initialize Chat state, select configured Agent defaults, and focus Draft Request.

If multiple orchestration strategies are installed/applicable, Agent Interaction may expose strategy choice. A Session is permanently bound to the selected strategy; changing strategy means creating another Session.

---

# 53. New Task

`+ New Task` is prominent in Task Browser.

A small dialog may gather **Task-owned** data such as name/title and category:

```text
NEW TASK

Name
┌─────────────────────────────────────────┐
│ SPHY-4934                               │
└─────────────────────────────────────────┘

Category
[ Active ▾ ]

                         Cancel   Create Task
```

Task Browser then submits this intent to **core Task creation**. It does not directly create a Git worktree, Docker container, or other Environment.

The stock lifecycle is directionally:

```text
Task Browser
    -> CreateTask(title/category/...)

Core Task lifecycle
    -> create durable Task identity
    -> resolve applicable/default EnvironmentProvider
    -> stock default: Git Worktree provider
    -> provider establishes primary Environment
    -> core associates Environment with Task
    -> optional default Session creation / UI transition
```

If multiple Environment providers are enabled and user choice is useful, core can expose a reusable provider-selection control in the creation flow. The Task Browser should not own Git/Docker-specific logic.

A Task can retain history even if expensive Environment resources are later released, subject to the selected provider's lifecycle semantics.

---

# 54. State ownership

The current stock conceptual ownership model is:

| Surface/state | Owner |
|---|---|
| Project identity | Core Project domain |
| Concrete Project association/selection | Project selector/provider plugin |
| Task category/title/metadata | Core Task domain |
| Primary Environment association | Core Task domain + Environment provider lifecycle |
| Chat conversation/Draft/forks | Chat strategy state for Session |
| Session progress/work items | TODO/Progress plugin, Session scoped |
| Agent/model overrides | Agent/Model plugins, Session scoped |
| Main Content/right inspection live layout | window/workbench state, possibly seeded from remembered state |
| Shell/process resources | Environment/runtime-resource provider |
| Console presentation | Console plugin + window/Environment context |
| Filesystem/process implementation | Environment provider APIs |
| SCM state | SCM plugin/external SCM |
| Diff projection | Diff plugin derived from change/SCM provider |
| Usage/cost/quota | Accounting plugin |

Two Sessions sharing an Environment can have different Chat/workbench state while seeing the same Environment-owned shell resources. Switching Tasks/Environments changes Environment resources while strategy/window state changes with the selected Session.

---

# 55. Workbench restoration

Stock Chat/workbench state may eventually preserve Chat scroll/view state, Draft Request, Main Content pane visibility/widths, horizontal scroll, Source views/cursors/folds/history, Diff review position, current Artifact, inspection cards, and Agent/model overrides.

Environment/runtime state may preserve/reconnect interactive shells, running processes where possible, retained command-output resources, and console-resource state.

These persistence mechanisms need not all be Session fields. The profile/configuration architecture distinguishes underlying shared domain state, plugin-owned state, live per-window presentation state, and remembered defaults for future windows.

Not every part needs to exist before self-hosting; the ownership boundaries should merely avoid blocking later persistence.

---

# 56. Deliberately postponed or excluded IDE conventions

The following are not currently standard stock ADELE requirements:

- permanent VS Code-style activity rail;
- stock filesystem Explorer;
- general graphical SCM client;
- permanent Search destination;
- permanent Problems panel;
- editor document tabs;
- arbitrary two-dimensional editor splitting;
- side-by-side Diff;
- destructive Reject controls in Diff;
- hard-coded Commit workflow;
- Session artifact dashboard permanently pinned right;
- multiple simultaneous generic Artifact viewers;
- separate AI autocomplete/model system inside Source Editor.

These can later arrive through Commands, contextual Navigation views, plugins, or evidence from real usage.

---

# 57. Plugin/extensibility implications

The mockups should be implemented through **semantic extension roles**, not plugins claiming fixed physical coordinates.

Likely broad core-facing semantics include concepts such as:

```text
MainContentView
NavigationView
SessionStatusContribution
InspectionPresentation
StreamView / ConsolePresentation
ContextStatusContribution
Commands / keybindings
```

Examples:

```text
filesystem browser plugin
    → NavigationView

graphical Git client plugin
    → Navigation/Main Content as appropriate

database schema browser
    → NavigationView

profiler output
    → Main Content or Stream presentation

custom tool detail
    → InspectionPresentation
```

A plugin may define further extension points inside its own surface. Chat can define prompt accessories and turn actions; Task Browser can define Task/Session summary contributions; Diff can define review/change-provider interfaces.

The Task Browser itself may be a dedicated Project-level selection experience rather than a Main Content provider.

Plugins should participate in established semantic composition rather than create arbitrary disconnected panel systems.

---

# 58. General design principles

## 58.1 User attention controls arrangement

Agent activity should not gratuitously open, close, or rearrange panels. Tools normally remain compact until explicitly inspected.

## 58.2 Views are disposable; underlying objects are not

Closing Diff, Plan, an inspection card, console output, or Source view removes presentation, not the underlying change/artifact/invocation/file.

## 58.3 Direct navigation beats permanent chrome

Prefer breadcrumb, Quick Open, Command Palette, links from Agent output, and contextual Navigation views over permanent navigation merely because IDEs traditionally have it.

## 58.4 SCM is authoritative

For SCM-backed behavior, derive state from SCM whenever practical instead of maintaining parallel synchronized acceptance state.

## 58.5 Configuration/plugins define workflow

Requirements → Plan → Code should be easy out of the box but arise from configurable Agent instructions, model-callable Agent/Model tools, Commands, and plugins rather than hard-coded Chat strategy workflow logic.

## 58.6 Progressive disclosure

Show compact summaries first; allow drill-down from Chat summary to structured Inspection to full specialized representation.

## 58.7 Optimize for review

The stock development composition assumes agents increasingly produce implementation while humans inspect, direct, review, and hand-edit when useful. Diff, Session progress, tool transparency, and rapid full-source inspection/editing are therefore central.

---

# 59. Near-term implementation versus direction

This document describes desired stock UX, not the minimum feature set required before ADELE can self-host.

Near-term implementation should prioritize whatever subset enables ADELE to improve itself, plausibly including portions of:

- Project/Task/Session lifecycle;
- a stock Project Selector and Task Browser;
- Chat with persistent Draft Request;
- Agent/model policy/controls;
- basic tool activity;
- one Environment provider;
- mutable source tools/editor;
- Diff review;
- command/console functionality;
- enough persistence to resume work.

Advanced accounting, quota meters, rich forks, multi-shell restoration, precise progress weighting, document-specific AI editing, plugin-provided view ecosystems, and extensive Task analytics can arrive incrementally.

Implementations should avoid unnecessary complexity merely to satisfy this document in one phase while also avoiding shortcuts that fundamentally contradict the accepted architecture.

---

# 60. Expected evolution

This UX should be treated as a hypothesis tested by using ADELE for real development.

Some ideas will work better than expected; some will prove unnecessary; other workflows will emerge only after substantial self-hosting use.

Future changes should preserve the reasoning behind these decisions while remaining willing to modify details.

The primary goal is not a perfect static IDE design. It is a coherent **agent-development workbench** produced by a replaceable plugin/configuration composition:

```text
select Project
    ↓
select/create Task + Environment
    ↓
one or more top-level Sessions
    ↓
direct stock Chat Agent through Draft Request
    ↓
observe progress and tool activity
    ↓
review changes
    ↓
inspect/edit source where useful
    ↓
optionally delegate to child Sessions
    ↓
iterate
```

That is the current stock development-workflow direction for ADELE, not an assertion that every ADELE profile/plugin set must look or behave exactly this way.
