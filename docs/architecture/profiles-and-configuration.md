# Profiles and Configuration

## Status

ADELE profiles and general configuration management are planned but not yet
implemented. The maintained development runtime uses one implicit default
development profile. There is no profile manager, selector, persistence model,
profile-aware router, generic configuration service, or workbench-state store.

This document records intended product and architecture direction beyond the
immediate implementation horizon. It deliberately leaves exact storage formats,
final project/workspace identity, migration mechanics, security-policy
composition, and several runtime lifecycle details open.

A profile is a named, sparse operating-mode layer. Profiles may contribute
plugin activation decisions, configuration overrides, provider availability and
preferences, and other profile-scoped behavior. Profiles are not plugin
installations, provider configurations, accounts, runtime instances, or
projects.

## Goals

The intended model should support all of the following without forcing users to
think in terms of plugin implementation details:

- A `Developer` profile can enable editors, diffs, terminals, SCM views, and
  other inspection-oriented tooling.
- A `Vibe` profile can deliberately expose a much smaller surface, such as
  primarily agent chat, while leaving the omitted tooling installed for other
  profiles.
- A `Work` profile can add work-specific providers, policy, or configuration to
  another profile such as `Developer`.
- A `Personal` profile can similarly compose with the same development setup.
- One project can normally reopen with `Developer + Work` while another reopens
  with `Developer + Personal`.
- Project- or resource-specific settings can override broader defaults when that
  setting meaningfully supports those scopes.
- Shareable configuration can be represented in a stable, human-readable form
  suitable for normal tooling and version control where appropriate.
- Normal settings UX is organized around user concepts rather than around the
  plugins that technically own each setting.
- Different open windows can present the same project, task, session, or runtime
  resource with independent UI state.

The design should remain understandable with the common one- or two-profile
case while not imposing an arbitrary architectural limit on larger profile
stacks.

## Distinct concepts

| Concept | Meaning |
| --- | --- |
| Installed plugin | Plugin source and compiled artifacts available to the ADELE installation |
| Profile | Named sparse layer of activation, configuration, availability, and preference decisions |
| Active profile stack | Ordered list of profiles applied to one window/context |
| Plugin activation | Whether an installed plugin is effectively active in a context |
| Configuration declaration | Host- or plugin-owned description of a stable setting and its editing/validation metadata |
| Configuration override | Value intentionally supplied by one eligible configuration scope |
| Effective configuration | Result of resolving relevant configuration layers for a subject/context |
| Provider availability | Whether a configured capability instance may participate in a context |
| Provider preference | Host-owned preference among compatible available providers or configured instances |
| Configured capability instance | Persistent named account, provider, connection, endpoint, cluster, device configuration, or similar plugin-managed capability instance |
| Plugin runtime instance | Running plugin created from an activation context; normally one per context |
| Configuration context | Opaque generation-bound runtime execution scope for configured plugin state shared by one or more capability providers/services |
| Runtime resource | Temporary session, document, process, connection, terminal, browser, or active execution |
| Window state | Live presentation state owned by one open window/view context |
| Remembered workbench state | Persisted local state used to seed future windows without forcing existing windows to change |

Installation, activation, configuration, provider selection, runtime instances,
configured capability instances, runtime resources, and UI state must remain
distinct. They may evaluate against related context but must not be collapsed
into one generic plugin-state object.

## Ordered profile stacks

