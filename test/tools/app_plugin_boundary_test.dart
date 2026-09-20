import 'dart:io';

import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

void main() {
  group('production app plugin boundary', () {
    late Set<String> pluginNames;

    setUpAll(() {
      pluginNames = _pluginPackageNames(Directory('plugins'));
    });

    test('production dependencies contain no plugin packages', () {
      expect(
        _productionPluginDependencies(
          File('app/pubspec.yaml').readAsStringSync(),
          pluginNames,
        ),
        isEmpty,
        reason: 'Plugin packages belong only in app dev_dependencies.',
      );
    });

    test('app/lib directives neither link plugins nor escape app/lib', () {
      final files = Directory('app/lib')
          .listSync(recursive: true, followLinks: false)
          .whereType<File>()
          .where((file) => file.path.endsWith('.dart'))
          .toList();
      expect(files, isNotEmpty);
      final violations = <String>[
        for (final file in files)
          for (final uri in _forbiddenAppUris(
            file.readAsStringSync(),
            file.absolute.uri,
            pluginNames,
          ))
            '${file.path}: $uri',
      ];
      expect(violations, isEmpty);
    });
  });

  group('plugin boundary helpers', () {
    test('discovers YAML names recursively, excluding output and symlinks', () {
      final root = Directory.systemTemp.createTempSync('adele-boundary-');
      addTearDown(() => root.deleteSync(recursive: true));
      final plugins = Directory('${root.path}/plugins')..createSync();
      final manifests = <String, String>{
        'example/pubspec.yaml':
            "name: 'example_plugin' # not the directory name\n",
        'example/packages/backend/pubspec.yaml':
            'name: >-\n  example_backend\n',
        'external/pubspec.yaml': 'name: external_plugin\n',
        for (final directory in [
          '.dart_tool',
          '.adele-build',
          '.symlinks',
          'build',
          'cache',
          'coverage',
          'generated',
          'ephemeral',
        ])
          'example/$directory/nested/pubspec.yaml': 'not: [valid YAML',
      };
      for (final entry in manifests.entries) {
        final file = File('${plugins.path}/${entry.key}');
        file.parent.createSync(recursive: true);
        file.writeAsStringSync(entry.value);
      }
      final external = Directory(
        '${plugins.path}/external',
      ).renameSync('${root.path}/external');
      if (!Platform.isWindows) {
        Link('${plugins.path}/linked-directory').createSync(external.path);
        final linkedPackage = Directory('${plugins.path}/linked-package')
          ..createSync();
        Link(
          '${linkedPackage.path}/pubspec.yaml',
        ).createSync('${external.path}/pubspec.yaml');
      }
      expect(
        _pluginPackageNames(plugins),
        unorderedEquals(['example_plugin', 'example_backend']),
      );
    });

    test('empty package discovery cannot silently pass', () {
      final root = Directory.systemTemp.createTempSync('adele-boundary-empty-');
      addTearDown(() => root.deleteSync(recursive: true));
      expect(() => _pluginPackageNames(root), throwsA(isA<TestFailure>()));
    });

    test(
      'YAML dependencies reject plugins but allow development dependencies',
      () {
        expect(
          _productionPluginDependencies(
            '''
dev_dependencies: {example_plugin: any}
dependencies:
  "example_backend":
    path: ../plugins/example/packages/backend
  example_plugin_extra: any
description: 'example_plugin: any'
# example_plugin: any
''',
            {'example_plugin', 'example_backend'},
          ),
          ['example_backend'],
        );
        expect(
          _productionPluginDependencies(
            '''
dev_dependencies: {example_plugin: any}
dependencies: {public_api: any}
''',
            {'example_plugin'},
          ),
          isEmpty,
        );
      },
    );

    final sourceUri = File('app/lib/core/example.dart').absolute.uri;

    test('checks import/export defaults and every conditional URI', () {
      expect(
        _forbiddenAppUris(
          r'''
import 'package:example_plugin/default.dart'
    if (dart.library.io) 'package:example_plugin/io.dart'
    if (dart.library.html) 'package:example_plugin/web.dart';
export 'package:example_plugin/export.dart'
    if (dart.library.io) 'package:example_plugin/export_io.dart'
    if (dart.library.html) 'package:example_plugin/export_web.dart';
import 'package:public_api/default.dart'
    if (dart.library.io) 'package:example_plugin/conditional_only.dart';
export 'package:public_api/default.dart'
    if (dart.library.html) 'package:example_plugin/export_conditional_only.dart';
import 'package:\u0065xample_plugin/escaped.dart';
''',
          sourceUri,
          {'example_plugin'},
        ),
        [
          'package:example_plugin/default.dart',
          'package:example_plugin/io.dart',
          'package:example_plugin/web.dart',
          'package:example_plugin/export.dart',
          'package:example_plugin/export_io.dart',
          'package:example_plugin/export_web.dart',
          'package:example_plugin/conditional_only.dart',
          'package:example_plugin/export_conditional_only.dart',
          'package:example_plugin/escaped.dart',
        ],
      );
    });

    test('ignores comments, strings, and package-name lookalikes', () {
      expect(
        _forbiddenAppUris(
          '''
// import 'package:example_plugin/comment.dart';
/* export 'package:example_plugin/comment.dart'; */
import 'dart:io';
import 'package:example_plugin_extra/api.dart';
export 'package:public_api/example_plugin/api.dart';
const text = "import 'package:example_plugin/string.dart';";
const escapedPath = "export '../../tool/development.dart';";
''',
          sourceUri,
          {'example_plugin'},
        ),
        isEmpty,
      );
    });

    test(
      'rejects relative development backdoors but allows app/lib siblings',
      () {
        expect(
          _forbiddenAppUris(
            '''
import 'local.dart';
export '../ui/../core/public.dart';
import '../../tool/development.dart';
export '../public.dart'
    if (dart.library.io) '../../test/fixture.dart'
    if (dart.library.html) '../../lib_extra/backdoor.dart';
''',
            sourceUri,
            {},
          ),
          [
            '../../tool/development.dart',
            '../../test/fixture.dart',
            '../../lib_extra/backdoor.dart',
          ],
        );
      },
    );
  });
}

