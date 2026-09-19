@Timeout(Duration(minutes: 2))
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:adele_capabilities/adele_capabilities.dart';
import 'package:adele_contract/adele_contract.dart';
import 'package:adele_desktop/core/remote_inference_context_host.dart';
import 'package:adele_orchestration/adele_orchestration.dart';
import 'package:adele_plugin_api/adele_plugin_api.dart';
import 'package:adele_product/adele_product.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plugin_builder/plugin_builder.dart';
import 'package:plugin_runtime/plugin_runtime.dart';

const _pluginId = 'dev.adele.test.orchestration-attack';
const _strategyId = 'dev.adele.test.orchestration-attack.strategy';
const _bound = Duration(seconds: 10);
final _capability = CapabilityKey(
  id: CapabilityId('dev.adele.test.orchestration-attack.capability'),
  majorVersion: 1,
);

void main() {
  late File hostArtifact;
  late File probeArtifact;
  late String aotRuntime;

  setUpAll(() async {
    final artifacts = await Directory.systemTemp.createTemp(
      'adele-orch-attack-',
    );
    addTearDown(() => artifacts.delete(recursive: true));
    final dart = _dartExecutable();
    aotRuntime = File.fromUri(
      File(dart).parent.uri.resolve(
        Platform.isWindows ? 'dartaotruntime.exe' : 'dartaotruntime',
      ),
    ).path;
    hostArtifact = File.fromUri(artifacts.uri.resolve('host.aot'));
    probeArtifact = File.fromUri(artifacts.uri.resolve('attack.aot'));
    for (final target in [
      (
        entrypoint: 'packages/plugin_backend_host/bin/adele_backend_host.dart',
        artifact: hostArtifact,
      ),
      (
        entrypoint:
            'app/test/core/fixtures/remote_orchestration_attack_probe.dart',
        artifact: probeArtifact,
      ),
    ]) {
      await compileAotSnapshot(
        dartExecutable: dart,
        workingDirectory: Directory.current.parent,
        entrypoint: target.entrypoint,
        artifact: target.artifact,
        stage: 'remote-orchestration-attack-test',
      );
    }
  });

  late PluginBackendHost backend;
  late CapabilityRegistry capabilities;
  late ExtensionRegistry extensions;

  setUp(() async {
    backend = await PluginBackendHost.start(
      dartaotruntimeExecutable: aotRuntime,
      hostArtifactPath: hostArtifact.path,
    );
    addTearDown(backend.close);
    capabilities = CapabilityRegistry();
    extensions = ExtensionRegistry();
  });

  Future<PluginBackendActivation> activate([
    Map<String, Object?> options = const {},
  ]) async {
    final connection = await backend.startPlugin(
      pluginId: _pluginId,
      artifactUri: probeArtifact.uri,
      arguments: [jsonEncode(options)],
    );
    addTearDown(connection.close);
    final activation = await PluginBackendActivation.registerAdvertised(
      connection: connection,
      capabilities: capabilities,
      extensions: extensions,
      adapters: createRemoteExtensionAdapters(),
    );
    addTearDown(activation.close);
    return activation;
  }

  Future<OrchestrationExecution> materialize(_RecordingHost host) async {
    // These are adapter-only attacks. Canonical lifecycle/kernel execution is
    // exercised by the separate remote orchestration integration suite.
    final execution = await extensions
        .discover(orchestrationStrategyContributions)
        .single
        .value
        .materialize(
          OrchestrationStrategyHostContext(
            session: Session(
              id: host.sessionId,
              taskId: TaskId('attack-task'),
              strategyId: OrchestrationStrategyId(_strategyId),
            ),
            host: host,
          ),
        );
    addTearDown(execution.close);
    return execution;
  }

  for (final attack in [
    'fabricated snapshot',
    'fabricated proposal',
    'cross snapshot',
  ]) {
    test(
      '$attack never reaches the native host or consumes a valid proposal',
      () async {
        final probe = await activate();
        final host = _RecordingHost();
        final execution = await materialize(host);
        final advancing = execution.start();
        final active = await _ready(probe.connection, 'execution-0/start');
        final turns = active['turns'] as List;
        final first = Map<String, Object?>.from(turns[0] as Map);
        final second = Map<String, Object?>.from(turns[1] as Map);
        _expectDenied(
          await _proposal(probe.connection, active, {
            'snapshot': attack == 'fabricated snapshot'
                ? 'invented'
                : first['snapshot'],
            'proposal': switch (attack) {
              'fabricated proposal' => 'invented',
              'cross snapshot' => second['proposal'],
              _ => first['proposal'],
            },
          }),
        );
        expect(host.processed, isEmpty);
        for (var index = 0; index < turns.length; index++) {
          expect(
            await _proposal(probe.connection, active, turns[index] as Map),
            {'ok': true},
          );
          final observed = host.processed[index];
          expect(observed.tools, same(host.turns[index].tools));
          expect(
            observed.proposal,
            same(
              (host.turns[index].output.single as ModelToolProposalOutput)
                  .proposal,
            ),
          );
        }
        // The two proposals are value-equivalent, but not interchangeable objects.
        expect(
          host.processed[0].proposal,
          isNot(same(host.processed[1].proposal)),
        );
        _expectDenied(await _proposal(probe.connection, active, first));
        expect(host.processed, hasLength(2));
        await _finish(probe.connection, 'execution-0/start');
        await advancing;
        expect(host.state, RunState.completed);
        expect(await _control(probe.connection, 'released'), ['execution-0']);
      },
    );
  }

  for (final source in [
    'live execution',
    'released execution',
    'replacement generation',
  ]) {
    test(
      'rejects handles from $source even with matching Session and Run IDs',
      () async {
        final original = await activate();
        final oldHost = _RecordingHost()..waitForApproval = true;
        final oldExecution = await materialize(oldHost);
        final starting = oldExecution.start();
        final old = await _ready(original.connection, 'execution-0/start');
        final oldTurns = old['turns'] as List;
        expect(
          await _proposal(original.connection, old, oldTurns.first as Map),
          {'ok': true},
        );
        await _finish(original.connection, 'execution-0/start', 'waiting');
        await starting;

        var current = original;
        var executionId = 'execution-1';
        if (source == 'released execution') {
          await oldExecution.close();
          await oldExecution.close();
        } else if (source == 'replacement generation') {
          await original.retire();
        }
        if (source != 'live execution') {
          expect(await _control(original.connection, 'released'), [
            'execution-0',
          ]);
          expect(oldHost.state, RunState.waiting);
          expect(oldHost.approvals, isEmpty);
          await expectLater(
            oldExecution.start(),
            throwsA(
              source == 'replacement generation'
                  ? isA<StaleExtensionBinding>()
                  : isA<InvalidRunOperation>(),
            ),
          );
        }
        if (source == 'replacement generation') {
          await original.connection.close();
          current = await activate();
          executionId =
              'execution-0'; // The new AOT isolate intentionally reuses it.
        }
        final host = _RecordingHost();
        final execution = await materialize(host);
        final advancing = execution.start();
        final active = await _ready(current.connection, '$executionId/start');
        final fresh = (active['turns'] as List).first as Map;
        final foreign =
            oldTurns.last as Map; // Never consumed in the source Run.
        expect(fresh['snapshot'], isNot(foreign['snapshot']));
        expect(fresh['proposal'], isNot(foreign['proposal']));
        for (final handles in [
          foreign,
          {'snapshot': fresh['snapshot'], 'proposal': foreign['proposal']},
          {'snapshot': foreign['snapshot'], 'proposal': fresh['proposal']},
        ]) {
          _expectDenied(await _proposal(current.connection, active, handles));
        }
        _expectDenied(
          await _proposal(current.connection, old, foreign),
          'host_invocation_unavailable',
        );
        expect(host.processed, isEmpty);
        expect(oldHost.processed, hasLength(1));
        expect(await _proposal(current.connection, active, fresh), {
          'ok': true,
        });
        expect(host.processed.single.tools, same(host.turns.first.tools));
        expect(
          host.processed.single.proposal,
          same(
            (host.turns.first.output.single as ModelToolProposalOutput)
                .proposal,
          ),
        );
        await _finish(current.connection, '$executionId/start');
        await advancing;
        expect(host.state, RunState.completed);
      },
    );
  }

  for (final waiting in [false, true]) {
    test('failed release retires only its generation without changing '
        '${waiting ? 'waiting' : 'terminal'} evidence', () async {
      final probe = await activate();
      final host = _RecordingHost()..waitForApproval = waiting;
      final execution = await materialize(host);
      final starting = execution.start();
      final active = await _ready(probe.connection, 'execution-0/start');
      if (waiting) {
        await _proposal(
          probe.connection,
          active,
          (active['turns'] as List).first as Map,
        );
      }
      await _control(probe.connection, 'failRelease');
      await _finish(
        probe.connection,
        'execution-0/start',
        waiting ? 'waiting' : 'complete',
      );
      await starting;
      await execution.close();
      await probe.retire();
      expect(probe.connection.isClosed, isTrue);
      expect(backend.isClosed, isFalse);
      expect(host.state, waiting ? RunState.waiting : RunState.completed);
      expect(host.approvals, isEmpty);
      expect(extensions.discover(orchestrationStrategyContributions), isEmpty);
    });
  }

  for (final fails in [false, true]) {
    test('retirement joins an already-started release, including '
        '${fails ? 'failed' : 'successful'} acknowledgement', () async {
      final probe = await activate();
      final host = _RecordingHost()..waitForApproval = true;
      final execution = await materialize(host);
      final starting = execution.start();
      final active = await _ready(probe.connection, 'execution-0/start');
      await _proposal(
        probe.connection,
        active,
        (active['turns'] as List).first as Map,
      );
      await _finish(probe.connection, 'execution-0/start', 'waiting');
      await starting;
      await _control(probe.connection, 'holdRelease');
      if (fails) await _control(probe.connection, 'failRelease');
      var closed = false;
      final closing = execution.close().then((_) => closed = true);
      await _control(probe.connection, 'releaseReady');
      var retired = false;
      final retiring = probe.retire().then((_) => retired = true);
      expect(extensions.discover(orchestrationStrategyContributions), isEmpty);
      // Control roundtrip gives an incorrectly detached cleanup time to settle.
      await _control(probe.connection, 'released');
      expect(closed, isFalse);
      expect(retired, isFalse);
      await _control(probe.connection, 'releaseContinue');
      await closing;
      await retiring;
      expect(host.state, RunState.waiting);
      expect(host.approvals, isEmpty);
      expect(probe.connection.isClosed, fails);
      expect(backend.isClosed, isFalse);
    });
  }

  for (final approved in [false, true]) {
    test(
      'resume applies only the exact host resolution once (approved: $approved)',
      () async {
        final probe = await activate();
        final host = _RecordingHost()..waitForApproval = true;
        final execution = await materialize(host);
        final starting = execution.start();
        final start = await _ready(probe.connection, 'execution-0/start');
        _expectDenied(
          await _control(probe.connection, 'approval', {
            'context': start['context'],
          }),
        );
        expect(host.approvals, isEmpty);
        final handles = (start['turns'] as List).first as Map;
        expect(await _proposal(probe.connection, start, handles), {'ok': true});
        await _finish(probe.connection, 'execution-0/start', 'waiting');
        await starting;
        expect(host.state, RunState.waiting);
        expect(await _control(probe.connection, 'released'), isEmpty);
        _expectDenied(
          await _control(probe.connection, 'approval', {
            'context': start['context'],
          }),
          'host_invocation_unavailable',
        );

        final resolution = ToolApprovalResolution(
          interruptionId: RunInterruptionId('approval'),
          toolInvocationId: ToolInvocationId('invocation'),
          approved: approved,
        );
        final resuming = execution.resolveApproval(resolution);
        final resume = await _ready(probe.connection, 'execution-0/resume');
        expect(resume['context'], isNot(start['context']));
        _expectDenied(
          await _control(probe.connection, 'approval', {
            'context': start['context'],
          }),
          'host_invocation_unavailable',
        );
        _expectDenied(
          await _control(probe.connection, 'forgedApproval', {
            'context': resume['context'],
            'resolution': {
              'interruptionId': resolution.interruptionId.value,
              'toolInvocationId': resolution.toolInvocationId.value,
              'approved': !approved,
            },
          }),
          'invalid_request',
        );
        expect(host.approvals, isEmpty);
        expect(
          await _control(probe.connection, 'approval', {
            'context': resume['context'],
          }),
          {'ok': true},
        );
        expect(host.approvals.single, same(resolution));
        _expectDenied(
          await _control(probe.connection, 'approval', {
            'context': resume['context'],
          }),
        );
        _expectDenied(await _proposal(probe.connection, resume, handles));
        expect(host.approvals, hasLength(1));
        expect(host.processed, hasLength(1));
        await _finish(probe.connection, 'execution-0/resume');
        await resuming;
        _expectDenied(
          await _control(probe.connection, 'approval', {
            'context': resume['context'],
          }),
          'host_invocation_unavailable',
        );
        expect(host.state, RunState.completed);
        expect(await _control(probe.connection, 'released'), ['execution-0']);
      },
    );
  }

  test(
    'detached reverse work is revoked and drained before caller failure, preserving evidence',
    () async {
      final probe = await activate();
      final host = _RecordingHost()..settleProposal = Completer<void>();
      final execution = await materialize(host);
      addTearDown(() {
        if (!host.settleProposal!.isCompleted) host.settleProposal!.complete();
      });
      // Failure is caller-owned, as in SessionOrchestrationRun. The adapter must
      // not deliver it until the already-entered host operation has settled.
      final advancing = execution.start().catchError((Object error) {
        host.fail(error);
        throw error;
      });
      final failed = expectLater(
        advancing,
        throwsA(isA<AdeleProtocolException>()),
      );
      final active = await _ready(probe.connection, 'execution-0/start');
      final turns = active['turns'] as List;
      final detached = _proposal(probe.connection, active, turns.first as Map);
      await host.proposalEntered.future.timeout(_bound);
      // The generated dispatcher serializes ordinary calls. Revocation must
      // reject this queued call as well as the detached, already-entered one.
      final queued = _proposal(probe.connection, active, turns.last as Map);
      await _finish(probe.connection, 'execution-0/start', 'detached');
      _expectDenied(await detached, 'host_invocation_unavailable');
      _expectDenied(await queued, 'host_invocation_unavailable');
      _expectDenied(
        await _proposal(probe.connection, active, turns.last as Map),
        'host_invocation_unavailable',
      );
      expect(host.state, RunState.running);
      expect(host.failure, isNull);
      expect(host.evidence, isEmpty);
      expect(host.observedOutcomes, isEmpty);
      expect(await _control(probe.connection, 'released'), isEmpty);
      host.settleProposal!.complete();
      await failed.timeout(_bound);
      expect(host.state, RunState.failed);
      expect(host.failure, isA<AdeleProtocolException>());
      expect(host.evidence, ['proposal.settled', 'run.failed']);
      expect(host.processed, hasLength(1));
      expect(host.observedOutcomes.single, same(host.outcome));
      expect(
        host.observedOutcomes.single.effectCertainty,
        EffectCertainty.knownOccurred,
      );
      expect(host.observedOutcomes.single.hostData, {'evidence': 'retained'});
      expect(await _control(probe.connection, 'released'), ['execution-0']);
      expect(probe.connection.isClosed, isFalse);
    },
  );

  for (final invalid in <String, Map<String, Object?>>{
    'unknown metadata': {
      'metadata': {
        'strategyId': _strategyId,
        'routeId': 'attack-route',
        'authority': true,
      },
    },
    'blank strategy': {
      'metadata': {'strategyId': ' ', 'routeId': 'attack-route'},
    },
    'blank route': {
      'metadata': {'strategyId': _strategyId, 'routeId': '\t'},
    },
    'missing route': {
      'metadata': {'strategyId': _strategyId},
    },
    'unsupported service': {'serviceId': 'unsupportedOrchestration'},
  }.entries) {
    test(
      '${invalid.key} coherently rolls back earlier extension and capability registrations',
      () async {
        await expectLater(
          activate(invalid.value),
          throwsA(isA<ExtensionContractException>()),
        );
        expect(
          extensions.discover(orchestrationStrategyContributions),
          isEmpty,
        );
        expect(capabilities.providersFor(_capability), isEmpty);
        expect(backend.isClosed, isFalse);
        // Exact same IDs can be activated again: no hidden registration survives.
        final healthy = await activate();
        expect(
          extensions.discover(orchestrationStrategyContributions),
          hasLength(1),
        );
        expect(capabilities.providersFor(_capability), hasLength(1));
        expect(healthy.connection.isClosed, isFalse);
      },
    );
  }
}

