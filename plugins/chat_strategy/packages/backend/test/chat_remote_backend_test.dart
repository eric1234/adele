import 'dart:async';
import 'dart:isolate';

import 'package:adele_contract/adele_contract.dart';
import 'package:adele_orchestration/adele_orchestration.dart';
import 'package:adele_orchestration/remote_orchestration.dart';
import 'package:chat_strategy_backend/chat_strategy_backend.dart';
import 'package:test/test.dart';

import '../bin/chat_strategy_backend.dart' as entrypoint;

void main() {
  test(
    'standalone entrypoint routes private service and advertises only strategy',
    () async {
      final backend = await _RunningBackend.start();
      addTearDown(backend.close);
      expect(
        backend.ready['pluginBackendProtocolVersion'],
        adelePluginBackendProtocolVersion,
      );
      expect(backend.ready.containsKey('capabilityExposures'), isFalse);
      expect(AdeleCapabilityExposure.fromReady(backend.ready), isEmpty);
      final extension = AdeleExtensionExposure.fromReady(backend.ready).single;
      expect(
        extension.extensionPointId,
        orchestrationStrategyContributions.value,
      );
      expect(extension.extensionId, chatStrategyExtensionId.value);
      expect(extension.serviceId, remoteOrchestrationServiceId);
      expect(extension.configurationContext, 'configured-default');
      expect(extension.metadata, {
        'strategyId': chatStrategyId.value,
        'routeId': chatStrategyRouteId,
      });
      expect(backend.hostCalls, isEmpty);

      final snapshot = await backend.chat.snapshot('session');
      expect(snapshot.entries, isEmpty);
      expect(snapshot.instructions, chatDefaultInstructions);
      expect(snapshot.maxModelInvocations, 8);
      expect(backend.hostCalls, isEmpty);
      await expectLater(
        backend.request(
          chatSessionServiceId,
          'chat.session.appendAssistantMessage',
          {'sessionId': 'session', 'content': 'Forged final.'},
        ),
        throwsA(
          isA<AdeleRemoteFailure>().having(
            (error) => error.code,
            'code',
            'unknown_method',
          ),
        ),
      );
    },
  );

  test(
    'canonical service allocates occurrences, preserves bytes and validates atomically',
    () async {
      final backend = await _RunningBackend.start();
      addTearDown(backend.close);
      await backend.chat.configureSession(
        'session',
        '  exact instructions\r\n',
        2,
      );
      final first = await backend.chat.appendUserMessage(
        'session',
        '  Repeat.\r\n',
      );
      final before = await backend.chat.snapshot('session');
      final second = await backend.chat.appendUserMessage(
        'session',
        first.content,
      );
      final after = await backend.chat.snapshot('session');
      expect(first.id, isNot(second.id));
      expect(after.entries.map((entry) => entry.id), [first.id, second.id]);
      expect(after.entries.map((entry) => entry.role), ['user', 'user']);
      expect(after.entries.map((entry) => entry.content), [
        first.content,
        first.content,
      ]);
      expect(before.entries, hasLength(1));
      expect(before.entries.single.id, first.id);
      expect(() => after.entries.clear(), throwsUnsupportedError);
      expect(after.instructions, '  exact instructions\r\n');
      expect(after.maxModelInvocations, 2);
      expect((await backend.chat.snapshot('other')).entries, isEmpty);
      for (final invalid in ['', ' ', '\t\r\n']) {
        await expectLater(
          backend.chat.appendUserMessage('session', invalid),
          _failure('invalid_content'),
        );
        await expectLater(
          backend.chat.snapshot(invalid),
          _failure('invalid_session'),
        );
      }
      for (final invalid in [0, -1]) {
        await expectLater(
          backend.chat.configureSession(
            'session',
            'Must not replace.',
            invalid,
          ),
          _failure('invalid_configuration'),
        );
      }
      final unchanged = await backend.chat.snapshot('session');
      expect(unchanged.instructions, after.instructions);
      expect(unchanged.maxModelInvocations, 2);
      expect(
        unchanged.entries.map((entry) => entry.id),
        after.entries.map((entry) => entry.id),
      );
    },
  );

  for (final mutationsFirst in [true, false]) {
    test(
      'queued mutations ${mutationsFirst ? 'before' : 'after'} materialization are atomic',
      () async {
        final backend = await _RunningBackend.start();
        addTearDown(backend.close);
        await backend.chat.configureSession(
          'session',
          'Original instructions.',
          2,
        );
        final original = await backend.chat.appendUserMessage(
          'session',
          'Original prompt.',
        );
        final before = await backend.chat.snapshot('session');
        late final Future<String> materializing;
        if (!mutationsFirst) materializing = backend.materialize();
        final configuring = backend.chat.configureSession(
          'session',
          'Changed instructions.',
          3,
        );
        final appending = backend.chat.appendUserMessage(
          'session',
          'Additional prompt.',
        );
        if (mutationsFirst) {
          materializing = backend.materialize();
          await configuring;
          await appending;
        } else {
          await Future.wait([
            expectLater(configuring, _failure('session_busy')),
            expectLater(appending, _failure('session_busy')),
          ]);
        }
        final execution = await materializing;
        final captured = await backend.chat.snapshot('session');
        expect(captured.entries.first.id, original.id);
        expect(
          captured.instructions,
          mutationsFirst ? 'Changed instructions.' : before.instructions,
        );
        expect(
          captured.maxModelInvocations,
          mutationsFirst ? 3 : before.maxModelInvocations,
        );
        expect(captured.entries.map((entry) => entry.content), [
          'Original prompt.',
          if (mutationsFirst) 'Additional prompt.',
        ]);
        expect(before.entries.single.id, original.id);
        expect(before.instructions, 'Original instructions.');
        expect(before.maxModelInvocations, 2);
        expect(
          await backend.orchestration.start(execution, 'token'),
          RemoteRunState.completed,
        );
        expect(
          backend.host.materials.single.instructions,
          '$chatToolNarrationGuidance\n\n${captured.instructions}',
        );
        final settled = await backend.chat.snapshot('session');
        expect(settled.instructions, captured.instructions);
        expect(settled.maxModelInvocations, captured.maxModelInvocations);
        expect(
          settled.entries
              .take(captured.entries.length)
              .map((entry) => entry.id),
          captured.entries.map((entry) => entry.id),
        );
      },
    );
  }

  test(
    'mutation lock spans materialization, model work and terminal host flush',
    () async {
      final backend = await _RunningBackend.start();
      addTearDown(backend.close);
      backend.host.modelGate = Completer<void>();
      backend.host.completeGate = Completer<void>();
      final user = await backend.chat.appendUserMessage('session', 'Prompt.');
      final execution = await backend.materialize();
      await backend.expectBusy();
      await backend.chat.appendUserMessage('other', 'Independent.');
      final advancing = backend.orchestration.start(execution, 'start-token');
      await backend.host.modelEntered.future;
      await backend.expectBusy();
      backend.host.modelGate!.complete();
      await backend.host.completeEntered.future;
      await backend.expectBusy();
      final duringFlush = await backend.chat.snapshot('session');
      expect(duringFlush.entries.map((entry) => entry.role), ['user']);
      expect(duringFlush.entries.single.id, user.id);
      backend.host.completeGate!.complete();
      expect(await advancing, RemoteRunState.completed);
      final finalSnapshot = await backend.chat.snapshot('session');
      expect(finalSnapshot.entries.first.id, user.id);
      expect(finalSnapshot.entries.last.id, isNot(user.id));
      expect(finalSnapshot.entries.last.content, 'Final answer.');
      expect(
        backend.host.materials.single.instructions,
        '$chatToolNarrationGuidance\n\n$chatDefaultInstructions',
      );
      await backend.chat.configureSession('session', 'Next instructions.', 1);
      final nextUser = await backend.chat.appendUserMessage(
        'session',
        'Follow up.',
      );
      expect(nextUser.id, isNot(finalSnapshot.entries.last.id));
      backend.host.state = RemoteRunState.created;
      final next = await backend.materialize(run: 'run-2');
      expect(
        await backend.orchestration.start(next, 'second-token'),
        RemoteRunState.completed,
      );
      expect(
        backend.host.materials.last.input.cast<SemanticMessageInput>().map(
          (item) => item.content,
        ),
        ['Prompt.', 'Final answer.', 'Follow up.'],
      );
      expect(
        backend.host.materials.last.instructions,
        '$chatToolNarrationGuidance\n\nNext instructions.',
      );
      final entries = (await backend.chat.snapshot('session')).entries;
      expect(entries.map((entry) => entry.id).toSet(), hasLength(4));
    },
  );

  for (final approved in [true, false]) {
    test(
      'approval $approved preserves private batch replay and lock while waiting',
      () async {
        final backend = await _RunningBackend.start();
        addTearDown(backend.close);
        backend.host.batch = true;
        await backend.chat.appendUserMessage('session', 'Perform steps.');
        final execution = await backend.materialize();
        expect(
          await backend.orchestration.start(execution, 'start-token'),
          RemoteRunState.waiting,
        );
        final waiting = await backend.chat.snapshot('session');
        expect(waiting.entries.single.content, 'Perform steps.');
        await expectLater(
          backend.orchestration.start(execution, 'invalid-restart-token'),
          throwsA(isA<AdeleRemoteFailure>()),
        );
        await backend.expectBusy();
        backend.host.approved = approved;
        expect(
          await backend.orchestration.resolveApproval(
            execution,
            RemoteApprovalResolution(
              interruptionId: 'approval',
              toolInvocationId: 'tool',
              approved: approved,
            ),
            'approval-token',
          ),
          RemoteRunState.completed,
        );
        expect(backend.host.events, [
          'start',
          'model',
          'proposal-one',
          'approval',
          'proposal-two',
          'model',
          'complete',
        ]);
        final input = backend.host.materials.last.input;
        expect(input.map((item) => item.runtimeType), [
          SemanticMessageInput,
          SemanticNativeInput,
          SemanticMessageInput,
          SemanticToolProposalInput,
          SemanticToolProposalInput,
          SemanticToolOutcomeInput,
          SemanticToolOutcomeInput,
        ]);
        final outcome = input.whereType<SemanticToolOutcomeInput>().first;
        expect(
          outcome.outcome.disposition,
          approved
              ? ToolOutcomeDisposition.success
              : ToolOutcomeDisposition.userRejected,
        );
        final snapshot = await backend.chat.snapshot('session');
        expect(snapshot.entries.map((entry) => entry.content), [
          'Perform steps.',
          'Final answer.',
        ]);
        expect(snapshot.entries.first.id, waiting.entries.single.id);
        expect(
          backend.hostCalls
              .map((request) => request['hostInvocationContext'])
              .toSet(),
          {'start-token', 'approval-token'},
        );
        await backend.chat.appendUserMessage('session', 'Next.');
      },
    );
  }

  for (final phase in ['start', 'refusal', 'approval']) {
    for (final rejection in ['error', 'mismatched state']) {
      test(
        '$phase $rejection at terminal acknowledgement discards final history',
        () async {
          final backend = await _RunningBackend.start();
          addTearDown(backend.close);
          backend.host.batch = phase == 'approval';
          backend.host.refuse = phase == 'refusal';
          backend.host.completeGate = Completer<void>();
          backend.host.completeError = rejection == 'error';
          backend.host.completeState = rejection == 'mismatched state'
              ? RemoteRunState.failed
              : null;
          await backend.chat.configureSession(
            'session',
            'Retained instructions.',
            3,
          );
          final user = await backend.chat.appendUserMessage(
            'session',
            'Prompt.',
          );
          final execution = await backend.materialize();
          final Future<RemoteRunState> advancing;
          if (phase == 'approval') {
            expect(
              await backend.orchestration.start(execution, 'start-token'),
              RemoteRunState.waiting,
            );
            advancing = backend.orchestration.resolveApproval(
              execution,
              RemoteApprovalResolution(
                interruptionId: 'approval',
                toolInvocationId: 'tool',
                approved: true,
              ),
              'approval-token',
            );
          } else {
            advancing = backend.orchestration.start(execution, 'start-token');
          }
          final failed = expectLater(
            advancing,
            throwsA(isA<AdeleRemoteFailure>()),
          );
          await backend.host.completeEntered.future;
          await backend.expectBusy();
          final pending = await backend.chat.snapshot('session');
          expect(pending.entries.map((entry) => entry.id), [user.id]);
          backend.host.completeGate!.complete();
          await failed;
          final rejected = await backend.chat.snapshot('session');
          expect(
            rejected.entries.map(
              (entry) => (entry.id, entry.role, entry.content),
            ),
            [(user.id, 'user', 'Prompt.')],
          );
          expect(rejected.instructions, 'Retained instructions.');
          expect(rejected.maxModelInvocations, 3);
          await backend.orchestration.release(execution);
          backend.host
            ..batch = false
            ..refuse = false
            ..completeError = false
            ..completeState = null
            ..state = RemoteRunState.created;
          await backend.chat.appendUserMessage('session', 'Retry.');
          final retry = await backend.materialize(run: 'retry');
          expect(
            await backend.orchestration.start(retry, 'retry-token'),
            RemoteRunState.completed,
          );
          expect(
            backend.host.materials.last.input.cast<SemanticMessageInput>().map(
              (item) => item.content,
            ),
            ['Prompt.', 'Retry.'],
          );
          final recovered = await backend.chat.snapshot('session');
          expect(recovered.entries.map((entry) => entry.role), [
            'user',
            'user',
            'assistant',
          ]);
          expect(
            recovered.entries.map((entry) => entry.id).toSet(),
            hasLength(3),
          );
        },
      );
    }
  }

  for (final mode in [
    'model error',
    'limit',
    'close before start',
    'close waiting',
  ]) {
    test('$mode releases Session without inventing a final entry', () async {
      final backend = await _RunningBackend.start();
      addTearDown(backend.close);
      backend.host.batch = mode != 'model error';
      backend.host.modelError = mode == 'model error';
      await backend.chat.appendUserMessage('session', 'Prompt.');
      if (mode == 'limit') {
        await backend.chat.configureSession('session', '', 1);
      }
      final execution = await backend.materialize();
      if (mode == 'model error') {
        await expectLater(
          backend.orchestration.start(execution, 'token'),
          throwsA(isA<AdeleRemoteFailure>()),
        );
      } else if (mode == 'limit') {
        expect(
          await backend.orchestration.start(execution, 'token'),
          RemoteRunState.failed,
        );
        expect(backend.host.events, ['start', 'model', 'fail']);
      } else {
        if (mode == 'close waiting') {
          expect(
            await backend.orchestration.start(execution, 'token'),
            RemoteRunState.waiting,
          );
        }
        await backend.orchestration.release(execution);
        await backend.orchestration.release(execution);
        expect(backend.host.events, isNot(contains('approval')));
      }
      expect(
        (await backend.chat.snapshot('session')).entries.single.content,
        'Prompt.',
      );
      await backend.chat.configureSession('session', 'After release.', 2);
      await backend.chat.appendUserMessage('session', 'Next.');
    });
  }

  test(
    'duplicate materialization cannot release the first Session claim',
    () async {
      final backend = await _RunningBackend.start();
      addTearDown(backend.close);
      final first = await backend.materialize();
      await expectLater(
        backend.materialize(run: 'duplicate'),
        throwsA(isA<AdeleRemoteFailure>()),
      );
      await backend.expectBusy();
      await backend.orchestration.release(first);
      await backend.chat.appendUserMessage('session', 'Now accepted.');
    },
  );

  test(
    'shutdown settles a blocked reverse call before forward drain',
    () async {
      final backend = await _RunningBackend.start();
      addTearDown(backend.close);
      backend.host.modelGate = Completer<void>();
      final execution = await backend.materialize();
      final advancing = backend.orchestration.start(execution, 'token');
      final failed = expectLater(advancing, throwsA(isA<AdeleRemoteFailure>()));
      await backend.host.modelEntered.future;
      await backend.shutdown();
      await failed;
      backend.host.modelGate!.complete();
    },
  );

  for (final closeBackend in [false, true]) {
    for (final rejectCompletion in [false, true]) {
      test(
        '${closeBackend ? 'backend close' : 'release'} drains '
        '${rejectCompletion ? 'rejected' : 'accepted'} terminal history transaction',
        () async {
          final store = ChatSessionStore();
          final service = ChatSessionBackend(store);
          final host = _Host()
            ..completeGate = Completer<void>()
            ..completeError = rejectCompletion;
          final dispatcher = RemoteOrchestrationHostServiceDispatcher(host);
          final backend = ChatRemoteOrchestrationBackend(
            sessions: store,
            hostChannel: (_) => _DirectHostChannel(dispatcher),
          );
          addTearDown(() async {
            if (!host.completeGate!.isCompleted) host.completeGate!.complete();
            await backend.close();
            await dispatcher.close();
          });
          final user = await service.appendUserMessage('session', 'Prompt.');
          final execution = await backend.materialize(
            chatStrategyRouteId,
            RemoteOrchestrationSession(
              sessionId: 'session',
              taskId: 'task',
              strategyId: chatStrategyId.value,
            ),
            'run',
          );
          final advancing = backend.start(execution, 'token');
          final observed = expectLater(
            advancing,
            rejectCompletion
                ? throwsA(isA<AdeleRemoteFailure>())
                : completion(RemoteRunState.completed),
          );
          await host.completeEntered.future;
          await expectLater(
            backend.start(execution, 'duplicate'),
            throwsA(isA<InvalidRunOperation>()),
          );
          final closing = closeBackend
              ? backend.close()
              : backend.release(execution);
          expect(
            closeBackend ? backend.close() : backend.release(execution),
            same(closing),
          );
          bool closed = false;
          final drained = closing.then((_) => closed = true);
          await service.snapshot('session');
          expect(closed, isFalse);
          await expectLater(
            service.appendUserMessage('session', 'Blocked.'),
            _failure('session_busy'),
          );
          expect(
            (await service.snapshot(
              'session',
            )).entries.map((entry) => entry.id),
            [user.id],
          );
          host.completeGate!.complete();
          await observed;
          await drained;
          final settled = await service.snapshot('session');
          expect(settled.entries.map((entry) => entry.role), [
            'user',
            if (!rejectCompletion) 'assistant',
          ]);
          expect(settled.entries.first.id, user.id);
          await service.configureSession('session', 'After close.', 2);
          await service.appendUserMessage('session', 'Next.');
        },
      );
    }
  }

  test(
    'backend close during materialization discards and releases exact claim',
    () async {
      final store = ChatSessionStore();
      final service = ChatSessionBackend(store);
      final backend = ChatRemoteOrchestrationBackend(
        sessions: store,
        hostChannel: (_) =>
            throw StateError('Materialization has no host authority.'),
      );
      addTearDown(backend.close);
      final user = await service.appendUserMessage('session', 'Prompt.');
      final materializing = backend.materialize(
        chatStrategyRouteId,
        RemoteOrchestrationSession(
          sessionId: 'session',
          taskId: 'task',
          strategyId: chatStrategyId.value,
        ),
        'run',
      );
      final closing = backend.close();
      await expectLater(materializing, throwsStateError);
      await closing;
      expect(
        (await service.snapshot('session')).entries.map((entry) => entry.id),
        [user.id],
      );
      await service.appendUserMessage('session', 'Next.');
    },
  );
}

