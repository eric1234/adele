import 'dart:async';

import 'package:adele_orchestration/adele_orchestration.dart';
import 'package:adele_plugin_api/adele_plugin_api.dart';
import 'package:adele_ui/adele_ui.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const kind = 'dev.example.native';
  late ExtensionRegistry registry;
  late ModelNativeActivityPresentationResolver resolver;
  final output = ModelNativeOutput(
    providerItemId: 'opaque-id',
    providerNativeMetadata: ModelNativeEnvelope(
      kind: kind,
      compatibility: const {'private': 'compatibility'},
      data: const {'private': 'opaque-native-data'},
    ),
  );
  final projection = ModelNativeActivityProjection(
    compactText: 'Safe summary',
    data: const {'text': 'Safe detail'},
  );
  int calls = 0;

  setUp(() {
    registry = ExtensionRegistry();
    resolver = ModelNativeActivityPresentationResolver(registry);
    calls = 0;
  });

  ExtensionRegistration register({
    String id = 'dev.example.presenter',
    String nativeKind = kind,
    ModelNativeActivityProjection? Function(ModelNativeOutput)? project,
  }) => registry.register(
    point: modelNativeActivityPresentationContributions,
    id: ExtensionId(id),
    value: ModelNativeActivityPresentationContribution(
      nativeKind: nativeKind,
      project:
          project ??
          (received) {
            expect(received, same(output));
            calls++;
            return projection;
          },
      createInspection: (_) => throw StateError('Factory must not run here.'),
    ),
  );

  test('zero and unrelated kinds have no display or fallback', () {
    expect(resolver.project(output), isNull);
    register(nativeKind: '$kind.other');
    expect(resolver.project(output), isNull);
    expect(
      () => resolver.resolve(kind),
      throwsA(isA<ModelNativeActivityPresentationUnavailable>()),
    );
    expect(calls, 0);
  });

  test('exact kind resolves a binding without projecting or creating UI', () {
    register();
    register(id: 'dev.example.other', nativeKind: 'other');
    final binding = resolver.resolve(kind);
    expect(binding.id, ExtensionId('dev.example.presenter'));
    expect(calls, 0);
    final result = resolver.project(output)!;
    expect(result.binding.value, same(binding.value));
    expect(result.projection, same(projection));
    result.binding.validate();
    expect(calls, 1);
  });

  test('one projector can decline without invoking inspection', () {
    register(project: (_) => null);
    expect(resolver.project(output), isNull);
    resolver.resolve(kind).validate();
  });

  test('many matches are explicit ambiguity before any projector runs', () {
    register(id: 'dev.example.z');
    register(id: 'dev.example.a', project: (_) => null);
    final matcher = isA<AmbiguousModelNativeActivityPresentation>().having(
      (error) => error.extensionIds,
      'sorted identities',
      [ExtensionId('dev.example.a'), ExtensionId('dev.example.z')],
    );
    expect(() => resolver.resolve(kind), throwsA(matcher));
    expect(() => resolver.project(output), throwsA(matcher));
    expect(calls, 0);
    final ids = [ExtensionId('dev.example.z')];
    final error = AmbiguousModelNativeActivityPresentation(ids);
    ids.clear();
    expect(error.extensionIds, hasLength(1));
    expect(error.extensionIds.clear, throwsUnsupportedError);
  });

  test('projection recursively copies and freezes safe JSON-like data', () {
    final nested = <String, Object?>{'text': 'Approved'};
    final list = <Object?>[nested, null, true, 1, 1.5];
    final data = <String, Object?>{'parts': list, 'shared': nested};
    final captured = ModelNativeActivityProjection(
      compactText: 'Summary',
      data: data,
    );
    data.clear();
    list.clear();
    nested['text'] = 'Changed';
    expect(captured.compactText, 'Summary');
    expect(captured.data['parts'], [
      {'text': 'Approved'},
      null,
      true,
      1,
      1.5,
    ]);
    expect(captured.data.clear, throwsUnsupportedError);
    final parts = captured.data['parts']! as List<Object?>;
    expect(parts.clear, throwsUnsupportedError);
    expect(
      (parts.first! as Map<String, Object?>).clear,
      throwsUnsupportedError,
    );
  });

  test('unsafe values and cycles are rejected without stringifying them', () {
    final cycle = <Object?>[];
    cycle.add(cycle);
    for (final value in [
      _OpaqueFailure(),
      double.nan,
      double.infinity,
      {1: 'bad key'},
      cycle,
    ]) {
      expect(
        () => ModelNativeActivityProjection(
          compactText: 'Safe',
          data: {'bad': value},
        ),
        throwsArgumentError,
      );
    }
  });

  test('projector failures expose only a bounded presentation error', () {
    register(project: (_) => throw _OpaqueFailure());
    expect(
      () => resolver.project(output),
      throwsA(
        isA<ModelNativeActivityProjectionFailed>().having(
          (error) => error.toString(),
          'safe error',
          'Model native activity could not be projected.',
        ),
      ),
    );
  });

  test('retirement during projection rejects the captured binding', () async {
    late ExtensionRegistration registration;
    registration = register(
      project: (_) {
        unawaited(registration.close());
        return projection;
      },
    );
    expect(
      () => resolver.project(output),
      throwsA(isA<ModelNativeActivityProjectionFailed>()),
    );
    await registration.close();
  });

  test(
    'safe projection survives retirement but binding never migrates',
    () async {
      final first = register();
      final retained = resolver.project(output)!;
      final value = retained.binding.value;
      await first.close();
      registry.register(
        point: modelNativeActivityPresentationContributions,
        id: retained.binding.id,
        value: value,
      );
      expect(retained.binding.validate, throwsA(isA<StaleExtensionBinding>()));
      expect(retained.projection.data, {'text': 'Safe detail'});
      resolver.project(output)!.binding.validate();
    },
  );
}

final class _OpaqueFailure {
  @override
  String toString() => throw StateError('Opaque data must never be printed.');
}
