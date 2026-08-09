import 'public_id.dart';

/// A stable, globally namespaced plugin identifier.
final class PluginId {
  factory PluginId(String value) {
    validateAdelePublicId(value, label: 'plugin ID');
    return PluginId._(value);
  }

  const PluginId._(this.value);

  final String value;

  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is PluginId && other.value == value;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => value;
}
