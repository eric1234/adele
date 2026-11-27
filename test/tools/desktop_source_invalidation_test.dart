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

  for (final mutation in [
    (path: gitEntrypoint, expected: [gitEntrypoint]),
    (
      path: modelConfigurationEntrypoint,
      expected: [modelConfigurationEntrypoint],
    ),
    (
      path: agentConfigurationEntrypoint,
      expected: [agentConfigurationEntrypoint],
    ),
    (
      path: 'app/$agentConfigurationFrontendHarness',
      expected: [agentConfigurationFrontendHarness],
    ),
    (
      path: 'plugins/model_configuration/packages/frontend/lib/fixture.dart',
      expected: [modelConfigurationFrontendHarness],
    ),
    (
      path: conservativeToolPolicyEntrypoint,
      expected: [conservativeToolPolicyEntrypoint],
    ),
    (path: chatSource, expected: [frontendHarness]),
    (path: chatCompiler, expected: [frontendHarness]),
    (path: frontendBridge, expected: frontendCompilations.values.toList()),
    (
      path: sharedSource,
      expected: [...backendEntrypoints, ...frontendCompilations.values],
    ),
    (path: 'contract.dart', expected: [...backendEntrypoints, frontendHarness]),
    (path: nativeSource, expected: ['git-pty-helper']),
    (path: nativeHeader, expected: ['git-pty-helper']),
    (path: 'native/ld', expected: ['git-pty-helper']),
    (path: 'native/libc.so', expected: ['git-pty-helper']),
    (path: 'tools/git_pty_artifact.dart', expected: ['git-pty-helper']),
    (
      path: 'tools/frontend_artifacts.dart',
      expected: frontendCompilations.values.toList(),
    ),
    (
      path: 'packages/plugin_builder/lib/src/development_plugin_builder.dart',
      expected: backendEntrypoints,
    ),
    (
      path: 'tools/desktop_build_inputs_worker.dart',
      expected: [...backendEntrypoints, ...frontendCompilations.values],
    ),
  ]) {
    test(
      'incremental preparation rebuilds only consumers of ${mutation.path}',
      () async {
        final before = await fixture.prepare();
        expect(
          fixture.compilations(),
          hasLength(
            backendEntrypoints.length + frontendCompilations.length + 1,
          ),
        );
        expect(fixture.toolCompilations(), toolStages.values);
        final retained = fixture.retainedFiles();
        fixture.changeSource(mutation.path);
        final after = await fixture.prepare(['build', 'linux', '--release']);
        expect(fixture.compilations(), unorderedEquals(mutation.expected));
        expect(
          fixture.toolCompilations(),
          mutation.path.startsWith('tools/')
              ? [workerEntrypoint]
              : mutation.path ==
                    'packages/plugin_builder/lib/src/development_plugin_builder.dart'
              ? toolStages.values
              : isEmpty,
        );
        expect(
          after['ADELE_PLUGIN_INSTALLATION_ROOT'],
          isNot(before['ADELE_PLUGIN_INSTALLATION_ROOT']),
        );
        fixture.expectRetained(retained);
        final warm = await fixture.prepare();
        expect(fixture.compilations(), isEmpty);
        expect(fixture.toolCompilations(), isEmpty);
        expect(warm, after);
        fixture.expectRetained(retained);
      },
    );
  }

  test('touches and unrelated files retain all cached paths', () async {
    final before = await fixture.prepare();
    final retained = fixture.retainedFiles();
    for (final path in [
      gitEntrypoint,
      chatSource,
      sharedSource,
      frontendBridge,
      nativeSource,
      generatorSource,
      analyzerSource,
      workerEntrypoint,
    ]) {
      File(
        '${fixture.root.path}/$path',
      ).setLastModifiedSync(DateTime.utc(2000));
    }
    fixture.generatedContract.setLastModifiedSync(DateTime.utc(2000));
    File('${fixture.sdkBin.path}/dart').setLastModifiedSync(DateTime.utc(2000));
    File(
      '${fixture.root.path}/unrelated.txt',
    ).writeAsStringSync('not a compiler input');
    File(
      '${fixture.root.path}/app/unrelated.dart',
    ).writeAsStringSync('// not in discovery');
    expect(await fixture.prepare(['build', 'linux', '--profile']), before);
    expect(fixture.compilations(), isEmpty);
    expect(fixture.toolCompilations(), isEmpty);
    fixture.expectRetained(retained);
  });

  test(
    'discovered source additions and removals invalidate their component',
    () async {
      final before = await fixture.prepare();
      final retained = fixture.retainedFiles();
      final added = File(
        '${fixture.root.path}/plugins/source_editor/packages/frontend/lib/new_part.dart',
      )..writeAsStringSync('const added = 1;\n');
      final inputs =
          (jsonDecode(fixture.buildInputs.readAsStringSync())
                  as Map<String, dynamic>)
              .map(
                (key, value) => MapEntry(key, (value as List).cast<String>()),
              );
      const stage = 'source-editor-frontend-compilation';
      inputs[stage]!.add(added.path);
      inputs[stage]!.sort();
      fixture.buildInputs.writeAsStringSync(jsonEncode(inputs));
      final withAddition = await fixture.prepare();
      expect(fixture.compilations(), [sourceEditorFrontendHarness]);
      expect(fixture.toolCompilations(), isEmpty);
      expect(withAddition, isNot(before));
      final removed = inputs[stage]!.firstWhere(
        (path) => path.endsWith('/fixture.dart'),
      );
      inputs[stage]!.remove(removed);
      File(removed).deleteSync();
      fixture.buildInputs.writeAsStringSync(jsonEncode(inputs));
      final withRemoval = await fixture.prepare();
      expect(fixture.compilations(), [sourceEditorFrontendHarness]);
      expect(fixture.toolCompilations(), isEmpty);
      expect(withRemoval, isNot(withAddition));
      fixture.expectRetained(retained);
    },
  );
}
