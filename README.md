# ADELE

ADELE is an extensible, cross-platform desktop environment for building,
running, inspecting, and extending agent systems. The long-term goal is for
ADELE to become capable of developing ADELE itself.

ADELE's maintained foundation includes:

```text
Dynamic source-plugin runtime and generated typed transport
Active capability registry and exact-generation routing
Provider-neutral Run/model/tool/policy/approval mechanics
Session-bound executable strategies and headless stock Chat
Typed Session presentation and prepared interpreted stock Chat history/composer
Read-only live Run activity with tool-batch narration and native activity summaries
Plugin-owned compact activity and retained, newest-first Inspection cards
Per-inference instruction-source capture and immutable context snapshots
Shared application runtime and six static in-process stock plugins
Prepared installed-backend discovery and backend-owned capability advertisements
Typed Project selectors and minimal local-directory Project opening
Normal title-only Task creation with a real Git primary Environment
Normal stock Chat Sessions with approval-gated ChatGPT-backed Runs
Stock root-level AGENTS.md instructions
Session-authorized Environment read/search and bounded text-file mutation
Foreground process execution and model-facing command validation
```

Interpreted Flutter frontends run in the Flutter host; locally compiled AOT
backends run through one shared child Dart runtime with generated typed clients,
codecs, backend dispatch, and deterministic provider selection. `workspace_demo` remains the
Phase I/II regression fixture, `resource_inspector` remains the Phase III
multi-provider capability fixture, and `scripted_model` remains deterministic
model-provider/transport regression infrastructure. These are internal
reference fixtures, not product UI or product-domain definitions.

F1 implements a bounded prepared installed-backend startup snapshot, not a plugin
installer or general activation manager. Profiles, enable/disable controls,
version solving, watching, frontend discovery, reverse RPC, hot upgrade,
production packaging, configurable permissions, sandboxing, and general
third-party extension APIs are not yet implemented.

`AdeleRuntime()` in `app/lib/core/adele_runtime.dart` synchronously constructs a
provider-free application host graph. It owns the capability and
extension registries, in-memory product store, generated lifecycle coordinator,
inference context composer, retained Chat plugin, and six static in-process
activations: Chat, AGENTS.md, Filesystem Tools, Search Tools, Command Tools, and
Local Directory Project Selector. The reduced smoke composition omits only
Command Tools. It also owns pure-Dart `ApplicationPluginBootstrap` on the same
capability registry, without starting it from the constructor.

Normal `AdeleApplication` explicitly calls `ApplicationPluginBootstrap.start`
asynchronously with an installation root, shared runtime/host paths, and optional
generic startup argv. `plugin_runtime.PreparedPluginCatalog.discover(rootPath)`
first snapshots immediate child directories' `adele_plugin.installation.json`
files in deterministic order. Version-1 manifests contain `PluginMetadata` and
optional backend component paths to confined, existing prepared artifacts, not
source paths, exposures, configuration, or activation state. Versions are opaque.
Missing/empty roots succeed empty; malformed children are reported and excluded,
and duplicate IDs exclude all conflicts without a version winner. Root I/O failure
reports generic bootstrap failure while the in-process core remains usable.

No valid backends means successful startup without a process, even with invalid
host paths. Otherwise one shared host attempts all valid backends independently,
with no required Git or additional-OpenAI tier. Local start/metadata/registration
failure cleans up only that attempt; later termination retires only its exact
generation. Shared-host failure is global. Read-only backend states and catalog
issues are exposed without a plugin-management UI.

Git and OpenAI entrypoints own their ready `capabilityExposures`. The existing
isolate-ready -> host `pluginReady` -> exact connection path feeds generic
`registerAdvertised`, which delegates to `PluginCapabilityActivation.register`
with existing registry/liveness semantics. Omitted advertisements mean zero
capabilities; installation/connection identity is authoritative. The app has no
backend exposure table. The launcher supplies a temporary separate PluginId-to-argv
JSON file; OpenAI receives `--chatgpt-only` plus a configuration JSON argument when
configured, containing only a credential-file reference and public OAuth/endpoint
options, never tokens. Normal bootstrap always sets `startupArgumentsOnly: true`;
OpenAI disables environment fallback and advertises zero capabilities for
empty argv or an absent configuration document. Root-only normal activation thus
cannot inherit API-key exposure even without the launcher's map. The app forwards
argv and the flag generically, without a PluginId switch or interpreting OpenAI
configuration. `app/lib/plugins/temporary_chatgpt_selection.dart` retains the
selected provider identity and model-only configuration, always supplying the
model default or override without a credential-presence gate. Availability comes
from the active registry; the app never inspects startup OAuth/credential
configuration. General provider/model configuration remains deferred; this seam
is intended to disappear with general plugin configuration/profiles. Startup compiles
no source and creates no Project, Task, Environment, Session, tool catalog, or Run.

