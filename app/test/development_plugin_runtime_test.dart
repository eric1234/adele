import 'dart:io';

import 'package:adele_desktop/development/development_plugin_runtime.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plugin_runtime/plugin_runtime.dart';

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
