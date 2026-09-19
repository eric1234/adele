import 'package:adele_orchestration/adele_orchestration.dart';
import 'package:chat_strategy_backend/chat_strategy_backend.dart';
import 'package:test/test.dart';

void main() {
  test('store retains state by canonical Session identity', () {
    final ChatSessionStore store = ChatSessionStore();
    final ChatSessionState first = store.obtain(SessionId('session-1'))
      ..appendUserMessage('Inspect.');

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

    expect(state.instructions, chatDefaultInstructions);
    expect(state.maxModelInvocations, 8);
    expect(state.snapshot().instructions, state.instructions);
    expect(state.snapshot().maxModelInvocations, state.maxModelInvocations);
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
      ..appendUserMessage('Inspect the resource.');
    final ChatSessionSnapshot before = state.snapshot();
    final ChatEntry second = state.appendUserMessage('Another question.');

    expect(before.entries, hasLength(1));
    expect(before.entries.single.role, 'user');
    expect(state.snapshot().entries, <Matcher>[isA<ChatEntry>(), same(second)]);
    expect(() => before.entries.add(second), throwsUnsupportedError);
    expect(() => before.entries[0] = second, throwsUnsupportedError);
    expect(() => before.entries.clear(), throwsUnsupportedError);
  });

  test('snapshot constructor copies caller-owned entries', () {
    const ChatEntry user = ChatEntry(
      id: 'entry-1',
      role: 'user',
      content: 'Inspect.',
    );
    final List<ChatEntry> entries = <ChatEntry>[user];
    final ChatSessionSnapshot snapshot = ChatSessionSnapshot(
      entries: entries,
      instructions: 'Instructions.',
      maxModelInvocations: 8,
    );
    entries.clear();

    expect(snapshot.entries, <ChatEntry>[user]);
    expect(() => snapshot.entries.remove(user), throwsUnsupportedError);
  });

  for (final String blank in <String>['', ' ', '\t\r\n']) {
    test('user messages reject blank content ${blank.length}', () {
      final state = ChatSessionState(SessionId('session-1'));
      expect(() => state.appendUserMessage(blank), throwsFormatException);
      expect(state.snapshot().entries, isEmpty);
    });
  }

  test('messages preserve nonblank content without normalization', () {
    const String content = '  Inspect.\r\n\t';

    final state = ChatSessionState(SessionId('session-1'));
    expect(state.appendUserMessage(content).content, content);
  });
}