Matcher _failure(String code) => throwsA(
  isA<ChatSessionFailure>().having((error) => error.code, 'code', code),
);

final class _RunningBackend {
  _RunningBackend(this.isolate, this.responses, this.ready)
    : commands = ready['commandPort']! as SendPort {
    subscription = responses.listen((message) {
      final map = Map<String, Object?>.from(message as Map);
      if (map['kind'] == 'hostRequest') {
        hostCalls.add(map);
        unawaited(_respond(map));
      } else {
        final completer = pending.remove(map['requestId']);
        if (map['ok'] == true) {
          completer!.complete(map['payload']);
        } else {
          completer!.completeError(_WireFailure(map['error'] as Map));
        }
      }
    });
  }

  final Isolate isolate;
  final ReceivePort responses;
  final Map<String, Object?> ready;
  final SendPort commands;
  late final StreamSubscription<Object?> subscription;
  final pending = <int, Completer<Object?>>{};
  final hostCalls = <Map<String, Object?>>[];
  final host = _Host();
  late final dispatcher = RemoteOrchestrationHostServiceDispatcher(host);
  late final chat = ChatSessionServiceClient(
    _Channel(this, chatSessionServiceId),
  );
  late final orchestration = RemoteOrchestrationServiceClient(
    _Channel(this, remoteOrchestrationServiceId),
  );
  int nextRequest = 0;
  bool stopped = false;

