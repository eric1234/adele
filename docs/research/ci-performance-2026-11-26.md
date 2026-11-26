# Where ADELE CI spends its time

Role: Non-normative performance investigation, 2026-11-26. Source snapshot: `1367bb502cf0de1b6c161bdb057271dd07e0b8a2`. The recommendations are not accepted architecture or current CI policy. The [desktop ownership appendix](ci-desktop-test-ownership-2026-11-26.md) is part of the report.

## Recommended priorities

**Work on desktop shard 2 and `adele_tools` first.** In 20 consecutive first attempts they were the last matrix job to finish 9 and 10 times respectively. Desktop shard 3 was last once. A fifth desktop shard or more workers in every test process is not the first experiment: four serial, better-balanced shards can move substantial work off shard 2 without another bootstrap. Tools has the opposite problem: almost all its long tail lives in *one* serial test file that mostly orchestrates fake compilers. Split by fixture responsibility before distributing it.

**For runner consumption, the highest-leverage shared work is repeated preparation.** Bootstrap and Flutter installation averaged **64.7 runner-minutes per workflow**, before the next generation in each target. A runner-minute saved here is not a minute off the critical path. Treat approximately five minutes as a guide: with unchanged desktop fixtures even a balanced four-way split still exceeds it; do not relax assertions, reduce transcript volume or skip freshness checks to reach it.

## Baseline and method

