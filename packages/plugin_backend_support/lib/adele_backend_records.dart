import 'dart:convert';

/// Immutable nonsecret records captured for one backend generation.
///
/// The caller validates declaration ownership, allowed fields and required values
/// before startup. This value validates only the bounded transport shape. It
/// supplies no persistence, credential access, authority or live reconfiguration.
final class AdeleBackendRecords {
  AdeleBackendRecords(List<Map<String, Object?>> records)
    : this._(adeleCopyBackendRecords(records));

  AdeleBackendRecords._(this.records);

  /// Requires an explicit `records` list, including when it is empty.
  factory AdeleBackendRecords.fromBootstrap(Object? bootstrap) {
    if (bootstrap is! Map || !bootstrap.containsKey('records')) {
      throw const FormatException(
        'Backend bootstrap must contain an explicit records list.',
      );
    }
    return AdeleBackendRecords._(adeleCopyBackendRecords(bootstrap['records']));
  }

  static const maxRecords = 256;
  static const maxFields = 128;
  static const maxLocalIdLength = 64;
  static const maxTypeIdLength = 256;
  static const maxStringLength = 64 * 1024;
  static const maxJsonBytes = 1024 * 1024;

  /// Deeply copied, unmodifiable entries with exactly collection/type/id/values.
  /// Values are string-keyed maps containing only bool, int and String scalars.
  final List<Map<String, Object>> records;
}

/// Validates and defensively copies records at each startup boundary.
///
/// Collection/record/field identities follow the R1 local-ID grammar; collection
/// and record IDs also reject portable device names. Type IDs follow ADELE's
/// public-ID grammar. No identity is normalized and (collection, id) is unique
/// across all types. Failures are bounded and never include supplied data.
List<Map<String, Object>> adeleCopyBackendRecords(Object? records) {
  if (records is! List) {
    throw const FormatException('Backend records must be a list.');
  }
  if (records.length > AdeleBackendRecords.maxRecords) {
    throw const FormatException('Backend records exceed the count limit.');
  }
  final copied = <Map<String, Object>>[];
  final identities = <(String, String)>{};
  // Include outer list brackets; budget each entry before retaining it.
  var jsonBytes = 2;
  for (final record in records) {
    if (record is! Map ||
        record.length != 4 ||
        !record.containsKey('collection') ||
        !record.containsKey('type') ||
        !record.containsKey('id') ||
        !record.containsKey('values')) {
      throw const FormatException('Backend record has invalid fields.');
    }
    final collection = record['collection'];
    final type = record['type'];
    final id = record['id'];
    if (!_localId(collection, portable: true) ||
        !_localId(id, portable: true) ||
        type is! String ||
        type.length > AdeleBackendRecords.maxTypeIdLength ||
        !_fullMatch(_publicId, type)) {
      throw const FormatException('Backend record has an invalid identity.');
    }
    if (!identities.add((collection as String, id as String))) {
      throw const FormatException(
        'Backend records contain a duplicate identity.',
      );
    }
    final rawValues = record['values'];
    if (rawValues is! Map) {
      throw const FormatException('Backend record values must be a map.');
    }
    if (rawValues.length > AdeleBackendRecords.maxFields) {
      throw const FormatException('Backend record exceeds the field limit.');
    }
    final values = <String, Object>{};
    final entry = <String, Object>{
      'collection': collection,
      'type': type,
      'id': id,
      'values': values,
    };
    jsonBytes += utf8.encode(jsonEncode(entry)).length;
    if (copied.isNotEmpty) jsonBytes++;
    for (final field in rawValues.entries) {
      final key = field.key;
      final value = field.value;
      if (!_localId(key)) {
        throw const FormatException('Backend record has an invalid field ID.');
      }
      if (value is! bool && value is! int && value is! String) {
        throw const FormatException('Backend record values must be scalars.');
      }
      if (value is String &&
          value.length > AdeleBackendRecords.maxStringLength) {
        throw const FormatException('Backend record string exceeds the limit.');
      }
      // Count JSON escaping and UTF-8 bytes without encoding an unbounded aggregate.
      jsonBytes += utf8.encode(jsonEncode({key: value})).length - 2;
      if (values.isNotEmpty) jsonBytes++;
      if (jsonBytes > AdeleBackendRecords.maxJsonBytes) {
        throw const FormatException(
          'Backend records exceed the JSON byte limit.',
        );
      }
      values[key as String] = value as Object;
    }
    if (jsonBytes > AdeleBackendRecords.maxJsonBytes) {
      throw const FormatException(
        'Backend records exceed the JSON byte limit.',
      );
    }
    entry['values'] = Map<String, Object>.unmodifiable(values);
    copied.add(Map<String, Object>.unmodifiable(entry));
  }
  return List<Map<String, Object>>.unmodifiable(copied);
}

final _localIdentity = RegExp(r'^[a-z][a-z0-9]*(?:-[a-z0-9]+)*$');
final _portableDevice = RegExp(r'^(?:con|prn|aux|nul|com[1-9]|lpt[1-9])$');
final _publicId = RegExp(
  r'^[a-z][a-z0-9]*(?:-[a-z0-9]+)*(\.[a-z][a-z0-9]*(?:-[a-z0-9]+)*)+$',
);

bool _fullMatch(RegExp grammar, String value) =>
    grammar.firstMatch(value)?.end == value.length;

bool _localId(Object? value, {bool portable = false}) =>
    value is String &&
    value.length <= AdeleBackendRecords.maxLocalIdLength &&
    _fullMatch(_localIdentity, value) &&
    (!portable || !_portableDevice.hasMatch(value));
