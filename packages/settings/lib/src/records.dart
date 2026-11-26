part of '../adele_settings.dart';

/// Portable collection identity, not an owning plugin or a filesystem path.
final class RecordCollectionId {
  factory RecordCollectionId(String value) {
    _validateRecordLocalId(value, 'record collection ID', portable: true);
    return RecordCollectionId._(value);
  }

  const RecordCollectionId._(this.value);
  final String value;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is RecordCollectionId && other.value == value;
  @override
  int get hashCode => value.hashCode;
  @override
  String toString() => value;
}

/// Portable identity of one named configuration record within a collection.
final class ConfigurationRecordId {
  factory ConfigurationRecordId(String value) {
    _validateRecordLocalId(value, 'configuration record ID', portable: true);
    return ConfigurationRecordId._(value);
  }

  const ConfigurationRecordId._(this.value);
  final String value;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ConfigurationRecordId && other.value == value;
  @override
  int get hashCode => value.hashCode;
  @override
  String toString() => value;
}

/// Public, owner-namespaced identity of a record declaration.
final class RecordTypeId {
  factory RecordTypeId(String value) {
    validateAdelePublicId(value, label: 'record type ID');
    return RecordTypeId._(value);
  }

  const RecordTypeId._(this.value);
  final String value;

  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is RecordTypeId && other.value == value;
  @override
  int get hashCode => value.hashCode;
  @override
  String toString() => value;
}

/// Local field identity, independent of ordinary setting IDs.
final class RecordFieldId {
  factory RecordFieldId(String value) {
    _validateRecordLocalId(value, 'record field ID');
    return RecordFieldId._(value);
  }

  const RecordFieldId._(this.value);
  final String value;

  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is RecordFieldId && other.value == value;
  @override
  int get hashCode => value.hashCode;
  @override
  String toString() => value;
}

/// Local credential association identity, separate from ordinary record fields.
final class RecordCredentialSlotId {
  factory RecordCredentialSlotId(String value) {
    _validateRecordLocalId(value, 'record credential slot ID');
    return RecordCredentialSlotId._(value);
  }

  const RecordCredentialSlotId._(this.value);
  final String value;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is RecordCredentialSlotId && other.value == value;
  @override
  int get hashCode => value.hashCode;
  @override
  String toString() => value;
}

void _validateRecordLocalId(
  String value,
  String label, {
  bool portable = false,
}) {
  if (_recordSegmentError(value, portable: portable) != null) {
    throw FormatException('Invalid $label: $value.');
  }
}

// Local identities and initial filename stems share lexical restrictions only.
String? _recordSegmentError(String value, {required bool portable}) {
  if (value.length > 64) return 'Use at most 64 characters.';
  if (!RegExp(r'^[a-z][a-z0-9]*(?:-[a-z0-9]+)*$').hasMatch(value)) {
    return 'Start with a letter and use letters or digits separated by hyphens.';
  }
  if (portable &&
      RegExp(r'^(?:con|prn|aux|nul|com[1-9]|lpt[1-9])$').hasMatch(value)) {
    return 'Choose a name that is not a reserved device name.';
  }
  return null;
}

/// A closed record value declaration: a scalar or one flat structured value.
sealed class RecordFieldType<T extends Object> {
  const RecordFieldType._();

  /// Exactly one of the immutable snapshot and the validation error is non-null.
  (T? snapshot, String? error) _checkedValue(Object? value);
}

/// A single atomic field with an ordered, fixed set of required scalar properties.
final class StructuredRecordFieldType
    extends RecordFieldType<Map<String, Object>> {
  factory StructuredRecordFieldType(
    Map<RecordFieldId, SettingType<Object>> properties,
  ) {
    if (properties.isEmpty || properties.length > maxProperties) {
      throw ArgumentError(
        'A structured field requires 1..$maxProperties properties.',
      );
    }
    final copy = Map<RecordFieldId, SettingType<Object>>.unmodifiable(
      properties,
    );
    if (copy.length != properties.length) {
      throw ArgumentError('Duplicate structured property ID.');
    }
    return StructuredRecordFieldType._(copy);
  }

  const StructuredRecordFieldType._(this.properties) : super._();

  static const maxProperties = 16;

  /// Maximum UTF-16 code units in a single string component.
  static const maxStringLength = 64 * 1024;

  final Map<RecordFieldId, SettingType<Object>> properties;

  @override
  (Map<String, Object>?, String?) _checkedValue(Object? value) {
    if (value is! Map<Object?, Object?>) {
      return (null, 'Expected a structured value.');
    }
    if (value.length > properties.length) {
      return (null, 'Unexpected structured property.');
    }
    // Loose transport maps are allowed, but only their actual string keys count.
    final input = <String, Object?>{};
    for (final entry in value.entries) {
      final key = entry.key;
      if (key is! String) return (null, 'Expected string property IDs.');
      input[key] = entry.value;
    }
    final snapshot = <String, Object>{};
    for (final property in properties.entries) {
      final key = property.key.value;
      if (!input.containsKey(key)) {
        return (null, 'Required property $key is missing.');
      }
      final component = input[key];
      if (component is String && component.length > maxStringLength) {
        return (
          null,
          'Property $key exceeds $maxStringLength UTF-16 code units.',
        );
      }
      final error = property.value._violation(component);
      if (error != null) return (null, 'Property $key: $error');
      snapshot[key] = component!;
    }
    return (Map<String, Object>.unmodifiable(snapshot), null);
  }
}

