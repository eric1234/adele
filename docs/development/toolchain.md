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

## Native editor preparation

The application uses `code_forge 10.14.0` under the integrated SDK pin.
[`third_party/code_forge/preparation.json`](../../third_party/code_forge/preparation.json)
owns the archive URL/checksum, ordered patches, prepared-tree digest, Rust
**1.93.0**, and FRB **2.13.0** binding identity (content hash **434014572**).
Preparation applies `01-compatibility-build.patch` and the small
`02-correctness.patch`; ordinary CodeForge widget/font behavior is retained.
Change these tracked inputs, not materialized source or the pub cache.
The [retained investigation](../experiments/codeforge-correctness.md) explains this
small, unpublished patch set and its evidence limits.

The root `pubspec.yaml` has a stable path override to the Git-ignored
`.adele/dependencies/code_forge`; `app/pubspec.yaml` declares the exact package and
`re_highlight 0.0.3`. The root lockfile owns workspace resolution; inspect its diff
after resolution rather than upgrading unrelated dependencies.

### Source preparation

`dart tools/adele.dart bootstrap` prepares source **before** `flutter pub get`,
workspace listing, and contract generation. Bootstrap a fresh checkout before
direct IDE/Flutter resolution. The
SDK-only helper in [`tools/code_editor_dependency.dart`](../../tools/code_editor_dependency.dart)
uses `curl`, Git, GNU `tar`, and `sha256sum` on Linux, without invoking pub, Flutter,
Rust, or Cargo. Workspace-wide pub resolution needs this path even for SDK-only
consumers; source preparation does not initialize or compile the editor.

```sh
dart tools/adele.dart prepare-code-editor
dart tools/adele.dart prepare-code-editor --archive /absolute/path/code_forge-10.14.0.tar.gz
```

The optional archive must match the pinned checksum. The helper stages source,
applies the ordered patches and runner lock, verifies package/FRB identities and
the tracked tree digest, then publishes to the same ignored directory. Cached
source is verified too. Its local `.adele-preparation.json` ledger cannot override
the tracked digest. The preparation identity includes tracked inputs and the
absolute source path; stale or modified source fails instead of silently using a
hosted package or editing the pub cache.

Run preparation serially. For changed inputs, a moved checkout, or deliberate
replacement of stale source, stop **all** consumers, including IDE analyzers and
direct Flutter/Cargo processes, before using:

```sh
dart tools/adele.dart prepare-code-editor --reprepare
dart tools/adele.dart prepare-code-editor --reprepare --archive /absolute/path/code_forge-10.14.0.tar.gz
```

Reprepare verifies fresh source before replacing the old tree, restoring the old
tree if publication fails; it does not build Rust. The helper's exclusive source
lease also covers `withCodeEditorSource` callbacks, not unleased IDE/direct
consumers or every repository compiler. Keep those stopped until replacement
finishes, then bootstrap again.
If dependency asset declarations changed, clean the app's Flutter build output
before bootstrap as well; an old test asset bundle can retain the prior font
manifest. This does not remove the prepared source under `.adele/`.

### Native builds

Current native preparation and checks target Linux x64. Install the exact
compiler before app tests or desktop builds:

```sh
rustup toolchain install 1.93.0 --profile minimal --target x86_64-unknown-linux-gnu
dart tools/adele.dart build-code-editor-tests
```

`build-code-editor-tests` verifies source, builds with exact Rust/Cargo,
`--locked --release` and `RUST_MIN_STACK=16777216`, and prints the library directory
under `.adele/dependencies/code_forge-native/<preparation-identity>/x86_64-unknown-linux-gnu/release`.
Maintained test targets declaring `nativeCodeEditor` (`adele_desktop` and
`source_editor_frontend`) share one build before workers and receive
`FRB_DART_LOAD_EXTERNAL_LIBRARY_NATIVE_LIB_DIR`. Other maintained test targets
prepare/verify source without building Rust.

