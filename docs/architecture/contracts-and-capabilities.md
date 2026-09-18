# Contracts and Capabilities

## Status

Generated typed unary and server-streaming/cancellation transport, active one-to-many capability routing, exact generation bindings, configured OpenAI provider contexts, and the common ModelProvider capability are implemented in the maintained development foundation. Backend-ready extension advertisements, host adapters over the existing extension registry, and operation-scoped backend-to-host calls support remote inference sources and model tools. Model-tool execution uses host-to-backend server streaming; authorized reads/mutations use reverse unary calls and foreground processes use reverse server streaming. This is not general symmetric RPC.

The broader recursive extension model described in [`plugin-extension-model.md`](plugin-extension-model.md) is accepted architecture but mostly unimplemented. Capabilities should therefore be understood as one specialized callable part of that future extension architecture rather than as a universal registry for every kind of plugin participation.

## Separate questions

Contracts and capabilities solve different problems:

| Concern | Question |
| --- | --- |
| Contract | How do typed values and asynchronous operations cross a runtime boundary? |
| Capability | Which compatible provider handles a callable semantic request? |
| Extension point | Where and how may plugins participate in a typed composition? |

A capability can be implemented using a generated contract when the operation crosses a runtime boundary, but capability identity/selection is separate from transport. Likewise, a UI summary extension or inference-context extension may be an extension point without being a callable capability.

The constrained Phase II-A generated unary transport and Phase II-B generated server-streaming/cancellation transport are implemented and used by maintained plugin contracts where applicable. The scripted model fixture retains a generated unary reference method, while the Phase IV application adapter consumes generated ModelProvider streams and emits kernel semantic model events incrementally.

The public `adele_model_provider` package defines capability major 1 with generated streaming, typed ordered input, live text observations, authoritative completed output, and explicit semantic terminal settlement. Ordered input/output wrappers exclusively own optional provider item identity and native metadata; tool-proposal payloads own only tool-call correlation, name, and arguments. The ordered input/output union also has one native-only item whose required opaque envelope occupies an independent list position without semantic text/tool payload. This preserves provider item cardinality and order while keeping provider-specific reasoning or compaction outside common semantics.

Capability transport plus Phase III active provider registration, deterministic discovery, exact-major resolution, and generated-client invocation are implemented for the maintained resource-inspector fixture and common ModelProvider path.

## Contracts

Plugin contract source is shared by frontend and backend packages and should normally describe immutable snapshot values. A value received across a runtime boundary is reconstructed; its object identity is not shared with the sender.

The internal generator treats contracts as a constrained IDL embedded in Dart and provides typed clients, dispatchers, codecs, request handling, and structured errors. A contract library declares one or more local, non-empty `@AdeleService` services with unary `Future<T>` and server-streaming `Stream<T>` methods. Each service has its own client/dispatcher while sharing local DTO/failure codecs; Environment's provider, authorized-read, authorized-mutation, and authorized-process services share its value and failure declarations. Zero declared `@AdeleFailure` types is valid, as in remote inference-source transport: no domain-specific failure is required, and unrecognized remote failures retain their transport semantics.

Values use one unnamed generative constructor with required named parameters, schema enums and values must be declared in the contract source library rather than imported, wire IDs use a conservative ASCII segment grammar, and every transported double must be finite. Client/bidirectional streaming, ambient callbacks, general symmetric RPC, replay, and broader schema composition remain future work.

The contract annotation import is exactly canonical, unprefixed, and without combinators or configurations. The plugin API import has the same shape exactly when the extracted schema semantically uses canonical `ResourceRef`; prefixed plugin API imports do not require it otherwise. Additional imports from either package, including repeated canonical URIs with `show` or `hide`, and every other import must be prefixed. Conditional imports whose default or configured URI is within either package are rejected. Every import prefix shares the generated top-level collision namespace with contract declarations, generated identifiers, unqualified ADELE runtime names, and SDK names; `ResourceRef` is reserved conditionally.

Schema names match `[A-Za-z][A-Za-z0-9_]*` across annotated declarations and members plus reachable enums and enum values. Private, dollar-prefixed, and non-ASCII names are outside the IDL, although unrelated unreachable private helpers and enums remain ordinary implementation details. These restrictions may be permanent rather than promises of future Dart-language parity.

