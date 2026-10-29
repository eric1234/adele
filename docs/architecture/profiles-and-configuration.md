# Profiles and Configuration

Role: Canonical architecture

Implementation status: Declarative ordinary scalar settings, immutable catalogs,
default/global resolution, conditional global TOML persistence, and prepared-plugin
declaration discovery are implemented, with an application-owned Global Settings
dialog. Desktop Main Content frontends and AOT backends receive owner-scoped values
from one shared startup snapshot; Source Editor folding and Chat's per-Run model
invocation limit consume scalar settings. Declarative configuration records
share scalar validation and conditional persistence and are browsable and manageable
in Global Settings; the OpenAI plugin declares the first provider record and its
credential slot. Record creation, editing, and guarded deletion are implemented.
App-private record credential associations use nonsecret TOML references and Linux
x64 Secret Service. Credential UI, runtime record consumption, provider authentication
integration, and Profiles remain unimplemented.

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
and host invocation/infrastructure contexts are not Profiles; their boundaries
belong to [plugin layout](plugin-layout.md) and
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

The implemented boundary in [`adele_settings`](../../packages/settings/README.md)
supports exactly **declared default -> optional global override**. Boolean,
signed 64-bit integer (optional bounds), ordinary string, and string-enumeration
definitions are immutable data, not executable validators/default factories.
Defaults must satisfy their declaration. Definitions carry stable setting and
declaration-owner IDs using ADELE's public-ID grammar; each setting lives beneath
its owner's namespace. This is declaration consistency, not live plugin identity,
activation, or proof of trust. An immutable catalog rejects duplicate IDs,
including collisions across owners, and enumerates in stable setting-ID order.

Effective results carry a typed value, source, and explicit global-override
presence. A default-equal explicit override still has global provenance. A known
invalid override fails with its setting ID and violation; it never silently
falls back. Unknown persisted IDs do not invalidate known settings or disappear
when owners are unavailable. Reset removes the global entry and restores default
provenance. No null, Profile/Project layer, compound merge, or named configuration
record model is supplied by this scalar contract.

