import 'package:adele_plugin_api/adele_plugin_api.dart';
import 'package:adele_ui/adele_ui.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const kind = 'dev.example.safe-presentation';
  late ExtensionRegistry registry;
  late ModelNativeActivityPresentationResolver resolver;
  final presentation = ModelNativePresentation(
    kind: kind,
    compactText: 'Safe summary',
    data: const {'text': 'Safe detail'},
  );
  int factories = 0;

  setUp(() {
    registry = ExtensionRegistry();
    resolver = ModelNativeActivityPresentationResolver(registry);
    factories = 0;
  });

  ExtensionRegistration register({
    String id = 'dev.example.presenter',
    String presentationKind = kind,
  }) => registry.register(
    point: modelNativeActivityPresentationContributions,
    id: ExtensionId(id),
    value: ModelNativeActivityPresentationContribution(
      presentationKind: presentationKind,
      createInspection: (received) {
        factories++;
        expect(received, same(presentation));
        return Text(received.data['text']! as String);
      },
    ),
  );

  test('zero and unrelated kinds are unavailable without fallback', () {
    expect(
      () => resolver.resolve(kind),
      throwsA(isA<ModelNativeActivityPresentationUnavailable>()),
    );
    for (final other in ['$kind.other', kind.toUpperCase(), '$kind ']) {
      register(
        id: 'dev.example.other-${other.length}',
        presentationKind: other,
      );
      expect(
        () => resolver.resolve(kind),
        throwsA(isA<ModelNativeActivityPresentationUnavailable>()),
      );
    }
    expect(factories, 0);
  });

  test('exact kind returns the registry binding without creating UI', () {
    register();
    register(id: 'dev.example.other', presentationKind: 'other');
    final binding = resolver.resolve(presentation.kind);
    expect(binding.id, ExtensionId('dev.example.presenter'));
    expect(binding.value.presentationKind, kind);
    expect(factories, 0);
    binding.validate();
    final widget = binding.value.createInspection(presentation) as Text;
    expect(widget.data, 'Safe detail');
    expect(factories, 1);
  });

  test('many matches are explicit ambiguity before any factory runs', () {
    register(id: 'dev.example.z');
    register(id: 'dev.example.a');
    expect(
      () => resolver.resolve(kind),
      throwsA(
        isA<AmbiguousModelNativeActivityPresentation>().having(
          (error) => error.extensionIds,
          'sorted identities',
          [ExtensionId('dev.example.a'), ExtensionId('dev.example.z')],
        ),
      ),
    );
    expect(factories, 0);
    final ids = [ExtensionId('dev.example.z')];
    final error = AmbiguousModelNativeActivityPresentation(ids);
    ids.clear();
    expect(error.extensionIds, hasLength(1));
    expect(error.extensionIds.clear, throwsUnsupportedError);
  });

  test(
    'safe evidence survives retirement but binding never migrates',
    () async {
      final first = register();
      final retained = resolver.resolve(kind);
      final value = retained.value;
      await first.close();
      expect(
        () => resolver.resolve(kind),
        throwsA(isA<ModelNativeActivityPresentationUnavailable>()),
      );
      registry.register(
        point: modelNativeActivityPresentationContributions,
        id: retained.id,
        value: value,
      );
      expect(retained.validate, throwsA(isA<StaleExtensionBinding>()));
      expect(presentation.data, {'text': 'Safe detail'});
      resolver.resolve(kind).validate();
      expect(factories, 0);
    },
  );
}