  static Future<_RunningBackend> start() async {
    final bootstrap = ReceivePort();
    final responses = ReceivePort();
    final isolate = await Isolate.spawn(_runBackend, [
      bootstrap.sendPort,
      responses.sendPort,
    ]);
    try {
      final ready = await bootstrap.first.timeout(const Duration(seconds: 5));
      return _RunningBackend(
        isolate,
        responses,
        Map<String, Object?>.from(ready as Map),
      );
    } on Object {
      isolate.kill(priority: Isolate.immediate);
      responses.close();
      rethrow;
    } finally {
      bootstrap.close();
    }
  }

  Future<Object?> request(
    String service,
    String method,
    Map<String, Object?> payload,
  ) {
    final id = nextRequest++;
    final completer = Completer<Object?>();
    pending[id] = completer;
    commands.send({
      'kind': 'request',
      'requestId': id,
      'serviceId': service,
      'configurationContext': 'configured-default',
      'method': method,
      'payload': payload,
    });
    return completer.future.timeout(const Duration(seconds: 5));
  }

  Future<String> materialize({String run = 'run'}) => orchestration.materialize(
    chatStrategyRouteId,
    RemoteOrchestrationSession(
      sessionId: 'session',
      taskId: 'task',
      strategyId: chatStrategyId.value,
    ),
    run,
  );

