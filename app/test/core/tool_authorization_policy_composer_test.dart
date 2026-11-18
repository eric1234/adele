import 'dart:async';

import 'package:adele_capabilities/adele_capabilities.dart';
import 'package:adele_desktop/core/application_plugin_bootstrap.dart';
import 'package:adele_desktop/core/tool_authorization_policy_composer.dart';
import 'package:adele_orchestration/adele_orchestration.dart';
import 'package:adele_plugin_api/adele_plugin_api.dart';
import 'package:agent_kernel/agent_kernel.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/orchestration_test_lifecycle.dart';

void main() {
  late ExtensionRegistry extensions;
  late OrchestrationTestLifecycle topology;
  late Session session;
  late ToolInvocation invocation;
  late ToolPolicyInput input;
  late ToolAuthorizationPolicyComposer composer;
  final runId = RunId('authorization-run');

  ExtensionRegistration register(
    String suffix,
    FutureOr<ToolAuthorizationDecision> Function(ToolAuthorizationRequest)
    evaluate,
  ) {
    final registration = extensions.register(
      point: toolAuthorizationPolicies,
      id: ExtensionId('dev.test.policy.$suffix'),
      value: ToolAuthorizationPolicyContribution(evaluate: evaluate),
    );
    addTearDown(registration.close);
    return registration;
  }

  setUp(() async {
    extensions = ExtensionRegistry();
    final strategyId = OrchestrationStrategyId('dev.test.strategy');
    final registration = extensions.register(
      point: orchestrationStrategyContributions,
      id: ExtensionId('dev.test.strategy'),
      value: OrchestrationStrategyContribution(
        strategyId: strategyId,
        materialize: (_) => throw StateError('No strategy execution needed.'),
      ),
    );
    addTearDown(registration.close);
    topology = await OrchestrationTestLifecycle.create(
      extensions,
      SessionId('authorization-session'),
    );
    addTearDown(topology.lifecycle.close);
    session = topology.createSession(strategyId);
    final resolution = await const ToolInvocationResolver().resolve(
      invocationId: ToolInvocationId('authorization-invocation'),
      proposal: ProviderToolProposal(
        providerCallId: 'provider-call',
        alias: 'alias_is_not_identity',
        arguments: {'path': '  source.dart  '},
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
          executable: _Tool(),
        ),
      ]),
      runId: runId,
      sessionId: session.id,
    );
    invocation = (resolution as ResolvedToolProposal).invocation;
    input = ToolPolicyInput(
      invocation: invocation,
      effects: _effects,
      context: invocation.context,
    );
    composer = ToolAuthorizationPolicyComposer(
      extensions: extensions,
      lifecycle: topology.lifecycle,
      session: session,
      runId: runId,
    );
  });

  test('zero standalone contributions allow', () async {
    expect(await composer.evaluate(input), ToolPolicyDecision.allow);
  });

  test(
    'empty prepared participation does not require a stock implementation',
    () async {
      final plugins = ApplicationPluginBootstrap(
        CapabilityRegistry(),
        extensions,
      );
      addTearDown(plugins.close);
      composer = ToolAuthorizationPolicyComposer(
        extensions: extensions,
        plugins: plugins,
        lifecycle: topology.lifecycle,
        session: session,
        runId: runId,
      );
      await expectLater(composer.evaluate(input), throwsStateError);
      await plugins.start(installationRoot: '');
      expect(plugins.expectedToolAuthorizationPolicies, isEmpty);
      expect(await composer.evaluate(input), ToolPolicyDecision.allow);
      register('independent', (_) => ToolAuthorizationDecision.ask);
      expect(await composer.evaluate(input), ToolPolicyDecision.ask);
    },
  );

  // Every ordered combination through three participants, including repeated
  // opinions and all-abstain, exercises precedence independently of order.
  final combinations = <List<ToolAuthorizationDecision>>[
    for (final a in ToolAuthorizationDecision.values) [a],
    for (final a in ToolAuthorizationDecision.values)
      for (final b in ToolAuthorizationDecision.values) [a, b],
    for (final a in ToolAuthorizationDecision.values)
      for (final b in ToolAuthorizationDecision.values)
        for (final c in ToolAuthorizationDecision.values) [a, b, c],
  ];
  for (final decisions in combinations) {
    test('composes ${decisions.map((d) => d.name).join(', ')}', () async {
      final seen = <int>[];
      for (var i = 0; i < decisions.length; i++) {
        register('participant-$i', (_) {
          seen.add(i);
          return decisions[i];
        });
      }
      expect(
        await composer.evaluate(input),
        decisions.contains(ToolAuthorizationDecision.deny)
            ? ToolPolicyDecision.deny
            : decisions.contains(ToolAuthorizationDecision.ask)
            ? ToolPolicyDecision.ask
            : ToolPolicyDecision.allow,
      );
      expect(seen, List.generate(decisions.length, (i) => i));
    });
  }

  test(
    'passes only normalized semantic data and canonical graph IDs',
    () async {
      register('inspect', (request) {
        expect(request.toolId, invocation.toolId);
        expect(request.toolInvocationId, invocation.id);
        expect(request.runId, runId);
        expect(request.sessionId, session.id);
        expect(request.projectId, topology.task.projectId);
        expect(request.canonicalArguments, {'path': 'source.dart'});
        expect(request.effects, same(input.effects));
        expect(
          () => request.canonicalArguments.clear(),
          throwsUnsupportedError,
        );
        return ToolAuthorizationDecision.allow;
      });
      expect(await composer.evaluate(input), ToolPolicyDecision.allow);
    },
  );

  test(
    'evaluates sequentially in Extension ID order, not registration order',
    () async {
      final entered = Completer<void>();
      final pending = Completer<ToolAuthorizationDecision>();
      final seen = <String>[];
      register('z', (_) {
        seen.add('z');
        return ToolAuthorizationDecision.ask;
      });
      register('a', (_) {
        seen.add('a');
        entered.complete();
        return pending.future;
      });
      register('m', (_) {
        seen.add('m');
        return ToolAuthorizationDecision.allow;
      });
      final result = composer.evaluate(input);
      await entered.future;
      expect(seen, ['a']);
      pending.complete(ToolAuthorizationDecision.allow);
      expect(await result, ToolPolicyDecision.ask);
      expect(seen, ['a', 'm', 'z']);
    },
  );

  for (final asynchronous in [false, true]) {
    test(
      'preserves ${asynchronous ? 'async' : 'sync'} exception after Deny',
      () async {
        final error = StateError('Policy unavailable');
        register('a-deny', (_) => ToolAuthorizationDecision.deny);
        register('z-failure', (_) {
          if (asynchronous) {
            return Future<ToolAuthorizationDecision>.error(error);
          }
          throw error;
        });
        await expectLater(composer.evaluate(input), throwsA(same(error)));
      },
    );
  }

  for (final replace in [false, true]) {
    test(
      'retirement during evaluation fails${replace ? ' despite same-ID replacement' : ''}',
      () async {
        final entered = Completer<void>();
        final pending = Completer<ToolAuthorizationDecision>();
        final original = register('pending', (_) {
          entered.complete();
          return pending.future;
        });
        final result = composer.evaluate(input);
        final checked = expectLater(
          result,
          throwsA(isA<StaleExtensionBinding>()),
        );
        await entered.future;
        await original.close();
        var replacementCalls = 0;
        if (replace) {
          register('pending', (_) {
            replacementCalls++;
            return ToolAuthorizationDecision.allow;
          });
        }
        pending.complete(ToolAuthorizationDecision.allow);
        await checked;
        expect(replacementCalls, 0);
        expect(await composer.evaluate(input), ToolPolicyDecision.allow);
        expect(replacementCalls, replace ? 1 : 0);
      },
    );
  }

  test(
    'revalidates earlier participants after later asynchronous evaluation',
    () async {
      final earlier = register('a', (_) => ToolAuthorizationDecision.allow);
      final entered = Completer<void>();
      final pending = Completer<ToolAuthorizationDecision>();
      register('b', (_) {
        entered.complete();
        return pending.future;
      });
      final result = composer.evaluate(input);
      final checked = expectLater(
        result,
        throwsA(isA<StaleExtensionBinding>()),
      );
      await entered.future;
      await earlier.close();
      pending.complete(ToolAuthorizationDecision.allow);
      await checked;
    },
  );

  test('validates a captured registration before invoking it', () async {
    final entered = Completer<void>();
    final pending = Completer<ToolAuthorizationDecision>();
    register('a', (_) {
      entered.complete();
      return pending.future;
    });
    var laterCalls = 0;
    final later = register('b', (_) {
      laterCalls++;
      return ToolAuthorizationDecision.allow;
    });
    final result = composer.evaluate(input);
    final checked = expectLater(result, throwsA(isA<StaleExtensionBinding>()));
    await entered.future;
    await later.close();
    register('b', (_) {
      laterCalls++;
      return ToolAuthorizationDecision.allow;
    });
    pending.complete(ToolAuthorizationDecision.allow);
    await checked;
    expect(laterCalls, 0);
  });

  test(
    'new registration affects only subsequent authorization requests',
    () async {
      final entered = Completer<void>();
      final pending = Completer<ToolAuthorizationDecision>();
      register('initial', (_) {
        if (!entered.isCompleted) entered.complete();
        return pending.future;
      });
      final result = composer.evaluate(input);
      await entered.future;
      var addedCalls = 0;
      register('added', (_) {
        addedCalls++;
        return ToolAuthorizationDecision.deny;
      });
      pending.complete(ToolAuthorizationDecision.allow);
      expect(await result, ToolPolicyDecision.allow);
      expect(addedCalls, 0);
      expect(await composer.evaluate(input), ToolPolicyDecision.deny);
      expect(addedCalls, 1);
    },
  );

  test(
    'effects and uncertainty alone cannot restrict an empty composition',
    () async {
      for (var mask = 0; mask < (1 << ToolEffect.values.length); mask++) {
        for (final uncertainty in EffectUncertainty.values) {
          final candidate = ToolPolicyInput(
            invocation: invocation,
            context: invocation.context,
            effects: EffectDescription(
              effects: [
                for (final effect in ToolEffect.values)
                  if (mask & (1 << effect.index) != 0) effect,
              ],
              targets: const [],
              summary: 'Not an authorization signal.',
              uncertainty: uncertainty,
            ),
          );
          expect(await composer.evaluate(candidate), ToolPolicyDecision.allow);
        }
      }
    },
  );

  test(
    'rejects noncanonical Session and mismatched Run context before callbacks',
    () async {
      var calls = 0;
      register('inspect', (_) {
        calls++;
        return ToolAuthorizationDecision.allow;
      });
      for (final candidate in [
        ToolAuthorizationPolicyComposer(
          extensions: extensions,
          lifecycle: topology.lifecycle,
          session: Session(
            id: session.id,
            taskId: session.taskId,
            strategyId: session.strategyId,
          ),
          runId: runId,
        ),
        ToolAuthorizationPolicyComposer(
          extensions: extensions,
          lifecycle: topology.lifecycle,
          session: session,
          runId: RunId('other-run'),
        ),
      ]) {
        await expectLater(candidate.evaluate(input), throwsArgumentError);
      }
      expect(calls, 0);
    },
  );
}

final _effects = EffectDescription(
  effects: [ToolEffect.sourceRead],
  targets: [EffectTarget(uri: Uri.parse('file:///source.dart'))],
  summary: 'Read source.',
);

final class _Tool implements ToolExecutable {
  @override
  void validateBinding() {}

  @override
  CanonicalToolArguments validateAndNormalize(Map<String, Object?> arguments) =>
      CanonicalToolArguments({'path': (arguments['path']! as String).trim()});

  @override
  Future<EffectDescription> describe(
    CanonicalToolArguments arguments,
    ToolExecutionContext context,
  ) async => _effects;

  @override
  Stream<ToolExecutionEvent> execute(
    CanonicalToolArguments arguments,
    ToolExecutionContext context,
  ) => throw StateError('Composition must not execute tools.');
}
