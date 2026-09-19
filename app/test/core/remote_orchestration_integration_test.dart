@Timeout(Duration(minutes: 2))
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:adele_capabilities/adele_capabilities.dart';
import 'package:adele_contract/adele_contract.dart';
import 'package:adele_desktop/core/model_provider_host.dart';
import 'package:adele_desktop/core/orchestration_host.dart';
import 'package:adele_desktop/core/remote_inference_context_host.dart';
import 'package:adele_model_provider/adele_model_provider.dart';
import 'package:adele_orchestration/adele_orchestration.dart';
import 'package:adele_orchestration/remote_orchestration.dart';
import 'package:adele_plugin_api/adele_plugin_api.dart';
import 'package:agent_kernel/agent_kernel.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plugin_builder/plugin_builder.dart';
import 'package:plugin_runtime/plugin_runtime.dart';

import '../support/orchestration_test_lifecycle.dart';

const _pluginId = 'dev.adele.test.remote-orchestration';
const _extensionId = '$_pluginId.registration';
const _strategyId = '$_pluginId.strategy';
const _bound = Duration(seconds: 10);

void main() {
  late Directory artifacts;
  late File hostArtifact;
  late File probeArtifact;
  late String aotRuntime;

  setUpAll(() async {
    artifacts = await Directory.systemTemp.createTemp('adele-remote-strategy-');
    addTearDown(() => artifacts.delete(recursive: true));
    final dart = _dartExecutable();
    aotRuntime = File.fromUri(
      File(dart).parent.uri.resolve(
        Platform.isWindows ? 'dartaotruntime.exe' : 'dartaotruntime',
      ),
    ).path;
    hostArtifact = File.fromUri(artifacts.uri.resolve('host.aot'));
    probeArtifact = File.fromUri(artifacts.uri.resolve('probe.aot'));
    for (final target in [
      (
        entrypoint: 'packages/plugin_backend_host/bin/adele_backend_host.dart',
        artifact: hostArtifact,
      ),
      (
        entrypoint: 'app/test/core/fixtures/remote_orchestration_probe.dart',
        artifact: probeArtifact,
      ),
    ]) {
      await compileAotSnapshot(
        dartExecutable: dart,
        workingDirectory: Directory.current.parent,
        entrypoint: target.entrypoint,
        artifact: target.artifact,
        stage: 'remote-orchestration-integration',
      );
    }
  });

  late PluginBackendHost host;
  late CapabilityRegistry capabilities;
  late ExtensionRegistry extensions;

  setUp(() async {
    host = await PluginBackendHost.start(
      dartaotruntimeExecutable: aotRuntime,
      hostArtifactPath: hostArtifact.path,
    );
    addTearDown(host.close);
    capabilities = CapabilityRegistry();
    extensions = ExtensionRegistry();
  });

  Future<PluginBackendActivation> start({
    String pluginId = _pluginId,
    String extensionId = _extensionId,
    Map<String, Object?> options = const {},
  }) async {
    final connection = await host.startPlugin(
      pluginId: pluginId,
      artifactUri: probeArtifact.uri,
      arguments: [extensionId, jsonEncode(options)],
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

  test(
    'normal advertisement and awaited materialization grant no execution authority',
    () async {
      final probe = await start(options: {'hold': 'materialize'});
      expect(probe.connection.pluginId, _pluginId);
      expect(probe.connection.capabilityExposures, isEmpty);
      expect(probe.connection.extensionExposures.single.toMap(), {
        'extensionPointId': orchestrationStrategyContributions.value,
        'extensionId': _extensionId,
        'serviceId': remoteOrchestrationServiceId,
        'configurationContext': 'default',
        'metadata': {'strategyId': _strategyId, 'routeId': 'probe-route'},
      });
      expect((await _snapshot(probe))['records'], isEmpty);
      final fixture = await _Fixture.create(extensions);
      var materialized = false;
      final creating = fixture.createRun().then((run) {
        materialized = true;
        return run;
      });
      await _control(probe, 'ready', {'operation': 'materialize'});
      expect(materialized, isFalse);
      final held = await _snapshot(probe);
      expect(held['contexts'], isEmpty);
      expect(fixture.model.requests, isEmpty);
      expect(fixture.executions, isEmpty);
      expect(_operations(held), ['materialize.begin', 'materialize.denied']);
      expect((_records(held).first), {
        'operation': 'materialize.begin',
        'sessionId': fixture.session.id.value,
        'taskId': fixture.session.taskId.value,
        'strategyId': _strategyId,
        'runId': 'probe-run-1',
      });
      await _control(probe, 'release', {'operation': 'materialize'});
      final run = await creating.timeout(_bound);
      expect(run.run.state, RunState.created);
      expect(run.run.journal.records, isEmpty);
      expect((await _snapshot(probe))['executionCount'], 1);
      await run.close();
      expect((await _snapshot(probe))['executionCount'], 0);
      expect(fixture.model.requests, isEmpty);
    },
  );

  for (final approved in [true, false]) {
    test(
      'real AOT ${approved ? 'approval' : 'rejection'} resumes the same multi-proposal snapshot with fresh authority',
      () async {
        final probe = await start();
        final fixture = await _Fixture.create(extensions);
        final run = await fixture.createRun();
        await run.start().timeout(_bound);
        expect(run.run.state, RunState.waiting);
        expect(fixture.model.requests, hasLength(1));
        expect(fixture.executions, isEmpty);
        expect(fixture.policyCalls, ['A']);
        expect(run.run.interruptions, hasLength(1));
        final waiting = await _snapshot(probe);
        expect(waiting['executionCount'], 1);
        final firstContext = (waiting['contexts'] as List).single;
        _expectDenied(
          await _control(probe, 'replay', {'context': firstContext}),
        );

        final resolution = _decision(run, approved);
        final before = run.run.journal.records;
        await expectLater(
          run.resolveApproval(
            ToolApprovalResolution(
              interruptionId: resolution.interruptionId,
              toolInvocationId: ToolInvocationId('invented'),
              approved: true,
            ),
          ),
          throwsA(isA<InvalidRunOperation>()),
        );
        expect(run.run.journal.records, orderedEquals(before));
        expect((await _snapshot(probe))['contexts'], [firstContext]);

        // Changing the live catalog cannot replace proposal B's captured executable.
        fixture.catalog.register(
          _registration('B', _Tool('replacement-B', fixture.executions)),
        );
        await run.resolveApproval(resolution).timeout(_bound);
        expect(run.run.state, RunState.completed);
        expect(run.run.interruptions, isEmpty);
        expect(fixture.executions, [if (approved) 'A', 'B']);
        expect(fixture.policyCalls, ['A', 'B']);
        expect(fixture.model.requests, hasLength(2));
        expect(
          fixture.model.requests.first.tools,
          isNot(same(fixture.model.requests.last.tools)),
        );
        final continued = fixture.model.requests.last.context;
        expect(renderInferenceInstructions(continued), 'Probe instructions.\n');
        expect(continued.input.map((item) => item.runtimeType), [
          SemanticMessageInput,
          SemanticMessageInput,
          SemanticNativeInput,
          SemanticToolProposalInput,
          SemanticToolProposalInput,
          SemanticToolOutcomeInput,
          SemanticToolOutcomeInput,
        ]);
        final message = continued.input[1] as SemanticMessageInput;
        expect(message.content, 'Narration');
        expect(message.providerItemId, 'text-item');
        _expectEnvelope(message.providerNativeMetadata!);
        final native = continued.input[2] as SemanticNativeInput;
        expect(native.providerItemId, 'native-item');
        _expectEnvelope(native.providerNativeMetadata);
        final proposals = continued.input
            .whereType<SemanticToolProposalInput>()
            .toList();
        expect(proposals.map((item) => item.providerItemId), [
          'item-A',
          'item-B',
        ]);
        expect(proposals.map((item) => item.proposal.providerCallId), [
          'call-A',
          'call-B',
        ]);
        for (final item in proposals) {
          _expectEnvelope(item.providerNativeMetadata!);
          expect(item.proposal.arguments, {'value': item.proposal.alias});
        }
        final outcomes = continued.input
            .whereType<SemanticToolOutcomeInput>()
            .toList();
        expect(outcomes.map((item) => item.providerCallId), [
          'call-A',
          'call-B',
        ]);
        expect(
          outcomes.first.outcome.disposition,
          approved
              ? ToolOutcomeDisposition.success
              : ToolOutcomeDisposition.userRejected,
        );
        expect(outcomes.last.outcome.modelContent, 'Executed B');
        expect(outcomes.last.outcome.hostData, {
          'tool': 'B',
          'nested': [1, true, null],
        });
        expect(outcomes.last.outcome.cause, isNull);
        final events = run.run.journal.records.map((record) => record.event);
        expect(events.whereType<ModelInvocationStarted>(), hasLength(2));
        expect(events.whereType<ToolInvocationPrepared>(), hasLength(2));
        expect(
          events.whereType<ToolExecutionStarted>(),
          hasLength(approved ? 2 : 1),
        );
        expect(events.whereType<RunInterruptionResolved>(), hasLength(1));
        expect(events.last, isA<RunCompleted>());
        expect(events.whereType<RunFailed>(), isEmpty);

        final finished = await _snapshot(probe);
        expect(finished['executionCount'], 0);
        final contexts = finished['contexts'] as List;
        expect(contexts, hasLength(2));
        expect(contexts.toSet(), hasLength(2));
        for (final context in contexts) {
          _expectDenied(await _control(probe, 'replay', {'context': context}));
        }
        final records = _records(finished);
        final turn = records.singleWhere((r) => r['operation'] == 'model.turn');
        expect(turn['metadata'], {
          'effectiveModel': 'deterministic-probe',
          'providerResponseId': 'response-1',
          'providerRequestId': 'request-1',
          'providerStopReason': 'probe-stop',
          'nativeState': _envelope().data,
          'usage': {
            'inputTokens': 11,
            'outputTokens': 7,
            'cacheReadTokens': 3,
            'cacheWriteTokens': 2,
            'providerDetails': {
              'nested': [1, null, true],
            },
          },
        });
        expect(turn['presentations'], [
          {
            'kind': 'probe.summary',
            'compactText': 'Safe summary',
            'data': {
              'summary': ['safe'],
            },
          },
        ]);
        _expectDenied(
          records.singleWhere(
            (r) => r['operation'] == 'resume.oldToken',
          )['result'],
        );
        expect(_operations(finished), contains('close.native'));
        final processed = records
            .where(
              (record) =>
                  record['method'] ==
                  remoteOrchestrationHostServiceProcessProposalId,
            )
            .toList();
        expect(processed, hasLength(2));
        expect(
          (processed.first['payload'] as Map)['toolSnapshotHandle'],
          (processed.last['payload'] as Map)['toolSnapshotHandle'],
        );
        expect(
          (processed.first['payload'] as Map)['proposalHandle'],
          isNot((processed.last['payload'] as Map)['proposalHandle']),
        );
        await run.close();
        expect(
          _operations(
            await _snapshot(probe),
          ).where((op) => op == 'close.native'),
          hasLength(1),
        );
      },
    );
  }

  for (final attack in ['fabricatedApproval', 'consumedProposal']) {
    test(
      'native remote proxy rejects $attack without extra tool authority',
      () async {
        final probe = await start(options: {'attack': attack});
        final fixture = await _Fixture.create(extensions);
        final run = await fixture.createRun();
        await run.start();
        await expectLater(
          run.resolveApproval(_decision(run, true)),
          throwsA(isA<PluginRemoteFailure>()),
        );
        expect(run.run.state, RunState.failed);
        expect(
          fixture.executions,
          attack == 'fabricatedApproval' ? isEmpty : ['A'],
        );
        expect(fixture.policyCalls, ['A']);
        expect(fixture.model.requests, hasLength(1));
        final snapshot = await _snapshot(probe);
        expect(snapshot['executionCount'], 0);
        expect(
          _operations(snapshot),
          contains(
            attack == 'fabricatedApproval'
                ? 'approval.fabricated.denied'
                : 'proposal.consumed.denied',
          ),
        );
        final calls = _records(snapshot).where(
          (record) =>
              record['method'] ==
              remoteOrchestrationHostServiceApplyCurrentApprovalId,
        );
        expect(calls, hasLength(attack == 'fabricatedApproval' ? 0 : 1));
        final proposals = _records(snapshot).where(
          (record) =>
              record['method'] ==
              remoteOrchestrationHostServiceProcessProposalId,
        );
        expect(proposals, hasLength(1));
        _expectDenied(await _control(probe, 'replay'));
      },
    );
  }

  test(
    'closing a waiting execution releases backend state without approving its tool',
    () async {
      final probe = await start();
      final fixture = await _Fixture.create(extensions);
      final run = await fixture.createRun();
      await run.start();
      final resolution = _decision(run, true);
      final waitingEvidence = run.run.journal.records;
      expect((await _snapshot(probe))['executionCount'], 1);
      await run.close().timeout(_bound);
      await run.close();
      final snapshot = await _snapshot(probe);
      expect(snapshot['executionCount'], 0);
      expect(
        _operations(snapshot).where((op) => op == 'close.native'),
        hasLength(1),
      );
      expect(fixture.executions, isEmpty);
      expect(fixture.model.requests, hasLength(1));
      expect(run.run.state, RunState.waiting);
      expect(run.run.interruptions, hasLength(1));
      expect(run.run.journal.records, orderedEquals(waitingEvidence));
      await expectLater(
        run.resolveApproval(resolution),
        throwsA(isA<InvalidRunOperation>()),
      );
      _expectDenied(await _control(probe, 'replay'));
    },
  );

  for (final phase in ['materialize', 'start']) {
    test(
      '$phase failure releases state and keeps the backend connection available',
      () async {
        final probe = await start(options: {'fail': phase});
        final fixture = await _Fixture.create(extensions);
        if (phase == 'materialize') {
          await expectLater(
            fixture.createRun(),
            throwsA(isA<PluginRemoteFailure>()),
          );
        } else {
          final run = await fixture.createRun();
          await expectLater(run.start(), throwsA(isA<PluginRemoteFailure>()));
          expect(run.run.state, RunState.failed);
          expect(run.run.journal.records.last.event, isA<RunFailed>());
          _expectDenied(await _control(probe, 'replay'));
        }
        expect((await _snapshot(probe))['executionCount'], 0);
        expect(fixture.model.requests, isEmpty);
        expect(fixture.executions, isEmpty);
        expect(probe.connection.isClosed, isFalse);
        expect(host.isClosed, isFalse);
      },
    );
  }

  for (final settlement in ['failure', 'incomplete', 'refused']) {
    test(
      'model $settlement reaches the native strategy and releases terminal execution',
      () async {
        final probe = await start();
        final fixture = await _Fixture.create(extensions);
        fixture.model.settlement = settlement;
        final run = await fixture.createRun();
        await run.start().timeout(_bound);
        expect(run.run.state, RunState.failed);
        expect(fixture.executions, isEmpty);
        expect(fixture.policyCalls, isEmpty);
        expect(fixture.model.requests, hasLength(1));
        final snapshot = await _snapshot(probe);
        expect(snapshot['executionCount'], 0);
        final turn = _records(
          snapshot,
        ).singleWhere((record) => record['operation'] == 'model.turn');
        expect(turn['settlement'], settlement == 'failure' ? null : settlement);
        expect(
          turn['incompleteReason'],
          settlement == 'incomplete' ? 'outputLimit' : null,
        );
        if (settlement == 'failure') {
          expect(run.run.failure, isA<RemoteStrategyFailure>());
          expect((run.run.failure as RemoteStrategyFailure).code, 'StateError');
          expect(
            (run.run.failure as RemoteStrategyFailure).message,
            'Bad state: Deterministic model failure.',
          );
          expect(turn['metadata'], isNull);
        }
        _expectDenied(await _control(probe, 'replay'));
      },
    );
  }

  for (final kind in ['rpc', 'protocol']) {
    test(
      'collected provider $kind failure preserves partial output through real AOT strategy',
      () async {
        final probe = await start();
        final fixture = await _Fixture.create(extensions);
        final channel = _ProviderFailureChannel(kind);
        final registration = capabilities.register(
          provider: ProviderDescriptor(
            id: ProviderId('dev.adele.test.failing-model'),
            capability: modelProviderCapability,
            pluginId: 'dev.adele.test.model-provider',
            displayName: 'Failing provider transport',
            serviceId: modelProviderServiceId,
          ),
          endpoint: AdeleRequestChannelEndpoint(
            channel: channel,
            serviceId: modelProviderServiceId,
            isAvailable: () => true,
          ),
        );
        addTearDown(registration.close);
        final run = await fixture.createRun(
          model: ModelProviderCapabilityAdapter(
            capabilities.resolve(modelProviderCapability),
            selectedModel: 'deterministic-probe',
          ),
        );
        await run.start().timeout(_bound);
        expect(run.run.state, RunState.failed);
        expect(channel.invocations, 1);
        expect(fixture.executions, isEmpty);
        expect(fixture.policyCalls, isEmpty);
        final events = run.run.journal.records.map((record) => record.event);
        final collected = events.whereType<ModelInvocationFailed>().single;
        if (kind == 'rpc') {
          expect(collected.error, same(channel.failure));
        } else {
          expect(collected.error, isA<AdeleProtocolException>());
        }
        final originalMessage = collected.error.toString();
        final expectedMessage = originalMessage.length > 4096
            ? originalMessage.substring(0, 4096)
            : originalMessage;
        final failure = run.run.failure! as RemoteStrategyFailure;
        expect(failure.code, collected.error.runtimeType.toString());
        expect(failure.message, expectedMessage);
        expect(failure.message.length, lessThanOrEqualTo(4096));
        expect(events.whereType<RunFailed>(), hasLength(1));
        expect(events.whereType<ToolInvocationPrepared>(), isEmpty);
        final output = events.whereType<ModelOutputObserved>().toList();
        expect(output.map((event) => event.item.runtimeType), [
          ModelTextOutput,
          ModelNativeOutput,
          ModelToolProposalOutput,
        ]);
        final snapshot = await _snapshot(probe);
        final turn = _records(
          snapshot,
        ).singleWhere((record) => record['operation'] == 'model.turn');
        expect(turn['settlement'], isNull);
        expect(turn['metadata'], isNull);
        expect(turn['failureData'], {
          'code': failure.code,
          'message': expectedMessage,
        });
        final received = turn['output'] as List;
        expect(received.map((item) => (item as Map)['kind']), [
          'text',
          'providerNative',
          'toolProposal',
        ]);
        for (int index = 0; index < output.length; index++) {
          expect(
            (received[index] as Map)['payload'],
            RemoteModelOutput.fromLocal(output[index].item).payload,
          );
        }
        expect(turn['presentations'], [
          {
            'kind': 'probe.summary',
            'compactText': 'Safe partial summary',
            'data': {
              'summary': ['partial'],
            },
          },
        ]);
        expect(snapshot['executionCount'], 0);
        expect(
          _operations(
            snapshot,
          ).where((operation) => operation == 'close.native'),
          hasLength(1),
        );
        expect(probe.connection.isClosed, isFalse);
        _expectDenied(await _control(probe, 'replay'));
      },
    );
  }

  for (final state in [RunState.failed, RunState.completed]) {
    test(
      'real backend cleanup failure preserves $state and explicit release closes only its generation',
      () async {
        final probe = await start(
          options: {'failClose': true, 'hold': 'release.failed'},
        );
        final binding = extensions
            .discover(orchestrationStrategyContributions)
            .single;
        final sibling = await start(
          pluginId: '$_pluginId.sibling',
          extensionId: '$_extensionId.sibling',
          options: {'strategyId': '$_strategyId.sibling'},
        );
        final fixture = await _Fixture.create(extensions);
        if (state == RunState.failed) fixture.model.settlement = 'failure';
        final run = await fixture.createRun();
        addTearDown(() async {
          if (!probe.connection.isClosed) {
            await _control(probe, 'release', {'operation': 'release.failed'});
          }
        });
        if (state == RunState.completed) await run.start().timeout(_bound);
        final terminated = probe.connection.terminated.timeout(_bound);
        final advancing = state == RunState.failed
            ? run.start()
            : run.resolveApproval(_decision(run, true));
        final succeeded = expectLater(advancing, completes);
        await _control(probe, 'ready', {'operation': 'release.failed'});
        expect(run.run.state, state);
        if (state == RunState.failed) {
          expect(run.run.failure, isA<RemoteStrategyFailure>());
          expect(
            (run.run.failure! as RemoteStrategyFailure).message,
            'Bad state: Deterministic model failure.',
          );
        } else {
          expect(run.run.failure, isNull);
        }
        final evidence = run.run.journal.records;
        final snapshot = await _snapshot(probe);
        final records = _records(snapshot);
        expect(
          records.singleWhere(
            (record) => record['operation'] == 'release',
          )['executionCount'],
          1,
        );
        final release = records.singleWhere(
          (record) => record['operation'] == 'release.failed',
        );
        expect(
          release['error'],
          'Bad state: Deliberate native cleanup failure.',
        );
        expect(release['executionCount'], 0);
        expect(snapshot['executionCount'], 0);
        expect(
          _operations(
            snapshot,
          ).where((operation) => operation == 'close.native'),
          hasLength(1),
        );
        expect(probe.connection.isClosed, isFalse);
        _expectDenied(await _control(probe, 'replay'));
        await _control(probe, 'release', {'operation': 'release.failed'});
        await succeeded.timeout(_bound);
        await terminated;
        expect(probe.connection.isClosed, isTrue);
        expect(binding.validate, throwsA(isA<StaleExtensionBinding>()));
        expect(run.run.state, state);
        expect(run.run.journal.records, orderedEquals(evidence));
        await run.close();
        expect(sibling.connection.isClosed, isFalse);
        expect((await _snapshot(sibling))['executionCount'], 0);
        expect(host.isClosed, isFalse);
      },
    );
  }

  test(
    'canonical resolver keeps unavailable and ambiguous semantics without materialization',
    () async {
      final topology = await OrchestrationTestLifecycle.create(
        extensions,
        SessionId('resolver-session'),
      );
      expect(
        () => topology.createSession(OrchestrationStrategyId(_strategyId)),
        throwsA(isA<OrchestrationStrategyUnavailable>()),
      );
      final first = await start();
      final session = topology.createSession(
        OrchestrationStrategyId(_strategyId),
      );
      final retained = topology.lifecycle.resolveSessionStrategy(session.id);
      final second = await start(
        pluginId: '$_pluginId.sibling',
        extensionId: '$_extensionId.sibling',
      );
      expect(
        () => topology.lifecycle.resolveSessionStrategy(session.id),
        throwsA(isA<AmbiguousOrchestrationStrategy>()),
      );
      expect((await _snapshot(first))['records'], isEmpty);
      expect((await _snapshot(second))['records'], isEmpty);
      await second.retire();
      expect(
        topology.lifecycle.resolveSessionStrategy(session.id).binding.id.value,
        _extensionId,
      );
      await first.retire();
      expect(retained.validateBinding, throwsA(isA<StaleExtensionBinding>()));
      expect(
        () => topology.lifecycle.resolveSessionStrategy(session.id),
        throwsA(isA<OrchestrationStrategyUnavailable>()),
      );
      expect(topology.lifecycle.store.session(session.id), same(session));
    },
  );

  test(
    'retirement cannot migrate a waiting Run; fresh resolution uses same-ID replacement',
    () async {
      final old = await start();
      final fixture = await _Fixture.create(extensions);
      final run = await fixture.createRun();
      final binding = extensions
          .discover(orchestrationStrategyContributions)
          .single;
      await run.start();
      final resolution = _decision(run, true);
      final oldToken = ((await _snapshot(old))['contexts'] as List).single;
      await old.retire().timeout(_bound);
      expect(extensions.discover(orchestrationStrategyContributions), isEmpty);
      expect(binding.validate, throwsA(isA<StaleExtensionBinding>()));
      await expectLater(
        run.resolveApproval(resolution),
        throwsA(isA<StaleExtensionBinding>()),
      );
      expect(run.run.state, RunState.failed);
      expect(fixture.executions, isEmpty);
      expect((await _snapshot(old))['executionCount'], 0);
      await old.close();
      final replacement = await start();
      await old.close();
      _expectDenied(
        await _control(replacement, 'replay', {'context': oldToken}),
      );
      fixture.model.requests.clear();
      final fresh = await fixture.createRun();
      await fresh.start();
      await fresh.resolveApproval(_decision(fresh, true));
      expect(fresh.run.state, RunState.completed);
      expect(fixture.executions, ['A', 'B']);
      expect(
        fixture.topology.lifecycle.store.session(fixture.session.id),
        same(fixture.session),
      );
      expect(binding.validate, throwsA(isA<StaleExtensionBinding>()));
      expect(replacement.connection.isClosed, isFalse);
    },
  );

  test(
    'retirement rejects late async materialization and releases its returned execution',
    () async {
      final probe = await start(options: {'hold': 'materialize'});
      final fixture = await _Fixture.create(extensions);
      final failed = expectLater(
        fixture.createRun(),
        throwsA(isA<StaleExtensionBinding>()),
      );
      await _control(probe, 'ready', {'operation': 'materialize'});
      await probe.retire();
      await _control(probe, 'release', {'operation': 'materialize'});
      await failed.timeout(_bound);
      expect((await _snapshot(probe))['executionCount'], 0);
      expect(fixture.model.requests, isEmpty);
      expect(fixture.executions, isEmpty);
    },
  );

  test(
    'termination settles held advancement; sibling and replacement remain usable',
    () async {
      final old = await start(options: {'hold': 'turn'});
      final fixture = await _Fixture.create(extensions);
      final run = await fixture.createRun();
      addTearDown(() async {
        if (!old.connection.isClosed) {
          await _control(old, 'release', {'operation': 'turn'});
        }
      });
      final failed = expectLater(
        run.start(),
        throwsA(
          anyOf(isA<PluginRemoteFailure>(), isA<StaleExtensionBinding>()),
        ),
      );
      await _control(old, 'ready', {'operation': 'turn'});
      final token = ((await _snapshot(old))['contexts'] as List).single;
      final sibling = await start(
        pluginId: '$_pluginId.sibling',
        extensionId: '$_extensionId.sibling',
        options: {'strategyId': '$_strategyId.sibling'},
      );
      _expectDenied(await _control(sibling, 'replay', {'context': token}));
      final terminated = old.connection.terminated.timeout(_bound);
      await expectLater(
        _control(old, 'terminate'),
        throwsA(isA<PluginRemoteFailure>()),
      );
      await terminated;
      await failed.timeout(_bound);
      expect(run.run.state, RunState.failed);
      expect(fixture.model.requests, hasLength(1));
      expect(fixture.executions, isEmpty);
      final replacement = await start();
      await old.close();
      _expectDenied(await _control(replacement, 'replay', {'context': token}));
      final fresh = await fixture.createRun();
      await fresh.start();
      await fresh.resolveApproval(_decision(fresh, true));
      expect(fresh.run.state, RunState.completed);
      expect(sibling.connection.isClosed, isFalse);
      expect(replacement.connection.isClosed, isFalse);
      expect(host.isClosed, isFalse);
    },
  );

  for (final invalid in <String, Map<String, Object?>>{
    'missing route': {
      'metadata': {'strategyId': _strategyId},
    },
    'extra identity': {
      'metadata': {
        'strategyId': _strategyId,
        'routeId': 'probe-route',
        'pluginId': 'forged',
      },
    },
    'blank route': {
      'metadata': {'strategyId': _strategyId, 'routeId': ''},
    },
    'wrong service': {'serviceId': 'notOrchestration'},
  }.entries) {
    test(
      'invalid ${invalid.key} advertisement rolls back registration',
      () async {
        await expectLater(
          start(options: invalid.value),
          throwsA(isA<ExtensionContractException>()),
        );
        expect(
          extensions.discover(orchestrationStrategyContributions),
          isEmpty,
        );
        expect(host.isClosed, isFalse);
        final healthy = await start();
        expect((await _snapshot(healthy))['records'], isEmpty);
      },
    );
  }
}

Future<Object?> _control(
  PluginBackendActivation probe,
  String method, [
  Map<String, Object?> payload = const {},
]) => probe.connection
    .channelFor(probe.connection.defaultConfigurationContext, 'probe')
    .request(method, payload)
    .timeout(_bound);

Future<Map<String, Object?>> _snapshot(PluginBackendActivation probe) async =>
    Map<String, Object?>.from(await _control(probe, 'snapshot') as Map);

List<Map<String, Object?>> _records(Map<String, Object?> snapshot) => [
  for (final record in snapshot['records'] as List)
    Map<String, Object?>.from(record as Map),
];

Iterable<Object?> _operations(Map<String, Object?> snapshot) =>
    _records(snapshot).map((record) => record['operation']);

void _expectDenied(
  Object? result, [
  String code = 'host_invocation_unavailable',
]) {
  expect(result, isA<Map<Object?, Object?>>());
  expect((result as Map)['ok'], isFalse);
  expect(result['code'], code);
}

ToolApprovalResolution _decision(SessionOrchestrationRun run, bool approved) {
  final interruption =
      run.run.interruptions.values.single as ToolApprovalInterruption;
  return ToolApprovalResolution(
    interruptionId: interruption.id,
    toolInvocationId: interruption.toolInvocationId,
    approved: approved,
  );
}

final class _Fixture {
  _Fixture(this.extensions, this.topology, this.session);

  static Future<_Fixture> create(ExtensionRegistry extensions) async {
    final topology = await OrchestrationTestLifecycle.create(
      extensions,
      SessionId('probe-session'),
    );
    final fixture = _Fixture(
      extensions,
      topology,
      topology.createSession(OrchestrationStrategyId(_strategyId)),
    );
    for (final name in ['A', 'B']) {
      fixture.catalog.register(
        _registration(name, _Tool(name, fixture.executions)),
      );
    }
    return fixture;
  }

  final ExtensionRegistry extensions;
  final OrchestrationTestLifecycle topology;
  final Session session;
  final model = _Model();
  final catalog = ToolCatalog();
  final executions = <String>[];
  final policyCalls = <String>[];
  int nextRun = 0;

  Future<SessionOrchestrationRun> createRun({ModelPort? model}) async {
    final run = await createSessionOrchestrationRun(
      lifecycle: topology.lifecycle,
      sessionId: session.id,
      runId: RunId('probe-run-${++nextRun}'),
      contextComposer: InferenceContextComposer(extensions),
      model: model ?? this.model,
      toolCatalog: catalog,
      policy: _Policy(policyCalls),
    );
    addTearDown(run.close);
    return run;
  }
}

/// Exercises the real generated provider decoder and capability adapter before
/// the collected failure crosses the actual AOT orchestration transport.
final class _ProviderFailureChannel implements AdeleStreamChannel {
  _ProviderFailureChannel(this.kind);

  final String kind;
  int invocations = 0;
  final failure = PluginRemoteFailure(
    code: 'provider_transport_failed',
    message: 'Provider connection failed: ${'x' * 5000}',
    details: const {'private': 'not part of the semantic failure snapshot'},
  );

  @override
  Future<Object?> request(String method, Map<String, Object?> payload) =>
      throw StateError('Model invocation must use streaming transport.');

  @override
  Stream<Object?> stream(String method, Map<String, Object?> payload) async* {
    expect(method, modelProviderServiceInvokeId);
    invocations++;
    final envelope = _envelope();
    for (final output in <Map<String, Object?>>[
      {
        'kind': 'text',
        'text': 'Partial narration',
        'toolProposal': null,
        'itemId': 'partial-text',
        'nativePresentation': null,
      },
      {
        'kind': 'nativeItem',
        'text': null,
        'toolProposal': null,
        'itemId': 'partial-native',
        'nativePresentation': {
          'kind': 'probe.summary',
          'compactText': 'Safe partial summary',
          'data': {
            'summary': ['partial'],
          },
        },
      },
      {
        'kind': 'toolProposal',
        'text': null,
        'toolProposal': {
          'callId': 'partial-call',
          'name': 'A',
          'arguments': {'value': 'A'},
        },
        'itemId': 'partial-proposal',
        'nativePresentation': null,
      },
    ]) {
      yield <String, Object?>{
        'kind': 'output',
        'observation': null,
        'terminal': null,
        'output': {
          ...output,
          'nativeMetadata': {
            'kind': envelope.kind,
            'compatibility': envelope.compatibility,
            'data': envelope.data,
          },
        },
      };
    }
    if (kind == 'rpc') throw failure;
    yield <String, Object?>{'kind': 'malformed-provider-event'};
  }
}

final class _Model implements ModelPort {
  final requests = <SemanticModelRequest>[];
  String settlement = 'completed';

  @override
  Stream<ModelEvent> invoke(SemanticModelRequest request) async* {
    requests.add(request);
    if (settlement == 'failure') {
      yield ModelInvocationFailedEvent(
        invocationId: request.invocationId,
        error: StateError('Deterministic model failure.'),
      );
      return;
    }
    final output = request.invocationId.value.endsWith('-model-1')
        ? <ModelOutputItem>[
            ModelTextOutput(
              'Narration',
              providerItemId: 'text-item',
              providerNativeMetadata: _envelope(),
            ),
            ModelNativeOutput(
              providerItemId: 'native-item',
              providerNativeMetadata: _envelope(),
              presentation: ModelNativePresentation(
                kind: 'probe.summary',
                compactText: 'Safe summary',
                data: const {
                  'summary': ['safe'],
                },
              ),
            ),
            for (final name in ['A', 'B'])
              ModelToolProposalOutput(
                ProviderToolProposal(
                  providerCallId: 'call-$name',
                  alias: name,
                  arguments: {'value': name},
                ),
                providerItemId: 'item-$name',
                providerNativeMetadata: _envelope(),
              ),
          ]
        : <ModelOutputItem>[ModelTextOutput('Final answer')];
    for (final item in output) {
      yield ModelOutputItemCompleted(
        invocationId: request.invocationId,
        item: item,
      );
    }
    yield ModelInvocationSettledEvent(
      invocationId: request.invocationId,
      settlement: switch (settlement) {
        'incomplete' => ModelSettlement.incomplete,
        'refused' => ModelSettlement.refused,
        _ => ModelSettlement.completed,
      },
      incompleteReason: settlement == 'incomplete'
          ? ModelIncompleteReason.outputLimit
          : null,
      metadata: ModelTerminalMetadata(
        effectiveModel: 'deterministic-probe',
        providerResponseId: 'response-1',
        providerRequestId: 'request-1',
        providerStopReason: 'probe-stop',
        providerNativeState: _envelope(),
        usage: ModelUsage(
          inputTokens: 11,
          outputTokens: 7,
          cacheReadTokens: 3,
          cacheWriteTokens: 2,
          providerDetails: const {
            'nested': [1, null, true],
          },
        ),
      ),
    );
  }
}

ModelNativeEnvelope _envelope() => ModelNativeEnvelope(
  kind: 'probe.native',
  compatibility: const {'model': 'deterministic-probe', 'version': 1},
  data: const {
    'opaque': ['exact', 4, null, true],
    'nested': {'key': 'value'},
  },
);

void _expectEnvelope(ModelNativeEnvelope envelope) {
  expect(envelope.kind, 'probe.native');
  expect(envelope.compatibility, _envelope().compatibility);
  expect(envelope.data, _envelope().data);
}

ToolRegistration _registration(String name, ToolExecutable executable) =>
    ToolRegistration(
      definition: ToolDefinition(
        id: ToolId('dev.adele.test.tool-$name'),
        description: 'Probe $name',
      ),
      modelDefinition: ModelToolDefinition(
        alias: name,
        description: 'Probe $name',
        argumentsSchema: const {
          'type': 'object',
          'properties': {
            'value': {'type': 'string'},
          },
        },
      ),
      executable: executable,
    );

final class _Tool implements ToolExecutable {
  const _Tool(this.name, this.executions);
  final String name;
  final List<String> executions;
  @override
  void validateBinding() {}
  @override
  CanonicalToolArguments validateAndNormalize(
    Map<String, Object?> proposedArguments,
  ) => CanonicalToolArguments(proposedArguments);
  @override
  Future<EffectDescription> describe(
    CanonicalToolArguments arguments,
    ToolExecutionContext context,
  ) async => EffectDescription(
    effects: [ToolEffect.sourceMutation],
    targets: [],
    summary: 'Probe $name',
  );
  @override
  Stream<ToolExecutionEvent> execute(
    CanonicalToolArguments arguments,
    ToolExecutionContext context,
  ) async* {
    executions.add(name);
    yield ToolExecutionProgress(ToolProgress(content: 'Executing $name'));
    yield ToolExecutionTerminal(
      ToolOutcome(
        disposition: ToolOutcomeDisposition.success,
        effectCertainty: EffectCertainty.knownOccurred,
        modelContent: 'Executed $name',
        hostData: {
          'tool': name,
          'nested': [1, true, null],
        },
        cause: StateError('Never transport this exception instance.'),
      ),
    );
  }
}

final class _Policy implements ToolPolicy {
  const _Policy(this.calls);
  final List<String> calls;
  @override
  ToolPolicyDecision evaluate(ToolPolicyInput input) {
    final alias = input.invocation.proposal.alias;
    calls.add(alias);
    return alias == 'A' ? ToolPolicyDecision.ask : ToolPolicyDecision.allow;
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
