import 'package:adele_plugin_api/adele_plugin_api.dart';
import 'package:adele_ui/adele_ui.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const kind = 'dev.example.safe';
  late ExtensionRegistry registry;
  late ModelNativeActivityCompactPresentationResolver resolver;
  int factories = 0;
  final presentation = ModelNativePresentation(
    kind: kind,
    compactText: 'Safe compact',
    data: const {'text': 'Safe detail'},
  );

  setUp(() {
    registry = ExtensionRegistry();
    resolver = ModelNativeActivityCompactPresentationResolver(registry);
    factories = 0;
  });

  ExtensionRegistration register({
    String id = 'dev.example.compact',
    String presentationKind = kind,
    ModelNativeActivityCompactPresentationContribution? value,
  }) => registry.register(
    point: modelNativeActivityCompactPresentationContributions,
    id: ExtensionId(id),
    value:
        value ??
        ModelNativeActivityCompactPresentationContribution(
          presentationKind: presentationKind,
          createPresentation: (received) {
            factories++;
            expect(received, same(presentation));
            return Text(received.compactText);
          },
        ),
  );

  test('exact safe kind resolves without invoking a factory', () {
    register();
    final binding = resolver.resolve(kind);
    binding.validate();
    expect(factories, 0);
    expect(
      (binding.value.createPresentation(presentation) as Text).data,
      'Safe compact',
    );
    expect(factories, 1);
    expect(
      () => ModelNativeActivityPresentationResolver(registry).resolve(kind),
      throwsA(isA<ModelNativeActivityPresentationUnavailable>()),
    );
  });

  test(
    'missing, unrelated and rich-only kinds cannot supply compact presentation',
    () {
      registry.register(
        point: modelNativeActivityPresentationContributions,
        id: ExtensionId('dev.example.rich'),
        value: ModelNativeActivityPresentationContribution(
          presentationKind: kind,
          createInspection: (_) => throw StateError('Do not invoke rich.'),
        ),
      );
      for (final other in [kind.toUpperCase(), '$kind ', '$kind.other']) {
        register(
          id: 'dev.example.other-${other.length}',
          presentationKind: other,
        );
      }
      expect(
        () => resolver.resolve(kind),
        throwsA(isA<ModelNativeActivityCompactPresentationUnavailable>()),
      );
      expect(factories, 0);
    },
  );

  test(
    'many matches fail before factories with sorted immutable identities',
    () {
      register(id: 'dev.example.z');
      register(id: 'dev.example.a');
      expect(
        () => resolver.resolve(kind),
        throwsA(
          isA<AmbiguousModelNativeActivityCompactPresentation>().having(
            (error) => error.extensionIds,
            'identities',
            [ExtensionId('dev.example.a'), ExtensionId('dev.example.z')],
          ),
        ),
      );
      final ids = [ExtensionId('dev.example.z')];
      final error = AmbiguousModelNativeActivityCompactPresentation(ids);
      ids.clear();
      expect(error.extensionIds, hasLength(1));
      expect(error.extensionIds.clear, throwsUnsupportedError);
      expect(factories, 0);
    },
  );

  test(
    'retirement cannot migrate a binding or destroy captured safe data',
    () async {
      final first = register();
      final retained = resolver.resolve(kind);
      final value = retained.value;
      await first.close();
      register(value: value);
      expect(retained.validate, throwsA(isA<StaleExtensionBinding>()));
      expect(() => retained.value, throwsA(isA<StaleExtensionBinding>()));
      resolver.resolve(kind).validate();
      expect(presentation.data, {'text': 'Safe detail'});
      expect(factories, 0);
    },
  );
}