/// Compares two field snapshots (or absence) without depending on map identity
/// or property order. This compares one field, not a whole record.
bool recordFieldValuesEqual(Object? left, Object? right) {
  if (left is! Map<Object?, Object?> || right is! Map<Object?, Object?>) {
    return left == right;
  }
  return left.length == right.length &&
      left.entries.every(
        (entry) =>
            right.containsKey(entry.key) && right[entry.key] == entry.value,
      );
}

/// Presentation hint for a record field, not a value type.
sealed class RecordFieldEditor {
  const RecordFieldEditor._();

  static const RecordFieldEditor markdown = _BuiltinRecordFieldEditor.markdown;
}

enum _BuiltinRecordFieldEditor implements RecordFieldEditor { markdown }

/// A reference to an editor contributed by the record type's owning plugin.
/// It neither requires a live registration nor changes value validation.
final class ContributedRecordFieldEditor extends RecordFieldEditor {
  const ContributedRecordFieldEditor(this.extensionId) : super._();

  final ExtensionId extensionId;

  /// Checks the declaration namespace, not installation or registration liveness.
  bool isOwnedBy(PluginId owner) => isOwnedRecordExtension(extensionId, owner);

  @override
  bool operator ==(Object other) =>
      other is ContributedRecordFieldEditor && other.extensionId == extensionId;

  @override
  int get hashCode => extensionId.hashCode;
}

/// Field editor and form behavior references belong directly to their declaring
/// plugin, not to a parent or nested plugin with a similar namespace.
bool isOwnedRecordExtension(ExtensionId id, PluginId owner) =>
    id.value.substring(0, id.value.lastIndexOf('.')) == owner.value;

/// Ordered record field metadata with no default, coercion, or executable hooks.
final class RecordFieldDefinition<T extends Object> {
  RecordFieldDefinition({
    required this.id,
    required this.label,
    this.description,
    required this.type,
    required this.required,
    this.editor,
    this.unsetLabel,
  }) {
    _validatePresentation(label, 'label');
    if (unsetLabel case final text?) {
      if (required || type is! EnumSettingType || editor != null) {
        throw ArgumentError('unsetLabel requires an ordinary optional enum.');
      }
      _validatePresentation(text, 'unsetLabel');
    }
    if (editor is _BuiltinRecordFieldEditor && type is! StringSettingType) {
      throw ArgumentError.value(
        editor,
        'editor',
        'Built-in record field editors require a StringSettingType field.',
      );
    }
    if (type is StructuredRecordFieldType) {
      if (!required) {
        throw ArgumentError('Structured field $id must be required.');
      }
      if (editor is! ContributedRecordFieldEditor) {
        throw ArgumentError(
          'Structured field $id requires a contributed editor.',
        );
      }
    }
  }

  final RecordFieldId id;
  final String label;
  final String? description;
  final RecordFieldType<T> type;
  final bool required;
  final RecordFieldEditor? editor;

  /// Presentation of absence on an optional enum; never an option or a default.
  final String? unsetLabel;

  /// Validation feedback for a present value, independent of field inclusion.
  String? valueError(Object? value) => type._checkedValue(value).$2;

  /// Returns an immutable snapshot of a present value, or throws [ArgumentError].
  T snapshotValue(Object? value) {
    final (snapshot, error) = type._checkedValue(value);
    if (error != null) throw ArgumentError('Field $id: $error');
    return snapshot!;
  }
}

/// Credential shape metadata, not an ordinary setting value type.
enum RecordCredentialKind { secretText }

