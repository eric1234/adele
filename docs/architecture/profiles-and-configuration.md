# Profiles and Configuration

## Status

ADELE profiles and general configuration management are accepted architectural direction but are not yet implemented. The maintained development runtime uses one implicit default development profile. There is no profile manager, selector, persistence model, profile-aware router, generic configuration service, or production workbench-state store.

This document records intended product and architecture direction beyond the immediate implementation horizon. ADR 0031 now defines `Project` as an abstract core identity and `Environment` as the practical filesystem/source + process context for Task work; the earlier Project/Workspace identity question is no longer intentionally open.

A profile is a named, sparse operating-mode layer. Profiles may contribute plugin activation decisions, configuration overrides, provider availability/preferences, and other profile-scoped behavior. Profiles are not plugin installations, provider configurations, accounts, runtime instances, Projects, Tasks, Sessions, or Environments.

See also:

- ADR 0029 for the accepted ordered-profile decision;
- ADR 0031 for Project/Task/Session/Environment direction;
- [`plugin-extension-model.md`](plugin-extension-model.md) for the recursive extension model.

## Goals

The intended model should support all of the following without forcing users to think in terms of plugin implementation details:

- A `Developer` profile can enable editors, diffs, terminals, SCM views, and other inspection-oriented tooling.
- A `Vibe` profile can deliberately expose a much smaller surface, such as primarily agent chat, while leaving omitted tooling installed for other profiles.
- A `Work` profile can add work-specific providers, policy, or configuration to another profile such as `Developer`.
- A `Personal` profile can similarly compose with the same development setup.
- One Project can normally reopen with `Developer + Work` while another reopens with `Developer + Personal`.
- Project- or resource-specific settings can override broader defaults when that setting meaningfully supports those scopes.
- Shareable configuration can use a stable human-readable form suitable for normal tooling/version control where appropriate.
- Settings UX is organized around user concepts rather than plugin ownership.
- Different open windows can present the same Project, Task, Session, Environment, or runtime resource with independent UI state.

The design should remain understandable for the common one- or two-profile case without imposing an arbitrary architectural limit on larger profile stacks.

## Distinct concepts

| Concept | Meaning |
| --- | --- |
| Installed plugin | Plugin source and compiled artifacts available to the ADELE installation |
| Profile | Named sparse layer of activation, configuration, availability, and preference decisions |
| Active profile stack | Ordered list of profiles applied to one window/context |
| Plugin activation | Whether an installed plugin is effectively active in a context |
| Configuration declaration | Host- or plugin-owned description of a stable setting and editing/validation metadata |
| Configuration override | Value intentionally supplied by one eligible configuration scope |
| Effective configuration | Result of resolving relevant configuration layers for a subject/context |
| Provider availability | Whether a configured capability instance may participate in a context |
| Provider preference | Host-owned preference among compatible available providers/configured instances |
| Configured capability instance | Persistent named account/provider/connection/endpoint/cluster/device configuration or similar plugin-managed instance |
| Plugin runtime instance | Running plugin created from an activation context; normally one per context |
| Configuration context | Opaque generation-bound runtime execution scope for configured plugin state shared by one or more capability providers/services |
| Project | Core persistent product identity selected/associated through replaceable Project providers/selectors |
| Task | Core durable unit of user intent within a Project |
| Session | Core orchestration container bound to one strategy |
| Environment | Task-associated practical filesystem/source + process context supplied by an Environment provider |
| Runtime resource | Temporary process, terminal, browser, document, connection, or active execution |
| Window state | Live presentation state owned by one open window/view context |
| Remembered workbench state | Persisted local state used to seed future windows without forcing existing windows to change |

Installation, activation, configuration, provider selection, runtime instances, configured instances, product identities, runtime resources, and UI state must remain distinct. They may evaluate against related context but must not collapse into one generic plugin-state object.

## Ordered profile stacks

A window/context may activate an ordered list of profiles. Profiles are flat; they do not inherit from or include other profiles. Where a domain uses normal precedence semantics, later profiles have higher precedence than earlier profiles.

For example:

```text
ADELE defaults
    |
user / all-profiles configuration
    |
Developer
    |
Work
    |
Project-specific configuration
```

