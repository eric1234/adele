import 'dart:io';

import 'package:test/test.dart';

import 'support/desktop_launcher_fixture.dart';
import 'support/desktop_launcher_inputs.dart';

void main() {
  late DesktopLauncherFixture fixture;
  setUp(() async {
    fixture = await DesktopLauncherFixture.create();
  });

  test(
    'cold and warm desktop runs execute incremental AOT generation once and discovery twice',
    () async {
      Map<String, String>? before;
      for (final cold in [true, false]) {
        final after = await fixture.prepare();
        expect(fixture.toolCompilations(), cold ? toolStages.values : isEmpty);
        expect(
          fixture.compilations(),
          hasLength(
            cold
                ? backendEntrypoints.length + frontendCompilations.length + 1
                : 0,
          ),
        );
        expect(
          fixture.commands.readAsLinesSync().where(
            (line) => line.startsWith('generate|'),
          ),
          ['generate|aot|--incremental'],
        );
        fixture.expectGenerationArguments(['--incremental'], true);
        expect(
          File('${fixture.root.path}/logs/discovery.txt').readAsLinesSync(),
          List.filled(cold ? 2 : 4, 'discover|aot'),
        );
        final discoveryArguments = File(
          '${fixture.root.path}/logs/discovery-arguments.txt',
        ).readAsLinesSync();
        for (var index = 0; index < discoveryArguments.length; index += 2) {
          expect(
            discoveryArguments[index],
            startsWith(
              '${fixture.root.path}/.dart_tool/adele/desktop-plugins/',
            ),
          );
          expect(discoveryArguments[index], endsWith('/tool.aot'));
          expect(discoveryArguments[index + 1], fixture.root.path);
        }
        for (final stage in toolStages.keys) {
          final artifact = fixture.componentArtifact(stage);
          expect(artifact.uri.pathSegments.last, 'tool.aot');
          expect(
            artifact.parent.listSync().map(
              (file) => file.uri.pathSegments.last,
            ),
            unorderedEquals(['tool.aot', 'receipt.json']),
          );
        }
        if (before != null) expect(after, before);
        before = after;
      }
    },
  );

  test('desktop preparation defaults to full AOT generation', () async {
    final entrypoint = File('${fixture.root.path}/tools/prepare-default.dart')
      ..writeAsStringSync('''
import 'dart:io';
import 'backend_artifacts.dart';

Future<void> main() async {
  await prepareDesktopPluginDefines(
    repositoryRoot: Directory.current,
    flutterExecutable: '${fixture.root.path}/bin/flutter',
  );
}
''');
    final result = await Process.run(
      Platform.resolvedExecutable,
      [entrypoint.path],
      workingDirectory: fixture.root.path,
      environment: fixture.environment,
    );
    expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
    expect(
      fixture.commands.readAsLinesSync().where(
        (line) => line.startsWith('generate|'),
      ),
      ['generate|aot'],
    );
    fixture.expectGenerationArguments([], true);
    expect(File('${fixture.root.path}/logs/discovery.txt').readAsLinesSync(), [
      'discover|aot',
      'discover|aot',
    ]);
    expect(fixture.launchArguments.existsSync(), isFalse);
  });

  for (final mutation in [
    (path: generatorSource, expected: codegenEntrypoint),
    (path: 'tools/test_runner.dart', expected: workerEntrypoint),
  ]) {
    test(
      'tool-only ${mutation.path} change preserves plugin installations',
      () async {
        final before = await fixture.prepare();
        final retained = fixture.retainedFiles();
        fixture.changeSource(mutation.path);
        expect(await fixture.prepare(), before);
        expect(fixture.toolCompilations(), [mutation.expected]);
        expect(fixture.compilations(), isEmpty);
        fixture.expectRetained(retained);
        expect(await fixture.prepare(), before);
        expect(fixture.toolCompilations(), isEmpty);
        expect(fixture.compilations(), isEmpty);
      },
    );
  }

  for (final tool in toolStages.entries) {
    for (final damage in [
      'missing-artifact',
      'corrupt-artifact',
      'missing-receipt',
      'corrupt-receipt',
    ]) {
      test(
        '$damage ${tool.key} is repaired without replacing installations',
        () async {
          final before = await fixture.prepare();
          final old = fixture.componentArtifact(tool.key);
          final damaged = damage.endsWith('receipt')
              ? File('${old.parent.path}/receipt.json')
              : old;
          if (damage.startsWith('missing')) {
            damaged.deleteSync();
          } else {
            damaged.writeAsStringSync('corrupt cached tool');
          }
          final retained = fixture.retainedFiles();
          expect(await fixture.prepare(), before);
          expect(fixture.toolCompilations(), [tool.value]);
          expect(fixture.compilations(), isEmpty);
          fixture.expectRetained(retained);
          final replacements = fixture.publishedFiles().where(
            (file) =>
                file.path.contains('/components/${tool.key}/') &&
                file.uri.pathSegments.last == 'tool.aot' &&
                file.path != old.path,
          );
          expect(replacements, hasLength(1));
          expect(
            replacements.single.readAsStringSync(),
            'snapshot ${tool.value}\n',
          );
          expect(await fixture.prepare(), before);
          expect(fixture.toolCompilations(), isEmpty);
          expect(fixture.compilations(), isEmpty);
        },
      );
    }

    for (final failure in ['exit', 'missing', 'empty']) {
      test(
        '${tool.key} $failure compile failure prevents generation and publication',
        () async {
          fixture.environment[switch (failure) {
                'exit' => 'ADELE_TEST_FAIL_ENTRYPOINT',
                'missing' => 'ADELE_TEST_OMIT_ARTIFACT',
                _ => 'ADELE_TEST_EMPTY_ARTIFACT',
              }] =
              tool.value;
          final result = await fixture.invoke(['run', 'linux']);
          expect(result.exitCode, failure == 'exit' ? 17 : 1);
          expect(result.stderr, contains(tool.key));
          expect(
            result.stderr,
            contains(
              failure == 'exit' ? 'snapshot compiler failed' : 'produced no',
            ),
          );
          expect(fixture.compilations(), isEmpty);
          expect(fixture.generationArguments.existsSync(), isFalse);
          expect(fixture.launchArguments.existsSync(), isFalse);
          expect(fixture.publishedFiles(), isEmpty);
        },
      );
    }

    for (final invalidation in ['source', 'receipt']) {
      test(
        '${tool.key} failed $invalidation rebuild never falls back to retained AOT',
        () async {
          final before = await fixture.prepare();
          if (invalidation == 'source') {
            fixture.changeSource(
              tool.value == codegenEntrypoint
                  ? generatorSource
                  : 'tools/test_runner.dart',
            );
          } else {
            File(
              '${fixture.componentArtifact(tool.key).parent.path}/receipt.json',
            ).writeAsStringSync('{invalid');
          }
          final retained = fixture.retainedFiles();
          fixture.environment['ADELE_TEST_FAIL_ENTRYPOINT'] = tool.value;
          fixture.commands.deleteSync();
          fixture.launchArguments.deleteSync();
          final failed = await fixture.invoke(['run', 'linux']);
          expect(failed.exitCode, 17);
          expect(fixture.toolCompilations(), [tool.value]);
          expect(fixture.compilations(), isEmpty);
          expect(
            fixture.commands.readAsLinesSync().where(
              (line) => line.startsWith('generate|'),
            ),
            isEmpty,
          );
          expect(fixture.launchArguments.existsSync(), isFalse);
          fixture.expectRetained(retained);
          expect(
            fixture.publishedFiles().map((file) => file.path),
            unorderedEquals(retained.keys),
          );
          fixture.environment.remove('ADELE_TEST_FAIL_ENTRYPOINT');
          expect(await fixture.prepare(), before);
          expect(fixture.toolCompilations(), [tool.value]);
          expect(fixture.compilations(), isEmpty);
        },
      );
    }
  }

  for (final failure in ['missing', 'empty', 'undeclared']) {
    test('$failure tool compiler depfile blocks publication', () async {
      fixture.environment['ADELE_TEST_TOOL_DEPFILE'] = failure;
      final result = await fixture.invoke(['run', 'linux']);
      expect(result.exitCode, isNot(0));
      expect(
        result.stderr,
        contains(
          failure == 'undeclared'
              ? 'Uncovered build tool compiler input'
              : failure == 'empty'
              ? 'Invalid build tool compiler depfile'
              : 'tool.d',
        ),
      );
      expect(fixture.toolCompilations(), [codegenEntrypoint]);
      expect(fixture.compilations(), isEmpty);
      expect(fixture.generationArguments.existsSync(), isFalse);
      expect(fixture.launchArguments.existsSync(), isFalse);
      expect(fixture.publishedFiles(), isEmpty);
    });
  }
}