/// Data-only credential association metadata; contains no secret or reference.
final class RecordCredentialSlotDefinition {
  RecordCredentialSlotDefinition({
    required this.id,
    required this.label,
    required this.kind,
  }) {
    _validatePresentation(label, 'label');
    if (label.length > maxLabelLength) {
      throw ArgumentError.value(
        label,
        'label',
        'Must not exceed $maxLabelLength characters.',
      );
    }
  }

  static const maxLabelLength = 128;

  final RecordCredentialSlotId id;
  final String label;
  final RecordCredentialKind kind;
}

/// A plugin-owned record type, grouped into a product-facing collection.
final class RecordTypeDefinition {
  RecordTypeDefinition({
    required this.id,
    required this.owner,
    required this.collection,
    required this.collectionLabel,
    required this.label,
    this.description,
    required Iterable<RecordFieldDefinition<Object>> fields,
    this.displayField,
    RecordFieldId? filenameField,
    this.formBehavior,
    Iterable<RecordCredentialSlotDefinition> credentialSlots = const [],
  }) : fields = List.unmodifiable(fields),
       credentialSlots = List.unmodifiable(credentialSlots) {
    if (!id.value.startsWith('${owner.value}.')) {
      throw ArgumentError.value(id, 'id', 'Must be within owner $owner.');
    }
    if (formBehavior case final id? when !isOwnedRecordExtension(id, owner)) {
      throw ArgumentError.value(
        id,
        'formBehavior',
        'Must be directly within owner $owner.',
      );
    }
    _validatePresentation(collectionLabel, 'collectionLabel');
    _validatePresentation(label, 'label');
    final byId = <RecordFieldId, RecordFieldDefinition<Object>>{};
    for (final field in this.fields) {
      final editor = field.editor;
      if (editor is ContributedRecordFieldEditor && !editor.isOwnedBy(owner)) {
        throw ArgumentError.value(
          editor.extensionId,
          'editor',
          'Editor for field ${field.id} must be directly within owner $owner.',
        );
      }
      if (byId.containsKey(field.id)) {
        throw ArgumentError.value(
          field.id,
          'fields',
          'Duplicate record field.',
        );
      }
      byId[field.id] = field;
    }
    final slotIds = <RecordCredentialSlotId>{};
    for (final slot in this.credentialSlots) {
      if (!slotIds.add(slot.id)) {
        throw ArgumentError.value(
          slot.id,
          'credentialSlots',
          'Duplicate record credential slot.',
        );
      }
    }
    RecordFieldDefinition<Object>? requiredStringField(
      RecordFieldId? reference,
      String parameter,
    ) {
      if (reference == null) return null;
      final field = byId[reference];
      if (field == null ||
          !field.required ||
          field.type is! StringSettingType) {
        throw ArgumentError.value(
          reference,
          parameter,
          'Must reference a declared required StringSettingType field.',
        );
      }
      return field;
    }

    requiredStringField(displayField, 'displayField');
    _filenameSource = requiredStringField(filenameField, 'filenameField');
  }

  final RecordTypeId id;
  final PluginId owner;
  final RecordCollectionId collection;
  final String collectionLabel;
  final String label;
  final String? description;
  final List<RecordFieldDefinition<Object>> fields;

  /// Ordered credential associations, never part of ordinary [validate] values.
  final List<RecordCredentialSlotDefinition> credentialSlots;

  /// Optional display-name source, referencing a required ordinary string field.
  ///
  /// This does not change record identity or constrain the field's string values.
  final RecordFieldId? displayField;

  /// Optional source of the initial filename, independent of [displayField].
  RecordFieldId? get filenameField => _filenameSource?.id;
  late final RecordFieldDefinition<Object>? _filenameSource;

  /// Optional presentation behavior of the exact owning frontend. This does not
  /// change record validation or require the frontend to be active.
  final ExtensionId? formBehavior;

  /// Derives a basename for creation, not the location of an existing record.
  /// Checks only the designated source; [validate] checks the whole record.
  String initialFileName(
    ConfigurationRecordId recordId,
    Map<String, Object?> values,
  ) {
    final field = _filenameSource;
    if (field == null) return '${recordId.value}.toml';

    final value = values[field.id.value];
    final error = values.containsKey(field.id.value)
        ? field.valueError(value)
        : 'Required field is missing.';
    if (error != null) {
      throw InvalidRecordValue(collection, recordId, field.id, error);
    }
    final source = value as String;
    if (RegExp(r'[^\x20-\x7e]').hasMatch(source)) {
      throw InvalidRecordValue(
        collection,
        recordId,
        field.id,
        'Use only printable ASCII characters for the filename.',
      );
    }
    final stem = RegExp(
      r'[a-z0-9]+',
    ).allMatches(source.toLowerCase()).map((match) => match[0]!).join('-');
    final stemError = _recordSegmentError(stem, portable: true);
    if (stemError != null) {
      throw InvalidRecordValue(
        collection,
        recordId,
        field.id,
        'Filename: $stemError',
      );
    }
    return '$stem.toml';
  }