  Future<void> expectBusy() async {
    final before = await chat.snapshot('session');
    await Future.wait([
      expectLater(
        chat.appendUserMessage('session', 'Rejected.'),
        _failure('session_busy'),
      ),
      expectLater(
        chat.configureSession('session', 'Rejected.', 3),
        _failure('session_busy'),
      ),
    ]);
    final after = await chat.snapshot('session');
    expect(after.instructions, before.instructions);
    expect(after.maxModelInvocations, before.maxModelInvocations);
    expect(
      after.entries.map((entry) => (entry.id, entry.role, entry.content)),
      before.entries.map((entry) => (entry.id, entry.role, entry.content)),
    );
  }

  Future<void> _respond(Map<String, Object?> request) async {
    expect(request['serviceId'], remoteOrchestrationHostServiceId);
    final response = await dispatcher.dispatch({
      'kind': 'request',
      'requestId': request['requestId'],
      'method': request['method'],
      'payload': request['payload'],
    });
    commands.send({...response, 'kind': 'hostResponse'});
  }

  Future<void> shutdown() async {
    if (stopped) return;
    expect(await request('', 'shutdown', {}), {'stopping': true});
    stopped = true;
  }

  Future<void> close() async {
    try {
      await shutdown();
    } finally {
      isolate.kill(priority: Isolate.immediate);
      responses.close();
      await subscription.cancel();
      if (host.modelGate case final gate? when !gate.isCompleted) {
        gate.complete();
      }
      if (host.completeGate case final gate? when !gate.isCompleted) {
        gate.complete();
      }
      await dispatcher.close();
    }
  }
}