`Developer + Work` and `Developer + Personal` are natural compositions. A profile should record only values for which it has an opinion rather than duplicate every value established by earlier layers.

ADELE should not impose an arbitrary small maximum profile count. The normal UX may optimize for one or two active profiles, but four or more remain valid. A profile should appear at most once in one stack, and UI must make ordering/precedence understandable.

Profiles should not activate/include other profiles. If repeated complex stacks eventually need a convenience abstraction, that should be a separate named stack/preset that expands to an explicit ordered profile list rather than another inheritance mechanism.

Plugin versions are not profile properties. Installation/source/build artifacts/generation availability belong to the ADELE installation/toolchain environment. Profiles control activation/configuration of available plugins rather than selecting conflicting installed versions as another cascade dimension.

## Remembering a Project's active profile stack

The active profile stack is window/context state with a remembered local default for reopening the same Project context.

If windows A and B start with `Developer + Work` and B changes to `Developer + Personal`, A remains on `Developer + Work`. The remembered value becomes `Developer + Personal`, so a subsequently opened window C starts with that stack. Later changes from A may replace the remembered value without mutating B/C.

A separate explicit temporary/try-without-remembering operation may be useful later, but persistence-by-default is the intended normal behavior.

The remembered profile stack is local ADELE state. It is not repository configuration other users automatically inherit.

Project is now an accepted core identity, but its concrete association need not be a filesystem root. A local-directory Project, remote/cloud Project, or another Project implementation can all have remembered profile state without changing profile semantics.

## Configuration layers

Ordinary settings should support layered resolution. A useful conceptual model is:

```text
host/plugin defaults
        |
user / all-profiles overrides
        |
ordered active profiles
        |
Project overrides
        |
optional narrower subject-specific overrides
```

Possible narrower subjects include resources/directories, Tasks, Sessions, Environments, or Runs, but they are not universal layers. A setting declaration determines which scopes are meaningful and legal.

Application theme, model account selection, formatter behavior, Agent instructions, Environment-specific execution configuration, and per-resource test settings do not necessarily share the same valid scope set.

A missing value means "inherit/continue resolving." An explicit `null`, where valid, is distinct from absence.

The host should retain provenance for effective values so UI/diagnostics can explain which layer supplied a value and which lower-precedence values were overridden.

## Context is shared; composition semantics are not universal

Profiles, Project context, resource context, Task/Session context, and runtime context provide common inputs to several host-owned resolvers. They do not imply one universal last-writer-wins algorithm.

At minimum, ADELE should treat these as distinct systems:

| Domain | Intended direction |
| --- | --- |
| Ordinary settings | Ordered override/cascade, with setting-specific merge rules where declared |
| Plugin activation | Sparse tri-state composition plus lifecycle/availability validation |
| Provider availability/preference | Host-owned filtering and deterministic/contextual preference resolution |
| Security/permissions/approvals/policy | Constraint/policy composition; not ordinary last-writer-wins settings |
| Extension applicability/ordering | Defined by each extension contract; not a configuration deep merge |
| Workbench/window state | Independent live window state with remembered persistence for future windows |
| Product/runtime state | Domain semantics rather than configuration inheritance |

A lower-trust Project/resource scope must not automatically weaken security merely because it is more specific. Exact security/policy composition remains deferred.

## Plugin activation

Profile activation should be sparse and effectively tri-state:

```text
unspecified / inherit
enabled
disabled
```

An unspecified profile has no opinion and resolution continues. A later explicit activation decision can override an earlier profile decision, subject to host validation and future policy constraints.

Installing a plugin never implies global activation. Activation is contextual and must not be stored as an intrinsic property of installed-plugin metadata.

When a plugin is effectively inactive in a context, its normal product surface should normally be absent:

- no plugin workbench/selection UI;
- no plugin Commands or suggested keybindings;
- no plugin-provided runtime capabilities;
- no plugin-defined active extension registrations;
- no plugin-contributed ordinary settings/custom settings UI.

Disabling a plugin must not delete its persisted configuration. Re-enabling should restore its contributions using previously stored values. From the user's perspective, however, an inactive plugin should largely cease to exist in that context rather than leave settings clutter.

ADELE still needs installation/activation metadata available without activating the plugin so host-owned plugin/profile management can show installed plugins and enable/disable them.