Prepared installations can supply optional, data-only JSON declarations before
executable components start. The installation's `PluginId` supplies declaration
ownership; schema contents cannot select an owner. The catalog reuses the scalar
contract rather than establishing another validation engine. Schema discovery
diagnoses failures independently of executable components; a consumer that requires
an undeclared setting still fails explicitly. Cross-installation setting-ID
collisions fail catalog aggregation explicitly. See [plugin layout](plugin-layout.md#prepared-installation-snapshot)
and the [runtime schema owner](../../packages/plugin_runtime/README.md#prepared-catalog).

The desktop captures default/global resolution once for independently activated
frontends and backends, with synchronous store/document operations in its shared
host I/O worker. Access is bound to the exact owning prepared installation and its
validated declarations, not a namespace-prefix match. Prepared Main Content uses
read-only scalar access, including finite operations before panes are published.
Backend startup receives a copied immutable map of only its installation's resolved
values through public backend support, not a settings service or persistence API.

Invalid known values fail each owning component's activation, never silently
defaulting or disabling unrelated healthy components. Whole-file load and catalog
aggregation failures affect components with declarations; settings-free components
remain usable. Malformed schemas remain independent discovery issues, but a backend
consuming a missing required value fails before readiness. No Profile filtering,
cross-plugin settings access, live notification, or plugin mutation API is supplied.
The [application boundary](../../app/README.md#prepared-settings)
owns startup projection and failure details.

## Declarative Configuration Records

The single implicit global configuration layer also contains collections of
identified, structured definitions. A **configuration record** is durable data,
not an installation, live provider, routing context, active Session selection,
credential, Profile, or Agent execution. The host owns generic validation and
persistence; plugins own data-only declarations. The OpenAI plugin's
`dev.adele.openai.api-key` declaration is the first real type, not host-embedded
provider logic. It can exist with no credentials or running backend.

Collections group compatible types for generic presentation. Collection identity
(`providers`), record-type identity (`dev.adele.openai.api-key`) and record identity
(`work-openai`) are distinct. A record ID is unique within its collection across
all types and independent of its display name. Type IDs use the shared public-ID
grammar and belong to the declaring installation's plugin namespace. Collection
and record IDs use a narrow portable lowercase grammar rather than arbitrary
paths; the [semantic owner](../../packages/settings/README.md) specifies it.
Catalog aggregation rejects duplicate types and conflicting collection labels,
never choosing a winner by installation order.

Fields are ordered declarations with local identity, label, optional description,
required/optional presence, and existing Boolean, integer, string or string-enum
types. They are not synthetic global `SettingId`s. Both models use the same scalar
validation primitive. Required values must be explicit; optional absence stays
distinct from false, zero and empty strings. There are no field defaults, explicit
nulls, nested values, executable validators or cross-record validation. Unknown
persisted data remains untouched, including when an owner is unavailable.

A type may declare one `displayField` referencing a required string field. Discovery
validates that reference; omission preserves existing declarations. Presentation uses
the declared value when usable and otherwise the stable record ID, never a host
field-name convention. This metadata does not change identity or require nonblank
strings: required still means presence.

Optional ordered `credentialSlots` are separate declarations, not scalar fields or
secret values. Each has a local identity, bounded presentation label and credential
kind; the only kind is `secretText`. Omission means no slots. The public Settings
contract contains no credential reference type or native access. See
[record declarations](../../packages/settings/README.md#named-records) and the
[prepared schema](../../packages/plugin_runtime/README.md#record-schemas) for exact
validation and bounds.

Prepared installations optionally reference `recordsSchema`, separately versioned
from scalar schemas and independent of executable activation. Discovery extends
the existing catalog; one invalid schema does not disable healthy executable or
scalar components. The [runtime schema contract](../../packages/plugin_runtime/README.md#prepared-catalog)
owns exact declaration fields and limits.

Records use `<configurationRoot>/<collection>/<record-id>.toml` beside global
`settings.toml`. A fixed version/type header and regular `[values]` table are edited
by the existing native TOML document API. The
[host adapter](../../packages/settings_host/README.md#configuration-records) owns
the exact format, CRUD API, diagnostics and bounds. Each record has its own
existence/byte baseline; independent-record changes do not conflict. Update supplies
the complete known-field set, removing omitted optional fields and preserving
unknown content. Delete removes only that layer's file, not a tombstone or mask.
Stale update/delete and no-op writes fail explicitly and require deliberate reload.
Enumeration retains healthy records alongside attributable bad-file diagnostics;
directory-wide failures remain errors. Aliased identities never select a winner.

Global Settings discovers these collections from the captured prepared catalog,
lists valid records and attributable diagnostics, and creates and edits records with
shared declaration-generated forms. Collection, record ID and type are immutable
when editing; display-name changes do not change filenames. New records have explicit
stable IDs and no inferred defaults; controls preserve absence separately from false,
zero and empty strings. Editing initializes only declared values and their presence,
not controls for unknown persisted content. Duplicate IDs never overwrite an occupant,
including an invalid or unknown-type record. Malformed entries have no mutation UI.

Each existing record has a separate draft retained through details collapse and
ordinary Settings navigation; Cancel editing discards only that record's draft.
Save presents confirmed worker results, with no optimistic replacement or automatic
refresh of unrelated baselines. Delete requires explicit modal confirmation of the
exact record's title, stable identity, and entire-file removal, including unknown data.
Cancel or dismissal does not write. Confirmed deletion removes only that record and
its draft. Conflicts or uncertain update/delete outcomes fence the affected record,
retaining unsaved values for inspection without retry or automatic merging. Known
pre-write validation failures remain correctable. Unconfirmed creation requires
collection Reload before another creation attempt.

Collection Reload is deliberate, confirms discarding dirty existing-record drafts,
and keeps creation drafts and other sections intact. A successful read replaces the
collection's edit baselines and clears stale drafts; a failed read retains the last
displayed records and drafts with diagnostics, while fencing old handles. No failed
read is presented as an empty collection. Closing the whole dialog discards drafts;
canceled application exit preserves the original dialog and its drafts.

The OpenAI schema contains required `display-name` and optional nonsecret `endpoint`
strings, plus an `api-key` credential slot, never a secret under ordinary values.
These records and associations are not consumed by the runtime, including after
restart. Existing OpenAI authentication, Chat selection and startup behavior are
unchanged. Future Profiles may contain the same
kinds of collections, but no Profile identity, ordered record composition or merge
rules exist yet. Record UI uses the established host-owned serialized I/O boundary,
not another writer isolate or persistence service.

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

Current scalar declarations include stable setting/owner identity, type, default,
type-specific validation, label, optional description, and product category/section.
Category and section need not follow plugin ownership. Future declarations may add
search metadata, allowed scopes, merge/apply behavior, and portability/sensitivity
metadata; these remain illustrative categories, not implemented API fields.

The application header opens a host-owned **Global Settings** dialog, independently
of Project, Session, or executable frontend availability. It uses the same prepared
installation catalog as normal startup, without rediscovery. Categories and sections
come from declaration metadata, not plugin IDs. Generic Boolean, bounded integer,
multiline string, and enumeration controls edit drafts; enum labels are presentation
only and stable values are persisted. Effective values and Default/Global provenance
remain separate from unsaved drafts. Search filters labels, descriptions, categories,
sections, and IDs without discarding hidden drafts.

Preferences remains the default view. Record collection navigation is supplied by
`RecordCatalog.collectionLabel`; a collection may contain multiple plugins' types.
Navigation retains scalar controls and record drafts while excluding hidden
controls from keyboard focus. Scalar and record schema/aggregation failures remain
independent; genuine installation-wide diagnostics are represented in both areas.

Each setting has explicit Save and Reset actions. Save validates through its
definition and creates an explicit Global override, even when equal to the default.
Reset removes a supported scalar override instead of writing a default. The dialog
loads current disk contents when opened; Reload deliberately replaces the editing
snapshot and discards drafts. These snapshots are separate from startup consumer
values. Opening or dismissing Settings does not navigate a Session or reconstruct
its workbench. Saved changes require restarting ADELE, including for later Chat
Runs and Source editors opened in the same application; no live notification or
reconfiguration is implemented.

Malformed TOML and I/O failures prevent editing, rather than becoming an empty
document. Invalid known overrides have no displayed effective value and can be
reset when the existing scalar document API supports removal. Unsupported structures
remain explicit failures requiring manual correction. Diagnostics include the
configuration path where available. Schema issues remain visible without hiding
healthy declarations; duplicate IDs reject aggregation rather than choosing a
winner. Installation repairs require restart, while configuration repairs can be
reloaded. Whole-document save conflicts leave external content untouched and require
explicit Reload; there is no retry, merge, or file watcher.
Other save failures also require Reload: cleanup or transport can fail after
publication, so an unconfirmed result must not be presented as proof that nothing
was persisted. The prior loaded values remain visible until that explicit read.

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

Secrets are not ordinary serialized configuration values. Configuration may retain
nonsecret credential references, never secrets in TOML, Project/plugin state,
installation metadata, logs, or artifact identity inputs. OpenAI's declared slot
does not change existing authentication or provider selection.

The standalone app-private `CredentialService` owns serialized admission,
validation, mutation verification, and shutdown. Its production adapter runs
synchronous operations from the internal
[`adele_credential_store`](../../packages/credential_store/README.md) in
`Isolate.run`, off the Flutter UI isolate. The package is an OS-storage boundary,
not a public Settings or plugin API, account manager, OAuth refresh store, or
credential provider. Constructing or closing an idle service does not access the
keyring, and normal application startup does not probe or load credentials.
An explicit trusted host owner must drain the service before releasing it.

A credential reference is a nonsecret, persistable association identity of the form
`cred1_` followed by 32 lowercase hexadecimal digits. Its authoritative internal
`CredentialReference` value lives in the SDK-only
[`credential_reference.dart`](../../packages/credential_store/lib/credential_reference.dart)
entrypoint, without importing native operations. It is independent of record,
plugin, account, display name, Profile, and runtime generation. Possession is not
authorization to read or mutate a secret. A valid reference may have no local
credential, for example on another machine; absence does not invalidate the
reference. Secret values are nonempty, valid UTF-8 text without NUL, bounded to
2560 encoded bytes. Redacted wrappers and fixed diagnostic categories limit
accidental disclosure; Dart strings are not zeroizable and this is not isolation
from other trusted host code in the process.

The enabled native path is Linux x64 Secret Service through an explicit store,
with an ADELE namespace and the reference as the item identity. It uses no plaintext
file fallback or substitute in-memory store. The user's Secret Service provider
owns persistence and at-rest policy; encrypted transport is not a guarantee about
that provider's keyring configuration. macOS, Windows, and other architectures
have no enabled backend and reject credential access as unavailable until
separately implemented and validated. This does not disable the application's other
functionality or desktop build paths.

Confirmed absence remains distinct from inaccessible, locked, corrupt, ambiguous,
or failed storage. Reads never delete or repair malformed values. A fresh explicit
native store is constructed for each operation, so initial connection failure is
not cached permanently. A later deliberate request may try again; a failed request
is never automatically retried. Native calls may wait for the OS/keyring, including
an unlock prompt. There is no cancellation or application timeout; shutdown fences
new requests and drains admitted calls rather than abandoning native work.

Create/replace/delete preconditions and postverification do not constitute
cross-process compare-and-swap or a transaction with configuration persistence.
An unconfirmed mutation is not proof of rollback: the host fences further mutations
of that reference until an explicit successful read, or confirmed absence,
reconciles it. Presence alone cannot verify replacement contents. No automatic
retry, merge, secret enumeration, provider wiring, or plugin access grant is added.
Account-management and future explicitly authorized plugin access remain separate
design work. See the [application map](../../app/README.md) for local ownership and
[credential validation](../development/testing.md#credential-storage-checks) for
the distinction between deterministic tests, isolated keyring smoke, and packaging.

### Record association lifecycle

Records may contain an optional regular `[credentials]` table beside `[values]`.
Declared slot keys contain validated reference strings only. The
[Settings host adapter](../../packages/settings_host/README.md#credential-references)
preserves unknown entries without interpreting or adopting them; malformed known
references make that record unavailable rather than being treated as missing.
Ordinary record deletion is blocked while **any** credential entry exists,
including unknown nested content. Empty/absent tables do not block deletion.
Ordinary value edits retain associations and use the same whole-record baseline.

The app-private `RecordCredentialService`, part of `GlobalSettingsService`, is the
only association coordinator. Callers supply an owner-bound `RecordView`, a declared
slot, and a secret for writes, not an owner, record type, native key or reference.
The existing Settings worker verifies the exact owner/revision, declaration and
conditional byte baseline. A shared worker admission gate spans the entire
workflow, including OS waits, so ordinary configuration operations and other owners
cannot interleave with it. Every TOML operation still runs on that worker; there is
no second writer or native-document transfer to presentation. `CredentialService`
retains its independent OS-operation queue and uncertain-outcome fence.
Replacement and deletion revalidate the protected binding inside that queue, so
an intervening admitted host operation cannot substitute a foreign protected value.
Immediately before OS mutation, the coordinator revalidates the same configuration
baseline after queued operations and native preflight/unlock waits; a failed guard
does not perform a mutation or create an uncertain-outcome fence.

OS storage contains a protected JSON envelope with exactly `version`, `owner`,
`type`, `collection`, `record`, `slot`, `reference` and `secret`. Version is integer
`1`; every binding value must match the validated record and reference. The whole
encoded envelope, including metadata and JSON escaping, must fit the existing
2560-byte bound before either store is mutated. Copying a TOML reference to another
owner/type/record/slot does not authorize using or deleting the protected value.
Malformed, foreign or unsupported envelopes remain invalid and are never repaired
or deleted automatically.

- **Attach:** validate, allocate a fresh reference, conditionally persist it, then
  create the OS value. A keyring failure may therefore leave a reference with no
  local value. The safe failure carries the latest acknowledged record handle;
  `establishLocal` can deliberately reuse that reference after confirmed absence.
- **Replace:** require the existing valid bound envelope, recheck the configuration
  baseline after the OS read, then replace under the same reference. Missing local
  storage is not an implicit create, and invalid bindings are not overwritten.
- **Forget:** require a valid bound value or confirmed absence, recheck the baseline,
  delete a present OS value first, then conditionally remove the TOML reference.
  Configuration failure after deletion can leave a reference to missing local data;
  it is not evidence that the OS deletion rolled back.
- **Inspect/reconcile:** return storage status only, never secret material or an
  authentication assertion. No reference means no keyring access. Inspection does
  not bypass an uncertain-mutation fence; an explicit reconciliation read establishes
  the outcome before a later deliberate mutation. Full protected-envelope validation
  occurs inside the queued read before clearing uncertainty; malformed or foreign
  payloads cannot reconcile it. Successful mutations and
  reconciliation issue fresh record revisions. Configuration failures require Reload,
  not a substituted baseline or automatic retry.

The application lazily pairs one coordinator with its Settings owner and retained
credential service. Construction and startup do not probe credentials. Accepted
shutdown synchronously fences both the coordinator and Settings public admission,
then drains admitted workflows before releasing the Settings worker or closing the
credential dependency;
rejected exit leaves the existing owners usable. A blocked OS prompt can delay this
drain without timeout, cancellation or an inferred rollback.

This is a host-only lifecycle, not a cross-store transaction or cross-process
keyring compare-and-swap. Manual filesystem edits remain outside it and can race
conditional checks. It adds no secret-entry UI, runtime/backend delivery, OAuth,
provider activation, Profile or Agent semantics. Generic record views expose no
credential references or protected payloads. Linux x64 remains the only enabled
native credential backend.

## Configuration persistence

Persisted configuration can outlive activation and plugin versions. Stable setting
identities, validation, migration, and deprecation therefore matter. ADELE must not
casually discard persisted or unrecognized configuration merely because its owning
plugin is inactive or unavailable.

Human-editable persistent configuration uses **TOML**, with Rust **`toml_edit`**
behind a Flutter-free Dart document boundary. Ordinary Dart values and document
operations are the consumer interface, not Rust types, foreign-memory handles,
or editor controllers. Edits preserve comments and unrelated formatting on a
best-effort basis. This choice does not replace internal JSON transports or
prepared installation formats, nor settle configuration schemas or precedence.

Global persistence has separate ownership and lifetime domains:

| Domain | Boundary |
| --- | --- |
| Configuration | User-managed preferences and definitions, potentially Git/dotfile-managed. |
| Local application state | Frequently changing machine-local state, such as remembered layouts and recent Projects. Not portable configuration. |
| Local application data | Other durable application-managed global data. |
| Cache | Disposable, rebuildable data. |
| Secrets | App-private OS-backed storage, separate from ordinary configuration and global filesystem roots; see [credentials and secrets](#credentials-and-secrets). |
| Project/Session data | Existing per-Project product and plugin-owned storage, not a global settings store. |

[`adele_platform_storage`](../../packages/platform_storage/README.md) resolves
distinct global roots using Linux XDG, macOS Application Support/Caches, and
Windows Roaming versus Local AppData conventions. It accepts injected platform
inputs or explicit roots, performs no directory creation, and owns no consumers
or persistence APIs. Global state/data locations do not belong to a future public
configuration API simply because they share location-resolution infrastructure.

[`adele_toml_document`](../../packages/toml_document/README.md) independently owns
validation and narrow immutable scalar document edits. It provides no filesystem
service, setting declarations, effective-value resolution, or Profile semantics.

[`adele_configuration_store`](../../packages/configuration_store/README.md) owns
the narrow host persistence boundary for `settings.toml` and independently
identified record files under the explicit configuration root. Loading validates
existing TOML or represents absence as an empty document,
without creating directories or artifacts. Malformed content and I/O failures
remain distinct errors; neither causes repair or substitution with defaults.
Snapshots retain content/existence baselines. Saves reject stale whole-document
edits, skip unchanged content, and return an updated baseline after publication.
Conditional deletion and create-without-overwrite share that same transaction
boundary rather than another atomic-write implementation.

Cooperating host writers use a stable advisory lock under the **local-state** root,
not inside potentially Git-managed configuration. Each process routes operations
through one owning isolate; the synchronous API serializes that isolate while OS
locks coordinate processes. Complete staged content is flushed and replaced on
the same filesystem. Linux is the maintained write path; other platforms reject
changed saves pending validation. Symlinked configuration directories work, but
changed saves reject file-level symlinks rather than destroying their arrangement.
Record operations additionally reject symlinked collection directories and file
entries rather than discovering records through unexpected links.
External editors/Git can race the final content check, so this is not unconditional
compare-and-swap against uncooperative writers. The local README owns the exact
placement, permission, crash-durability, and coordination limits.

This host-only boundary grants plugins no arbitrary filesystem service and does
not itself implement Settings or Profiles. File watching, automatic merging,
and portable/local overlays remain later work; Project storage ownership is
unchanged.

[`adele_settings_host`](../../packages/settings_host/README.md) is the separate,
narrow adapter over these store/document APIs and the public scalar catalog.
Global overrides use root-level quoted fully qualified setting IDs in
`settings.toml`; each ID is **one literal key**, not dotted table traversal:

```toml
"dev.adele.example.enabled" = true
"dev.adele.example.output-limit" = 5000
"dev.adele.example.mode" = "detailed"
```

Loading and resolution never materialize defaults. Host snapshots retain the
conditional-save baseline while edits produce new immutable documents; save
propagates whole-document conflicts without retry or merge. Unknown values are
not scanned or rewritten. Unsupported known TOML values fail explicitly instead
of causing structural repair, and no syntax/type coercion is performed. Ordinary
scalar edits and explicit reset use the existing document operations and their
preservation limits. The adapter remains synchronous on the owning host isolate.
Desktop [`GlobalSettingsService`](../../app/lib/core/global_settings_service.dart)
leases one retained worker from the Flutter root isolate; all application owners
share its serialized store operations, including owners with separate editing
baselines. Awaited record enumeration and mutations settle before the next worker
request, including requests from another owner; asynchronous handlers do not run
independently. Independent root-isolate writers are rejected rather than relying on
same-process filesystem locks. Only immutable scalar results, provenance, errors,
opaque view revisions, and record IDs/types/declared values/diagnostics cross
back to presentation. Stores, native documents, and conditional baselines remain in
the worker. Each owner retains independent snapshots keyed by collection and record
ID. A record view binds its private handle to that service owner, collection, ID,
type, and a specific loaded or saved revision. Callers cannot substitute another
record's baseline or acquire filesystem authority. Creation and successful updates
(including no-ops) issue fresh handles; deletion retires the handle. Deliberate Reload
revokes older handles for the affected collection, including on read failure.
Conflicts and uncertain persistence failures retire the affected baseline until Reload,
without invalidating independent records. A rejected stale request cannot revoke a
newer successful revision. The store's existence/byte comparison still detects
external or competing-owner writes, including stale no-op edits; there is no retry
with fresh data.
Startup and Settings use the same captured storage roots; tests inject temporary
roots at application composition.

Closing the dialog only disposes presentation, not the service or an admitted
transaction. Application shutdown fences new requests, drains admitted work, and
awaits worker exit when the last owner releases it. Reopening Settings queues a
fresh read after any previous admitted operation. Linux remains the changed-save
path; other platforms report unsupported writes rather than success. Runtime
bridges receive resolved immutable values, not the store or document. The standalone
read-only prepared snapshot loader can still use a short-lived isolate for isolated
hosts/tests; it is not an additional application writer.

The implemented [per-Project SQLite store](product-model.md#project-storage)
persists the core product graph through Sessions and their semantic Environment
associations. Plugins can retain Session-associated relational state through
`adele_project_storage`; Chat's history, instructions, Draft Request, and entry
counter are domain state, not a settings cascade. Its model invocation limit is
ordinary global configuration, not Session state. This is not the general
configuration store, a remembered Profile stack, configured-provider/credential
store, or workbench persistence. Owner-keyed SQL migrations do not establish a
setting migration API or change the human-readable configuration boundary.

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

### Chat invocation budget

Chat declares `dev.adele.plugin.chat-strategy.max-model-invocations` in its
authoritative [`settings.schema.json`](../../plugins/chat_strategy/settings.schema.json).
It is an integer setting with default `40`, minimum `1`, and no declared maximum
beyond the scalar type's range, presented under **Agents / Execution**. Only the
declared default and optional global override participate; there is no Session or
Run override layer.

The Chat backend requires the resolved startup value and captures it when
materializing each Run. Continuations and approval resume retain that capture.
Changing global Settings neither mutates active Runs nor changes later Runs on the
same application startup snapshot; restarting ADELE applies saved values. The
limit is absent from Chat Session state, public snapshots, and relational storage;
`configureSession` changes instructions only. Native fixtures supply an explicit
positive constructor value, and standalone AOT hosts inject a value at backend
startup rather than changing a Session. The [execution model](execution-model.md#strategy-sequencing-and-host-mechanics)
owns sequencing and exhaustion semantics; [self-hosting](../development/self-hosting.md#execution-topology)
owns the developer runner's explicit budget path.

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

- Distinct platform storage locations, native TOML scalar document operations,
  and conditional global configuration-file persistence exist independently of
  Settings/Profile semantics.
- A public immutable scalar declaration/catalog/resolution contract and a separate
  internal global settings adapter support standalone host consumers without
  plugin activation or Flutter. Only default/global resolution is implemented.
- Installation/catalog metadata remains distinct from activation/configuration.
- Prepared installation schemas expose scalar declarations independently of code
  startup. Owner-scoped desktop Main Content reads and backend bootstrap values
  share one startup snapshot. Source Editor applies folding at native construction;
  Chat captures its backend-configured invocation limit per Run. Settings-file
  changes require an application restart, not mutation of retained documents or
  execution state.
- The host-owned Global Settings dialog edits those declarations through the shared
  asynchronous configuration owner, with current persisted provenance, per-setting
  save/reset, explicit reload, and non-destructive error/conflict handling.
- Plugin-declared records support generic validation and headless independent-file
  CRUD in the same global layer, with browsing, creation, editing, and confirmed
  deletion in Global Settings. OpenAI supplies a nonsecret API-key provider
  declaration, not runtime activation or authentication.
- Capability endpoints have generation-bound configuration contexts.
- Host credential storage has a Linux x64 Secret Service adapter and an app-private
  record association lifecycle, without credential UI, provider activation, runtime
  delivery, or public/plugin access.
- Durable product records and plugin-owned relational Session state provide no
  Profile, general settings, configured-instance, credential, or workbench storage.
- Backend infrastructure access is generation-local, distinct from both
  configuration routing and operation-scoped execution authority.
- Normal startup uses a fixed participation policy, attempting discovered valid
  components rather than resolving Profiles.
- Current provisional provider selection and temporary source-checkout configuration
  do not implement this architecture; operational details belong in the
  [application documentation](../../app/README.md#chatgpt-source-checkout-configuration).

Not implemented: Profile manager/persistence, profile-aware activation,
configured-provider activation/authentication, profile-aware provider routing,
or production workbench-state persistence.

## Deferred decisions

- Profile CRUD/import/export UX and storage.
- Optional named stack presets and non-remembering Profile switches.
- Broader configuration file schemas, local state/data store technologies, and
  portable/local overlays.
- Setting migration APIs, richer value types, and specific non-default merge
  semantics.
- Exact narrower subject scopes and their override semantics.
- Security/policy/approval composition.
- Account-management and public/plugin credential-access APIs; additional native
  credential platforms require separate implementation and validation.
- Plugin reconfiguration/restart rules.
- Richer provider suitability/default policy, including non-capability selection.
- Remembered workbench-state keying and garbage collection.

These deferrals do not reopen ordered flat Profile composition or the product
identities accepted by ADRs 0029 and 0031. Beyond the global roots, TOML document
boundary, scalar global `settings.toml` and identified collection representation
above, broader configuration layouts, migration protocols, and settings APIs
remain open; ADRs
[0033](../adr/0033-durable-project-storage-and-provider-backing.md) and
[0034](../adr/0034-plugin-owned-relational-session-storage.md) separately settle
Project backing and plugin-owned relational Session storage, not these domains.

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
