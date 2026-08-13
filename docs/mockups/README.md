# ADELE Development Workflow UX Direction

## Status and purpose

This document captures the current UX direction for ADELE's **primary software-development workflows**.

It is intended to provide architectural and interaction context to future implementation and design agents working on ADELE. It should explain not only what the current mockups look like, but why the UI is organized this way and which traditional IDE conventions we have deliberately chosen not to adopt.

This document is **directional rather than contractual**.

Some of these ideas may not be part of the immediate implementation needed to make ADELE self-hosting. Likewise, once ADELE is usable for real development, experience may show that some of these decisions should change. The purpose is to establish the current product model and design philosophy so that incremental implementations move in a coherent direction rather than independently recreating conventional IDE behavior.

The near-term implementation may therefore be a subset of this design.

---

# 1. Product model

ADELE is an **Agent Development Environment**, not primarily a text editor with an AI feature.

The core hierarchy is:

```text
Project
    └── Task
         ├── Session
         ├── Session
         └── Session
```

Sessions operate against an **execution environment**.

The common case is effectively:

```text
Project
    └── Task
         └── Primary Execution Environment
              ├── Session A
              ├── Session B
              └── Session C
```

Exceptional sessions or agent subtasks may operate against isolated execution environments:

```text
Task
    ├── Primary Environment
    │    ├── Session A
    │    └── Session B
    │
    └── Isolated Environment
         └── Session C
```

## 1.1 Project

A project is fundamentally a directory opened by the user.

Projects are selected through the normal operating-system directory-selection UI.

ADELE may also expose a command for quickly reopening or switching to a recent project.

Different projects can be open in different windows. The same project may also be opened in multiple ADELE windows if desired.

## 1.2 Task

A Task is a durable unit of development work.

Examples:

- `SPHY-4934 — Add todo deadlines`
- `Refactor resolver API`
- `Improve terminal integration`
- `Review backend plugin loading`

A Task owns:

- its title and optional description;
- workflow category;
- sessions;
- its primary execution environment;
- task-level usage/cost information;
- task-related artifacts and history.

In the normal workflow, a Task and its primary execution environment feel like one thing to the user.

## 1.3 Session

A Session is an independent agent context within a Task.

Multiple Sessions may work against the same Task environment. This allows separate conversations and contexts without unnecessarily duplicating the filesystem.

Examples of named sessions might be:

- `Investigate circular dependency`
- `Review async resolution path`
- `Validate error propagation`
- `Address QA feedback`

Sessions should **not** normally be named `Session 1`, `Session 2`, etc. ADELE derives a meaningful name from the initial request, although the user may later rename it.

A Session owns or retains state such as:

- conversation;
- Draft Request;
- progress/work items;
- center workspace arrangement;
- right-side inspections;
- active agent and model overrides;
- conversation forks;
- session-specific artifacts.

## 1.4 Execution environment

An Execution Environment is an ADELE-level abstraction representing the filesystem/runtime context in which work occurs.

For the Git SCM integration, the normal implementation is expected to be approximately:

```text
ADELE Environment: sphy-4934

Git implementation:
    worktree: sphy-4934
    branch:   sphy-4934
```

From the user's perspective this is simply one execution environment named `sphy-4934`.

ADELE should **not** require users to routinely reason about the distinction between Git worktrees and branches.

The equality between environment name, worktree name, and branch name is a useful default convention, not a core architectural invariant. If the underlying branch changes independently, ADELE should tolerate and report that state rather than pretending the concepts cannot diverge.

Other SCM plugins may implement environments differently.

---

# 2. Core UX philosophy

ADELE should borrow useful conventions from IDEs without cargo-culting the IDE layout.

The important distinction is:

> ADELE is task/session-centric rather than editor-centric.

The primary work artifacts may include:

- conversation;
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

ADELE
    direct agent → review work → inspect/edit manually when useful
```

The UI should therefore optimize for:

- understanding what an agent is doing;
- reviewing changes;
- giving structured feedback;
- navigating relevant code quickly;
- monitoring progress;
- inspecting tool activity;
- moving among tasks and sessions.

It should avoid forcing users to manage UI concepts that agents have made less important.

---

# 3. Active-session window shell

The conceptual shell is:

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

Most of those surfaces are optional.

A newly created Session is intentionally simple:

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

The application should accumulate UI only when the work actually requires it.

---

# 4. Title bar and breadcrumb

The title bar provides:

- ADELE logo/identity;
- hierarchical breadcrumb;
- execution-environment identity when applicable;
- help;
- settings.

Example:

```text
ADELE   adele-core > SPHY-4934 > Investigate resolver failure

                                      env: sphy-4934       ?   ⚙
```

There is no user-profile/avatar UI. ADELE is a local desktop development application, not a collaborative social workspace.

## 4.1 Breadcrumb as navigation

The breadcrumb is functional navigation.

From:

```text
adele-core > Refactor resolver API > Validate error propagation
```

clicking `adele-core` returns to the project-level Task Browser with no Task selected.

Clicking `Refactor resolver API` returns to the same Task Browser with that Task selected and its Sessions visible.

This eliminates the need for a permanent Tasks navigation icon.

## 4.2 Environment identity is not a switcher

The environment indicator is **status/identity**, not a routine dropdown for switching environments.

Normally:

```text
env: sphy-4934
```

Clicking it may inspect environment information.

It should not imply:

> Choose which environment this Session should operate against.

Environment changes normally occur as consequences of explicit higher-level operations:

```text
switch Task
    → Task's environment becomes active

switch Session within same environment
    → environment remains unchanged

switch to isolated Session
    → isolated environment becomes active
