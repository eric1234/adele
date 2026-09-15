import 'package:adele_model_tool/adele_model_tool.dart';
import 'package:adele_plugin_api/adele_plugin_api.dart';
import 'package:adele_ui/adele_ui.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final tool = ToolId('dev.example.tool');
  late ExtensionRegistry registry;
  late ToolActivityCompactPresentationResolver resolver;
  int factories = 0;

  setUp(() {
    registry = ExtensionRegistry();
    resolver = ToolActivityCompactPresentationResolver(registry);
    factories = 0;
  });

  ExtensionRegistration register({
    String id = 'dev.example.compact',
    ToolId? toolId,
    ToolActivityCompactPresentationContribution? value,
  }) => registry.register(
    point: toolActivityCompactPresentationContributions,
    id: ExtensionId(id),
    value:
        value ??
        ToolActivityCompactPresentationContribution(
          toolId: toolId ?? tool,
          createPresentation: (_) {
            factories++;
            return const SizedBox.shrink();
          },
        ),
  );

  test('missing, unrelated and rich-only registrations are unavailable', () {
    registry.register(
      point: toolActivityInspectionContributions,
      id: ExtensionId('dev.example.rich'),
      value: ToolActivityInspectionContribution(
        toolId: tool,
        createPresentation: (_) => throw StateError('Do not invoke rich.'),
      ),
    );
    for (final id in [tool.value.toUpperCase(), '${tool.value}.other']) {
      register(id: 'dev.example.other-${id.length}', toolId: ToolId(id));
    }
    expect(
      () => resolver.resolve(tool),
      throwsA(
        isA<ToolActivityCompactPresentationUnavailable>().having(
          (error) => error.toolId,
          'tool',
          tool,
        ),
      ),
    );
    expect(factories, 0);
  });

  test(
    'exact semantic Tool resolves without running a factory or rich fallback',
    () {
      register();
      final binding = resolver.resolve(ToolId(tool.value));
      binding.validate();
      expect(binding.id, ExtensionId('dev.example.compact'));
      expect(factories, 0);
      expect(
        () => ToolActivityInspectionResolver(registry).resolve(tool),
        throwsA(isA<ToolActivityInspectionUnavailable>()),
      );
    },
  );

  test(
    'multiple matches are ambiguous with sorted detached immutable identities',
    () {
      register(id: 'dev.example.z');
      register(id: 'dev.example.a');
      expect(
        () => resolver.resolve(tool),
        throwsA(
          isA<AmbiguousToolActivityCompactPresentation>().having(
            (error) => error.extensionIds,
            'identities',
            [ExtensionId('dev.example.a'), ExtensionId('dev.example.z')],
          ),
        ),
      );
      final ids = [ExtensionId('dev.example.z')];
      final error = AmbiguousToolActivityCompactPresentation(tool, ids);
      ids.clear();
      expect(error.extensionIds, hasLength(1));
      expect(error.extensionIds.clear, throwsUnsupportedError);
      expect(factories, 0);
    },
  );

  test(
    'same-ID same-value replacement cannot revive retained compact binding',
    () async {
      final first = register();
      final retained = resolver.resolve(tool);
      final value = retained.value;
      await first.close();
      register(value: value);
      expect(retained.validate, throwsA(isA<StaleExtensionBinding>()));
      expect(() => retained.value, throwsA(isA<StaleExtensionBinding>()));
      resolver.resolve(tool).validate();
      expect(factories, 0);
    },
  );

  test('closing either role leaves the other role registered', () async {
    final compact = register();
    final rich = registry.register(
      point: toolActivityInspectionContributions,
      id: ExtensionId('dev.example.rich'),
      value: ToolActivityInspectionContribution(
        toolId: tool,
        createPresentation: (_) => const SizedBox.shrink(),
      ),
    );
    await rich.close();
    resolver.resolve(tool).validate();
    await compact.close();
    expect(
      registry.discover(toolActivityCompactPresentationContributions),
      isEmpty,
    );
  });
}