Plugins should not silently activate arbitrary other plugin implementations. Complementary behavior should normally use public typed interfaces and runtime discovery. Missing compatible providers/extensions should be diagnosable or simply make an affordance unavailable according to that extension contract.

## Settings declarations and UX

Each ordinary setting needs a stable technical identity/owner, but technical ownership should not dictate Settings organization. Plugins may contribute settings to product-oriented categories such as models/providers, editing/review, execution/Environment, source control, appearance, security/approvals, or other concepts.

The common case should be declarative. A setting declaration may eventually include:

```text
stable setting id
value type
label and description
default value
category/group/order/search metadata
allowed scopes
validation constraints
merge behavior
apply/restart behavior
sensitivity/portability metadata
```

The exact schema is deferred.

ADELE should provide native editors for common declarative types. A plugin may provide a custom settings editor when generic property editing would be poor UX, for example account management, model-provider setup, MCP server management, or complex approval rules.

A custom editor does not own configuration persistence. It edits through ADELE-owned APIs so scope selection, validation, transactions, provenance, reset/inheritance semantics, and persistence remain consistent.

Normal Settings UX should select the target editing scope at a higher level rather than putting a scope selector beside every control. For example, the user might edit `All Profiles`, `Developer`, `Work`, or `This Project`, with controls indicating inherited provenance.

Resetting an override removes that layer's value so normal resolution resumes; it does not copy the parent value into the child scope.

Resource/Environment/Session configuration, when supported, should be exposed contextually rather than forcing every user to reason about every possible scope at all times.

## Merge behavior

Simple scalar settings naturally use the more specific/later explicit value.

ADELE should not invent a universal deep-merge algorithm for arbitrary objects/lists. Replacement is the conservative default for compound values unless a setting explicitly declares well-defined merge semantics such as ordered union, append, keyed merge, or another domain-specific operation.

Complex persistent records may be better represented as separately identified records rather than one deeply nested setting.

Effective-value resolution should preserve provenance even when an explicit merge strategy combines values from multiple layers.

## Providers, accounts, credentials, and defaults

Configured capability instances remain distinct from profiles. One plugin runtime may expose several named accounts/providers/endpoints/clusters/connections/devices. Profiles can participate in deciding which configured instances are available and which compatible instance is preferred without duplicate plugin installs/runtime copies.

Availability and preference are separate. A profile may make a work account available, prefer it, do both, or do neither.

ADELE owns preferred-provider resolution. Providers cannot declare themselves globally primary.

The same host-owned default-selection concept may eventually apply to interchangeable extension interfaces beyond the currently implemented capability registry, such as choosing the default source-display provider or Environment provider. Exact generalized preference plumbing remains unimplemented.

Credentials/secrets are not ordinary configuration values. Ordinary configuration should reference a managed credential/configured instance rather than serialize the secret itself. Exact secure storage remains deferred.

## Persistence, portability, and schema evolution

Shareable or Project-version-controlled configuration should have a stable human-readable representation and remain editable through ADELE APIs/UI and ordinary tooling. This does not require every class of persistence to use the same textual storage mechanism.

Machine-local configuration, remembered UI state, caches, runtime state, and operational metadata may use another internal store. A future design may distinguish portable/local overlays at the same conceptual scope when needed.

Persisted configuration outlives individual plugin activations and may outlive plugin versions. Stable setting IDs, validation, deprecation, migration, and unknown-value preservation therefore matter. Exact migration protocols are deferred, but ADELE should not casually discard unrecognized persisted configuration merely because its owner is inactive/unavailable.

Plugin-owned domain state may use ADELE persistence facilities but is not automatically ordinary cascading configuration. Chat Session state, TODO progress, Task summaries, or artifact metadata have their own domain semantics.

External systems may remain authoritative where their persistence semantics are part of the feature; for example, Git staging may represent approved review hunks.

## Runtime application and stable snapshots

Changing persisted configuration and changing an already-running operation are separate concerns.

Settings may eventually declare/apply behavior such as:

- live for future observations in existing UI;
- next operation/Run/inference;
- plugin reconfiguration/restart;
- application restart.

Execution-sensitive work should normally use a stable resolved configuration/context snapshot rather than have provider selection, Agent/model choices, tool policy, or approval behavior mutate unpredictably halfway through an operation because another window changed Settings.

