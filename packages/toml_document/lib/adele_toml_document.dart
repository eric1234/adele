import 'src/native.dart';

/// A validated TOML snapshot. Operations do not read or write files.
final class TomlDocument {
  const TomlDocument._(this.source);

  /// Validates [source] with Rust toml_edit, retaining the original text.
  factory TomlDocument.parse(String source) {
    invokeToml({'operation': 'parse', 'document': source});
    return TomlDocument._(source);
  }

  final String source;

  /// Reads a string, signed 64-bit integer, or boolean at a literal key path.
  ///
  /// Segments are keys, not dotted TOML expressions. Parents must be existing
  /// regular tables (including dotted-key tables), not inline tables or arrays.
  /// Missing keys and unsupported value types fail rather than returning null.
  Object readScalar(List<String> path) => _invoke('read', path)['value']!;

  /// Requires an existing regular table, including implicit dotted-key tables.
  /// Missing keys fail with [TomlFailureKind.path]; scalars, inline tables and
  /// arrays at any segment fail with [TomlFailureKind.type]. No text is changed.
  void requireTable(List<String> path) => _invoke('requireTable', path);

  /// Returns immutable direct keys, including nested tables and unsupported
  /// values. Requires a regular table with the same errors as [requireTable].
  List<String> tableKeys(List<String> path) => List<String>.unmodifiable(
    (_invoke('tableKeys', path)['keys']! as List).cast<String>(),
  );

  /// Creates an explicit regular table at a missing leaf under existing regular
  /// parents. An existing regular table is an exact no-op; other values fail.
  TomlDocument ensureTable(List<String> path) =>
      _edited(_invoke('ensureTable', path));

  /// Inserts or updates a string, integer, or boolean under an existing table.
  /// An existing value must have the same scalar type. No tables are created.
  /// An equal value is a text-preserving no-op.
  TomlDocument setScalar(List<String> path, Object value) {
    if (value is! String && value is! int && value is! bool) {
      throw const TomlException(
        TomlFailureKind.type,
        'Only String, int, and bool values are supported.',
      );
    }
    return _edited(_invoke('set', path, value));
  }

  /// Removes a supported scalar. A missing leaf is a text-preserving no-op;
  /// a missing parent or an unsupported value is an error. Explicit tables are
  /// retained, but an implicit dotted-key parent can disappear with its last key.
  TomlDocument removeScalar(List<String> path) =>
      _edited(_invoke('remove', path));

  Map<String, Object?> _invoke(
    String operation,
    List<String> path, [
    Object? value,
  ]) => invokeToml({
    'operation': operation,
    'document': source,
    'path': path,
    'value': ?value,
  });

  TomlDocument _edited(Map<String, Object?> result) {
    final text = result['document']! as String;
    return text == source ? this : TomlDocument._(text);
  }
}

enum TomlFailureKind { parse, path, type, edit }

/// A document failure, distinct from native library preparation/loading failure.
final class TomlException implements Exception {
  const TomlException(this.kind, this.message);

  final TomlFailureKind kind;
  final String message;

  @override
  String toString() => 'TomlException(${kind.name}): $message';
}

/// No substitute parser is used when the native asset is unavailable.
final class TomlNativeException implements Exception {
  const TomlNativeException(this.message);

  final String message;

  @override
  String toString() => 'TomlNativeException: $message';
}
