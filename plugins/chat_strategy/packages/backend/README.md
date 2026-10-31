# Chat Backend

`chat_strategy_backend` owns canonical Chat history, Draft Request, configuration,
and sequencing. Its AOT entrypoint exposes the generated Chat Session, public
Session feedback, dedicated read-only feedback Inspection, and remote orchestration
services over one backend router and
one retained `ChatSessionStore`. It advertises only its orchestration strategy
contribution, whose `feedbackServiceId` opts the same exact Chat route into the
public feedback contract.

The entrypoint requires the host's generation-bound `hostInfrastructureContext`
and injects a generated `ProjectStorageServiceClient` over the existing host-call
multiplexer. Construction makes no storage calls before ready. First Session
access deduplicates hydration, asks `isDurableSession`, and initializes or reads
the Chat-owned v1 relational baseline. The schema owner is the connection's exact
PluginId, `dev.adele.plugin.chat-strategy`, not a caller-supplied owner.
`adele_chat_sessions` stores instructions, the
next-entry counter, and `draft_request TEXT NOT NULL`, keyed by and referencing
`adele_product_sessions(id)`. The current schema remains a v1 baseline, with no
upgrade migration or compatibility reader for development schemas.
`adele_chat_entries` stores ordered user/final-assistant occurrences with
Session-local unique entry IDs and nullable `run_id TEXT`. Only user entries may
carry a Run association; `(session_id, run_id)` is unique for non-null values.
There is no foreign key from `run_id` to the core terminal Run table because
association precedes terminal retention. `adele_chat_feedback_submissions` retains
the complete canonical structured payload and its user entry link, with primary
key `(session_id, submission_id)`, unique `(session_id, entry_id)`, and a composite
foreign key to the canonical entry. Chat never writes core tables or whole-history
JSON snapshots. Cross-system ownership belongs to
[Chat participation](../../../../docs/architecture/plugin-system.md#chat-participation).

Hydration looks up the next expected `sequence` within the Session using the
existing composite index, without rescanning a history prefix. `LIMIT 2` detects
duplicate sequences if constraints are damaged; valid state returns one entry per
query, keeping individually readable rows within the response bound. An empty
result ends the contiguous lookup. A final retained-row count and the entry-counter
check reject hidden rows or gaps before publishing state. It validates the current
contiguous sequence/`entry-N` IDs, role, nonblank content, nullable user-only Run
associations and their uniqueness, counter, and string draft. The counter
starts at zero and is shared by both roles. Raw message,
draft, and instruction bytes are retained. Missing state is initialized to stock
instructions, counter zero, and an empty draft. Invalid canonical row
values raise `ChatStateCorruption`; schema/query failures also propagate rather
than resetting state. Before durable
writes, each projected configuration/entry row must fit the
host's 1 MiB encoded-result bound: two initial bytes plus the UTF-8 JSON encoding
of `{'values': row}` and one separator byte. All projected fields, JSON escaping,
and multibyte text count, including the draft in the Session row. Default
initialization, configuration/draft replacement, draft submission, and
user/final-assistant appends validate before their write transaction; appends also
recheck the Session row with the proposed next-entry counter and retained draft,
or the cleared draft for submission. There is no smaller draft-specific limit.
Oversize rejection does not mutate the canonical cache or database or consume an entry ID. An
oversized final assistant still fails after host completion, not by rolling back
the host Run. Explicitly volatile state has no persistence row bound. Injected
oversized stored rows fail explicitly on read, never truncate.
Storage/transport failures propagate without volatile fallback or
hidden retry. A failed hydration remains failed for that store generation.
Concurrent first access by independent stores uses a conflict-safe default insert
and reads the durable winner instead of publishing speculative defaults.

`ChatSessionStore()` without a client is the explicit volatile fixture path.
With a client, only the host's explicit `isDurableSession == false` selects
volatile canonical state. `load` is asynchronous; synchronous `obtain`, state
setters, and direct native strategy execution cannot bypass durable writes.
`ChatStrategyPlugin` and standalone `ChatSessionState` retain their synchronous
volatile fixture behavior.

The strategy preserves ordered canonical user/final-assistant projection,
provider-native Run-local replay, sequential tool proposals, approval pauses,
refusals, and the positive model-invocation limit. `ChatStrategyPlugin` and
`ChatRemoteOrchestrationBackend` require a positive `maxModelInvocations` argument
independently of the store. Each execution captures that immutable budget at
materialization alongside the Session instructions. The authoritative
[`settings.schema.json`](../../settings.schema.json) declares default 40, minimum 1,
and no maximum; the entrypoint requires the host's resolved startup value through
`AdeleBackendSettings.fromBootstrap(...).read<int>(chatMaxModelInvocationsSettingId)`.
No missing-setting fallback exists. A differently configured plugin/backend can
share the store for a later Run, without changing an existing execution across
tool or approval waits. The budget is absent from Session snapshots, SQL, and
instruction configuration. Intermediate tool, native, reasoning, and narration
items do not enter canonical history.

After successful `RemoteOrchestrationBackend.materialize`,
`ChatRemoteOrchestrationBackend` associates the final history entry with the semantic
Run ID only when it is an unassociated user entry, while retaining the Session claim. It persists the
association before updating canonical and execution-local staged caches. Association
failure releases the newly materialized execution and claim, without publishing
the association or silently retrying. Starting and approval resume do not replace
an already accepted association. An unstarted or waiting Run may never acquire
terminal history; the association does not manufacture it. Historical native
envelopes are never loaded into future inference.

## Historical execution projection

`lib/src/historical_projection.dart` is Chat-owned model-input construction, not
another history store. At start, after `host.start()` and before the first model
call, Chat captures canonical entries and uses public `readHistoricalRun` for each
associated user entry except the current Run. Reads are sequential under the
active host operation, never during materialization. One immutable input prefix
is reused throughout the Run, including approval resume; `_runItems` continues
to grow separately with current-Run model/tool items. Reads consume no model slots.

Canonical entry order supplies chronology. Each earlier Run gets one semantic
assistant message immediately after its initiating user entry. Original canonical
message bytes and unassociated entries remain unchanged. The message labels its
JSON as historical observations, not instructions, authorization, or current
Environment state. Sorted JSON object keys and sequence-ordered events make
identical evidence stable without timestamps or native provider reconstruction.
Model text, proposals and arguments, resolved tool identity/canonical arguments,
policy/approval/rejection facts, progress, actual model-visible outcomes, and
failures retain Run-local sequence and correlation. Missing proposal resolution,
model terminal, and tool outcome observations are explicit, not invented success.
The actual terminal status and available failure classification are retained;
generic `unknown` failures are not diagnosed as a specific invocation-budget cause.

Final-answer deduplication requires a completed Run, its last settled answer or
refusal, and an immediately following canonical assistant entry with exactly the
concatenated text. Only those final text occurrences become references to that
entry; earlier identical narration is not removed. If no matching committed entry
exists, including after Chat SQL fails following host completion, the output stays
in the historical record without becoming a canonical final answer. Native-only
output, native attachments, provider item IDs, opaque reasoning/state, host-only
data, and executable authority are not replayed.

`unavailable` and `result_too_large` reads produce explicit incomplete-history
notices identifying the Run, with unknown terminal status and no fabricated
progress. Unexpected `current_run` is an invariant failure. Other declared codes
and undeclared transport, lifecycle, or binding errors propagate, not absence.
Valid terminal evidence with empty activity still retains its actual status.

There is no truncation, paging, summarization, compaction, or file freshness check.
M1's per-Run read bounds still apply; aggregate inference transport/provider bounds
remain explicit failures, never a reason to discard old material. Aggregate
transport failures currently surface through the generic orchestration
error, not a context-size-specific diagnostic. Historical tool results retain only
the model-visible content M1 supplies, not private full
tool transcripts. The entire prefix is resent for each inference and grows across
Runs. Semantic serialization changes the previous Run's native input shape, so
stable ordering does not promise byte-identical native replay or provider cache
reuse. Aggregate context management and more efficient/finer-fidelity projection
require a later explicit design.

## Draft Request

When ordinary materialization carries an expected feedback receipt, the same
claim validates its durable submission and exact linked user occurrence. That
occurrence must still be the eligible history tail and not belong to a different
Run. The association transaction checks the captured Session counter/configuration,
entry content, and immutable submission linkage together; a newer input or a stale
generation fails closed without associating unrelated input. An uncertain association
write invalidates cached state before subsequent mutations. Public feedback lookup
exposes the current durable `runId` separately from its immutable receipt, including
after backend replacement with no terminal Run record. A missing association after
attempted scheduling is not proof of rollback or permission to schedule again.
The explicit volatile native helper rejects expected feedback; this durable path
uses the installed remote backend and needs no mounted Chat presentation.

`ChatSessionState` owns the generation-local exact draft string, exposed through
`ChatSessionSnapshot.draftRequest`. `setDraftRequest` replaces it exactly, including
empty or whitespace-only text, committing before updating memory. `submitDraftRequest`
rejects `trim().isEmpty` with declared `invalid_content`; nonblank text is never
normalized. Submission atomically inserts one canonical user entry, advances the
counter, and clears the draft in one SQL transaction, then updates memory and
returns the accepted occurrence. It does not start a Run. Direct `appendUserMessage`
and `configureSession` retain the draft; execution neither projects it into model
input nor consumes it. Volatile stores use these same semantics in memory only.

## Structured feedback

`ChatSessionFeedbackService` implements the public generated
`RemoteSessionFeedbackService`; `ChatStrategyPlugin` also supplies a bound native
`feedbackTarget` factory over the same store. Neither path materializes execution,
starts a Run, reads an Environment, approves work, or changes the Draft Request.
Feedback requires durable Project storage. Explicitly volatile fixtures/Projects
fail with `storage_failure`, without a fallback receipt cache or temporary backing.

An immutable submission identity identifies one complete canonical payload within
its Session and Project. An exact duplicate returns the original receipt; changed
payload under the same ID fails with `submission_conflict`. Equal comments under
different IDs remain separate user occurrences. Durable receipt reads do not trust
the generation cache, and validate both the full structured payload and its linked
user projection. Reads of unknown IDs return null only after a successful query;
unavailable storage or invalid retained data is `storage_failure`, not absence.
An old development v1 schema missing the feedback table fails explicitly, without
schema repair, migration, or compatibility fallback.

Acceptance acquires the existing Session claim and commits a conditional counter
CAS, canonical user entry, and structured submission in one SQL transaction.
The CAS includes the prior counter/configuration/draft and absence of the submission
ID. SQLite `changes()` links the conditional inserts to that update: an independent
store's duplicate/CAS loser is an acknowledged no-op, followed only by read-only
reconciliation. Primary/unique constraints protect identity and entry linkage.
There is no check-then-insert occurrence allocation or automatic mutation replay.
Only in-flight same-ID requests are coalesced; no completed receipt cache is kept.
New input while claimed fails with `session_busy`; accepted duplicates and receipt
lookup remain readable during materialization, advancement, and approval waits.

Thrown SQL/transport writes are always `outcome_uncertain`: the public storage
boundary does not expose a provable rollback classification. Explicit lookup by the
original ID can positively establish acceptance after a lost acknowledgement, but
absence does not prove a still-running write rolled back. Failure messages contain
no raw storage errors. Cache publication follows acknowledged SQL and validated
durable reads. Recovery reloads the existing cached Session under its normal claim;
an active claim is never overwritten, and a required refresh waits until the next
idle load before further execution or mutation. Claim acquisition also checks that
flag, so a previously returned cached-load future cannot enter stale work. A
positive receipt read invalidates stale history even when payload comparison
rejects a conflicting duplicate. Shutdown stops new feedback
admission and drains accepted operations. If the entrypoint closes reverse calls
while SQL is unresolved, acceptance settles uncertain and a fresh target can look
up the durable result.

`renderChatSessionFeedback` produces one deterministic user message containing
explicit feedback guidance and the complete canonical JSON. JSON string escaping
keeps paths, excerpts, metadata, and comments unambiguous while preserving exact
Unicode, CRLF, whitespace, same-line comments, and original ordering. Captured
positions are explicitly historical, not current-source claims; the message asks
for current-source inspection before editing and labels supplied content as user
data, not system instructions. Existing Session/system instructions are unchanged.
The public 128 KiB canonical submission bound, 144 KiB model-content bound, and
actual encoded storage-row bounds are enforced before creating an occurrence.

`ChatEntry.feedback` is a nullable typed summary derived from the unique durable
submission-to-entry relationship. Hydration reads only the relationship identities,
kind, and comment-array count using guarded SQLite JSON extraction; it does not
load complete payloads for labels or parse model-facing content. One indexed
existence check avoids per-entry feedback queries for ordinary histories. When
feedback exists, separate narrow lookups for user entries preserve the existing
exact canonical-content row bound.
Invalid metadata, assistant relationships, duplicates, and orphan relationship
counts fail hydration explicitly. The summary is not another stored column or
projection. Acceptance refreshes it through the canonical load path, and later Run
association preserves it alongside the unchanged content and occurrence order.

`ChatFeedbackInspectionBackend` implements the separately generated
`ChatFeedbackInspectionService` using the same exact infrastructure storage client
as the store. It only validates durable Session access and queries the requested
occurrence; it never ensures schema, initializes Chat state, hydrates or refreshes
the cache, or acquires a mutation/execution claim. The read-only service is registered
independently in the AOT router, so a renderer need not receive a mutation-capable
Chat or public feedback service.

Inspection and public receipt lookup share one authoritative relationship reader.
One joined read validates the actual canonical user occurrence, Chat Session row
and counter, submission/occurrence identities, public canonical payload encoding,
exact model-content projection, and nullable Run identity before returning complete
structured review data. Inspection maps failures to safe declared
`invalid_request`, `not_found`, `unavailable`, or `corrupt` results. An unavailable
schema or storage grant is not absence and is never repaired by reading. The
typed Chat transport DTOs mirror public Session feedback fields only because the
generator requires library-local value declarations; public decoding/encoding
remains the only canonical JSON codec. All accepted data through the public 128 KiB
bound is returned without truncation, including before a Run and after reopen.

## Sequencing and lifecycle

Service mutations hold the same Session claim while SQL is pending and are
rejected while another write or materialized execution owns it, including
approval waits and terminal acknowledgement. `configureSession` replaces only
instructions in one SQL transaction before memory publication. Appends persist the candidate
entry and counter atomically before returning it. Expected row counts and prior
counter/configuration/draft predicates reject writes from stale generation caches.
Read-only snapshots and other Sessions remain available.
All generated entrypoint dispatchers explicitly admit concurrent requests;
Session claims and per-execution advancement guards, not a backend-global request
queue, enforce exclusion. A model/tool wait in one Session cannot delay another
Session's materialization, execution, or canonical reads through that router.
Chat-owned `ChatRemoteOrchestrationBackend`
runs sequencing against an execution-local history copy and commits its final
assistant entry and counter only after `RemoteOrchestrationBackend` returns
acknowledged completion, then merges them into the canonical cache. Until SQL
settles, snapshots still expose the prior canonical history. A storage failure
does not merge or advance that cache, even though the host Run may already be
completed; the error propagates rather than inventing a rollback of host state.
Rejected completion discards that candidate, preserving accepted
user entries and prior history. The claim is released after execution close and
commit or discard; closing during advancement drains one shared asynchronous
settlement, and closing during hydration drains accepted materializations without
publishing late executions.
Generic host orchestration retains
model/tool execution, policy, Environment authority, and approval authorization;
Chat composes the unchanged F3f backend, not direct provider/tool calls.

Backend startup is independent of frontend activation. A missing or corrupt EVC
does not prevent headless execution. Each generation has one canonical cache;
a fresh generation reloads durable semantics, not live execution state or claims.
Retirement never causes an old frontend to attach to a replacement. Host-owned
[terminal Run/activity history](../../../../docs/architecture/execution-model.md#terminal-execution-history)
is separate from Chat storage. Live Runs, claims, actionable approvals, and native
continuation state are not restored; native envelopes in history are evidence only.

The sequencing and state tests live here rather than in a second root semantic
package. The in-process activation helper is for explicit backend/host fixtures,
not production application composition. See the [plugin overview](../../README.md)
for the contract and execution semantics.

Validation from the repository root:

```sh
dart tools/adele.dart test --target chat_strategy_backend
dart tools/adele.dart test --target chat_strategy_contract
```

`chat_durable_state_test.dart` exercises the public relational boundary with a
test-owned SQLite service, including real trigger rollback, exact draft row bounds,
and stale-cache rejection; `chat_remote_backend_test.dart` also covers installed
entrypoint draft operations and generation replacement, infrastructure routing,
terminal acknowledgement, held commits, and close/hydration races.
`chat_historical_projection_test.dart` inspects actual strategy inference material
through generated host transport: ordered observations, final-answer matching,
incomplete-history notices, failure distinctions, and frozen history across live
continuations and approval resume. The application's
`durable_chat_session_integration_test.dart` uses installed Chat with real terminal
retention and Project reopening; `normal_chatgpt_run_integration_test.dart` also
checks effective provider HTTP input with deterministic responses.
`chat_feedback_test.dart` covers complete structured roundtrip, SQL identity/CAS
concurrency across stores, busy reads, rollback, commit-then-lost-ack recovery,
shutdown draining, independent Sessions/Projects, cache refresh, and byte/row
bounds. The remote suite additionally exercises generated feedback routing and
retirement uncertainty and checks the later model input remains a user message.
The feedback suite also checks narrow metadata, identical ordinary prose,
read-only Inspection, corrupt relationships, and the exact 128 KiB boundary over
both generated storage and Inspection transport. The remote suite checks the
dedicated entrypoint route before association and after backend replacement.
Focused backend checks after contract generation, from this package:

```sh
dart test test/chat_durable_state_test.dart test/chat_remote_backend_test.dart
dart test test/chat_feedback_test.dart
dart test test/chat_session_state_test.dart
dart analyze --fatal-infos lib bin test
```

The actual Project database and application composition are covered by their host
integration tests, not imported here.
