@Timeout(Duration(minutes: 3))
library;

import 'dart:async';
import 'dart:io';

import 'package:adele_capabilities/adele_capabilities.dart';
import 'package:adele_contract/adele_contract.dart';
import 'package:adele_desktop/core/adele_runtime.dart';
import 'package:adele_desktop/core/application_plugin_bootstrap.dart';
import 'package:adele_desktop/core/approval_gated_tool_policy.dart';
import 'package:adele_desktop/core/prepared_settings.dart';
import 'package:adele_desktop/core/tool_authorization_policy_composer.dart';
import 'package:adele_desktop/ui/execution/session_execution_controller.dart';
import 'package:adele_environment/adele_environment.dart';
import 'package:adele_model_provider/adele_model_provider.dart';
import 'package:adele_orchestration/adele_orchestration.dart';
import 'package:adele_orchestration/remote_tool_authorization.dart';
import 'package:adele_plugin_api/adele_plugin_api.dart';
import 'package:agent_kernel/agent_kernel.dart';
import 'package:chat_strategy_backend/chat_strategy_backend.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plugin_builder/plugin_builder.dart';
import 'package:plugin_runtime/plugin_runtime.dart';

import '../../../tools/backend_artifacts.dart';

const _pluginId = 'dev.adele.plugin.conservative-tool-policy';
const _extensionId = '$_pluginId.authorization';
const _bound = Duration(seconds: 10);
final _runId = RunId('policy-parity');
final _modelId = ProviderId('dev.adele.test.policy-model');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory artifacts;
  late Directory installations;
  late Directory emptyInstallations;
  late File hostArtifact;
  late String aotRuntime;

  setUpAll(() async {
    artifacts = await Directory.systemTemp.createTemp('adele-stock-policy-');
    addTearDown(() => artifacts.delete(recursive: true));
    installations = Directory.fromUri(artifacts.uri.resolve('installations/'));
    emptyInstallations = await Directory.fromUri(
      artifacts.uri.resolve('empty/'),
    ).create();
    final dart = File.fromUri(
      Directory(
        Platform.environment['FLUTTER_ROOT']!,
      ).uri.resolve('bin/cache/dart-sdk/bin/dart'),
    );
    aotRuntime = File.fromUri(dart.parent.uri.resolve('dartaotruntime')).path;
    hostArtifact = File.fromUri(artifacts.uri.resolve('host.aot'));
    final backend = File.fromUri(
      installations.uri.resolve('conservative-tool-policy/backend.aot'),
    );
    for (final target in [
      (
        entrypoint: 'packages/plugin_backend_host/bin/adele_backend_host.dart',
        artifact: hostArtifact,
      ),
      (
        entrypoint:
            'plugins/conservative_tool_policy/packages/backend/bin/conservative_tool_policy_backend.dart',
        artifact: backend,
      ),
    ]) {
      await compileAotSnapshot(
        dartExecutable: dart.path,
        workingDirectory: Directory.current.parent,
        entrypoint: target.entrypoint,
        artifact: target.artifact,
        stage: 'stock-policy-integration',
      );
    }
    await publishStockPluginInstallation(
      repositoryRoot: Directory.current.parent,
      installationDirectory: backend.parent,
      pluginId: _pluginId,
      displayName: 'Conservative Tool Policy',
      backend: true,
    );
  });

  late AdeleRuntime runtime;
  late ChatStrategyPlugin chat;
  late Session session;
  late _Tool tool;
  late _Channels channels;

  setUp(() async {
    runtime = AdeleRuntime();
    addTearDown(runtime.close);
    chat = ChatStrategyPlugin(maxModelInvocations: 2);
    addTearDown(chat.activate(runtime.extensions).close);
    tool = _Tool();
    channels = _Channels();
    addTearDown(
      runtime.extensions
          .register(
            point: modelToolContributions,
            id: ExtensionId('dev.adele.test.policy-tool'),
            value: tool,
          )
          .close,
    );
    for (final provider in [
      ProviderDescriptor(
        id: _modelId,
        capability: modelProviderCapability,
        pluginId: 'dev.adele.test.model',
        displayName: 'Local deterministic model',
        serviceId: modelProviderServiceId,
      ),
      ProviderDescriptor(
        id: ProviderId('dev.adele.test.environment'),
        capability: environmentProviderCapability,
        pluginId: 'dev.adele.test.environment',
        displayName: 'Fixture Environment',
        serviceId: environmentProviderServiceId,
      ),
    ]) {
      addTearDown(
        runtime.registry
            .register(
              provider: provider,
              endpoint: AdeleRequestChannelEndpoint(
                channel: channels,
                serviceId: provider.serviceId,
                isAvailable: () => true,
              ),
            )
            .close,
      );
    }
    final project = runtime.lifecycle.createProject(
      Uri.parse('file:///fixture'),
    );
    final task = await runtime.lifecycle.createTask(
      projectId: project.id,
      title: 'Stock authorization',
    );
    session = runtime.lifecycle.createSession(
      taskId: task.task.id,
      strategyId: chatStrategyId,
    );
  });

  Future<ApplicationPluginBootstrap> start({
    bool installed = true,
    ApplicationPluginBootstrap? bootstrap,
  }) async {
    final plugins = bootstrap ?? runtime.plugins;
    plugins.configureSettingsLoader(
      (catalog) async => PreparedSettingsSnapshot.resolve(catalog),
    );
    await plugins.start(
      installationRoot: (installed ? installations : emptyInstallations).path,
      dartaotruntimeExecutable: aotRuntime,
      hostArtifactPath: hostArtifact.path,
      startupArguments: const {},
    );
    expect(plugins.state, ApplicationPluginState.ready);
    expect(plugins.catalog!.issues, isEmpty);
    expect(plugins.backends, hasLength(installed ? 1 : 0));
    if (installed) {
      final backend = plugins.backends.single;
      expect(
        backend.state,
        InstalledBackendState.active,
        reason: '${backend.failure}',
      );
      expect(backend.installation.metadata.id.value, _pluginId);
      expect(backend.installation.authorizationPolicies, [
        ExtensionId(_extensionId),
      ]);
      expect(plugins.expectedToolAuthorizationPolicies, {
        backend.installation: [ExtensionId(_extensionId)],
      });
      expect(backend.installation.frontend, isNull);
      expect(
        backend.installation.backendArtifactUri!.path,
        endsWith('/installations/conservative-tool-policy/backend.aot'),
      );
      expect(backend.connection!.capabilityExposures, isEmpty);
      expect(backend.connection!.extensionExposures.map((e) => e.toMap()), [
        {
          'extensionPointId': toolAuthorizationPolicies.value,
          'extensionId': _extensionId,
          'serviceId': remoteToolAuthorizationPolicyServiceId,
          'configurationContext': 'default',
          'metadata': {'routeId': 'conservative'},
        },
      ]);
      expect(
        runtime.extensions
            .discover(toolAuthorizationPolicies)
            .where((binding) => binding.id.value == _extensionId),
        hasLength(1),
      );
    } else {
      expect(plugins.host, isNull);
      expect(plugins.expectedToolAuthorizationPolicies, isEmpty);
      expect(runtime.extensions.discover(toolAuthorizationPolicies), isEmpty);
    }
    return plugins;
  }

  Future<ToolInvocation> resolve() async {
    final result = await const ToolInvocationResolver().resolve(
      invocationId: ToolInvocationId('policy-invocation'),
      proposal: ProviderToolProposal(
        providerCallId: 'proposal',
        alias: 'harmless_read',
        arguments: const {'command': '  echo harmless  ', 'ignored': true},
      ),
      tools: MaterializedToolSet([
        MaterializedTool(
          definition: tool.definition,
          modelDefinition: tool.modelDefinition,
          executable: tool,
        ),
      ]),
      runId: _runId,
      sessionId: session.id,
    );
    return (result as ResolvedToolProposal).invocation;
  }

  ToolAuthorizationPolicyComposer composer({
    bool legacy = true,
    ApplicationPluginBootstrap? plugins,
  }) => ToolAuthorizationPolicyComposer(
    extensions: runtime.extensions,
    plugins: plugins ?? runtime.plugins,
    lifecycle: runtime.lifecycle,
    session: session,
    runId: _runId,
    legacyPolicy: legacy ? const ApprovalGatedToolPolicy() : null,
  );

  for (final failure in ['startup', 'termination']) {
    test(
      'expected stock $failure fails normal authorization even with Deny',
      () async {
        if (failure == 'startup') {
          runtime.plugins.configureSettingsLoader(
            (catalog) async => PreparedSettingsSnapshot.resolve(catalog),
          );
          await runtime.plugins.start(
            installationRoot: installations.path,
            dartaotruntimeExecutable: aotRuntime,
            hostArtifactPath: hostArtifact.path,
            // The actual stock entrypoint rejects arguments before advertising ready.
            startupArguments: const {
              _pluginId: ['unsupported'],
            },
          );
          expect(runtime.plugins.state, ApplicationPluginState.ready);
          expect(
            runtime.plugins.backends.single.state,
            InstalledBackendState.failed,
          );
        } else {
          await start();
          final backend = runtime.plugins.backends.single;
          final terminated = runtime.plugins.changes.firstWhere(
            (_) => backend.state == InstalledBackendState.terminated,
          );
          await backend.connection!.close();
          await terminated.timeout(_bound);
        }
        expect(runtime.plugins.expectedToolAuthorizationPolicies, hasLength(1));
        expect(runtime.extensions.discover(toolAuthorizationPolicies), isEmpty);
        addTearDown(
          runtime.extensions
              .register(
                point: toolAuthorizationPolicies,
                id: ExtensionId('dev.adele.test.independent-deny'),
                value: ToolAuthorizationPolicyContribution(
                  evaluate: (_) => ToolAuthorizationDecision.deny,
                ),
              )
              .close,
        );
        tool.effects = _effects([ToolEffect.sourceMutation]);
        chat.sessions
            .obtain(session.id)
            .appendUserMessage('Exercise the tool.');
        final controller = SessionExecutionController(
          runtime: runtime,
          session: session,
          providerId: _modelId,
          model: 'fixture-model',
        );
        addTearDown(controller.close);
        final runId = await controller.startRun();
        await controller.activeRunFuture;
        final outcome = controller.activityForRun(runId)!.tools.single.outcome!;
        expect(outcome.disposition, ToolOutcomeDisposition.failure);
        expect(outcome.failureKind, ToolFailureKind.infrastructure);
        expect(outcome.effectCertainty, EffectCertainty.knownNotOccurred);
        expect(controller.pendingApproval, isNull);
        expect(tool.executions, 0);
      },
    );
  }

  test(
    'expected stock and independent native policies compose normally',
    () async {
      await start();
      final invocation = await resolve();
      final input = ToolPolicyInput(
        invocation: invocation,
        effects: tool.effects,
        context: invocation.context,
      );
      for (final decision in ToolAuthorizationDecision.values) {
        var calls = 0;
        final registration = runtime.extensions.register(
          point: toolAuthorizationPolicies,
          id: ExtensionId('dev.adele.test.independent-policy'),
          value: ToolAuthorizationPolicyContribution(
            evaluate: (_) {
              calls++;
              return decision;
            },
          ),
        );
        addTearDown(registration.close);
        expect(await composer().evaluate(input), switch (decision) {
          ToolAuthorizationDecision.deny => ToolPolicyDecision.deny,
          ToolAuthorizationDecision.ask => ToolPolicyDecision.ask,
          _ => ToolPolicyDecision.allow,
        });
        expect(calls, 1);
        await registration.close();
      }
    },
  );

  test(
    'prepared AOT policy independently matches all 32 legacy decisions',
    () async {
      await start();
      final binding = runtime.extensions
          .discover(toolAuthorizationPolicies)
          .single;
      final invocation = await resolve();
      final totals = <String, int>{};
      expect(ToolEffect.values, hasLength(4));
      expect(EffectUncertainty.values, hasLength(2));
      for (var mask = 0; mask < 1 << ToolEffect.values.length; mask++) {
        for (final uncertainty in EffectUncertainty.values) {
          final effects = _effects([
            for (final effect in ToolEffect.values)
              if (mask & (1 << effect.index) != 0) effect,
          ], uncertainty);
          final input = ToolPolicyInput(
            invocation: invocation,
            effects: effects,
            context: invocation.context,
          );
          final expected = const ApprovalGatedToolPolicy().evaluate(input);
          // Compare the actual remote opinion, not a restrictive composed result
          // that could hide a too-permissive stock implementation (or Abstain).
          final actual = await binding.value.evaluate(
            ToolAuthorizationRequest(
              toolId: invocation.toolId,
              canonicalArguments: invocation.canonicalArguments,
              effects: effects,
              runId: _runId,
              sessionId: session.id,
              projectId: runtime.store.task(session.taskId)!.projectId,
              toolInvocationId: invocation.id,
            ),
          );
          expect(
            actual.name,
            expected.name,
            reason: 'mask=$mask ${uncertainty.name}',
          );
          expect(await composer(legacy: false).evaluate(input), expected);
          expect(await composer().evaluate(input), expected);
          totals.update(actual.name, (n) => n + 1, ifAbsent: () => 1);
        }
      }
      expect(totals, {'allow': 2, 'ask': 3, 'deny': 27});
      expect(tool.executions, 0);
      expect(channels.environmentRequests, 1); // Product setup only.
      expect(channels.modelRequests, isEmpty);
    },
  );

  for (final installed in [true, false]) {
    for (final effects in [
      _effects([ToolEffect.sourceRead]),
      _effects([ToolEffect.sourceMutation]),
      _effects([ToolEffect.processExecution], EffectUncertainty.uncertain),
      _effects([ToolEffect.sourceRead, ToolEffect.sourceMutation]),
    ]) {
      test('normal Chat authorization/continuation for ${effects.effects} '
          '(stock installed=$installed)', () async {
        await start(installed: installed);
        tool.effects = effects;
        final invocation = await resolve();
        final expected = const ApprovalGatedToolPolicy().evaluate(
          ToolPolicyInput(
            invocation: invocation,
            effects: effects,
            context: invocation.context,
          ),
        );
        chat.sessions
            .obtain(session.id)
            .appendUserMessage('Exercise the tool.');
        final controller = SessionExecutionController(
          runtime: runtime,
          session: session,
          providerId: _modelId,
          model: 'fixture-model',
        );
        addTearDown(controller.close);
        final runId = await controller.startRun();
        await controller.activeRunFuture;
        if (expected == ToolPolicyDecision.ask) {
          expect(controller.stateForRun(runId), RunState.waiting);
          expect(tool.executions, 0);
          final approval = controller.pendingApproval!;
          // A completed decision retains its invocation through stock retirement.
          if (installed) {
            await runtime.plugins.close();
            expect(
              runtime.extensions.discover(toolAuthorizationPolicies),
              isEmpty,
            );
          }
          expect(controller.resolveApproval(approval, approved: true), isTrue);
          await controller.activeRunFuture;
        }
        expect(controller.failure, isNull);
        expect(controller.stateForRun(runId), RunState.completed);
        expect(controller.pendingApproval, isNull);
        expect(tool.executions, expected == ToolPolicyDecision.deny ? 0 : 1);
        expect(channels.modelRequests, hasLength(2));
        final input = channels.modelRequests.last['input']! as List<Object?>;
        final outcome =
            input.cast<Map<String, Object?>>().singleWhere(
                  (item) => item['kind'] == 'toolOutcome',
                )['toolOutcome']
                as Map<String, Object?>;
        expect(
          outcome['status'],
          expected == ToolPolicyDecision.deny ? 'rejected' : 'success',
        );
        expect(channels.environmentRequests, 1);
      });
    }
  }

  test(
    'stock retirement invalidates unresolved composition without retargeting',
    () async {
      await start();
      final old = runtime.extensions.discover(toolAuthorizationPolicies).single;
      final entered = Completer<void>();
      final release = Completer<void>();
      addTearDown(() {
        if (!release.isCompleted) release.complete();
      });
      final later = runtime.extensions.register(
        point: toolAuthorizationPolicies,
        id: ExtensionId('dev.adele.test.later-policy'),
        value: ToolAuthorizationPolicyContribution(
          evaluate: (_) async {
            if (!entered.isCompleted) entered.complete();
            await release.future;
            return ToolAuthorizationDecision.abstain;
          },
        ),
      );
      addTearDown(later.close);
      // A legacy and stock Deny must not hide infrastructure failure.
      tool.effects = _effects(ToolEffect.values);
      final invocation = await resolve();
      Future<ToolPolicyGateResult> evaluate({
        ApplicationPluginBootstrap? plugins,
      }) => const ToolPolicyGate().evaluate(
        invocation: invocation,
        policy: composer(plugins: plugins),
        interruptionId: RunInterruptionId('retirement'),
      );
      final pending = expectLater(
        evaluate(),
        throwsA(
          isA<ToolPolicyEvaluationFailed>().having(
            (e) => e.cause,
            'cause',
            isA<StaleExtensionBinding>(),
          ),
        ),
      );
      // The actual AOT evaluation has completed, but its composed request has not.
      await entered.future.timeout(_bound);
      await runtime.plugins.close();
      expect(
        runtime.extensions
            .discover(toolAuthorizationPolicies)
            .map((e) => e.id.value),
        ['dev.adele.test.later-policy'],
      );
      expect(old.validate, throwsA(isA<StaleExtensionBinding>()));
      final replacement = ApplicationPluginBootstrap(
        runtime.registry,
        runtime.extensions,
      );
      addTearDown(replacement.close);
      // This uses normal bootstrap again, not a manually retargeted contribution.
      await start(bootstrap: replacement);
      final fresh = runtime.extensions
          .discover(toolAuthorizationPolicies)
          .singleWhere((binding) => binding.id.value == _extensionId);
      expect(fresh.isSameRegistration(old), isFalse);
      release.complete();
      await pending.timeout(_bound);
      // The retired authoritative snapshot cannot borrow a foreign installation,
      // even if its metadata, artifact, and Extension ID are identical.
      await expectLater(evaluate(), throwsA(isA<ToolPolicyEvaluationFailed>()));
      expect(await evaluate(plugins: replacement), isA<ToolExecutionDenied>());
      expect(tool.executions, 0);
    },
  );

  test(
    'stock generated service rejects unsupported routes and malformed requests',
    () async {
      final plugins = await start();
      final connection = plugins.backends.single.connection!;
      final channel = connection.channelFor(
        connection.defaultConfigurationContext,
        remoteToolAuthorizationPolicyServiceId,
      );
      final request = RemoteToolAuthorizationRequest.fromLocal(
        ToolAuthorizationRequest(
          toolId: tool.definition.id,
          canonicalArguments: const {'command': 'echo harmless'},
          effects: tool.effects,
          runId: _runId,
          sessionId: session.id,
          projectId: runtime.store.task(session.taskId)!.projectId,
          toolInvocationId: ToolInvocationId('invalid-request'),
        ),
      );
      final client = RemoteToolAuthorizationPolicyServiceClient(channel);
      await expectLater(
        client.evaluate('unknown', request),
        throwsA(
          isA<PluginRemoteFailure>().having(
            (e) => e.code,
            'code',
            'internal_error',
          ),
        ),
      );
      await expectLater(
        channel.request(remoteToolAuthorizationPolicyServiceEvaluateId, {
          'routeId': 'conservative',
          'request': {
            'toolId': request.toolId,
            'canonicalArguments': request.canonicalArguments,
            'effects': <String, Object?>{},
            'runId': request.runId,
            'sessionId': request.sessionId,
            'projectId': request.projectId,
            'toolInvocationId': request.toolInvocationId,
          },
        }),
        throwsA(
          isA<PluginRemoteFailure>().having(
            (e) => e.code,
            'code',
            'invalid_request',
          ),
        ),
      );
      expect(
        await client.evaluate('conservative', request),
        RemoteToolAuthorizationDecision.allow,
      );
      expect(tool.executions, 0);
    },
  );
}

