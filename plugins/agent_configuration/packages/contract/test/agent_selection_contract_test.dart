import 'dart:async';

import 'package:adele_contract/adele_contract.dart';
import 'package:agent_configuration_contract/agent_configuration_contract.dart';
import 'package:test/test.dart';

void main() {
  test(
    'selection DTO accepts exact identities and inclusive revision bounds',
    () {
      for (final (session, agent, revision) in <(String, String?, int)>[
        ('session', null, 0),
        ('session', null, 1),
        (
          's' * AgentSelectionLimits.maxSessionIdLength,
          'a' * 64,
          AgentSelectionLimits.maxRevision,
        ),
      ]) {
        final snapshot = AgentSelectionSnapshot(
          sessionId: session,
          selectedAgentId: agent,
          revision: revision,
        );
        expect(snapshot.sessionId, session);
        expect(snapshot.selectedAgentId, agent);
        expect(snapshot.revision, revision);
      }
    },
  );

  test('selection DTO rejects invalid identities and impossible revisions', () {
    for (final (session, agent, revision) in <(String, String?, int)>[
      ('', null, 0),
      (' \r\n\t', null, 1),
      (' session', null, 1),
      ('session ', null, 1),
      ('s' * (AgentSelectionLimits.maxSessionIdLength + 1), null, 1),
      ('session', null, -1),
      ('session', null, AgentSelectionLimits.maxRevision + 1),
      ('session', 'work', 0),
      for (final agent in ['', 'Work', '../private', 'con', 'a' * 65])
        ('session', agent, 1),
    ]) {
      expect(
        () => AgentSelectionSnapshot(
          sessionId: session,
          selectedAgentId: agent,
          revision: revision,
        ),
        throwsFormatException,
      );
    }
  });

  test(
    'generated service preserves required nulls and exact request shape',
    () async {
      final service = _SelectionService();
      final dispatcher = AgentSelectionServiceDispatcher(service);
      addTearDown(dispatcher.close);
      final channel = _Channel(dispatcher);
      final client = AgentSelectionServiceClient(channel);
      expect(agentSelectionServiceId, 'agentSelection');
      expect(
        agentSelectionServiceReadSessionSelectionId,
        'agentSelection.readSessionSelection',
      );
      expect(
        agentSelectionServiceUpdateSessionSelectionId,
        'agentSelection.updateSessionSelection',
      );
      final absent = await client.readSessionSelection('session');
      expect(absent.sessionId, 'session');
      expect(absent.selectedAgentId, isNull);
      expect(absent.revision, 0);
      expect(absent, isNot(same(service.response)));
      for (final agent in <String?>['work', null]) {
        service.response = AgentSelectionSnapshot(
          sessionId: 'session',
          selectedAgentId: agent,
          revision: 8,
        );
        final result = await client.updateSessionSelection('session', agent, 7);
        expect(result.sessionId, 'session');
        expect(result.selectedAgentId, agent);
        expect(result.revision, 8);
        expect(
          channel.calls.last.$1,
          agentSelectionServiceUpdateSessionSelectionId,
        );
        expect(channel.calls.last.$2, {
          'sessionId': 'session',
          'selectedAgentId': agent,
          'expectedRevision': 7,
        });
      }
      expect(
        channel.calls.first.$1,
        agentSelectionServiceReadSessionSelectionId,
      );
      expect(channel.calls.first.$2, {'sessionId': 'session'});
      expect(service.calls, [
        ('session', null, null),
        ('session', 'work', 7),
        ('session', null, 7),
      ]);
      final response = await dispatcher.dispatch({
        'kind': 'request',
        'requestId': 4,
        'method': agentSelectionServiceReadSessionSelectionId,
        'payload': {'sessionId': 'session'},
      });
      expect(response['payload'], {
        'sessionId': 'session',
        'selectedAgentId': null,
        'revision': 8,
      });
    },
  );

  test(
    'wire snapshots reject missing, foreign, mistyped and out-of-range values',
    () async {
      final valid = <String, Object?>{
        'sessionId': 'session',
        'selectedAgentId': null,
        'revision': 0,
      };
      for (final response in <Object?>[
        null,
        <Object?>[],
        for (final key in valid.keys) {...valid}..remove(key),
        {...valid, 'agent': <String, Object?>{}},
        {...valid, 'sessionId': 1},
        {...valid, 'sessionId': ' \n'},
        {...valid, 'sessionId': ' session'},
        {
          ...valid,
          'sessionId': 's' * (AgentSelectionLimits.maxSessionIdLength + 1),
        },
        {...valid, 'selectedAgentId': false},
        {...valid, 'selectedAgentId': 'work'},
        {...valid, 'selectedAgentId': '../private', 'revision': 1},
        {...valid, 'selectedAgentId': 'a' * 65, 'revision': 1},
        for (final revision in <Object?>[
          null,
          '0',
          0.0,
          -1,
          AgentSelectionLimits.maxRevision + 1,
        ])
          {...valid, 'revision': revision},
      ]) {
        final client = AgentSelectionServiceClient(_ResponseChannel(response));
        await expectLater(
          client.readSessionSelection('session'),
          throwsA(isA<AdeleProtocolException>()),
        );
        await expectLater(
          client.updateSessionSelection('session', null, 0),
          throwsA(isA<AdeleProtocolException>()),
        );
      }
    },
  );

  test('decoded snapshot is independent of the mutable response map', () async {
    final response = <String, Object?>{
      'sessionId': 's' * AgentSelectionLimits.maxSessionIdLength,
      'selectedAgentId': 'a' * 64,
      'revision': AgentSelectionLimits.maxRevision,
    };
    final client = AgentSelectionServiceClient(_ResponseChannel(response));
    final snapshot = await client.readSessionSelection(
      response['sessionId']! as String,
    );
    response.clear();
    expect(snapshot.sessionId, 's' * AgentSelectionLimits.maxSessionIdLength);
    expect(snapshot.selectedAgentId, 'a' * 64);
    expect(snapshot.revision, AgentSelectionLimits.maxRevision);
  });

  test(
    'strict request decoding rejects missing nullable and foreign fields',
    () async {
      final service = _SelectionService();
      final dispatcher = AgentSelectionServiceDispatcher(service);
      addTearDown(dispatcher.close);
      for (final (method, valid) in [
        (
          agentSelectionServiceReadSessionSelectionId,
          <String, Object?>{'sessionId': 'session'},
        ),
        (
          agentSelectionServiceUpdateSessionSelectionId,
          <String, Object?>{
            'sessionId': 'session',
            'selectedAgentId': null,
            'expectedRevision': 0,
          },
        ),
      ]) {
        for (final payload in <Object?>[
          null,
          <Object?>[],
          for (final key in valid.keys) {...valid}..remove(key),
          {...valid, 'sessionId': null},
          {...valid, 'sessionId': 1},
          for (final key in ['projectId', 'ownerId', 'path', 'instructions'])
            {...valid, key: 'caller-selected'},
          if (method == agentSelectionServiceUpdateSessionSelectionId) ...[
            {...valid, 'selectedAgentId': 1},
            for (final revision in <Object?>[null, '0', 0.0])
              {...valid, 'expectedRevision': revision},
          ],
        ]) {
          final response = await dispatcher.dispatch({
            'kind': 'request',
            'requestId': 1,
            'method': method,
            'payload': payload,
          });
          expect(response['ok'], isFalse, reason: '$method: $payload');
          expect((response['error']! as Map)['code'], 'invalid_request');
        }
      }
      expect(service.calls, isEmpty);
    },
  );

  test(
    'declared failures reconstruct without losing their outcome classification',
    () async {
      final service = _SelectionService();
      final dispatcher = AgentSelectionServiceDispatcher(service);
      addTearDown(dispatcher.close);
      final client = AgentSelectionServiceClient(_Channel(dispatcher));
      for (final code in [
        'invalid_request',
        'agent_not_found',
        'catalog_incomplete',
        'catalog_unavailable',
        'storage_unavailable',
        'corrupt_state',
        'stale_revision',
        'revision_exhausted',
        'outcome_uncertain',
      ]) {
        service.failure = AgentSelectionFailure(
          code: code,
          message: 'Safe failure.',
        );
        final matcher = isA<AgentSelectionFailure>()
            .having((error) => error.code, 'code', code)
            .having((error) => error.message, 'message', 'Safe failure.')
            .having((error) => error.details, 'details', isEmpty)
            .having(
              (error) => identical(error, service.failure),
              'reconstructed',
              isFalse,
            );
        await expectLater(
          client.readSessionSelection('session'),
          throwsA(matcher),
        );
        await expectLater(
          client.updateSessionSelection('session', null, 0),
          throwsA(matcher),
        );
      }
    },
  );

  test(
    'failure transport rejects invalid JSON details without leaking values',
    () async {
      final service = _SelectionService();
      final dispatcher = AgentSelectionServiceDispatcher(service);
      addTearDown(dispatcher.close);
      final cycle = <Object?>[];
      cycle.add(cycle);
      Object deep = 1;
      for (var depth = 0; depth < 65; depth++) {
        deep = [deep];
      }
      for (final value in <Object>[Object(), double.nan, cycle, deep]) {
        service.failure = AgentSelectionFailure(
          code: 'test',
          message: '/private/diagnostic',
          details: {'invalid': value},
        );
        final response = await dispatcher.dispatch({
          'kind': 'request',
          'requestId': 1,
          'method': agentSelectionServiceReadSessionSelectionId,
          'payload': {'sessionId': 'session'},
        });
        expect(response['ok'], isFalse);
        expect(response['error'], {
          'code': 'backend_contract_violation',
          'message': 'The backend violated its generated contract.',
          'details': <String, Object?>{},
        });
      }
    },
  );

  test(
    'default dispatcher serializes calls rather than simulating concurrent CAS',
    () async {
      final gate = Completer<void>();
      final service = _SelectionService()..gate = gate.future;
      final dispatcher = AgentSelectionServiceDispatcher(service);
      addTearDown(() async {
        if (!gate.isCompleted) gate.complete();
        await dispatcher.close();
      });
      final client = AgentSelectionServiceClient(_Channel(dispatcher));
      final first = client.readSessionSelection('session');
      final second = client.updateSessionSelection('session', null, 0);
      await Future<void>.delayed(Duration.zero);
      expect(service.calls, [('session', null, null)]);
      gate.complete();
      await Future.wait([first, second]);
      expect(service.calls, [('session', null, null), ('session', null, 0)]);
    },
  );
}

