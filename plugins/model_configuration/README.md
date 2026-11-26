# Model Configuration

`dev.adele.plugin.model-configuration` contributes the **Model Presets** collection
to Global Settings. The host discovers its version-1 [record schema](records.schema.json)
independently of backend activation, so editing does not require a running
backend. Its [prepared frontend](packages/frontend/README.md) supplies the model
reference editor, preset form behavior, and a separate Session selector. The
selector changes the Session's choice; the [AOT backend](packages/backend/README.md)
resolves that choice when a new Run is prepared.

## Choosing a Model Preset

1. Open **Global Settings → Model Presets**. Choose **Add** or edit an existing
   preset. Enter a **Name**. Choose **Browse models...** to see models across
   configured providers. Search the loaded results, filter by provider, or
   click a column header to change the sort. The same model on Work and
   Personal is two choices. Select a row and choose **Use model**. This changes
   the unsaved pair; canceling the browser leaves it alone. Leave **Reasoning Effort**
   at **Provider default** or choose an explicit effort. **Create** or **Save**
   stores the draft; neither selects it for a Session.
2. In a Session that shows execution configuration, open **Model Preset** and
   choose the saved preset. Opening the choices reads the current catalog.
   **Refresh** rereads both the definitions and this Session's selection, for
   example after a change in another window. The displayed configuration is what
   the record requests, not a check that the provider or model is available.
3. To switch, choose a different preset. To clear, choose **No Model Preset**.
   This allows a direct model configuration to be used **if one is configured**.
   Changes apply to newly prepared Runs, not to an active Run awaiting approval.

Only explicit browsing and refresh request catalogs. One provider's missing or
failed catalog does not prevent using a healthy sibling. If the provider has no
catalog, choose **Enter manually**, choose the configured instance and enter the
exact model ID. **Enter provider ID instead** also works for unresolved or
offline references. A syntax error identifies the invalid property and leaves
the browser open for correction or Cancel, without changing the accepted pair
or effort choices. Confirmation does not verify model support or authentication.
If the plugin frontend is unavailable, Settings does not
substitute a native control; unrelated fields and an existing valid reference
remain intact.

The effort dropdown stays disabled until you select a model. A catalog row can
report supported efforts, including an empty list (Provider default only).
Manual references, saved presets reopened without a fresh observation, and
catalog rows without effort information allow all declared efforts, marked
unverified. Browse and confirm the same pair to obtain its current observation.
If the current effort is not supported, the form warns but retains it; you can
leave it unchanged, choose a supported effort, or choose Provider default. Only
changing to a **different** pair known not to support that effort resets it to
Provider default, with an explanation. Cancel discards the change.

**Missing Model Preset** means a complete catalog did not contain the selected
ID. **Unresolved Model Preset** means the catalog was incomplete or unavailable
and could not establish whether the ID exists. Neither changes the stored choice.
Refresh, select another visible preset, or clear the choice. Clearing needs a
readable selection, but not a readable catalog. If the selection itself is
unavailable, Refresh before making a change. If a change is **not confirmed**,
Refresh to see what was actually saved; the selector will not retry the write.

## Records and persistence

Each `dev.adele.plugin.model-configuration.preset` record in `model-presets`
has an immutable record ID, distinct from its editable provider and model IDs.
Settings generates the preset ID independently of the Name. A new preset named
`Fast` starts at `model-presets/fast.toml`; if that filename is occupied, choose
a different Name. Editing a saved Name never moves the file, so presets in
different files can share a display name. The Session references the preset's
`recordId` from the TOML header, not its Name or filename. See the
[record editing guide](../../docs/architecture/profiles-and-configuration.md#creating-and-editing-records)
for draft retention and recovery.

| Field | Presence | Meaning |
| --- | --- | --- |
| `name` | Required string | Nonblank display name without ASCII controls. |
| `description` | Optional string | Purpose or guidance. |
| `model` | Required struct | `provider-id` and `model-id`, both required strings. The pair is edited and validated as one field. |
| `reasoning-effort` | Optional enum | Requested `ModelReasoningEffort`: `none`, `minimal`, `low`, `medium`, `high`, `xhigh`, or `max`. |

Provider default omits `reasoning-effort`; `none` is an explicit request.
The pair is persisted under `[values.model]`, distinct from the preset's own
identity. Old top-level `provider-id` and `model-id` fields are not an alternative
representation: a record without `model` is invalid, not silently migrated.
The provider ID must be an ADELE public ID, and the model ID must be nonblank
and free of ASCII controls. Each is limited to 1,024 UTF-16 code units; neither
is normalized. Settings validates these declarations, not whether
a provider is running, a model exists, or an effort is supported. Saving does
not read credentials, choose a preset for a Session, or run inference.

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
Deleting a definition leaves the stored ID intact. Creating a new preset with
the same Name in Settings generates a new ID and does not repair that selection.
Durable Project storage survives reopen; volatile storage
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
