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
| Task/Environment lifecycle | [`test/task_creation_test.dart`](../../app/test/task_creation_test.dart), [`test/core/product_lifecycle_test.dart`](../../app/test/core/product_lifecycle_test.dart) |
| Durable Project/Task/Environment records | [`test/core/project_database_test.dart`](../../app/test/core/project_database_test.dart), [`test/core/durable_project_lifecycle_test.dart`](../../app/test/core/durable_project_lifecycle_test.dart), [`test/core/durable_task_environment_lifecycle_test.dart`](../../app/test/core/durable_task_environment_lifecycle_test.dart), [`test/core/durable_task_git_integration_test.dart`](../../app/test/core/durable_task_git_integration_test.dart) (fresh runtime and whole-Project move, real SQLite/Git backends) |
| Durable Session identity/Environment association | [`test/core/durable_session_lifecycle_test.dart`](../../app/test/core/durable_session_lifecycle_test.dart), [`test/core/project_database_test.dart`](../../app/test/core/project_database_test.dart) (complete-graph validation, atomic creation, missing strategy/provider, and no volatile fallback) |
| Session-scoped plugin storage host | [`test/core/project_storage_host_test.dart`](../../app/test/core/project_storage_host_test.dart) (owner schema, Project routing, scalar/query bounds, atomic batches, explicit volatile distinction, and queued-entry revocation) |
| Durable Chat across real backend generations | [`test/core/durable_chat_session_integration_test.dart`](../../app/test/core/durable_chat_session_integration_test.dart) (conversation/configuration/plain-text draft, atomic draft submission and fresh-runtime reopen; real Local Directory/Git/Chat AOT backends and SQLite with a deterministic native model fixture, no paid provider) |
| Prepared Chat composer | [`test/chat_frontend_eval_test.dart`](../../app/test/chat_frontend_eval_test.dart) (draft restoration, sequential/coalesced saves, save failure, flush-before-submit, accepted-entry scheduling retry, and stale snapshot protection) |
| Session presentation/execution/approval | [`test/session_presentation_host_test.dart`](../../app/test/session_presentation_host_test.dart), [`test/session_execution_test.dart`](../../app/test/session_execution_test.dart), [`test/core/approval_gated_tool_policy_test.dart`](../../app/test/core/approval_gated_tool_policy_test.dart) |
| Orchestration/authority adapters | [`test/core/orchestration_host_test.dart`](../../app/test/core/orchestration_host_test.dart), [`test/core/orchestration_authority_test.dart`](../../app/test/core/orchestration_authority_test.dart), [`test/core/model_tool_host_test.dart`](../../app/test/core/model_tool_host_test.dart), [`test/core/remote_inference_context_integration_test.dart`](../../app/test/core/remote_inference_context_integration_test.dart) |
| Activity/Inspection | [`test/core/run_activity_projection_test.dart`](../../app/test/core/run_activity_projection_test.dart), [`test/inspection_host_test.dart`](../../app/test/inspection_host_test.dart), [`test/inspection_stack_test.dart`](../../app/test/inspection_stack_test.dart), [`test/openai_activity_frontend_eval_test.dart`](../../app/test/openai_activity_frontend_eval_test.dart) |
| Prepared normal composition, no live model | [`test/core/normal_task_git_integration_test.dart`](../../app/test/core/normal_task_git_integration_test.dart), [`test/core/normal_chatgpt_run_integration_test.dart`](../../app/test/core/normal_chatgpt_run_integration_test.dart) (local fake Responses/credentials and picker) |
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
restart. The normal Chat test uses a local fake provider and exercises the prepared
composer-to-Run flow. Consult the test source
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
canonical-cache ordering, and explicit volatile behavior.
Draft cases include SQLite-trigger rollback of set/submission, unchanged entry
occurrence IDs after failure, mutation/execution fencing, and rejection before
persisting a draft that would exceed the existing full-row read bound. Contract
changes additionally require `dart tools/adele.dart test --target chat_strategy_contract`
and `dart tools/adele.dart generate --check`; eval preparation derives the current
wire shape from those same declarations, with no old-wire compatibility.

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
