# Session Evaluator

Session Evaluator (`dev.adele.plugin.session-evaluator`) is a **trusted,
development-only diagnostic**, not a model tool or production export workflow.
It collects retained evidence for an explicit durable Session without resolving
its strategy, materializing its Environment, starting a Run, or initializing state.
The development desktop can export evidence after using a normal ADELE Chat
Session and give it to an independent evaluator. This plugin does not evaluate,
score, or interpret the evidence, and does not replace the legacy headless runner.

## Ownership

`packages/contract` owns the narrow generated `SessionEvaluatorService` and
`readSessionEvidence` document assembler. `packages/backend` owns the collector,
selected SQL schema knowledge, validation, and native entrypoint. There is no
frontend, Capability, strategy, backend Command, storage schema, or file-writing
service. The development-only native adapter in
[`app/tool/session_evidence_exporter.dart`](../../app/tool/session_evidence_exporter.dart)
owns the desktop Command, confirmation, native Save dialog, and local file commit.
Production `app/lib` imports no evaluator contract or implementation.

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
text or an invocation string alone. Captures sort lexically by Run then invocation,
not execution chronology. Chunk positions are contiguous one-based ordinals in
recorded combined pipe-arrival order, not byte offsets or a stronger cross-pipe
ordering guarantee. Each stored chunk contains at most 4,096 UTF-16 code units.

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
one-header pages ordered by the composite Run/invocation key, and command chunks
use bounded multirow keyset pages of at most 32 rows. Chunk queries scope the exact
Run/invocation through its Session-owned header and never exceed the initially
observed `high_water`. No path assumes 1,000 messages or one response can hold a
Session. The host's 1 MiB limit still applies to each query. Counts detect cursor
gaps caused by duplicate keys or changed extents. All paths, including schema,
header, extent, and final validation reads, share one collection budget of 100,000
returned query rows and 16 MiB of encoded query results. The final JSON separately
has a 16 MiB UTF-8 limit. Oversize data is an error, never truncated.

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
absent from the evidence. Retained command captures can exist without terminal Run
evidence; their inclusion does not add live Run observation. This JSON document is
not a portable reproduction bundle. Any later portable-bundle work must account
for those missing artifacts and sensitive output; this format does not introduce
a bundle design or promise reproducibility.

## Desktop Export

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
leaves export unavailable, not a prerequisite for unrelated application behavior.
The launcher selects `app/tool/development_main.dart`, which mounts the ordinary
`AdeleApplication` and attaches the native adapter through `attachSessionContext`.
Direct `app/lib/main.dart` remains plugin-neutral and does not attach the exporter.

1. Open a durable Project and a Session. Use ADELE normally, preferably letting
   work settle before collecting its retained evidence.
2. Open the Command Palette with the AppBar button or its platform shortcut and
   select **Export Session Evidence...**
3. Read the sensitive-data confirmation and explicitly choose **Continue**.
4. Choose a local destination in the native Save dialog, which suggests
   `session-evidence.json`. Cancellation at either dialog writes nothing.
5. Wait for **Session evidence exported.** before using the file. Failure feedback
   is generic and never includes evidence contents or backend/SQL diagnostics.

The ordinary semantic Command ID is
`dev.adele.session-evaluator.export-session-evidence`. The adapter registers exactly
one Command when the evaluator becomes ready and retires it with that generation;
bootstrap and registration notifications refresh an open palette without polling.
Before readiness or after failure/retirement it is not registered. With a ready
backend but no Session it is hidden; while an export is pending it is disabled.
No Main Content, Console, or Inspection participation is needed.

### Capture And Lifetime

Command invocation synchronously captures the `WindowSessionSnapshot`, canonical
Session, exact `InstalledBackendActivation`, and its default configuration/service
route. `SessionEvaluatorServiceClient` and `readSessionEvidence` use that retained
route through the existing generation-validated channel. No storage reader is
linked into the adapter. Navigation, including leaving and reentering a Session,
does not replace the captured Session or retarget the backend. The selection
revision is only an epoch, not execution or storage authority. Fresh invocation
captures the new selection.

Only one export may be pending per exporter/window, from confirmation through file
commit. Success, cancellation, and failure clear pending state. Backend retirement
fences collection and pre-commit validation; no replacement is silently selected.
Valid partial evidence is exported unchanged with its existing coverage fields.

Window cleanup closes admission and removes the exact Command and bootstrap
subscription immediately. It withdraws only its own confirmation route, suppresses
late feedback, and does not await an unanswered native Save dialog or collection.
Late picker results cannot start collection or writing. Backend shutdown settles
the captured transport. In-flight file staging receives at most two seconds of
shutdown joining; its next validation prevents commit and its `finally` cleanup
removes staging where possible. A rename already submitted may complete, without
a late success notification. Forced process termination can leave a private staging
directory; this is not a crash-recovery or persistent-export-history mechanism.

### File Semantics

The complete versioned document is collected and validated before any staging file
is created. The adapter preserves its structured data, schema, coverage, and bounds;
it does not interpret, redact, wrap, or truncate evidence. It encodes JSON, flushes
a staged file in a unique private `.adele-session-evidence-*` directory under the
destination's parent, then renames the completed file over the destination.
Collection, staging, or pre-commit validation failure leaves an existing destination
intact. Failed finalization never deletes the destination as a fallback. Staging
cleanup is best effort after both failure and success.

The writer uses POSIX same-filesystem rename on Linux/macOS; only Linux is tested
and automatically provisioned by the maintained launcher. Other platforms fail
cleanly before staging rather than claiming unsafe replacement semantics. This
does not guarantee power-loss durability, preserve the previous file's metadata,
or provide conflict detection against another writer. A destination symlink is
replaced, not followed. The native dialog owns destination/overwrite interaction.
Evidence is unredacted local development data; choose an appropriately protected
destination and review it before sharing.

## Exercise And Validate

Use the [pinned toolchain](../../docs/development/toolchain.md) and repository
bootstrap/generation. Prepared checkout paths are not portable release packaging.
`app/test/core/session_evaluator_integration_test.dart`
compiles the real shared host, Chat, Command Tools, and evaluator AOT entrypoints,
assembles an explicit temporary backend-only installation, and uses normal
application bootstrap plus the real Project storage host. Its deterministic local
model/tools produce actual retained Chat and Run data without paid provider calls.
The native export path includes command captures from a compiled local child
executed through the fixture's deterministic Environment adapter. The test
caller and native Command Palette workflow write JSON in temporary directories and
check exact documents, read-only state, Session isolation, valid partial coverage,
cancellation, failure, pending work, navigation, shutdown, and generation retirement.
`app/test/core/command_output_capture_integration_test.dart` adds real Git/Command
Tools/evaluator AOT and socket-gated process output: exact decoded transcripts
beyond the model-result bound, an unsealed committed prefix, evaluator-only Project
reopen without Command Tools activation, and an over-budget transcript that fails
without emitting a successful prefix. These are separate from Chat strategy support
and from a claim of process liveness.
`app/test/session_evidence_file_test.dart` injects faults at real staging and rename
boundaries. Tooling tests check the ordinary prepared catalog and launcher target;
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
flutter test --no-pub --concurrency 1 test/core/session_evaluator_integration_test.dart test/core/command_output_capture_integration_test.dart test/session_evidence_file_test.dart test/application_test.dart
```

The packages participate in maintained analysis/test targets; the existing
`adele_desktop` target discovers the integration tests. See the
[testing map](../../docs/development/testing.md) for repository/CI policy.
