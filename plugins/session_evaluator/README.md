# Session Evaluator

Session Evaluator (`dev.adele.plugin.session-evaluator`) is a **trusted,
development-only diagnostic**, not a model tool or production export workflow.
It collects retained evidence for an explicit durable Session without resolving
its strategy, materializing its Environment, starting a Run, or initializing state.
The development desktop can prepare a local evaluation handoff after using a
normal ADELE Chat Session. This plugin does not evaluate, score, or interpret the
evidence, and does not replace the separate legacy headless runner.

## Ownership

`packages/contract` owns the narrow generated `SessionEvaluatorService` and
`readSessionEvidence` document assembler. `packages/backend` owns the collector,
selected SQL schema knowledge, validation, and native entrypoint. There is no
frontend, Capability, strategy, backend Command, storage schema, or file-writing
service. The development-only native adapter in
[`app/tool/session_evidence_exporter.dart`](../../app/tool/session_evidence_exporter.dart)
owns the desktop Command, sensitive-data confirmation, local directory writing,
and completion feedback. Its development-only
[`session_evaluation_handoff.dart`](../../app/tool/session_evaluation_handoff.dart)
helper captures canonical source metadata and renders the companion README; it
does not depend on the legacy runner. Production `app/lib` imports no evaluator
contract or implementation.

The backend obtains the public `ProjectStorageService` through its exact
generation's infrastructure context. It calls only `queryForSession`, in `durable`
mode, with named parameters and explicit Session predicates. Session scope selects
the host's Project database, not a row-level permission boundary; this diagnostic
intentionally reads current product, Chat, execution, and Command Tools tables
across owners.
It imports no application-private database or other plugin implementation and
opens no SQLite connection. Normal host retirement revokes its storage access;
replacement requires a fresh route and performs a fresh collection.

