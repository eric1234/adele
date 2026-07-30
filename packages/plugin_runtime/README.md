# Plugin Runtime

`plugin_runtime` is an internal, pure-Dart package for the Phase 1 backend-host
experiment. It owns the semantic process-host connection, deterministic framed
IPC, request correlation, plugin routing, structured remote failures,
exit/stderr monitoring, and shutdown cleanup. Process and framing objects do not
escape its API.

## Dependencies

It may depend on ADELE's public plugin-facing packages and small pure-Dart host
packages when implementation requires them. It must not depend on Flutter,
plugin implementations, `adele_desktop`, or `plugin_builder`. Plugins must never
depend on this package.

## Expected Model

The expected default is one plugin runtime instance per activation context,
with multiple configured capability instances managed by that runtime when
needed. This is not a permanent restriction; additional runtimes for isolation
or concurrency may be considered after evidence exists.

Future semantic names may include `PluginBackendLauncher`,
`PluginBackendConnection`, `PluginTransport`, and `PluginRuntime`. Names that
encode an unproven mechanism are intentionally avoided.

## Experiment Result

Direct Flutter `Isolate.spawnUri` remains disproven. The continuation starts one
shared child `dartaotruntime` host, which successfully loads plugin snapshots in
separate isolate groups under Linux profile mode. Discovery, installation,
profiles, packaging, and production lifecycle remain deferred.