A window/context may activate an ordered list of profiles. Profiles are flat;
they do not inherit from or include other profiles. Where a domain uses normal
precedence semantics, later profiles in the stack have higher precedence than
earlier profiles.

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
project-specific configuration
```

`Developer + Work` and `Developer + Personal` are therefore natural
compositions. A profile should normally record only values for which it has an
opinion rather than duplicate every value established by earlier layers.

ADELE should not impose an arbitrary small maximum profile count. The normal UX
may optimize for one or two active profiles, but four or more profiles remain a
valid ordered stack. A profile should appear at most once in one stack, and the
UI must make ordering/precedence understandable when several profiles are
present.

Profiles should not themselves activate/include other profiles. If repeated
complex stacks eventually need a convenience abstraction, that should be a
separate named stack/preset that expands to an explicit ordered profile list,
not another inheritance mechanism.

Plugin versions are not intended to be profile properties. Plugin installation,
source, build artifacts, and generation availability belong to the ADELE
installation/toolchain environment. Profiles control activation and
configuration of available plugins rather than selecting conflicting installed
versions as another cascade dimension.

## Remembering a project's active profile stack

The active profile stack is window/context state with a remembered local default
for reopening the same development context. In ordinary use, changing the stack
in a project window should immediately become the stack that a newly opened
window for that project starts with.

Existing windows remain stable. If windows A and B both start with
`Developer + Work` and window B changes to `Developer + Personal`, window A
continues using `Developer + Work`. The remembered state becomes
`Developer + Personal`, so a subsequently opened window C starts with that
stack. If window A later changes its own stack, that later change becomes the
new remembered value without mutating B or C.

A separate explicit temporary/try-without-remembering operation may be useful
later, but persistence-by-default is the intended normal behavior.

The association between a development context and its remembered profile stack
is local ADELE state. It is not, by default, repository configuration that other
users should inherit.

Final `Project`/`Workspace` identity, multi-root behavior, and lifecycle remain
outside this document. References to a project below mean a future persistent
development context, not a decision that project identity equals one filesystem
root.

## Configuration layers

Ordinary settings should support layered resolution. A useful conceptual model
is:

```text
host/plugin defaults
        |
user / all-profiles overrides
        |
ordered active profiles
        |
project overrides
        |
