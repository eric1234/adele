import 'dart:async';

import 'package:adele_contract/adele_contract.dart';
import 'package:adele_orchestration/adele_orchestration.dart';
import 'package:adele_orchestration/remote_orchestration.dart';
import 'package:adele_orchestration/remote_orchestration_backend.dart';
import 'package:test/test.dart';

void main() {
  test(
    'async materialization has identity but no operation authority',
    () async {
      int channels = 0;
      late OrchestrationExecutionHost proxy;
      final execution = _Execution();
      final backend = RemoteOrchestrationBackend(
        routes: {
          'route': OrchestrationStrategyContribution(
            strategyId: OrchestrationStrategyId('dev.test.strategy'),
            materialize: (context) async {
              proxy = context.host;
              expect(context.session.taskId.value, 'task');
              expect(proxy.id, RunId('run'));
              expect(proxy.sessionId, SessionId('session'));
              expect(proxy.state, RunState.created);
              expect(
                proxy.validateBinding,
                throwsA(isA<InvalidRunOperation>()),
              );
              expect(proxy.start, throwsA(isA<InvalidRunOperation>()));
              expect(proxy.complete, throwsA(isA<InvalidRunOperation>()));
              expect(
                () => proxy.fail(StateError('no authority')),
                throwsA(isA<InvalidRunOperation>()),
              );
              await expectLater(
                proxy.invokeModel(_material()),
                throwsA(isA<InvalidRunOperation>()),
              );
              await expectLater(
                proxy.processProposal(
                  tools: _Tools(),
                  proposal: _proposal('forged'),
                ),
                throwsA(isA<InvalidRunOperation>()),
              );
              await expectLater(
                proxy.resolveApproval(_approval().toLocal()),
                throwsA(isA<InvalidRunOperation>()),
              );
              await Future<void>.value();
              return execution;
            },
          ),
        },
        hostChannel: (_) {
          channels++;
          throw StateError('materialize must not bind a channel');
        },
      );
      addTearDown(backend.close);
      await expectLater(
        backend.materialize('missing', _session(), 'run'),
        throwsArgumentError,
      );
      await expectLater(
        backend.materialize(
          'route',
          RemoteOrchestrationSession(
            sessionId: 'session',
            taskId: 'task',
            strategyId: 'dev.other.strategy',
          ),
          'run',
        ),
        throwsArgumentError,
      );
      final id = await backend.materialize('route', _session(), 'run');
      expect(backend.executionCount, 1);
      expect(channels, 0);
      expect(proxy.validateBinding, throwsA(isA<InvalidRunOperation>()));
      await backend.release(id);
      await backend.release(id);
      expect(execution.closeCount, 1);
      expect(proxy.state, RunState.created);
      expect(backend.executionCount, 0);
    },
  );

  test(
    'synchronous lifecycle queues flush in order and complete before response',
    () async {
      final fixture = _Fixture();
      addTearDown(fixture.close);
      fixture.host.completeGate = Completer<void>();
      fixture.onStart = (host) async {
        host.start();
        expect(host.state, RunState.running);
        host.validateBinding();
        host.complete();
        expect(host.state, RunState.completed);
        expect(fixture.host.events, isEmpty);
      };
      final id = await fixture.materialize();
      bool returned = false;
      final result = fixture.backend.start(id, 'start-token').then((state) {
        returned = true;
        return state;
      });
      await fixture.host.completeEntered.future;
      expect(returned, isFalse);
      expect(fixture.host.state, RemoteRunState.running);
      expect(fixture.executions.single.closeCount, 0);
      fixture.host.completeGate!.complete();
      expect(await result, RemoteRunState.completed);
      expect(fixture.host.events, ['start', 'complete']);
      expect(fixture.host.state, RemoteRunState.completed);
      expect(fixture.backend.executionCount, 0);
      expect(fixture.executions.single.closeCount, 1);
      expect(
        fixture.proxies.single.validateBinding,
        throwsA(isA<InvalidRunOperation>()),
      );
      expect(fixture.calls.map((call) => call.context), [
        'start-token',
        'start-token',
      ]);
    },
  );

  test(
    'retains exact reconstructed proposals across waiting and fresh approval context',
    () async {
      final fixture = _Fixture();
      addTearDown(fixture.close);
      late StrategyModelTurn turn;
      fixture.host.wait = true;
      fixture.onStart = (host) async {
        host.start();
        turn = await host.invokeModel(_material());
        expect(turn.output.map((item) => item.runtimeType), [
          ModelTextOutput,
          ModelNativeOutput,
          ModelToolProposalOutput,
          ModelToolProposalOutput,
        ]);
        expect(
          (turn.output[1] as ModelNativeOutput).presentation!.compactText,
          'safe',
        );
        expect(
          await host.processProposal(
            tools: turn.tools,
            proposal: (turn.output[2] as ModelToolProposalOutput).proposal,
          ),
          isA<StrategyToolWaiting>(),
        );
        expect(host.state, RunState.waiting);
      };
      fixture.onResume = (host, resolution) async {
        expect(host.state, RunState.waiting);
        final outcome = await host.resolveApproval(resolution);
        expect(
          outcome.outcome.disposition,
          ToolOutcomeDisposition.userRejected,
        );
        expect(host.state, RunState.running);
        fixture.host.wait = false;
        await host.processProposal(
          tools: turn.tools,
          proposal: (turn.output[3] as ModelToolProposalOutput).proposal,
        );
        host.complete();
      };
      final id = await fixture.materialize();
      expect(
        await fixture.backend.start(id, 'first-token'),
        RemoteRunState.waiting,
      );
      expect(fixture.backend.executionCount, 1);
      expect(
        fixture.proxies.single.validateBinding,
        throwsA(isA<InvalidRunOperation>()),
      );
      await expectLater(
        fixture.proxies.single.processProposal(
          tools: turn.tools,
          proposal: (turn.output[3] as ModelToolProposalOutput).proposal,
        ),
        throwsA(isA<InvalidRunOperation>()),
      );
      expect(
        await fixture.backend.resolveApproval(id, _approval(), 'second-token'),
        RemoteRunState.completed,
      );
      expect(fixture.host.events, [
        'start',
        'model',
        'proposal:one',
        'approval',
        'proposal:two',
        'complete',
      ]);
      expect(fixture.host.handles, [
        ('snapshot', 'handle-one'),
        ('snapshot', 'handle-two'),
      ]);
      final approval = fixture.calls.singleWhere(
        (call) =>
            call.method == remoteOrchestrationHostServiceApplyCurrentApprovalId,
      );
      expect(approval.context, 'second-token');
      expect(approval.payload, isEmpty);
      expect(
        fixture.calls.where((call) => call.context == 'first-token'),
        hasLength(3),
      );
      expect(
        fixture.calls.where((call) => call.context == 'second-token'),
        hasLength(3),
      );
      expect(fixture.backend.executionCount, 0);
    },
  );

  for (final attack in [
    'equivalent proposal',
    'foreign snapshot',
    'consumed proposal',
  ]) {
    test('rejects $attack without forwarding forged authority', () async {
      final fixture = _Fixture();
      addTearDown(fixture.close);
      fixture.onStart = (host) async {
        host.start();
        final turn = await host.invokeModel(_material());
        final proposal = (turn.output[2] as ModelToolProposalOutput).proposal;
        if (attack == 'consumed proposal') {
          await host.processProposal(tools: turn.tools, proposal: proposal);
        }
        try {
          await host.processProposal(
            tools: attack == 'foreign snapshot' ? _Tools() : turn.tools,
            proposal: attack == 'equivalent proposal'
                ? ProviderToolProposal(
                    providerCallId: proposal.providerCallId,
                    alias: proposal.alias,
                    arguments: proposal.arguments,
                  )
                : proposal,
          );
          fail('Forged proposal was accepted.');
        } on InvalidRunOperation {
          expect(host.validateBinding, throwsA(isA<InvalidRunOperation>()));
          expect(host.complete, throwsA(isA<InvalidRunOperation>()));
          rethrow;
        }
      };
      final id = await fixture.materialize();
      await expectLater(
        fixture.backend.start(id, 'token'),
        throwsA(isA<InvalidRunOperation>()),
      );
      expect(
        fixture.host.handles,
        hasLength(attack == 'consumed proposal' ? 1 : 0),
      );
      expect(fixture.backend.executionCount, 0);
      expect(fixture.executions.single.closeCount, 1);
    });
  }

  for (final attack in [
    'equivalent approval',
    'changed approval',
    'repeated approval',
  ]) {
    test('rejects $attack and consumes current approval before RPC', () async {
      final fixture = _Fixture();
      addTearDown(fixture.close);
      fixture.waitOnStart();
      fixture.onResume = (host, resolution) async {
        if (attack == 'repeated approval') {
          await host.resolveApproval(resolution);
          await host.resolveApproval(resolution);
        } else {
          await host.resolveApproval(
            ToolApprovalResolution(
              interruptionId: resolution.interruptionId,
              toolInvocationId: resolution.toolInvocationId,
              approved: attack == 'changed approval'
                  ? !resolution.approved
                  : resolution.approved,
            ),
          );
        }
      };
      final id = await fixture.materialize();
      await fixture.backend.start(id, 'start');
      await expectLater(
        fixture.backend.resolveApproval(id, _approval(), 'resume'),
        throwsA(isA<InvalidRunOperation>()),
      );
      expect(
        fixture.host.events.where((event) => event == 'approval'),
        hasLength(attack == 'repeated approval' ? 1 : 0),
      );
      expect(fixture.backend.executionCount, 0);
    });
  }

  for (final primary in <Object>[
    const _RpcFailure(),
    const AdeleProtocolException('malformed orchestration response'),
  ]) {
    test(
      '${primary.runtimeType} from orchestration RPC poisons mirror, not semantic failure',
      () async {
        final fixture = _Fixture();
        addTearDown(fixture.close);
        fixture.rpcFailure = primary;
        fixture.failMethod = remoteOrchestrationHostServiceInvokeModelId;
        fixture.closeFailure = StateError('secondary cleanup failure');
        fixture.onStart = (host) async {
          host.start();
          try {
            await host.invokeModel(_material());
          } on Object catch (error) {
            expect(error, same(primary));
            expect(host.validateBinding, throwsA(same(primary)));
            expect(() => host.fail(error), throwsA(same(primary)));
            expect(host.complete, throwsA(same(primary)));
            // Even a strategy swallowing the RPC failure cannot return success.
          }
        };
        final id = await fixture.materialize();
        await expectLater(
          fixture.backend.start(id, 'token'),
          throwsA(same(primary)),
        );
        expect(fixture.host.events, ['start']);
        expect(
          fixture.calls.where((call) => call.payload['transition'] == 'fail'),
          isEmpty,
        );
        expect(fixture.backend.executionCount, 1);
        await expectLater(
          fixture.backend.release(id),
          throwsA(same(fixture.closeFailure)),
        );
        expect(fixture.backend.executionCount, 0);
        expect(fixture.executions.single.closeCount, 1);
      },
    );
  }

  for (final state in [RemoteRunState.failed, RemoteRunState.completed]) {
    for (final resume in [false, true]) {
      test(
        '$state ${resume ? 'resume' : 'start'} preserves terminal result when close fails',
        () async {
          final fixture = _Fixture();
          addTearDown(fixture.close);
          final primary = StateError('primary Run failure');
          final cleanup = StateError('secondary cleanup failure');
          fixture.closeFailure = cleanup;
          void finish(OrchestrationExecutionHost host) {
            if (state == RemoteRunState.failed) {
              host.fail(primary);
            } else {
              host.complete();
            }
          }

          if (resume) {
            fixture.waitOnStart();
            fixture.onResume = (host, resolution) async {
              await host.resolveApproval(resolution);
              finish(host);
            };
          } else {
            fixture.onStart = (host) async {
              host.start();
              finish(host);
            };
          }
          final id = await fixture.materialize();
          if (resume) {
            expect(
              await fixture.backend.start(id, 'start'),
              RemoteRunState.waiting,
            );
          }
          expect(
            await (resume
                ? fixture.backend.resolveApproval(id, _approval(), 'resume')
                : fixture.backend.start(id, 'start')),
            state,
          );
          expect(fixture.host.state, state);
          expect(
            fixture.host.failure?.message,
            state == RemoteRunState.failed ? primary.toString() : null,
          );
          expect(fixture.executions.single.closeCount, 1);
          expect(fixture.backend.executionCount, 1);
          expect(
            fixture.proxies.single.validateBinding,
            throwsA(isA<InvalidRunOperation>()),
          );
          await expectLater(
            fixture.backend.start(id, 'cannot-reenter'),
            throwsA(isA<InvalidRunOperation>()),
          );
          final events = fixture.host.events.toList();
          await expectLater(
            fixture.backend.release(id),
            throwsA(same(cleanup)),
          );
          expect(fixture.backend.executionCount, 0);
          await fixture.backend.release(id);
          expect(fixture.executions.single.closeCount, 1);
          expect(fixture.host.events, events);
          expect(fixture.host.state, state);
        },
      );
    }
  }

  for (final modelFailure in <Object>[
    StateError('intentional model failure'),
    const _RpcFailure(),
    const AdeleProtocolException('malformed provider response'),
  ]) {
    test(
      'collected ${modelFailure.runtimeType} reaches strategy and flushes host failure',
      () async {
        final fixture = _Fixture();
        addTearDown(fixture.close);
        fixture.host.modelFailure = modelFailure;
        fixture.onStart = (host) async {
          host.start();
          final turn = await host.invokeModel(_material());
          expect(turn.failure, isA<RemoteStrategyFailure>());
          expect(turn.output, hasLength(4));
          host.validateBinding();
          host.fail(turn.failure!);
          expect(host.state, RunState.failed);
        };
        final id = await fixture.materialize();
        expect(await fixture.backend.start(id, 'token'), RemoteRunState.failed);
        expect(fixture.host.state, RemoteRunState.failed);
        expect(fixture.host.failure!.code, modelFailure.runtimeType.toString());
        expect(fixture.host.events, ['start', 'model', 'fail']);
        expect(fixture.backend.executionCount, 0);
      },
    );
  }

  test(
    'queued intentional failure settles even when native execution throws',
    () async {
      final fixture = _Fixture();
      addTearDown(fixture.close);
      final primary = StateError('strategy failed');
      fixture.closeFailure = StateError('secondary cleanup failure');
      fixture.onStart = (host) async {
        host.start();
        host.fail(primary);
        throw primary;
      };
      final id = await fixture.materialize();
      await expectLater(
        fixture.backend.start(id, 'token'),
        throwsA(same(primary)),
      );
      expect(fixture.host.events, ['start', 'fail']);
      expect(fixture.host.state, RemoteRunState.failed);
      expect(fixture.backend.executionCount, 1);
      await expectLater(
        fixture.backend.release(id),
        throwsA(same(fixture.closeFailure)),
      );
      expect(fixture.backend.executionCount, 0);
      expect(fixture.executions.single.closeCount, 1);
    },
  );

  test(
    'transition mismatch fails instead of trusting the optimistic mirror',
    () async {
      final fixture = _Fixture();
      addTearDown(fixture.close);
      fixture.host.wrongTransition = true;
      fixture.onStart = (host) async {
        host.start();
        await host.invokeModel(_material());
      };
      final id = await fixture.materialize();
      await expectLater(
        fixture.backend.start(id, 'token'),
        throwsA(isA<AdeleProtocolException>()),
      );
      expect(fixture.host.events, ['start']);
      expect(fixture.backend.executionCount, 0);
    },
  );

  test(
    'release and close abandon waiting without approval or lifecycle effects',
    () async {
      final fixture = _Fixture();
      addTearDown(fixture.close);
      fixture.waitOnStart();
      final id = await fixture.materialize();
      await fixture.backend.start(id, 'token');
      final before = fixture.host.events.toList();
      await Future.wait([
        fixture.backend.release(id),
        fixture.backend.release(id),
      ]);
      await fixture.backend.close();
      expect(fixture.host.events, before);
      expect(fixture.host.state, RemoteRunState.waiting);
      expect(fixture.executions.single.closeCount, 1);
      expect(fixture.backend.executionCount, 0);
      await expectLater(
        fixture.backend.materialize('route', _session(), 'other'),
        throwsStateError,
      );
    },
  );

  test(
    'overlapping advances are denied while release drains the active operation',
    () async {
      final fixture = _Fixture();
      addTearDown(fixture.close);
      fixture.host.modelGate = Completer<void>();
      fixture.onStart = (host) async {
        host.start();
        await host.invokeModel(_material());
        host.complete();
      };
      final id = await fixture.materialize();
      final advance = fixture.backend.start(id, 'token');
      await fixture.host.modelEntered.future;
      await expectLater(
        fixture.backend.start(id, 'overlap'),
        throwsA(isA<InvalidRunOperation>()),
      );
      expect(fixture.executions.single.closeCount, 0);
      bool released = false;
      final release = fixture.backend.release(id).then((_) {
        released = true;
      });
      await Future<void>.value();
      expect(released, isFalse);
      await expectLater(
        fixture.backend.start(id, 'during-release'),
        throwsA(isA<InvalidRunOperation>()),
      );
      fixture.host.modelGate!.complete();
      expect(await advance, RemoteRunState.completed);
      await release;
      expect(fixture.executions.single.closeCount, 1);
      expect(fixture.backend.executionCount, 0);
      expect(fixture.contexts, ['token']);
    },
  );

  test(
    'close attempts every execution and shares first cleanup failure',
    () async {
      final fixture = _Fixture();
      final failure = StateError('cleanup');
      fixture.closeFailure = failure;
      await fixture.materialize();
      await fixture.materialize();
      final closing = fixture.backend.close();
      expect(fixture.backend.close(), same(closing));
      await expectLater(closing, throwsA(same(failure)));
      expect(fixture.executions.map((execution) => execution.closeCount), [
        1,
        1,
      ]);
      expect(fixture.backend.executionCount, 0);
      expect(fixture.host.events, isEmpty);
      await fixture.dispatcher.close();
    },
  );

  test(
    'close racing async materialization drains and closes the late execution',
    () async {
      final entered = Completer<void>();
      final materialized = Completer<OrchestrationExecution>();
      final closeGate = Completer<void>();
      final execution = _Execution()..onClose = () => closeGate.future;
      final backend = RemoteOrchestrationBackend(
        routes: {
          'route': OrchestrationStrategyContribution(
            strategyId: OrchestrationStrategyId('dev.test.strategy'),
            materialize: (context) {
              expect(context.host.start, throwsA(isA<InvalidRunOperation>()));
              entered.complete();
              return materialized.future;
            },
          ),
        },
        hostChannel: (_) => throw StateError('no authority'),
      );
      final pending = backend.materialize('route', _session(), 'run');
      final rejected = expectLater(pending, throwsStateError);
      await entered.future;
      bool closed = false;
      final closing = backend.close().then((_) {
        closed = true;
      });
      materialized.complete(execution);
      await execution.closeEntered.future;
      expect(closed, isFalse);
      expect(backend.executionCount, 0);
      closeGate.complete();
      await rejected;
      await closing;
      expect(execution.closeCount, 1);
      expect(backend.executionCount, 0);
    },
  );

  test(
    'detached host work is revoked then drained before failed advance returns',
    () async {
      final fixture = _Fixture();
      addTearDown(fixture.close);
      fixture.host.modelGate = Completer<void>();
      Object? detachedFailure;
      fixture.onStart = (host) async {
        host.start();
        unawaited(
          host
              .invokeModel(_material())
              .then<void>(
                (_) {
                  fail('Late model result escaped.');
                },
                onError: (Object error) {
                  detachedFailure = error;
                },
              ),
        );
        await fixture.host.modelEntered.future;
      };
      final id = await fixture.materialize();
      bool returned = false;
      final result = fixture.backend.start(id, 'token');
      final rejected = expectLater(
        result.whenComplete(() {
          returned = true;
        }),
        throwsA(isA<InvalidRunOperation>()),
      );
      await fixture.host.modelEntered.future;
      // Let the native strategy return and the backend revoke its operation.
      await Future<void>.delayed(Duration.zero);
      expect(returned, isFalse);
      expect(
        fixture.proxies.single.validateBinding,
        throwsA(isA<InvalidRunOperation>()),
      );
      fixture.host.modelGate!.complete();
      await rejected;
      expect(detachedFailure, isA<InvalidRunOperation>());
      expect(fixture.executions.single.closeCount, 1);
      expect(fixture.backend.executionCount, 0);
    },
  );

  test('failed channel acquisition releases only its execution', () async {
    final fixture = _Fixture();
    addTearDown(fixture.close);
    fixture.channelFailure = StateError('cannot bind');
    final first = await fixture.materialize();
    final second = await fixture.materialize();
    await expectLater(
      fixture.backend.start(first, 'token'),
      throwsA(same(fixture.channelFailure)),
    );
    expect(fixture.backend.executionCount, 1);
    expect(fixture.executions.first.closeCount, 1);
    expect(fixture.executions.last.closeCount, 0);
    await fixture.backend.release(second);
  });

  test('repeated execution lifetimes do not retain closed resources', () async {
    final fixture = _Fixture();
    addTearDown(fixture.close);
    final ids = <String>{};
    for (int index = 0; index < 25; index++) {
      final id = await fixture.materialize();
      expect(ids.add(id), isTrue);
      await fixture.backend.release(id);
      expect(fixture.backend.executionCount, 0);
    }
    expect(
      fixture.executions.every((execution) => execution.closeCount == 1),
      isTrue,
    );
    expect(fixture.host.events, isEmpty);
  });
}

