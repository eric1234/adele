import 'package:adele_orchestration/adele_orchestration.dart';
import 'package:chat_strategy_plugin/chat_strategy_plugin.dart';
import 'package:test/test.dart';

void main() {
  test('store retains state by canonical Session identity', () {
    final ChatSessionStore store = ChatSessionStore();
    final ChatSessionState first = store.obtain(SessionId('session-1'))
      ..append(ChatUserMessage('Inspect.'));

    expect(store.obtain(SessionId('session-1')), same(first));
    expect(store.obtain(SessionId('session-2')), isNot(same(first)));
    expect(store.obtain(SessionId('session-2')).snapshot().entries, isEmpty);
    expect(first.id, SessionId('session-1'));
  });

  test(
    'plugin retains the supplied store and defaults to an isolated store',
    () {
      final ChatSessionStore store = ChatSessionStore();
      final ChatStrategyPlugin plugin = ChatStrategyPlugin(sessions: store);

      expect(plugin.sessions, same(store));
      expect(ChatStrategyPlugin().sessions, isNot(same(store)));
      expect(
        ChatStrategyPlugin().sessions,
        isNot(same(ChatStrategyPlugin().sessions)),
      );
    },
  );

  test('standalone state defaults to empty history and eight model calls', () {
    final ChatSessionState state = ChatSessionState(SessionId('session-1'));

    expect(state.instructions, '');
    expect(state.maxModelInvocations, 8);
    expect(state.snapshot().id, state.id);
    expect(state.snapshot().entries, isEmpty);
  });

  test('configuration is mutable and rejects nonpositive budgets', () {
    final ChatSessionState state = ChatSessionState(SessionId('session-1'))
      ..instructions = 'Use source tools before answering.'
      ..maxModelInvocations = 2;

    expect(state.instructions, 'Use source tools before answering.');
    expect(state.maxModelInvocations, 2);
    for (final int invalid in <int>[0, -1, -20]) {
      expect(() => state.maxModelInvocations = invalid, throwsArgumentError);
      expect(state.maxModelInvocations, 2);
    }
  });

  test('snapshot is an immutable copy, not a live view of conversation', () {
    final ChatSessionState state = ChatSessionState(SessionId('session-1'))
      ..append(ChatUserMessage('Inspect the resource.'));
    final ChatSessionSnapshot before = state.snapshot();
    final ChatAssistantMessage assistant = ChatAssistantMessage('Complete.');
    state.append(assistant);

    expect(before.id, state.id);
    expect(before.entries, hasLength(1));
    expect(before.entries.single, isA<ChatUserMessage>());
    expect(state.snapshot().entries, <Matcher>[
      isA<ChatUserMessage>(),
      same(assistant),
    ]);
    expect(() => before.entries.add(assistant), throwsUnsupportedError);
    expect(() => before.entries[0] = assistant, throwsUnsupportedError);
    expect(() => before.entries.clear(), throwsUnsupportedError);
  });

  test('snapshot constructor copies caller-owned entries', () {
    final ChatUserMessage user = ChatUserMessage('Inspect.');
    final List<ChatEntry> entries = <ChatEntry>[user];
    final ChatSessionSnapshot snapshot = ChatSessionSnapshot(
      id: SessionId('session-1'),
      entries: entries,
    );
    entries.clear();

    expect(snapshot.entries, <ChatEntry>[user]);
    expect(() => snapshot.entries.remove(user), throwsUnsupportedError);
  });

  for (final String blank in <String>['', ' ', '\t\r\n']) {
    test(
      'user and assistant messages reject blank content ${blank.length}',
      () {
        expect(() => ChatUserMessage(blank), throwsFormatException);
        expect(() => ChatAssistantMessage(blank), throwsFormatException);
      },
    );
  }

  test('messages preserve nonblank content without normalization', () {
    const String content = '  Inspect.\r\n\t';

    expect(ChatUserMessage(content).content, content);
    expect(ChatAssistantMessage(content).content, content);
  });
}
