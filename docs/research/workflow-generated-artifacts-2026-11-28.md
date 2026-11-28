# Can CI share generated contract sources?

Role: Dated, non-normative CI investigation. Base: [`042d69d6d30abd4230cb6336772b094c6d2f7056`](https://github.com/eric1234/adele/commit/042d69d6d30abd4230cb6336772b094c6d2f7056), tree `98a14416085cb4398a73fded5e0e5eb096504eeb`, after [#287](https://github.com/eric1234/adele/pull/287).

**Recommendation: keep generation local to each matrix runner.** The [hosted trial](https://github.com/eric1234/adele/actions/runs/46168075889) worked: 79 verified consumers, no fallbacks, 24 byte-identical parts, and 16.28 fewer occupied runner-minutes than exact base. But even the better producer delayed eligibility by about 35 s of new work. The run reached green in **13:05**, versus **11:34** on exact main and **12:38** on its equivalent PR tree. That difference is not all attributable to the handoff. It is also not evidence that a new workflow dependency and verification boundary buy earlier green. Only this investigation is retained.

## What repeats now

The [original baseline](ci-performance-2026-11-26.md#1-generate-once-per-test-runner-before-adding-a-distributed-cache) included two generations per matrix job. That is **not** the control today. `resolve-workspace` prepares both editor sources, runs `flutter pub get`, and lists the workspace. `test` validates shard discovery, prepares the sources, runs the source generator once with its default options, builds CodeForge when required, then holds the editor leases around the worker. The pre-bootstrap plan expands to 79 independent runners, seven with `nativeCodeEditor`. Neither the standalone analysis job nor the Linux profile build is a proposed consumer. The `generated` job independently bootstraps and runs the read-only `generate --check`.

This question concerns Git-ignored Dart source parts, not [compiled artifacts passed between suites](test-artifact-reuse-2026-11-27.md). [Desktop measurements](desktop-host-reuse-2026-11-28.md) and the [retirement decision](verified-aot-observations-2026-11-28.md) illustrate why avoiding invocations is not itself a result.

## Hosted control and placement model

Use the ordinary first attempts of [#847, PR #287](https://github.com/eric1234/adele/actions/runs/46164626297) and [#845, previous main](https://github.com/eric1234/adele/actions/runs/46152119793). #847 checked out merge `723675385c4e6254d3250866da91cf4c4c45875c` (same tree as the investigated main), **not** its PR head `49496aa`. #845 was before retirement, at `63b379f`. Each has 79 matrix jobs and six other jobs. Use the attempt-specific `jobs?per_page=100` API and timestamped `logs` ZIP. Time from workflow creation to last completed job, not the sum of durations. Occupied time sums `completed_at - started_at`, not queue time, CPU time, or billing.

| Observed, seconds unless marked | #847 | #845 |
|---|---:|---:|
| Workflow elapsed | 12:37 | 15:21 |
| Occupied runner-min, all / matrix | 195.12 / 181.37 | 197.93 / 184.63 |
| Creation to discovery complete | 31 | 32 |
| `generated` duration / completion since creation | 84 / 88 | 80 / 83 |
| Matrix admission after discovery, min / median / P90 / max | 3 / 332 / 510 / 540 | 2 / 302 / 478 / 516 |
| `generated` completion minus discovery completion | 57 | 51 |
| `generated` bootstrap write / independent check, near-isolated | 19.62 / 19.58 | 21.73 / 21.39 |
| First generation inside analyze / build bootstrap, near-isolated | 26.22 / 25.85 | 25.68 / 24.71 |
| Ordinary non-CodeForge generation marker to `START`, min / median / P90 / max | 14.64 / 21.67 / 25.62 / 31.62 | 15.34 / 21.77 / 26.06 / 27.88 |
| Seven CodeForge entries, same bracket, min-max | 38.07-47.26 | 29.05-50.32 |

`runContractCodegen` prints a start marker but no ordinary end marker. In a standalone step or before a directly following command the log brackets the real generator process closely, including VM startup and teardown. In matrix logs the next reliable marker is worker admission. In #847, 72 ordinary brackets sum to **1,584 s**, plus **293 s** in seven mixed brackets. Do not count the latter as generation: they include the native build and subsequent source lease/identity checks. For #845 exclude the old Git proof path as well. Flutter loading, package test hooks and test bodies occur *after* `START`. Dependency resolution, runner admission, SDK and OS installation are outside those brackets. Imputing the ordinary median for mixed entries and allowing 0.5 s per ordinary bracket for retained launcher work puts repeated generation at **about 28 runner-min**, not a measured 28-minute workflow speedup.

The critical worker is not necessarily the longest worker. In #847, tools occupied **586 s** (532 s worker), but the critical path was discovery 31 + Source Editor admission 534 + job 185 + aggregate gate tail 7 = **757 s**; Diff Viewer finished only 3 s earlier. In #845 the critical path was discovery 32 + tools admission 341 + job 543 + tail 5 = **921 s**.

**Counterfactual, not a trial.** For `generated`, retain its full bootstrap and independent check; the matrix needs both discovery and successful publication. For discovery, leave `test-plan --json` pre-bootstrap, then add bootstrap and publication to that job; retain `generated` in parallel. The latter costs one additional full generation but adds less time before the first admission. As a transfer calibration only, [the same repository's #287 smoke job](https://github.com/eric1234/adele/actions/runs/46164626291/job/141039315230) uploaded a different, 3,011-byte ZIP in 0.80 s from action start to finalization; two previous such steps also took 1 s at API precision. There was no existing hosted download step for these sources.

Model 3 s for pack and upload, 3 s per consumer for download and complete validation/restore. Keep the observed admission order, measured dispatch delays and 20 concurrent all-job slots; release each slot when its shortened job finishes. Hold unaffected jobs and gate tail fixed. Contrast a replay with **no** compression of the queue. Numbers below are #847 / #845, changes against the respective ordinary attempt; negative wall time means earlier green.

| Placement | Additional eligibility delay, s | Occupied minutes saved | Elapsed change, slot replay | Elapsed change, queue unchanged |
|---|---:|---:|---:|---:|
| `generated` | 60 / 54 | 24.27 / 24.32 | -7 / -15 s | +42 / +42 s |
| Discovery | 28 / 30 | 23.85 / 23.87 | -38 / -35 s | +10 / +18 s |

At 5 s producer and 10 s per consumer, the same slot replay predicts **14 / 6 s earlier** for discovery versus **18 / 13 s later** for `generated`. This is evidence for choosing discovery *if* there is an inexpensive, correct consumer path. It is not a guarantee of runner capacity or launch order.

**Exact-base cross-check:** [main #848](https://github.com/eric1234/adele/actions/runs/46166639229) was green in **11:34**, 191.05 occupied runner-min (178.97 matrix). Discovery finished at +23 s (20 s on runner); `generated` at +85 s (82 s on runner, 27 s bootstrap, 20 s check). Near-isolated write/check took 20.15/19.72 s. Admission after discovery was 2/233/478/504 s (min/median/P90/max); peak 20 jobs. The 72 ordinary intervals totaled 1,630.86 s (15.60/22.20/26.55/32.75 s), and the seven mixed intervals 277.58 s. The last shard-selection print to generation start, which includes the two pre-generation source checks, had median 0.54 s across 13 shards; the analogous 0.5 s post-generation allowance remains an estimate. With imputation the generation-only estimate is **1,746.75 s (29.11 runner-min)**. Resolution separately took 515 runner-seconds; workers spent 5,881 s between `START` and `PASS`. The longest job was [tools](https://github.com/eric1234/adele/actions/runs/46166639229/job/141045626976) (543 s); the last feeder was [Source Editor](https://github.com/eric1234/adele/actions/runs/46166639229/job/141045629417): 23 + 483 + 180 + 8 = 694 s. Git desktop finished 4 s earlier. With 3/3 s overhead the model saves 25.11/24.66 occupied minutes for generated/discovery, adds 65/30 s to eligibility and moves elapsed by -28/-57 s (slot replay) or +46/+11 s (queue unchanged).

## Transfer boundary

The generator reads the ordered `sources` in [`contract_codegen.yaml`](../../contract_codegen.yaml). Each authored `*.dart` produces its own sibling with the extension replaced by `.g.dart`. The following is a snapshot of the payload, not an additional configuration file:

```text
packages/core_extensions/lib/project_provider.g.dart
packages/core_extensions/lib/remote_command.g.dart
packages/environment/lib/adele_environment.g.dart
packages/model_provider/lib/adele_model_catalog.g.dart
packages/model_provider/lib/adele_model_provider.g.dart
packages/model_tool/lib/remote_model_tool.g.dart
packages/orchestration/lib/remote_inference_context.g.dart
packages/orchestration/lib/remote_orchestration.g.dart
packages/orchestration/lib/remote_run_model_preference.g.dart
packages/orchestration/lib/remote_tool_authorization.g.dart
packages/orchestration/lib/session_feedback.g.dart
packages/plugin_backend_support/lib/backend_local_state.g.dart
packages/plugin_backend_support/lib/capability_consumer.g.dart
packages/project_storage/lib/adele_project_storage.g.dart
plugins/agent_configuration/packages/contract/lib/agent_configuration_contract.g.dart
plugins/model_configuration/packages/contract/lib/model_configuration_contract.g.dart
plugins/chat_strategy/packages/contract/lib/chat_strategy_contract.g.dart
plugins/command_tools/packages/contract/lib/command_tools_contract.g.dart
plugins/diff_viewer/packages/contract/lib/diff_viewer_contract.g.dart
plugins/diff_viewer/packages/contract/lib/review_draft.g.dart
plugins/resource_inspector/packages/contract/lib/resource_inspector_contract.g.dart
plugins/scripted_model/packages/contract/lib/scripted_model_contract.g.dart
plugins/session_evaluator/packages/contract/lib/session_evaluator_contract.g.dart
plugins/workspace_demo/packages/contract/lib/workspace_demo_contract.g.dart
```

In particular, `generateEvalClient()` is not another sibling to publish. The analyzer overlays only the current source's native part; other generated libraries can be inputs. Never infer the payload by globbing for `*.g.dart`. A producer package configuration selects machine-local roots; the production incremental receipt contains checkout-local observations. Neither is portable. Editor ledgers, SDK/pub caches, installations, test state and all compiled artifacts stay with their owner.

## Local feasibility

Four detached Linux checkouts of the base, obtained with `git clone --no-local`, started without the ignored outputs. Each ran the maintained `resolve-workspace`, with `FLUTTER_ROOT` set to Flutter 3.38.10 framework `c6f67dede3d4aa1aa7a69dd56a3494a5cde6cc80`, engine `cafcda5721a78a7884db92f13c5e89f7643d52dd`, bundled Dart 3.10.9. The Flutter consumer used a separately located pub cache. This was a fresh **checkout**, not an SDK download benchmark. The 235 resolved packages comprised 153 hosted, four SDK and 78 checkout packages including the prepared path overrides. The raw package configuration digests differed; the normalized tables matched. Each checkout retained its own editor preparation identities.

| Local operation | Observed wall time |
|---|---:|
| Producer resolve; ordinary full `generate` on missing parts | 7.135 s; 32.676 s |
| Guarded producer: pre-identity / full generation / read-only check / post-identity | 0.186 / 37.424 / 35.614 / 0.201 s |
| Inventory read, SHA-256 and manifest / encode, gzip and write | 0.0024 / 0.0249 s |
| Small Dart consumer: verify inputs / decode and verify every output / stage, replace, read back and check clean | 0.200 / 0.0098 / 0.0154 s |
| Resolve to `START`, ordinary reference / restored checkout | **42.211 / 9.985 s** |
| `test --target scripted_model_contract --ci`, complete launcher, reference / restore | 41.810 / 20.685 s |

The reference and restored Dart workers passed the same 17 cases. The **32.226 s admission saving** includes independent local resolution in each arm; the smaller whole-command saving includes a slower restored worker concurrent with a native build. Neither is a hosted speedup. The Flutter consumer ran the original `adele_plugin_interactions --ci --shard 1` selection. It finished installation at 1.588 s and reached `START` at 24.082 s with a cold native editor build and unchanged leases. All 65 cases passed (three selected files; launcher 489.444 s). Flutter's own subsequent package loading/resolution is not generation.

The 24 restored and independently generated files matched byte-for-byte. The ordered `[path,length,SHA-256]` inventory digest (compact JSON) was `4e820abe91f5f2871c42856053b23b0d4169657da3c722ace2a38a690c44ada2`. They totaled **891,963 bytes**. None contained the tested checkout, home, SDK or pub-cache paths, `file://` URIs or common absolute machine prefixes. The prototype's versioned manifest was 4,257 bytes; its UTF-8 envelope was 925,148 bytes, **98,666 bytes gzip-6**. This was a local carrier size, not an Actions transfer observation.

The disposable driver compared actual Git commit and tree, clean index/worktree, configuration, full native options, exact source/part pairs, lock digest, graph and per-package resolution, actual selected SDK and workflow identity (simulated locally). It resolved each `rootUri` relative to the local package config, retained the root *class and relative location* within checkout, SDK or hosted cache as well as package name, library URI and language version, and rejected unknown roots. Merely dropping path-valued fields would confuse genuinely different resolutions. The checked tree covers the tracked CLI, generator, declarations, imports, options and editor recipes conservatively. Inspect before generation and again before publication; on the consumer inspect after local resolution. Plain `flutter pub get` is not a frozen-install guarantee: a changed tracked lockfile is an error here, not something to discard.

Local refusal tests covered another actual revision, staged and unstaged changes, changed declarations/config/lock, an untracked override, graph edges, package roots/URIs/language and nearer ignored package configs, wrong run/attempt/toolchain/options, malformed/oversized envelopes, duplicates, missing/extra/changed bytes, unsafe paths, and linked or non-file inputs/destinations. With the first destination deliberately missing, late rejection left the entire output inventory unchanged, including mtimes. A stale-attempt bundle through the launcher exited 1 without `START`. Valid repair succeeded, and an identical reinstall preserved mtimes.

An actual generator diagnostic on a changed declaration produced neither an envelope nor any part; packaging refused a missing or linked output. Injecting an I/O error on the second destination rename left a partial filesystem set, but the operation failed closed. There is no claim of atomic replacement across 24 directories: the guarantee is full validation before writing and no worker admission after any failed write or readback. Ordinary fresh generation or a complete verified reinstall repairs the workspace. A ZIP of just the 24 outputs with paths was 139,518 bytes (DEFLATE level 6); a prepared CodeForge `runner.lock` contained the checkout's absolute path and was not transferable.

**Trust limit:** this is an identity check for isolated ordinary CI on the same repository/workflow/run/attempt and actual checkout, not a remote build cache. It assumes the Actions service, checkout, pinned SDK and resolved hosted package contents, maintained preparers and producer are trusted, with no other writer in the workspace. In #847 the observed SDK cache key included the full framework revision; the pub key additionally included the lock hash. A lockfile and normalized package graph are not independent authentication of installed dependency bytes. Nor can a manifest authenticate payloads against a producer that can replace both. A client with mutable SDK/package installations or concurrent source writers is outside the boundary; it must use its own authoritative generation. Do not try to enlarge this boundary by porting the production receipt, watching ancestors or reconstructing a per-file provenance service.

## Trial design

The local and placement gates justified one ordinary PR attempt using discovery. The [trial implementation](https://github.com/eric1234/adele/tree/2cbe5c2e2cc1a0b02a8f7d4389e1456e7ec447e9) ran the plan first, resolved locally, required absent siblings, ran full configured generation, rechecked producer inputs and only then published. Actions compressed one versioned UTF-8 JSON file, not an inner gzip or directory of arbitrary paths. Each matrix job downloaded the **raw** single-artifact ZIP for the exact run and attempt into runner temp. The helper validated its entry, complete manifest, local identity, expected targets and bytes before replacing any files. No archive extraction over the checkout, `continue-on-error`, general skip flag, persistent cache or cross-workflow search.

An initial-attempt missing artifact, failed producer or transfer, mismatch, corruption or failed readback was an error. The aggregate gate still required discovery and matrix success. Reruns (including isolated consumer retries) deliberately used ordinary full generation without requesting an older artifact; if discovery itself reran it still had to prepare and publish successfully. Manual dispatch retained its ordinary path. Exercising the actual workflow shell locally with command stand-ins confirmed: retry/dispatch made no download request and forwarded the original selected test/shard arguments; a failed initial lookup exited nonzero; a first-attempt delivery passed the explicit filename only to the launcher. No hosted fault injection or rerun for benchmarking.

## Hosted result and decision

[Trial #849](https://github.com/eric1234/adele/actions/runs/46168075889), attempt 1 on [PR #288](https://github.com/eric1234/adele/pull/288), tested synthetic merge `461ab6fce97a6177c98a1abca581a0bc81ccfa45`, tree `23e00bf02cf08b07d6e5858d47c7fe99b64b206e`. All **85 jobs passed**. Every matrix launcher verified, restored and read back 24 parts: **79 consumers, zero fallbacks, 79 consumer generation calls avoided, 78 fewer full generation calls across the workflow** after counting the added discovery generation. Generation *inside* test fixtures, the independent generated gate, analysis and the Linux build remained real.

| Observed | Exact-base #848 | Same-tree PR #847 | Trial PR #849 |
|---|---:|---:|---:|
| Matrix eligibility after workflow creation, s | 23 | 31 | 71 |
| Post-eligibility admission, min / median / P90 / max, s | 2 / 233 / 478 / 504 | 3 / 332 / 510 / 540 | 3 / 212 / 420 / 459 |
| Matrix preparation through `START`, summed, s | 1,988.06 | 1,954.39 | 393.08 |
| Matrix `START` to `PASS`, summed, s | 5,881.32 | 6,126.95 | 6,322.78 |
| Occupied runner-min, matrix / entire CI | 178.97 / 191.05 | 181.37 / 195.12 | 161.13 / 174.77 |
| Longest job (tools), s | 543 | 586 | 661 |
| Creation to last job / CI green | 11:34 / 11:34 | 12:37 / 12:38 | 13:05 / 13:05 |

**Producer.** [Discovery](https://github.com/eric1234/adele/actions/runs/46168075889/job/141050023408) occupied 67 s. From preparation group start to upload group start: **33.546 s** including six offline regression tests (4.263 s), source/dependency resolution and workspace list, initial identity (0.251 s), actual full generation (22.470 s), final identity (0.193 s) and packaging (0.007 s). Upload group start to successful finalization: **1.422 s**, including 0.537 s transferring blob content. Total new serial work: **34.97 s**; the rest of the observed +48/+40 s eligibility difference includes different setup time. Service ZIP: **98,557 bytes**, from 924,362 bytes of versioned JSON. Retrieved as data and compared against independently generated local bytes: all 24 matched, not just their names or the ZIP checksum.

**Consumer.** From download group to test group, min/median/P90/max **0.673/1.156/2.672/3.390 s**, 113.28 s summed. Per-worker medians for local input identity, payload verification and installation/readback: **0.256/0.007/0.011 s**. The external launcher marker through final readback includes Python startup, median **0.315 s**, sum 24.80 s. Combined lookup/download and complete restore: **138.08 s** across 79 (median 1.488 s, P90 3.005 s). For the table, start the baseline preparation clock at the `Run test target` group and the trial clock at `Download generated contract sources`, both **after local resolution**; stop at the same target's `START`. All 79 comparisons improved, median saving **20.16 s** vs #848, **19.38 s** vs #847. The summed improvement was 26.58/26.02 runner-min; subtracting the new producer work gives **26.00/25.44 runner-min of net preparation interval saving**. These spans include retained source, lease and native work; they are not isolated generator CPU. The smaller actual savings in whole-workflow occupancy were **16.28/20.35 runner-min**.

**Coverage.** Compare the attempt log archives between launcher `START` and `PASS`, per job, as multisets rather than completion order. The 78 Dart/Flutter reporter summaries had **13,772 passes and 10 skips**, and the native Rust target **10 passes**, in both #848 and #849. The observed case headings, outcomes, skip diagnostics, multiplicities, and all 13 explicit shard file lists matched. The tools fixture's unterminated `generator stdout` precedes one heading on the same line; its generator marker *after* `START` is not a launcher fallback. Reporter headings are what Actions preserved, not the original in-memory Dart strings. Test files, eligibility conditions, native metadata, registry, recursive allocator and worker arguments were unchanged. The trial also passed pinned formatting, analysis, full tooling/generator targets, independent read-only generation check and profile build. Local validation included `generate --check`, `format --check`, fatal-infos launcher analysis, 155 routing/inventory tests, 83 launcher routing regressions and the maintained `contract_codegen` target.

**Critical path.** [Tools](https://github.com/eric1234/adele/actions/runs/46168075889/job/141050385109) set the finish in #849: 71 s discovery + 47 s to admit tools + 661 s job + 6 s aggregate tail = **785 s**. Its creation-relative start was +118 s versus +26/+90 s in #848/#847. Its preparation improved from 20.68/22.53 s to 3.34 s, but its *worker* took 619.53 s versus 493.35/532.43 s. Source Editor, the earlier critical job, actually finished 11/75 s earlier. Two smoke jobs shared runner capacity on the PR; they are not counted as CI occupancy. Neither the slower worker nor the full wall-time regression is demonstrably caused by the artifact.

Replaying **the trial's own launch order** with the same observed worker times, accounting for the two concurrent smoke runners, removing the 34.97 s producer extension and putting the corresponding baseline preparation back gives **791-797 s without handoff**. That is only **6-12 s of modeled benefit**, not an observed improvement. Holding admission lags fixed instead makes the no-handoff tools finish about **16-18 s earlier**. In both models the unconditional producer dependency costs more than one early worker saves. Actual runner order, future contention and which job will finish last are not predictable from one attempt.

**Do not enable either placement.** The transfer passed the correctness and aggregate-work gates; the latency and maintenance tradeoff did not. Waiting for `generated` would impose the larger dependency, not fix this one. Even the narrower discovery trial needed a 320-line verifier, 279 lines of new regression tests and a second language in the preparation path. Retiring that boundary is preferable to keeping a dormant option on every worker. Revisit if ordinary generation becomes substantially more expensive, or if the producer is already an unavoidable prerequisite with sufficient slack. **Do not pursue another shared preparation artifact now:** editor sources are tied to local verification and paths; native/AOT/EVC outputs have harder identity and distribution requirements. Profile an already-required local phase or a recurrent critical worker first, without adding a matrix-wide barrier. No benchmark-only workflows were dispatched.
