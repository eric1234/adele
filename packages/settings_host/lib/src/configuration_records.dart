import 'dart:convert';
import 'dart:io';

import 'package:adele_configuration_store/adele_configuration_store.dart';
import 'package:adele_settings/adele_settings.dart';
import 'package:adele_toml_document/adele_toml_document.dart';

/// Headless, single-layer records over the host's existing configuration owner.
///
/// The supplied store carries explicit roots. Route these operations through the
/// same owning isolate as scalar settings, never an independent UI-isolate writer.
/// Enumeration is asynchronous to bound directory iteration; transactions reuse
/// the synchronous configuration store and its stable cross-process lock.
final class ConfigurationRecordStore {
  const ConfigurationRecordStore({required this.store, required this.catalog});

  /// Bounds retained documents in one successful collection result.
  static const maxEnumerationBytes = 16 * 1024 * 1024;

  final ConfigurationStore store;
  final RecordCatalog catalog;

  /// Returns valid records and attributable failures, each in filename order.
  /// Directory-wide failures reject the operation, never an empty replacement.
  Future<ConfigurationRecordEnumeration> enumerate(
    RecordCollectionId collection,
  ) async {
    catalog.collectionLabel(collection);
    final entries = await store.listCollection(collection.value);
    final names = <String, int>{};
    for (final entry in entries) {
      names.update(_alias(entry.name), (count) => count + 1, ifAbsent: () => 1);
    }
    final records = <ConfigurationRecordSnapshot>[];
    final diagnostics = <ConfigurationRecordDiagnostic>[];
    var sourceBytes = 0;
    for (final entry in entries) {
      ConfigurationRecordId? id;
      try {
        final name = entry.name;
        if (!name.endsWith('.toml')) {
          throw FormatException(
            'Expected a canonical <record-id>.toml filename.',
          );
        }
        id = ConfigurationRecordId(name.substring(0, name.length - 5));
        if (names[_alias(name)] != 1) {
          throw ConfigurationRecordFormatException(
            collection,
            id,
            'Ambiguous record filename aliases.',
          );
        }
        if (entry.type != FileSystemEntityType.file) {
          throw ConfigurationRecordFormatException(
            collection,
            id,
            'Expected a regular record file, not ${entry.type}.',
          );
        }
        final record = _load(collection, id);
        sourceBytes += utf8.encode(record.document.source).length;
        records.add(record);
      } on Exception catch (error) {
        diagnostics.add(
          ConfigurationRecordDiagnostic(collection, entry.name, id, error),
        );
      }
      if (sourceBytes > maxEnumerationBytes) {
        throw ConfigurationLimitException(
          collection.value,
          maxEnumerationBytes,
          'enumerated record bytes',
        );
      }
    }
    return ConfigurationRecordEnumeration._(records, diagnostics);
  }

  Future<ConfigurationRecordSnapshot> load(
    RecordCollectionId collection,
    ConfigurationRecordId id,
  ) async {
    await _checkIdentity(collection, id);
    return _load(collection, id);
  }

  Future<ConfigurationRecordSnapshot> create(
    RecordTypeId typeId,
    ConfigurationRecordId id,
    Map<String, Object?> values,
  ) async {
    final type = catalog.definition(typeId);
    final validated = _validateDesired(type, id, values);
    var document = TomlDocument.parse(
      'recordVersion = 1\nrecordType = ""\n\n[values]\n',
    ).setScalar(['recordType'], type.id.value);
    for (final field in type.fields) {
      if (validated.containsKey(field.id.value)) {
        document = document.setScalar([
          'values',
          field.id.value,
        ], validated[field.id.value]!);
      }
    }
    await _checkIdentity(type.collection, id);
    final saved = _file(type.collection, id).create(document);
    return ConfigurationRecordSnapshot._(catalog, id, type, validated, saved);
  }

  /// Replaces the complete known-field set, preserving unknown content. Omitted
  /// optional fields are removed. No identity/type changes or field merging.
  Future<ConfigurationRecordSnapshot> update(
    ConfigurationRecordSnapshot expected,
    Map<String, Object?> values,
  ) async {
    _checkCatalog(expected);
    final validated = _validateDesired(expected.type, expected.id, values);
    var document = expected.document;
    for (final field in expected.type.fields) {
      final path = ['values', field.id.value];
      document = validated.containsKey(field.id.value)
          ? document.setScalar(path, validated[field.id.value]!)
          : document.removeScalar(path);
    }
    try {
      document.requireTable(['values']);
    } on TomlException catch (error) {
      // Removing the last dotted key can discard an implicit parent. Do not
      // publish an invalid record or invent structural repair in this adapter.
      throw InvalidRecordValue(
        expected.collection,
        expected.id,
        null,
        'The edit must retain a regular [values] table: ${error.message}',
      );
    }
    await _checkIdentity(expected.collection, expected.id);
    final saved = _file(
      expected.collection,
      expected.id,
    ).save(expected._baseline, document);
    if (identical(saved, expected._baseline)) return expected;
    return ConfigurationRecordSnapshot._(
      catalog,
      expected.id,
      expected.type,
      validated,
      saved,
    );
  }

  /// Removes only this record in this layer, conditional on its observed bytes.
  Future<void> delete(ConfigurationRecordSnapshot expected) async {
    _checkCatalog(expected);
    await _checkIdentity(expected.collection, expected.id);
    _file(expected.collection, expected.id).delete(expected._baseline);
  }

  ConfigurationStore _file(
    RecordCollectionId collection,
    ConfigurationRecordId id,
  ) => store.recordFile(collectionId: collection.value, recordId: id.value);

