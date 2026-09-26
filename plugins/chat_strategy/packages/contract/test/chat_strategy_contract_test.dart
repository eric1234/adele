import 'package:adele_contract/adele_contract.dart';
import 'package:chat_strategy_contract/chat_strategy_contract.dart';
import 'package:test/test.dart';

void main() {
  test(
    'public semantic identities and occurrence value equality are stable',
    () {
      expect(chatStrategyPluginId.value, 'dev.adele.plugin.chat-strategy');
      expect(chatStrategyId.value, 'dev.adele.strategy.chat');
      expect(
        chatStrategyExtensionId.value,
        'dev.adele.plugin.chat-strategy.orchestration',
      );
      expect(chatSessionServiceId, 'chat.session');
      expect(ChatEntryId('entry-1'), ChatEntryId('entry-1'));
      expect(ChatEntryId('entry-1').hashCode, ChatEntryId('entry-1').hashCode);
      expect(ChatEntryId('entry-1'), isNot(ChatEntryId('entry-2')));
      expect(ChatEntryId('entry-1').toString(), 'entry-1');
      expect(() => ChatEntryId('  '), throwsFormatException);
    },
  );

  test(
    'generated client reconstructs canonical DTOs and immutable lists',
    () async {
      final service = _Service();
      final dispatcher = ChatSessionServiceDispatcher(service);
      addTearDown(dispatcher.close);
      final channel = _Channel(dispatcher);
      final client = ChatSessionServiceClient(channel);
      await client.configureSession('session', '  exact\r\n', 3);
      final accepted = await client.appendUserMessage('session', '  Prompt.\n');
      final snapshot = await client.snapshot('session');
      expect(accepted.id, 'entry-0');
      expect(accepted.role, 'user');
      expect(accepted.content, '  Prompt.\n');
      expect(snapshot.entries.single.id, accepted.id);
      expect(snapshot.entries.single, isNot(same(accepted)));
      expect(snapshot.instructions, '  exact\r\n');
      expect(snapshot.maxModelInvocations, 3);
      expect(snapshot.draftRequest, '');
      expect(() => snapshot.entries.clear(), throwsUnsupportedError);
      expect(channel.calls.map((call) => call.$1), [
        chatSessionServiceConfigureSessionId,
        chatSessionServiceAppendUserMessageId,
        chatSessionServiceSnapshotId,
      ]);
      expect(channel.calls[1].$2, {
        'sessionId': 'session',
        'content': '  Prompt.\n',
      });
    },
  );

  test(
    'generated draft operations retain exact text and accepted entry',
    () async {
      final service = _Service();
      final dispatcher = ChatSessionServiceDispatcher(service);
      addTearDown(dispatcher.close);
      final channel = _Channel(dispatcher);
      final client = ChatSessionServiceClient(channel);
      for (final draft in ['', '   ', '\n', '  Exact\r\n\t\u0000draft  ']) {
        await client.setDraftRequest('session', draft);
        expect((await client.snapshot('session')).draftRequest, draft);
      }
      final before = await client.snapshot('session');
      final accepted = await client.submitDraftRequest('session');
      expect(accepted.id, 'entry-0');
      expect(accepted.role, 'user');
      expect(accepted.content, before.draftRequest);
      final after = await client.snapshot('session');
      expect(after.draftRequest, '');
      expect(after.entries.single.id, accepted.id);
      expect(after.entries.single.content, accepted.content);
      expect(channel.calls.first.$1, chatSessionServiceSetDraftRequestId);
      expect(channel.calls.first.$2, {'sessionId': 'session', 'content': ''});
      final submission = channel.calls[channel.calls.length - 2];
      expect(submission.$1, chatSessionServiceSubmitDraftRequestId);
      expect(submission.$2, {'sessionId': 'session'});
    },
  );

  test('declared busy errors survive the generated service boundary', () async {
    final service = _Service()..busy = true;
    final dispatcher = ChatSessionServiceDispatcher(service);
    addTearDown(dispatcher.close);
    final client = ChatSessionServiceClient(_Channel(dispatcher));
    await expectLater(
      client.appendUserMessage('session', 'Prompt.'),
      throwsA(
        isA<ChatSessionFailure>()
            .having((error) => error.code, 'code', 'session_busy')
            .having((error) => error.details, 'details', {
              'sessionId': 'session',
            }),
      ),
    );
  });

  test(
    'current wire snapshot requires a string draft without legacy defaults',
    () async {
      for (final draftFields in <Map<String, Object?>>[
        {},
        {'draftRequest': null},
        {'draftRequest': 3},
      ]) {
        final client = ChatSessionServiceClient(
          _SnapshotChannel({
            'entries': <Object?>[],
            'instructions': '',
            'maxModelInvocations': 8,
            ...draftFields,
          }),
        );
        await expectLater(
          client.snapshot('session'),
          throwsA(isA<AdeleProtocolException>()),
        );
      }
    },
  );
}

final class _SnapshotChannel implements AdeleRequestChannel {
  _SnapshotChannel(this.payload);
  final Map<String, Object?> payload;

  @override
  Future<Object?> request(
    String method,
    Map<String, Object?> arguments,
  ) async => payload;
}

final class _Channel implements AdeleRequestChannel {
  _Channel(this.dispatcher);
  final ChatSessionServiceDispatcher dispatcher;
  final calls = <(String, Map<String, Object?>)>[];

  @override
  Future<Object?> request(String method, Map<String, Object?> payload) async {
    calls.add((method, payload));
    final response = await dispatcher.dispatch({
      'kind': 'request',
      'requestId': calls.length,
      'method': method,
      'payload': payload,
    });
    if (response['ok'] != true) {
      throw _WireFailure(response['error']! as Map);
    }
    return response['payload'];
  }
}

final class _Service implements ChatSessionService {
  final entries = <ChatEntry>[];
  String instructions = '';
  int maximum = 8;
  String draft = '';
  bool busy = false;

  @override
  Future<ChatSessionSnapshot> snapshot(String sessionId) async =>
      ChatSessionSnapshot(
        entries: entries,
        instructions: instructions,
        maxModelInvocations: maximum,
        draftRequest: draft,
      );

  @override
  Future<ChatEntry> appendUserMessage(String sessionId, String content) async {
    if (busy) {
      throw ChatSessionFailure(
        code: 'session_busy',
        message: 'Busy.',
        details: {'sessionId': sessionId},
      );
    }
    final entry = ChatEntry(
      id: 'entry-${entries.length}',
      role: 'user',
      content: content,
    );
    entries.add(entry);
    return entry;
  }

  @override
  Future<void> setDraftRequest(String sessionId, String content) async {
    draft = content;
  }

  @override
  Future<ChatEntry> submitDraftRequest(String sessionId) async {
    final entry = await appendUserMessage(sessionId, draft);
    draft = '';
    return entry;
  }

  @override
  Future<void> configureSession(
    String sessionId,
    String instructions,
    int maxModelInvocations,
  ) async {
    this.instructions = instructions;
    maximum = maxModelInvocations;
  }
}

final class _WireFailure implements AdeleRemoteFailure {
  _WireFailure(this.error);
  final Map<Object?, Object?> error;
  @override
  String? get declaredFailureType => error['declaredFailureType'] as String?;
  @override
  String get code => error['code'] as String;
  @override
  String get message => error['message'] as String;
  @override
  Map<String, Object?> get details =>
      Map<String, Object?>.from(error['details'] as Map);
}
