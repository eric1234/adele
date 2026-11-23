# Model Configuration frontend

Model Configuration packages two independent presentations in `frontend.evc`.
See [choosing a Model Preset](../../README.md#choosing-a-model-preset) for the
user workflow.

## Settings editor

[`buildModelReferenceEditor`](lib/model_reference_editor.dart) edits the
`model` field through the [public field draft bridge](../../../../packages/ui/lib/settings_field_editor_bridge.dart).
Its two text inputs read the current pair and propose one complete replacement
against the observed revision. An incomplete pair stays local to the widget;
an incomplete or rejected edit does not replace an already accepted draft.
Only the form's Create or Save button persists the draft. The editor has no
Session, backend, provider catalog, credential, or sibling-field access.

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
generates eval clients from the plugin contract for the selector; the Settings
editor needs only its own bridge. From a bootstrapped checkout,
run `dart tools/adele.dart test --target model_configuration_frontend` for the
compiled widget tests, including an [editor test](test/model_reference_editor_eval_test.dart)
with the real Settings store and no installed backend. The [desktop integration fixture](../../../../app/test/core/model_preset_integration_test.dart)
exercises actual prepared components and Run capture.
