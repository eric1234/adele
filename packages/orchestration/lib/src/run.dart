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

enum RunState { created, running, waiting, completed, failed, cancelled }

sealed class RunInterruptionResolution {
  const RunInterruptionResolution(this.interruptionId);

  final RunInterruptionId interruptionId;
}

final class ToolApprovalResolution extends RunInterruptionResolution {
  const ToolApprovalResolution({
    required RunInterruptionId interruptionId,
    required this.toolInvocationId,
    required this.approved,
  }) : super(interruptionId);

  final ToolInvocationId toolInvocationId;
  final bool approved;
}

final class InvalidRunOperation implements Exception {
  const InvalidRunOperation(this.message);

  final String message;

  @override
  String toString() => 'InvalidRunOperation: $message';
}

String _requireId(String value, String label) {
  if (value.isEmpty || value.trim() != value) {
    throw FormatException('$label must be non-empty and have no outer space.');
  }
  return value;
}