Future<Object?> _control(
  PluginBackendConnection connection,
  String method, [
  Map<String, Object?> payload = const {},
]) => connection
    .channelFor(connection.defaultConfigurationContext, 'probe')
    .request(method, payload)
    .timeout(_bound);

Future<Map<String, Object?>> _ready(
  PluginBackendConnection connection,
  String operation,
) async {
  // Failed assertions must not leave an advancing execution blocking teardown.
  addTearDown(() async {
    if (!connection.isClosed) await _control(connection, 'unblock');
  });
  return Map<String, Object?>.from(
    (await _control(connection, 'ready', {'operation': operation}))! as Map,
  );
}

Future<Object?> _finish(
  PluginBackendConnection connection,
  String operation, [
  String state = 'complete',
]) => _control(connection, 'finish', {'operation': operation, 'state': state});

Future<Object?> _proposal(
  PluginBackendConnection connection,
  Map<Object?, Object?> active,
  Map<Object?, Object?> handles,
) => _control(connection, 'proposal', {
  'context': active['context'],
  'snapshot': handles['snapshot'],
  'proposal': handles['proposal'],
});

void _expectDenied(Object? result, [String code = 'internal_error']) {
  expect(result, isA<Map<Object?, Object?>>());
  final response = result! as Map;
  expect(response['ok'], isFalse, reason: '$response');
  expect(response['code'], code, reason: '$response');
  expect(response.containsKey('unexpected'), isFalse);
}

