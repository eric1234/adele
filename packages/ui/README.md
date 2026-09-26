# ADELE UI

`adele_ui` is the experimental public Flutter package for semantic Session and
read-only activity presentation. It depends only on Flutter and public ADELE
contracts, never application code, internal host implementations, or stock plugins.
Product, orchestration, model tools, and the extension registry remain pure Dart.

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