Future<void> _runBackend(List<SendPort> ports) => entrypoint.main([], {
  'bootstrapPort': ports[0],
  'responsePort': ports[1],
  'defaultConfigurationContext': 'configured-default',
});

final class _Channel implements AdeleRequestChannel {
  _Channel(this.backend, this.service);
  final _RunningBackend backend;
  final String service;
  @override
  Future<Object?> request(String method, Map<String, Object?> payload) =>
      backend.request(service, method, payload);
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

final class _DirectHostChannel implements AdeleRequestChannel {
  _DirectHostChannel(this.dispatcher);

  final RemoteOrchestrationHostServiceDispatcher dispatcher;

  @override
  Future<Object?> request(String method, Map<String, Object?> payload) async {
    final response = await dispatcher.dispatch({
      'kind': 'request',
      'requestId': 1,
      'method': method,
      'payload': payload,
    });
    if (response['ok'] != true) {
      throw _WireFailure(response['error']! as Map);
    }
    return response['payload'];
  }
}

final class _Tools implements StrategyToolSnapshot {}

final class _Host implements RemoteOrchestrationHostService {
  final events = <String>[];
  final materials = <StrategyInferenceMaterial>[];
  final modelEntered = Completer<void>();
  final completeEntered = Completer<void>();
  Completer<void>? modelGate;
  Completer<void>? completeGate;
  bool batch = false;
  bool approved = false;
  bool modelError = false;
  bool completeError = false;
  RemoteRunState? completeState;
  bool refuse = false;
  RemoteRunState state = RemoteRunState.created;