RemoteOrchestrationSession _session() => RemoteOrchestrationSession(
  sessionId: 'session',
  taskId: 'task',
  strategyId: 'dev.test.strategy',
);
RemoteApprovalResolution _approval() => RemoteApprovalResolution(
  interruptionId: 'interrupt',
  toolInvocationId: 'invocation',
  approved: false,
);
StrategyInferenceMaterial _material() => StrategyInferenceMaterial(
  instructions: 'exact',
  input: [
    SemanticMessageInput(role: SemanticMessageRole.user, content: 'task'),
  ],
);
ProviderToolProposal _proposal(String id) => ProviderToolProposal(
  providerCallId: id,
  alias: 'tool',
  arguments: {'id': id},
);
SemanticToolOutcomeInput _outcome() => SemanticToolOutcomeInput(
  providerCallId: 'one',
  outcome: ToolOutcome(
    disposition: ToolOutcomeDisposition.userRejected,
    effectCertainty: EffectCertainty.knownNotOccurred,
    modelContent: 'rejected',
  ),
);

final class _Tools implements StrategyToolSnapshot {}

final class _Fixture {
  _Fixture() {
    dispatcher = RemoteOrchestrationHostServiceDispatcher(host);
    backend = RemoteOrchestrationBackend(
      routes: {
        'route': OrchestrationStrategyContribution(
          strategyId: OrchestrationStrategyId('dev.test.strategy'),
          materialize: (context) {
            proxies.add(context.host);
            final execution = _Execution()
              ..onStart = (() => onStart(context.host))
              ..onResume = ((resolution) => onResume(context.host, resolution))
              ..onClose = () async {
                if (closeFailure != null) throw closeFailure!;
              };
            executions.add(execution);
            return execution;
          },
        ),
      },
      hostChannel: (context) {
        if (channelFailure != null) throw channelFailure!;
        contexts.add(context);
        return _Channel(this, context);
      },
    );
  }
  final _Host host = _Host();
  late final RemoteOrchestrationBackend backend;
  late final RemoteOrchestrationHostServiceDispatcher dispatcher;
  final List<_Execution> executions = [];
  final List<OrchestrationExecutionHost> proxies = [];
  final List<String> contexts = [];
  final List<({String context, String method, Map<String, Object?> payload})>
  calls = [];
  Object? closeFailure;
  Object? channelFailure;
  Object? rpcFailure;
  String? failMethod;
  Future<void> Function(OrchestrationExecutionHost) onStart = (host) async {
    host.start();
    host.complete();
  };
  Future<void> Function(OrchestrationExecutionHost, ToolApprovalResolution)
  onResume = (host, resolution) async {
    await host.resolveApproval(resolution);
    host.complete();
  };

