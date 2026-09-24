# Profiles and Configuration

Role: Canonical architecture

Implementation status: Mostly unimplemented

This document defines how Profiles, activation, ordinary configuration, configured
providers, credentials, workbench state, and execution-time configuration relate
without becoming one generic settings or plugin-state model. These are accepted
architectural constraints, principally recorded in
[ADR 0029](../adr/0029-ordered-profile-composition-and-configuration-direction.md),
not a proposed API or storage design.

Current normal startup uses a fixed participation policy, not profile-aware
activation. The self-hosting CLI's `chatgpt` / `api-key` provider-selection
"profiles" are unrelated implementation terminology. Prepared installation
metadata, backend-ready advertisements, generation-bound configuration contexts,
and host invocation contexts are not Profiles; their boundaries belong to
[plugin layout](plugin-layout.md) and
[contracts and capabilities](contracts-and-capabilities.md).

## Profiles and ordered stacks

A **Profile** is a named, sparse composition layer. It may contribute opinions
about plugin activation, ordinary configuration overrides, configured-provider
availability, provider preference, and other explicitly profile-scoped choices.
It records only choices for which it has an opinion, not a complete copy of the
application's configuration or plugin list.

A Profile is not a plugin installation, plugin runtime, configured account/provider
instance, Project, Task, Session, Environment, runtime resource, or workbench/window
instance. Profiles do not select plugin versions: installation, source, build, and
version selection belong to the installation/toolchain domain.

A window/context may use an ordered stack of **zero or more** Profiles:

- Profiles are flat: they do not inherit from, include, or activate other Profiles.
- A Profile appears at most once in one active stack.
- Where a domain uses ordinary precedence, later Profiles have higher precedence.
- The architecture imposes no arbitrary small maximum stack size, although UX may
  optimize for one or two.

For example, `Developer + Work` and `Developer + Personal` reuse a development
composition with different provider/configuration choices. `Vibe` may deliberately
expose a smaller surface while leaving omitted tooling installed. These examples
do not prescribe a required stock composition.

If repeated stacks eventually need convenience, a separate named stack/preset may
expand to an explicit ordered list. It must not introduce Profile inheritance;
the preset mechanism remains deferred.

## Active and remembered profile stacks

```text
active profile stack
    live context/window state
remembered project profile stack
    local persisted default for future windows
```

Changing the stack normally changes the current window immediately and updates
the remembered local default for that Project. It does not change another open
window's active stack.

If A and B share a Project and start with `Developer + Work`, B can switch to
`Developer + Personal` without changing A. A later window C can start from the
new remembered default. A subsequent change in A may update that default again,
but must not mutate B or C.

The remembered stack is local ADELE state, not automatically repository-shared
configuration. Its exact persistence key is deferred, as is an optional explicit
switch-without-remembering operation.

## Ordinary configuration resolution

Profiles are inputs to configuration resolution, not the resolver or its entire
scope model. An ordinary setting may resolve through eligible layers such as:

```text
host/plugin default
    -> user/all-profiles override
    -> ordered active profiles
    -> Project override
    -> optional narrower subject-specific override
```

Scopes are setting-specific, not universal. Task, Session, Environment, resource,
and Run overrides are not automatically available to every setting. The setting's
declaration determines which subjects and layers are meaningful and legal.

Absence means "continue resolving." Explicit `null`, where legal, is a value
distinct from absence. Effective values should retain provenance so Settings and
diagnostics can explain their contributing layers and overridden values. This
resolution model does not prescribe a configuration storage or API schema.

## Shared context, distinct composition

Profiles and product/resource context can supply inputs to several systems.
Sharing those inputs does not give the systems one composition algorithm:

| Domain | Composition semantics |
| --- | --- |
| Ordinary settings | Precedence/cascade, with declared merge behavior. |
| Plugin activation | Sparse tri-state composition, subject to lifecycle/availability validation. |
| Provider availability/preference | Host-owned filtering and preference among compatible available instances. |
| Security/policy/approval | Policy/constraint composition, not normal last-writer-wins. |
| Extension applicability/order | Defined by the owning extension contract. |
| Inference/context material | Defined by the execution/context contract, not a settings cascade. |
| Workbench state | Independent live state plus remembered defaults. |
| Product/runtime state | Domain semantics, not configuration inheritance. |

A more-specific Project or resource layer must not automatically weaken security
because it has higher ordinary-setting precedence. Exact security-policy
composition remains deferred; neither activation nor provider availability grants
invocation authority.

## Plugin activation

Installation makes an implementation available; it does not imply activation.
Activation is contextual, not an intrinsic installed-metadata flag. Profiles store
sparse activation opinions using a tri-state model:

```text
unspecified / inherit
enabled
disabled
```

An unspecified entry has no opinion and resolution continues. Later explicit
decisions may override earlier Profile decisions where host validation and policy
allow. This is not a requirement to copy complete plugin lists into Profiles.

