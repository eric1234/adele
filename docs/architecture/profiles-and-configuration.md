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
Global Settings manages declared credential slots through the app-private association
coordinator, with nonsecret TOML references and Linux x64 Secret Service storage.
Opted-in backends receive immutable nonsecret record metadata at startup and may
explicitly observe fresh nonsecret records or capture current records with a fresh
credential scope through separate generation-scoped host services. Nonsecret
observations do not renew credential authority; neither host operation applies provider
changes. OpenAI materializes independently addressable API-key inference/catalog pairs
and supports explicit targeted refresh within one backend generation, composing fresh
captures with dynamic publication and route retirement. Untouched startup routes keep
lazy startup-scope credential reads. Advertisement is not proof of successful
authentication. [Record apply](#applying-confirmed-record-changes) connects confirmed
Global Settings mutations to an opted-in backend. Sessions can select a Model Preset
by stable record ID. Record-based OAuth and Profiles remain unimplemented.
The [Agent Configuration plugin](../../plugins/agent_configuration/README.md)
projects its ordinary global Agent records through a read-only catalog using fresh
nonsecret observations. Agent selection and execution are separate from that service.

This document defines how Profiles, activation, ordinary configuration, configured
providers, credentials, workbench state, and execution-time configuration relate
without becoming one generic settings or plugin-state model. These are accepted
architectural constraints, principally recorded in
[ADR 0029](../adr/0029-ordered-profile-composition-and-configuration-direction.md),
not a proposed API or storage design.

Current normal startup uses a fixed participation policy, not profile-aware
activation. Prepared installation metadata, backend-ready advertisements,
generation-bound configuration contexts,
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
nulls, executable validators or cross-record validation. Unknown
persisted data remains untouched, including when an owner is unavailable.

A string declaration may require nonblank content, bound its UTF-16 length,
reject ASCII controls, or require an ADELE public ID. These predicates are
independent of presence and never rewrite the text. The same declaration governs
ordinary Settings, scalar fields and structured properties. Editor feedback is not
the authority: the host validates before writing and again when reading persisted
values for enumeration or authorized backend observations. Invalid records remain
on disk with attributable diagnostics; they are neither repaired nor projected as
valid records.

A required record field may instead declare a fixed structure. Its ordered,
required properties have local IDs and ordinary scalar types. A supplied value
must contain exactly those properties; validation identifies the field and the
missing or invalid component. The validated projection is immutable. Change
detection compares component values, not map identity or insertion order. This
is one replaceable field, not separately addressable settings, a list, or a
recursive schema. It has no default and requires a contributed editor.

### Record Field Editors

Without an editor declaration, Settings uses the ordinary scalar control. A
field can instead name a prepared editor with `"editor": {"extensionId": "..."}`.
The reference is data, not code or proof of availability. The public
`dev.adele.ui.settings-field-editor` extension point belongs to `adele_ui`.
An editor ID consists of the owning plugin ID and one local segment. Only the
frontend from the installation that supplied the **actual field declaration**
may supply its presentation. Resolution requires its exact live registration:
there is no ranking, native substitute, or lookup of an editor by scalar type.
A missing, failed or retired editor leaves the field unavailable, not the whole
form. It does not invalidate a previously valid field value.

One presentation reads its field in the unsaved draft and proposes a complete
replacement against the revision it observed. A structured read returns a flat
snapshot, not a mutable host map; the bridge copies and bounds proposals before
declaration validation. There is no component patch or sibling access. The host checks the mount, editing
state, revision, and field validator before accepting a proposal. A rejection
leaves the value, revision and transient field context unchanged. An absent
optional scalar is editable: the editor
reads null and may propose a declared value. Removing a value is a host control,
not a null proposal; it revokes the old editor's callbacks before remounting.
The editor cannot select a different field or record or submit the form. Navigation, dismissal, and
retirement revoke old callbacks; returning can create a fresh presentation
over the retained draft. Only the form's ordinary Create/Save transaction
persists an accepted edit. See the [public UI contract](../../packages/ui/lib/settings_field_editor.dart).

The `markdown` hint edits an ordinary string as a document using a native
control. Settings has no model/provider-specific field hints or discovery path.

### Record Form Behavior

A record type can reference one `settingsFormBehavior` operation from the exact
frontend installation that supplied its declaration. Like a field editor, this
requires an owned live registration, not just matching IDs. Unlike an editor,
the operation receives a snapshot of **all declared ordinary values in this
draft**, not a widget or field handle. It receives no store, credential slots,
Session, Environment, Capability routes or backend services. A field editor's
grants do not extend to its sibling form behavior.

Settings evaluates the operation when presenting the form and on user edits,
including removals and accepted field proposals. An absent optional field has
no key; entered but unrepresentable input has a key with a null draft value,
never a null to persist. Notifications follow changes to the draft,
not transitions of its dirty flag. A field proposal may also replace that
field's bounded, transient string-list context. Only an accepted revision can
publish context; replacing the value without context removes it. Reconfirming
an equal value can update the observation without reporting a change of value.

Each synchronous result replaces the form's **presentation**, not its values:
field enablement, a subset of declared enum choices, and guidance. An excluded
current value remains authored, not an available choice. On an actual change
the result may *separately* propose clearing one optional enum in this draft.
The host validates the entire result before applying any of it, without feeding
the clear back into the hook. Unavailable, failed or retired behavior leaves
the ordinary declared controls and a diagnostic; it never chooses a substitute
or clears a draft value. A new form scope starts without the old presentation
or observations. None of this metadata changes schema validation, reaches a
record write, or participates in execution.

### Record Metadata

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

Records live in `<configurationRoot>/<collection>/<filename>.toml` beside global
`settings.toml`. The collection directory supplies the collection identity; the
version-2 TOML header supplies the immutable `recordId` and declared `recordType`.
The filename is a storage location, not an ID or a fallback for a missing header.
Settings initially writes `<record-id>.toml`. An external rename to another valid
filename in the same collection preserves Session references, configured-provider
IDs and protected credential associations. Fresh discovery reads the new location;
it does not rewrite the document or change any existing capture.

The header and regular `[values]` table are persisted with the native TOML API. The
[host adapter](../../packages/settings_host/README.md#configuration-records) owns
the exact format, CRUD API, diagnostics and bounds. Each snapshot pins the observed
filename and its existence/byte baseline; independent-record changes do not conflict.
A Save or Delete from before a rename cannot follow the file or recreate its old
name. Update supplies the complete known-field set, removing omitted optional
fields and preserving unknown content. Delete removes only that layer's file,
not a tombstone or mask.
For a structured field, a regular `[values.<field>]` table holds its scalar
properties. Only declared properties are read and edited. Unknown siblings and
unknown properties under that table stay in the document, not in the editor or
backend snapshot. Component edits are published together under the record's one
conditional write; they cannot succeed separately.
Stale update/delete and no-op writes fail explicitly and require deliberate reload.
Bounded discovery retains healthy records alongside attributable bad-file diagnostics;
directory-wide failures remain errors. If multiple readable headers claim one ID in
a collection, none is authoritative, even if only one record has a known type or
valid values. Settings diagnoses the conflicting files; semantic lookup fails and
the conflict grants no mutation or credential authority.

### Creating and editing records

Global Settings discovers collections from the captured prepared catalog and lists
valid records alongside attributable diagnostics. The generic **Add** form keeps a
separate draft for each record type and assigns each draft a secure random record ID,
independent of the display name. Users enter the declared fields, not the ID. Open
**Advanced details** to inspect or copy the read-only ID before creation; for a
saved record, expand its details to copy the ID. Collection, type and ID are
immutable when editing; editing the display name does not change the filename.
ID generation belongs to the panel: [headless callers](../../packages/settings_host/README.md#configuration-records)
supply an explicit, validated `ConfigurationRecordId` to `create`.

Create and Edit use the same declaration-generated form. Required fields are
marked **(Required)**. Edit them directly. Required
means present, not nonblank. A required string or Markdown document can be empty
if its declaration permits that content. In a new record, a required Boolean or enum has no
preselected choice, and a required integer starts blank.

Optional fields start unset and are directly editable. Leaving a text or integer
input empty, or clearing its contents, omits the field. Nonempty text is not
trimmed; `0` is an integer value. Optional Booleans and enums offer **Not set**
alongside their values, including `false`; an enum declaration can label absence
more specifically. These choices never introduce a default or a stored sentinel.

A legal, already authored empty string survives unrelated edits. **Remove empty value**
omits it without requiring the user to type first. An emptied optional Markdown
document likewise means omission, but only on an authoritative snapshot. Normal
document editing retains Undo; explicitly removing the field discards its native
editor, including any pending input. **Create** and **Save** stay disabled for
malformed or out-of-range integers, unavailable Markdown snapshots and other
invalid inputs. Edit restores declared values without exposing unknown persisted
fields. Malformed records have no mutation UI.

**Back to records**, switching types and navigating between Settings sections keep
the draft's original ID and field values. Only a confirmed **Create** automatically
resets the successful type's draft; other types' drafts are untouched. A collision
never overwrites the occupant, even if its record is malformed or its type unknown.
On collision or an uncertain Create outcome, Settings keeps the draft and requires an
explicit collection **Reload** before another creation attempt. Inspect the reloaded
records using the original ID: an unconfirmed write may have succeeded. Reload does
not change the ID in the retained draft. After a successful Reload, **Discard and
start new draft** replaces only the affected draft with a blank one and a new ID.
It does not write a record. Settings never retries Create automatically.

Each existing record has a separate draft retained through details collapse and
ordinary Settings navigation; Cancel editing discards only that record's draft.
Save presents confirmed worker results, with no optimistic replacement or automatic
refresh of unrelated baselines. Delete requires explicit modal confirmation of the
exact record's title, stable identity, and entire-file removal, including unknown data.
Cancel or dismissal does not write. Confirmed deletion removes only that record and
its draft. Conflicts or uncertain update/delete outcomes fence the affected record,
retaining unsaved values for inspection without retry or automatic merging. Known
pre-write validation failures remain correctable.

Collection Reload is deliberate, confirms discarding dirty existing-record drafts,
and keeps creation drafts and other sections intact. A successful read replaces the
collection's edit baselines and clears existing-record edits. A failed read retains
the last displayed records and drafts with diagnostics, while fencing old handles. No failed
read is presented as an empty collection. Closing the whole dialog discards drafts;
canceled application exit preserves the original dialog and its drafts.

The OpenAI schema contains required `display-name` and optional nonsecret `endpoint`
strings, plus an `api-key` credential slot, never a secret under ordinary values.
Its backend separately opts into startup record metadata and its `api-key` slot;
the [configured-provider lifecycle](#configured-openai-providers) consumes these
distinct grants without exposing credential associations to plugins. Applying an edit
does not replace the backend generation or select an account for Chat. Future Profiles
may contain the same kinds of collections, but no Profile identity, ordered record
composition or merge rules exist yet. Record UI uses the established host-owned
serialized I/O boundary, not another writer isolate or persistence service.

### Model Presets

A Model Preset names one concrete configuration: one configured ModelProvider
`ProviderId`, one exact model ID for that provider, and optionally a requested
reasoning effort. The stable record ID identifies the preset even when the user
edits its name or changes either target identifier. It is not a model type with
a separate mapping for every installed provider.

The [Model Configuration plugin](../../plugins/model_configuration/README.md)
contributes the declaration, not preset instances. Installation makes the empty
collection editable in Global Settings; nothing is seeded, selected or reserved.
Stock definitions await a configuration-defaults policy: discovery and startup
must not seed or recreate records that users chose to delete. A preset neither
installs a provider plugin nor creates the provider instance it names. It can
outlive that instance's availability. Saving it needs no credentials, live
Capability binding, or Model Catalog observation.

The preset declares one required `model` field. Model Configuration's prepared
editor can take the configured provider ID and provider-local model ID from a
confirmed browser row, or accept the user's explicitly authored pair without
discovery. Labels are presentation data, never identifiers. For example:

```toml
[values]
name = "Review"
reasoning-effort = "high"

[values.model]
provider-id = "dev.adele.openai.api-key.work"
model-id = "review-v2"
```

The provider ID uses ADELE's public-ID grammar. The provider-local model ID
must be nonblank and free of ASCII controls, but retains its exact spelling.
Both have the same length bounds as a Run model preference. These checks do
not prove availability or inference compatibility. Opening Settings,
rendering the reference or saving does not request a catalog. Only browsing or
refreshing asks the providers; the plugin owns the search, sort, filters and
manual entry. A catalog choice must still match its captured live association
at confirmation. Once accepted into the draft, the reference is authored data:
provider retirement cannot invalidate a Save or silently change the reference
or reasoning effort. Separate top-level identifiers do not satisfy `model`.

The confirmed browser row can carry its validated effort observation into this
draft. Model Configuration uses it to configure the ordinary effort dropdown:
no model disables it, known support offers only reported explicit choices, and
a known empty list offers only **Provider default** (omission, not `none`). A
saved or manually authored reference without an observation allows deliberate
unverified choices. Changing to a different pair clears an explicit effort
only if the observation excludes it, with an explanation. Fresh evidence for
the *same* pair warns without erasing the authored preference. This is an
authoring aid, not a fresh provider query or a Run admission check.

Model Configuration owns both the live definition reader and the Session's
choice. Its catalog RPC is a boundary for its own frontend, not the provider
Model Catalog Capability or a cross-plugin lookup. Selection uses the same
reader in process. Visible records in an incomplete observation are positive
evidence for selection; absence is definitive only in a complete observation.
Unavailable authority cannot establish either presence or absence.

The plugin stores the stable preset ID or an explicit null, guarded by a
revision, in host-mediated Project storage for the canonical Session. No row
means no preference and revision zero. Reads do not require the definition to
exist: deletion leaves an unresolved reference rather than silently changing
the Session. The stored choice follows Project storage lifetime, not the
backend generation or a Global Settings editing session.

In a Session that mounts execution configuration, the plugin's [selector](../../plugins/model_configuration/README.md#choosing-a-model-preset)
reads both the selection and the catalog. An unreadable selection means unknown,
not null. Clearing needs an authoritative revision but does not depend on catalog
completeness. A fresh read reconciles an unconfirmed update; it neither retries
the write nor confirms that the earlier request caused the observed state.

During [Run model preference capture](execution-model.md#run-model-preferences),
Model Configuration reads that Session's selection once. A confirmed null
leaves the direct configuration in effect. For a stored ID, the plugin must
observe the exact preset in a fresh authorized catalog. A missing preset in a
complete observation and an unobserved preset in an incomplete one both fail
preparation, as do unreadable storage and unusable identifiers. None clear the
stored ID or permit fallback. A visible preset yields its authored provider,
model and optional effort, whether or not that provider is currently available.

A preset definition, the Session's stored ID, and the Run's effective binding
are separate concerns. The host alone resolves the executable provider. Editing,
deleting or selecting a preset affects later captures, never the active Run.
There is no persisted Run selection or runtime record-apply operation.

### Applying confirmed record changes

Saving configuration and applying it to a running backend are separate operations.
Global Settings schedules runtime apply for the affected record only after a
confirmed Create, Save, Delete, or credential Attach, Replace, Establish Local or
Forget. Check, Reconcile, Reload, drafts and scalar Save/Reset do not trigger record
apply. Neither do failed, conflicted or uncertain writes, external edits or direct
store calls. This is not a file watcher or a general change notification.

The optional [prepared backend declaration](../../packages/plugin_runtime/README.md#component-declarations)
maps an owned, consumed record type to a private unary control. The app validates
the exact installation and its live backend activation before dispatch and again
before accepting the reply. The payload contains only the stable record ID; the
backend reads current configuration and owns its interpretation. No declaration
means persistence only. An unavailable owner is not started or replaced by a
matching plugin, provider, or another generation.

Settings reports persistence separately from runtime application, including after
deletion. A runtime failure never rolls back a confirmed write. Retry repeats
only the runtime request for that record, never the file or credential mutation.
Reconcile can recover usable local credential state; it does not confirm a runtime
apply. Applying that recovered state requires a separate runtime request.
An acknowledged preflight failure is retryable. If the backend reports unknown
publication, or its apply acknowledgement is lost, malformed, or replaced by a
transport error, the app cannot establish that publication did not happen. It
fences further applies to that exact live generation and shows restart instead
of Retry. The one-minute acknowledgement deadline ends the wait, not backend
execution; a late success cannot clear the fence. Pending cleanup is
reported separately: an applied change is not undone while old work drains, and
successful publication does not imply authentication or a change of Session model.

### Backend record snapshots

A prepared backend's optional `consumesRecordTypes` list requests only exact type
IDs declared by its own installation snapshot. Absence means no access and no
record read. Missing/malformed schemas cannot satisfy an opt-in; invalid requests
fail the backend component without suppressing independent metadata or frontend
discovery. Neither namespace-prefix matching nor another installation's declaration
can confer ownership. See [prepared layout](plugin-layout.md#prepared-installation-snapshot).

After discovery establishes ownership, the application uses the existing
`GlobalSettingsService` serialized worker and authoritative `ConfigurationRecordStore`
to capture a read-only startup projection. This is not editable collection loading:
it publishes no UI revision and never replaces or revokes loaded edit baselines.
Native TOML documents, protected associations and conditional file baselines remain
worker-private. Ordinary CRUD and projection share admission/serialization; no
second writer, filesystem parser or backend file access is introduced.

Each delivered entry contains exactly a collection ID, record-type ID, stable
record ID and validated declared `values`, including complete flat structures. Optional absence is
omission, not null, a default, false, zero or an empty string. Records of other types
in the same collection, unknown fields/comments, credential references, protected
credential values, roots and worker/revision handles are excluded. The immutable
projection is ordered by collection, type and ID, never display name. Public backend
support structurally validates bounded data at runtime, shared-host and plugin
bootstrap boundaries; declaration-specific validation remains host-owned.

Malformed individual records are omitted, not partially parsed or repaired, with
existing attributable diagnostics available in Settings. Healthy siblings remain
eligible. Whole-directory failures fail the affected backend's configuration read
explicitly; unrelated installations remain eligible to start. Missing/empty valid
collections yield an explicit empty list without creating directories or files.
There is no keyring operation, even when valid credential associations exist.

The snapshot belongs to one exact installation and backend generation. Accepted
application shutdown synchronously fences new starts before draining existing work;
bootstrap rechecks this fence after pending reads so shutdown cannot spawn a late backend. Later
record edits do not update this capture; a subsequent generation may capture
new values. Running backends can separately request live observations or explicitly
capture fresh credential authority as described below.
There is no subscription to this snapshot, file watcher or automatic restart.
Record identity is neither configured-provider identity nor credential authority.
The receiving plugin owns any interpretation into configured providers and live
routing contexts. OpenAI uses that boundary for independent API-key routes; neither
the generic snapshot transport nor the separate credential permission registers a
provider on its behalf.

### Live record observations

Observation is separate from runtime application. A running backend can explicitly pull
current nonsecret records through `AdeleConfigurationClient.currentRecords()`, using
the existing generation-scoped infrastructure grant rather than a provider Capability.
Its exact installation's nonempty `consumesRecordTypes` authorizes the same types as
startup; there is no second permission list. Host composition fixes the installation,
declarations and global scope. The request has no caller-selected identity, type,
collection, credential or configuration-context selector.

`GlobalSettingsService.loadCurrentRecords` reuses the same serialized worker,
`ConfigurationRecordStore`, validated `StartupRecordsView` projection and bounded
record grammar. It independently enumerates current persisted data without UI Reload,
edit-baseline mutation, credential capture or vault access. Each delivered observation
is a copied immutable value, ordered by collection, type and stable ID. Earlier values
do not change; no implicit caching, polling, subscription or filesystem watcher exists.
Serialization orders host-managed reads and writes, not an atomic multi-file snapshot
against uncooperative external writers.

Healthy authorized records survive malformed siblings. `isComplete: false` safely
indicates omitted invalid entries in any scanned collection, including malformed or
unknown types that cannot reliably be attributed to an owner. It exposes no filename,
identity, count, raw exception or field value from those diagnostics. An all-invalid
collection can therefore produce partial `[]`, distinct from clean empty `[]`.
Whole-directory, scan-limit and bounded-projection failures reject the observation,
never silently returning empty or truncated success. Detailed diagnostics stay host-side.

The actual connection grant is checked at service entry and after worker completion.
Retirement fences new admission and late successful publication, without pretending to
cancel native work; Settings closure fences and drains its own admitted work. A copied
projection cannot mint, refresh or retarget startup credential authority. Newly observed
records are not thereby credential-authorized, and mutated old captures remain stale.

Reading does not register or retire providers, change routes or invalidate a Run. The
plugin owns interpretation and safe application; host resolution and exact captured
execution bindings remain authoritative. Application must not silently replace
a running Run's account, endpoint, model or reasoning effort. Fresh credential authority
requires a separate [live capture](#live-credential-captures); dynamic provider
application is not supplied by either read. OpenAI separately composes capture with
publication in its [explicit refresh lifecycle](#configured-openai-providers).

### Backend credential delivery

`consumesCredentialSlots` is a separate backend-only opt-in, not implied by
`consumesRecordTypes` or by the presence of credential-slot declarations. Each
entry names one exact installation-owned, already consumed record type and a
list of its declared slots. Invalid, duplicate or foreign requests fail the
backend component, not independent schemas/frontends. An absent or effectively
empty permission registers no credential service and performs no vault access.
The [prepared catalog](../../packages/plugin_runtime/README.md) owns declaration
syntax and limits; the [transport boundary](contracts-and-capabilities.md#backend-credential-access)
owns the narrow request contract.

For opted-in installations the Settings worker captures a separate private
authority batch from the **same validated record snapshots** used for the
corresponding record projection, at startup or on explicit live capture. Native
documents, file baselines, association references and mutation epochs stay in the
trusted host; no authority token is added to `{collection,type,id,values}`.
An ordinary constructed/copy of that presentation view cannot acquire the worker
batch. The host binds it once to the actual `PluginBackendConnection` and its
current infrastructure grant, with exact installation/type/collection/record/slot
checks. Stable IDs and matching plugin namespaces are selectors, not authority.
Omitted/malformed records and records created later are never eligible within that
capture.

An explicit backend read first verifies the captured association and current
configuration in the worker, then uses the existing `CredentialService` with
`reconcile: false`. Protected-envelope decoding is shared with the association
coordinator: version, owner, type, collection, record, slot, exact reference and
bounded inner secret must all match. After the OS wait the worker validates the
same original capture again, and generation/owner liveness is checked before
release. This read never replaces its baseline, repairs configuration, mutates
the vault, or clears an uncertain-mutation fence. The explicit Settings Reconcile
workflow remains authoritative.

Ordinary field changes, reference changes, Forget, deletion, type changes and
record replacement invalidate the old capture. A capture pins its original
location; it cannot follow an external rename. A fresh authorized capture can
resolve the existing protected association at the newly observed filename, with
no secret rebinding. Worker-shared mutation epochs also fence host-managed
change-and-restore and same-reference credential replacement, whose TOML may
be byte-identical. Strict credential file observations
include device/inode and nanosecond change/modification metadata on the maintained
Linux path; the capture brackets native loads and validation brackets baseline
checks. Editable Settings handles retain their existing byte-baseline semantics.
Once observed stale, that record's captured authority cannot become current again
by restoring old bytes. Fresh authority requires an explicit new capture or backend
generation; neither retargets an old capture. Unchanged sibling records retain their
independent authority.
Epoch keys resolve supported configuration-root aliases to the same canonical
record path; retargeting an alias does not transfer captured authority. The worker
also mirrors opaque mutation markers/epochs to the root isolate through its
existing event channel and waits for acknowledgment before a mutation proceeds.
Final root-side checks therefore catch a mutation even if it commits after the
worker postcheck but before the credential read's continuation publishes its result.
No native baseline or path is needed in that root-side fence. A transient inability
to observe file identity fails closed as unavailable, not as a proven permanently
stale record.

The two worker checks are short serialized operations, not an exclusive Settings
lock held through a keyring unlock prompt. Unrelated configuration work can proceed
while the OS read waits. Existing association mutations retain their guarded
workflow; the retained owners track and drain admitted backend captures and reads
independently. Accepted application exit fences new work synchronously, suppresses
late successful delivery and drains native work before releasing its owners.
Retirement revokes only that generation, without waiting for or falsely canceling
a stalled OS operation.

These are read-only observations and in-process mutation fences, not a cross-process
transaction or keyring CAS. An uncooperative filesystem writer can still race a
completed check, and arbitrary external keyring changes are not a credential-rotation
subscription. Strict credential access fails closed when its file identity cannot
be established; ordinary startup metadata remains independently usable.

A successfully delivered secret exists in backend memory and cannot be revoked
retroactively. Transport copying and immutable Dart strings do not provide zero-copy
transfer or complete zeroization. Provider consumers must define safe adoption of
fresh captures or retirement/restart when credential changes must take effect;
OpenAI's explicit revision lifecycle is described [below](#configured-openai-providers).
Credential availability alone creates no provider, routing context, model selection
or authenticated network request.

### Live credential captures

`AdeleCredentialClient.captureCurrentConfiguration()` explicitly obtains current
nonsecret records and fresh credential authority within the same running backend
generation. The host fixes the exact prepared catalog/installation and both existing
`consumesRecordTypes` and `consumesCredentialSlots` declarations. There is no new
permission list or caller-selected scope. Startup `readCredential` remains bound to
its original capture; `AdeleConfigurationClient.currentRecords()` remains
nonauthorizing, even when its values equal a credential capture's records.

`RecordCredentialService.captureCurrentConfiguration` reuses
`GlobalSettingsService.loadStartupRecords` and its genuine worker-owned batch,
not editable collection Reload, an observation-to-authority conversion, or a second
reader/parser. Ordinary records and the private references, baselines and mutation
epochs are captured together from the same validated snapshots. Capture performs no
vault access and leaves UI edit baselines intact. Serialization orders host-managed
work, not an atomic multi-file or configuration/keyring snapshot against external
processes; the read-time validation and mutation fences above still apply.

The returned `AdeleCredentialCapture` exposes immutable `records`, `isComplete`,
scoped `readCredential` and explicit `release`. Completeness follows the
[live observation rules](#live-record-observations): healthy authorized records
survive malformed siblings, partial empty results are not proof of deletion, and
clean empty results are distinct. Whole-scan or bounded-projection failures reject
capture with `credentialAccessFailed`, never empty or truncated success. Detailed
diagnostics stay host-side. Completeness does not assert configured slots, available
storage or authentication; those outcomes belong to each explicit credential read.

Each capture is independently releasable without changing startup authority or
other captures. A later capture can authorize newly created records or current
associations, but never refreshes a stale earlier record. The
[credential access contract](contracts-and-capabilities.md#backend-credential-access)
owns connection-scoped handles, bounded retention, immediate release fences and
asynchronous draining. Capturing, reading or releasing does not register/retire
providers, change routes, alter Run/model bindings, or apply configuration on the
plugin's behalf. OpenAI owns the separate [explicit refresh](#configured-openai-providers)
that combines these captures with fresh routes and exact registration replacement;
the host capture infrastructure does not supply that policy.

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

An ordinary global boolean can control whether a declared tool policy is
expected. The host resolves the condition from the exact installation's startup
settings; the backend receives the same value before advertising its policies.
Saving an edit in Global Settings takes effect after restart, not for an active
Run or for later Runs in the same process. The stock
[Conservative policy](../../plugins/conservative_tool_policy/README.md#global-setting)
is enabled by default. Disabling it does not deactivate its plugin or disable
other policies. The setting changes participation; it does not contribute an Allow
decision or grant tool authority. See [authorization composition](execution-model.md#authorization-composition).

Project- and Agent-specific policy applicability and hierarchical security
configuration remain deferred. A more-specific layer must not automatically
weaken security through ordinary-setting precedence; neither activation nor
provider availability grants invocation authority.

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
loads current disk contents when opened; Preferences Reload replaces the scalar
editing snapshot and discards scalar drafts. These snapshots are separate from
startup consumer values. Opening or dismissing Settings does not navigate a Session or reconstruct
its workbench. Applying scalar changes requires restarting ADELE, including for later
Chat Runs and Source editors opened in the same application. Named records instead
follow the [confirmed-write apply boundary](#applying-confirmed-record-changes).

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

### Configured OpenAI providers

The OpenAI backend interprets its captured API-key records into associated inference
and model-catalog registrations within **one AOT backend generation**. Explicit
targeted refresh applies current configuration without replacing that generation.
The plugin owns this interpretation and identity mapping, not the application or a
new generic provider registry. These identities remain distinct:

| Identity | Meaning and lifetime |
| --- | --- |
| Configuration record ID | Stable durable identity within the `providers` collection, independent of display name, endpoint and credential association. |
| Inference/catalog `ProviderId`s | Distinct stable semantic discovery/selection identities derived by OpenAI from the record ID. They do not prove live bindings, credential presence or authentication. |
| `configurationContext` | Fresh opaque backend-local route for one immutable configured revision, shared by its two services. It is not derived from the record ID and is never rebound to a replacement. |
| Exact registration/binding | One published occurrence in this generation. Replacement creates new occurrences and a new association even when both Provider IDs stay equal. |

Each valid startup record gets a fresh retireable route and is advertised without
reading credentials or taking a live capture. Plugin-specific invalid
configuration is rejected without advertising that instance or disabling healthy
siblings. The [OpenAI backend](../../plugins/openai/packages/backend/README.md#configured-api-key-instances)
owns exact mapping, endpoint policy and safe diagnostics. The host retains credential
references and protected associations; no key or reference enters startup records or
provider descriptors. Initial inference/catalog pairs are adopted into publication
groups lazily, only when first targeted for replacement or retirement. Adoption
preserves the original exact registrations; startup must not eagerly consume finite
group handles for every configured record.

Each subscribed configured-provider invocation or supported catalog call explicitly
reads only its record's `api-key` slot before HTTP. Untouched startup revisions retain
the original generation-scoped `readCredential` path. A refreshed revision uses only
its fresh captured scope, with no fallback to startup authority. The logical route
does not cache a key for future invocations. Missing configuration
or local data, unavailable storage, invalid binding, reconciliation-required state,
stale configuration and retired generation produce explicit safe failures. They are
not OpenAI HTTP authentication rejections when no request was sent. No error selects
another configured account, the legacy environment key or ChatGPT; there is no
automatic retry, repair or reconciliation. Waiting for a keyring prompt does not
authorize later HTTP after invocation cancellation or generation retirement.

A trusted explicit refresh names one record ID. The backend captures current ordinary
records and fresh credential authority together, validates the selected record, and
prepares new inference/catalog dispatchers on a fresh route before publication.
Neither capture nor preparation reads a secret, prompts for keyring unlock, performs
model discovery or starts inference HTTP. Each later operation lazily reads within
that immutable revision's scope. Capturing all authorized records does not refresh
or retire untargeted siblings.

| Current observation / change | Targeted refresh behavior |
| --- | --- |
| Valid record with no current revision | Publish its inference/catalog pair. |
| Valid current record after an edit or credential-only replacement | Replace the pair with a fresh configuration/credential capture, route, exact registrations and association. Equal ordinary values cannot establish unchanged credential authority. |
| Forget while the record remains valid | Publish a fresh revision whose credential read reports `notConfigured`; absence of an attached key is not record deletion. |
| Target absent from a complete observation | Retire the existing pair, or report no change if already absent. |
| Target omitted from an incomplete observation | Fail without inferring deletion. Healthy present targets remain eligible despite malformed siblings. |
| Invalid selected configuration or failed capture | Fail before replacing the old registrations; never substitute defaults or another account. |

After host publication confirms replacement or retirement, the old backend route
synchronously fences new requests and stream opens. Holding a binding, channel or
unsubscribed stream is not admission. Only requests and stream opens already
admitted by that route retain their old dispatcher, configuration and credential scope;
stream credit/cancellation and transport completion still reach that dispatcher.
Draining is asynchronous and does not block fresh selection or the refresh queue.
Capture ownership is reference-counted across preparation and revisions: the last
lease is released only after every owning route drains admitted work. A paused stream
or pending operation can delay release indefinitely. Failed candidate routes also
drain before releasing their scope, since uncertain publication may have admitted work.
Retaining a scope preserves its lifetime, not its validity: admitted credential reads
remain subject to the host's configuration freshness and generation checks.

Refresh admission is serialized and bounded, independently of the host's finite
[capture scopes](contracts-and-capabilities.md#backend-credential-access) and
[publication groups](contracts-and-capabilities.md#dynamic-capability-publication).
The eight capture slots per connection include retained refreshed revisions, pending
captures and released scopes still draining reads; startup authority is separate.
Exhaustion fails without evicting active revisions or releasing dependencies early
to make room. A rejected preflight preserves the old registration, not the validity
of its credential capture. A later read can still fail stale.

Failure after old-registration retirement reports unavailable rather than reviving
the old binding. An uncertain publication acknowledgement is not proof of rollback:
the backend fences further configured refresh until restart, retires/drains routes
that may have participated in the change, and leaves unrelated data-plane routes
usable. It does not automatically retry or reconcile uncertain publication. Safe
outcomes distinguish publication status from pending or unconfirmed cleanup; the
[OpenAI control surface](../../plugins/openai/packages/backend/README.md#explicit-configured-refresh)
owns exact response fields and codes.

An already-held binding never retargets to the new revision. Later operations through
retired bindings fail; only fresh resolution can select the replacement. Existing
Runs retain their captured provider, model and reasoning effort, not permission to
substitute a new account or route. Edits outside the Global Settings write path do
not trigger refresh. Without a targeted apply or restart, the existing revision
remains unchanged and credential reads can fail stale.

An HTTP request already started with a delivered credential may continue; Forget
cannot retract network authorization already in flight or erase immutable backend
strings. Existing cancellation/retirement mechanisms remain distinct from that limit.
Advertisement therefore means an invocable route for a valid record, not a successful
credential check or externally authenticated account. The independent experimental
ChatGPT credential-file path and explicit legacy API-key development mode remain
separate. The direct configuration still explicitly selects ChatGPT; registration
alone neither selects a provider nor establishes a Session selector UI.

## Credentials and secrets

Secrets are not ordinary serialized configuration values. Configuration may retain
nonsecret credential references, never secrets in TOML, Project/plugin state,
installation metadata, logs, or artifact identity inputs. A declared slot alone
grants no read access, performs no authentication and changes no provider selection.

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
reconciles it. Presence alone cannot verify replacement contents. Backend reads are
explicitly nonreconciling; no automatic retry, merge or secret enumeration is added.
[Backend delivery](#backend-credential-delivery) is a separate,
exact-generation authorization boundary, not direct plugin access to OS storage.
See the [application map](../../app/README.md) for local ownership and
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
Declared associations must be explicitly forgotten before deletion. Unknown entries
are neither adopted as slots nor automatically removed: the deletion guard reports
safe guidance for deliberate manual correction and Reload, without echoing credential
content. Removing a TOML entry manually does not delete its OS-stored value.

The app-private `RecordCredentialService`, part of `GlobalSettingsService`, is the
only association coordinator. Management callers supply an owner-bound `RecordView`, a declared
slot, and a secret for writes, not an owner, record type, native key or reference.
The existing Settings worker verifies the exact owner/revision, declaration and
conditional byte baseline. A shared worker admission gate spans the entire
management workflow, including OS waits, so ordinary configuration operations and other owners
cannot interleave with it. Every TOML operation still runs on that worker; there is
no second writer or native-document transfer to presentation. `CredentialService`
retains its independent OS-operation queue and uncertain-outcome fence.
Replacement and deletion revalidate the protected binding inside that queue, so
an intervening admitted host operation cannot substitute a foreign protected value.
Immediately before OS mutation, the coordinator revalidates the same configuration
baseline after queued operations and native preflight/unlock waits; a failed guard
does not perform a mutation or create an uncertain-outcome fence.

The OS-protected value is a JSON envelope with exactly `version`, `owner`,
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
conditional checks. The separate read-only [backend delivery](#backend-credential-delivery)
path reuses its binding validation without granting management operations. Neither
path adds OAuth, provider activation, Profile or Agent semantics.
Generic record views expose no credential references
or protected payloads. Linux x64 remains the only enabled native credential backend.

### Record credential management

Global Settings generates controls from each type's declared credential slots only
after the record exists. Presentation uses the application's retained association
coordinator, not a second credential service or direct native access. Opening,
reopening, navigating or reloading Settings does not probe the vault. Each slot
starts unchecked, which asserts neither presence nor absence. Explicit Check uses
`inspect`; setting a new association uses `attach`; replacement, missing-local
establishment, Forget and reconciliation use `replace`, `establishLocal`, `forget`
and `reconcile` respectively. No operation authenticates or activates a provider.

Status describes local storage only. A reference with confirmed missing-local data
is recoverable through deliberate `establishLocal`, using the same reference, or
Forget. Unavailable storage is not missing data and never permits implicit creation
or overwrite; invalid bindings remain failures without repair. An uncertain mutation
requires explicit reconciliation before a later deliberate mutation, not automatic
retry or a successful-looking status inferred from persisted configuration.

Secret input is masked and transient, never prefilled from OS storage or retained
with ordinary scalar drafts. Cancel, operation settlement (success or failure),
navigation away and dialog close clear it. Presentation displays only safe status
and fixed diagnostics, never stored secrets, references or protected envelopes.
Clearing controllers and dropping values limits retention; it does not guarantee
zeroization of immutable Dart strings or runtime copies.

Every returned owner-bound record view replaces only the corresponding record's
handle, including the latest acknowledged view carried by a partial failure. This
must preserve unsaved scalar field drafts and sibling record baselines; it is not a
collection refresh or field merge. Stale-record and configuration failures fence the
affected record until explicit Reload. Keyring reconciliation cannot repair a stale
configuration baseline. Closing presentation does not cancel an admitted workflow;
the application retains and drains its owners as described above.

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
replacement. For example, saving an Agent definition or selecting a Model Preset
changes the input to the next Run's preparation, not the active Run. See
[inference preparation](execution-model.md#inference-preparation) for the
distinction from per-inference observations, and [generation-bound execution](execution-model.md#generation-bound-execution)
for executable lifetimes. Neither is another settings cascade.

### Chat invocation budget

Chat declares `dev.adele.plugin.chat-strategy.max-model-invocations` in its
authoritative [`settings.schema.json`](../../plugins/chat_strategy/settings.schema.json).
It is an integer setting with default `40`, minimum `1`, and no declared maximum
beyond the scalar type's range, presented under **Agents / Execution**. Only the
declared default and optional global override participate; there is no Session or
Run override layer.

The Chat backend requires the resolved startup value and captures it when
materializing each Run. Continuations and approval resume retain that capture.
Changing this scalar neither mutates active Runs nor changes the budget for later
Runs on the same application startup snapshot; restarting ADELE applies it. The
limit is absent from Chat Session state, public snapshots, and relational storage;
`configureSession` changes instructions only. Native fixtures supply an explicit
positive constructor value, and standalone AOT hosts inject a value at backend
startup rather than changing a Session. The [execution model](execution-model.md#strategy-sequencing-and-host-mechanics)
owns sequencing and exhaustion semantics.

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
  deletion in Global Settings. Opted-in backends receive exact-installation
  nonsecret startup snapshots without changing UI baselines. OpenAI maps valid
  API-key records to independent providers in one generation, without startup
  credential reads; invocation retrieves the exact captured record's credential.
- Capability endpoints have generation-bound configuration contexts.
- Host credential storage has a Linux x64 Secret Service adapter and an app-private
  record association lifecycle with declaration-generated Global Settings controls,
  separately from narrow host-authorized backend credential delivery. Plugins have
  no direct native storage or association-management access.
- Durable product records and plugin-owned relational Session state provide no
  Profile, general settings, configured-instance, credential, or workbench storage.
- Backend infrastructure access is generation-local, distinct from both
  configuration routing and operation-scoped execution authority.
- Normal startup uses a fixed participation policy, attempting discovered valid
  components rather than resolving Profiles.
- Current provisional provider selection and temporary source-checkout configuration
  do not implement this architecture; operational details belong in the
  [application documentation](../../app/README.md#chatgpt-source-checkout-configuration).

Not implemented: Profile manager/persistence, profile-aware activation/routing,
Session provider/model selection, record-based OAuth,
or production workbench-state persistence.

## Deferred decisions

- Profile CRUD/import/export UX and storage.
- Optional named stack presets and non-remembering Profile switches.
- Broader configuration file schemas, local state/data store technologies, and
  portable/local overlays.
- Setting migration APIs, richer value types, and specific non-default merge
  semantics.
- Exact narrower subject scopes and their override semantics.
- Hierarchical security/policy configuration beyond global startup participation.
- Account-management and general public/plugin credential-storage APIs; additional
  native credential platforms require separate implementation and validation.
- General live plugin reconfiguration and automated restart mechanisms.
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
