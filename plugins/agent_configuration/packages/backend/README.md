# Agent Configuration backend

[`bin/agent_configuration_backend.dart`](bin/agent_configuration_backend.dart)
registers the generated `agentCatalog`, `agentSelection`, and
`runBoundInferenceContextSource` dispatchers on the same shared AOT backend's
default configuration context. The [Agent contract](../contract/lib/agent_configuration_contract.dart)
returns global definitions and Session selection data. The separate inference
service consumes those same implementations; none exposes a Capability.

The prepared backend opts in to exactly `dev.adele.plugin.agent-configuration.agent`
from its [installation's schema](../../records.schema.json), and to no credential
slots. Its `AdeleConfigurationClient` is bound to the infrastructure context of
the generation the host started. Each `readAgents()` calls `currentRecords()`;
there is no startup-value fallback, record store, or cache in the plugin. The host
owns validation and I/O. The backend projects the `agents` records to public
definitions without altering their strings.

A partial read returns the healthy definitions with `isComplete: false`, even if
none remain. This differs from a clean empty snapshot (`isComplete: true`) and
from failure. If live access fails or the response does not match the authorized
projection, the active service returns a bounded `AgentCatalogFailure` without
record contents or host diagnostics. If the backend itself is missing or retires,
the service is unavailable; Global Settings still owns editing, and Chat and
Project restoration do not depend on this service.

## Selection storage

`AgentSelectionBackend` uses the generation-bound `ProjectStorageServiceClient`
through the same infrastructure channel. Its v1 owner migration creates only
`adele_agent_selections(session_id, selected_agent_id, revision)`.
`session_id` is a primary key and foreign key to `adele_product_sessions(id)`;
`selected_agent_id` is a nullable scalar global record ID, not a foreign key to
configuration files. The host derives schema ownership from the existing
`dev.adele.plugin.agent-configuration` installation. No core, Chat, or Run rows
are mutated.

There is no selection or schema cache. Each operation validates the published
Session through host storage, lazily ensures the owner schema, and reads the
authoritative row. No row means null/revision zero. Stored revisions are integers
from 1 through `AgentSelectionLimits.maxRevision` (2,147,483,647); exhaustion fails
before writing. Snapshots bound Session IDs to 512 code units and validate Agent
IDs with the public configuration-record identity contract. Invalid stored data
fails explicitly without repair or reset.

Updates use conditional SQL with an expected-row assertion inside one host
transaction. The first insert is protected by the Session primary key; later
updates require the expected revision. Every acknowledged mutation advances it,
including reselecting the same ID or clearing an already empty selection. Clears
retain the row to prevent stale writers from confusing cleared state with an
untouched Session. The ordinary generated dispatcher serializes calls within one
generation; SQL still protects against overlapping writers from other instances.

A detected prewrite mismatch returns `stale_revision`. Invalid requests, missing
Agents in complete observations, incomplete catalog observations, unavailable
catalog/storage, corruption, and exhausted revisions have distinct bounded failure
codes. Once a transaction is submitted, any failure is `outcome_uncertain`, even
when a row-count conflict may have caused host rollback: the existing void
transaction transport does not certify that distinction to the caller. Success
is returned only after acknowledgement. There is no hidden retry; callers must
read again to reconcile, and a later read is not an acknowledgement of the failed
request. Failures contain no SQL, paths, instructions, or host diagnostics.

`durableOrTemporary` retains durable data across reopen and explicitly volatile
data across backend replacement within the live Project lifetime. Durable failures
never select temporary or in-memory fallback. Retirement revokes the old storage
grant; a replacement reads the same data with a fresh grant, without retargeting
old clients. See [plugin-owned persistence](../../../../docs/architecture/plugin-system.md#plugin-owned-state-and-persistence)
for the shared host lifecycle boundary.

## Inference source

The ready advertisement contributes `dev.adele.plugin.agent-configuration.instructions`
to `dev.adele.extension.inference-context-sources` with `failureMode: required`.
`AgentInferenceContextBackend.captureRun` reads `AgentSelectionService` once. A
null selection returns an empty list without a catalog read. Otherwise it calls
`AgentCatalogService.readAgents()` once and resolves the exact record ID. Nonblank
instructions return one `RemoteInferenceInstruction` with key `instructions`, the
original Markdown, and null revision; blank instructions return an empty list.
Read failures and unresolved IDs fail the capture without a selection write.

Both reads use existing generation-scoped infrastructure. There is no host
invocation token, Environment access, private Run map, or executable Run handle.
The [host owns the capture](../../../../docs/architecture/execution-model.md#inference-preparation);
continuations make no request to this backend. See the [plugin map](../../README.md#instructions-during-a-run)
for selection and definition changes during a Run.
