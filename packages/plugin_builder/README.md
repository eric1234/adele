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
shared host, Git Environment, and OpenAI backend AOT snapshots plus Chat,
Filesystem Tools, and Command Tools frontend EVC before launching the Flutter
run/build command. Backend compilation runs
outside Flutter; frontend compilation uses Flutter build-time tooling. This also
applies to explicit Linux debug/release modes; non-Linux commands and the explicit
development smoke entry remain unchanged. `tools/backend_artifacts.dart` owns
backend source paths, not the normal app runtime or the snapshot primitive.

The launcher inspects its selected Flutter executable and uses that SDK's bundled
`dart` and sibling `dartaotruntime`, not a potentially unrelated `dart` on PATH.
It compiles the host first, then Git and OpenAI. `tools/frontend_artifacts.dart`
then prepares all three stock EVCs with the selected Flutter SDK. Only after preparation
succeeds does the launcher pass:

- `ADELE_DARTAOTRUNTIME_EXECUTABLE`: absolute matched runtime path.
- `ADELE_BACKEND_HOST_ARTIFACT`: absolute shared host `.aot` path.
- `ADELE_GIT_ENVIRONMENT_ARTIFACT`: absolute Git backend `.aot` path.
- `ADELE_OPENAI_ARTIFACT`: absolute OpenAI backend `.aot` path.
- `ADELE_CHAT_FRONTEND_ARTIFACT`: absolute Chat frontend `.evc` path.
- `ADELE_FILESYSTEM_TOOLS_FRONTEND_ARTIFACT`: absolute Filesystem Inspection `.evc` path.
- `ADELE_COMMAND_TOOLS_FRONTEND_ARTIFACT`: absolute Command Inspection `.evc` path.

These are deployment inputs only. ChatGPT credential-store paths, OAuth
configuration, and model selection remain runtime stock configuration described
in [`app/README.md`](../../app/README.md#chatgpt-source-checkout-configuration),
not compiler defines or shared-host configuration.

Frontend preparation invokes `app/tool/compile_chat_frontend.dart` from `app/`
with `flutter test --no-pub --concurrency 1 tool/compile_chat_frontend.dart`.
`ADELE_REPOSITORY_ROOT` and `ADELE_CHAT_FRONTEND_OUTPUT` are build-time environment
inputs, not normal runtime source/compiler configuration. The test runner supplies
the Flutter environment required by the eval compiler; this package remains pure
Dart and does not gain Flutter/eval dependencies. See
[`app/README.md`](../../app/README.md#prepared-chat-frontend) for standalone use.

The same launcher invokes `app/tool/compile_tool_inspection_frontends.dart` once
for each owning tool frontend, using `ADELE_TOOL_INSPECTION_FRONTEND` and
`ADELE_TOOL_INSPECTION_FRONTEND_OUTPUT` alongside the repository root. Each stage
must produce nonempty EVC before application launch; failure never silently reuses
an older artifact. These Flutter compiler entrypoints remain outside this package
and the normal application startup import graph.

Each invocation gets fresh `.dart_tool/adele/desktop-backends/build-*` and
`.dart_tool/adele/desktop-frontends/build-*` directories.
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

Future installation/update should prepare artifacts independently of activation.
Normal activation only consumes prepared artifacts and never compiles source.
Current checkout tooling is a stand-in for that preparation, not implemented
installation, update management, discovery, profiles, or caching.

## Current Scope

Frontend EVC compilation belongs to Flutter build-time tooling under `app/tool`,
not the normal app runtime or generic prepared frontend host. This package stays
pure Dart and must not depend on eval or Flutter. Production
caching, installation, signing, and invalidation remain deferred. Generation is
owned by `contract_codegen`; this package rejects stale generated files before
compilation and never activates an incomplete build. Its tests create isolated
temporary plugin layouts so verification cannot accidentally depend on the
repository's generator configuration or maintained fixture.
