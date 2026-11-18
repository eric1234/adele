@Timeout(Duration(minutes: 2))
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:adele_capabilities/adele_capabilities.dart';
import 'package:adele_contract/adele_contract.dart';
import 'package:adele_desktop/core/remote_inference_context_host.dart';
import 'package:adele_desktop/core/tool_authorization_policy_composer.dart';
import 'package:adele_orchestration/adele_orchestration.dart';
import 'package:adele_orchestration/remote_tool_authorization.dart';
import 'package:adele_plugin_api/adele_plugin_api.dart';
import 'package:agent_kernel/agent_kernel.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plugin_builder/plugin_builder.dart';
import 'package:plugin_runtime/plugin_runtime.dart';

import '../support/orchestration_test_lifecycle.dart';

const _pluginId = 'dev.adele.test.remote-tool-authorization';
const _bound = Duration(seconds: 10);

void main() {
  late Directory artifacts;
  late File hostArtifact;
  late File probeArtifact;
  late String aotRuntime;

  setUpAll(() async {
    artifacts = await Directory.systemTemp.createTemp('adele-remote-policy-');
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
        entrypoint:
            'app/test/core/fixtures/remote_tool_authorization_probe.dart',
        artifact: probeArtifact,
      ),
    ]) {
      await compileAotSnapshot(
        dartExecutable: dart,
        workingDirectory: Directory.current.parent,
        entrypoint: target.entrypoint,
        artifact: target.artifact,
        stage: 'remote-tool-authorization-integration',
      );
    }
  });

  late PluginBackendHost host;
  late CapabilityRegistry capabilities;
  late ExtensionRegistry extensions;
  late OrchestrationTestLifecycle topology;
  late Session session;
  late AgentRun run;
  late _Tool tool;
  final runId = RunId('authorization-run');

  setUp(() async {
    host = await PluginBackendHost.start(
      dartaotruntimeExecutable: aotRuntime,
      hostArtifactPath: hostArtifact.path,
    );
    addTearDown(host.close);
    capabilities = CapabilityRegistry();
    extensions = ExtensionRegistry();
    final strategyId = OrchestrationStrategyId('dev.test.strategy');
    final strategy = extensions.register(
      point: orchestrationStrategyContributions,
      id: ExtensionId('dev.test.strategy'),
      value: OrchestrationStrategyContribution(
        strategyId: strategyId,
        materialize: (_) => throw StateError('No strategy execution needed.'),
      ),
    );
    addTearDown(strategy.close);
    topology = await OrchestrationTestLifecycle.create(
      extensions,
      SessionId('authorization-session'),
    );
    addTearDown(topology.lifecycle.close);
    session = topology.createSession(strategyId);
    run = AgentRun(id: runId, sessionId: session.id)..start();
    tool = _Tool();
  });

  Future<PluginBackendConnection> connect({
    String pluginId = _pluginId,
    required List<Map<String, Object?>> exposures,
  }) async {
    final connection = await host.startPlugin(
      pluginId: pluginId,
      artifactUri: probeArtifact.uri,
      arguments: [
        jsonEncode({'exposures': exposures}),
      ],
    );
    addTearDown(connection.close);
    return connection;
  }

  Future<PluginBackendActivation> activate(
    PluginBackendConnection connection,
  ) async {
    final activation = await PluginBackendActivation.registerAdvertised(
      connection: connection,
      capabilities: capabilities,
      extensions: extensions,
      adapters: createRemoteExtensionAdapters(),
    );
    addTearDown(activation.close);
    return activation;
  }

  Future<PluginBackendActivation> start({
    String pluginId = _pluginId,
    required List<Map<String, Object?>> exposures,
  }) async => activate(await connect(pluginId: pluginId, exposures: exposures));

  ExtensionRegistration local(
    String name,
    FutureOr<ToolAuthorizationDecision> Function(ToolAuthorizationRequest)
    evaluate,
  ) {
    final registration = extensions.register(
      point: toolAuthorizationPolicies,
      id: ExtensionId('$_pluginId.registration.$name'),
      value: ToolAuthorizationPolicyContribution(evaluate: evaluate),
    );
    addTearDown(registration.close);
    return registration;
  }

  Future<ToolInvocation> resolve([String suffix = '1']) async {
    final resolution = await const ToolInvocationResolver().resolve(
      invocationId: ToolInvocationId('authorization-invocation-$suffix'),
      proposal: ProviderToolProposal(
        providerCallId: 'provider-call-$suffix',
        alias: 'alias_is_not_identity',
        arguments: {'path': '  source.dart  ', 'discarded': 'provider-only'},
      ),
      tools: MaterializedToolSet([
        MaterializedTool(
          definition: ToolDefinition(
            id: ToolId('dev.test.tool.read'),
            description: 'Read source.',
          ),
          modelDefinition: ModelToolDefinition(
            alias: 'alias_is_not_identity',
            description: 'Read source.',
            argumentsSchema: const {},
          ),
          executable: tool,
        ),
      ]),
      runId: runId,
      sessionId: session.id,
    );
    return (resolution as ResolvedToolProposal).invocation;
  }

  Future<ToolPolicyGateResult> evaluate(ToolInvocation invocation) =>
      const ToolPolicyGate()
          .evaluate(
            invocation: invocation,
            policy: ToolAuthorizationPolicyComposer(
              extensions: extensions,
              lifecycle: topology.lifecycle,
              session: session,
              runId: runId,
            ),
            interruptionId: RunInterruptionId(
              'approval-${invocation.id.value}',
            ),
          )
          .timeout(_bound);

  for (final decision in ToolAuthorizationDecision.values) {
    test(
      'real remote ${decision.name} reaches the existing kernel gate',
      () async {
        final probe = await start(exposures: [_exposure(decision.name)]);
        local('native-allow', (_) => ToolAuthorizationDecision.allow);
        expect(
          toolAuthorizationPolicies.value,
          'dev.adele.extension.tool-authorization-policies',
        );
        expect(probe.connection.capabilityExposures, isEmpty);
        expect(probe.connection.extensionExposures.map((e) => e.toMap()), [
          _exposure(decision.name),
        ]);
        expect(await _snapshot(probe.connection), _emptySnapshot);
        final invocation = await resolve();
        final result = await evaluate(invocation);
        expect(result.invocation, same(invocation));
        expect(result.effects, same(tool.effects));
        expect(tool.executions, 0);
        expect(await _snapshot(probe.connection), {
          'requests': [_request(decision.name, invocation, tool.effects)],
          'evaluations': [
            _evaluation(
              decision.name,
              invocation,
              tool.effects,
              decision: decision.name,
            ),
          ],
        });
        switch (decision) {
          case ToolAuthorizationDecision.allow ||
              ToolAuthorizationDecision.abstain:
            final observation = await collectToolExecution(
              run.startToolExecution(result as ToolExecutionAllowed).events(),
            );
            expect(
              observation.outcome.disposition,
              ToolOutcomeDisposition.success,
            );
            expect(tool.executions, 1);
            expect(tool.executedArguments.single, same(invocation.arguments));
            expect(tool.executedContexts.single, same(invocation.context));
            expect(run.interruptions, isEmpty);
          case ToolAuthorizationDecision.deny:
            final outcome = (result as ToolExecutionDenied).outcome;
            expect(outcome.disposition, ToolOutcomeDisposition.policyDenied);
            expect(outcome.effectCertainty, EffectCertainty.knownNotOccurred);
            expect(tool.executions, 0);
            expect(run.interruptions, isEmpty);
          case ToolAuthorizationDecision.ask:
            final required = result as ToolApprovalRequired;
            run.interrupt(required.interruption);
            expect(run.state, RunState.waiting);
            expect(required.interruption.invocation, same(invocation));
            expect(required.interruption.canonicalArguments, _arguments);
            expect(required.interruption.effects, same(tool.effects));
            expect(tool.executions, 0);
        }
      },
    );
  }

  test(
    'full normalized request has exact authority-free fields and values',
    () async {
      final probe = await start(exposures: [_exposure('allow')]);
      tool.effects = EffectDescription(
        effects: ToolEffect.values,
        targets: [
          EffectTarget(uri: Uri.parse('file:///source.dart')),
          EffectTarget(uri: Uri.parse('https://example.test/a%20b?q=1#part')),
        ],
        summary: 'Exact effect summary.\nNot authorization.',
        uncertainty: EffectUncertainty.uncertain,
      );
      final invocation = await resolve();
      expect(invocation.proposal.arguments['path'], '  source.dart  ');
      expect(invocation.canonicalArguments, _arguments);
      expect(await evaluate(invocation), isA<ToolExecutionAllowed>());
      final snapshot = await _snapshot(probe.connection);
      expect(snapshot, {
        'requests': [_request('allow', invocation, tool.effects)],
        'evaluations': [_evaluation('allow', invocation, tool.effects)],
      });
      final payload = (snapshot['requests']! as List).single['payload'] as Map;
      expect(payload.keys, unorderedEquals(['routeId', 'request']));
      expect(
        (payload['request'] as Map).keys,
        unorderedEquals([
          'toolId',
          'canonicalArguments',
          'effects',
          'runId',
          'sessionId',
          'projectId',
          'toolInvocationId',
        ]),
      );
      expect((payload['request'] as Map)['toolId'], 'dev.test.tool.read');
      expect(tool.executions, 0);
    },
  );

  test(
    'distinct IDs, routes and configurations compose with local restrictions',
    () async {
      final maximum = 'A${'x' * 251}._:-';
      expect(maximum.length, 256);
      final exposures = [
        _exposure('z', routeId: maximum),
        _exposure('m', routeId: 'ask', configuration: 'alternate'),
        _exposure('a', routeId: 'allow'),
        _exposure('b', routeId: 'abstain'),
      ];
      final probe = await start(exposures: exposures);
      expect(extensions.discover(toolAuthorizationPolicies), hasLength(4));
      expect(
        probe.connection.extensionExposures.map((e) => e.toMap()),
        exposures,
      );
      expect(await _snapshot(probe.connection), _emptySnapshot);
      final invocation = await resolve();
      expect(await evaluate(invocation), isA<ToolApprovalRequired>());
      var localCalls = 0;
      local('n-local-deny', (request) {
        localCalls++;
        expect(request.canonicalArguments, _arguments);
        return ToolAuthorizationDecision.deny;
      });
      expect(await evaluate(invocation), isA<ToolExecutionDenied>());
      expect(localCalls, 1);
      final routes = ['allow', 'abstain', 'ask', maximum];
      expect(await _snapshot(probe.connection), {
        'requests': [
          for (var repetition = 0; repetition < 2; repetition++)
            for (final route in routes)
              _request(
                route,
                invocation,
                tool.effects,
                configuration: route == 'ask' ? 'alternate' : 'default',
              ),
        ],
        'evaluations': [
          for (var repetition = 0; repetition < 2; repetition++)
            for (final route in routes)
              _evaluation(
                route,
                invocation,
                tool.effects,
                configuration: route == 'ask' ? 'alternate' : 'default',
                decision: route == maximum ? 'allow' : route,
              ),
        ],
      });
      expect(tool.executions, 0);
    },
  );

  for (final approved in [false, true]) {
    test('completed Ask retains exact ${approved ? 'approval' : 'rejection'} '
        'across retirement and same-ID replacement', () async {
      final old = await start(exposures: [_exposure('policy', routeId: 'ask')]);
      final invocation = await resolve();
      final required = await evaluate(invocation) as ToolApprovalRequired;
      run.interrupt(required.interruption);
      expect(run.state, RunState.waiting);
      expect(tool.executions, 0);
      for (final resolution in [
        ToolApprovalResolution(
          interruptionId: RunInterruptionId('wrong-interruption'),
          toolInvocationId: invocation.id,
          approved: true,
        ),
        ToolApprovalResolution(
          interruptionId: required.interruption.id,
          toolInvocationId: ToolInvocationId('wrong-invocation'),
          approved: true,
        ),
      ]) {
        expect(
          () => run.resolveInterruption(resolution),
          throwsA(isA<InvalidRunOperation>()),
        );
      }
      await old.retire().timeout(_bound);
      expect(run.state, RunState.waiting);
      expect((await _snapshot(old.connection))['evaluations'], [
        _evaluation('ask', invocation, tool.effects, decision: 'ask'),
      ]);
      await old.close();
      final replacement = await start(
        exposures: [_exposure('policy', routeId: 'deny')],
      );
      expect(run.state, RunState.waiting);
      expect(await _snapshot(replacement.connection), _emptySnapshot);
      final resolved = run.resolveInterruption(
        ToolApprovalResolution(
          interruptionId: required.interruption.id,
          toolInvocationId: invocation.id,
          approved: approved,
        ),
      );
      if (approved) {
        final allowed = const ToolPolicyGate().approve(resolved);
        expect(allowed.invocation, same(invocation));
        expect(allowed.effects, same(required.effects));
        final observation = await collectToolExecution(
          run.startToolExecution(allowed).events(),
        );
        expect(observation.outcome.disposition, ToolOutcomeDisposition.success);
        expect(tool.executions, 1);
        expect(tool.executedArguments.single, same(invocation.arguments));
      } else {
        expect(
          () => const ToolPolicyGate().approve(resolved),
          throwsA(isA<InvalidRunOperation>()),
        );
        expect(tool.executions, 0);
      }
      expect(await _snapshot(replacement.connection), _emptySnapshot);
      final next = await resolve('2');
      expect(await evaluate(next), isA<ToolExecutionDenied>());
      expect((await _snapshot(replacement.connection))['evaluations'], [
        _evaluation('deny', next, tool.effects, decision: 'deny'),
      ]);
      expect(tool.executions, approved ? 1 : 0);
    });
  }

  for (final restriction in [
    ToolAuthorizationDecision.ask,
    ToolAuthorizationDecision.deny,
  ]) {
    test('remote Allow cannot override a local ${restriction.name}', () async {
      final probe = await start(exposures: [_exposure('allow')]);
      local('restriction', (_) => restriction);
      final invocation = await resolve();
      expect(
        await evaluate(invocation),
        restriction == ToolAuthorizationDecision.ask
            ? isA<ToolApprovalRequired>()
            : isA<ToolExecutionDenied>(),
      );
      expect((await _snapshot(probe.connection))['evaluations'], [
        _evaluation('allow', invocation, tool.effects),
      ]);
      expect(tool.executions, 0);
    });
  }

  for (final route in [
    'fail',
    'malformed-null',
    'malformed-map',
    'malformed-enum',
  ]) {
    test('$route is infrastructure failure, not Deny or execution', () async {
      final probe = await start(exposures: [_exposure(route)]);
      // A previous denial must not hide a failed participant.
      local('a-deny', (_) => ToolAuthorizationDecision.deny);
      final invocation = await resolve();
      await expectLater(
        evaluate(invocation),
        throwsA(
          isA<ToolPolicyEvaluationFailed>()
              .having((e) => e.effects, 'effects', same(tool.effects))
              .having(
                (e) => e.cause,
                'cause',
                route == 'fail'
                    ? isA<PluginRemoteFailure>().having(
                        (e) => e.code,
                        'code',
                        'internal_error',
                      )
                    : isA<AdeleProtocolException>(),
              ),
        ),
      );
      expect(tool.executions, 0);
      expect(run.interruptions, isEmpty);
      expect((await _snapshot(probe.connection))['evaluations'], [
        _evaluation(
          route,
          invocation,
          tool.effects,
          state: route == 'fail' ? 'failed' : 'completed',
        ),
      ]);
      expect(probe.connection.isClosed, isFalse);
    });
  }

  test('malformed raw requests never reach the generated evaluator', () async {
    final probe = await start(exposures: [_exposure('allow')]);
    final invocation = await resolve();
    final valid = _wireRequest(invocation, tool.effects);
    final malformed = <Map<String, Object?>>[
      {'routeId': 'allow'},
      {'routeId': 42, 'request': valid},
      {'routeId': 'allow', 'request': valid, 'hostInvocationContext': 'forged'},
      {
        'routeId': 'allow',
        'request': {...valid}..remove('projectId'),
      },
      {
        'routeId': 'allow',
        'request': {...valid, 'toolId': 42},
      },
      {
        'routeId': 'allow',
        'request': {...valid, 'runId': ''},
      },
      {
        'routeId': 'allow',
        'request': {...valid, 'canonicalArguments': <Object?>[]},
      },
      {
        'routeId': 'allow',
        'request': {
          ...valid,
          'hostServices': ['execute'],
        },
      },
      {
        'routeId': 'allow',
        'request': {
          ...valid,
          'effects': {
            ...valid['effects']! as Map<String, Object?>,
            'uncertainty': 'certain',
          },
        },
      },
    ];
    final channel = probe.connection.channelFor(
      probe.connection.defaultConfigurationContext,
      remoteToolAuthorizationPolicyServiceId,
    );
    for (final payload in malformed) {
      await expectLater(
        channel
            .request(remoteToolAuthorizationPolicyServiceEvaluateId, payload)
            .timeout(_bound),
        throwsA(
          isA<PluginRemoteFailure>().having(
            (e) => e.code,
            'code',
            'invalid_request',
          ),
        ),
      );
    }
    expect((await _snapshot(probe.connection))['evaluations'], isEmpty);
    expect(await evaluate(invocation), isA<ToolExecutionAllowed>());
    expect((await _snapshot(probe.connection))['evaluations'], [
      _evaluation('allow', invocation, tool.effects),
    ]);
    expect(tool.executions, 0);
  });

  for (final route in ['held-allow', 'held-fail']) {
    test('retirement fences $route without executing or retargeting', () async {
      final probe = await start(
        exposures: [_exposure('policy', routeId: route)],
      );
      final captured = extensions.discover(toolAuthorizationPolicies).single;
      final callback = captured.value.evaluate;
      final invocation = await resolve();
      var settled = false;
      final pending = evaluate(invocation).whenComplete(() => settled = true);
      final checked = expectLater(
        pending,
        throwsA(
          isA<ToolPolicyEvaluationFailed>().having(
            (e) => e.cause,
            'cause',
            route == 'held-allow'
                ? isA<StaleExtensionBinding>()
                : isA<PluginRemoteFailure>(),
          ),
        ),
      );
      await _control(probe.connection, 'ready', {'count': 1});
      expect(tool.executions, 0);
      expect((await _snapshot(probe.connection))['evaluations'], [
        _evaluation(route, invocation, tool.effects, state: 'held'),
      ]);
      await probe.retire().timeout(_bound);
      expect(probe.connection.isClosed, isFalse);
      expect(settled, isFalse);
      expect(extensions.discover(toolAuthorizationPolicies), isEmpty);
      expect(captured.validate, throwsA(isA<StaleExtensionBinding>()));
      // Keep the old connection alive to deliver a real late response while a
      // different backend generation already owns the same Extension ID.
      final replacement = await start(
        pluginId: '$_pluginId.replacement',
        exposures: [_exposure('policy', routeId: 'allow')],
      );
      expect(await _snapshot(replacement.connection), _emptySnapshot);
      await _control(probe.connection, 'release');
      await checked.timeout(_bound);
      expect((await _snapshot(probe.connection))['evaluations'], [
        _evaluation(
          route,
          invocation,
          tool.effects,
          state: route == 'held-allow' ? 'completed' : 'failed',
        ),
      ]);
      await probe.close();
      final request = ToolAuthorizationRequest(
        toolId: invocation.toolId,
        canonicalArguments: invocation.canonicalArguments,
        effects: tool.effects,
        runId: runId,
        sessionId: session.id,
        projectId: topology.task.projectId,
        toolInvocationId: invocation.id,
      );
      await expectLater(
        Future.sync(() => callback(request)),
        throwsA(isA<StaleExtensionBinding>()),
      );
      expect(await _snapshot(replacement.connection), _emptySnapshot);
      final fresh = extensions.discover(toolAuthorizationPolicies).single;
      expect(fresh.isSameRegistration(captured), isFalse);
      expect(await evaluate(await resolve('2')), isA<ToolExecutionAllowed>());
      expect(
        (await _snapshot(replacement.connection))['evaluations'],
        hasLength(1),
      );
      expect(tool.executions, 0);
      expect(run.interruptions, isEmpty);
    });
  }

  test(
    'captured membership excludes additions until the next evaluation',
    () async {
      final probe = await start(
        exposures: [_exposure('a', routeId: 'held-allow')],
      );
      final invocation = await resolve();
      final pending = evaluate(invocation);
      await _control(probe.connection, 'ready', {'count': 1});
      final added = await start(
        pluginId: '$_pluginId.added',
        exposures: [_exposure('z', routeId: 'deny')],
      );
      expect(await _snapshot(added.connection), _emptySnapshot);
      await _control(probe.connection, 'release');
      expect(await pending, isA<ToolExecutionAllowed>());
      expect(await _snapshot(added.connection), _emptySnapshot);
      expect(await evaluate(await resolve('2')), isA<ToolExecutionDenied>());
      expect((await _snapshot(added.connection))['evaluations'], hasLength(1));
      expect(tool.executions, 0);
    },
  );

  test(
    'retired captured later member cannot be replaced during a held evaluation',
    () async {
      final first = await start(
        exposures: [_exposure('a', routeId: 'held-allow')],
      );
      final later = await start(
        pluginId: '$_pluginId.later',
        exposures: [_exposure('z', routeId: 'allow')],
      );
      final pending = expectLater(
        evaluate(await resolve()),
        throwsA(
          isA<ToolPolicyEvaluationFailed>().having(
            (e) => e.cause,
            'cause',
            isA<StaleExtensionBinding>(),
          ),
        ),
      );
      await _control(first.connection, 'ready', {'count': 1});
      await later.close();
      final replacement = await start(
        pluginId: '$_pluginId.later',
        exposures: [_exposure('z', routeId: 'deny')],
      );
      await _control(first.connection, 'release');
      await pending.timeout(_bound);
      expect(await _snapshot(replacement.connection), _emptySnapshot);
      expect(await evaluate(await resolve('2')), isA<ToolExecutionDenied>());
      expect(
        (await _snapshot(replacement.connection))['evaluations'],
        hasLength(1),
      );
      expect(tool.executions, 0);
    },
  );

  test(
    'earlier completed remote member is revalidated after a later wait',
    () async {
      final earlier = await start(
        exposures: [_exposure('a', routeId: 'allow')],
      );
      final later = await start(
        pluginId: '$_pluginId.later',
        exposures: [_exposure('z', routeId: 'held-allow')],
      );
      final invocation = await resolve();
      final pending = expectLater(
        evaluate(invocation),
        throwsA(
          isA<ToolPolicyEvaluationFailed>().having(
            (e) => e.cause,
            'cause',
            isA<StaleExtensionBinding>(),
          ),
        ),
      );
      await _control(later.connection, 'ready', {'count': 1});
      expect((await _snapshot(earlier.connection))['evaluations'], [
        _evaluation('allow', invocation, tool.effects),
      ]);
      await earlier.retire();
      await _control(later.connection, 'release');
      await pending.timeout(_bound);
      expect(tool.executions, 0);
      expect(run.interruptions, isEmpty);
    },
  );

  test(
    'termination fails a held policy and isolates the sibling generation',
    () async {
      final probe = await start(
        exposures: [_exposure('a', routeId: 'held-allow')],
      );
      final captured = extensions.discover(toolAuthorizationPolicies).single;
      final pending = expectLater(
        evaluate(await resolve()),
        throwsA(
          isA<ToolPolicyEvaluationFailed>().having(
            (e) => e.cause,
            'cause',
            isA<PluginRemoteFailure>(),
          ),
        ),
      );
      await _control(probe.connection, 'ready', {'count': 1});
      final sibling = await start(
        pluginId: '$_pluginId.sibling',
        exposures: [_exposure('z', routeId: 'allow')],
      );
      final terminated = probe.connection.terminated.timeout(_bound);
      await expectLater(
        _control(probe.connection, 'terminate'),
        throwsA(isA<PluginRemoteFailure>()),
      );
      await terminated;
      await pending.timeout(_bound);
      expect(captured.validate, throwsA(isA<StaleExtensionBinding>()));
      expect(probe.connection.isClosed, isTrue);
      expect(await _snapshot(sibling.connection), _emptySnapshot);
      expect(await evaluate(await resolve('2')), isA<ToolExecutionAllowed>());
      expect(
        (await _snapshot(sibling.connection))['evaluations'],
        hasLength(1),
      );
      expect(host.isClosed, isFalse);
      expect(tool.executions, 0);
    },
  );

  final invalid = <String, Map<String, Object?>>{
    for (final service in [
      'other',
      'toolAuthorizationPolicy.extra',
      'ToolAuthorizationPolicy',
    ])
      'service $service': _exposure('bad', serviceId: service),
    'missing route': _exposure('bad', metadata: {}),
    'non-string route': _exposure('bad', metadata: {'routeId': 42}),
    'extra authority': _exposure(
      'bad',
      metadata: {'routeId': 'allow', 'hostInvocationContext': 'forged'},
    ),
    'extra configuration selector': _exposure(
      'bad',
      metadata: {'routeId': 'allow', 'configurationContext': 'other'},
    ),
    for (final route in <String, String>{
      'empty': '',
      'blank': ' ',
      'slash': 'route/name',
      'non-ASCII': 'rout\u00e9',
      'control': 'route\n',
      'too long': 'r' * 257,
      'leading punctuation': '.route',
    }.entries)
      '${route.key} route': _exposure('bad', routeId: route.value),
  };
  for (final entry in invalid.entries) {
    test(
      'invalid ${entry.key} rolls back preceding advertised registrations',
      () async {
        local('unrelated', (_) => ToolAuthorizationDecision.allow);
        final retained = extensions.discover(toolAuthorizationPolicies).single;
        final connection = await connect(
          exposures: [
            _exposure('partial', routeId: 'allow'),
            entry.value,
          ],
        );
        await expectLater(
          activate(connection),
          throwsA(isA<ExtensionContractException>()),
        );
        expect(connection.isClosed, isTrue);
        expect(
          extensions
              .discover(toolAuthorizationPolicies)
              .single
              .isSameRegistration(retained),
          isTrue,
        );
        expect(retained.validate, returnsNormally);
        expect(host.isClosed, isFalse);
        final healthy = await start(
          exposures: [_exposure('partial', routeId: 'allow')],
        );
        expect(extensions.discover(toolAuthorizationPolicies), hasLength(2));
        expect(await _snapshot(healthy.connection), _emptySnapshot);
        expect(await evaluate(await resolve()), isA<ToolExecutionAllowed>());
        expect(tool.executions, 0);
      },
    );
  }
}

