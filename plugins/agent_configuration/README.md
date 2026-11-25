# Agent Configuration

`dev.adele.plugin.agent-configuration` owns global Agent definitions and
Session-associated selected Agent identity, not Agent execution. Its version-1
[`records.schema.json`](records.schema.json)
declares the `agents` collection (Agents) and record type
`dev.adele.plugin.agent-configuration.agent` (Agent).

| Field | Meaning | Presence |
| --- | --- | --- |
| `name` | Mutable display name, used as the record's display field. | Required |
| `description` | Summary of the Agent's purpose. | Optional |
| `when-to-use` | Guidance about when the Agent is appropriate. | Optional |
| `instructions` | Agent instructions. Only this field declares `"editor": "markdown"`. | Required |

In **Global Settings > Agents**, choose **Add**. Enter **Name** directly and
write **Instructions** in the rich Markdown editor. Names must be nonblank and
free of ASCII controls; names need not be unique. The required Instructions
document may be empty. Enter **Description** or **When to Use** directly; leaving
either blank omits it. Choose **Create** to save the definition, not to select
it for a Session.
Settings generates the Agent's immutable ID. To copy it, open **Advanced details**
in Add or expand the saved Agent's details.

These are ordinary global configuration records managed by the existing generic
Global Settings UI and host persistence. See the
[record editing guide](../../docs/architecture/profiles-and-configuration.md#creating-and-editing-records)
for draft retention and recovery. No custom editor,
configuration scope, or persistence format is supplied here.

## Reading definitions

The [catalog contract](packages/contract/lib/agent_configuration_contract.dart)
exposes one operation: `AgentCatalogService.readAgents()`. Each call returns an
immutable snapshot in stable record-ID order. `instructions` is the configured
Markdown, uninterpreted; an absent `description` or `when-to-use` is returned as
null, not an empty string. `isComplete` distinguishes a clean observation (including
an empty collection) from one where the host omitted invalid records.

The [backend](packages/backend/README.md) reads current records from the host on
each call. Once a Settings edit succeeds, the next successful read sees the change
without restarting the backend. A failed read does not return an earlier snapshot.
Stock preparation publishes the schema, backend AOT, and selector frontend EVC
in the same installation.
If the backend is unavailable the catalog cannot be read; the declaration and
ordinary Global Settings CRUD remain available independently.

## Session selection

The separate generated `AgentSelectionService` exposes
`readSessionSelection(sessionId)` and
`updateSessionSelection(sessionId, selectedAgentId, expectedRevision)`. Its
immutable snapshot contains `sessionId`, nullable `selectedAgentId`, and `revision`.
A new Session reads as null at revision zero; there is no default Agent or
automatic selection. Every acknowledged update, including a clear or reselect,
advances the revision. Callers must supply a previously read revision.

Only the stable record ID is stored, never the name or instructions. Setting an ID
requires a fresh authorized catalog observation containing that Agent. An unseen
ID in an incomplete observation is not proven absent; unavailable configuration
fails rather than becoming an empty catalog. Reading or clearing a selection does
not require catalog access.

Renaming a definition leaves selection unchanged. Deleting it also leaves the
stored ID intact: selection is a Session preference, not ownership of the global
definition. It becomes an unresolved reference for later consumers to report, not
a reason to silently choose another Agent. Validation and persistence are not one
distributed transaction, so deletion can race an otherwise valid selection.

Durable Projects retain selections across backend replacement and Project reopen.
Explicitly volatile Projects use host-owned temporary backing for their live
Project lifetime. See the [backend map](packages/backend/README.md#selection-storage)
for the table, revision limits, and uncertain-write reconciliation. Missing or
failed Agent functionality does not block core Project or Session restoration.

### Choosing an Agent

Create definitions in **Global Settings > Agents**. In a Chat Session, open the
Agent control and choose a name, or choose **No Agent** to clear the stored ID.
The [prepared frontend](packages/frontend/) contributes
`dev.adele.plugin.agent-configuration.selector` at `execution-configuration`.
Any strategy mounting that [Session accessory location](../../packages/ui/README.md#session-accessories)
can show it; the strategy neither supplies the choices nor persists the result.

Opening the choices reads the live catalog. **Refresh** also rereads the
Session selection, including changes saved by another window. A complete catalog
can confirm a missing Agent; an incomplete or unavailable catalog cannot. None
of these observations clears the stored ID. The user may explicitly replace or
clear it, and an empty catalog does not provision a default.

The control writes against the revision it last read or received in an
acknowledgement. If a change is not acknowledged, it asks the user to refresh
before making another change. The interpreted bridge does not expose native
failure codes, so it does not guess whether a write conflicted or committed.
A fresh read shows the current state; it neither acknowledges the old request
nor retries it. Leaving the Session retires the control, not a transaction
already admitted by its backend.

## Instructions during a Run

Selecting an Agent does not start a Run and is not a model-callable operation.
When you submit a request, the active Agent backend captures the Session's
selected record ID for that Run. Changing or clearing the selection while the
Run is working or awaiting approval affects the **next Run**, not this one.
If it started with **No Agent**, it contributes no Agent instructions throughout.

For each model inference the backend resolves the captured ID in the current
catalog. Only its `instructions` enter the context, alongside the strategy's
instructions and other sources such as root `AGENTS.md`. Nonblank Markdown is
passed verbatim; empty or whitespace-only instructions contribute nothing.
Editing the effective Agent in Settings changes what the **next inference**
receives, even within the same Run. Already prepared requests do not change.

A partial catalog can supply a valid definition. If the captured ID is absent
from a complete or partial catalog, or the catalog cannot be read, inference
fails before calling the model. Nothing clears the Session preference or uses a
different Agent. A record re-created under the captured ID supplies its current
instructions. Agent selection changes neither model routing nor tool authority.

Stock default records and their one-time provisioning and Model Preset references
remain deferred. Collections may remain empty; no records are provisioned,
reserved, or recreated after deletion. Agents currently have no provider, model,
reasoning, or `defaultModelPresetId` fields.

For the package, stock publication, Settings and compiled-backend checks see
[testing and validation](../../docs/development/testing.md#configuration-foundation-checks).
