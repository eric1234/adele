/// Immutable scalar settings captured for one backend generation.
///
/// The caller resolves declaration ownership, defaults, and semantic constraints
/// before startup. This value only validates the transport shape; it performs no
/// lookup, persistence, coercion, or live reconfiguration.
final class AdeleBackendSettings {
  AdeleBackendSettings(Map<String, Object> settings)
    : this._(adeleCopyBackendSettings(settings));

  AdeleBackendSettings._(this.values);

  /// Reads an explicit `settings` map from the isolate bootstrap message.
  ///
  /// Missing or malformed settings throw [FormatException], including when the
  /// consumer would otherwise need no values. An explicit empty map is valid.
  factory AdeleBackendSettings.fromBootstrap(Object? bootstrap) {
    if (bootstrap is! Map || !bootstrap.containsKey('settings')) {
      throw const FormatException(
        'Backend bootstrap must contain an explicit settings map.',
      );
    }
    return AdeleBackendSettings._(
      adeleCopyBackendSettings(bootstrap['settings']),
    );
  }

  /// Copied, unmodifiable values. Only bool, int, and String are supported.
  final Map<String, Object> values;

  /// Returns a captured value, throwing [StateError] if absent or not a [T].
  T read<T>(String id) {
    if (!values.containsKey(id)) {
      throw StateError('Missing backend setting "$id".');
    }
    final value = values[id];
    if (value is! T) {
      throw StateError('Backend setting "$id" must have type $T.');
    }
    return value;
  }
}

/// Validates and copies a settings transport map into unmodifiable scalar data.
///
/// Runtime, shared host, and backend readers use the same structural validation.
/// Keys must be strings and values must be bool, int, or String; null, collections,
/// doubles, and other objects throw [FormatException]. Setting identities and
/// declaration-specific constraints belong to the caller, not this transport.
Map<String, Object> adeleCopyBackendSettings(Object? settings) {
  if (settings is! Map) {
    throw const FormatException('Backend settings must be a map.');
  }
  final values = <String, Object>{};
  for (final entry in settings.entries) {
    final key = entry.key;
    final value = entry.value;
    if (key is! String) {
      throw const FormatException('Backend settings keys must be strings.');
    }
    if (value is! bool && value is! int && value is! String) {
      throw FormatException(
        'Backend setting "$key" must be a bool, int, or String.',
      );
    }
    values[key] = value as Object;
  }
  return Map<String, Object>.unmodifiable(values);
}