  void waitOnStart() {
    host.wait = true;
    onStart = (host) async {
      host.start();
      final turn = await host.invokeModel(_material());
      await host.processProposal(
        tools: turn.tools,
        proposal: (turn.output[2] as ModelToolProposalOutput).proposal,
      );
    };
  }

  Future<String> materialize() =>
      backend.materialize('route', _session(), 'run');
  Future<void> close() async {
    await backend.close();
    await dispatcher.close();
  }
}

final class _Execution implements OrchestrationExecution {
  Future<void> Function() onStart = () async {};
  Future<void> Function(ToolApprovalResolution) onResume = (_) async {};
  Future<void> Function() onClose = () async {};
  int closeCount = 0;
  final closeEntered = Completer<void>();
  @override
  Future<void> start() => onStart();
  @override
  Future<void> resolveApproval(ToolApprovalResolution resolution) =>
      onResume(resolution);
  @override
  Future<void> close() async {
    closeCount++;
    if (!closeEntered.isCompleted) closeEntered.complete();
    await onClose();
  }
}

final class _Host implements RemoteOrchestrationHostService {
  final List<String> events = [];
  final List<(String, String)> handles = [];
  final modelEntered = Completer<void>();
  final completeEntered = Completer<void>();
  Completer<void>? modelGate;
  Completer<void>? completeGate;
  RemoteRunState state = RemoteRunState.created;
  RemoteOrchestrationFailure? failure;
  Object? modelFailure;
  bool wait = false;
  bool wrongTransition = false;

