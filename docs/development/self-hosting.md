# Developer Self-Hosting

Role: Current repository development procedure

ADELE's developer-only headless workflow asks the normal ADELE
runtime/plugin/execution stack to modify an isolated copy of ADELE itself and
retain evidence. It is developer infrastructure and an important self-hosting
proof/workflow, not the final product CLI, normal desktop application, a security
sandbox, or an automatic commit/push/PR system.

Current source/tests define behavior. The [application map](../../app/README.md)
owns local composition; this document owns the runner's usage, topology, and
retained-evidence procedure.

## Entrypoints

```text
app/bin/adele_self_host.dart (SDK-only launcher)
    -> generate current native contracts
    -> app/tool/self_hosting/cli.dart
    -> DevelopmentSelfHostingRunner
```

The [SDK-only launcher](../../app/bin/adele_self_host.dart) generates ignored native
contract siblings before compiling/loading the
[native CLI consumer](../../app/tool/self_hosting/cli.dart). This also happens
before launcher help or invalid-argument handling; help is not a read-only
generation bypass. Follow [toolchain policy](toolchain.md#generated-contract-artifacts)
for generation semantics rather than invoking the internal CLI to avoid preparation.

## Prerequisites

- Linux x64 and executable `/usr/bin/setsid` or `/bin/setsid`. The runner checks
  those locations, not `PATH`; general macOS/Windows support is not claimed.
- Git and a bootstrapped/resolved ADELE checkout using the
  [pinned toolchain](toolchain.md). The runner does not provision an SDK or perform
  workspace bootstrap.
- A clean launching checkout. The runner requires empty output from
  `git status --porcelain --untracked-files=all`: tracked changes and nonignored
  untracked files fail; ignored generated parts/caches are allowed. After AOT
  compilation it rechecks both cleanliness and the captured HEAD before cloning.
- Nonblank UTF-8 prompt/instruction files and a Task title. Keep input files
  outside the checkout or Git-ignored so they do not violate the clean-checkout
  requirement.
- Provider configuration for the selected preset below. The invocation is live
  and can incur API charges or consume subscription usage.
- A writable output root outside the launching checkout or Git-ignored inside it.
  Output-root validation resolves existing symlinks and rejects `..` components.
  The root may contain earlier runs; each invocation claims a fresh run directory.

These checks are not a hermetic build or security boundary. In particular, ignored
local files may still influence preparation. Process constraints and the limits
of source isolation belong to the [Git Environment](../../plugins/git_environment/README.md).

## Provider presets

`--profile chatgpt|api-key` selects a **runner provider preset**, not an ADELE
architectural [Profile](../architecture/profiles-and-configuration.md). The runner
explicitly resolves the selected provider without fallback.

### `chatgpt` (default)

Required: `ADELE_OPENAI_CHATGPT_CREDENTIAL_FILE`, referencing ADELE's credential
store for the configured instance. Use a private absolute path. A nonblank path
does not prove usable credentials; failure can occur on the first model invocation.
The runner does not perform browser login.

Optional model input: `ADELE_OPENAI_CHATGPT_TEST_MODEL`; missing/blank currently
defaults to `gpt-6-astra`. **`ADELE_OPENAI_CHATGPT_MODEL` does not select the
self-hosting model**; that variable belongs to normal desktop source-checkout
selection.

The preset forwards the backend's optional client ID, instance ID, OAuth issuer,
redirect URI, and ChatGPT endpoint configuration. Without a client ID it opts into
the experimental Codex client. It masks inherited API-key configuration by setting
`OPENAI_API_KEY` to an empty value. See the
[OpenAI backend](../../plugins/openai/packages/backend/README.md), its
[startup configuration](../../plugins/openai/packages/backend/bin/openai_model_provider_backend.dart),
and [credential/auth decision](../adr/0028-experimental-chatgpt-openai-configured-instance.md)
for credential format, login, overrides, and experimental support limits.

### `api-key`

Required: nonblank `OPENAI_API_KEY` and `ADELE_OPENAI_TEST_MODEL`; there is no
default model. Optional `ADELE_OPENAI_ENDPOINT` overrides the public Responses
endpoint. Credential and endpoint interpretation belongs to the same OpenAI
backend, not the runner.

Preset selection is not wholesale environment isolation. In particular, the
API-key preset does not clear inherited ChatGPT configuration; that configuration
can also be loaded or interfere with backend startup even though the runner
selects the API-key provider.

## Canonical invocation

From the repository root, after preparation and provider configuration:

```sh
dart run app/bin/adele_self_host.dart \
  --prompt-file /absolute/path/to/prompt.md \
  --instructions-file /absolute/path/to/instructions.md \
  --task-title "Implement the focused development task" \
  --max-model-invocations 40 \
  --output-dir .dart_tool/adele/self-hosting
```

All five shown options are required. `--max-model-invocations` must be a positive
integer; `40` is an example, not a default. Optionally add
`--profile chatgpt` or `--profile api-key`; omission selects `chatgpt`. Relative
file/output paths resolve from the caller's working directory. The parser accepts
separated or `--name=value` forms and rejects duplicate or unknown options.

## Execution topology

```text
launching clean ADELE checkout
    -> fresh self-hosting run directory
    -> fresh AOT host/plugin artifacts
    -> isolated clone of exact launching HEAD
    -> Project with explicitly known source
    -> Task + Git worktree Environment
    -> Chat Session
    -> ADELE Run through normal remote plugin/execution paths
    -> retained source + Run/Git evidence
```

[`DevelopmentSelfHostingArtifacts.compile`](../../app/tool/self_hosting/development_self_hosting.dart)
builds fresh host and backend snapshots from the launching checkout, not a cached
normal desktop installation. The Project clone checks out the captured HEAD
detached and removes its `origin`. Git Environment establishes a distinct Task
branch/worktree from that Project source. Only committed source is cloned: ignored
dependencies, generated parts, and caches are not copied. Task-local validation
may therefore need its own bootstrap/preparation.

`DevelopmentSelfHostingTopology` owns an `AdeleRuntime`, explicitly starts its host
and backends, and uses ordinary registries, product lifecycle, Session authority,
and execution adapters. Chat, context, tools, and model calls use maintained remote
backend paths, not special in-process coding semantics. This composition does not
use normal installation-catalog bootstrap, frontend/EVC composition, or the native
picker; its Project source URI is already known.

The runner uses an allow policy for validated tools, unlike the interactive
desktop's approval-gated mutation/process policy. Domain validation, revision
checks, and Session authority still apply, but there is no approval UI. Commands
use direct program/argument execution with Environment-relative working directories.
**Source/worktree isolation is not arbitrary-command sandboxing:** same-user
filesystem/network powers remain, and an explicitly invoked shell or Git command
can have effects outside the source layout. The runner itself does not commit,
push, open a PR, or apply changes back to the launching checkout; that is not an
enforced prohibition on model-issued commands.

## Retained evidence

Use the paths printed by the CLI and recorded in `manifest.json`; the Task
worktree directory name is provider-generated rather than a fixed `task/` path.

| Run-directory content | Purpose |
| --- | --- |
| `state/project/` | Detached clone of the launching HEAD. |
| Task worktree under `state/` | Retained Task source and agent changes, separate from Project source. |
| `manifest.json` | Source SHA, paths, product identities, Task branch/baseline, preset/model, input hashes, timings, and failure information. |
| `journal.json` | Captured Chat entries and Run/model/tool events. |
| `summary.json` | Structured execution, usage, tool, Git, and final-response summary. |
| `summary.md` | Human-readable evidence summary with a bounded final-response rendering; `summary.json` retains the full captured response. |
| `runner.log` | Runner messages and captured compilation diagnostics, not a complete backend-stderr log. |
| `git/` | Task/Project/launching-checkout status, patch/stat/whitespace-check evidence, changed paths, Git facts, and collection errors. |

Git evidence includes tracked changes against the Task baseline and nonignored
untracked files. Normal teardown closes runtime resources and removes transient
`.artifacts`, but retains source, worktrees, and evidence rather than automatically
deleting them. Caught setup/execution failures also attempt to retain available
state and reports. Do not expect a complete evidence bundle after every failure:
generation/usage errors can occur before a run directory exists, and filesystem
failures or forced termination can prevent report completion.

Inspect the evidence rather than treating runner success as proof that all
requested validation passed. Individual tool/command failures and whitespace-check
results are evidence, not automatically runner failure. The runner is not an
automatic validation or publication system.

Invocation-ceiling exhaustion fails the Run rather than reporting successful
partial completion. A completed Run alone is not sufficient for runner success:
ChatGPT requires at least one completed model settlement, with every completed
settlement reporting exactly the selected model. Missing/mismatched effective-model
evidence fails the runner; the API-key preset does not apply that check. Required
Git-evidence collection failures also make the runner fail.

Prompt/instruction files are not copied as standalone inputs; retain them
separately if needed for reproducibility. Their hashes are recorded, and the prompt
normally appears in Chat history. Evidence can contain source, tool arguments and
output, provider-native metadata, and errors; it is not globally secret-redacted.
Review it before sharing.

## Validation and source map

Deterministic validation and a live paid self-hosting invocation are different
activities. Select proportionate checks using [testing and validation](testing.md);
do not run the live workflow merely to validate its documentation.

| Boundary | Source/test anchors |
| --- | --- |
| Generation-before-CLI and launcher behavior | [`app/bin/adele_self_host.dart`](../../app/bin/adele_self_host.dart), [`test/tools/self_hosting_cli_test.dart`](../../test/tools/self_hosting_cli_test.dart) in `adele_tools`. |
| Options, preflight, run lifecycle | [`cli.dart`](../../app/tool/self_hosting/cli.dart), [`development_self_hosting_runner.dart`](../../app/tool/self_hosting/development_self_hosting_runner.dart). |
| Compiler, provider presets, clone, topology, execution | [`development_self_hosting.dart`](../../app/tool/self_hosting/development_self_hosting.dart). |
| Deterministic self-hosting behavior | [`development_self_hosting_test.dart`](../../app/test/development/agent/development_self_hosting_test.dart) in `adele_desktop`: presets, real AOT topology, limits, output constraints, and retained evidence. |
| Environment-read agent integration | [`environment_read_agent_integration_test.dart`](../../app/test/development/agent/environment_read_agent_integration_test.dart): authorized remote context/tools, source reads/mutations, and commands in distinct Task worktrees. |
| Reports and Git evidence | [`development_self_hosting_report.dart`](../../app/tool/self_hosting/development_self_hosting_report.dart), with deterministic coverage in `development_self_hosting_test.dart`. |