Set<String> _pluginPackageNames(Directory root) {
  final names = <String>{};
  final pending = <Directory>[root];
  while (pending.isNotEmpty) {
    for (final entity in pending.removeLast().listSync(followLinks: false)) {
      final name = entity.uri.pathSegments
          .where((part) => part.isNotEmpty)
          .last;
      if (entity is Directory) {
        if (!name.startsWith('.') &&
            !const {
              'build',
              'cache',
              'coverage',
              'generated',
              'ephemeral',
              'Pods',
            }.contains(name)) {
          pending.add(entity);
        }
      } else if (entity is File && name == 'pubspec.yaml') {
        final manifest =
            loadYaml(entity.readAsStringSync(), sourceUrl: entity.uri)
                as YamlMap;
        final packageName = manifest['name'];
        expect(packageName, isA<String>(), reason: entity.path);
        expect(packageName as String, isNotEmpty, reason: entity.path);
        names.add(packageName);
      }
    }
  }
  expect(names, isNotEmpty, reason: 'No plugin pubspec.yaml files discovered.');
  return names;
}

Iterable<String> _productionPluginDependencies(
  String source,
  Set<String> pluginNames,
) {
  final manifest = loadYaml(source) as YamlMap;
  final dependencies = manifest['dependencies'] as YamlMap?;
  return (dependencies?.keys.cast<String>() ?? const <String>[]).where(
    pluginNames.contains,
  );
}

List<String> _forbiddenAppUris(
  String source,
  Uri sourceUri,
  Set<String> pluginNames,
) {
  final libRoot = Directory('app/lib').absolute.uri.toString();
  final unit = parseString(content: source, path: sourceUri.toFilePath()).unit;
  final forbidden = <String>[];
  for (final directive in unit.directives.whereType<NamespaceDirective>()) {
    for (final literal in [
      directive.uri,
      for (final configuration in directive.configurations) configuration.uri,
    ]) {
      final value = literal.stringValue!;
      final uri = Uri.parse(value);
      if ((uri.scheme == 'package' &&
              pluginNames.contains(uri.pathSegments.first)) ||
          (!uri.hasScheme &&
              !sourceUri.resolveUri(uri).toString().startsWith(libRoot))) {
        forbidden.add(value);
      }
    }
  }
  return forbidden;
}