Application close immediately blocks window actions and notifications and drains
any in-flight Task establishment and currently advancing Run start/resume before
calling `runtime.close`, even when either fails. A quiescent waiting Run is
abandoned with runtime teardown without resolving or executing its pending
invocation or waiting indefinitely for approval. This is settlement draining, not
cancellation or rollback. Desktop exit awaits that close; detach/dispose initiate
the same cleanup and report failures. Backend capability registrations retire
before connections close, then the shared host closes, then the runtime's
in-process activations retire in reverse order. Cleanup attempts every action
before reporting its first failure. Self-hosting reuses the runtime and generic
registration of backend-owned advertisements, but owns its explicit
artifact/host/profile and product/Run topology independently of normal discovery
and startup configuration. It keeps the default `startupArgumentsOnly: false`,
so its own profile environment determines backend
configuration; it registers all advertised online contexts, potentially both
OpenAI contexts, then explicitly resolves the selected profile's provider ID.

B1 adds `ProjectSelectorContribution` in tiny pure-Dart `adele_core_extensions`,
whose only package dependency is `adele_plugin_api`. The typed
`projectSelectorContributions` point accepts zero, one, or multiple independent
selectors, with no priority, default, category, or applicability machinery.
`AdeleApplication` discovers the shared registry in `build`; the existing themed
shell keeps its ADELE header and shows one button per contribution in registry
registration order, or an explicit unavailable state when none exist.

Stock `local_directory_project_selector_plugin` supplies `Open Local Directory...`
using a native directory picker. Only the app passes its URI to
`runtime.lifecycle.createProject`, which publishes and returns the canonical
Project. Presentation is window-local app State, not `runtime.currentProject`.
Buttons are disabled during selection; `null` is cancellation, errors stay inline
without fallback or changing the presented Project, and stale/late results cannot
open a Project after selector retirement or window disposal/exit.

After opening, the shell shows a URI-derived leaf name (falling back to host or
URI), source URI, `Project is open`, and initially `No Tasks yet`. Opening itself
starts no Task, Environment, Session, model, tool catalog, or Run and does not
trigger backend activation. B2 adds a title-only inline `New Task` form with
Cancel/Create controls, pending duplicate-submit protection, and inline errors
with retry. The app calls `runtime.lifecycle.createTask(projectId: ..., title: ...)`
without a provider ID. Existing deterministic rank/identity default resolution
is unchanged; stock composition supplies Git, not Git-specific UI routing.

Only successful lifecycle completion presents the new canonical Task and primary
Environment. The shell shows the Task title, Environment ID, and readiness from
the live exact materialization binding, never by parsing opaque `providerState`.
Project/Task/Environment presentation remains window-local. Non-Git source
validation belongs to the selected provider, not Project selection or the form.
This is not a Task Browser, Command surface, catalog, persistence, or deduplication
system. Normal presentation supplies one window-local canonical stock Chat Session,
independent of model availability, and a minimal conversation/prompt surface. Each
accepted prompt creates a fresh Run with an exact newly resolved ChatGPT provider
binding, fresh Session-authorized tools, and `ApprovalGatedToolPolicy`. Certain
source reads are allowed; eligible source mutations and commands require
per-invocation approval,
while other effects are denied through model-visible tool outcomes. Window-local
approval cards resume the same Run through the existing interruption boundary;
they do not enter canonical Chat history or bypass revision and binding checks.
See `app/README.md` for bootstrap ownership, lifecycle settlement, and validation
paths.

ADELE separates provider-neutral Run/model/tool/policy/approval mechanics from
strategy-owned Session meaning. `adele_product` owns the final immutable
`Session(id, taskId, strategyId)` and semantic `OrchestrationStrategyId`; public
pure-Dart `adele_orchestration` supplies executable strategy contributions and
exact-binding resolution over the existing extension registry. Session creation
requires an existing Task and one current matching strategy, validates the
Task's primary or explicitly selected same-Task Environment, and atomically
publishes the Session and separate Environment authority in memory.

The first executable stock strategy is `chat_strategy_plugin` under
`plugins/chat_strategy`, registered as `dev.adele.strategy.chat` with separate
plugin and extension identities. Chat owns retained in-memory canonical
user/final assistant history, instructions, and a positive model-invocation
budget snapshotted per Run. Intermediate model/native output, proposals, and tool
results remain Run-local; canonical history is reused across Runs.

`createSessionOrchestrationRun` in `app/lib/core/orchestration_host.dart` resolves
the canonical Session and its exact contribution once per Run, then materializes
it against `KernelOrchestrationHost`. The public execution facade exposes semantic
model turns, opaque tool snapshots, proposal processing, and approval
continuation, not kernel ports, catalogs, policy, `AgentRun`, or journal objects.
Minimal semantic DTOs live in the existing `adele_orchestration` package and are
reused by the kernel; neither the public package nor Chat imports the kernel.
Missing or duplicate strategy IDs fail explicitly. Retained bindings are
validated on operations, approval resume, and asynchronous settlement: stale
active Runs fail rather than migrate, while a later Run in the same Session may
freshly resolve a replacement under its unchanged strategy ID.

