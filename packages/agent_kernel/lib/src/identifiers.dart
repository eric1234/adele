export 'package:adele_product/adele_product.dart' show SessionId;

final class RunId {
  RunId(String value) : value = _requireId(value, 'Run ID');

  final String value;

  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is RunId && other.value == value;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => value;
}

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

final class ToolInvocationId {
  ToolInvocationId(String value)
    : value = _requireId(value, 'Tool invocation ID');

  final String value;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ToolInvocationId && other.value == value;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => value;
}

final class RunInterruptionId {
  RunInterruptionId(String value)
    : value = _requireId(value, 'Run interruption ID');

  final String value;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is RunInterruptionId && other.value == value;

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
