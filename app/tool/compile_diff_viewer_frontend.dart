import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'diff_viewer_frontend_compiler.dart';

void main() {
  test('compile the prepared stock Diff frontend', () async {
    final root = Platform.environment['ADELE_REPOSITORY_ROOT'];
    final output = Platform.environment['ADELE_DIFF_VIEWER_FRONTEND_OUTPUT'];
    if (root == null || root.isEmpty || output == null || output.isEmpty) {
      throw StateError(
        'ADELE_REPOSITORY_ROOT and ADELE_DIFF_VIEWER_FRONTEND_OUTPUT are required.',
      );
    }
    final artifact = File(output);
    await compileDiffViewerFrontend(
      repositoryRoot: Directory(root),
      sdkPath: diffViewerDartSdk(),
      artifact: artifact,
    );
    expect(await artifact.length(), greaterThan(0));
  });
}