```

Before any Task/Session is active, there is no environment indicator.

## 4.3 Isolated environment indication

An intentionally isolated Session should make that exceptional state visible:

```text
◇ Isolated · sphy-4934-debug
```

Isolation is not part of the default workflow.

Possible future creation operations include:

- create isolated Session;
- fork Session into isolated environment;
- agent-created isolated subtask.

Agent-created temporary subtask environments should generally remain implementation/task details rather than becoming top-level title-bar navigation choices.

---

# 5. Left auxiliary surface

ADELE should **not** have a permanent VS Code-style activity rail.

Earlier mockups included permanent icons for:

- Tasks;
- Files;
- SCM;
- Search.

Further analysis showed that none of those justify consuming permanent horizontal space in the default ADE workflow.

Instead, ADELE has an **optional left auxiliary surface**.

Normally it is absent.

When useful:

```text
┌────────────────┬─────────────────────────────────────────────────────┐
│ SEARCH RESULTS │ primary workspace                                   │
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

The surface is generally:

- invoked by a command/action;
- contextual;
- closable;
- one view at a time initially.

## 5.1 Tasks

Tasks do not need a permanent left-nav destination.

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

A user who wants a conventional filesystem browser could eventually install a plugin that provides one.

## 5.3 Search

Project search is an invoked operation, not a permanent destination.

For explicit search:

```text
Ctrl/Cmd+Shift+F
```

ADELE may open Search Results in the left auxiliary surface.

Agent searches normally remain summarized in Chat unless the user explicitly inspects the results.

## 5.4 SCM

ADELE needs deep SCM integration but does not necessarily need to be a general graphical SCM client.

ADELE should support workflow-specific SCM operations such as:

- understanding changes;
- reviewing diffs;
- approving/unapproving changes;
- task-level comparison;
- committing through configured commands.

Generic functionality such as branch browsers, interactive rebases, stash managers, Git graphs, etc. is not a default UX requirement.

Plugins may provide richer graphical SCM clients.

---

# 6. Center workspace

The center workspace is intentionally **one-dimensional and horizontally ordered**, rather than an arbitrary recursive tiling system.

The semantic order is:

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

Key invariants:

- Chat is singleton.
- Diff is singleton.
- Source Group contains zero or more visible editor views.
- Artifact is singleton.
- ordering is fixed;
- only vertical pane boundaries are supported initially;
- top-level panels are not arbitrarily reordered.

The simplicity of a linear layout enables strong keyboard navigation and avoids the complexity of arbitrary horizontal/vertical split trees.

## 6.1 Width and horizontal overflow

Each surface has a practical minimum useful width.

Available space is divided/shrunk until those minima are reached.

If all visible panels cannot fit at their minimum widths, the **center workspace itself becomes horizontally scrollable**.

```text
viewport
┌────────────────────────────────────────────────────────────┐
│ Chat │ Diff │ File A │ File B │ File C │ Artifact ...    │
└────────────────────────────────────────────────────────────┘
          ← horizontally scrollable →
```

The title bar, right panel, and bottom dock remain fixed.

Focusing a pane that is currently offscreen automatically scrolls the center enough to reveal it.

ADELE should not automatically hide panels merely because space becomes tight. The visible set represents explicit user state.

## 6.2 Resizing

Pane boundaries are draggable.

Manual resizing redistributes space while respecting practical minimum widths.

Pane widths are session workspace state.

## 6.3 Focus/maximize

A temporary `Focus Current View` or equivalent command may hide other center surfaces while preserving the underlying arrangement.

Restoring returns to the previous layout.

---

# 7. Chat / Session timeline

Chat is the most important primary surface.

It should not visually pretend to be two people exchanging social messages.

There are no:

- fake avatars;
- `You`;
- `ADELE Agent`;
- unnecessary identity labels beside each message.

Instead, authorship is conveyed through alignment and styling:

```text
                              ┌────────────────────────┐
                              │ User message           │
                              └────────────────────────┘

┌───────────────────────────────────┐
│ Agent response                    │
└───────────────────────────────────┘
```

User messages are generally right-aligned.

Agent messages are generally left-aligned.

Agent blocks should remain wide enough to comfortably display Markdown, code, tables, links, etc.

## 7.1 Chat is logically permanent but hideable

The conversation is the home of the Session.

Chat may be hidden temporarily to reclaim width, but this is semantically **hide/show**, not closing/destroying the conversation.

When restored it preserves transient state including:

- scroll position;
- current draft;
- expanded/collapsed content;
- attachments;
- relevant view state.

---

# 8. Operation groups in Chat

Between visible user/agent messages ADELE displays a compact summary of agent activity.

Two common operation types are:

- tool calls;
- provider-visible reasoning/activity traces.

Individual operations should not fill the transcript with noise.

Instead, contiguous operations between messages are grouped.

Example while active:

```text
⌁ Investigating resolver cycle handling…
```

Example completed:

```text
⌁ Investigated resolver cycle handling · 8 operations
```

The active indicator may subtly pulse.

Clicking the group adds an inspection card to the right panel:

```text
ACTIVITY · Investigated resolver cycle handling

✓ Reasoning    Examining resolver architecture
✓ Read         resolver.dart:40–160
✓ Search       "_resolving"
✓ Reasoning    Checking recursion behavior
✓ Shell        dart test ...
✓ Read         resolver_test.dart
```

Clicking a specific operation adds a separate inspection card for that operation.

## 8.1 Reasoning/provider differences

ADELE should not assume every provider exposes full reasoning.

The underlying concept is a provider-visible **reasoning/activity trace**.

Depending on provider capabilities, ADELE may receive:

- detailed reasoning;
- a reasoning summary;
- no reasoning.

The UI displays only what the provider legitimately exposes.

---

# 9. Progressive tool representation

A tool invocation may have several representations.

This is a core ADELE pattern.

Example shell search:

```text
Chat
    ✓ Search for foo, bar, or baz
```

Click:

```text
Right inspector

SHELL · Search for foo, bar, or baz

Command
grep -RnE 'foo|bar|baz' ...

Output
first lines...
first lines...
...

[Open full output]
```

Then:

```text
Bottom console dock

$ grep foo|bar|baz
```

Other examples:

