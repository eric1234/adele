import 'dart:io';

import 'package:adele_core_extensions/adele_core_extensions.dart';
import 'package:adele_plugin_api/adele_plugin_api.dart';
import 'package:local_directory_project_selector_plugin/local_directory_project_selector_plugin.dart';
import 'package:test/test.dart';

void main() {
  test('activation registers stable metadata without invoking the picker', () {
    int calls = 0;
    final registry = ExtensionRegistry();
    final activation = LocalDirectoryProjectSelectorPlugin(
      pickDirectory: () async {
        calls++;
        return null;
      },
    ).activate(registry);
    addTearDown(activation.close);

    final binding = registry.discover(projectSelectorContributions).single;
    expect(
      localDirectoryProjectSelectorPluginId.value,
      'dev.adele.plugin.local-directory-project-selector',
    );
    expect(
      binding.id.value,
      'dev.adele.plugin.local-directory-project-selector.project-selector',
    );
    expect(binding.value.displayName, 'Open Local Directory...');
    expect(activation.isClosed, isFalse);
    expect(calls, 0);
  });

  test('absolute path becomes a space-encoded file directory URI', () async {
    final expected = Directory.current.uri.resolve('selected%20project/');
    int calls = 0;
    final contribution = _activate(() async {
      calls++;
      return expected.toFilePath();
    });

    final selected = await contribution.selectProject();
    expect(selected, expected);
    expect(selected!.scheme, 'file');
    expect(selected.isAbsolute, isTrue);
    expect(selected.path, endsWith('/'));
    expect(selected.toString(), contains('selected%20project/'));
    expect(calls, 1);
  });

  final current = Directory.current.uri.normalizePath();
  final root = Directory(Platform.pathSeparator).absolute.uri;
  for (final (label, path, expected) in <(String, String, Uri)>[
    ('relative', 'selected project', current.resolve('selected%20project/')),
    ('dot', '.', current),
    (
      'dot segments',
      'parent${Platform.pathSeparator}..${Platform.pathSeparator}selected project',
      current.resolve('selected%20project/'),
    ),
    (
      'trailing separator',
      'selected project${Platform.pathSeparator}',
      current.resolve('selected%20project/'),
    ),
    (
      'absolute dot segments',
      '${current.toFilePath()}parent${Platform.pathSeparator}..${Platform.pathSeparator}selected project${Platform.pathSeparator}.',
      current.resolve('selected%20project/'),
    ),
    ('root', root.toFilePath(), root),
  ]) {
    test('normalizes $label using host platform path semantics', () async {
      final contribution = _activate(() async => path);
      expect(await contribution.selectProject(), expected);
    });
  }

  test('null picker result is cancellation', () async {
    final contribution = _activate(() async => null);
    expect(await contribution.selectProject(), isNull);
  });

  test(
    'empty picker result fails rather than selecting the current directory',
    () async {
      final contribution = _activate(() async => '');
      await expectLater(
        contribution.selectProject(),
        throwsA(isA<StateError>()),
      );
    },
  );

  for (final synchronous in [false, true]) {
    test(
      'propagates the same picker error (synchronous: $synchronous)',
      () async {
        final failure = StateError('picker failed');
        final contribution = _activate(
          synchronous ? () => throw failure : () async => throw failure,
        );
        await expectLater(contribution.selectProject(), throwsA(same(failure)));
      },
    );
  }

  test(
    'retirement removes the selector and stales retained bindings',
    () async {
      final registry = ExtensionRegistry();
      final activation = const LocalDirectoryProjectSelectorPlugin().activate(
        registry,
      );
      final binding = registry.discover(projectSelectorContributions).single;
      await activation.close();

      expect(activation.isClosed, isTrue);
      expect(registry.discover(projectSelectorContributions), isEmpty);
      expect(binding.validate, throwsA(isA<StaleExtensionBinding>()));
      expect(() => binding.value, throwsA(isA<StaleExtensionBinding>()));
    },
  );

  test(
    'default headless activation succeeds but selection requires Flutter',
    () async {
      final registry = ExtensionRegistry();
      final activation = const LocalDirectoryProjectSelectorPlugin().activate(
        registry,
      );
      addTearDown(activation.close);
      final binding = registry.discover(projectSelectorContributions).single;
      binding.validate();
      await expectLater(
        binding.value.selectProject(),
        throwsA(
          isA<UnsupportedError>().having(
            (error) => error.message,
            'message',
            contains('requires a Flutter host'),
          ),
        ),
      );
      binding.validate();
    },
    skip: const bool.fromEnvironment('dart.library.ui'),
  );
}

ProjectSelectorContribution _activate(
  Future<String?> Function() pickDirectory,
) {
  final registry = ExtensionRegistry();
  final activation = LocalDirectoryProjectSelectorPlugin(
    pickDirectory: pickDirectory,
  ).activate(registry);
  addTearDown(activation.close);
  return registry.discover(projectSelectorContributions).single.value;
}
