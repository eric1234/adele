/// Public canonical Chat snapshots and typed backend service.
library;

import 'package:adele_contract/adele_contract.dart';

export 'src/identities.dart';

part 'chat_strategy_contract.g.dart';

/// An immutable canonical occurrence, not a model/tool activity item.
/// [id] is the wire form of ChatEntryId, scoped to its Session.
@AdeleValue('chat.entry')
final class ChatEntry {
  const ChatEntry({
    required this.id,
    required this.role,
    required this.content,
  });

  final String id;
  final String role;
  final String content;
}

@AdeleValue('chat.sessionSnapshot')
final class ChatSessionSnapshot {
  ChatSessionSnapshot({
    required List<ChatEntry> entries,
    required this.instructions,
    required this.maxModelInvocations,
  }) : entries = List<ChatEntry>.unmodifiable(entries);

  final List<ChatEntry> entries;
  final String instructions;
  final int maxModelInvocations;
}

@AdeleService('chat.session')
abstract interface class ChatSessionService {
  @AdeleMethod('snapshot')
  Future<ChatSessionSnapshot> snapshot(String sessionId);

  /// Returns the accepted occurrence. Blank content is rejected, not normalized.
  @AdeleMethod('appendUserMessage')
  Future<ChatEntry> appendUserMessage(String sessionId, String content);

  /// Replaces both settings atomically; the invocation limit must be positive.
  @AdeleMethod('configureSession')
  Future<void> configureSession(
    String sessionId,
    String instructions,
    int maxModelInvocations,
  );
}

/// Declared codes: session_busy, invalid_session, invalid_content,
/// invalid_configuration. A busy Session remains readable.
@AdeleFailure('chat.sessionFailure')
final class ChatSessionFailure implements Exception {
  const ChatSessionFailure({
    required this.code,
    required this.message,
    required this.details,
  });

  final String code;
  final String message;
  final Map<String, Object?> details;

  @override
  String toString() => 'ChatSessionFailure($code): $message';
}
