import 'plugin_id.dart';

/// Source plugin identity and descriptive metadata.
///
/// [version] remains an opaque string in Phase 0. Semantic version parsing,
/// comparison, and ranges are deferred.
final class PluginMetadata {
  const PluginMetadata({
    required this.id,
    required this.version,
    required this.displayName,
    this.description,
  });

  final PluginId id;
  final String version;
  final String displayName;
  final String? description;
}