```text
Shell
    chat → inspector → bottom console

File read
    chat → inspector → source editor

File edit
    chat → perhaps inspector → Diff

Search
    chat → inspector → optional rich result

MCP
    chat → inspector → optional rich result
```

Tools should not all be forced through identical presentations.

---

# 10. Persistent Draft Request

The Chat composer is not merely a transient text box.

It is a persistent, rich, agent-editable **Draft Request document** owned by the Session.

It should be continuously saved so partially written prompts are not lost across:

- switching Sessions;
- switching Tasks;
- closing/reopening ADELE;
- application restarts.

Conceptually:

```text
Session
├── conversation
├── Draft Request
├── progress
├── inspections
└── artifacts
```

## 10.1 Submission

Before submission, editing the Draft Request is ordinary document editing.

When submitted:

```text
Draft Request
    → immutable snapshot becomes user message
    → new empty Draft Request is created
```

Editing an already-submitted historical user message is different and creates a conversation fork.

## 10.2 Rich text

The Draft Request uses a rich-text/structured editor even in compact mode.

It may contain:

- Markdown-like formatting;
- lists;
- code;
- file references;
- images;
- structured references.

The underlying representation should remain LLM/tool-friendly rather than becoming an opaque rich-text blob.

---

# 11. Expanded Draft Request

The Draft Request can expand into a document-oriented editing presentation.

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
│ - ...                                       │
│                                             │
├─────────────────────────────────────────────┤
│ document-specific instruction...            │
└─────────────────────────────────────────────┘
```

The expanded and collapsed forms are two views of the **same document**, not separate buffers.

Chat history may be temporarily hidden within the Chat pane while the Draft Request occupies it.

The normal center focus/maximize command can then give the Chat pane even more room if desired.

---

# 12. Requirements workflow

ADELE may ship a stock `Requirements` agent.

This is not hard-coded product behavior.

It is simply an Agent configuration whose context and tool access instruct it to refine the current Draft Request.

Example stock behavior:

> Improve the prompt based on your understanding of the application. The prompt is Markdown. Perform limited investigation only where necessary to resolve important ambiguity. This is requirements definition, not implementation planning. Use `read_prompt` to inspect the current draft and `write_prompt` to update it. If the resulting request is substantial, use the expand option so the user can review it in document mode.

The agent may have:

```text
default model type: Fast
default reasoning:  Low
submit label:       Refine
tools:
    read_prompt
    write_prompt
    limited read/search capabilities
```

Project-level context such as `AGENTS.md` remains available and often provides enough application understanding without source-code investigation.

A common workflow is:

```text
rough request
    ↓ Requirements
detailed requirements
    ↓ Plan
implementation plan
    ↓ Code
implementation
```

This workflow is configuration-driven rather than hard-coded.

---

# 13. Document-specific AI editing

Both Draft Request and Plan are agent-editable documents.

They may expose a small document-specific instruction input:

```text
Rename "Due Date" to "Deadline" in the UI and data model.
                                                       Apply
```

The resulting LLM calls count toward Session cost/usage, but do not need to appear as normal Chat turns.

Agent document edits should be recorded as one editor transaction so they can be undone easily.

---

# 14. Agent configuration

An Agent configuration conceptually contains:

```text
Agent
    stockContext
    allowedTools
    defaultModelType
    defaultReasoningEffort
    submitLabel = "Send"
    nextAgent = optional
```

Examples:

```text
Ask
    role: answer project questions
    tools: read/search only
    model: Fast
    reasoning: Low
    submitLabel: Ask
    nextAgent: none

Requirements
    role: refine Draft Request
    tools: prompt read/write + limited inspection
    model: Fast
    reasoning: Low
    submitLabel: Refine
    nextAgent: Plan

Plan
    role: produce implementation plan
    tools: broad read/search + plan tools
    model: Contemplative
    reasoning: High
    submitLabel: Plan
    nextAgent: Code

Code
    role: implement work
    tools: normal development capabilities
    model: Contemplative
    reasoning: High
    submitLabel: Send
    nextAgent: none

Debug
    role: develop hypotheses, instrument, validate
    tools: development/debugging capabilities
    model: Contemplative
    reasoning: High
    nextAgent: none
```

## 14.1 Initial Agent

ADELE configuration defines an Initial Agent.

A likely stock default is:

```text
Initial Agent: Requirements
```

Users who do not want that workflow can set:

```text
Initial Agent: Plan
```

or:

```text
Initial Agent: Code
```

## 14.2 Next Agent

`nextAgent` defines a lightweight configurable workflow.

It does **not** automatically run the next Agent.

Instead, after normal successful completion the next Agent becomes selected.

```text
Requirements [Refine]
      ↓
Plan becomes selected

Plan [Plan]
      ↓
Code becomes selected

Code [Send]
      ↓
Code remains selected
```

Stopped/failed/interrupted runs should normally remain on the current Agent.

Agent IDs should be stable identifiers rather than display names so renaming Agents does not break workflow configuration.

---

# 15. Commands and skills

Agents and skills/commands are related because both package reusable context, but they operate at different levels.

## Agent

Defines the persistent role/policy:

- what the agent's job is;
- tool restrictions;
- model defaults;
- reasoning defaults.

Agent context should occur relatively early in the provider payload so it participates effectively in prefix caching.

## Skill

Defines instructions for a particular kind of invocation.

Examples:

- `commit`
- `review-api`
- `security-review`
- `write-tests`

## Slash command

`/` is the composer interaction for discovering/invoking commands or skills.

Example:

```text
/commit
```

could activate the configured commit skill.

The same `/commit` skill may work under both Code and Debug Agents.

Skills/commands must **not** elevate the Agent's allowed capabilities. An Ask Agent without SCM-write access does not gain commit access merely because `/commit` was selected.

Commands may declare required capabilities so incompatible commands can be marked unavailable.

Some slash commands may invoke application actions rather than skills.

---

# 16. Agent/model controls

The Draft Request composer exposes:

- selected Agent;
- provider;
- model type/profile;
- reasoning effort;
- Send/Refine/etc.

Example:

```text
Code ▾        OpenAI · Cheap · High            Send
```

Agent selection is relatively prominent.

Provider/model/reasoning information is visually secondary because defaults should normally be appropriate.

## 16.1 Persistent overrides

If the user changes model type or reasoning away from the Agent default, that override persists until:

- the user changes it again;
- the user explicitly resets to Agent defaults;
- the selected Agent changes.

Example:

```text
Code
default: Contemplative · High

