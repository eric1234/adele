# Agent Tooling Direction

## Status and purpose

**Guiding product/architecture direction; not a frozen tool catalog or public API.**

This document captures the current direction for ADELE's stock development agent tools and the execution/presentation model around those tools.

It is intentionally directional rather than contractual. The exact tool set, names, schemas, persistence model, permission system, scheduling model, and implementation layering may change as ADELE becomes capable of self-hosting and real usage exposes better designs. The near-term implementation may provide only a small subset of this document.

The maintained Phase IV vertical currently proves bounded read-only source search/read tools projected from DevelopmentSource plus provider-neutral model/tool/model execution. It does **not** yet implement the stock Command Tool, mutable Environment filesystem tools, TODO/Progress, Plan, Console/Terminal, background scheduling, or the broader presentation model described here.

The purpose is to preserve the reasoning behind the current direction so later implementation work does not independently rediscover a conventional coding-agent tool surface or accidentally conflict with ADELE's product model.

This document should be read alongside:

- [`../mockups/README.md`](../mockups/README.md), which describes the stock development-workflow UX direction;
- [`agent-kernel-semantic-model.md`](agent-kernel-semantic-model.md), which describes lower-level Run, ToolInvocation, progress, outcome, interruption, runtime-resource, and execution-observation semantics;
- [`plugin-extension-model.md`](plugin-extension-model.md), which defines the broader recursive extension model;
- [`stock-plugin-direction.md`](stock-plugin-direction.md), which places expected tools into the speculative default plugin topology.

The mockups currently place compact activity in Chat, structured inspection on the right, and stream/terminal presentation at the bottom. Those are stock layout choices; plugin-facing extension APIs should use semantic roles rather than encode those physical coordinates.

This document sits between the kernel and product UX levels. It focuses on which model-callable operations are worth making first-class, why they are preferable to shell commands for common operations, how command execution should project into ADELE's live UX, and how concurrent/asynchronous work should interact with model inference.

---

# 1. Core principle: command execution is the universal escape hatch

The most fundamental coding-agent tool is command execution.

Given access to a suitable Environment process-execution facility, an agent can bootstrap nearly every ordinary development operation:

```text
read files          cat / sed / head / tail
find files          find / fd
search text         grep / rg
write files         shell redirection / scripts
transform content   python / dart / other scripting tools
inspect SCM         git / fossil / other SCM CLI
build/test           dart / flutter / cargo / npm / etc.
network access       curl / wget / provider CLIs
```

This makes command execution a natural Layer 0 capability. ADELE can remain useful before a large specialized tool catalog exists, and unusual operations do not require a dedicated tool merely to be possible.

The architectural principle is therefore:

> A first-class tool does not need to provide a capability that command execution cannot provide. It should exist when it makes an important operation meaningfully safer, clearer, more deterministic, more inspectable, more portable, or easier to authorize.

The shell remains the long-tail escape hatch even as the structured tool surface grows.

---

# 2. Why promote operations into dedicated tools

Dedicated tools are justified primarily by the quality of the interface they provide to the model and host.

## 2.1 More precise operations

Shell commands are textual programs. Quoting, escaping, platform syntax, pipelines, glob expansion, and output conventions introduce incidental complexity.

A structured call such as:

```text
search(
    query: "Foo(",
    path: "packages/foo/lib",
    mode: literal,
    include: ["*.dart"]
)
```

has clearer semantics than asking the model to construct the equivalent `rg`, `grep`, PowerShell, or shell expression correctly.

The tool can also return a stable structured result rather than requiring the model to infer structure from terminal text.

## 2.2 Better permissions and access control

A dedicated operation can be authorized according to its semantic effects and exact targets.

For example, ADELE can distinguish:

```text
read_file("lib/foo.dart")
write_file("lib/foo.dart", ...)
search(...)
```

with much greater confidence than it can infer the full effects of an arbitrary command line.

Command filtering can still be useful, but arbitrary shell execution is inherently open-ended and should be treated as such. A policy system should not pretend that parsing a shell command gives the same certainty as authorizing a narrow structured operation.

## 2.3 Better inspectability

A shell invocation fundamentally starts with command input and produces process output. The host may summarize it, but the semantic meaning of the operation is indirect.

