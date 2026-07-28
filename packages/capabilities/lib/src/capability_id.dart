/// A stable identifier for an action, service, or event capability.
final class CapabilityId {
  const CapabilityId(this.value);

  final String value;

  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is CapabilityId && other.value == value;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => value;
}
