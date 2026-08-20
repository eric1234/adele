# Contracts and Capabilities

## Separate questions

Contracts and capabilities solve different problems:

| Concern | Question |
| --- | --- |
| Contract | How do typed values and asynchronous operations cross a runtime boundary? |
| Capability | Which compatible provider handles a request? |

The constrained Phase II-A generated unary transport and Phase II-B generated
server-streaming/cancellation transport are implemented and used by maintained
plugin contracts where applicable. The scripted model fixture retains a generated unary
reference method, while the Phase IV application adapter consumes generated
ModelProvider streams and emits kernel semantic model events incrementally. The
public `adele_model_provider` package defines
capability major 1 with generated streaming, typed ordered input, live text
observations, authoritative completed output, and explicit semantic terminal
settlement.
Ordered input/output wrappers exclusively own optional provider item identity
and native metadata; tool-proposal payloads own only tool-call correlation,
name, and arguments.
The ordered input/output union also has one native-only item whose required
opaque envelope occupies an independent list position without semantic
text/tool payload. This preserves provider item cardinality and order while
keeping provider-specific reasoning or compaction outside common semantics.
Capability transport plus Phase III active
provider registration, deterministic discovery, exact-major resolution, and
generated-client invocation are implemented for the maintained
resource-inspector fixture.

## Contracts

Plugin contract source is shared by frontend and backend packages and should
normally describe immutable snapshot values. A value received across a runtime
boundary is reconstructed; its object identity is not shared with the sender.

The Phase II internal generator treats contracts as a constrained IDL embedded
in Dart and provides a typed client, dispatcher, codecs,
request handling, and structured errors for the maintained fixture. Its scope is
one non-empty service per contract library with unary `Future<T>` and
server-streaming `Stream<T>` methods.
Values use one unnamed generative constructor with
required named parameters, schema enums and values must be declared in the
contract source library rather than imported, wire IDs use a conservative ASCII
segment grammar, and every transported double must be finite.
Client/bidirectional streaming, reverse RPC, replay, and broader schema
composition remain future work.
The contract annotation import is exactly canonical, unprefixed, and without
combinators or configurations. The plugin API import has the same shape exactly
when the extracted schema semantically uses canonical `ResourceRef`; prefixed
plugin API imports do not require it otherwise. Additional imports from either
package, including repeated canonical URIs with `show` or `hide`, and every
other import must be prefixed. Conditional imports whose default or configured
URI is within either package are rejected. Every import prefix shares the
generated top-level collision namespace with contract declarations, generated
identifiers, unqualified ADELE runtime names, and SDK names; `ResourceRef` is
reserved conditionally.
Schema names match `[A-Za-z][A-Za-z0-9_]*` across annotated declarations and
members plus reachable enums and enum values. Private, dollar-prefixed, and
non-ASCII names are outside the IDL, although unrelated unreachable private
helpers and enums remain ordinary implementation details. These restrictions
may be permanent rather than promises of future Dart-language parity.
Generated code should hide ports, wire formats, request IDs, subscriptions, and
transport details from plugin code. Contract declarations remain lightweight
and independent of compiler or generation tooling.

The generated transport layers over the proven process-hosted communication
path through a transport-neutral request channel. Its annotations and generator
remain experimental; no general schema compatibility policy is accepted yet.
Dispatch explicitly decodes the envelope and method, decodes arguments, invokes
the service, and encodes the result as separate stages. Malformed requests are
`invalid_request`; every service-thrown undeclared exception, including
`AdeleProtocolException`, is `internal_error`; and backend results or declared
failure details that violate the generated response contract become opaque
`backend_contract_violation` failures. URI values, including `ResourceRef.uri`,
must be reconstructible absolute URIs.

The same absolute-URI rule applies recursively to direct values,
`ResourceRef.uri`, annotated value fields, lists, and nested lists. Clients
perform request encoding before invoking the channel, so invalid local URIs are
preflight failures. JSON map transport rejects map, list, and mutual cycles and
container depth beyond 64 while accepting shared acyclic subgraphs. Value
constructor exceptions are opaque malformed-value failures at the client and
dispatcher boundaries, and each dispatcher failure remains isolated to its
request.

