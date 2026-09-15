import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'openai_activity_frontend_compiler.dart';

void main() {
  test('compile the prepared stock OpenAI activity frontend', () async {
    final String? root = Platform.environment['ADELE_REPOSITORY_ROOT'];
    final String? output =
        Platform.environment['ADELE_OPENAI_ACTIVITY_FRONTEND_OUTPUT'];
    if (root == null || root.isEmpty || output == null || output.isEmpty) {
      throw StateError(
        'ADELE_REPOSITORY_ROOT and ADELE_OPENAI_ACTIVITY_FRONTEND_OUTPUT '
        'are required.',
      );
    }
    await File(output).writeAsBytes(
      await compileOpenAiActivityFrontend(repositoryRoot: Directory(root)),
    );
  });
}