final class _SelectionService implements AgentSelectionService {
  AgentSelectionSnapshot response = AgentSelectionSnapshot(
    sessionId: 'session',
    selectedAgentId: null,
    revision: 0,
  );
  AgentSelectionFailure? failure;
  Future<void>? gate;
  final calls = <(String, String?, int?)>[];

  @override
  Future<AgentSelectionSnapshot> readSessionSelection(String sessionId) async {
    calls.add((sessionId, null, null));
    await gate;
    if (failure case final error?) throw error;
    return response;
  }

  @override
  Future<AgentSelectionSnapshot> updateSessionSelection(
    String sessionId,
    String? selectedAgentId,
    int expectedRevision,
  ) async {
    calls.add((sessionId, selectedAgentId, expectedRevision));
    await gate;
    if (failure case final error?) throw error;
    return response;
  }
}

final class _ResponseChannel implements AdeleRequestChannel {
  const _ResponseChannel(this.response);
  final Object? response;

  @override
  Future<Object?> request(String method, Map<String, Object?> payload) async =>
      response;
}

final class _Channel implements AdeleRequestChannel {
  _Channel(this.dispatcher);
  final AdeleBackendDispatcher dispatcher;
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

final class _WireFailure implements AdeleRemoteFailure {
  const _WireFailure(this.error);
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
