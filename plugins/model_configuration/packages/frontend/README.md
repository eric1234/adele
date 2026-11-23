# Model Configuration frontend

Model Configuration packages two independent presentations in `frontend.evc`.
See [choosing a Model Preset](../../README.md#choosing-a-model-preset) for the
user workflow.

## Settings editor

[`buildModelReferenceEditor`](lib/model_reference_editor.dart) edits the
`model` field through the [public field draft bridge](../../../../packages/ui/lib/settings_field_editor_bridge.dart).
The field displays the accepted pair and can resolve provider labels without
requesting a catalog. Its modal Model Browser reads available catalogs through
the [associated Capability bridge](../../../../packages/ui/lib/capability_bridge.dart).
Search, sorting, provider filters and draft row selection operate on loaded
observations, not on the network. Confirming a still-current row, or explicitly
confirming both IDs in manual entry, proposes one complete replacement against
the revision from which the browser opened. Dismissing the browser does not
propose anything. Only the form's Create or Save persists the draft. The editor
has no inference, Session, credential, configuration-store or sibling-field access.

The browser limits each observation to 64 configured providers and four pending
catalog calls. It retains up to 2,048 rows and 1 Mi UTF-16 units of row text
across catalogs; provider status indicates when the view is limited. IDs on
different providers remain distinct. Search and sorting cannot start requests.
Refresh discards the previous observation, not the accepted field value. No
catalog data is persisted, and no timer polls for availability.

The interpreted editor validates each provider's [catalog](../../../../packages/model_provider/README.md#model-catalog)
before offering any of its rows. Malformed reasoning-effort evidence rejects
that provider's observation, not a healthy sibling's. Valid evidence (unknown,
known empty, or an explicit ordered list) neither filters models nor changes
the preset's reasoning effort: **Use model** still proposes only the ID pair.

## Session selector

[`buildModelPresetSelector`](lib/model_configuration_frontend.dart) is a
separate interpreted `sessionAccessory`. The strategy
only mounts `execution-configuration`; it does not implement the selector.
The host can compose this control (order 200) after Agent Configuration (100),
or mount either control alone.

Each mount captures one Session ID and uses generated clients for two services
of its own installation: `modelPresetCatalog` and `modelPresetSelection`. It
has no Run preference service, provider lookup, or Project storage grant. A
choice carries the revision at which it was offered. Only the backend's
acknowledgement confirms a change; Refresh reads current state without replay.
Leaving the Session retires the presentation, not an already admitted backend
transaction. Returning creates a fresh observation.

The [frontend compiler](../../../../app/tool/model_configuration_frontend_compiler.dart)
generates eval clients from the plugin contract for the selector and the public
Model Catalog contract for the browser. From a bootstrapped checkout,
run `dart tools/adele.dart test --target model_configuration_frontend` for the
compiled widget tests, including an [editor test](test/model_reference_editor_eval_test.dart)
with the real Settings store and no installed backend. The [desktop integration fixture](../../../../app/test/core/model_preset_integration_test.dart)
exercises actual prepared components and Run capture.
