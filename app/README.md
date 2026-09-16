# ADELE Desktop

`adele_desktop` is ADELE's single Flutter desktop application and composition
root. It is an internal application, not a plugin-facing package.

## Normal Application

The app owns its minimal shell, theme, and private widgets. It retains the ADELE
header and initially displays `No Project is open` with B1 Project selector
buttons. After opening, it shows the Project source and initially `No Tasks yet`.
B2 adds title-only Task creation and primary Environment status. Normal interaction
supports one canonical stock Chat Session and approval-gated ChatGPT-backed Runs,
with plugin-owned evaluated history/composer, direct compact activity or groups, and
retained window-local Inspection cards containing interpreted Apply Patch, Run Command, and
OpenAI provider-supplied reasoning-summary cards.
Execution status/approvals remain host-owned; this is not a Task Browser or
complete active-Session workbench.

The Stateful `AdeleApplication` constructs one `AdeleRuntime` synchronously in
`initState` and retains it across rebuilds. `lib/core/adele_runtime.dart` owns one
`CapabilityRegistry`, `ExtensionRegistry`, `InMemoryProductStore`,
`ProductLifecycleCoordinator.generated` wired to those same registries and store,
`InferenceContextComposer` over the same extension registry, and retained
`ChatStrategyPlugin`. It statically owns six activations in order: Chat,
root-level AGENTS.md, Filesystem Tools, Search Tools, Command Tools, and Local
Directory Project Selector, all using the same `ExtensionRegistry`. This is
implicit in-process stock composition, outside installed-component discovery and
not a profile API. The existing `includeCommandTools` flag only preserves the
reduced live-smoke harness composition; it omits only Command Tools, not the selector. Normal startup
includes all six; changing those activations is an F3 follow-up, not part of F2.
Construction remains provider-free: it starts no backend host or compiler, loads
no credentials, and performs no product operation. It also owns
pure-Dart `ApplicationPluginBootstrap` in `lib/core/application_plugin_bootstrap.dart`,
using the exact same `CapabilityRegistry` as lifecycle resolution.

Application close synchronously blocks actions and notifications, then awaits
retained in-flight Task establishment and only the currently advancing Run
start/resume before calling `runtime.close`. A quiescent waiting Run is abandoned
with teardown without resolving or executing its pending invocation or waiting
indefinitely for approval. Either failure does not bypass cleanup.
This lets real worktree creation settle before the host's bounded two-second
shutdown can force termination; it adds no cancellation or rollback machinery.
Desktop exit requests await this complete close. Detach/dispose initiate the same
cleanup without awaiting it, and runtime cleanup failures are reported through
`FlutterError`.
`AdeleRuntime.close` shares one completion or failure across callers. Its backend
owner retires all owned capability registrations before closing any of their
connections, then closes the shared host. The runtime then retires its in-process
activations in reverse activation order. The `closeResources` helper in
`lib/core/resource_cleanup.dart`, shared with development teardown, attempts every
action before rethrowing the first error with its stack.

### Normal backend startup

After synchronous runtime construction, `AdeleApplication` explicitly calls
async `ApplicationPluginBootstrap.start`. The pure-Dart owner takes only an
installation root, shared runtime/host locations, and optional generic startup
arguments. It has no stock plugin selection, activation callbacks, Git requirement,
or OpenAI knowledge.

