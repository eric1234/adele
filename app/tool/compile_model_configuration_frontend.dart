import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'model_configuration_frontend_compiler.dart';

void main() {
  test('compile the prepared stock Model Configuration frontend', () async {
    final root = Platform.environment['ADELE_REPOSITORY_ROOT'];
    final output =
        Platform.environment['ADELE_MODEL_CONFIGURATION_FRONTEND_OUTPUT'];
    if (root == null || root.isEmpty || output == null || output.isEmpty) {
      throw StateError(
        'ADELE_REPOSITORY_ROOT and ADELE_MODEL_CONFIGURATION_FRONTEND_OUTPUT are required.',
      );
    }
    await File(output).writeAsBytes(
      await compileModelConfigurationFrontend(repositoryRoot: Directory(root)),
    );
  });
}
