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
  static const maxProperties = 16;
  static const maxLocalIdLength = 64;
  static const maxTypeIdLength = 256;
  static const maxStringLength = 64 * 1024;
  static const maxJsonBytes = 1024 * 1024;

  /// Deeply copied, unmodifiable entries with exactly collection/type/id/values.
  /// Each field is a scalar or one flat, nonempty map of scalar properties.
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
  // Count each bounded member, including JSON escaping, before retaining it.
  // Never encode a whole caller-supplied map (it could even be cyclic).
  void charge(int bytes) {
    jsonBytes += bytes;
    if (jsonBytes > AdeleBackendRecords.maxJsonBytes) {
      throw const FormatException(
        'Backend records exceed the JSON byte limit.',
      );
    }
  }

  Object copyScalar(Object? value) {
    if (value is! bool && value is! int && value is! String) {
      throw const FormatException('Backend record contains an invalid scalar.');
    }
    if (value is String && value.length > AdeleBackendRecords.maxStringLength) {
      throw const FormatException('Backend record string exceeds the limit.');
    }
    charge(utf8.encode(jsonEncode(value)).length);
    return value!;
  }

  String memberKey(Object? key, {required bool first}) {
    if (!_localId(key)) {
      throw const FormatException(
        'Backend record has an invalid field or property ID.',
      );
    }
    // Local IDs are ASCII without escapes. Include quotes, colon and comma.
    charge((key as String).length + (first ? 3 : 4));
    return key;
  }

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
    charge(utf8.encode(jsonEncode(entry)).length + (copied.isEmpty ? 0 : 1));
    for (final field in rawValues.entries) {
      final key = memberKey(field.key, first: values.isEmpty);
      final value = field.value;
      if (value is Map) {
        if (value.isEmpty || value.length > AdeleBackendRecords.maxProperties) {
          throw const FormatException(
            'Backend record structure has an invalid size.',
          );
        }
        charge(2); // Braces.
        final properties = <String, Object>{};
        for (final property in value.entries) {
          final id = memberKey(property.key, first: properties.isEmpty);
          properties[id] = copyScalar(property.value);
        }
        values[key] = Map<String, Object>.unmodifiable(properties);
      } else {
        values[key] = copyScalar(value);
      }
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
