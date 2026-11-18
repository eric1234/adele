# Agent Configuration

`dev.adele.plugin.agent-configuration` owns declarative Agent definitions, not
Agent execution. Its version-1 [`records.schema.json`](records.schema.json)
declares the `agents` collection (Agents) and record type
`dev.adele.plugin.agent-configuration.agent` (Agent).

| Field | Meaning | Presence |
| --- | --- | --- |
| `name` | Mutable display name, used as the record's display field. | Required |
| `description` | Summary of the Agent's purpose. | Optional |
| `when-to-use` | Guidance about when the Agent is appropriate. | Optional |
| `instructions` | Markdown instructions, stored as ordinary string data. | Required |

All fields are strings. Required means present, not nonblank. Optional absence
remains distinct from an explicitly empty string. The immutable record ID is
separate from the editable name; renaming does not change identity.

These are ordinary global configuration records managed by the existing generic
Global Settings UI and host persistence. See the
[configuration architecture](../../docs/architecture/profiles-and-configuration.md#declarative-configuration-records)
for identity, persistence, validation, and editing semantics. No custom editor,
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
Stock preparation publishes the schema and backend AOT together, with no frontend.
If the backend is unavailable the catalog cannot be read; the declaration and
ordinary Global Settings CRUD remain available independently.

Defining an Agent does not select one for a Session, start a Run, inject context,
or change provider requests or tool authorization. Stock default records and their
one-time provisioning, Model Preset references, Session selection, and context
injection are deferred. Collections may remain empty; no records are provisioned,
reserved, or recreated after deletion. Agents currently have no provider, model,
reasoning, or `defaultModelPresetId` fields.

For the package, stock publication, Settings and compiled-backend checks see
[testing and validation](../../docs/development/testing.md#configuration-foundation-checks).
