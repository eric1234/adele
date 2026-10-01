# Testing and Validation

Role: Current repository development procedure

Use this guide to choose validation for a change and to use ADELE's maintained
analysis, test, and check workflow. [`tools/adele.dart`](../../tools/adele.dart)
and current source/tests remain authoritative for exact commands and targets.
SDK setup, bootstrap, generation, and build preparation belong to
[toolchain policy](toolchain.md).

## Proportionate validation

Choose checks for the boundary and risk being changed, not simply the largest
available suite.

| Change type | Normal validation |
| --- | --- |
| Documentation-only | Source/doc consistency, links/fragments as relevant, `git diff --check`; behavioral suites normally unnecessary. |
| Small isolated Dart behavior | Focused package/test target plus analysis and formatting as appropriate. |
| Public contract/schema | Generation/check plus affected consumers and tests. |
| Package/plugin wiring | Owning target plus maintained discovery/integration checks. |
| Application composition | Relevant app/integration tests and the app dependency boundary. |
| Broad cross-system/runtime change | Multiple maintained targets or repository check as scope warrants. |
| Native packaging/runtime | Relevant build/smoke where the change actually affects it. |
| Live-provider behavior | Explicit gated live test only when intentionally needed. |

**Do not run behavioral suites for a prose-only change merely to prove unchanged
runtime behavior.** Source/test inspection is normally sufficient to validate
factual documentation claims. A behavioral test is appropriate for documentation
work only when a specific factual uncertainty cannot reasonably be resolved by
inspecting source and existing tests.

## Maintained commands

Run repository commands from the repository root with the pinned toolchain:

```sh
dart tools/adele.dart bootstrap
dart tools/adele.dart format --check
dart tools/adele.dart generate --check
dart tools/adele.dart analyze
dart tools/adele.dart test
dart tools/adele.dart check
```

These are available operations, not a checklist to run for every edit.

| Command | Current behavior |
| --- | --- |
| `bootstrap` | Resolves workspace dependencies with `flutter pub get`, verifies that `dart pub workspace list` succeeds, then materializes configured ignored native contract parts. |
| `format --check` | Checks repository Dart formatting without rewriting files; formatting differences fail. |
| `generate --check` | Verifies current local generated siblings without writing; missing or stale output fails. |
| `analyze` | Regenerates current contracts, then analyzes repository tools, tool tests, and maintained Dart/Flutter analysis targets with fatal infos. |
| `test` | Regenerates current contracts once before executing the selected maintained test targets. |
| `check` | Runs `generate --check`, then format check, then analysis, then tests, stopping between phases on failure. |

