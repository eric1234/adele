# Plugin Builder

`plugin_builder` is an internal, pure-Dart package. It implements narrow
development manifest parsing, exact toolchain checks, dependency resolution,
fresh build directories, generated-contract verification, backend AOT
compilation, captured process diagnostics, and complete-build activation.

`prepareBackend` validates the Dart toolchain before running build tooling. It
resolves `packages.contract` from the requested plugin manifest, reads that
package's name from `pubspec.yaml`, and checks the absolute
`lib/<package-name>.dart` source with `contract_codegen --check --source`.
Missing or stale plugin contract sources fail before Flutter validation,
dependency resolution, or backend compilation.

`compileAotSnapshot` is the reusable single-snapshot primitive. Callers select
the Dart executable, working directory, entrypoint, output artifact, and diagnostic
stage. It creates the output parent, runs `dart compile aot-snapshot`, delivers
captured `PluginBuildDiagnostic` output (including failures), and throws
`PluginBuildFailure` on process-start failure, a nonzero exit, or missing output.
The optional diagnostic callback is awaited before checking the result, preserving
the builder's stdout/stderr files even on compiler failure. Source discovery,
toolchain selection, dependency resolution, and artifact lifetime stay with callers.
The development builder, self-hosting compiler, and resource-inspector smoke
compiler share this primitive.

## Desktop Tooling

Normal `dart tools/adele.dart run linux` and `build linux --profile` prepare the
shared host and Git Environment backend AOT snapshots outside Flutter, before
launching the Flutter run/build command. This also applies to explicit Linux
debug/release modes; non-Linux commands and the explicit development smoke entry
remain unchanged. `tools/backend_artifacts.dart` owns the repository source paths,
not the app or the snapshot primitive.

The launcher inspects its selected Flutter executable and uses that SDK's bundled
`dart` and sibling `dartaotruntime`, not a potentially unrelated `dart` on PATH.
It compiles the host first, then Git, and only after both succeed passes exactly:

- `ADELE_DARTAOTRUNTIME_EXECUTABLE`: absolute matched runtime path.
- `ADELE_BACKEND_HOST_ARTIFACT`: absolute shared host `.aot` path.
- `ADELE_GIT_ENVIRONMENT_ARTIFACT`: absolute Git backend `.aot` path.

Each invocation gets a fresh `.dart_tool/adele/desktop-backends/build-*` directory.
Outputs are retained, including partial failed builds, so later invocations do not
replace artifacts still used by an app or previously built bundle. This is local
development provisioning, not portable distribution: bundles retain absolute paths,
and removing those artifacts or changing the SDK can invalidate them. There is no
cache, manifest, installation, automatic cleanup, or packaging architecture here.
Workspace dependencies must already be bootstrapped for real compilation. The
launcher uses SDK-only relative imports so `test-plan --json` still runs before
bootstrap. Focused launcher tests use fake SDK processes rather than desktop builds.

## Dependencies

It may depend on lightweight pure-Dart build libraries and public contract
declarations required by the implemented pipeline. It must not depend on Flutter runtime
UI, `adele_desktop`, plugin implementations, or `plugin_runtime`. Plugins must
never depend on this package.

## Artifact Scope

Compiled artifacts normally belong to an installation and pinned-toolchain
context. Identical source and build context should allow reuse across ADELE
profiles and across configured capability instances. Toolchain changes may
invalidate those artifacts.

## Current Scope

Frontend EVC compilation remains in the Flutter application because this
package stays pure Dart and must not depend on eval or Flutter. Production
caching, installation, signing, and invalidation remain deferred. Generation is
owned by `contract_codegen`; this package rejects stale generated files before
compilation and never activates an incomplete build. Its tests create isolated
temporary plugin layouts so verification cannot accidentally depend on the
repository's generator configuration or maintained fixture.
