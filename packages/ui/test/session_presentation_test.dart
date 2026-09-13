import 'package:adele_plugin_api/adele_plugin_api.dart';
import 'package:adele_product/adele_product.dart';
import 'package:adele_ui/adele_ui.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final OrchestrationStrategyId strategyId = OrchestrationStrategyId(
    'dev.adele.test.strategy',
  );
  final OrchestrationStrategyId otherStrategyId = OrchestrationStrategyId(
    'dev.adele.test.other-strategy',
  );

  test('zero matching presentations is explicitly unavailable', () {
    final ExtensionRegistry registry = ExtensionRegistry();
    expect(
      () => SessionPresentationResolver(registry).resolve(strategyId),
      throwsA(
        isA<SessionPresentationUnavailable>().having(
          (error) => error.strategyId,
          'strategyId',
          strategyId,
        ),
      ),
    );
  });

  test('unrelated presentation is not a fallback', () {
    final ExtensionRegistry registry = ExtensionRegistry();
    registry.register(
      point: sessionPresentationContributions,
      id: ExtensionId('dev.adele.test.unrelated-presentation'),
      value: SessionPresentationContribution(
        strategyId: otherStrategyId,
        createPresentation: (_) => throw StateError('Must not be invoked.'),
      ),
    );

    expect(
      () => SessionPresentationResolver(registry).resolve(strategyId),
      throwsA(isA<SessionPresentationUnavailable>()),
    );
  });

  test(
    'exact strategy resolution returns a binding without invoking factories',
    () {
      final ExtensionRegistry registry = ExtensionRegistry();
      final ExtensionId id = ExtensionId('dev.adele.test.presentation');
      final Session session = Session(
        id: SessionId('session-1'),
        taskId: TaskId('task-1'),
        strategyId: strategyId,
      );
      int creations = 0;
      Session? received;
      const Widget presentation = SizedBox.shrink();
      final SessionPresentationContribution contribution =
          SessionPresentationContribution(
            strategyId: strategyId,
            createPresentation: (value) {
              creations++;
              received = value;
              return presentation;
            },
          );
      registry.register(
        point: sessionPresentationContributions,
        id: ExtensionId('dev.adele.test.unrelated-presentation'),
        value: SessionPresentationContribution(
          strategyId: otherStrategyId,
          createPresentation: (_) => throw StateError('Must not be invoked.'),
        ),
      );
      registry.register(
        point: sessionPresentationContributions,
        id: id,
        value: contribution,
      );

      final ExtensionBinding<SessionPresentationContribution> binding =
          SessionPresentationResolver(
            registry,
          ).resolve(OrchestrationStrategyId(strategyId.value));
      expect(creations, 0);
      expect(binding.id, id);
      expect(binding.value, same(contribution));
      binding.validate();
      expect(binding.value.createPresentation(session), same(presentation));
      expect(creations, 1);
      expect(received, same(session));
    },
  );

  test(
    'duplicate semantic strategies are explicitly ambiguous regardless of IDs',
    () {
      final ExtensionRegistry registry = ExtensionRegistry();
      final ExtensionId first = ExtensionId('dev.adele.test.presentation.a');
      final ExtensionId second = ExtensionId('dev.adele.test.presentation.b');
      for (final ExtensionId id in <ExtensionId>[second, first]) {
        registry.register(
          point: sessionPresentationContributions,
          id: id,
          value: SessionPresentationContribution(
            strategyId: OrchestrationStrategyId(strategyId.value),
            createPresentation: (_) => throw StateError('Must not be invoked.'),
          ),
        );
      }

      expect(
        () => SessionPresentationResolver(registry).resolve(strategyId),
        throwsA(
          isA<AmbiguousSessionPresentation>()
              .having((error) => error.strategyId, 'strategyId', strategyId)
              .having(
                (error) => error.extensionIds,
                'extensionIds',
                <ExtensionId>[first, second],
              ),
        ),
      );
      final AmbiguousSessionPresentation error = AmbiguousSessionPresentation(
        strategyId,
        <ExtensionId>[second, first],
      );
      expect(() => error.extensionIds.clear(), throwsUnsupportedError);
    },
  );

  test(
    'retired bindings stay stale even with the same ID and contribution',
    () async {
      final ExtensionRegistry registry = ExtensionRegistry();
      final SessionPresentationResolver resolver = SessionPresentationResolver(
        registry,
      );
      final ExtensionId id = ExtensionId('dev.adele.test.presentation');
      final SessionPresentationContribution contribution =
          SessionPresentationContribution(
            strategyId: strategyId,
            createPresentation: (_) => const SizedBox.shrink(),
          );
      final ExtensionRegistration first = registry.register(
        point: sessionPresentationContributions,
        id: id,
        value: contribution,
      );
      final ExtensionBinding<SessionPresentationContribution> retained =
          resolver.resolve(strategyId);
      await first.close();
      expect(
        () => resolver.resolve(strategyId),
        throwsA(isA<SessionPresentationUnavailable>()),
      );
      registry.register(
        point: sessionPresentationContributions,
        id: id,
        value: contribution,
      );
      final ExtensionBinding<SessionPresentationContribution> replacement =
          resolver.resolve(strategyId);

      expect(() => retained.validate(), throwsA(isA<StaleExtensionBinding>()));
      expect(() => retained.value, throwsA(isA<StaleExtensionBinding>()));
      replacement.validate();
      expect(replacement.value, same(contribution));
    },
  );
}
