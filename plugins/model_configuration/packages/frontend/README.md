# Model Configuration frontend

[`buildModelPresetSelector`](lib/model_configuration_frontend.dart) is the
interpreted `sessionAccessory` contributed by Model Configuration. The strategy
only mounts `execution-configuration`; it does not implement the selector.
The host can compose this control (order 200) after Agent Configuration (100),
or mount either control alone. See [choosing a Model Preset](../../README.md#choosing-a-model-preset)
for the user workflow.

Each mount captures one Session ID and uses generated clients for two services
of its own installation: `modelPresetCatalog` and `modelPresetSelection`. It
has no Run preference service, provider lookup, or Project storage grant. A
choice carries the revision at which it was offered. Only the backend's
acknowledgement confirms a change; Refresh reads current state without replay.
Leaving the Session retires the presentation, not an already admitted backend
transaction. Returning creates a fresh observation.

The [frontend compiler](../../../../app/tool/model_configuration_frontend_compiler.dart)
generates eval clients from the plugin contract and packages the widget in
`frontend.evc`, beside (not inside) `backend.aot`. From a bootstrapped checkout,
run `dart tools/adele.dart test --target model_configuration_frontend` for the
compiled widget tests. The [desktop integration fixture](../../../../app/test/core/model_preset_integration_test.dart)
exercises actual prepared components and Run capture.
