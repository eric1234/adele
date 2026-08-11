import 'identifiers.dart';

sealed class SessionEntry {
  const SessionEntry(this.content);

  final String content;
}

final class UserSessionMessage extends SessionEntry {
  UserSessionMessage(String content) : super(_requireContent(content));
}

final class AssistantSessionMessage extends SessionEntry {
  AssistantSessionMessage(String content) : super(_requireContent(content));
}

final class SessionSnapshot {
  SessionSnapshot({required this.id, required Iterable<SessionEntry> entries})
    : entries = List<SessionEntry>.unmodifiable(entries);

  final SessionId id;
  final List<SessionEntry> entries;
}

abstract interface class SessionHistoryPort {
  SessionId get id;

  SessionSnapshot snapshot();

  void append(SessionEntry entry);
}

String _requireContent(String content) {
  if (content.trim().isEmpty) {
    throw const FormatException('Session message content must not be empty.');
  }
  return content;
}
