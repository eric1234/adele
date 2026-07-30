# Phase 1 Shared Backend-Host Continuation

## Relationship to the Original Experiment

The original result in `phase-1-dual-runtime.md` remains unchanged:

```text
FAILED — Flutter same-process external AOT loading mechanism blocked
```

This continuation starts from commit `70f6337` and tests a separate mechanism:

```text
Flutter profile application
  -> one child dartaotruntime backend-host process
       -> one spawnUri isolate group per active plugin
```

## Toolchain

- Flutter `3.38.10`
- Framework `c6f67dede3d4aa1aa7a69dd56a3494a5cde6cc80`
- Engine `cafcda5721a78a7884db92f13c5e89f7643d52dd`
- Dart `3.10.9`
- `dart_eval 0.8.5`
- `flutter_eval 0.8.2`
- Analyzer `8.4.1`

`.tool-versions` tracks `flutter 3.38.10-stable` for local asdf sessions. This
is still a temporary validation pin, not ADELE's permanent toolchain.

## Gate Results

### Gate 1: Backend-Host AOT — PASS

The host compiled to AOT, emitted framed `hostHello`, accepted
`shutdownHost`, emitted `hostStopped`, and exited zero under the matched
absolute `dartaotruntime`.

### Gate 2: Host Loads Plugin — PASS

The shared host loaded `workspace_demo_backend.aot`, completed its `SendPort`
handshake, served a directory request, stopped the plugin independently,
remained alive, restarted the same plugin, stopped it again, and shut down.

An initial failure proved that `List.cast<String>()` is not portable across the
new isolate-group boundary. Materializing a standard `List<String>` fixed the
bootstrap without loosening the portable-value rule.

### Gate 3: Framed Transport — PASS

The protocol uses a four-byte big-endian unsigned length followed by UTF-8 JSON.
Tests cover partial reads, multiple frames per read, malformed UTF-8, oversized
frames, structured startup errors, unknown response IDs, process exit with a
pending request, startup timeout, and graceful-shutdown timeout followed by
forced termination. Stdout is protocol-only; diagnostics use stderr.

### Gate 4: Typed Workspace Service — PASS

The existing `WorkspaceDemoProxy` listed `two.txt`, reconstructed immutable
contract values, and read `gate two` through the child process and plugin
isolate. Plugin stop left the shared host alive; host shutdown exited cleanly.
Filesystem confinement, symlink rejection, and strict UTF-8 tests remain green.

### Gate 5: Flutter Profile Host — PASS

`dart tools/adele.dart smoke linux --profile` built and ran the actual profile
application. It compiled backend-host and plugin AOT artifacts, started the
absolute matched `dartaotruntime`, loaded the plugin, completed typed backend
calls while constructing the interpreted widget, stopped the plugin, and
stopped the process cleanly.

### Gate 6: Complete Vertical Path — PASS

The profile application compiled and loaded persisted EVC, registered the
official Flutter plugin plus the narrow workspace bridge, awaited typed backend
calls through the child process, and constructed the interpreted widget. No
process, framing, request ID, port, or wire map is visible to interpreted code.

### Gate 7: Stop, Rebuild, Reload — PASS

Three profile cycles completed with distinct build IDs:

```text
cycle=1 build=1785376747668635 hostPid=339011
cycle=2 build=1785376759975294 hostPid=339191
cycle=3 build=1785376772076195 hostPid=339368
```

Each cycle invalidated and unmounted the frontend, stopped the plugin, shut down
the host process, built a fresh plugin artifact generation, started a fresh
connection and request-ID table, loaded fresh EVC, and rendered again. All
three PIDs were verified stopped after the run.

### Gate 8: Failure Handling — PASS

Tests prove structured plugin startup errors, malformed frames, host exit with
pending requests, startup timeout, forced shutdown after graceful timeout,
unknown IDs, and stage-specific stderr diagnostics. Plugin isolate uncaught
errors are forwarded as `plugin-isolate` diagnostics. Unexpected plugin exit
removes the plugin from the host registry, fails every routed pending request
with `plugin_exited` or `plugin_failed`, closes the semantic connection, and
allows the same plugin ID to start again. Tests cover exit with and without a
pending request plus successful restart.

## Interactive Frontend Follow-Up

The interpreted UI now receives two files, lets the user select the second,
awaits its typed contents, updates interpreted state, and renders both
`Selected: notes.txt` and `typed backend text`. A delayed completion after
unmount is ignored using an interpreted disposal flag.

Narrow eval workarounds remain:

- Explicit `Compiler.entrypoints` for the non-`main.dart` frontend.
- `$Value`-preserving immutable bridge wrappers.
- Two explicit file buttons because `dart_eval 0.8.5` miscompiles a captured
  loop index in the button callback.
- An interpreted disposal flag because `flutter_eval 0.8.2` does not expose
  `State.mounted`.

## Platform Status

Linux x64 profile is tested end to end. macOS and Windows are not tested. No
Flutter 3.44 or Dart 3.12 compatibility is claimed.

## Verdict

```text
SUCCESS — complete Linux x64 profile vertical path proven
```

This verdict applies to the shared backend-host continuation on Linux x64
profile mode. It does not reverse the failed same-process result and does not
yet accept the process-host architecture as production-ready.