  @override
  Future<RemoteRunState> transition(
    RemoteRunTransition transition,
    RemoteOrchestrationFailure? failure,
  ) async {
    events.add(transition.name);
    if (transition == RemoteRunTransition.complete) {
      if (!completeEntered.isCompleted) completeEntered.complete();
      await completeGate?.future;
    }
    this.failure = failure;
    state = switch (transition) {
      RemoteRunTransition.start => RemoteRunState.running,
      RemoteRunTransition.complete => RemoteRunState.completed,
      RemoteRunTransition.fail => RemoteRunState.failed,
    };
    return wrongTransition ? RemoteRunState.created : state;
  }

  @override
  Future<RemoteStrategyModelTurn> invokeModel(
    RemoteStrategyInferenceMaterial material,
  ) async {
    expect(state, RemoteRunState.running);
    expect(material.toLocal().instructions, 'exact');
    events.add('model');
    if (!modelEntered.isCompleted) modelEntered.complete();
    await modelGate?.future;
    final output = <ModelOutputItem>[
      ModelTextOutput('narration'),
      ModelNativeOutput(
        providerNativeMetadata: ModelNativeEnvelope(
          kind: 'native',
          compatibility: {},
          data: {'opaque': true},
        ),
        presentation: ModelNativePresentation(
          kind: 'safe',
          compactText: 'safe',
          data: {},
        ),
      ),
      ModelToolProposalOutput(_proposal('one')),
      ModelToolProposalOutput(_proposal('two')),
    ];
    return RemoteStrategyModelTurn.fromLocal(
      modelFailure == null
          ? StrategyModelTurn.settled(tools: _Tools(), output: output)
          : StrategyModelTurn.failed(
              tools: _Tools(),
              output: output,
              error: modelFailure!,
            ),
      toolSnapshotHandle: 'snapshot',
      proposalHandle: (proposal) => 'handle-${proposal.providerCallId}',
    );
  }