Generated code should hide ports, wire formats, request IDs, subscriptions, and transport details from plugin code. Contract declarations remain lightweight and independent of compiler or generation tooling.

The generated transport layers over the proven process-hosted communication path through a transport-neutral request channel. Its annotations and generator remain experimental; no general schema compatibility policy is accepted yet. Dispatch explicitly decodes the envelope and method, decodes arguments, invokes the service, and encodes the result as separate stages. Malformed requests are `invalid_request`; every service-thrown undeclared exception, including `AdeleProtocolException`, is `internal_error`; and backend results or declared failure details that violate the generated response contract become opaque `backend_contract_violation` failures. URI values, including `ResourceRef.uri`, must be reconstructible absolute URIs.

The same absolute-URI rule applies recursively to direct values, `ResourceRef.uri`, annotated value fields, lists, and nested lists. Clients perform request encoding before invoking the channel, so invalid local URIs are preflight failures. JSON map transport rejects map, list, and mutual cycles and container depth beyond 64 while accepting shared acyclic subgraphs. Value constructor exceptions are opaque malformed-value failures at the client and dispatcher boundaries, and each dispatcher failure remains isolated to its request.

Annotation interpretation is multiplicity-aware: repeated role, method, and field annotations and mixed class roles are invalid regardless of declaration order. Generated implementation state and temporaries occupy indexed `_adele` names rather than contract namespaces, and public schema methods such as `dispatch` coexist with the generated client, dispatcher, and backend service. Every contract-derived string entering generated Dart source is emitted through one single-quoted literal escaping path.

Supported core and async types are checked by exact semantic library identity, not spelling: core scalars, collections, `Uri`, and `Object` come from `dart:core`, method wrappers are exact `dart:async` `Future` or `Stream`, and `ResourceRef` is the exact canonical plugin API declaration. Type aliases are excluded from the transported closure recursively, including the outer wrapper, while unused implementation aliases remain permitted. Service parameters are explicitly typed required positionals; optional, named, covariant, initializing-formal, super-formal, function-typed, and implicitly dynamic forms are rejected.

`ContractDiagnostic` locations retain the precise import, annotation, method, parameter, field, constructor, enum, or enum-value source node when available; whole-library constraints use the compilation unit.

Committed transport is checked in normal CI. Development plugin preparation also checks the requested plugin independently: the manifest-selected contract package's `pubspec.yaml` name determines `lib/<package-name>.dart`, and that absolute source is passed explicitly to `contract_codegen --check --source`. This keeps stale transport failure local to the plugin and ahead of compilation.

Server-streaming uses the existing shared backend-host path. Generated clients open lazily and decode ordered typed items. Generated dispatchers hide producer iteration, cancellation, and terminal failure mapping. A fixed one-item credit window means paused consumers stop producer advancement after the already-granted item and cancellation reaches the producer iterator. Streams remain bound to their exact provider generation and fail rather than migrating when that generation disappears.

### Transport version policy

Both `backendHostProtocolVersion` and `adelePluginBackendProtocolVersion` are
currently 1. Before the first release, the unstable wire may change in place
without incrementing these versions. Increment a transport version only when
released artifacts establish a compatibility boundary, not for unreleased
development changes.

Artifacts must match the relevant protocol version exactly, and the runtime,
shared host, and backends must be rebuilt as one coherent set after wire changes.
Matching version numbers do not make prior development artifacts compatible;
those artifacts are unsupported. There is no compatibility layer, negotiation, or
shim for them. These transport versions are separate from capability majors and
the unchanged version-1 installed manifest.

## Capability semantics

| Kind | Semantics | Directional examples |
| --- | --- | --- |
| Action | Brokered one-shot request/response operation | `DisplaySourceFile`, create/open a resource, perform one review operation |
| Service | Sustained typed capability | `ModelProvider`, Environment filesystem/process access, `ConsoleService` |
| Event | Fact that has occurred | `SessionCreated`, `ModelInvocationSettled`, plugin-defined domain events |

Actions, Services, and Events retain distinct semantics even if they eventually share some registration or transport infrastructure.

Events are not provider-selected callable operations. They are read-only fact notifications: a subscriber cannot change whether the announced fact occurred, and subscriber failure normally does not retroactively fail the producer. Events do not imply durable replay/history. A domain that needs historical queries should expose that separately.

The final public mechanism for generic Event publication/subscription is not implemented.

## Capabilities inside the extension model

