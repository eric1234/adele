# Toolchain Policy

Role: Current repository development policy

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
The narrow stock Chat Session, Local Directory Project Selector,
Filesystem/Command Tools Inspection, and OpenAI reasoning-summary Inspection
frontends use this pin; they neither modernize eval
nor establish a broad third-party
Flutter compatibility surface.

## Generated contract artifacts

Authoritative annotated declarations produce native sibling parts, which then feed
the analyzer and compiler:

```text
contract.dart -> contract_codegen -> contract.g.dart -> native tests / AOT / app
```

The `.g.dart` parts are Git-ignored local artifacts. Their physical sibling
location and the declaration's `part` directive remain unchanged. Run
`dart tools/adele.dart bootstrap` after checkout: workspace dependency resolution
and listing precede generation of the sources in `contract_codegen.yaml`, leaving
ordinary IDE analysis and direct Dart/Flutter compilation ready to use.

`tools/adele.dart` regenerates before analysis and before starting test workers.
Linux desktop preparation regenerates once with the selected Flutter SDK's Dart
before any backend AOT or frontend harness compilation. Other desktop build/run
commands and development smoke generate before launching Flutter. The SDK-only
`app/bin/adele_self_host.dart` launcher generates before starting its native CLI
consumer, which in turn compiles the self-hosting AOT artifacts. Low-level snapshot
compilers remain generation-agnostic; direct Dart/Flutter or standalone frontend
harness invocations require bootstrap/current generation first.

Chat EVC compilation still derives its eval client directly from annotations with
`generateEvalClient()`, not from the native part. Its native compiler harness has
native imports, so repository preparation happens before starting that harness.
`DevelopmentPluginBuilder.prepareBackend()` separately generates only its explicit
selected-plugin contract source before backend compilation, not the repository set.

Generation recomputes prospective output and writes only changed content. It can
replace stale siblings left by branch switches without manual deletion; no timestamp
dependency engine or alternate build system is involved. `generate --check` writes
nothing and fails for missing/stale local outputs. Each independent CI consumer job
bootstraps; the generated job runs bootstrap then check as an independent
idempotence/freshness verification. Root `check` checks freshness before any
automatic regeneration so it does not hide stale local output.

`dart tools/adele.dart clean-contracts` is a narrow escape hatch: it removes the
configured native contract outputs and recognizes orphan native parts by an
ADELE-generator-specific marker and matching sibling `part of` declaration under
`packages/` and `plugins/`. It does not follow symlinks or remove arbitrary
`.g.dart`, authored files, build directories, or Dart/Flutter caches. Bootstrap or
generate recreates current outputs. Cleaning is not required for normal branch
switches; legacy unmarked outputs outside the configured set are left alone.

## Local plugin compilation

Source is the canonical plugin distribution format. The integrated development
pipeline compiles backend source to native Dart AOT and frontend source to
`dart_eval`/`flutter_eval` bytecode. End-user SDK provisioning and consistent
Windows and macOS behavior remain future packaging and validation work.

Normal desktop runtime activation never compiles plugin source. The Linux checkout
launcher compiles the shared host and seven backend AOT artifacts (Git, OpenAI, Chat,
AGENTS.md, Search, Filesystem Tools, and Command Tools) plus five stock frontend
EVCs (Chat, Local Directory Project Selector, Filesystem Tools, Command Tools, and
OpenAI activity) before launching or building Flutter, using the selected SDK.
The eight prepared installations share one fresh installation root; the host
snapshot is beside that root. Local Directory Project Selector is
frontend-only; Git, AGENTS.md, and Search are
backend-only; Chat, Filesystem Tools, Command Tools, and OpenAI each combine backend and
frontend. Filesystem's `filesystem-tools/backend.aot` and Command's
`command-tools/backend.aot` use source under their plugins' `packages/backend`;
their frontend EVCs remain independently activatable. Chat, AGENTS.md, Search,
Filesystem Tools, and Command Tools require no
startup configuration or additional deployment defines. Both host and plugin protocols are
currently version 1, supporting unary authorized reads/mutations and reverse
server-streaming processes: prepared hosts and backends must be rebuilt together,
and protocol versions must match exactly. Before the first release, unstable wire
changes may retain that version; prior development artifacts are unsupported even
when their version numbers match. The installed manifest remains version 1; see
the [pre-release transport policy](../architecture/contracts-and-capabilities.md#transport-version-policy).
`tools/frontend_artifacts.dart` invokes
`app/tool/compile_chat_frontend.dart`, `app/tool/compile_local_directory_frontend.dart`,
`app/tool/compile_tool_inspection_frontends.dart`, and
`app/tool/compile_openai_activity_frontend.dart` through the Flutter test runner.
Frontend compilation runs in Flutter build-time tooling, not generic runtime hosting or the
pure-Dart `plugin_builder` dependency graph. Normal activation loads the prepared
artifacts; missing or invalid artifacts fail the affected support rather than
triggering compilation or a substitute implementation.

The selector fixture uses the exact helper
`app/tool/local_directory_frontend_compiler.dart` with build-time inputs
`ADELE_REPOSITORY_ROOT` and `ADELE_LOCAL_DIRECTORY_FRONTEND_OUTPUT`. It compiles
`plugins/local_directory_project_selector/packages/frontend` using compile-only
`DirectoryPickerDeclarations`, with no native picker call. The output is
`local-directory-project-selector/frontend.evc`; there is no selector backend
snapshot or additional deployment define. The old root selector package is retired;
`local_directory_project_selector_frontend` replaces it in workspace membership
and maintained analysis/test discovery.

Behavioral `frontend.extensions` metadata is separate from the
`presentations` list under manifest version 1. Activation validates behavioral
bytecode and entrypoint presence without executing plugin code; actual selection
uses a fresh operation runtime and native bridge. Presentation-only corruption
remains per-view. Runtime still compiles no source.

Chat follows `plugins/chat_strategy/packages/{contract,backend,frontend}` rather
than a root semantic package linked into the app. Its generated frontend client
uses the generic own-backend bridge; Session execution uses the separate generic
bridge. Build-time declarations and generated codecs are compiled into the EVC,
not handwritten Chat RPC in the host. The Session descriptor supplies `displayName`,
a `backendServices` allowlist containing generated `chatSessionServiceId`, and
`strategyAffinity: 'owningBackend'` instead
of `hostAdapter`, still under manifest version 1. Rebuild prepared artifacts and
descriptors together. No deployment define is added.

Plugin-specific self-hosting composition lives in `app/tool/self_hosting/`, outside
the normal `app/lib` import graph. It uses Chat Contract as a development dependency
and the same remote Chat backend, not an in-process strategy fallback.

`tools/backend_artifacts.dart` still owns stock source entrypoints and writes
`adele_plugin.installation.json` beside each installation's independently optional
`backend.aot` and `frontend.evc`. Runtime
receives `ADELE_PLUGIN_INSTALLATION_ROOT`, the shared runtime/host paths, and the
temporary generic `ADELE_PLUGIN_STARTUP_ARGUMENTS_FILE`, not per-stock backend
or frontend artifact defines or source paths. Installed manifests are distinct from the draft
`adele_plugin.yaml` source/build manifest; stock source layouts are not normalized
to it. See [`../architecture/plugin-layout.md`](../architecture/plugin-layout.md#prepared-installation-snapshot).

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
reasoning/tool approvals. That scope
does not establish live-provider summary support or broader SDK/platform
compatibility. Generated safe-presentation transport, generic adapter mapping, and
safe Chat activity without rich activity frontend activation are separate regression boundaries.

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
