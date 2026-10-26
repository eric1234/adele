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

void _validateRecordLocalId(
  String value,
  String label, {
  bool portable = false,
}) {
  if (value.length > 64 ||
      !RegExp(r'^[a-z][a-z0-9]*(?:-[a-z0-9]+)*$').hasMatch(value) ||
      (portable &&
          RegExp(r'^(?:con|prn|aux|nul|com[1-9]|lpt[1-9])$').hasMatch(value))) {
    throw FormatException('Invalid $label: $value.');
  }
}

/// Ordered record field metadata with no default, coercion, or executable hooks.
final class RecordFieldDefinition<T extends Object> {
  RecordFieldDefinition({
    required this.id,
    required this.label,
    this.description,
    required this.type,
    required this.required,
  }) {
    _validatePresentation(label, 'label');
  }

  final RecordFieldId id;
  final String label;
  final String? description;
  final SettingType<T> type;
  final bool required;
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
  }) : fields = List.unmodifiable(fields) {
    if (!id.value.startsWith('${owner.value}.')) {
      throw ArgumentError.value(id, 'id', 'Must be within owner $owner.');
    }
    _validatePresentation(collectionLabel, 'collectionLabel');
    _validatePresentation(label, 'label');
    final ids = <RecordFieldId>{};
    for (final field in this.fields) {
      if (!ids.add(field.id)) {
        throw ArgumentError.value(
          field.id,
          'fields',
          'Duplicate record field.',
        );
      }
    }
    if (displayField != null &&
        !this.fields.any(
          (field) =>
              field.id == displayField &&
              field.required &&
              field.type is StringSettingType,
        )) {
      throw ArgumentError.value(
        displayField,
        'displayField',
        'Must reference a declared required StringSettingType field.',
      );
    }
  }

  final RecordTypeId id;
  final PluginId owner;
  final RecordCollectionId collection;
  final String collectionLabel;
  final String label;
  final String? description;
  final List<RecordFieldDefinition<Object>> fields;

  /// Optional display-name source, referencing a required ordinary string field.
  ///
  /// This does not change record identity or constrain the field's string values.
  final RecordFieldId? displayField;

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
      final value = values[field.id.value];
      final violation = field.type._violation(value);
      if (violation != null) {
        throw InvalidRecordValue(collection, recordId, field.id, violation);
      }
      result[field.id.value] = value!;
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
