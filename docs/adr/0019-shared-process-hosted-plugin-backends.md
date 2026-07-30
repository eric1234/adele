# ADR 0019: Plugin backends use one shared process-hosted Dart runtime

## Status

Accepted for the current experimental foundation

## Context

ADELE needs to load locally compiled plugin backend AOT snapshots without
linking plugin implementation code into the Flutter application. A Linux x64
profile experiment proved that stock Flutter does not execute an external AOT
snapshot supplied to `Isolate.spawnUri`; it starts the Flutter application's
entrypoint in the new isolate group instead.

A continuation experiment proved a shared child Dart runtime:

```text
ADELE Flutter process
  -> one child dartaotruntime backend host
       -> one external AOT isolate group per active plugin
```

The failed experiment is preserved at branch
`experiment/phase1-dual-runtime`, commit `70f6337`. The successful continuation
is preserved at branch `experiment/phase1-backend-host`, commit `7b41d37`.

## Decision

ADELE's current backend runtime direction is one shared pure-Dart backend-host
process started with an absolute matched `dartaotruntime` executable. The host
loads each active plugin backend snapshot into its own isolate group using
`Isolate.spawnUri`.

The Flutter process communicates with the host through deterministic
length-prefixed UTF-8 JSON frames over stdin/stdout. Stdout is reserved for
protocol frames and stderr carries diagnostics. Semantic host APIs hide process
objects, frames, request IDs, ports, and wire maps.

Unexpected plugin termination removes the plugin from the host registry, fails
its pending requests with structured errors, and permits restart with the same
plugin ID. Host startup and shutdown are bounded, with forced termination after
a graceful timeout.

## Consequences

- One operating-system process can host multiple plugin isolate groups.
- The Dart runtime must be packaged and version-matched with compiled plugin
  artifacts.
- This is isolation, not a security sandbox.
- Linux x64 Flutter profile mode is proven. Windows, macOS, release mode,
  packaging, discovery, sandboxing, and current-Flutter compatibility remain
  unproven.
- The interpreted frontend currently uses pinned `dart_eval` and
  `flutter_eval`; those dependencies must be modernized or replaced before a
  broad third-party interpreted UI API is exposed.
