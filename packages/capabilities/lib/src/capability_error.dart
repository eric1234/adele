sealed class CapabilityException implements Exception {
  const CapabilityException(this.message);

  final String message;

  @override
  String toString() => '$runtimeType: $message';
}

final class InvalidCapabilityIdentity extends CapabilityException {
  const InvalidCapabilityIdentity(super.message);
}

final class InvalidCapabilityVersion extends CapabilityException {
  const InvalidCapabilityVersion(super.message);
}

final class InvalidProviderRegistration extends CapabilityException {
  const InvalidProviderRegistration(super.message);
}

final class DuplicateProviderRegistration extends CapabilityException {
  const DuplicateProviderRegistration(super.message);
}

final class CapabilityUnavailable extends CapabilityException {
  const CapabilityUnavailable(this.capability)
    : super('No active provider for $capability.');

  final Object capability;
}

final class ProviderUnavailable extends CapabilityException {
  ProviderUnavailable({
    required this.capability,
    required this.providerId,
    required Iterable<Object> availableProviderIds,
    this.stale = false,
  }) : availableProviderIds = List<Object>.unmodifiable(availableProviderIds),
       super(
         '${stale ? 'Stale' : 'Unavailable'} provider $providerId for '
         '$capability; available: ${availableProviderIds.join(', ')}.',
       );

  final Object capability;
  final Object providerId;
  final List<Object> availableProviderIds;
  final bool stale;
}

final class ProviderEndpointUnavailable extends CapabilityException {
  const ProviderEndpointUnavailable(this.providerId)
    : super('Provider endpoint is unavailable: $providerId.');

  final Object providerId;
}

final class CapabilityContractMismatch extends CapabilityException {
  const CapabilityContractMismatch({
    required this.providerId,
    required this.expectedServiceId,
    required this.actualServiceId,
  }) : super(
         'Provider $providerId uses service $actualServiceId; expected '
         '$expectedServiceId.',
       );

  final Object providerId;
  final String expectedServiceId;
  final String actualServiceId;
}
