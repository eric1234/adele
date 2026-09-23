# ADELE Desktop

Role: Local application/composition map

`adele_desktop` is ADELE's private Flutter desktop composition root. It owns
integration and hosting that require application authority or Flutter/native
composition, not the semantic definitions of plugins, product identities,
strategies, tools, providers, or canonical plugin-owned state.

Source/tests define current behavior. This README maps local ownership,
entrypoints, important invariants, and focused validation; it is not another
canonical architecture document. Start with the [documentation policy](../docs/README.md)
and [architecture overview](../docs/architecture/overview.md) for cross-system context.

## Ownership

| Application owns | Deliberately does not own / follow the owner |
| --- | --- |
| Construction of the shared `AdeleRuntime` and its registries/store/coordinators | Generic Extension Point semantics: [plugin system](../docs/architecture/plugin-system.md), [plugin API](../packages/plugin_api/README.md). |
| Normal prepared backend bootstrap and window-owned frontend activation | Source preparation/build semantics: [plugin layout](../docs/architecture/plugin-layout.md), [plugin builder](../packages/plugin_builder/README.md); backend hosting: [plugin runtime](../packages/plugin_runtime/README.md). |
| App-native implementations of public bridges, including the directory picker | Public presentation/bridge contracts: [UI](../packages/ui/README.md); local-path selection semantics: [Local Directory selector](../plugins/local_directory_project_selector/README.md). |
| Product lifecycle composition and publication | Product identity definitions: [product model](../docs/architecture/product-model.md), [product package](../packages/product/README.md); provider behavior: [Environment](../packages/environment/README.md), [Git Environment](../plugins/git_environment/README.md). |
| Session execution hosting and provider/tool/context adaptation | Public [orchestration](../packages/orchestration/README.md), [model-tool](../packages/model_tool/), and [model-provider](../packages/model_provider/) contracts; generic mechanics in [agent kernel](../packages/agent_kernel/README.md). |
| Host policy, exact-invocation approval, and Run activity projection | Concrete strategy sequencing, conversation state/history, and grouping: [Chat](../plugins/chat_strategy/README.md). |
| Generic shell, Session/Inspection hosting, and application-local window state | Tool behavior and bespoke cards: [Filesystem](../plugins/filesystem_tools/README.md), [Command](../plugins/command_tools/README.md), and [Search source](../plugins/search_tools/). |
| Temporary source-checkout provider/model selection | OpenAI protocol, credentials, and provider algorithms: [OpenAI backend](../plugins/openai/packages/backend/README.md). |
| Current in-memory composition and fixed startup participation | General installation/Profile management and durable product/plugin storage, which are not implemented: [profiles and configuration](../docs/architecture/profiles-and-configuration.md). |

## Normal startup

[`main.dart`](lib/main.dart) launches `AdeleApplication` in
[`application.dart`](lib/application.dart). Application State constructs one
`AdeleRuntime` synchronously, retains it across rebuilds, and explicitly starts
asynchronous plugin bootstrap.

```text
Flutter application
    -> construct AdeleRuntime
    -> discover shared prepared installation catalog
         +-> notify window -> activate prepared frontends -> ExtensionRegistry
         +-> start valid prepared backends
                  -> ready advertisements
                  -> existing capability/extension registries
    -> window / product / Session interaction
```

`AdeleRuntime()` statically activates zero stock plugins. Construction is
provider-free: it starts no backend host or compiler, loads no credentials, and
creates no Project, Task, Environment, Session, or Run. It shares one
`CapabilityRegistry`, `ExtensionRegistry`, and `InMemoryProductStore` with
`ProductLifecycleCoordinator.generated`, `InferenceContextComposer`, and backend
bootstrap.

Normal startup consumes prepared artifacts, never plugin source. Backend and
frontend availability are independent, but both owners consume the same catalog
snapshot. Missing plugin functionality remains unavailable without app-native
stock substitutes. Backend registrations enter the same generic registries used
by lifecycle and execution composition; installation presence alone grants none.

### Normal backend startup

[`ApplicationPluginBootstrap`](lib/core/application_plugin_bootstrap.dart)
discovers installations through `PreparedPluginCatalog.discover` and publishes the
catalog before starting backends. It needs a shared `PluginBackendHost` only when
at least one valid backend component exists. Empty/unconfigured composition can
settle without a child process, including with frontend-only installations.

