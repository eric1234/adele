# ADELE Settings Host

`adele_settings_host` is an internal, Flutter-free adapter connecting the public
[`adele_settings`](../settings/README.md) scalar and record declarations to
[`ConfigurationStore`](../configuration_store/README.md) and
[`TomlDocument`](../toml_document/README.md). It owns no file transaction, parser,
native build, plugin discovery, or runtime reconfiguration mechanism.

See [configuration architecture](../../docs/architecture/profiles-and-configuration.md)
for ordinary settings versus Profiles, named records, and domain state, and
[dependency rules](../../docs/architecture/dependency-rules.md) for the public/host
boundary. Plugins may use `adele_settings`, not this package.

## Host Workflow

Supply a `SettingsCatalog` assembled from independent declarations and a
`ConfigurationStore` configured with explicit storage roots:

```dart
import 'package:adele_configuration_store/adele_configuration_store.dart';
import 'package:adele_settings/adele_settings.dart';
import 'package:adele_settings_host/adele_settings_host.dart';

final host = GlobalSettingsStore(
  store: ConfigurationStore(roots),
  catalog: catalog,
);
final id = SettingId('dev.adele.example.output-limit');
final loaded = host.load();
final initial = loaded.resolve<int>(id);
final edited = loaded.setOverride(id, 5000);
final saved = host.save(edited);
final reloaded = host.load();
assert(reloaded.resolve<int>(id).value == 5000);
final reset = host.save(saved.resetOverride(id));
assert(reset.resolve<int>(id).source == SettingValueSource.defaultValue);
```

The catalog in this example must declare `id` as an integer accepting `5000`.
Operations are synchronous. Preserve CFG2's **one owning host isolate per process**
coordination and route work off the desktop UI isolate; constructing several
independent writer isolates is not supported. No application consumer is wired here.

`GlobalSettingsSnapshot` is an immutable pending document plus its last loaded or
saved whole-document baseline. Edits do not touch disk. `exists` describes that
baseline; `document` exposes immutable TOML for inspection. The successful `save`
result becomes the next baseline. Snapshots must use the same catalog instance,
and CFG2 rejects saves to a different configuration file. New adapter construction
and reload need no runtime or plugin backend.

## Stored Overrides

Overrides occupy root-level **literal** fully qualified keys in CFG2's existing
`<configurationRoot>/settings.toml`:

```toml
"dev.adele.example.enabled" = true
"dev.adele.example.output-limit" = 5000
"dev.adele.example.mode" = "detailed"
```

Each ID is passed to TOML operations as a one-element key path. Unquoted dotted
keys describe nested tables instead and are unrelated to this representation.
Enums are ordinary TOML strings. Defaults stay in declarations: loading an absent
file, resolving defaults, and resetting an absent key create no files or locks.
Setting a value equal to the default still creates an explicit global override.
Reset removes the key, not writes the default, and returns default provenance.

Only requested known settings are read and validated. Unknown/unavailable owners'
entries, including unsupported structures, remain untouched and cannot invalidate
independently known settings. Invalid known scalar values produce
`InvalidSettingOverride` with the setting ID and violation. Unsupported known TOML
types also become this diagnostic; they are never treated as absence. Malformed
TOML, native loading failures, UTF-8 errors, and I/O failures retain the underlying
document/store errors.

`setOverride` validates the new value before editing (`InvalidSettingValue` on
failure). Existing unsupported TOML or a different scalar type fails explicitly;
there is no structural conversion/repair. An explicit same-type replacement or
reset of a supported scalar can correct an invalid range/enum value. Reset of
unsupported structures fails too. No load/resolve operation repairs or rewrites
anything, and nullable settings are not supported.

## Configuration Records

`ConfigurationRecordStore(store: ConfigurationStore(roots), catalog: records)`
provides headless CRUD in one explicit configuration root. The `RecordCatalog`
normally comes from `PreparedPluginCatalog.records`; this adapter does not scan
installations or import plugins. The root can be supplied from
`PlatformStorageRoots.configurationRoot`; it is not a process-global constant.

```dart
final records = ConfigurationRecordStore(store: persistence, catalog: catalog);
final providers = RecordCollectionId('providers');
final id = ConfigurationRecordId('work-openai');
var record = await records.create(
  RecordTypeId('dev.adele.openai.api-key'),
  id,
  {'display-name': 'Work OpenAI'},
);
record = await records.update(record, {'display-name': 'Renamed Work'});
final collection = await records.enumerate(providers);
final reloaded = await records.load(providers, id);
await records.delete(reloaded);
```

`create` requires an unoccupied collection/record identity, including when another
record type or malformed content occupies it. `load` returns an immutable
`ConfigurationRecordSnapshot` with `id`, `type`, `collection`, typed known `values`,
the native document, and a private conditional baseline. Absence is
`ConfigurationRecordNotFound`, not an empty valid record. Snapshots belong to the
same catalog instance and exact file path; successful updates return the next
baseline. Reconstructing the store and explicitly loading recovers persisted data.

Updates supply the complete desired known-field set. Required fields must remain
present; omitted optional fields are removed, not defaulted. False, zero and empty
strings remain explicit values. Unknown desired fields are rejected, while unknown
persisted keys, tables and comments are retained by the native scalar editor. A
snapshot cannot change its record type, collection or ID. Delete removes just that
file, not credentials, other records, a mask or a cascading exclusion.

