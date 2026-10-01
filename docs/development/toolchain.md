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

## Native editor compatibility gate

**CodeForge is not an application dependency. E1 remains incomplete.** The
retained `tools/code_editor_probe.dart` experiment distinguishes buildability
under the integrated pin from safe editable-document behavior. It adds no public
editor contract, prepared-EVC editor bridge, production editor, or fallback widget.
The normal workspace manifests and `pubspec.lock` are unchanged.

The investigated published source is **`code_forge 10.14.0`**, archive SHA-256
`bddb3fe2001e4dd1653b32fc2752b9d4f60c7cb78f2a02165ea45ee60a867b61`.
Its manifest declares Dart `^3.13.2`. Its generated Dart/Rust bridge is
`flutter_rust_bridge 2.13.0`, content hash **434014572**, and its Rust crate is
`code_forge 0.1.0`. The supplied Cargo lock resolves `ropey 1.6.1`,
`zed-sum-tree 0.2.0`, and `unicode-bidi 0.3.18`. The sum-tree crate uses edition
2024; the root crate's edition 2021 is not a graph-wide compiler requirement.

Published manifests/source were rechecked on 2026-10-01; 10.14.0 remained latest,
and upstream main remained `0d75fa298b368bc6f47b0daa82aa6bee2b900815`.
A bounded comparison found no preferable earlier Rust-backed baseline:

| Release | Verified archive SHA-256 | Relevant tradeoff (source inspection, not runtime validation) |
| --- | --- | --- |
| 10.13.0 | `8b30559d2b7a15fda71bd01fb358bcd553a91c93bcfba1159a0da30b775ec1ab` | Same controller/rope/undo/Rust sources; loses later scrolling/highlighting and Shift-click fixes. |
| 10.12.0 | `930c8c1ddd873dc39beb575ca01e15ad12e32f4f63545bec9f8dff2c9d4bbee6` | Same relevant editing logic; also loses drag-selection changes and uses FRB 2.12.0. |
| 10.0.0 | `4eddf43e57f0eed2d379383c29b64403993b692647ef238854508fcf9f2c29cf` | First Rust release; avoids the specific stale ASCII-delete payload but retains other defects and uses UTF-8 byte length for inserted cursor movement. Loses later Unicode/IME/undo fixes. |

All three still need the twelve constructor-parameter rewrites and an SDK
constraint adaptation. No pre-Rust release or replacement editor was selected.

The reviewable `tools/code_editor_probe/fixtures/compatibility.patch`:

- Lowers the experiment's Dart constraint to `^3.10.9` and pins Dart FRB to
  **2.13.0**, matching the upstream generated and Rust sides.
- Expands twelve private named initializing parameters in `_CodeFieldRenderer`
  into ordinary typed parameters and initializer assignments, preserving behavior.
- Pins the included Cargokit builder to **Rust/Cargo 1.93.0**, target
  `x86_64-unknown-linux-gnu`, recognizes that installed version, and adds
  `cargo --locked`.
- Makes the Linux Cargokit runner use the retained effective runner lock with
  `pub get --enforce-lockfile`. Upstream's helper-package lock does not lock its
  generated runner; upstream otherwise selects floating `stable`.

The driver sets `RUST_MIN_STACK=16777216` during compilation. A local rustc
SIGSEGV in `proc-macro2 1.0.106` was followed by a successful build with this
compiler-recommended stack setting; the crash's root cause was not established.
No compiler or crate version was changed. Verbose Flutter/native build diagnostics
are retained in the probe's stage log.

No rope/editing logic, generated bindings/codecs, rendering architecture, feature
set, or app/evaluator dependency is changed. The isolated application's pub lock
and Cargokit runner lock are fixture inputs, not workspace lockfile changes.
Only the runner's source-directory placeholder is materialized locally. Downloaded
source, the generated Flutter shell, Cargo output, EVCs, and native libraries are
not committed. Upstream-distributed FRB generated source is consumed from the
checksum-pinned archive unchanged; it is not ADELE contract-generated output.

### Rejected behavior

Real Rust-backed tests under the pin demonstrate these defects after the
compile-only adaptation. These are not inferred from the SDK constraint:

