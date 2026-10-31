# Plugin Backend Host

`plugin_backend_host` is an internal pure-Dart executable package. One AOT host
process accepts framed stdin,
reserves stdout for protocol output, writes diagnostics to stderr, and loads one
external AOT isolate group per active plugin.

It is not plugin-facing API, a sandbox, a production daemon, or one process per
plugin. The host reuses `plugin_runtime`'s internal framing declarations while
owning isolate ports and plugin routing.

The host waits for actual isolate exit after shutdown acknowledgement and kills
an isolate that misses the exit deadline. Stdin EOF triggers full host cleanup.
Oversized plugin responses become bounded `response_too_large` failures without
terminating the host or plugin.

The existing isolate-ready handshake may carry backend-owned `capabilityExposures`
and `extensionExposures` using public `AdeleCapabilityExposure` and
[`AdeleExtensionExposure`](../contract/lib/adele_contract.dart).
The host validates and forwards these on `pluginReady` to the exact runtime
connection. Each omitted list means zero registrations of that kind. Plugin identity
remains host/connection-owned, not advertisement-owned. Malformed ready metadata
fails only that plugin startup and cleans up its partial isolate resources;
shared-host failure remains global. The host does not discover installations,
select stock backends, interpret plugin configuration argv, or own the active
capability or extension registry, or remote extension adapters. See
[`contracts-and-capabilities.md`](../../docs/architecture/contracts-and-capabilities.md#backend-ready-advertisements).

The host also forwards `startupArgumentsOnly` from `startPlugin` into the backend
startup message alongside argv, without a PluginId switch or configuration parsing.
The flag defaults to `false` for direct/self-hosting callers; normal application
bootstrap always sets it to `true`. This is temporary deployment metadata, not an
environment scrubber or settings/profile/credential service. See
[`plugin_runtime` startup arguments](../plugin_runtime/README.md#startup-arguments).

Every `startPlugin` frame also carries an explicit `settings` map, including when
empty. The host uses public
[`adele_plugin_backend_support`](../plugin_backend_support/README.md#bootstrap-settings)
structural validation to copy string-keyed bool/int/String values before spawning,
then forwards them to that exact isolate generation's bootstrap message. It does
not resolve defaults, interpret setting IDs or declaration constraints, or add a
configuration lookup/RPC. A backend may ignore the field; consumers use
`AdeleBackendSettings` to capture and read it. Missing required values or wrong
consumer types fail that startup without affecting peers or a corrected retry.
`test/backend_settings_test.dart` covers malformed frames before spawn;
`test/plugin_termination_test.dart` uses the real shared-host/backend AOT fixture
for scalar roundtrips, immutable capture, peer isolation, and same-ID replacement.

Every `startPlugin` frame also requires an explicit nonsecret `records` list,
including `[]`. Public
[`AdeleBackendRecords`](../plugin_backend_support/README.md#bootstrap-records)
owns its strict shape, identity grammar, duplicate rejection, scalar and size
bounds. The runtime captures it before startup callbacks/awaits; the host validates
and makes a fresh immutable copy before spawning. `spawnUri` requires fresh plain
list/map containers rather than unmodifiable wrappers, and the plugin-side decoder
validates and copies those again. No mutable caller container survives a boundary.
Malformed records fail before isolate creation with fixed bounded errors that do
not echo record contents. Declaration-specific ownership, allowed fields and
required values remain the upstream host owner's responsibility.

Records contain no credential references, native documents, filesystem roots,
baseline handles or authorization, and do not affect settings, ready advertisements,
exposures, or registration. `test/backend_records_test.dart` sends malformed raw
frames and proves rejection precedes spawn. The maintained AOT fixture in
`test/plugin_termination_test.dart` covers roundtrips, explicit emptiness, caller
and bootstrap mutation, settings coexistence, peers, and same-ID replacements.

Both shared-host and plugin-backend protocols use version 1 with exact
protocol-version matching. Before the first release, unstable wire changes may
retain that version; rebuild coherent runtime/host/backend snapshots rather than
reuse prior development artifacts. See the
[transport version policy](../../docs/architecture/contracts-and-capabilities.md#transport-version-policy).
Every `startPlugin` frame must supply a nonempty `hostInfrastructureContext`,
forwarded unchanged in the backend bootstrap message even for an empty allowlist.
The host does not mint this runtime-owned grant or infer one when omitted.
Forward unary requests may carry a nonempty top-level `hostInvocationContext`.
The host validates and forwards it unchanged, separately from the semantic
payload, configuration context, and service route. Explicit null and non-unary
forward commands reject the field; the backend configuration router separately
requires dispatcher opt-in. This does not alter reverse framing or grant access
to a host service. See the public
[`contextual unary adapter`](../plugin_backend_support/README.md#contextual-unary-services).
Unary `hostRequest`/`hostResponse` reuse the same response/command ports and framed
transport. The host stamps PluginId and
the host-issued connection generation from the owning isolate, correlates each
request independently of forward calls, and returns responses only to that captured
generation. Plugin-side reverse request IDs are nonnegative and strictly increasing
per plugin generation in port-send order; replay rejection retains only a
high-watermark, not an unbounded history. Plugin termination removes its pending
routes, never retargeting them
to a replacement with the same PluginId.
Reverse unary requests and stream openings require `hostContextKind` (`invocation`
or `infrastructure`) and opaque `hostContext`. Both kinds share the same increasing
request-ID sequence, replay watermark, and captured-generation response routing.
There is no compatibility interpretation of missing fields; semantic operation
payloads that use `hostInvocationContext` are unchanged.

Reverse unary responses are shape- and JSON-validated before isolate forwarding;
malformed responses settle with a fixed `invalid_host_response` failure rather
than logging their contents or a raw isolate-send exception. Framing failures use
fixed messages without parser source text or native error interpolation. Generic
runtime/backend failure formatting also omits remote error fields, while preserving
those structured fields for deliberate generated-client decoding. This protects
the existing reverse path used by the public
[`AdeleCredentialClient`](../plugin_backend_support/README.md#credential-reads);
the shared host adds no credential policy, native storage dependency, or new
transport. `test/plugin_termination_test.dart` covers malformed reverse replies
with secret-bearing payloads and continued generation-local response correlation,
plus the real AOT credential client's success, fixed failures, and grant denial.

Reverse server streaming uses the same ports/framed transport and captured
generation routing, with one-item credit and cancellation forwarded between the
backend consumer and host producer. Invocation settlement, cancellation, or
retirement revokes authority immediately and cancels its owned streams with
bounded cleanup. Late items or terminals cannot reach a replacement generation.
The installed manifest stays version 1, independently of transport versions.

Context-token validation and service allowlisting belong to `plugin_runtime`;
infrastructure has a separate generation lifetime revoked on activation retirement
before cleanup, not on individual operation completion. No host service is granted
implicitly by either transport direction. See
[`plugin_runtime` infrastructure](../plugin_runtime/README.md#generation-infrastructure).
Canonical Session/Environment authority and generated read/mutation/process dispatchers belong
to the app/domain boundary. The host neither derives authority from semantic IDs
nor knows stock source/tool behavior. Client/bidirectional streaming, ambient
callbacks, and general symmetric RPC remain unimplemented. See
[operation-scoped host calls](../../docs/architecture/contracts-and-capabilities.md#operation-scoped-host-calls)
for authorization and revocation semantics.