A structured tool makes both intent and result explicit. ADELE can present a search as a search, a source read as a source read, and an edit as a source mutation rather than forcing every operation through a terminal-shaped presentation.

This supports progressive representation:

```text
Chat summary
    ↓ inspect
structured InspectionPresentation
    ↓ when useful
specialized full presentation
```

## 2.4 Better portability and host control

Dedicated tools can abstract over platform differences and execution location. An Environment may be local, Git-worktree-backed, containerized, remote, or otherwise not reducible to the host process's local filesystem.

A semantic `read_file` or `search` operation can remain stable while its Environment-backed executor changes.

---

# 3. Avoid a tool for every operation

The advantages above do not imply that every possible developer action should become model-callable API surface.

Every first-class tool has costs:

- implementation and maintenance;
- schemas and compatibility concerns;
- policy and permission rules;
- presentation support;
- tests and documentation;
- model context/tool-definition budget;
- additional choices the model must learn to use correctly.

ADELE should prefer a relatively small set of orthogonal, high-frequency primitives and leave uncommon operations to command execution or plugin-provided tools.

A useful promotion rule is:

> Promote an operation out of command execution when agents perform it frequently enough, or when a dedicated interface gives ADELE substantial semantic, security, observability, portability, or UX value.

Tool granularity should also remain coarse enough to avoid unnecessary variants. For example, a bounded `read_file(path, range?)` is preferable to separate tools for reading a whole file, head, tail, line range, and multiple other minor variations unless later evidence justifies them.

---

# 4. Directional stock tool layers

These layers describe conceptual priority/dependency, not implementation milestones or core ownership. The expected long-term home of these tools is stock plugins, not `agent_kernel`.

## 4.1 Layer 0 — universal execution

```text
Execution
    run_command
```

`run_command` is the minimum useful coding-agent tool because it enables the agent to bootstrap nearly all other operations.

The exact model-visible schema remains to be designed. The underlying Environment process facility should preserve the distinction between direct process execution and shell interpretation even if ADELE ultimately exposes one convenient tool abstraction.

For example, direct argument-vector execution avoids quoting ambiguity:

```text
executable: "git"
arguments: ["diff", "--", "some file.dart"]
```

while some operations genuinely require shell syntax such as pipelines, redirection, expansion, or compound commands.

ADELE should not prematurely freeze whether those become separate model-visible forms.

## 4.2 Layer 1 — high-value structured coding primitives

A strong initial structured surface is:

```text
Source / filesystem
    list_directory
    glob
    read_file
    search

Mutation
    apply_patch
    write_file
    delete_file

Execution
    run_command
```

The names are descriptive rather than normative.

These operations are frequent enough in coding work and benefit enough from precise contracts, bounded results, clear policy semantics, and specialized presentation to justify first-class treatment.

`apply_patch` is expected to be the primary mutation primitive for existing source because it naturally describes an intentional localized change. `write_file` remains useful for new files, generated content, or complete replacement. Exact stale-read/precondition semantics should be designed separately.

Long-tail filesystem actions such as move, copy, directory creation, permissions, or unusual metadata manipulation do not automatically need dedicated model tools. They can initially remain command operations unless experience shows clear value in promotion.

The structured filesystem tools should consume the active Run/Session Environment filesystem API rather than assume host-local paths or one concrete Environment provider.

## 4.3 Later specialized layers

Potential future areas include:

```text
semantic/LSP intelligence
SCM-aware operations
web/documentation access
browser automation
rich diagnostics/test results
external/MCP tools
child Sessions and orchestration
specialized artifact operations
```

Those areas need separate design before becoming part of the built-in surface. This document intentionally does not prescribe a complete next-tier catalog.

---

# 5. `run_command` is model-synchronous but host-live

For an ordinary foreground command, the model-facing experience of `run_command` may be a normal tool call that produces its terminal result only after the command settles.

The underlying ADELE execution must nevertheless be live from the moment execution starts.

Conceptually:

```text
model proposes run_command
        ↓
ToolInvocation resolves/authorizes
        ↓
CommandInvocation starts immediately
        ↓
progress/output events ...
        ↓
terminal process status
        ↓
model-facing bounded tool result
```

The UI must not wait for the model-facing tool result before exposing the running command.

