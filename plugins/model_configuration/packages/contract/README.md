# Model Configuration Contract

The [contract source](lib/model_configuration_contract.dart) declares two
services on Model Configuration's owning backend. They are not Capabilities.
A selector can read both without resolving an executable model provider.

`modelPresetCatalog.readPresets` returns current definitions in stable record ID
order. Names are editable and need not be unique. An empty list is meaningful
only with its `isComplete` flag; unavailable access is a failure, not a list.
Provider and model IDs are authored strings, not live bindings. The generator
only accepts locally declared enums, so reasoning effort travels as a nullable
string checked against `ModelReasoningEffort` on the native side. Null means
unspecified; `none` is an explicit request.

`modelPresetSelection.readSessionSelection` returns the stored reference without
looking it up. Null at revision zero means untouched; null at a positive revision
means explicitly cleared. `updateSessionSelection` requires the observed revision.
A non-null choice needs a visible preset, even if the catalog is incomplete;
absence from an incomplete observation cannot establish that a preset is missing.
Deletion leaves the stored ID unresolved until replacement, clearing, or recreation.
An `outcome_uncertain` write needs a fresh read, not an automatic retry.

Neither service supplies a default or changes an active Run. Run capture uses
the separate [orchestration contract](../../../../packages/orchestration/README.md#run-model-preferences),
not a new method on the selector API. See the [plugin](../../README.md)
for storage ownership and the [generator](../../../../packages/contract_codegen/README.md)
for native and interpreted client generation.
