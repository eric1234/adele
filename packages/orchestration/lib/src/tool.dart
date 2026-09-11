final class ProviderToolProposal {
  ProviderToolProposal({
    required String providerCallId,
    required String alias,
    required Map<String, Object?> arguments,
  }) : providerCallId = _requireNonEmpty(providerCallId, 'Provider call ID'),
       alias = _requireNonEmpty(alias, 'Proposed model tool alias'),
       arguments = _freezeMap(arguments);

  final String providerCallId;
  final String alias;
  final Map<String, Object?> arguments;
}

enum ToolProposalFailureKind {
  unknownAlias,
  invalidArguments,
  staleBinding,
  bindingUnavailable,
}

final class ToolProposalFailure {
  ToolProposalFailure({
    required this.kind,
    required String providerCallId,
    required String alias,
    required String message,
    this.cause,
  }) : providerCallId = _requireNonEmpty(providerCallId, 'Provider call ID'),
       alias = _requireNonEmpty(alias, 'Proposed model tool alias'),
       message = _requireNonEmpty(message, 'Tool proposal failure message');

  final ToolProposalFailureKind kind;
  final String providerCallId;
  final String alias;
  final String message;
  final Object? cause;
}

String _requireNonEmpty(String value, String label) {
  if (value.trim().isEmpty) throw FormatException('$label must not be empty.');
  return value;
}

Map<String, Object?> _freezeMap(Map<String, Object?> source) =>
    Map<String, Object?>.unmodifiable(
      source.map(
        (String key, Object? value) =>
            MapEntry<String, Object?>(key, _freezeValue(value)),
      ),
    );

Object? _freezeValue(Object? value) {
  if (value == null || value is bool || value is String || value is int) {
    return value;
  }
  if (value is double) {
    if (!value.isFinite) {
      throw const FormatException('Structured values require finite doubles.');
    }
    return value;
  }
  if (value is List<Object?>) {
    return List<Object?>.unmodifiable(value.map(_freezeValue));
  }
  if (value is Map<String, Object?>) return _freezeMap(value);
  throw FormatException('Unsupported structured value: ${value.runtimeType}.');
}
