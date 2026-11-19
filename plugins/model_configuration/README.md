# Model Configuration

`dev.adele.plugin.model-configuration` contributes the **Model Presets** collection
to Global Settings. Its prepared installation contains only metadata and the
version-1 [record schema](records.schema.json). There is no backend, frontend,
provider registration, or runtime apply handler.

Each `dev.adele.plugin.model-configuration.preset` record in `model-presets`
has a user-chosen, immutable record ID. Use that ID, not the editable name, to
identify the preset. Names need not be unique.

| Field | Presence | Meaning |
| --- | --- | --- |
| `name` | Required string | Display name for the preset. |
| `description` | Optional string | Purpose or guidance. |
| `provider-id` | Required string | Stable `ProviderId` of one configured ModelProvider instance, not a vendor or plugin ID. |
| `model-id` | Required string | Exact, opaque identifier the selected provider expects. |
| `reasoning-effort` | Optional enum | Requested `ModelReasoningEffort`: `none`, `minimal`, `low`, `medium`, `high`, `xhigh`, or `max`. |

Omit `reasoning-effort` for no preference; `none` is an explicit request.
Saving checks field presence, scalar types and enum membership, not whether a
string is nonblank, a provider is running, a model is listed, or an effort is
supported. Saving does not read credentials, select a model for a Session, or
run inference.

The collection starts empty. Discovery and reads do not create preset files,
and deleting the last preset leaves it empty. Stock presets are deferred to a
future general configuration-defaults mechanism. For record identity, editing,
and resolution boundaries, see [Model Presets](../../docs/architecture/profiles-and-configuration.md#model-presets).
