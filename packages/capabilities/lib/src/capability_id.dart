import 'capability_error.dart';

/// A stable identifier for an action, service, or event capability.
final class CapabilityId {
  factory CapabilityId(String value) {
    validatePublicIdentifier(value, label: 'capability ID');
    return CapabilityId._(value);
  }

  const CapabilityId._(this.value);

  final String value;

  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is CapabilityId && other.value == value;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => value;
}

void validatePublicIdentifier(String value, {required String label}) {
  if (!RegExp(r'^[a-z][a-z0-9_]*(\.[a-z][a-z0-9_]*)+$').hasMatch(value)) {
    throw InvalidCapabilityIdentity(
      '$label must be a lowercase reverse-domain ASCII identifier: $value',
    );
  }
}
