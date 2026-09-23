# ADELE Plugin API

`adele_plugin_api` is an experimental public, pure-Dart package for plugin
identity, generic typed extension registration/discovery, and exact binding
liveness. Its APIs are not stable. The public entrypoint is
[`adele_plugin_api.dart`](lib/adele_plugin_api.dart).

| Surface | Local responsibility |
| --- | --- |
| `PluginId`, `validateAdelePublicId` | Plugin identity and shared public-ID validation. |
| `PluginMetadata` | Descriptive plugin identity, version, and display data. |
| `ResourceRef` | A resource URI and optional media type, without resource-resolution behavior. |
| `LiveObjectRegistry<Id, Value>` | Component-local in-memory ID-to-object bindings. |
| `ExtensionPoint<T>`, `ExtensionId`, `ExtensionRegistry` | Typed contribution points, registration identities, and live registration/discovery. |
| `ExtensionBinding<T>`, `ExtensionRegistration`, `ExtensionRegistrationGroup` | Exact registration-bound access, retirement, and grouped cleanup. |

## Dependencies

It may depend only on lightweight public plugin-facing packages when a concrete
need exists. It must not depend on Flutter or internal packages such as
`plugin_runtime`, `plugin_builder`, `agent_kernel`, or `adele_desktop`.

## Boundaries

`PluginId` is distinct from a Dart package name, display name, repository name,
capability ID, extension registration ID, and runtime generation. Plugin versions
are opaque strings in the maintained API; parsing, comparison, and ranges are
intentionally absent.

`PluginMetadata` does not contain activation, global enablement, configuration,
profile state, runtime-instance state, or configured provider instances.
`ResourceRef` uses `Uri` so identity is not tied to local filesystem paths.
`LiveObjectRegistry<Id, Value>` is deliberately only an in-memory binding for
live component objects. It is not persistence, a global object graph, or a
provider lifecycle abstraction; unbinding does not dispose objects or invalidate
previously returned references.

### Extension Registry

[`ExtensionRegistry`](lib/src/extension_registry.dart) keeps one exact contribution
type per point ID and permits at most one active registration of each
`ExtensionId` within that point. A point may have multiple distinct contribution
IDs. Discovery returns an unmodifiable snapshot of `ExtensionBinding<T>` values
bound to exact registrations, not merely their semantic IDs.

Closing an `ExtensionRegistration` retires only that registration and immediately
makes its bindings stale. Access through `value` or `validate()` throws
`StaleExtensionBinding`; reusing the ID or contribution object never retargets
them to a replacement. `ExtensionRegistrationGroup` provides idempotent,
reverse-order cleanup, not transactional activation. The asynchronous `changes`
stream signals registration/retirement changes so consumers can rediscover;
it is not a replay log or automatic binding refresh.

The generic registry does not define a point's cardinality, priority, selection,
composition, ordering, applicability, or failure policy. Those semantics belong
to the point/domain. See the [plugin system](../../docs/architecture/plugin-system.md)
for the cross-system composition and liveness rules.

Registry behavior is covered by the [package tests](test/).

Other concerns have separate owners:

- Installation/prepared manifests: [plugin layout](../../docs/architecture/plugin-layout.md).
- Profiles/configuration: [profiles and configuration](../../docs/architecture/profiles-and-configuration.md).
- Backend hosting: [plugin runtime](../plugin_runtime/README.md).
- Host-service authority: [operation-scoped host calls](../../docs/architecture/contracts-and-capabilities.md#operation-scoped-host-calls).
- Capability provider resolution: [capabilities](../capabilities/README.md).
- Concrete extension contracts: their domain packages, such as [orchestration](../orchestration/README.md), [model tools](../model_tool/lib/adele_model_tool.dart), and [UI](../ui/README.md).

## Deferred

Generic registration/discovery and binding retirement are implemented. They do
not establish general plugin-context APIs, profile-aware activation/configuration,
or resource-scheme resolution; those broader mechanisms remain incomplete or
outside this package's responsibility.
