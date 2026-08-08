final class CapabilityProviderData {
  const CapabilityProviderData({required this.id, required this.displayName});

  final String id;
  final String displayName;
}

final class ResolvedInspectorData {
  const ResolvedInspectorData({required this.token, required this.providerId});

  final String token;
  final String providerId;
}

final class InspectionData {
  const InspectionData({
    required this.providerLabel,
    required this.summary,
    required this.cancelled,
  });

  final String providerLabel;
  final String summary;
  final bool cancelled;
}

Future<List<CapabilityProviderData>> resourceInspectorProviders() {
  throw UnsupportedError('Available only inside the ADELE eval runtime.');
}

Future<ResolvedInspectorData> resolveResourceInspector([String? providerId]) {
  throw UnsupportedError('Available only inside the ADELE eval runtime.');
}

Future<InspectionData> inspectResource(String token, String resourceUri) {
  throw UnsupportedError('Available only inside the ADELE eval runtime.');
}
