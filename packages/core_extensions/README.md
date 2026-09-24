# adele_core_extensions

Experimental public, pure-Dart contracts for narrow core-owned extension points
that lack a natural existing public domain owner. This is not a catch-all for
plugin APIs or shared types. Its current contracts cover Project selection and
provider backing preparation. It depends on public `adele_plugin_api`,
`adele_capabilities`, and `adele_contract`, not Flutter, product, SQLite,
application code, or internal host implementations.

## Ownership

Existing owners remain authoritative:

- `adele_plugin_api`: generic typed registration, discovery, retirement, and exact
  binding liveness.
- `adele_product`: shared product identities, values, and lifecycle invariants.
- `adele_orchestration`: strategy execution and inference-context composition.
- `adele_model_tool`: model-tool contributions and execution contracts.
- `adele_environment`: Environment provider and authorized filesystem/process
  contracts.
- Plugin-defined public API packages: extension ecosystems for concepts those
  plugins own, rather than moving their interfaces into core by default.

New contracts belong here only when a concrete core-owned need has no natural
existing public domain owner. Generic infrastructure is not duplicated here.

## Project Selection

`ProjectSelectorContribution` is a final value with a const constructor requiring
`String displayName`, `ProviderId projectProviderId`, and
`Future<Uri?> Function() selectProject`.
`projectSelectorContributions` is the typed extension point with stable identity
`dev.adele.extension.project-selectors`, used with the existing `ExtensionRegistry`.

Zero or multiple selectors are valid. Contributions have distinct `ExtensionId`
identities; display names are labels, not identities. There is no priority,
implicit default, or replacement selection policy.

The callback returns only a URI; `projectProviderId` names the backend semantics
to prepare that source. Null means user cancellation, not an unavailable
selector or a suppressed error. Errors propagate. URIs are not restricted to
local files or directories by the selection contract. Current durable backing has
the [host's narrower local-storage constraints](../../docs/architecture/product-model.md#project-storage).
The host opens the Project; selectors do not
create Project identities, Tasks, Environments, Sessions, or Runs.

The host retains the exact discovered `ExtensionBinding` and resolved
`ProviderBinding` through selection and backing preparation. It validates them
before selection, after selection, and after provider settlement. Retirement makes
the captured binding stale even if another contribution is registered under the
same ID; an in-flight selection never substitutes a replacement. Every prepared
selector requires the exact same-installation ready backend's capability
registration, not a semantic-ID match or optional affinity flag. See
[selector ownership](../../docs/architecture/plugin-system.md#project-selector-ownership).
Binding validation remains host responsibility, not a second registry in this package.

## Project Provider

[`project_provider.dart`](lib/project_provider.dart) declares
`ProjectProviderService.prepareSource(Uri sourceLocation) -> Future<ProjectBacking>`.
`ProjectBacking` contains the selected `Uri sourceLocation` and a portable
source-relative `String databaseRelativePath`. It describes backing, not an open
database, canonical Project, or grant of filesystem authority. The provider owns
source semantics and placement; the host independently validates the backing and
confines storage access. The contract contains no universal `.adele/data.db` path.

`projectProviderCapability` is `dev.adele.project.provider`, major version 1.
Generated `projectProviderServiceId` is also `dev.adele.project.provider`;
`ProjectProviderServiceClient` and `ProjectProviderServiceDispatcher` carry the
typed unary operation. Capability advertisement remains separate from declaring
the service. Provider selection for opening is explicit, with no default fallback.

The native `project_provider.g.dart` sibling is an ignored generated artifact.
Its source is listed in root `contract_codegen.yaml`; use the maintained
[generation workflow](../contract_codegen/README.md), not hand edits.
Lifecycle, SQL/schema/migrations, recents, defaults/Profiles, and selection UI are
outside this package. The [product model](../../docs/architecture/product-model.md#project-storage)
owns storage semantics; [Local Directory Project](../../plugins/local_directory_project/README.md)
maps the stock provider and selector.

## Validation

After workspace dependency resolution, run
`dart tools/adele.dart test --target adele_core_extensions` from the repository
root. Tests cover typed selection/cancellation, exact binding staleness, and the
generated provider contract. Host publication, confinement, and backend ownership
tests belong to the [app](../../app/README.md#focused-validation).
