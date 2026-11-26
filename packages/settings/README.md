# ADELE Settings

`adele_settings` is an experimental public, pure-Dart package for immutable scalar
setting declarations, default/global value resolution, and named configuration
record declarations with separate deterministic catalogs.
Import `package:adele_settings/adele_settings.dart`. Its only production dependency
is `adele_plugin_api`, for public IDs, record-type ownership, and editor references.

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
| `StringSettingType` | Any Dart `String` unless the declaration specifies content constraints. |
| `EnumSettingType` | Exactly one declared stable string, not a separate TOML scalar type. Options are copied and immutable, nonempty, and unique by value. Values must be trimmed, nonblank, and free of controls/line breaks. Optional labels are nonblank single-line display text. |

`const StringSettingType()` permits empty and multiline text. Use
`StringSettingType.constrained` to combine any of these checks:

| Constraint | Valid when |
| --- | --- |
| `nonBlank: true` | `value.trim().isNotEmpty`. The original string, including leading/trailing whitespace, is returned. |
| `maxLength: n` | `value.length <= n`, in UTF-16 code units (not bytes or displayed characters). Declare a positive integer. |
| `rejectAsciiControls: true` | No U+0000 through U+001F or U+007F. |
| `format: StringSettingFormat.adelePublicId` | The shared `validateAdelePublicId` accepts the exact value. If also specified, `maxLength` must accommodate at least `a.b`. |

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
| `ConfigurationRecordId` | Immutable identity of one record within a collection, independent of its filename, display name and type. |
| `RecordTypeId` | ADELE public ID beneath the declaring `PluginId` namespace at a dot boundary. |
| `RecordFieldId` | Local field identity, never a synthetic `SettingId`. |
| `RecordCredentialSlotId` | Local credential-slot identity, distinct from scalar fields and credential references. |

Collection, record, field and credential-slot IDs use exact lowercase ASCII
`[a-z][a-z0-9]*(?:-[a-z0-9]+)*`, at most 64 characters. Collection and record IDs
additionally reject Windows device names `con`, `prn`, `aux`, `nul`, `com1` through
`com9`, and `lpt1` through `lpt9`. Reserved aliases such as `CON`, `con.txt`,
`conin$`, `conout$`, `clock$`, trailing dots/spaces, and superscript digits already
fail the grammar; no trimming or case normalization occurs. Field and slot IDs are
not paths and do not have the device-name restriction. Invalid IDs throw
`FormatException`. Identity classes have value equality within their own type.

`RecordFieldDefinition<T>` requires `id`, `label`, a `RecordFieldType<T>`, and
an explicit `required` boolean; `description` is optional. A field type is either
a scalar `SettingType<T>` or a `StructuredRecordFieldType`. Fields have no defaults,
null values, or executable validators. `RecordTypeDefinition` requires
`id`, `owner: PluginId`, `collection`, `collectionLabel`, `label`, and `fields`;
`description` is optional. Labels use the same presentation validation as settings;
descriptions are optional prose. Fields are copied, immutable, duplicate-free,
and retain declaration order. Empty field lists are valid. Ownership is declaration
consistency, not activation or proof of trust.

`StructuredRecordFieldType(properties)` declares one atomic field, not a nested
record. Its ordered map contains 1 to 16 `RecordFieldId` keys, each with a scalar
`SettingType<Object>`. Each property is required; structs cannot contain other
structs, optional components, or extra authored keys. Each string component is
limited to 65,536 UTF-16 code units, but an ordinary string can be empty. Property
names in values are the IDs' string values. The validated result is a detached,
immutable `Map<String, Object>` in declaration order. `field.snapshotValue(value)`
returns that snapshot (or the original scalar) and rejects invalid values with
`ArgumentError`; `field.valueError(value)` supplies feedback without throwing.
`recordFieldValuesEqual` compares field snapshots by content, not map identity.

`ContributedRecordFieldEditor(extensionId)` references an `ExtensionId` of the form
`<record type owner's PluginId>.<single local segment>`. It is optional for scalars.
A structured field must be required and name a contributed editor; this does not
require an installed or active frontend. An editor never changes value validation.
The only built-in hint, `RecordFieldEditor.markdown`, requests Markdown editing
for `StringSettingType` (not a string-valued enum).

`RecordTypeDefinition.formBehavior` can name an owned frontend operation for
[form presentation](../../docs/architecture/profiles-and-configuration.md#record-form-behavior).
On an optional ordinary enum, `unsetLabel` names the control's omission choice,
not a stored default. These references and labels do not change `validate`.

Optional `displayField: RecordFieldId?` identifies a declared required
`StringSettingType` field for record display names. Construction rejects missing,
optional, or other scalar-type references, including enum fields. Omission is null
and makes no display-field assumption; presentation can fall back to the record ID.
This metadata neither changes record identity nor adds string-value constraints:
use explicit string constraints if the field requires a nonblank display label.

`RecordCredentialSlotDefinition` requires `id`, `label`, and `kind`; the only
`RecordCredentialKind` is `secretText`. Labels use the existing nonblank single-line
presentation rules and are bounded to 128 UTF-16 code units. Optional
`RecordTypeDefinition.credentialSlots` defaults to an empty list, copies its input,
retains declaration order, is immutable, and rejects duplicate slot IDs within the
type. Slot identities are local to each type and independent of field identities.
These declarations contain neither secrets nor credential references and do not
participate in `validate(values)`. The app-private
[association lifecycle](../../docs/architecture/profiles-and-configuration.md#record-association-lifecycle)
owns storage and authorization.

`type.validate(recordId, Map<String, Object?> values)` validates known fields and
returns an immutable `Map<String, Object>` in declaration order. Required absence
fails; optional absence remains absent; explicit null and wrong scalar values
always fail. Scalar constraints use the same identity-independent primitive as
ordinary settings, preserving `InvalidSettingValue` behavior and messages for
existing consumers. Record failures instead throw `InvalidRecordValue` with
`collection`, `recordId`, `fieldId`, and `message`. Hosts may use a null `fieldId`
for record-wide/header errors.

Unknown top-level fields are not inspected or mutated. Inside a structured field,
the supplied value must contain exactly the declared properties. A storage adapter
projects only known properties for validation and preserves unknown persisted keys
when writing. The returned projection is **not a replacement persistence document**.

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
secret values or access, policy, or workbench state. Host adapters own storage
representation and must preserve their own unknown data. The broader ownership model is documented
in [profiles and configuration](../../docs/architecture/profiles-and-configuration.md)
and [dependency rules](../../docs/architecture/dependency-rules.md).

After repository bootstrap, run `dart test` and `dart analyze --fatal-infos` in
this directory for focused validation. These tests require no native library.