The common `ModelProvider` capability uses generated streaming/cancellation,
ordered semantic/provider-native items, explicit settlement, and exact
generation-bound routing. The real OpenAI plugin provides the public API-key
Responses route and two separately routed configured contexts: API key and an
explicitly experimental ChatGPT subscription-backed route. The latter is
positive interoperability evidence, not a documented/stable third-party OpenAI
integration contract. Both profiles explicitly send `parallel_tool_calls:true`,
which permits multiple function-call outputs from one model invocation, not
concurrent ADELE host-tool execution or a common-contract change.

Product lifecycle uses immutable Project, Task, and Environment values and binds
Sessions authoritatively to one Task-associated Environment in memory.
Active plugin generations contribute contextual model tools through the generic
extension registry. The independent stock Filesystem Tools, Search Tools, and
Command Tools plugins own `read_file`, `apply_patch`, `create_file`,
`delete_file`, `search`, and `run_command`, while a Session-scoped host facade
supplies coherent read, mutation, and process facets over the one authorized
Environment. Search requests only the read facet and recursively composes
`readDirectory` and `readFile` in Dart; Command Tools requests only the process
facet.

The stock Chat strategy accepts multiple proposals from
one completed model invocation and executes them sequentially in output order
against that turn's same materialized tool set and executable generations.
Proposal and tool failures or policy denial produce results and continue to later
proposals; `ask` pauses the batch, and approval or rejection resumes it in order
with prior results retained. One model continuation follows all proposal results.
A batch emitted in the final allowed model-invocation slot fails before any
proposal is prepared or executed because no continuation slot remains.

`ChatStrategyPlugin.activate` follows the existing in-process stock-tools
conventions. `AdeleRuntime` activates and retains Chat in normal startup and
development/self-hosting. Self-hosting obtains its retained Session state, appends
the prompt, and routes `SessionId` through core lifecycle and orchestration
hosting rather than constructing a loop directly.
Normal presentation consumes this retained Chat state through a provisional app
controller adapter. The separate Flutter `chat_strategy_frontend` package under
`plugins/chat_strategy/packages/frontend` owns the evaluated history and composer,
without importing the headless strategy implementation, app, or kernel.

Public Flutter `adele_ui` in `packages/ui` defines
`SessionPresentationContribution(strategyId, createPresentation)` and typed
`sessionPresentationContributions` over the existing extension registry. The
factory has type `Widget Function(Session)`. The generic app Session host matches
the canonical Session's `OrchestrationStrategyId` exactly: no match is unavailable,
one match supplies presentation, and multiple matches are explicitly ambiguous.
It validates retained bindings and removes retired presentation widgets; only
fresh resolution may select a replacement. Missing or failed presentation does
not invalidate the Session or backend execution.

Normal Chat presentation loads prepared EVC bytecode rather than compiling source
at runtime. Its narrow bridge carries immutable primitive mixed message/activity
timeline snapshots, composer-enabled state, prompt submission with synchronous
boolean acceptance, and host-built inspectable activity widgets using opaque IDs
emitted to that presentation. These native slots compose plugin compact widgets
in their own prepared runtimes, without plugin-specific Chat parsing.
Run status and approval cards remain host-owned under
`app/lib/ui/execution`; execution objects and approval authority never cross that
bridge. `ChatController` remains provisional in `app/lib/ui/chat`, while generic
prepared frontend hosting lives in `app/lib/frontend` and stock Chat activation
and adaptation belong at `app/lib/plugins/stock_chat_frontend.dart`. This is a
bounded Session presentation API, not production plugin discovery or a general
workbench extension framework.

Normal Runs expose immutable live activity through public pure-Dart
`adele_orchestration`, projected by the application host from the internal journal.
Observation grants no execution or approval authority. Ordered model text, opaque
native outputs, proposals, and resolved tool evidence retain stable identities.
Chat counts one occurrence per tool proposal or native output with
`presentation != null` within each successfully completed model invocation.
Narration and opaque native items do not count. A single occurrence appears
directly using plugin compact presentation; two or more use one lightweight group.
Its heading prefers explicit narration only when tools are present, then safe
presentation `compactText`, then a structural operation count. Missing compact
presentation preserves a bounded tool alias or provider-approved compact text,
never a one-operation group count. Reasoning-only activity appears before the
canonical final assistant text, without turning that text into batch narration.
The Chat strategy automatically adds batch-narration guidance to its inference
instructions while preserving Session instructions and independent context sources.
Grouping never requests an extra inference. Activity stays out of canonical Chat
history; completed groups remain only for the current controller lifetime,
including follow-up prompts. Reconstructing a
Session cannot restore historical activity without future persistence. Raw native
output remains opaque to generic Chat and Inspection code; the provider backend
supplies safe presentation separately. Chat needs no native-presentation negative
cache or registry-change retry machinery to decide activity presence.
Clicking prepends a window-local Inspection card: a group target identifies exact
Session/Run/model, while an individual target additionally identifies output
sequence and remains stable from proposal through prepared invocation. Card IDs
are independent of targets; duplicate targets are permitted. Cards independently
collapse/expand or dismiss without affecting other cards or evidence. Group bodies
interleave compact tool/native rows in exact output order; common row clicks
prepend rich individual cards without replacing the group. Retained cards follow
live evidence, survive follow-up prompts, and clear on Session replacement.
Filesystem Tools, Command Tools, and OpenAI expose compact and rich entrypoints
from their existing prepared artifacts through distinct public `adele_ui` roles.
Exact zero/one/many resolution never picks an ordering winner; retirement affects
only presentation. The app transports immutable data without interpreting plugin
fields. Plugins receive no inspect or approval callbacks. See
`docs/architecture/overview.md` for contracts, liveness, and deferred scope.

