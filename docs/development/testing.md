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
| `bootstrap` | Prepares/verifies pinned CodeForge source before `flutter pub get`, verifies that `dart pub workspace list` succeeds, then materializes configured ignored native contract parts. No Rust compilation. |
| `format --check` | Checks repository Dart formatting without rewriting files; formatting differences fail. |
| `generate --check` | Verifies current local generated siblings without writing; missing or stale output fails. |
| `analyze` | Prepares/verifies CodeForge source, regenerates current contracts, then analyzes repository tools, tool tests, and maintained Dart/Flutter analysis targets with fatal infos. |
| `test` | Prepares/verifies CodeForge source and regenerates contracts before workers; selecting any target declaring `nativeCodeEditor` builds one shared pinned native editor test library and supplies the loader environment only to those targets. |
| `check` | Runs `generate --check`, then format check, then analysis, then tests, stopping between phases on failure. |

`check` does not bootstrap the workspace or run desktop builds/smokes. Its app test
phase does build the native editor test library. The initial generation check
deliberately exposes missing/stale local output before later analysis or testing
could regenerate it. See
[generated contract artifacts](toolchain.md#generated-contract-artifacts) for
generation inputs, ignored outputs, freshness, and cleanup semantics.

## Maintained test targets

`dart tools/adele.dart test` runs all maintained targets with bounded package-level
concurrency. The default is at most two concurrent target processes, reduced to
one on a single-processor host. This is separate from concurrency inside an
individual Dart/Flutter test process. Queued targets still run after another
target fails; the final summary reports failures.

For one maintained target, use `dart tools/adele.dart test --target <name>`
or `dart tools/adele.dart test --target=<name>`.
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
dependency requirements, native Code Editor requirements, and CI concurrency metadata. It can run before bootstrap
without resolving dependencies or generating artifacts. It is not automatic
discovery of every package containing tests.

| Test option | Meaning and constraints |
| --- | --- |
| `--jobs N` | Positive integer controlling concurrent target processes; `--jobs=N` also works. Cannot be combined with `--target`. An explicit value may exceed the default of two. |
| `--target NAME` | Runs exactly one named maintained target. Unknown names fail; `--target=NAME` also works, including with `--ci`. |
| `--ci` | Valid only with `--target`. Applies that target's CI runner arguments/concurrency policy. It is not a generic credential/environment scrub. |

The [CI workflow](../../.github/workflows/ci.yaml) consumes `test-plan --json` and
runs each matrix entry with `test --target NAME --ci` after independent bootstrap.
The local two-process default does not limit CI matrix parallelism.

Single-plugin interpreted frontend integration belongs to the owning frontend
package even when it uses the private desktop host as test infrastructure.
`chat_strategy_frontend`, `filesystem_tools_frontend`, `command_tools_frontend`,
`openai_frontend`, and `source_editor_frontend` run
that coverage independently with development-only host dependencies and shared
app-side compiler support. Generic desktop/native infrastructure and whole-product
multi-plugin integration remain in `adele_desktop`.

Single-plugin Apply Patch and Run Command rich/compact Inspection semantics live
in the [Filesystem frontend suite](../../plugins/filesystem_tools/packages/frontend/test/filesystem_tools_frontend_eval_test.dart)
and [Command Inspection suite](../../plugins/command_tools/packages/frontend/test/command_tools_inspection_frontend_eval_test.dart).
The Command target also discovers its existing output presentation suite.
[`app/test/tool_inspection_frontend_eval_test.dart`](../../app/test/tool_inspection_frontend_eval_test.dart)
retains mixed-plugin retirement/failure isolation and generic Session/Inspection
composition; generic activation rollback remains in
[`prepared_frontend_activation_test.dart`](../../app/test/prepared_frontend_activation_test.dart).
Focused commands after bootstrap/current generation:

```sh
# Repository root: single-plugin presentation semantics.
dart tools/adele.dart test --target filesystem_tools_frontend
dart tools/adele.dart test --target command_tools_frontend
# app/: mixed/generic composition.
flutter test --no-pub --concurrency 1 test/tool_inspection_frontend_eval_test.dart
```

The `adele_desktop` CI target runs Flutter test files with one worker. Its real-AOT
and prepared-EVC fixtures are compiler-heavy; concurrent files can consume the
unchanged activity timing and full-capture deadlines through resource contention.
Serial CI execution preserves those assertions, full transcript volumes, and all
test selection. The non-CI target retains Flutter's normal worker default.
The app and Source Editor targets require Rust 1.93.0 for their shared CodeForge
library; Source Editor does not require Linux desktop or PTY prerequisites.
Source-only bootstrap
and tooling tests do not. Follow [native preparation](toolchain.md#native-editor-preparation)
and use an explicit pinned `FLUTTER_ROOT`, not just a Dart executable selected by
a version-manager shim.

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
Direct editor tests also need the separately built native library and loader
environment described in [focused editor checks](#focused-editor-checks); a direct
Flutter test invocation does not perform that preparation.

## Application validation map

Select tests for the application boundary being changed. Paths in the table are
relative to `app/`; this is a testing map, not an application architecture map.

| Changed boundary | Representative app test paths |
| --- | --- |
| Zero-plugin runtime/shell | [`test/core/adele_runtime_test.dart`](../../app/test/core/adele_runtime_test.dart), [`test/application_test.dart`](../../app/test/application_test.dart) |
| Global Commands/Command Palette | [`test/command_palette_test.dart`](../../app/test/command_palette_test.dart), [`test/application_test.dart`](../../app/test/application_test.dart) (AppBar and fixed platform-shortcut dispatch across shell states, text-field focus restoration, modal isolation, repeat suppression, focus/search/keyboard/empty states, live conflicts and exact stale selection, safe failures, Session-only console toggling/navigation fencing, and application retirement); pure-Dart identity/resolution/admission belongs to the maintained `adele_core_extensions` target and [`commands_test.dart`](../../packages/core_extensions/test/commands_test.dart) |
| Context-free remote Commands | [`test/core/remote_command_integration_test.dart`](../../app/test/core/remote_command_integration_test.dart) (real shared-host/probe AOT, strict backend-ready metadata, local availability, exact route/generation, retirement and admitted completion, and backend-only prepared installation through the actual application palette before Project opening); generated client/dispatcher payload and completion tests belong to [`remote_command_test.dart`](../../packages/core_extensions/test/remote_command_test.dart) in `adele_core_extensions` |
| Context-free prepared frontend Commands | [`test/prepared_command_palette_test.dart`](../../app/test/prepared_command_palette_test.dart) (actual compiled EVC, normal frontend-only/no-presentation startup before Project opening, safe invocation failure, and live palette retirement/replacement); [`test/prepared_frontend_activation_test.dart`](../../app/test/prepared_frontend_activation_test.dart) covers operation validation, no-authority invocation/return shape, rollback, exact retirement and evaluator lifetime; the remote integration suite above proves native/backend/frontend coexistence. Strict descriptor parsing belongs to the maintained `plugin_runtime` catalog tests. |
| Contextual Console-action Commands | [`test/prepared_frontend_activation_test.dart`](../../app/test/prepared_frontend_activation_test.dart) (same-component target validation before publication); [`test/prepared_console_host_test.dart`](../../app/test/prepared_console_host_test.dart) (canonical authority, availability without EVC, shared creation/policy, safe warning, rollback, and asymmetric exact retirement); [`test/console_controller_test.dart`](../../app/test/console_controller_test.dart) (fresh post-reveal admission and owner/action pending state across context changes); stock palette/PTY evidence is in the Terminal case of [`test/core/normal_chatgpt_run_integration_test.dart`](../../app/test/core/normal_chatgpt_run_integration_test.dart). |
| Contextual Main Content input-action Commands | [`test/prepared_frontend_activation_test.dart`](../../app/test/prepared_frontend_activation_test.dart) (exact sibling targets and synchronous rollback); [`test/prepared_main_content_host_test.dart`](../../app/test/prepared_main_content_host_test.dart) (availability and asymmetric registration/replacement lifetime); [`test/main_content_controller_test.dart`](../../app/test/main_content_controller_test.dart) and [`test/main_content_host_test.dart`](../../app/test/main_content_host_test.dart) (exact action/current attachment, single input route, shared button/Command presentation, safe factory failure, and navigation). Stock Source EVC/no-read-before-submit belongs to the Source frontend target; normal global palette behavior belongs to the Source cases in the normal application suite. |
| Prepared backend/frontend bootstrap | [`test/core/application_plugin_bootstrap_test.dart`](../../app/test/core/application_plugin_bootstrap_test.dart), [`test/prepared_frontend_activation_test.dart`](../../app/test/prepared_frontend_activation_test.dart), [`test/prepared_frontend_failure_test.dart`](../../app/test/prepared_frontend_failure_test.dart) |
| Prepared cross-plugin callable Capabilities | [`test/prepared_capability_integration_test.dart`](../../app/test/prepared_capability_integration_test.dart) (frontend-only EVC, separately installed ready-advertised AOT providers, authoritative generated native/eval contract, normal catalog/bootstrap/Main Content path); [`test/capability_access_bridge_test.dart`](../../app/test/capability_access_bridge_test.dart) (default-deny grants, exact handles, retirement/admitted unary settlement, bounded retention, lazy streams and presentation fencing). Shared transport regressions remain in [`test/owning_backend_stream_bridge_test.dart`](../../app/test/owning_backend_stream_bridge_test.dart); descriptor validation belongs to `plugin_runtime`. |
| Prepared contextual Environment-read Capabilities | [`test/prepared_environment_capability_integration_test.dart`](../../app/test/prepared_environment_capability_integration_test.dart) (independent frontend-only EVC and backend-only AOT through normal catalog/Main Content hosting, generated value DTOs and actual reverse reads from canonical nonprimary Environments, separate declarations, navigation and concurrent presentation isolation); [`test/core/environment_capability_invocation_integration_test.dart`](../../app/test/core/environment_capability_invocation_integration_test.dart) adds native bridge handle bounds, release/retirement and the external synchronous grant-revocation hook. Run alongside the unchanged C1 unary/streaming, C2a selection, Main Content and frontend activation suites, not instead of them. Public request-only API belongs to `adele_ui`; strict descriptor/roundtrip tests belong to `plugin_runtime`. |
| Project/native picker bridge | [`test/project_opening_test.dart`](../../app/test/project_opening_test.dart), [`test/directory_picker_bridge_test.dart`](../../app/test/directory_picker_bridge_test.dart) |
| Native editor ownership | [`test/native_code_editor_test.dart`](../../app/test/native_code_editor_test.dart) (ordinary editing/undo, external controller lifetime, fixed read-only configuration, same-editor clipboard completion, and targeted small fixes) |
| Prepared editor bridge | [`test/code_editor_bridge_test.dart`](../../app/test/code_editor_bridge_test.dart) (actual prepared EVC, explicit text snapshots, generic revisions, scoped handle retirement, and independently owned text/undo) |
| Grouped Main Content ownership/layout | [`test/main_content_controller_test.dart`](../../app/test/main_content_controller_test.dart), [`test/main_content_host_test.dart`](../../app/test/main_content_host_test.dart), [`test/adele_shell_test.dart`](../../app/test/adele_shell_test.dart) (registered groups only, ordinary ordering including Chat, zero-pane geometry, contiguous groups, stable panes, equal individual widths/minima, local reveal/focus, departure/retirement, and canonical Session context independent of view availability) |
| Prepared Main Content/catalog composition | [`test/prepared_main_content_host_test.dart`](../../app/test/prepared_main_content_host_test.dart), [`test/main_content_editor_test.dart`](../../app/test/main_content_editor_test.dart), [`test/core/normal_chatgpt_run_integration_test.dart`](../../app/test/core/normal_chatgpt_run_integration_test.dart) (provider-free canonical Session/Environment context without grants, explicit per-pane services/native bindings, scoped operations, independent editor text/undo, and direct contributed Chat coexistence); see [focused commands](#focused-main-content-checks) |
| Source retained data/native owners and captured file authority | [`source_editor_frontend/test/source_editor_host_test.dart`](../../plugins/source_editor/packages/frontend/test/source_editor_host_test.dart), [`test/environment_text_files_test.dart`](../../app/test/environment_text_files_test.dart), [`test/environment_access_bridge_test.dart`](../../app/test/environment_access_bridge_test.dart) (actual Source EVC, explicit-operation recovery without same-capture retry/migration, unchanged expected revisions, finite Save/Close, hidden exit, denied grants, and structured failures); see [focused Source checks](#focused-source-checks) |
| Normal Source workflow and exit cancellation | Source cases in [`test/core/normal_chatgpt_run_integration_test.dart`](../../app/test/core/normal_chatgpt_run_integration_test.dart) (stock catalog/EVC and real Git worktrees, Session/Environment retention without Chat or Run, conditional Save/conflict/Close, and hidden unsaved exit cancellation without closing an active Run) |
| Native terminal emulator/view | [`test/native_terminal_surface_test.dart`](../../app/test/native_terminal_surface_test.dart) (real control parsing/styles/Unicode, hidden output, finite retention/geometry, local read-only copy/scroll, attachment, denied ambient clipboard, and explicit disposal) |
| Prepared terminal bridge | [`test/terminal_surface_bridge_test.dart`](../../app/test/terminal_surface_bridge_test.dart) (actual EVC compilation/mount, native input/focus/paste/mouse, resize/rebuild, scoped handles, retained-widget and pending-paste revocation, prepared failure/retirement, independent lifetimes, and bundled MIT notice) |
| Shared console contracts/state/chrome | [`test/console_controller_test.dart`](../../app/test/console_controller_test.dart), [`test/workbench_console_test.dart`](../../app/test/workbench_console_test.dart), plus [`adele_ui` console tests](../../packages/ui/test/console_test.dart) (independent contributions, selected-only default, lazy bounded LRU residency including the selected slot, exact interaction epochs, working-set departure, advisory confirmation, retirement, and bounded cleanup) |
| Prepared console/Session Environment authority | [`test/prepared_console_host_test.dart`](../../app/test/prepared_console_host_test.dart) (actual EVC action/content paths, canonical Session association rather than Task primary, captured creation scope, fresh view access, title/exit policy, and failure cleanup) |
| Native terminal lifecycle/title observation | [`test/native_terminal_surface_test.dart`](../../app/test/native_terminal_surface_test.dart), [`test/environment_terminal_owner_test.dart`](../../app/test/environment_terminal_owner_test.dart) (normalized title changes, hidden observation, lifecycle/cleanup evidence separate from output, and conservative pre-resource failure) |
| Task/Environment lifecycle | [`test/task_creation_test.dart`](../../app/test/task_creation_test.dart), [`test/core/product_lifecycle_test.dart`](../../app/test/core/product_lifecycle_test.dart) |
| Environment-eligible Capability selection | [`test/core/environment_capability_selection_test.dart`](../../app/test/core/environment_capability_selection_test.dart) (canonical nonprimary capture, sticky materialization/selection, exact binding retirement and replacement); [`test/core/environment_capability_integration_test.dart`](../../app/test/core/environment_capability_integration_test.dart) (real shared-host/backend AOT advertisements, shared-context instances, bootstrap rollback, gated canonical restore, generated calls without host authority). Association parsing and exact registration ownership belong to the maintained `adele_contract` and `plugin_runtime` targets; retain the C1 bridge/integration regressions above. |
| Contextual unary Capability admission | [`test/core/environment_capability_invocation_integration_test.dart`](../../app/test/core/environment_capability_invocation_integration_test.dart) (real shared-host/backend AOT, generated plugin-owned service and authorized reverse reads, canonical nonprimary authority, overlapping calls, payload/allowlist/generation isolation, grant expiry, failures and replacement). Router opt-in belongs to `adele_contract`; explicit operation-context lifetime to `adele_plugin_backend_support`; exact channel and individual registration revocation to `plugin_runtime`; wire forwarding and unchanged stream controls to `plugin_backend_host`. Run alongside the C2a, C1, and remote extension regressions, not instead of them. |
| Task Browser canonical projection/actions | [`test/window_task_browser_source_test.dart`](../../app/test/window_task_browser_source_test.dart) (immutable Session queries, Project/Task scope, canonical opening independent of frontend/backend availability, separate execution status/readiness, exact orchestration creation choices and label fallback, retirement, and opening without Environment materialization or Run start) |
| Task Browser bridge/view hosting | [`test/task_browser_bridge_test.dart`](../../app/test/task_browser_bridge_test.dart), [`test/task_browser_presentation_host_test.dart`](../../app/test/task_browser_presentation_host_test.dart) (safe action settlement, subscriptions/revocation, zero/one/many resolution, and retained factory state) |
| Prepared Task Browser activation | [`test/prepared_task_browser_host_test.dart`](../../app/test/prepared_task_browser_host_test.dart) (frontend-only activation, lazy source creation/disposal, exact retirement, and per-view bytecode/entrypoint failure) |
| Durable Project/Task/Environment records | [`test/core/project_database_test.dart`](../../app/test/core/project_database_test.dart), [`test/core/durable_project_lifecycle_test.dart`](../../app/test/core/durable_project_lifecycle_test.dart), [`test/core/durable_task_environment_lifecycle_test.dart`](../../app/test/core/durable_task_environment_lifecycle_test.dart), [`test/core/durable_task_git_integration_test.dart`](../../app/test/core/durable_task_git_integration_test.dart) (fresh runtime and whole-Project move, real SQLite/Git backends) |
| Durable Session identity/Environment association | [`test/core/durable_session_lifecycle_test.dart`](../../app/test/core/durable_session_lifecycle_test.dart), [`test/core/project_database_test.dart`](../../app/test/core/project_database_test.dart) (complete-graph validation, atomic creation, missing strategy/provider, and no volatile fallback) |
| Terminal Run schema/publication | [`test/core/project_database_test.dart`](../../app/test/core/project_database_test.dart), [`test/core/durable_session_lifecycle_test.dart`](../../app/test/core/durable_session_lifecycle_test.dart) (separate product/execution v1 owners, atomic record/activity retention, whole-graph publication, immutable lookup, and explicit volatile retention) |
| Terminal execution evidence | [`test/core/execution_evidence_test.dart`](../../app/test/core/execution_evidence_test.dart) (normalized schema, field-by-field public snapshot roundtrip, Run-local ordering/provenance validation, corruption rejection, and record/evidence rollback) |
| Terminal Run execution/restart | [`test/core/durable_run_lifecycle_test.dart`](../../app/test/core/durable_run_lifecycle_test.dart) (completed/failed fresh-runtime snapshot restore, unstarted/waiting close without invented outcomes, approval completion, SQLite and execution-plus-storage failures without retry, deferred mechanics draining, and no ID allocation or live execution/approval recreation) |
| Session-scoped plugin storage host | [`test/core/project_storage_host_test.dart`](../../app/test/core/project_storage_host_test.dart) (owner schema, Project routing, scalar/query bounds, atomic batches, explicit volatile distinction, and queued-entry revocation) |
| Durable Chat across real backend generations | [`test/core/durable_chat_session_integration_test.dart`](../../app/test/core/durable_chat_session_integration_test.dart) (conversation/configuration/plain-text draft, user-entry Run association, atomic draft submission, fresh-runtime reopen, and completed Run/activity retention despite Chat storage failure; real Local Directory/Git/Chat AOT backends and SQLite with a deterministic native model fixture, no paid provider) |
| Prepared Chat applicability/composer/history | [`chat_strategy_frontend/test/chat_frontend_eval_test.dart`](../../plugins/chat_strategy/packages/frontend/test/chat_frontend_eval_test.dart) (initializer strategy match without service acquisition, local service failure, plugin-owned layout, draft saves/submission/retry, latest-save deactivation settlement, recoverable failure/pending-Send refusal, stale snapshot protection, historical activity placement, and preserving live handles during refresh) |
| Contributed-pane services and departure settlement | [`test/session_presentation_lifecycle_bridge_test.dart`](../../app/test/session_presentation_lifecycle_bridge_test.dart), [`test/prepared_session_services_test.dart`](../../app/test/prepared_session_services_test.dart), [`test/prepared_main_content_host_test.dart`](../../app/test/prepared_main_content_host_test.dart) (exact service/affinity capture, per-pane hooks, async acceptance/failure/retry, no-hook behavior, retirement during settlement, and action revocation on unbind/reopen without closing execution) |
| Session execution/approval | [`test/session_execution_test.dart`](../../app/test/session_execution_test.dart), [`test/session_execution_bridge_test.dart`](../../app/test/session_execution_bridge_test.dart), [`test/core/approval_gated_tool_policy_test.dart`](../../app/test/core/approval_gated_tool_policy_test.dart) (passive retained-owner lookup, independent Session advancement, shared IDs, exact approval isolation, semantic readiness, and all-owner shutdown) |
| Orchestration/authority adapters | [`test/core/orchestration_host_test.dart`](../../app/test/core/orchestration_host_test.dart), [`test/core/orchestration_authority_test.dart`](../../app/test/core/orchestration_authority_test.dart), [`test/core/model_tool_host_test.dart`](../../app/test/core/model_tool_host_test.dart), [`test/core/remote_inference_context_integration_test.dart`](../../app/test/core/remote_inference_context_integration_test.dart) |
| Activity/Inspection | [`test/core/run_activity_projection_test.dart`](../../app/test/core/run_activity_projection_test.dart), [`test/inspection_host_test.dart`](../../app/test/inspection_host_test.dart), [`test/inspection_stack_test.dart`](../../app/test/inspection_stack_test.dart), [`openai_frontend/test/openai_activity_frontend_eval_test.dart`](../../plugins/openai/packages/frontend/test/openai_activity_frontend_eval_test.dart) |
| Scoped activity reacquisition | [`test/session_execution_activity_test.dart`](../../app/test/session_execution_activity_test.dart), [`test/session_execution_bridge_test.dart`](../../app/test/session_execution_bridge_test.dart) (live/waiting/preparing and historical Session validation, fresh read-only opaque handles, permanent old-view revocation, unchanged activity/Inspection paths, and no execution authority) |
| Prepared normal composition, no live model | [`test/core/normal_task_git_integration_test.dart`](../../app/test/core/normal_task_git_integration_test.dart), [`test/core/normal_chatgpt_run_integration_test.dart`](../../app/test/core/normal_chatgpt_run_integration_test.dart) (local fake Responses/credentials and picker; canonical Session opening with missing components or zero Main Content, ordinary Chat/editor coexistence, frontend retirement without Run closure, concurrent Session commands in separate Task worktrees through shared AOT hosting, warm Command Output switching and cold Session history return, browser running/attention status, live/terminal Chat/activity reentry, stale approval callbacks, delayed/failed draft settlement, Inspection clearing, and hidden-owner shutdown; not interactive native-picker proof) |
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

### Focused Command checks

After bootstrap/current generation, run from `app/` with the pinned SDK:

```sh
flutter test --no-pub --concurrency 1 test/command_search_test.dart test/command_palette_test.dart test/prepared_command_palette_test.dart test/application_test.dart test/adele_shell_test.dart
```

The pure-Dart search tests cover matching tiers, ordered label subsequences,
word/ID boundaries, deterministic ties and empty-query order, and long valid inputs.
Palette fixtures also exercise ranked keyboard navigation, disabled relevance,
registry reranking, and exact Tab-focus/selection/replacement identity. These files
are discovered by the existing unrestricted `adele_desktop` target.
The application fixtures cover the keyboard-to-Command boundary without adding a
backend or new integration harness. Platform variants verify modifier policy,
not physical macOS/Windows execution. The native editor and terminal suites also
exercise the production shell shortcut around focused real native views; terminal
cases include Kitty and modifyOtherKeys encoding, repeats/releases, and absence of
the shell scope. Run those files with the existing
[editor library prerequisites](#focused-editor-checks) and
[terminal checks](#focused-terminal-checks). Palette IME composition and Tab-focused
exact row identity remain in the palette suite; native IME behavior is unchanged.

### Focused Main Content checks

These commands map affected boundaries, not recorded test outcomes. After bootstrap
and current generation, select public API, catalog, and tooling targets from the
repository root:

```sh
dart tools/adele.dart test --target adele_ui
dart tools/adele.dart test --target plugin_runtime
dart tools/adele.dart test --target adele_orchestration
dart tools/adele.dart test --target adele_tools
```

The public cases live in
[`packages/ui/test/main_content_test.dart`](../../packages/ui/test/main_content_test.dart)
and [`session_bridge_test.dart`](../../packages/ui/test/session_bridge_test.dart);
descriptor validation remains in
[`prepared_plugin_catalog_test.dart`](../../packages/plugin_runtime/test/prepared_plugin_catalog_test.dart).
For focused host iteration from `app/`, serialize Flutter invocations sharing its
build directory:

```sh
flutter test --no-pub --concurrency 1 test/main_content_controller_test.dart test/main_content_host_test.dart test/adele_shell_test.dart test/inspection_stack_test.dart
flutter test --no-pub --concurrency 1 test/prepared_main_content_host_test.dart test/prepared_session_services_test.dart test/session_presentation_lifecycle_bridge_test.dart
flutter test --no-pub --concurrency 1 test/window_task_browser_source_test.dart test/session_execution_bridge_test.dart
(cd .. && dart tools/adele.dart test --target chat_strategy_frontend)
```

The controller/widget tests target registered groups without an injected strategy
pane, zero-pane layout, ordinary Chat ordering, exact retirement, and pane
identity across title/order/width changes, local scroll/focus, bounded geometry,
and failure isolation. Prepared-host tests use actual EVC through the generic
catalog/bootstrap path, including readiness and stale callback boundaries. Service
tests keep exact backend/installation/controller validation separate from renderer
selection. Chat's initializer uses only captured identities; applicability mismatch
must not acquire execution or backend services. Navigation checks distinguish
canonical `canOpen` from `executionAvailable` and retained status, and creation
choices from UI availability.

For native editor ownership and stock Chat integration, first run
`dart tools/adele.dart build-code-editor-tests` from the repository root and set
`FRB_DART_LOAD_EXTERNAL_LIBRARY_NATIVE_LIB_DIR` to the absolute directory it prints.
Then, from `app/`:

```sh
flutter test --no-pub --concurrency 1 test/main_content_editor_test.dart
flutter test --no-pub --concurrency 1 test/core/normal_chatgpt_run_integration_test.dart --plain-name 'normal catalog editor panes preserve the stock Chat draft and active Run'
flutter test --no-pub --concurrency 1 test/core/normal_chatgpt_run_integration_test.dart --name 'actual Task Browser opens retained|hidden installed Session|prepared Chat navigation'
```

The focused editor case checks independent EVC runtimes, native text/undo, and
stable view/controller identities across interpreted collection changes. The
normal application case installs the frontend-only synthetic fixture alongside the
stock catalog and launches actual `AdeleApplication`. The interpreted
[`main_content_frontend.dart`](../../app/test/fixtures/main_content_frontend.dart)
owns open/title/order/focus/remove requests; the shared
[`main_content_fixture.dart`](../../app/tool/main_content_fixture.dart) supplies
independent native editor bindings. Assertions compare retained Chat presentation,
composer, Session/Run, and editor identities before and during a gated local fake
Responses invocation. Neighbor operations must retain the actual Chat EVC, not a
native stand-in. The same suite maps retained opening with absent frontend,
absent backend, or no Main Content; per-pane draft settlement/retry; and frontend
retirement while core execution survives. The synthetic editors may release their
owners on Session departure; this is fixture policy, not the stock
[Source Document lifetime](../../plugins/source_editor/README.md#ownership).
These are test paths and intended assertions, not recorded passing
outcomes, live-model checks, or human desktop evidence.

The unrestricted maintained `adele_desktop` target discovers these app files
without new test-list wiring or a CI concurrency change. For application-wide
changes use `dart tools/adele.dart test --target adele_desktop --ci`, which also
prepares the native library/environment. Use the [editor checks](#focused-editor-checks)
for lower-level native/bridge changes and the
[manual grouped workspace](#manual-grouped-workspace) for interactive inspection.

### Focused Source checks

These are validation commands and ownership maps, not passing outcomes. After
bootstrap/current generation, select the affected public, policy, catalog, and
tooling targets from the repository root:

```sh
dart tools/adele.dart test --target source_editor_frontend
dart tools/adele.dart test --target adele_ui
dart tools/adele.dart test --target plugin_runtime
dart tools/adele.dart test --target adele_tools
```

The Source target runs both isolated pure-Dart policy cases in
[`source_documents_test.dart`](../../plugins/source_editor/packages/frontend/test/source_documents_test.dart)
and real prepared-EVC/native integration in
[`source_editor_host_test.dart`](../../plugins/source_editor/packages/frontend/test/source_editor_host_test.dart)
through Flutter, with native editor preparation handled by the maintained runner. Public resolver cases are in
[`display_source_file_test.dart`](../../packages/ui/test/display_source_file_test.dart).
Catalog checks own explicit permissions/actions/operations and hook validation;
tooling checks own workspace/analysis/test discovery, stock descriptor entrypoints,
frontend-only preparation, and the production app/plugin dependency boundary.
The Source host fixture mounts the window-local input coordinator and invokes the
stock semantic Command, proving no provider read before form submission and the
same normalized, deduplicated native editor flow in the captured Environment.
Normal-product Source coverage uses the actual global palette as well as the
existing button, including hidden availability outside a Session.

From `app/`, serialize Flutter invocations sharing build output. Authority and
generic action-chrome checks need no native editor library:

```sh
flutter test --no-pub --concurrency 1 test/environment_text_files_test.dart test/environment_access_bridge_test.dart test/main_content_controller_test.dart test/main_content_host_test.dart
```

For the app-owned whole-product Source workflow, first run `dart tools/adele.dart build-code-editor-tests`
from the repository root and set `FRB_DART_LOAD_EXTERNAL_LIBRARY_NATIVE_LIB_DIR`
to the absolute directory it prints. Then, from `app/`:

```sh
flutter test --no-pub --concurrency 1 test/core/normal_chatgpt_run_integration_test.dart --name 'normal Source Editor'
```

The focused host fixture compiles actual Source EVC and uses a deterministic
Environment provider with held/failing operations: Save snapshots and baseline
advancement, edits during a held write, navigation, stale callbacks, explicit Open
recovery after restore failure or retirement, later explicit Save with the last
acknowledged revision, conflicts, native owner release, and hidden exit snapshots
are separate boundaries. The capture and Environment bridge tests distinguish
sticky per-capture failure/exact binding from fresh-operation access, and cover
denied grants, complete DTOs, structured failures, and admitted acknowledgements
without automatic retry.
The normal application cases use prepared stock components and real Git AOT/file
replacement; their active-Run case uses local fake model responses, not paid/live
credentials. Provider encoding, confinement, one-MiB bound, and revision checks
belong to `git_environment_backend` and its
[`git_worktree_environment_provider_test.dart`](../../plugins/git_environment/packages/backend/test/git_worktree_environment_provider_test.dart).
App files are discovered by the existing `adele_desktop` target; no new CI
concurrency policy is needed. These checks do not establish human keyboard/IME,
profile packaging, or macOS/Windows acceptance. Follow the
[manual Source workflow](#manual-source-workflow) and preserve the
[native limitations](../../app/README.md#known-limitations).

### Focused editor checks

The current tests cover conventional CodeForge ownership and the thin EVC boundary,
not a custom input/cancellation policy. These are commands to run, not recorded
pass results. Bootstrap with the explicit pinned SDK and native prerequisites from
[toolchain policy](toolchain.md#native-editor-preparation). For the maintained
tooling and complete app target, run from the repository root:

```sh
dart tools/adele.dart test --target adele_tools --ci
dart tools/adele.dart test --target adele_desktop --ci
```

The unrestricted app target discovers the editor tests and prepares their native
library/environment automatically. Tooling coverage includes
[`code_editor_dependency_test.dart`](../../test/tools/code_editor_dependency_test.dart)
for source verification, explicit reprepare, and source leases, plus
[`code_editor_smoke_test.dart`](../../test/tools/code_editor_smoke_test.dart),
shared settlement and launcher/discovery checks using local fixtures rather than
real Rust compilation or a live provider.

For narrow app iteration, first run `dart tools/adele.dart build-code-editor-tests`
from the repository root. Set `FRB_DART_LOAD_EXTERNAL_LIBRARY_NATIVE_LIB_DIR` to the
absolute library directory it prints, then run from `app/`:

```sh
flutter test --no-pub --concurrency 1 test/native_code_editor_test.dart test/code_editor_bridge_test.dart
```

The bridge fixture compiles only public UI and Flutter against compile-only editor
declarations, writes EVC bytes, and mounts through
`PreparedFrontend.load/createPresentation`. It exercises native input rather than
exporting a controller or mutation API to EVC. Its explicit synchronous snapshot is
`{text, revision}`; notifications carry no text. Revision includes component
selection/layout invalidations and is not a content version. Retired handles fail
against their captured owner; ordinary native operations already admitted to that
editor are not cancelled by a new focus policy. Text/undo ownership is separate
from widget lifetime, without a cursor/scroll restoration promise. See the
[current limitations](../../app/README.md#known-limitations), especially composition
at departure; a text snapshot is not lossless file-saving evidence.

When shared presentation or dependency wiring changes, include the nearby terminal,
prepared-host, public UI, analysis, and generation checks as appropriate. From
`app/`, serialize Flutter invocations sharing its build directory:

```sh
flutter test --no-pub --concurrency 1 test/native_terminal_surface_test.dart test/terminal_surface_bridge_test.dart test/terminal_projection_bridge_test.dart
flutter test --no-pub --concurrency 1 test/prepared_frontend_activation_test.dart test/prepared_frontend_failure_test.dart
flutter analyze --no-pub --fatal-infos
```

From the repository root:

```sh
dart tools/adele.dart test --target adele_ui
dart tools/adele.dart analyze
dart tools/adele.dart generate --check
git diff --check
```

Select proportional checks rather than running both focused files and the full app
suite for every edit. Widget/evaluator coverage is not a packaged library-loading
check or human keyboard/IME proof; use the separate
[integrated smoke](#integrated-editor-smoke) for Linux profile packaging. No
macOS/Windows acceptance is implied.

#### Deferred selected composition reproduction

[`selected_composition_repro.dart`](../../app/tool/code_editor_smoke/selected_composition_repro.dart)
is an explicit investigation, outside normal `*_test.dart` discovery and editor
acceptance. After bootstrap with the pinned SDK, prepare the native library from
the repository root:

```sh
dart tools/adele.dart build-code-editor-tests
```

From `app/`, use the absolute library directory printed by that command:

```sh
env FRB_DART_LOAD_EXTERNAL_LIBRARY_NATIVE_LIB_DIR=/absolute/path/printed/by/build-code-editor-tests \
  flutter test --no-pub --concurrency 1 tool/code_editor_smoke/selected_composition_repro.dart
```

Replacing selected `a` in `ab` with composing `x` must finish as `xb`. The normal
completion control preserves that result; the two departure cases, blur/refocus
and unmount/remount, are known to fail with `b`, while undo restores `ab`. Keep the
correct `xb` assertions: these failures are deferred evidence, not accepted
behavior or a normal acceptance gate. No composition repair or cancel-on-blur
policy is implied. See the [retained findings](../experiments/codeforge-correctness.md).

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
(cd .. && dart tools/adele.dart test --target command_tools_frontend)
flutter test --no-pub --concurrency 1 test/tool_inspection_frontend_eval_test.dart test/tool_activity_inspection_bridge_test.dart test/inspection_host_test.dart
flutter test --no-pub --concurrency 1 test/terminal_projection_bridge_test.dart test/native_terminal_surface_test.dart test/terminal_surface_bridge_test.dart
flutter test --no-pub --concurrency 1 test/console_bridge_test.dart test/console_controller_test.dart test/prepared_console_host_test.dart test/workbench_console_test.dart
flutter test --no-pub --concurrency 1 test/core/normal_chatgpt_run_integration_test.dart
flutter test --no-pub --concurrency 1 test/core/command_output_capture_integration_test.dart
flutter test --no-pub --concurrency 1 test/core/remote_model_tool_host_test.dart test/core/remote_model_tool_integration_test.dart
flutter test --no-pub --concurrency 1 test/core/project_storage_host_test.dart test/core/project_database_test.dart test/core/product_lifecycle_test.dart
(cd .. && dart tools/adele.dart test --target chat_strategy_frontend)
flutter test --no-pub --concurrency 1 test/prepared_session_services_test.dart test/session_execution_bridge_test.dart
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
flutter test --no-pub --concurrency 1 test/prepared_frontend_activation_test.dart test/command_palette_test.dart test/prepared_command_palette_test.dart
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
Browser panel/toggle/actions), hidden New Terminal outside a Session, palette
creation from a collapsed console followed by `+` creation through the same stock
operation/numbering/Environment owners without a Run, independent shells,
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
flutter test --no-pub test/session_presentation_lifecycle_bridge_test.dart test/prepared_session_services_test.dart
(cd .. && dart tools/adele.dart test --target chat_strategy_frontend)
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
(cd .. && dart tools/adele.dart test --target chat_strategy_frontend)
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

### Integrated editor smoke

[`tools/code_editor_smoke.dart`](../../tools/code_editor_smoke.dart) builds the
**actual application package** in profile mode with
[`app/tool/code_editor_smoke/main.dart`](../../app/tool/code_editor_smoke/main.dart)
as its development entrypoint. It first compiles the public-UI fixture into EVC,
then packages `data/editor_frontend.evc` beside the app's native library. Runtime
loads those prepared bytes; it never compiles source or substitutes another editor.
The default mode is an isolated development surface, separate from normal product
startup. The same target's [workspace mode](#manual-grouped-workspace) instead
hosts prepared contributions alongside stock Chat in the actual application.

Use Linux x64, the pinned Flutter/Dart and Rust toolchains, ordinary Linux Flutter
desktop dependencies, `timeout`, `sha256sum`, and Xvfb (`xvfb-run`). After bootstrap,
run from the repository root with explicit SDK selection:

```sh
ADELE_FLUTTER=/absolute/path/to/flutter-3.38.10
env FLUTTER_ROOT="$ADELE_FLUTTER" "$ADELE_FLUTTER/bin/cache/dart-sdk/bin/dart" tools/adele.dart editor-smoke linux
```

The focused checks cover bundled `lib/libcode_forge.so` loading from
`/proc/self/maps`, native editing in a prepared EVC pane, generic notifications and
explicit snapshots, undo/redo, fixed read-only behavior, rendering, and text/undo
retention across fresh presentation mounts. They do not test strict content
versions, native callback cancellation, selection restoration, or distribution
clearance. Injected text-input messages and engine key records are not human OS
keyboard or IME tests.

The runner launches from a fresh working directory without loader overrides, then
temporarily removes the bundled library for a separate negative subprocess and
restores it afterward. Missing-library acceptance requires an actual initialization
failure, not a mapping failure after successful initialization, a timeout, signal,
or arbitrary nonzero exit. Shared settlement latches the first framework/platform
failure and rejects failure markers even if a completion marker was already
written. Logs, the native artifact hash, and `result.json` remain under
`app/build/code_editor_smoke/logs/`. The
[editor smoke workflow](../../.github/workflows/code-editor-smoke.yaml) invokes this
path and retains diagnostics.
These are expected checks, not a claim that the current profile run has passed.

#### Manual entrypoint

To prepare without running the automated positive/negative subprocesses, then
launch on the user's desktop, use the repository root:

```sh
env FLUTTER_ROOT="$ADELE_FLUTTER" "$ADELE_FLUTTER/bin/cache/dart-sdk/bin/dart" tools/adele.dart editor-smoke linux --prepare-only
env -C /tmp -u LD_LIBRARY_PATH -u LD_PRELOAD -u FRB_DART_LOAD_EXTERNAL_LIBRARY_NATIVE_LIB_DIR "$PWD/app/build/linux/x64/profile/bundle/adele_desktop" --interactive
```

`--prepare-only` builds the app and precompiles/packages EVC. This is a
source-checkout development target, not portable release packaging. The same
fixed-dark UI shows independent editable/read-only EVC panes, Snapshot/state
revision, synthetic clipboard, focus, unbind/rebind, and close controls; there is
no theme selector. Undo/redo use ordinary editor keyboard shortcuts.
Only synthetic in-memory content is used: no file opening/saving, diff, LSP, AI,
or network.
Do not run this preparation concurrently with other Flutter work sharing app build
output or with explicit dependency replacement.

1. Use **Focus editable**, type and delete a short ASCII sequence at a natural
   pace, then use Ctrl+Z/Ctrl+Y to check grouped undo/redo. Use **Snapshot** and
   inspect state revision; selection/layout changes may also advance revision.
2. Use **Copy synthetic emoji** or **Copy synthetic CRLF**, then **Focus editable**
   and paste. These replace the clipboard with U+1F600 or `a\r\nb` (actual CRLF).
   Use **Snapshot** after edits and undo to inspect the escaped text; distinguish
   `\r\n`, `\n`, and a stray `\r` rather than relying on rendering alone.
3. Use **Focus read-only**, select/copy text, and attempt typing, paste, and undo.
   Its text must remain unchanged. Switch panes and away from/back to the window;
   new typing should follow focus. Already admitted clipboard work may finish on
   its original editor.
4. Finish composition, use **Unbind editable**, then **Rebind editable** for a
   fresh presentation. Check retained text and undo, without expecting cursor or
   scroll restoration, then use **Dispose and close**. Consult the
   [known composition limitation](../../app/README.md#known-limitations) rather
   than treating departure during composition as a passed check.

Human validation of this integrated path is not established here. An automated
smoke result or `--prepare-only` build must not be reported as those human checks.

#### Manual grouped workspace

Reuse the same editor-smoke target rather than a separate development application.
With the pinned SDK and native prerequisites above, run from the repository root:

```sh
dart tools/adele.dart editor-smoke linux --workspace --prepare-only
env -C /tmp -u LD_LIBRARY_PATH -u LD_PRELOAD -u FRB_DART_LOAD_EXTERNAL_LIBRARY_NATIVE_LIB_DIR "$PWD/app/build/linux/x64/profile/bundle/adele_desktop" --workspace
```

Preparation uses the stock catalog/build path and adds the freshly compiled
frontend-only Main Content fixture to that development installation root. Launch
uses `AdeleApplication`, ordinary catalog discovery/registration, stock Task Browser
and directly contributed Chat, and the shared fixture's native bindings. No runtime
compilation or manual collection injection substitutes for the interpreted contribution. Model
execution is intentionally disabled in this workspace route; no credentials or
Run are needed. The synthetic editor text is in memory, but ordinary Project/Task
creation still uses the stock product lifecycle, so choose a disposable Git Project.

1. Open that Git Project, create a Task, and create a Chat Session. Confirm Chat
   and **Editor A** are visible, then enter an unsent Chat draft.
2. Use **Open B**, **Rename B**, and **Reverse editors** in A. Check equal
   individual pane widths and that Chat's draft and both editors' text remain
   intact through title/order changes. Type separately in A and B and use ordinary
   undo/redo to check their independent state.
3. Narrow the window until Main Content overflows. Use **Focus A** and **Focus B**
   to reveal/focus the chosen editor without scrolling the surrounding surfaces.
4. Finish composition, use **Remove B** or its close chrome, then **Open B** again.
   B is a fresh editor; A and Chat should remain unchanged. Use the Task breadcrumb
   to leave, then reopen the Session to inspect fresh attachment. Consult the
   [known native limitations](../../app/README.md#known-limitations) for composition
   at departure.

The fixture deliberately releases its in-memory editor owners on departure.
It does not establish a rule for Source Documents keyed by Environment and
resource path; see [stock Source ownership](../../plugins/source_editor/README.md#ownership)
and the separate normal Source workflow below.

For automated profile coverage, `dart tools/adele.dart editor-smoke linux
--workspace` runs the existing editor positive/negative checks and an additional
`--workspace-smoke` subprocess over a temporary Git Project, normal application
navigation, and pane operations. It also exercises stock Source Open, explicit
Save into the captured Environment, retention/undo across Task Browser departure,
and Close, emitting `ADELE_SOURCE_WORKSPACE_COMPLETE`. This is not human
keyboard/IME evidence. Neither
these commands nor `--prepare-only` assert that manual validation has been run.
Do not prepare or run concurrent Flutter jobs against the same app build output.

### Manual Source workflow

Use the normal application, not the synthetic editor-smoke fixture. With the
pinned SDK/native prerequisites and bootstrap complete, run from the repository root:

```sh
dart tools/adele.dart run linux
```

Use a disposable Git Project with an existing committed small UTF-8 text file.
ADELE creates a separate Task Environment worktree; identify that checkout with
`git -C /absolute/path/to/disposable-project worktree list` before inspecting or
externally editing files. All checks below target that disposable Task worktree,
not the original Project source or the ADELE development checkout. No model
credentials or Run are needed. **Complete IME composition before Save, blur,
navigation, Close, or exit**; snapshots do not promise pending composition text.

1. Open the disposable Project, create a Task and Session, then choose
   **Open Source...**. Enter the existing Environment-relative path and choose
   **Open**; dismiss the input with **Close input**. Open the same path again and
   check that it focuses the same document without replacing text/undo. Open a
   second file and use **Move left** / **Move right** to check local order.
2. Edit each document independently and use ordinary undo/redo. Choose **Save**
   explicitly and inspect the Task worktree's file/diff. Check that the original
   Project source is unchanged. Unsaved edits are not autosaved; if edits occur
   while a Save is pending, only its captured snapshot is saved and later edits
   must remain unsaved.
3. Leave unsaved text, return to Task Browser, then reopen the Session or another
   Session in the same Task Environment. Check retained text, undo, and order.
   Create another Task/Environment and open the same relative path there: it is a
   separate document. Returning to the first Environment must not replace it.
4. With local edits still open, change that exact Task-worktree file externally.
   Choose **Save** and inspect the conflict indication and retained local text;
   the external version must not be forcibly overwritten. Use **Close**, then
   **Cancel** to retain the document. Deliberately choose **Close** / **Discard**
   and reopen to read the external version. There is no automatic retry, reload,
   merge, or force-save recovery.
5. Close unchanged/saved documents without a discard prompt. Close all Source
   panes and check that **Open Source...** still works. Make an unsaved edit,
   navigate to another Environment or Task Browser, then request window exit.
   Choose **Cancel** in the aggregate discard prompt and return to the document:
   text/undo and further editing/Save must remain usable. Finally save or explicitly
   accept discard and exit. There is no Project-switch action to test.

This procedure records no human result. Retain the existing
[selected-composition and Unicode limitations](../../app/README.md#known-limitations);
Source does not repair them or promise cursor/viewport restoration. The stock
provider rejects oversized, invalid UTF-8, or unsupported files rather than opening
a truncated editable preview. No autosave, file watcher, new-file operation, or
durable document restoration is implied; broader UX direction remains unchanged.

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
