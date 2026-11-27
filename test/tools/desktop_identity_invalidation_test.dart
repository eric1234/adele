import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

// ignore: avoid_relative_lib_imports
import '../../packages/plugin_runtime/lib/plugin_runtime.dart';
import 'support/desktop_launcher_fixture.dart';
import 'support/desktop_launcher_inputs.dart';

void main() {
  late DesktopLauncherFixture fixture;
  setUp(() async {
    fixture = await DesktopLauncherFixture.create();
  });

  for (final toolchain in [
    'dart',
    'dartaotruntime',
    'machine',
    'cc',
    'dart-compiler',
    'flutter-compiler',
    'platform',
    'platform-product',
    'platform-jit',
  ]) {
    test(
      '$toolchain identity changes invalidate matching cached artifacts',
      () async {
        await fixture.prepare();
        final retained = fixture.retainedFiles();
        if (toolchain == 'machine') {
          final version =
              jsonDecode(fixture.sdkVersion.readAsStringSync())
                  as Map<String, dynamic>;
          version['engineRevision'] = 'fixture-engine-2';
          fixture.sdkVersion.writeAsStringSync(jsonEncode(version));
        } else {
          final executable = File(switch (toolchain) {
            'cc' => '${fixture.root.path}/bin/cc',
            'dart-compiler' =>
              '${fixture.sdkBin.path}/snapshots/gen_kernel_aot.dart.snapshot',
            'flutter-compiler' =>
              '${fixture.root.path}/flutter sdk/bin/cache/artifacts/engine/linux-x64/frontend_server_aot.dart.snapshot',
            'platform' =>
              '${fixture.sdkBin.parent.path}/lib/_internal/vm_platform_strong.dill',
            'platform-product' =>
              '${fixture.sdkBin.parent.path}/lib/_internal/vm_platform_product.dill',
            'platform-jit' =>
              '${fixture.sdkBin.parent.path}/lib/_internal/vm_platform.dill',
            _ => '${fixture.sdkBin.path}/$toolchain',
          });
          executable.writeAsStringSync(
            '\n# toolchain revision 2\n',
            mode: FileMode.append,
          );
        }
        await fixture.prepare();
        expect(
          fixture.compilations(),
          unorderedEquals(
            toolchain == 'cc'
                ? ['git-pty-helper']
                : [...backendEntrypoints, ...frontendCompilations.values],
          ),
        );
        expect(
          fixture.toolCompilations(),
          toolchain == 'cc' ? isEmpty : toolStages.values,
        );
        fixture.expectRetained(retained);
      },
    );
  }

  test(
    'startup configuration changes neither compile nor replace snapshots',
    () async {
      final before = await fixture.prepare();
      final retained = fixture.retainedFiles();
      fixture.environment.addAll({
        'ADELE_OPENAI_CHATGPT_CREDENTIAL_FILE':
            '${fixture.root.path}/credential-reference.json',
        'ADELE_OPENAI_CHATGPT_CLIENT_ID': 'different-public-client',
      });
      final configured = await fixture.prepare();
      expect(fixture.compilations(), isEmpty);
      for (final key in [
        'ADELE_BACKEND_HOST_ARTIFACT',
        'ADELE_PLUGIN_INSTALLATION_ROOT',
        'ADELE_DARTAOTRUNTIME_EXECUTABLE',
      ]) {
        expect(configured[key], before[key]);
      }
      expect(
        configured['ADELE_PLUGIN_STARTUP_ARGUMENTS_FILE'],
        isNot(before['ADELE_PLUGIN_STARTUP_ARGUMENTS_FILE']),
      );
      expect(
        fixture.readStartupArguments(),
        contains('different-public-client'),
      );
      fixture.expectRetained(retained);
      final credential = File(
        fixture.environment['ADELE_OPENAI_CHATGPT_CREDENTIAL_FILE']!,
      )..writeAsStringSync('secret-rotated-credential');
      fixture.environment['ADELE_OPENAI_CHATGPT_MODEL'] = 'not-a-build-input';
      expect(await fixture.prepare(), configured);
      expect(fixture.compilations(), isEmpty);
      expect(
        fixture.readStartupArguments(),
        isNot(contains(credential.readAsStringSync())),
      );
      fixture.environment['ADELE_OPENAI_CHATGPT_CREDENTIAL_FILE'] = '';
      expect(await fixture.prepare(), before);
      expect(fixture.compilations(), isEmpty);
    },
  );

  for (final metadata in [
    'settings',
    'policy-settings',
    'records',
    'agent-records',
    'model-presets',
    'descriptors',
  ]) {
    test(
      '$metadata changes republish metadata without plugin compilation',
      () async {
        final before = await fixture.prepare();
        final retained = fixture.retainedFiles();
        final file = File(
          '${fixture.root.path}/${switch (metadata) {
            'settings' => 'plugins/source_editor/settings.schema.json',
            'policy-settings' => 'plugins/conservative_tool_policy/settings.schema.json',
            'records' => 'plugins/openai/records.schema.json',
            'agent-records' => 'plugins/agent_configuration/records.schema.json',
            'model-presets' => modelPresetSchema,
            _ => 'tools/stock_frontend_descriptors.dart',
          }}',
        );
        file.writeAsStringSync(
          file.readAsStringSync().replaceFirst(switch (metadata) {
            'settings' => 'Enable Code Folding',
            'policy-settings' => 'Enable Conservative Tool Authorization',
            'records' => 'OpenAI API',
            'agent-records' => 'When to Use',
            'model-presets' => 'Reasoning Effort',
            _ => 'Open Source...',
          }, 'Revised metadata label'),
        );
        final after = await fixture.prepare();
        expect(fixture.compilations(), isEmpty);
        expect(
          fixture.toolCompilations(),
          metadata == 'descriptors' ? [workerEntrypoint] : isEmpty,
        );
        expect(
          after['ADELE_PLUGIN_INSTALLATION_ROOT'],
          isNot(before['ADELE_PLUGIN_INSTALLATION_ROOT']),
        );
        final catalog = await PreparedPluginCatalog.discover(
          after['ADELE_PLUGIN_INSTALLATION_ROOT']!,
        );
        expect(catalog.issues, isEmpty);
        final content = Directory(after['ADELE_PLUGIN_INSTALLATION_ROOT']!)
            .listSync(recursive: true)
            .whereType<File>()
            .where((file) => file.path.endsWith('.json'))
            .map((file) => file.readAsStringSync())
            .join();
        expect(content, contains('Revised metadata label'));
        fixture.expectRetained(retained);
      },
    );
  }
}
