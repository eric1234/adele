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
| App-native implementations of public bridges, including the directory picker | Public presentation/bridge contracts: [UI](../packages/ui/README.md); local-path selection semantics: [Local Directory Project](../plugins/local_directory_project/README.md). |
| Product lifecycle composition and publication | Product identity definitions: [product model](../docs/architecture/product-model.md), [product package](../packages/product/README.md); provider behavior: [Environment](../packages/environment/README.md), [Git Environment](../plugins/git_environment/README.md). |
| Private per-Project SQLite hosting, confinement, migrations, and connection lifetime | Source semantics/backing placement: [Project provider contract](../packages/core_extensions/README.md#project-provider) and [Local Directory Project backend](../plugins/local_directory_project/packages/backend/README.md). |
| Exact-generation mediation of Session-scoped relational storage | Public [Project storage contract](../packages/project_storage/lib/adele_project_storage.dart); plugin schema/state semantics: [plugin persistence](../docs/architecture/plugin-system.md#plugin-owned-state-and-persistence). |
| Session execution hosting and provider/tool/context adaptation | Public [orchestration](../packages/orchestration/README.md), [model-tool](../packages/model_tool/), and [model-provider](../packages/model_provider/) contracts; generic mechanics in [agent kernel](../packages/agent_kernel/README.md). |
| Host policy, exact-invocation approval, Run activity projection, and terminal evidence storage | Concrete strategy sequencing, conversation state/history, and grouping: [Chat](../plugins/chat_strategy/README.md). |
| Generic shell, Session/Inspection hosting, and application-local window state | Tool behavior and bespoke cards: [Filesystem](../plugins/filesystem_tools/README.md), [Command](../plugins/command_tools/README.md), and [Search](../plugins/search_tools/README.md). |
| Temporary source-checkout provider/model selection | OpenAI protocol, credentials, and provider algorithms: [OpenAI backend](../plugins/openai/packages/backend/README.md). |
| Live in-memory product graph and fixed startup participation | General installation/Profile management and complete runtime restoration remain unimplemented: [profiles and configuration](../docs/architecture/profiles-and-configuration.md), [storage scope](../docs/architecture/product-model.md#storage-scope-and-limits). |

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
creates no Project, Task, Environment, Session, or Run.

The runtime owns one `CapabilityRegistry`, one `ExtensionRegistry`, one
`InMemoryProductStore`, and the shared `RunIdSource` used by default execution
controllers. Run ID allocation and injection follow the
[terminal history model](../docs/architecture/product-model.md#terminal-run-history).
`ProductLifecycleCoordinator.generated` receives the registries and store;
`InferenceContextComposer` uses only the shared extension registry; and
`ApplicationPluginBootstrap` uses the shared capability and extension registries.
Lifecycle additionally owns private `ProjectDatabase` instances for durable opens
and a separate map of immutable terminal snapshots; constructing the runtime does
not open a database. Lifecycle is constructed before
bootstrap so the runtime can supply the generic
`projectStorageServices(lifecycle, connection)` infrastructure factory to every
backend connection without importing stock plugins.

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

`PluginBackendHost.startPlugin` invokes `createInfrastructureServices` with the
actual connection. The resulting storage dispatcher captures connection-owned
plugin identity and exact-generation validation, not caller-selected ownership.
Bootstrap supplies the distinct infrastructure context; operation tokens do not
grant this storage service. See [infrastructure access](../docs/architecture/contracts-and-capabilities.md#generation-scoped-infrastructure-access).

The bootstrap owns per-backend startup rollback, termination observation, and
registration retirement. Local startup failures are isolated to that attempt;
shared-host failure affects all its backends. `ready` means bootstrap settled,
not that every component or a model is usable. Close waits for startup, retires
owned registrations before closing connections, then closes the shared host.
Infrastructure access is revoked on retirement/rollback before asynchronous
cleanup, as well as on stop/close/termination. The bootstrap does not retire
registrations owned by external callers.

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
| [`tool/compile_local_directory_project_frontend.dart`](tool/compile_local_directory_project_frontend.dart) | `ADELE_LOCAL_DIRECTORY_PROJECT_FRONTEND_OUTPUT` |
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
registry. The stock [Local Directory Project selector](../plugins/local_directory_project/README.md)
is a prepared interpreted frontend, not an app-linked implementation. Its evaluated
`selectProject` calls the public [directory-picker bridge](../packages/ui/README.md#interpreted-bridges).
The app's [`DirectoryPickerBridge`](lib/frontend/directory_picker_bridge.dart)
owns native `file_selector.getDirectoryPath`; the evaluated frontend owns lexical
local-path normalization into a `file:` URI. The contribution also names an
explicit Project provider; its independently prepared AOT backend validates source
semantics and describes backing placement through public `ProjectProviderService`.

The app resolves the provider before invoking the picker and validates exact
selector/provider liveness and same-installation ownership before picking, after
picking, and after provider preparation. Every prepared selector requires its
exact ready owning backend, proven by owned capability registration rather than
matching semantic IDs. See [selector ownership](../docs/architecture/plugin-system.md#project-selector-ownership).

`ProductLifecycleCoordinator.openProject` accepts the selected `sourceLocation`,
exact `ProviderBinding`, and optional host `validateSelection` callback. Private
[`ProjectDatabase`](lib/core/project_database.dart) validates source/backing paths
and symlinks, hosts `sqlite3`, and coordinates explicit SQL migrations. After final
binding validation, SQLite work is synchronous. After the identity/source commit,
`loadProductGraph` reconstructs Tasks, Environments, Sessions, their semantic
Environment associations, and terminal Run records. Separate `loadExecutionHistory`
reconstructs terminal public snapshots against those records. Lifecycle validates
both restore sets before publishing the graph through `publishRestoredProject`
and retaining activity outside the product store. Stored strategies and
Environment providers are not resolved; missing Chat or an Environment provider
does not prevent these records loading or cause plugin tables to be touched. Later
provider/frontend retirement does not invalidate the published Project.
Schema, reopen/move behavior, and failure rules have one canonical home in
[Project storage](../docs/architecture/product-model.md#project-storage).

Cancellation creates nothing; failures are local and do not try another selector.
Pending selection blocks duplicate actions. Retirement or window close prevents
late results from publishing a Project, without forcibly closing an open OS dialog
or migrating the operation. Picking uses the frontend/native bridge, while backing
preparation uses generated backend RPC; neither obtains Session/Environment
authority. Opening a directory does not validate it as a Git source; that belongs
to later Environment establishment. A headless caller can open a known source
through the same provider/lifecycle path without a frontend. `createProject` is
explicitly volatile for development/deterministic fixtures, not a durable-open fallback.

Native integration requires writable access for SQLite and its sidecars. The macOS
user-selected entitlement is `com.apple.security.files.user-selected.read-write`,
replacing picker-only read access, in both
[Debug/Profile](macos/Runner/DebugProfile.entitlements) and
[Release](macos/Runner/Release.entitlements). Generated
[Linux](linux/flutter/generated_plugin_registrant.cc),
[macOS](macos/Flutter/GeneratedPluginRegistrant.swift), and
[Windows](windows/flutter/generated_plugin_registrant.cc) registrants wire the
native picker plugin. These files establish wiring, not platform feature parity.

Interactive OS picking and macOS/Windows builds are not established by these
registrants, entitlements, or path-conversion tests. Evaluated tests use a fake
native picker; Windows path-conversion cases are not Windows integration proof.
See [Project opening tests](test/project_opening_test.dart),
[durable lifecycle tests](test/core/durable_project_lifecycle_test.dart),
[database tests](test/core/project_database_test.dart),
[bridge tests](test/directory_picker_bridge_test.dart), and the plugin's own tests.

`AdeleRuntime.close` stops new lifecycle work and joins in-flight Project opens and
database closure with backend teardown. Starting teardown allows normal connection
revocation to settle pending remote opens. Window disposal/exit still owns existing
Task establishment and Run draining; this is not general cancellation or a bounded
shutdown deadline. Closing rejects late Project publication without replacing a
provider or serializing its binding.

<a id="b2-task-and-primary-environment"></a>
### Task and primary Environment

The private `TaskTitleForm` accepts a title. The application trims/rejects blank
input, guards pending submission, and calls `ProductLifecycleCoordinator.createTask`
without a Git-specific provider selection. Provider resolution belongs to lifecycle
and the capability registry; the selected provider owns source suitability and
establishment.

For durable Projects, establishment success is followed by one SQLite transaction
that inserts the Task and finalized primary Environment. Only a successful commit
publishes them in the live store and retains their materialization. Provisional
null provider state is never persisted, and database failure never falls back to
volatile publication. External resources created by successful establishment cannot
yet be generically rolled back if the subsequent database commit fails.
Development/fixture Projects created by `createProject` remain in memory only.

The UI presents returned canonical values and exact live availability, without
decoding opaque provider state or restoring a binding just to render status.
Successful publication survives later provider retirement even when its retained
materialization becomes unavailable. See [lifecycle source](lib/core/product_lifecycle.dart),
[lifecycle tests](test/core/product_lifecycle_test.dart), [Task UI tests](test/task_creation_test.dart),
and the [Environment](../packages/environment/README.md) / [Git provider](../plugins/git_environment/README.md) owners.

Reopening loads Tasks, Environment semantic records, and opaque provider-state
snapshots without materializing them. Explicit materialization resolves the recorded
provider through a fresh binding and invokes restore. Refreshed provider state is
committed before in-memory replacement and final binding-readiness validation; a
subsequently stale binding does not roll the committed snapshot back. The stock Git
provider can restore its existing checkout after moving the complete Project,
including `.git`, `.adele/data.db`, and `.adele/worktrees`.
If a refresh commit fails after provider restore bound live state, the old core
snapshot remains; recovery may require a fresh provider generation rather than a
same-generation retry. There is no generic release/rollback contract.
The shell says `No Task selected` while its window-local Task is null, even when
restored Tasks exist; `New Task` remains available subject to provider readiness.
There is no automatic selection, Task Browser, or resume/navigation policy.
See [durable Task lifecycle tests](test/core/durable_task_environment_lifecycle_test.dart)
and [fresh-runtime Git restart/move integration](test/core/durable_task_git_integration_test.dart).

### Session lifecycle

Session creation UI is strategy-neutral: it offers usable contributed presentation
names and strategy identities, not a compiled Chat choice. `PreparedSessionHost`
validates presentation/strategy selection and required owning-backend affinity;
lifecycle validates the semantic strategy and same-Task Environment relationship
before ID allocation, revalidates the exact strategy, and checks identity conflicts.
For a durable Project, Session and authority commit in one SQL transaction before
live publication. Failure publishes neither; volatile `createProject` fixtures
remain explicit rather than becoming a database-failure fallback.

[`SessionPresentationHost`](lib/ui/session/session_presentation_host.dart) resolves
the canonical Session through public [UI](../packages/ui/README.md) contracts.
Missing, ambiguous, retired, or failed presentation does not redefine Session
identity. Model availability is not a Session-creation requirement. Where required,
the host validates the strategy's exact owning-backend origin and retains that
selection; a later Run does not silently refresh a stale pinned selection.

Reopen restores semantic Session/Environment associations, not presentations, live
facets, or executable bindings. Missing strategy resolution fails explicitly while
the restored identity remains. See [durable Session lifecycle tests](test/core/durable_session_lifecycle_test.dart).

The window presents one Session and then hides further Task/Session creation;
before that, another Task can replace the presented Task without navigation back.
This is a temporary shell constraint, not the canonical Session model. Follow
[product semantics](../docs/architecture/product-model.md#session),
[orchestration](../packages/orchestration/README.md), and [Chat](../plugins/chat_strategy/README.md)
for the respective owners.

### Plugin storage hosting

[`project_storage_host.dart`](lib/core/project_storage_host.dart) implements the
public `ProjectStorageService`. `ProjectStorageHost` uses
`ProductLifecycleCoordinator.databaseForSession` to route through Session, Task,
and the currently open Project. It revalidates the captured infrastructure context
at service entry, including after generated-dispatcher queueing. Missing/closed
storage throws; only an explicitly volatile published Session reports non-durable.

`ProjectDatabase` executes bounded queries, owner-schema initialization, and atomic
statement batches on its existing connection. The app knows no Chat schema or
history algorithm. The service exposes neither arbitrary owners/paths nor raw
SQLite handles, but does not enforce SQL table-prefix or row isolation. Follow
[the canonical storage boundary](../docs/architecture/contracts-and-capabilities.md#session-scoped-relational-storage)
for value limits and security qualifications, and
[storage-host tests](test/core/project_storage_host_test.dart) for local checks.

### Normal Chat interaction

With its prepared contributions available, Chat is the current stock Session.
The Chat backend owns conversation state/history, Draft Request, configuration,
and strategy sequencing; its interpreted frontend owns history/composer
presentation and activity grouping.
The app owns generic scheduling, Run hosting, provider/tool/context composition,
execution status, policy, and approvals, not a second Chat implementation.

The backend lazily loads initialized durable Chat history/configuration/draft
through the shared storage service; Project opening does not hydrate Chat. The host
Run can already be completed when plugin history storage fails; the
[terminal retention rules](../docs/architecture/execution-model.md#terminal-run-retention)
preserve that outcome while surfacing the error. Generation-local
cache, durable state, and transport-uncertainty boundaries live in
[plugin persistence](../docs/architecture/plugin-system.md#chat-participation)
and the [Chat README](../plugins/chat_strategy/README.md).

The current Draft Request is plain text. Chat's prepared frontend restores it and
sequentially saves coalesced edits through its own backend service. Send flushes
the latest local text, atomically submits/clears the draft, then schedules a Run.
Scheduling retry reuses the accepted entry without duplicating history. Save or
submission failure preserves visible local text; refreshing history cannot erase
newer edits. None of these semantics requires app-owned Chat storage or codecs.

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
before backend teardown. Closing a quiescent waiting Run does not resolve its
approval, execute the pending invocation, or invent a terminal record. Cleanup
attempts continue after failure; close is resource cleanup, not general
cancellation or a bounded deadline.
This does not restore live Runs/approvals or introduce a Session browser or Profile
system. [Durable Chat integration](test/core/durable_chat_session_integration_test.dart)
exercises the persistence boundary without a paid model.

## Orchestration hosting

`createSessionOrchestrationRun` looks up the canonical Session, resolves its stored
strategy or validates a supplied exact selection in the lifecycle's registry,
then materializes it against `KernelOrchestrationHost`. The returned
`SessionOrchestrationRun` owns advancement, terminal record/activity retention through
`ProductLifecycleCoordinator.retainTerminalRun`, and execution cleanup. The
[product model](../docs/architecture/product-model.md#terminal-run-history) defines
the stored record; the [execution model](../docs/architecture/execution-model.md#terminal-run-retention)
defines finalization, failure precedence, and the one-attempt boundary.
Retention supplies the explicit public snapshot and commits it with the record in
one SQL transaction before in-memory publication; the kernel journal is not a
storage format. Lifecycle exposes `runActivity` and `runActivitiesForSession` for
read-only historical lookup.

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
guarantees from remote-adapter coverage. The
[authority/host tests](../docs/development/testing.md#application-validation-map)
capture the current boundaries; this map does not redefine them.

Public semantics belong to [orchestration](../packages/orchestration/README.md),
[execution architecture](../docs/architecture/execution-model.md), and
[contracts/authority](../docs/architecture/contracts-and-capabilities.md).
Internal mechanics belong to [agent kernel](../packages/agent_kernel/README.md),
not plugin APIs. Primary application paths are in the source map below.

## Activity Inspection

`RunActivityProjection` exposes read-only public execution snapshots. The execution
controller observes live activity and can read retained terminal snapshots from
lifecycle; it is neither the durable store nor the owner of canonical Chat history.
Durable retention and restore use the separate
[execution-history boundary](../docs/architecture/execution-model.md#terminal-execution-history).
The full read model retains opaque native historical evidence, while frontend
bridges expose narrower safe presentation data, never future continuation input.

The generic `openSessionRunActivity` bridge operation resolves a semantic Run ID
only within the presented Session and returns an opaque read-only handle, or null
when retained evidence is unavailable. Restored
snapshots use the existing activity reads, compact presentation, and Inspection
paths, not a separate history renderer. Chat supplies its own durable user-entry
association and fills missing view-local handles; app composition does not query
Chat tables. A historical lookup starts no Run, resolves no approval, and requires
no live model/tool provider or Environment materialization.

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
Missing rich presentation does not erase safe activity or alter live Run-local
replay. Retained terminal native envelopes remain historical evidence, not input
to a later Run.

For OpenAI, [Contract](../plugins/openai/packages/contract/README.md) owns shared
identities/schema, [Backend](../plugins/openai/packages/backend/README.md) owns
classification/projection, and [Frontend](../plugins/openai/packages/frontend/README.md)
owns rendering. The app does not parse OpenAI fields or recover hidden reasoning.

## Dependencies

Production `dependencies` in [`pubspec.yaml`](pubspec.yaml) and imports/exports
under `lib/` contain no package under `plugins/**`, including plugin contracts.
The app may use public ADELE APIs, internal generic host packages, Flutter, and
generic native/host libraries such as `file_selector`, `sqlite3`, and eval runtime libraries.

Plugin-aware tests, source preparation, and self-hosting use development dependencies
outside the normal runtime graph. Source/build tooling is not a normal runtime
dependency. The temporary provider identity/model seam grants no plugin-import
exception. Follow [dependency rules](../docs/architecture/dependency-rules.md);
the [application boundary test](../test/tools/app_plugin_boundary_test.dart) checks
production manifest dependencies and import/export directives.

## Developer Self-Hosting Runner

[`bin/adele_self_host.dart`](bin/adele_self_host.dart) and
[`tool/self_hosting/cli.dart`](tool/self_hosting/cli.dart) are the developer-only
headless entrypoints. Runner, topology, and report owners live under
[`tool/self_hosting/`](tool/self_hosting/), deliberately outside `app/lib` because
they know concrete plugins. They reuse application/core runtime composition and
normal remote execution boundaries, not desktop frontend composition.

See [developer self-hosting](../docs/development/self-hosting.md) for usage,
prerequisites, provider presets, topology, retained outputs, and validation.

## Focused validation

Application changes should use the repository's
[testing and validation workflow](../docs/development/testing.md), including its
[application validation map](../docs/development/testing.md#application-validation-map)
and dependency-boundary checks. Local starting points include
[`adele_runtime_test.dart`](test/core/adele_runtime_test.dart),
[`product_lifecycle_test.dart`](test/core/product_lifecycle_test.dart),
[`durable_project_lifecycle_test.dart`](test/core/durable_project_lifecycle_test.dart),
[`durable_session_lifecycle_test.dart`](test/core/durable_session_lifecycle_test.dart),
[`durable_run_lifecycle_test.dart`](test/core/durable_run_lifecycle_test.dart),
[`execution_evidence_test.dart`](test/core/execution_evidence_test.dart),
[`project_storage_host_test.dart`](test/core/project_storage_host_test.dart), and
[`orchestration_authority_test.dart`](test/core/orchestration_authority_test.dart).

### Live tests

Opt-in app/provider cases, gates, costs, and known blockers are documented in
[live testing guidance](../docs/development/testing.md#live-tests). Provider-only
validation belongs to the [OpenAI backend](../plugins/openai/packages/backend/README.md).

## Current limits

Project identity/source, Tasks, Environment semantic records, and provider-state
snapshots, Sessions, semantic Environment associations, terminal Run records, and
terminal public activity snapshots are durable; initialized Chat conversation,
configuration, plain-text Draft Request, and user-entry Run associations are
plugin-owned durable state. Environment materialization remains lazy
and runtime-only.
Active/waiting Runs, claims, approval restart, live bindings, and native continuation
recovery are not persisted. Rich Draft Request documents, conversation forks,
and concurrent editing are unimplemented. Task Browser/general
Session navigation, automatic selection/resume, general settings, Profiles,
configured-provider/credential management, and workbench persistence remain absent.
Current model-provider selection is the source-checkout seam above, not finished
settings.
Intended UX belongs to
[product direction](../docs/product/README.md); future technical work belongs to
[technical direction](../docs/direction/README.md) and
[profiles architecture](../docs/architecture/profiles-and-configuration.md), not a
repository-wide deferred-feature ledger here.

## Source map

| Concern | Primary application anchors |
| --- | --- |
| Entry/window composition | [`lib/main.dart`](lib/main.dart), [`lib/application.dart`](lib/application.dart): `AdeleApplication` |
| Runtime construction | [`lib/core/adele_runtime.dart`](lib/core/adele_runtime.dart): `AdeleRuntime` |
| Shared Run identity allocation | [`lib/core/run_id_source.dart`](lib/core/run_id_source.dart): `RunIdSource`, `MonotonicRunIdSource`; `AdeleRuntime.runIds` |
| Backend bootstrap | [`lib/core/application_plugin_bootstrap.dart`](lib/core/application_plugin_bootstrap.dart): `ApplicationPluginBootstrap` |
| Frontend generations/activation | [`lib/frontend/application_frontend_bootstrap.dart`](lib/frontend/application_frontend_bootstrap.dart), [`lib/frontend/prepared_frontend.dart`](lib/frontend/prepared_frontend.dart) |
| Product lifecycle/Environment authority | [`lib/core/product_lifecycle.dart`](lib/core/product_lifecycle.dart): `ProductLifecycleCoordinator`, `EnvironmentRuntime` |
| Private Project persistence | [`lib/core/project_database.dart`](lib/core/project_database.dart): `ProjectDatabase`, `MigrationCoordinator` |
| Terminal Run retention and lookup | [`lib/core/product_lifecycle.dart`](lib/core/product_lifecycle.dart): `retainTerminalRun`, `InMemoryProductStore.runRecord`, `runsForSession`, `publishTerminalRun` |
| Terminal activity retention and restore | [`lib/core/product_lifecycle.dart`](lib/core/product_lifecycle.dart): `runActivity`, `runActivitiesForSession`; [`lib/core/project_database.dart`](lib/core/project_database.dart): `loadExecutionHistory`, `insertTerminalRun` |
| Execution evidence validation/schema | [`lib/core/execution_evidence.dart`](lib/core/execution_evidence.dart), [`lib/core/execution_evidence_schema.dart`](lib/core/execution_evidence_schema.dart) |
| Plugin relational storage mediation | [`lib/core/project_storage_host.dart`](lib/core/project_storage_host.dart): `projectStorageServices`, `ProjectStorageHost` |
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