The generated `adele_model_provider` contract carries
`ModelProviderNativePresentation(kind, compactText, data)` separately from raw
`nativeMetadata`. `ModelProviderOutput.nativePresentation` is required but nullable:
`null` means no safe presentation, while the generated key remains required under
the coherent-schema convention. The generic capability adapter maps it to
immutable `adele_orchestration.ModelNativePresentation` with the same fields on
optional `ModelNativeOutput.presentation`, without provider-specific parsing.
Raw `nativeMetadata` remains exact and the only native replay source; safe
presentation is never replayed.

Public Flutter `adele_ui` defines
`ModelNativeActivityPresentationContribution(presentationKind, createInspection)`
at `modelNativeActivityPresentationContributions`, with a
`Widget Function(ModelNativePresentation)` factory. There is no UI projection type
or projector callback. `ModelNativeActivityPresentationResolver` matches the exact
safe presentation kind: zero makes rich Inspection unavailable without removing
safe activity, one supplies a retained binding, and multiple matches are explicitly
ambiguous, without priority or fallback.

OpenAI uses `plugins/openai/packages/{contract,backend,frontend}`. Pure-Dart
`openai_contract` owns identities and payload schema only, not algorithms. The raw
kind remains `openai.responses.item.v1`, version 1; the distinct safe presentation
kind is `openai.responses.reasoning-summary.v1`, version 1. The backend classifies
raw Responses items and produces bounded safe summaries; `openai_frontend` renders
the read-only `summaryParts`/`truncated` payload. Generic Chat escapes compact
display text, and the OpenAI frontend escapes full text. Raw envelopes,
compatibility metadata, encrypted content, and execution/approval authority never
enter that EVC. This is a supplied summary, not hidden chain-of-thought disclosure.

`app/lib/plugins/stock_openai_activity_frontend.dart` imports Contract identity,
loads the prepared artifact, registers its factory, and retires that registration
and its resources through `PreparedFrontend` and existing registry liveness. This
stock activation edge is explicitly provisional until frontend discovery/profiles replace
hard-coded selection; it owns no projection or display-safety algorithms.
Missing/corrupt EVC, malformed safe payload, and factory failure remain
presentation-local without failing the Run or selecting a native fallback.
Retirement removes the exact-generation view; a replacement
requires fresh resolution and cannot retarget stale resources. Backend summary
request support remains a narrow provider-local policy documented in the
[OpenAI backend README](plugins/openai/packages/backend/README.md), not a common
model option or a claim that every OpenAI model supports summaries.

Chat supplies `StrategyInferenceMaterial` containing instructions and ordered
semantic input from history projection plus Run-local replay. Public
`adele_orchestration` now supplies `InferenceContextComposer` over the same
`ExtensionRegistry`: each new inference, including Chat continuation, discovers
`inferenceContextSources` and captures instruction material into an immutable
`InferenceContextSnapshot` without changing semantic input. Strategy instructions
come first, then sources in lexicographic `ExtensionId` order with source-local
order preserved. This is deterministic composition, not priority or semantic
authority. Required source failure stops preparation before model invocation;
optional failure omits that entire source and retains diagnostics.

The host constructs internal `SemanticModelRequest(context, invocationId, tools)`.
The current app `ModelProviderCapabilityAdapter` calls orchestration's
`renderInferenceInstructions` to lower the snapshot to the unchanged
`ModelProviderRequest.instructions` string. With no source material, strategy
instruction bytes remain unchanged. Source freshness is source-owned, not a
generic refresh API. Chat activates no context source and remains AGENTS-unaware;
tools, policy, model controls, and Environment authority retain their existing
owners. See `packages/orchestration/README.md` for capture and rendering semantics.