final class _Tools implements StrategyToolSnapshot {}

final class _RecordingHost implements OrchestrationExecutionHost {
  @override
  final id = RunId('attack-run');
  @override
  final sessionId = SessionId('attack-session');
  @override
  RunState state = RunState.created;
  final turns = <StrategyModelTurn>[];
  final processed =
      <({StrategyToolSnapshot tools, ProviderToolProposal proposal})>[];
  final approvals = <ToolApprovalResolution>[];
  final observedOutcomes = <ToolOutcome>[];
  final evidence = <String>[];
  final proposalEntered = Completer<void>();
  Completer<void>? settleProposal;
  bool waitForApproval = false;
  Object? failure;
  final outcome = ToolOutcome(
    disposition: ToolOutcomeDisposition.success,
    effectCertainty: EffectCertainty.knownOccurred,
    modelContent: 'Host operation settled.',
    hostData: const {'evidence': 'retained'},
  );

  @override
  void validateBinding() {}

  @override
  void start() {
    expect(state, RunState.created);
    state = RunState.running;
  }

  @override
  void complete() {
    expect(state, RunState.running);
    state = RunState.completed;
  }

  @override
  void fail(Object error) {
    failure = error;
    evidence.add('run.failed');
    state = RunState.failed;
  }

  @override
  Future<StrategyModelTurn> invokeModel(
    StrategyInferenceMaterial material,
  ) async {
    final turn = StrategyModelTurn.settled(
      tools: _Tools(),
      output: [
        ModelToolProposalOutput(
          ProviderToolProposal(
            providerCallId: 'same-call',
            alias: 'same_tool',
            arguments: const {'same': 'arguments'},
          ),
        ),
      ],
    );
    turns.add(turn);
    return turn;
  }