If an agent launches a long `curl`, test run, build, or other command, the user should immediately be able to see that work in the Session activity and inspect it while it is still running.

This aligns with the kernel semantic model's existing rule that one started tool execution can emit zero or more progress observations before exactly one terminal outcome.

Background/detached command execution is a distinct mode discussed later; it should not require holding one model tool call open until the process eventually exits.

---

# 6. Command invocation as a live inspectable object

A command execution should have host identity and live state independent of the compact result eventually returned to the model.

The exact type/schema is deferred, but the conceptual information resembles:

```text
CommandInvocation
    identity
    originating ToolInvocation / Run / Session
    Environment

    executable/command representation
    arguments / shell text
    working directory
    relevant environment overrides

    status
        starting
        running
        succeeded
        failed/nonzero
        cancelled
        timed out
        infrastructure failure

    start/completion timing
    exit status when available
    output stream
```

This should not be confused with a new generic kernel-wide execution-attempt identity. `agent-kernel-semantic-model.md` intentionally keeps one ToolInvocation/one execution phase as the current assumption. A command executor may still have a domain-specific invocation/resource identity useful for observation and presentation.

A nonzero process exit code is normally command-domain data, not necessarily failure of ADELE's execution infrastructure.

---

# 7. One execution, multiple projections

The same command invocation should project differently depending on the consumer.

```text
                         CommandInvocation
                                │
             ┌──────────────────┼──────────────────┐
             │                  │                  │
             ▼                  ▼                  ▼
          Chat              Inspection          Model result
       short summary       live details       bounded content
                                │
                                ▼
                         Show full output
                                │
                                ▼
                         Console/Stream view
```

The projections are views of one operation, not separate executions or duplicated semantic objects.

## 7.1 Chat projection

Chat should show a compact semantic activity summary rather than terminal noise.

While active, a command may appear inside the current operation group as something conceptually like:

```text
Running dependency download…
```

or as an operation within a grouped activity summary.

When the underlying state changes, the visible summary should update without requiring a new message.

## 7.2 Inspection projection

Inspecting the command should show live structured detail with information such as:

```text
SHELL · Downloading dependency

Status
Running · 12s

Command
curl -L ...

Working directory
/path/to/environment

Output
<recent rendered output>

[Show full output]
```

While the process runs, status and output update in place. After settlement, exit status and final timing become available.

The inspection presentation should normally display only a bounded recent portion of output. For simple commands that portion may contain everything.

## 7.3 Full console projection

When output is larger or the user wants the complete stream, `Show full output` should ask the active Console/Stream provider to display the retained/live command output.

The stock mockups currently place that presentation in a bottom dock because a wide area suits streaming and terminal-oriented data. That physical placement is not the semantic API.

Showing full output must not re-run the command. It opens a richer presentation of the same retained/live invocation output.

## 7.4 Model projection

The model should receive a bounded, tool-appropriate result rather than automatically consuming every byte retained for the user.

A command may emit tens of megabytes while ADELE:

- retains the full output according to policy;
- shows only a recent terminal tail in the inspection view;
- exposes the full stream through Console/Stream presentation;
- returns only bounded/relevant content plus truncation metadata to the model.

This is an important architectural separation:

> Retained operation data, model-facing tool result, and UI presentation are different projections with different budgets and purposes.

---

# 8. Output is fundamentally streaming

Command output should be modeled as streaming progress rather than accumulated only into one final `stdout`/`stderr` string.

Conceptually, output observations may contain information such as:

```text
invocation identity
sequence/order
stdout vs stderr when available
bytes/text chunk
timing if useful
```

The exact persisted representation remains open.

Streaming enables:

- immediate UI updates;
- cancellation and status observation;
- incremental persistence;
- bounded in-memory buffering;
- different retention policies;
- replay or full-output inspection;
- model truncation independent of user-visible retention.

The implementation should not require that all historical output remain permanently in memory merely because the UI can inspect it.

---

# 9. Terminal rendering and ANSI/control sequences

Console-oriented output should be rendered using a terminal-emulation presentation rather than by manually converting ANSI codes into ordinary styled text.

The current UX direction expects a Dart/Flutter xterm-family widget or equivalent terminal emulator to be suitable for both:

- read-only rendering of agent command output;
- interactive user shell/process consoles.

This is a presentation choice, not a claim that command-tool execution and interactive shells are the same resource.

Terminal output is stateful. Carriage returns, cursor movement, color state, line clearing, and other control sequences mean that the visible terminal tail is not necessarily equivalent to the last N newline-delimited strings from the raw stream.

ADELE should therefore avoid designing the inspection view around naive text-tail assumptions. The eventual implementation may keep bounded live terminal state, replay retained output, maintain larger terminal buffers, or use another strategy. That optimization remains open.

---

# 10. Interactive shells are separate from agent tool calls

The stock Console/Terminal plugin may show both agent command output and user-created interactive shells because the same wide stream-oriented surface suits both.

Their ownership and semantics are different.

## 10.1 Agent command invocation

An agent command is part of a Run/Session's tool activity and executes against an Environment.

Conceptually:

```text
Session A
    ToolInvocation
        CommandInvocation
            Environment: foo
```

Its output may be inspected in Chat, structured Inspection, or Console/Stream presentation.

## 10.2 Interactive user shell

An interactive shell is explicitly launched by the user as a runtime resource of the current Environment.

Conceptually:

```text
Environment foo
    interactive shell: main
    interactive shell: server
```

It is not inherently owned by one Session and does not need to be a model-callable tool merely because the user can interact with it.

When several Sessions share an Environment, they should see the Environment-owned console resources appropriate to that Environment. Switching to a Task with another Environment naturally exposes that other Environment's consoles.

The common presentation should therefore not drive the underlying semantic model.

---

# 11. PTY versus ordinary process pipes

ADELE should support both ordinary subprocess execution and PTY-backed execution.

This decision is not merely about richer rendering. A PTY changes the child's behavior because the program believes it is connected to a terminal.

Potential PTY benefits include:

- richer color/progress output;
- terminal-aware formatting;
- line-buffered or more immediately flushed output for some programs;
- compatibility with commands that expect terminal semantics.

Potential costs include:

- commands becoming interactive or prompting unexpectedly;
- pagers or terminal-only behavior being enabled;
- stdout/stderr commonly becoming one combined terminal stream;
- noisier machine/model transcripts due to cursor movement and progress repainting;
- behavior differing from normal automation/CI invocation.

Ordinary pipes can provide cleaner automation semantics and separate stdout/stderr while still allowing ADELE to render whatever ANSI/control sequences the program emits through a terminal emulator.

The current direction is therefore:

> Preserve both execution modes and defer the default until ADELE can test real coding workloads.

PTY-by-default is worth experimentation because ADELE places unusual value on pleasant live human inspection of agent activity, but it should not be baked into the architecture as if PTY were only a display enhancement.

---

# 12. Tool concurrency and asynchronous work

Agent work should not be forced into a strictly serial pattern. ADELE should allow both concurrent foreground tool execution and longer-lived background work, while keeping scheduling semantics separate from individual tool definitions.

These are related but distinct capabilities.

## 12.1 Parallel foreground tool invocations

One model invocation may produce several independent tool proposals. ADELE should be able to execute compatible proposals concurrently and perform the next model inference after the foreground set has settled.

Conceptually:

```text
Model invocation
        ↓
        ├── read_file(A) ─────┐
        ├── read_file(B) ──┐  │
        ├── search(C) ────────┤
        └── run_command(D) ───┤
                              ↓
                         foreground join
                              ↓
                     next model invocation
```

Parallelism should not require special batch variants such as `run_command_batch`, `read_files_batch`, or `apply_patch_batch`. Each operation remains an ordinary ToolInvocation with its own identity, policy decision, progress, result, presentation, and provider-call correlation.

The Run/execution scheduler decides whether proposed operations may actually execute concurrently. Reads and other independent operations are natural candidates. Mutations of the same target, commands with uncertain shared effects, provider restrictions, or executor limitations may require serialization.

The guiding principle is:

> Tool definitions describe operations; concurrency belongs to Run/execution scheduling.

Concurrency should therefore be permitted without assuming that every combination of ToolInvocations is safe to execute simultaneously.

## 12.2 Background/detached work

Some work is useful to start without blocking every subsequent model turn. Examples may include:

- long-running test suites or builds;
- downloads;
- external jobs;
- child Runs/Sessions;
- other future runtime resources.

For this kind of work, ADELE should allow an operation to start longer-lived asynchronous work and return control to the model while that work continues.

Conceptually:

```text
Parent Run
    ↓
start asynchronous work #42
    ↓
model continues useful work ─────────────┐
    ↓                                    │
other tool/model turns                   │
                                         │
                           work #42 completes
                                         │
                                         ▼
                              completion observation
```

A detached command should not be represented as one unresolved provider tool call that is secretly still running while ADELE pretends the call completed. The immediate tool operation may instead succeed by starting an independently observable command/runtime resource whose later progress and terminal state have their own identity and provenance.

Exact tool schemas and the boundary between command-invocation identity and a longer-lived runtime resource remain deferred.

## 12.3 Background work should not require polling

ADELE should specifically avoid designs that encourage repeated model calls such as:

```text
get_status(#42)
get_status(#42)
get_status(#42)
```

Repeated polling wastes inference tokens while teaching the model to busy-wait on state that ADELE already knows.

Instead, ADELE should retain typed asynchronous observations and make relevant unseen changes available to later context assembly. For example:

```text
Since the previous model turn:

✓ Background command completed
  dart test integration_test/
  exit code: 1
  <bounded relevant output>

→ Child investigation still running
  elapsed: 1m 42s
```

The exact context representation remains open. The important rule is:

> If ADELE already knows relevant changing execution state, the model should normally learn about that state through subsequent context rather than needing to poll for it.

A separate operation may still be useful when the model deliberately needs more detail from a large retained result. Fetching additional output is different from repeatedly asking whether work has finished.

## 12.4 Context delivery and continuation are separate decisions

An asynchronous observation being relevant to future inference does not automatically mean that its arrival should start an inference.

For every background completion/change there are conceptually two questions:

```text
1. Should this information become eligible for future model context?
2. Should this event make an otherwise waiting/idle Run runnable now?
```

For background work started by the agent, completion/state changes will normally be eligible for subsequent context.

Whether they should trigger continuation can be selected by the launching agent/workflow or determined by workflow policy. The exact API is deferred, but conceptually an asynchronous operation may be passive or may request continuation on a relevant terminal event.

For example:

```text
background command
    passive
        completion is recorded
        next natural inference sees it
        no inference is created merely because it finished

background command
    resume on completion
        completion is recorded
        next natural inference sees it
        if the parent Run is otherwise waiting, completion makes it runnable
```

This same mechanism can apply to child Runs/Sessions and future external jobs.

## 12.5 Asynchronous events never interrupt an active inference

An asynchronous completion must not interrupt a model invocation already in progress.

Conceptually:

```text
parent inference running
        │
        ├──────── background work completes
        │              ↓
        │       observation recorded/queued
        │
        ▼
parent inference settles
        ↓
next natural inference receives observation
```

Likewise, if foreground tool work is currently progressing, unrelated asynchronous completion can be retained for the next appropriate inference boundary.

This should be an execution invariant rather than left to individual background-work implementations.

## 12.6 Waiting should be event-driven and inference-free

A parent Run may eventually reach a point where no useful work remains until one or more asynchronous dependencies settle.

In that case the Run should be able to enter a genuine waiting state rather than spending inference tokens polling:

```text
Run running
    ↓
waiting for asynchronous dependency
    ↓
(no model inference)
    ↓
dependency event occurs
    ↓
Run becomes runnable
    ↓
next inference receives completion information
```

A completed Run should not normally be resurrected merely because an unrelated background resource later changes state. If the agent/workflow expects a completion to continue the Run, the Run should remain logically alive/waiting until the relevant dependency is resolved or cancelled.

The exact representation of dependencies, any/all barriers, timeouts, cancellation, and scheduling is deferred.

## 12.7 Typed asynchronous observations are broader than command execution

The delivery/scheduling mechanism should not erase domain semantics by turning every event into an untyped "context note."

Possible producers include:

```text
CommandCompleted
ChildRunCompleted
ChildSessionCompleted
ExternalJobCompleted
UserInputSupplied
InterSessionMessage          // optional future feature
```

Each observation should retain its real type, provenance, target scope, and payload. What can be generalized is the machinery that records unseen asynchronous information, makes it available to context assembly, and optionally satisfies a continuation dependency.

