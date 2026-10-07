# adele_core_extensions

Experimental public, pure-Dart contracts for narrow core-owned extension points
that lack a natural existing public domain owner. This is not a catch-all for
plugin APIs or shared types. Its current contracts cover Commands, Project
selection, and provider backing preparation. It depends on public `adele_plugin_api`,
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

## Commands

[`commands.dart`](lib/commands.dart) defines semantic user operations independently
of presentation. `commandContributions` is the ordinary typed extension point
`dev.adele.extension.commands` in the existing `ExtensionRegistry`.
`CommandId` uses shared public-ID validation and names the stable operation;
`ExtensionId` names its registration, not its semantic identity.

`CommandContribution` carries one ID, a nonblank single-line label bounded to 160
UTF-16 code units, a cheap synchronous side-effect-free availability callback, and
a `FutureOr<void>` invocation callback. `CommandAvailability` distinguishes
`hidden` (irrelevant), `disabled` (relevant but unavailable), and `enabled`.
There is no generic Project/Session/Environment context or authority grant.

`CommandResolver` owns composition and dispatch admission. Zero registrations is
valid; distinct IDs coexist. Duplicate IDs are ambiguous regardless of their
availability, with no priority or winner. Discovery omits conflicted identities,
retains hidden/disabled entries for consumer filtering, and sorts by
case-insensitive label then ID. Explicit resolution distinguishes `CommandNotFound`
from `AmbiguousCommand`.

`ResolvedCommand` retains the exact `ExtensionBinding` and copied ID/label. Its
availability getter fails closed to disabled on evaluation failure, retirement,
or conflict. `invoke()` checks liveness, unique exact resolution, and current
enabled state immediately before entering the implementation; non-enabled or
failed evaluation yields `CommandUnavailable`. Reusing IDs or a contribution
object never retargets an old binding. Retirement after admission neither cancels
an asynchronous invocation nor migrates its completion. Implementation errors
propagate to the invoking surface for safe containment.

Registration supports native/in-process contributions and context-free remote
backend contributions, independently of Main Content, Console, or any frontend.
The [application palette](../../app/README.md#command-palette) is one consumer;
keybindings and other future input surfaces can use the same domain. Registration
changes use the existing registry stream; no general availability notification or
polling protocol is defined. Cross-system rules belong to
[Commands and input](../../docs/architecture/plugin-system.md#commands-and-input).

### Remote Commands

[`remote_command.dart`](lib/remote_command.dart) declares the generated unary
`RemoteCommandService.invoke(String routeId) -> Future<void>` service with ID
`dev.adele.command.remote` (`remoteCommandServiceId`). Backends dispatch it with
`RemoteCommandServiceDispatcher`; the app-private `RemoteCommandAdapter` uses
`RemoteCommandServiceClient` and registers ordinary `CommandContribution`s.
The native sibling is an ignored artifact configured in `contract_codegen.yaml`.

A backend advertises each Command through ordinary `AdeleExtensionExposure` at
`dev.adele.extension.commands`, with its own registration `extensionId`, the
supported `serviceId`, and `configurationContext`. Metadata contains exactly
`commandId`, `label`, and `routeId` strings. The adapter reuses `CommandId` and
`CommandContribution` validation; route IDs are 1-256 ASCII characters matching
`[A-Za-z0-9][A-Za-z0-9._:-]*`. A route is opaque backend-local implementation data,
not a Command, extension, plugin, configured-instance identity, or authority token.
Several advertised Commands can use one service/configuration context.

Remote availability is synchronous and local: enabled while that exact extension
registration/backend is live, failing closed through `ResolvedCommand` when stale
or ambiguous. There is no availability RPC, backend state projection, polling, or
invalidation event. A backend omits Commands that should not be exposed for that
generation. Invocation sends only the advertised route to the captured generated
service/configuration channel, without host context or services. It never retries
through a replacement or rejects successful completion merely because registration
retired after admission; transport termination can still fail in-flight requests.

Prepared-frontend Command hosting, dynamic contextual backend availability, and
keybindings remain unimplemented. No stock backend needs to advertise a Command;
the app's real-AOT probe tests the production adapter without inventing a stock
context-free operation.

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
root. Tests cover Command identity/composition/availability/admission and async
retirement, typed selection/cancellation, exact binding staleness, and the
generated provider and remote Command contracts. Host publication, confinement,
and backend ownership tests belong to the [app](../../app/README.md#focused-validation).
