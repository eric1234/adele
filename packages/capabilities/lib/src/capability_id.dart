import 'package:adele_plugin_api/adele_plugin_api.dart';

import 'capability_error.dart';

/// A stable identifier for an action, service, or event capability.
final class CapabilityId {
  factory CapabilityId(String value) {
    try {
      validateAdelePublicId(value, label: 'capability ID');
    } on FormatException catch (error) {
      throw InvalidCapabilityIdentity(error.message);
    }
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