user chooses Cheap

Code        Cheap · High   ↶
```

Subsequent Code turns stay Cheap until changed/reset.

Switching to another Agent initializes that Agent's defaults.

## 16.2 Model types per provider

Model type describes intent, while concrete model mapping is provider-specific.

Example:

```text
Cheap
    OpenAI     → configured inexpensive OpenAI model
    Anthropic  → configured Haiku-class model
    Google     → configured inexpensive Gemini model
```

Selection therefore has independent dimensions:

```text
Provider:   OpenAI
Model type: Cheap
```

which resolves to a concrete configured model.

Changing provider while keeping `Cheap` preserves the user's intent.

## 16.3 Custom model

The user can bypass model-type mapping and select a concrete model directly.

This is useful for trying newly released models without editing global configuration.

The composer then displays the concrete override rather than pretending it belongs to a configured type.

---

# 17. Context usage

The Chat header shows measurable context usage:

```text
Context 37%
```

This represents the effective context expected for the next invocation given the currently selected Agent/model configuration.

Clicking it may show a breakdown such as:

```text
Context

47.2k / 128k

Conversation        ...
Compacted history   ...
Tool/context data   ...
Agent/system         ...

[Compress context]
```

Changing models may change the percentage because context-window capacity differs.

The current unsent Draft Request is included in the estimate.

## 17.1 Context compression

The user can explicitly compress context.

Compression does not erase visible history.

Instead, earlier conversation is replaced in future model context by a summary while the complete transcript remains visible.

A timeline marker indicates the event:

```text
──────────── Context compressed ────────────
Earlier conversation summarized for future turns
```

The marker can expose the generated summary.

---

# 18. Cost and usage

Cost visibility is a core ADELE feature.

Sessions may mix:

- subscription-covered models;
- direct API models;
- local/free models;
- multiple providers.

ADELE therefore needs an invocation-level usage ledger rather than calculating cost from whichever model is currently selected.

Historical invocations retain the actual provider/model/pricing basis used.

## 18.1 Session-level cost

The Chat header may show:

```text
Cost $0.42
```

or:

```text
Cost Included
```

A popover can distinguish:

- direct billed API spend;
- subscription-covered usage;
- API-equivalent cost/value;
- provider/model breakdown.

## 18.2 Turn-level cost

A subtle rule separates conversational turns.

The rule includes a small cost/usage affordance:

```text
──────────────────────────────────────────── $
```

Hover/click may show:

```text
Provider
Model
Input tokens
Output tokens
Cache tokens

Billed cost
Subscription-covered usage
API-equivalent cost
```

This keeps the transcript visually clean while retaining precise accounting.

## 18.3 Subscription usage pools

Some providers expose subscription quota/rate-limit pools.

When relevant to the currently selected provider/model, the composer may show a small usage indicator.

Example:

```text
OpenAI · Cheap · High      ▰▰▰▰▰▱▱
```

Popover:

```text
5-hour pool    ███████░░░   resets in 1h 42m
Weekly pool    █████░░░░░   resets Monday
```

Only display quota information the provider integration can actually know.

If exhausting included quota changes future requests to API billing, ADELE should make that transition visible rather than allowing billing behavior to change silently.

---

# 19. Attachments and references

## 19.1 Images

Images are added by dragging/dropping them into the Draft Request.

No permanent Attach button is required initially.

Dropped images appear as removable attachments before submission.

If the current effective model does not support image input, ADELE should explain that and allow the user to change model/provider rather than silently changing models.

## 19.2 File references

Typing `@` performs file completion:

```text
@foo

