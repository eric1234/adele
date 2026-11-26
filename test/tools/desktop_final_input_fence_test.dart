import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import 'support/desktop_launcher_fixture.dart';
import 'support/desktop_launcher_inputs.dart';

void main() {
  late DesktopLauncherFixture fixture;
  setUp(() async {
    fixture = await DesktopLauncherFixture.create();
  });

  for (final phase in ['plugin compilation', 'final discovery']) {
    test('tool source mutation during $phase blocks all publication', () async {
      fixture.environment[phase == 'plugin compilation'
              ? 'ADELE_TEST_MUTATE_SOURCE'
              : 'ADELE_TEST_MUTATE_TOOL_DURING_DISCOVERY'] =
          '${fixture.root.path}/$generatorSource';
      final result = await fixture.invoke(['run', 'linux']);
      expect(result.exitCode, 1);
      expect(
        result.stderr,
        contains(
          'Build tool inputs or artifacts changed during desktop preparation',
        ),
      );
      expect(fixture.launchArguments.existsSync(), isFalse);
      expect(fixture.publishedFiles(), isEmpty);
    });
  }

  for (final mutation in [
    'tool source edit-restore',
    'new tool file in empty directory',
    'tool source removal',
    'watched empty directory removal',
    'optional override create-delete',
    'optional override removal',
    'package configuration edit',
    'generated output edit',
    'native header edit',
    'shared input edit-restore',
    'shared input removal',
    'agent schema edit',
    'agent backend edit',
  ]) {
    test('final discovery $mutation rejects warm preparation without publication', () async {
      final source = File(
        '${fixture.root.path}/${mutation == 'shared input edit-restore' ? sharedSource : generatorSource}',
      );
      final empty = Directory('${source.parent.path}/empty')..createSync();
      final added = File('${empty.path}/new.dart');
      final override = File(
        '${fixture.root.path}/packages/contract_codegen/pubspec_overrides.yaml',
      );
      if (mutation == 'optional override removal') {
        override.writeAsStringSync('dependency_overrides: {}\n');
      }
      await fixture.prepare();
      final retained = fixture.retainedFiles();
      final original = source.readAsBytesSync();
      final hook = File('${fixture.root.path}/logs/final-discovery-hook');
      final mutationScript = switch (mutation) {
        'tool source edit-restore' || 'shared input edit-restore' =>
          '''
cp '${source.path}' '${fixture.root.path}/logs/original-source'
printf '\\n// transient edit\\n' >> '${source.path}'
cp '${fixture.root.path}/logs/original-source' '${source.path}'
TZ=UTC touch -m -t 200001010000 '${source.path}'
''',
        'new tool file in empty directory' =>
          "printf '// new tool input\\n' > '${added.path}'",
        'tool source removal' => "rm '${source.path}'",
        'watched empty directory removal' => "rmdir '${empty.path}'",
        'optional override create-delete' =>
          '''
printf 'dependency_overrides: {}\\n' > '${override.path}'
rm '${override.path}'
TZ=UTC touch -m -t 200001010000 '${override.parent.path}'
''',
        'optional override removal' => "rm '${override.path}'",
        'package configuration edit' =>
          "printf '\\n' >> '${fixture.root.path}/.dart_tool/package_config.json'",
        'generated output edit' =>
          "printf '// changed output\\n' >> '${fixture.generatedContract.path}'",
        'shared input removal' => "rm '${fixture.root.path}/$sharedSource'",
        'agent schema edit' =>
          "printf '\\n' >> '${fixture.root.path}/plugins/agent_configuration/records.schema.json'",
        'agent backend edit' =>
          "printf '\\n' >> '${fixture.root.path}/$agentConfigurationEntrypoint'",
        _ =>
          "printf '// changed header\\n' >> '${fixture.root.path}/$nativeHeader'",
      };
      writeExecutableScript(hook, 'set -e\n$mutationScript');
      fixture.environment['ADELE_TEST_FINAL_DISCOVERY_HOOK'] = hook.path;
      final discoveries = File('${fixture.root.path}/logs/discovery.txt')
        ..writeAsStringSync('');
      fixture.commands.deleteSync();
      fixture.launchArguments.deleteSync();

      final result = await fixture.invoke(['run', 'linux']);
      expect(result.exitCode, 1, reason: '${result.stdout}\n${result.stderr}');
      expect(
        result.stderr,
        contains(switch (mutation) {
          'shared input removal' =>
            'Desktop build input must be an existing absolute file',
          'generated output edit' ||
          'native header edit' ||
          'agent schema edit' ||
          'agent backend edit' ||
          'shared input edit-restore' =>
            'Build inputs changed during desktop preparation',
          _ =>
            'Build tool inputs or artifacts changed during desktop preparation',
        }),
      );
      expect(discoveries.readAsLinesSync(), ['discover|aot', 'discover|aot']);
      expect(fixture.toolCompilations(), isEmpty);
      expect(fixture.compilations(), isEmpty);
      expect(
        fixture.commands.readAsLinesSync(),
        isNot(contains('flutter-launch')),
      );
      expect(fixture.launchArguments.existsSync(), isFalse);
      fixture.expectRetained(retained);
      expect(
        fixture.publishedFiles().map((file) => file.path),
        unorderedEquals(retained.keys),
      );
      if (mutation.endsWith('edit-restore')) {
        expect(source.readAsBytesSync(), original);
        expect(source.lastModifiedSync().toUtc(), DateTime.utc(2000));
      } else if (mutation == 'optional override create-delete') {
        expect(override.existsSync(), isFalse);
        expect(override.parent.statSync().modified.toUtc(), DateTime.utc(2000));
      }
    });
  }

  for (final damage in ['corrupt', 'missing']) {
    test(
      '$damage selected discovery artifact during compilation is rejected before second execution',
      () async {
        await fixture.prepare();
        final discovery = fixture.componentArtifact(
          'desktop-inputs-compilation',
        );
        final generator = fixture.componentArtifact(
          'contract-codegen-compilation',
        );
        final retained = fixture.retainedFiles()..remove(discovery.path);
        fixture.changeSource(gitEntrypoint);
        final hook = File('${fixture.root.path}/logs/compile-hook');
        writeExecutableScript(
          hook,
          damage == 'missing'
              ? "rm '${discovery.path}'"
              : "printf 'corrupt selected AOT\\n' > '${discovery.path}'",
        );
        fixture.environment['ADELE_TEST_COMPILE_HOOK'] = hook.path;
        final executions = File('${fixture.root.path}/logs/aot-executions.txt')
          ..writeAsStringSync('');
        final discoveries = File('${fixture.root.path}/logs/discovery.txt')
          ..writeAsStringSync('');
        fixture.commands.deleteSync();
        fixture.launchArguments.deleteSync();

        final result = await fixture.invoke(['run', 'linux']);
        expect(
          result.exitCode,
          1,
          reason: '${result.stdout}\n${result.stderr}',
        );
        expect(
          result.stderr,
          contains(
            damage == 'missing'
                ? 'Unable to fingerprint build inputs'
                : 'Build tool inputs or artifacts changed during desktop preparation',
          ),
        );
        // Record runtime entry before it can reject missing/corrupt snapshots.
        expect(executions.readAsLinesSync(), [generator.path, discovery.path]);
        expect(discoveries.readAsLinesSync(), ['discover|aot']);
        expect(fixture.toolCompilations(), isEmpty);
        expect(fixture.compilations(), [gitEntrypoint]);
        expect(
          fixture.commands.readAsLinesSync(),
          isNot(contains('flutter-launch')),
        );
        expect(fixture.launchArguments.existsSync(), isFalse);
        fixture.expectRetained(retained);
        expect(
          fixture.publishedFiles().map((file) => file.path),
          unorderedEquals([
            ...retained.keys,
            if (damage != 'missing') discovery.path,
          ]),
        );
      },
    );
  }

  for (final change in ['added', 'removed']) {
    test(
      'final discovery rejects $change graph inputs even when files are unchanged',
      () async {
        final extra = File(
          '${fixture.root.path}/plugins/source_editor/extra.dart',
        )..writeAsStringSync('// additional graph input\n');
        await fixture.prepare();
        final retained = fixture.retainedFiles();
        final inputs =
            (jsonDecode(fixture.buildInputs.readAsStringSync())
                    as Map<String, dynamic>)
                .map(
                  (key, value) => MapEntry(key, (value as List).cast<String>()),
                );
        final paths = inputs['source-editor-frontend-compilation']!;
        if (change == 'added') {
          paths.add(extra.path);
          paths.sort();
        } else {
          expect(paths.remove('${fixture.root.path}/$sharedSource'), isTrue);
        }
        final finalInputs = File(
          '${fixture.root.path}/logs/final-build-inputs.json',
        )..writeAsStringSync(jsonEncode(inputs));
        final hook = File('${fixture.root.path}/logs/final-discovery-hook');
        writeExecutableScript(
          hook,
          "cp '${finalInputs.path}' '${fixture.buildInputs.path}'",
        );
        fixture.environment['ADELE_TEST_FINAL_DISCOVERY_HOOK'] = hook.path;
        final discoveries = File('${fixture.root.path}/logs/discovery.txt')
          ..writeAsStringSync('');
        fixture.commands.deleteSync();
        fixture.launchArguments.deleteSync();

        final result = await fixture.invoke(['run', 'linux']);
        expect(
          result.exitCode,
          1,
          reason: '${result.stdout}\n${result.stderr}',
        );
        expect(
          result.stderr,
          contains('Build inputs changed during desktop preparation'),
        );
        expect(discoveries.readAsLinesSync(), ['discover|aot', 'discover|aot']);
        expect(fixture.toolCompilations(), isEmpty);
        expect(fixture.compilations(), isEmpty);
        expect(
          fixture.commands.readAsLinesSync(),
          isNot(contains('flutter-launch')),
        );
        expect(fixture.launchArguments.existsSync(), isFalse);
        fixture.expectRetained(retained);
        expect(
          fixture.publishedFiles().map((file) => file.path),
          unorderedEquals(retained.keys),
        );
      },
    );
  }

  test(
    'changed selected runtime is rejected before final discovery execution',
    () async {
      await fixture.prepare();
      final retained = fixture.retainedFiles();
      fixture.changeSource(gitEntrypoint);
      final marker = File('${fixture.root.path}/logs/changed-runtime-executed');
      final replacement = File('${fixture.root.path}/logs/replacement-runtime');
      writeExecutableScript(replacement, "touch '${marker.path}'\nexit 97");
      final hook = File('${fixture.root.path}/logs/compile-hook');
      writeExecutableScript(
        hook,
        "cp '${replacement.path}' '${fixture.sdkBin.path}/dartaotruntime'",
      );
      fixture.environment['ADELE_TEST_COMPILE_HOOK'] = hook.path;
      final discoveries = File('${fixture.root.path}/logs/discovery.txt')
        ..writeAsStringSync('');
      fixture.commands.deleteSync();
      fixture.launchArguments.deleteSync();

      final result = await fixture.invoke(['run', 'linux']);
      expect(result.exitCode, 1, reason: '${result.stdout}\n${result.stderr}');
      expect(
        result.stderr,
        contains(
          'Build tool inputs or artifacts changed during desktop preparation',
        ),
      );
      expect(marker.existsSync(), isFalse);
      expect(discoveries.readAsLinesSync(), ['discover|aot']);
      expect(fixture.toolCompilations(), isEmpty);
      expect(fixture.compilations(), [gitEntrypoint]);
      expect(fixture.launchArguments.existsSync(), isFalse);
      fixture.expectRetained(retained);
      expect(
        fixture.publishedFiles().map((file) => file.path),
        unorderedEquals(retained.keys),
      );
    },
  );

  test(
    'source mutation during compilation prevents publication and launch',
    () async {
      fixture.environment['ADELE_TEST_MUTATE_SOURCE'] =
          '${fixture.root.path}/$sharedSource';
      final result = await fixture.invoke(['run', 'linux']);
      expect(result.exitCode, 1);
      expect(
        result.stderr,
        contains('Build inputs changed during desktop preparation'),
      );
      expect(fixture.launchArguments.existsSync(), isFalse);
      expect(fixture.publishedFiles(), isEmpty);
      fixture.environment.remove('ADELE_TEST_MUTATE_SOURCE');
      await fixture.prepare();
      expect(
        fixture.compilations(),
        hasLength(backendEntrypoints.length + frontendCompilations.length + 1),
      );
    },
  );

  test(
    'tool mutation during generation cannot cache the already-loaded implementation',
    () async {
      fixture.environment['ADELE_TEST_MUTATE_TOOL_DURING_GENERATION'] =
          '${fixture.root.path}/packages/plugin_builder/lib/src/development_plugin_builder.dart';
      final result = await fixture.invoke(['run', 'linux']);
      expect(result.exitCode, 1);
      expect(
        result.stderr,
        contains('Build inputs changed during desktop preparation'),
      );
      expect(fixture.launchArguments.existsSync(), isFalse);
      expect(fixture.publishedFiles(), isEmpty);
    },
  );
}
