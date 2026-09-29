/// Command Tools-owned decoded-text history, independent of execution authority.
library;

import 'package:adele_contract/adele_contract.dart';

part 'command_tools_contract.g.dart';

const int commandOutputChunkCodeUnits = 4096;
const int commandOutputPageChunks = 16;
const int commandOutputPageCodeUnits = 65536;

/// State and committed extent, not a transcript snapshot or a process handle.
@AdeleValue('command.captureState')
final class CommandCaptureState {
  const CommandCaptureState({
    required this.sessionId,
    required this.runId,
    required this.toolInvocationId,
    required this.state,
    required this.version,
    required this.highWater,
    required this.totalCodeUnits,
    required this.program,
    required this.argumentsJson,
    required this.workingDirectory,
    required this.environmentId,
    required this.timeoutSeconds,
    required this.termination,
    required this.exitCode,
    required this.failure,
  });

  final String sessionId;
  final String runId;
  final String toolInvocationId;

  /// absent, capturing, complete, failed, or interrupted (no active writer).
  final String state;
  final int version;

  /// Last committed chunk ordinal; zero means no output, not absent capture.
  final int highWater;
  final int totalCodeUnits;
  final String? program;
  final String? argumentsJson;
  final String? workingDirectory;
  final String? environmentId;
  final int? timeoutSeconds;
  final String? termination;
  final int? exitCode;
  final String? failure;
}

@AdeleValue('command.outputChunk')
final class CommandOutputChunk {
  const CommandOutputChunk({
    required this.cursor,
    required this.stream,
    required this.text,
  });

  /// Stable one-based ordinal in observed arrival order across the two pipes.
  final int cursor;
  final String stream;
  final String text;
}

@AdeleValue('command.outputPage')
final class CommandOutputPage {
  CommandOutputPage({
    required this.state,
    required List<CommandOutputChunk> chunks,
  }) : chunks = List<CommandOutputChunk>.unmodifiable(chunks);

  final CommandCaptureState state;

  /// Always ascending cursor order, including backward/tail reads.
  final List<CommandOutputChunk> chunks;
}

@AdeleService('command.output')
abstract interface class CommandOutputService {
  @AdeleMethod('getState')
  Future<CommandCaptureState> getState(
    String sessionId,
    String runId,
    String toolInvocationId,
  );

  /// Exclusive cursor; zero starts at the beginning. Empty means end of the
  /// currently committed extent, not necessarily process/capture completion.
  /// Bounds: 1..16 chunks, 4096..65536 UTF-16 code units. Chunks are not split.
  @AdeleMethod('readAfter')
  Future<CommandOutputPage> readAfter(
    String sessionId,
    String runId,
    String toolInvocationId,
    int afterCursor,
    int maxChunks,
    int maxCodeUnits,
  );

  /// Exclusive cursor, or null for the current tail. A tail is text, not a
  /// terminal-emulator checkpoint. Continue backward before the first cursor.
  @AdeleMethod('readBefore')
  Future<CommandOutputPage> readBefore(
    String sessionId,
    String runId,
    String toolInvocationId,
    int? beforeCursor,
    int maxChunks,
    int maxCodeUnits,
  );

  /// Subscribe first, then page history. The initial committed state and later
  /// coalesced state/extent changes allow race-free catch-up using readAfter.
  /// Pausing or cancelling observation never pauses/cancels command capture.
  @AdeleMethod('watch')
  Stream<CommandCaptureState> watch(
    String sessionId,
    String runId,
    String toolInvocationId,
  );
}

@AdeleFailure('command.outputFailure')
final class CommandOutputFailure implements Exception {
  const CommandOutputFailure({
    required this.code,
    required this.message,
    required this.details,
  });

  final String code;
  final String message;
  final Map<String, Object?> details;

  @override
  String toString() => 'CommandOutputFailure($code): $message';
}