  /// Validates known fields and returns an immutable projection in field order.
  ///
  /// Unknown persisted fields are neither inspected nor mutated. This projection
  /// is not a replacement persistence document; hosts must retain unknown data.
  /// Missing optional fields stay absent, while explicit null always fails.
  Map<String, Object> validate(
    ConfigurationRecordId recordId,
    Map<String, Object?> values,
  ) {
    final result = <String, Object>{};
    for (final field in fields) {
      if (!values.containsKey(field.id.value)) {
        if (field.required) {
          throw InvalidRecordValue(
            collection,
            recordId,
            field.id,
            'Required field is missing.',
          );
        }
        continue;
      }
      final (snapshot, violation) = field.type._checkedValue(
        values[field.id.value],
      );
      if (violation != null) {
        throw InvalidRecordValue(collection, recordId, field.id, violation);
      }
      result[field.id.value] = snapshot!;
    }
    return Map.unmodifiable(result);
  }
}

/// Immutable record declarations, sorted by type ID independently of discovery.
final class RecordCatalog {
  RecordCatalog(Iterable<RecordTypeDefinition> definitions)
    : definitions = List.unmodifiable(
        List<RecordTypeDefinition>.of(definitions)..sort((a, b) {
          final order = a.id.value.compareTo(b.id.value);
          return order != 0 ? order : a.owner.value.compareTo(b.owner.value);
        }),
      ) {
    for (final definition in this.definitions) {
      final previous = _byId[definition.id];
      if (previous != null) {
        throw DuplicateRecordTypeId(
          definition.id,
          previous.owner,
          definition.owner,
        );
      }
      final previousLabel = _collectionLabels[definition.collection];
      if (previousLabel != null &&
          previousLabel != definition.collectionLabel) {
        throw ConflictingRecordCollectionLabel(
          definition.collection,
          previousLabel,
          definition.collectionLabel,
        );
      }
      _byId[definition.id] = definition;
      _collectionLabels[definition.collection] = definition.collectionLabel;
    }
    collections = List.unmodifiable(
      _collectionLabels.keys.toList()
        ..sort((a, b) => a.value.compareTo(b.value)),
    );
  }

  final List<RecordTypeDefinition> definitions;
  late final List<RecordCollectionId> collections;
  final Map<RecordTypeId, RecordTypeDefinition> _byId = {};
  final Map<RecordCollectionId, String> _collectionLabels = {};

  RecordTypeDefinition definition(RecordTypeId id) {
    final result = _byId[id];
    if (result == null) throw RecordTypeNotFound(id);
    return result;
  }

  String collectionLabel(RecordCollectionId id) {
    final label = _collectionLabels[id];
    if (label == null) {
      throw ArgumentError.value(id, 'id', 'Unknown collection.');
    }
    return label;
  }
}

final class InvalidRecordValue implements Exception {
  const InvalidRecordValue(
    this.collection,
    this.recordId,
    this.fieldId,
    this.message,
  );

  final RecordCollectionId collection;
  final ConfigurationRecordId recordId;

  /// Null for a record-wide failure, such as an invalid persisted header.
  final RecordFieldId? fieldId;
  final String message;

  @override
  String toString() =>
      'InvalidRecordValue: $collection/$recordId: '
      '${fieldId == null ? '' : '$fieldId: '}$message';
}

final class RecordTypeNotFound implements Exception {
  const RecordTypeNotFound(this.id);
  final RecordTypeId id;

  @override
  String toString() => 'RecordTypeNotFound: $id is not declared.';
}

final class DuplicateRecordTypeId implements Exception {
  const DuplicateRecordTypeId(this.id, this.firstOwner, this.secondOwner);
  final RecordTypeId id;
  final PluginId firstOwner;
  final PluginId secondOwner;

  @override
  String toString() =>
      'DuplicateRecordTypeId: $id is declared by $firstOwner and $secondOwner.';
}

final class ConflictingRecordCollectionLabel implements Exception {
  const ConflictingRecordCollectionLabel(
    this.collection,
    this.first,
    this.second,
  );
  final RecordCollectionId collection;
  final String first;
  final String second;

  @override
  String toString() =>
      'ConflictingRecordCollectionLabel: $collection has labels $first and $second.';
}
