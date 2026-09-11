export 'package:adele_orchestration/adele_orchestration.dart'
    show RunId, SessionId, ToolInvocationId, RunInterruptionId;

final class ModelInvocationId {
  ModelInvocationId(String value)
    : value = _requireId(value, 'Model invocation ID');

  final String value;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ModelInvocationId && other.value == value;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => value;
}

String _requireId(String value, String label) {
  if (value.isEmpty || value.trim() != value) {
    throw FormatException('$label must be non-empty and have no outer space.');
  }
  return value;
}