The same principle applies to structured inference composition: UI/model-tool changes made after a model invocation is resolved affect a subsequent invocation, not the in-flight one.

Exact snapshot/reconfiguration mechanics remain deferred.

## Workbench and window state

Workbench state is not ordinary configuration. Profiles influence which plugins/extensions exist, while splitter positions, selected tabs, view visibility, scroll position, and similar presentation state belong to windows/views.

Different windows over the same Project/Task/Session may have independent live workbench state while presenting shared underlying domain data.

ADELE should maintain remembered local workbench state used to initialize future windows. Once opened, each window owns an independent live copy. Changes write through to remembered state but do not push into already-open windows.

For example:

```text
remembered console height = 300

Window A opens -> 300
Window B opens -> 300
Window B changes to 400
  Window B = 400
  remembered = 400
  Window A remains 300

Window C opens -> 400
Window A changes to 200
  Window A = 200
  remembered = 200
  Window B and C remain 400

Window D opens -> 200
```

Persistence must be fine-grained enough that one window changing a sidebar width does not overwrite another window's newer remembered console height through a stale full-layout snapshot. Last-writer-wins is acceptable for concurrent writes to the same remembered property; unrelated properties should not overwrite one another.

The exact persistence key remains open. ADELE should be able to remember materially different arrangements for Project/profile contexts whose active plugin surfaces differ, but this document does not require the key to be exact Project ID + exact profile stack.

Changing active profiles can substantially change which semantic workbench extensions exist. UI extensions should therefore have stable identities, and remembered state for a temporarily unavailable extension may remain dormant so it can be restored when that extension returns.

Plugin-facing UI extension names should describe semantics rather than current physical position. A Session-status extension should remain the same extension if the stock layout moves it from right to left or makes placement user-configurable.

A future explicit operation may allow saving an arrangement as a profile/layout default. Ordinary splitter dragging should not silently become shared profile configuration.

## Runtime activation contexts

The intended default remains one plugin runtime per activation context, while activation-context lifecycle is not yet implemented. One active plugin generation may expose multiple configured capability instances through one or more explicit configuration contexts without requiring another plugin install/backend copy.

Each active capability endpoint executes under an explicit generation-bound configuration context. The context is runtime metadata derived from persistent configuration/activation decisions; it is not the persistent configuration record itself. Several providers/services may share a context when they operate over the same configured plugin state, and one generation may host several contexts.

Temporary terminals, browsers, documents, processes, Runs, and active tool executions remain runtime resources rather than profiles, persistent configured instances, or plugin runtime instances.

## Project, Task, Session, and Environment context

ADR 0031 supplies the product-domain identities that profile/configuration systems may use as contextual inputs:

- Project is an abstract persistent identity, not necessarily a directory.
- Task is the durable user-intent object.
- Session is permanently bound to an orchestration strategy.
- Environment is the practical filesystem/source + process context for Task work.

A Task normally has one primary Environment and may own additional Environments for child Session work. Environment lifecycle is not ordinary profile/configuration state; profiles/configuration may influence which Environment provider is available/preferred, while core Task lifecycle and the selected provider own Environment establishment/release/destruction semantics.

A separate first-class Workspace concept is not currently part of accepted architecture. It should be reintroduced only if concrete requirements show that Environment cannot cleanly represent an independent needed identity.

## Deferred decisions

This document intentionally does not settle:

- profile create/delete/import/export UX and persistence format;
- whether named profile-stack presets are useful;
- exact serialized configuration format or local store technology;
- portable-vs-local overlay mechanics;
- exact setting declaration/schema/migration APIs;
- exact complex-value merge strategies beyond conservative defaults;
- exact Project/resource/Task/Session/Environment override semantics;
- security/permission/policy constraint composition;
- credential storage/account-management APIs;
- dynamic plugin reconfiguration versus restart boundaries;
- exact provider/default matching and suitability policy;
- exact remembered-workbench-state keying/garbage collection;
- whether profile stack switching supports explicit non-remembered mode;
- implementation staging for the currently implicit development profile;
- generalized default-selection infrastructure for non-capability extension interfaces.

The product-domain identity question formerly deferred here is now governed by ADR 0031 rather than remaining undefined.
