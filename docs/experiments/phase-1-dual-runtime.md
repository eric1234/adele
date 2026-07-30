# Phase 1 Dual-Runtime Experiment

## Baseline

- Required base commit: `1a3090cb3308d35a11df194a3e29c1169c3bcb7d`
- Experiment date: 2026-07-28
- Host: Linux x86_64, kernel `6.8.0-136-generic`
- Eval candidates: `dart_eval 0.8.5`, `flutter_eval 0.8.2`

## Gate 1: Flutter 3.44.8

Status: **FAIL**

Verified identity:

- Flutter `3.44.8`
- Framework revision `058e0af2c2b57e369d905a03ac9748b0ebf543c6`
- Engine revision `0cd610717bde95fd88343c64f81c11ba4e5c0010`
- Dart `3.12.2`

Commands:

```text
flutter --version --machine
dart --version
dart tools/adele.dart bootstrap
dart pub workspace list
flutter pub deps
flutter test test/phase1_eval_compatibility_test.dart
```

Dependency resolution succeeded but changed `analyzer` from `12.1.0` to
`8.4.1` and `_fe_analyzer_shared` from `99.0.0` to `91.0.0`. Compilation then
failed before any EVC program was compiled:

```text
flutter_eval-0.8.2/lib/src/widgets/container.dart:14:7: Error:
The non-abstract class '$Container' is missing implementations for:
 - Container.isAntiAlias
```

