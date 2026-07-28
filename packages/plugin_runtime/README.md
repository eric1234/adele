# Plugin Runtime

`plugin_runtime` is an internal, pure-Dart package reserved for host-side plugin
lifecycle and runtime coordination. It contains no runtime API in Phase 0.

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

## Deferred

Discovery, installation state, artifact selection, backend startup and shutdown,
runtime connections, frontend coordination, failures, reload, profiles, and
multiple runtime instances are deferred. Activation will not be modeled as an
intrinsic installed-plugin property.
