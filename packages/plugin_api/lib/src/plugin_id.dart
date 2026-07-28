/// A stable, globally namespaced plugin identifier.
final class PluginId {
  const PluginId(this.value);

  final String value;

  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is PluginId && other.value == value;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => value;
}
