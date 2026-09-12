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
Per-inference instruction-source capture and immutable context snapshots
Shared application runtime and static stock plugin composition
Typed Project selectors and minimal local-directory Project opening
Stock root-level AGENTS.md instructions
Session-authorized Environment read/search and bounded text-file mutation
Foreground process execution and model-facing command validation
```

Interpreted Flutter frontends and locally compiled AOT backends run through one
shared child Dart runtime with generated typed clients, codecs, backend
dispatch, and deterministic provider selection. `workspace_demo` remains the
Phase I/II regression fixture, `resource_inspector` remains the Phase III
multi-provider capability fixture, and `scripted_model` remains deterministic
model-provider/transport regression infrastructure. These are internal
reference fixtures, not product UI or product-domain definitions.

Plugin installation/discovery, general production plugin activation, packaging,
permissions, sandboxing, and general third-party extension APIs are not yet
implemented.

Normal desktop startup synchronously constructs one application-owned
`AdeleRuntime` in `app/lib/core/adele_runtime.dart`. It owns the capability and
extension registries, in-memory product store, generated lifecycle coordinator,
inference context composer, retained Chat plugin, and six static in-process
activations: Chat, AGENTS.md, Filesystem Tools, Search Tools, Command Tools, and
Local Directory Project Selector. The reduced smoke composition omits only
Command Tools. The shell initially displays `No Project is open`. Startup does
not launch providers, compile AOT artifacts, load credentials, create a Project, Task,
Environment, or Session, build a tool catalog, or start a Run. Desktop exit awaits
runtime close; detach/dispose initiate cleanup and failures are reported. Owned
activations close in reverse order, attempting all before reporting the first
failure. Self-hosting owns an instance of this same runtime and adds its explicit
provider, product lifecycle, and Run setup rather than duplicating the host graph.

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
URI), source URI, `Project is open`, and `No Tasks yet`. No display metadata is
added to `adele_product`, which remains unchanged and independent. This is not a
Task Browser, Command surface, Project catalog, persistence, or deduplication
system, and opening starts no Task, Environment, Session, provider, model, Git,
tool catalog, or Run work. See `app/README.md` for URI normalization, exact-binding
validation, the headless import boundary, and native validation status.

ADELE separates provider-neutral Run/model/tool/policy/approval mechanics from
strategy-owned Session meaning. `adele_product` owns the final immutable
`Session(id, taskId, strategyId)` and semantic `OrchestrationStrategyId`; public
pure-Dart `adele_orchestration` supplies executable strategy contributions and
exact-binding resolution over the existing extension registry. Session creation
requires an existing Task and one current matching strategy, validates the
Task's primary or explicitly selected same-Task Environment, and atomically
publishes the Session and separate Environment authority in memory.

The first executable stock strategy is headless `chat_strategy_plugin` under
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
This is executable plugin composition, not production plugin discovery or Chat UI.

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
typed model-tool, orchestration-strategy, inference-context-source, and Project
selector points are implemented; broader recursive composition and plugin-facing
UI APIs remain deferred. The Project buttons are temporary host presentation,
not a chooser framework or application Commands.

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

The repository development command above is unrelated to ADELE's future
application-level Command Palette/keybinding subsystem described by the
extension architecture.

## Repository

```text
app/                         single Flutter desktop application
packages/plugin_api/         adele_plugin_api (experimental public)
packages/core_extensions/    adele_core_extensions narrow core-owned contracts
packages/contract/           adele_contract (experimental public)
packages/contract_codegen/   contract_codegen (internal, pure Dart)
packages/model_provider/     adele_model_provider (experimental public)
packages/model_tool/         adele_model_tool public contribution/execution API
packages/capabilities/       adele_capabilities (experimental public)
packages/product/            adele_product canonical product identities/values
packages/orchestration/      adele_orchestration strategies/execution/context API
packages/environment/        adele_environment provider/filesystem contract
packages/plugin_runtime/     plugin_runtime (internal, pure Dart)
packages/plugin_backend_host/ shared backend host (internal, pure Dart)
packages/plugin_builder/     plugin_builder (internal, pure Dart)
packages/agent_kernel/       agent_kernel (internal, pure Dart)
plugins/workspace_demo/      internal source-plugin reference fixture
plugins/resource_inspector/  Phase III two-provider capability fixture
plugins/scripted_model/      deterministic ModelProvider/transport fixture
plugins/openai/              real OpenAI ModelProvider; ChatGPT route experimental
plugins/filesystem_tools/    stock Session-authorized text-file tools
plugins/search_tools/        stock Session-authorized literal Search tool
plugins/command_tools/       stock Session-authorized foreground Command tool
plugins/chat_strategy/       stock headless Chat strategy and in-memory history
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
the implicit static stock composition, not a profile API.

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
Normal provider/model configuration, Task/Environment establishment, Task Browser,
Chat UI, and the Run product flow remain deferred despite B1 Project opening,
shared runtime composition, and the headless self-hosting path. GitHub, cloud,
recent-project/catalog selectors, persistence, and deduplication are not
implemented; application Command surfacing remains deferred.
Chat persistence, profiles, child Session lifecycle, strategy defaults,
SCM/review integration, general whole-file overwrite, and directory/move/copy/
binary operations also remain unimplemented.

`EnvironmentRuntime` remains provisional and domain-specific, not a general
extension materialization/cache framework. Implementation should introduce only
the concrete boundaries required by working product behavior.

Windows, macOS, release packaging, plugin packaging/discovery, sandboxing,
current Flutter compatibility, and eval-stack modernization also remain open.
See `docs/architecture/overview.md`, ADRs 0030/0031, and the earlier ADRs they
refine rather than replace wholesale.
