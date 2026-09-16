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
using public [`AdeleCapabilityExposure`](../contract/lib/adele_contract.dart).
The host validates and forwards these on `pluginReady` to the exact runtime
connection. Omission means zero capabilities. Plugin identity
remains host/connection-owned, not advertisement-owned. Malformed ready metadata
fails only that plugin startup and cleans up its partial isolate resources;
shared-host failure remains global. The host does not discover installations,
select stock backends, interpret plugin configuration argv, or own the active
capability registry. See
[`contracts-and-capabilities.md`](../../docs/architecture/contracts-and-capabilities.md#backend-ready-advertisements).

The host also forwards `startupArgumentsOnly` from `startPlugin` into the backend
startup message alongside argv, without a PluginId switch or configuration parsing.
The flag defaults to `false` for direct/self-hosting callers; normal application
bootstrap always sets it to `true`. This is temporary deployment metadata, not an
environment scrubber or settings/profile/credential service. See
[`plugin_runtime` startup arguments](../plugin_runtime/README.md#startup-arguments).
