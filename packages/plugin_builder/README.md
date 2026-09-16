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
Filesystem Tools, Command Tools, and OpenAI activity frontend EVCs before launching the Flutter
run/build command. Backend compilation runs
outside Flutter; frontend compilation uses Flutter build-time tooling. This also
applies to explicit Linux debug/release modes; non-Linux commands and the explicit
development smoke entry remain unchanged. `tools/backend_artifacts.dart` owns
backend source paths and stock installation assembly, not the normal app runtime
or the snapshot primitive. Stock source directories are not required to have the
reference fixture's draft `adele_plugin.yaml` source/build manifest.

The launcher inspects its selected Flutter executable and uses that SDK's bundled
`dart` and sibling `dartaotruntime`, not a potentially unrelated `dart` on PATH.
It compiles the host first, then Git and OpenAI. `tools/frontend_artifacts.dart`
then prepares all four stock EVCs with the selected Flutter SDK. Only after preparation
succeeds does the launcher pass:

- `ADELE_DARTAOTRUNTIME_EXECUTABLE`: absolute matched runtime path.
- `ADELE_BACKEND_HOST_ARTIFACT`: absolute shared host `.aot` path.
- `ADELE_PLUGIN_INSTALLATION_ROOT`: absolute fresh prepared-installations root.
- `ADELE_PLUGIN_STARTUP_ARGUMENTS_FILE`: absolute generic startup-arguments JSON file.
- `ADELE_CHAT_FRONTEND_ARTIFACT`: absolute Chat frontend `.evc` path.
- `ADELE_FILESYSTEM_TOOLS_FRONTEND_ARTIFACT`: absolute Filesystem Inspection `.evc` path.
- `ADELE_COMMAND_TOOLS_FRONTEND_ARTIFACT`: absolute Command Inspection `.evc` path.
- `ADELE_OPENAI_ACTIVITY_FRONTEND_ARTIFACT`: absolute OpenAI activity `.evc` path.

Backend installation directories are immediate children of the installation root:

```text
desktop-backends/build-*/
|-- host.aot
|-- startup-arguments.json
`-- installations/
    |-- git-environment/
    |   |-- adele_plugin.installation.json
    |   `-- backend.aot
    `-- openai/
        |-- adele_plugin.installation.json
        `-- backend.aot
```

Each installed JSON manifest contains a schema version, plugin metadata, and a
relative prepared backend artifact, not source paths, capability exposures, configuration, or
activation state. Its runtime schema and catalog failure rules are maintained in
[`plugin-layout.md`](../../docs/architecture/plugin-layout.md#prepared-installation-snapshot).
The runtime discovers this snapshot before starting a host; it does not run the
source builder or know Git/OpenAI source layout.

The separate temporary startup file is a JSON object mapping PluginId to
`List<String>` argv. The launcher derives OpenAI's credential-file reference and
public OAuth/endpoint options from its environment, never token contents. It always
writes `--chatgpt-only` for OpenAI, adding a second JSON-string argument only when
configured. With no configuration the backend starts with zero capabilities; it
does not inherit an API-key exposure. Independently, normal bootstrap always sets
`startupArgumentsOnly: true`, forwarded through the shared host to backend startup.
OpenAI then disables environment fallback even for empty argv or an absent
configuration document; root-only normal activation cannot inherit an API-key
exposure even without this launcher map. Direct/self-hosting callers keep the default `false` and their existing
environment configuration path. This is temporary deployment metadata, not
general settings/profile/credential infrastructure. The application forwards argv
generically without interpreting OpenAI fields. The app reads only the model default/override,
without a credential-presence gate; provider availability comes from the active
registry. This does not implement general provider/model configuration. See
[`app/README.md`](../../app/README.md#chatgpt-source-checkout-configuration).
The defines carry deployment locations, not tokens or model values. This temporary
seam is intended to disappear with general plugin configuration/profiles.

Frontend preparation invokes `app/tool/compile_chat_frontend.dart` from `app/`
with `flutter test --no-pub --concurrency 1 tool/compile_chat_frontend.dart`.
`ADELE_REPOSITORY_ROOT` and `ADELE_CHAT_FRONTEND_OUTPUT` are build-time environment
inputs, not normal runtime source/compiler configuration. The test runner supplies
the Flutter environment required by the eval compiler; this package remains pure
Dart and does not gain Flutter/eval dependencies. See
[`app/README.md`](../../app/README.md#prepared-chat-frontend) for standalone use.

The same launcher invokes `app/tool/compile_tool_inspection_frontends.dart` once
for each owning tool frontend, using `ADELE_TOOL_INSPECTION_FRONTEND` and
`ADELE_TOOL_INSPECTION_FRONTEND_OUTPUT` alongside the repository root. It also
invokes `app/tool/compile_openai_activity_frontend.dart` with build-time inputs
`ADELE_REPOSITORY_ROOT` and `ADELE_OPENAI_ACTIVITY_FRONTEND_OUTPUT`. Each stage
must produce nonempty EVC before application launch; failure never silently reuses
an older artifact. These Flutter compiler entrypoints remain outside this package
and the normal application startup import graph.

The OpenAI source split is Contract/Backend/Frontend under
`plugins/openai/packages/{contract,backend,frontend}`. Contract is pure-Dart
identities/schema only; raw classification and bounded safe presentation belong
to Backend, not the frontend compiler or app activation. The app stock activator
imports Contract identity to load/register/retire prepared presentation and remains
provisional until frontend discovery/profiles replace hard-coded selection. These
compile harnesses stand in for future installation/update-time preparation, not
an installer.

Each invocation gets fresh `.dart_tool/adele/desktop-backends/build-*` and
`.dart_tool/adele/desktop-frontends/build-*` directories.
Outputs are retained, including partial failed builds, so later invocations do not
replace artifacts still used by an app or previously built bundle. This is local
development provisioning, not portable distribution: bundles retain absolute paths,
and removing those artifacts or changing the SDK can invalidate them. There is no
cache, installer/update manager, automatic cleanup, or production packaging here;
the prepared installation manifests serve only bounded startup discovery.
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
Current checkout tooling assembles fresh prepared installations for runtime
discovery as a stand-in for that preparation, not an installer, update manager,
profile system, or cache. Discovery and activation remain separate; normal F1
startup attempts all valid installed backends without enable/disable controls,
version solving, watching, frontend discovery, reverse RPC, or hot upgrade.

## Current Scope

Frontend EVC compilation belongs to Flutter build-time tooling under `app/tool`,
not the normal app runtime or generic prepared frontend host. This package stays
pure Dart and must not depend on eval or Flutter. Production
caching, installation, signing, and invalidation remain deferred. Generation is
owned by `contract_codegen`; this package rejects stale generated files before
compilation and never activates an incomplete build. Its tests create isolated
temporary plugin layouts so verification cannot accidentally depend on the
repository's generator configuration or maintained fixture.
