# Model Configuration backend

The stock AOT entrypoint binds the generation's host-authorized configuration
reader and Project storage client. Its default configuration context dispatches
the two services in the [plugin contract](../contract/README.md) and the
orchestration contract's `runModelPreference`. The last is advertised as
`dev.adele.plugin.model-configuration.run-model-preference` with empty metadata.
It is an Extension, not a provider Capability.

Catalog reads project each preset's `model` field into a typed reference, retaining
`provider-id` and `model-id` together without resolving either. A flat or
malformed reference is not substituted or repaired. Selecting requires positive
evidence from a fresh catalog; an incomplete result can confirm a visible ID
but cannot prove absence. Reading or clearing the Session selection does not
consult configuration. Deleting a preset does not clear its ID in a Session or
change its revision.

Each canonical Session's optional preset ID and revision live in the plugin's
Project storage schema. No row means revision zero and no preference. The host
selects durable storage or explicitly temporary Project storage; the plugin
has no fallback. Each acknowledged conditional update (including clear and
reselect) advances the revision. On `outcome_uncertain`, read current state;
do not automatically retry.

`ModelPresetRunPreferenceBackend` uses those same selection and catalog services
in process. It returns null for a confirmed null selection, or projects the one
visible selected preset into a bounded semantic preference. Each new Run observes
the saved definition even if its Session selection and revision are unchanged.
Failed or incomplete reads never authorize another model. The backend neither
resolves providers nor stores Run state. See the
[Run capture boundary](../../../../docs/architecture/execution-model.md#run-model-preferences).
