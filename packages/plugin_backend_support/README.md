# ADELE Plugin Backend Support

`adele_plugin_backend_support` is an experimental public, pure-Dart package with
only `adele_contract` as a production dependency. It provides
`AdeleHostRequestMultiplexer` for generated unary clients calling operation-scoped
host services. It imports neither Flutter nor internal host implementations.

Construct one `AdeleHostRequestMultiplexer(send: responsePort.send)` per backend
generation with the existing response port. Its bound channels share the
generation's increasing request-ID sequence.
`bind(hostInvocationContext: ..., serviceId: ...)` returns an `AdeleRequestChannel`
for a generated unary client. Pass command messages to
`handleResponse` before normal dispatcher routing; it consumes `hostResponse`
messages. Successful responses use `ok: true` and `payload`, not `result`.
Correlation and declared remote failures are preserved for generated clients.
Call `close()` before awaiting forward-dispatcher shutdown so pending reverse
calls settle.

This helper does not mint authority, select an Environment, or own host policy.
The host invocation identity is opaque, operation-local, and must not be persisted
or treated as a general capability handle. A retained channel cannot extend its
authority beyond the host operation's lifetime.
It supplies no reverse streaming or general symmetric RPC and is not a sandbox.
See [operation-scoped host calls](../../docs/architecture/contracts-and-capabilities.md#operation-scoped-host-calls).
