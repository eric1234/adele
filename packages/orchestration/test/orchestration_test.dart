import 'package:adele_orchestration/adele_orchestration.dart';
import 'package:adele_plugin_api/adele_plugin_api.dart';
import 'package:adele_product/adele_product.dart' as product;
import 'package:test/test.dart';

void main() {
  final OrchestrationStrategyId strategyId = OrchestrationStrategyId(
    'dev.adele.strategy.test',
  );
  final ExtensionId extensionId = ExtensionId('dev.adele.test.strategy');

  test('strategy identity is reexported from product', () {
    final product.OrchestrationStrategyId productId = strategyId;

    expect(productId, product.OrchestrationStrategyId(strategyId.value));
  });

  test('unavailable strategy carries the requested semantic identity', () {
    final OrchestrationStrategyResolver resolver =
        OrchestrationStrategyResolver(ExtensionRegistry());

    expect(
      () => resolver.resolve(strategyId),
      throwsA(
        isA<OrchestrationStrategyUnavailable>()
            .having((error) => error.strategyId, 'strategyId', strategyId)
            .having(
              (error) => error.toString(),
              'diagnostic',
              contains(strategyId.value),
            ),
      ),
    );
  });

  test('resolves a contribution by semantic ID, not registration ID', () {
    final ExtensionRegistry registry = ExtensionRegistry();
    final OrchestrationStrategyResolver resolver =
        OrchestrationStrategyResolver(registry);
    expect(
      () => resolver.resolve(strategyId),
      throwsA(isA<OrchestrationStrategyUnavailable>()),
    );
    final OrchestrationStrategyContribution contribution =
        OrchestrationStrategyContribution(
          strategyId: strategyId,
          materialize: _materialize,
        );
    registry.register(
      point: orchestrationStrategyContributions,
      id: extensionId,
      value: contribution,
    );

    final ResolvedOrchestrationStrategy resolved = resolver.resolve(
      OrchestrationStrategyId(strategyId.value),
    );
    final ExtensionBinding<OrchestrationStrategyContribution> binding =
        resolved.binding;

    expect(resolved.strategyId, strategyId);
    expect(binding.id, extensionId);
    expect(binding.value, same(contribution));
    expect(resolved.contribution, same(contribution));
    expect(resolved.contribution.strategyId, strategyId);
    resolved.validateBinding();
    expect(
      () => resolver.resolve(OrchestrationStrategyId(extensionId.value)),
      throwsA(isA<OrchestrationStrategyUnavailable>()),
    );
  });

  test('unrelated strategies do not provide or make the target ambiguous', () {
    final ExtensionRegistry registry = ExtensionRegistry();
    final OrchestrationStrategyResolver resolver =
        OrchestrationStrategyResolver(registry);
    final OrchestrationStrategyId unrelatedId = OrchestrationStrategyId(
      'dev.adele.strategy.unrelated',
    );
    for (final String suffix in <String>['one', 'two']) {
      registry.register(
        point: orchestrationStrategyContributions,
        id: ExtensionId('dev.adele.test.unrelated.$suffix'),
        value: OrchestrationStrategyContribution(
          strategyId: unrelatedId,
          materialize: _materialize,
        ),
      );
    }
    expect(
      () => resolver.resolve(strategyId),
      throwsA(
        isA<OrchestrationStrategyUnavailable>().having(
          (error) => error.strategyId,
          'strategyId',
          strategyId,
        ),
      ),
    );
    final OrchestrationStrategyContribution contribution =
        OrchestrationStrategyContribution(
          strategyId: strategyId,
          materialize: _materialize,
        );
    registry.register(
      point: orchestrationStrategyContributions,
      id: ExtensionId(strategyId.value),
      value: contribution,
    );

    expect(resolver.resolve(strategyId).contribution, same(contribution));
  });

  test('ambiguity is sorted and independent of registration order', () {
    final List<ExtensionId> sortedIds = <ExtensionId>[
      ExtensionId('dev.adele.test.strategy.alpha'),
      ExtensionId('dev.adele.test.strategy.middle'),
      ExtensionId('dev.adele.test.strategy.zulu'),
    ];
    for (final List<ExtensionId> order in <List<ExtensionId>>[
      sortedIds,
      sortedIds.reversed.toList(),
      <ExtensionId>[sortedIds[1], sortedIds[2], sortedIds[0]],
    ]) {
      final ExtensionRegistry registry = ExtensionRegistry();
      for (final ExtensionId id in order) {
        registry.register(
          point: orchestrationStrategyContributions,
          id: id,
          value: OrchestrationStrategyContribution(
            strategyId: strategyId,
            materialize: _materialize,
          ),
        );
      }
      registry.register(
        point: orchestrationStrategyContributions,
        id: ExtensionId('dev.adele.test.unrelated'),
        value: OrchestrationStrategyContribution(
          strategyId: OrchestrationStrategyId('unrelated'),
          materialize: _materialize,
        ),
      );

      expect(
        () => OrchestrationStrategyResolver(registry).resolve(strategyId),
        throwsA(
          isA<AmbiguousOrchestrationStrategy>()
              .having((error) => error.strategyId, 'strategyId', strategyId)
              .having((error) => error.extensionIds, 'extensionIds', sortedIds)
              .having(
                (error) => error.toString(),
                'diagnostic',
                'AmbiguousOrchestrationStrategy: Strategy $strategyId is '
                    'contributed by ${sortedIds.join(', ')}.',
              ),
        ),
      );
    }
  });

  test('ambiguity snapshots an immutable sorted registration list', () {
    final ExtensionId alpha = ExtensionId('dev.adele.test.strategy.alpha');
    final ExtensionId zulu = ExtensionId('dev.adele.test.strategy.zulu');
    final List<ExtensionId> supplied = <ExtensionId>[zulu, alpha];
    final AmbiguousOrchestrationStrategy error = AmbiguousOrchestrationStrategy(
      strategyId,
      supplied,
    );

    expect(supplied, <ExtensionId>[zulu, alpha]);
    supplied.clear();
    expect(error.strategyId, strategyId);
    expect(error.extensionIds, <ExtensionId>[alpha, zulu]);
    expect(() => error.extensionIds.add(extensionId), throwsUnsupportedError);
    expect(() => error.extensionIds[0] = zulu, throwsUnsupportedError);
  });

  test('resolver observes ambiguity appearing and disappearing', () async {
    final ExtensionRegistry registry = ExtensionRegistry();
    final OrchestrationStrategyResolver resolver =
        OrchestrationStrategyResolver(registry);
    final OrchestrationStrategyContribution contribution =
        OrchestrationStrategyContribution(
          strategyId: strategyId,
          materialize: _materialize,
        );
    registry.register(
      point: orchestrationStrategyContributions,
      id: extensionId,
      value: contribution,
    );
    expect(resolver.resolve(strategyId).contribution, same(contribution));

    final ExtensionRegistration duplicate = registry.register(
      point: orchestrationStrategyContributions,
      id: ExtensionId('dev.adele.test.strategy.duplicate'),
      value: OrchestrationStrategyContribution(
        strategyId: strategyId,
        materialize: _materialize,
      ),
    );
    expect(
      () => resolver.resolve(strategyId),
      throwsA(isA<AmbiguousOrchestrationStrategy>()),
    );

    await duplicate.close();
    expect(resolver.resolve(strategyId).contribution, same(contribution));
  });

  test(
    'replacement with both IDs unchanged never retargets old binding',
    () async {
      final ExtensionRegistry registry = ExtensionRegistry();
      final OrchestrationStrategyResolver resolver =
          OrchestrationStrategyResolver(registry);
      final OrchestrationStrategyContribution original =
          OrchestrationStrategyContribution(
            strategyId: strategyId,
            materialize: _materialize,
          );
      final ExtensionRegistration registration = registry.register(
        point: orchestrationStrategyContributions,
        id: extensionId,
        value: original,
      );
      final ResolvedOrchestrationStrategy oldResolved = resolver.resolve(
        strategyId,
      );
      final ExtensionBinding<OrchestrationStrategyContribution> oldBinding =
          oldResolved.binding;
      expect(oldResolved.contribution, same(original));
      oldResolved.validateBinding();

      await registration.close();
      final Matcher stale = throwsA(
        isA<StaleExtensionBinding>().having(
          (error) => error.id,
          'id',
          extensionId,
        ),
      );
      expect(() => oldResolved.contribution, stale);
      expect(oldResolved.validateBinding, stale);
      expect(
        () => resolver.resolve(strategyId),
        throwsA(isA<OrchestrationStrategyUnavailable>()),
      );

      final OrchestrationStrategyContribution replacement =
          OrchestrationStrategyContribution(
            strategyId: OrchestrationStrategyId(strategyId.value),
            materialize: _materialize,
          );
      registry.register(
        point: orchestrationStrategyContributions,
        id: ExtensionId(extensionId.value),
        value: replacement,
      );
      final ResolvedOrchestrationStrategy newResolved = resolver.resolve(
        strategyId,
      );

      expect(replacement, isNot(same(original)));
      expect(newResolved.strategyId, oldResolved.strategyId);
      expect(newResolved.binding.id, oldBinding.id);
      expect(newResolved.binding, isNot(same(oldBinding)));
      expect(newResolved.contribution, same(replacement));
      expect(newResolved.binding.value, same(replacement));
      newResolved.validateBinding();
      expect(oldResolved.binding, same(oldBinding));
      expect(() => oldResolved.contribution, stale);
      expect(oldResolved.validateBinding, stale);
      expect(() => oldBinding.value, stale);
      expect(oldBinding.validate, stale);
    },
  );

  test('host context requires matching canonical Session identity', () {
    final Session session = _session(strategyId);
    final _TestHost host = _TestHost(SessionId('another-session'));

    expect(
      () => OrchestrationStrategyHostContext(session: session, host: host),
      throwsArgumentError,
    );
  });

  test('materializes an execution with the exact supplied context', () async {
    final ExtensionRegistry registry = ExtensionRegistry();
    final Session session = _session(strategyId);
    final _TestHost host = _TestHost(session.id);
    final OrchestrationStrategyHostContext context =
        OrchestrationStrategyHostContext(session: session, host: host);
    OrchestrationStrategyHostContext? received;
    final OrchestrationExecution execution = _materialize(context);
    registry.register(
      point: orchestrationStrategyContributions,
      id: extensionId,
      value: OrchestrationStrategyContribution(
        strategyId: strategyId,
        materialize: (value) {
          received = value;
          return execution;
        },
      ),
    );

    final OrchestrationExecution materialized = OrchestrationStrategyResolver(
      registry,
    ).resolve(strategyId).materialize(context);

    expect(materialized, same(execution));
    expect(received, same(context));
    expect(context.session, same(session));
    expect(context.host, same(host));
    expect(host.validations, 2);
    expect(host.state, RunState.created);
    await materialized.start();
    expect(host.state, RunState.completed);
    final ToolApprovalResolution resolution = ToolApprovalResolution(
      interruptionId: RunInterruptionId('approval-1'),
      toolInvocationId: ToolInvocationId('tool-1'),
      approved: false,
    );
    await materialized.resolveApproval(resolution);
    expect(host.resolution, same(resolution));
  });

  test('wrong strategy never reaches the contribution factory', () {
    final ExtensionRegistry registry = ExtensionRegistry();
    int calls = 0;
    registry.register(
      point: orchestrationStrategyContributions,
      id: extensionId,
      value: OrchestrationStrategyContribution(
        strategyId: strategyId,
        materialize: (context) {
          calls++;
          return _materialize(context);
        },
      ),
    );
    final Session session = _session(OrchestrationStrategyId('other-strategy'));
    final OrchestrationStrategyHostContext context =
        OrchestrationStrategyHostContext(
          session: session,
          host: _TestHost(session.id),
        );

    expect(
      () => OrchestrationStrategyResolver(
        registry,
      ).resolve(strategyId).materialize(context),
      throwsArgumentError,
    );
    expect(calls, 0);
  });

  test('retired materialization never uses a replacement factory', () async {
    final ExtensionRegistry registry = ExtensionRegistry();
    int originalCalls = 0;
    int replacementCalls = 0;
    final ExtensionRegistration registration = registry.register(
      point: orchestrationStrategyContributions,
      id: extensionId,
      value: OrchestrationStrategyContribution(
        strategyId: strategyId,
        materialize: (context) {
          originalCalls++;
          return _materialize(context);
        },
      ),
    );
    final OrchestrationStrategyResolver resolver =
        OrchestrationStrategyResolver(registry);
    final ResolvedOrchestrationStrategy original = resolver.resolve(strategyId);
    final Session session = _session(strategyId);
    final OrchestrationStrategyHostContext context =
        OrchestrationStrategyHostContext(
          session: session,
          host: _TestHost(session.id),
        );
    await registration.close();
    registry.register(
      point: orchestrationStrategyContributions,
      id: extensionId,
      value: OrchestrationStrategyContribution(
        strategyId: strategyId,
        materialize: (context) {
          replacementCalls++;
          return _materialize(context);
        },
      ),
    );

    expect(
      () => original.materialize(context),
      throwsA(isA<StaleExtensionBinding>()),
    );
    expect(originalCalls, 0);
    expect(replacementCalls, 0);
    resolver.resolve(strategyId).materialize(context);
    expect(replacementCalls, 1);
  });

  test('retirement during a factory invalidates its result', () async {
    final ExtensionRegistry registry = ExtensionRegistry();
    final Session session = _session(strategyId);
    final OrchestrationStrategyHostContext context =
        OrchestrationStrategyHostContext(
          session: session,
          host: _TestHost(session.id),
        );
    Future<void>? retirement;
    late final ExtensionRegistration registration;
    registration = registry.register(
      point: orchestrationStrategyContributions,
      id: extensionId,
      value: OrchestrationStrategyContribution(
        strategyId: strategyId,
        materialize: (context) {
          retirement = registration.close();
          return _materialize(context);
        },
      ),
    );

    expect(
      () => OrchestrationStrategyResolver(
        registry,
      ).resolve(strategyId).materialize(context),
      throwsA(isA<StaleExtensionBinding>()),
    );
    await retirement;
  });

  test('host identity is rechecked before and after the factory', () {
    for (final bool changeDuringFactory in <bool>[false, true]) {
      final ExtensionRegistry registry = ExtensionRegistry();
      final Session session = _session(strategyId);
      final _TestHost host = _TestHost(session.id);
      final OrchestrationStrategyHostContext context =
          OrchestrationStrategyHostContext(session: session, host: host);
      int calls = 0;
      registry.register(
        point: orchestrationStrategyContributions,
        id: extensionId,
        value: OrchestrationStrategyContribution(
          strategyId: strategyId,
          materialize: (context) {
            calls++;
            host.sessionId = SessionId('another-session');
            return _materialize(context);
          },
        ),
      );
      if (!changeDuringFactory) host.sessionId = SessionId('another-session');

      expect(
        () => OrchestrationStrategyResolver(
          registry,
        ).resolve(strategyId).materialize(context),
        throwsArgumentError,
      );
      expect(calls, changeDuringFactory ? 1 : 0);
    }
  });

  test('host binding is validated before and after the factory', () {
    for (final bool retireDuringFactory in <bool>[false, true]) {
      final ExtensionRegistry registry = ExtensionRegistry();
      final Session session = _session(strategyId);
      final _TestHost host = _TestHost(session.id);
      final OrchestrationStrategyHostContext context =
          OrchestrationStrategyHostContext(session: session, host: host);
      final StateError failure = StateError('host binding is stale');
      int calls = 0;
      registry.register(
        point: orchestrationStrategyContributions,
        id: extensionId,
        value: OrchestrationStrategyContribution(
          strategyId: strategyId,
          materialize: (context) {
            calls++;
            host.bindingFailure = failure;
            return _materialize(context);
          },
        ),
      );
      if (!retireDuringFactory) host.bindingFailure = failure;

      expect(
        () => OrchestrationStrategyResolver(
          registry,
        ).resolve(strategyId).materialize(context),
        throwsA(same(failure)),
      );
      expect(calls, retireDuringFactory ? 1 : 0);
    }
  });

  test('factory failures propagate without fallback', () {
    final ExtensionRegistry registry = ExtensionRegistry();
    final Session session = _session(strategyId);
    final StateError failure = StateError('materialization failed');
    registry.register(
      point: orchestrationStrategyContributions,
      id: extensionId,
      value: OrchestrationStrategyContribution(
        strategyId: strategyId,
        materialize: (_) => throw failure,
      ),
    );

    expect(
      () => OrchestrationStrategyResolver(registry)
          .resolve(strategyId)
          .materialize(
            OrchestrationStrategyHostContext(
              session: session,
              host: _TestHost(session.id),
            ),
          ),
      throwsA(same(failure)),
    );
  });
}

