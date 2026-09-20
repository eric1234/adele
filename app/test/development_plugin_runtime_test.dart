import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:plugin_builder/plugin_builder.dart';
import 'package:plugin_runtime/plugin_runtime.dart';

import '../tool/development_runtime_smoke/development_plugin_runtime.dart';

void main() {
  test('validates explicit development configuration', () {
    final Directory root = Directory.systemTemp.createTempSync(
      'adele-development-runtime-',
    );
    addTearDown(() => root.deleteSync(recursive: true));
    final DevelopmentRuntimeConfiguration configuration =
        DevelopmentRuntimeConfiguration(
          repositoryRoot: root,
          pluginDirectory: root,
          developmentDirectory: root,
          dartExecutable: '${root.path}/dart',
          dartAotRuntimeExecutable: '${root.path}/dartaotruntime',
          flutterExecutable: '${root.path}/flutter',
        );
    expect(configuration.validate, throwsStateError);
  });

  for (final scenario in [
    (backend: 'basic', exitCode: 7),
    (backend: 'alternate', exitCode: 9),
    (backend: 'basic', exitCode: 0),
  ]) {
    test(
      '${scenario.backend} compiler exit ${scenario.exitCode} preserves failure output without noisy success',
      () async {
        final Directory root = await Directory.systemTemp.createTemp(
          'adele development compiler ',
        );
        addTearDown(() => root.delete(recursive: true));
        final File compiler = File('${root.path}/fake-dart');
        await compiler.writeAsString('''#!/bin/sh
test "\$1" = compile && test "\$2" = aot-snapshot && test "\$4" = -o || exit 99
printf 'compiler stdout sentinel\\n'
printf 'compiler stderr sentinel\\n' >&2
if [ ${scenario.exitCode} = 0 ]; then
  printf snapshot > "\$5"
fi
exit ${scenario.exitCode}
''');
        final ProcessResult chmod = await Process.run('chmod', [
          '+x',
          compiler.path,
        ]);
        expect(chmod.exitCode, 0);
        final DevelopmentPluginRuntime runtime = DevelopmentPluginRuntime(
          DevelopmentRuntimeConfiguration(
            repositoryRoot: root,
            pluginDirectory: root,
            developmentDirectory: root,
            dartExecutable: compiler.path,
            dartAotRuntimeExecutable: Platform.resolvedExecutable,
            flutterExecutable: Platform.resolvedExecutable,
          ),
        );
        addTearDown(runtime.stop);
        final File artifact = File('${root.path}/output/backend.aot');
        final Future<void> compiling = runtime.compileResourceInspectorBackend(
          '${root.path}/resource_inspector_${scenario.backend}_backend.dart',
          artifact,
        );
        if (scenario.exitCode == 0) {
          await compiling;
          expect(await artifact.readAsString(), 'snapshot');
        } else {
          await expectLater(
            compiling,
            throwsA(
              isA<PluginBuildFailure>()
                  .having(
                    (error) => error.toString(),
                    'displayed failure',
                    allOf(
                      contains('resource-inspector compile'),
                      contains('exit code ${scenario.exitCode}'),
                      contains('stdout:\ncompiler stdout sentinel'),
                      contains('stderr:\ncompiler stderr sentinel'),
                    ),
                  )
                  .having(
                    (error) => error.diagnostic?.exitCode,
                    'compiler exit',
                    scenario.exitCode,
                  ),
            ),
          );
          expect(await artifact.exists(), isFalse);
        }
        expect(runtime.diagnostics, [
          'resource-inspector compile: exit ${scenario.exitCode}',
        ]);
        expect(runtime.hostProcessId, isNull);
      },
      skip: Platform.isWindows ? 'POSIX fake compiler fixture' : false,
    );
  }

  test('forces host cleanup when connection close fails', () async {
    final List<String> calls = <String>[];
    await expectLater(
      cleanupDevelopmentRuntimeResources(
        closeConnection: () async {
          calls.add('connection');
          throw StateError('plugin stop failed');
        },
        closeHost: ({required bool graceful}) async {
          calls.add('host:$graceful');
        },
      ),
      throwsA(
        isA<StateError>().having(
          (StateError error) => error.message,
          'message',
          'plugin stop failed',
        ),
      ),
    );
    expect(calls, <String>['connection', 'host:false']);
  });

  test('preserves plugin stop failure when host cleanup also fails', () async {
    final List<Object> cleanupErrors = <Object>[];
    await expectLater(
      cleanupDevelopmentRuntimeResources(
        closeConnection: () async {
          throw const PluginConnectionClosed('host exited during plugin stop');
        },
        closeHost: ({required bool graceful}) async {
          expect(graceful, isFalse);
          throw StateError('host already gone');
        },
        onCleanupError: cleanupErrors.add,
      ),
      throwsA(isA<PluginConnectionClosed>()),
    );
    expect(cleanupErrors.single, isA<StateError>());
  });

  test('cleanup state permits a subsequent start attempt', () async {
    bool active = true;
    Future<void> stop() async {
      active = false;
      await cleanupDevelopmentRuntimeResources(
        closeConnection: () async => throw StateError('stop failed'),
        closeHost: ({required bool graceful}) async {},
      );
    }

    await expectLater(stop(), throwsStateError);
    expect(active, isFalse);
    active = true;
    expect(active, isTrue);
  });
}
