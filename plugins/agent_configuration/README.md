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
or change provider requests or tool authorization. Agents have no provider,
model, reasoning, or `defaultModelPresetId` fields.

## Stock templates

The files in [`stock/`](stock/) are the maintained source for five ordinary
version-1 records. The filename stem is the record ID, not a reserved name.

| Template | Intended role |
| --- | --- |
| [Ask](stock/ask.toml) | Answer questions and explain choices without treating a question as a request for edits. |
| [Requirements](stock/requirements.toml) | Refine an idea into a request with clear scope and observable acceptance criteria. |
| [Plan](stock/plan.toml) | Investigate the design, compare approaches, and propose steps for review. |
| [Code](stock/code.toml) | Implement a scoped change using project conventions and verify the result. |
| [Debug](stock/debug.toml) | Isolate a defect using evidence and verify a targeted correction when requested. |

These source templates are not installed or automatically provisioned. Discovering
the schema leaves the user's `agents` collection untouched; it may be empty.
Any records created from the templates belong to the user and can be edited or
deleted like any other Agent. Future provisioning must not overwrite user
modifications or recreate records the user deliberately deleted.

Focused coverage belongs to the existing `adele_tools` and `adele_settings_host`
test targets and `app/test/record_settings_dialog_test.dart`; see
[testing and validation](../../docs/development/testing.md#configuration-foundation-checks).