Session _session(OrchestrationStrategyId strategyId) => Session(
  id: SessionId('session-1'),
  taskId: product.TaskId('task-1'),
  strategyId: strategyId,
);

OrchestrationExecution _materialize(OrchestrationStrategyHostContext context) =>
    _TestExecution(context.host);

final class _TestExecution implements OrchestrationExecution {
  const _TestExecution(this.host);

  final OrchestrationExecutionHost host;

  @override
  Future<void> start() async {
    host.start();
    host.complete();
  }

  @override
  Future<void> resolveApproval(ToolApprovalResolution resolution) async {
    await host.resolveApproval(resolution);
  }
}

final class _TestHost implements OrchestrationExecutionHost {
  _TestHost(this.sessionId);

  @override
  final RunId id = RunId('run-1');
  @override
  SessionId sessionId;
  @override
  RunState state = RunState.created;
  int validations = 0;
  Object? bindingFailure;
  ToolApprovalResolution? resolution;

  @override
  void validateBinding() {
    validations++;
    if (bindingFailure case final Object error) throw error;
  }

  @override
  void start() => state = RunState.running;

  @override
  void complete() => state = RunState.completed;

  @override
  void fail(Object error) => state = RunState.failed;

  @override
  Future<StrategyModelTurn> invokeModel(StrategyInferenceMaterial material) =>
      throw UnimplementedError();

  @override
  Future<StrategyToolResult> processProposal({
    required StrategyToolSnapshot tools,
    required ProviderToolProposal proposal,
  }) => throw UnimplementedError();

  @override
  Future<SemanticToolOutcomeInput> resolveApproval(
    ToolApprovalResolution resolution,
  ) async {
    this.resolution = resolution;
    return SemanticToolOutcomeInput(
      providerCallId: 'call-1',
      outcome: ToolOutcome(
        disposition: ToolOutcomeDisposition.userRejected,
        effectCertainty: EffectCertainty.knownNotOccurred,
        modelContent: 'Rejected.',
      ),
    );
  }
}