const _arguments = <String, Object?>{
  'path': 'source.dart',
  'normalized': true,
  'count': 7,
  'ratio': 1.25,
  'optional': null,
  'nested': {
    'values': ['exact', false, 3, null],
  },
};

const _emptySnapshot = <String, Object?>{
  'requests': <Object?>[],
  'evaluations': <Object?>[],
};

Map<String, Object?> _exposure(
  String name, {
  String? routeId,
  String configuration = 'default',
  String serviceId = remoteToolAuthorizationPolicyServiceId,
  Map<String, Object?>? metadata,
}) => {
  'extensionPointId': toolAuthorizationPolicies.value,
  'extensionId': '$_pluginId.registration.$name',
  'serviceId': serviceId,
  'configurationContext': configuration,
  'metadata': metadata ?? {'routeId': routeId ?? name},
};

Map<String, Object?> _wireRequest(
  ToolInvocation invocation,
  EffectDescription effects,
) => {
  'toolId': 'dev.test.tool.read',
  'canonicalArguments': _arguments,
  'effects': {
    'effects': effects.effects.map((e) => e.name).toList(),
    'targetUris': effects.targets.map((t) => t.uri.toString()).toList(),
    'summary': effects.summary,
    'uncertainty': effects.uncertainty.name,
  },
  'runId': 'authorization-run',
  'sessionId': 'authorization-session',
  'projectId': 'project-authorization-session',
  'toolInvocationId': invocation.id.value,
};