Upstream issue
[flutter_eval #140](https://github.com/ethanblake4/flutter_eval/issues/140),
opened 2026-07-15, confirms this Flutter 3.44 incompatibility with the same
error and package versions. No `flutter_eval` patch was applied. Results under
the replacement validation toolchain must not be represented as Flutter 3.44
or Dart 3.12 compatibility.

Architectural implication: Phase 1 requires a matched older validation
toolchain to test the walking skeleton. Flutter modernization and an upstream
`flutter_eval` contribution or compatible release remain separate work after
the skeleton.

## Replacement Validation Toolchain

The gates restart at Gate 1 under this temporary matched toolchain:

- Flutter `3.38.10`
- Framework revision `c6f67dede3d4aa1aa7a69dd56a3494a5cde6cc80`
- Engine revision `cafcda5721a78a7884db92f13c5e89f7643d52dd`
- Engine content hash `3c25ef829c74f0f39fbb8df093d9a6b9f941ea6b`
- Dart `3.10.9`
- DevTools `2.51.1`
- SDK root `/home/me/.asdf/installs/flutter/3.38.10-stable`

This identity was observed from that SDK's absolute `flutter` and `dart`
executables. It is a Phase 1 validation pin, not a permanent ADELE toolchain.

The `analyzer 8.4.1` resolution is acceptable only if formatting, analysis,
and all repository tests pass under this exact toolchain.

## Gate 1: Matched Toolchain Compatibility

Status: **PASS**

Commands were run with
`/home/me/.asdf/installs/flutter/3.38.10-stable/bin` first on `PATH`:

```text
flutter pub get
dart tools/adele.dart bootstrap
dart pub workspace list
flutter pub deps
flutter test test/phase1_eval_compatibility_test.dart
dart tools/adele.dart format
dart tools/adele.dart format --check
dart tools/adele.dart analyze
dart tools/adele.dart test
```

The direct `Compiler` plus monolithic `flutterEvalPlugin` probe compiled and
passed. Formatting, every package analysis, existing public value tests, the
Phase 0 shell test, and the eval compatibility test all passed. This accepts
`analyzer 8.4.1` and `_fe_analyzer_shared 91.0.0` as a Phase 1 limitation only.
The Dart 3.10 pub workspace implementation also required replacing workspace
path globs with the same explicit package paths; no package was added or
removed.

## Gate 2: Minimal Backend AOT

Status: **PASS**

Source: `tools/experiments/phase1/aot_spawn_uri/backend.dart`

Commands:

```text
/home/me/.asdf/installs/flutter/3.38.10-stable/bin/dart compile aot-snapshot tools/experiments/phase1/aot_spawn_uri/backend.dart -o .dart_tool/adele/phase1/experiments/aot_spawn_uri/backend.aot
/home/me/.asdf/installs/flutter/3.38.10-stable/bin/cache/dart-sdk/bin/dartaotruntime .dart_tool/adele/phase1/experiments/aot_spawn_uri/backend.aot
```

The architecture-specific AOT snapshot was 778,208 bytes and printed
`backend-aot=valid` under the matching `dartaotruntime`.

## Gate 3: AOT Host Loads Backend AOT

Status: **PASS**

Source: `tools/experiments/phase1/aot_spawn_uri/host.dart`

The host was compiled with the same `dart compile aot-snapshot` command and
executed using the same `dartaotruntime`. It loaded:

```text
file:///home/me/Data/Development/adele/.dart_tool/adele/phase1/experiments/aot_spawn_uri/backend.aot
```

Observed evidence:

```text
handshake=ready
ping={kind: response, requestId: 1, ok: true, payload: {message: pong, nested: [1, true, {portable: true}]}}
unknown={kind: response, requestId: 2, ok: false, error: {code: unknown_method, message: Unknown method.}}
shutdown={kind: response, requestId: 3, ok: true, payload: {stopping: true}}
exit=observed
```

This proves the mechanism in a pure-Dart AOT host under Dart 3.10.9 on Linux
x64. It does not yet prove loading from the Flutter 3.38.10 desktop embedding.

## Gate 4: Portable Transport

Status: **PASS**

`plugin_runtime` now owns request IDs, one pending table per connection,
portable request/response envelopes, structured remote failures, diagnostics
for malformed/unknown/duplicate responses, startup timeout, exit/error ports,
pending-request rejection, and graceful shutdown with forced-isolate fallback.
Tests passed for concurrent out-of-order responses, monotonic IDs, unknown and
duplicate response IDs, structured errors, and pending requests during close.

## Gates 5-8: Builder Through Typed Filesystem Service

Status: **PASS**

The integration driver was compiled to AOT because an initial `dart run`
attempt correctly failed with:

```text
IsolateSpawnException: The uri(...) is an AOT snapshot and the JIT VM cannot
spawn an isolate using it.
```

The matching AOT host then produced:

```text
buildId=1785290766337213
backendArtifact=/home/me/Data/Development/adele/.dart_tool/adele/phase1/plugins/dev.adele.workspace-demo/builds/1785290766337213/backend.aot
stage=configuration exitCode=0
stage=configuration exitCode=0
stage=dependency-resolution exitCode=0
stage=backend-compilation exitCode=0
listing=[phase1.txt]
contents=phase one
runtime=Backend exit observed.
closed=true
```

The plugin contract contains immutable nested directory values, text contents,
and an asynchronous typed service. The app owns the temporary typed proxy and
host codec. The backend owns the independently located dispatcher and codec.
No wire maps are exposed by the contract package.

Backend direct tests cover deterministic immediate listing, nested/empty
directories through the same implementation, strict UTF-8, missing resources,
wrong resource kinds, outside-root access, and symlink escape rejection. The
proof resolves symlinks before confinement checks, so links resolving outside
the development root are rejected and symlink entries are omitted from
listings.

## Gate 9: Persisted EVC

Status: **PASS**

A pure-Dart direct `Compiler` probe produced a 9,251-byte EVC artifact, read it
back from disk, constructed `Runtime` from the bytes, and returned
`pure-dart-evc`. Under the Flutter engine, the monolithic official
`flutterEvalPlugin` compiled an interpreted `StatelessWidget`, serialized the
program, reloaded EVC bytes, and executed its constructor.

Running a Flutter-importing probe with standalone `dart` produced expected
`dart:ui` type failures and is not treated as Flutter compatibility evidence.
Flutter eval compilation must run inside a Flutter engine process.

## Gate 10: Interpreted Flutter Widget

Status: **PASS**

The app test persisted `frontend.evc` to a real temporary file, reread it,
constructed a fresh runtime, registered `flutterEvalPlugin`, executed
`MyApp.`, validated a Flutter `Widget`, mounted it, and found the interpreted
text. The completed test took two seconds.

Earlier apparent hangs were reduced to asynchronous filesystem calls inside a
Flutter fake-async widget test. Synchronous file operations made the artifact
proof deterministic; in-memory EVC reload and mounting independently passed.
`dart_eval 0.8.5` exposes no explicit runtime disposal API observed in this
experiment, so reclamation currently relies on unmounting and releasing host
references.

## Gate 11: Typed Async Eval Bridge

Status: **PASS WITH DEVIATION**

A custom top-level bridge returning `Future<$Value?>` was awaited by
interpreted code. The eval function combined the bridged value with its own
string and returned `$String("interpreted:host")`. Returning a host
`Future<String>` directly failed because the await opcode requires values to
remain `$Value` instances inside the eval VM. This establishes the minimum
async bridge convention; full workspace contract-value wrappers and UI remain
to be completed.

The completed EVC test compiles the real
`workspace_demo_frontend.dart`, explicitly retains its non-`main.dart`
entrypoint through `Compiler.entrypoints`, persists and reloads EVC, and
registers only `flutterEvalPlugin` plus one workspace-demo plugin. Interpreted
code awaits directory and text calls through immutable typed bridge wrappers,
then renders `notes.txt` and `typed backend text`. Ports, request IDs, maps,
filesystem APIs, and host runtime objects remain hidden.

Two package limitations required narrow handling:

- `dart_eval` tree-shakes source files not ending in `/main.dart` unless their
  URI is added explicitly to `Compiler.entrypoints`.
- A raw `String` returned after a second interpreted `await` is unboxed to a
  host `String`, which Flutter bridge constructors reject because they require
  `$Value`. A small immutable `WorkspaceDemoTextData` wrapper keeps the value
  boxed until its getter is used.

Interactive file selection is not yet proven. Attempts to retain async values
in an interpreted stateful widget exposed the same unboxing issue, so this
proof selects the first regular file after listing. This Phase 1 deviation
prevents a final `SUCCESS` verdict unless resolved.

## Gate 12: Stop, Build, and Reload Scaffolding

Status: **PARTIAL**

The private app controller validates explicit Phase 1 configuration, builds
fresh backend and frontend artifact generations, activates only complete
builds, invalidates and unmounts the old eval bridge before stopping the
backend, keys interpreted subtrees by build ID, and exposes build/start, stop,
and rebuild/reload controls with app-visible diagnostics. Phase 0 fallback and
Phase 1 inactive/configuration-error shell tests pass.

Three consecutive profile reload cycles were not run because Gate 13 failed at
the foundational backend launch mechanism.

## Gate 13: Flutter Profile Host

Status: **FAIL**

Command:

```text
ADELE_PHASE1_REPOSITORY_ROOT=/home/me/Data/Development/adele \
ADELE_PHASE1_PLUGIN_DIRECTORY=/home/me/Data/Development/adele/plugins/workspace_demo \
ADELE_PHASE1_DEVELOPMENT_DIRECTORY=/home/me/Data/Development/adele/.dart_tool/adele/phase1/profile-demo \
ADELE_PHASE1_DART_EXECUTABLE=/home/me/.asdf/installs/flutter/3.38.10-stable/bin/dart \
ADELE_PHASE1_FLUTTER_EXECUTABLE=/home/me/.asdf/installs/flutter/3.38.10-stable/bin/flutter \
dart tools/adele.dart smoke linux --profile
```

The Linux profile app built successfully. At runtime the app verified both
toolchains, resolved backend dependencies, compiled a fresh backend AOT
snapshot, and called `Isolate.spawnUri` with that artifact URI. No backend
handshake occurred. After startup monitoring was changed to race handshake
against error and exit ports, the new isolate reported:

```text
UI actions are only available on root isolate.
#0 PlatformDispatcher.__nativeSetNeedsReportTimings
...
#20 runApp
#21 main (package:adele_desktop/main.dart:37)
```

This shows that the Flutter profile runtime created a new isolate group but
executed the ADELE Flutter application's `main`, not the supplied backend AOT
entrypoint. The separately compiled backend source contains no Flutter import
or `runApp` call. The same backend AOT loading mechanism and bootstrap protocol
passed from a separately compiled pure-Dart AOT host under the same Dart
3.10.9 SDK.

Observed platform and mode:

- Linux x86_64
- Flutter `3.38.10` profile mode
- Framework `c6f67dede3d4aa1aa7a69dd56a3494a5cde6cc80`
- Engine `cafcda5721a78a7884db92f13c5e89f7643d52dd`
- Backend built by bundled Dart `3.10.9`

Architectural consequence: same-process loading of a separately compiled Dart
AOT module through `Isolate.spawnUri` is not viable as specified in this
Flutter desktop embedding. Phase 1 must not use a process fallback without a
separate decision. A future ADR should evaluate a pinned `dartaotruntime`
process and explicit local transport, including lifecycle, security, packaging,
and cross-platform implications.

## Gate 14: Platform Status

Status: **PARTIAL**

| Platform | Build | Runtime | Backend AOT load | Transport | Eval compile/render | Reload |
| --- | --- | --- | --- | --- | --- | --- |
| Linux x64 | Profile PASS | Profile FAIL | FAIL in Flutter embedding; PASS in pure-Dart AOT host | PASS in pure-Dart AOT host | PASS in Flutter tests | NOT RUN |
| macOS | NOT TESTED | NOT TESTED | NOT TESTED | NOT TESTED | NOT TESTED | NOT TESTED |
| Windows | NOT TESTED | NOT TESTED | NOT TESTED | NOT TESTED | NOT TESTED | NOT TESTED |

## Final Validation

All commands used the Flutter 3.38.10 SDK's `bin` directory first on `PATH`:

| Command | Result |
| --- | --- |
| `dart tools/adele.dart bootstrap` | PASS |
| `dart tools/adele.dart format` | PASS, 50 files unchanged |
| `dart tools/adele.dart format --check` | PASS |
| `dart tools/adele.dart analyze` | PASS for tools and every package |
| `dart tools/adele.dart test` | PASS |
| `dart tools/adele.dart check` | PASS |
| `dart tools/adele.dart build linux --profile` | PASS |
| `dart tools/adele.dart smoke linux --profile` | FAIL at backend launch |

The final backend artifact was a 976,296-byte x86-64 ELF shared object. The
profile Linux launcher was an x86-64 PIE executable. Generated artifacts remain
under ignored `.dart_tool` and `app/build` roots.

## Proven Assumptions

- Flutter 3.38.10 and bundled Dart 3.10.9 resolve exact `dart_eval 0.8.5` and
  `flutter_eval 0.8.2` with analyzer 8.4.1.
- Repository formatting, analysis, and tests pass with analyzer 8.4.1.
- The pinned Dart compiler produces a valid architecture-specific backend AOT
  module.
- A separately compiled pure-Dart AOT host can load that module with
  `Isolate.spawnUri`, exchange portable values, and observe shutdown.
- Persisted EVC can be loaded and can render an interpreted Flutter widget.
- Typed awaited bridge calls can invoke the workspace service and reconstruct
  immutable nested values.

## Disproven Assumptions

- `flutter_eval 0.8.2` is not source-compatible with Flutter 3.44.8; upstream
  issue #140 confirms the missing `Container.isAntiAlias` bridge member.
- A Flutter 3.38.10 Linux profile host does not execute the supplied external
  AOT backend through `Isolate.spawnUri`; it executes the Flutter application's
  entrypoint in the new isolate group.
- Raw host strings after multiple interpreted awaits cannot always be passed
  directly to Flutter bridge constructors; boxed bridge values are required.

## Unresolved Hypotheses

- Flutter release mode was not run after profile mode disproved the
  foundational backend launch mechanism.
- macOS and Windows behavior is not tested.
- A process-hosted backend may provide the required separation, but packaging,
  lifecycle, security, and transport require a separate ADR and experiment.
- Stateful interactive selection may become viable after `dart_eval` async
  bridge behavior is modernized.

## Verdict

```text
FAILED — foundational mechanism disproven or blocked
```

The requested complete profile/release vertical path did not run. No process
fallback was implemented. Recommended follow-up is a separate backend-process
ADR plus a compatibility workstream to upgrade Flutter and contribute or adopt
modernized `flutter_eval` support. Generated contracts should remain proposed
until a viable runtime boundary is selected and the manual binding requirements
are exercised against it.
