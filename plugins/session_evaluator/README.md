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
intentionally reads current product, Chat, and execution tables across owners.
It imports no application-private database or other plugin implementation and
opens no SQLite connection. Normal host retirement revokes its storage access;
replacement requires a fresh route and performs a fresh collection.

See the canonical [dependency rules](../../docs/architecture/dependency-rules.md),
[storage contract](../../packages/project_storage/README.md),
[infrastructure access](../../docs/architecture/contracts-and-capabilities.md#generation-scoped-infrastructure-access),
and [plugin layout](../../docs/architecture/plugin-layout.md).

## Retained Evidence

The provisional JSON document has schema `dev.adele.session-evidence.v1`:

- `identity`: Project ID/source URI, Task ID/title, Session ID/strategy, and the
  canonical same-Task Environment association, role, and provider identity.
- `conversation`: Chat configuration and exact canonical entries, including
  stable entry IDs, roles, text, Session-local sequences, and nullable Run IDs.
  Assistant entries remain unassociated. Draft text is not a submitted message.
- `runs`: terminal product records with their execution root, lifecycle,
  model invocations and outputs, prepared tools, tool changes, and rejected
  proposals. Each relationship retains its Run-local identities/sequences.
- `coverage`: explicit completeness status, associated Run IDs without observed
  terminal evidence, consistency limits, and deliberate exclusions.

Evidence maps retain selected SQL column names and values. Structured `*_json`
columns remain exact source JSON text, validated as objects rather than normalized
or interpreted. Model metadata/usage presence flags and nullable input, output,
cache-read, and cache-write counters are preserved. Null is unreported, not zero;
no totals, prices, cache-efficiency claims, or guessed effective models are added.
Provider-native envelope kinds and retained safe presentation are included, but
opaque compatibility/data maps are not read or exported.
Selected text, arguments, and provider details are not redacted and may contain
sensitive development data; the caller controls handling of the assembled document.

Model proposals are output occurrences, not executions. Prepared tools can be
denied or rejected without an `executionStarted` change. Terminal Runs can contain
unfinished subordinate invocations; their missing terminal fields stay missing.
Run list order is lexical ID order for deterministic pagination, **not chronology**.
The semantic boundaries remain in the
[product model](../../docs/architecture/product-model.md#terminal-run-history) and
[execution model](../../docs/architecture/execution-model.md#terminal-execution-history).

## Completeness And Bounds

Conversation status distinguishes `available` (including valid empty history),
`uninitialized` (Chat schema exists but this Session has no state), `unavailable`
(Chat schema and owner version are absent), and `unsupported_strategy`.
Non-available history or an associated Run without observed terminal evidence
makes coverage `partial`. Missing terminal evidence establishes no active, waiting,
failed, or completed state. An existing terminal product Run without its evidence
root, broken provenance, invalid selected data, or incompatible expected schema
fails collection rather than becoming empty or complete evidence.

Data reads use ordered, single-row keyset pages. This deliberately prioritizes
support for any individually readable row over SQL-call throughput; it never
assumes 1,000 messages or one response can hold a Session. The host's 1 MiB limit
still applies to each query. Counts detect cursor gaps caused by duplicate keys
or changed extents. Collection is limited to 100,000 returned query rows and
16 MiB of encoded query results, including validation reads; the final JSON also
has a 16 MiB UTF-8 limit. Oversize data is an error, never truncated.

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

Full Command Tools stdout/stderr transcripts, Git/worktree evidence, Environment
provider state, live/waiting Runs, provider replay data, Markdown reports, and
evaluation questions are deliberately absent from the evidence.
Generic tool progress and bounded command outcomes are not full command transcripts.

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

The complete E1 document is collected and validated before any staging file is
created. The adapter preserves its structured data, schema, coverage, and bounds;
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
compiles the real shared host, Chat, and evaluator AOT entrypoints, assembles an
explicit temporary backend-only installation, and uses normal application
bootstrap plus the real Project storage host. Its deterministic local model/tools
produce actual retained Chat and Run data without paid provider calls. The test
caller and native Command Palette workflow write JSON in temporary directories and
check exact documents, read-only state, Session isolation, valid partial coverage,
cancellation, failure, pending work, navigation, shutdown, and generation retirement.
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
flutter test --no-pub --concurrency 1 test/core/session_evaluator_integration_test.dart test/session_evidence_file_test.dart test/application_test.dart
```

The new packages participate in maintained analysis/test targets; the existing
`adele_desktop` target discovers the integration test. See the
[testing map](../../docs/development/testing.md) for repository/CI policy.