The bootstrap accepts generic deployment locations and an optional PluginId-to-argv
file. It forwards opaque arguments with `startupArgumentsOnly: true`; neither the
bootstrap nor shared host interprets provider credentials or stock configuration.
Ready advertisements are adapted by `PluginBackendActivation.registerAdvertised`
and `createRemoteExtensionAdapters` into existing registries, not an app-specific
stock activation table.

The bootstrap owns per-backend startup rollback, termination observation, and
registration retirement. Local startup failures are isolated to that attempt;
shared-host failure affects all its backends. `ready` means bootstrap settled,
not that every component or a model is usable. Close waits for startup, retires
owned registrations before closing connections, then closes the shared host.
It does not retire registrations owned by external callers.

| Compile-time define | Deployment location |
| --- | --- |
| `ADELE_DARTAOTRUNTIME_EXECUTABLE` | Matched SDK runtime executable. |
| `ADELE_BACKEND_HOST_ARTIFACT` | Prepared shared-host AOT snapshot. |
| `ADELE_PLUGIN_INSTALLATION_ROOT` | Prepared installation root. |
| `ADELE_PLUGIN_STARTUP_ARGUMENTS_FILE` | Optional generic startup-argv file. |

Exact formats and transport belong to [plugin layout](../docs/architecture/plugin-layout.md),
[runtime catalog/startup documentation](../packages/plugin_runtime/README.md), and
[contracts and capabilities](../docs/architecture/contracts-and-capabilities.md).
The [bootstrap tests](test/core/application_plugin_bootstrap_test.dart) and
[real-host integration](test/core/normal_task_git_integration_test.dart) map local
ownership and failure boundaries.

### Prepared frontend activation

Window-owned [`ApplicationFrontendBootstrap`](lib/frontend/application_frontend_bootstrap.dart)
uses that same catalog and the runtime's existing `ExtensionRegistry`, without
waiting for backend readiness. Data-only prepared descriptors identify supported
presentation and behavioral entrypoints. `InstalledFrontendActivation` owns each
independent generation's registrations; [`PreparedFrontend`](lib/frontend/prepared_frontend.dart)
retains prepared bytes and supplies interpreted execution/presentation.

The app implements native bridges when authority is required, while public
semantics remain in [UI](../packages/ui/README.md). Component activation and
per-view failures have different scopes: successful registration is not proof that
every view will render. A missing/failed frontend does not invalidate canonical
product objects or its sibling backend.