ADELE's long-term architecture uses **Extension Point** as the broader composition concept.

Capabilities are appropriate when another component needs callable functionality from one of potentially several compatible implementations. Other extension points may instead collect all applicable UI fragments, gather structured inference contributions, or implement plugin-specific composition semantics.

The existing capability registry should therefore remain focused on callable provider resolution rather than becoming a universal registry for every UI, Event, Command, or composition extension.

Plugins may define extension APIs of their own. Depending on a shared interface definition is acceptable; depending on a specific implementation plugin being active is generally not required. Runtime composition should prefer typed discovery and graceful zero/one/many behavior over hidden activation chains.

## One-to-many provider resolution

Several plugins may implement one Action or Service:

```text
DisplaySourceFile
|-- ADELE Internal Source Editor
`-- External Editor launcher
```

The Phase III active registry allows a caller to:

- check whether a compatible provider is available;
- enumerate all compatible providers;
- invoke ADELE's deterministic default provider;
- explicitly select and invoke another provider.

Callers must handle zero, one, or many providers. The in-memory host-owned active registry orders discovery by higher provider rank and then stable provider ID; default resolution selects the first result, while explicit resolution never falls back. Exact positive major-version matching is provisional. Bindings retain one runtime generation and become stale when its registration closes.

ADELE owns deterministic default resolution; a provider cannot declare itself globally primary. The current rank-based default is an implemented deterministic fallback, not the final user/profile preference system. Persistent preferences, profile-aware routing, richer compatibility negotiation, dynamic suitability, and contextual default policy remain deferred.

The long-term convention is host-owned contextual default selection with explicit alternatives when useful. For example, the Internal Source Editor and External Editor may both provide `DisplaySourceFile`; configuration can choose the normal provider while a UI exposes alternates. Likewise, Git Worktree and Docker may later provide the same Environment-provider interface.

Public capability, provider, and plugin identities share a lowercase reverse-domain ASCII grammar. Dot-separated segments begin with a letter and may contain digits or internal hyphens; underscores are not valid identity characters. A missing capability and a capability available only at other active major versions are separate structured resolution failures.

## Live discovery and stable binding

Future composition should be able to react when providers appear or disappear. That does not change the existing execution rule:

```text
live provider set
    may change for future operations

resolved binding
    remains tied to one exact active generation