Queried `eric1234/adele`, workflow `ci.yaml`, [run 784](https://github.com/eric1234/adele/actions/runs/45264622748) through [803](https://github.com/eric1234/adele/actions/runs/45869197471), November 23-26, 2026, both pushes and PRs. Used attempt **1** throughout, not the latest partial rerun of 786. All 20 had 82 completed jobs (76 matrix entries); 17 attempts passed. Workflow/runner statistics include all outcomes. Per-target means and nearest-rank P90 below use successful **jobs**, even if a sibling failed. Window and units are explicit: the supplied earlier 20-run averages (15.4m, 14.8m, 10m, etc.) are consistent in priority but not identical to these unrounded timestamp measurements. Minute-rounded UI/billing values are not elapsed seconds.

To reproduce with read-only GitHub access, enumerate the fixed run numbers from `gh run list --repo eric1234/adele --workflow ci.yaml --created '2026-11-23..2026-11-26' --limit 100 --json databaseId,number`. For each ID use `gh api repos/eric1234/adele/actions/runs/ID/attempts/1`, its `jobs?per_page=100` endpoint and its `logs` archive (one timestamped text log per job, subject to Actions retention). Verify `total_count` or paginate. The source of phase boundaries is the [workflow](../../.github/workflows/ci.yaml), [bootstrap, test registry and launcher](../../tools/adele.dart) and [target runner](../../tools/test_runner.dart), not the Actions job display name alone.

| Measure | Result | Interpretation |
| --- | ---: | --- |
| Workflow elapsed: created to last job completed | mean **18m51s**, median 17m55s, P90 21m59s; range 15m37s-24m52s | Includes scheduling and gates; not sum of jobs. API `updated_at` averaged another second. |
| Sum of all jobs' `completed_at - started_at` | mean **220.4 runner-min**, range 209.2-229.1 | Occupied runner time, not CPU time, billing, or time in queue. Matrix alone: 207.3 runner-min. |
| Creation to discovery complete | median 32.5s, mean 36.6s | Matrix cannot start before this; discovery compute itself averaged <1s. |
| Matrix admission after discovery | median across runs of each run's median **4m32s**; median of within-run P90 **8m20s**; last admission typically **9m12s** | From discovery finish to each matrix `started_at`; job creation to start gives almost the same numbers. Not target setup. |
| Simultaneously running jobs | peak **20** in each of 20 attempts | Sweep half-open job intervals. Consistent with finite runner capacity; not proof of a plan quota, runner CPU count or a guarantee of launch order. |

### Job budget

Mean seconds unless noted. **SDK** = Install pinned Flutter; **OS** = apt desktop/PTY and Rust install steps where applicable; **boot** = bootstrap workspace; **pre** = start of the Run test target step to the launcher's `START test`; **worker** = `START` to `PASS` (process startup, Flutter/Dart compilation, hooks, fixtures, assertions and teardown). Checkout, verification, post-actions and small gaps explain the remainder. Build's last column of work is the profile-build step, not a test. Queue is excluded throughout.

| Job (successful n) | Elapsed min | P90 min | >10m | SDK s | OS s | Boot s | Pre s | Worker/build s |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| desktop 2 (20) | **14.82** | 16.80 | 20 | 21 | 34 | 28 | 44 | **754** |
| tools (20) | **14.14** | 17.27 | 18 | 20 | 0 | 27 | 23 | **771** |
| desktop 3 (20) | 9.29 | 11.02 | 6 | 22 | 52 | 27 | 42 | 407 |
| desktop 4 (19) | 7.67 | 10.12 | 2 | 21 | 56 | 28 | 44 | 303 |
| build-linux (19) | 7.60 | 8.65 | 0 | 21 | 42 | 29 | - | 356 |
| desktop 1 (20) | 7.33 | 8.45 | 0 | 19 | 36 | 29 | 43 | 306 |
| contract_codegen (20) | 6.21 | 7.23 | 0 | 21 | 0 | 28 | 23 | 293 |
| git_backend 1 (20) | 5.49 | 6.67 | 0 | 19 | 5 | 29 | 24 | 245 |
| git_backend 2-7 (20 each; range of shard statistics) | 4.40-5.34 | 5.22-6.40 | 0 | 18-21 | 6-7 | 27-29 | 22-24 | 174-236 |

A specific slow run illustrates the distinction. In [795](https://github.com/eric1234/adele/actions/runs/45679656469) tools waited **7m03s after discovery**, occupied a runner 17m17s, spent 16m22s in the target step and 15m55s in the worker. Desktop 2 waited **4s**, occupied a runner 15m42s and ran its worker 13m24s. Git 1's single file occupied a **5m48s worker**, in a 7m17s job, not a 5m48s job. Reordering matrix entries is at most a scheduling hint: across the 20 attempts, median job-created-to-start wait for tools was 3.5s, P90 4m38s, max 7m02s. `test-plan` already emits sharded targets first. `--jobs` controls local *target processes*, not Actions admission or workers inside a CI job.

### Preparation across the matrix

Hosted jobs start in separate `ubuntu-latest` checkouts. All 1,520 matrix logs had two successful cache restores (Flutter and pub); this is a **warm SDK/pub-cache, fresh workspace** baseline, not an all-cold SDK installation. Pin: Flutter 3.38.10 framework `c6f67de`, bundled Dart 3.10.9; Rust 1.93.0 only where declared. See [toolchain policy](../development/toolchain.md) and [maintained test policy](../development/testing.md).

| Envelope | Mean runner-min/workflow | What was measured |
| --- | ---: | --- |
| Install pinned Flutter | 27.29 | Across all 81 installations; restoring a cache still costs time. |
| Bootstrap workspace | 37.40 | All 79 bootstraps. Within the **76 matrix** bootstraps: ~2.17 min to pub (launcher + editor sources), 5.84 resolving, 0.05 listing, **27.89** first generation to next step. These are components, not additional costs. |
| Run test target | 130.18 | Matrix only. ~31.27 min from step entry to `START` (source verification, **second generation**, source leases and native CodeForge build if selected); ~98.85 min `START` to result. |
| Other work | includes 5.82 build, 2.13 analysis, 2.90 desktop apt, 2.69 Rust installation | Across all outcomes. Seconds-rounded Actions steps and timestamps need not add exactly to job time. |

The pre-worker generation marker to `START` averaged **22.4s** on the 71 entries without native editor compilation; this bracket includes verification after generation, not just analyzer CPU. Five entries (desktop x4 and Source Editor) build the native editor on independent runners. In each attempt **38-42 workers finished in under 10s**. For example, `adele_product` averaged 4.8s of actual worker in an 83.4s job. The potential for less repeated work is real even if a particular long job barely moves.

## Desktop: fix the distribution, then move coverage to its owner

**Measured.** [Desktop 2, run 802](https://github.com/eric1234/adele/actions/runs/45864576951/job/140064377451) charged about **206s** to `app/test/prepared_diff_git_integration_test.dart`, **166s** to `app/test/prepared_portable_git_integration_test.dart`, **60s** to `app/test/core/command_output_capture_integration_test.dart` (57s to its first T3a completion), and **38s** to `app/test/core/session_evaluator_integration_test.dart`. These four account for ~470s on one worker. The earlier estimates of 3m37s, 2m47s and 1m07s in [run 795](https://github.com/eric1234/adele/actions/runs/45679656469/job/139436738008) include the interval leading up to each file's first completion. For command capture that interval was 64.3s; only 2.8s separated its two completions. Neither span is an isolated file benchmark. Several other heavy suites exist, e.g. normal Chat ~92s and OpenAI record startup ~64s in 802 (Model Browser case interval ~29s).

**Replay, not a CI benchmark.** Trained duration hints on [800](https://github.com/eric1234/adele/actions/runs/45858839635) and [801](https://github.com/eric1234/adele/actions/runs/45861901832); predicted a different attempt [802](https://github.com/eric1234/adele/actions/runs/45864576951). The latter two tested the same tree, not independent samples of future source changes. In each serial worker charge each interval between timestamped completion/skip records to the *finishing path*. Hold out `START` to the first completion and last completion to `PASS` as residual. This includes file loads, fixture setup/teardown and possible reporter delay; it is not per-assertion timing. Mean the two training costs per path; for paths averaging >=20s use nearest 10s units, else default 1. Use the existing Git LPT allocator with stable path and shard-id ties, no discovery allowlist.

| Holdout, same 160 files and four one-worker jobs | Shard 1 | Shard 2 | Shard 3 | Shard 4 |
| --- | ---: | ---: | ---: | ---: |
| Current FNV file counts | 38 | 55 | 29 | 38 |
| Current charged work, seconds | 255 | 687 | 262 | 214 |
| Current actual `START`-`PASS`, seconds | 335 | **750** | 314 | 271 |
| Modeled LPT counts with 13 hints | 39 | 39 | 40 | 42 |
| Held-out charged work under LPT, seconds | 368 | 357 | 353 | 340 |
| With each old runner's unchanged residual, seconds | **448** | 421 | 404 | 397 |

That is **~5m off the slowest worker** in this replay, not five minutes off every workflow. The second holdout, green PR run 803, gave 777s actual vs 435s modeled with the same frozen hints (44% lower). It tested merge revision `44437781333efa9a251270217fa04f6cbc11f9dd`, the same tree later merged as `5932cadc9f64825b72470125126726ba6e878f77` in [#267](https://github.com/eric1234/adele/pull/267). That change updated Settings-related cases and stock publication assertions but not the workflow, shard allocator or desktop test file inventory. The ownership audit and local measurements remain pinned to `1367bb5`.

Real startup depends on which file loads first, artifacts on disk, runner and test order. Ideal charged-work floor at four workers in 802 was already ~355s, before starting Flutter or provisioning runners. Validate the peak on freshly scheduled CI jobs; keep one worker for heavy desktop and PTY/capture tests, the existing timeouts, activity deadlines, environment gates and full data volumes. Refit rather than transferring old weights by filename after moves.

For reproducibility the 13 hints, relative to `app/test/` with `_test.dart` omitted, were: `prepared_diff_git_integration` 24, `prepared_portable_git_integration` 19, `core/normal_chatgpt_run_integration` 14, `core/command_output_capture_integration` and `core/openai_record_startup_integration` 7 each, `record_settings_dialog` 5, `core/durable_chat_session_integration` and `core/session_evaluator_integration` 4 each, `core/model_preset_integration`, `prepared_console_host`, `prepared_environment_buffered_process_integration` and `record_credential_settings_dialog` 3 each, `prepared_environment_capability_integration` 2. Shard by paths actually discovered, not these thirteen filenames. For PR timings use the checked-out merge tree, not merely the PR head SHA.

### Ownership and discovery

Use the [exhaustive classification and proposed paths](ci-desktop-test-ownership-2026-11-26.md), including mixed files and non-entrypoint `part`s. Classify by the **assertion that would break**: desktop owns generic host mediation even when a real schema supplies data; a single plugin owns its observable behavior even when running through Flutter or real AOT; the interaction target owns cooperation of two or more implementations. The number of installations in setup is not the number of owners.

For example, the real Diff/Git review flow belongs in interactions, but the portable-Git file mixes actual stock interactions, portable Git backend services and synthetic host-admission fixtures. Moving either whole subtree based on imports would misclassify cases. Command output capture checks Command Tools and Session Evaluator (including the T3a limit/refusal, not only the E3 export) against a Git worktree; Local Directory supplies backing, not the export behavior. Preserve the genuine integrations, including retirement, durable reopen, and failure cases, when extracting them.

Keep `app/test/**` as core. Prefer existing `plugins/<owner>/packages/frontend/test/` for single-plugin host-backed frontend checks. For backend behavior requiring Flutter, keep the pure-Dart backend target pure; give a plugin-owned Flutter integration directory a maintained invocation as detailed in the appendix. Put cross-plugin cases under **`app/plugin_interactions_test/`** with independent target **`adele_plugin_interactions`** using `app/` as working directory. This avoids another public package, a dependency on an implementation or accidentally running the same file in both desktop targets. Test/support and app compiler helpers stay development-only. Preserve proper analysis and per-target native/PTY metadata, including new targets that no longer match the workflow's hard-coded target-name condition.

## Tools: split the file that occupies the worker

The case numbers and local benchmark commands in this section refer to the [original `backend_artifacts_test.dart` at `1367bb5`](https://github.com/eric1234/adele/blob/1367bb502cf0de1b6c161bdb057271dd07e0b8a2/test/tools/backend_artifacts_test.dart). For current commands, see [testing and validation](../development/testing.md).

`adele_tools` runs `dart test test/tools` with the Dart runner's default **file** concurrency. It is not the serial desktop policy. On [run 802, tools job](https://github.com/eric1234/adele/actions/runs/45864576951/job/140064377542) the worker was 689s. The 318 `backend_artifacts_test.dart` completions spanned **635s**, excluding the first case's setup; the other nine suites had all finished with **614s** of that file still to go. The ~14m39s span in [795](https://github.com/eric1234/adele/actions/runs/45679656469/job/139436738116) is plausible but not a stable isolated runtime.

**Which tests?** The following are disjoint completion-interval sums from that file in 802 and a second successful [tools job in 803](https://github.com/eric1234/adele/actions/runs/45869197471/job/140080152573). First row omits time before completion 1; other rows start at the previous row's last completion. Cases *within* this file are sequential, other files can overlap. Seconds measure elapsed lane occupancy, not exclusive CPU. Proposed basenames below would live under `test/tools/`; the IDs identify case order at the inspected revision, not a proposed test selector.

| Cases | Fixture responsibility / proposed suite | 802 s | 803 s |
| --- | --- | ---: | ---: |
| 1-25 | `desktop_tool_cache_test.dart`: warm tools, repair/failure, depfiles | 80 | 111 |
| 26-45 | `desktop_final_input_fence_test.dart`: mutations between discovery and use | 63 | 90 |
| 46-106 | `desktop_launcher_routing_test.dart`: CLI, generation, smoke and refusal before launch | 44 | 65 |
| 107-153 | `stock_installation_publication_test.dart`: catalog, entrypoints, schemas and isolation | 49 | 70 |
| 154-181 | `desktop_backend_compile_failure_test.dart`: per-backend failure matrix | 30 | 42 |
| 182-254 | `desktop_frontend_compile_failure_test.dart`: per-frontend failures and retained fallback rejection | **117** | **159** |
| 255-275 | `desktop_source_invalidation_test.dart`: owned and shared source changes | **104** | **143** |
| 276-291 | `desktop_identity_invalidation_test.dart`: toolchain and metadata changes | 60 | 83 |
| 292-318 | `desktop_publication_recovery_test.dart`: integrity, repair and overlapping processes | 87 | 119 |

No single timed interval between successive completions in 802 exceeded 7s. The largest were `tool-only packages/contract_codegen/lib/generator.dart change preserves plugin installations` (6.56s) and `startup configuration changes neither compile nor replace snapshots` (6.49s); the long stock-publication case itself took ~4.8s. The *repeated failure and invalidation paths* dominate, not the longest assertion block. Keep named per-descriptor/entrypoint cases: taking a single representative plugin could miss a real mapping error. Move reusable scaffolding into `test/tools/support/` without a `_test.dart` suffix. Separate catalog-only assertions that need published schemas from ones requiring full launcher admission; do not start a launcher to test a data-only declaration. Keep one genuine round trip at the owning layer for every different orchestration/failure contract.

### Local fixture measurements

Source `1367bb5`, Linux 6.8, Intel i5-1135G7 (4 cores/8 threads), 39 GiB, pinned Flutter and Dart with `FLUTTER_ROOT` and `PATH` set to the SDK. Fresh isolated worktree, existing SDK and user pub cache, no Rust build or cache purge. Maintained `dart tools/adele.dart bootstrap`: **44.37s**. Direct timings below exclude repository bootstrap; they are not forecasts for hosted runners.

| Probe | Elapsed result | What it isolates |
| --- | ---: | --- |
| `dart test --concurrency=1 test/tools/backend_artifacts_test.dart --plain-name 'test-plan runs pre-bootstrap'`, first then identical repeat | **7.82s / 2.42s** | First vs already-used test runner/package state. Each test still gets a fresh fixture; not OS-cold vs RAM-only. |
| Stopwatch around setup/teardown in a disposable instrumented copy, nine selected serial cases / 41.80s wall | first setup 449ms (195ms CodeForge, 100ms rich-editor fixture); later fresh roots 102-135ms, teardown 4-11ms | Copying/building fixture trees matters across 318 cases, but does not explain seconds per invocation by itself. |
| Real `tools/adele.dart` process in same synthetic fixture, first run / unchanged rerun | **3.747s / 2.176s** | Fake compiler invocations dropped 29 to zero. Launcher, generation/discovery protocols, input/output hashes, filesystem, leases, and child process startup still run. |
| Missing tool: cold / repair / unchanged; edited Git input: cold / edit / unchanged | 3.420 / 2.588 / 2.250s; 2.841 / 1.943 / 2.444s | Warming a synthetic fixture does not eliminate the second/third launcher. |
| Final native-header fence: seed / rejecting rerun; first backend failure vs late empty Diff frontend | 3.698 / 2.271s; 1.087 vs 2.292s | Later stages incur earlier work even when the expected outcome is refusal. Metadata-only case did no launcher run. |
| Neighbor `desktop_build_inputs_test.dart`, **real** AOT discovery worker | compile 7.614s; 2,962,032-byte snapshot; execution 24ms and validation 10ms in a small fixture | Do not attribute real compiler cost to the fake-SDK matrix. Keep the real worker and rejection proof. |
| Same neighbor, real bootstrapped 26-stage stock graph | in-process 2.322s; source worker 10.4s plus 236ms validation | Preserve real worker/coordinator equivalence, not just a fast fake inventory. |

`backend_artifacts_test.dart` launches the actual Dart CLI against temporary roots, fake executables and stubs. It does **not** repeatedly compile real stock Flutter EVC, backend AOT, or Rust. A separate `strace -f -e trace=execve` probe of the cold/unchanged pair counted **228/149 successful single-line execs**, including **90/86 real `sha256sum`** and **45/44 fixture `cc`**. A warm cache still performs native identity probes and hashes. These are counts, not CPU attribution; a warm 2.18s is not a measured hash cost. Prioritize fewer unnecessary full-fixture invocations, not a faster hash algorithm.

Seed immutable source/archive/SDK fixture inputs once per suite when keys and embedded paths permit. Copy into private writable roots, regenerate absolute-path metadata, preserve links, modes and timestamps where under test, and use fresh cache/ledger/outputs for miss, corruption and mutation tests. Never hardlink data that a test edits. Avoid creating both editor fixtures for a genuinely pre-bootstrap plan test. Combine setup only for identical baselines; keep ordered cold/edit/repair/warm sequences, no-launch assertions, independent corruptions, locks and concurrent-process gates. Fixture optimization should save *work*; a file split alone largely redistributes it.

**Worker pilot.** Two disposable suite wrappers registered four of the existing cases unchanged (cold/warm and late empty-EVC failure versus empty depfile and Git input rebuild). In the warm local environment two file workers took **9.88s**, one took **15.81s**, all four passed both ways. User+system CPU rose from 19.06s to 21.53s. This single pair in `-j2` then `-j1` order is a feasibility result, not a 38% prediction for the full target or an RSS bound. Start with a two-worker CI trial after decomposition; compare with the same files on one worker. If still >10m or memory/timeout regressions appear, compare **two independently admitted LPT jobs with one worker each** against one two-worker job. Do not both multiply shards and uncap workers. Another tools runner costs roughly 77s before/around its worker on the current baseline, plus queue effects.

For tools sharding, discover **`test/tools/**/*_test.dart`**, not all of root `test/`. `TestTarget.argumentsFor` currently appends selected paths after the existing `['test','test/tools']`: replace the positional directory with the explicit selection or the shard can also run the whole directory. Keep non-CI `--target adele_tools` one full logical target, update the focused commands/links and the registry/path assertions in `test/tools/adele_test.dart`. Do not move coverage into undiscovered helper files.

## Other opportunities, ranked by the cost they address

### 1. Generate once per test runner before adding a distributed cache

The first generation in 76 matrix jobs occupied **27.89 runner-min/workflow** (including step transition) across all 20 runs. This is the largest *duplicated* phase directly identified. Preserve ordinary `bootstrap` for IDEs and direct consumers. For CI jobs whose **next maintained command itself regenerates**, consider a resolve-only preparation (verify editor sources, `flutter pub get`, workspace listing), followed by the unchanged `test`/`analyze` generation and admission. Do not add a general `--skip-freshness` switch. This removes one semantic pass per job, not both. Keep the separate `generated` job's bootstrap and authoritative read-only `generate --check`; keep `check` ordering so a write cannot mask stale content. Test fresh checkout, restored cache, changed declarations, ignored outputs missing and failure-before-launch. A ~22s/job reduction would save roughly 28 aggregate minutes in the matrix, *before* any new orchestration overhead; it would not cut 28 minutes off an 18m51s workflow.

Only if this still dominates, trial one **same-workflow, same-attempt immutable artifact** for verified generated siblings. Bind an exact, confined path/digest inventory to the actual checked-out tree (including merge revision), resolved dependencies, generator and pinned SDK. Validate all inputs/outputs before consumption; reject mismatches and require normal fresh generation/check, never use a receipt as the proof of semantic correctness. Do not ship a producer's `.dart_tool`, package config, deployment paths, executable cache, or `freshness.json` to arbitrary jobs/PRs. Run 803's second-generation-to-admission bracket in 71 non-CodeForge jobs totaled 26.37 runner-min; this is an **upper bound**, not an expected additional saving. Making discovery wait for `generated` would have deferred matrix eligibility by **56s** there, plus transfer time. Measure both axes before adding that dependency.

### 2. Eliminate duplicate desktop setup; reuse bytes, not live fixtures

In `prepared_diff_git_integration_test.dart`, `setUp` constructs a real `_Fixture` (repo, host, Task and Environments); **12 Linux variants** then construct a replacement for feedback/custom source initialization. Select that initializer *before* creating the private fixture. Do not share a mutable repository. In `app/test/core/normal_chatgpt_run_integration_test.dart` two calls to `installTerminal` compile the same EVC and prepare the PTY helper: lazy-prepare immutable outputs once in that suite, like the Agent installation, copy to fresh installations. These are concrete duplicate operations, not measured wall savings.

At this revision **40/160 desktop files** reference the shared host source path, 15 on shard 2; 11 reference stock Git, 7 on shard 2. This is a source count, not 40 measured identical builds. Command capture and session evaluator share five actual AOT inputs (host, child, Git, Command, Evaluator). Many heavy suites already use `setUpAll`: in run 802 the Diff/Git file had 58 completions and ~189s *after* the first; portable Git had 79 and ~152s after the first. Even free compilation would not remove those case costs.

Profile one common AOT snapshot first. Key any reuse to **complete** transitive source/generated inputs, package config/resolution, SDK/runtime/compiler binary and arguments, OS/architecture and native/helper/bridge identities as relevant. Prefer within-job private immutable bytes first; atomic publish after non-empty/digest/mode validation, explicit miss/rebuild or failure, keys and outputs revalidated before use. Never reuse live processes, mutable catalogs, Git worktrees, PTYs, temp paths, SQLite state, generations or credentials. Distinguish actual stock artifacts from identically named fault/fixture builds. Preserve EVC compiler isolation (cached evaluator type state), per-case recovery/expiry and corruption tests, and an independent genuine fresh compilation path. Existing Linux checkout caches include path-sensitive identities: don't tar and restore `.adele` or all of `.dart_tool` as a CI fast path. Only expand reuse across jobs if validated restore is faster than the compile, including producer gate and download.

### 3. Reduce repeated work inside contract_codegen

The 6.21m average job has ~293s in its worker and already uses **four file workers in CI, two locally**. In [803's generator job](https://github.com/eric1234/adele/actions/runs/45869197471/job/140080152521), the worker took 279s for 324 tests. Three successive transport cases in the same file completed at 12.0, 11.8 and 11.8s intervals. `packages/contract_codegen/test/support/contract_generator_support.dart` creates a new package for each `runGeneratedFixture(runtimeContract(), runtimeTests(name))`. Ten cases generate/analyze the **same** schema and execute different branches. Build one fresh package, analyze it once, run all ten independently named behavioral assertions in it. This eliminates nine generations and **27 child process starts** (`pub get`, analyze, test), not nine times 12s of target wall. Keep distinct schema fixtures distinct. Do this before trying another shard or raising concurrency; uncapped local analyzer/VM failures are recorded in `9a611a7`.

In `packages/contract_codegen/test/incremental_generation_test.dart`, successive settling-cycle/failure cases occupied 24.0/18.3s of one worker lane in 803. A deterministic test generator using the **real input recorder** could exercise receipt retry/corruption bookkeeping without a full analyzer on every synthetic pass. It must not replace real transitive-import/generated-sibling checks, `incremental_contract_integration_test.dart`'s actual 24-output cloned inventory, warm no-generation proof, byte comparison and single edit, or `contract_codegen_cli_test.dart`'s forged-receipt vs independent `--check` and process-lock tests. Launcher routing/failure-before-consumer is tools coverage; semantic generation is generator coverage; real runtime transport is consumer coverage. A passing test at one layer is not a substitute for these three different contracts.

### 4. Linux build: measure cold component misses rather than deleting fences

Two successful cold-workspace profile jobs with cached SDKs: [803](https://github.com/eric1234/adele/actions/runs/45869197471/job/140079866334) and [801](https://github.com/eric1234/adele/actions/runs/45861901832/job/140054786820). Seconds from launcher stage timing, **nested**, not additive down the table:

| Stage | 803 | 801 |
| --- | ---: | ---: |
| Launcher total | 320.0 | 407.1 |
| Desktop plugin/tool preparation | 206.6 | 259.5 |
| Preparation tools | 26.2 | 32.7 |
| Incremental generation (0 current, 24 regenerated) | 15.1 | 18.0 |
| 14 host/backend AOT stages, summed | 25.2 | 32.9 |
| First frontend harness (Chat) | 73.1 | 95.4 |
| Other 11 frontend harnesses, summed | 60.1 | 71.9 |
| Final input revalidation | 3.1 | 4.0 |
| Subsequent Flutter profile build | 112.8 | 146.8 |

`tools/frontend_artifacts.dart::prepareDesktopFrontendArtifacts` runs 12 sequential `flutter test --no-pub --concurrency 1` compiler harnesses in `app/` on complete misses. Test one serial harness for the misses with **isolated compiler state**, preserving stage-specific keys, diagnostics and outputs. The 60-72s for the later eleven is a **ceiling including actual compilation**, not removable startup time. Do not parallelize Flutter/Cargo writers in the same build root. [802's build](https://github.com/eric1234/adele/actions/runs/45864576951/job/140063992963) failed on a downloaded SQLite native library digest mismatch; this is not evidence of a slow Chat assertion or a reason to disable integrity checks.

`tools/backend_artifacts.dart::_prepareDesktopPlugins` serially awaits AOT compilers. Two backend compiler workers could save **at most ~13-16s** on those measured stages at unchanged speeds. Retain one preparation lease, private outputs, deterministic identities/order, drain admitted workers on failure, and publish nothing on partial failure. Keep final graph rediscovery, pre-use tool checks and digest/stat/output validation: input mutation *during* compilation is a different failure from a damaged cached output. Historical matched warm runs in [#170](https://github.com/eric1234/adele/pull/170) and [#171](https://github.com/eric1234/adele/pull/171) already improved 38.53 to 28.57s and 21.0 to 19.4s respectively under their then-current inventories. Cold receipt construction was more expensive than full generation in #170. Do not extrapolate developer warm-build hits to a fresh hosted runner.

### 5. Git backend: split for flexibility, not as a claimed speedup

`plugins/git/packages/backend/test/git_portable_review_layer_safety_test.dart` is alone on 1/7. Run 795's worker took 348s; in 802 it took **236s** for 129 cases, with 231s between first and last completions. These are real Git CLI/temp repo/index comparisons, not AOT compiles. Suggested files in the **same directory**, classified on 802 completion intervals:

| Proposed file | Existing cases, preserve both directions | Cases | Lane s |
| --- | --- | ---: | ---: |
| `git_portable_review_layer_safety_test.dart` | identity and target rejection; request budgets | 63 | 99.5 |
| `git_portable_review_layer_staleness_test.dart` | stale state and late discovery | 32 | 45.4 |
| `git_portable_review_layer_outcomes_test.dart` | loss/external outcomes, duplicates, post-apply corruption | 34 | 86.2 |

Retain `@TestOn('linux')`, real per-case `TestRepo.create/close`, no retry/write assertions, and `support/git_portable_review_approval_support.dart`'s independent raw index, mode/OID/blob, HEAD/worktree and symlink oracles. Independent object reads per state snapshot might be batched after profiling; do not share mutable index/locks/spy logs. Other large suites in 802: portable new-file ~236s/150 cases, approval ~221s/131, unstaged snapshot ~208s/230, deletion safety ~171s/191. **Splitting only layer-safety did not improve a replay**: replace hint 19 with 12/5/10, keep all other Git weights and 7 jobs; predicted unit loads nearly equal but held-out peak charged time *rose* 254 to 267s in 802 and 265 to 293s in 803. Those figures even exclude extra suite startups. Don't increase Git shard count based on a single 5m48s worker. Recalibrate all heavy weights, compare multiple holdouts and only change the policy if an actual runner trial helps. Git is already near the soft target.

## Implementation slices and acceptance criteria

Estimates are relative effort, not commitments: **S** = contained test/tool change; **M** = multiple fixtures or registry/CI coordination; **L** = cross-owner migration or artifact protocol. Each row can be reviewed or reverted independently; ownership changes are worthwhile even if they save no time. Do not take all the parallelism options at once.

| Order | Slice | Expected benefit; principal risk | Accept or reject using |
| --- | --- | --- | --- |
| 1 (S) | Rebalance the existing four desktop shards with a small measured cost map, keeping worker=1. Update FNV/exclusivity-specific registry tests and documented policy, not the exact-once assertions. | Modeled ~5.0-5.7m off the slowest **worker** on two holdouts; possible drift, first-load cost changes. No added jobs. | Recursive union/disjointness, default cost, tie/order stability, nonempty partitions; full CI on same tree, unchanged case/skip counts and deadlines. |
| 2 (M) | Move tools fixtures into test support; extract the failure matrices, invalidation families, then remaining cohesive cases with no behavioral change. | Exposes the ~10-15m serial file tail to file scheduling. Extra loads and repeated suite setup may cost time. | Run each new file alone and the unchanged logical tools target. Map all parameterized cases and originals, verify fresh/repair/stale/failure paths. |
| 3 (S/M) | Trial `adele_tools` two file workers vs one on the same split; separately lighten fixture setup in measured families. Use cost-aware two-shard CI only if one runner fails the time/resource budget. | Local four-case pilot 15.81 to 9.88s, full-job gain unknown. CPU/I/O contention and extra bootstrap are real costs. | Compare interleaved repeated hosted runs, peak RSS, worker wall, timeouts, queue and runner minutes. Exercise lock/overlap gates repeatedly with no tolerance changes. |
| 4 (M) | Separate resolve-only CI prep from generating consumers; retain public bootstrap and generated/check gates. | Up to ~28 matrix runner-min (~22s/entry) before overhead; risk of missing generated code or checking repaired outputs. | Fresh, warm, stale/missing output and pre-launch failure fixtures, authoritative `generate --check`, matrix timing. No build fresh-check removal. |
| 5 (M, then per-owner M) | Register the disjoint interaction root with its first real case; migrate the single-plugin groups and interaction groups one vertical slice at a time as in the appendix. | Correct owners and smaller movable suites; **no inherent time saving**. Extra `setUpAll`, wrong cwd, missing PTY/native metadata, two runners writing same local `app/` outputs. | Before/after names/skips and side effects; `test-plan --json`, unsharded vs shard union; plugin targets, app analysis and production boundary checks. Refit costs on all receiving targets; shard interactions by duration only when measured. |
| 6 (S/M) | Remove double construction in Diff/Git and repeated Terminal preparation; separately batch identical codegen runtime fixtures. | Avoid 12 redundant real fixtures, a repeat Terminal build, nine generated packages. Time saved is not separately measured. | Actual Git/portable/no-write cases and unchanged UI/PTY behavior; all ten generated runtime branches, analysis and fresh semantic comparison. |
| 7 (M/L, gated) | Trial one within-job immutable AOT reuse; separately prototype serial frontends-on-miss and optionally backend pool=2 on build-linux. | Reduces repeated compilers, but only the <60-72s frontend overhead envelope and ~13-16s ideal backend saving are supported on these cold builds. Stale bytes, races or memory regressions could invalidate the trade. | Cold/warm/partial-miss/mutation/failure; compare stage and total profile build on same tree, plus packaged runtime smoke. Keep independent real compile and final freshness tests. |
| 8 (S/M, optional) | Reweight/split Git families; evaluate small-target grouping or a validated generated-artifact handoff only after measuring earlier slices. | More even work or fewer setup copies; current one-file Git split replay lost. Shared producer dependencies, gate semantics, admission and loss of isolation can outweigh gains. | Compare hosted workflow wall **and** runner-min, job P90 and failure diagnostics. Group only like-prerequisite small targets; retain every logical target, named result, failure propagation and independent selection. |

**What remains uncertain.** Hosted runner class/load, competing repository work, cache download variability, first Flutter/native compilation vs individual case CPU, and runner service admission policy were not controlled. No all-cold SDK download, billed-minute claim, peak process-tree RSS study, full optimization A/B, or five-minute SLA is implied. Runner ordering in YAML cannot guarantee priority. At the observed concurrency, even perfect packing of today's work has a throughput floor of about **11 minutes** (`220.4 / 20`) for the *workflow*, independent of the five-minute *job* aspiration. If capacity is the limiting factor after reducing work, verify the actual account/organization limit and concurrent workflows before paying for more runners or increasing fan-out.

For future comparisons, pin checkout/attempt, runner image and CPU/RAM, record restore hits, distinguish clean workspace vs same-checkout warm, and collect job/step times plus reporter start/done, suite-load/setup/teardown and compiler subprocess wall/CPU/RSS. Compare several interleaved baseline/candidate runs with the same cases, report medians, tails, admission, slowest job, wall, aggregate load and failures. Start with the isolated bottleneck; an expensive full suite is justified for final coverage/integration or contention validation, not for timing a single fixture operation.
