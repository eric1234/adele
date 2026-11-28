# What does a verified AOT observation actually read?

**Subsequent decision: retire test AOT reuse, including in the Git worker.** Independent review accepted the compiler and validation savings below, but not the implementation and filesystem sensitivity they required for the measured end-to-end benefit. The hashing candidate at [the measured revision](https://github.com/eric1234/adele/tree/6f2866f9cace9f33ad42cbda43d8793f20024e96) was not adopted. The measurements and original recommendation below are historical; [maintained testing](../development/testing.md) uses fresh suite-owned compilation.

The candidate's [failed contract_codegen job](https://github.com/eric1234/adele/actions/runs/46156193223/job/141013380077) illustrates the sensitivity: 325 cases passed, but the test-only `TestGeneration.generate` fixture failed in `ProvenanceFiles.verify` on a changed `/home/runner` stamp. The log does not identify what changed the directory. This was not the worker's shared hash pass or a production incremental receipt; the [independent generated-files check](https://github.com/eric1234/adele/actions/runs/46156193223/job/141013270684) passed. The fixture was retired with its verifier; production freshness and mutation tests were retained.

**Keep a single content-hash pass inside each Git worker observation.** On this Linux x64 checkout it removed about 89 MB of duplicate reads per observation. A separate change to the size of the checksum batches also paid for itself. Together they cut complete observation time by 39–42%; this is not a 39–42% reduction in test preparation or CI latency.

Dated local evidence, 2026-11-28. Base [`63b379f`](https://github.com/eric1234/adele/commit/63b379f19e46e0cf6447f0c46440ea541454f4a0), including [#286](https://github.com/eric1234/adele/pull/286). The [original pilot](test-artifact-reuse-2026-11-27.md), [maintained Git comparison](https://github.com/eric1234/adele/pull/285), and [desktop experiment](desktop-host-reuse-2026-11-28.md) measured different fences. The maintained Git scope authorizes host and Git; the historical desktop policy authorized only host. Their proofs are not interchangeable.

## Reads at one observation

Fresh full generation for each policy, actual VM depfile and analyzer read evidence, warm file cache. Each cell is **distinct paths / bytes read by the content checksum**. The intersection is exactly the repeated content in the sequential observation; the union is what must still be read. Counts are logical file reads, not SSD traffic.

| Proof / requested recipe | Compiler | Provenance | Intersection | Union | Sequential opens / bytes |
|---|---:|---:|---:|---:|---:|
| Git worker / host | 90 / 117,533,818 | 988 / 153,278,124 | 53 / 88,994,835 | 1,025 / 181,817,107 | 1,078 / 270,811,942 |
| Git worker / Git | 136 / 117,813,174 | 986 / 153,268,482 | 92 / 89,287,555 | 1,030 / 181,794,101 | 1,122 / 271,081,656 |
| Host-only proof / host | 90 / 117,533,818 | 984 / 153,153,564 | 53 / 88,994,835 | 1,021 / 181,692,547 | 1,074 / 270,687,382 |

Eight pinned SDK paths account for **88,353,928** duplicate bytes in every row. The two Git-worker recipes share 63 compiler paths (117,116,143 bytes) and 985 proof paths (153,268,125 bytes). Their unions share 1,004 paths; 21 / 322,345 bytes belong only to the host union, 26 / 299,339 only to Git. None of this justifies sharing a hash *between* recipes or requests. Generation's common read set is 837 paths / 150,882,638 bytes. With nine configured outputs witnessed for the Git worker versus seven for host-only, even the same host compiler tree requires four more proof paths under the Git-worker policy.

Compiler discovery itself also reads config, graph, Flutter version, SDK version and the root manifest: another five reads / 97,687 bytes **in every arm**. Parsing these is not the checksum operation. The final recipe hashes 40,227 bytes (host) or 55,827 (Git) of JSON over stdin in its own subprocess. It is not another file in the union.

## Complete-observation gate

Linux 6.8.0-149, i5-1135G7, GNU coreutils 9.4, pinned Flutter 3.38.10 (`c6f67dede3d4`), bundled Dart 3.10.9. Same checkout outside system temp, real SDK and pub paths, stable lock, no competing target or pub resolution. `FLUTTER_ROOT` was set explicitly and its `bin` first on `PATH`. Full proof generation (43.5–46.3 s here) is admission work, excluded from this table but not from the worker comparison.

* **A**: base capture and independent provenance verification, each using 128-path batches.
* **B**: same discovery, two initial witnesses, hash the sorted union in 128-path batches, project compiler digests, compare proof reads, recheck both witnesses, construct the identical recipe identity.
* **C**: B with an argv budget of 64 KiB **only for the union**. Charge 64 bytes for fixed args and UTF-8 pathname length + NUL + an 8-byte pointer per operand. Identical strict NUL-record, path, order and digest checks. All three paths keep the separate recipe-JSON SHA.

Warm each arm in the proof-bearing Dart process; run all six permutations of A/B/C for each recipe (six complete observations per cell, not six individual file timings). Wall is monotonic; CPU is `getrusage` user + system for the launcher and reaped children. Separate untimed `strace -yy -e trace=openat,read` captures on the checksum processes confirmed opens and summed successful file `read()` lengths against each absolute inventory. Both path sets and compiler identity had to match across arms on every repetition. An independent A/B run (ABBA BAAB) gave 22–26% lower median wall for the 128-path union alone.

| Proof / recipe | Median wall A / B / C, ms | Wall range A / C, ms | Median CPU A / B / C, ms | Content checksum execs A / B / C |
|---|---:|---:|---:|---:|
| Git worker / host | 510 / 406 / 305 | 482–524 / 296–319 | 539 / 438 / 317 | 9 / 9 / 2 |
| Git worker / Git | 521 / 402 / 304 | 501–615 / 293–373 | 549 / 431 / 315 | 10 / 9 / 2 |
| Host-only / host | 473 / 359 / 287 | 469–503 / 266–309 | 504 / 379 / 297 | 9 / 8 / 2 |

The base compiler batches were `[90]` or `[128,8]`; proof batches were seven full batches plus 92, 90 or 88, respectively. The 128-path union took eight full batches plus one or six for the Git-worker recipes; host-only used seven full batches plus 125. The byte budget gave `[659,366]`, `[659,371]`, `[659,362]` on these paths. Add **one** subprocess in all cases for recipe identity. In particular B saves **no** process launch for the Git worker's host, despite removing nearly 89 MB of reads.

Where the wall time went (mean ms per complete observation; minor components rounded). Discovery includes the initial no-follow stats made *while traversing*; compiler fence is initial stamp construction plus final metadata/membership recheck. Proof selection and both proof checks include absence and directory witnesses, not just the paths that need bytes. Compiler paths stamped: 151 / 209 / 151, including 33 / 42 / 33 listed or guarded directories. Proof stamps: 1,571 / 1,579 / 1,567.

| Policy / recipe / arm | Compiler discovery | Compiler fence | Proof selection + initial / final check | Content hash: compiler + proof or union | Recipe JSON + SHA |
|---|---:|---:|---:|---:|---:|
| Git worker / host A | 13.3 | 1.8 | 6.9 / 7.0 | 155.0 + 307.8 | 15.5 |
| Git worker / host C | 12.2 | 3.1 | 6.5 / 6.4 | 261.9 | 14.9 |
| Git worker / Git A | 12.9 | 2.8 | 8.0 / 6.2 | 167.6 + 316.8 | 17.2 |
| Git worker / Git C | 12.3 | 2.1 | 5.8 / 6.4 | 271.1 | 16.0 |
| Host-only / host A | 10.3 | 1.8 | 6.8 / 6.0 | 145.1 + 295.6 | 13.0 |
| Host-only / host C | 9.4 | 1.9 | 7.1 / 5.4 | 245.8 | 15.4 |

Union filtering was under 0.3 ms on average. The content phase includes paths, process creation, byte reads, SHA computation, result pipes and decoding. To distinguish startup, time 50 `Process.run('sha256sum', ['--zero', '--', '/dev/null'])` calls in the **proof-bearing launcher**, not a tiny shell: median 14.2 ms, range 11.9–16.0 (independent series median 14.8). This calibrates launch/empty I/O, not the cost of a real file. B versus C isolates batch overhead on **identical bytes and witnesses**: C won all 18 matched triples. The remaining 246–271 ms union hash includes two such launches and reading/checksumming 182 MB; it is not all subprocess startup.

## What remains independent

The [compiler inventory](https://github.com/eric1234/adele/blob/6f2866f9cace9f33ad42cbda43d8793f20024e96/tools/git_test_aot_inputs.dart) still witnesses directories before listing/probing and files before decoding discovery data. The [generation check](https://github.com/eric1234/adele/blob/6f2866f9cace9f33ad42cbda43d8793f20024e96/tools/test_contract_provenance.dart) selects its own stamped generator/analyzer reads, checks **all** recorded configured source/output pairs even if neither is in the compiler tree, and rejects unproven required parts. The combined implementation uses a fresh local hash map after both initial fences. Only compiler paths enter the sorted recipe hash and depfile allowlist; generation compares against its original expected hashes. Both final metadata checks now follow the awaited recipe digest. Nothing returns or persists the observed file digests. A failure aborts the request.

The [store](https://github.com/eric1234/adele/blob/6f2866f9cace9f33ad42cbda43d8793f20024e96/tools/git_test_aot_store.dart) still repeats the entire operation before a hit or compile, after a compile before publication, and after the private copy before delivery. The generation-time proof check, actual depfile, retained receipt/payload, independent copy verification, separate `generate --check`, worker isolation and desktop artifact cache's default batch policy were not replaced.

## Maintained worker

Ran `dart tools/adele.dart test --target git_desktop_tests --ci` serially in the **same checkout**. Actual order: excluded fresh warmup, exact base A1, excluded candidate warmup, candidate B1, B2, fresh control F, exact base A2. Restored only the candidate diff between base and candidate. F selected the existing unknown-`DART_*` ineligibility guard, not a new flag. No cache purge, concurrent target or shard changes. Each scoped invocation made its own proof and scope. No hosted measurement runs.

For reproduction, prepend a temporary `flutter` wrapper that `exec`s the pinned binary with the original worker argv plus `--file-reporter=json:ABS_PATH`; keep cwd, environment and process group unchanged. Use GNU `time` around the complete launcher and `strace -f --seccomp-bpf -ttt -s 2048 -e trace=execve,execveat -e status=successful` to count successful execs and match driver, kernel input/dill, and independent ELF producer within each compiler lifetime. Compare normalized suite path, full registered/executed case names, outcomes, skip metadata and multiplicities. Use the union of the reporter's load/setup intervals, **not case durations**, for suite preparation. Worker here is pinned Flutter exec to exit. All timed arms used the same warm Flutter kernel path.

| Seconds unless noted | Base A1 | Candidate B1 | Candidate B2 | Fresh F | Base A2 |
|---|---:|---:|---:|---:|---:|
| Real AOT drivers / ELF producers / hits | 7 / 7 / 5 | 7 / 7 / 5 | 7 / 7 / 5 | 12 / 12 / 0 | 7 / 7 / 5 |
| Checksum execs, whole command / worker interval | 244 / 190 | 125 / 71 | 125 / 71 | 38 / 0 | 244 / 190 |
| Request observations (not compiler or copy) | 9.918 | 5.917 | 4.001 | 0 | 6.081 |
| All compiler subprocesses | 27.524 | 24.587 | 16.089 | 26.154 | 15.761 |
| Artifact validation / copy / residual FS | 0.756 | 0.712 | 0.397 | N/A | 0.397 |
| Full generation incl. proof | 50.003 | 50.444 | 27.829 | 26.051 | 27.063 |
| Suite loading / setup | 14.292 / 53.106 | 13.604 / 43.030 | 8.630 / 28.412 | 8.460 / 33.924 | 8.372 / 30.071 |
| Suite preparation (union) | 67.398 | 56.634 | 37.042 | 42.384 | 38.443 |
| Generation + scope + suite preparation | 117.434 | 107.112 | 64.890 | 68.435 | 65.526 |
| Flutter worker / complete command | 262.133 / 316.86 | 170.716 / 225.92 | 144.308 / 175.05 | 149.225 / 178.15 | 144.985 / 175.04 |
| Command CPU user / system | 345.78 / 142.53 | 245.09 / 83.09 | 182.56 / 71.36 | 187.08 / 70.51 | 180.96 / 72.32 |

All six files and **73 named successes** matched across every timed arm, no skips. Four private host runtime paths per worker, seven scoped deliveries; only the five repeated host/Git compiles became hits. Nine host and seven Git observations explain **all 119 fewer execs** (`9×7 + 7×8`). Artifact checks and the 54 pre-worker checksum execs in both scoped arms remained. At base, capture/proof took 3.376/6.542 s (A1) and 2.162/3.919 s (A2); the candidate measures the joint observation once.

The two comparisons saved **4.001 and 2.080 s in actual request validation**. Do not attribute the 91-second A1/B1 worker gap to hashing: even generation and unmodified compiler work varied dramatically across the series. On the closer, later A2/B2 comparison, candidate suite setup saved **1.659 s**, suite load+setup **1.401 s**, preparation including generation/scope **0.636 s**, and worker **0.677 s**. The whole command differed by **0.01 s in the other direction**. There is no demonstrated repeatable whole-command or hosted CI speedup.

## Decision

**Keep Git-hosted reuse narrowly, stop expanding it.** Compared with the nearby fresh F, B2 saved 5.342 s in suite preparation and 3.545 s including generation/scope, with equivalent cases and independent runtimes. That and the five avoided compilers justify keeping the already implemented mechanism here, not generalizing its protocol. The margin is small relative to the variance and complexity. Reconsider its maintenance cost if future ordinary workers cease showing a preparation benefit.

**Keep desktop and interactions fresh; pursue simpler preparation work next.** Applying the measured host-only difference, `27 × (473.2 − 287.3) ms`, to the historical shard would recover about **5.0 s**, or roughly **5.4–5.8 s** if applying the 39% fraction to its measured 13.8–14.9 s of validation. Even with that saving, neither historical full-preparation regression (39.6 and 50.3 s) turns into a win. At this inventory/batching size the model removes 189 of the historical 326 extra launches (`27 × 7`), not all 326. These are extrapolations, not a rerun or a forecast of hosted latency. Neither warrants repeating the desktop adoption experiment in this slice.
