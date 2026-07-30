import 'dart:io';

import 'package:adele_desktop/development/development_plugin_runtime.dart';
import 'package:flutter_test/flutter_test.dart';

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
}
