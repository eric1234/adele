import 'dart:async';

import 'package:adele_capabilities/adele_capabilities.dart';
import 'package:adele_model_provider/adele_model_provider.dart';
import 'package:adele_orchestration/adele_orchestration.dart';
import 'package:adele_plugin_api/adele_plugin_api.dart';
import 'package:adele_product/adele_product.dart' show TaskId;
import 'package:test/test.dart';

void main() {
  late ExtensionRegistry registry;
  late RunModelPreferenceResolver resolver;
  final session = Session(
    id: SessionId('session'),
    taskId: TaskId('task'),
    strategyId: OrchestrationStrategyId('strategy'),
  );
  final runId = RunId('run');
  final provider = ProviderId('dev.fixture.configured');
  const private = '/private/example';
  ExtensionRegistration register(
    Future<RunModelPreference?> Function(Session, RunId) capture, {
    String id = 'dev.fixture.preference',
  }) => registry.register(
    point: runModelPreferencesExtensionPoint,
    id: ExtensionId(id),
    value: RunModelPreferenceContribution(captureRun: capture),
  );

  Matcher failure(RunModelPreferenceFailureKind kind) => throwsA(
    isA<RunModelPreferenceFailure>()
        .having((e) => e.kind, 'kind', kind)
        .having((e) => e.toString(), 'diagnostic', isNot(contains(private))),
  );

  setUp(() {
    registry = ExtensionRegistry();
    resolver = RunModelPreferenceResolver(registry);
  });

  test(
    'no registration and explicit null are the two no-opinion paths',
    () async {
      expect(
        runModelPreferencesExtensionPoint.value,
        'dev.adele.extension.run-model-preferences',
      );
      expect(resolver.resolve(), isNull);
      var calls = 0;
      register((capturedSession, capturedRun) async {
        calls++;
        expect(capturedSession, same(session));
        expect(capturedRun, runId);
        return null;
      });
      final selected = resolver.resolve()!;
      expect(calls, 0);
      expect(await selected.captureRun(session, runId), isNull);
      expect(calls, 1);
    },
  );

  test(
    'captured values preserve exact IDs and distinguish absent effort from none',
    () async {
      const exact = '  Org/Model@1.0:Mix+case  ';
      ModelReasoningEffort? effort;
      register(
        (_, _) async => RunModelPreference(
          providerId: provider,
          modelId: exact,
          reasoningEffort: effort,
        ),
      );
      final first = (await resolver.resolve()!.captureRun(session, runId))!;
      effort = ModelReasoningEffort.none;
      final next = (await resolver.resolve()!.captureRun(
        session,
        RunId('next'),
      ))!;
      expect(first.modelId, exact);
      expect(first.providerId, provider);
      expect(first.reasoningEffort, isNull);
      expect(next.reasoningEffort, ModelReasoningEffort.none);
    },
  );

  test(
    'IDs are bounded in UTF-16 code units; malformed values never become null',
    () async {
      final limit = '\u{1f600}' * 512;
      expect(
        RunModelPreference(providerId: provider, modelId: limit).modelId,
        limit,
      );
      for (final model in [
        '',
        '  ',
        '$limit!',
        '$private\x00',
        '$private\n',
        '$private\x7f',
      ]) {
        final reg = register(
          (_, _) async =>
              RunModelPreference(providerId: provider, modelId: model),
        );
        await expectLater(
          resolver.resolve()!.captureRun(session, runId),
          failure(RunModelPreferenceFailureKind.malformed),
        );
        await reg.close();
      }
      final maxProvider =
          'a.${'b' * (RunModelPreference.maxProviderIdLength - 2)}';
      expect(
        RunModelPreference(
          providerId: ProviderId(maxProvider),
          modelId: 'm',
        ).providerId.value,
        maxProvider,
      );
      for (final id in ['$maxProvider.x', private]) {
        final reg = register(
          (_, _) async =>
              RunModelPreference(providerId: ProviderId(id), modelId: 'm'),
        );
        await expectLater(
          resolver.resolve()!.captureRun(session, runId),
          failure(RunModelPreferenceFailureKind.malformed),
        );
        await reg.close();
      }
    },
  );

  test(
    'arbitrary source failures are opaque, even failed parsing inside a source',
    () async {
      register((_, _) async => throw const FormatException(private));
      await expectLater(
        resolver.resolve()!.captureRun(session, runId),
        failure(RunModelPreferenceFailureKind.failed),
      );
    },
  );

  test(
    'ambiguity is a failed admission snapshot; removing a contender does not repair it',
    () async {
      var calls = 0;
      Future<RunModelPreference?> capture(Session _, RunId _) async {
        calls++;
        return null;
      }

      register(capture);
      final second = register(capture, id: 'dev.fixture.second');
      final admission = resolver.resolve()!;
      await second.close();
      await expectLater(
        admission.captureRun(session, runId),
        failure(RunModelPreferenceFailureKind.ambiguous),
      );
      expect(calls, 0);
      expect(await resolver.resolve()!.captureRun(session, runId), isNull);
      expect(calls, 1);
    },
  );

  test(
    'missing expected origin stays unavailable even if the same ID appears',
    () async {
      resolver = RunModelPreferenceResolver(
        registry,
        captureExpected: (bindings) {
          expect(bindings, isEmpty);
          throw StateError(private);
        },
      );
      final admission = resolver.resolve()!;
      register((_, _) async => null);
      await expectLater(
        admission.captureRun(session, runId),
        failure(RunModelPreferenceFailureKind.unavailable),
      );
    },
  );

  test(
    'retirement before and during capture fences same-ID replacements',
    () async {
      for (final whilePending in [false, true]) {
        final gate = Completer<RunModelPreference?>();
        var calls = 0;
        final old = register((_, _) {
          calls++;
          return gate.future;
        });
        final admission = resolver.resolve()!;
        final pending = whilePending
            ? admission.captureRun(session, runId)
            : null;
        await old.close();
        final replacement = register(
          (_, _) async => fail('replacement must not run'),
        );
        gate.complete(null);
        await expectLater(
          pending ?? admission.captureRun(session, runId),
          failure(RunModelPreferenceFailureKind.unavailable),
        );
        expect(calls, whilePending ? 1 : 0);
        await replacement.close();
      }
    },
  );

  test(
    'origin captured once; loss during await wins over a late source failure',
    () async {
      final gate = Completer<RunModelPreference?>();
      final reg = register((_, _) => gate.future);
      var captures = 0;
      var live = true;
      resolver = RunModelPreferenceResolver(
        registry,
        captureExpected: (bindings) {
          captures++;
          expect(reg.owns(bindings.single), isTrue);
          return () {
            if (!live) throw StateError(private);
          };
        },
      );
      final pending = resolver.resolve()!.captureRun(session, runId);
      live = false;
      gate.completeError(StateError(private));
      await expectLater(
        pending,
        failure(RunModelPreferenceFailureKind.unavailable),
      );
      expect(captures, 1);
    },
  );
}
