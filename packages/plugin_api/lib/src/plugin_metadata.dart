import 'plugin_id.dart';

/// Plugin identity and descriptive metadata, independent of activation.
///
/// [version] remains an opaque string. Semantic version parsing,
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
