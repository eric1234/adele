# ADELE Settings

`adele_settings` is an experimental public, pure-Dart package for immutable scalar
setting declarations, default/global value resolution, and named configuration
record declarations with separate deterministic catalogs.
Import `package:adele_settings/adele_settings.dart`. Its only production dependency
is `adele_plugin_api`, for the shared public-ID validator and record-type ownership.

## Declarations

`SettingId` and `SettingOwnerId` are separate value identities using ADELE's
lowercase reverse-domain ID grammar. A definition's ID must start with its owner's
value plus `.`. An owner identifies the declaration namespace, not a `PluginId`,
runtime generation, registration, or trust verification. Nested namespaces can
still collide on one setting ID; the catalog rejects every duplicate and reports
both owners.

`SettingDefinition<T>` requires an ID, owner, label, category, section, type, and
default. Required presentation fields are nonblank single-line text without
control characters; optional description is prose and may contain line breaks.
Defaults and subsequent values pass the same validation, with no coercion:

| Type | Values |
| --- | --- |
| `BooleanSettingType` | Dart `bool`. |
| `IntegerSettingType` | Native Dart signed 64-bit `int`, from -9223372036854775808 through 9223372036854775807; optional inclusive `minimum` and `maximum`. No `double`, `BigInt`, or numeric string conversion. This is a native-runtime contract, not JavaScript integer portability. |
| `StringSettingType` | Any Dart `String`, including empty or multiline content. |
| `EnumSettingType` | Exactly one declared stable string, not a separate TOML scalar type. Options are copied and immutable, nonempty, and unique by value. Values must be trimmed, nonblank, and free of controls/line breaks. Optional labels are nonblank single-line display text. |

`definition.validate(value)` returns `T` or throws `InvalidSettingValue` with the
setting ID and a message. Invalid defaults fail during construction with that same
error; malformed declarations and typed resolution mismatches are argument errors
(malformed public IDs use the shared validator's `FormatException`).

## Use

```dart
import 'package:adele_settings/adele_settings.dart';

final owner = SettingOwnerId('dev.example.editor');
final tabWidth = SettingDefinition<int>(
  id: SettingId('dev.example.editor.tab-width'),
  owner: owner,
  label: 'Tab width',
  category: 'Editor',
  section: 'Indentation',
  type: IntegerSettingType(minimum: 1, maximum: 16),
  defaultValue: 4,
);
final catalog = SettingsCatalog([tabWidth]);
final declared = catalog.definition(tabWidth.id);
final resolved = catalog.resolve<int>(
  declared.id,
  globalOverrides: {declared.id: 2},
);
// resolved.value == 2
// resolved.source == SettingValueSource.global
// resolved.hasGlobalOverride == true
```

`SettingsCatalog` copies its input and exposes an immutable `definitions` list
sorted by ID. Missing lookups throw `SettingNotFound`; duplicate declarations
throw `DuplicateSettingId`. Typed resolution requests are checked against the
declared scalar type, including when a mixed catalog infers definitions as
`SettingDefinition<Object>`. Both enum and ordinary string declarations have
`String` values.

Resolution only chooses between a validated default and a supplied global map.
`containsKey` distinguishes absence from explicit `null`: all current types are
non-null, so a known null override throws `InvalidSettingOverride`. Other invalid
known overrides also throw that error, never silently falling back. Unknown map
entries are ignored. Results retain `id`, `value`, `source`, and independent
`hasGlobalOverride` presence, including overrides equal to the default. Removing
an override resumes the default; the catalog does not retain the caller's map.

## Named Records

Record declarations are separate from scalar settings and their default/global
resolution. They describe user-named structured configuration, not Dart `Record`
values, executable registrations, live providers, or plugin instances.

| Identity | Contract |
| --- | --- |
| `RecordCollectionId` | Product-facing collection, shared across declaring plugins. |
| `ConfigurationRecordId` | One named record within a collection, independent of its display name and type. |
| `RecordTypeId` | ADELE public ID beneath the declaring `PluginId` namespace at a dot boundary. |
| `RecordFieldId` | Local field identity, never a synthetic `SettingId`. |

Collection, record, and field IDs use exact lowercase ASCII
`[a-z][a-z0-9]*(?:-[a-z0-9]+)*`, at most 64 characters. Collection and record IDs
additionally reject Windows device names `con`, `prn`, `aux`, `nul`, `com1` through
`com9`, and `lpt1` through `lpt9`. Reserved aliases such as `CON`, `con.txt`,
`conin$`, `conout$`, `clock$`, trailing dots/spaces, and superscript digits already
fail the grammar; no trimming or case normalization occurs. Field IDs are not
paths and do not have the device-name restriction. Invalid IDs throw
`FormatException`. Identity classes have value equality within their own type.

`RecordFieldDefinition<T>` requires `id`, `label`, existing `SettingType<T>`, and
an explicit `required` boolean; `description` is optional. Fields have no defaults,
null values, callbacks, or nested structures. `RecordTypeDefinition` requires
`id`, `owner: PluginId`, `collection`, `collectionLabel`, `label`, and `fields`;
`description` is optional. Labels use the same presentation validation as settings;
descriptions are optional prose. Fields are copied, immutable, duplicate-free,
and retain declaration order. Empty field lists are valid. Ownership is declaration
consistency, not activation or proof of trust.

Optional `displayField: RecordFieldId?` identifies a declared required
`StringSettingType` field for record display names. Construction rejects missing,
optional, or other scalar-type references, including enum fields. Omission is null
and makes no display-field assumption; presentation can fall back to the record ID.
This metadata neither changes record identity nor adds string-value constraints:
empty and multiline values remain ordinary strings.

`type.validate(recordId, Map<String, Object?> values)` validates known fields and
returns an immutable `Map<String, Object>` in declaration order. Required absence
fails; optional absence remains absent; explicit null and wrong scalar values
always fail. Scalar constraints use the same identity-independent primitive as
ordinary settings, preserving `InvalidSettingValue` behavior and messages for
existing consumers. Record failures instead throw `InvalidRecordValue` with
`collection`, `recordId`, `fieldId`, and `message`. Hosts may use a null `fieldId`
for record-wide/header errors.

Unknown persisted keys are not inspected or mutated. The returned known-field
projection is **not a replacement persistence document**: host adapters must retain
unknown data and may reject unknown keys in desired edits. Validation neither reads
nor rewrites persisted records.

`RecordCatalog(definitions)` copies declarations and exposes immutable `definitions`
sorted by type ID and `collections` sorted by collection ID. `definition(typeId)`
throws `RecordTypeNotFound` when absent; `collectionLabel(collectionId)` throws an
argument error for an undeclared collection. Duplicate type IDs throw
`DuplicateRecordTypeId`, including both owners; different labels for the same
collection throw `ConflictingRecordCollectionLabel`. Neither conflict selects a
winner. Distinct types and plugins may share a collection when labels agree exactly.

Prepared JSON declaration discovery is owned by
[`plugin_runtime`](../plugin_runtime/README.md#record-schemas), not this package.

## Boundaries

This package owns no persistence, TOML parsing/serialization, filesystem access,
callbacks, schema transport, plugin registration/lifecycle, UI, or native code.
It does not implement Profiles, Project/Session overrides, a generic cascade,
secrets, policy, or workbench state. Host adapters own storage representation and
must preserve their own unknown data. The broader ownership model is documented
in [profiles and configuration](../../docs/architecture/profiles-and-configuration.md)
and [dependency rules](../../docs/architecture/dependency-rules.md).

After repository bootstrap, run `dart test` and `dart analyze --fatal-infos` in
this directory for focused validation. These tests require no native library.
