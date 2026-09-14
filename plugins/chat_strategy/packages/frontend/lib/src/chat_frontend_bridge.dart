final class ChatPresentationEntry {
  const ChatPresentationEntry({required this.role, required this.content});

  final String role;
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

void subscribeChatChanges(void Function() callback) {
  throw UnsupportedError('Interpreted Chat bridge only.');
}

void unsubscribeChatChanges() {
  throw UnsupportedError('Interpreted Chat bridge only.');
}
