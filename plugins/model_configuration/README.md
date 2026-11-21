# Model Configuration

`dev.adele.plugin.model-configuration` contributes the **Model Presets** collection
to Global Settings. The host discovers its version-1 [record schema](records.schema.json)
independently of backend activation, so editing does not require a running
backend. The [AOT backend](packages/backend/README.md) reads the definitions
and manages Session selections. There is no frontend or runtime apply handler.

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
and deleting the last preset leaves it empty. Each catalog read projects a
fresh host-authorized observation in record-ID order, without changing Settings
edit baselines. A partial observation can confirm the IDs it contains; only a
complete observation can establish that an ID is missing. A failed observation
is not an empty catalog.

The backend stores only the selected preset ID (or null) and revision for each
Session in its own Project storage table. An untouched Session has no row and
revision zero. Explicit updates, including reselecting or clearing, advance
the revision conditionally. Clearing and reading work without the catalog.
Deleting a definition leaves the stored ID intact; recreating that ID makes
it resolvable again. Durable Project storage survives reopen; volatile storage
has only its Project lifetime.

The [generated services](packages/contract/README.md) are for this plugin's
own frontend/backend boundary, not a provider Capability or a core model
catalog. Selection does not change a Run. See [Model Presets](../../docs/architecture/profiles-and-configuration.md#model-presets)
for the boundary between authored preferences and executable bindings.
