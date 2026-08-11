# Contracts and Capabilities

## Separate questions

Contracts and capabilities solve different problems:

| Concern | Question |
| --- | --- |
| Contract | How do typed values and asynchronous operations cross a runtime boundary? |
| Capability | Which compatible provider handles a request? |

The constrained Phase II generated typed request/response transport is
implemented for `workspace_demo`. The Phase IV-A scripted model fixture also
uses this unary generator behind an application adapter that emits kernel
semantic model events; it is not the final common ModelProvider contract.
Broader transport generation and capability transport plus Phase III active
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
one non-empty service per contract library and unary request/response only.
Values use one unnamed generative constructor with
required named parameters, schema enums and values must be declared in the
contract source library rather than imported, wire IDs use a conservative ASCII
segment grammar, and every transported double must be finite. Streams,
cancellation, events, and broader schema composition remain future work.
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
`dart:core`, method wrappers are the `dart:async` `Future`, and `ResourceRef` is
the exact canonical plugin API declaration. Type aliases are excluded from the
transported closure recursively, including the outer `Future`, while unused
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

A future caller must be able to:

- Check whether a compatible provider is available.
- Enumerate all compatible providers.
- Invoke ADELE's preferred provider.
- Explicitly select and invoke another provider.

Callers must handle zero, one, or many providers. ADELE owns preference
resolution and deterministic fallback; a provider cannot declare itself
globally primary. Future selection may consider explicit selection, user and
profile preferences, workspace overrides, request compatibility, resource
scheme, media type, availability, and dynamic suitability. The matching model
and precedence are intentionally deferred.

Phase III has an in-memory host-owned active registry. Discovery orders higher
provider rank first and then stable provider ID lexically; default resolution
selects the first result. Explicit resolution never falls back. Bindings retain
one runtime generation and become stale when its registration closes. Exact
positive major-version matching is provisional. Preference persistence,
profiles, compatibility negotiation, message buses, streams, and retained
handles remain unimplemented.

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

Provider-instance persistence, account and credential management, discovery,
selection, and profile-aware routing are not implemented in Phase 0.

## Runtime resources

Browser sessions, terminal sessions, open documents, processes, temporary
connections, and active tool executions are runtime resources. They are
normally represented by temporary handles or session objects. They are not
persistent configured capability instances, plugin runtime instances, or
plugin installations.
