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
The narrow stock Terminal, Task Browser, Chat Session, Local Directory Project,
Filesystem/Command Tools Inspection, and OpenAI reasoning-summary Inspection
frontends use this pin; they neither modernize eval
nor establish a broad third-party
Flutter compatibility surface.

## Isolated native editor probe

CodeForge is not an application dependency. `tools/code_editor_probe.dart` is an
optional Linux x64 investigation, separate from workspace resolution and normal
application preparation. It does not change the integrated SDK/evaluator pin or
initialize a native editor on SDK-only execution paths.

The ADELE-pin configuration requires the integrated SDK above and Rust/Cargo
**1.93.0**, target `x86_64-unknown-linux-gnu`. The driver verifies the exact
`code_forge 10.14.0` archive, uses the isolated fixture locks, and preserves its
FRB **2.13.0** generated bindings. The SDK/build compatibility patch is separate
from experimental correctness changes. Neither patch is a production dependency.
Native builds use upstream Flutter CMake/Cargokit with locked inputs and
`RUST_MIN_STACK=16777216`; diagnostic build output stays in the probe directory.

Use an explicit separate SDK path for any upstream control; do not change
`.tool-versions`, `toolchain.json`, global Flutter selection, workspace manifests,
or the root lockfile to run it. Downloaded upstream-generated source and native
build output remain local artifacts, distinct from ADELE contract generation.