| Operation | Required result | Observed result |
| --- | --- | --- |
| Native keyboard Delete twice in `abc`, then undo twice before the line flush | `abc` | `aac` |
| Insert U+1F600 before `ab`, then undo | `ab` | `b` |
| Backspace at scalar offset 4 in `\u{1f600}\nab`, then immediate snapshot | `\u{1f600}\na` | `\u{1f600}ab` |
| Backspace at start of second line in `a\r\nb` | `ab` | `a\rb` |
| Complete pending clipboard paste after setting read-only | unchanged `ab` | `lateab` |

CodeForge's rope positions are Unicode scalar indices, while Dart strings and
Flutter platform text offsets are UTF-16 code units; UTF-8 bytes and visual
columns are different again. The component has some conversion helpers but mixes
these units inside pending-line reconstruction, undo spans, copy/search, and IME
composition. CRLF projection additionally strips CR without preserving a position
map. An ADELE-facing range converter cannot repair those internal paths. No ADELE
offset contract or lossless-editing support is advertised by this experiment.

The ASCII defect reads deleted characters from the unflushed old rope instead of
the pending line buffer. The immediate Unicode snapshot can stay incorrectly
cached even after the rope flushes. `text=` also leaves pending line/history state
in place. These affect the authoritative text, not cosmetic syntax presentation.
Fixing only the reproduced examples would leave other editing/composition paths
with the same coordinate inconsistency; undertaking that broader engine repair
requires a separate scope decision rather than silently growing a compatibility
shim or weakening admission to ASCII/LF-only content.

### Lifetime and packaging limits

A supplied controller and undo controller can outlive a widget, but one controller
contains selection, composition, focus/input connection, folds, callbacks, and
renderer-consumed dirty flags. Two widgets sharing it do **not** establish two
independent views. An eventual adapter must explicitly reject a competing
attachment until the component has a real shared-document/per-view boundary.
Widget startup can attach input even without focus; stale callbacks and native
disposal need further work. Controller disposal does not reject later mutation
or explicitly release all native handles/notifiers. A read-only boolean alone
does not fence asynchronous clipboard completion or undo/programmatic mutation.
An eventual ADELE grant must be presentation-scoped and permanently revocable;
that grant has deliberately not been implemented over the rejected component.

The probe supplies text only and leaves `filePath`, `openedFile`, LSP, AI, and
network integrations unconfigured. It does not exercise or grant file save/open,
process, URL-launch, or workspace-edit authority. Default optional component
shortcuts are not being certified as a safe production interaction surface.

The Linux profile build uses upstream Flutter CMake/Cargokit bundling of
`libcode_forge.so`, not a checked-in or manually copied development library.
The process runs from a separate empty working directory without loader override
variables or Cargo on its configured PATH. It initializes FRB, verifies the actual
mapping in `/proc/self/maps` points to the bundle's `lib/libcode_forge.so`, renders
the widget, dispatches native platform input, checks ASCII undo/redo and complete
view unmount, then disposes the owner. A second subprocess with the bundled library
removed must fail explicitly. This is a **native component experiment**, not the
required compiled-interpreted frontend proof or a distributable ADELE editor.

Upstream Windows CMake DLL bundling and macOS CocoaPods static-library/framework
paths remain untouched and were inspected only, not executed. The macOS podspec
still reports 10.12.0. Runtime must load prebuilt artifacts; compilation/downloads
occur only during probe preparation.

The archive's MIT notice (Athul A S, 2025) is truncated upstream, and the eight
bundled icon fonts have no separate provenance statement. Patch-source notices
are retained in `fixtures/upstream-notices.txt`. Native distribution still needs
a target-specific transitive Rust/standard-library notice inventory, including
Apache-2.0 `zed-sum-tree`; Flutter's Dart `NOTICES.Z` alone is insufficient. CI
uploads diagnostic logs only, **not** the redistribution-unready bundle.

The fixture's roundtrips include a 32 Ki-code-unit line and a 2,048-line document.
These are reproducible samples, not production admission/performance guarantees.
The mutable rope and undo payloads use content-proportional memory; upstream's
1,000-operation default history is not a byte bound. No constant-memory,
allocation-accounting, retained-resource, or per-keystroke EVC-copy claim is made.
The safe alternatives are an upstream fidelity/lifecycle fix followed by the same
gate, or an explicitly reviewed expanded patch scope. A different editor or
integrated SDK/evaluator upgrade is not selected by this experiment.

See [reproduction commands and result modes](testing.md#native-editor-candidate-probe).

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
