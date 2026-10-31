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
      final ChatStrategyPlugin plugin = ChatStrategyPlugin(
        sessions: store,
        maxModelInvocations: 8,
      );

      expect(plugin.sessions, same(store));
      expect(
        ChatStrategyPlugin(maxModelInvocations: 8).sessions,
        isNot(same(store)),
      );
      expect(
        ChatStrategyPlugin(maxModelInvocations: 8).sessions,
        isNot(same(ChatStrategyPlugin(maxModelInvocations: 8).sessions)),
      );
    },
  );

  test('standalone state defaults to stock instructions and empty history', () {
    final ChatSessionState state = ChatSessionState(SessionId('session-1'));

    expect(state.instructions, chatDefaultInstructions);
    expect(state.snapshot().instructions, state.instructions);
    expect(state.snapshot().entries, isEmpty);
    expect(state.draftRequest, '');
    expect(state.snapshot().draftRequest, '');
  });

  test('Session instructions are mutable', () {
    final ChatSessionState state = ChatSessionState(SessionId('session-1'))
      ..instructions = 'Use source tools before answering.';

    expect(state.instructions, 'Use source tools before answering.');
  });

  test(
    'strategy constructors reject nonpositive budgets independently of store',
    () {
      final store = ChatSessionStore();
      for (final int invalid in <int>[0, -1, -20]) {
        expect(
          () =>
              ChatStrategyPlugin(sessions: store, maxModelInvocations: invalid),
          throwsArgumentError,
        );
        expect(
          () => ChatRemoteOrchestrationBackend(
            sessions: store,
            maxModelInvocations: invalid,
            hostChannel: (_) => throw StateError('No execution expected.'),
          ),
          throwsArgumentError,
        );
      }
    },
  );

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
      runId: null,
      feedback: null,
    );
    final List<ChatEntry> entries = <ChatEntry>[user];
    final ChatSessionSnapshot snapshot = ChatSessionSnapshot(
      entries: entries,
      instructions: 'Instructions.',
      draftRequest: 'Draft.',
    );
    entries.clear();

    expect(snapshot.entries, <ChatEntry>[user]);
    expect(snapshot.draftRequest, 'Draft.');
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

  test(
    'volatile service draft belongs to canonical state and snapshots copy it',
    () async {
      final store = ChatSessionStore();
      final state = store.obtain(SessionId('session'));
      final service = ChatSessionBackend(store);
      const draft = '  Exact\r\n\t\u0000draft.  ';
      await service.setDraftRequest('session', draft);
      final before = state.snapshot();
      state.appendUserMessage('Direct append.');
      state.instructions = 'Changed.';
      expect(state.draftRequest, draft);
      final entry = await service.submitDraftRequest('session');
      expect(entry.id, 'entry-1');
      expect(entry.content, draft);
      expect(state.draftRequest, '');
      expect(before.draftRequest, draft);
      expect(before.entries, isEmpty);
      expect(
        (await ChatSessionBackend(
          ChatSessionStore(),
        ).snapshot('session')).draftRequest,
        '',
      );
    },
  );
}