The stock `agents_md_plugin` under `plugins/agents_md` is activated by
`AdeleRuntime` in normal startup and development/self-hosting. Activation alone
does not read a file. Each snapshot rereads root `AGENTS.md` in
the Session-authorized Environment through `AuthorizedEnvironmentFileReadFacet`.
`not_found` or blank/whitespace-only text produces successful empty output; other
read/service/authority errors fail composition as a required source. Exact nonblank
file text and its opaque Environment revision are retained in one material,
separate from stable plugin-owned semantics stating that explicit user
instructions and direct requests take precedence over AGENTS.md guidance.
This adds a concrete source, not generic context infrastructure or a
repository-instructions owner for Skills, Agent Roles, or repository maps.

Filesystem Tools owns the model-facing
`apply_patch(relativePath, expectedRevision, edits)` grammar. Its non-empty
`edits` array contains `{search, replace}` objects applied in list order to a
working string, so later edits see earlier replacements. Each non-empty search
must match exactly once, literally and case-sensitively, including overlapping
candidate starts; replacement text may be empty. The tool preflights the original
opaque revision once, validates every edit before writing, and makes one
conditional whole-file replacement with that same revision. A failed edit or a
final result identical to the original text causes no write. Environment owns
the conditional replacement primitive, not the model patch grammar.

The OpenAI API-key and experimental ChatGPT source-coding paths use this
plugin-composed, Session-authorized Environment tool path. Deterministic AOT
integration proves recursive discovery and reading of copied maintained ADELE
source, real-model continuation, and generation-safe replacement of tool and
Environment-provider generations. Deterministic integration also covers
model-visible Read File revision flow into plugin-owned ordered exact-unique
`apply_patch`, conditional mutation of the Session-authorized Git worktree, and
model continuation. Recorded opt-in paid OpenAI API-key full-stack evidence
includes real-model `read_file` opaque-revision flow into `apply_patch`, mutation
confined to the Task Git worktree, post-write observation, and model
continuation. A separate paid OpenAI API-key smoke proves real-model direct-argv
`git diff --check` validation and continuation after that mutation. A separately
gated experimental ChatGPT subscription-backed smoke proves the same real-model
`read_file` -> `apply_patch` -> direct-argv `run_command` -> continuation path
through the current classic Responses profile, including Task-worktree mutation
and Project/checkout isolation. This remains experimental interoperability
evidence rather than a stable OpenAI integration contract. The current
Session-routed Chat path is validated by deterministic tests; paid live services
have not been rerun against it.

ADELE has also validated `gpt-6-astra` through the existing classic ChatGPT
Responses backend's ordinary function-tool continuation and the full-stack
`search` -> `read_file` -> final-response smoke. Every completed invocation
reported exactly `gpt-6-astra`; missing or mismatched service-reported model
identity fails validation rather than falling back to the request. The maintained
development/self-hosting default is `gpt-6-astra`;
`ADELE_OPENAI_CHATGPT_TEST_MODEL` remains the explicit override.
Newer catalog `use_responses_lite:true` metadata is not a demonstrated
requirement for Lite. [ADR 0028](docs/adr/0028-experimental-chatgpt-openai-configured-instance.md)
separates external Astra/5.6 classic-route evidence from ADELE's Astra proof and
defers Lite until concrete compatibility pressure requires it.

The practical bounded UTF-8 source-file mutation set includes
create-new-only `create_file` and opaque-revision-conditional `delete_file` over
the existing Session Environment authority. Creation never intentionally
overwrites a target that exists at its exclusive claim point and requires an
existing direct parent directory. Deletion requires a revision from an observed
file state. Deterministic real-Git integration proves model-visible create ->
read -> delete continuation and final Task/Project/checkout isolation; no paid
create/delete smoke is claimed.

Environment supplies a provider-neutral, Session-authorized foreground process
primitive. The stock Git Worktree implementation uses direct
argv, generated stdout/stderr streaming, bounded head/tail output, confined cwd,
required timeout, explicit child-environment filtering, and practical Linux x64
process-group cleanup.

Independently activatable stock Command Tools supplies the direct
`program` plus `arguments` `run_command` tool. It projects stdout/stderr as
structured progress, retains bounded terminal model output, and uses the
existing allow/deny/ask policy path with a conservative uncertain
`processExecution` effect over the whole authorized Environment. Deterministic
real-Git integration proves `read_file` -> `apply_patch` -> `git diff --check`
-> model continuation in the Task worktree. This does not add implicit shell
syntax, command safety classification, environment overrides, background
process resources, or sandboxing.

Recorded paid opt-in OpenAI API-key evidence covers the same `read_file`
-> `apply_patch` -> direct-argv `run_command` -> continuation path. It proves
exact model-visible revision provenance, command policy/outcome evidence, final
Task source, and Project/checkout isolation. This does
not claim general shell compatibility, fine-grained command permissions,
sandboxing, background process management, general build/test success, or
complete self-hosting.

## Accepted long-term architecture beyond the current implementation

