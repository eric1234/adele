# Model Configuration backend

The stock AOT entrypoint binds the generation's host-authorized configuration
reader and Project storage client. Its default configuration context dispatches
only the two services in the [plugin contract](../contract/README.md). They
exist for the plugin's own frontend/backend boundary, not as provider capabilities.

Catalog reads project the current `model-presets` records without resolving a
provider or model. Selecting requires positive evidence from a fresh catalog;
an incomplete result can confirm a visible ID but cannot prove absence.
Read and clear never consult configuration. Deleting a preset does not clear
its ID in a Session or change its revision.

Each canonical Session's optional preset ID and revision live in the plugin's
Project storage schema. No row means revision zero and no preference. The host
selects durable storage or explicitly temporary Project storage; the plugin
has no fallback. Each acknowledged conditional update (including clear and
reselect) advances the revision. On `outcome_uncertain`, read current state;
do not automatically retry. No selection changes Run execution.