app/models/foo.rb
test/models/foo_test.rb
lib/foo_builder.rb
```

After selection:

```text
@app/models/foo.rb
```

This is internally a structured reference containing environment/path identity rather than merely text.

Possible future range forms include:

```text
@foo.rb:40
@foo.rb:40-80
```

Selecting code in the Source editor should eventually allow inserting an equivalent structured reference into the Draft Request.

---

# 20. Running, stopping, and scrolling

While the Agent is running:

- Send becomes Stop;
- the active operation-group summary may pulse/update;
- the user can interrupt execution.

Auto-scroll follows streaming activity only if the user is already near the bottom.

If the user scrolls upward, ADELE must not pull them back down. Instead it shows a `Jump to latest` affordance.

Approval/decision requests requiring user intervention should appear as explicit actionable timeline content rather than disappearing inside an operation group.

---

# 21. Conversation forks

Any historical user message can be edited.

Editing an already-submitted user message implicitly creates a fork from that point.

The original continuation remains preserved.

Where forks exist, lightweight navigation appears:

```text
‹   2 / 3   ›
```

The active fork determines model context.

Sibling branches are not included in current context.

Session cost, however, includes usage incurred across all branches because already-spent usage does not disappear.

Forking normally shares the same execution environment.

A future explicit operation may support forking into an isolated environment, but that is not currently required.

---

# 22. Right status/inspection stack

The right panel is normally visible but can be collapsed to reclaim space.

It is a **session-owned status and inspection stack**.

It is not a generic fixed dashboard.

The special top section is Session Progress.

Below it are explicitly opened inspections.

```text
SESSION PROGRESS               [fixed top]
──────────────────────────────────────────
Newest inspection
──────────────────────────────────────────
Older inspection
──────────────────────────────────────────
Older inspection
```

The whole panel scrolls vertically.

New inspections appear immediately beneath Session Progress.

There is no manual drag/reordering initially.

---

# 23. Session Progress

Once an Agent creates progress/work items, Session Progress appears automatically.

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

States include at least:

```text
✓ complete
◔ in progress
○ not started
```

The in-progress circle is a graphical approximate progress ring.

The Agent may internally maintain a numerical estimate, but **no percentage is displayed** because the estimate is inherently approximate.

Likewise the overall progress bar has no numeric percentage label.

## 23.1 Work-item weights

Internally, the Agent may estimate relative work weights:

```text
Investigate       0.10
Implement         0.65
Tests             0.20
Documentation     0.05
```

These weights can help calculate overall progress.

They are not normally user-visible.

Historical actual durations may eventually help improve remaining-work estimates.

## 23.2 Progress terminology

Because `Task` is already a first-class ADELE object, checklist entries should preferably be called `work items`, `steps`, or similar internally rather than creating another concept called Task.

---

# 24. Right-side inspection cards

Examples include:

- tool-call details;
- grouped operation activity;
- file-read details;
- search details;
- MCP invocation details;
- change-set metadata;
- other plugin-provided structured inspections.

Cards are:

- independently expandable/collapsible;
- individually removable;
- not reordered manually.

Collapsed headers remain informative:

```text
SEARCH · "CircularDependencyException" · 14 hits
READ FILE · resolver_policy.dart:40-120
MCP · github.search_issues · 8 results
```

Closing an inspection only removes its **view**.

It does not delete:

- the tool call;
- historical output;
- artifacts;
- underlying state.

Clicking the originating item again restores/reuses the existing inspection.

Session Progress can similarly be hidden and restored through a command.

Agent activity does **not** automatically flood the panel with cards. Most inspections appear only because the user explicitly requested them.

---

# 25. Bottom console dock

The bottom area is not a traditional IDE category panel.

There are no permanent:

- Terminal;
- Command Output;
- Problems

mode tabs.

Instead it is a **dynamic environment-owned console dock**.

Tabs represent concrete instances:

```text
>_ main
>_ server
$ dart test
$ grep CircularDependency
```

## 25.1 Interactive shells

Interactive shells are explicitly created and writable.

They persist as resources of the current execution environment.

## 25.2 Tool output

Wide/console-oriented tool output can be opened here when the user explicitly inspects it.

Agent execution alone does not create tabs.

Example:

```text
Agent runs 10 commands
    → compact tool activity in Chat
    → zero console tabs automatically

User clicks "dart test"
    → $ dart test tab opens
```

Clicking the same invocation again focuses its existing tab.

Closing the tab removes the visual representation, not the historical invocation.

## 25.3 Environment ownership

The console dock belongs to the execution environment.

If two Sessions share the same environment:

```text
Session A → Session B
Environment unchanged
Console dock unchanged
```

If the user switches to another Task or isolated Session:

```text
Environment A → Environment B
Console dock A → Console dock B
```

Switching away does not automatically kill long-running shells/processes.

Returning to the environment restores its dock/resources.

The tool invocation itself may belong to a Session history, but its currently open console representation is environment workspace state.

---

# 26. Diff reviewer

The Diff surface is a first-class review experience, not merely another source viewer.

AI shifts development toward reviewing code, so this is one of ADELE's defining interactions.

The viewer is:

- singleton;
- unified only initially;
- continuous across changed files/hunks;
- backed directly by SCM state.

Side-by-side diff is deliberately postponed and may never be necessary.

## 26.1 Review scopes

The scope selector uses ADELE terminology:

```text
Changes to approve
Current changes
Task changes
```

### Changes to approve

Default after an Agent edits code.

Represents current changes not yet accepted.

For Git this corresponds approximately to:

```text
unstaged modifications + new/untracked files
```

### Current changes

All uncommitted work:

```text
unapproved current changes
+ approved/staged current changes
+ new files
```

### Task changes

The complete delta attributable to the Task:

```text
committed Task work
+ approved uncommitted work
+ unapproved current work
```

The precise SCM computation is delegated to the SCM plugin.

---

# 27. SCM as source of truth

ADELE should not maintain a parallel internal database of SCM acceptance state.

The SCM **is** the state.

For Git:

```text
working tree vs index
    → Changes to approve

index vs HEAD
    → approved uncommitted state

Task branch/baseline relationship
    → Task changes
```

Operations:

```text
Approve
    → modify Git index

Unapprove
    → modify Git index

Manual edit
    → modify working tree

Agent edit
    → modify working tree

Commit
    → modify HEAD/index
```

The Diff viewer watches for relevant filesystem/SCM state changes and recomputes its projection.

If the user manually runs:

```text
git add resolver.dart
```

the Diff viewer simply refreshes and reflects that state.

This avoids fragile synchronization between ADELE and Git.

The watcher should be cross-platform in abstraction even if implementations use inotify, FSEvents, Windows filesystem APIs, etc.

---

# 28. Approve / Unapprove

The core review grammar is intentionally small.

## Unapproved change

```text
Comment
Approve
```

## Approved, uncommitted change

```text
Comment
Unapprove
```

## Committed Task change

```text
Comment
```

There is **no normal Reject button**.

Approval changes acceptance state.

Comments/manual edits/Agent work change code.

This separation reduces destructive operations and better matches an agent-review workflow.

If the user dislikes a change:

```text
comment: "We don't need this."
    ↓
Submit Review
    ↓
Agent removes/reworks it
```

or the user opens Source and manually edits it.

Explicit discard/reset SCM operations may eventually exist as deliberate commands/plugins but are not part of normal hunk review.

---

# 29. Diff organization

The Diff is a continuous review document:

```text
File A
    hunk
    hunk

File B
    hunk

File C
    hunk