```

An already-resolved model/tool operation must not silently migrate to a restarted provider. A new generation can participate only in a new resolution/materialization cycle.

## Backend-ready advertisements

Installed metadata stays separate from active capability and extension registration.
`adele_plugin.installation.json` identifies prepared components; it declares no
providers or configuration contexts and is not proof of readiness. The owning
backend entrypoint supplies optional `capabilityExposures` on its existing isolate
`ready` message. The shared host forwards that list on `pluginReady`, and runtime
retains it on the exact `PluginBackendConnection`. Omission means zero capabilities,
not a stock fallback or a failed handshake.

Public pure-Dart `adele_contract.AdeleCapabilityExposure` carries:

| Field | Meaning |
| --- | --- |
| `providerId` | Stable public provider identity |
| `capabilityId` | Public capability identity |
| `capabilityMajorVersion` | Positive exact-match capability major |
| `serviceId` | Generated contract service routed by the endpoint |
| `displayName` | Nonblank provider display name |
| `configurationContext` | Explicit context token scoped to this connection generation |
| `rank` | Optional integer, default zero; existing deterministic selection semantics |

Plugin identity is deliberately absent: the installation/connection is authoritative
and the advertisement cannot replace it. Malformed advertisements fail that backend
attempt. `PluginCapabilityActivation.registerAdvertised` maps advertisements to
existing `PluginCapabilityExposure` values and delegates to `register`, preserving
registry validation, registration-group rollback, scoped channels, and exact
generation liveness. A registration failure rolls back that attempt's partial
registrations, not unrelated providers. Termination retires only the owning
generation; stale bindings never move to a replacement.

Git and OpenAI entrypoints own their advertisements rather than app-side exposure
helpers. Normal startup discovers prepared installations and attempts all valid
backends independently. Self-hosting uses the same generic registration path with
its own explicit artifact/host/profile topology, without requiring normal discovery.
It configures the backend through its own profile environment, registers all
advertised online contexts, and explicitly resolves the selected profile's provider
ID. Both OpenAI contexts may be registered when configured; selection does not
filter advertisements or imply a fallback to another provider.
Ready metadata is not a new registry, a host-call authorization grant, or a general
dynamic configuration protocol. It preserves the distinctions accepted in ADRs 0015,
0021, 0027, and 0028. See
[`plugin-layout.md`](plugin-layout.md#prepared-installation-snapshot) for catalog
semantics and [`app/README.md`](../../app/README.md#normal-backend-startup) for ownership.

### Extension advertisements

Optional `extensionExposures` follow the same isolate `ready` -> host
`pluginReady` -> exact connection path. Public pure-Dart
`adele_contract.AdeleExtensionExposure` has exactly these required fields:

| Field | Meaning |
| --- | --- |
| `extensionPointId` | Public typed extension-point identity understood by a host adapter |
| `extensionId` | Public registration identity in the existing `ExtensionRegistry` |
| `serviceId` | Generated service implementing the remote contribution |
| `configurationContext` | Backend route scoped to the exact connection generation |
| `metadata` | Recursively copied, immutable JSON-compatible point-specific data |

Unknown exposure keys are rejected. There is no `PluginId`, priority, rank, or
provider selection in this value. Plugin identity remains connection-owned.
Metadata rejects unsupported values, non-finite doubles, cycles, and container
nesting deeper than 64; its semantic schema belongs to the extension adapter.
Omitting `extensionExposures` means zero extensions, independently of capabilities.

Internal `plugin_runtime.PluginExtensionActivation` uses
`RemoteExtensionAdapterRegistry` to find the host adapter for an advertised point,
build an exact-generation proxy contribution, and register it in the existing
`ExtensionRegistry`. The adapter registry holds host implementations of known
contracts, not plugin contributions or another public discovery system.
Unsupported points, invalid metadata, and registration collisions fail that
backend attempt rather than silently dropping an exposure.
`PluginBackendActivation.registerAdvertised` owns both capability and extension
registration phases, rolls back both on failure, and retires their exact
registrations before connection close. Termination cannot retarget old bindings.

## Frontend behavioral operations

Prepared frontend behavior is separate from generated backend RPC and capability
selection. Under installed `manifestVersion: 1`, `frontend.extensions` is an
optional list distinct from the unchanged `frontend.presentations` list; both may
coexist. Its supported `kind: 'projectSelector'` descriptor has `extensionId`,
`displayName`, `library`, and `entrypoint`. The Flutter owner adapts it to the
existing `ProjectSelectorContribution` in the same extension registry, not a new
capability or backend exposure. The exact schema is in
[`plugin-layout.md`](plugin-layout.md#prepared-installation-snapshot).

Bootstrap validates behavioral bytecode and entrypoint presence without executing
initializers or plugin code, using a validation runtime that intercepts dispatch.
Presentation-only corruption remains per-view. Internal `PreparedFrontend.invoke<T>`
executes a descriptor-selected no-argument entrypoint in a fresh eval runtime with
a supplied bridge and result decoder, revoking the bridge in `finally`. This is not
a public arbitrary-eval interface or remote-object API.

Local Directory's EVC calls the interpreted-only public
`adele_ui/directory_picker_bridge.dart` `Future<String?> pickDirectory()` stub. App
`DirectoryPickerDeclarations` carries compile-time ABI only; operation-scoped
`DirectoryPickerBridge` uses `$Future.wrap` over `file_selector.getDirectoryPath`,
returning the raw platform path and allowing one native call per operation. EVC
owns path validation and normalization into an absolute `file:` URI string or
`null`. The generic adapter validates the URI result and liveness; the app validates
the exact binding and window lifetime before creating a Project. Retirement rejects
late native results without forcibly closing a dialog, and semantic failures stay
operation-local. No AOT selector, backend host-invocation token, generated backend
RPC, or Session/Environment authority is involved. The backend host-service rules
below remain a distinct boundary.

## Operation-scoped host calls

The hosting decision is recorded in
[ADR 0032: Remote backend extensions use operation-scoped host services](../adr/0032-remote-backend-extensions-use-operation-scoped-host-services.md).

The app's `RemoteInferenceContextSourceAdapter` adapts the generated orchestration
`RemoteInferenceContextSourceService.snapshot(sessionId, runId,
hostInvocationContext)` to an `InferenceContextSourceContribution`. The unary
result is `List<RemoteInferenceInstruction>` with `key`, `text`, and required
nullable `revision`. Its only metadata is `failureMode: 'required'` or
`'optional'`; other keys/values fail activation. Composer ordering, validation,
required/optional failure, and immutable capture semantics are unchanged.

For each authorized operation, the host creates a cryptographically random opaque
`hostInvocationContext` and a service allowlist tied to the exact connection and
registration. This token is distinct from the backend's `configurationContext`.
The supplied generated Environment `AuthorizedEnvironmentReadService` exposes
`authority() -> AuthorizedEnvironmentIdentity`, `readFile(relativePath) ->
EnvironmentTextFile`, and `readDirectory(relativePath) -> EnvironmentDirectoryListing`
as unary operations. `authority()` takes no arguments and returns the already-bound
`sessionId` and `environmentId`; it does not select authority. Reads preserve declared
`EnvironmentFailure`, including `not_found`. No method accepts Session, Task,
Environment, provider, or other authority-selection IDs. Mutation and process
operations are absent from this host service.

The separate generated unary `AuthorizedEnvironmentMutationService` exposes only
`createTextFile(relativePath, text)`, `replaceExistingTextFile(relativePath,
replacementText, expectedRevision)`, and `deleteExistingTextFile(relativePath,
expectedRevision)`. It reuses existing mutation results and declared
`EnvironmentFailure`, with no authority query, authority-selection IDs, reads, or
process operations. The read service remains unchanged for inference sources and
other consumers; granting mutation never implicitly grants reads.

Separate generated `AuthorizedEnvironmentProcessService` exposes exactly
`runForegroundProcess(EnvironmentForegroundProcessRequest request) ->
Stream<EnvironmentProcessEvent>`. It reuses the existing request/event DTOs and
declared `EnvironmentFailure`. It has no authority query, authority-selection IDs,
file reads, or mutations. The host routes it through the captured
`AuthorizedEnvironmentProcessFacet`, not a plugin-selected Environment. Granting
this service does not implicitly grant either filesystem service.

For remote inference sources, the read dispatcher captures the canonical
`InferenceContextSourceContext` supplied by the composer and obtains its
`AuthorizedEnvironmentFileReadFacet`. It never
reconstructs authority from the transported Session/Run strings. Binding checks
bracket the read, including failure settlement. The remote source cannot choose
another Environment through this service.

Unary `hostRequest`/`hostResponse` messages reuse the existing isolate ports and
framed shared-host transport. Successful `hostResponse` messages carry `ok: true`
and `payload`, not `result`. The shared host stamps plugin identity and the
host-issued exact connection generation from the owning isolate, not plugin input;
replies route back to that captured generation. Runtime checks invocation liveness
and the service allowlist before dispatch, then rechecks liveness after asynchronous
settlement.
`RemoteExtensionContext.invoke` revokes the token in `finally`.
`RemoteExtensionContext.invokeStream` is single-subscription and creates authority
only on listen. It retains that authority across the host-to-backend stream and
revokes it on done, first error, cancellation, or retirement, before waiting for
producer cancellation. Registration retirement, connection shutdown, and termination
also revoke contexts and settle pending host calls without waiting for arbitrary
host service code, including while the outer stream is idle or paused. Late results
cannot revive authority or reach a replacement generation. Revocation is not
cancellation or rollback of an already-started read or mutation.

Reverse server streams reuse those same ports, framing, and exact-generation
routing under the current transport protocol. They open lazily and use a fixed
one-item credit window: pausing stops producer advancement after the already-granted item, and
cancellation reaches the producer. The invocation's allowlist and liveness apply
to stream opening and delivery, not just unary dispatch. Outer-operation
settlement, cancellation, registration retirement, and connection termination
revoke authority immediately and cancel owned reverse streams. Cleanup is bounded
and cannot keep authority alive while arbitrary producer cleanup is pending.
Late items and terminals cannot revive a revoked operation or reach a replacement.
Cancellation acknowledgement means cancellation was dispatched, not that arbitrary
producer cleanup or operating-system process termination has completed. Bounded
transport cleanup does not promise to interrupt arbitrary host service code.
This supplies foreground-process streaming, not client/bidirectional streaming,
ambient callbacks, or a general remote-object system.
Host process adapters forward subscription cancellation even when a producer is
idle or paused; delivery of a primary failure does not await producer cleanup.

The reverse stream family is `hostStreamOpen`, `hostStreamCredit`, and
`hostStreamCancel` from the backend, and `hostStreamItem`, `hostStreamDone`,
`hostStreamFailure`, and `hostStreamCancelled` from the runtime. Opens carry the
plugin-local request ID, invocation token, service, method, and payload. The shared
host correlates its own request ID and stamps PluginId/generation; backend frames
cannot supply those identities. Unary calls and stream opens share a monotonically
increasing plugin-local ID space, so replay needs no unbounded historical ID set.
`hostStreamCancelled` is sent after output is revoked and producer cancellation
is initiated, without waiting for cleanup. A backend `hostStreamAck` confirms
terminal receipt, allowing bounded terminal records to absorb controls already
in flight without reopening authority. Missing receipt retires only the offending
generation after the existing plugin lifecycle deadline; it does not accumulate
terminal records indefinitely. Excess credit and unknown/replayed controls are
protocol violations, not another producer window.

Public pure-Dart `adele_plugin_backend_support` supplies only the reusable
`AdeleHostRequestMultiplexer`; its `bind` returns an `AdeleStreamChannel` supporting
both unary requests and server streams for generated clients. Its only production
package dependency is `adele_contract`, with no internal
host or Flutter imports. It does not mint authority, grant service access, or
implement general symmetric RPC. Profiles
and general plugin configuration remain deferred; this boundary is not a sandbox.

### Remote model tools

Public `adele_model_tool/remote_model_tool.dart` declares generated
`RemoteModelToolService` (`remoteModelToolServiceId`): unary `materialize`,
`validateAndNormalize`, and `describe`, plus server-streaming `execute`. Immutable
descriptors carry semantic tool identity/description, model alias/description/schema,
an opaque `routeId`, and required `executionHostServices`. Canonical arguments,
effect descriptions, progress, and terminal outcomes cross as immutable snapshots.
Outcome classification, effect
certainty, model content, structured `hostData`, and diagnostic text are preserved;
arbitrary exception `cause` objects are not transported. Route IDs identify backend
executables only within the captured connection generation. They are not persistent
handles, model aliases, or authority tokens.

The app's `RemoteModelToolAdapter` registers `ModelToolContribution` proxies through
the existing adapter and extension registries. It requires the generated service ID
and exactly one metadata key: `hostServices`, a duplicate-free list drawn from
`authorizedEnvironmentRead`, `authorizedEnvironmentMutation`, and
`authorizedEnvironmentProcess`, including an
empty list. Unknown keys, services, or duplicates fail activation. This exposure
declares the maximum dependencies to capture, not permission grants or Profiles.
Each descriptor's required `executionHostServices` is a duplicate-free subset of
that exposure, not an inherited default. Unknown, duplicate, or undeclared services
fail materialization. The subset is the exact service allowlist for that tool's
execution; a read-only descriptor never receives mutation or process authority
because its contribution also supplies effectful tools.

Materialization captures every requested Session-bound read/mutation/process facet and its
exact Environment-provider binding, alongside the exact remote registration. All
facets must belong to the materializing Session and the same Environment; incoherent
facets fail rather than being substituted or re-resolved.
The existing composer still owns zero-or-many tools, duplicate Tool IDs, and alias
collisions; the adapter adds no provider selection or tool registry.

Preparation carries data, not host-service authority:

- `materialize(sessionId)` receives no invocation token.
- `validateAndNormalize(routeId, proposedArguments)` receives no host authority.
- `describe(routeId, arguments, sessionId, runId, environmentId?)` receives pure identity data, without a token or host calls.
- `execute(routeId, arguments, sessionId, runId, environmentId?, hostInvocationContext?)` receives identity data and, when services are required, a fresh invocation token allowlisting exactly the descriptor's services.

The nullable Environment identity describes the host-captured binding; it cannot
select or reconstruct authority. `environmentId` and `hostInvocationContext` are
required nullable arguments, not optional wire fields. Environment identity is null
when no Environment facets were captured; the execution token is null for an empty
service subset. The executable retains host-side bindings, never
a reusable invocation token. Synchronous `validateBinding()` checks the remote
generation and every captured facet, including dependencies outside an individual
descriptor's execution subset. No operation re-resolves a binding. Retirement
fails old work rather than selecting a replacement.

Only execution after the normal policy/approval decision can receive model-tool
host authority. Execute-stream authority starts on listen and is revoked on done,
error, cancellation, or exact registration/connection retirement. Denied, rejected,
or waiting invocations receive no execution token. Host calls and asynchronous
settlement validate the exact captured bindings; semantic Session/Run/Environment
IDs do not grant access. This controls the host-service API, not native backend
operating-system access, and is not an OS sandbox.

Local `ToolExecutable.validateAndNormalize` returns
`FutureOr<CanonicalToolArguments>`, preserving synchronous local validators.
`ToolInvocationResolver.resolve` returns a Future, awaited by normal proposal
processing, and checks exact binding around validation. Unknown alias, invalid
arguments, stale binding, and unavailable binding remain distinct. Only declared
`RemoteToolArgumentValidationFailure` is translated to local argument-validation
failure; malformed transport and other backend/protocol failures are not relabeled
as invalid model arguments. Host effect description, policy, approval, execution
collection, and continuation remain on the normal path.

Stock Search, Filesystem Tools, and Command Tools use this point without capability exposures.
Their backends advertise `dev.adele.extension.model-tools` with their existing
`dev.adele.plugin.search-tools.model-tools`,
`dev.adele.plugin.filesystem-tools.model-tools`, and
`dev.adele.plugin.command-tools.model-tools` registration IDs, generated service
ID `modelTool`, and default configuration context. All reuse their pure-Dart root semantics.
Search declares only `authorizedEnvironmentRead`, describes effects from pure
identity data, and receives read authority only during execution. Filesystem
declares read and mutation dependencies; Command declares process only. Their exact
execution subsets are:

| Tool | `executionHostServices` |
| --- | --- |
| `search` | `['authorizedEnvironmentRead']` |
| `read_file` | `['authorizedEnvironmentRead']` |
| `apply_patch` | `['authorizedEnvironmentRead', 'authorizedEnvironmentMutation']` |
| `create_file` | `['authorizedEnvironmentMutation']` |
| `delete_file` | `['authorizedEnvironmentRead', 'authorizedEnvironmentMutation']` |
| `run_command` | `['authorizedEnvironmentProcess']` |

Command declares only `authorizedEnvironmentProcess` and describes effects from
pure identity and argument data. Its backend uses reverse process streaming only
during authorized execution. Read and mutation calls remain unary; the separate
host services change neither tool semantics nor policy/effect ordering. Command's
installed backend and frontend are independently available. Headless Chat
migration, client/bidirectional streaming, ambient callbacks, and general symmetric
RPC remain deferred; the Local Directory selector is already a prepared frontend,
not a consumer of backend host-service authority.

## Configured capability instances

One plugin runtime may expose multiple named configurations of the same capability:

```text
OpenAI plugin runtime
|-- Model provider: Work
`-- Model provider: Personal
```

