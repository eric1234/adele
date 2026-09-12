# adele_core_extensions

Experimental public, pure-Dart contracts for narrow core-owned extension points
that lack a natural existing public domain owner. This is not a catch-all for
plugin APIs or shared types. Its only current contract is project selection.
It depends on `adele_plugin_api`, not Flutter, product, application code, or
internal host implementations.

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
`String displayName` and `Future<Uri?> Function() selectProject`.
`projectSelectorContributions` is the typed extension point with stable identity
`dev.adele.extension.project-selectors`, used with the existing `ExtensionRegistry`.

Zero or multiple selectors are valid. Contributions have distinct `ExtensionId`
identities; display names are labels, not identities. There is no priority,
implicit default, or replacement selection policy.

Selection returns only a URI. Null means user cancellation, not an unavailable
selector or a suppressed error. Errors propagate. URIs are not restricted to
local files or directories. The host creates the Project; selectors do not
create Project identities, Tasks, Environments, Sessions, or Runs.

The host retains the exact discovered `ExtensionBinding` for invocation and
validates it both before calling the selector and before accepting a returned URI
or creating a Project. Cancellation remains a no-op. Retirement makes that binding
stale even if another contribution is registered under the same ID. Never
rediscover and substitute a replacement
during an in-flight selection. Binding validation remains host responsibility,
not a second registry or an invocation wrapper in this package.

Project persistence, recents, defaults/profiles, selection UI, and product
lifecycle coordination are outside this contract.

## Validation

After workspace dependency resolution, run
`dart tools/adele.dart test --target adele_core_extensions` from the repository
root. Tests exercise typed zero/multiple selection and cancellation, and exact
binding staleness across asynchronous selection and replacement.
