import 'dart:async';

import 'package:adele_core_extensions/adele_core_extensions.dart';
import 'package:adele_plugin_api/adele_plugin_api.dart';
import 'package:test/test.dart';

void main() {
  test('the stable typed point permits zero selectors', () {
    expect(
      projectSelectorContributions,
      ExtensionPoint<ProjectSelectorContribution>(
        'dev.adele.extension.project-selectors',
      ),
    );
    expect(ExtensionRegistry().discover(projectSelectorContributions), isEmpty);
  });

  test(
    'distinct IDs retain typed URI and cancellation contributions',
    () async {
      final registry = ExtensionRegistry();
      final selectedId = ExtensionId('dev.adele.test.project-selector.catalog');
      final cancelledId = ExtensionId('dev.adele.test.project-selector.cancel');
      final location = Uri.parse('catalog:project/selected');
      registry.register(
        point: projectSelectorContributions,
        id: selectedId,
        value: ProjectSelectorContribution(
          displayName: 'Choose Project...',
          selectProject: () async => location,
        ),
      );
      registry.register(
        point: projectSelectorContributions,
        id: cancelledId,
        value: const ProjectSelectorContribution(
          displayName: 'Choose Project...',
          selectProject: _cancelSelection,
        ),
      );

      final List<ExtensionBinding<ProjectSelectorContribution>> bindings =
          registry.discover(projectSelectorContributions);
      expect(
        bindings.map((binding) => binding.id),
        unorderedEquals([selectedId, cancelledId]),
      );
      final selected = bindings.singleWhere(
        (binding) => binding.id == selectedId,
      );
      final cancelled = bindings.singleWhere(
        (binding) => binding.id == cancelledId,
      );
      expect(selected.value.displayName, 'Choose Project...');
      selected.validate();
      expect(await selected.value.selectProject(), location);
      selected.validate();
      cancelled.validate();
      expect(await cancelled.value.selectProject(), isNull);
      cancelled.validate();
    },
  );

  for (final result in <Uri?>[Uri.parse('catalog:project/retired'), null]) {
    test(
      'in-flight selection ($result) stays stale across replacement',
      () async {
        final registry = ExtensionRegistry();
        final id = ExtensionId('dev.adele.test.project-selector.replaceable');
        final selection = Completer<Uri?>();
        final generationA = registry.register(
          point: projectSelectorContributions,
          id: id,
          value: ProjectSelectorContribution(
            displayName: 'A',
            selectProject: () => selection.future,
          ),
        );
        final bindingA = registry.discover(projectSelectorContributions).single;
        bindingA.validate();
        final pending = bindingA.value.selectProject();

        await generationA.close();
        expect(registry.discover(projectSelectorContributions), isEmpty);
        int replacementCalls = 0;
        registry.register(
          point: projectSelectorContributions,
          id: id,
          value: ProjectSelectorContribution(
            displayName: 'B',
            selectProject: () async {
              replacementCalls++;
              return Uri.parse('catalog:project/replacement');
            },
          ),
        );
        selection.complete(result);
        expect(await pending, result);
        expect(bindingA.validate, throwsA(isA<StaleExtensionBinding>()));
        expect(() => bindingA.value, throwsA(isA<StaleExtensionBinding>()));
        expect(replacementCalls, 0);

        final bindingB = registry.discover(projectSelectorContributions).single;
        expect(bindingB.value.displayName, 'B');
        bindingB.validate();
        expect(
          await bindingB.value.selectProject(),
          Uri.parse('catalog:project/replacement'),
        );
        bindingB.validate();
        expect(replacementCalls, 1);
        expect(bindingA.validate, throwsA(isA<StaleExtensionBinding>()));
      },
    );
  }
}

Future<Uri?> _cancelSelection() async => null;