The maintained runtime is deliberately narrower than ADELE's accepted product
and extension direction.

ADR 0030 accepts a **recursive typed extension model**:

```text
ADELE core
    -> typed extension points
        -> plugins
            -> plugin-defined typed extension points
                -> other plugins
```

Plugins should normally cooperate through public typed interfaces and live
runtime discovery rather than dependencies on specific implementation plugins.
Capabilities remain the callable Action/Service provider mechanism; Events are
read-only fact notifications; UI/composition extension points may use different
zero/one/many and merge/failure semantics. Generic registration/liveness and
typed model-tool, orchestration-strategy, inference-context-source, Project
selector, Session presentation, tool Inspection, and model-native activity
presentation points are implemented; broader recursive composition and workbench
UI APIs remain deferred. The Project buttons are
temporary host presentation, not a chooser framework or application Commands.

ADR 0031 accepts these shared product-domain identities:

```text
Project
└── Task
    ├── Environment(s)
    └── Session(s)
        ├── Run(s)
        └── child Session(s)
```

- Project is an abstract core identity, not intrinsically a local directory.
- Task is the durable core unit of user intent.
- Environment is initially the practical filesystem/source + process context;
  providers such as Git Worktree or Docker may implement it differently.
- A separate first-class Workspace concept is not required unless future
  concrete needs demonstrate an independent identity.
- Session is permanently bound to one orchestration strategy; Chat history is
  one strategy's state, not the universal Session model.
- Child Sessions represent delegated work and may share or use another
  Task-associated Environment.

The expected default development experience is itself a plugin/configuration
composition rather than hard-coded core behavior. See
`docs/architecture/stock-plugin-direction.md` and `docs/mockups/README.md`.
Most of that stock plugin set does not exist yet.

## Toolchain

The integrated foundation is temporarily pinned to Flutter `3.38.10`
(framework `c6f67dede3d4aa1aa7a69dd56a3494a5cde6cc80`, engine
`cafcda5721a78a7884db92f13c5e89f7643d52dd`) and bundled Dart `3.10.9`.
`.tool-versions` selects this SDK for asdf users and `toolchain.json` records the
manager-independent identity. This is not ADELE's permanent toolchain.

`flutter_eval 0.8.2` fails against Flutter 3.44.8 due to missing
`Container.isAntiAlias` support. Modernizing or replacing the eval dependency
is required before exposing a broad third-party interpreted UI API.

Future ADELE distributions are expected to include a pinned toolchain capable
of compiling plugin source locally. A toolchain upgrade may invalidate compiled
plugin artifacts and require rebuilding them. ADELE's own version will not be
tied directly to Dart semantic versions.

## Commands

Run all commands from the repository root:

```sh
dart tools/adele.dart bootstrap
dart tools/adele.dart run linux     # use macos or windows on those hosts
dart tools/adele.dart format
dart tools/adele.dart generate
dart tools/adele.dart analyze
dart tools/adele.dart test --jobs 2
dart tools/adele.dart check
dart tools/adele.dart build linux
```

Normal Linux `run` and `build` compile fresh shared-host, Git, and OpenAI backend AOT
snapshots and assemble a prepared installation root, plus four frontend EVCs
(Chat, Filesystem Tools, Command Tools, and OpenAI activity), before the Flutter
run/build invocation.
`tools/backend_artifacts.dart` uses `compileAotSnapshot` from `plugin_builder` and
selects the Dart compiler and `dartaotruntime` from the launching Flutter SDK. It
still knows stock Git/OpenAI source paths and writes their installed JSON
manifests; source directories are not normalized to the reference fixture's draft
`adele_plugin.yaml` source/build format. Installed manifests and source/build
manifests are distinct; see `docs/architecture/plugin-layout.md`.
`tools/frontend_artifacts.dart` invokes the Flutter build-time entrypoints
`app/tool/compile_chat_frontend.dart`,
`app/tool/compile_tool_inspection_frontends.dart`, and
`app/tool/compile_openai_activity_frontend.dart`. Fresh artifacts are retained under
`.dart_tool/adele/desktop-backends/` and `.dart_tool/adele/desktop-frontends/`.
The launcher passes `ADELE_DARTAOTRUNTIME_EXECUTABLE`,
`ADELE_BACKEND_HOST_ARTIFACT`, `ADELE_PLUGIN_INSTALLATION_ROOT`,
`ADELE_PLUGIN_STARTUP_ARGUMENTS_FILE`, `ADELE_CHAT_FRONTEND_ARTIFACT`,
`ADELE_FILESYSTEM_TOOLS_FRONTEND_ARTIFACT`,
`ADELE_COMMAND_TOOLS_FRONTEND_ARTIFACT`, and
`ADELE_OPENAI_ACTIVITY_FRONTEND_ARTIFACT` as compile-time deployment-location defines.
The normal app consumes only prepared locations; runtime activation never compiles
source. See `app/README.md` for frontend
preparation inputs and standalone build-time invocations.