  Future<void> _checkIdentity(
    RecordCollectionId collection,
    ConfigurationRecordId id,
  ) async {
    catalog.collectionLabel(collection);
    final name = '${id.value}.toml';
    // Cooperating writers only create canonical names. An external editor can
    // still change entries after this bounded scan, just as it can race CFG2's
    // final byte check; this is not filesystem compare-and-swap.
    for (final entry in await store.listCollection(collection.value)) {
      if (_alias(entry.name) == name && entry.name != name) {
        throw ConfigurationRecordFormatException(
          collection,
          id,
          'Noncanonical or ambiguous filename: ${entry.name}.',
        );
      }
    }
  }

  ConfigurationRecordSnapshot _load(
    RecordCollectionId collection,
    ConfigurationRecordId id,
  ) {
    final baseline = _file(collection, id).load();
    if (!baseline.exists) throw ConfigurationRecordNotFound(collection, id);
    final document = baseline.document;
    final RecordTypeDefinition type;
    try {
      if (document.readScalar(['recordVersion']) != 1) {
        throw ConfigurationRecordFormatException(
          collection,
          id,
          'recordVersion must be integer 1.',
        );
      }
      final typeValue = document.readScalar(['recordType']);
      if (typeValue is! String) {
        throw ConfigurationRecordFormatException(
          collection,
          id,
          'recordType must be a declared record-type string.',
        );
      }
      type = catalog.definition(RecordTypeId(typeValue));
      if (type.collection != collection) {
        throw ConfigurationRecordFormatException(
          collection,
          id,
          'Record type ${type.id} belongs to ${type.collection}.',
        );
      }
      document.requireTable(['values']);
    } on TomlException catch (error) {
      throw ConfigurationRecordFormatException(collection, id, error.message);
    } on FormatException catch (error) {
      throw ConfigurationRecordFormatException(collection, id, error.message);
    } on RecordTypeNotFound catch (error) {
      throw ConfigurationRecordFormatException(
        collection,
        id,
        error.toString(),
      );
    }
    final values = <String, Object?>{};
    for (final field in type.fields) {
      try {
        values[field.id.value] = document.readScalar([
          'values',
          field.id.value,
        ]);
      } on TomlException catch (error) {
        // requireTable above establishes the parent. Only a missing leaf is
        // absence; unsupported known structures must never be repaired away.
        if (error.kind == TomlFailureKind.path) continue;
        throw InvalidRecordValue(collection, id, field.id, error.message);
      }
    }
    return ConfigurationRecordSnapshot._(
      catalog,
      id,
      type,
      type.validate(id, values),
      baseline,
    );
  }

  Map<String, Object> _validateDesired(
    RecordTypeDefinition type,
    ConfigurationRecordId id,
    Map<String, Object?> values,
  ) {
    final known = {for (final field in type.fields) field.id.value};
    for (final key in values.keys) {
      if (!known.contains(key)) {
        throw ConfigurationRecordFormatException(
          type.collection,
          id,
          'Cannot edit undeclared field "$key".',
        );
      }
    }
    return type.validate(id, values);
  }

  void _checkCatalog(ConfigurationRecordSnapshot snapshot) {
    if (!identical(snapshot._catalog, catalog)) {
      throw ArgumentError('The snapshot belongs to another record catalog.');
    }
  }
}

String _alias(String name) =>
    name.toLowerCase().replaceFirst(RegExp(r'[ .]+$'), '');

/// Immutable typed known values plus the exact whole-file persistence baseline.
final class ConfigurationRecordSnapshot {
  ConfigurationRecordSnapshot._(
    this._catalog,
    this.id,
    this.type,
    Map<String, Object> values,
    this._baseline,
  ) : values = Map.unmodifiable(values);

  final RecordCatalog _catalog;
  final ConfigurationSnapshot _baseline;
  final ConfigurationRecordId id;
  final RecordTypeDefinition type;
  final Map<String, Object> values;
  RecordCollectionId get collection => type.collection;
  TomlDocument get document => _baseline.document;
}

final class ConfigurationRecordEnumeration {
  ConfigurationRecordEnumeration._(
    Iterable<ConfigurationRecordSnapshot> records,
    Iterable<ConfigurationRecordDiagnostic> diagnostics,
  ) : records = List.unmodifiable(records),
      diagnostics = List.unmodifiable(diagnostics);

  final List<ConfigurationRecordSnapshot> records;
  final List<ConfigurationRecordDiagnostic> diagnostics;
}

/// The original error is retained so parse, UTF-8, value and I/O failures differ.
final class ConfigurationRecordDiagnostic {
  const ConfigurationRecordDiagnostic(
    this.collection,
    this.fileName,
    this.recordId,
    this.error,
  );

  final RecordCollectionId collection;
  final String fileName;
  final ConfigurationRecordId? recordId;
  final Object error;
}

final class ConfigurationRecordFormatException implements Exception {
  const ConfigurationRecordFormatException(
    this.collection,
    this.recordId,
    this.message,
  );

  final RecordCollectionId collection;
  final ConfigurationRecordId recordId;
  final String message;

  @override
  String toString() => 'Invalid record $collection/$recordId: $message';
}

final class ConfigurationRecordNotFound implements Exception {
  const ConfigurationRecordNotFound(this.collection, this.recordId);

  final RecordCollectionId collection;
  final ConfigurationRecordId recordId;

  @override
  String toString() => 'Record not found: $collection/$recordId';
}