This is useful even if ADELE never implements explicit inter-agent messaging. A future Session-search capability may often be preferable to waking another model just to answer information that already exists in strategy-owned Session state/history.

Inter-session messaging therefore remains an optional specialized feature rather than a foundational requirement. The more fundamental direction is typed asynchronous observation plus event-driven continuation.

---

# 13. Session progress/work items are not implementation plans

The UX direction distinguishes durable/reviewable work artifacts from live Session progress.

## 13.1 Implementation plan

A plan is substantive content. In workflows such as:

```text
rough request
    ↓ Requirements
refined requirements
    ↓ Plan
implementation plan
    ↓ Code
implementation
```

an implementation plan is best thought of as a document/artifact or other rich Session content.

Markdown may be an entirely appropriate representation. ADELE does not currently need to force planning into a generic `update_plan` agent tool merely because other harnesses expose one.

Future Plan-agent tools should be designed around ADELE's artifact/Draft Request workflow rather than imported from conventional agent-harness assumptions.

## 13.2 Session work items

Session Progress is operational state maintained while an agent works. It is concise, structured, and mutable.

The UX direction currently shows work items such as:

```text
complete       Reproduce cycle failure
in progress    Implement resolver fix
not started    Add regression tests
not started    Validate test suite
```

Possible internal information may later include progress estimates and relative weights, while the user-facing UI deliberately avoids presenting false precision as a numeric completion percentage.

These work items belong to the Session. They are not the same as ADELE Tasks, which are durable user-level units of development work.

The eventual model-facing mutation API might resemble `set_work_items`, `update_work_item`, or another structured operation, but exact tool shape is deferred.

The expected stock topology places this behavior in a replaceable TODO/Progress plugin. Task-level TODOs are not part of the current expected stock design.

The important semantic distinction is:

```text
Task
    durable user/project work object

Implementation Plan
    substantive reviewable content/artifact

Session work items
    structured live execution/progress state
```

---

# 14. Asking the user is a Run interruption, not merely another I/O function

ADELE needs a way for an agent to request information or a decision from the user, but the final shape deserves dedicated design.

The kernel semantic model already reserves user input/elicitation as a `RunInterruption`: execution cannot progress until external input is supplied.

That is a better semantic foundation than treating user interaction as an ordinary environmental RPC such as a blocking `ask_user()` function.

Potential interaction forms include:

- free-form information;
- structured choice;
- confirmation;
- permission/approval;
- external-action completion.

The provider/model-facing interface may still look tool-like, but the ADELE domain should understand that the Run has entered a waiting state and that the Session UI now contains a resolvable input request.

Exact schemas, lifecycle, multiple simultaneous requests, cancellation, and relationship to ordinary strategy-owned user input/messages remain deferred.

---

# 15. Tool results should be specialized, not terminal-shaped by default

The existence of `run_command` should not cause every stock tool to inherit shell presentation semantics.

Examples from the UX direction include:

```text
Shell
    Chat → Inspection → Console/Stream

File read
    Chat → Inspection → source editor/display

File edit
    Chat → Inspection when useful → Diff

Search
    Chat → Inspection → optional navigation/search results

MCP/external tool
    Chat → Inspection → optional plugin-provided presentation
```

This is a core reason to prefer semantic tools for common operations: ADELE can give each operation an appropriate progressive representation while retaining a generic fallback for unknown tools.

The same principle applies to result contracts. A rich host result may contain structured data, resource references, artifacts, truncation metadata, or presentation hints while exposing a compact model-facing projection.

---

# 16. Tool surface and execution substrate should remain separate

Model-callable tools are one projection over deeper ADELE capabilities and services.

A semantic operation such as `read_file` may be implemented over the current Environment's filesystem/source Service. `run_command` may project the Environment process-execution Service. MCP functions may be dynamically contributed without becoming first-class ADELE capabilities.

This follows the existing distinction in `agent-kernel-semantic-model.md`:

```text
ADELE capability/service
        ↓
model-tool projection
        ↓
ToolInvocation
        ↓
executor
```

The tool catalog should therefore not become the primary internal API of the application.