  @override
  Future<RemoteRunState> transition(
    RemoteRunTransition transition,
    RemoteOrchestrationFailure? failure,
  ) async {
    events.add(transition.name);
    if (transition == RemoteRunTransition.complete) {
      if (!completeEntered.isCompleted) completeEntered.complete();
      await completeGate?.future;
      if (completeError) throw StateError('Terminal host authority retired.');
      if (completeState case final rejected?) return state = rejected;
    }
    state = switch (transition) {
      RemoteRunTransition.start => RemoteRunState.running,
      RemoteRunTransition.complete => RemoteRunState.completed,
      RemoteRunTransition.fail => RemoteRunState.failed,
    };
    return state;
  }

  @override
  Future<RemoteStrategyModelTurn> invokeModel(
    RemoteStrategyInferenceMaterial material,
  ) async {
    expect(state, RemoteRunState.running);
    events.add('model');
    materials.add(material.toLocal());
    if (!modelEntered.isCompleted) modelEntered.complete();
    await modelGate?.future;
    if (modelError) throw StateError('Host failed.');
    final output = batch && materials.length == 1
        ? <ModelOutputItem>[
            ModelNativeOutput(
              providerNativeMetadata: ModelNativeEnvelope(
                kind: 'opaque',
                compatibility: {},
                data: {'replay': true},
              ),
            ),
            ModelTextOutput('Batch narration.'),
            for (final call in ['one', 'two'])
              ModelToolProposalOutput(
                ProviderToolProposal(
                  providerCallId: call,
                  alias: 'tool',
                  arguments: {},
                ),
              ),
          ]
        : <ModelOutputItem>[ModelTextOutput('Final answer.')];
    return RemoteStrategyModelTurn.fromLocal(
      StrategyModelTurn.settled(
        tools: _Tools(),
        output: output,
        settlement: refuse
            ? ModelSettlement.refused
            : ModelSettlement.completed,
      ),
      toolSnapshotHandle: 'snapshot',
      proposalHandle: (proposal) => proposal.providerCallId,
    );
  }

