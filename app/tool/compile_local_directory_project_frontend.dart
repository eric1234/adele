import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'local_directory_project_frontend_compiler.dart';

void main() {
  test('compile the prepared stock Local Directory Project frontend', () async {
    final String? root = Platform.environment['ADELE_REPOSITORY_ROOT'];
    final String? output =
        Platform.environment['ADELE_LOCAL_DIRECTORY_PROJECT_FRONTEND_OUTPUT'];
    if (root == null || root.isEmpty || output == null || output.isEmpty) {
      throw StateError(
        'ADELE_REPOSITORY_ROOT and ADELE_LOCAL_DIRECTORY_PROJECT_FRONTEND_OUTPUT '
        'are required.',
      );
    }
    await File(output).writeAsBytes(
      await compileLocalDirectoryProjectFrontend(
        repositoryRoot: Directory(root),
      ),
    );
  });
}