Flutter desktop packaging instead uses the prepared dependency's CMake/Cargokit
hooks, exact compiler and Cargo lock, and pinned build-runner lock on the maintained
Linux path. These libraries are build artifacts, not downloaded binaries or ADELE
contract outputs. Upstream Windows DLL and macOS CocoaPods static-library/framework
paths remain present; preserving them is not an executed build or runtime claim.
See [editor validation](testing.md#focused-editor-checks) for direct-test setup and
the actual app profile smoke.

Set `FLUTTER_ROOT` explicitly to the pinned SDK as well as selecting its binaries.
An inherited root from a version-manager shim can otherwise cause a pinned Dart
command to resolve against another Flutter installation:

```sh
ADELE_FLUTTER=/absolute/path/to/flutter-3.38.10
export FLUTTER_ROOT="$ADELE_FLUTTER"
export PATH="$ADELE_FLUTTER/bin:$PATH"
```

### Licensing

Keep upstream license files and Flutter's normal generated notices. The small
[`upstream-notices.txt`](../../third_party/code_forge/upstream-notices.txt) retains
source attribution; preparation does not materialize a separate notice inventory
or override upstream font assets. Publishing prebuilt binaries needs appropriate
license review for the shipped target and contents; this checkout makes no
redistribution-clearance claim.

## Native rich-editor dependency

The application pins `appflowy_editor 6.2.0`, prepared from its published archive.
[`third_party/appflowy_editor/preparation.json`](../../third_party/appflowy_editor/preparation.json)
owns the archive SHA-256, ordered compatibility patches, and expected
prepared-tree digest.
The root override points only to Git-ignored
`.adele/dependencies/appflowy_editor`; the root lockfile owns workspace resolution.
Neither public UI contracts nor stock plugins depend on AppFlowy implementation
types. The integrated Flutter/Dart/evaluator pins above are unchanged.

The first patch removes `device_info_plus` and an unused Android SDK-version probe from
`keyboard_height_observer.dart`. The version had no consumers beyond its own
initialization guard. Actual `keyboard_height_plugin` reporting, listeners, and
Android duplicate-height suppression remain unchanged. Removing this unnecessary
dependency avoids its Win32 5.x constraint without changing the OpenAI backend's
Win32 6.x dependency or forcing a transitive override.

AppFlowy's `file_picker ^10.2.0` constraint also requires Win32 5.x. A second patch
pins published `file_picker 12.0.0-beta.3` and updates its three calls from
`FilePicker.platform` to the package's static API. This exact prerelease declares
Dart 3.10/Flutter 3.38 minimums and Win32 6.x support while retaining the existing
picker argument/result contracts. Stable 12.x changes save-file semantics and is
not substituted. This is a bounded dependency compatibility choice, not evidence
of native picker dialogs or image-upload behavior on any platform.

A third manifest-only patch constrains `image` to `4.10.2`, within PDF's existing
declared range. With this SDK, `pdf 3.12.0` selects `archive <4.1.0`; `image 4.11.0`
incorrectly permits that archive range while calling its unavailable `decodeLazy`
API. Image 4.10.2 uses the supported `decodeBytes` API. This normal dependency
constraint does not override PDF/archive constraints or alter codec source.

A desktop selection lifecycle patch replaces the globally keyed metrics debounce
with an instance-owned 100 ms timer. A new metrics event replaces that instance's
pending refresh; clearing selection or disposing the selection service cancels it.
The callback checks that the widget is mounted and still has a selection before
refreshing, preventing a delayed null-selection failure after teardown without
coupling independent editors' timers. Mobile selection behavior is unchanged.

The composition-only backtick formatter respects the installed character-shortcut
allowlist through a focused source patch. Omitting inline-code formatting must not
secretly format literal fenced-code input during IME commits. Default AppFlowy
shortcuts retain their existing behavior. No version, public API or preparation
workflow changes are involved.

Bootstrap prepares and verifies both editor sources before pub resolution.
Maintained analysis, tests, and desktop run/build/smoke commands also verify
AppFlowy before consumers. CI uses those same commands, not a separate setup path.
The SDK-only helper uses the existing `curl`, Git, GNU `tar`, and `sha256sum`
prerequisites; it does not build native code or edit the Pub cache.

```sh
dart tools/adele.dart prepare-rich-editor
dart tools/adele.dart prepare-rich-editor --archive /absolute/path/appflowy_editor-6.2.0.tar.gz
```

Cached source is checked against tracked inputs and the trusted tree digest;
changed, missing, or unexpected immutable source fails without fallback. To
deliberately replace stale source, stop **all** consumers (including IDE analyzers
and direct Flutter commands), then run:

```sh
dart tools/adele.dart prepare-rich-editor --reprepare
dart tools/adele.dart bootstrap
```

Repreparation stages and verifies fresh source before replacing the old tree under
an exclusive lease. Direct Flutter/IDE consumers are not covered by that lease.
Do not edit prepared source; change the checked-in patches and reviewed digest.

Use the MPL-2.0 option of AppFlowy's MPL-2.0/AGPL-3.0 dual license. Preserve the
upstream license and embedded attributions; see the
[retained notices](../../third_party/appflowy_editor/upstream-notices.txt).
Distributing binaries requires making the corresponding covered source, including
these patches, available and telling recipients how to obtain it. Normal Flutter
license collection does not establish complete embedded-source/asset notice
coverage or future release clearance.

The [native widget smoke](../../app/test/appflowy_editor_smoke_test.dart) exercises
actual mounting, Flutter text input, Backspace, and unmount/disposal on Linux with
the pinned SDK. It does not establish mobile/macOS/Windows runtime or packaging
support, Markdown fidelity, a reusable editor owner, or evaluated frontend access.

## Native TOML documents

[`adele_toml_document`](../../packages/toml_document/README.md) uses a package-local
`hook/build.dart`, not CodeForge/FRB or an application-private loader. Native build
hooks and `@Native` code assets work with the pinned Dart/Flutter SDK. Its exact
`hooks 2.0.2`, `code_assets 1.2.1`, and `ffi 2.2.0` dependencies already exist in
the workspace lock; no SDK upgrade or separate native-plugin framework is needed.

Provision Rust **1.93.0** (the package's `native/rust-toolchain`), the target, and
the platform linker. On maintained Linux x64:

```sh
rustup toolchain install 1.93.0 --profile minimal --target x86_64-unknown-linux-gnu
dart tools/adele.dart bootstrap
dart tools/adele.dart test --target adele_toml_document
```

Normal Dart tests/run invoke the hook automatically. It calls the pinned compiler
through rustup with `cargo build --locked --release`, registers its source/lock
inputs, and bundles the resulting dynamic library as a Dart code asset. Rust
source, manifests, and `Cargo.lock` are committed; generated libraries are not.
Loading never substitutes a Dart parser. CI's `nativeToml` target metadata selects
the compiler prerequisite independently of `nativeCodeEditor`. The desktop now
consumes the Settings host at frontend startup, so its tests and frontend targets
with a development dependency on the desktop require native TOML as well. This
does not add Rust to standalone semantic Settings or prepared-catalog parsing.

The host-only [`adele_configuration_store`](../../packages/configuration_store/README.md)
uses that same transitive hook and compiler requirement, not another native build.
Its Linux write path uses coreutils `chmod`; its filesystem tests also use GNU
`stat` and require an unprivileged user for permission-denied coverage.

The hook maps native-host Linux/macOS/Windows x64 and arm64, rejecting unsupported
targets, cross-compilation, static-only linking, and sanitizers. Only Linux x64 is
validated; this is not cross-platform release-packaging evidence. Flutter desktop
consumes the same standard hook without a Flutter dependency in the package.
Raw `dart compile` on this pin
rejects build hooks: existing independently loaded backend AOT artifacts are not
automatically supported. The SDK's hook-aware standalone AOT path is `dart build
cli`, still preview on this pin. Maintained backend AOT compilation remains rooted
at the repository's dependency-free launcher package and imports no Settings host
or TOML implementation. Do not move those commands to the app's native-hook graph
or infer native-asset delivery from successful snapshot compilation.

`toml_edit` and the private JSON bridge have exact direct Cargo pins and a committed
transitive lock. See the package's [native notices](../../packages/toml_document/third_party_notices.txt)
for attribution: normal Flutter Dart license collection does not include Cargo
dependencies automatically. Release distribution needs notice inclusion and
review of the actual shipped contents.

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
`plugins/git/packages/backend/native/git_pty_helper.c`, helper protocol
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
`tools/backend_artifacts.dart` prepares or reuses `git/pty-helper` under the
installation root before publishing the installation and supplies its absolute
path as `--pty-helper=...` through the existing generic startup-argv file.
Activation never compiles or downloads it.
Direct test/development callers prepare the helper explicitly; omitting it leaves
terminals unavailable without disabling other Git plugin operations.

Stock Terminal requests the provider's `defaultShell` launch kind, not an
app-selected executable. The provider-owned
[`SHELL` path/name resolution, absent-only `/bin/sh`, interactive `-i`, and Environment-root startup rules](../../plugins/git/README.md#interactive-terminals)
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
are not established by this helper. The [Git README](../../plugins/git/README.md)
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
Linux development `run` and `build` validate every configured contract using the
selected Flutter SDK's prepared AOT generator before dependency discovery or any
backend AOT or frontend harness compilation. A content-matching successful
generation receipt permits reuse without semantic resolution; missing, stale, or
uncertain evidence requires authoritative generation. This validation still runs
when all compiled components can be reused. Generation failures stop preparation;
cached output is not a fallback. Other desktop build/run
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

Explicit generation recomputes prospective output and writes only changed content.
It can replace stale siblings left by branch switches without manual deletion; no
timestamp dependency engine or alternate build system is involved. `generate --check` writes
nothing and fails for missing/stale local outputs. Each independent CI consumer job
bootstraps; the generated job runs bootstrap then check as an independent
idempotence/freshness verification, independent of incremental receipts. Root `check`
checks freshness before any automatic regeneration so it does not hide stale local
output.

Linux incremental receipts live in `.dart_tool/adele/contracts/`, separate from
immutable plugin artifacts. They validate source-specific transitive inputs,
analyzer resolution/configuration probes, selected SDK inputs, tool/runtime identity,
and generated output bytes. Only the target generated sibling is excluded from its
own inputs; other generated libraries retain their normal analyzer behavior.
Unchanged outputs retain their modification times. Receipt publication is atomic
after successful generation/validation, under the preparation lease and a local
generation lock. Source additions/removals follow `contract_codegen.yaml` without
unnecessarily invalidating unrelated receipts. See the owning
[incremental generation policy](../../packages/contract_codegen/README.md#incremental-linux-preparation)
for dependency coverage, conservative fallbacks, races, and diagnostics.

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
launcher prepares or reuses the shared host, stock backend AOT artifacts, and stock
frontend EVCs before launching or building Flutter, using the selected SDK. The source
inventory and installation assembly live in
[`tools/backend_artifacts.dart`](../../tools/backend_artifacts.dart), with frontend
compiler selection in [`tools/frontend_artifacts.dart`](../../tools/frontend_artifacts.dart)
and build-side descriptor metadata in
[`tools/stock_frontend_descriptors.dart`](../../tools/stock_frontend_descriptors.dart).
Prepared installations share one immutable, content-identified snapshot root; the
host snapshot is beside it. Unchanged inputs reuse that root and the deployment
paths rather than allocating a fresh `build-*` directory for every invocation.
Backend-only, frontend-only, and combined installations use the same catalog.
Ordinary Linux `run` and `build` commands also prepare the trusted development-only
Session Evaluator as `session-evaluator/backend.aot`, with semantic identity
`dev.adele.plugin.session-evaluator` and no frontend or extra startup arguments.
No opt-in flag is required. Those commands select
`app/tool/development_main.dart` automatically, including explicit debug/profile/release
modes. This is development composition, not release packaging; existing absolute
artifact paths and platform/build limitations remain. Other platform commands and
the separate runtime smoke retain their existing entrypoints and preparation paths.
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
`backend.aot` and `frontend.evc`. The same stock publication helper copies the
Source Editor's authoritative `settings.schema.json` and OpenAI's authoritative
`records.schema.json` byte-for-byte, referencing them through the independent
installation-level `settingsSchema` and `recordsSchema` fields. Schema metadata is
available without backend/frontend activation or authentication; the OpenAI record
declaration contains no credential fields and does not change runtime startup
configuration. Global user values remain in TOML, not generated installation
artifacts. Runtime receives `ADELE_PLUGIN_INSTALLATION_ROOT`, the shared
runtime/host paths, and the temporary generic
`ADELE_PLUGIN_STARTUP_ARGUMENTS_FILE`, not per-stock backend or frontend artifact
defines or source paths. Installed manifests are distinct from the draft
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
a source-checkout stand-in with a local compilation cache and a bounded
installed-component startup snapshot, not an installer, profile manager, runtime
cache, or portable production package. Operational preparation inputs and
invocations live in
[`app/README.md`](../../app/README.md#prepared-chat-frontend) and the
[`plugin_builder` README](../../packages/plugin_builder/README.md#desktop-tooling).

## Artifact identity and invalidation

The Linux checkout launcher uses
[`tools/desktop_artifact_cache.dart`](../../tools/desktop_artifact_cache.dart) under
`.dart_tool/adele/desktop-plugins/`. The shared host, each stock backend AOT, each
stock frontend EVC, and the Git PTY helper are separate cache components. Linux
`run` and `build`, including debug/profile/release app modes, share these components:
their plugin compiler arguments do not vary with the app mode. A hit avoids that
component's compilation, not SDK inspection, contract freshness validation, input
discovery, output verification, or installation assembly.

### Compiled preparation tools

After SDK inspection, Linux `run` and `build` prepare or reuse AOT snapshots of
the contract generator and dependency-discovery worker through
[`tools/desktop_tool_artifacts.dart`](../../tools/desktop_tool_artifacts.dart).
They execute with the selected SDK's matching `dartaotruntime`, retaining the
repository working directory, arguments, diagnostics, and failure behavior.
The generator CLI still executes once and dependency discovery twice on every
launch. Linux `run`/`build` select incremental native generation within that CLI;
explicit generation/check and editor smoke retain full semantic generation.
These snapshots are local developer tools, not installation catalog components;
their identities do not enter the runtime snapshot or deployment defines.
Bootstrap, explicit generation/check/cleanup, analysis, tests, pre-bootstrap
`test-plan --json`, and non-Linux commands retain their source-execution paths.

Tool identities hash source-tree membership and contents, resolved package
configuration/graph and lockfiles, owning manifests/overrides, compiler arguments,
preparation implementation, platform, and the selected SDK/compiler/runtime files.
The generator includes its `bin/` and resolved library trees. The worker includes
`tools/` and the root's resolved tooling dependencies, including development
dependencies; transitive packages contribute normal dependencies only. Package
locations come from package configuration, including path overrides and nonstandard
library directories. Compilation explicitly selects that root package configuration,
so stale nested configurations cannot shadow it. Entire selected library trees are
conservative compilation inputs, not a symbol-level import cache. Ordinary plugin
implementations and contract declarations are execution inputs, not tool-compilation inputs.
Dependency-resolution metadata rewrites can conservatively recompile tools even
when their library contents have not changed.

Each cold compilation emits a temporary compiler depfile. Every compiler input must
already belong to the pre-fingerprinted scope; an uncovered input fails preparation
rather than publishing an incompletely keyed executable. Bootstrap after changing
dependency declarations/resolution. Imports outside the tooling and resolved package
library trees require an explicit scope change. Depfiles are not reused to skip
discovery. Tool input membership, contents and race observations are rechecked before
first use and before publication. Executable artifact contents and stats, including
the selected `dartaotruntime`, are also validated immediately before each discovery
invocation. Final revalidation performs
one full tool-input recapture after rediscovery and the component/native checks,
comparing against the original observations; it does not repeat that source scan
before rediscovery. Changed tool sources still prevent publication, even if the
already-prepared worker finishes first. The tools share the existing lease,
receipt validation, staging, immutable publication and retention below. Missing or
damaged snapshots rebuild; compilation or execution failure never falls back to an
old tool or bypasses generation/discovery.
Directory race observations also guard transient source/optional-override additions
and removals; unrelated membership changes in those watched directories may require
a retry. Flutter's unrelated `.dart_tool/` cache membership is not watched.

### Input identities

AOT/EVC identities use SHA-256 over ordered input paths and content hashes, compiler
arguments and frontend selection, relevant preparation implementation, platform/ABI,
and the selected SDK identity. SDK context includes Flutter's machine-version
report and the paths/content hashes of the resolved Flutter executable, bundled
Dart, matched `dartaotruntime`, compiler snapshots and binaries, platform kernels,
and the Flutter test engine. Generated parts are fingerprinted after current
generation. Timestamps are not persistent cache keys: touching unchanged input
between invocations does not itself require recompilation. Hashing uses Linux
`sha256sum`, already required by CodeForge source preparation.

After generation, the selected Dart runs the analyzer-based
[`desktop_build_inputs_worker.dart`](../../tools/desktop_build_inputs_worker.dart)
through an SDK-only launcher coordinator. The worker resolves package URIs from
package-config JSON and follows imports, exports, parts, and every conditional
directive alternative, rather than traversing pubspec dependency/dev-dependency
lists. Inputs include each backend's own `bin/` and `lib/` trees, each frontend's
own `lib/` and optional `assets/` trees, owning manifests/configuration and declared
assets, and explicit dynamic source-map seeds for the stock frontend harnesses:
frontend source, public UI stubs, and generated-client contract declarations.
Membership changes in those trees are inputs too. Compiler helpers and imported
app-native bridges contribute their transitive file dependencies.

The coordinator validates each distinct returned file path once per worker response,
including paths shared by multiple components. This deduplication is local to that
response: both complete discovery passes still execute and validate their results
independently. No dependency graph or file-existence evidence is cached across
passes or launches.

This deliberately avoids one whole-repository or whole-source-plugin key, but is
not symbol-level precision. Common workspace lock/package configuration, generator
configuration and discovery implementation can invalidate multiple components.
Native bridge declarations share libraries with runtime implementation, so their
transitive imports can conservatively invalidate frontends even when interpreted
output would be unchanged. Shared frontend helpers and own source trees can also
broaden invalidation. Stock dynamic input declarations must be maintained alongside
the corresponding `app/tool` compiler helpers; the worker does not infer arbitrary
runtime `File` reads or automatically discover every third-party plugin layout.

The Git PTY helper has its own native identity in
[`git_pty_artifact.dart`](../../tools/git_pty_artifact.dart): C source and preparation
implementation, compiler/options/platform, selected compiler and subordinate tool
binaries, reported startup objects/libraries, compiler version, relevant compiler
environment, and preprocessed source covering selected macros and system headers.
Native inspection/preprocessing still runs on a hit; it does not generate machine
code. Public plugin startup configuration is not a compilation input.

### Publication and lifetime

An exclusive checkout preparation lease covers generation through publication.
Missing components compile into private `.staging/` directories; installation
assembly also uses private staging, including on a fully cached invocation.
Before publishing pending components or the snapshot, preparation rediscovers the
dependency graph and compares input contents, file/parent-directory stats, and the
native identity with their initial observations. This race fence rejects detected
mid-preparation changes, including membership changes and edit-and-restore cases;
stat information is not part of the reusable identity. Generation, discovery,
compiler, or validation failure is fatal, with no fallback to older incompatible
artifacts.

Entries under `components/<stage>/<identity>/entry-*/` and
`snapshots/<identity>/entry-*/` are immutable published generations with
`receipt.json` inventories. Reuse verifies output contents and executable bits;
missing, empty, linked, or damaged output/receipts cause a miss. Repair publishes a
new generation rather than overwriting a path captured by an existing application
or bundle. Snapshot identity includes component identities and the assembled files,
including installation descriptors and copied declaration schemas. Unchanged
assembly reuses the same host and installation paths.

Startup arguments are separate content-identified JSON under
`startup/<identity>/entry-*/`. Changing OpenAI's public credential-file reference or
options can select a new startup JSON path without recompiling components or
changing an otherwise identical snapshot; credential contents are not fingerprinted
or copied. Unchanged snapshot and startup inputs keep the generic deployment defines
stable. Git's prepared helper path is supplied through that same startup JSON.

There is no desktop `current.json` pointer, automatic garbage collection, installer,
or runtime caching. Published entries and failed staging are retained. The narrow
reference `DevelopmentPluginBuilder` still has its separate development pointer;
it does not define this checkout cache. Artifacts and defines remain checkout-local
absolute paths and depend on the referenced SDK's lifetime. Moving the checkout,
deleting retained outputs, or removing/changing that SDK can invalidate existing
bundles. This is not portable release packaging or a general third-party artifact
cache; that broader format, provenance, compatibility and distribution policy remain
deferred. Profiles and configured capability instances do not inherently own
compiled artifacts when source and build context are identical.

### Diagnostics

Stage diagnostics report elapsed time and status, including component `cached`,
`rebuilt`, or `failed` results, editor source preparation, SDK inspection,
build-tool preparation, generation, dependency discovery, installation assembly,
desktop preparation, the Flutter command, and launcher total. `flutter-run` and its
enclosing launcher total include the application's lifetime until the Flutter process exits; they are not
startup-to-first-frame measurements. Use preparation/component stages to distinguish
cache work from the subsequent app build/run. The native editor's own source and
native-test preparation workflow above remains separate from this cache.

Final `build-input-revalidation` reports its tool-artifact precheck, rediscovery,
metadata comparison, source/SDK content hashing, native identity reinspection, and
full tool-input postcheck separately. Discovery also reports worker execution and
coordinator result-validation time. These subphases are nested within the enclosing
stage durations; do not add them to those totals a second time.

## No SDK vendoring

The repository records the exact toolchain but does not vendor Flutter or Dart.
Vendoring would add large binaries, platform-specific content, update and
licensing maintenance, and release-distribution concerns before the local
plugin pipeline has proven its requirements. Developers and CI provision the
pinned SDK externally for the current development foundation.

Bundling or provisioning a pinned SDK for end-user ADELE distributions is a
future packaging decision. The repository excludes compiled plugin artifacts,
SDK caches, and build output from source control.
