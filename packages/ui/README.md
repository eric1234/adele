# ADELE UI

`adele_ui` is the experimental public Flutter package for semantic Task Browser,
Session, and read-only activity presentation. It depends only on Flutter and public
ADELE contracts, never application code, internal host implementations, or stock plugins.
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

## Session Presentation

`SessionPresentationContribution(strategyId, displayName, createPresentation)`
registers at `sessionPresentationContributions`. Its factory is
`Widget Function(Session)`. `SessionPresentationResolver` matches the canonical
Session's strategy exactly: zero is unavailable, one supplies an exact binding,
and multiple matches are ambiguous. There is no default, priority, or fallback.
The host retains views across updates and removes them when their registration
retires; replacement requires fresh resolution. Presentation failure does not
invalidate canonical product state or independently hosted backend execution.

Prepared Session descriptors use generic hosting, not stock adapter names. They
supply `displayName`, `strategyId`, `extensionId`, `library`, and `entrypoint`, with
optional `backendServices` and `strategyAffinity`. Manifest version remains 1;
`hostAdapter` is no longer supported. See the exact
[installed schema](../plugin_runtime/README.md#prepared-catalog).

## Interpreted Bridges

The bridge libraries are interpreted-only stubs. App-owned eval declarations and
native implementations supply their behavior; calling a stub natively throws
`UnsupportedError`.

- `owning_backend_bridge.dart` supplies `OwningBackendRequestChannel` for generated
  unary clients. Requests are limited to descriptor-allowlisted services on the
  exact sibling backend connection and configuration context captured by the host.
  There is no PluginId selection, arbitrary backend lookup, or retargeting after
  retirement. `owningBackend` strategy affinity requires exact host-verified
  registration origin and pins execution to that same strategy binding.
- `session_execution_bridge.dart` supplies current Session identity, immutable
  execution snapshots and subscriptions, asynchronous `startSessionRun`, retained
  activity reads, and inspect/build operations over emitted opaque handles.
  `String? openSessionRunActivity(String runId)` accepts a semantic Run ID, validates that retained
  activity belongs to the presented Session, and returns a read-only opaque handle
  for those same activity/Inspection paths, or null when unavailable. It grants no
  execution or approval authority and creates no Run. Run start resolves when
  scheduled, not when execution completes. Generic
  `settleSessionOperation(Future)` returns `[true, value]` or `[false, null]` to
  contain native Future rejection that the evaluator cannot reliably unwind;
  it preserves interpreted success values without codecs or exception transport.
  Tool output handles retain immutable proposal arguments, rejection evidence,
  prepared identity/arguments, ordered lifecycle/policy/approval/progress evidence,
  and public outcome data, never executable objects or diagnostic exceptions.
  Model/tools/policy,
  approval authority, Run evidence, and Inspection remain host-owned. Canonical
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
  unregisters the same callback object; only one hook may be registered. For
  host-requested navigation, the host awaits `true` before leaving, blocks input
  while settling, and keeps the live view on rejection or failure. No hook means
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
| `tasks` | List of `{id, title, sessionCount}` |
| `selectedTask` | Null, or `{id, title, primaryEnvironment, sessions, sessionCreationOptions}` |
| `selectedTask.primaryEnvironment` | Null, or `{id, providerId}` |
| `selectedTask.sessions` | List of `{id, strategyId, presentationName, available}` |
| `selectedTask.sessionCreationOptions` | List of `{opaqueHandle, displayName}` |

IDs and labels are strings, counts are integers, and availability is boolean.
Unavailable Sessions remain in the snapshot. Availability describes current
presentation/strategy resolution and required affinity, not a promise that a view
will render or a Run can execute. The host revalidates exact creation choices and
Project/Task membership on action; the frontend cannot select authority through
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

Exact zero/one/many resolution and registration liveness apply to every role.
Missing or failed rich presentation is unavailable; compact presentation retains
bounded factual identity or provider-approved text without parsing plugin fields.
Factories receive no execution, approval, navigation, or inspect callbacks. The
common host owns Inspection interaction, card identity/order, collapse/dismiss,
and group-row composition; strategy frontends own grouping and timeline placement.

Frontend activation and backend readiness are independent. Missing/corrupt EVC or
view failure does not trigger compilation, native presentation fallback, or backend
replacement. Prepared hosting and runtime-local failure containment belong to the
app, not this public API. Terminal evidence persistence belongs to the
[execution-history owner](../../docs/architecture/execution-model.md#terminal-execution-history),
not UI; it does not restore open cards, handles, or workbench layout. Broader
workbench, Commands, workbench persistence, and general third-party interpreted
Flutter compatibility remain deferred.
