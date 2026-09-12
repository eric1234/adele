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
Project/Task establishment and canonical strategy-bound Session creation
coordinator, a separate authoritative Session-to-Task/Environment relation,
exact-generation Environment runtime materialization, and a generic
Session-scoped model-tool host context that
projects coherent read, mutation, and process facets over one Environment
authority. Independent stock Filesystem Tools, Search Tools, and Command Tools
plugins use that context to provide Environment-authorized `read_file`,
`apply_patch`, `create_file`, `delete_file`, `search`, and `run_command`. Search
requests only the read facet; Command Tools requests only the process facet.
`search(query, path?)` performs bounded, case-sensitive literal substring search.
The optional Environment-relative `path` scopes recursion to a directory;
omitted or empty selects root (canonical `""`). Redundant slashes and `.`
segments are removed; parent traversal and absolute paths are rejected.
Canonical `path` is retained in host evidence and used in effect descriptions.
Normal scopes are opened through the authorized directory-read boundary, so
missing directories and file-valued scopes fail rather than falling back to root.
The stock `.git`, `.dart_tool`, `build`, and `node_modules` exclusions match
directory names case-insensitively on every Environment, including case-sensitive
filesystems. This policy applies both to recursive traversal and explicit scope
segments; explicit excluded scopes fail before provider reads. It does not change
case-sensitive query matching or the spelling of canonical paths.
Use `read_file` for an exact known file.
Lifecycle UI and normal stock-plugin composition are not implemented yet.

The normal application does not display the `workspace_demo` reference plugin.
The maintained `lib/development_smoke.dart` entrypoint exercises the plugin
runtime only through the explicit root smoke command.

## Session Lifecycle

`adele_product` owns the final immutable `Session(id, taskId, strategyId)` and
semantic `OrchestrationStrategyId`. The strategy ID lives in product so product
values do not depend on the orchestration package. Public pure-Dart
`adele_orchestration` provides executable strategy contributions, a thin resolver
over the existing `ExtensionRegistry`, and the narrow provider-neutral execution
facade consumed by strategy plugins. The public package and stock Chat do not
depend on the internal kernel.

`ProductLifecycleCoordinator.createSession` requires `taskId` and `strategyId`
and accepts an optional `environmentId`. It requires an existing Task and exactly
one current strategy registration for that semantic ID. The selected Environment
must exist and belong to that Task; omission selects the Task's primary
Environment. The coordinator allocates `SessionId`, revalidates the retained
strategy binding, atomically publishes the canonical Session and its separate
Environment authority, and returns the `Session`. Failed validation publishes
neither Session nor authority. Publication is private; there is no public
`associateSession` operation.

`store.session(id)` reads the canonical product value. Existing tool-host access
continues through `requireSessionAuthority`; neither Run nor generic tool context
selects another Environment. `coordinator.resolveSessionStrategy(sessionId)`
looks up the canonical Session and resolves its stored strategy ID, not a
caller-supplied replacement. No match throws `OrchestrationStrategyUnavailable`;
multiple matches throw `AmbiguousOrchestrationStrategy` even when they have
different `ExtensionId` values.
`ResolvedOrchestrationStrategy` retains the exact `ExtensionBinding`: retirement
makes it stale with `StaleExtensionBinding`, and only fresh resolution can select
a replacement. Resolution never falls back to another strategy or rewrites the
Session's stored ID.

## Orchestration Hosting

`lib/core/orchestration_host.dart` owns `createSessionOrchestrationRun`. It accepts
`SessionId`, looks up the published canonical Session, resolves that Session's
stored strategy exactly once for this Run, and materializes the retained
contribution against `KernelOrchestrationHost` via
`OrchestrationStrategyHostContext(session, host)`. Callers do not supply a
replacement strategy or construct the strategy loop directly.

The contribution's `materialize` callback returns `OrchestrationExecution` with
`start` and `resolveApproval`. `OrchestrationExecutionHost` exposes lifecycle
operations and binding validation, `invokeModel(StrategyInferenceMaterial)`,
`processProposal` using an opaque `StrategyToolSnapshot` and
`ProviderToolProposal`, and approval resolution returning semantic continuation.
Model selection/adapters, tool catalogs, policy, and Environment authority remain
core composition choices. Stream collection, proposal resolution, policy gates,
exact executable objects, `AgentRun`, and journal evidence stay internal.