Similarly, interactive shells, command invocation resources, terminal presentations, output retention, policy decisions, Session progress, asynchronous observations, and scheduling should not be collapsed into model-tool definitions simply because tools interact with them.

---

# 17. Permission implications

The structured tool surface should improve authorization without pretending to solve command-execution security.

ADELE can make strong statements about narrow operations such as reading a known Environment-relative source path or applying a validated patch within a bounded Environment root.

An arbitrary command has inherently broader and less certain effects:

```text
filesystem mutation
process spawning
network access
credential use
external service mutation
indirect execution through scripts/build systems
```

The Command Tool's effect description should therefore be conservative. Parsing or classifying the command may help UX and policy, but it cannot generally prove the command's complete effects.

This is compatible with the kernel semantic model's distinction between static effect metadata, invocation-specific effect description, policy/approval, and actual Environment isolation.

Parallel execution also means policy/approval is evaluated per ToolInvocation rather than once for an opaque batch. Scheduling permission is not authorization to perform effects that would otherwise be denied.

Strong sandboxing remains a separate concern from model-tool authorization.

---

# 18. Near-term guidance

The immediate self-hosting path does not need to implement the complete direction described here.

A plausible progression is:

```text
1. run_command with live execution observations

2. core/stock structured Environment-backed source reads/search

3. structured source mutation

4. support multiple foreground ToolInvocations with safe concurrency

5. richer retained command-output inspection/projection

6. background work/resources with typed completion observations

7. event-driven continuation without model polling

8. structured Session work items

9. user-input interruption

10. specialized semantic integrations as real workflows justify them
```

The actual development sequence may differ according to the current Phase roadmap and implementation constraints.

In particular, ADELE should resist implementing speculative tools simply because other agent harnesses expose them. The universal command escape hatch allows the built-in catalog to grow from demonstrated needs.

The current stock-plugin direction treats Filesystem Tools, Search, Command Tool, TODO/Progress, and Plan as replaceable plugin responsibilities rather than mandatory hard-coded kernel features.

---

# 19. Summary principles

The current direction can be summarized as:

1. **Command execution is foundational.** It is the universal escape hatch that makes the agent useful before a large tool catalog exists.
2. **Structured tools exist for quality, not mere capability.** Promote common operations when precision, policy, inspectability, portability, or UX materially improves.
3. **Keep the built-in/stock surface small and orthogonal.** Avoid a dedicated tool for every possible operation.
4. **Tools operate through the current Environment.** Filesystem/source and process tools should not depend on Git worktrees, Docker, VMs, or host-local paths directly.
5. **Execution is live even when the model-facing foreground call is synchronous.** Users must be able to observe and inspect running work immediately.
6. **One operation can have several projections.** Chat summary, Inspection detail, Console/Stream output, and model result have different purposes and budgets.
7. **Retain streaming semantics.** Output/progress should not exist only as one final accumulated string.
8. **Terminal rendering is presentation, not resource identity.** Agent output and user interactive shells may share a Console surface without becoming the same concept.
9. **Support PTY and pipe execution.** The choice changes program behavior and should remain an execution semantic rather than a rendering assumption.
10. **Parallelism belongs to execution scheduling, not batch tools.** Multiple independent ToolInvocations may run concurrently and join before the next foreground inference.
11. **Support asynchronous/background work.** Long-running commands, child Runs/Sessions, and future jobs may continue while the parent performs other useful work.
12. **Do not make models poll state ADELE already knows.** Relevant asynchronous changes should be supplied as typed observations in later context.
13. **Continuation is event-driven and explicit.** Background work may be passive or may make a waiting Run runnable when relevant events occur.
14. **Never interrupt active inference with asynchronous events.** Queue observations for the next inference boundary instead.
15. **Preserve provenance and semantics of asynchronous information.** Generalize delivery/scheduling machinery, not every event into an untyped note.
16. **Plans and Session progress are distinct.** Plans are substantive artifacts/content; work items are structured mutable Session state; neither is the same as an ADELE Task.
17. **User elicitation is an interruption.** The Run waits for external input; the product should model that state explicitly.
18. **Tools project deeper services.** The model-tool catalog should not become ADELE's internal application architecture.
19. **Presentation APIs should be semantic.** The current right/bottom placement in mockups should not become hard-coded extension-point identity.