These provisional absolute paths make the built app runnable only on the
source-checkout machine while those artifacts and that SDK remain in place.
Moving or deleting them breaks the corresponding backend startup or frontend
loading. This is not artifact caching, an installer, portable/production
packaging, or profiles. Discovery is only the prepared backend startup snapshot.
Invoking Flutter directly without the defines
leaves Task Environment support, Chat presentation, stock tool Inspection, and
OpenAI activity presentation unavailable independently.
Checkout tooling stands in for future installation/update-time compilation;
activation consumes prepared artifacts rather than building them.

Recorded B2 Linux profile build, real-host/Git, widget/runtime/bootstrap, tooling,
and Xvfb startup evidence predates F1 and is not validation of the new catalog or
advertisement path. See `app/README.md` for bounded validation evidence, maintained
validation commands, and source-checkout limitations.

The internal Linux profile smoke is explicit and does not alter normal app
startup:

```sh
ADELE_DEVELOPMENT_REPOSITORY_ROOT="$PWD" \
ADELE_DEVELOPMENT_PLUGIN_DIRECTORY="$PWD/plugins/workspace_demo" \
ADELE_DEVELOPMENT_DIRECTORY=/path/to/demo-root \
dart tools/adele.dart smoke linux --profile
```

`bootstrap` uses the standard Dart pub workspace through Flutter's pub command.
`generate` deterministically updates committed experimental contract transport;
`generate --check` rejects stale outputs and is included in `check`.
The command driver runs package test suites through a bounded worker pool and
reports every failed package after all targets settle. `check` verifies
formatting, analysis, and all implemented tests, including committed
generated-output freshness.

The workspace includes `plugins/chat_strategy` and `plugins/agents_md`, and `app`
depends on `chat_strategy_plugin` and `agents_md_plugin`. The driver includes both
in package analysis and test discovery; `test-plan --json` also includes both in
the CI matrix. Run their pure-Dart tests with
`dart tools/adele.dart test --target chat_strategy_plugin` or
`dart tools/adele.dart test --target agents_md_plugin`.

`adele_ui` is a Flutter analysis/test target. The separate
`chat_strategy_frontend`, `filesystem_tools_frontend`, `command_tools_frontend`,
and `openai_frontend` packages are Flutter workspace members and analysis targets;
their EVC preparation belongs to the app's build-time tooling. Pure-Dart
`openai_contract` has maintained identity tests and analysis/test discovery through
`tools/adele.dart`; raw classification, projection, bounds, and native-preservation
tests belong to `openai_model_provider_backend`.

The repository development command above is unrelated to ADELE's future
application-level Command Palette/keybinding subsystem described by the
extension architecture.

## Repository

```text
app/                         single Flutter desktop application
packages/plugin_api/         adele_plugin_api (experimental public)
packages/core_extensions/    adele_core_extensions narrow core-owned contracts
packages/ui/                 adele_ui public Session/tool/native activity UI APIs
packages/contract/           adele_contract (experimental public)
packages/contract_codegen/   contract_codegen (internal, pure Dart)
packages/model_provider/     adele_model_provider (experimental public)
packages/model_tool/         adele_model_tool public contribution/execution API
packages/capabilities/       adele_capabilities (experimental public)
packages/product/            adele_product canonical product identities/values
packages/orchestration/      adele_orchestration strategies/execution/context/activity API
packages/environment/        adele_environment provider/filesystem contract
packages/plugin_runtime/     plugin_runtime (internal, pure Dart)
packages/plugin_backend_host/ shared backend host (internal, pure Dart)
packages/plugin_builder/     plugin_builder (internal, pure Dart)
packages/agent_kernel/       agent_kernel (internal, pure Dart)
plugins/workspace_demo/      internal source-plugin reference fixture
plugins/resource_inspector/  Phase III two-provider capability fixture
plugins/scripted_model/      deterministic ModelProvider/transport fixture
plugins/openai/              Contract identities/schema, backend safe projection, evaluated frontend
plugins/filesystem_tools/    stock text-file tools plus evaluated Apply Patch Inspection
plugins/search_tools/        stock Session-authorized literal Search tool
plugins/command_tools/       stock foreground Command tool plus evaluated Inspection
plugins/chat_strategy/       headless Chat strategy plus separate evaluated frontend
plugins/agents_md/           stock root-level AGENTS.md instruction source
plugins/local_directory_project_selector/ stock native directory Project selector
plugins/git_environment/     Git worktree Environment provider
docs/architecture/           architecture boundaries/directional models
docs/adr/                    architectural decision records
tools/                       root development command driver
```

Key current direction documents include:

```text
docs/architecture/plugin-extension-model.md
    accepted recursive extension architecture

docs/architecture/stock-plugin-direction.md
    speculative expected default plugin topology

docs/architecture/agent-kernel-semantic-model.md
    provider-neutral execution semantics

docs/architecture/agent-tooling-direction.md
    stock tool/execution/presentation direction

docs/mockups/README.md
    stock development UX produced by the expected plugin/configuration set
```