```

File headers may remain sticky.

There is no file-tab UI.

A lightweight `Files` jump menu can provide:

```text
resolver.dart                 2 to review
resolver_policy.dart          approved
resolver_test.dart            3 to review
```

For large reviews a Changed Files left auxiliary view may optionally be opened.

## 29.1 Review actions

At hunk level:

- Approve;
- Unapprove where appropriate;
- Comment;
- Open in Source;
- expand surrounding context.

At file level:

- Approve File;
- Unapprove File where appropriate;
- File Comment.

At change-set level:

- Approve All;
- Unapprove All where appropriate;
- Submit Review.

These controls belong **inside the Diff surface**, not in the right inspector.

---

# 30. Review comments

ADELE follows a code-review model similar to GitHub.

Users may comment on:

- a specific line;
- a line range;
- a hunk;
- a file generally.

Comments are collected as pending review feedback rather than immediately invoking the Agent.

Example:

```text
Don't log here. Return the cycle information in the
error so callers can decide how to log it.
```

The user may accumulate several comments and then submit:

```text
Submit Review (4)
```

The Agent receives the comments as one coherent structured request.

This allows it to reason across multiple requested modifications.

A submitted review appears compactly in Chat rather than dumping every line comment into the transcript.

---

# 31. Diff comment anchors

Review comments must be structurally anchored to change identity/revision information, not merely raw line numbers.

Conceptually they need information such as:

```text
file
revision/change-set identity
hunk identity
old/new side
line/range
comment
```

If the underlying change invalidates an anchor, ADELE may mark the comment outdated rather than silently attaching it to unrelated code.

Pending review comments are ADELE session state even though the underlying code/approval state comes from SCM.

---

# 32. Open in Source

Every relevant diff location should make it easy to open the full source file.

Example:

```text
Chat | Diff | resolver.dart
```

Opening Source:

- focuses an existing editor for that file if one exists;
- otherwise opens it in the active Source slot;
- navigates to the corresponding location.

Manual edits appear naturally back in `Changes to approve` because the filesystem/SCM remains the source of truth.

---

# 33. Commit workflow

The Diff reviewer does not have a built-in `Save Changes` or Commit button.

Committing is preferably a configurable command:

```text
/commit
```

The default `/commit` command can instruct the selected Agent to:

- inspect changes;
- run appropriate validation;
- write commit messages according to configured/project conventions;
- create one or multiple commits as appropriate.

This is intentionally configuration-driven rather than hard-coded ADELE behavior.

A future visible Commit button, if desired, should invoke the same configurable command rather than introduce a second commit implementation path.

After committing:

- changes disappear from `Current changes`;
- they remain visible in `Task changes`.

---

# 34. Source editor group

Source editing is a supporting interaction rather than ADELE's central product identity.

The Source Group contains multiple visible editor views:

```text
[ resolver.dart ][ graph.dart ][ resolver_test.dart ]
```

There are no hidden source tabs.

A source file is either:

- currently visible;
- or not open in the Source Group.

## 34.1 Vertical-only source layout

All source views are side-by-side.

Horizontal splits are deliberately postponed.

The simple linear ordering enables keyboard operations such as:

```text
Focus Source 1
Focus Source 2
Focus Source 3

Move current Source to position 1
Move current Source to position 2
```

Editors may also be reordered by drag/drop within the Source Group.

---

# 35. Opening files

Quick Open is the default file-navigation mechanism.

Normal open:

```text
Enter
    → replace active Source editor
```

Open to side:

```text
Shift+Enter
    → append another Source editor
```

The same semantic distinction should apply to links from:

- Chat;
- Diff;
- search;
- right inspectors;
- references/symbols.

If there is no Source editor yet, normal open creates Source 1.

If focus is currently outside Source, the Source Group remembers its most recently active editor for replacement behavior.

---

# 36. Same file in multiple editors

Normally, opening a file that is already visible focuses the existing view.

However, viewing different parts of the same file simultaneously is useful.

ADELE therefore provides an explicit:

```text
Split Current Editor
```

operation.

This creates two independent editor views over the same underlying document:

```text
resolver.dart @ line 80
resolver.dart @ line 640
```

Each has independent:

- cursor;
- selection;
- scroll position;
- folded regions.

Edits are shared immediately because both represent the same document.

This distinguishes:

```text
Open file
    → navigate to document

Split editor
    → create another view of same document
```

---

# 37. Editor implementation direction

`code_forge` is currently a promising Flutter editor component.

ADELE does not require the world's most sophisticated editor because manual source editing is expected to be secondary to agent-driven implementation/review.

The editor should nevertheless support the core review/inspection use cases reliably.

ADELE should wrap CodeForge behind an internal editor/document abstraction rather than letting its APIs define ADELE's architecture.

This allows replacement or adaptation later.

---

# 38. Editor save/external-change semantics

The Source editor should behave approximately as an autosaving view of the real environment filesystem.

Manual edits should become visible to:

- agents;
- terminals;
- SCM;
- Diff

without requiring users to remember an IDE-style save workflow.

Edits may be written after a short debounce, with Save forcing an immediate flush if such a command remains available.

External modification is expected because Agents and shells can change open files.

If disk changes while there are no conflicting local pending edits, reload while preserving view state as well as possible.

If local and external edits conflict, do not silently overwrite either side.

---

# 39. Document versus editor view

Internally distinguish:

```text
Document
    environment
    path
    current content/revision

Editor View
    cursor
    selection
    scroll
    folds
