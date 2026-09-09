# ADELE Desktop

`adele_desktop` is ADELE's single Flutter desktop application and composition
root. It is an internal application, not a plugin-facing package.

## Normal Application

The app currently owns its minimal shell, theme, and private widgets. It
displays only the ADELE name and static empty-state messages. The current
`No workspace is open` text is legacy/provisional UI copy; it does not define a
first-class Workspace product concept.

ADR 0031 accepts Project, Task, Session, Run, and Environment as the shared
product-domain identities. The application now contains the in-memory
Project/Task establishment coordinator, a provisional authoritative
Session-to-Task/Environment relation, exact-generation Environment runtime
materialization, and a generic Session-scoped model-tool host context that
projects coherent read, mutation, and process facets over one Environment
authority. Independent stock Filesystem Tools, Search Tools, and Command Tools
plugins use that context to provide Environment-authorized `read_file`,
`apply_patch`, `create_file`, `delete_file`, `search`, and `run_command`. Search
requests only the read facet; Command Tools requests only the process facet.
Lifecycle UI and normal stock-plugin composition are not implemented yet.

The normal application does not display the `workspace_demo` reference plugin.
The maintained `lib/development_smoke.dart` entrypoint exercises the plugin
runtime only through the explicit root smoke command.

## Dependencies

Allowed dependencies are Flutter, ADELE public packages, and internal host
implementations required at the composition root.

The app must not be a dependency of plugins or reusable core packages. Plugin
implementations, Agent/orchestration logic, public plugin APIs, and reusable
core host logic do not belong here.

The long-term extension direction expects the host to own broad workbench
geometry, Command/Command Palette/keybinding infrastructure, and composition of
semantic plugin surfaces. Concrete plugin-facing UI/Command APIs remain
unimplemented.

## Developer Self-Hosting Runner

`app/bin/adele_self_host.dart` is experimental developer infrastructure for
repeatable ADELE-authored source-development experiments. It is not ADELE's
final CLI or product orchestration interface.

The temporary runner currently requires Linux x64 and an executable
`/usr/bin/setsid` or `/bin/setsid`. This mirrors the current Git Environment
foreground-process limitation because the maintained six-tool profile always
includes `run_command`.

The default `chatgpt` profile requires
`ADELE_OPENAI_CHATGPT_CREDENTIAL_FILE`, honors the maintained optional ChatGPT
configuration variables, uses `ADELE_OPENAI_CHATGPT_TEST_MODEL` when set, and
otherwise selects the classic Responses fallback `gpt-5.5`. The optional
`--profile api-key` path requires `OPENAI_API_KEY` and
`ADELE_OPENAI_TEST_MODEL` and retains the existing public Responses endpoint
configuration.

From a clean ADELE checkout, run:

```console
dart run app/bin/adele_self_host.dart \
  --prompt-file /path/to/prompt.md \
  --instructions-file /path/to/instructions.md \
  --task-title "Implement the focused development task" \
  --max-model-invocations 40 \
  --output-dir .dart_tool/adele/self-hosting
```

Each invocation creates a new run directory below `--output-dir`. The runner
compiles fresh AOT artifacts, clones the exact launching `HEAD` into an isolated
Project repository, removes the clone's local origin, and lets Git Environment
create a distinct Task worktree. ADELE receives the six maintained development
tools. The isolated repository does not share Git refs or a writable local
origin with the launching checkout; final Git evidence records what actually
remained clean. This is source-layout isolation, not a command sandbox.

The bounded development strategy accepts multiple proposals from one completed
model invocation and executes them sequentially in output order against that
turn's same materialized tool set and executable generations. Proposal and tool
failures or policy denial produce results and continue to later proposals. An
`ask` decision pauses the batch, and approval or rejection resumes it in order with
prior results retained; the runner itself keeps its existing allow policy and
does not add an approval UI. One model continuation follows all proposal results.
A batch emitted in the final allowed model-invocation slot fails before any
proposal is prepared or executed because no continuation slot remains. Both
OpenAI profiles explicitly send `parallel_tool_calls:true` to permit multi-call
outputs, not concurrent ADELE host tools; common model/tool contracts are
unchanged.

The output directory must be outside the launching Git checkout or inside a
path Git considers ignored. The documented `.dart_tool` location is ignored by
this repository. A non-ignored in-repository output directory is rejected
before the runner creates it, so final checkout-cleanliness evidence remains
literal Git status rather than a runner-specific exclusion.

