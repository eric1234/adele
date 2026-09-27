import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'task_browser_frontend_compiler.dart';

void main() {
  test('compile the prepared stock Task Browser frontend', () async {
    final root = Platform.environment['ADELE_REPOSITORY_ROOT'];
    final output = Platform.environment['ADELE_TASK_BROWSER_FRONTEND_OUTPUT'];
    if (root == null || root.isEmpty || output == null || output.isEmpty) {
      throw StateError(
        'ADELE_REPOSITORY_ROOT and ADELE_TASK_BROWSER_FRONTEND_OUTPUT are required.',
      );
    }
    await File(output).writeAsBytes(
      await compileTaskBrowserFrontend(repositoryRoot: Directory(root)),
    );
  });
}
