# Chat Contract

`chat_strategy_contract` is Chat's pure-Dart component contract, shared by its
backend and frontend. The production ADELE application does not import it.

It owns the plugin/strategy identities, `ChatEntryId` occurrence identity,
immutable canonical `ChatEntry` and `ChatSessionSnapshot` values, and
`ChatSessionService` and the dedicated read-only `ChatFeedbackInspectionService`.
It also exports the String `chatMaxModelInvocationsSettingId`
for explicit backend setting injection; its declaration belongs to the plugin's
[`settings.schema.json`](../../settings.schema.json), not Session state.
`ChatSessionSnapshot` contains `entries`, `instructions`,
and the required `String draftRequest`. The current Draft
Request representation is an exact String (Markdown for the rich frontend), not
AppFlowy JSON or a backend rich document model. The service does not normalize it.

`ChatEntry` requires `id`, `role`, `content`, nullable `String? runId`, and nullable
`ChatEntryFeedback? feedback`. Both nullable keys are required even when null.
Only a user entry may have a non-null Run
association; assistant entries and newly accepted, unassociated users carry null.
The value is a semantic Run ID, not an opaque view handle, execution authority, or
a promise of available terminal evidence. Backend association semantics belong to
the [backend map](../backend/README.md); frontend lookup uses the generic public
Session execution bridge rather than a Chat history/evidence service.

`ChatEntryFeedback` contains typed `ChatFeedbackKind kind`, `submissionId`, and
`commentCount`. It identifies an accepted structured occurrence from Chat's durable
submission relationship, never from message text. Ordinary user and assistant
entries have null metadata even when their content resembles feedback. Metadata
does not replace the original canonical content, order, occurrence ID, or Run
association. `chatFeedbackInspectionKind` identifies the Session-content Inspection
kind `dev.adele.chat.review-feedback`; occurrence identity remains Session-local.

`ChatFeedbackInspectionService.readAcceptedFeedback(sessionId, occurrenceId)`
returns `ChatAcceptedFeedback` through the separate `chat.feedbackInspection`
service. The service exposes no mutation, acceptance, or execution methods.
The result retains Session/occurrence/submission identities, kind, ordered comments,
and nullable current Run association. Comments retain exact text, identity,
version, sequence, and all historical anchor/provenance fields. The local typed
DTOs are a generated transport projection of public Session feedback semantics:
the generator only supports library-local schemas, while the public feedback
codec remains authoritative for canonical payload validation. There is no Chat
JSON codec or second persisted representation.

Retrieval fails with declared `ChatFeedbackInspectionFailure` codes
`invalid_request`, `not_found`, `unavailable`, or `corrupt`, never partial data.
Failure messages/details contain no private source or storage diagnostics. Valid
absence is distinct from unavailable storage, including missing schema, closed
Projects, and retired exact-generation infrastructure access. Retrieval does not
initialize storage, hydrate or refresh canonical caches, create receipts, change
drafts, or start Runs.

The service supports snapshot, direct `appendUserMessage`, atomic
instruction replacement through `configureSession(sessionId, instructions)`, and
two distinct draft operations:

- `setDraftRequest(sessionId, content)` replaces the draft exactly; empty and
  whitespace-only strings are valid intermediate editing states.
- `submitDraftRequest(sessionId)` atomically accepts the current draft as one
  canonical user entry and clears the draft. When `draftRequest.trim().isEmpty`
  is true, submission fails as `invalid_content`; nonblank content is not trimmed
  or normalized.

Accepted appends/submissions return the canonical entry, including its stable
Session-local ID. Direct append and configuration do not change the draft.
Assistant append and arbitrary history replacement are not public operations.

These operations retain the same frontend contract for durable and explicitly
volatile Sessions. For durable state, successful mutations acknowledge SQL commit
before returning canonical values. Snapshots remain on the previous canonical
state while a write or terminal assistant commit is pending. Storage/corruption
failures are not invalid-content/session failures and do not select volatile
fallback. Schema, hydration, and terminal-acknowledgement details belong to the
[backend](../backend/README.md), not this transport contract.
Draft edits and submissions share the existing Session mutation/execution fence.
Failed durable mutations leave canonical draft/history/counter unchanged; there
is no storage-error fallback or Run start implicit in draft restoration/submission.

`chat_strategy_contract.dart` is the annotated source of truth and retains
`part 'chat_strategy_contract.g.dart';`. Its native sibling is configured in
[`contract_codegen.yaml`](../../../../contract_codegen.yaml), is Git-ignored local
output rather than committed source, and supplies the native client, dispatcher,
codecs, and service ID. From the repository root:

```sh
# Materialize or update native contract siblings.
dart tools/adele.dart generate

# Verify existing local siblings without writing.
dart tools/adele.dart generate --check
```

The check fails when local output is missing or stale. Manual generation is
normally unnecessary: maintained bootstrap, analyze, test, and build/run flows
materialize output at their prerequisite boundary. See
[`contract_codegen`](../../../../packages/contract_codegen/README.md) and the
[toolchain workflow](../../../../docs/development/toolchain.md#generated-contract-artifacts).

EVC preparation uses `ContractGenerator.generateEvalClient` to derive a bounded
eval-compatible client directly from the same annotated declarations. That
projection is compiled into the EVC; it is not the native sibling or a second
hand-maintained semantic contract. No application-owned Chat codec exists.
This pre-release shape keeps transport version 1 and requires coherent artifact
rebuilds, without omitted-`runId`, omitted-feedback, omitted-draft, or old-wire compatibility reads.
The frontend supplies an `OwningBackendRequestChannel` for the explicitly
allowlisted service; native headless tooling can use the captured backend's
configuration-scoped channel. The service is plugin-internal, not a core extension
point or capability advertisement.

Entry IDs are opaque occurrence data, not core Product IDs or authority. Generic
Session/Run lifecycle, execution, approvals, frontend hosting, and Inspection stay
in ADELE public/core APIs. See the [plugin overview](../../README.md).
