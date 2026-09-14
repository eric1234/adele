import 'package:adele_model_tool/adele_model_tool.dart';
import 'package:adele_plugin_api/adele_plugin_api.dart';
import 'package:adele_ui/adele_ui.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final ToolId toolId = ToolId('dev.adele.test.tool');
  late ExtensionRegistry registry;
  late ToolActivityInspectionResolver resolver;

  setUp(() {
    registry = ExtensionRegistry();
    resolver = ToolActivityInspectionResolver(registry);
  });

  ExtensionRegistration register({
    String id = 'dev.adele.test.inspection',
    ToolId? tool,
  }) => registry.register(
    point: toolActivityInspectionContributions,
    id: ExtensionId(id),
    value: ToolActivityInspectionContribution(
      toolId: tool ?? toolId,
      createPresentation: (_) => throw StateError('Must not be invoked.'),
    ),
  );

  test(
    'zero matches is explicitly unavailable, with no unrelated fallback',
    () {
      expect(
        () => resolver.resolve(toolId),
        throwsA(
          isA<ToolActivityInspectionUnavailable>().having(
            (error) => error.toolId,
            'toolId',
            toolId,
          ),
        ),
      );
      register(tool: ToolId('${toolId.value}.other'));
      expect(
        () => resolver.resolve(toolId),
        throwsA(isA<ToolActivityInspectionUnavailable>()),
      );
    },
  );

  test('exact semantic Tool ID resolves without invoking the factory', () {
    register();
    register(id: 'dev.adele.test.other', tool: ToolId('other'));
    final binding = resolver.resolve(ToolId(toolId.value));
    expect(binding.id, ExtensionId('dev.adele.test.inspection'));
    expect(binding.value.toolId, toolId);
    binding.validate();
  });

  test('multiple exact matches are ambiguous with sorted immutable IDs', () {
    register(id: 'dev.adele.test.b');
    register(id: 'dev.adele.test.a', tool: ToolId(toolId.value));
    expect(
      () => resolver.resolve(toolId),
      throwsA(
        isA<AmbiguousToolActivityInspection>()
            .having((error) => error.toolId, 'toolId', toolId)
            .having((error) => error.extensionIds, 'extensionIds', [
              ExtensionId('dev.adele.test.a'),
              ExtensionId('dev.adele.test.b'),
            ]),
      ),
    );
    final List<ExtensionId> ids = [
      ExtensionId('dev.adele.test.b'),
      ExtensionId('dev.adele.test.a'),
    ];
    final error = AmbiguousToolActivityInspection(toolId, ids);
    ids.clear();
    expect(error.extensionIds, [
      ExtensionId('dev.adele.test.a'),
      ExtensionId('dev.adele.test.b'),
    ]);
    expect(error.extensionIds.clear, throwsUnsupportedError);
  });

  test(
    'retired bindings never migrate even with the same ID and value',
    () async {
      final contribution = ToolActivityInspectionContribution(
        toolId: toolId,
        createPresentation: (_) => const SizedBox.shrink(),
      );
      ExtensionRegistration activate() => registry.register(
        point: toolActivityInspectionContributions,
        id: ExtensionId('dev.adele.test.inspection'),
        value: contribution,
      );
      final first = activate();
      final retained = resolver.resolve(toolId);
      await first.close();
      expect(
        () => resolver.resolve(toolId),
        throwsA(isA<ToolActivityInspectionUnavailable>()),
      );
      activate();
      final fresh = resolver.resolve(toolId);
      expect(retained.validate, throwsA(isA<StaleExtensionBinding>()));
      expect(() => retained.value, throwsA(isA<StaleExtensionBinding>()));
      fresh.validate();
      expect(fresh.value, same(contribution));
    },
  );
}
