# ADELE Plugin Backend Support

`adele_plugin_backend_support` is an experimental public, pure-Dart package with
only `adele_contract` as a production dependency. It provides
`AdeleHostRequestMultiplexer` for generated unary and server-streaming clients
calling explicitly scoped host services. It imports neither Flutter nor internal
host implementations.

Construct one `AdeleHostRequestMultiplexer(send: responsePort.send)` per backend
generation with the existing response port. Its bound channels share the
generation's increasing request-ID sequence.
`bind(hostInvocationContext: ..., serviceId: ...)` returns an `AdeleStreamChannel`
supporting both unary requests and server streams. Pass command messages to
`handleResponse` before normal dispatcher routing; it consumes reverse-call
responses and stream events. Successful unary responses use `ok: true` and
`payload`, not `result`.
Correlation and declared remote failures are preserved for generated clients.
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