Map<String, Object?> _request(
  String route,
  ToolInvocation invocation,
  EffectDescription effects, {
  String configuration = 'default',
}) => {
  'configurationContext': configuration,
  'serviceId': remoteToolAuthorizationPolicyServiceId,
  'method': remoteToolAuthorizationPolicyServiceEvaluateId,
  'payload': {'routeId': route, 'request': _wireRequest(invocation, effects)},
};

Map<String, Object?> _evaluation(
  String route,
  ToolInvocation invocation,
  EffectDescription effects, {
  String configuration = 'default',
  String state = 'completed',
  String decision = 'allow',
}) => {
  'configurationContext': configuration,
  'routeId': route,
  'request': _wireRequest(invocation, effects),
  'state': state,
  if (state == 'completed') 'decision': decision,
};

Future<Object?> _control(
  PluginBackendConnection connection,
  String method, [
  Map<String, Object?> payload = const {},
]) => connection
    .channelFor(connection.defaultConfigurationContext, 'probe')
    .request(method, payload)
    .timeout(_bound);

Future<Map<String, Object?>> _snapshot(
  PluginBackendConnection connection,
) async =>
    Map<String, Object?>.from(await _control(connection, 'snapshot') as Map);

final class _Tool implements ToolExecutable {
  EffectDescription effects = EffectDescription(
    effects: [ToolEffect.sourceRead],
    targets: [EffectTarget(uri: Uri.parse('file:///source.dart'))],
    summary: 'Read source.',
  );
  int executions = 0;
  final executedArguments = <CanonicalToolArguments>[];
  final executedContexts = <ToolExecutionContext>[];

  @override
  void validateBinding() {}

  @override
  CanonicalToolArguments validateAndNormalize(Map<String, Object?> arguments) =>
      CanonicalToolArguments({
        ..._arguments,
        'path': (arguments['path']! as String).trim(),
      });

  @override
  Future<EffectDescription> describe(
    CanonicalToolArguments arguments,
    ToolExecutionContext context,
  ) async => effects;

  @override
  Stream<ToolExecutionEvent> execute(
    CanonicalToolArguments arguments,
    ToolExecutionContext context,
  ) async* {
    executions++;
    executedArguments.add(arguments);
    executedContexts.add(context);
    yield ToolExecutionTerminal(
      ToolOutcome(
        disposition: ToolOutcomeDisposition.success,
        effectCertainty: EffectCertainty.knownOccurred,
        modelContent: 'Read completed.',
      ),
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