Every normal backend attempt passes `startupArgumentsOnly: true` to
`PluginBackendHost.startPlugin`, even with an installation root but no startup-argv
file or matching plugin entry. The shared host forwards this generic deployment
mode to the backend startup message without a PluginId switch. Direct/self-hosting
callers retain the API default `false`; see
[`plugin_runtime`](../packages/plugin_runtime/README.md#startup-arguments).

`plugin_runtime.PreparedPluginCatalog.discover(rootPath)` first reads a
deterministically sorted startup snapshot of immediate child installations. Each
child has `adele_plugin.installation.json` containing `manifestVersion: 1`,
`PluginMetadata` (`id`, opaque `version`, `displayName`, optional `description`),
and `components`, with independently optional backend and frontend components.
Backend supplies `artifact` such as `backend.aot`; frontend supplies `artifact`
such as `frontend.evc` and strict data-only `presentations` descriptors for
`session`, `toolActivity`, or `modelNativeActivity`. All artifact files must be
existing and confined to the installation. Descriptors specify executable
ABI/preparation data, not profile state; the manifest contains no exposures,
source paths, configuration, or activation state. See the exact schema in
[`plugin-layout.md`](../docs/architecture/plugin-layout.md#prepared-installation-snapshot).

An unconfigured, missing, or empty root succeeds with an empty catalog. Malformed
installation envelopes become catalog issues and are excluded independently.
Invalid components instead record typed backend/frontend issues, omitting only
the failed component and retaining the installation and healthy sibling. Readable
valid identities are reserved before remaining validation, so duplicate PluginIds
exclude all conflict members, including otherwise invalid manifests, without a
version or ordering winner. Root I/O failure becomes generic bootstrap failure
while the core and Project opening remain usable. Discovery is a snapshot, not a
watch or rescan service.

Discovery precedes shared-host creation. `ApplicationPluginBootstrap` publishes
the catalog through its existing change notification before backend startup;
window-owned `ApplicationFrontendBootstrap` starts from that same snapshot without
waiting for backend readiness. There is no second installation root/catalog,
registry, or frontend runtime mechanism. With no valid backend components,
bootstrap succeeds without spawning a process, even when runtime/host paths are
invalid. Otherwise one `PluginBackendHost` attempts every valid backend
independently. A local start, ready-metadata, or registration failure cleans up
only that attempt's partial registrations and generation; unrelated attempts
continue. Later plugin termination retires only its own exact generation.
Shared-host failure invalidates all backends globally. Task Environment support
depends on live Environment capability registration, not on required Git startup.

Ready backends advertise `capabilityExposures` through the existing isolate-ready
message, host `pluginReady`, and exact `PluginBackendConnection`.
`PluginCapabilityActivation.registerAdvertised` delegates to existing `register`,
preserving validation, rollback, registry routing, and exact-generation liveness.
The installation/connection supplies authoritative plugin identity. Git and
OpenAI entrypoints own their exposures; an omitted list means zero capabilities.
Installed metadata alone never registers a provider. Advertisement fields and
configuration-context semantics are maintained in
[`contracts-and-capabilities.md`](../docs/architecture/contracts-and-capabilities.md#backend-ready-advertisements).

The owner exposes `unconfigured`, `starting`, `ready`, `failed`, `closing`, and
`closed` states, read-only per-backend `pending`, `starting`, `active`, `failed`,
`terminated`, and `closed` states, and catalog issues. `ready` means bootstrap
settled, not that every backend succeeded or a model is usable. These are
diagnostic surfaces, not a plugin-management UI. Close waits for in-progress
startup, retires all registrations before closing any generations, closes the
shared host, and then lets runtime close retire in-process activations. Cleanup
attempts every action and retains failures for reporting.

Normal plugin composition consumes only these four compile-time deployment-location
inputs:

| Define | Prepared deployment input |
| --- | --- |
| `ADELE_DARTAOTRUNTIME_EXECUTABLE` | Executable from the matched Flutter/Dart SDK |
| `ADELE_BACKEND_HOST_ARTIFACT` | Shared backend-host AOT snapshot |
| `ADELE_PLUGIN_INSTALLATION_ROOT` | Root containing prepared installation directories |
| `ADELE_PLUGIN_STARTUP_ARGUMENTS_FILE` | Optional file containing a JSON object mapping PluginId to string argv lists |

With no inputs, startup reaches `ready` with no discovered backend or frontend
components; Task Environment support and interpreted presentation are unavailable
but core in-process contributions remain usable. There is no source-path discovery,
on-start compiler, or fallback provider. Task UI and lifecycle contain no stock Git IDs.

Normal Linux `dart tools/adele.dart run linux` and `build linux` prepare the host,
Git, and OpenAI snapshots plus four frontend EVCs (Chat, Filesystem Tools, Command
Tools, and OpenAI activity) before the Flutter run/build invocation. The unified
launcher helper `prepareDesktopPluginDefines` in `tools/backend_artifacts.dart` uses
`plugin_builder.compileAotSnapshot`, selects compiler/runtime from the launching
Flutter SDK, and invokes `tools/frontend_artifacts.dart` to assemble one fresh
root below `.dart_tool/adele/desktop-plugins/build-*/installations/` on every
invocation. Its five directories are frontend-only `chat-strategy`,
`filesystem-tools`, and `command-tools`, backend-only `git-environment`, and one
`openai` containing both `backend.aot` and `frontend.evc`. Each installation has
one JSON manifest; all frontend artifacts are named `frontend.evc`.
`tools/stock_frontend_descriptors.dart` is the singular stock build-side descriptor
table. Tooling still knows stock source entrypoints; runtime discovery does not.
Earlier artifacts are not overwritten because a running app or earlier build may
still reference them.
Source paths and compilation stay in tooling, outside the app runtime graph.

The built app embeds provisional absolute installation/runtime/host and startup-file
paths; frontend locations come from that installation root, not per-stock fields
or defines. It is runnable only on the source-checkout machine while that
SDK and those artifacts remain in place; moving/deleting them breaks the
corresponding backend startup or frontend loading. This is bounded
installed-component discovery, not a cache, installer, portable/production
packaging, or profile system. Direct Flutter startup without the artifact defines
leaves backend support, Chat presentation, stock tool Inspection, and OpenAI activity presentation unavailable
independently.

Future installation/update should own artifact preparation; current activation
already consumes prepared installations through the same registry/lifecycle
semantics. Checkout tooling is only a stand-in, not an installer, general build
graph, or activation-management system. F2 adds prepared frontend discovery but no
enable/disable controls, profiles, version solving, watching, reverse RPC, or hot
upgrade. Normal startup attempts all discovered valid components; future profiles
are a separate activation-participation policy, not descriptor metadata. The six
static in-process activations are unchanged.
Normal artifact provisioning is currently limited to the Linux launcher; other
desktop targets retain their existing launch behavior without these defines.

Normal startup creates no Project, Task, Environment, Session, tool catalog, or
Run. The app forwards generic argv, while the OpenAI backend owns interpretation
of its configuration references and credential loading. Explicit Project, Task,
Session, and prompt actions are separate operations. The shared runtime has no
dependency on development composition.

### Prepared frontend activation

`lib/frontend/application_frontend_bootstrap.dart` owns generic Flutter-side
`ApplicationFrontendBootstrap` over the runtime's existing `ExtensionRegistry`.
It consumes the backend bootstrap's already-discovered catalog, loads each frontend
once per generation with `PreparedFrontend.load`, and registers its typed
descriptors at the existing `adele_ui` extension points. Tool and model-native
activity descriptors each supply separate compact and rich registrations. There
is no app runtime stock identity table for those roles and no stock tool/OpenAI
activator. A component load or registration failure stays local; partial exact
registrations roll back and that generation is invalidated, not a healthy sibling
frontend or backend.

`InstalledFrontendActivation.retire(extensionId)` closes only that generation's
matching exact registrations, leaving other roles and the shared prepared bytes
active. Existing hosts remove retired views through registry liveness; captured
factories stay stale even if a replacement reuses the same ID. Generation close
revokes factories, settles any pending load, retires all its registrations, and
invalidates its prepared views. Owner close also closes its native Session
adapters, attempting cleanup even on failure and sharing completion across callers.
Read-only frontend states report activation settlement, not successful decoding of
every possible view; they do not implement a plugin-management UI.

The catalog checks confined existing files and strict descriptor fields/roles,
not executable EVC correctness. `PreparedFrontend.load` reads immutable bytes;
decoding and entrypoint execution still occur separately for each view. Readable
corrupt bytes can therefore register but fail only when presented. Frontend
availability does not depend on backend readiness, credentials, or another
frontend; presentation failure never invalidates a canonical Session or Run.

Session descriptors select a native adapter by `hostAdapter`, not PluginId.
The only supplied adapter is `stock-chat-controller-v1` in
`lib/plugins/stock_chat_frontend.dart`. It validates the descriptor's strategy and
adapts the provisional app `ChatController`; it does not load EVC, register
contributions, or own activation. Unsupported adapter/strategy combinations fail
the frontend attempt without fallback. This is a bounded internal native bridge,
not a public universal Session-controller API or reverse-call mechanism.

### Prepared Chat frontend

`tools/frontend_artifacts.dart` prepares all four EVCs in their installation
directories before launching or building the app. Chat compilation invokes
`app/tool/compile_chat_frontend.dart` with the selected Flutter SDK and takes
`ADELE_REPOSITORY_ROOT` and `ADELE_CHAT_FRONTEND_OUTPUT` as build-time environment
inputs. From `app/`, with an existing output parent directory, the standalone
invocation is:

```sh
ADELE_REPOSITORY_ROOT="$(git rev-parse --show-toplevel)" \
ADELE_CHAT_FRONTEND_OUTPUT="/absolute/path/to/chat.evc" \
flutter test --no-pub --concurrency 1 tool/compile_chat_frontend.dart
```

Tool Inspection compilation invokes `app/tool/compile_tool_inspection_frontends.dart`,
using `tool_inspection_frontend_compiler.dart`. Its inputs are
`ADELE_REPOSITORY_ROOT`, `ADELE_TOOL_INSPECTION_FRONTEND` (`filesystem` or
`command`), and `ADELE_TOOL_INSPECTION_FRONTEND_OUTPUT`. From `app/`, with an
existing output parent directory:

```sh
ADELE_REPOSITORY_ROOT="$(git rev-parse --show-toplevel)" \
ADELE_TOOL_INSPECTION_FRONTEND=filesystem \
ADELE_TOOL_INSPECTION_FRONTEND_OUTPUT="/absolute/path/to/filesystem.evc" \
flutter test --no-pub --concurrency 1 tool/compile_tool_inspection_frontends.dart
```

Use `command` and its output path to compile the Command Tools frontend.

OpenAI activity compilation invokes `app/tool/compile_openai_activity_frontend.dart`,
using `openai_activity_frontend_compiler.dart`. From `app/`, with an existing
output parent directory:

```sh
ADELE_REPOSITORY_ROOT="$(git rev-parse --show-toplevel)" \
ADELE_OPENAI_ACTIVITY_FRONTEND_OUTPUT="/absolute/path/to/openai.evc" \
flutter test --no-pub --concurrency 1 tool/compile_openai_activity_frontend.dart
```

These compiler inputs are build-time environment variables, not runtime artifact
defines. Runtime receives the generic installation root and discovers frontend
locations/descriptors, not source paths or compiler output environment variables.

The Flutter test runner is the build-time execution environment for eval
compilation, not an on-start compilation mechanism. Normal runtime never compiles
source. The `app/tool` compile harness is a checkout stand-in for future
installation/update-time preparation, not an installer or runtime plugin manager.
`lib/frontend` owns generic activation and prepared-generation/runtime hosting;
`lib/plugins/stock_chat_frontend.dart` retains only the bounded Chat controller
adapter. Missing or failed EVC loading leaves presentation unavailable without
invalidating the canonical Session, headless strategy, Git, or OpenAI backend
activation. There is no compiled native Chat view fallback.

The window owns frontend activation separately from the pure-Dart `AdeleRuntime`.
Close immediately blocks submission through the controller and drains Task/Run
advancement. `stopStarting` prevents pending generations from registering during
that drain; already active views stay mounted until final cleanup. The inert input
remains mounted while Flutter exit observers await settlement; final cleanup
retires the frontend and invalidates its callbacks even
if runtime cleanup fails. The frontend owner settles pending
loads and retires exact registrations; a late activation is retired rather than
attached to a closed owner. Retirement cannot remove a replacement registration.
The frontend generation is distinct from each presentation instance. The pinned
eval implementation shares prepared bytes but uses a separate runtime per view
to isolate globals and callbacks. This is an implementation constraint, not a
permanent plugin-instance model. View disposal and generation retirement
invalidate their bridges; neither migrates callbacks to a replacement generation.

`lib/frontend/interpreted_widget.dart` installs runtime-local guards for the
current pin's interpreted `createState`, `initState`, `build`, and `dispose`
calls. Together with the Tool bridge's per-view failure notification, these revoke
observation, release the failed view, and display generic unavailable UI without
retiring sibling presentations. Interpreted cleanup gets one attempt, with native
State disposal completed even on failure. These guards do not intercept native
Flutter errors outside the guarded calls, such as layout/paint errors, or arbitrary
asynchronous callbacks; they do not replace global Flutter error handling.

Tool and model-native activity reuse this same generic owner and `PreparedFrontend`
lifecycle. Retirement removes exact registrations and invalidates their bridges.
Missing/corrupt EVC never triggers source compilation or a native tool/reasoning-card
fallback, and leaves headless tools, backend support, and healthy presentations
independent.

### ChatGPT source-checkout configuration

Normal composition uses only `dev.adele.openai.chatgpt-experimental`, backed by
the existing experimental ChatGPT subscription route, OAuth implementation, and
credential store. It does not expose the API-key provider in the normal UI.
ChatGPT-only backend startup requires no `OPENAI_API_KEY` or dummy value. The
API-key provider remains supported for other consumers, including self-hosting's
explicit API-key profile, and both contexts may coexist outside normal activation.

Set these environment variables before invoking the Linux repository launcher to
prepare/build the app. The launcher snapshots backend startup references into the
separate startup-arguments file; model selection remains a residual app runtime
input rather than part of that file:

| Variable | Purpose |
| --- | --- |
| `ADELE_OPENAI_CHATGPT_CREDENTIAL_FILE` | Existing OpenAI credential-store file; without a reference the backend advertises no model capability |
| `ADELE_OPENAI_CHATGPT_MODEL` | Optional selected model; defaults to `gpt-6-astra` |
| `ADELE_OPENAI_CHATGPT_CLIENT_ID` | Optional explicit public OAuth client ID |
| `ADELE_OPENAI_CHATGPT_INSTANCE_ID` | Optional existing configured credential instance identity |
| `ADELE_OPENAI_CHATGPT_OAUTH_ISSUER` | Optional OAuth issuer override |
| `ADELE_OPENAI_CHATGPT_REDIRECT_URI` | Optional OAuth redirect override |
| `ADELE_OPENAI_CHATGPT_ENDPOINT` | Optional experimental Responses endpoint override |

Without an explicit client ID, the maintained experimental source-visible Codex
OAuth client opt-in behavior is retained. Existing credentials can be reused;
explicit manual login remains available through
`dart run plugins/openai/packages/backend/bin/openai_chatgpt_development.dart login`
from the repository root, with the same credential-file and optional OAuth variables.
Use an absolute credential-file path. The existing file store is provisional local
development storage, not a new secure-storage claim. See
[ADR 0028](../docs/adr/0028-experimental-chatgpt-openai-configured-instance.md)
for the route's experimental support limitations.
Normal composition adds no login/account UI and does not perform browser OAuth
during normal startup or automated tests. Missing or invalid credentials fail
model execution without invalidating the Session, Task, Project, or Git Environment.

`tools/backend_artifacts.dart` writes a temporary JSON object of
`PluginId -> List<String>` outside the installed manifests. For OpenAI, the list
always begins with `--chatgpt-only`. When a credential-file reference is configured,
the second string is a JSON object requiring `credentialFile` and either a
nonblank `clientId` or `experimentalCodexClient: true`; `instanceId`, `issuer`,
`redirectUri`, and `endpoint` are optional. Only the file reference and public
OAuth/endpoint options enter argv, never tokens. Unknown fields and malformed
values fail locally without echoing configuration contents.

The launcher still emits explicit `--chatgpt-only`. Independently, normal bootstrap
always sends `startupArgumentsOnly: true`. OpenAI honors this mode by refusing
environment configuration fallback and advertising zero capabilities when argv is
empty or the configuration document is absent. Thus root-only normal activation
without the launcher's argv map cannot accidentally expose an inherited
`OPENAI_API_KEY` provider. A supplied malformed document still fails locally;
absence is not malformed configuration.

Direct and self-hosting callers retain `startupArgumentsOnly: false` by default;
without explicit startup arguments, OpenAI retains its legacy environment-based
configuration path. Configured capability advertisements belong to the OpenAI
entrypoint, not Flutter or the installed manifest. The flag is a temporary
argv-only deployment rule, not generic settings/profile/credential infrastructure
or process-environment scrubbing.

`ApplicationPluginBootstrap` reads only the generic map and forwards opaque argv
to `PluginBackendHost.startPlugin`; runtime and shared host stay OpenAI-unaware.
`lib/plugins/temporary_chatgpt_selection.dart` retains the provisional selected
provider identity and model-only `StockChatGptConfiguration`. Its `fromEnvironment`
always supplies `ADELE_OPENAI_CHATGPT_MODEL` or the default `gpt-6-astra`; it has no
`credentialFile` field or credential-presence gate. Provider availability comes
from the active registry, not app inspection of startup OAuth/credential
configuration. The app does not start backends through this selection helper,
construct configuration argv, or define exposures. This remains temporary product
selection, not a general provider/model configuration solution. The startup-file seam is intended
to disappear with general plugin configuration/profiles, not become a settings or
accounts API. Shared-process execution is not a credential or filesystem sandbox.

### Normal Chat interaction

After creating a Task, `New Session` calls canonical lifecycle with the explicit
stock `chatStrategyId`. Lifecycle chooses the Task's primary Environment; model
availability is not a Session creation requirement. One currently presented
Session is retained in window-local state, with no list, naming, persistence, or
strategy picker. Once the Session is presented, the temporary UI does not create
additional Tasks/Sessions that it cannot navigate back to.

Public Flutter `adele_ui` defines
`SessionPresentationContribution(strategyId: OrchestrationStrategyId,
createPresentation: Widget Function(Session))` and typed
`sessionPresentationContributions`. `lib/ui/session/session_presentation_host.dart`
hosts this contract without Chat-specific routing. It resolves the canonical
Session's stored strategy ID exactly: zero matches is unavailable, one creates
presentation, and multiple matches is explicit ambiguity, with no priority or
fallback. The host observes registry changes, validates the retained exact
binding, and removes retired widgets so their presentation resources dispose.
Only fresh resolution can create a replacement presentation. Factory/load failure
does not change Session identity, strategy binding, or backend validity.

`plugins/chat_strategy/packages/frontend` (`chat_strategy_frontend`)
owns conversation rendering and the prompt/Send composer as interpreted Flutter
source. It imports neither `chat_strategy_plugin` implementation nor app/kernel
code. The stock adapter exposes immutable primitive mixed message/activity snapshots,
a composer-enabled boolean, submission of a string returning synchronous
boolean acceptance, and `buildChatActivity` for emitted opaque activity IDs.
The latter returns a native widget wrapper that hosts plugin compact presentation
in a separate prepared runtime and supplies common inspect interaction. The
interpreted Chat strategy still decides timeline placement, without receiving
plugin fields or manufacturing identities. Neither `Session`, `ChatController`, execution objects,
approval objects, nor approval decisions cross this eval bridge. The public
Session factory is the native registration boundary, not an execution bridge.

The evaluated composer retains its draft across host updates and clears it only
on synchronous acceptance, preserving the submitted text exactly. The current
eval pin exposes only a single-line `TextField` without decoration, so the prompt
label is adjacent to the input. Its button bridge does not safely support nullable
callbacks; disabled submission is a muted, non-actionable Send label alongside
the disabled input. These are bounded presentation limitations, not native Chat
fallbacks or changes to host submission/approval validation.

`lib/ui/chat/chat_controller.dart` obtains `runtime.chat.sessions.obtain(session.id)`
and retains immutable snapshots of canonical user/final assistant entries. It
intentionally remains provisional app composition, not a public Chat controller
API or code linked into the frontend.
Each nonblank accepted prompt appends one user message, allocates a fresh ID through
injectable `RunIdSource`, resolves the selected capability binding exactly, creates
a new `ModelProviderCapabilityAdapter`, and builds tools through
`buildModelToolCatalogForSession`. A new `SessionOrchestrationRun` uses the existing
Chat strategy and per-inference AGENTS.md context composition. The second prompt
reuses canonical Chat history, not a Run, model binding, or materialized tool set.

Normal Runs expose a read-only live activity source in public pure-Dart
`adele_orchestration`. The application host translates internal journal evidence
into immutable model/output/tool snapshots, preserving exact identities and
authoritative order without executable bindings, arbitrary exceptions, or approval
authority. Asynchronous coalesced journal invalidations do not eagerly freeze
snapshots per progress chunk. The controller captures the latest evidence at most
once per frame, plus advancement-settlement catch-up, while model/tool work is
still in flight. Raw native output and terminal metadata remain opaque to generic
consumers; backend-supplied safe presentation is separate from exact replay.
Only rich Inspection requires an exact safe-presentation-kind contribution.
Structured tool `hostData` is retained, not flattened into summary prose or
rendered automatically.

The provisional controller subscribes before starting its Run and retains
presentation-only activity snapshots separately from canonical Chat. It inserts
one activity entry after the initiating user entry for each successfully completed
model invocation containing proposals or native `output.presentation != null`.
Each proposal and safe native output counts once; narration and opaque native
output do not count. One occurrence uses its compact presentation directly, while
two or more use one group. Later invocations make separate decisions. Presence is
independent of frontend activation. A group's heading prefers
ordered explicit tool-batch `ModelTextOutput` narration only when tools are present,
then safe `compactText`, then a structural `N operations` count. Generic Chat
escapes unsafe display controls and reapplies the 160-code-point compact cap after
escaping, rather than relying on stock OpenAI activation for display safety.
A reasoning-only invocation can produce a direct compact activity before its canonical final
assistant message; proposal-free final text is not repurposed as batch narration.
Raw items without safe presentation alone create no activity; a missing rich
presenter does not hide safe activity. The Chat strategy
automatically includes stable shared-purpose narration guidance, with explicit
user instructions taking precedence, without erasing
Session instructions or changing independent AGENTS.md composition.

Completed groups survive follow-up prompts for this controller's lifetime, not by
adding `ChatEntry` variants. Reconstructing/reopening the Session cannot restore
historical activity without future persistence. Observation detaches on close,
and the interpreted bridge retains coalesced post-frame callbacks and disposal
guards. Compact activity remains plugin-owned interpreted content; clicking it
requests the window-local Inspection described below, not execution or approval.

`ApprovalGatedToolPolicy` allows a singleton certain `sourceRead` effect, asks for
a singleton certain `sourceMutation`, and asks for a singleton `processExecution`
regardless of uncertainty. It denies everything else, including empty effects,
`resourceInspection`, mixed effects, and uncertain reads or mutations. Tool aliases
and instruction prose do not determine authorization. Policy denial remains a
model-visible `policyDenied` outcome without execution or an interruption.

The evaluated frontend shows conversation, compact activity, prompt, and Send. Common host-owned
`RunExecutionStatus`, `PendingToolApproval`, and display-safety code live under
`lib/ui/execution`; `lib/plugins/stock_chat_execution_status.dart` adapts the
provisional controller to that common surface. Advancing/waiting state, model/Run
failure reasons, and approval cards stay outside the evaluated Chat widget.
A waiting approval card is a window-local
projection of the retained Run interruption, not a canonical Chat entry. It
presents immutable summary, effect classes and uncertainty, tool identity, targets,
and canonical arguments. `Allow once` or `Deny` resolves that exact retained
interruption through `SessionOrchestrationRun.resolveApproval`; object-identity
checks reject stale card callbacks, and synchronous acceptance blocks duplicate
decisions. Denial produces `userRejected` continuation without execution.

Approval presentation visibly escapes control, bidi, and related invisible format
characters and malformed UTF-16 without changing the exact invocation or canonical
payload. Literal backslashes in plain-text fields are distinguished from escape
notation; JSON details retain only trusted formatting newlines. Unsafe raw tool
identity/summary or one decoded layer of target URI text disables `Allow once`,
enforced by the controller as well as the card. Undecodable target URI escapes
also fail closed.
`Deny` remains available without automatic resolution. Canonical source payload
content is safely rendered, not blanket-rejected; ordinary Unicode is preserved.

One Run may require multiple sequential approvals. Each decision resumes the same
Run and exact tool materialization; no inference occurs between proposals in the
same batch. Only after all results does Chat continue the model. Advancing and
waiting both block new prompts. Canonical Chat remains user/final assistant only.
A failed Run preserves the accepted user message and prior canonical history
without fabricating an assistant error entry; another prompt may run after terminal
settlement. Close drains only an already advancing start/resume, including when it reaches another
approval after closing; it never resolves a waiting approval to force completion.

Approval authorizes an invocation; it does not override revisions or provide a
sandbox. Existing revision checks and exact-generation binding validation still
apply. Command execution retains direct argv, bounded output and timeout,
process-group lifecycle, and filtered child environment; it is not sandboxed.
The Session presentation API changes neither kernel execution semantics, Chat
sequencing, nor Environment contracts. Host policy and exact-invocation approval
remain the security authority, not the frontend or its bridge. Configurable
permissions/profiles, steering, cancellation controls,
streaming/reasoning-delta UI, compaction UI, arbitrary plugin
drill-down, Source/Diff/Console navigation, terminal/PTY/full-output views, and a
Run history browser remain deferred.

Focused deterministic coverage lives in `test/chat_session_test.dart`,
`test/chat_frontend_eval_test.dart`, `test/core/run_activity_projection_test.dart`,
`test/core/approval_gated_tool_policy_test.dart`, and
`test/core/run_id_source_test.dart`. The separate
`test/core/normal_chatgpt_run_integration_test.dart` compiles real host/Git/OpenAI
artifacts and drives the normal controller through a local fake ChatGPT SSE
endpoint with temporary fake credentials and real prepared frontend artifacts.
Its maintained validation scope includes direct reasoning activity followed by
mixed reasoning/tool groups, group-row-to-individual card insertion, independent
collapse/dismiss, read-to-patch-and-command continuation, separate approvals
without an intervening inference, and direct-argv `git diff --check`.
The scope checks interpreted Chat/Inspection ordering, a visible
timeline during held final continuation, retention between user and canonical
final response, safe summary-only frontend data, untouched encrypted replay, and
Task-worktree/Project/checkout isolation. It requires no account or API key and
performs no live model request; deterministic fixture coverage does not establish
live-provider summary compatibility. Focused presentation cases live in
`test/model_native_activity_bridge_test.dart`,
`test/model_native_activity_inspection_host_test.dart`, and
`test/openai_activity_frontend_eval_test.dart`, alongside public `adele_ui`
resolver tests. Pure-Dart raw classification, projection, bounds, and preservation
coverage lives in the OpenAI backend's `test/openai_native_presentation_test.dart`
and `test/openai_model_provider_backend_test.dart`. Common ModelProvider DTO tests
and `test/development/agent/agent_capability_adapters_test.dart` cover the separate
safe payload, required nullable transport key, and generic mapping. Chat tests
cover safe activity independently of rich frontend activation.

From `app/`, focused validation uses:

```sh
flutter test --no-pub test/chat_session_test.dart test/core/approval_gated_tool_policy_test.dart test/core/orchestration_host_test.dart test/core/orchestration_authority_test.dart test/core/model_tool_host_test.dart
flutter test --no-pub test/core/run_activity_projection_test.dart test/chat_frontend_eval_test.dart
flutter test --no-pub test/model_native_activity_bridge_test.dart test/model_native_activity_inspection_host_test.dart test/openai_activity_frontend_eval_test.dart
flutter test --no-pub test/inspection_host_test.dart test/inspection_stack_test.dart test/tool_activity_compact_host_test.dart test/model_native_activity_compact_host_test.dart test/tool_inspection_frontend_eval_test.dart
flutter test --no-pub test/core/normal_chatgpt_run_integration_test.dart
```

### Activity Inspection

One `WindowInspection` in application State owns newest-first `InspectionCard`
instances, not activity copies or Session history. Each has a window-local
`InspectionCardId`, an exact target, and independent collapsed state. Targets are
`ActivityGroupInspectionTarget(SessionId, RunId, ModelInvocationId)` or
`ModelOutputInspectionTarget` with an additional exact output sequence. Every
open prepends a new card; duplicates are allowed. Collapse retains target/order
and the mounted presentation, expand restores its visibility, and dismiss removes
exactly that card. Binding a
different presented Session clears all cards and invalidates stale callbacks.
Completion, follow-up prompts, and presenter retirement do not clear cards.
The shell places independently scrollable Inspection to the right on wide windows
and stacks it below on narrow windows; this is not a public physical panel API.

The stock Chat adapter accepts only opaque IDs it emitted for retained activity,
resolving exact Run/model/output identity rather than decoding arbitrary input or
matching labels. The application validates the current Session and retained
activity before insertion. Common host code supplies inspect interaction, not
plugin callbacks. No controller, kernel, Run execution, or approval object crosses
the eval bridge.

`lib/ui/inspection/inspection_host.dart` owns common card chrome. Group bodies
interleave compact tool/native rows in exact `output.sequence`, not rich bodies
or separate reasoning sections. Selecting a row prepends an individual card,
leaving its group in place. Individual cards use compact headers and existing rich
bodies. Proposals not yet prepared, rejected before preparation, or left
unprocessed when the Run ends keep factual placeholders. Stable output targets
upgrade to prepared tool presentation in place as live evidence changes, without
duplicating the Chat entry or reordering the stack. Each prepared invocation gets a stable read-only
`ToolActivityInspectionSource`, a `Listenable` whose `snapshot` is an immutable
`ToolInvocationActivity` from public pure-Dart `adele_orchestration`.

Public Flutter `adele_ui` supplies
`ToolActivityInspectionContribution(toolId, createPresentation)` with factory type
`Widget Function(ToolActivityInspectionSource)` and typed
`toolActivityInspectionContributions`. `ToolActivityInspectionResolver` matches
the exact `ToolId`: zero is unavailable, one returns a binding, multiple are
ambiguous. `tool_activity_inspection_host.dart` uses existing registry liveness,
retains a view across source updates, and removes retired widgets/resources.
Only fresh resolution can select a replacement; factory/load failure does not
invalidate execution or select a fallback.

The distinct compact role uses public
`ToolActivityCompactPresentationContribution` and
`ModelNativeActivityCompactPresentationContribution`, with typed extension points
and exact ToolId/safe-kind resolvers. Zero matches use bounded factual fallback;
one uses its exact binding; many expose ambiguity plus fallback, never an ordering
winner. Retirement/failure affects the custom view only, with fresh exact
resolution required for replacement. Tool fallback identifies the alias without
parsing arguments; native fallback retains provider-approved `compactText`.
Plugins own bespoke compact and rich widgets, while Chat owns grouping/placement,
the common host owns inspect interaction/cards, Run owns evidence lifecycle, and
the approval host alone authorizes execution.

The separate `filesystem_tools_frontend` and `command_tools_frontend` packages
under their plugins' `packages/frontend` own interpretation of `apply_patch` and
`run_command` fields. Prepared `toolActivity` descriptors supply their registration
and tool identities to generic frontend bootstrap, without runtime imports of
headless tool identities or native frontend views for activation. Each artifact exposes
compact and rich entrypoints. Filesystem compact shows relative path and canonical
edit count, not inferred Git line statistics; Command compact preserves bounded
direct-argv token boundaries without reconstructing a shell command. Other tools
remain unavailable for bespoke Inspection but have factual compact fallbacks.

`lib/frontend/tool_activity_inspection_bridge.dart` transports recursively
immutable canonical-argument and terminal `hostData` maps, the latest non-progress
common lifecycle, outcome disposition/failure kind, and model content. It does not
switch on tool-specific fields or flatten progress history. Coalesced post-frame
notifications update the same interpreted view/runtime; the Command card's output
preview comes from bounded terminal data, not a live console. Tool cards display
read-only status. Only the common host approval card offers `Allow once` / `Deny`
for the exact retained interruption.

### Model-native activity presentation

The generated `adele_model_provider` DTO
`ModelProviderNativePresentation(kind, compactText, data)` travels separately from
raw `nativeMetadata`. `ModelProviderOutput.nativePresentation` is required but
nullable: `null` denotes semantic absence, while generated keys remain required
under the existing coherent-schema convention. `lib/core/model_provider_host.dart`
maps it generically to pure-Dart orchestration's immutable
`ModelNativePresentation(kind, compactText, data)` on optional
`ModelNativeOutput.presentation`. No OpenAI import, raw classification, or
provider-specific projection belongs in that adapter.

Public Flutter `adele_ui` supplies
`ModelNativeActivityPresentationContribution(presentationKind, createInspection)`
at `modelNativeActivityPresentationContributions`. Its factory is
`Widget Function(ModelNativePresentation)`; there is no UI projection type or
projector callback. `ModelNativeActivityPresentationResolver` matches the exact
safe presentation kind: zero makes rich Inspection unavailable while safe activity
still exists, one returns a retained binding, and multiple matches are explicit
ambiguity. There is no priority, tie-breaking, provider switch, or fallback.
Generic Chat and Inspection never parse OpenAI fields.

OpenAI uses `plugins/openai/packages/{contract,backend,frontend}`. Pure-Dart
`openai_contract` owns shared identities and payload schema only, with no
algorithms. Raw `openAiResponsesItemKind = 'openai.responses.item.v1'`, version 1,
is unchanged; safe presentation uses `openai.responses.reasoning-summary.v1`,
version 1. Backend owns raw Responses classification and bounded reasoning-summary
projection in `plugins/openai/packages/backend/lib/src/openai_native_presentation.dart`;
`plugins/openai/packages/backend/lib/openai_model_provider_backend.dart` attaches
the result while preserving exact native metadata. The safe data contains only
`{'summaryParts': List<String>, 'truncated': bool}`. Compact/full limits remain
160/32,768 Unicode code points and 128 display parts, with pre-processing input
limits of 1,024 parts and 262,144 aggregate UTF-16 code units. The separate
`openai_frontend` owns `lib/openai_frontend.dart` and
`buildOpenAiReasoningInspection`, rendering safe provider-supplied summaries and
escaping full display text, not raw or recovered hidden reasoning.

The common Inspection host keeps exact `output.sequence` order and passes only
`ModelNativePresentation` to
`lib/ui/inspection/model_native_activity_inspection_host.dart`.
`lib/frontend/model_native_activity_bridge.dart` forwards only its safe `data`
map into the EVC. Raw native envelopes, compatibility metadata, encrypted replay
content, Run/kernel/controller objects, and execution or approval authority do not
cross that boundary. The backend and full Run retain exact raw `nativeMetadata`
as the only native replay source; safe presentation is never replayed. Display
filtering, bounds, and escaping never rewrite raw evidence. See the
[OpenAI frontend README](../plugins/openai/packages/frontend/README.md) for the
plugin-owned display contract and the [backend README](../plugins/openai/packages/backend/README.md)
for provider-local summary request support.

OpenAI's single prepared installation supplies both backend and frontend components.
Its `modelNativeActivity` descriptor supplies the safe kind and compact/rich
entrypoints to `ApplicationFrontendBootstrap`. The generic owner loads, registers,
and retires exact frontend resources without stock OpenAI identity imports,
projection, raw parsing, or display escaping. Backend and frontend activation
remain independent even though their artifacts share one installation.

Malformed, unsupported, empty, or oversized summary input produces no safe
presentation in Backend, without changing Run replay. Missing/corrupt EVC,
malformed safe payload, factory failure, and contained EVC failure affect only
presentation, retaining common compact fallback. Existing exact-binding liveness removes retired views and
invalidates their resources; only fresh resolution may create a replacement,
never retargeting stale resources or removing captured safe activity. Multiple
registrations remain explicitly ambiguous. Native Inspection is read-only,
without approval or continuation controls.

Hidden chain-of-thought and encrypted reasoning are never user-presented.
Reasoning deltas, compaction and configuration UI, arbitrary plugin
drill-down, Source/Diff/Console integration, terminal/PTY/full-output views,
navigation history and persistence remain deferred.

### B1 Project opening

Pure-Dart `adele_core_extensions` defines `ProjectSelectorContribution` with only
`String displayName` and `Future<Uri?> Function() selectProject`. Its typed
`projectSelectorContributions` point is `dev.adele.extension.project-selectors`.
`AdeleApplication.build` discovers current contributions through
`runtime.extensions`; `AdeleShell` renders one button per contribution in
deterministic registry registration order. Zero selectors displays
`No Project selectors are available.`; one or multiple selectors are independent
actions, not a default/alternate chooser. There are no priorities, categories,
applicability predicates, or selector defaults.

The application invokes the selected contribution and passes a non-null URI to
`runtime.lifecycle.createProject`, which publishes and returns the canonical
Project. Window presentation retains that value in `_project` on
`_AdeleApplicationState`, never a shared `runtime.currentProject`. All selector
buttons are disabled while selection is pending. `null` is cancellation, not
failure, and creates nothing. Selector or lifecycle failure is an inline error;
it neither tries another selector nor changes the presented Project. After
asynchronous selection, the app validates the retained exact `ExtensionBinding`
before creating a Project; retirement cannot silently substitute a replacement.
Results arriving after disposal or exit has begun are ignored.

The opened view derives its name from the last nonempty source URI path segment,
falling back to the host, then the URI. It shows the source URI, `Project is open`,
and `No Tasks yet`. These are presentation values, not new Project metadata;
`adele_product` is unchanged and independent of the selector API. B1 adds no
Task/Environment/Session creation, provider/model/Git startup, tool catalog, Run,
persistence, Project catalog, or deduplication. GitHub/cloud/catalog selectors
remain possible future plugins. These buttons are temporary presentation over
the contribution and lifecycle operations; Command surfacing and Task Browser
remain deferred.

`plugins/local_directory_project_selector` supplies
`local_directory_project_selector_plugin`. Its const
`LocalDirectoryProjectSelectorPlugin` registers via `activate(ExtensionRegistry)`,
returning an `ExtensionRegistration`, with extension ID
`dev.adele.plugin.local-directory-project-selector.project-selector` and
`displayName` `Open Local Directory...`. It uses `file_selector ^1.1.0` through an
injected narrow picker function. The result is an absolute `file:` directory URI
with lexical `.`/`..` normalization, without filesystem/Git validation or symlink
resolution. Registration itself makes no OS call. A conditional Flutter-only
picker import keeps the real plain-Dart self-hosting CLI import graph free of
Flutter libraries; invoking the default picker headlessly explicitly throws
`UnsupportedError`, rather than returning cancellation or falling back.

B1 native integration adds only the minimum macOS
`com.apple.security.files.user-selected.read-only` entitlement for picking.
Flutter regenerates the Linux/macOS/Windows native registrants. The recorded B1
Linux profile build passed on the pinned toolchain. Interactive OS picking and
macOS/Windows builds have not been validated. The maintained tooling tests also
run the self-hosting CLI's `--help` with plain Dart to guard the shared import
boundary without credentials or live provider calls.

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
The optional Environment-relative `path` scopes search to one regular text file
or recursively to a directory; omitted or empty recursively selects root
(canonical `""`). A file scope searches only that file, never siblings.
Redundant slashes and `.` segments are removed; parent traversal and absolute
paths are rejected.
Canonical `path` is retained in host evidence and used in effect descriptions.
Scopes are opened through the authorized directory-read boundary; only a
`not_directory` failure for a nonempty path permits trying a text-file read.
Invalid, missing, unreadable, stale, or unavailable scopes fail rather than
falling back to root or successful empty results.
The stock `.git`, `.dart_tool`, `build`, and `node_modules` exclusions match
directory names case-insensitively on every Environment, including case-sensitive
filesystems. This policy applies both to recursive traversal and explicit scope
segments; explicit excluded scopes fail before provider reads. It does not change
case-sensitive query matching or the spelling of canonical paths.
Use `read_file` to retrieve an exact known file's contents and revision.
The normal UI also creates a stock Chat Session and approval-gated Runs through these
same boundaries; the broader workbench remains deferred.

The normal application does not display the `workspace_demo` reference plugin.
The maintained `lib/development_smoke.dart` entrypoint exercises the plugin
runtime only through the explicit root smoke command.

### B2 Task and primary Environment

With a Project open and Environment support available, `New Task` opens the
private inline `TaskTitleForm` with only a title and `Cancel` / `Create Task`
controls. The app trims the title and rejects blank input. Cancel creates nothing.
Pending submission disables editing/cancellation/submission, shows progress, and
guards duplicate submission. Errors remain inline with the title retained for
retry; they do not replace the currently presented Project or prior Task.

The app calls `runtime.lifecycle.createTask(projectId: ..., title: ...)` without
`providerId`. `EnvironmentRuntime` uses the existing `CapabilityRegistry` default:
descending rank, then ascending provider identity. Multiple providers do not
introduce a new ambiguity rule. There is no provider chooser, suitability probe,
or Git routing in presentation. The selected provider owns source validation,
including rejection of a non-Git directory by the stock Git provider; opening
such a directory as a Project remains valid.

Lifecycle resolves one exact provider binding, allocates Task and provisional
primary Environment values, and invokes generated Environment establishment.
Only provider success publishes the Task and finalized Environment together and
records that establishment-time materialization. The app presents the returned
canonical values only after lifecycle succeeds, retaining `_project`, `_task`,
and `_environment` in window-local State. Late completion after disposal/exit
does not update presentation. Application close still drains that establishment
future before runtime teardown, preserving lifecycle settlement without cancelling
or rolling back provider work.

The shell shows the Task title, Environment ID, and `Primary Environment ready`
or `Primary Environment unavailable`. Readiness validates the current exact
materialization binding; the UI does not parse opaque `providerState` for paths,
branches, or status and does not restore or migrate a binding merely to render.
Existing lifecycle semantics deliberately retain successful provider state even
if its generation retires immediately after establishment. That successful
publication is not rolled back; its old materialization is unavailable. B2
changes neither publication nor generation-retirement semantics.

This bounded flow creates no Session, Chat state, model invocation, tool catalog,
or Run. It adds no Task Browser, application Command, provider preference API,
product persistence, or general Environment management UI.

### B2 validation paths

Tests added for this slice include:

- `app/test/task_creation_test.dart`: canonical creation, pending duplicate guards, blank/cancel/error/retry paths, unavailable startup, window lifetime, and narrow presentation.
- `app/test/core/application_plugin_bootstrap_test.dart` and `app/test/core/normal_task_git_integration_test.dart`: unconfigured/failed startup, real Git establishment and source preservation, non-Git rejection, exact bindings, activation rollback, termination, and close during startup.
- `test/tools/backend_artifacts_test.dart` and `packages/plugin_builder/test/compile_aot_snapshot_test.dart`: fresh artifact/define preparation before Flutter run/build, compilation failures and diagnostics, and SDK-only pre-bootstrap tooling discovery.

From `app/`, focused presentation/bootstrap validation uses:

```sh
flutter test --no-pub test/application_test.dart test/project_opening_test.dart test/task_creation_test.dart test/core/adele_runtime_test.dart test/core/product_lifecycle_test.dart test/core/application_plugin_bootstrap_test.dart test/core/normal_task_git_integration_test.dart
```

From the repository root, use `dart tools/adele.dart test --target adele_tools`,
`dart tools/adele.dart test --target plugin_builder`, and
`dart tools/adele.dart build linux --profile`.

The recorded B2 Linux profile build passed with actual host and Git AOT compilation
before Flutter build. Both core bootstrap suites above passed: the bootstrap
unit suite requires no AOT compilation, while the real-host/Git integration suite
compiles each artifact once in suite setup through `compileAotSnapshot`.
Focused widget/B1/runtime/lifecycle tests, builder/tooling suites (including the
plain-Dart self-hosting CLI help/import smoke), and relevant development and Git
host regressions passed. Widget tests verify pending-Task draining on exit and
disposal, with no late window-state mutation on success or failure.
The maintained normal `run linux --profile` command also reached
`ADELE backend plugins: ready` under Xvfb with model credential variables removed.
That startup check does not claim interactive native picking or Task entry;
canonical Task establishment is proven by the separate real-Git integration test.
Focused analysis and changed-Dart formatting passed. No full repository test
suite, paid/live model calls, or macOS/Windows B2 validation were performed.
This is prior B2 evidence, not validation of F1's installation catalog,
advertisements, or startup-arguments deployment path, nor F2's frontend discovery
and metadata-driven activation. Validation commands identify maintained paths,
not recorded F2 results.

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
`lib/core/model_provider_host.dart` calls orchestration's
`renderInferenceInstructions` at lowering. The common capability still receives
one `ModelProviderRequest.instructions` string: strategy first, then sources in
lexicographic `ExtensionId` order, preserving each source's local order and exact
text bytes, separated by blank lines. The snapshot always retains its
`StrategyInstructionGroup`, even with empty instructions. Only the renderer omits
empty strategy text; whitespace-only strategy text is preserved. Zero-source behavior is
byte-for-byte unchanged. Source sorting grants no semantic authority or numeric
priority, and semantic input is unchanged. Chat activates no source and remains
AGENTS-unaware. `AdeleRuntime` activates stock `agents_md_plugin` in normal startup
and development/self-hosting. Activation alone does not read a file; the source
rereads root `AGENTS.md` through the Session-authorized
`AuthorizedEnvironmentFileReadFacet` each snapshot. `not_found` and blank files
produce successful empty output; other read/service/authority errors fail the
required source. Nonblank exact file text and its Environment revision form one
material, separate from stable plugin-owned explicit-user-precedence semantics.

The app has no `simple_tool_loop_strategy.dart` or
`development_strategy_registration.dart`; `development_agent_support.dart`
contains only development policy. The private Chat loop lives in the plugin.
Rich Chat UI, persistence, profiles, child Sessions, strategy defaults, and general
context material beyond instructions, provider-aware projection/cache planning,
token budgets, and compaction remain deferred.

## Dependencies

Allowed dependencies are Flutter, ADELE public packages, and internal host
implementations required at the composition root. Statically composed stock
plugins include `chat_strategy_plugin`, `agents_md_plugin`,
`filesystem_tools_plugin`, `search_tools_plugin`, `command_tools_plugin`, and
`local_directory_project_selector_plugin`, resolved through the root pub workspace
for shared `AdeleRuntime` composition.
Normal backend bootstrap uses `plugin_runtime` and generic public metadata and
capability types, not linked Git/OpenAI implementations or stock exposure helpers.
Environment consumers still use public Environment contracts. Source compilation
belongs to `plugin_builder` and Flutter build-time/repository tooling, not the
normal startup path. The headless Chat package's only direct production dependencies are
`adele_orchestration` and `adele_plugin_api`; it has no `agent_kernel` dependency, including in
`dev_dependencies`.

`adele_ui` is the deliberately public Flutter Session, tool Inspection, and
model-native activity presentation package. It depends on Flutter, `adele_plugin_api`,
`adele_product`, `adele_orchestration`, and `adele_model_tool`, not internal host
packages, app code, or concrete plugins. Product, orchestration, model tools, the
registry, and shared headless runtime retain their pure-Dart boundaries. The
separate Chat, Filesystem Tools, Command Tools, and OpenAI frontends are compiled
to EVC, not imported as native app views or linked to their headless/backend
implementations. Runtime tool/native frontend activation consumes prepared
descriptors without stock identity imports; build-side stock metadata remains in
`tools/stock_frontend_descriptors.dart`. Raw Responses
interpretation and projection stay in the OpenAI backend; safe payload rendering
stays in its frontend, outside generic Chat, Inspection, and frontend hosting.

`adele_core_extensions` imports only `adele_plugin_api` and owns core extension
contracts with no natural existing public domain package. It does not absorb
product values, orchestration/context, tools, Environment providers, or
plugin-defined ecosystems; see `docs/architecture/dependency-rules.md`.

The app must not be a dependency of plugins or reusable core packages. Plugin
implementations, Agent/orchestration logic, public plugin APIs, and reusable
core host logic do not belong here.

The long-term extension direction expects the host to own broad workbench
geometry, Command/Command Palette/keybinding infrastructure, and composition of
semantic plugin surfaces. Narrow Session, tool Inspection, and model-native
activity presentation APIs are implemented; broader workbench UI and Command APIs
remain unimplemented.

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
otherwise selects the classic Responses fallback `gpt-6-astra`. The optional
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

`DevelopmentSelfHostingTopology` owns an `AdeleRuntime` instance rather than
duplicating its registries, store, lifecycle coordinator, context composer,
Chat plugin, and stock activations. It uses generic
`PluginCapabilityActivation.registerAdvertised` for the backends' own exposure
metadata, but does not require normal catalog discovery or consume its deployment
defines. It retains the default `startupArgumentsOnly: false` and supplies its own
profile environment; registration includes
all contexts actually advertised by the backend, potentially both API-key and
ChatGPT when configured. It then explicitly resolves the selected profile's
provider ID. Profile selection does not filter advertisements or invent an
exposure, and a missing selected provider fails rather than falling back.
The topology/runner still owns its independent shared backend host and
AOT artifacts, isolated Git source and provider activations,
Project/Task/Environment/Session establishment, tool catalog, model selection,
development IDs, Run execution, and evidence. The generic model capability adapter
is shared from `lib/core/model_provider_host.dart`; resource-inspector adapters
remain development-only. ChatGPT setup no longer injects an unused API key.
Topology teardown closes its runtime, then its Environment activation and host,
attempting every cleanup action.

The runtime activates Chat and the independent root-level AGENTS.md source
before the topology creates the canonical Session. Execution obtains that
Session's retained Chat state, sets instructions and invocation budget, appends
`ChatUserMessage(prompt)`, and passes `SessionId` through lifecycle resolution and
`createSessionOrchestrationRun`. It does not construct a Chat loop or a separate
development history adapter.

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

General provider/model configuration, Task Browser, rich Session/Chat/Run UI,
Project catalog/persistence/deduplication,
additional selectors, Session/Chat persistence and child lifecycle,
context sources beyond root AGENTS.md, nested/scoped AGENTS.md, aliases/overrides,
global/home files, imports, AGENTS.md caching, broader Reference/Observation material,
provider-aware projection/cache planning, token budgets and compaction, additional
Environment-backed mutation tools, configurable permissions/profiles, steering,
richer activity/console and diff/review presentation,
configurable activation, installation/update management,
version solving, watching, hot upgrade, production Agent UI, application
Commands/keybindings, a common execution timeline, and broader plugin-facing
workbench UI APIs remain deferred. Normal UI reaches a canonical Chat Session with
evaluated history/composer, clickable activity groups and window-local tool/native
Inspection, including OpenAI provider-supplied reasoning summaries, read/search,
and per-invocation approvals for eligible source mutation and command execution
over the Task's real Git
worktree. These window-local controls are not a general permission configuration
or workbench presentation API.

The application composition root contains the model adapters, core orchestration
host, Session-scoped model-tool and inference-source host contexts, and AOT
integration tests.
The headless Chat package owns bounded loop sequencing and retained conversation
state; its separate Flutter frontend owns the minimal history/composer.
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
Responses fallback `gpt-6-astra`. All five remain opt-in and are excluded from
normal CI.

Recorded `ADELE_OPENAI_CHATGPT_TEST_MODEL=gpt-6-astra` evidence includes an
ordinary function-tool outcome and canonical continuation in two model
invocations in the backend smoke. The full-stack ChatGPT source-coding smoke
recorded `search` -> `read_file` -> final response in three, with inspected source
unchanged in the distinct Task worktree, Project source, and launching checkout.
Every completed invocation in these proofs must contain the exact selected
service-reported `effectiveModel`; missing or substituted model identity fails
validation. The backend no longer falls back to the request when the service
omits its model. The backend tool smoke also passed with the previous `gpt-5.5`
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
