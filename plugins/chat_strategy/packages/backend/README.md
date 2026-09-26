# Chat Backend

`chat_strategy_backend` owns canonical Chat history, Draft Request, configuration,
and sequencing. Its AOT entrypoint exposes the generated Chat Session service and the
existing remote orchestration service over one backend router and one retained
`ChatSessionStore`. It advertises only its orchestration strategy contribution.

The entrypoint requires the host's generation-bound `hostInfrastructureContext`
and injects a generated `ProjectStorageServiceClient` over the existing host-call
multiplexer. Construction makes no storage calls before ready. First Session
access deduplicates hydration, asks `isDurableSession`, and initializes or reads
the Chat-owned v1 relational baseline. The schema owner is the connection's exact
PluginId, `dev.adele.plugin.chat-strategy`, not a caller-supplied owner.
`adele_chat_sessions` stores instructions, positive invocation budget, the
next-entry counter, and `draft_request TEXT NOT NULL`, keyed by and referencing
`adele_product_sessions(id)`. Draft Request extends the current v1 baseline in
place; it does not add a migration or compatibility reader for development schemas.
`adele_chat_entries` stores ordered user/final-assistant occurrences with
Session-local unique entry IDs. Chat never writes core tables or JSON snapshots.

Hydration looks up the next expected `sequence` within the Session using the
existing composite index, without rescanning a history prefix. `LIMIT 2` detects
duplicate sequences if constraints are damaged; valid state returns one entry per
query, keeping individually readable rows within the response bound. An empty
result ends the contiguous lookup. A final retained-row count and the entry-counter
check reject hidden rows or gaps before publishing state. It validates the current
contiguous sequence/`entry-N` IDs, role, nonblank content, counter, budget, and
string draft. The counter starts at zero and is shared by both roles. Raw message,
draft, and instruction bytes are retained. Missing state is initialized to stock
instructions, budget eight, counter zero, and an empty draft. Invalid canonical row
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

`ChatSessionStore()` without a client is the explicit volatile fixture path.
With a client, only the host's explicit `isDurableSession == false` selects
volatile canonical state. `load` is asynchronous; synchronous `obtain`, state
setters, and direct native strategy execution cannot bypass durable writes.
`ChatStrategyPlugin` and standalone `ChatSessionState` retain their synchronous
volatile fixture behavior.

The strategy preserves ordered canonical user/final-assistant projection,
provider-native Run-local replay, sequential tool proposals, approval pauses,
refusals, and the positive model-invocation limit. Instructions and the limit are
captured at materialization; the default limit is eight and stock instructions
are backend-owned. Intermediate tool, native, reasoning, and narration items do
not enter canonical history.

`ChatSessionState` owns the generation-local exact draft string, exposed through
`ChatSessionSnapshot.draftRequest`. `setDraftRequest` replaces it exactly, including
empty or whitespace-only text, committing before updating memory. `submitDraftRequest`
rejects `trim().isEmpty` with declared `invalid_content`; nonblank text is never
normalized. Submission atomically inserts one canonical user entry, advances the
counter, and clears the draft in one SQL transaction, then updates memory and
returns the accepted occurrence. It does not start a Run. Direct `appendUserMessage`
and `configureSession` retain the draft; execution neither projects it into model
input nor consumes it. Volatile stores use these same semantics in memory only.

Service mutations hold the same Session claim while SQL is pending and are
rejected while another write or materialized execution owns it, including
approval waits and terminal acknowledgement. Configuration replaces both fields
in one SQL transaction before memory publication. Appends persist the candidate
entry and counter atomically before returning it. Expected row counts and prior
counter/configuration/draft predicates reject writes from stale generation caches.
Read-only snapshots and other Sessions remain available.
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
Retirement never causes an old frontend to attach to a replacement. Runs,
approvals, native replay, and activity remain non-durable.

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
Focused backend checks after contract generation, from this package:

```sh
dart test test/chat_durable_state_test.dart test/chat_remote_backend_test.dart
dart test test/chat_session_state_test.dart
dart analyze --fatal-infos lib bin test
```

The actual Project database and application composition are covered by their host
integration tests, not imported here.