The host accepts each proposal only once from the completed model turn that
issued it, using that turn's exact materialization. Approval continuation accepts
only the exact host-issued `ToolApprovalResolution` object forwarded during the
current `SessionOrchestrationRun.resolveApproval` call. Matching interruption and
invocation IDs alone is insufficient: a plugin cannot manufacture a replacement
resolution or change rejection into approval. The host consumes the authorization
on resolution and clears it when the resume call ends, preventing later reuse.
The retained invocation still binds the exact executable generation.

Materialization cannot start Run/model/tool work: host execution stays disabled
until the application enters the returned execution. Invalid caller operations
remain recoverable, but escaped invalid strategy work cannot strand a running
Run. Per-Run self-hosting reports capture immutable Chat history snapshots;
serializing an earlier result never reads a later Session tail.

The returned `SessionOrchestrationRun` retains the exact strategy execution and
binding. It exposes the Run and tool evidence only to application callers, not
plugins. Host validation applies to later operations, approval resume, and
asynchronous settlement. If generation A retires, its active Run fails explicitly
and cannot advance using B. A later Run in the same Session may freshly resolve B
under the unchanged semantic strategy ID. Retirement does not imply cancellation
or rollback of effects already in flight.

Headless stock `chat_strategy_plugin` registers executable Chat under
`dev.adele.strategy.chat`, distinct from plugin ID
`dev.adele.plugin.chat-strategy` and extension ID
`dev.adele.plugin.chat-strategy.orchestration`. `ChatStrategyPlugin.activate`
uses the existing in-process stock tool activation convention. Its
`ChatSessionStore.obtain(SessionId)` retains `ChatSessionState` across Runs;
immutable snapshots contain `ChatEntry` values (`ChatUserMessage` and
`ChatAssistantMessage`). Only user and final assistant messages are canonical.
Intermediate native/model output, proposals, and tool results stay Run-local.
Chat instructions and its positive invocation budget are snapshotted when each
Run is materialized.

Chat projects history plus Run-local replay into `StrategyInferenceMaterial`
(instructions and ordered semantic input). Before allocating invocation identity,
materializing tools, recording model-start evidence, or calling the provider, the
host calls `InferenceContextComposer` over the same existing `ExtensionRegistry`.
Every genuinely new inference, including Chat continuation, discovers current
`inferenceContextSources` and captures an immutable `InferenceContextSnapshot`.
The host then constructs internal `SemanticModelRequest(context, invocationId,
tools)`. Model/tool/policy selection and executable binding rules are unchanged.
Minimal semantic DTOs are shared from `adele_orchestration`
and reused by the kernel, without adding another public package.

`lib/core/inference_context_host.dart` supplies a fresh
`SessionInferenceContextSourceContext` per inference. It accepts only the published
canonical `Session`, supplies `runId`, and explicitly allows only
`requireHostService<AuthorizedEnvironmentFileReadFacet>()`, delegating that request
to the existing `SessionModelToolHostContext`. All other service types are rejected,
including mutation/process facets and broader Environment authority/filesystem
interfaces. Mutation and process execution remain behind the existing tool,
policy, approval, and execution-evidence boundary. Typed read authority follows
Session -> Task -> authorized Environment -> exact provider generation; a source
cannot select another Environment through this context.

Capture validates the exact source binding, calls its snapshot callback, copies,
freezes, and validates all returned material (including duplicate local keys),
then postvalidates the binding before committing that source's data. Required
failure aborts composition before model invocation identity/evidence/provider
work. Optional failure omits the whole source with its original diagnostic;
successful empty output is a distinct result. There is no replacement fallback
within the same capture. After safe capture, instruction data no longer depends
on source liveness: retirement during the provider call does not invalidate it,
and a later inference discovers any replacement. Source implementations own
freshness through rereads, watches, caches, or versions; each snapshot callback
returns current material according to those semantics. Logical source-local keys
remain stable across captures. There is no generic refresh API.

