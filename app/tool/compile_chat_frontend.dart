import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'chat_frontend_compiler.dart';

void main() {
  test('compile the prepared stock Chat frontend', () async {
    final String? root = Platform.environment['ADELE_REPOSITORY_ROOT'];
    final String? output = Platform.environment['ADELE_CHAT_FRONTEND_OUTPUT'];
    if (root == null || root.isEmpty || output == null || output.isEmpty) {
      throw StateError(
        'ADELE_REPOSITORY_ROOT and ADELE_CHAT_FRONTEND_OUTPUT are required.',
      );
    }
    await compileChatFrontend(
      repositoryRoot: Directory(root),
      artifact: File(output),
    );
  });
}
