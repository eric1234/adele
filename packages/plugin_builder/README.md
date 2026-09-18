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
shared host AOT snapshot, five backend AOT snapshots (Git Environment, OpenAI,
AGENTS.md, Search, and Filesystem Tools), and four frontend EVCs (Chat, Filesystem
Tools, Command Tools, and OpenAI activity) before launching the Flutter run/build command. Backend compilation
runs outside Flutter; frontend compilation uses Flutter build-time tooling. This also
applies to explicit Linux debug/release modes; non-Linux commands and the explicit
development smoke entry remain unchanged. `prepareDesktopPluginDefines` in
`tools/backend_artifacts.dart` owns backend source paths and unified stock
installation assembly, not the normal app runtime or the snapshot primitive.
Stock source directories are not required to have the
reference fixture's draft `adele_plugin.yaml` source/build manifest.

The launcher inspects its selected Flutter executable and uses that SDK's bundled
`dart` and sibling `dartaotruntime`, not a potentially unrelated `dart` on PATH.
It compiles the host and Git, OpenAI, AGENTS.md, Search, and Filesystem Tools backends.
`tools/frontend_artifacts.dart` prepares all four stock EVCs in the same installation root with the selected Flutter
SDK. `tools/stock_frontend_descriptors.dart` is the singular stock build-side
presentation descriptor table, shared with installation fixtures rather than
duplicated in app runtime activation. Manifests are written after all component
preparation succeeds. The launcher passes only four generic deployment defines:

- `ADELE_DARTAOTRUNTIME_EXECUTABLE`: absolute matched runtime path.
- `ADELE_BACKEND_HOST_ARTIFACT`: absolute shared host `.aot` path.
- `ADELE_PLUGIN_INSTALLATION_ROOT`: absolute fresh prepared-installations root.
- `ADELE_PLUGIN_STARTUP_ARGUMENTS_FILE`: absolute generic startup-arguments JSON file.

Seven installation directories are immediate children of the one installation root;
Filesystem Tools and OpenAI each share one manifest and PluginId across their
independently activatable backend and frontend components:

```text
desktop-plugins/build-*/
|-- host.aot
|-- startup-arguments.json
`-- installations/
    |-- chat-strategy/
    |   |-- adele_plugin.installation.json
    |   `-- frontend.evc
    |-- filesystem-tools/
    |   |-- adele_plugin.installation.json
    |   |-- backend.aot
    |   `-- frontend.evc
    |-- command-tools/
    |   |-- adele_plugin.installation.json
    |   `-- frontend.evc
    |-- git-environment/
    |   |-- adele_plugin.installation.json
    |   `-- backend.aot
    |-- agents-md/
    |   |-- adele_plugin.installation.json
    |   `-- backend.aot
    |-- search-tools/
    |   |-- adele_plugin.installation.json
    |   `-- backend.aot
    `-- openai/
        |-- adele_plugin.installation.json
        |-- backend.aot
        `-- frontend.evc
```

Each installed JSON manifest contains a schema version, plugin metadata, and
independently optional `backend` and `frontend` components. Each frontend contains
a relative artifact and strict presentation descriptors for Session, tool activity,
or model-native activity roles. Descriptors are executable ABI/preparation data,
not profile state. Manifests contain no source paths, capability/extension exposures,
configuration, or activation state. Their runtime schema and catalog failure rules
are maintained in
[`plugin-layout.md`](../../docs/architecture/plugin-layout.md#prepared-installation-snapshot).
The runtime discovers this snapshot before starting a host and shares it with the
Flutter frontend owner; it does not run the source builder or know stock source
layouts. Catalog validation checks confined existing files, not executable EVC
correctness. Runtime bytecode decoding remains presentation-local.

Filesystem's backend source is under `plugins/filesystem_tools/packages/backend`.
AGENTS.md, Search, and Filesystem Tools need no configuration/startup arguments or
extra deployment defines. Their entrypoints own ready extension advertisements; the app uses generic
remote extension activation rather than linking their semantic plugins in production.
Both host and plugin-backend protocols use version 2, so all host/backend artifacts
must be rebuilt together. The installed manifest uses version 1.

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
to Backend, not the frontend compiler or app activation. Generic app frontend
bootstrap loads/registers/retires its prepared presentation from catalog metadata,
without a stock OpenAI activator or runtime identity switch. These compile
harnesses stand in for future installation/update-time preparation, not
an installer.

Each invocation gets one fresh `.dart_tool/adele/desktop-plugins/build-*` directory.
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
profile system, or cache. Discovery and activation remain separate; normal startup
attempts all discovered valid backend and frontend components without enable/disable
controls, version solving, watching, or hot upgrade. Future profiles choose
activation participation separately from prepared descriptors. The remote AGENTS.md
source and Search tools use narrow unary host reads; Filesystem tools also use a
separate unary mutation service. Remote model-tool preparation has no host token;
only execution after policy/approval receives its descriptor's exact read/mutation
allowlist through existing host-to-backend server streaming. Reverse streaming and
general symmetric RPC are unimplemented. The three in-process stock activations
(Chat, Command Tools, and Local Directory Project Selector) are outside this
discovery path, with their migration deferred.

## Current Scope

Frontend EVC compilation belongs to Flutter build-time tooling under `app/tool`,
not the normal app runtime or generic prepared frontend host. This package stays
pure Dart and must not depend on eval or Flutter. Production
caching, installation, signing, and invalidation remain deferred. Generation is
owned by `contract_codegen`; this package rejects stale generated files before
compilation and never activates an incomplete build. Its tests create isolated
temporary plugin layouts so verification cannot accidentally depend on the
repository's generator configuration or maintained fixture.