optional narrower subject-specific overrides
```

Possible narrower subjects include directories/resources and sessions/runs, but
they are not universal layers. A setting declaration determines which scopes
are meaningful and legal for that setting. Application theme, model account
selection, formatter behavior, agent instructions, and per-directory test
configuration do not necessarily share the same valid scope set.

A missing value means "inherit/continue resolving." An explicit `null`, where
`null` is a valid value, is distinct from absence.

The host should retain provenance for effective values so the UI and diagnostics
can explain which layer supplied a value and which lower-precedence values were
overridden.

## Context is shared; composition semantics are not universal

Profiles, project context, resource context, and runtime context provide common
inputs to several host-owned resolvers. They do not imply one universal
last-writer-wins algorithm.

At minimum, ADELE should treat these as distinct systems:

| Domain | Intended direction |
| --- | --- |
| Ordinary settings | Ordered override/cascade, with setting-specific merge rules where explicitly declared |
| Plugin activation | Sparse tri-state composition plus lifecycle/availability validation |
| Provider availability and preference | Host-owned availability filtering and deterministic preference resolution |
| Security, permissions, approvals, policy | Constraint/policy composition; not assumed to be ordinary last-writer-wins settings |
| Workbench/window state | Independent live window state with remembered persistence for future windows |
| Runtime/session data | Domain/runtime semantics rather than configuration inheritance |

A lower-trust project or resource scope must not automatically be able to weaken
security policy merely because it is more specific than a user/profile scope.
Exact security and policy composition remains deferred.

## Plugin activation

Profile activation should be sparse and effectively tri-state:

```text
unspecified / inherit
enabled
disabled
```

An unspecified profile has no opinion and resolution continues. A later explicit
activation decision can override an earlier profile decision, subject to host
validation and any future policy constraints.

Installing a plugin never implies global activation. Activation is contextual
and must not be stored as an intrinsic property of installed-plugin metadata.

When a plugin is effectively inactive in a context, its product surface should
normally be absent from that context:

- no plugin workbench views or commands,
- no plugin-provided runtime capabilities,
- no plugin-contributed ordinary settings or custom settings UI.

Disabling a plugin must not delete its persisted configuration. Re-enabling the
plugin should restore its contributions using the previously stored values.
From the user's perspective, however, a disabled plugin should largely cease to
exist in that profile/context rather than leave behind settings clutter.

ADELE still needs installation/activation metadata that is available without
activating the plugin so a host-owned plugin/profile-management surface can show
installed plugins and enable or disable them. That does not require exposing the
plugin's normal settings UI while disabled.

Plugins should not silently activate arbitrary other plugin implementations.
Dependencies on functionality should be expressed through public capabilities;
missing required capabilities should be diagnosable rather than resolved by
hidden plugin-activation chains.

## Settings declarations and UX

Each ordinary setting needs a stable technical identity and owner, but technical
ownership should not dictate Settings UI organization. Plugins may contribute
settings to host-defined conceptual categories such as models/providers,
editing/review, execution, source control, appearance, security/approvals, or
other product-oriented groups.

The common case should be declarative. A setting declaration may eventually
include information such as:

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

ADELE should provide native editors for common declarative setting types. A
plugin may also provide a custom settings editor when a generic property editor
would produce poor UX, for example account management, model-provider setup,
MCP server management, or complex approval rules.

A custom settings editor does not own configuration persistence. It edits
through an ADELE-owned configuration API so that scope selection, validation,
transactions, provenance, reset/inheritance semantics, and persistence remain
consistent with generic settings.

Normal Settings UX should select the target editing scope at a higher level,
rather than putting a scope selector beside every control. For example, the
user might edit `All Profiles`, `Developer`, `Work`, or `This Project`, with
individual controls indicating when a displayed value is inherited and where it
comes from. Resetting an override means removing that layer's value so normal
resolution resumes; it does not copy the parent value into the child scope.

Directory/resource configuration, if supported, should be exposed contextually
rather than forcing every user to reason about every possible scope at all
times.

## Merge behavior

Simple scalar settings naturally use the more specific/later explicit value.
ADELE should not invent a magical universal deep-merge algorithm for arbitrary
objects and lists.

Replacement should be the conservative default for compound values unless a
setting explicitly declares well-defined merge semantics such as ordered union,
append, keyed merge, or another domain-specific operation. Complex persistent
records may be better represented as separately identified records rather than
one deeply nested setting.

The effective-value resolver should preserve provenance even when an explicit
merge strategy combines values from multiple layers.

## Providers, accounts, and credentials

Configured capability instances remain distinct from profiles. One plugin
runtime may expose several named accounts, providers, endpoints, clusters,
connections, or devices. Profiles can participate in deciding which configured
instances are available in a context and which compatible instance is
preferred, without requiring duplicate plugin installations or runtime copies.

Availability and preference are separate decisions. A profile may make a work
account available, prefer it, do both, or do neither. This distinction matters
when profile stacks combine concerns such as `Developer`, `Work`, and
`Personal`.

ADELE owns preferred-provider resolution. Providers cannot declare themselves
globally primary.

Credentials and secrets are not ordinary configuration values. Ordinary
configuration should reference an ADELE/plugin-managed credential or configured
instance rather than serialize the secret itself. Exact secure-storage and
credential-management architecture remains deferred.

## Persistence, portability, and schema evolution

Configuration intended for sharing or project version control should have a
stable, human-readable serialized representation and should be editable through
ADELE's configuration APIs/UI and ordinary tooling. This does not require every
class of ADELE persistence to use the same textual storage mechanism.

Machine-local configuration, remembered UI state, caches, runtime state, and
other operational metadata may use a different internal store. A future design
may distinguish portable and local overlays at the same conceptual scope when a
setting is shareable in principle but one machine requires a local override.

Persisted configuration outlives individual plugin activations and may outlive
plugin versions. Stable setting identifiers, validation, deprecation, schema
migration, and unknown-value preservation therefore matter. Exact migration
protocols are deferred, but ADELE should not casually discard unrecognized
persisted configuration merely because its owning plugin or declaration is not
currently active/available.

## Runtime application and configuration snapshots

Changing persisted configuration and changing the behavior of an already
running operation are separate concerns. Settings should be able to declare or
participate in apply behavior such as:

- live for future observations in existing UI,
- next operation/run,
- plugin reconfiguration/restart,
- application restart.

Execution-sensitive work should normally operate against a stable resolved
configuration/context snapshot rather than have semantically important values
such as provider selection or approval behavior mutate unpredictably halfway
through an operation because another window changed Settings.

The exact snapshot/reconfiguration mechanism remains deferred, but runtime
boundaries should preserve reproducible, explicit context where correctness
requires it.

## Workbench and window state

Workbench state is not ordinary configuration. Profiles influence which plugins
and UI contributions exist, while live presentation choices such as splitter
positions, selected tabs, view visibility, scroll position, and similar layout
state belong to windows/views.

Different windows over the same project or even the same task/session may have
independent live workbench state while presenting shared underlying domain data.
For example, two windows can show the same session chat while using different
console heights and different scroll positions.

ADELE should maintain remembered local workbench state used to initialize future
windows. Once opened, each window owns an independent live copy. Changes write
through to remembered state but do not push back into already-open windows.

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

Persistence must be fine-grained enough that one window changing a sidebar
width does not overwrite another window's newer remembered console height merely
because each window holds a stale full-layout snapshot. Last-writer-wins is
acceptable for concurrent writes to the same remembered property; unrelated
properties should not overwrite one another.

The exact persistence key for remembered layouts remains intentionally open.
ADELE should be able to remember materially different arrangements for
project/profile contexts whose active plugin surfaces differ, but this document
does not require the key to be the exact project ID plus exact ordered profile
stack.

Changing the active profile stack can substantially change which workbench
contributions exist. UI contributions should therefore have stable identities,
and remembered state for a temporarily unavailable contribution may remain
dormant so it can be restored if that contribution becomes available again.

A future explicit operation may allow a user to save a current arrangement as a
profile/layout default. Ordinary splitter dragging should not silently turn into
shared profile configuration.

## Runtime activation contexts

The intended default remains one plugin runtime per activation context, while
activation-context lifecycle is not yet implemented. One active plugin
generation may expose multiple configured capability instances through one or
more explicit configuration contexts without requiring another plugin install
or backend copy.

Each active capability endpoint executes under an explicit generation-bound
configuration context. The context is runtime metadata derived from persistent
configuration and activation decisions; it is not the persistent configuration
record itself. Several providers/services may share a context when they operate
over the same configured plugin state, and one generation may host several
contexts.

Temporary terminals, browsers, documents, processes, model runs, and active tool
executions remain runtime resources rather than profiles, persistent configured
instances, or plugin runtime instances.

## Deferred decisions

This document intentionally does not settle:

- profile creation/deletion/import/export UX and persistence format,
- whether named profile-stack presets are eventually useful,
- final Project/Workspace identity, roots, multi-root behavior, and lifecycle,
- exact serialized configuration format or local database/store technology,
- exact portable-vs-local overlay mechanics,
- exact setting declaration/schema and migration APIs,
- exact complex-value merge strategies beyond the conservative defaults above,
- exact directory/resource/session override semantics,
- security/permission/policy constraint composition,
- credential storage and account-management APIs,
- dynamic plugin reconfiguration versus restart boundaries,
- exact provider-preference matching and suitability policy,
- exact remembered-workbench-state keying and garbage collection,
- whether profile stack switching ever supports an explicit non-remembered mode,
- implementation staging for the currently implicit development profile.

## Workspace terminology

The shell message `No workspace is open` does not establish a workspace model.
Workspace identity, roots, selection, state, and its relationship to profiles
remain intentionally undefined. `profile`, `workspace`, `project`, and
`environment` are not interchangeable. This document uses `project` as
convenient product-language shorthand for a future persistent development
context and does not establish it as a maintained foundational ADELE type.
