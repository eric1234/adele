# Toolchain Policy

## Temporary integrated pin

| Component | Identity |
| --- | --- |
| Flutter | `3.38.10`, framework revision `c6f67dede3d4aa1aa7a69dd56a3494a5cde6cc80` |
| Engine | `cafcda5721a78a7884db92f13c5e89f7643d52dd` |
| Dart | `3.10.9`, bundled with the pinned Flutter SDK |

The framework revision is part of the Flutter identity; the semantic version
alone is not sufficient for reproducible plugin builds. Dart must be the
version supplied by that Flutter pin where Flutter tooling is involved. ADELE's
own product version is independent of Dart's semantic version.

The repository tracks `flutter 3.38.10-stable` in `.tool-versions`. This pin is
temporary. Flutter 3.44.8 with `flutter_eval 0.8.2` is not compatible, and no
Flutter 3.44 or Dart 3.12 support is claimed. Eval modernization or replacement
is required before broad third-party interpreted UI support.
The narrow stock Chat Session, Filesystem/Command Tools Inspection, and OpenAI
reasoning-summary Inspection frontends use this pin; they neither modernize eval
nor establish a broad third-party
Flutter compatibility surface.

## Local plugin compilation

Source is the canonical plugin distribution format. The integrated development
pipeline compiles backend source to native Dart AOT and frontend source to
`dart_eval`/`flutter_eval` bytecode. End-user SDK provisioning and consistent
Windows and macOS behavior remain future packaging and validation work.

Normal desktop runtime activation never compiles plugin source. The Linux checkout
launcher compiles the shared host and three backend AOT artifacts (Git, OpenAI,
and AGENTS.md) plus four stock frontend EVCs (Chat, Filesystem Tools, Command Tools,
and OpenAI activity) before launching or building Flutter, using the selected SDK.
The six prepared installations share one fresh installation root; the host
snapshot is beside that root. AGENTS.md adds backend-only `agents-md/backend.aot`
without configuration or additional deployment defines. F3a uses version 2 for
both host/plugin protocols, requiring coherent host/backend rebuilds; the installed
manifest remains version 1. `tools/frontend_artifacts.dart` invokes
`app/tool/compile_chat_frontend.dart`,
`app/tool/compile_tool_inspection_frontends.dart`, and
`app/tool/compile_openai_activity_frontend.dart` through the Flutter test runner.
Frontend compilation runs in Flutter build-time tooling, not generic runtime hosting or the
pure-Dart `plugin_builder` dependency graph. Normal activation loads the prepared
artifacts; missing or invalid artifacts fail the affected support rather than
triggering compilation or a substitute implementation.

`tools/backend_artifacts.dart` still owns stock source entrypoints and writes
`adele_plugin.installation.json` beside each installation's independently optional
`backend.aot` and `frontend.evc`. Runtime
receives `ADELE_PLUGIN_INSTALLATION_ROOT`, the shared runtime/host paths, and the
temporary generic `ADELE_PLUGIN_STARTUP_ARGUMENTS_FILE`, not per-stock backend
or frontend artifact defines or source paths. Installed manifests are distinct from the draft
`adele_plugin.yaml` source/build manifest; stock source layouts are not normalized
to it. See [`plugin-layout.md`](plugin-layout.md#prepared-installation-snapshot).

The OpenAI activity compiler takes build-time environment inputs
`ADELE_REPOSITORY_ROOT` and `ADELE_OPENAI_ACTIVITY_FRONTEND_OUTPUT`. Its output is
installed as `frontend.evc` alongside the backend in one `dev.adele.openai`
installation. Generic `ApplicationFrontendBootstrap` consumes prepared presentation
descriptors from the same catalog snapshot, using `PreparedFrontend` independently
of model backend support and other frontends. It imports no OpenAI identities,
loads no source, and substitutes no native card on failure. Descriptors are
preparation/runtime metadata, not profile participation, model options,
credentials, or a general configuration UI.

OpenAI follows `plugins/openai/packages/{contract,backend,frontend}`:
`openai_contract` is pure-Dart identities/schema with no algorithms; classification,
projection, bounds, and native-preservation tests belong to
`openai_model_provider_backend`. Contract identity tests and Backend tests have
workspace membership and maintained analysis/test discovery in `tools/adele.dart`.
`openai_frontend` is a Flutter analysis target whose EVC compilation and product
integration belong to app build-time/test tooling. The regression scope uses real
prepared artifacts with local fake Responses for mixed
reasoning/tool approvals and a separate reasoning-only final response. That scope
does not establish live-provider summary support or broader SDK/platform
compatibility. Generated safe-presentation transport, generic adapter mapping, and
safe Chat activity without frontend activation are separate regression boundaries.

Future installation/update should own source compilation and artifact preparation,
separate from activation consuming those artifacts. Current repository tooling is
a source-checkout stand-in that enables a bounded installed-component startup
snapshot, not an installer, profile manager, artifact cache, or portable production
package. Operational preparation inputs and invocations live in
[`app/README.md`](../../app/README.md#prepared-chat-frontend) and the
[`plugin_builder` README](../../packages/plugin_builder/README.md#desktop-tooling).

## Artifact identity and invalidation

A compiled artifact is valid only for its source and build context. Future
cache keys and provenance must include enough toolchain identity to prevent an
artifact built by an incompatible Flutter or Dart SDK from being reused.
Changing Flutter, its framework revision, Dart, eval/compiler dependencies,
target platform, architecture, build mode, or relevant build inputs may require
recompilation.

Artifacts should normally be reusable by multiple profiles and configured
capability instances when source and build context are identical. Profiles do
not inherently own compiled artifacts.

The concrete cache format, compatibility checks, provenance record, and
invalidation algorithm remain deferred beyond the implemented development
compilation pipeline.

## No SDK vendoring

The repository records the exact toolchain but does not vendor Flutter or Dart.
Vendoring would add large binaries, platform-specific content, update and
licensing maintenance, and release-distribution concerns before the local
plugin pipeline has proven its requirements. Developers and CI provision the
pinned SDK externally for the current development foundation.

Bundling or provisioning a pinned SDK for end-user ADELE distributions is a
future packaging decision. The repository excludes compiled plugin artifacts,
SDK caches, and build output from source control.