When a plugin is effectively disabled in a context, its normal user-facing
presence should disappear from that context, normally including:

- workbench/UI contributions;
- Commands and keybindings;
- capabilities and extension registrations;
- contributed settings and custom settings UI.

This is intentional product simplification, not merely hiding a toolbar.
**Disabling a plugin does not delete its persisted configuration.** Re-enabling
should be able to restore the plugin with its dormant configuration. Host-owned
plugin-management metadata may still expose the installed plugin for management
while its normal product/settings surfaces are hidden. Deactivation does not
uninstall it.

Plugins must not silently activate concrete complementary plugins. They cooperate
through public interfaces and runtime discovery; missing participation follows the
owning extension contract's availability/failure semantics. See the
[plugin system](plugin-system.md#identity-and-lifecycle-distinctions).

## Settings ownership and UX

Technical setting ownership identifies a stable ID/schema owner. Settings UX
organization follows user/product concepts, not a plugin list. Common settings
should be declarative so ADELE can provide consistent native editing.

A future declaration may describe a stable ID, value type, label/description,
default, category/search metadata, allowed scopes, validation, merge/apply behavior,
and portability/sensitivity metadata. These are illustrative categories, not an
API specification.

Plugins may supply custom editors where generic editing is inadequate. Such UI
must use host-owned configuration and persistence APIs, not establish a separate
settings store. Scope, provenance, reset, validation, and persistence semantics
remain consistent with declarative editing.

Normal Settings UX should expose the editing scope at a higher level, for example
`All Profiles`, `Developer`, `Work`, or `This Project`, with controls indicating
inherited provenance. Supported narrower subjects can expose configuration
contextually rather than requiring every control to display every possible scope.
Reset removes the current-layer override so resolution resumes; it must not copy
the parent value downward.

## Merge behavior

Scalar/simple settings normally use the highest-precedence explicit value.
Replacement is the conservative default for compound values: there is no universal
deep merge for arbitrary objects or lists. A setting may explicitly declare another
well-defined merge semantic. Complex durable records may be better modeled as
identified records than as giant nested settings. Effective resolution should
preserve provenance, including when several layers contribute to a merged value.

## Configured instances and provider selection

A configured capability instance is a persistent/logical account, provider,
endpoint, connection, or similar named configuration, not a Profile. One plugin
runtime may represent several such instances, derived from shared configuration
and applicable overrides, without another installation or backend process for each.

Profiles may influence two separate decisions:

1. **Availability:** may this configured instance participate in this context?
2. **Preference:** which compatible available instance should normally be chosen?

Making a work account available need not prefer it. Preference does not make an
unavailable instance usable. ADELE/host owns preference resolution; providers do
not declare themselves globally primary. Explicit provider selection and failure
semantics remain governed by
[contracts and capabilities](contracts-and-capabilities.md#capability-semantics).

A persistent configured instance is not a generation-bound `configurationContext`.
The latter is live routing metadata, not the durable record; see
[configuration contexts](contracts-and-capabilities.md#configuration-context).

## Credentials and secrets

Secrets are not ordinary serialized configuration values. Ordinary configuration
should reference managed credentials or configured instances rather than embed
secrets. Credential storage and account-management APIs remain deferred; this
architecture does not choose a secure-storage technology.

## Configuration persistence

Persisted configuration can outlive activation and plugin versions. Stable setting
identities, validation, migration, and deprecation therefore matter. ADELE must not
casually discard persisted or unrecognized configuration merely because its owning
plugin is inactive or unavailable.

Shareable/Project configuration should support a stable human-readable
representation suitable for ordinary tooling and version control where appropriate.
Machine-local operational state may use a different store; not every persistence
domain needs the same representation. Portable/local overlays and exact storage
mechanics remain deferred.

The implemented [per-Project SQLite store](product-model.md#project-storage)
persists Project identity/source only. It is not the configuration store, a
remembered Profile stack, configured-provider state, or general plugin
persistence. Its owner-keyed migration metadata does not establish a public
setting/plugin migration API or change the human-readable configuration boundary.

Plugin-owned domain state is not automatically ordinary cascading configuration,
even when host persistence facilities store it. Storage does not transfer semantic
ownership to core. External systems may remain authoritative when that is part of
the domain. See [plugin-owned state](plugin-system.md#plugin-owned-state-and-persistence)
and [product state](product-model.md#core-owned-and-plugin-owned-durable-state).

## Stable configuration for execution

Changing persisted configuration is distinct from mutating an already-running
operation. Execution-sensitive work needs a defined application boundary, such as:

- future observation;
- next inference;
- next Run;
- plugin restart/reconfiguration;
- application restart.

The boundary and mechanism are setting/domain-specific. An in-flight execution
must not unpredictably change provider, tool, policy, or configuration semantics
merely because another window edits Settings. Stable resolved configuration/context
boundaries preserve that invariant without requiring every change to wait for the
same event.

Stability does not keep retired executable bindings alive or authorize silent
replacement. The [execution model](execution-model.md#generation-bound-execution)
owns executable snapshot and binding lifetimes; inference/context composition is
not another settings cascade.

## Workbench and window state

Workbench presentation state is not ordinary cascading configuration. Profiles
influence available extensions; each open window owns independent live presentation
state, such as splitters, selected tabs, view visibility, and scroll position.
Windows may present shared domain data without sharing their live arrangement.

Remembered local state seeds future windows. Changes may update that remembered
state but must not rearrange already-open windows. Writes must be fine-grained
enough that one window's stale whole-layout snapshot does not overwrite another
window's newer, unrelated property. Concurrent writes to the same remembered
property may use last-writer-wins without losing unrelated changes.

Remembered state for temporarily unavailable extensions may remain dormant and
return when the extension becomes available again. Physical placement is not a
plugin extension's semantic identity. Ordinary splitter dragging must not silently
become shared Profile configuration; a future explicit save-as-default operation
would be a separate choice. Exact remembered-state keying and garbage collection
remain deferred.

## Runtime activation context

The intended model is normally one plugin runtime per activation context. One
active generation can expose multiple configured instances. Its generation-bound
`configurationContext` is runtime routing metadata derived from configured state,
not a persistent configuration record, Profile, account identity, or invocation
authority. Several providers/services may share a context, and one generation may
have several contexts.

Temporary processes, terminals, connections, and active executions are runtime
resources, not Profiles or configured instances. See
[contracts and capabilities](contracts-and-capabilities.md#configuration-context)
for live routing and its separation from host invocation authority.

## Product-context inputs

Profile/configuration resolution may use product identities as contextual inputs
where the setting or domain supports them. Product lifecycle is not configuration.
Profiles may influence Environment-provider availability/preference, but
Environment establishment, release, and destruction remain product/provider
lifecycle responsibilities. No separate Workspace identity is required.

The [product model](product-model.md) owns Project, Task, Session, Environment,
and Run semantics; this document does not redefine them as configuration scopes
or lifecycle objects.

## Implementation status

Implemented foundations and current limits:

- Installation/catalog metadata remains distinct from activation/configuration.
- Capability endpoints have generation-bound configuration contexts.
- Durable Project identity/source provide no Profile, configuration, or general
  plugin-state persistence.
- Normal startup uses a fixed participation policy, attempting discovered valid
  components rather than resolving Profiles.
- Current provisional provider selection and temporary source-checkout configuration
  do not implement this architecture; operational details belong in the
  [application documentation](../../app/README.md#chatgpt-source-checkout-configuration).

Not implemented: Profile manager/persistence, profile-aware activation, a generic
settings declaration/resolution service, configured-instance management UI,
profile-aware provider routing, or production workbench-state persistence.

## Deferred decisions

- Profile CRUD/import/export UX and storage.
- Optional named stack presets and non-remembering Profile switches.
- Exact configuration serialization/local-store technology and portable/local overlays.
- Setting declaration/migration APIs and specific non-default merge semantics.
- Exact narrower subject scopes and their override semantics.
- Security/policy/approval composition.
- Credential storage and account-management APIs.
- Plugin reconfiguration/restart rules.
- Richer provider suitability/default policy, including non-capability selection.
- Remembered workbench-state keying and garbage collection.

These deferrals do not reopen ordered flat Profile composition or the product
identities accepted by ADRs 0029 and 0031. Configuration storage layouts, schemas,
migration protocols, and APIs remain open; [ADR 0033](../adr/0033-durable-project-storage-and-provider-backing.md)
separately settles the narrower Project backing/storage decision.

## Related architecture

- [ADR 0029](../adr/0029-ordered-profile-composition-and-configuration-direction.md):
  ordered Profile decisions and rationale.
- [Plugin system](plugin-system.md): installation, activation, and runtime distinctions;
  [ADR 0015](../adr/0015-plugin-installation-differs-from-profile-activation.md) and
  [ADR 0017](../adr/0017-one-plugin-runtime-may-expose-multiple-configured-capability-instances.md)
  record the activation and multiple-instance decisions.
- [Plugin layout](plugin-layout.md): prepared installation metadata boundary.
- [Contracts and capabilities](contracts-and-capabilities.md): configured instances,
  live contexts, provider selection, and authority;
  [ADR 0027](../adr/0027-generation-bound-plugin-configuration-contexts.md) records
  the generation-bound context decision.
- [Product model](product-model.md): product identities and state, with rationale in
  [ADR 0031](../adr/0031-project-task-session-environment-domain-direction.md).
- [Execution model](execution-model.md): stable execution and binding snapshots.
- [Product UX direction](../product/development-workflow/README.md): intended Settings
  and workbench experience, not architecture authority.