EffectDescription _effects(
  Iterable<ToolEffect> effects, [
  EffectUncertainty uncertainty = EffectUncertainty.none,
]) => EffectDescription(
  effects: effects,
  targets: [EffectTarget(uri: Uri.parse('file:///source.dart'))],
  summary: 'A harmless read, regardless of authoritative effects.',
  uncertainty: uncertainty,
);

final class _Tool implements ModelToolContribution, ToolExecutable {
  final definition = ToolDefinition(
    id: ToolId('dev.adele.test.read'),
    description: 'Read only',
  );
  final modelDefinition = ModelToolDefinition(
    alias: 'harmless_read',
    description: 'Read only',
    argumentsSchema: const {'type': 'object'},
  );
  EffectDescription effects = _effects([ToolEffect.sourceRead]);
  int executions = 0;

  @override
  Future<Iterable<ToolRegistration>> materialize(
    ModelToolHostContext context,
  ) async => [
    ToolRegistration(
      definition: definition,
      modelDefinition: modelDefinition,
      executable: this,
    ),
  ];

  @override
  void validateBinding() {}

  @override
  CanonicalToolArguments validateAndNormalize(Map<String, Object?> arguments) =>
      CanonicalToolArguments({
        'command': (arguments['command']! as String).trim(),
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
    expect(arguments.snapshot, {'command': 'echo harmless'});
    executions++;
    yield ToolExecutionTerminal(
      ToolOutcome(
        disposition: ToolOutcomeDisposition.success,
        effectCertainty: EffectCertainty.knownOccurred,
        modelContent: 'Executed fixture operation.',
      ),
    );
  }
}

// Only product establishment and deterministic model output are substituted.
// Policy transport/bootstrap, Chat sequencing, and host authorization are real.
final class _Channels implements AdeleStreamChannel {
  int environmentRequests = 0;
  final modelRequests = <Map<String, Object?>>[];