### File Format

For example, `providers/work-openai.toml` contains:

```toml
recordVersion = 1
recordType = "dev.adele.openai.api-key"

[values]
display-name = "Work OpenAI"
endpoint = "https://api.openai.com/v1"
```

The collection and filename supply stable identity; no editable ID is duplicated
inside the document. Renaming the display name never relocates the file. The header
requires integer version `1`, a declared type belonging to the exact collection,
and a regular `values` table (not an inline table or array). Values are literal
field keys. Unknown header/values content is not interpreted. Unsupported known
structures, missing required fields and invalid scalars fail rather than repairing
the file or silently substituting defaults. The shared public scalar validator owns
type, integer-bound and enum checks; there is no endpoint/provider-specific logic.
Use an explicit `[values]` table for optional-only records: removing the last
dotted key can discard its implicit parent in the native editor. Such an update
fails before saving rather than publishing a record without the required table.

### Enumeration and Safety

All record operations return Futures and first perform a bounded, nonrecursive
directory scan. On Linux the scan waits behind any ordinary writer using the
existing stable shared lock, then runs synchronously without exposing transaction
staging in either collection or configuration-root entries. The actual reads and
transactions remain synchronous on the owning host isolate; no additional actor
is created. Future desktop editing must route these operations through the
established serialized host I/O owner,
not construct a writer in the UI isolate alongside the Settings worker.

`enumerate` returns immutable filename-sorted `records` and `diagnostics`. A bad
file does not hide healthy siblings. Each diagnostic retains the filename,
collection, record ID when valid, and original error: malformed TOML, invalid
UTF-8, schema violations, file I/O failures and size limits remain distinguishable.
Unexpected entries are reported, never followed as records. Directory-wide I/O or
enumeration-limit failures reject the operation instead of returning an empty or
successful truncated list. A missing root/collection creates no artifacts.

Only validated lowercase portable IDs form paths. Case and trailing-dot/space
filename aliases block exact operations on that identity, and enumeration excludes
every conflicting candidate. Collection aliases are rejected by the filesystem
store. Collection and record-file symlinks are rejected; the explicitly supplied
configuration root may itself be symlinked. Every mutation uses the existing stable
configuration lock and independent file baseline. Stale updates/deletes, including
no-op updates, require explicit reload, with no retry or field-level merge.

The underlying store bounds each record at 1 MiB and scans at 1024 immediate entries
per configuration-root/collection directory, including unrelated entries. These
limits include the entry a create will add: capacity is rechecked inside the
existing write lock before creating a collection or staging, so cooperating
creates cannot overflow either directory. Full directories still permit existing
record updates/deletes; a full root permits new records in an existing collection
with room. No hidden/unexpected user names are excluded from the count. These
are fixed safeguards, not quotas or a query API. A collection result additionally
retains at most 16 MiB of valid record source; exceeding that bound rejects the
whole result, not a successful truncated list. External path changes after the
scan can still race observation; the established CFG2 uncooperative-writer and
protected-root limitations below apply. This is not an OS sandbox.

The real OpenAI declaration stores only nonsecret configuration and does not start
or reconfigure a provider. Credentials remain external. No Profiles, record editing
UI, secret entry, schema migrations, or runtime consumption is implemented here.

## Preservation and Limits

All saves use CFG2's conditional-save API. Stale writes, including stale no-ops,
propagate `ConfigurationConflictException` without reload, merge, or overwrite.
Equal-value edits and absent resets preserve the original document; an unchanged
save checks the baseline but does not rewrite bytes or create a lock.

Comments, unrelated keys, and unknown values retain TOML's existing best-effort
preservation. Actual edits can normalize line endings or scalar spelling, and
removing a key can remove its attached comments. All
[CFG2 placement, lock, permissions, symlink, and durability limits](../configuration_store/README.md#placement-and-coordination)
remain unchanged. Only configuration and CFG2's local-state lock are used, never
local application data/cache or Project storage.

Linux x64 is the validated native/persistence path; changed saves on macOS and
Windows remain unsupported by CFG2. The standard transitive native TOML hook
requires pinned Rust, but no CodeForge build. Independently loaded backend AOT
native-asset packaging remains unvalidated and unchanged. A successful save does
not mean an active plugin, provider binding, or in-flight Run adopted the value.
Prepared discovery belongs to `plugin_runtime`. Profiles/Projects, Settings UI,
secrets, watching, automatic merging, and runtime application boundaries are not
implemented by this adapter.

## Validation

After [bootstrap and native prerequisites](../../docs/development/toolchain.md#native-toml-documents):

```sh
dart tools/adele.dart test --target adele_settings_host
```

Run `dart analyze --fatal-infos` in this package for focused analysis. Tests use
isolated temporary roots and the actual CFG2 store with Rust TOML, not mocks. The
public semantic target `adele_settings` needs no Rust/native preparation.
`configuration_records_test.dart` publishes the actual OpenAI schema through the
maintained stock preparation helper, discovers it without executable startup, and
exercises independent records using real native TOML and conditional persistence.
A test-only job declaration covers Boolean, bounded integer and enum reuse.
