import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

// Match the launcher's SDK-only imports, without requiring workspace packages.
// ignore: avoid_relative_lib_imports
import '../../packages/plugin_builder/lib/plugin_builder.dart';
import '../../tools/desktop_artifact_cache.dart';
import '../../tools/desktop_tool_artifacts.dart';

const _generator = 'contract-codegen-compilation';
const _discovery = 'desktop-inputs-compilation';
const _both = {_generator, _discovery};

void main() {
  late Directory sandbox;
  late Directory root;
  late Directory external;
  late File compiler;
  late File runtime;
  late File calls;
  late File hook;
  late File extraDependency;
  late File sdk;

  File write(String path, [String content = '// fixture\n']) {
    final file = File.fromUri(root.uri.resolveUri(Uri.file(path)));
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(content);
    return file;
  }

  void resolution() {
    write(
      '.dart_tool/package_config.json',
      jsonEncode({
        'configVersion': 2,
        'packages': [
          {'name': 'adele_workspace', 'rootUri': '../', 'packageUri': 'lib/'},
          for (final package in [
            'contract_codegen',
            'shared',
            'generator_only',
            'worker_only',
            'unused',
          ])
            {
              'name': package,
              'rootUri': '../packages/$package/',
              'packageUri': 'lib/',
            },
          {
            'name': 'leaf',
            'rootUri': external.uri.toString(),
            'packageUri': 'sources/',
          },
          {
            'name': 'plugin',
            'rootUri': '../plugins/example/',
            'packageUri': 'lib/',
          },
        ],
      }),
    );
    write(
      '.dart_tool/package_graph.json',
      jsonEncode({
        'packages': [
          {
            'name': 'adele_workspace',
            'dependencies': <String>[],
            'devDependencies': ['shared', 'worker_only'],
          },
          {
            'name': 'contract_codegen',
            'dependencies': ['shared', 'generator_only'],
            'devDependencies': ['unused'],
          },
          {
            'name': 'shared',
            'dependencies': ['leaf'],
            'devDependencies': ['unused'],
          },
          for (final package in [
            'leaf',
            'generator_only',
            'worker_only',
            'unused',
            'plugin',
          ])
            {
              'name': package,
              'dependencies': <String>[],
              'devDependencies': <String>[],
            },
        ],
      }),
    );
  }

  List<String> compilations() =>
      calls.existsSync() ? calls.readAsLinesSync() : [];

  Future<DesktopToolArtifacts> prepare(
    DesktopArtifactCache cache, {
    Object sdkVersion = 'pinned-sdk',
  }) => DesktopToolArtifacts.prepare(
    repositoryRoot: root,
    cache: cache,
    dartExecutable: compiler.path,
    runtimeExecutable: runtime.path,
    sdkFiles: [compiler.path, sdk.path],
    sdkVersion: sdkVersion,
  );

  Future<Map<String, String>> publish({Object sdkVersion = 'pinned-sdk'}) =>
      withDesktopArtifactCache(root, (cache) async {
        final tools = await prepare(cache, sdkVersion: sdkVersion);
        expect(cache.componentIdentities, isEmpty);
        await tools.validate();
        await tools.cache.publishComponents();
        return Map.of(tools.cache.componentIdentities);
      });

  Directory components() => Directory.fromUri(
    root.uri.resolve('.dart_tool/adele/desktop-plugins/components/'),
  );

  setUp(() {
    sandbox = Directory.systemTemp.createTempSync('desktop tool artifacts ');
    root = Directory.fromUri(sandbox.uri.resolve('repo/'))..createSync();
    external = Directory.fromUri(sandbox.uri.resolve('external package/'));
    compiler = File.fromUri(sandbox.uri.resolve('fake compiler'));
    runtime = File.fromUri(sandbox.uri.resolve('fake runtime'))
      ..writeAsStringSync('pinned runtime');
    calls = File.fromUri(sandbox.uri.resolve('calls'));
    hook = File.fromUri(sandbox.uri.resolve('compiler hook'));
    extraDependency = File.fromUri(sandbox.uri.resolve('extra dependency'));
    sdk = File.fromUri(sandbox.uri.resolve('sdk platform.dill'))
      ..writeAsStringSync('pinned platform');
    write('pubspec.yaml', '''
name: adele_workspace
workspace:
  - packages/contract_codegen
  - plugins/example
dev_dependencies:
  shared: any
  worker_only: any
''');
    write('pubspec.lock', 'packages: {}\n');
    for (final package in [
      'contract_codegen',
      'shared',
      'generator_only',
      'worker_only',
      'unused',
    ]) {
      write('packages/$package/pubspec.yaml', 'name: $package\n');
      write('packages/$package/lib/source.dart');
    }
    write('../external package/pubspec.yaml', 'name: leaf\n');
    write('../external package/sources/leaf #1.dart');
    write('../external package/lib/not_selected.dart');
    write('plugins/example/pubspec.yaml', 'name: plugin\n');
    write('plugins/example/lib/plugin.dart');
    write('plugins/example/lib/contract.g.dart');
    write('contract_codegen.yaml', 'sources: []\n');
    write('tools/desktop_tool_artifacts.dart');
    write('tools/desktop_artifact_cache.dart');
    write('tools/desktop_build_inputs_worker.dart');
    write('packages/contract_codegen/bin/contract_codegen.dart');
    write('packages/plugin_builder/lib/src/development_plugin_builder.dart');
    Directory.fromUri(root.uri.resolve('tools/empty/')).createSync();
    resolution();
    compiler.writeAsStringSync('''#!/bin/bash
set -eu
[[ "\$#" == 9 && "\$1" == compile && "\$2" == aot-snapshot ]]
[[ "\$4" == -o && "\$6" == --depfile ]]
[[ "\$8" == --packages && "\$9" == ${_quote(File.fromUri(root.uri.resolve('.dart_tool/package_config.json')).path)} ]]
[[ "\$(dirname "\$5")" != "\$(dirname "\$7")" ]]
printf '%s\\n' "\$3" >> ${_quote(calls.path)}
escape() {
  local path="\$1"
  path="\${path//\\\\/\\\\\\\\}"
  path="\${path// /\\\\ }"
  path="\${path//#/\\\\#}"
  printf '%s' "\$path"
}
{
  escape "\$5"
  printf ': '
  escape "\$PWD/\$3"
  printf ' '
  escape "\$9"
  if [[ -f ${_quote(extraDependency.path)} ]]; then
    printf ' '
    escape "\$(< ${_quote(extraDependency.path)})"
  fi
  printf '\\n'
} > "\$7"
printf 'snapshot:%s\\n' "\$3" > "\$5"
if [[ -f ${_quote(hook.path)} ]]; then source ${_quote(hook.path)}; fi
''');
    expect(Process.runSync('chmod', ['+x', compiler.path]).exitCode, 0);
  });
  tearDown(() => sandbox.deleteSync(recursive: true));

  test(
    'uses the existing lease and publishes tools outside deployment keys',
    () async {
      final cold = await withDesktopArtifactCache(root, (cache) async {
        final tools = await prepare(cache);
        expect(cache.componentIdentities, isEmpty);
        expect(tools.cache.root.path, cache.root.path);
        expect(components().existsSync(), isFalse);
        expect(
          tools.generator.readAsStringSync(),
          contains('contract_codegen.dart'),
        );
        expect(
          tools.discovery.readAsStringSync(),
          contains('desktop_build_inputs_worker.dart'),
        );
        await expectLater(
          withDesktopArtifactCache(root, (_) async {}),
          throwsA(isA<PluginBuildFailure>()),
        );
        await tools.validate();
        await tools.cache.publishComponents();
        return Map.of(tools.cache.componentIdentities);
      });
      expect(cold.keys, unorderedEquals(_both));
      expect(await publish(), cold);
      expect(compilations(), [
        'packages/contract_codegen/bin/contract_codegen.dart',
        'tools/desktop_build_inputs_worker.dart',
      ]);
      expect(
        components()
            .listSync(recursive: true)
            .whereType<File>()
            .map((file) => file.uri.pathSegments.last),
        unorderedEquals([
          'tool.aot',
          'receipt.json',
          'tool.aot',
          'receipt.json',
        ]),
      );
    },
  );

  test(
    'pins compilation to root package config despite a nested shadow config',
    () async {
      final before = await publish();
      write(
        'packages/contract_codegen/.dart_tool/package_config.json',
        jsonEncode({'configVersion': 2, 'packages': <Object>[]}),
      );
      expect(await publish(), before);
      expect(compilations(), hasLength(2));

      // A miss must use the same root resolution as the warm cache identity.
      write(
        'packages/contract_codegen/lib/source.dart',
        '// rebuild generator\n',
      );
      final rebuilt = await publish();
      expect(rebuilt[_generator], isNot(before[_generator]));
      expect(rebuilt[_discovery], before[_discovery]);
      expect(compilations(), [
        'packages/contract_codegen/bin/contract_codegen.dart',
        'tools/desktop_build_inputs_worker.dart',
        'packages/contract_codegen/bin/contract_codegen.dart',
      ]);
    },
  );

  test(
    'keys resolved transitive libraries and owning tool inputs independently',
    () async {
      var before = await publish();
      for (final entry in <String, Set<String>>{
        '../external package/sources/leaf #1.dart': _both,
        'packages/shared/pubspec.yaml': _both,
        'packages/shared/pubspec_overrides.yaml': _both,
        'packages/contract_codegen/lib/source.dart': {_generator},
        'packages/contract_codegen/bin/contract_codegen.dart': {_generator},
        'packages/generator_only/lib/source.dart': {_generator},
        'packages/worker_only/lib/source.dart': {_discovery},
        'tools/desktop_build_inputs_worker.dart': {_discovery},
        'tools/desktop_tool_artifacts.dart': _both,
        'packages/plugin_builder/lib/src/development_plugin_builder.dart':
            _both,
        'pubspec_overrides.yaml': _both,
        'pubspec.lock': _both,
      }.entries) {
        final count = compilations().length;
        write(entry.key, '// changed ${entry.key}\n');
        final after = await publish();
        expect(
          {
            for (final name in _both)
              if (before[name] != after[name]) name,
          },
          entry.value,
          reason: entry.key,
        );
        expect(
          compilations().length - count,
          entry.value.length,
          reason: entry.key,
        );
        before = after;
      }
    },
  );

  test(
    'source membership additions invalidate and removals recover prior keys',
    () async {
      final before = await publish();
      for (final entry in <String, Set<String>>{
        'tools/empty/new.dart': {_discovery},
        'packages/contract_codegen/lib/new.dart': {_generator},
        '../external package/sources/new.dart': _both,
      }.entries) {
        final source = write(entry.key);
        final after = await publish();
        expect(
          {
            for (final name in _both)
              if (before[name] != after[name]) name,
          },
          entry.value,
          reason: entry.key,
        );
        final count = compilations().length;
        source.deleteSync();
        expect(await publish(), before, reason: entry.key);
        expect(compilations(), hasLength(count));
      }
    },
  );

  test(
    'excludes plugin inputs, generated contracts and dependency dev packages',
    () async {
      final before = await publish();
      for (final path in [
        'plugins/example/lib/plugin.dart',
        'plugins/example/lib/contract.g.dart',
        'plugins/example/lib/new.dart',
        'contract_codegen.yaml',
        'packages/unused/lib/source.dart',
        'packages/unused/pubspec.yaml',
        '../external package/lib/not_selected.dart',
      ]) {
        write(path, '// not a tool input\n');
      }
      expect(await publish(), before);
      expect(compilations(), hasLength(2));
    },
  );

  test(
    'follows override root and nondefault packageUri rather than old libraries',
    () async {
      final before = await publish();
      external = Directory.fromUri(sandbox.uri.resolve('replacement package/'));
      write('../replacement package/pubspec.yaml', 'name: leaf\n');
      final selected = write('../replacement package/sources/leaf.dart');
      resolution();
      // The fake compiler reports the resolved external input, not its old location.
      extraDependency.writeAsStringSync(selected.path);
      final overridden = await publish();
      for (final name in _both) {
        expect(overridden[name], isNot(before[name]));
      }
      write('../external package/sources/leaf #1.dart', '// old override\n');
      write('../replacement package/lib/not_selected.dart');
      expect(await publish(), overridden);
      selected.writeAsStringSync('// selected override changed\n');
      final changed = await publish();
      for (final name in _both) {
        expect(changed[name], isNot(overridden[name]));
      }
      expect(compilations(), hasLength(6));
    },
  );

  test('SDK contents and version invalidate both tools', () async {
    final before = await publish();
    sdk.writeAsStringSync('changed platform');
    final contentChange = await publish();
    final versionChange = await publish(sdkVersion: 'other-sdk');
    for (final name in _both) {
      expect(contentChange[name], isNot(before[name]));
      expect(versionChange[name], isNot(contentChange[name]));
    }
    expect(compilations(), hasLength(6));
  });

  test(
    'rejects uncovered compiler imports before publishing any component',
    () async {
      extraDependency.writeAsStringSync(
        write('plugins/example/lib/escape.dart').path,
      );
      await expectLater(
        publish(),
        throwsA(_failure('Uncovered build tool compiler input:')),
      );
      expect(components().existsSync(), isFalse);
      expect(compilations(), hasLength(1));
      extraDependency.writeAsStringSync(
        File.fromUri(external.uri.resolve('sources/leaf%20%231.dart')).path,
      );
      await publish();
      expect(compilations(), hasLength(3));
    },
  );

  for (final mutation in ['source edit', 'source addition']) {
    test('rejects $mutation during compilation before publication', () async {
      final path = mutation == 'source edit'
          ? 'tools/desktop_build_inputs_worker.dart'
          : 'tools/empty/new.dart';
      hook.writeAsStringSync(
        "printf '// changed\\n' > ${_quote(File.fromUri(root.uri.resolve(path)).path)}\n",
      );
      await expectLater(
        publish(),
        throwsA(_failure('changed during desktop preparation')),
      );
      expect(components().existsSync(), isFalse);
      hook.deleteSync();
      await publish();
      expect(compilations(), hasLength(4));
    });
  }

  for (final cached in [false, true]) {
    for (final restore in [false, true]) {
      test(
        'worker compilation rejects ${cached ? 'cached' : 'new'} generator ${restore ? 'edit and restore' : 'corruption'}',
        () async {
          final generatorPath = File.fromUri(
            sandbox.uri.resolve('generator artifact path'),
          );
          if (cached) {
            await publish();
            generatorPath.writeAsStringSync(
              Directory.fromUri(components().uri.resolve('$_generator/'))
                  .listSync(recursive: true)
                  .whereType<File>()
                  .singleWhere((file) => file.path.endsWith('/tool.aot'))
                  .path,
            );
            write(
              'packages/worker_only/lib/source.dart',
              '// rebuild worker\n',
            );
          }
          final before = components().existsSync()
              ? components()
                    .listSync(recursive: true)
                    .map((entry) => entry.path)
                    .toSet()
              : <String>{};
          final count = compilations().length;
          hook.writeAsStringSync('''
if [[ "\$3" == packages/contract_codegen/bin/contract_codegen.dart ]]; then
  printf '%s' "\$5" > ${_quote(generatorPath.path)}
elif [[ "\$3" == tools/desktop_build_inputs_worker.dart ]]; then
  artifact="\$(< ${_quote(generatorPath.path)})"
  test -f "\$artifact"
  printf 'tampered artifact' > "\$artifact"
${restore ? '''  printf 'snapshot:packages/contract_codegen/bin/contract_codegen.dart\\n' > "\$artifact"
  touch -m -t 200001010000 "\$artifact"
''' : ''}fi
''');
          await expectLater(
            publish(),
            throwsA(_failure('changed during desktop preparation')),
          );
          expect(compilations().length - count, cached ? 1 : 2);
          expect(
            File(generatorPath.readAsStringSync()).readAsStringSync(),
            restore
                ? 'snapshot:packages/contract_codegen/bin/contract_codegen.dart\n'
                : 'tampered artifact',
          );
          expect(
            components().existsSync()
                ? components()
                      .listSync(recursive: true)
                      .map((entry) => entry.path)
                : <String>[],
            unorderedEquals(before),
          );
        },
      );
    }
  }

  for (final mutation in [
    'source',
    'membership',
    'artifact',
    'artifact edit and restore',
    'runtime',
    'runtime edit and restore',
  ]) {
    test('final validation fences $mutation changes after prepare', () async {
      await withDesktopArtifactCache(root, (cache) async {
        final tools = await prepare(cache);
        switch (mutation) {
          case 'source':
            final source = File.fromUri(
              root.uri.resolve('packages/shared/lib/source.dart'),
            );
            final original = source.readAsStringSync();
            source.writeAsStringSync('// changed\n');
            source.writeAsStringSync(original);
            source.setLastModifiedSync(DateTime.utc(2000));
          case 'membership':
            write('tools/empty/transient.dart').deleteSync();
            // Ensure a distinct stat even on filesystems with coarse timestamps.
            expect(
              Process.runSync('touch', [
                '-m',
                '-t',
                '200001010000',
                Directory.fromUri(root.uri.resolve('tools/empty/')).path,
              ]).exitCode,
              0,
            );
          case 'artifact':
            tools.generator.writeAsStringSync('tampered artifact');
          case 'artifact edit and restore':
            final artifact = tools.generator;
            final original = artifact.readAsStringSync();
            artifact.writeAsStringSync('tampered artifact');
            artifact.writeAsStringSync(original);
            artifact.setLastModifiedSync(DateTime.utc(2000));
          case 'runtime':
            runtime.writeAsStringSync('changed runtime');
          case 'runtime edit and restore':
            final original = runtime.readAsStringSync();
            runtime.writeAsStringSync('changed runtime');
            runtime.writeAsStringSync(original);
            runtime.setLastModifiedSync(DateTime.utc(2000));
        }
        if (mutation.startsWith('runtime')) {
          await expectLater(
            tools.validateArtifacts(),
            throwsA(_failure('changed during desktop preparation')),
          );
        }
        await expectLater(
          tools.validate(),
          throwsA(_failure('changed during desktop preparation')),
        );
        expect(components().existsSync(), isFalse);
      });
    });
  }

  test(
    'unrelated Flutter cache membership does not trip tool race checks',
    () async {
      await withDesktopArtifactCache(root, (cache) async {
        final tools = await prepare(cache);
        write('.dart_tool/flutter-cache/new-cache-file', 'cache');
        await tools.validate();
        await tools.cache.publishComponents();
      });
    },
  );

  group('depfile coverage', () {
    test(
      'accepts escaped absolute/relative paths and continued dependency lines',
      () {
        final output = File.fromUri(root.uri.resolve('output%20%231.aot'));
        final relative = 'sources/space and #hash.dart';
        final backslash = r'sources/back\slash.dart';
        final absolute = File.fromUri(
          external.uri.resolve('sources/leaf.dart'),
        ).path;
        final inputs = {
          File.fromUri(root.uri.resolveUri(Uri.file(relative))).path,
          File.fromUri(root.uri.resolveUri(Uri.file(backslash))).path,
          absolute,
        };
        validateToolDepfile(
          '${_escape(output.path)}: ${_escape(relative)} \\\n\t${_escape(backslash)} ${_escape(absolute)}\n',
          output: output,
          root: root,
          inputs: inputs,
        );
      },
    );

    test('normalizes paths before rejecting uncovered inputs', () {
      final output = File.fromUri(root.uri.resolve('output.aot'));
      final covered = File.fromUri(root.uri.resolve('tools/input.dart')).path;
      validateToolDepfile(
        '${_escape(output.path)}: tools/../tools/input.dart',
        output: output,
        root: root,
        inputs: {covered},
      );
      expect(
        () => validateToolDepfile(
          '${_escape(output.path)}: tools/../../uncovered.dart',
          output: output,
          root: root,
          inputs: {covered},
        ),
        throwsA(_failure('Uncovered build tool compiler input:')),
      );
    });

    test('rejects empty, wrong-target, and incomplete escape rules', () {
      final output = File.fromUri(root.uri.resolve('output.aot'));
      for (final content in [
        '',
        '${_escape(output.path)}:',
        'wrong.aot: input.dart',
        '${_escape(output.path)}: input.dart\\',
      ]) {
        expect(
          () => validateToolDepfile(
            content,
            output: output,
            root: root,
            inputs: {},
          ),
          throwsA(_failure('Invalid build tool compiler depfile.')),
          reason: content,
        );
      }
    });
  });
}

Matcher _failure(String message) => isA<PluginBuildFailure>().having(
  (failure) => failure.message,
  'message',
  contains(message),
);

String _quote(String value) => "'${value.replaceAll("'", "'\\''")}'";

String _escape(String value) =>
    value.replaceAll(r'\', r'\\').replaceAll(' ', r'\ ').replaceAll('#', r'\#');
