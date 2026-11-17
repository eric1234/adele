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

Stock preparation in [`tools/backend_artifacts.dart`](../../tools/backend_artifacts.dart)
publishes this schema byte-for-byte in a metadata-only installation with an empty
`components` object. There is no executable backend or frontend, Dart workspace
package, service, or runtime consumer. The existing prepared catalog discovers the
declaration without executing plugin code.

Defining an Agent does not select one for a Session, start a Run, inject context,
or change provider requests or tool authorization. Stock default records and their
one-time provisioning, Model Preset references, Session selection, and context
injection are deferred. Collections may remain empty; no records are provisioned,
reserved, or recreated after deletion. Agents currently have no provider, model,
reasoning, or `defaultModelPresetId` fields.

Focused coverage belongs to the existing `adele_tools` and `adele_settings_host`
test targets and `app/test/record_settings_dialog_test.dart`; see
[testing and validation](../../docs/development/testing.md#configuration-foundation-checks).