  @override
  Future<StrategyToolResult> processProposal({
    required StrategyToolSnapshot tools,
    required ProviderToolProposal proposal,
  }) async {
    // Record before any validation so adapter leaks cannot hide behind the fake.
    processed.add((tools: tools, proposal: proposal));
    if (!proposalEntered.isCompleted) proposalEntered.complete();
    await settleProposal?.future;
    evidence.add('proposal.settled');
    observedOutcomes.add(outcome);
    if (waitForApproval) {
      state = RunState.waiting;
      return const StrategyToolWaiting();
    }
    return StrategyToolContinuation(
      SemanticToolOutcomeInput(
        providerCallId: proposal.providerCallId,
        outcome: outcome,
      ),
    );
  }

  @override
  Future<SemanticToolOutcomeInput> resolveApproval(
    ToolApprovalResolution resolution,
  ) async {
    approvals.add(resolution);
    state = RunState.running;
    return SemanticToolOutcomeInput(
      providerCallId: 'same-call',
      outcome: outcome,
    );
  }
}

String _dartExecutable() {
  final flutterRoot = Platform.environment['FLUTTER_ROOT'];
  if (flutterRoot != null) {
    final executable = File.fromUri(
      Directory(flutterRoot).uri.resolve(
        'bin/cache/dart-sdk/bin/${Platform.isWindows ? 'dart.exe' : 'dart'}',
      ),
    );
    if (executable.existsSync()) return executable.path;
  }
  final executable = File(Platform.resolvedExecutable);
  if (executable.parent.path.endsWith(
    '${Platform.pathSeparator}dart-sdk${Platform.pathSeparator}bin',
  )) {
    return executable.path;
  }
  throw StateError('Unable to locate the Dart SDK executable for AOT tests.');
}
