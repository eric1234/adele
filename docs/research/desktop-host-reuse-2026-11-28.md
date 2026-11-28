# Does verified host reuse pay for a desktop worker?

**Subsequent decision:** Desktop reuse was not adopted. The Git worker mechanism used as this experiment's starting point was also retired; see the [observation measurements and retirement decision](verified-aot-observations-2026-11-28.md).

**Keep desktop fresh.** In the strongest selection, reuse eliminated twelve of thirteen host compilations, delivered working private copies to thirteen suites, and preserved every reported case. But full preparation was slower in both warm comparisons. The results justify neither enabling reuse nor claiming a stable slowdown of the size observed.

This is a local experiment following [the inventory](test-artifact-reuse-2026-11-27.md) and [the verified Git implementation](https://github.com/eric1234/adele/pull/285). Exact base: [`516f06aa`](https://github.com/eric1234/adele/commit/516f06aae88319bca3514794459f7857d97971d9). Reproducible, **non-default** [pilot revision `40cabaa9`](https://github.com/eric1234/adele/commit/40cabaa9b709813a718c4123f2cf05498af9656d). The final policy enables no desktop suites; the pilot is identified here so it can be measured without keeping dormant branches in fixtures.

## What qualified

The actual recursive LPT partitions still contain 37/40/40/40 files. Ordinary Linux paths request 8/9/10/13 shared hosts; 8/8/8/13 are straightforward candidates, **not** four measured wins. Four of these sites already use Git-hosted test support. The three `development/agent/` suites `environment_read_agent_integration`, `openai_provider_integration` and `phase_iv_agent_integration` use parallel raw compilers and fixed, overwriteable outputs. Those paths, gated live compiles, synthetic backends, and all stock Git requests remain fresh. No list of suites or shard numbers controls execution.

| Desktop selection | Unscoped host builds / all AOTs (traced) | Host requests admitted in pilot runs | Final scoped requests / hits | Exact-base CI worker / full job / post-discovery admission, s |
|---|---:|---:|---:|---:|
| 1 | 8/29 | not trialled | 0/0 | 383/489/4 |
| 2 | 9/33 | not trialled | 0/0 | 252/328/3 |
| 3 | 10/34 | not trialled | 0/0 | 248/373/3 |
| 4 | 13/42 | 13 | 0/0 | 425/524/210 |

The first three counts are from complete exact-base runs; the fourth is from both warm fresh controls below. No paired timing or generation proof was needed for the three unadopted selections. On exact-base [CI #843](https://github.com/eric1234/adele/actions/runs/46091807231), 85 jobs occupied 12,128 runner-seconds; the aggregate gate ended 920 s after workflow creation. These are not compiler timings.

The pilot explicitly opted in the host preparation in these shard-4 suites (paths under `app/test`, suffix `_test.dart`):

- `core/{agent_catalog_integration,backend_capability_integration,conservative_tool_policy_integration,durable_chat_session_integration,environment_capability_integration,remote_model_tool_integration,remote_tool_authorization_integration,session_evaluator_integration}`
- `environment_terminal_integration`, `prepared_capability_integration`, `prepared_environment_capability_integration`, `project_opening`, `session_execution`

`prepared_capability_integration` and `prepared_environment_capability_integration` spell the entrypoint absolutely. They use the same pinned compiler, checkout cwd, package resolution and options as the relative path. Three independent builds (ordinary absolute, ordinary relative, scoped relative with explicit packages, depfile and restricted environment) produced identical whole-file SHA-256 `993c14714598eb760ea0a7271ab56a03e752cad262bdb7afa8717b280442bb4a` at basename `snapshot`. This tests the path spelling, not equality under different ELF debug basenames. The fresh control retained the original argv. The pilot used the existing coordinator, peer check, store and per-suite destinations; no compiler interception, shared installation or live runtime.

## Warm comparison

Same checkout, x86-64 Linux, pinned Flutter 3.38.10 / bundled Dart 3.10.9, Rust 1.93.0, unchanged workspace lock. A separate exact-base run and a full scoped warmup are excluded. The four timed runs used the original **complete** `test --target adele_desktop --ci --shard 4` command, serially, with no competing test target. All five reporter inventories (exact base and timed arms) matched on suite path, full case name, outcome, skip reason and multiplicity: **1,055 passed, one gated skip**, 40 suites. The exact-base JSON also matched [ordinary main CI #843](https://github.com/eric1234/adele/actions/runs/46091807231).

| Seconds unless noted, in run order | Fresh A1 | Scoped B1 | Scoped B2 | Fresh A2 |
|---|---:|---:|---:|---:|
| Successful AOT drivers / independent ELF producers | 42/42 | 30/30 | 30/30 | 42/42 |
| Host builds / verified hits | 13/0 | 1/12 | 1/12 | 13/0 |
| Host compiler wall | 27.751 | 2.533 | 2.690 | 23.254 |
| Other 29 compilers (4 Git, 25 other) | 62.365 | 81.429 | 87.335 | 67.722 |
| Authoritative generator subprocess | 25.378 | 44.310 | 46.643 | 45.770 |
| Full generation including proof creation | 25.378 | 45.201 | 47.586 | 45.770 |
| Scope creation, ms | 0 | 23.8 | 30.1 | 0 |
| Request inventory/fingerprint | 0 | 4.742 | 5.095 | 0 |
| Request generation-proof validation | 0 | 9.013 | 9.785 | 0 |
| Artifact validation/copy and residual filesystem work | 0 | 0.811 | 0.979 | 0 |
| Suite loading / setUpAll | 51.261/115.175 | 56.391/128.569 | 59.227/138.661 | 41.862/107.378 |
| Generation + scope + union of load/setup intervals | **191.814** | **230.184** | **245.504** | **195.010** |
| Including all other launcher prework | **194.885** | **234.483** | **249.930** | **199.660** |
| Flutter worker / whole command | 552.08/580.57 | 645.12/694.68 | 683.34/735.43 | 498.55/549.00 |
| User/system CPU s | 496.00/106.09 | 640.21/141.33 | 686.70/151.56 | 465.10/94.78 |
| Max process RSS, KiB (not summed) | 1,182,500 | 1,177,020 | 1,162,036 | 1,175,344 |

The host subprocess reduction saved **25.22/20.56 s** on adjacent pairs. The noncompiler request phases alone took **14.57/15.86 s** (queueing under 1 ms per run). Proof selection was already restricted to the host's twelve-package graph: no Diff Viewer-only witnesses, but seven configured generated sources still qualify. All 24 configured sources still undergo full semantic generation. Two observations per delivery plus one after the single compile mean **27** input and provenance checks. Compared with about 3.8 s over seven requests in #285, request provenance here took 9.0–9.8 s over thirteen; it is not a fixed admission cost. The subprocess includes semantic witness creation; its difference from full generation (0.89/0.94 s) is **not** the entire cost of the proof.

Full preparation including launcher prework **regressed 39.60/50.27 s**. Do not attribute the whole command delta to validation: even the 29 unaffected compilers took 19–20 s longer in the scoped arms, and the two fresh generations differed by 20.39 s. All warm runs used the same Flutter kernel path, one frontend server, 40 testers, identical loader delivery, and a warm CodeForge build (0.12–0.16 s, no `rustc` invocations). One-minute load samples at arm boundaries were 1.36–2.04. These checks do not control CPU frequency or guarantee identical OS scheduling; tracing also costs more when more hash subprocesses are launched. There is no measured net benefit to extrapolate to the lower-multiplicity shards or to hosted workflow latency.

## Reproduction

1. Use a checkout of the **pilot revision**, outside system temp. Set `FLUTTER_ROOT` to the real pinned SDK and prepend its `bin` to `PATH`. Run `dart tools/adele.dart bootstrap`; inspect `generatorVersion`, `flutterRoot`, and the lockfile. Use the normal pinned Rust and native editor preparation. Do not enable live tests. Use a clean exact-base checkout for the independent case comparison.
2. Let `cmd=(dart tools/adele.dart test --target adele_desktop --ci --shard 4)` in Bash. Run `"${cmd[@]}"` once to warm the full selection, then A/B/B/A on the same checkout. B runs `"${cmd[@]}"`; A runs `env DART_S7L_FRESH_CONTROL=1 "${cmd[@]}"`. This otherwise unused environment name deliberately trips the existing unknown-`DART_*` eligibility guard; it is **not** a maintained configuration flag. Verify absence/presence of proof and scope logs rather than inferring the arm. Don't introduce a Dart define, clear caches, or reuse a scope between runs.
3. For each arm place `/usr/bin/time -f 'wall=%e user=%U sys=%S maxrss=%M'` around the complete launcher and trace it and its children with `strace -f --seccomp-bpf -ttt -s 1024 -e trace=execve,execveat,exit_group -e status=successful -o TRACE`. Count only successful pinned SDK `dart compile aot-snapshot` execs with exit 0; match each canonical kernel source and its output dill to the successful `gen_snapshot --snapshot-kind=app-aot-elf --elf=OUTPUT` in that driver's lifetime. Do not count requests, executable lookups or Dart VM re-execs as compilations.
4. A temporary `flutter` on `PATH` can `exec` the real pinned `bin/flutter` with the original test argv plus `--file-reporter=json:ABSOLUTE_FILE` for the selected worker. Leave cwd, process group, native loader and runtime environment intact. Compare reporter multisets against the exact base, reconciling suite root registrations with non-lifecycle completions; include skipped names and text, not just totals. Use the union of hidden loading and group/root setup intervals, not case durations, for suite preparation. Request-phase timers are **inside** those intervals, not additive. Keep the independent read-only `generate --check`.

**Next experiment:** profile duplicate content reads and the cost of spawning hash processes at each observation before trying another consumer. The warm traces contained 50 `sha256sum` executions fresh versus 376 scoped. Measure a batched union of the compiler/provenance byte reads **within one observation**, retaining both independent pre/post membership and mutation checks and all read/output evidence. First separate process startup from byte hashing on a controlled host; do not memoize across deliveries or replace hashing with stat checks.
