# ADELE Plugin Backend Support

`adele_plugin_backend_support` is an experimental public, pure-Dart package with
only `adele_contract` as a production dependency. It provides immutable backend
bootstrap settings/records and `AdeleHostRequestMultiplexer` for generated unary and
server-streaming clients calling explicitly scoped host services. It imports
neither Flutter nor internal host implementations. Its public Capability consumer
facade lets generated plugin
clients use declared context-free unary access without importing runtime packages.
Its credential client reads explicitly declared record slots through the existing
generation infrastructure grant, without native credential-store dependencies.

## Bootstrap Settings

`AdeleBackendSettings.fromBootstrap(bootstrapMessage)` reads the explicit
`settings` map delivered at backend startup. `AdeleBackendSettings(values)` also
supports native construction. Both copy scalar values into an immutable snapshot;
`read<T>(id)` fails on a missing value or wrong type, without coercion or fallback.
The public `values` map is unmodifiable. Only string keys with bool, int, or String
values are accepted, using the shared `adeleCopyBackendSettings` structural helper.
There is no transport-specific integer ceiling or declaration policy.

Resolve defaults, ownership, and declaration constraints before startup. The
snapshot belongs to that exact backend generation; later caller edits or a new
same-ID generation cannot change captured values. Settings are data, not a
configuration-context lookup, host-service grant, or RPC. This package does not
load files, interpret TOML, select plugin identities, or implement live updates.
Consumers must receive an explicit map, even if empty; missing or malformed
bootstrap settings fail rather than substituting an empty map. Backends that do
not consume settings need not construct the reader.

[`backend_settings_test.dart`](test/backend_settings_test.dart) covers immutable
copies, typed reads, and shared structural validation. Real AOT bootstrap and
generation isolation are tested by the internal
[`plugin_backend_host`](../plugin_backend_host/README.md).

## Bootstrap Records

`AdeleBackendRecords.fromBootstrap(bootstrapMessage)` requires an explicit
`records` list, including `[]`. `AdeleBackendRecords(records)` supports native
construction. Both use `adeleCopyBackendRecords(Object?)` and expose a deeply
copied, unmodifiable `records` list. Import the package root or
`package:adele_plugin_backend_support/adele_backend_records.dart`.

