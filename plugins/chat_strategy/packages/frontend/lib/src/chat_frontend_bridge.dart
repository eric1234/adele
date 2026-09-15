import 'package:flutter/widgets.dart';

final class ChatPresentationEntry {
  const ChatPresentationEntry({
    required String this.role,
    required this.content,
  }) : kind = 'message',
       id = null;

  const ChatPresentationEntry.activity({
    required String this.id,
    required this.content,
  }) : kind = 'activity',
       role = null;

  final String kind;

  /// Opaque presentation-local activity identity; null for a message.
  final String? id;
  final String? role;
  final String content;
}

final class ChatPresentationSnapshot {
  ChatPresentationSnapshot({
    required List<ChatPresentationEntry> entries,
    required this.canSubmit,
  }) : entries = List<ChatPresentationEntry>.unmodifiable(entries);

  final List<ChatPresentationEntry> entries;
  final bool canSubmit;
}

ChatPresentationSnapshot readChatSnapshot() {
  throw UnsupportedError('Interpreted Chat bridge only.');
}

bool submitChatPrompt(String prompt) {
  throw UnsupportedError('Interpreted Chat bridge only.');
}

/// Requests navigation only; the host validates the emitted opaque identity.
bool inspectChatActivity(String opaqueId) {
  throw UnsupportedError('Interpreted Chat bridge only.');
}

/// Mounts an opaque native presentation host, not another runtime's eval object.
Widget? buildChatActivity(String opaqueId) {
  throw UnsupportedError('Interpreted Chat bridge only.');
}

void subscribeChatChanges(void Function() callback) {
  throw UnsupportedError('Interpreted Chat bridge only.');
}

void unsubscribeChatChanges() {
  throw UnsupportedError('Interpreted Chat bridge only.');
}
