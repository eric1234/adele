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

  test('resolves current metadata by semantic ID, not registration ID', () {
    final ExtensionRegistry registry = ExtensionRegistry();
    final OrchestrationStrategyResolver resolver =
        OrchestrationStrategyResolver(registry);
    expect(
      () => resolver.resolve(strategyId),
      throwsA(isA<OrchestrationStrategyUnavailable>()),
    );
    final OrchestrationStrategyContribution contribution =
        OrchestrationStrategyContribution(strategyId: strategyId);
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
        value: OrchestrationStrategyContribution(strategyId: unrelatedId),
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
        OrchestrationStrategyContribution(strategyId: strategyId);
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
          value: OrchestrationStrategyContribution(strategyId: strategyId),
        );
      }
      registry.register(
        point: orchestrationStrategyContributions,
        id: ExtensionId('dev.adele.test.unrelated'),
        value: OrchestrationStrategyContribution(
          strategyId: OrchestrationStrategyId('unrelated'),
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
        OrchestrationStrategyContribution(strategyId: strategyId);
    registry.register(
      point: orchestrationStrategyContributions,
      id: extensionId,
      value: contribution,
    );
    expect(resolver.resolve(strategyId).contribution, same(contribution));

    final ExtensionRegistration duplicate = registry.register(
      point: orchestrationStrategyContributions,
      id: ExtensionId('dev.adele.test.strategy.duplicate'),
      value: OrchestrationStrategyContribution(strategyId: strategyId),
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
          OrchestrationStrategyContribution(strategyId: strategyId);
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
}