Each entry has exactly `collection`, `type`, `id`, and `values`. The first three
are strings; `values` is a string-keyed map of ordinary bool/int/String scalars.
Unknown entry keys, nulls, doubles, nested values, and duplicate `(collection, id)`
pairs across any types fail. Identities follow the
[R1 record grammar](../settings/README.md#named-records), including portable device
name rejection for collections/records, without normalization. Type IDs use the
public reverse-domain grammar. Limits are 256 records, 128 fields per record,
64-character local IDs, 256-character type IDs, 64 Ki UTF-16 units per scalar
string, and 1 MiB of total UTF-8 JSON including escaping and container overhead.
The `AdeleBackendRecords.max*` constants own these transport bounds. Empty values,
false, zero, and optional absence remain distinct; integer semantics are unchanged.
Failures use fixed bounded messages without supplied values or identities.

Declaration ownership, opted-in types, allowed/required fields, and scalar semantic
constraints are validated by the host owner where declarations are available, not
by this transport. Inputs are already nonsecret projections: credential references,
documents, storage roots, baseline handles, and authorization are not part of the
contract. Records confer no persistence, mutation, lookup, credential access, live
provider registration, or routing authority. The snapshot belongs only to its
captured generation and does not change readiness or exposures.

[`backend_records_test.dart`](test/backend_records_test.dart) covers strict shape,
identities, duplicate rejection, all bounds, safe errors, and immutable copies.
The shared host exercises real AOT transport and independent generation capture.

## Host Calls

Construct one `AdeleHostRequestMultiplexer(send: responsePort.send)` per backend
generation with the existing response port. Its bound channels share the
generation's increasing request-ID sequence.
`bind(hostInvocationContext: ..., serviceId: ...)` returns an `AdeleStreamChannel`
supporting both unary requests and server streams. Pass command messages to
`handleResponse` before normal dispatcher routing; it consumes reverse-call
responses and stream events. Successful unary responses use `ok: true` and
`payload`, not `result`.
Correlation and declared remote failure fields are preserved for generated clients;
generic failure `toString()` does not print remote codes, messages, or details.
Unary responses are validated and defensively copied before completing callers.
Malformed responses produce fixed protocol errors without retaining their payload.
Call `close()` before awaiting forward-dispatcher shutdown so pending reverse
calls and stream consumers settle. Host grant revocation and connection
shutdown own cancellation of host producers.

`bindInfrastructure(hostInfrastructureContext: ..., serviceId: ...)` binds the
opaque `hostInfrastructureContext` supplied in the backend bootstrap message to
one explicitly allowlisted infrastructure service. This required, nonempty
protocol-v1 bootstrap field exists even when no infrastructure services are
granted. Use the same multiplexer for both context kinds: all bound unary and
stream channels share one increasing request-ID sequence.

Generic reverse requests and stream openings carry required `hostContextKind`
(`invocation` or `infrastructure`) and opaque `hostContext`; there is no legacy
missing-field interpretation. Domain operation payloads retain their existing
`hostInvocationContext` fields. Binding selects the context kind, not authority:
the host rejects cross-kind tokens, foreign generations, and unlisted services.

Streams open lazily and use one-item credit. Pausing withholds further credit
after the already-granted item; cancellation reaches the host producer. Authority
belongs to the explicit host grant, not the channel or subscription. Operation
settlement, cancellation, or exact-generation retirement revokes it immediately,
with bounded cleanup that cannot prolong access. Both transport protocols use
version 1; host and backend artifacts must be rebuilt together under the
[pre-release transport policy](../../docs/architecture/contracts-and-capabilities.md#transport-version-policy).

This helper does not mint authority, select an Environment, or own host policy.
The host invocation identity is opaque, operation-local, and must not be persisted
or treated as a general capability handle. A retained channel cannot extend its
authority beyond the host operation's lifetime.
Infrastructure tokens instead last until their exact backend activation retires
or the connection ends; operation completion and individual extension retirement
do not revoke that separate grant. They must not be persisted or reused with a
replacement generation and grant no execution or other services implicitly.
It supplies no client/bidirectional streaming, ambient callbacks, or general
symmetric RPC and is not a sandbox.
See [operation-scoped host calls](../../docs/architecture/contracts-and-capabilities.md#operation-scoped-host-calls).

## Credential Reads

`AdeleCredentialClient(hostRequests: ..., hostInfrastructureContext: ...)` binds
the generation's existing multiplexer to the dedicated `adele.credentials`
infrastructure service (`backendCredentialServiceId`). Import the package root or
[`adele_backend_credentials.dart`](lib/adele_backend_credentials.dart).
Binding grants no access: the host owns declaration, record binding, configuration
freshness, and exact-generation authorization. No secrets or references are added
to bootstrap settings or records.

`readCredential(collection: ..., recordType: ..., recordId: ..., slot: ...)`
returns `Future<String>`. The method is `readCredential`; its fresh request
payload contains exactly those four string fields. There is no reference, key,
owner, generation, or service override. Successful transport payloads have exactly
`{'secret': String}` or `{'failure': String}`. The client validates secrets as
nonempty, NUL-free, strict Unicode with at most 2560 UTF-8 bytes using only the SDK.
Response containers are copied before asynchronous publication; callers must not
log returned secrets. Requests use fresh plain maps rather than unmodifiable map
wrappers so they can cross spawned AOT isolate groups.

Failures throw `AdeleCredentialFailure` with one `AdeleCredentialFailureKind`:
`notAuthorized`, `notConfigured`, `missingLocally`, `storageUnavailable`,
`invalidCredentialBinding`, `reconciliationRequired`, `staleConfiguration`,
`generationUnavailable`, or `credentialAccessFailed`. The exception retains only
the kind and formats a fixed bounded diagnostic. Missing-service transport denial
maps to `notAuthorized`; transport grant revocation maps to `generationUnavailable`.
Malformed responses and other transport failures map to `credentialAccessFailed`,
never a raw native error or payload-bearing decoder exception.

The facade supplies no enumeration, mutation, filesystem, keyring, Flutter, or host
implementation access, and never renews a retired grant. See the
[configuration architecture](../../docs/architecture/profiles-and-configuration.md#credentials-and-secrets)
for host ownership. [`backend_credentials_test.dart`](test/backend_credentials_test.dart)
covers exact wire shape, defensive copying, all failure kinds, secret bounds, and
redaction through the existing maintained backend-support test target.

## Capability Consumption

[`AdeleCapabilityConsumer`](lib/adele_capability_consumer.dart) is the public facade
for declared context-free unary calls to another prepared backend's Capability.
Import it from `package:adele_plugin_backend_support/adele_plugin_backend_support.dart`
or its facade library. Construct it with the generation's existing `hostRequests`
multiplexer and bootstrap `hostInfrastructureContext`; binding alone grants no
access. The host checks the installation's backend-only
[`consumesCapabilities` declaration](../plugin_runtime/README.md#prepared-catalog).
Send the backend ready handshake before awaiting consumer calls, and keep handling
`hostRequests.handleResponse` while forward dispatch is pending. Do not make
initialization or shutdown depend on new peer work; the
[shared-host scheduling boundary](../../docs/architecture/contracts-and-capabilities.md#prepared-backend-capability-consumption)
does not support arbitrary recursive composition.

| API | Purpose |
| --- | --- |
| `AdeleCapabilityConsumer(hostRequests: ..., hostInfrastructureContext: ...)` | Bind the generated infrastructure consumer service using the existing reverse transport. |
| `discover(capabilityId, majorVersion)` | Return current `BackendCapabilityProvider` metadata in host selection order; no compatible providers returns an empty list. |
| `resolve(capabilityId, majorVersion, expectedServiceId: ..., providerId: ...)` | Resolve once to `AdeleResolvedCapability?`; omit `providerId` for host default selection. No provider returns null; denied, incompatible, or unsupported selection fails, never substitutes. |
| `AdeleResolvedCapability.provider` | Selected metadata: Capability ID/major, provider/plugin IDs, display name, and service ID, not a backend route. |
| `AdeleResolvedCapability.requestChannel` | Request-only `AdeleRequestChannel` for the consumer's own generated semantic client. It does not implement `AdeleStreamChannel`. |
| `AdeleResolvedCapability.release()` | Synchronously fence local admission and late publication, then release host bookkeeping; repeated calls join the same cleanup. |

The facade does not depend on a particular semantic contract. The caller passes
the expected service identity from its generated contract and retains/releases the
resolved access around that client's use. It exposes no configuration-context,
target-backend, or invocation-token selector, and never re-resolves a retired handle.

[`capability_consumer.dart`](lib/capability_consumer.dart) owns the authored
`BackendCapabilityConsumerService` and provider/access DTOs; the package root exports
both it and the facade. Generated discover/resolve/invoke/release requests use
`bindInfrastructure` and service ID `adele.capabilityConsumer`. The invoke envelope
preserves structured success values and `AdeleRemoteFailure` fields for the plugin's
generated decoder to reconstruct declared failures, not a second semantic codec.
The facade bounds and snapshots request data and control responses before generated
decoding, and rejects malformed envelopes.

Selection policy, exact activation/channel ownership, the bounded handle table,
and diagnostic sanitization belong to the [application mediator](../../app/README.md#backend-capability-consumption).
Provider registration retirement prevents new calls but need not reject admitted
unary settlement; release or consumer retirement fences publication without
cancelling provider effects. This route supplies no operation token or Environment
grant. See [backend Capability architecture](../../docs/architecture/contracts-and-capabilities.md#prepared-backend-capability-consumption)
for authority, lifetime, and intentionally unsupported composition.

[`capability_consumer_test.dart`](test/capability_consumer_test.dart) owns generated
control roundtrips, request-only access, structured values/failures, malformed
envelopes, and local release fencing. It is discovered by the existing
`adele_plugin_backend_support` test target.

## Contextual Unary Services

`AdeleContextualServiceDispatcher` opts a router service into optional top-level
forward `hostInvocationContext` metadata without changing its generated contract:

```dart
final dispatcher = AdeleContextualServiceDispatcher(
  hostRequests: hostRequests,
  createDispatcher: (context) => ExampleServiceDispatcher(
    ExampleServiceImpl(context),
  ),
);
```

Install the wrapper under the existing configuration-context/service router key.
The factory must create a fresh implementation holding the supplied
`AdeleBackendOperationContext` and a fresh generated dispatcher per admitted unary
operation. These operations can overlap; any shared domain state remains the
service owner's responsibility. `context.bind(serviceId)` returns a request-only
`AdeleRequestChannel` for a generated host client, using the existing multiplexer
and unchanged reverse protocol. It exposes neither the token nor a stream API,
and checks context validity at every call and asynchronous response settlement.
No Zone or ambient current context is used.

Missing metadata fails closed, as do streaming openings and controls. A context
expires before its response is sent, when dispatch returns or throws, and
synchronously when the wrapper closes. Expiration precedes potentially slow
delegate cleanup; close fences new admission and drains every admitted operation
and its dispatcher cleanup rather than interrupting unary work. A factory/dispatch
exception or a unary dispatcher returning without a response produces a correlated
opaque failure before cleanup, so host grant settlement does not wait for cleanup.
Retained contexts and channels cannot make new reverse calls after expiration.
The wrapper does not
own the shared multiplexer, revoke host grants, or replace host-side generation,
service allowlist, and revocation checks.