The current `ModelProviderCapabilityAdapter` in
`lib/development/agent/agent_capability_adapters.dart` calls orchestration's
`renderInferenceInstructions` at lowering. The common capability still receives
one `ModelProviderRequest.instructions` string: strategy first, then sources in
lexicographic `ExtensionId` order, preserving each source's local order and exact
text bytes, separated by blank lines. The snapshot always retains its
`StrategyInstructionGroup`, even with empty instructions. Only the renderer omits
empty strategy text; whitespace-only strategy text is preserved. Zero-source behavior is
byte-for-byte unchanged. Source sorting grants no semantic authority or numeric
priority, and semantic input is unchanged. Chat activates no source and remains
AGENTS-unaware. Only development/self-hosting composition activates stock
`agents_md_plugin`, which rereads root `AGENTS.md` through the Session-authorized
`AuthorizedEnvironmentFileReadFacet` each snapshot. `not_found` and blank files
produce successful empty output; other read/service/authority errors fail the
required source. Nonblank exact file text and its Environment revision form one
material, separate from stable plugin-owned explicit-user-precedence semantics.

The app has no `simple_tool_loop_strategy.dart` or
`development_strategy_registration.dart`; `development_agent_support.dart`
contains only development policy. The private Chat loop lives in the plugin.
Chat UI, persistence, profiles, child Sessions, strategy defaults, and general
context material beyond instructions, provider-aware projection/cache planning,
token budgets, and compaction remain deferred.

## Dependencies

Allowed dependencies are Flutter, ADELE public packages, and internal host
implementations required at the composition root. Statically composed stock
plugins include `chat_strategy_plugin` and `agents_md_plugin`, resolved through
the root pub workspace for development/self-hosting composition.
Chat's only direct production dependencies are `adele_orchestration` and
`adele_plugin_api`; it has no `agent_kernel` dependency, including in
`dev_dependencies`.

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

The topology activates Chat and the independent root-level AGENTS.md source
before creating the canonical Session. Execution obtains that Session's retained
Chat state, sets instructions and invocation
budget, appends `ChatUserMessage(prompt)`, and passes `SessionId` through lifecycle
resolution and `createSessionOrchestrationRun`. It does not construct a Chat loop
or a separate development history adapter.

The bounded stock Chat strategy accepts multiple proposals from one completed
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

Normal Project selection, Chat UI, Session/Chat persistence and child lifecycle,
context sources beyond root AGENTS.md, nested/scoped AGENTS.md, aliases/overrides,
global/home files, imports, AGENTS.md caching, broader Reference/Observation material,
provider-aware projection/cache planning, token budgets and compaction, additional
Environment-backed mutation tools, profiles, product
plugin discovery/activation, production Agent UI, application
Commands/keybindings, and plugin-facing UI extension APIs remain deferred. The
stock Git worktree Environment provider is currently exercised through focused
backend and shared-host AOT tests rather than normal UI.

The application composition root contains the model adapters, core orchestration
host, Session-scoped model-tool and inference-source host contexts, and AOT
integration tests.
The Chat plugin owns bounded loop sequencing and retained conversation state.
The independent stock
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
`EnvironmentRuntime` remains provisional application/domain-specific
implementation rather than a general extension-runtime pattern. Headless Chat
execution is not a claim of production orchestration UI, persistence, or complete
self-hosting.

## Live Tests

The OpenAI backend's provider-only API-key and ChatGPT live smokes validate
network, authentication, and Responses behavior in isolation. Separate app-level
source-coding live smokes validate the current read/search stack through
Project/Task/Environment establishment, Session authority, plugin-contributed
Search and Read File tools, Session-routed Chat orchestration, and real model
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

Recorded `ADELE_OPENAI_CHATGPT_TEST_MODEL=gpt-6-astra` evidence includes an
ordinary function-tool outcome and canonical continuation in two model
invocations in the backend smoke. The full-stack ChatGPT source-coding smoke
recorded `search` -> `read_file` -> final response in three, with inspected source
unchanged in the distinct Task worktree, Project source, and launching checkout.
Every completed invocation in these proofs must contain the exact selected
service-reported `effectiveModel`; missing or substituted model identity fails
validation. The backend no longer falls back to the request when the service
omits its model. The backend tool smoke also passes with the retained `gpt-5.5`
default. Deterministic tests validate the current Session-routed Chat path;
paid live services have not been rerun against it.

These are classic Responses proofs, retaining `store:false`, native replay, and
`parallel_tool_calls:true`, not a Responses Lite implementation or a larger
self-hosting experiment. Newer account-catalog `use_responses_lite:true` metadata
does not establish a classic-route limitation. ADR 0028 distinguishes current
external Astra/5.6 interoperability evidence from ADELE's Astra-specific proof;
Lite is deferred unless concrete compatibility pressure requires it. The route
remains experimental.

See `docs/architecture/overview.md`, `docs/architecture/plugin-extension-model.md`,
and ADR 0031.