See the canonical [dependency rules](../../docs/architecture/dependency-rules.md),
[storage contract](../../packages/project_storage/README.md),
[infrastructure access](../../docs/architecture/contracts-and-capabilities.md#generation-scoped-infrastructure-access),
and [plugin layout](../../docs/architecture/plugin-layout.md).

## Retained Evidence

The provisional JSON document has schema `dev.adele.session-evidence.v2`.
This README owns its versioned format. `readSessionEvidence` accepts only this
version: v1's `complete_retained_evidence` did not account for command transcripts
and must not be interpreted as v2 completeness. The generated service ID, method,
stream transport, and collection bounds are unchanged; there is no implicit
upgrade of an older document.

- `identity`: Project ID/source URI, Task ID/title, Session ID/strategy, and the
  canonical same-Task Environment association, role, and provider identity.
- `conversation`: Chat configuration and exact canonical entries, including
  stable entry IDs, roles, text, Session-local sequences, and nullable Run IDs.
  Assistant entries remain unassociated. Draft text is not a submitted message.
- `runs`: terminal product records with their execution root, lifecycle,
  model invocations and outputs, prepared tools, tool changes, and rejected
  proposals. Each relationship retains its Run-local identities/sequences.
- `command_tools`: independently collected, Session-scoped retained command
  captures, including exact decoded stdout/stderr text and capture metadata.
- `coverage`: explicit completeness status, associated Run IDs without observed
  terminal evidence, separate general and command coverage, consistency limits,
  and deliberate exclusions.

Evidence maps retain selected SQL column names and values. Structured `*_json`
columns remain exact source JSON text, validated against their expected shape
rather than normalized or interpreted; command `arguments_json` must decode to
an array of strings. Model metadata/usage presence flags and nullable input,
output, cache-read, and cache-write counters are preserved. Null is unreported,
not zero; no totals, prices, cache-efficiency claims, or guessed effective models
are added.
Provider-native envelope kinds and retained safe presentation are included, but
opaque compatibility/data maps are not read or exported.
Selected text, arguments, provider details, and full command output are not
redacted and may contain secrets or other sensitive development data; the caller
controls handling of the assembled document.

Model proposals are output occurrences, not executions. Prepared tools can be
denied or rejected without an `executionStarted` change. Terminal Runs can contain
unfinished subordinate invocations; their missing terminal fields stay missing.
Run list order is lexical ID order for deterministic pagination, **not chronology**.
The semantic boundaries remain in the
[product model](../../docs/architecture/product-model.md#terminal-run-history) and
[execution model](../../docs/architecture/execution-model.md#terminal-execution-history).

### Command Tools Format

`command_tools` has exactly these fields:

| Field | Value |
| --- | --- |
| `status` | `unavailable` or `available` |
| `schema_version` | `null` when unavailable, otherwise `1` for the Command Tools storage owner schema, not the evidence document version |
| `captures` | Ordered array of capture objects, empty when unavailable or when the initialized schema has no captures for this Session |

Each capture has these fields:

| Field | Value |
| --- | --- |
| `header` | Exact persisted columns listed below, from the initial committed observation |
| `chunks` | Ordered array of `{position, stream, text}` through that header's `high_water`; `stream` is `stdout` or `stderr` |
| `completeness` | `complete`, `incomplete`, or `unsealed_liveness_unknown` |
| `terminal_provenance` | `matched` or `terminal_evidence_unavailable` |
| `consistency` | `committed_high_water_snapshot` |

`header` preserves `invocation_id`, `session_id`, `run_id`, `environment_id`,
`program`, `arguments_json`, `working_directory`, `timeout_seconds`, `state`,
`version`, `high_water`, `total_code_units`, `termination`, `exit_code`, and
`failure`, including nullable values. Command metadata and argv boundaries are
not rewritten. Capture identity is the composite Run/invocation pair, not command
text or an invocation string alone. Captures sort lexically by invocation then Run,
matching the existing primary-key index, not Run chronology or command execution
order. Chunk positions are contiguous one-based ordinals in recorded combined
pipe-arrival order, not byte offsets or a stronger cross-pipe ordering guarantee.
Each stored chunk contains at most 4,096 UTF-16 code units.

Completeness maps persisted `complete` to `complete`, `failed` to `incomplete`,
and `capturing` to `unsealed_liveness_unknown`. A failed capture's validated
committed prefix is useful evidence and remains exportable; it is not a successful
prefix of a failed collection. An unsealed row establishes neither a running nor
an interrupted process. This passive reader has no writer-generation or process
liveness knowledge and never rewrites stored state to `interrupted`.
Nonzero exit and timeout can both have complete captures; process outcome,
transcript completeness, and Run success or failure remain independent.

`matched` means the capture agrees with retained terminal Run/tool evidence for
the exact invocation, Command Tools identity, execution start, and canonical command
metadata. Every capture must agree with its Session's Environment association.
When that terminal evidence was not observed, `terminal_evidence_unavailable`
preserves the capture without inventing a terminal Run, execution outcome, or
provenance match. Contradictory retained provenance fails collection rather than
being relabeled unavailable.
Command collection is independent of the Session's Chat strategy or Chat history
availability and does not require a running Command Tools backend.

`unavailable` means both Command Tools tables and their owner version are absent;
it does **not** mean no commands ran. A valid initialized v1 schema with no captures
is `available` with `captures: []`. Neither case initializes storage. An unsupported
owner version, partially present schema, or incompatible expected columns fails
with `incompatible_schema`; no writer, migration, or schema initialization runs.
The evaluator reads SQL through its own durable Project storage grant, not the
Command Tools read service, which can initialize its owner's schema.

Text is exact **decoded text**, not original process bytes, terminal screen state,
or the bounded model-facing tool result. ANSI controls, Unicode, carriage returns,
partial lines, and stdout/stderr provenance are preserved, not rendered or stripped.
JSON escaping does not change the decoded strings. Generic tool progress and the
bounded command result remain distinct from these retained transcripts. Capture
and writer semantics belong to [Command Tools](../command_tools/README.md#full-decoded-text-capture).

## Completeness And Bounds

Conversation status distinguishes `available` (including valid empty history),
`uninitialized` (Chat schema exists but this Session has no state), `unavailable`
(Chat schema and owner version are absent), and `unsupported_strategy`.
Non-available history or an associated Run without observed terminal evidence
makes `coverage.retained_session_evidence` equal `partial`; otherwise it is
`complete_retained_evidence`. This preserves the general coverage meaning from v1.
Missing terminal evidence establishes no active, waiting, failed, or completed
state. An existing terminal product Run without its evidence root, broken
provenance, invalid selected data, or incompatible expected schema fails collection
rather than becoming empty or complete evidence.

`coverage.command_transcripts` contains:

| Field | Value |
| --- | --- |
| `status` | `unavailable`, `complete_retained_captures`, or `partial` |
| `invocations_without_capture` | Array of `{run_id, invocation_id, execution}` for retained Command Tools invocations lacking a capture; `execution` is `started`, `not_executed`, or `not_observed` |

These execution labels distinguish observed execution start, established
nonexecution through policy denial or approval rejection, and no observation
establishing execution either way. An observed start takes precedence over a denial;
these labels do not turn model proposals into executions. Unavailable command
storage produces `unavailable` coverage, not an empty-complete claim. Available
initialized empty storage can have `complete_retained_captures` when no retained
invocation requires a missing capture. Incomplete/unsealed captures, unavailable terminal provenance,
or missing captures without established nonexecution make command coverage
`partial`. `coverage.status` is `complete_retained_evidence` only when
`retained_session_evidence` is `complete_retained_evidence` **and**
`command_transcripts.status` is `complete_retained_captures`; otherwise it is
`partial`. Completeness describes retained evidence, not whether the Session or
its commands succeeded.

General evidence reads use ordered single-row keyset pages. Command headers use
one-header pages ordered by the composite invocation/Run key, and command chunks
use bounded multirow keyset pages of at most 32 rows. Chunk queries scope the exact
Run/invocation through its Session-owned header and never exceed the initially
observed `high_water`. No path assumes 1,000 messages or one response can hold a
Session. The host's 1 MiB limit still applies to each query. Counts detect cursor
gaps caused by duplicate keys or changed extents. All paths, including schema,
header, extent, and final validation reads, share one collection budget of 100,000
returned query rows and 16 MiB of encoded query results. The final JSON separately
has a 16 MiB UTF-8 limit. Oversize data is an error, never truncated.

Header discovery uses separate initial and successor queries. Successors use the
strict `(invocation_id, run_id) > (:after_invocation, :after_run)` range over the
producer's existing index, retaining explicit Session filtering without a nullable
cursor `OR` or repeated full scan/sort. SQLite may scan/sort for the initial page;
successors range-seek instead. Other Sessions can occupy index entries between
this Session's captures; no Session-leading index or producer migration is
introduced.

For each capture, the initial header and chunk count/minimum/maximum position are
read atomically in one SQL statement to validate its committed extent. Paging
checks contiguous positions, streams, chunk bounds, and the exact UTF-16 text sum
against that initial header. A final atomic header/extent reread validates immutable
metadata, monotonic state/version/extent, and the current chunk count/minimum/maximum.
Safe committed growth or sealing after the initial observation is accepted, but
the export retains the **initial** header, high-water, state, and completeness;
it does not include new chunks or silently upgrade to the later state. Corruption,
regression, or incompatible mutation fails the entire collection. This finite
committed-high-water guarantee is not a cross-owner atomic snapshot or a process
liveness claim.

`collectSession(sessionId)` streams consecutive JSON text chunks of at most
16 Ki UTF-16 code units, without splitting surrogate pairs. No chunk is emitted
until the complete document has been collected and validated. The generated
transport handles backpressure, cancellation, and retirement; the helper returns
a document only after successful stream completion and bounds/schema checks.
It does not write files. Callers must discard incomplete streams and may write a
successfully assembled document to their own test/development location.

Declared failure codes are `invalid_session`, `incompatible_schema`,
`malformed_data`, `collection_limit`, and `storage_query_failed`. The last preserves
failure without pretending the storage transport can distinguish SQL size,
availability, incompatibility, and generation errors. Unknown/closed Sessions and
volatile Projects fail; the collector never creates temporary backing as fallback.

These are **independently observed reads**, not a cross-owner atomic snapshot.
Concurrent mutation can cause explicit consistency failure, or leave a qualified
document reflecting different observation points. Collect after work has settled.
Chat configuration is current, not historical per-Run configuration. Validation
covers selected fields and attributable relationships, not excluded opaque data or
Project-wide orphan rows that cannot be attributed to this Session.

Git/worktree evidence, Environment provider state, live/waiting Run observation,
provider replay data, Markdown reports, and evaluation questions are deliberately
absent from the JSON evidence. Retained command captures can exist without terminal
Run evidence; their inclusion does not add live Run observation. The desktop
handoff's companion README supplies source-inspection guidance separately, without
changing this schema or its collection bounds. Neither file is a source snapshot
or a portable reproduction bundle, and neither promises reproducibility.

<a id="desktop-export"></a>

## Desktop Handoff

With the [pinned toolchain](../../docs/development/toolchain.md), run from the
repository root:

```sh
dart tools/adele.dart bootstrap
dart tools/adele.dart run linux
```

The ordinary Linux development preparation compiles the evaluator AOT backend and
publishes `session-evaluator/backend.aot` in the same prepared installation catalog
as the other plugins. Normal bootstrap activates it without a feature switch,
special startup arguments, or artificial advertisements. Its absence or failure
leaves handoff preparation unavailable, not a prerequisite for unrelated application
behavior.
The launcher selects `app/tool/development_main.dart`, which mounts the ordinary
`AdeleApplication` and attaches the native adapter through `attachSessionContext`.
Direct `app/lib/main.dart` remains plugin-neutral and does not attach the exporter.

1. Open a durable Project and a Session. Use ADELE normally, preferably letting
   work settle before collecting its retained evidence.
2. Open the Command Palette with the AppBar button or its platform shortcut and
   select **Prepare Evaluation Handoff...**
3. Read the sensitive-data warning and explicitly choose **Continue**. **Cancel**
   writes nothing. There is no Save dialog, destination picker, or format selector.
4. Wait for the completion snackbar, which displays the absolute handoff directory
   path and offers **Copy path**. Use its `README.md` as the evaluator entrypoint
   and `evidence.json` as the complete collected document. Failure feedback is
   generic and never includes evidence contents or backend/SQL diagnostics.

The ordinary semantic Command ID is
`dev.adele.session-evaluator.export-session-evidence`. The adapter registers exactly
one Command when the evaluator becomes ready and retires it with that generation;
bootstrap and registration notifications refresh an open palette without polling.
Before readiness or after failure/retirement it is not registered. With a ready
backend but no Session it is hidden; while a handoff is pending it is disabled.
No Main Content, Console, or Inspection participation is needed.

### Capture And Lifetime

Command invocation synchronously captures the `WindowSessionSnapshot`, canonical
Session, exact `InstalledBackendActivation`, and its default configuration/service
route. Metadata capture follows that retained Session's canonical same-Task
Environment association, not an assumed Task-primary
Environment. `SessionEvaluatorServiceClient` and `readSessionEvidence` use the
retained route through the existing generation-validated channel. No storage reader
is linked into the adapter. Navigation, including leaving and reentering a Session,
does not replace the captured Session or retarget the backend. The selection
revision is only an epoch, not execution or storage authority. Fresh invocation
captures the new selection.

Only one handoff may be pending per exporter/window, from confirmation through
directory writing. Success, cancellation, and failure clear pending state. Backend
retirement fences collection and writing; no replacement is silently selected.
Valid partial evidence is written unchanged with its existing coverage fields;
successful handoff preparation does not upgrade that coverage to complete.

Window cleanup closes admission and removes the exact Command and bootstrap
subscription immediately. It withdraws only its own confirmation route, suppresses
late feedback and clipboard actions, and does not await an unanswered confirmation
or collection. Backend shutdown settles the captured transport. In-flight writing
receives at most two seconds of shutdown joining; further validation rejects closed
ownership and failure cleanup removes the new directory where possible. Shutdown never publishes
a late successful handoff or reports an incomplete directory as successful. Forced
process termination or failed cleanup can leave an incomplete directory.

### Directory Semantics

The default output root is `evaluations/` beneath
`PlatformStorageRoots.resolve(...).localStateRoot`, resolved with the host's
`Platform.operatingSystem` and `Platform.environment`. This is local state, not
configuration, cache, or a directory in the selected Project. See
[platform storage paths](../../packages/platform_storage/README.md#paths) for the
OS/environment policy. Tests inject a temporary `outputRoot` instead of writing
real user storage. The writer resolves existing output aliases and rejects output
inside the launching checkout, selected Project's enclosing repository, or a
`.adele/worktrees/` hierarchy rather than falling back to another location.
Unresolvable output-confinement paths, including dangling Project source aliases,
fail preparation safely even when source metadata could otherwise be marked
unavailable. There is no guessed exclusion or fallback output location.

For example, with the default Linux XDG state location:

```text
~/.local/state/adele/state/evaluations/
  session-<random>/
    README.md
    evidence.json
```

The complete versioned document is collected and validated before creating a
handoff directory. The writer uses `createTemp('session-')` to allocate a unique
directory under the output root, containing `README.md` and `evidence.json`.
On Linux/macOS it requires `chmod` on `PATH` and sets the directory to owner-only
mode `0700` before writing sensitive contents; a permission-setting failure aborts
the handoff and attempts cleanup. Windows instead inherits the output root's ACL;
private Windows access has not been validated, and no POSIX-mode guarantee applies.
The adapter preserves the document's structured data, schema, coverage, and bounds;
it does not interpret, redact, wrap, or truncate evidence. Both files must finish
writing with flush requested and ownership validation must succeed before
completion is reported.
Failed writing or validation attempts best-effort removal of the new directory;
earlier successful handoffs are not overwritten or removed.

There is no automatic pruning, export history, durable registry, archive, or
power-loss durability guarantee. Only the maintained Linux launch path provisions
this development workflow; platform path resolution is not cross-platform desktop
acceptance evidence. Review sensitive content before sharing, and remove retained
handoff directories manually when no longer needed.

### Source Inspection

The companion README records captured Project, Task, Session, and Environment
identities plus validated local source hints when available. The development helper
recognizes only the stock Git Environment provider's v1 retained state, validates
its retained identity fields, relative paths, and selected-source scope against the
Project source's nearest enclosing checkout marker. It resolves
the Project source canonically, then requires direct derived worktree/scope paths
and a direct checkout marker, rejecting symlinks in those derived paths. This is
filesystem preflight and source-hint validation, not protection against concurrent
path replacement or proof of current Git registration, baseline-object availability,
branch, or HEAD. Unsupported providers or malformed, missing, or unsafe source
metadata are explicitly unavailable, not replaced with the Task primary, current
checkout, or a guessed repository. The helper neither materializes the Environment
nor runs Git commands or changes Git state.
An invalid canonical product graph fails capture rather than substituting another
Session or Environment.

For valid source hints, follow the README's quoted, source-scoped Git inspection
commands. They distinguish retained baseline-to-HEAD changes, staged changes,
unstaged changes, and nonignored untracked paths rather than treating one diff as
all work. A Project selected from a repository subdirectory must be inspected in
that scope, not across the entire linked checkout. These are instructions for a
separate evaluator, not Git evidence collected during handoff preparation.

Source paths refer to a **live worktree** that can change or disappear after
preparation and can be shared by multiple Sessions. Its current changes are not
automatically attributable to the captured Session. The handoff copies no source,
patch, repository, or archive; unsaved editor buffers are not on-disk evidence.
Retained evidence can be partial and is unredacted; source, prompts, responses,
arguments, and full command output may be sensitive.
Use the stated coverage and limitations rather than treating directory creation
as proof of a complete, isolated, or reproducible evaluation.

## Exercise And Validate

Use the [pinned toolchain](../../docs/development/toolchain.md) and repository
bootstrap/generation. Prepared checkout paths are not portable release packaging.
`app/test/core/session_evaluator_integration_test.dart`
compiles the real shared host, Chat, Command Tools, and evaluator AOT entrypoints,
assembles an explicit temporary backend-only installation, and uses normal
application bootstrap plus the real Project storage host. Its deterministic local
model/tools produce actual retained Chat and Run data without paid provider calls.
The native handoff path includes command captures from a compiled local child
executed through the fixture's deterministic Environment adapter. The test
caller and native Command Palette workflow use temporary output roots and check
exact evidence, the companion README, completion path and clipboard action,
read-only state, Session isolation, valid partial coverage, cancellation, failure,
pending work, navigation, shutdown, and generation retirement.
A stock Git AOT fixture exercises a nonprimary Session Environment with nested
source scope, retained baseline/branch hints, and unchanged Git state without
materializing the reopened Environment.
`app/test/core/command_output_capture_integration_test.dart` adds real Git/Command
Tools/evaluator AOT and socket-gated process output: exact decoded transcripts
beyond the model-result bound, an unsealed committed prefix, evaluator-only Project
reopen without Command Tools activation, and an over-budget transcript that fails
without emitting a successful prefix. These are separate from Chat strategy support
and from a claim of process liveness.
`app/test/session_evidence_file_test.dart` owns unique two-file directory writing,
bounds, ownership revocation, and best-effort failure cleanup using real temporary
files and injected write faults. `app/test/session_evaluation_handoff_test.dart`
owns captured source metadata, canonical nonprimary association, stock Git v1
validation, unsafe/unavailable source handling, and rendered inspection guidance.
Tooling tests check the ordinary prepared catalog and launcher target;
application tests check the plugin-neutral Navigator/context composition seams.

From the repository root:

```sh
dart tools/adele.dart bootstrap
dart tools/adele.dart test --target session_evaluator_contract
dart tools/adele.dart test --target session_evaluator_backend
dart tools/adele.dart test --target adele_core_extensions
dart tools/adele.dart test --target adele_tools
dart tools/adele.dart test --target adele_desktop --ci
dart tools/adele.dart generate --check
```

After current generation, from `app/`:

```sh
flutter test --no-pub --concurrency 1 test/core/session_evaluator_integration_test.dart test/core/command_output_capture_integration_test.dart test/session_evidence_file_test.dart test/session_evaluation_handoff_test.dart test/application_test.dart
```

The packages participate in maintained analysis/test targets; the existing
`adele_desktop` target discovers the integration tests. See the
[testing map](../../docs/development/testing.md) for repository/CI policy.
