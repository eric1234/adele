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
    required this.runId,
  });

  final String id;
  final String role;
  final String content;

  /// The Run associated with this user occurrence, or null before scheduling.
  /// Assistant entries never carry a Run association.
  final String? runId;
}

@AdeleValue('chat.sessionSnapshot')
final class ChatSessionSnapshot {
  ChatSessionSnapshot({
    required List<ChatEntry> entries,
    required this.instructions,
    required this.maxModelInvocations,
    required this.draftRequest,
  }) : entries = List<ChatEntry>.unmodifiable(entries);

  final List<ChatEntry> entries;
  final String instructions;
  final int maxModelInvocations;
  final String draftRequest;
}

@AdeleService('chat.session')
abstract interface class ChatSessionService {
  @AdeleMethod('snapshot')
  Future<ChatSessionSnapshot> snapshot(String sessionId);

  /// Returns the accepted occurrence without changing the Draft Request.
  /// Blank content is rejected, not normalized.
  @AdeleMethod('appendUserMessage')
  Future<ChatEntry> appendUserMessage(String sessionId, String content);

  /// Replaces the current plain-text draft exactly, including empty/blank text.
  @AdeleMethod('setDraftRequest')
  Future<void> setDraftRequest(String sessionId, String content);

  /// Atomically accepts the exact nonblank draft as a user entry and clears it.
  @AdeleMethod('submitDraftRequest')
  Future<ChatEntry> submitDraftRequest(String sessionId);

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