The run directory retains Project and Task source after success and failure. It
also contains a versioned manifest, raw Run journal, deterministic JSON and
Markdown summaries, runner log, and Task/Project/launching-checkout Git
evidence. Summary aggregates retain `toolProposalCount` and report
`modelInvocationsWithToolProposals`, `multiProposalModelInvocations`, and
`maxToolProposalsPerModelInvocation`. JSON additionally includes
`toolProposalCountsByModelInvocation`, an ordered sequence of
`{modelInvocationId, toolProposalCount}` records in journal model-start order,
including zero-proposal invocations. Counts use observed proposals, whether or
not prepared or executed; empty/no-run cases have zero aggregates and an empty
sequence. Markdown renders compact aggregate rows, while JSON and the raw journal
retain detailed tool evidence.
A failed Task is intentionally preserved for review; there is no
automatic cleanup, validation planning, commit, push, or PR workflow.

## Deferred

Normal Project selection, complete strategy-bound Task/Session lifecycle,
additional Environment-backed mutation tools, profiles, product
plugin discovery/activation, production Agent UI, application
Commands/keybindings, and plugin-facing UI extension APIs remain deferred. The
stock Git worktree Environment provider is currently exercised through focused
backend and shared-host AOT tests rather than normal UI.

The application composition root contains the development-only Phase IV model
adapters, bounded Chat-shaped tool-loop strategy, generic Session-scoped
model-tool host context, and AOT integration tests. The independent stock
Filesystem Tools, Search Tools, and Command Tools plugins, not application code,
define `read_file`, `apply_patch`, `create_file`, `delete_file`, `search`, and
`run_command`; the host context exposes facets of only the Session-selected
Environment. The OpenAI API-key and experimental ChatGPT source-coding paths use
the read/search composition. Deterministic real-Git integration additionally
proves model-visible revision flow through `apply_patch`, direct
`git diff --check` through `run_command`, and create -> read ->
revision-conditional delete continuation with final filesystem isolation. An
opt-in paid OpenAI
API-key smoke now also proves real-model `read_file`
opaque-revision flow through `apply_patch`, mutation confined to the Task Git
worktree, post-write observation, and continuation. A distinct paid API-key
smoke proves real-model direct-argv `git diff --check` through `run_command`,
model-visible command-result interpretation, and final continuation after that
edit. A separately gated experimental ChatGPT subscription-backed smoke proves
the same read -> patch -> direct-argv validation -> continuation sequence while
preserving Task-worktree, Project-source, and checkout isolation. This evidence
does not make that route a stable OpenAI integration contract or establish the
final product workflow, strategy-bound Session persistence, stock UI
composition, general whole-file overwrite, directory/move/copy/binary mutation,
fine-grained command classification, or background command execution.
`DevelopmentToolLoopStrategy` and `EnvironmentRuntime` remain provisional
application/domain-specific implementation rather than production orchestration
or a general extension-runtime pattern.

## Live Tests

The OpenAI backend's provider-only API-key and ChatGPT live smokes validate
network, authentication, and Responses behavior in isolation. Separate app-level
source-coding live smokes validate the current read/search stack through
Project/Task/Environment establishment, Session authority, plugin-contributed
Search and Read File tools, provisional orchestration, and real model
continuation. A separate paid API-key smoke validates real-model `read_file`
opaque-revision flow through `apply_patch`, Task-worktree-only mutation, and
continuation. A separate paid API-key source-validation smoke and an
independently gated experimental ChatGPT subscription-backed smoke have
completed the combined real-model `read_file` -> `apply_patch` -> direct-argv
`run_command` -> continuation path successfully, including exact Task-worktree
and source-copy isolation evidence. This does not change the ChatGPT route's
experimental status.

`ADELE_OPENAI_SOURCE_CODING_LIVE_TEST=1` enables the paid API-key full-stack
smoke when `OPENAI_API_KEY` and `ADELE_OPENAI_TEST_MODEL` are also configured.
`ADELE_OPENAI_SOURCE_MUTATION_LIVE_TEST=1` independently enables the paid
API-key full-stack source-mutation smoke with the same credentials and model.
`ADELE_OPENAI_SOURCE_VALIDATION_LIVE_TEST=1` independently enables the paid
API-key source-edit and command-validation smoke with the same credentials and
model.
`ADELE_OPENAI_CHATGPT_LIVE_TEST=1` enables the experimental ChatGPT
subscription-route full-stack smoke with
`ADELE_OPENAI_CHATGPT_CREDENTIAL_FILE`.
`ADELE_OPENAI_CHATGPT_SOURCE_VALIDATION_LIVE_TEST=1` independently enables the
experimental ChatGPT source-edit and command-validation smoke with the same
credential configuration. Both ChatGPT app smokes honor
`ADELE_OPENAI_CHATGPT_TEST_MODEL` and otherwise use the maintained classic
Responses fallback `gpt-5.5`. All five remain opt-in and are excluded from
normal CI.

See `docs/architecture/overview.md`, `docs/architecture/plugin-extension-model.md`,
and ADR 0031.
