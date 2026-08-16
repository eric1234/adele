# Profiles and Configuration

## Phase 0 status

ADELE profiles are planned but not implemented. Phase 0 and the initial Phase 1
proof use one implicit default development profile. There is no profile
package, profile manager, selector, persistence model, or profile-aware router.

An ADELE profile is a future named collection of plugin activation, optional
configuration overrides, and preferred capability providers. Provider
configurations are not profiles; call them provider configurations, provider
instances, accounts, connections, endpoints, clusters, or device
configurations as appropriate.

## Distinct concepts

| Concept | Meaning |
| --- | --- |
| Installed plugin | Plugin source and compiled artifacts available to the ADELE installation |
| Profile activation | Whether an installed plugin is enabled in one ADELE profile |
| Shared plugin configuration | Normal installation-level settings reused across profiles |
| Profile override | Optional differences applied for one profile |
| Effective configuration | Shared plugin configuration plus optional profile overrides |
| Preferred plugin provider | Profile preference among plugins that provide a capability |
| Preferred configured capability instance | Profile preference among named accounts/providers exposed by a plugin runtime |
| Plugin runtime instance | Running plugin created from an activation context; normally one per context |
| Configured capability instance | Persistent named provider, account, connection, endpoint, cluster, or device managed by a runtime |
| Configuration context | Opaque generation-bound runtime execution scope for configured plugin state shared by one or more capability providers/services |
| Runtime resource | Temporary session, document, process, connection, or active execution |

Installing a plugin does not enable it globally. Activation is contextual and
must not be stored as an intrinsic property of installed-plugin metadata.
Configuration, activation, runtime state, and temporary resources must not be
collapsed into a single plugin model.

## Configuration model

The default model is:

```text
shared plugin configuration
          +
optional profile overrides
          =
effective plugin configuration
```

Profiles should store only necessary differences rather than duplicate a
plugin's complete configuration. A plugin can therefore use common executable
paths, endpoints, defaults, or credential references while a profile changes
only selected behavior. Which fields can be overridden and how values merge
are not yet defined.

Compiled artifacts normally belong to the installation and toolchain context.
They should be reusable across profiles and configured capability instances
when source and build context are identical.

## Activation and providers

The default is one plugin runtime per activation context. A runtime can expose
multiple configured capability instances simultaneously. Profiles may
eventually control availability and preferences for both plugin providers and
configured instances without requiring duplicate installations or runtime
copies.

Each active capability endpoint executes under one explicit configuration
context. A context is runtime metadata bound to one plugin generation; it is
not the persistent configuration record itself. Several providers or services
may share a context when they operate over the same configured plugin state,
and one generation may host several contexts. Plugins with no meaningful
user-visible configuration still use one explicit default context. This does
not define persistence, profile override, configuration schema, or dynamic
configuration lifecycle.

Temporary browser or terminal sessions, open documents, processes, and active
tool executions are runtime resources. They are not profile configuration,
configured provider instances, or plugin runtime instances.

ADELE owns preferred-provider resolution. Profile preferences will be inputs
to that resolution, not provider declarations of global primacy. Exact
matching and precedence remain deferred.

## Possible scopes

Future configuration might involve installation, user, profile, workspace,
and session scopes. These names are possibilities, not an implemented model or
precedence order. Phase 0 does not define schemas, validation, nested-map
merging, list semantics, secrets, credentials, workspace overrides, or session
overrides.

## Deferred profile decisions

- Creation, deletion, persistence, launch selection, and switching.
- Simultaneous profiles, inheritance, templates, export, and sharing.
- Credential handling and profile-specific plugin versions.
- Workspace associations and profile-specific UI layouts.
- Configuration schemas, overridable fields, merge behavior, and validation.
- Preferred-provider matching, preference persistence, and precedence.
- Provider-instance availability, account management, and selection.

## Workspace terminology

The shell message `No workspace is open` does not establish a workspace model.
Workspace identity, roots, selection, state, and its relationship to profiles
remain intentionally undefined. `profile`, `workspace`, `project`, and
`environment` are not interchangeable; project and environment are not
foundational ADELE types in Phase 0.
