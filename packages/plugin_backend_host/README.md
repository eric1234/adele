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

F3a uses version 2 for both shared-host and plugin-backend protocols; rebuild the
host and backend snapshots together. Unary `hostRequest`/`hostResponse` reuse the
same response/command ports and framed transport. The host stamps PluginId and
the host-issued connection generation from the owning isolate, correlates each
request independently of forward calls, and returns responses only to that captured
generation. Plugin-side reverse request IDs are nonnegative and strictly increasing
per plugin generation in port-send order; replay rejection retains only a
high-watermark, not an unbounded history. Plugin termination removes its pending
routes, never retargeting them
to a replacement with the same PluginId.

Invocation-token validation and service allowlisting belong to `plugin_runtime`;
canonical Session/Environment authority and the generated read dispatcher belong
to the app/domain boundary. The host neither derives authority from semantic IDs
nor knows AGENTS.md behavior. Reverse streaming and general symmetric RPC remain
deferred. The confirmed Linux profile build includes this host and all three
backends plus four EVCs; build success alone does not validate every host-call or
termination path. See [normal backend startup](../../app/README.md#normal-backend-startup).
