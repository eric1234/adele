# Session Evaluator

Session Evaluator (`dev.adele.plugin.session-evaluator`) is a **trusted,
development-only diagnostic**, not a model tool or production export workflow.
It collects retained evidence for an explicit durable Session without resolving
its strategy, materializing its Environment, starting a Run, or initializing state.
The intended later workflow is to export evidence after using a normal ADELE Chat
Session and give it to an independent evaluator. This plugin does not evaluate,
score, or interpret the evidence, and does not replace the legacy headless runner.

## Ownership

`packages/contract` owns the narrow generated `SessionEvaluatorService` and
`readSessionEvidence` document assembler. `packages/backend` owns the collector,
selected SQL schema knowledge, validation, and native entrypoint. There is no
frontend, Capability, strategy, Command, storage schema, or file-writing service.

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
provider state, live/waiting Runs, provider replay data, filesystem export authority,
desktop UI, Markdown reports, and evaluation questions are deliberately absent.
Generic tool progress and bounded command outcomes are not full command transcripts.
These limitations must remain visible when a future export workflow is added.

## Exercise And Validate

Use the [pinned toolchain](../../docs/development/toolchain.md) and repository
bootstrap/generation. The evaluator is not included in ordinary desktop preparation
or release packaging. `app/test/core/session_evaluator_integration_test.dart`
compiles the real shared host, Chat, and evaluator AOT entrypoints, assembles an
explicit temporary backend-only installation, and uses normal application
bootstrap plus the real Project storage host. Its deterministic local model/tools
produce actual retained Chat and Run data without paid provider calls. The test
caller assembles and writes JSON in its temporary directory and checks read-only
state, Session isolation, failure semantics, and generation replacement.

From the repository root:

```sh
dart tools/adele.dart bootstrap
dart tools/adele.dart test --target session_evaluator_contract
dart tools/adele.dart test --target session_evaluator_backend
dart tools/adele.dart test --target adele_tools
dart tools/adele.dart generate --check
```

After current generation, from `app/`:

```sh
flutter test --no-pub --concurrency 1 test/core/session_evaluator_integration_test.dart
```

The new packages participate in maintained analysis/test targets; the existing
`adele_desktop` target discovers the integration test. See the
[testing map](../../docs/development/testing.md) for repository/CI policy.