See [reproduction procedures](testing.md#native-editor-candidate-probe) and the
[versioned correctness investigation](../experiments/codeforge-correctness.md)
for source provenance, observed results, qualifications, and open questions.

## Native terminal dependency

The app pins the published `xterm2 5.2.0` archive, with checksum
`0b62e7510b414329dfb6ce7dbcffcfe97cc5109033573cf0f4abca568dac8149`
recorded in `pubspec.lock`; there is no upstream branch dependency. Its declared
SDK constraints are Dart `>=3.0.0 <4.0.0` and Flutter `>=3.19.0`. Direct dependencies
are Flutter, `characters ^1.4.0`, `convert ^3.0.0`, `meta ^1.3.0`, `quiver ^3.0.0`,
`equatable ^2.0.3`, and `zmodem ^0.0.6`. Resolution under the integrated pin adds
`equatable 2.1.0`, `quiver 3.2.2`, and `zmodem 0.0.6`; existing SDK/eval versions
are unchanged. Declaring the transfer library does not enable transfer handling
in ADELE's adapter.

The package's MIT license retains `Copyright (c) 2020 xuty`. Flutter's normal
dependency-license collection includes it in `NOTICES.Z`; the prepared bridge
test checks that bundled notice rather than adding a separate licensing system.

Native widget and actual prepared-EVC compilation/mount checks use the complete
Flutter/framework/engine/Dart identity in the pin table above, with `dart_eval 0.8.5`
and `flutter_eval 0.8.2`. The interpreted fixture and stock Terminal import only
public UI and Flutter; `xterm2` stays native. These are debug widget/evaluator
checks, not desktop/profile, other-platform, broad third-party Flutter, or PTY
compatibility claims. See the [focused checks](testing.md#focused-terminal-checks)
and [local implementation map](../../app/README.md#native-terminal-surface).

## Git PTY preparation

The Linux x64 Git backend uses the original repository-owned
`plugins/git_environment/packages/backend/native/git_pty_helper.c`, helper protocol
version **1**, with the pure-Dart `GitPtySession` adapter. Its exact source revision
is the checkout revision, not a pub-cache patch or downloaded binary. No PTY package
or native framework is added to the Dart dependency graph. This repository currently
has no top-level license declaration; the helper introduces no copied third-party
source or additional license grant. It dynamically uses the system libc/libutil
(glibc is LGPL-2.1-or-later), not vendored native dependencies.

Candidate manifests and published archive source were inspected before selection:
`pty2 0.5.4` (MIT) requires Dart >=3.11 and calls parent-side `setsid` in its Unix
implementation; `portable_pty 0.0.5` (MIT, SDK `^3.10.4`) installs a process-global
SIGCHLD handler. Neither is used, forked, or made compatible by lowering its SDK
constraint. The helper keeps fork/session/signal setup in a separate single-threaded
process, never in the shared Dart backend host. No external native-library asset
resolution is required from an independently loaded AOT isolate group.

Public Environment terminal semantics remain provider/platform-neutral. The
separate helper process is the isolation boundary; its custom Linux supervision
is replaceable implementation, not a requirement to hand-write each future
platform backend. Before adding another native platform, compare retaining custom
code with an upstream cross-platform PTY library inside that isolated helper.
Rejecting a package unchanged inside the shared Dart host does not establish that
it is unsuitable behind the helper boundary. No such additional runtime experiment
is claimed here, and other platforms remain unvalidated.

Preparation requires Linux x64, `cc` with C11 support, libc development headers and
`libutil`; execution requires Linux 5.3+ pidfd syscalls, readable `/proc`, and working
`devpts`. The evidence uses Linux 6.8.0-138-generic, GCC 13.3.0, and glibc 2.39 on
x64 with the exact integrated Dart/Flutter pin above. The focused
job-control test additionally needs Bash. `tools/git_pty_artifact.dart` reproducibly
invokes `cc -std=c11 -O2 -Wall -Wextra -Werror ... -lutil`.
`tools/backend_artifacts.dart` prepares `git-environment/pty-helper` before publishing
the installation and supplies its absolute path as `--pty-helper=...` through the
existing generic startup-argv file. Activation never compiles or downloads it.
Direct test/development callers prepare the helper explicitly; omitting it leaves
terminals unavailable without disabling other Git Environment operations.

Stock Terminal requests the provider's `defaultShell` launch kind, not an
app-selected executable. The provider-owned
[`SHELL` path/name resolution, absent-only `/bin/sh`, interactive `-i`, and Environment-root startup rules](../../plugins/git_environment/README.md#interactive-terminals)
remain separate from artifact preparation. Normal startup does not suppress a
user's shell startup files. Integration fixtures instead control the child host's
environment and use a temporary `HOME`; see the
[validation map](testing.md#focused-console-checks). No toolchain identity,
eval/emulator dependency, or native dependency upgrade is required by this frontend.

The retained `pty_host_test.dart` compiles separate host/backend AOT snapshots and
loads the backend through `PluginBackendHost.startPlugin`, proving controlling-TTY
behavior, native controls, bounded failures, ordinary foreground-job cleanup, and
sibling responsiveness. This is real Linux shared-AOT-host evidence, not a standalone
JIT package example. Prepared frontend/native integration is a separate
[focused check](testing.md#focused-terminal-checks). Other platforms, portable
release packaging, universal descendant containment, and a native-plugin framework
are not established by this helper. The [Git README](../../plugins/git_environment/README.md)
owns operational buffering and cleanup guarantees.

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
launcher compiles the shared host, stock backend AOT artifacts, and stock frontend
EVCs before launching or building Flutter, using the selected SDK. The source
inventory and installation assembly live in
[`tools/backend_artifacts.dart`](../../tools/backend_artifacts.dart), with frontend
compiler selection in [`tools/frontend_artifacts.dart`](../../tools/frontend_artifacts.dart)
and build-side descriptor metadata in
[`tools/stock_frontend_descriptors.dart`](../../tools/stock_frontend_descriptors.dart).
Prepared installations share one fresh root; the host snapshot is beside it.
Backend-only, frontend-only, and combined installations use the same catalog.
The stock Task Browser and Terminal are frontend-only and need no owning backend
startup configuration or additional runtime deployment define. Terminal execution
still requires its selected Environment provider's prepared support. Both host and
plugin protocols are currently version 1, supporting unary authorized reads/mutations and reverse
server-streaming processes: prepared hosts and backends must be rebuilt together,
and protocol versions must match exactly. Before the first release, unstable wire
changes may retain that version; prior development artifacts are unsupported even
when their version numbers match. The installed manifest remains version 1; see
the [pre-release transport policy](../architecture/contracts-and-capabilities.md#transport-version-policy).
`tools/frontend_artifacts.dart` invokes the
[application compiler harnesses](../../app/README.md#prepared-frontend-artifacts)
through the Flutter test runner.
Frontend compilation runs in Flutter build-time tooling, not generic runtime hosting or the
pure-Dart `plugin_builder` dependency graph. Normal activation loads the prepared
artifacts; missing or invalid artifacts fail the affected support rather than
triggering compilation or a substitute implementation.

Terminal preparation uses `app/tool/compile_terminal_frontend.dart` and
`terminal_frontend_compiler.dart`, with `ADELE_REPOSITORY_ROOT` and
`ADELE_TERMINAL_FRONTEND_OUTPUT` as build-time inputs. It compiles stock content
and action entrypoints plus public stubs with `EnvironmentTerminalDeclarations`
and `TerminalSurfaceDeclarations`, without granting process/surface access during
compilation. The EVC is installed at `terminal/frontend.evc` under the same catalog
as other stock components. The version-1 `console` descriptor carries content and
creation-action entrypoints, with no strategy/backend-affinity fields. The
`terminal_frontend` workspace package has maintained analysis/test discovery;
its [local map](../../plugins/terminal/packages/frontend/README.md) owns the ABI.

Task Browser preparation uses `app/tool/compile_task_browser_frontend.dart` and
`task_browser_frontend_compiler.dart`, with `ADELE_REPOSITORY_ROOT` and
`ADELE_TASK_BROWSER_FRONTEND_OUTPUT` as build-time inputs. It compiles the stock
frontend and public bridge stub with compile-only `TaskBrowserDeclarations`, not
native lifecycle access. A separate `LayoutBuilderBridge` supplies matching
compile/runtime support for responsive interpreted layout under the pin. The EVC
is installed at `task-browser/frontend.evc`; its
`role: 'taskBrowser'` descriptor has no strategy/backend-affinity fields. The
`task_browser_frontend` package participates in workspace membership and maintained
analysis/test discovery. Its [local frontend map](../../plugins/task_browser/packages/frontend/README.md)
owns the pinned-evaluator UI constraints, including the inline Card rather than a
dialog; this is not broader Flutter compatibility.

The Local Directory Project frontend uses the exact helper
`app/tool/local_directory_project_frontend_compiler.dart` with build-time inputs
`ADELE_REPOSITORY_ROOT` and `ADELE_LOCAL_DIRECTORY_PROJECT_FRONTEND_OUTPUT`. It compiles
`plugins/local_directory_project/packages/frontend` using compile-only
`DirectoryPickerDeclarations`, with no native picker call. The output is
`local-directory-project/frontend.evc`, alongside the provider's independently
prepared `local-directory-project/backend.aot`; no additional deployment define is
required. Both `local_directory_project_frontend` and
`local_directory_project_backend` participate in workspace membership and maintained
analysis/test discovery.

Behavioral `frontend.extensions` metadata is separate from the
`presentations` list under manifest version 1. Activation validates behavioral
bytecode and entrypoint presence without executing plugin code; actual selection
uses a fresh operation runtime and native bridge. Console descriptors similarly
validate their content/action entrypoint presence before registration; other
presentation-only corruption remains per-view. Runtime still compiles no source.

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