```

Multiple Source views can therefore share one Document.

This is important for same-file splits.

---

# 40. Editor navigation history

Each Source pane may maintain browser-like navigation history.

Go-to-definition or similar navigation can replace the pane while remembering:

- previous file;
- previous location.

Back/Forward navigates those locations.

This provides useful hidden history without introducing hidden file tabs.

A restrained Source header might resemble:

```text
‹  ›   resolver.dart · lib/core/resolvers             Split   ×
```

---

# 41. Source intelligence

Useful inline features include:

- syntax highlighting;
- line numbers;
- folding;
- local find;
- hover documentation;
- go-to-definition;
- inline diagnostics;
- basic code actions;
- semantic highlighting.

Diagnostics should appear inline rather than requiring a permanent Problems panel.

ADELE should avoid creating a second editor-specific AI system such as independent AI autocomplete unless there is a clear later need. Agent/model/cost configuration should remain coherent across the product.

---

# 42. SCM decorations in Source

Subtle gutter indicators may show modified/unapproved lines.

These are informational.

Clicking a marker may focus the Diff viewer on the corresponding hunk.

Approval remains a Diff interaction rather than being duplicated inside Source.

---

# 43. Source references into Draft Request

Selecting code should support a command such as:

```text
Reference in Draft
```

which inserts a structured reference equivalent to:

```text
@lib/core/resolver.dart:72-91
```

This is more important to ADELE than recreating deep traditional refactoring menus.

---

# 44. Singleton Artifact viewer

The final center region is a singleton Artifact surface.

Potential contents include:

- Plan;
- rich MCP result;
- rendered Markdown;
- report;
- structured search result;
- test report;
- generated artifact.

Opening another Artifact replaces the current visual representation.

The underlying artifact persists and can be reopened.

This intentionally prevents unbounded horizontal growth.

---

# 45. Plan

A Plan is distinct from Session Progress.

## Plan

A substantial implementation artifact containing:

- phases;
- strategy;
- design decisions;
- dependencies;
- technical approach.

It is displayed in the Artifact viewer and is editable by the user/agents.

## Session Progress

Lightweight operational status:

```text
✓ Investigate
◔ Implement
○ Test
```

It lives in the right panel.

The Plan and Draft Request can share the same underlying agent-assisted rich document component.

---

# 46. Project and Task Browser

Project selection uses the operating-system directory picker or recent-project command.

After opening a project, ADELE displays the **Task Browser**.

This browser also serves as the Session selector.

There is no separate dedicated Session-selection page.

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
│               │                                   │                  │
│ Archive    47 │                                   │                  │
└───────────────┴───────────────────────────────────┴──────────────────┘
```

There is no environment indicator because no active Session/environment is necessarily selected.

---

# 47. Task categories and Archive

Task categories are configuration-managed workflow states such as:

- Active;
- In Review;
- Waiting for QA;
- Blocked;
- On Hold.

The left Task Browser sidebar contains:

```text
All
configured categories...
Archive
```

with task counts.

`All` means all **non-archived** Tasks.

Archive is a special state/view separate from workflow category.

This prevents old completed work from filling the everyday `All` list.

A user could still configure a `Done` category before tasks are eventually archived.

Saved Filters and task pinning are deliberately omitted for now.

---

# 48. Task list

Each Task row remains lightweight.

Example:

```text
Refactor resolver API
Improve async resolution and cycle handling

4 sessions · 18m ago                           In Review
```

High-value metadata:

- title;
- brief description;
- Session count;
- last activity;
- category when not already implied by current filter.

When viewing a single category, category labels can be visually omitted because they are redundant.

Search is important because Tasks accumulate over time.

Default sorting by last activity is likely sufficient initially; additional sorting can be added based on real need.

---

# 49. Task activity indicators

Workflow category and live activity are different dimensions.

Example:

```text
Category:
    In Review

Live activity:
    Agent working
    Waiting for user
    Idle
```

Task rows may show small indicators:

```text
◌ agent currently working
! waiting for user input/approval
```

If multiple Sessions create both states:

```text
Refactor resolver API                          ◌  !
```

the Task can show both.

Tooltip/details may say:

```text
2 Sessions working
1 Session waiting for approval
```

This becomes important when multiple Tasks/Sessions execute concurrently.

---

# 50. Task details / Session selection

Selecting a Task does not immediately resume it.

It populates the right-side Task Details pane.

Example:

```text
TASK DETAILS

Refactor resolver API
In Review

Description...

SESSIONS

◌ Validate error propagation
  Working · 18m ago

! Review async resolution path
  Waiting for approval · 32m ago

  Investigate circular dependency
  Idle · yesterday

+ New Session

USAGE
...

ACTIVITY
...
```

Clicking a Session enters/resumes it.

There is no separate ambiguous `Resume Session` button.

---

# 51. Task usage

Task details may aggregate usage across Sessions:

- input tokens;
- output tokens;
- cache tokens/hit ratio;
- actual billed cost;
- API-equivalent cost.

Detailed provider/model breakdown can remain behind hover/popover rather than dominating the pane.

---

# 52. New Session

`+ New Session` is available:

- in Task Details;
- as a shortcut from the active Chat pane.

Use the term **Session**, not `Chat`, consistently.

A Session is the product object; Chat is one view inside it.

Creating a new Session requires no dialog.

Behavior:

```text
create Session
    ↓
attach to Task primary environment
    ↓
open default active-session workspace
    ↓
configured Initial Agent selected
    ↓
focus empty Draft Request
```

The Session begins with a provisional name and is renamed from its initial request when enough information exists.

The new Session has:

- no conversation history;
- no extra center panels open;
- no progress list until one is created;
- the environment-owned console dock appropriate to the Task environment.

---

# 53. New Task

`+ New Task` is prominent in the Task Browser.

Unlike New Session, it requires a small creation dialog because the Task needs an identity used to seed its execution environment.

Minimal initial dialog:

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

Description is optional and does not need to be required initially because the Draft Request will contain the actual work request.

ADELE derives a safe environment identifier from the Task name/title as needed.

Creating a Task:

```text
create Task
    ↓
create primary Execution Environment
    ↓
SCM plugin creates appropriate worktree/branch/etc.
    ↓
create initial Session
    ↓
open active-session UI
    ↓
configured Initial Agent selected
```

Low-level worktree/branch naming is not exposed in the normal dialog.

---

# 54. Workspace/state ownership

The current conceptual ownership model is:

| Surface/state | Owner |
|---|---|
| Project identity/config | Project |
| Task category/title/metadata | Task |
| Primary execution environment | Task |
| Conversation | Session |
| Draft Request | Session |
| Center layout | Session |
| Right inspections | Session |
| Session Progress | Session |
| Conversation forks | Session |
| Active Agent/model override | Session |
| Shell/process resources | Environment |
| Bottom console dock | Environment |
| Filesystem | Environment |
| SCM state | Environment/SCM plugin |
| Diff projection | Derived from SCM state |

This distinction is important during Session switching.

Two Sessions sharing an environment:

```text
Session A → Session B

Center workspace:
    changes

Right panel:
    changes

Bottom console:
    remains
```

Switching Tasks/environments:

```text
Center workspace:
    changes

Right panel:
    changes

Bottom console:
    changes to that environment's dock
```

---

# 55. Workspace restoration

Session workspace state should eventually preserve:

- Chat scroll/view state;
- Draft Request;
- center pane visibility;
- pane widths;
- horizontal center scroll;
- open Source views;
- Source cursor/scroll/folds/history;
- Diff review position;
- currently displayed Artifact;
- right-side inspection cards;
- collapsed/expanded right cards;
- active Agent/model overrides.

Environment workspace state should preserve:

- interactive shells;
- running processes where possible;
- open console-tool representations;
- bottom-dock tab state.

Not every part of this needs to exist in the first self-hosting implementation, but the ownership model should avoid making future persistence unnecessarily difficult.

---

# 56. Deliberately postponed or excluded IDE conventions

The following are **not currently considered standard ADELE UI requirements**:

- permanent VS Code-style activity rail;
- stock filesystem Explorer;
- general graphical SCM client;
- permanent Search destination;
- permanent Problems panel;
- editor document tabs;
- arbitrary two-dimensional editor splitting;
- side-by-side Diff;
- destructive Reject controls in Diff;
- built-in Commit workflow;
- session artifact dashboard pinned permanently to the right;
- multiple simultaneous generic Artifact viewers;
- separate AI autocomplete/model system inside Source editor.

These may later be implemented through:

- commands;
- contextual auxiliary views;
- plugins;
- future evidence from real usage.

Their absence is intentional rather than an oversight.

---

# 57. Plugin/extensibility implications

ADELE should prefer **semantic UI contributions** over plugins claiming fixed physical coordinates.

Possible conceptual contribution types include:

```text
PrimaryView
AuxiliaryView
InspectionView
ConsoleView
Overlay/Command
```

Examples:

```text
filesystem browser plugin
    → AuxiliaryView

graphical Git client plugin
    → Auxiliary/Primary views

database schema browser
    → AuxiliaryView

profiler output
    → Primary or Console view

custom tool details
    → InspectionView
```

Plugins should participate in the shell's established semantics rather than creating arbitrary disconnected panel systems.

---

# 58. General design principles

Several broader principles have emerged from these decisions.

## 58.1 User attention controls workspace arrangement

Agent activity should not gratuitously open, close, or rearrange panels.

Tools normally remain compact in Chat until explicitly inspected.

## 58.2 Views are disposable; underlying objects are not

Closing:

- Diff;
- Plan;
- inspector card;
- console output;
- Source view

removes a visual representation.

It does not delete the underlying change/artifact/tool invocation/file.

## 58.3 Direct navigation beats permanent navigation chrome

Prefer:

- breadcrumb;
- Quick Open;
- command palette;
- links from Agent output;
- context-specific auxiliary views.

Avoid permanent navigation structures merely because IDEs traditionally have them.

## 58.4 SCM is authoritative

For SCM-backed behavior, derive ADELE state from the SCM whenever practical instead of maintaining parallel synchronized state.

## 58.5 Configuration defines workflow

Requirements → Plan → Code should be easy out of the box but should arise from configurable Agents, tools, commands, and `nextAgent` relationships rather than hard-coded workflow logic.

## 58.6 Progressive disclosure

Show compact summaries first.

Allow the user to drill from:

```text
Chat summary
    ↓
Right structured inspection
    ↓
full specialized representation
```

rather than showing maximum detail everywhere.

## 58.7 Optimize for review

ADELE should assume agents increasingly produce implementation while humans increasingly inspect, direct, and review that implementation.

The Diff reviewer, Session progress, tool transparency, and ability to rapidly inspect full source are therefore more central than sophisticated manual code-authoring UX.

---

# 59. Near-term implementation versus direction

This document describes the **desired direction**, not the minimum feature set required before ADELE can self-host.

Near-term implementation should prioritize whatever subset enables ADELE to become useful enough to improve itself.

A plausible minimal progression may only need portions of:

- Project/Task/Session lifecycle;
- Chat with persistent Draft Request;
- Agent/model selection;
- basic Agent tool activity;
- basic execution environment;
- Source editor;
- Diff review;
- one shell;
- enough persistence to resume work.

More advanced behaviors such as:

- sophisticated cost accounting;
- subscription quota meters;
- rich conversation forks;
- multi-shell restoration;
- precise progress weighting;
- document-specific AI editing;
- plugin-provided view ecosystems;
- extensive task analytics

can arrive incrementally.

Implementations should therefore avoid unnecessary complexity merely to satisfy this document in one phase, while also avoiding architectural shortcuts that fundamentally contradict the model described here.

---

# 60. Expected evolution

This UX should be treated as a hypothesis that will be tested by using ADELE for real development.

Some ideas will work better than expected.

Some will prove unnecessary.

Other workflows will emerge only after ADELE becomes capable of doing substantial work on itself.

Future changes should therefore preserve the reasoning behind these decisions while remaining willing to modify the details.

The primary goal is not to create a perfect static IDE design.

It is to establish a coherent **agent-development workbench** that can evolve based on real usage while retaining a clear conceptual model:

```text
Project
    ↓
Task + execution environment
    ↓
one or more independent Sessions
    ↓
direct Agent through Draft Request
    ↓
observe progress and tool activity
    ↓
review changes
    ↓
inspect/edit source where useful
    ↓
iterate
```

That is the current development-workflow direction for ADELE.