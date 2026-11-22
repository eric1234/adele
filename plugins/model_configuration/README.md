# Model Configuration

`dev.adele.plugin.model-configuration` contributes the **Model Presets** collection
to Global Settings. The host discovers its version-1 [record schema](records.schema.json)
independently of backend activation, so editing does not require a running
backend. The [Session selector](packages/frontend/README.md) changes the
Session's choice; the [AOT backend](packages/backend/README.md) resolves that
choice when a new Run is prepared.

## Choosing a Model Preset

1. Open **Global Settings → Model Presets**. Add a record with a stable record
   ID, or edit an existing preset. Include **Name**, **Provider ID**, and **Model ID**.
   Type the Provider ID or use **Choose configured provider...**. If several rows
   have the same display name, compare their full IDs and owning plugins. Picking
   a row copies its stable Provider ID, not its name, into the unsaved field.
   Enter the model ID manually and check it for the chosen provider: the picker
   does not look up models or change the model ID or reasoning effort. **Create**
   or **Save** stores the definition; it does not select it for any Session.
2. In a Session that shows execution configuration, open **Model Preset** and
   choose the saved preset. Opening the choices reads the current catalog.
   **Refresh** rereads both the definitions and this Session's selection, for
   example after a change in another window. The displayed configuration is what
   the record requests, not a check that the provider or model is available.
3. To switch, choose a different preset. To clear, choose **No Model Preset**.
   This allows a direct model configuration to be used **if one is configured**.
   Changes apply to newly prepared Runs, not to an active Run awaiting approval.

**Refresh providers** rereads currently advertised routes, not the preset files.
A provider can be offline or registered later; you can keep or save its exact ID
even if the list is empty or discovery fails. Appearing in the list does not
mean the provider has authenticated or supports the model you enter.

**Missing Model Preset** means a complete catalog did not contain the selected
ID. **Unresolved Model Preset** means the catalog was incomplete or unavailable
and could not establish whether the ID exists. Neither changes the stored choice.
Refresh, select another visible preset, or clear the choice. Clearing needs a
readable selection, but not a readable catalog. If the selection itself is
unavailable, Refresh before making a change. If a change is **not confirmed**,
Refresh to see what was actually saved; the selector will not retry the write.

## Records and persistence

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

The plugin's [catalog and selection services](packages/contract/README.md) are
not provider Capabilities. Its separate Run preference service returns null only
after reading an unselected Session. Otherwise it reads the current catalog
once and returns the visible preset's exact provider/model/effort. Invalid
data, an unresolved reference, or unavailable storage fails capture. Installing
Model Configuration declares an expected source: an unavailable backend blocks
Run preparation, not Global Settings. The host binds the provider and reuses the
captured configuration across model/tool turns and approval waits. Editing or
clearing a preset cannot switch the active Run to another model. See
[Model Presets](../../docs/architecture/profiles-and-configuration.md#model-presets).