  @override
  Future<Object?> request(String method, Map<String, Object?> payload) async {
    expect(method, environmentProviderServiceEstablishId);
    environmentRequests++;
    return {'providerState': <String, Object?>{}, 'initialState': null};
  }

  @override
  Stream<Object?> stream(String method, Map<String, Object?> payload) async* {
    expect(method, modelProviderServiceInvokeId);
    modelRequests.add(payload['request']! as Map<String, Object?>);
    if (modelRequests.length == 1) {
      yield {
        'kind': 'output',
        'observation': null,
        'terminal': null,
        'output': {
          'kind': 'toolProposal',
          'text': null,
          'toolProposal': {
            'callId': 'proposal',
            'name': 'harmless_read',
            'arguments': {'command': '  echo harmless  ', 'ignored': true},
          },
          'itemId': 'proposal',
          'nativeMetadata': null,
          'nativePresentation': null,
        },
      };
    } else {
      yield {
        'kind': 'output',
        'observation': null,
        'terminal': null,
        'output': {
          'kind': 'text',
          'text': 'Tool outcome received.',
          'toolProposal': null,
          'itemId': 'answer',
          'nativeMetadata': null,
          'nativePresentation': null,
        },
      };
    }
    yield {
      'kind': 'terminal',
      'observation': null,
      'output': null,
      'terminal': {
        'settlement': 'completed',
        'incompleteReason': null,
        'failure': null,
        'providerStopReason': 'stop',
        'usage': null,
        'effectiveModel': 'fixture-model',
        'responseId': 'fixture-response',
        'requestId': null,
        'nativeState': null,
        'affinityState': null,
      },
    };
  }
}
