import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:adele_configuration_store/adele_configuration_store.dart';
import 'package:adele_credential_store/credential_reference.dart';
import 'package:adele_settings/adele_settings.dart';
import 'package:adele_toml_document/adele_toml_document.dart';

/// Headless, single-layer records over the host's existing configuration owner.
///
/// The supplied store carries explicit roots. Route these operations through the
/// same owning isolate as scalar settings, never an independent UI-isolate writer.
/// Enumeration retains a Future API; Linux scans and transactions run
/// synchronously under the configuration store's stable cross-process lock.
final class ConfigurationRecordStore {
  const ConfigurationRecordStore({required this.store, required this.catalog});

  /// Bounds retained documents in one successful collection result.
  static const maxEnumerationBytes = 16 * 1024 * 1024;

  final ConfigurationStore store;
  final RecordCatalog catalog;

  /// Returns valid records in semantic ID order and diagnostics in filename order.
  /// Directory-wide failures reject the operation, never an empty replacement.
  Future<ConfigurationRecordEnumeration> enumerate(
    RecordCollectionId collection, {
    bool captureStartupIdentity = false,
  }) async {
    catalog.collectionLabel(collection);
    final entries = await store.listCollection(collection.value);
    final paths = [
      if (captureStartupIdentity)
        for (final entry in entries)
          if (ConfigurationStore.isRecordFileName(entry.name) &&
              entry.type == FileSystemEntityType.file)
            _file(collection, entry.name).filePath,
    ];
    final before = captureStartupIdentity
        ? await _startupIdentities(paths)
        : const <String, String?>{};
    final firstFile = <ConfigurationRecordId, String>{};
    final records = <ConfigurationRecordId, ConfigurationRecordSnapshot>{};
    final diagnostics = <String, ConfigurationRecordDiagnostic>{};
    var sourceBytes = 0;
    for (final candidate in _headers(collection, entries)) {
      final (:fileName, :id, :error, :baseline) = candidate;
      if (id != null) {
        final first = firstFile.putIfAbsent(id, () => fileName);
        if (first != fileName) {
          final removed = records.remove(id);
          if (removed != null) {
            sourceBytes -= utf8.encode(removed.document.source).length;
          }
          final duplicate = _duplicate(collection, id);
          for (final name in [first, fileName]) {
            diagnostics[name] = ConfigurationRecordDiagnostic(
              collection,
              name,
              id,
              duplicate,
            );
          }
          continue;
        }
      }
      try {
        if (error != null) throw error;
        final record = _decode(collection, id!, fileName, baseline!);
        sourceBytes += utf8.encode(record.document.source).length;
        records[id] = record;
      } on Exception catch (error) {
        diagnostics[fileName] = ConfigurationRecordDiagnostic(
          collection,
          fileName,
          id,
          error,
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
    if (captureStartupIdentity) {
      final after = await _startupIdentities(paths);
      for (final record in records.values) {
        final path = _file(record.collection, record.fileName).filePath;
        record._startupIdentity = before == null || after == null
            ? null
            : (before[path], after[path]);
      }
    }
    final sorted = records.values.toList()
      ..sort((a, b) => a.id.value.compareTo(b.id.value));
    return ConfigurationRecordEnumeration._(sorted, [
      for (final entry in entries) ?diagnostics[entry.name],
    ]);
  }

  Future<ConfigurationRecordSnapshot> load(
    RecordCollectionId collection,
    ConfigurationRecordId id,
  ) async {
    catalog.collectionLabel(collection);
    final entries = await store.listCollection(collection.value);
    _RecordHeader? match;
    for (final candidate in _headers(collection, entries)) {
      if (candidate.id != id) continue;
      if (match != null) throw _duplicate(collection, id);
      match = candidate;
    }
    if (match == null) throw ConfigurationRecordNotFound(collection, id);
    if (match.error case final error?) throw error;
    return _decode(collection, id, match.fileName, match.baseline!);
  }

  /// Creates at the declaration's initial filename. [beforeWrite] may fence
  /// that exact location after validation; it is never called under the lock.
  Future<ConfigurationRecordSnapshot> create(
    RecordTypeId typeId,
    ConfigurationRecordId id,
    Map<String, Object?> values, {
    FutureOr<void> Function(String fileName)? beforeWrite,
  }) async {
    final type = catalog.definition(typeId);
    final validated = _validateDesired(type, id, values);
    final fileName = type.initialFileName(id, validated);
    final file = _file(type.collection, fileName);
    var document =
        TomlDocument.parse(
          'recordVersion = 2\nrecordId = ""\nrecordType = ""\n\n[values]\n',
        ).setScalar(['recordId'], id.value).setScalar([
          'recordType',
        ], type.id.value);
    for (final field in type.fields) {
      final value = validated[field.id.value];
      if (value != null) {
        document = _setField(document, field, value);
      }
    }
    final insert = file.prepareCreate(
      document,
      collectionAllowsCreate: (entries) =>
          _noOtherClaim(type.collection, id, fileName, entries),
    );
    if (beforeWrite != null) await beforeWrite(fileName);
    final saved = insert();
    return ConfigurationRecordSnapshot._(
      catalog,
      id,
      fileName,
      type,
      validated,
      saved,
    );
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
    try {
      for (final field in expected.type.fields) {
        final value = validated[field.id.value];
        document = value == null
            ? document.removeScalar(['values', field.id.value])
            : _setField(document, field, value);
      }
      document.requireTable(['values']);
    } on TomlException catch (error) {
      // Removing the last dotted key can discard an implicit parent. Do not
      // publish an invalid record or invent structural repair in this adapter.
      throw InvalidRecordValue(
        expected.collection,
        expected.id,
        null,
        'The edit must preserve the declared field structure and a regular '
        '[values] table: ${error.message}',
      );
    }
    final file = await _exclusiveFile(
      expected.collection,
      expected.id,
      expected.fileName,
    );
    final saved = file.save(expected._baseline, document);
    if (identical(saved, expected._baseline)) return expected;
    return ConfigurationRecordSnapshot._(
      catalog,
      expected.id,
      expected.fileName,
      expected.type,
      validated,
      saved,
      credentials: expected.credentials,
      hasCredentialEntries: expected.hasCredentialEntries,
    );
  }

  TomlDocument _setField(
    TomlDocument document,
    RecordFieldDefinition<Object> field,
    Object validated,
  ) {
    final path = ['values', field.id.value];
    if (field.type case StructuredRecordFieldType(:final properties)) {
      final components = validated as Map<String, Object>;
      var edited = document.ensureTable(path);
      for (final key in properties.keys) {
        edited = edited.setScalar([...path, key.value], components[key.value]!);
      }
      return edited;
    }
    return document.setScalar(path, validated);
  }

  /// Changes only one declared nonsecret association, conditional on the same
  /// whole-record baseline as ordinary values. Unknown entries are never adopted.
  Future<ConfigurationRecordSnapshot> setCredentialReference(
    ConfigurationRecordSnapshot expected,
    RecordCredentialSlotId slot,
    CredentialReference? reference,
  ) async {
    _checkCatalog(expected);
    if (!expected.type.credentialSlots.any(
      (definition) => definition.id == slot,
    )) {
      throw ConfigurationRecordFormatException(
        expected.collection,
        expected.id,
        'Cannot edit an undeclared credential slot.',
      );
    }
    if (expected.credentials[slot] == reference) {
      return validateCurrent(expected);
    }
    var document = expected.document;
    final path = ['credentials', slot.value];
    if (reference == null) {
      document = document.removeScalar(path);
    } else {
      document = document
          .ensureTable(['credentials'])
          .setScalar(path, reference.value);
    }
    final credentials = _readCredentials(expected.type, expected.id, document);
    final file = await _exclusiveFile(
      expected.collection,
      expected.id,
      expected.fileName,
    );
    final saved = file.save(expected._baseline, document);
    return ConfigurationRecordSnapshot._(
      catalog,
      expected.id,
      expected.fileName,
      expected.type,
      expected.values,
      saved,
      credentials: credentials.references,
      hasCredentialEntries: credentials.hasEntries,
    );
  }

  /// Asserts the exact observed byte/existence baseline without writing or
  /// loading a replacement snapshot. Success returns [expected] itself.
  Future<ConfigurationRecordSnapshot> validateCurrent(
    ConfigurationRecordSnapshot expected,
  ) async {
    _checkCatalog(expected);
    final file = await _exclusiveFile(
      expected.collection,
      expected.id,
      expected.fileName,
    );
    file.save(expected._baseline, expected.document);
    return expected;
  }

  /// Startup authority additionally pins the file incarnation. Ordinary UI
  /// handles deliberately retain their existing byte-equivalence semantics.
  Future<void> validateStartupCurrent(
    ConfigurationRecordSnapshot expected,
  ) async {
    _checkCatalog(expected);
    final identity = expected._startupIdentity;
    if (identity == null) {
      throw const ConfigurationStartupIdentityUnavailable();
    }
    final path = _file(expected.collection, expected.fileName).filePath;
    if (identity.$1 == null || identity.$1 != identity.$2) {
      throw ConfigurationConflictException(path);
    }
    final before = await _startupIdentities([path]);
    if (before == null) throw const ConfigurationStartupIdentityUnavailable();
    if (before[path] != identity.$1) {
      throw ConfigurationConflictException(path);
    }
    await validateCurrent(expected);
    final after = await _startupIdentities([path]);
    if (after == null) throw const ConfigurationStartupIdentityUnavailable();
    if (after[path] != identity.$1) {
      throw ConfigurationConflictException(path);
    }
  }

  /// Removes only this record in this layer, conditional on its observed bytes.
  Future<void> delete(ConfigurationRecordSnapshot expected) async {
    _checkCatalog(expected);
    expected.requireNoCredentialEntries();
    final file = await _exclusiveFile(
      expected.collection,
      expected.id,
      expected.fileName,
    );
    file.delete(expected._baseline);
  }

  ConfigurationStore _file(RecordCollectionId collection, String fileName) =>
      store.recordFile(collectionId: collection.value, fileName: fileName);

  Future<ConfigurationStore> _exclusiveFile(
    RecordCollectionId collection,
    ConfigurationRecordId id,
    String fileName,
  ) async {
    final entries = await store.listCollection(collection.value);
    final file = _file(collection, fileName);
    if (!_noOtherClaim(collection, id, fileName, entries)) {
      throw ConfigurationConflictException(file.filePath);
    }
    return file;
  }

  /// Check other files for this ID, but leave the target's raw bytes (including
  /// malformed replacements or absence) to the conditional file transaction.
  /// Create supplies entries from inside the write lock; never re-open it here.
  bool _noOtherClaim(
    RecordCollectionId collection,
    ConfigurationRecordId id,
    String fileName,
    List<ConfigurationCollectionEntry> entries,
  ) {
    for (final entry in entries) {
      if (entry.name != fileName &&
          ConfigurationStore.recordFileNameAlias(entry.name) == fileName) {
        throw ConfigurationRecordFormatException(
          collection,
          id,
          'Noncanonical or ambiguous filename: ${entry.name}.',
        );
      }
    }
    return !_headers(
      collection,
      entries,
      skip: fileName,
    ).any((candidate) => candidate.id == id);
  }

  /// Stream one bounded file at a time. A valid embedded ID claims its place
  /// even when the type, values or credential associations aren't usable.
  Iterable<_RecordHeader> _headers(
    RecordCollectionId collection,
    List<ConfigurationCollectionEntry> entries, {
    String? skip,
  }) sync* {
    final names = <String, int>{};
    for (final entry in entries) {
      names.update(
        ConfigurationStore.recordFileNameAlias(entry.name),
        (count) => count + 1,
        ifAbsent: () => 1,
      );
    }
    for (final entry in entries) {
      final fileName = entry.name;
      if (fileName == skip) continue;
      ConfigurationRecordId? id;
      try {
        if (!ConfigurationStore.isRecordFileName(fileName)) {
          throw const FormatException(
            'Expected a portable record filename ending in .toml.',
          );
        }
        final file = _file(collection, fileName);
        if (entry.type == FileSystemEntityType.link) {
          throw ConfigurationSymlinkException(file.filePath);
        }
        if (entry.type != FileSystemEntityType.file) {
          throw FileSystemException(
            'Expected a regular record file.',
            file.filePath,
          );
        }
        final baseline = file.load();
        if (!baseline.exists) {
          throw FileSystemException(
            'Listed record file no longer exists.',
            file.filePath,
          );
        }
        final value = baseline.document.readScalar(['recordId']);
        if (value is! String) {
          throw const FormatException('recordId must be a string.');
        }
        try {
          id = ConfigurationRecordId(value);
        } on FormatException {
          throw const FormatException('Invalid embedded recordId.');
        }
        // Only the canonical, regular file is opened, never an alias. Its
        // header still reserves the ID; the alias bars using the snapshot.
        if (names[fileName] != 1) {
          throw ConfigurationRecordFormatException(
            collection,
            id,
            'Ambiguous record filename aliases.',
          );
        }
        yield (fileName: fileName, id: id, baseline: baseline, error: null);
      } on TomlNativeException {
        // A broken reader is not evidence of absent semantic identities.
        rethrow;
      } on Exception catch (error) {
        yield (fileName: fileName, id: id, baseline: null, error: error);
      }
    }
  }

  ConfigurationRecordFormatException _duplicate(
    RecordCollectionId collection,
    ConfigurationRecordId id,
  ) => ConfigurationRecordFormatException(
    collection,
    id,
    'Multiple files declare this recordId.',
  );

  ConfigurationRecordSnapshot _decode(
    RecordCollectionId collection,
    ConfigurationRecordId id,
    String fileName,
    ConfigurationSnapshot baseline,
  ) {
    final document = baseline.document;
    final RecordTypeDefinition type;
    try {
      if (document.readScalar(['recordVersion']) != 2) {
        throw ConfigurationRecordFormatException(
          collection,
          id,
          'recordVersion must be integer 2.',
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
      final path = ['values', field.id.value];
      try {
        if (field.type case StructuredRecordFieldType(:final properties)) {
          document.requireTable(path);
          final components = <String, Object>{};
          for (final key in properties.keys) {
            try {
              components[key.value] = document.readScalar([...path, key.value]);
            } on TomlException catch (error) {
              throw InvalidRecordValue(
                collection,
                id,
                field.id,
                'Property "$key": ${error.message}',
              );
            }
          }
          values[field.id.value] = components;
        } else {
          values[field.id.value] = document.readScalar(path);
        }
      } on TomlException catch (error) {
        // The values table exists. Only a missing field may be absent; a
        // present structured field must have every declared property.
        if (error.kind == TomlFailureKind.path) continue;
        throw InvalidRecordValue(collection, id, field.id, error.message);
      }
    }
    final credentials = _readCredentials(type, id, document);
    return ConfigurationRecordSnapshot._(
      catalog,
      id,
      fileName,
      type,
      type.validate(id, values),
      baseline,
      credentials: credentials.references,
      hasCredentialEntries: credentials.hasEntries,
    );
  }

  ({
    Map<RecordCredentialSlotId, CredentialReference> references,
    bool hasEntries,
  })
  _readCredentials(
    RecordTypeDefinition type,
    ConfigurationRecordId id,
    TomlDocument document,
  ) {
    final List<String> keys;
    try {
      keys = document.tableKeys(['credentials']);
    } on TomlException catch (error) {
      if (error.kind == TomlFailureKind.path) {
        return (references: const {}, hasEntries: false);
      }
      throw ConfigurationRecordFormatException(
        type.collection,
        id,
        'credentials must be a regular table.',
      );
    }
    final references = <RecordCredentialSlotId, CredentialReference>{};
    for (final slot in type.credentialSlots) {
      if (!keys.contains(slot.id.value)) continue;
      try {
        final value = document.readScalar(['credentials', slot.id.value]);
        if (value is! String) throw const FormatException();
        references[slot.id] = CredentialReference.parse(value);
      } on TomlException {
        throw ConfigurationRecordFormatException(
          type.collection,
          id,
          'Credential slot "${slot.id}" must contain a valid credential reference.',
        );
      } on FormatException {
        throw ConfigurationRecordFormatException(
          type.collection,
          id,
          'Credential slot "${slot.id}" must contain a valid credential reference.',
        );
      }
    }
    return (references: references, hasEntries: keys.isNotEmpty);
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

typedef _RecordHeader = ({
  String fileName,
  ConfigurationRecordId? id,
  ConfigurationSnapshot? baseline,
  Exception? error,
});

/// GNU stat preserves nanosecond change times and device/inode identity that
/// Dart FileStat does not expose. Batch the collection, never spawn a worker or
/// process per configured record. Unsupported platforms/tools fail closed for
/// credential authority without preventing nonsecret startup projection.
Future<Map<String, String?>?> _startupIdentities(List<String> paths) async {
  if (!Platform.isLinux) return null;
  bool missing(String path) {
    if (FileSystemEntity.typeSync(path, followLinks: false) !=
        FileSystemEntityType.notFound) {
      return false;
    }
    // typeSync collapses all lookup errors to notFound. Only native absence,
    // not permission/tool failure or a racing replacement, proves staleness.
    try {
      File(path).resolveSymbolicLinksSync();
    } on FileSystemException catch (error) {
      if (error.osError?.errorCode == 2 || error.osError?.errorCode == 20) {
        return true;
      }
    }
    throw const ConfigurationStartupIdentityUnavailable();
  }

  try {
    final identities = <String, String?>{};
    final existing = <String>[];
    for (final path in paths) {
      if (missing(path)) {
        identities[path] = null;
      } else {
        existing.add(path);
      }
    }
    if (existing.isEmpty) return identities;
    final result = await Process.run(
      'stat',
      [r'--printf=%n\0%d:%i:%z:%y:%s:%f\0', '--', ...existing],
      environment: {'LC_ALL': 'C', 'TZ': 'UTC'},
    );
    final fields = (result.stdout as String).split('\x00');
    if (fields.last != '' || fields.length.isEven) return null;
    final requested = existing.toSet();
    for (var i = 0; i < fields.length - 1; i += 2) {
      if (!requested.remove(fields[i]) ||
          !RegExp(
            r'^\d+:\d+:.*\.\d{9} \+0000:.*\.\d{9} \+0000:\d+:[0-9a-f]+$',
          ).hasMatch(fields[i + 1])) {
        return null;
      }
      identities[fields[i]] = fields[i + 1];
    }
    if (result.exitCode != 0 && requested.isEmpty) return null;
    // Missing tool/output is not proof of a changed file. Only confirmed
    // absence has a null member; unavailable observation has a null result.
    for (final path in requested) {
      if (!missing(path)) {
        return null;
      }
      identities[path] = null;
    }
    return identities;
  } on Object {
    return null;
  }
}

final class ConfigurationStartupIdentityUnavailable implements Exception {
  const ConfigurationStartupIdentityUnavailable();

  @override
  String toString() => 'Strict startup record identity is unavailable.';
}

/// Immutable typed known values plus the exact whole-file persistence baseline.
final class ConfigurationRecordSnapshot {
  ConfigurationRecordSnapshot._(
    this._catalog,
    this.id,
    this.fileName,
    this.type,
    Map<String, Object> values,
    this._baseline, {
    Map<RecordCredentialSlotId, CredentialReference> credentials = const {},
    this.hasCredentialEntries = false,
  }) : values = Map.unmodifiable(values),
       credentials = Map.unmodifiable(credentials);

  final RecordCatalog _catalog;
  final ConfigurationSnapshot _baseline;
  (String?, String?)? _startupIdentity;
  final ConfigurationRecordId id;

  /// The observed basename, not the source of the record's semantic identity.
  final String fileName;
  final RecordTypeDefinition type;
  final Map<String, Object> values;
  final Map<RecordCredentialSlotId, CredentialReference> credentials;

  /// Includes unknown credential keys and nested tables, even when no declared
  /// slot is associated. Such content must not be silently deleted.
  final bool hasCredentialEntries;
  RecordCollectionId get collection => type.collection;
  TomlDocument get document => _baseline.document;

  /// Checks the deletion guard on this snapshot without touching storage.
  void requireNoCredentialEntries() {
    if (hasCredentialEntries) {
      throw ConfigurationRecordCredentialsPresent(collection, id);
    }
  }
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

/// Whole-record deletion cannot implicitly remove known or unknown associations.
final class ConfigurationRecordCredentialsPresent implements Exception {
  const ConfigurationRecordCredentialsPresent(this.collection, this.recordId);

  final RecordCollectionId collection;
  final ConfigurationRecordId recordId;

  @override
  String toString() =>
      'Record $collection/$recordId has credential entries; deletion is blocked.';
}
