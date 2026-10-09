# ADELE UI

`adele_ui` is the experimental public Flutter package for semantic Task Browser,
Session, grouped Main Content, source-file display, shared console, and read-only
activity presentation.
It depends only on Flutter and public ADELE contracts, never application code,
internal host implementations, or stock plugins.
Product, orchestration, model tools, and the extension registry remain pure Dart.

## Task Browser

`TaskBrowserContribution(displayName, createPresentation)` registers at
`taskBrowserContributions`; its factory is `Widget Function(Project)`.
`TaskBrowserResolver` resolves across that point: zero is unavailable, one supplies
the exact binding, and multiple contributions are ambiguous. There is no default,
priority, or native substitute. The host retains a view across unrelated rebuilds;
retirement or replacement cannot revive its captured binding.

This is a frontend-only role without strategy or owning-backend affinity. The
prepared descriptor schema belongs to the
[runtime catalog](../plugin_runtime/README.md#prepared-catalog). The
[stock Task Browser](../../plugins/task_browser/README.md) supplies presentation,
not product storage or lifecycle. Host ownership and selection validation belong
to the [UI architecture](../../docs/architecture/plugin-system.md#task-browser-presentation).

The public resolver checks live in
[`test/task_browser_test.dart`](test/task_browser_test.dart). Native bridge,
prepared-view, and navigation checks are mapped in
[application validation](../../docs/development/testing.md#application-validation-map).

## Grouped Main Content

[`main_content.dart`](lib/main_content.dart) defines the additive
`mainContentContributions` point. `MainContentContribution(order, attach)` owns an
ordered collection for one exact registration and canonical Session attachment,
not one collection per PluginId. Its `attach(MainContentAccess)` may be synchronous
or asynchronous; successful completion does not revoke native access. Groups sort
by ascending integer `order`, then lexical ExtensionId, preserving each owner's
contiguous local pane sequence before layout. Broader composition and retirement
rules belong to the
[Main Content architecture](../../docs/architecture/plugin-system.md#grouped-main-content).

Optional `MainContentAction(id, label, createPresentation)` entries expose input
presentations through common host chrome even when the group has no panes. Each
opening receives the exact attachment's access, not a dummy pane or execution
grant. Optional `detach(MainContentAccess)` ends transient attachment references;
it is not a document-close request or permission to reuse revoked access.

A prepared host may deliberately expose one exact action through a semantic
Command, as well as its button. This does not add Command concepts to the public
action/access contract: Main Content still owns current attachment, input
presentation, and retirement. See the
[contextual adapter](../../docs/architecture/plugin-system.md#commands-and-input).

`MainContentAccess` exposes the captured `session`, `isActive`, and immutable local
`panes` snapshots, plus `open(MainContentPane)`, `setTitle(id, title)`,
`setOrder(ids)`, `remove(id)`, and `focus(id, keyboardFocus: false)`. Reordering must
be an exact permutation of that group's current pane IDs. Opening an existing ID
throws `ArgumentError` without replacing, focusing, or transferring ownership of
the supplied pane; removing a missing ID is a no-op. Unknown title/focus targets
are errors. After revocation,
only `isActive` remains usable; old access never retargets a replacement.

`MainContentPane` supplies a local `id`, `title`, `createPresentation` factory, and
optional `requestFocus`, `onClose`, and `release` callbacks. Presentation is retained
across title/order updates; the factory is attempted at most once, including
failure. Common close chrome calls `onClose`; the owner decides when to remove the
pane. Removal does not call `onClose` again. `release` runs synchronously once on
logical removal or attachment retirement, immediately revoking old pane access.
Native owners defer physical resource teardown until mounted descendants detach
where necessary. Focus reveals the pane in Main Content; keyboard focus is separately
opt-in, using `requestFocus` or ordinary content traversal.

Every pane comes from a real contribution registration. The host injects no strategy
pane and reserves no order value; zero panes produce a generic empty workspace.
Stock Chat directly contributes at ordinary order 100 and decides whether to open
its pane from the captured Session context. No matching-renderer resolver gates
canonical Session navigation or independently hosted execution.

Prepared panes may explicitly request Session execution and allowlisted
owning-backend services. The defaults grant neither; descriptor policy is not
authority without host validation of exact registration, requested backend and
installation ownership, and any captured controller. The initializer receives no
such services. See the
[installed schema](../plugin_runtime/README.md#prepared-catalog) and
[service binding](../../app/README.md#grouped-main-content).
[Application hosting](../../app/README.md#grouped-main-content) owns geometry and
native bindings. Focused checks are mapped in
[Main Content validation](../../docs/development/testing.md#focused-main-content-checks).

## Source File Display

[`display_source_file.dart`](lib/display_source_file.dart) defines
`displaySourceFileContributions` and `DisplaySourceFileContribution(display)`.
`DisplaySourceFileResolver.display(relativePath, select: ...)` captures one exact
registration: zero is unavailable, multiple are ambiguous, and explicit selection
never falls back. Retirement rejects a late result without retrying or cancelling
already admitted work. The caller supplies a path, not Session/Environment
authority; prepared hosting captures the current approved Session attachment.
The stock [Source Editor](../../plugins/source_editor/README.md) uses the same
finite operation for this route and its Open Source input. Resolver checks live in
[`test/display_source_file_test.dart`](test/display_source_file_test.dart).

## Shared Console

[`console.dart`](lib/console.dart) defines an additive extension point:
`ConsoleContribution(actions, openPrepared)` registers at `consoleContributions`.
Independent contributions coexist; there is no single winning console provider or zero/one/many
resolver. The host owns common tabs, creation-action discovery, selection,
visibility, confirmation, and bounded cleanup. Contributions own independent content,
not another tab strip. See [console architecture](../../docs/architecture/plugin-system.md#shared-console).

`ConsoleCreationAction(id, label, create)` has an ID local to its exact registration.
The host admits it with `ConsoleCreationAccess`, which captures one Session and
can transfer a `ConsoleContent` through `open`. Navigation does not retarget or
revoke already admitted creation. Access ends when that action's Future settles,
or earlier on owner retirement or host close; it is not reusable background
creation authority. Late content received after access ends is released rather
than published, and each content object may be transferred only once.

The host can deliberately expose a semantic Command over one exact creation action.
Console still owns current-Session admission and resource lifetime; the action ID
remains local and the public contract gains no Command context or authority API.
See the [contextual adapter](../../app/README.md#session-console) for exact capture,
collapsed-console reveal, and asymmetric retirement.

The optional `openPrepared` factory admits declared read-only content through the
same captured creation scope. A `ConsoleContentDescriptor(key, metadata, data)`
contains bounded, immutable structured plugin data, not a widget or callback from
the requesting view. Opening targets must be explicitly allowlisted by that
presentation and belong to the same exact installation and frontend generation.
The host deduplicates admitted and pending openings by exact console registration,
canonical Session object, and content key. Reopening focuses that content without
replacing its descriptor or logical state; another owner, generation, or Session
cannot acquire it by reusing the key.

Descriptor data and retained logical view state each have bounds of 256 nodes,
nesting depth 16, and 8192 UTF-16 string units. They may contain ordinary structured
values, not transcripts, executable objects, or retained evaluator callbacks.
The native host retains these values independently of the requesting Inspection
runtime and mounted console views. Closing the Inspection does not close admitted
content. A cold remount creates fresh resident access, not a replacement backend
binding; closing a read-only tab releases its presentation data and observation,
not the independently owned execution or durable history.

`ConsoleContent` supplies `metadata`, `isEligible(Session)`, `createPresentation`,
optional synchronous `closeAdvice`, `keepAlive` (default false), and `release`.
`keepAlive` opts into host-bounded residency after first selection, not eager
construction or guaranteed retention. A selected-only presentation consumes a slot
while selected too; hidden opted-in residents are least-recently-selected eviction
candidates. Prepared console metadata exposes the same explicit opt-in. The
[application host](../../app/README.md#session-console) owns the current count bound
and disposal accounting. Eligibility is content-owned;
the generic contract does not assume every console is a terminal or Environment
resource. `ConsoleTabRegistration` can update only its content's metadata and
request its removal, including while hidden. `ConsoleMetadata` keeps title,
description, and `ConsoleStatus` separate and bounds display text.

`ConsoleCloseAdvice` is advisory, not a veto or asynchronous settlement hook.
Missing, failed, or unknown advice requires host confirmation. Confirmed close,
content-requested removal, contribution retirement, and host shutdown invoke
release without needing a mounted view. `ConsoleCleanupResult.warning` is safe
user-facing text, not an exception dump; cleanup failure or timeout cannot restore
a removed tab or indefinitely prevent host cleanup.

`ConsolePresentationAccess` is distinct from content registration. `isActive`
describes the exact resident lifetime; `interaction` supplies a selected-only
`ConsoleInteractionAccess`, or null while hidden, and `changes` reports transitions
synchronously. Each selection creates a new interaction grant. User actions retain
and validate that exact grant, including after asynchronous work, rather than
querying a newer grant to revive old callbacks. Resident-authorized observation
and programmatic rendering may continue while hidden. Default selected-only
content loses its resident on deselection. Collapse, canonical Session change or
null, console unmount, and host close end the whole working set; eviction, observed
eligibility loss, content removal, and retirement permanently revoke the affected
access. Access validation and host reconciliation check current content eligibility
for the exact presented Session, including hidden residents. False or a throwing
predicate fails closed. Changing callback-captured state is not itself observable:
there is no polling, and revocation is synchronous once a host check observes loss.
Eligibility recovery requires fresh access through normal selection and cold
restoration; it cannot revive old epochs or eagerly mount hidden tabs. Eligibility
eviction does not release content or ask close advice. None of this stops a content
owner's independent execution/resource observation. Prepared read-only projection
hosting can copy already-owned scalar native state into its exact retained content record without
invoking a revoked presenter. The record contains no view objects or transcript;
new-view leases fence stale checkpoints and content removal clears it permanently.
The current [application host](../../app/README.md#session-console)
is Session-only; Task Browser exposes no console panel, toggle, or creation actions.

## Interpreted Bridges

The bridge libraries are interpreted-only stubs. App-owned eval declarations and
native implementations supply their behavior; calling a stub natively throws
`UnsupportedError`.

- `owning_backend_bridge.dart` supplies `OwningBackendRequestChannel` for generated
  unary and server-streaming clients via `AdeleStreamChannel`. Requests are limited
  to descriptor-allowlisted services on the
  exact sibling backend connection and configuration context captured by the host.
  There is no PluginId selection, arbitrary backend lookup, or retargeting after
  retirement. `owningBackend` strategy affinity requires exact host-verified
  registration origin and pins execution to that same strategy binding.
  Streams open only on listen, with pause/resume/cancel propagated to native
  transport. Retirement cancels observation and fences queued eval callbacks;
  it does not cancel independently owned backend work. Native stream errors use
  fixed safe text, and malformed generated items terminate only that observation.
  The pinned evaluator misdeclares `Stream.listen`'s return type; interpreted
  consumers retain the subscription as `dynamic` for pause/resume/cancel. The
  native adapter corrects error/done callback dispatch locally, without a plugin
  codec or SDK/dependency patch. Runtime null callbacks are supported, but the pin's
  SDK declarations still reject literal null callback arguments at compilation;
  omit unused callbacks or use the tested dynamic-null shape. `PreparedFrontend` can host this bridge independently
  of Session execution services. `settleOwningBackendOperation(Future<dynamic>)`
  returns `[true, value]` or `[false, null]`, preserving generated interpreted
  success values while containing native Future rejection. It grants no authority;
  originating operations still enforce their captured lifetime. Rich Inspection
  and read-only console hosting do not resolve a strategy or acquire Session
  execution access merely to use an allowlisted backend service.
- `capability_bridge.dart` supplies generic callable Capability consumption to
  opted-in prepared Main Content panes. `discoverCapabilityProviders(id, major)`
  returns copied `{providerId, pluginId, displayName, serviceId}` metadata in
  registry order: an empty list means no provider, null means unavailable or denied
  access. `resolveCapabilityProvider(id, major, serviceId, providerId)` accepts the
  generated contract's expected service ID and a nullable explicit provider ID;
  it returns an opaque handle or null, never a substitute provider. A
  `CapabilityRequestChannel(handle)` implements `AdeleStreamChannel` for ordinary
  generated clients. `releaseCapabilityProvider(handle)` releases its access and
  observations, not backend-owned work. Handles are private to one presentation,
  with at most 64 retained at once; consumers must release unused handles, including
  stale ones. `settleCapabilityOperation(Future<dynamic>)` has the same safe
  `[true, interpretedValue]` / `[false, null]` result as owning-backend settlement.
  Generated eval DTO/stream restrictions and subscription callback limitations
  above apply unchanged. New requests through stale handles fail; admitted unary
  work may complete after registration-only retirement, while provider retirement
  cancels stream observations. Frontend/presentation retirement fences both.
  This supplies neither arbitrary backend services nor contextual host authority;
  see [Capability consumption](../../docs/architecture/contracts-and-capabilities.md#prepared-frontend-capability-consumption)
  for the exact cross-system lifetime and authority rules.
- `environment_capability_bridge.dart` is a separate contextual unary path for
  Main Content panes declaring `environmentReadCapabilities`; it does not widen
  `capability_bridge.dart` or the `capabilities` allowlist. Initializers, input
  actions, finite operations, and other presentation roles receive no access.
  `resolveEnvironmentCapabilityProvider(id, major, serviceId, providerId)` returns
  `Future<String?>`: an opaque presentation-local handle, or null for denied,
  unavailable, incompatible, or exhausted access. Resolution captures the canonical
  Session Environment and selects only an exact associated provider; explicit
  selection never falls back. There is no discovery API or caller-selected
  Environment. `EnvironmentCapabilityRequestChannel(handle)` implements only
  `AdeleRequestChannel`, forwarding generated unary calls through
  `requestEnvironmentCapability(handle, method, payload)`, with no streaming API.
  Each request admits a fresh operation-scoped Environment read grant; no host
  token, configuration route, mutation, process, storage, execution, or approval
  service is exposed. `releaseEnvironmentCapabilityProvider(handle)` releases
  bounded handle bookkeeping and revokes its grants without cancelling independent
  backend work. Stale handles never follow replacements. Unlike context-free
  admitted unary calls, contextual success requires the captured selection and
  presentation to remain valid through settlement.
  `settleEnvironmentCapabilityOperation(Future<dynamic>)` preserves generated
  interpreted success values as `[true, value]` or contains failure as
  `[false, null]`, without native diagnostics or an extension of authority. The
  [contextual admission boundary](../../docs/architecture/contracts-and-capabilities.md#contextual-unary-capability-invocation)
  owns the exact host grant and retirement semantics; the
  [catalog schema](../plugin_runtime/README.md#prepared-catalog) owns the opt-in.
- `session_execution_bridge.dart` supplies current Session identity, immutable
  execution snapshots and subscriptions, asynchronous `startSessionRun`, retained
  activity reads, and inspect/build operations over emitted opaque handles.
  `String? openSessionRunActivity(String runId)` accepts a semantic Run ID, validates that accepted preparing/live/waiting or terminal
  activity belongs to the presented Session, and returns a read-only opaque handle
  for those same activity/Inspection paths, or null when unavailable. It grants no
  execution or approval authority and creates no Run. Run start resolves when
  scheduled, not when execution completes. A fresh presentation receives fresh
  handles; retirement never revives prior access. Accepted preparation and startup
  failure remain readable with their actual state and no invented evidence.
  A stored terminal record without evidence remains unavailable. Execution snapshots include
  `sessionStateRevision`, a semantic invalidation after strategy materialization
  and terminal settlement, distinct from activity/evidence revision. Consumers
  capture it before hydration and recheck after subscribing and asynchronous reads
  to discover missed canonical changes without polling. Generic
  `settleSessionOperation(Future)` returns `[true, value]` or `[false, null]` to
  contain native Future rejection that the evaluator cannot reliably unwind;
  it preserves interpreted success values without codecs or exception transport.
  Tool output handles retain immutable proposal arguments, rejection evidence,
  prepared identity/arguments, ordered lifecycle/policy/approval/progress evidence,
  and public outcome data, never executable objects or diagnostic exceptions.
  `buildSessionExecutionStatus()` places the existing native Run status and approval
  controls inside the requesting pane. The plugin chooses placement; the host
  retains the controller, exact approval identity, and decision validation. Removing
  that presentation revokes its actions, not its Run.
  Model/tools/policy, approval authority, Run evidence, and Inspection remain
  host-owned. Canonical
  strategy history and composer semantics are not part of this bridge.
- `directory_picker_bridge.dart` supplies only `Future<String?> pickDirectory()`.
  A selector operation gets one asynchronous native call through a revocable
  bridge; plugin code owns path-to-URI semantics. This grants no backend RPC or
  Session/Environment authority.
- `terminal_surface_bridge.dart` supplies `String requestTerminalSurface()` and
  `Widget buildTerminalSurface(String handle)` for a host-selected native terminal
  surface. Handles are presentation-scoped and revocable even after widget
  construction. There is no caller-selected mode, resource lookup, output feed,
  execution, or disposal API. Native owners and their emulator state outlive views;
  fresh presentations require fresh access. Public contracts expose no terminal
  library types. The [application adapter](../../app/README.md#native-terminal-surface)
  owns interactive/read-only policy, bounds, attachment, and native callbacks.
- `code_editor_bridge.dart` supplies request/build, immutable metadata reads,
  deliberate `{text, revision}` snapshots, and coalesced invalidation subscriptions
  for one host-selected native editor. Every call checks the presentation's handle
  against that same owner; retired or foreign handles cannot select another editor.
  Metadata is `ready`, `readOnly`, `language`, and `revision`, without text or
  selection offsets. Revision counts component notifications, including possible
  selection/layout changes, not content edits or a filesystem version. Snapshots
  are synchronous text observations, not save transactions or a promise about
  uncommitted composition; notifications carry no text payload.
  Native input supplies ordinary editing, selection, clipboard, and undo. Retiring
  interpreted access is not cancellation of already admitted native work on the
  same editor. Presentation disposal releases access and observation, not the
  independently owned text/undo. There is no controller, mutator, mode upgrade,
  selection-range API, global document lookup, or raw CodeForge export.
  See the [public contract](lib/code_editor_bridge.dart),
  [application owner](../../app/README.md#native-code-editor), and
  [prepared-EVC tests](../../app/test/code_editor_bridge_test.dart). This bridge
  registers no Main Content/editor role and supplies no file/save, diff, or LSP API.
- `contribution_bridge.dart` supplies explicitly opted-in, current-window copied
  primitive records and native editor construction for one exact Main Content
  contribution. Keys and record semantics belong to the plugin; data contains no
  widgets, callbacks, controllers, or retained evaluator. Supplied-text
  `createContributionCodeEditor` rejects an existing ID without replacement; the
  native text/undo owner outlives attachments, with fresh per-pane access through
  `code_editor_bridge.dart`. Deliberate snapshots/state reads and explicit release
  remain scoped to that contribution, not a global document lookup.
  `invokeContributionOperation` admits only descriptor-declared finite entrypoints
  with copied arguments and captured context. Admitted operations can settle into
  retained data after navigation without reviving a departed view.
  `readContributionArguments()` returns a nullable copied map: `{}` for active
  presentations or argument-free operations, and null after retirement. Identity
  and pane ID reads belong only to `main_content_bridge.dart` below.
  `confirmContribution(request)` supplies native two-choice confirmation for a
  finite operation. The request contains exactly four nonempty strings: `title`,
  `message`, `acceptLabel`, and `cancelLabel`. The plugin owns the wording, when
  to ask, and the meaning of acceptance; dismissal, unavailable support, malformed
  requests, and retired access return false. Data subscriptions are coalesced
  invalidations, not text feeds. See the
  [public stub](lib/contribution_bridge.dart),
  [catalog opt-ins](../plugin_runtime/README.md#prepared-catalog), and
  [application retention/authority](../../app/README.md#source-editor-hosting).
- `environment_access_bridge.dart` supplies only `readEnvironmentTextFile(path)`
  and conditional `replaceEnvironmentTextFile(path, text, expectedRevision)` for
  an admitted finite operation's captured Environment. Views, initializers, and
  operations without permission or captured context receive `binding_unavailable`.
  Read success is `{ok: true, path, text, sizeBytes, revision}` with complete text,
  normalized path, and opaque provider revision; replacement success is
  `{ok: true, revision}`. Failure is `{ok: false, failure: {code, message, details}}`,
  preserving declared provider failures. Unknown failures use
  `operation_unacknowledged` with `The Environment operation was not acknowledged.`
  This reports neither local-buffer state nor rollback. Capture lifetime and
  explicit-operation recovery belong to the
  [frontend grant](../../docs/architecture/contracts-and-capabilities.md#frontend-behavioral-operations);
  the [public stub](lib/environment_access_bridge.dart) defines the narrow API.
- `main_content_bridge.dart` supplies `readMainContentContext()` with only the
  captured `{sessionId, strategyId, taskId, environmentKey}`, plus
  `readMainContentPanes()` and `readMainContentPaneId()`, and boolean-returning
  `openMainContentPane(id, title, canClose)`, `setMainContentPaneTitle(id, title)`,
  `setMainContentPaneOrder(ids)`, `removeMainContentPane(id)`, and
  `focusMainContentPane(id, keyboardFocus)`.
  Requests affect only the originating contribution's collection. Rejected requests
  return false; retired reads return an empty context, snapshot, or ID. Environment
  identity comes from canonical `SessionEnvironmentAuthority`, without provider
  resolution or materialization and independently of retained-data, native-editor,
  file, execution, or backend grants. Context is available to initialization,
  input/pane views, and finite operations; Session-less exit receives `{}`, not a
  fabricated current Environment. Identities are data, not authority. The current
  pane ID is empty outside a pane presentation. A short-lived initializer can
  inspect the context and open no panes without acquiring services, or open initial
  panes, then loses bridge access; each pane has an independent presentation runtime
  with its own scoped bridge. Closing every pane leaves no autonomous evaluator
  updating the collection. Declared actions and finite operations remain separate
  entrypoints, not hidden residency. A fresh Session attachment may initialize
  again over explicitly retained data/native owners.
  Native editor access, when supplied, is a separate per-pane binding, not an
  editor lookup through these local IDs.
- `terminal_projection_bridge.dart` is a separate, presentation-owned read-only
  projection API: request/build, bounded feed/reset, revocable replay yields, immutable observation,
  follow/local scroll, and change subscriptions. Each rich Inspection or read-only
  console resident has its own revocable handle, parser, buffer, and viewport; none
  reuses an interactive terminal or another view's projection. The public contract
  fixes 80 columns, 6 or 20 viewport rows, and 200 retained lines, with bounded
  accepted-prefix feeding and no queued remainder. The plugin explicitly chooses
  always-follow or interactive-follow policy, independent of geometry. Interactive
  scroll-away/selection freezes feeding; user return to the rendered end may resume
  a live-tail view but not a plugin-selected historical window. Programmatic
  scrolling never grants that intent. Resident-authorized feeds and observation
  survive warm deselection, while local user interaction requires its exact
  selected epoch. Always-follow leaves vertical scrolling to
  its parent and never persistently pauses for selection. Local scroll, selection,
  and explicit copy do not grant input,
  paste, terminal replies, resize, process, signal, or backend authority. Plugin
  readers own fetching and history position; the native projection is not history
  storage. `hideTerminalProjection(handle)` suppresses paint and interaction while
  preserving layout. `revealTerminalProjection(handle)` settles only after the
  intended viewport has laid out and the first revealed frame has painted; it
  returns false when the request is revoked or superseded. The `ready` snapshot
  field exposes presentation readiness, not transcript completeness. Plugins choose
  finite restore targets and use this gate for reconstruction, not ordinary live
  pages. See the [bridge contract](lib/terminal_projection_bridge.dart) for the
  exact operations and [app adapter](../../app/README.md#native-terminal-surface)
  for native hosting.
- `console_bridge.dart` supplies
  `openPreparedConsole(extensionId, key, title, data)` to an authorized rich
  presentation. It settles as `[true, null]` or `[false, safeErrorString]`; its
  strings and structured data cannot choose an arbitrary installation, generation,
  or Session. An admitted console view receives `readConsoleContentData()`,
  `readConsoleContentState()`, and `writeConsoleContentState(Map)`. State writes
  are bounded and return false after resident revocation; readers save logical
  changes while active rather than relying on disposal-time writes.
  `readConsoleInteraction()` captures a positive selected epoch, or zero while
  hidden. User callbacks retain it and check `isConsoleInteractionActive(epoch)`
  before effects and after awaits. `subscribeConsoleInteraction` and its matching
  unsubscribe provide coalesced deferred invalidation for rebuilding controls;
  delayed notification never extends the native grant. No originating eval
  callback is retained as a content factory. Missing host/target access is explicitly
  unavailable, not another contribution or a native content substitute.
- `environment_terminal_bridge.dart` supplies
  `openEnvironmentTerminal(label, liveCloseMessage, followTitle, removeAfterExit)`
  only to an admitted interpreted console creation action. It returns
  `[true, null]` or `[false, safeErrorString]`. The native adapter validates and
  copies these policy values out of the short-lived operation runtime; no
  evaluator callback becomes retained resource policy. The host captures the
  canonical Session Environment association, with no caller-selected Environment,
  resource lookup, or returned execution handle. Default-shell selection belongs
  to the [Environment provider](../environment/README.md#interactive-terminals).
  Later content views use the separate terminal-surface bridge above, with fresh
  presentation-scoped access to the retained owner.
- `task_browser_bridge.dart` supplies `isTaskBrowserActive()`, `readTaskBrowser()`,
  `selectTask(String?)`, `createTask(String title)`,
  `createSession(String optionHandle)`, `openSession(String sessionId)`, and
  `subscribeTaskBrowser` / `unsubscribeTaskBrowser` with a retained
  `void Function()` listener. Each action returns `Future<List<dynamic>>`, settling
  as `[true, null]` or `[false, safeErrorString]`, never a native diagnostic
  exception. Null selection clears the selected Task. The bridge is scoped to the
  presented Project and exact frontend lifetime; IDs do not confer authority, and
  a Session creation handle identifies a retained host choice, not a strategy ID.
  The active query is false after retirement even if the view and its read-only
  snapshot are retained for exit. Check it before local mutations and after awaits.
- `session_presentation_lifecycle_bridge.dart` supplies
  `registerSessionPrepareToDeactivate(Future<bool> Function() callback)` and
  matching `unregisterSessionPrepareToDeactivate`. A presentation retains and
  unregisters the same callback object; only one hook may be registered per pane
  presentation. For actual host-requested Session departure, the host aggregates
  the contributed panes' hooks and awaits acceptance before leaving, blocks input
  while settling, and keeps live panes on rejection or failure. Changing pane focus,
  title, order, or width is not Session departure. No hook means
  no local state to flush. Registration grants no navigation authority; retirement
  revokes the exact hook and rejects late success. This is not a general shutdown,
  cancellation, or persistence service.

### Task Browser snapshot

`readTaskBrowser()` returns structured presentation data, projected by the app's
`TaskBrowserSource`. The current shape is:

| Field | Data |
| --- | --- |
| `project` | `{id, displayName}` |
| `selectedTaskId` | Task ID or null |
| `tasks` | List of `{id, title, sessionCount, executionCounts}` |
| `tasks[].executionCounts` | `{preparing, running, waiting, terminal, completed, cancelled, failed}` integer Session counts |
| `selectedTask` | Null, or `{id, title, primaryEnvironment, sessions, sessionCreationOptions}` |
| `selectedTask.primaryEnvironment` | Null, or `{id, providerId}` |
| `selectedTask.sessions` | List of `{id, strategyId, displayName, canOpen, executionAvailable, executionStatus}` |
| `selectedTask.sessionCreationOptions` | List of `{opaqueHandle, displayName}` |

IDs and labels are strings, counts are integers, and `canOpen` and
`executionAvailable` are booleans. `displayName` uses the orchestration
contribution's optional label with the stored strategy ID as fallback, not a
frontend registration. Creation options come from exact uniquely resolved
`orchestrationStrategyContributions`, including backend-only strategies.
`executionStatus` is `idle`, `preparing`, `running`, `waitingForApproval`,
`completed`, `cancelled`, or `failed`. These values project the latest retained
execution owner's state, independently of presentation availability; no owner is
allocated just to enumerate or observe a Session. `idle` includes Sessions without
a retained execution owner. Task counts count Sessions, not historical Runs:
`waiting` counts `waitingForApproval`, `terminal` sums completed/cancelled/failed,
and idle Sessions contribute only to `sessionCount`. These are not persisted
Task states or plugin/tool-specific progress. Generic status changes use the
existing frame-coalesced browser subscription rather than packet-level workbench
rebuilds. Waiting is read-only attention; approval remains on the exact Session's
host-owned surface, never in this bridge.

Canonical Sessions remain openable through `canOpen` even with no strategy backend,
frontend, or Main Content contribution. `executionAvailable` describes current
unique live strategy resolution, not model readiness or a promise that a Run can
execute. It does not gate navigation or erase retained `executionStatus`.
The host revalidates exact strategy creation choices and Project/Task membership
on action; the frontend cannot select authority through
IDs. Snapshots expose no provider state, Environment facets, Chat history, database
handles, or backend channels. Browsing and opening retained Sessions do not
materialize Environments or start Runs. See the
[application host map](../../app/README.md#task-browser) for implementation anchors.

### Strategy-owned state

Stock Chat uses its own Contract-generated `ChatSessionServiceClient` for canonical
snapshot/append/configuration operations and the separate execution bridge for
Runs. Its frontend owns asynchronous composer acceptance, history refresh, and
activity grouping. Its durable user-entry-to-Run association is distinct from a
view-local opaque handle; after hydration it can open historical activity only
where a live handle is absent. Neither canonical Chat history nor Chat-specific
interpretation lives in this package or the generic execution core.

## Activity Presentation

Tool compact and rich Inspection contributions match exact `ToolId`; native
compact and rich contributions match exact safe presentation kind. Tool factories
receive a read-only `ToolActivityInspectionSource`; native factories receive
immutable `ModelNativePresentation`, not raw provider envelopes, including when
rendering restored terminal evidence. Compact and rich
roles are distinct, not size variants of one host card schema.

`ToolActivityInspectionSource.sessionId`, `.runId`, and `.snapshot.id` identify
one canonical invocation occurrence. The interpreted
`ToolActivityInspectionSnapshot` exposes their strings as `sessionId`, `runId`,
and `toolInvocationId`, alongside immutable arguments and bounded public outcome
facts. These are not aliases, provider call IDs, execution handles, transcript
cursors, or authority. Live and historical activity use the same source boundary;
updates preserve its identities and replace only the observed snapshot.

Exact zero/one/many resolution and registration liveness apply to every role.
Missing or failed rich presentation is unavailable; compact presentation retains
bounded factual identity or provider-approved text without parsing plugin fields.
Factories receive no execution, approval, navigation, or inspect callbacks. The
common host owns Inspection interaction, card identity/order, collapse/dismiss,
and group-row composition; strategy frontends own grouping and timeline placement.

Prepared rich Inspection may separately receive descriptor-allowlisted owning
backend reads, declared console opening, and an independent read-only projection.
Compact presentation receives only the factual source and acquires none of those
bridges. Missing backend or console access does not discard canonical Inspection
facts or authorize a substitute backend. Exact descriptor fields belong to the
[runtime catalog](../plugin_runtime/README.md#prepared-catalog).

Frontend activation and backend readiness are independent. Missing/corrupt EVC or
view failure does not trigger compilation, native presentation fallback, or backend
replacement. Prepared hosting and runtime-local failure containment belong to the
app, not this public API. Terminal evidence persistence belongs to the
[execution-history owner](../../docs/architecture/execution-model.md#terminal-execution-history),
not UI; it does not restore open cards, handles, or workbench layout. Broader
workbench, Commands, workbench persistence, and general third-party interpreted
Flutter compatibility remain deferred.
