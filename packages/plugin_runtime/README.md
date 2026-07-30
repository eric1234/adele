# Plugin Runtime

`plugin_runtime` is an internal, pure-Dart package for the Phase 1 backend
launch experiment. It owns semantic launcher/connection APIs, startup timeout,
portable request/response envelopes, request correlation, structured remote
failures, exit/error monitoring, and shutdown cleanup.

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

The implementation works from a pure-Dart AOT host. Flutter 3.38.10 Linux
profile mode does not execute the supplied backend snapshot through
`Isolate.spawnUri`; it executes the Flutter app entrypoint in the new isolate
group. This package does not contain a process fallback. Discovery,
installation, profiles, and production lifecycle remain deferred.
