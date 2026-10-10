# ADELE Settings Host

`adele_settings_host` is an internal, Flutter-free adapter connecting the public
[`adele_settings`](../settings/README.md) catalog and scalar resolver to
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
Prepared discovery, Profiles/Projects, Settings UI, secrets, named records, watching,
automatic merging, and runtime application boundaries are not implemented.

## Validation

After [bootstrap and native prerequisites](../../docs/development/toolchain.md#native-toml-documents):

```sh
dart tools/adele.dart test --target adele_settings_host
```

Run `dart analyze --fatal-infos` in this package for focused analysis. Tests use
isolated temporary roots and the actual CFG2 store with Rust TOML, not mocks. The
public semantic target `adele_settings` needs no Rust/native preparation.