Packages intended to become part of the public plugin-development surface use
the `adele_` prefix. Internal implementation packages use concise unprefixed
names. Every package is unpublished (`publish_to: none`). Public packages never
depend on internal host packages; pure-Dart packages never depend on Flutter.
The application is the composition root.

`adele_core_extensions` is only for core-owned extension contracts with no natural
existing public domain package, not a catch-all API package. Existing registry,
product, orchestration, tool, Environment, and plugin-ecosystem ownership remains
as defined in `docs/architecture/dependency-rules.md`.

Plugins may eventually depend on deliberately public extension API packages
defined by core or another plugin/component. They must not import another
plugin's frontend/backend/private implementation merely because it is present in
the repository.

`workspace_demo` exercises separate pure-Dart contract, Dart backend, and
Flutter frontend packages. Frontend/backend depend on the shared contract,
never on one another. It is maintained reference infrastructure; the word
`workspace` in this historical fixture name is not a product-domain decision.

`resource_inspector` contains a lightweight shared capability/contract package,
independent basic/alternate backend packages, and an evaluated consumer. The
consumer lists providers, invokes deterministic default/explicit providers, and
renders structured unavailable state through the capability bridge. The Linux
smoke verifies provider lifecycle around startup/shutdown.

## Profiles and configuration

ADELE profiles are accepted as sparse named composition layers for plugin
activation, configuration overrides, provider availability, and provider
preferences. A future window/context may use an ordered stack such as
`Developer + Work` or `Developer + Personal`; the architecture imposes no
arbitrary small stack limit.

Profiles are not implemented. Normal startup and development/self-hosting reuse
the implicit in-process stock composition and generic registration of
backend-owned advertisements, while owning separate backend topologies. Normal
startup attempts all valid discovered backend installations; self-hosting keeps
explicit artifact/host/profile selection. Installation itself does not activate
anything. Deployment-location defines and the temporary argv file are not a
profile or general configuration API.

Activation, ordinary configuration, provider selection, configured capability
instances, product/runtime state, security/policy, and workbench state remain
distinct concepts. An effectively disabled plugin is intended to disappear from
that context's normal product/settings surface without deleting dormant
persisted configuration.

Open windows may keep independent live workbench state while remembered local
state seeds future windows. Plugin-facing workbench extension points should be
semantic rather than tied to current center/right/bottom placement.

Core is also expected to own application Command registration, Command Palette,
keybinding resolution, plugin-suggested defaults, and user rebinding. Those
systems are accepted direction but not yet implemented.

See `docs/architecture/profiles-and-configuration.md`.

## Deferred

The implemented context slice remains instruction-only, with root-level
AGENTS.md as its first stock source. Nested/path-scoped files, `AGENTS.override.md`,
alternate names, global/home files, imports, and AGENTS.md caching remain
deferred. Other context sources such as time, Skills, roles, or repository maps
are not included and remain independent plugin concerns.
Broader Reference/Observation material remains directional, without placeholder
public APIs. Provider-aware projection and cache planning, token budgets,
compaction, and context preview remain deferred.
General provider/model configuration, Task Browser, and richer Session/Run UI
remain deferred. The normal product path reaches one stock Chat Session with
plugin-owned evaluated history/composer and sequential, approval-gated Runs through
experimental ChatGPT subscription auth. Single compact Chat activities and groups
open retained window-local Inspection cards with interpreted Apply Patch, Run
Command, and OpenAI provider-supplied reasoning-summary bodies. Deterministic
regression scope uses real prepared artifacts with local fake Responses for
reasoning-only activity, mixed groups, nested individual cards, independent card
controls, live evidence, and separate tool approvals, not live-provider evidence.
Hidden chain-of-thought and encrypted reasoning are never user-presented.
Reasoning deltas, compaction UI, arbitrary plugin drill-down, Source/Diff/Console navigation, terminal/PTY and
full-output views, and the broader presentation extension ecosystem remain deferred.
GitHub, cloud, recent-project/catalog selectors, persistence, and deduplication
are not implemented; application Command surfacing remains deferred.
Chat persistence, configurable permissions/profiles, steering, richer activity and
console presentation, child Session lifecycle, strategy defaults,
SCM/review integration, general whole-file overwrite, and directory/move/copy/
binary operations also remain unimplemented.

`EnvironmentRuntime` remains provisional and domain-specific, not a general
extension materialization/cache framework. Implementation should introduce only
the concrete boundaries required by working product behavior.

Windows, macOS, release packaging, plugin installation/update management,
frontend discovery, sandboxing,
current Flutter compatibility, and eval-stack modernization also remain open.
See `docs/architecture/overview.md`, ADRs 0030/0031, and the earlier ADRs they
refine rather than replace wholesale.
