# Plugin Runtime

`plugin_runtime` is an internal, pure-Dart package for the shared backend host.
It owns the semantic process-host connection, deterministic framed
IPC, request correlation, plugin routing, structured remote failures,
exit/stderr monitoring, and shutdown cleanup. Process and framing objects do not
escape its API.

## Dependencies

It may depend on ADELE's public plugin-facing packages and small pure-Dart host
packages when implementation requires them. It must not depend on Flutter,
plugin implementations, `adele_desktop`, or `plugin_builder`. Plugins must never
depend on this package.

## Runtime Model

The intended default remains one plugin runtime instance per activation
context; activation-context lifecycle is not implemented. The maintained
runtime proves that one plugin generation can expose several configured
capability instances under separate configuration contexts and that
context/service routing fails closed. Additional runtimes for isolation or
concurrency may be considered after evidence exists.

The maintained semantic surface is `PluginBackendHost` plus per-plugin
`PluginBackendConnection`. It intentionally hides `Process`, framing, ports,
and request IDs.

Stopping a plugin fails its outstanding requests. Malformed host output closes
all connections and kills and reaps the child process.
`PluginBackendConnection.close()` has one supported behavior: bounded semantic
plugin shutdown.

## Validated Scope

Direct Flutter `Isolate.spawnUri` remains disproven. The continuation starts one
shared child `dartaotruntime` host, which successfully loads plugin snapshots in
separate isolate groups under Linux profile mode. Generated unary and streaming
requests retain exact generation, configuration-context, and service routing;
the protocol handshake and shutdown/cancellation paths are validated. Discovery,
installation, profiles, packaging, and production lifecycle remain deferred.