  @override
  Future<RemoteStrategyToolResult> processProposal(
    String toolSnapshotHandle,
    String proposalHandle,
  ) async {
    expect(state, RemoteRunState.running);
    handles.add((toolSnapshotHandle, proposalHandle));
    events.add('proposal:${proposalHandle.substring('handle-'.length)}');
    if (wait) state = RemoteRunState.waiting;
    return RemoteStrategyToolResult.fromLocal(
      wait ? const StrategyToolWaiting() : StrategyToolContinuation(_outcome()),
    );
  }

  @override
  Future<RemoteSemanticModelInput> applyCurrentApproval() async {
    expect(state, RemoteRunState.waiting);
    events.add('approval');
    state = RemoteRunState.running;
    return RemoteSemanticModelInput.fromLocal(_outcome());
  }
}

final class _Channel implements AdeleRequestChannel {
  _Channel(this.fixture, this.context);
  final _Fixture fixture;
  final String context;
  @override
  Future<Object?> request(String method, Map<String, Object?> payload) async {
    fixture.calls.add((context: context, method: method, payload: payload));
    if (method == fixture.failMethod) throw fixture.rpcFailure!;
    final response = await fixture.dispatcher.dispatch({
      'kind': 'request',
      'requestId': 1,
      'method': method,
      'payload': payload,
    });
    if (response['ok'] != true) {
      throw StateError('Host dispatcher failed: ${response['error']}');
    }
    return response['payload'];
  }
}

final class _RpcFailure implements AdeleRemoteFailure {
  const _RpcFailure();
  @override
  String get code => 'host_invocation_closed';
  @override
  String get message => 'No authority';
  @override
  String? get declaredFailureType => null;
  @override
  Map<String, Object?> get details => const {};
}