  @override
  Future<RemoteStrategyToolResult> processProposal(
    String toolSnapshotHandle,
    String proposalHandle,
  ) async {
    expect(toolSnapshotHandle, 'snapshot');
    expect(state, RemoteRunState.running);
    events.add('proposal-$proposalHandle');
    if (proposalHandle == 'one') {
      state = RemoteRunState.waiting;
      return RemoteStrategyToolResult.fromLocal(const StrategyToolWaiting());
    }
    return RemoteStrategyToolResult.fromLocal(
      StrategyToolContinuation(
        _outcome('two', ToolOutcomeDisposition.policyDenied),
      ),
    );
  }

  @override
  Future<RemoteSemanticModelInput> applyCurrentApproval() async {
    expect(state, RemoteRunState.waiting);
    events.add('approval');
    state = RemoteRunState.running;
    return RemoteSemanticModelInput.fromLocal(
      _outcome(
        'one',
        approved
            ? ToolOutcomeDisposition.success
            : ToolOutcomeDisposition.userRejected,
      ),
    );
  }
}

SemanticToolOutcomeInput _outcome(
  String call,
  ToolOutcomeDisposition disposition,
) => SemanticToolOutcomeInput(
  providerCallId: call,
  outcome: ToolOutcome(
    disposition: disposition,
    effectCertainty: EffectCertainty.knownNotOccurred,
    modelContent: 'Resolved $call.',
  ),
);