`check` does not bootstrap the workspace or run native builds/smokes. Its initial
generation check deliberately exposes missing/stale local output before later
analysis or testing could regenerate it. See
[generated contract artifacts](toolchain.md#generated-contract-artifacts) for
generation inputs, ignored outputs, freshness, and cleanup semantics.

## Maintained test targets

`dart tools/adele.dart test` runs all maintained targets with bounded package-level
concurrency. The default is at most two concurrent target processes, reduced to
one on a single-processor host. This is separate from concurrency inside an
individual Dart/Flutter test process. Queued targets still run after another
target fails; the final summary reports failures.

For one maintained target, use `dart tools/adele.dart test --target <name>`.
Representative choices are:

```sh
dart tools/adele.dart test --target adele_desktop
dart tools/adele.dart test --target adele_tools
dart tools/adele.dart test --target plugin_runtime
dart tools/adele.dart test --target adele_project_storage
dart tools/adele.dart test --target search_tools_backend
```

Do not treat those examples as an exhaustive list. Obtain the current
machine-readable target/matrix view with:

```sh
dart tools/adele.dart test-plan --json
```

This exports the maintained registry, including target names, Linux desktop
dependency requirements, and CI concurrency metadata. It can run before bootstrap
without resolving dependencies or generating artifacts. It is not automatic
discovery of every package containing tests.

| Test option | Meaning and constraints |
| --- | --- |
| `--jobs N` | Positive integer controlling concurrent target processes; `--jobs=N` also works. Cannot be combined with `--target`. An explicit value may exceed the default of two. |
| `--target NAME` | Runs exactly one named maintained target. Unknown names fail; use the separated form, not `--target=NAME`. |
| `--ci` | Valid only with `--target`. Applies that target's CI runner arguments/concurrency policy. It is not a generic credential/environment scrub. |

The [CI workflow](../../.github/workflows/ci.yaml) consumes `test-plan --json` and
runs each matrix entry with `test --target NAME --ci` after independent bootstrap.
The local two-process default does not limit CI matrix parallelism.

The `adele_desktop` CI target runs Flutter test files with one worker. Its real-AOT
and prepared-EVC fixtures are compiler-heavy; concurrent files can consume the
unchanged activity timing and full-capture deadlines through resource contention.
Serial CI execution preserves those assertions, full transcript volumes, and all
test selection. The non-CI target retains Flutter's normal worker default.

When adding a package/plugin, verify workspace membership and update maintained
analysis/test discovery and relevant wiring checks where appropriate. Passing
the package's direct `dart test` alone does not establish repository or CI
integration. See [dependency rules](../architecture/dependency-rules.md#new-packages-and-apis),
the driver's `analysisTargets` / `testTargets`, and
[`test/tools/adele_test.dart`](../../test/tools/adele_test.dart).

## Direct local iteration

Direct commands remain useful for narrow iteration after dependencies and
generated parts are current. In the owning Dart package, run `dart test`; from
`app/`, for example:

```sh
flutter test --no-pub <test-path>
flutter analyze --no-pub --fatal-infos
```

A direct local test proves that selected code/test passes. A maintained
`tools/adele.dart` target additionally uses repository-maintained selection and
runner policy shared with CI. Direct Flutter commands do not regenerate native
contract parts; use `dart tools/adele.dart generate` from the repository root
after declaration changes. Repository `analyze` has no focused `--target` option.

## Application validation map

Select tests for the application boundary being changed. Paths in the table are
relative to `app/`; this is a testing map, not an application architecture map.

| Changed boundary | Representative app test paths |
| --- | --- |
| Zero-plugin runtime/shell | [`test/core/adele_runtime_test.dart`](../../app/test/core/adele_runtime_test.dart), [`test/application_test.dart`](../../app/test/application_test.dart) |
| Prepared backend/frontend bootstrap | [`test/core/application_plugin_bootstrap_test.dart`](../../app/test/core/application_plugin_bootstrap_test.dart), [`test/prepared_frontend_activation_test.dart`](../../app/test/prepared_frontend_activation_test.dart), [`test/prepared_frontend_failure_test.dart`](../../app/test/prepared_frontend_failure_test.dart) |
| Project/native picker bridge | [`test/project_opening_test.dart`](../../app/test/project_opening_test.dart), [`test/directory_picker_bridge_test.dart`](../../app/test/directory_picker_bridge_test.dart) |
| Native terminal emulator/view | [`test/native_terminal_surface_test.dart`](../../app/test/native_terminal_surface_test.dart) (real control parsing/styles/Unicode, hidden output, finite retention/geometry, local read-only copy/scroll, attachment, denied ambient clipboard, and explicit disposal) |
| Prepared terminal bridge | [`test/terminal_surface_bridge_test.dart`](../../app/test/terminal_surface_bridge_test.dart) (actual EVC compilation/mount, native input/focus/paste/mouse, resize/rebuild, scoped handles, retained-widget and pending-paste revocation, prepared failure/retirement, independent lifetimes, and bundled MIT notice) |
| Shared console contracts/state/chrome | [`test/console_controller_test.dart`](../../app/test/console_controller_test.dart), [`test/workbench_console_test.dart`](../../app/test/workbench_console_test.dart), plus [`adele_ui` console tests](../../packages/ui/test/console_test.dart) (independent contributions, selected-only default, lazy bounded LRU residency including the selected slot, exact interaction epochs, working-set departure, advisory confirmation, retirement, and bounded cleanup) |
| Prepared console/Session Environment authority | [`test/prepared_console_host_test.dart`](../../app/test/prepared_console_host_test.dart) (actual EVC action/content paths, canonical Session association rather than Task primary, captured creation scope, fresh view access, title/exit policy, and failure cleanup) |
| Native terminal lifecycle/title observation | [`test/native_terminal_surface_test.dart`](../../app/test/native_terminal_surface_test.dart), [`test/environment_terminal_owner_test.dart`](../../app/test/environment_terminal_owner_test.dart) (normalized title changes, hidden observation, lifecycle/cleanup evidence separate from output, and conservative pre-resource failure) |
| Task/Environment lifecycle | [`test/task_creation_test.dart`](../../app/test/task_creation_test.dart), [`test/core/product_lifecycle_test.dart`](../../app/test/core/product_lifecycle_test.dart) |
| Task Browser canonical projection/actions | [`test/window_task_browser_source_test.dart`](../../app/test/window_task_browser_source_test.dart) (immutable Session queries, Project/Task scope, unavailable retained Sessions, exact creation choices, retirement, and opening without Environment materialization or Run start) |
| Task Browser bridge/view hosting | [`test/task_browser_bridge_test.dart`](../../app/test/task_browser_bridge_test.dart), [`test/task_browser_presentation_host_test.dart`](../../app/test/task_browser_presentation_host_test.dart) (safe action settlement, subscriptions/revocation, zero/one/many resolution, and retained factory state) |
| Prepared Task Browser activation | [`test/prepared_task_browser_host_test.dart`](../../app/test/prepared_task_browser_host_test.dart) (frontend-only activation, lazy source creation/disposal, exact retirement, and per-view bytecode/entrypoint failure) |
| Durable Project/Task/Environment records | [`test/core/project_database_test.dart`](../../app/test/core/project_database_test.dart), [`test/core/durable_project_lifecycle_test.dart`](../../app/test/core/durable_project_lifecycle_test.dart), [`test/core/durable_task_environment_lifecycle_test.dart`](../../app/test/core/durable_task_environment_lifecycle_test.dart), [`test/core/durable_task_git_integration_test.dart`](../../app/test/core/durable_task_git_integration_test.dart) (fresh runtime and whole-Project move, real SQLite/Git backends) |
| Durable Session identity/Environment association | [`test/core/durable_session_lifecycle_test.dart`](../../app/test/core/durable_session_lifecycle_test.dart), [`test/core/project_database_test.dart`](../../app/test/core/project_database_test.dart) (complete-graph validation, atomic creation, missing strategy/provider, and no volatile fallback) |
| Terminal Run schema/publication | [`test/core/project_database_test.dart`](../../app/test/core/project_database_test.dart), [`test/core/durable_session_lifecycle_test.dart`](../../app/test/core/durable_session_lifecycle_test.dart) (separate product/execution v1 owners, atomic record/activity retention, whole-graph publication, immutable lookup, and explicit volatile retention) |
| Terminal execution evidence | [`test/core/execution_evidence_test.dart`](../../app/test/core/execution_evidence_test.dart) (normalized schema, field-by-field public snapshot roundtrip, Run-local ordering/provenance validation, corruption rejection, and record/evidence rollback) |
| Terminal Run execution/restart | [`test/core/durable_run_lifecycle_test.dart`](../../app/test/core/durable_run_lifecycle_test.dart) (completed/failed fresh-runtime snapshot restore, unstarted/waiting close without invented outcomes, approval completion, SQLite and execution-plus-storage failures without retry, deferred mechanics draining, and no ID allocation or live execution/approval recreation) |
| Session-scoped plugin storage host | [`test/core/project_storage_host_test.dart`](../../app/test/core/project_storage_host_test.dart) (owner schema, Project routing, scalar/query bounds, atomic batches, explicit volatile distinction, and queued-entry revocation) |
| Durable Chat across real backend generations | [`test/core/durable_chat_session_integration_test.dart`](../../app/test/core/durable_chat_session_integration_test.dart) (conversation/configuration/plain-text draft, user-entry Run association, atomic draft submission, fresh-runtime reopen, and completed Run/activity retention despite Chat storage failure; real Local Directory/Git/Chat AOT backends and SQLite with a deterministic native model fixture, no paid provider) |
| Prepared Chat composer/history | [`test/chat_frontend_eval_test.dart`](../../app/test/chat_frontend_eval_test.dart) (draft saves/submission/retry, latest-save deactivation settlement, recoverable failure/pending-Send refusal, stale snapshot protection, historical activity placement, and preserving live handles during refresh) |
| Session presentation settlement/rebinding | [`test/session_presentation_lifecycle_bridge_test.dart`](../../app/test/session_presentation_lifecycle_bridge_test.dart), [`test/prepared_session_host_test.dart`](../../app/test/prepared_session_host_test.dart) (async hook acceptance/failure, no-hook behavior, retirement during settlement, and exact action revocation on unbind/reopen) |
| Session presentation/execution/approval | [`test/session_presentation_host_test.dart`](../../app/test/session_presentation_host_test.dart), [`test/session_execution_test.dart`](../../app/test/session_execution_test.dart), [`test/core/approval_gated_tool_policy_test.dart`](../../app/test/core/approval_gated_tool_policy_test.dart) (passive retained-owner lookup, independent Session advancement, shared IDs, exact approval isolation, semantic readiness, and all-owner shutdown) |
| Orchestration/authority adapters | [`test/core/orchestration_host_test.dart`](../../app/test/core/orchestration_host_test.dart), [`test/core/orchestration_authority_test.dart`](../../app/test/core/orchestration_authority_test.dart), [`test/core/model_tool_host_test.dart`](../../app/test/core/model_tool_host_test.dart), [`test/core/remote_inference_context_integration_test.dart`](../../app/test/core/remote_inference_context_integration_test.dart) |
| Activity/Inspection | [`test/core/run_activity_projection_test.dart`](../../app/test/core/run_activity_projection_test.dart), [`test/inspection_host_test.dart`](../../app/test/inspection_host_test.dart), [`test/inspection_stack_test.dart`](../../app/test/inspection_stack_test.dart), [`test/openai_activity_frontend_eval_test.dart`](../../app/test/openai_activity_frontend_eval_test.dart) |
| Scoped activity reacquisition | [`test/session_execution_activity_test.dart`](../../app/test/session_execution_activity_test.dart), [`test/session_execution_bridge_test.dart`](../../app/test/session_execution_bridge_test.dart) (live/waiting/preparing and historical Session validation, fresh read-only opaque handles, permanent old-view revocation, unchanged activity/Inspection paths, and no execution authority) |
| Prepared normal composition, no live model | [`test/core/normal_task_git_integration_test.dart`](../../app/test/core/normal_task_git_integration_test.dart), [`test/core/normal_chatgpt_run_integration_test.dart`](../../app/test/core/normal_chatgpt_run_integration_test.dart) (local fake Responses/credentials and picker; concurrent Session commands in separate Task worktrees through shared AOT hosting, warm Command Output switching and cold Session history return, browser running/attention status, live/terminal Chat/activity reentry, stale approval callbacks, delayed/failed draft settlement, Inspection clearing, and hidden-owner shutdown; not interactive native-picker proof) |
| Deterministic self-hosting | [`test/development/agent/development_self_hosting_test.dart`](../../app/test/development/agent/development_self_hosting_test.dart), [`test/development/agent/environment_read_agent_integration_test.dart`](../../app/test/development/agent/environment_read_agent_integration_test.dart) |

Application dependency-boundary checks belong to
[`test/tools/app_plugin_boundary_test.dart`](../../test/tools/app_plugin_boundary_test.dart)
in `adele_tools`. They check production app manifest dependencies and import/export
directives, not every repository dependency edge. Checkout preparation, driver,
and launcher checks also live in that target:
[`backend_artifacts_test.dart`](../../test/tools/backend_artifacts_test.dart),
[`adele_test.dart`](../../test/tools/adele_test.dart), and
[`self_hosting_cli_test.dart`](../../test/tools/self_hosting_cli_test.dart).
See [developer self-hosting](self-hosting.md#validation-and-source-map) for that
workflow's source/evidence owners and deterministic-versus-live distinction.

### Focused command output checks

After bootstrap/current generation, use the pinned SDK and serialize Flutter
invocations sharing the app build directory. The plugin-owned capture/read/watch
and generated contract checks run from the repository root:

```sh
dart tools/adele.dart test --target command_tools_plugin
dart tools/adele.dart test --target command_tools_backend
dart tools/adele.dart test --target command_tools_contract
dart tools/adele.dart test --target adele_model_tool
dart tools/adele.dart test --target adele_project_storage
dart tools/adele.dart test --target contract_codegen
dart test test/tools/adele_test.dart test/tools/app_plugin_boundary_test.dart test/tools/self_hosting_cli_test.dart
dart tools/adele.dart generate --check
```

For focused provider iteration, run `dart test
test/git_worktree_environment_provider_test.dart test/backend_host_integration_test.dart`
from `plugins/git_environment/packages/backend/`. Select the foreground process
cases when unrelated provider coverage is unnecessary; this work does not require
the PTY target. From `app/`:

```sh
flutter test --no-pub --concurrency 1 test/owning_backend_stream_bridge_test.dart
flutter test --no-pub --concurrency 1 test/command_output_frontend_eval_test.dart test/tool_inspection_frontend_eval_test.dart test/tool_activity_inspection_bridge_test.dart test/inspection_host_test.dart
flutter test --no-pub --concurrency 1 test/terminal_projection_bridge_test.dart test/native_terminal_surface_test.dart test/terminal_surface_bridge_test.dart
flutter test --no-pub --concurrency 1 test/console_bridge_test.dart test/console_controller_test.dart test/prepared_console_host_test.dart test/workbench_console_test.dart
flutter test --no-pub --concurrency 1 test/core/normal_chatgpt_run_integration_test.dart
flutter test --no-pub --concurrency 1 test/core/command_output_capture_integration_test.dart
flutter test --no-pub --concurrency 1 test/core/remote_model_tool_host_test.dart test/core/remote_model_tool_integration_test.dart
flutter test --no-pub --concurrency 1 test/core/project_storage_host_test.dart test/core/project_database_test.dart test/core/product_lifecycle_test.dart
flutter test --no-pub --concurrency 1 test/chat_frontend_eval_test.dart test/prepared_session_host_test.dart test/session_execution_bridge_test.dart
```

The early stream fixture compiles a generated `Stream<DTO>` client and mounts its
EVC through `PreparedFrontend.load/createPresentation`, proving the evaluator
projection and generic host bridge separately from Command behavior. The decisive
command fixture crosses real shared-host/Git/Command AOT, generated authorized
process transport in both hops, and the Project storage grant into SQLite. Its
socket-gated process emits more than 12 Mi UTF-16 code units per pipe, including
known beginning/middle/late markers and terminal controls, then waits for release.
Bounded pages establish live marker availability and exact full reconstruction
before exit. Two identical invocations share one Run but not one capture. A fresh
Project/backend read requires neither Git nor an Environment materialization.

The test-only interpreted capture consumer uses the plugin-generated client over
actual backend transport, reads pages and live state, unmounts without stopping
capture, and remounts with fresh access. It remains independent of production
presentation, so rendering changes do not weaken the full-volume capture proof.
Fixture source and compilation live in
`app/test/fixtures/command_output_frontend.dart` and
`app/tool/command_output_frontend_compiler.dart`, not runtime preparation of a
stock view.

The stock output EVC is built through the existing tool-Inspection compiler with
generated own-backend reads/watch and generic console/projection declarations.
`command_output_frontend_eval_test.dart` tests that actual client and stock UI with
small native retention, including prefix reconstruction, long unbroken lines,
state-only updates, frozen history, bounded read admission, safe failures, and
scalar-only cold-remount state. Prepared console coverage additionally checks
resident readers and generated-service accounting across warm tab switches;
native/bridge cases enforce the separate selected interaction epoch.
`terminal_projection_bridge_test.dart` separately
exercises scoped handles and revocation; existing interactive surface regressions
remain selected alongside it.
Readiness assertions observe native paint gating and settled viewport position at
frame boundaries, not only widget presence or the final rendered buffer. The stock
EVC cases cover finite high-water restoration under continued output, no ordinary
live-page flicker, and repeated hide/remount while a historical prefix is rebuilding.

The normal-application Command case in `normal_chatgpt_run_integration_test.dart`
uses the ordinary Chat activity click, stock Inspection/console EVCs, real Command
and Git AOT backends, SQLite, and deterministic local model responses. Its opt-in
mode in the existing socket-gated process fixture supplies ANSI, CR repainting,
partial lines, and known beginning/middle/late output. It checks both views before
completion, deduplication, identical-command independence, native scroll/follow,
and history beyond configured retention. Two warm output tabs retain tab,
resident, mounted view, and emulator identity across selection and repeated Show
more. A socket-gated later partial line is committed and consumed by the hidden
reader with Inspection closed; output also advances while interactive Terminal
is selected. Session departure revokes both residents and disposes their views,
while lightweight tabs survive for lazy cold historical reconstruction. It retains
the closing-readers-without-stopping-capture, nonzero completion, and fresh
compatible-backend history checks after Project reopen without installing Git.
The separate concurrent Session case continues to verify independent execution,
capture, approval, and history across navigation. These are debug
widget/evaluator/Linux-AOT checks, not paid-model or desktop/profile evidence.

Memory checks are accounting assertions, not absolute RSS claims: provider pending
decoded units/admitted reads and pause/resume, plugin pending batch row/text limits,
page limits, active writer/observer counts, coalesced paused notifications, and
absence of raw transcript events in generic progress/journal/activity. Test-owned
buffers used to compare expected whole transcripts do not represent production
retention. Resident count bounds are checked independently from Flutter subtree
disposal timing and do not claim absolute instantaneous object counts or RSS; see
the [host accounting policy](../../app/README.md#session-console). The normal
integration uses identity/lifetime evidence rather than adding production Command
read counters; deterministic stock EVC fixtures cover precise read/watch accounting.
The native process fixture is local and deterministic; these checks use
no paid/live model, self-hosting workflow, or desktop/profile run. Command capture
uses foreground pipes, not a PTY; the normal application's separate interactive
Terminal coexistence check does run the stock PTY path.
New app tests participate in the unrestricted maintained `adele_desktop` target;
the new contract package has explicit workspace/analysis/test discovery.

### Focused terminal checks

After bootstrap, run from `app/` using the repository pin:

```sh
flutter test --no-pub --concurrency 1 test/native_terminal_surface_test.dart test/terminal_surface_bridge_test.dart
flutter test --no-pub --concurrency 1 test/environment_terminal_owner_test.dart test/environment_terminal_integration_test.dart
flutter analyze --no-pub --fatal-infos
```

The fixture under `app/test/fixtures/terminal_frontend.dart` compiles against the
real public UI stub and compile-only declarations, writes EVC bytes, and loads and
mounts through `PreparedFrontend`. It uses synthetic ordered output and native
recording sinks, no shell, credentials, network, or product objects. Native event
paths exercise text/control input, explicit paste, focus, mouse reporting, and
layout changes. Fixed frame advancement accounts for the terminal's gesture and
cursor behavior; do not use unbounded `pumpAndSettle` with blinking cursors.

The Environment owner tests cover lifetime and captured authority separately from
the presentation-only regressions. The real integration prepares the same frontend
fixture and crosses the native owner, generated Environment transport, shared AOT
host, and actual Git backend. Its local process fixture uses bounded handshakes,
not credentials, network, or model calls. A widget-only or standalone native PTY
test is not a substitute for that combined path.

From the repository root, the owning public/backend and preparation checks are:

```sh
dart tools/adele.dart test --target adele_environment
dart tools/adele.dart test --target git_environment_backend
dart test test/tools/backend_artifacts_test.dart test/tools/app_plugin_boundary_test.dart test/tools/adele_test.dart
dart tools/adele.dart generate --check
```

The low-level terminal app files are automatically included by the unrestricted
`adele_desktop` target and its CI selection; their probe EVC needs no stock frontend
preparation. Stock console composition is a separate check below. The Git backend
target includes native PTY/shared-host and provider resource tests. CI explicitly
installs `gcc` and `libc6-dev` for the native Git/app checks. Keep Flutter compiler/test
invocations sharing the app build directory serialized. These checks target debug
widget/evaluator behavior on the pin, not native desktop/profile or cross-platform
runtime support.
The [application map](../../app/README.md#native-terminal-surface) owns the
adapter's lifetime, callback, and attachment policies.

### Focused console checks

This is a validation command map, not recorded pass results. After bootstrap and
current contract generation, run the focused host checks from `app/`:

```sh
flutter test --no-pub --concurrency 1 test/console_controller_test.dart test/workbench_console_test.dart test/prepared_console_host_test.dart
flutter test --no-pub --concurrency 1 test/core/normal_chatgpt_run_integration_test.dart
```

From the repository root, select the public contract, descriptor, stock EVC, and
tooling targets as appropriate:

```sh
dart tools/adele.dart test --target adele_ui
dart tools/adele.dart test --target plugin_runtime
dart tools/adele.dart test --target terminal_frontend
dart tools/adele.dart test --target adele_tools
```

The stock Terminal case reuses the normal application integration fixture: prepared
Local Directory/Task Browser/Chat/Terminal EVC, real shared-host and Git AOT,
SQLite, and the prepared Git PTY helper. It targets Session-only chrome (no Task
Browser panel/toggle/actions), explicit creation without a Run, independent shells,
input/resize, hidden output/title changes, Session/Environment navigation, actual
exit/removal, conservative close, and shutdown. It needs Linux x64/devpts and the
native prerequisites above, not credentials or a paid model.

The real-shell fixture launches the unchanged shared host through a controlled
environment wrapper with temporary `HOME`, `SHELL=/bin/sh`, and fixed `PATH`;
personal startup files do not determine test behavior. Provider-only default-shell
cases and their narrower environment seam belong to the
[Git provider](../../plugins/git_environment/README.md#interactive-terminals).
Production shell resolution/startup is not replaced by that fixture configuration.

Keep Flutter compiler/test invocations sharing app build output serialized. Use
bounded predicate/frame advancement for mounted terminals, not unbounded
`pumpAndSettle` with a blinking cursor. These checks target debug widget/evaluator
and actual Linux AOT/process boundaries, not native desktop/profile or cross-platform
support. They complement rather than replace the low-level terminal checks above.

### Focused browser checks

The Task Browser public resolver belongs to
[`packages/ui/test/task_browser_test.dart`](../../packages/ui/test/task_browser_test.dart);
descriptor validation belongs to
[`packages/plugin_runtime/test/prepared_plugin_catalog_test.dart`](../../packages/plugin_runtime/test/prepared_plugin_catalog_test.dart).
The stock frontend's actual-EVC presentation cases belong to the
[`task_browser_frontend` tests](../../plugins/task_browser/packages/frontend/test/task_browser_frontend_test.dart),
separate from app source/authority and real-backend composition checks. Use the
maintained targets from the repository root after bootstrap:

```sh
dart tools/adele.dart test --target adele_ui
dart tools/adele.dart test --target plugin_runtime
dart tools/adele.dart test --target task_browser_frontend
dart tools/adele.dart test --target adele_tools
```

For focused host and navigation iteration from `app/`, with generated parts current:

```sh
flutter test --no-pub test/window_task_browser_source_test.dart test/task_browser_bridge_test.dart test/task_browser_presentation_host_test.dart
flutter test --no-pub test/prepared_task_browser_host_test.dart
flutter test --no-pub test/session_presentation_lifecycle_bridge_test.dart test/prepared_session_host_test.dart test/chat_frontend_eval_test.dart
flutter test --no-pub --concurrency 1 test/core/normal_chatgpt_run_integration_test.dart
```

The normal integration uses prepared AOT/EVC components and real SQLite/Git with
local fake Responses and credentials, not a live paid model. Browser reads/opening
are checked separately from Task establishment and Run execution. Workspace,
analysis/test discovery, frontend compilation, frontend-only installation assembly,
and production app dependency boundaries are tooling concerns, not established by
a plugin widget test alone. These paths and commands are a validation map, not
recorded pass results or cross-platform desktop proof.

The concurrent Session case routes deterministic model continuation by each
Session's own prompt/tool context, not a global call count. Socket handshakes hold
A's command while B emits real output in a separate worktree; returning to A
checks retained Run/capture identity, hidden approval, exact resolution, and final
canonical history. Failed-test cleanup releases the processes before application
shutdown drains them. For application-wide ownership/navigation changes, follow
focused checks with the maintained `dart tools/adele.dart test --target
adele_desktop --ci`; preserve its single Flutter-worker policy.

### Focused persistence checks

After bootstrap, regenerate contracts from the repository root when declarations
or transport consumers change:

```sh
dart tools/adele.dart generate
```

For Session/storage work, use selected tests from `app/`, rather than routinely
running the full application target:

```sh
flutter test --no-pub test/core/project_database_test.dart test/core/durable_session_lifecycle_test.dart test/core/project_storage_host_test.dart
flutter test --no-pub --concurrency 1 test/core/durable_chat_session_integration_test.dart
flutter test --no-pub test/chat_frontend_eval_test.dart
flutter test --no-pub --concurrency 1 test/core/normal_chatgpt_run_integration_test.dart
```

The real-AOT integration needs the pinned Dart AOT toolchain and Git but no live
provider credentials. It checks durable state across runtime/backend lifetimes,
including exact partial-draft restoration without Run start and submission
retention after another reopen, not interactive desktop navigation or approval
restart. The normal Chat test uses a local fake provider and exercises prepared
browser/breadcrumb navigation, composer-to-Run flow, and reopened terminal activity
through the same presentation paths. Consult the test source
for its exact cases; these commands are guidance, not recorded pass results.

The public contract's value/transport checks belong to
`dart tools/adele.dart test --target adele_project_storage`. Chat-owned store and
remote settlement cases live in
[`chat_durable_state_test.dart`](../../plugins/chat_strategy/packages/backend/test/chat_durable_state_test.dart)
and [`chat_remote_backend_test.dart`](../../plugins/chat_strategy/packages/backend/test/chat_remote_backend_test.dart).
From `plugins/chat_strategy/packages/backend/`, use:

```sh
dart test test/chat_durable_state_test.dart test/chat_remote_backend_test.dart
```

The maintained `chat_strategy_backend` target is the broader package check from
the root. These tests complement app integration for corruption, failed writes,
canonical-cache ordering, explicit volatile behavior, and post-materialization
Run association/cleanup without overwriting an accepted association.
Draft cases include SQLite-trigger rollback of set/submission, unchanged entry
occurrence IDs after failure, mutation/execution fencing, and rejection before
persisting a draft that would exceed the existing full-row read bound. Contract
changes, including the required nullable `ChatEntry.runId` key, additionally require
`dart tools/adele.dart test --target chat_strategy_contract`
and `dart tools/adele.dart generate --check`; eval preparation derives the current
wire shape from those same declarations, with no old-wire compatibility.

For terminal Run/history changes, select public-value checks from the repository
root for the affected boundary:

```sh
dart tools/adele.dart test --target adele_product
dart tools/adele.dart test --target adele_orchestration
dart analyze --fatal-infos packages/product
```

Then run the affected database, Session, authority, execution, and restart tests
from `app/`, plus deterministic Chat integration for its separate storage boundary:

```sh
flutter test --no-pub \
  test/core/project_database_test.dart \
  test/core/execution_evidence_test.dart \
  test/core/durable_session_lifecycle_test.dart \
  test/core/orchestration_host_test.dart \
  test/core/orchestration_authority_test.dart \
  test/session_execution_test.dart \
  test/session_execution_activity_test.dart \
  test/session_execution_bridge_test.dart \
  test/core/durable_run_lifecycle_test.dart
flutter test --no-pub --concurrency 1 test/core/durable_chat_session_integration_test.dart
flutter analyze --no-pub --fatal-infos \
  lib/core lib/ui/execution test/core test/session_execution_test.dart
```

These are focused implementation checks, not a reason to run the broad
`adele_desktop` target or launch/build the desktop for a terminal-history change.
The Run restart fixture uses real SQLite and deterministic strategy/model/tool
mechanics; the Chat fixture crosses real backend generations without a live model.
The assertions distinguish immutable terminal evidence from live execution and
recovery, and check primary-error preservation, sole storage-error surfacing,
cleanup, and no automatic retry. Historical activity checks also cover Session
scope and the read-only bridge; the prepared frontend cases cover placement and
safe display without feeding historical native data into future continuation.
See [terminal retention semantics](../architecture/execution-model.md#terminal-run-retention)
and [execution history](../architecture/execution-model.md#terminal-execution-history).
For documentation-only updates, use the [proportionate checks](#proportionate-validation)
instead of running these behavioral suites.

Infrastructure grants also require focused transport/lifecycle validation in
[`plugin_runtime/test/extension_runtime_test.dart`](../../packages/plugin_runtime/test/extension_runtime_test.dart),
[`plugin_backend_host/test/plugin_termination_test.dart`](../../packages/plugin_backend_host/test/plugin_termination_test.dart),
and [`plugin_backend_support/test/host_request_multiplexer_test.dart`](../../packages/plugin_backend_support/test/host_request_multiplexer_test.dart).
Use the owning package's direct tests or maintained target. Check workspace,
generation configuration, analysis/test discovery, and app production dependency
boundaries when changing `adele_project_storage` wiring; passing only direct
contract tests does not establish repository integration.

## Native build and runtime smoke

When native packaging or runtime changes warrant it, use the relevant path:

```sh
dart tools/adele.dart build linux --profile
dart tools/adele.dart smoke linux --profile
```

The normal build validates normal application preparation/packaging; it does not
run the app. The separate development smoke builds and executes
[`app/tool/development_runtime_smoke/main.dart`](../../app/tool/development_runtime_smoke/main.dart).
That exercises reference-fixture build/start/stop and runtime cleanup, not normal
product interaction. Neither path automatically proves interactive native-picker
behavior.

The smoke needs existing directories configured through
`ADELE_DEVELOPMENT_REPOSITORY_ROOT`, `ADELE_DEVELOPMENT_PLUGIN_DIRECTORY`, and
`ADELE_DEVELOPMENT_DIRECTORY`; the
[smoke workflow](../../.github/workflows/runtime-smoke.yaml) shows its reference
fixture and display setup. Follow [toolchain policy](toolchain.md) for SDK,
generation, and artifact-preparation details.

### Native editor candidate probe

The [CodeForge investigation](../experiments/codeforge-correctness.md) is separate
from workspace dependency resolution and application compilation. Its evidence
table owns empirical findings and qualifications; passing a probe is not E1 or
prepared-EVC editor acceptance. Only Linux x64 is supported by these commands.
Prerequisites: the integrated SDK, ordinary Linux Flutter desktop dependencies,
`curl`, Git, `tar`, `diff`, `sha256sum`, `readelf`, `timeout`, Xvfb, and Rust 1.93.0:

```sh
rustup toolchain install 1.93.0 --profile minimal --target x86_64-unknown-linux-gnu
```

Use absolute SDK paths and a **new** output directory per configuration. Set
`FLUTTER_ROOT` for the command as well: an inherited value can make a pinned Dart
executable resolve against an unrelated Flutter SDK. Do not change global SDK
selection or ADELE's workspace lock. From the checked-out repository:

```sh
ADELE_FLUTTER=/absolute/path/to/flutter-3.38.10
PROBE=/tmp/adele-codeforge-manual
env FLUTTER_ROOT="$ADELE_FLUTTER" "$ADELE_FLUTTER/bin/cache/dart-sdk/bin/dart" tools/adele.dart probe-code-editor --flutter "$ADELE_FLUTTER/bin/flutter" --output "$PROBE" --prepare-only
env -C /tmp -u LD_LIBRARY_PATH -u LD_PRELOAD -u FRB_DART_LOAD_EXTERNAL_LIBRARY_NATIVE_LIB_DIR "$PROBE/probe/build/linux/x64/profile/bundle/adele_codeforge_probe" --interactive
```

`--prepare-only` verifies source/SDK/native identities, formats/analyzes fixtures,
builds a profile bundle, runs the corrected native input/render/unmount smoke and
missing-library subprocess, and checks the interactive reset/snapshot UI. It does
not run editor-correctness assertions. The second command launches the same binary
without auto-exit on the user's desktop; add `xvfb-run -a` before the binary only
for an automated headless launch. No Cargo or source checkout is needed at runtime.

The interactive view shows configuration/SDK identities and uses supplied synthetic
documents with fresh controller/undo state on Reset or sample change. It does not
open/save files or configure LSP, AI, or network services. It logs only startup and
explicit snapshots of probe content; there is no continuous document/clipboard or
global-key recording. Use synthetic content only. "Copy synthetic U+1F600" replaces
the current display's clipboard with that glyph without reading its old content.

Short Linux manual checklist (grouping on, widget read-only off):

1. **ASCII delete:** Reset `ASCII delete`, focus the editor, Ctrl+Home, Delete twice
   at a natural pace, then Ctrl+Z until the edit history is restored. Expected
   `abc`; one undo may suffice with grouping. Press F8 and return the one
   `CODEFORGE_MANUAL_SNAPSHOT` line. This checks ordinary desktop reachability;
   do not try to win the 100ms race. The automated 20ms case covers that trigger,
   and a slower successful manual result does not invalidate it.
2. **Unicode undo:** Choose `Unicode paste`, use "Copy synthetic U+1F600", Ctrl+Home,
   Ctrl+V, then Ctrl+Z. Expected `ab`; F8 exposes escaped text, scalar selection,
   UTF-16 code units and recorded history. This checks actual desktop clipboard
   delivery rather than the test's mocked response. No IME is required.
3. **CRLF join:** Choose `CRLF join`, focus the editor, Ctrl+End, Home, Backspace.
   Expected `ab`. F8 distinguishes `\r`, `\n` and code units even if rendering
   looks similar; Ctrl+Z should restore `a\r\nb`. This checks desktop navigation
   and joining at the actual caret position.

F8 is an explicit observation, not an immediate-input timing test. The snapshot
button can also observe after focus/flush changes; no immediate-snapshot proof is
based on clicking it. Actual human keyboard/clipboard checks are prepared for Eric,
not claimed as performed by automated Xvfb/widget tests. Return only synthetic
snapshot lines and the displayed configuration identity, not unrelated clipboard
contents or files. Human IME tests are deferred until a specific uncertainty needs
one and the tester has that input method.

For correct-behavior automated comparisons, use the same command with fresh output
paths and these options instead of `--prepare-only`:

- `--investigate`: mounted/default-configuration cases, with correct assertions.
- `--correctness-patch --investigate`: the separate bounded causal patch on the
  ADELE pin. Success covers the targeted tests, not production adoption.
- `--verify-known-defects`: only the original versioned 10.14.0 baseline observations.
  It cannot be combined with the causal patch or investigation suite. Compile,
  crash, timeout, or unexpected behavior still fails; success is not acceptance.

Default mode without those options retains the original correct-behavior tests.
Unpatched correctness runs are expected to fail the specifically documented
assertions; inspect per-case JSON and failure reasons, not exit status alone.
Stage logs, effective dependency locks, source/native hashes, SDK identity and
`logs/result.json` distinguish preparation failures, skipped correctness work,
test failures, and completed native smoke. Keep different configurations' artifacts
separate. Reusing unchanged artifacts within one configuration requires checking
their retained identities; do not share one configuration's library with another.

For an unmodified published control, obtain an isolated official supported SDK.
The [evidence record](../experiments/codeforge-correctness.md#controlled-comparison)
contains the tested Flutter 3.47.5 archive URL, checksum and machine identities.
Extract it outside the repository without changing the default SDK, then run:

```sh
CONTROL_FLUTTER=/absolute/path/to/isolated/flutter-3.47.5
env FLUTTER_ROOT="$ADELE_FLUTTER" "$ADELE_FLUTTER/bin/cache/dart-sdk/bin/dart" tools/adele.dart probe-code-editor --flutter "$CONTROL_FLUTTER/bin/flutter" --upstream-control --output /tmp/adele-codeforge-upstream --investigate
```

This uses hosted CodeForge, a private pub cache and isolated exact Rust selection,
with **no** SDK/component source patch. The driver checks the Dart admission
constraint but only an actual successful build establishes API compatibility.
Ordinary upstream dependency resolution and Cargokit behavior are retained and
their locks recorded; source equality and Cargo-lock stability are checked. A
control preparation failure is not an editing result.

For a minimal upstream-ready case after preparing a control bundle, the retained
`investigation_test.dart.template` is self-contained and imports only CodeForge,
Flutter, Flutter test and Dart SDK APIs. Run one named case from that prepared
application without rebuilding or changing its library identity:

```sh
CONTROL_PROBE=/tmp/adele-codeforge-upstream
env -C "$CONTROL_PROBE/probe" FLUTTER_ROOT="$CONTROL_FLUTTER" PUB_CACHE="$CONTROL_PROBE/pub-cache" FRB_DART_LOAD_EXTERNAL_LIBRARY_NATIVE_LIB_DIR="$CONTROL_PROBE/probe/build/linux/x64/profile/bundle/lib" "$CONTROL_FLUTTER/bin/flutter" test --no-pub --concurrency 1 --reporter expanded test/investigation_test.dart --plain-name 'A delete group=true gap=20ms'
```

Other focused selectors are `B scalar paste insert`,
`C scalar plain-controller snapshot control`, `D mounted-CRLF join`, and
`E widget readOnly rebuild current-client input delta`. The one JSON diagnostic
line identifies the operation payload, ranges, relevant pending/rope state and
desired versus actual result. Source-level causes and expected outcomes are in
the single experiment evidence table. The separate `correctness.patch` is ready
for review with those cases; it is not an upstream submission or production fix.

The narrow `code-editor-probe` workflow runs only the explicit baseline reproduction
and uploads logs, never redistribution-unready binaries/fonts. It does not impose
the full matrix on ordinary CI. Existing workflow concurrency policy is retained;
Flutter work within one build directory is serial. SDK-only driver/settlement and
launcher tests are discovered by the maintained target, without Rust/network:

```sh
env FLUTTER_ROOT="$ADELE_FLUTTER" "$ADELE_FLUTTER/bin/cache/dart-sdk/bin/dart" tools/adele.dart test --target adele_tools --ci
```

Neither route compiles an EVC. The production native owner/access bridge and later
Main Content/Source Editor work remain outside this investigation.

## Live tests

Live tests are explicitly opt-in and may incur API charges or consume subscription
usage. Run them deliberately, not as routine validation. Each gate below must be
exactly `1`. Credentials alone do not enable a test; an enabled test with missing
required credentials fails rather than silently skipping.

Normal CI discovers but skips these network cases because it supplies neither
gates nor credentials. Keep gates unset for normal local validation too:
`--ci` does not scrub inherited environment variables or disable live calls.

| App case | Enable variable | Provider / purpose |
| --- | --- | --- |
| [`openai_source_coding_live_test.dart`](../../app/test/development/agent/openai_source_coding_live_test.dart) | `ADELE_OPENAI_SOURCE_CODING_LIVE_TEST` | API key; search/read and continuation. |
| [`openai_source_mutation_live_test.dart`](../../app/test/development/agent/openai_source_mutation_live_test.dart) | `ADELE_OPENAI_SOURCE_MUTATION_LIVE_TEST` | API key; read/patch and continuation. |
| API-key case in [`openai_source_validation_live_test.dart`](../../app/test/development/agent/openai_source_validation_live_test.dart) | `ADELE_OPENAI_SOURCE_VALIDATION_LIVE_TEST` | API key; read/patch/direct-argv validation. |
| [`chatgpt_source_coding_live_test.dart`](../../app/test/development/agent/chatgpt_source_coding_live_test.dart) | `ADELE_OPENAI_CHATGPT_LIVE_TEST` | ChatGPT; search/read and continuation. |
| ChatGPT case in [`openai_source_validation_live_test.dart`](../../app/test/development/agent/openai_source_validation_live_test.dart) | `ADELE_OPENAI_CHATGPT_SOURCE_VALIDATION_LIVE_TEST` | ChatGPT; read/patch/direct-argv validation. |

The app API-key cases require nonblank `OPENAI_API_KEY` and
`ADELE_OPENAI_TEST_MODEL`. They explicitly use the public Responses endpoint,
overriding inherited `ADELE_OPENAI_ENDPOINT`. App ChatGPT cases require
`ADELE_OPENAI_CHATGPT_CREDENTIAL_FILE` and use `ADELE_OPENAI_CHATGPT_TEST_MODEL`
(missing/blank defaults to `gpt-6-astra`), not the normal desktop's
`ADELE_OPENAI_CHATGPT_MODEL`. Credential/OAuth/endpoint semantics belong to the
[OpenAI backend](../../plugins/openai/packages/backend/README.md) and its
[startup configuration](../../plugins/openai/packages/backend/bin/openai_model_provider_backend.dart).

The command-validation cases require Linux x64 process support and executable
`/usr/bin/setsid` or `/bin/setsid`; their gates do not automatically skip unsupported
platforms. Both currently have a stale ordered tool-catalog assertion before
provider activation in `_runSourceValidation`. The topology registers Command,
Search, then Filesystem tools, but the assertion expects Filesystem tools first.
This is a known test blocker, not a claim of live success or a provider failure.

Provider-only live smokes belong to the
[OpenAI backend](../../plugins/openai/packages/backend/README.md#validation-scope):
`ADELE_OPENAI_LIVE_TEST=1` enables its API-key smoke, while
`ADELE_OPENAI_CHATGPT_LIVE_TEST=1` enables its ChatGPT continuation case. The latter
gate is shared with app source coding: running both suites with it set enables
both network cases. Consult the backend's
[API-key test](../../plugins/openai/packages/backend/test/openai_live_test.dart)
and [ChatGPT test](../../plugins/openai/packages/backend/test/openai_chatgpt_live_test.dart)
for their exact configuration; these are separate from the app full-stack cases
and from a deliberate [self-hosting runner invocation](self-hosting.md).
