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
| Generic shell, Task Browser/Session/Inspection hosting, shared console chrome, and application-local window state | Browser presentation: [Task Browser](../plugins/task_browser/README.md); console content: [Terminal](../plugins/terminal/README.md); tool behavior and bespoke cards: [Filesystem](../plugins/filesystem_tools/README.md), [Command](../plugins/command_tools/README.md), and [Search](../plugins/search_tools/README.md). |
| Temporary source-checkout provider/model selection | OpenAI protocol, credentials, and provider algorithms: [OpenAI backend](../plugins/openai/packages/backend/README.md). |
| Live in-memory product graph and fixed startup participation | General installation/Profile management and complete runtime restoration remain unimplemented: [profiles and configuration](../docs/architecture/profiles-and-configuration.md), [storage scope](../docs/architecture/product-model.md#storage-scope-and-limits). |

## Normal startup

[`main.dart`](lib/main.dart) launches `AdeleApplication` in
[`application.dart`](lib/application.dart). Application State constructs one
`NativeAdeleRuntime` synchronously, retains it across rebuilds, and explicitly starts
asynchronous plugin bootstrap.

```text
Flutter application
    -> construct NativeAdeleRuntime
    -> discover shared prepared installation catalog
         +-> notify window -> activate prepared frontends -> ExtensionRegistry
         +-> start valid prepared backends
                  -> ready advertisements
                  -> existing capability/extension registries
    -> window / product / Session interaction
```

`AdeleRuntime` is the pure-Dart host graph shared with SDK-only self-hosting.
[`NativeAdeleRuntime`](lib/terminal/native_adele_runtime.dart) adds desktop-owned
terminal resources without putting Flutter in that shared import graph.
Both runtimes statically activate zero stock plugins. Construction is
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
| [`tool/compile_task_browser_frontend.dart`](tool/compile_task_browser_frontend.dart) | `ADELE_TASK_BROWSER_FRONTEND_OUTPUT` |
| [`tool/compile_terminal_frontend.dart`](tool/compile_terminal_frontend.dart) | `ADELE_TERMINAL_FRONTEND_OUTPUT` |
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

### Native code editor

[`native_code_editor.dart`](lib/editor/native_code_editor.dart) is the app-private
adapter over the adopted, locally patched CodeForge dependency. It supplies a
bounded in-memory editor, not a production Main Content contribution, Source Editor,
file model, or save workflow. No Project, Task, Session, Environment, file, LSP, AI,
or network authority is configured. The host chooses `plain`, `dart`, `json`, or
`python` highlighting without supplying a file path. Dependency identity,
preparation, and distribution notices belong to the
[toolchain policy](../docs/development/toolchain.md#native-editor-preparation).

`NativeCodeBuffer` owns the controller, native Rope, text, content version, and undo
history independently of widget lifetime. Admission requires well-formed UTF-16
and at most **262,144 Unicode scalars**, not UTF-16 code units or bytes. Edits that
exceed the bound are rejected rather than truncated. Undo retention is limited to
**128 operations**, with ordinary grouping; this is an operation-count limit, not
a byte budget. Text, snapshots, and retained edit payloads consume memory
proportional to their contents, not a fixed RSS allowance.

`NativeCodeView` separately retains logical selection and horizontal/vertical
scroll state, plus its immutable read-only setting. Full presentation unmount does
not discard the buffer or undo history; a fresh presentation can restore the same
logical view before revealing the editor. Only one mounted view may consume a
buffer, including a retired attachment awaiting actual disposal. A competing mount
fails unavailable rather than sharing controller callbacks or stealing input.
Independent simultaneous panes use independent buffers.

Each presentation receives a fresh, permanently revocable `NativeCodeAccess`.
Interactive editing and clipboard actions require live presentation access, an
active window, and actual editor focus. Activation tokens and input-client
generations prevent old keyboard, pointer, context-menu, or input callbacks from
becoming valid after A-to-B-to-A focus changes. At most one clipboard request is
pending per buffer; additional requests are not queued. Actions revalidate captured
activation; cut/paste also recheck version and selection after awaiting the
clipboard, and paste enforces the text bound. Read-only views allow local
navigation, selection, scrolling, and explicit copy, not editing, cut/paste, or
undo/redo. Focus loss, window deactivation, and unmount cancel uncommitted
composition, detach input, and flush already accepted pending text without turning
composition into a new accepted edit.

IME projection reads splice only the requested scalar window across the rope and
pending line; they do not force the typing debounce to flush. The ordinary context
window is bounded, but an explicit selection remains fully representable so
typing over a selection larger than that window replaces the whole range.

[`CodeEditorBridge`](lib/frontend/code_editor_bridge.dart) implements the
[interpreted public UI stubs](../packages/ui/lib/code_editor_bridge.dart).
Compile-only `CodeEditorDeclarations` neither initializes Rust nor acquires an
editor. At runtime one bridge supplies one opaque handle for its host-selected
view and one evaluator; guessed, foreign, and retired handles fail closed. Cached
native widgets remain subject to native revocation. `PreparedFrontend` failure,
retirement, and disposal revoke presentation access and observation, not buffer
ownership; remount requires a fresh grant.

`readCodeEditorState` is cheap metadata only: readiness, read-only state, version,
language, focus, and scroll offsets. It contains neither text nor selection.
`snapshotCodeEditor` deliberately returns a **synchronous `Map<String, dynamic>`**
containing coherent `text`, `version`, `selectionBase`, `selectionExtent`, and
`selectionUnit: 'utf16'`; no `Future` crosses EVC. Snapshots require initialized
state and copy full text only on request. Content-change and initial readiness
invalidations are coalesced; they are not text payloads or a caret/layout event
stream. Only accepted content edits advance the content version, not selection,
scrolling, layout, or a later flush
of an already accepted edit.

Trusted native `replaceText` is an explicit detached-buffer replacement that
resets undo and retained view positions; remount never reloads through it.
`replaceRangeUtf16` also requires a detached buffer and validates range ordering,
bounds, and scalar boundaries before recording a normal logical undo edit. It
resets retained view positions to that edit's caret and the top-left viewport.
Neither operation is a file synchronization
API, and neither is exposed to interpreted callers. `NativeCodeEngine` initializes
Rust once on demand for the process; disposing a buffer does not shut down the
global bridge. Owners explicitly release Rope handles and undo resources; views
and grants release timers, listeners, input connections, and mount-local resources.

The [focused acceptance checks](../docs/development/testing.md#focused-editor-checks)
cover the patched component, native owner, and actual prepared EVC separately.
The [packaged smoke and manual entrypoint](../docs/development/testing.md#integrated-editor-smoke)
exercise this application adapter on Linux x64, not a generated substitute app or
a claim of macOS/Windows validation. Human checks of the adopted patched editor
are not established by the historical unpatched probe findings.

### Native terminal surface

[`NativeTerminalSurface`](lib/terminal/native_terminal_surface.dart) is an
app-private adapter over published `xterm2 5.2.0`, not a stock Terminal plugin or
an execution resource. Native code constructs the owner, feeds ordered text with
`write`, chooses initial `readOnly` configuration and callbacks, and explicitly
calls `dispose`. It requires no Project, Task, Session, Environment, or durable ID.
The emulator and incremental escape parser survive complete view unmounts; output
while hidden updates the same buffers without transcript replay. Execution owners
may permanently revoke its outbound routes while preserving read-only display;
that transition never grants authority to an initially read-only surface.

`title` and `observeTitle` expose the parsed window title independently of view
attachment. The adapter removes unsafe formatting/bidi controls, collapses
control/whitespace runs to one space, and bounds the retained label to 160 UTF-16
code units without splitting supplementary characters. Empty titles become null.
Title changes are coalesced invalidations, not output notifications or process
lifecycle evidence; observer failures cannot interrupt parsing. Common console
metadata applies its own display bounds before showing the title. The shared tab
chrome renders lifecycle status separately from the ellipsized process title.

The default initial grid is 80 columns by 24 rows. The default `maxLines` is 2,000 lines
**including the viewport**, per emulator buffer; native callers may choose another
finite value of at least 24. Rows cannot exceed that bound, and columns are capped
at 1,000, including output-requested geometry. Older parsed lines are evicted by
the emulator, not by truncating the input stream. Zero-sized layouts leave the
previous dimensions intact. No additional output transcript is stored.

Only one mounted view may attach to an owner, including an inert exit-retained
view. A competing attachment fails unavailable rather than stealing resize/input
control. Cache the widget across ordinary rebuilds; a fresh mount gets fresh
focus, selection, scroll resources, and a permanently scoped native facade.
Deactivation retires that mount; reparenting a live mount is not supported.
Disposal of the owner is idempotent: further `write`/`buildView` calls throw,
queued view actions are inert immediately, and the mounted terminal detaches on
the next frame. Disposing a view or retiring a bridge never disposes the owner.

Outbound callbacks have distinct native responsibilities:

- `onInput` receives authorized view-originated keyboard, paste, mouse, and focus
  reports. A captured old mount cannot send through a new attachment.
- `onResponse` receives emulator-generated replies. Ordered output feeding can
  produce replies with no view mounted, independently of presentation authority.
- `onResize` receives distinct layout-generated character columns/rows while an
  interactive view is authorized. Output-requested geometry stays emulator-local.
- Read-only owners suppress **all three** execution-directed sinks, not just text
  input. They still render controls, resize locally, scroll, select, and explicitly
  copy. Clipboard escape requests and iTerm2 clipboard capture are disabled;
  no URL launch, notification, file-transfer, or other ambient host action is wired.
  Theme/color queries are deliberately declined rather than coupled to a view.

[`TerminalSurfaceBridge`](lib/frontend/terminal_surface_bridge.dart) implements
the two interpreted-only [public UI stubs](../packages/ui/lib/terminal_surface_bridge.dart).
Compile-only declarations need no owner. The native bridge issues one opaque
handle to one runtime/presentation for its host-selected owner; guessed, foreign,
retired, or reused-runtime access fails closed. No mode flag or native object is
exposed. `PreparedFrontend` disposal, failure, and exit retention revoke the
same bridge. Cached widgets check access when actions arrive, including clipboard
completion; retained display is not continuing interactive authority. A fresh
presentation can receive fresh access to the surviving owner.

The deterministic [`terminal_frontend.dart`](test/fixtures/terminal_frontend.dart)
fixture imports only Flutter and public UI. The
[prepared-EVC test](test/terminal_surface_bridge_test.dart) compiles it with
declarations, writes actual EVC bytes, and mounts through
`PreparedFrontend.load/createPresentation`. The
[native tests](test/native_terminal_surface_test.dart) inspect real buffer state.
See [focused commands](../docs/development/testing.md#focused-terminal-checks) and
[dependency/toolchain evidence](../docs/development/toolchain.md#native-terminal-dependency).
The surface alone registers no catalog role. The separately prepared stock
[Terminal](../plugins/terminal/README.md) uses it through the shared Session console
below. Interactive terminal persistence remains absent.

[`TerminalProjectionBridge`](lib/frontend/terminal_projection_bridge.dart) is a
separate read-only capability for interpreted output presentations. Each view
lazily owns its own `NativeTerminalSurface.projection`; card and console never
share one mounted attachment. The bridge exposes bounded accepted text feeds,
controlled reset, scalar render/scroll state, and coalesced observation. It grants
no interactive surface writes, execution input, clipboard reads, resize callbacks,
or resource lookup. Native explicit selection/copy and local scrolling remain
available. Fixed projection geometry, pipe LF policy, and synchronous user-scroll
freeze are separate from the unchanged interactive PTY path. See the
[public capability](../packages/ui/lib/terminal_projection_bridge.dart) and
[Command Tools replay policy](../plugins/command_tools/README.md#replay-and-history).
The projection bridge owns disposal, unlike the host-selected interactive surface
bridge; a new view reconstructs output through its plugin rather than inheriting
an emulator cursor. Scoped replay yields check the original view before resuming;
follow uses painted cursor geometry so short layouts do not follow empty screen
padding. Generic projection hide/reveal readiness suppresses paint while retaining
native layout, then reveals only after the intended scroll position has settled.
Command Tools chooses a finite restoration target and keeps the terminal concealed
during cancellable prefix reconstruction; normal live pages do not toggle readiness.
Cold restoration remains O(prefix length), not an instant seek. Warm console
selection instead preserves the resident's emulator/parser and reader position
within the bounded working set described below.
Native and actual-EVC coverage lives in
`test/native_terminal_surface_test.dart` and `test/terminal_projection_bridge_test.dart`.

### Environment terminal ownership

[`environment_terminal_owner.dart`](lib/terminal/environment_terminal_owner.dart)
connects the surface to the selected public Environment terminal facet.
`NativeAdeleRuntime.terminals` owns the application-private Environment-keyed collection;
each `EnvironmentTerminalOwner` retains a distinct process resource and emulator.
Only an explicit host-authorized open materializes canonical Environment context.
There is no Session/Run creation, model tool, public terminal registry, or frontend
Environment selector. Production app code imports no concrete PTY/provider package.

An owner captures one `EnvironmentMaterialization` and exact registration, validates
them across asynchronous opening and before subsequent operations, and observes
retirement even with no output or view. It never restores or retries an existing
resource through a replacement generation. Opened evidence precedes output; EOF
without terminal completion becomes failure rather than fabricated success.
Completion/disconnection revokes native input, layout resize, and protocol replies
while keeping the screen available for inspection. Explicit release and runtime
shutdown clean up resources independently of Flutter widget disposal.
Native runtime close fences terminals and product admission synchronously, then
grants terminal owners their bounded cleanup window before base runtime/backend
teardown. Product cleanup joins backend teardown rather than blocking it, so
connection revocation can still settle pending Project opens.

Each live owner consumes one continuous ordered stream, feeding the emulator while
hidden. View-originated input and layout callbacks carry their original native
presentation validator through deferred dispatch; fresh access never revives an old
view's queue. Emulator `onResponse` instead uses only live resource authority, so
terminal queries still receive replies with no mounted widget. Callback failures
are recorded on the owner and trigger cleanup, not unhandled evaluator/Flutter
errors. Input admission is bounded to 65,536 pending UTF-16 code units and 128
chunks, with at most 8192 code units per dispatched message; pending resize is
coalesced. Closure or retirement discards queued effects before cleanup; it does
not roll back an already admitted effect. The provider's
[pending-output bounds](../plugins/git_environment/README.md#interactive-terminals)
remain separate from emulator scrollback.

`EnvironmentTerminalOwner.observe` reports lifecycle, cleanup, and normalized title
changes, including while hidden; ordinary output does not rebuild console chrome.
The coordinator's `observe` reports collection changes. `shellCompleted` requires
actual shell-exit evidence, while `cleanupPending`, `cleanupSettled`, and
`cleanupSucceeded` describe resource cleanup separately. Neither the surface nor
the owner chooses tab-removal policy. `launchFailedWithoutResources` is deliberately
limited to failures before a terminal request was issued: successful local stream
cancellation alone is not proof that no remote resource was created.

[`environment_terminal_owner_test.dart`](test/environment_terminal_owner_test.dart)
isolates authority, queue, and startup/retirement races. The
[real integration](test/environment_terminal_integration_test.dart) prepares the
unchanged interpreted fixture, actual shared host and Git backend AOT snapshots,
and the provider's native helper before activation. It tests native input/resize,
hidden output/query replies, complete unmount/remount without respawn, and retained
completed/disconnected display. This is Linux debug widget/evaluator plus actual
Dart AOT backend/process coverage, not a cross-platform runtime claim. Stock console
composition is covered separately by the normal integration mapped below; its
widgets consume these owners rather than creating processes themselves.

### Session console

[`ConsoleController`](lib/ui/console/console_controller.dart) is window-owned;
[`WorkbenchConsole`](lib/ui/console/workbench_console.dart) renders its common tab
strip, creation menu, selection, visibility toggle, confirmation, and warnings.
Independent `consoleContributions` compose into this host without a single-provider
resolver or native stock fallback. The public [UI contract](../packages/ui/README.md#shared-console)
and [architecture](../docs/architecture/plugin-system.md#shared-console) define the
content/access and close boundaries.

Each native close confirmation has an exact request lifetime. Tab removal or
context/view revocation withdraws its owned dialog route and settles the abandoned
request without awaiting an answer or cleanup. Metadata updates do not withdraw
it, and route withdrawal cannot pop unrelated navigation or authorize cleanup.

`AdeleApplication` sets the controller's Session in `_activateSession`, clears it
only after accepted navigation in `_showBrowser`, and supplies the shell's bounded
console area only while a Session is presented. Task Browser has no panel, toggle,
or console creation actions, even with a selected Task. The console is outside the
Session/Inspection scroll views; navigation settlement blocks its input/focus too.
Presentation defaults to selected-only. `ConsoleContent.keepAlive` explicitly
opts into a lazy, least-recently-selected working set while this console is
expanded for one canonical Session object. `ConsoleController.presentationLimit`
defaults to four constructed presentation slots, including initializing, failed,
and selected presentations even when selected-only. Unvisited tabs never construct
views; eviction chooses an unselected resident, not the selected tab. `residentPresentations`
provides the host's admitted resident identities; it is not a history or resource
registry.

Within that set, tab switches preserve opted-in evaluator/widget state, native
projection/parser/viewport, readers, and bounded in-flight work. Hidden content
has no paint, semantics, pointer, focus, keyboard, or selected action authority.
`ConsolePresentationAccess.isActive` follows residency; its `interaction` is a
fresh selected epoch, and earlier epochs remain invalid after reselection.
Collapse, canonical Session identity change or null, console unmount, and host
close revoke the entire set. Content close, retirement, or eviction revokes its
exact resident. Revocation and native bridge/resource invalidation are synchronous.
Whole-set revocation fences lazy presentation admission before firing callbacks,
and nested teardown cannot reopen that fence. Construction captures a working-set
identity so an attempt interrupted by teardown cannot publish afterward, even if
the Session and selection are unchanged. A later host render may admit fresh cold
content normally; ordinary selective eviction does not close admission for siblings.
Current content eligibility is part of that lifetime even while hidden. Access
use and controller collection/notification reconciliation evaluate eligibility for
the exact Session, permanently evicting only residents whose predicate returns
false or throws. There is no watcher for arbitrary callback-captured state: loss
ends access as soon as a host check observes it. Reconciliation keeps healthy
siblings warm and restores eligible selection if necessary, without changing
unaffected selection epochs or LRU recency. Pending questions for ineligible
targets withdraw; logical content and resource ownership remain intact. Eligibility
recovery permits a fresh, lazily selected cold presentation, never revival of old
access. Predicate/reconciliation guards and snapshot iteration contain reentrant
checks; eviction removes the exact entry before notifying teardown listeners.
Removed Flutter subtrees from the previous mounted set can briefly overlap the
replacement set until frame disposal. Normal reconciliation therefore has at most
one previous set plus the new set, rather than a deferred resident cleanup queue.
Already admitted transport work and cancellation cleanup may settle later without
regaining presentation authority.
The four-slot bound is on authorized residents, not an absolute instantaneous
Dart-object or RSS bound. Lightweight content, bounded checkpoints, and selection
remain independent of those resident lifetimes. Selection is remembered per
Session among its eligible tabs; removing the selected tab prefers an eligible
neighbor.

[`PreparedConsoleHost.environmentForSession`](lib/frontend/prepared_console_host.dart)
checks canonical Session identity and its published Project/Task graph, then uses
`store.sessionAuthority(session.id)` to select the same-Task Environment. It never
falls back to Task primary. Eligibility is passive and creates no Environment,
terminal, or Run. A creation action captures that association before awaiting;
navigation cannot retarget its admitted work or let a late result steal the new
context's selection. Sessions sharing that Environment can show the same terminals;
another Environment cannot.

[`EnvironmentTerminalBridge`](lib/frontend/environment_terminal_bridge.dart)
copies validated `TerminalContentPolicy` from one short-lived EVC action into
[`TerminalConsoleContent`](lib/terminal/terminal_console_content.dart). Retained
native policy handles hidden title/lifecycle changes, close advice, and cleanup;
it never calls back into a disposed operation evaluator. Every selected view uses
fresh `ConsolePresentationAccess` and `TerminalSurfaceBridge` access to the same
owner. Interactive Terminal is not opted into resident presentation: deselection
still releases its view while the separately owned shell/emulator survives. The
stock frontend's [policy map](../plugins/terminal/README.md#terminal-policy)
describes conservative confirmation, actual-exit-only automatic removal, and
failure retention. Shell selection/startup remains with the
[Environment contract](../packages/environment/README.md#interactive-terminals)
and [Git provider](../plugins/git_environment/README.md#interactive-terminals).

Prepared read-only console descriptors use `PreparedConsoleHost` and
[`ConsoleBridge`](lib/frontend/console_bridge.dart), not Terminal creation. An
authorized presentation may open only its explicit `consoleExtensions` from the
same prepared installation/generation. `ConsoleController.openOrFocus` deduplicates
the opaque key within the exact contribution and canonical Session. It admits
bounded plugin data plus metadata, never originating evaluator callbacks. Stock
Command Output explicitly opts into residency through its prepared descriptor;
other contributions keep the selected-only default unless they opt in. Each cold
remount receives fresh resident-scoped backend/projection bridges; retained logical
state is bounded opaque data, not a rendered transcript. `ConsoleContentState`
also owns one scalar `TerminalProjectionRetention` record. Native progress and
viewport changes checkpoint synchronously without entering eval; final bridge
release copies already-owned local state before disposal, even if presentation
authority has already been revoked. Detachment retains the known viewport offset.
Each new view takes an exact-owner lease, fencing stale snapshots; content release
clears and permanently retires that record. The plugin combines this accepted
native prefix/viewport with its logical reading mode when reconstructing a fresh
emulator. After a resident ends, no evaluator/widget/controller or hidden observer
is retained in that record. Warm resident observation remains separate from
selected interaction; this adds no global `PreparedFrontend` cache or
post-revocation plugin authority.
Missing optional console
hosting does not disable factual Inspection. Read-only content closes without
confirmation and releases no process resource. Command-specific reads, status,
history, and follow behavior remain in its stock EVC.

Close fences console actions immediately and starts forced content cleanup without
waiting for plugin advice or a confirmation dialog. After accepted Task/Run work
drains, the app joins bounded console cleanup before `NativeAdeleRuntime.close`;
runtime teardown still runs on cleanup failure and owns remaining terminal cleanup.
Frontend retirement also removes its exact content. Cleanup warnings do not claim
that a process stopped. Session navigation releases resident presentation/readers,
not independent execution, capture, terminal resources, or retained lightweight
tabs. No tabs, titles, selection, or terminal transcripts are persisted by the
console host.

Focused host/bridge/widget tests and the real stock EVC/Git AOT case in
[`normal_chatgpt_run_integration_test.dart`](test/core/normal_chatgpt_run_integration_test.dart)
are mapped in [console validation](../docs/development/testing.md#focused-console-checks).

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
    -> browse/select Task or create Task + primary Environment
    -> open retained Session or create/present Session
    -> submit/schedule Run
    -> observe / approve / inspect execution
    -> return to Task Browser after presentation settlement
```

`AdeleApplication` coordinates these actions; the light Material 3 `AdeleShell`
hosts plugin presentation and Project/Task/Session breadcrumbs. The presented
Project/Task/Environment/Session and Inspection arrangement are window-local state,
not new product identities or a final workbench architecture.
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

### Task Browser

After opening a Project, the window presents
[`TaskBrowserPresentationHost`](lib/ui/task_browser/task_browser_presentation_host.dart)
with no automatic Task selection, including when restored Tasks exist. The host
uses the public `TaskBrowserResolver`: missing or ambiguous contributions display
unavailability, not a native Task form. It retains the exact factory result across
unrelated rebuilds and does not repeatedly retry a failed factory. Prepared hosting
uses [`PreparedTaskBrowserHost`](lib/frontend/prepared_task_browser_host.dart)
without a strategy or owning-backend dependency.

[`WindowTaskBrowserSource`](lib/frontend/window_task_browser_source.dart) projects
the runtime's canonical live graph through the app-owned `TaskBrowserSource` and
[`TaskBrowserBridge`](lib/frontend/task_browser_bridge.dart). It does not query SQL
or maintain a second Task/Session store. `tasksFor` and immutable `sessionsForTask`
queries supply Task rows, Session counts, and the selected Task's Sessions;
Environment details expose identity/provider only. Unavailable Sessions remain
visible. The public [UI README](../packages/ui/README.md#task-browser-snapshot)
owns the snapshot/action shape and safe asynchronous result contract.

Read-only execution status comes from window-owned `SessionExecutionOwners`,
without creating controllers during enumeration or querying tool transcripts.
Task rows aggregate preparing/running/approval/terminal Session counts; Session
rows identify the affected work independently of presentation availability.
Status invalidations are coalesced and exclude ordinary evidence-only updates.

The source validates current Project/Task membership and the exact browser
registration. Opaque creation choices retain exact Session presentation/strategy
bindings and required affinity; submission revalidates them rather than resolving
a replacement for a stale handle. Overlapping actions are rejected. Task
establishment still uses lifecycle; browser retirement cannot undo publication, but rejects late
selection/navigation. Leaving the browser revokes its presentation-local source,
subscriptions, and choices.

New and retained Sessions enter the same `AdeleApplication._activateSession` path
for canonical membership checks, lazy controller creation/reuse, exact presentation
binding, and Inspection setup. Opening an existing Session preserves its identity and
Environment association; browsing/opening does not materialize an Environment or
start a Run. Missing model configuration does not prevent browsing or opening an
otherwise available Session.

The stock [Task Browser](../plugins/task_browser/README.md) owns local title search,
responsive list/detail presentation, and the inline new-Task Card required by the
pinned evaluator. Its local README owns richer-UX limitations and plugin identities;
the app owns neither a duplicate browser implementation nor those UI choices.
Browser selection, search, and navigation do not add persisted product fields.

<a id="b2-task-and-primary-environment"></a>
### Task and primary Environment

The browser submits a title through the host bridge. The application
trims/rejects blank input, guards pending submission, and calls
`ProductLifecycleCoordinator.createTask` without a Git-specific provider selection.
Provider resolution belongs to lifecycle and the capability registry; the selected
provider owns source suitability and establishment.

For durable Projects, establishment success is followed by one SQLite transaction
that inserts the Task and finalized primary Environment. Only a successful commit
publishes them in the live store and retains their materialization. Provisional
null provider state is never persisted, and database failure never falls back to
volatile publication. External resources created by successful establishment cannot
yet be generically rolled back if the subsequent database commit fails.
Development/fixture Projects created by `createProject` remain in memory only.

The browser presents canonical Environment/provider identities, without decoding
opaque provider state or restoring a binding just to render details. An Environment
record is not a promise of live provider readiness.
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
The browser can select restored Tasks without materializing their Environments;
new Task creation still requires available Environment support. Reopening a
Project does not automatically select a Task or resume work.
See [durable Task lifecycle tests](test/core/durable_task_environment_lifecycle_test.dart)
and [fresh-runtime Git restart/move integration](test/core/durable_task_git_integration_test.dart).

### Session lifecycle

Host Session creation is strategy-neutral: it resolves usable contributed
presentation names and exact strategy bindings, not a compiled Chat choice. The
browser submits an opaque host-issued choice. `PreparedSessionHost`
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

The window presents one Session at a time, with independently active Sessions
retained by [`SessionExecutionOwners`](lib/ui/execution/session_execution_owners.dart)
outside the pure-Dart runtime graph. Its Task breadcrumb returns to the browser
with that Task selected; its Project breadcrumb clears the Task selection.
Both use `AdeleApplication._showBrowser`, which blocks input and awaits
`PreparedSessionHost.prepareToDeactivate`, backed by the public asynchronous
[presentation lifecycle hook](../packages/ui/README.md#interpreted-bridges).
Failed draft saves or in-flight message acceptance retain the view for retry,
but preparation, inference, tools, approvals, and history settlement do not block
navigation for the duration of a Run.

After acceptance, the app unbinds/revokes exact presentation actions, detaches
selected-view listeners, and clears Inspection/console context. Changing the
presented Session does not close its execution. Reentry reuses the same owner
and live Run with a fresh presentation binding; cached native approval callbacks
and interpreted handles remain inert even when that Session is opened again.
Only the selected owner updates workbench UI; background work never selects a
Session or replaces Inspection. Owners remain until shutdown, while settled
backend executions are released through the existing terminal path.
`PreparedSessionHost` checks a retained controller's exact captured strategy
against the new presentation's owning-backend affinity. A compatible frontend
remount does not replace execution; unavailable or retired backends remain
unavailable rather than migrating work. This is navigation settlement, not Run
cancellation, restart recovery, or a promise to flush on arbitrary widget
disposal/application exit. Follow
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

Close blocks new owner creation, starts, and decisions and initiates closure of
all retained controllers before awaiting their collective settlement, including
hidden Sessions. Accepted Task establishment and Run advancement drain while
backend/storage services remain available for normal history persistence.
Closing a waiting Run does not resolve its approval, execute the pending
invocation, or invent a terminal record. Cleanup attempts continue after failure;
the memoized close result is stable and UI reports a failure once. This is resource
cleanup, not general cancellation or a bounded total deadline.
A failed execution release fences further starts on that owner rather than
repeatedly accepting work against a failed cleanup future; sibling Sessions remain
independent. Startup failures before a Run actually starts remain presentation
failures, not invented durable terminal records.
This does not restore live Runs/approvals or introduce a Profile system.
[Durable Chat integration](test/core/durable_chat_session_integration_test.dart)
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
only within the presented Session and returns a fresh opaque read-only handle for
its retained live/waiting Run or terminal history, or null when unavailable. Restored
snapshots use the existing activity reads, compact presentation, and Inspection
paths, not a separate history renderer. Chat supplies its own durable user-entry
association and fills missing view-local handles; app composition does not query
Chat tables. A historical lookup starts no Run, resolves no approval, and requires
no live model/tool provider or Environment materialization.

`SessionExecutionController.sessionStateRevision` separately signals completed
materialization/association and terminal settlement. Chat compares it across
initial hydration and later reads, so a late user-entry Run association or a
completion during hydration triggers canonical refresh without reloading history
for every evidence packet. Chat alone associates its entries; the host does not
infer a last-message relationship.

Window-owned `WindowInspection` and `InspectionHost` own selection, card stack,
collapse/dismiss state, common chrome, and inspect interaction. Generic compact and
rich hosts resolve contributions by their public semantic identity and retain
exact presenter bindings. Retirement/failure affects the view, not execution;
replacements require fresh resolution. Compact roles can show factual host content
without a custom presenter; this is not a native implementation of plugin behavior.

`ActivityOutputPresentation` constructs the tool source with the exact occurrence's
Session/Run identity and canonical tool snapshot; historical activity follows the
same path. Prepared rich Inspection may declare owning-backend service and console
target allowlists. `ApplicationFrontendBootstrap` captures those exact counterparts
once per view, without strategy affinity or Session execution controls. Compact
presentation receives only facts and never opens output observation or rendering.

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
and concurrent editing are unimplemented. The browser supports one open Project
and one presented Session with multiple independently active Sessions, not multiple
active Runs per Session. Automatic selection/resume, general settings,
Profiles, configured-provider/credential management, and workbench persistence
remain absent.
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
| Native runtime and terminal lifetime | [`lib/terminal/native_adele_runtime.dart`](lib/terminal/native_adele_runtime.dart): `NativeAdeleRuntime` |
| Shared console state/chrome | [`lib/ui/console/console_controller.dart`](lib/ui/console/console_controller.dart), [`lib/ui/console/workbench_console.dart`](lib/ui/console/workbench_console.dart) |
| Prepared console and retained terminal content | [`lib/frontend/prepared_console_host.dart`](lib/frontend/prepared_console_host.dart), [`lib/frontend/environment_terminal_bridge.dart`](lib/frontend/environment_terminal_bridge.dart), [`lib/terminal/terminal_console_content.dart`](lib/terminal/terminal_console_content.dart) |
| Shared Run identity allocation | [`lib/core/run_id_source.dart`](lib/core/run_id_source.dart): `RunIdSource`, `MonotonicRunIdSource`; `AdeleRuntime.runIds` |
| Backend bootstrap | [`lib/core/application_plugin_bootstrap.dart`](lib/core/application_plugin_bootstrap.dart): `ApplicationPluginBootstrap` |
| Frontend generations/activation | [`lib/frontend/application_frontend_bootstrap.dart`](lib/frontend/application_frontend_bootstrap.dart), [`lib/frontend/prepared_frontend.dart`](lib/frontend/prepared_frontend.dart) |
| Task Browser projection/actions | [`lib/frontend/window_task_browser_source.dart`](lib/frontend/window_task_browser_source.dart), [`lib/frontend/task_browser_bridge.dart`](lib/frontend/task_browser_bridge.dart): `WindowTaskBrowserSource`, `TaskBrowserSource`, `TaskBrowserBridge` |
| Task Browser presentation hosting | [`lib/frontend/prepared_task_browser_host.dart`](lib/frontend/prepared_task_browser_host.dart), [`lib/ui/task_browser/task_browser_presentation_host.dart`](lib/ui/task_browser/task_browser_presentation_host.dart) |
| Product lifecycle/Environment authority | [`lib/core/product_lifecycle.dart`](lib/core/product_lifecycle.dart): `ProductLifecycleCoordinator`, `EnvironmentRuntime` |
| Private Project persistence | [`lib/core/project_database.dart`](lib/core/project_database.dart): `ProjectDatabase`, `MigrationCoordinator` |
| Terminal Run retention and lookup | [`lib/core/product_lifecycle.dart`](lib/core/product_lifecycle.dart): `retainTerminalRun`, `InMemoryProductStore.runRecord`, `runsForSession`, `publishTerminalRun` |
| Terminal activity retention and restore | [`lib/core/product_lifecycle.dart`](lib/core/product_lifecycle.dart): `runActivity`, `runActivitiesForSession`; [`lib/core/project_database.dart`](lib/core/project_database.dart): `loadExecutionHistory`, `insertTerminalRun` |
| Execution evidence validation/schema | [`lib/core/execution_evidence.dart`](lib/core/execution_evidence.dart), [`lib/core/execution_evidence_schema.dart`](lib/core/execution_evidence_schema.dart) |
| Plugin relational storage mediation | [`lib/core/project_storage_host.dart`](lib/core/project_storage_host.dart): `projectStorageServices`, `ProjectStorageHost` |
| Session selection/presentation | [`lib/frontend/prepared_session_host.dart`](lib/frontend/prepared_session_host.dart), [`lib/ui/session/session_presentation_host.dart`](lib/ui/session/session_presentation_host.dart) |
| Session navigation/settlement | [`lib/application.dart`](lib/application.dart): `_activateSession`, `_showBrowser`; [`lib/frontend/session_presentation_lifecycle_bridge.dart`](lib/frontend/session_presentation_lifecycle_bridge.dart); `PreparedSessionHost.prepareToDeactivate`, `unbind` |
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