Annotation interpretation is multiplicity-aware: repeated role, method, and
field annotations and mixed class roles are invalid regardless of declaration
order. Generated implementation state and temporaries occupy indexed `_adele`
names rather than contract namespaces, and public schema methods such as
`dispatch` coexist with the generated client, dispatcher, and backend service.
Every contract-derived string entering generated Dart source is emitted through
one single-quoted literal escaping path.
Supported core and async types are checked by exact semantic library identity,
not spelling: core scalars, collections, `Uri`, and `Object` come from
`dart:core`, method wrappers are exact `dart:async` `Future` or `Stream`, and `ResourceRef` is
the exact canonical plugin API declaration. Type aliases are excluded from the
transported closure recursively, including the outer wrapper, while unused
implementation aliases remain permitted. Service parameters are explicitly
typed required positionals; optional, named, covariant, initializing-formal,
super-formal, function-typed, and implicitly dynamic forms are rejected.
`ContractDiagnostic` locations retain the precise import, annotation, method,
parameter, field, constructor, enum, or enum-value source node when available;
whole-library constraints use the compilation unit.

Committed transport is checked in normal CI. Development plugin preparation
also checks the requested plugin independently: the manifest-selected contract
package's `pubspec.yaml` name determines `lib/<package-name>.dart`, and that
absolute source is passed explicitly to `contract_codegen --check --source`.
This keeps stale transport failure local to the plugin and ahead of compilation.

Server-streaming uses the existing shared backend-host path. Generated clients
open lazily and decode ordered typed items. Generated dispatchers hide producer
iteration, cancellation, and terminal failure mapping. The initial protocol,
version 1, uses a fixed
one-item credit window, so paused consumers stop producer advancement after the
already-granted item and cancellation reaches the producer iterator. Streams
remain bound to their exact provider generation and fail rather than migrating
when that generation disappears.

## Capability semantics

| Kind | Semantics | Examples |
| --- | --- | --- |
| Action | Brokered one-shot request/response operation | `EditResource`, `ViewResource`, `ShowDiff`, `OpenTerminal` |
| Service | Sustained typed capability | `WorkspaceService`, `SourceControlService`, `ModelProvider`, `ToolProvider` |
| Event | Fact that has occurred | `ResourceChanged`, `EditorOpened`, `PluginStarted` |

Actions, services, and events retain these distinct semantics even if they
eventually share generated transport infrastructure.

## One-to-many provider resolution

Several plugins may implement one action or service:

```text
EditResource
|-- ADELE in-app editor plugin
`-- External editor launcher plugin
```

The Phase III active registry allows a caller to:

- Check whether a compatible provider is available.
- Enumerate all compatible providers.
- Invoke ADELE's deterministic default provider.
- Explicitly select and invoke another provider.

Callers must handle zero, one, or many providers. The in-memory host-owned active
registry orders discovery by higher provider rank and then stable provider ID;
default resolution selects the first result, while explicit resolution never
falls back. Exact positive major-version matching is provisional. Bindings
retain one runtime generation and become stale when its registration closes.

ADELE owns deterministic default resolution; a provider cannot declare itself
globally primary. Persistent preferences, profile-aware and
workspace/request-specific routing policy, richer compatibility negotiation,
dynamic suitability, message buses, and retained/durable handles remain
deferred.

Public capability, provider, and plugin identities share a lowercase
reverse-domain ASCII grammar. Dot-separated segments begin with a letter and
may contain digits or internal hyphens; underscores are not valid identity
characters. A missing capability and a capability available only at other
active major versions are separate structured resolution failures.

## Configured capability instances

One plugin runtime may expose multiple named configurations of the same
capability:

```text
OpenAI plugin runtime
|-- Model provider: Work
`-- Model provider: Personal
```

Accounts, providers, clusters, connections, endpoints, and devices are
configured capability instances. They do not require separate plugin
installations, backend copies, or runtime instances. A future ADELE profile may
make several instances available, prefer one, and apply optional configuration
overrides.

Active capability endpoints are bound to one opaque, generation-specific
configuration context. Several provider descriptors and services may share one
context, while one plugin generation may host several contexts. Context and
the endpoint's exact service ID are transport metadata supplied by the scoped
endpoint channel, not semantic contract data or provider identity. Request and
stream-open carry them separately from generated method payloads; later stream
control remains request-ID based.

ADELE does not yet have a generic host-wide configured-instance persistence,
account, or secrets framework. The OpenAI plugin has a private experimental
credential implementation for its ChatGPT proof; that implementation does not
define a generic capability contract. Generic configured-instance discovery,
selection, persistence, and profile-aware lifecycle remain deferred.

The provisional DevelopmentSource plugin also illustrates the distinction
between a sustained capability and model tools. Application composition
projects its generation-bound read/search service into source-search and
source-read tools; those tools are not separate ADELE capabilities and do not
establish final Workspace semantics.

## Runtime resources

Browser sessions, terminal sessions, open documents, processes, temporary
connections, and active tool executions are runtime resources. They are
normally represented by temporary handles or session objects. They are not
persistent configured capability instances, plugin runtime instances, or
plugin installations.