Accounts, providers, clusters, connections, endpoints, and devices are configured capability instances. They do not require separate plugin installations, backend copies, or runtime instances. A future ADELE profile may make several instances available, prefer one, and apply optional configuration overrides.

Active capability endpoints are bound to one opaque, generation-specific configuration context. Several provider descriptors and services may share one context, while one plugin generation may host several contexts. Context and the endpoint's exact service ID are transport metadata supplied by the scoped endpoint channel, not semantic contract data or provider identity. Request and stream-open carry them separately from generated method payloads; later stream control remains request-ID based.

ADELE does not yet have a generic host-wide configured-instance persistence,
account, or secrets framework. The OpenAI plugin has a private experimental
credential implementation for its ChatGPT proof; that implementation does not
define a generic capability contract. Ready advertisements expose callable
providers with live context tokens, not a general configured-instance catalog,
management/selection UI, persistence model, or profile-aware lifecycle.

The retired DevelopmentSource plugin historically illustrated the distinction between a sustained capability and model tools: application composition projected its generation-bound read/search Service into source-search and source-read tools. Phase V-A replaced that provisional path with stock plugin-contributed tools over Session-authorized Environment access; neither design makes each model tool a separate ADELE capability.

## Runtime resources

Browser sessions, terminal sessions, open documents, processes, temporary connections, and active tool executions are runtime resources. They are normally represented by temporary handles or session objects. They are not persistent configured capability instances, plugin runtime instances, or plugin installations.

Future `ConsoleService` or Environment APIs may expose operations over runtime resources without turning each runtime resource into another plugin or configured provider instance.