Retirement closes exact owned registrations and revokes captured factories and
bridges, never removing or retargeting a replacement generation. Hosts observe
binding liveness and dispose ordinary retired views. During application exit,
inert display subtrees can remain mounted while work drains; detach/dispose
releases them. This is window cleanup behavior, not plugin state persistence.
Descriptor details belong to [plugin layout](../docs/architecture/plugin-layout.md#prepared-frontend-descriptors)
and [plugin runtime](../packages/plugin_runtime/README.md#prepared-catalog);
concrete frontend behavior belongs to each plugin.

<a id="prepared-chat-frontend"></a>
### Prepared frontend artifacts

Source-checkout EVC compilation lives under `tool/`, not the runtime import graph.
[`prepareDesktopFrontendArtifacts`](../tools/frontend_artifacts.dart) chooses the
compiler harnesses; [`stock_frontend_descriptors.dart`](../tools/stock_frontend_descriptors.dart)
is the stock build-side descriptor source. Flutter/eval compilation is development
infrastructure, not on-start compilation or a plugin installer.

| Harness under `app/` | Build-time inputs in addition to `ADELE_REPOSITORY_ROOT` |
| --- | --- |
| [`tool/compile_chat_frontend.dart`](tool/compile_chat_frontend.dart) | `ADELE_CHAT_FRONTEND_OUTPUT` |
| [`tool/compile_local_directory_frontend.dart`](tool/compile_local_directory_frontend.dart) | `ADELE_LOCAL_DIRECTORY_FRONTEND_OUTPUT` |
| [`tool/compile_tool_inspection_frontends.dart`](tool/compile_tool_inspection_frontends.dart) | `ADELE_TOOL_INSPECTION_FRONTEND` (`filesystem` or `command`), `ADELE_TOOL_INSPECTION_FRONTEND_OUTPUT` |
| [`tool/compile_openai_activity_frontend.dart`](tool/compile_openai_activity_frontend.dart) | `ADELE_OPENAI_ACTIVITY_FRONTEND_OUTPUT` |

For standalone preparation, bootstrap/generate first, supply those environment
inputs and an existing output parent, then run the selected harness from `app/`
with `flutter test --no-pub --concurrency 1 <harness>`. These inputs are not runtime
artifact defines. Normally use repository `run linux` / `build linux` instead.

[`prepareDesktopPluginDefines`](../tools/backend_artifacts.dart) prepares backends,
frontends, and a fresh installation root before launching Flutter on Linux. Builds
embed provisional absolute SDK/artifact/startup-file paths and depend on those
files remaining available on the checkout machine. Other desktop launcher targets
do not provision this normal stock deployment. See the
[toolchain](../docs/development/toolchain.md) and [plugin builder](../packages/plugin_builder/README.md)
for the broader preparation model, not portable release packaging.

### ChatGPT source-checkout configuration

Normal application composition currently selects
`dev.adele.openai.chatgpt-experimental`; it has no API-key provider selector.
API-key and multiple configured contexts remain available to other development
consumers. This launcher/backend-startup seam and app model choice are temporary,
not the [Profile/settings architecture](../docs/architecture/profiles-and-configuration.md).

Set backend configuration before invoking the Linux repository launcher. It
snapshots references/public options into the startup-argv file, not tokens or
credential contents. **Model selection is different:**
[`StockChatGptConfiguration.fromEnvironment`](lib/plugins/temporary_chatgpt_selection.dart)
reads the app process environment during initialization. A model override supplied
only while building is not embedded; supply it when launching the built app too.

| Environment variable | Current use |
| --- | --- |
| `ADELE_OPENAI_CHATGPT_CREDENTIAL_FILE` | Credential-store reference; use an absolute path. No reference means no normal model capability. |
| `ADELE_OPENAI_CHATGPT_MODEL` | App model selection; missing/blank defaults to `gpt-6-astra`. |
| `ADELE_OPENAI_CHATGPT_CLIENT_ID` | Optional public OAuth client ID; omission selects the experimental Codex-client opt-in. |
| `ADELE_OPENAI_CHATGPT_INSTANCE_ID` | Optional configured credential instance; backend default `development-chatgpt`. |
| `ADELE_OPENAI_CHATGPT_OAUTH_ISSUER` | Optional issuer override. |
| `ADELE_OPENAI_CHATGPT_REDIRECT_URI` | Optional OAuth redirect override. |
| `ADELE_OPENAI_CHATGPT_ENDPOINT` | Optional experimental Responses endpoint override. |

The launcher supplies `--chatgpt-only`. Normal bootstrap's argv-only mode also
prevents OpenAI from exposing an inherited API-key provider when startup arguments
are absent. No valid selected provider context means unavailable, not fallback.
A configured file reference does not prove usable credentials: the backend can
advertise the provider before invocation discovers credential failure. That failure
does not invalidate the Project, Task, Environment, or Session.

The OpenAI backend interprets credentials, OAuth options, and endpoints. Normal
startup performs no browser login and adds no account UI or secure-storage claim.
Manual login is available after bootstrap through
`dart run plugins/openai/packages/backend/bin/openai_chatgpt_development.dart login`
from the repository root, with the credential-file variable above. Follow the
[OpenAI backend README](../plugins/openai/packages/backend/README.md) and
[ADR 0028](../docs/adr/0028-experimental-chatgpt-openai-configured-instance.md)
for credential semantics and experimental support limits.

## Current product shell

The current, limited normal path is:

```text
open Project
    -> create Task + primary Environment
    -> create/present Session
    -> submit/schedule Run
    -> observe / approve / inspect execution
```

`AdeleApplication` coordinates these actions; `AdeleShell` presents their results.
The presented Project/Task/Environment/Session and Inspection arrangement are
window-local state, not new product identities or a final workbench architecture.
The [product model](../docs/architecture/product-model.md) owns their semantics.

<a id="b1-project-opening"></a>
### Project opening

The shell renders live `ProjectSelectorContribution` actions from the existing
registry. The stock [Local Directory selector](../plugins/local_directory_project_selector/README.md)
is a prepared interpreted frontend, not an app-linked implementation. Its evaluated
`selectProject` calls the public [directory-picker bridge](../packages/ui/README.md#interpreted-bridges).
The app's [`DirectoryPickerBridge`](lib/frontend/directory_picker_bridge.dart)
owns native `file_selector.getDirectoryPath`; the evaluated frontend owns lexical
local-path normalization into a `file:` URI. The app revalidates the selected
binding and passes the URI to lifecycle to create the canonical Project.

Cancellation creates nothing; failures are local and do not try another selector.
Pending selection blocks duplicate actions. Retirement or window close prevents
late results from publishing a Project, without forcibly closing an open OS dialog
or migrating the operation. Selection uses no selector backend RPC, AOT selector,
or Session/Environment authority. Opening a directory does not validate it as a
Git source; that belongs to later Environment establishment.

Native integration includes the minimum macOS user-selected read-only entitlement,
`com.apple.security.files.user-selected.read-only`, in both
[Debug/Profile](macos/Runner/DebugProfile.entitlements) and
[Release](macos/Runner/Release.entitlements). Generated
[Linux](linux/flutter/generated_plugin_registrant.cc),
[macOS](macos/Flutter/GeneratedPluginRegistrant.swift), and
[Windows](windows/flutter/generated_plugin_registrant.cc) registrants wire the
native picker plugin. These files establish wiring, not platform feature parity.

Recorded validation includes successful Linux profile builds, including after the
interpreted-selector migration. Interactive OS picking and macOS/Windows builds
have not been validated in the maintained record. Evaluated tests use a fake
native picker; Windows path-conversion cases are not Windows integration proof.
See [Project opening tests](test/project_opening_test.dart),
[bridge tests](test/directory_picker_bridge_test.dart), and the plugin's own tests.

<a id="b2-task-and-primary-environment"></a>
### Task and primary Environment

The private `TaskTitleForm` accepts a title. The application trims/rejects blank
input, guards pending submission, and calls `ProductLifecycleCoordinator.createTask`
without a Git-specific provider selection. Provider resolution belongs to lifecycle
and the capability registry; the selected provider owns source suitability and
establishment.

Only establishment success publishes the Task and finalized primary Environment.
The UI presents returned canonical values and exact live availability, without
decoding opaque provider state or restoring a binding just to render status.
Successful publication survives later provider retirement even when its retained
materialization becomes unavailable. See [lifecycle source](lib/core/product_lifecycle.dart),
[lifecycle tests](test/core/product_lifecycle_test.dart), [Task UI tests](test/task_creation_test.dart),
and the [Environment](../packages/environment/README.md) / [Git provider](../plugins/git_environment/README.md) owners.

### Session lifecycle

Session creation UI is strategy-neutral: it offers usable contributed presentation
names and strategy identities, not a compiled Chat choice. `PreparedSessionHost`
validates presentation/strategy selection and required owning-backend affinity;
lifecycle validates the semantic strategy and same-Task Environment relationship
before publishing the Session and its separate authority.

[`SessionPresentationHost`](lib/ui/session/session_presentation_host.dart) resolves
the canonical Session through public [UI](../packages/ui/README.md) contracts.
Missing, ambiguous, retired, or failed presentation does not redefine Session
identity. Model availability is not a Session-creation requirement. Where required,
the host validates the strategy's exact owning-backend origin and retains that
selection; a later Run does not silently refresh a stale pinned selection.

The window presents one Session and then hides further Task/Session creation;
before that, another Task can replace the presented Task without navigation back.
This is a temporary shell constraint, not the canonical Session model. Follow
[product semantics](../docs/architecture/product-model.md#session),
[orchestration](../packages/orchestration/README.md), and [Chat](../plugins/chat_strategy/README.md)
for the respective owners.

### Normal Chat interaction

With its prepared contributions available, Chat is the current stock Session.
The Chat backend owns conversation state/history and strategy sequencing; its
interpreted frontend owns history/composer presentation and activity grouping.
The app owns generic scheduling, Run hosting, provider/tool/context composition,
execution status, policy, and approvals, not a second Chat implementation.

`SessionExecutionController` resolves the currently selected provider binding and
builds a Session-authorized tool catalog for each new Run. Continuations reuse
that provider and catalog; each inference snapshots tools and captures current
instruction sources. The retained strategy selection passes into
`createSessionOrchestrationRun`. Detailed capture/continuation semantics belong to
the [execution model](../docs/architecture/execution-model.md) and [Chat README](../plugins/chat_strategy/README.md).

Current `ApprovalGatedToolPolicy` allows a single certain source-read effect, asks
for a single certain source-mutation effect or a single process-execution effect,
and denies other combinations. Approvals are host-owned exact-invocation
interruptions. Common host UI offers `Allow once` / `Deny`, rejects stale/duplicate
decisions, and applies display-safety checks without changing executed arguments.
Approval neither overrides domain preconditions nor supplies an OS sandbox.

Close blocks new actions and drains accepted Task establishment and Run advancement
before backend teardown. A quiescent waiting Run is abandoned without resolving
its approval or executing the pending invocation. Cleanup attempts continue after
failure; close is resource cleanup, not general cancellation or a bounded deadline.
No durable history, general Session browser, or Profile system is implied.

## Orchestration hosting

`createSessionOrchestrationRun` looks up the canonical Session, resolves its stored
strategy or validates a supplied exact selection in the lifecycle's registry,
then materializes it against `KernelOrchestrationHost`. The returned
`SessionOrchestrationRun` owns advancement and execution cleanup.

| Application adapter | Local responsibility |
| --- | --- |
| `KernelOrchestrationHost` | Adapt public strategy operations to internal Run/model/tool/policy mechanics and retain exact proposal/approval provenance. |
| `ModelProviderCapabilityAdapter` | Lower provider-neutral requests and adapt generated provider transport; retain opaque native evidence without provider-specific parsing. |
| `buildModelToolCatalogForSession`, `SessionModelToolHostContext` | Compose contributed tools and lazily capture coherent facets from lifecycle-owned Session Environment authority. |
| `SessionInferenceContextSourceContext` | Supply a fresh per-inference context with read-only Environment access to the public context composer. |
| Remote strategy/tool/context adapters | Adapt advertised extension points and operation-scoped host services, without stock-plugin dispatch. |
| `SessionOrchestrationRun.close`, `closeResources` | Drain owned work and release resources; do not resolve abandoned approvals or undo external effects. |

Binding validation is boundary-specific, not an eager retirement-to-failure signal.
Native and remote paths are not fully symmetric: the native Run wrapper does not
itself enforce the remote settle-or-wait check, and native Environment read facets
do not universally postvalidate after awaiting a read. Do not infer those stronger
guarantees from remote-adapter coverage. The authority/host tests below capture the
current boundaries; this map does not redefine them.

Public semantics belong to [orchestration](../packages/orchestration/README.md),
[execution architecture](../docs/architecture/execution-model.md), and
[contracts/authority](../docs/architecture/contracts-and-capabilities.md).
Internal mechanics belong to [agent kernel](../packages/agent_kernel/README.md),
not plugin APIs. Primary application paths are in the source map below.

## Activity Inspection

`RunActivityProjection` exposes read-only public execution snapshots. The execution
controller observes and retains activity for current presentation; that is neither
canonical Chat history nor durable Run storage. The full read model can retain
opaque native evidence, while frontend bridges expose narrower presentation data.

Window-owned `WindowInspection` and `InspectionHost` own selection, card stack,
collapse/dismiss state, common chrome, and inspect interaction. Generic compact and
rich hosts resolve contributions by their public semantic identity and retain
exact presenter bindings. Retirement/failure affects the view, not execution;
replacements require fresh resolution. Compact roles can show factual host content
without a custom presenter; this is not a native implementation of plugin behavior.

Common execution/approval UI remains host-owned. Plugins interpret and render
tool/provider-specific fields; generic app hosts must not do so. Follow
[UI](../packages/ui/README.md), [execution activity](../packages/orchestration/README.md#live-run-activity),
[Chat grouping](../plugins/chat_strategy/README.md), and
[Filesystem](../plugins/filesystem_tools/README.md) / [Command](../plugins/command_tools/README.md)
cards rather than duplicating their schemas here.

### Model-native activity presentation

The model adapter carries provider-supplied safe presentation separately from raw
native replay evidence. Generic hosts resolve compact/rich contributions by exact
presentation kind. `ModelNativeActivityBridge` passes safe presentation data into
the interpreted frontend, not raw/encrypted native replay or execution authority.
Missing rich presentation does not erase safe activity or alter replay.

For OpenAI, [Contract](../plugins/openai/packages/contract/README.md) owns shared
identities/schema, [Backend](../plugins/openai/packages/backend/README.md) owns
classification/projection, and [Frontend](../plugins/openai/packages/frontend/README.md)
owns rendering. The app does not parse OpenAI fields or recover hidden reasoning.

## Dependencies

Production `dependencies` in [`pubspec.yaml`](pubspec.yaml) and imports/exports
under `lib/` contain no package under `plugins/**`, including plugin contracts.
The app may use public ADELE APIs, internal generic host packages, Flutter, and
generic native/host libraries such as `file_selector` and eval runtime libraries.

Plugin-aware tests, source preparation, and self-hosting use development dependencies
outside the normal runtime graph. Source/build tooling is not a normal runtime
dependency. The temporary provider identity/model seam grants no plugin-import
exception. Follow [dependency rules](../docs/architecture/dependency-rules.md);
the [application boundary test](../test/tools/app_plugin_boundary_test.dart) checks
production manifest dependencies and import/export directives.

## Developer Self-Hosting Runner

[`bin/adele_self_host.dart`](bin/adele_self_host.dart) is the SDK-only launcher for
headless developer source-development runs, not a final product CLI. It regenerates
native contracts before starting [`tool/self_hosting/cli.dart`](tool/self_hosting/cli.dart).
The runner currently requires Linux x64, executable `/usr/bin/setsid` or
`/bin/setsid`, and a clean bootstrapped checkout.

| Runner provider preset | Required configuration |
| --- | --- |
| `chatgpt` (default) | `ADELE_OPENAI_CHATGPT_CREDENTIAL_FILE`; optional `ADELE_OPENAI_CHATGPT_TEST_MODEL`, default `gpt-6-astra`, and the OAuth/endpoint options above. Masks an inherited API key. |
| `api-key` | `OPENAI_API_KEY` and `ADELE_OPENAI_TEST_MODEL`; optional `ADELE_OPENAI_ENDPOINT`. |

These `--profile` choices are runner presets, not ADELE Profiles. They resolve the
selected provider explicitly without fallback. `ADELE_OPENAI_CHATGPT_MODEL` does
not select the self-hosting model. From the repository root, with credentials
configured:

```sh
dart run app/bin/adele_self_host.dart \
  --prompt-file /absolute/path/to/prompt.md \
  --instructions-file /absolute/path/to/instructions.md \
  --task-title "Implement the focused development task" \
  --max-model-invocations 40 \
  --output-dir .dart_tool/adele/self-hosting
```

All five shown options are required; `40` is an example, not a default. Output must
be outside the launching checkout or Git-ignored. Each invocation creates a unique
run directory, compiles fresh AOT artifacts, clones exact launching HEAD without a
retained origin, and establishes a distinct Git Task worktree and Chat Session.
The runner uses an allow policy, not the normal window's approval UI. This is
source-layout isolation, not a command sandbox.

`DevelopmentSelfHostingTopology` owns an `AdeleRuntime` and uses the same remote
plugin/execution paths, but explicitly starts its own host/artifacts rather than
consuming the normal installation catalog. It uses a known Project source URI;
there is no frontend bootstrap, EVC, or native picker dependency.

The run directory retains Project/Task source, `manifest.json`, `journal.json`,
`summary.json`, `summary.md`, `runner.log`, and `git/` evidence after success or
failure. Teardown removes transient `.artifacts`; it does not automatically remove
retained source, commit, push, or open a PR. Runner/topology/report owners live in
[`tool/self_hosting/`](tool/self_hosting/); deterministic validation is listed below.

## Focused validation

Use the pinned [development toolchain](../docs/development/toolchain.md) and
[repository workflow](../docs/development/README.md). From the repository root:

```sh
dart tools/adele.dart bootstrap
dart tools/adele.dart test --target adele_desktop
dart tools/adele.dart test --target adele_tools
dart test test/tools/app_plugin_boundary_test.dart
```

`dart tools/adele.dart analyze` regenerates and analyzes all maintained targets;
there is no `analyze --target` option. For app-only analysis after bootstrap/current
generation, run `flutter analyze --no-pub --fatal-infos` from `app/`. For focused
tests, run `flutter test --no-pub <test-path> ...` there, selecting from this map:

| Changed boundary | Representative app test paths |
| --- | --- |
| Zero-plugin construction/shell | [`test/core/adele_runtime_test.dart`](test/core/adele_runtime_test.dart), [`test/application_test.dart`](test/application_test.dart) |
| Backend/frontend startup | [`test/core/application_plugin_bootstrap_test.dart`](test/core/application_plugin_bootstrap_test.dart), [`test/prepared_frontend_activation_test.dart`](test/prepared_frontend_activation_test.dart), [`test/prepared_frontend_failure_test.dart`](test/prepared_frontend_failure_test.dart) |
| Project/native bridge and Task/Environment lifecycle | [`test/project_opening_test.dart`](test/project_opening_test.dart), [`test/directory_picker_bridge_test.dart`](test/directory_picker_bridge_test.dart), [`test/task_creation_test.dart`](test/task_creation_test.dart), [`test/core/product_lifecycle_test.dart`](test/core/product_lifecycle_test.dart) |
| Session presentation/Run/approval | [`test/session_presentation_host_test.dart`](test/session_presentation_host_test.dart), [`test/session_execution_test.dart`](test/session_execution_test.dart), [`test/core/approval_gated_tool_policy_test.dart`](test/core/approval_gated_tool_policy_test.dart) |
| Execution adaptation/authority | [`test/core/orchestration_host_test.dart`](test/core/orchestration_host_test.dart), [`test/core/orchestration_authority_test.dart`](test/core/orchestration_authority_test.dart), [`test/core/model_tool_host_test.dart`](test/core/model_tool_host_test.dart), [`test/core/remote_inference_context_integration_test.dart`](test/core/remote_inference_context_integration_test.dart) |
| Activity/Inspection | [`test/core/run_activity_projection_test.dart`](test/core/run_activity_projection_test.dart), [`test/inspection_host_test.dart`](test/inspection_host_test.dart), [`test/inspection_stack_test.dart`](test/inspection_stack_test.dart), [`test/openai_activity_frontend_eval_test.dart`](test/openai_activity_frontend_eval_test.dart) |
| Real prepared normal composition, no live model | [`test/core/normal_task_git_integration_test.dart`](test/core/normal_task_git_integration_test.dart), [`test/core/normal_chatgpt_run_integration_test.dart`](test/core/normal_chatgpt_run_integration_test.dart) (local fake SSE/credentials and native picker) |
| Self-hosting determinism | [`test/development/agent/development_self_hosting_test.dart`](test/development/agent/development_self_hosting_test.dart), [`test/development/agent/environment_read_agent_integration_test.dart`](test/development/agent/environment_read_agent_integration_test.dart) |

Checkout preparation and plain-Dart self-hosting CLI checks also live in
[`backend_artifacts_test.dart`](../test/tools/backend_artifacts_test.dart),
[`adele_test.dart`](../test/tools/adele_test.dart), and
[`self_hosting_cli_test.dart`](../test/tools/self_hosting_cli_test.dart) in the tools target.
Native contract outputs are ignored local artifacts; direct Flutter commands do
not regenerate them. Use `dart tools/adele.dart generate` after declaration changes.

For native Linux packaging use `dart tools/adele.dart build linux --profile`.
The separate `dart tools/adele.dart smoke linux --profile` exercises
[`tool/development_runtime_smoke/main.dart`](tool/development_runtime_smoke/main.dart),
not normal product picking. Configure its existing directories through
`ADELE_DEVELOPMENT_REPOSITORY_ROOT`, `ADELE_DEVELOPMENT_PLUGIN_DIRECTORY`, and
`ADELE_DEVELOPMENT_DIRECTORY` as in the [smoke workflow](../.github/workflows/runtime-smoke.yaml).
Neither a build nor the reference-fixture smoke proves interactive native picking.

### Live tests

Live tests require explicit opt-in (`1`) and may incur provider charges or consume
subscription limits. Normal CI discovers but skips these cases because it supplies
neither gates nor credentials; `--ci` is not an environment-scrubbing mechanism.

| App case | Enable variable | Provider / purpose |
| --- | --- | --- |
| [`openai_source_coding_live_test.dart`](test/development/agent/openai_source_coding_live_test.dart) | `ADELE_OPENAI_SOURCE_CODING_LIVE_TEST` | API key; search/read and continuation. |
| [`openai_source_mutation_live_test.dart`](test/development/agent/openai_source_mutation_live_test.dart) | `ADELE_OPENAI_SOURCE_MUTATION_LIVE_TEST` | API key; read/patch and continuation. |
| API-key case in [`openai_source_validation_live_test.dart`](test/development/agent/openai_source_validation_live_test.dart) | `ADELE_OPENAI_SOURCE_VALIDATION_LIVE_TEST` | API key; read/patch/direct-argv validation. |
| [`chatgpt_source_coding_live_test.dart`](test/development/agent/chatgpt_source_coding_live_test.dart) | `ADELE_OPENAI_CHATGPT_LIVE_TEST` | ChatGPT; search/read and continuation. |
| ChatGPT case in [`openai_source_validation_live_test.dart`](test/development/agent/openai_source_validation_live_test.dart) | `ADELE_OPENAI_CHATGPT_SOURCE_VALIDATION_LIVE_TEST` | ChatGPT; read/patch/direct-argv validation. |

API-key cases require `OPENAI_API_KEY` and `ADELE_OPENAI_TEST_MODEL`. ChatGPT cases
require `ADELE_OPENAI_CHATGPT_CREDENTIAL_FILE`, honor optional configuration above,
and use `ADELE_OPENAI_CHATGPT_TEST_MODEL` (default `gpt-6-astra`). Command-validation
cases require Linux x64 process support; both currently contain a stale catalog-order
assertion before provider activation. This table maps gates/purpose, not live success.

Provider-only smokes belong to the [OpenAI backend](../plugins/openai/packages/backend/README.md):
`ADELE_OPENAI_LIVE_TEST=1` enables its API-key case; the shared
`ADELE_OPENAI_CHATGPT_LIVE_TEST=1` also enables its ChatGPT case when that suite runs.

## Current limits

The app has no durable product/Chat persistence, Task Browser/general Session
navigation, or general Profile/plugin-management UI. Current provider selection is
the source-checkout seam above, not finished settings. Intended UX belongs to
[product direction](../docs/product/README.md); future technical work belongs to
[technical direction](../docs/direction/README.md) and
[profiles architecture](../docs/architecture/profiles-and-configuration.md), not a
repository-wide deferred-feature ledger here.

## Source map

| Concern | Primary application anchors |
| --- | --- |
| Entry/window composition | [`lib/main.dart`](lib/main.dart), [`lib/application.dart`](lib/application.dart): `AdeleApplication` |
| Runtime construction | [`lib/core/adele_runtime.dart`](lib/core/adele_runtime.dart): `AdeleRuntime` |
| Backend bootstrap | [`lib/core/application_plugin_bootstrap.dart`](lib/core/application_plugin_bootstrap.dart): `ApplicationPluginBootstrap` |
| Frontend generations/activation | [`lib/frontend/application_frontend_bootstrap.dart`](lib/frontend/application_frontend_bootstrap.dart), [`lib/frontend/prepared_frontend.dart`](lib/frontend/prepared_frontend.dart) |
| Product lifecycle/Environment authority | [`lib/core/product_lifecycle.dart`](lib/core/product_lifecycle.dart): `ProductLifecycleCoordinator`, `EnvironmentRuntime` |
| Session selection/presentation | [`lib/frontend/prepared_session_host.dart`](lib/frontend/prepared_session_host.dart), [`lib/ui/session/session_presentation_host.dart`](lib/ui/session/session_presentation_host.dart) |
| Session execution/orchestration | [`lib/ui/execution/session_execution_controller.dart`](lib/ui/execution/session_execution_controller.dart), [`lib/core/orchestration_host.dart`](lib/core/orchestration_host.dart) |
| Model-provider adaptation | [`lib/core/model_provider_host.dart`](lib/core/model_provider_host.dart): `ModelProviderCapabilityAdapter` |
| Model-tool hosting | [`lib/core/model_tool_host.dart`](lib/core/model_tool_host.dart): `buildModelToolCatalogForSession`, `SessionModelToolHostContext` |
| Inference-context hosting | [`lib/core/inference_context_host.dart`](lib/core/inference_context_host.dart): `SessionInferenceContextSourceContext` |
| Remote extension adapters | [`lib/core/remote_inference_context_host.dart`](lib/core/remote_inference_context_host.dart), [`lib/core/remote_model_tool_host.dart`](lib/core/remote_model_tool_host.dart), [`lib/core/remote_orchestration_host.dart`](lib/core/remote_orchestration_host.dart) |
| Run activity projection | [`lib/core/run_activity_projection.dart`](lib/core/run_activity_projection.dart): `RunActivityProjection` |
| Policy/common execution UI | [`lib/core/approval_gated_tool_policy.dart`](lib/core/approval_gated_tool_policy.dart), [`lib/ui/execution/`](lib/ui/execution/) |
| Project selector/native picker and shell | [`lib/frontend/directory_picker_bridge.dart`](lib/frontend/directory_picker_bridge.dart), [`lib/ui/shell/`](lib/ui/shell/), `AdeleApplication` |
| Inspection/compact hosts | [`lib/ui/inspection/`](lib/ui/inspection/), [`lib/ui/activity/`](lib/ui/activity/) |
| Temporary provider/model choice | [`lib/plugins/temporary_chatgpt_selection.dart`](lib/plugins/temporary_chatgpt_selection.dart) |
| Source-checkout frontend compilation | [`tool/`](tool/): compiler harnesses listed [above](#prepared-chat-frontend) |
| Self-hosting | [`bin/adele_self_host.dart`](bin/adele_self_host.dart), [`tool/self_hosting/`](tool/self_hosting/) |
