import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'compile_frontend.dart';

void main() {
  test('prepare editor EVC before building the desktop smoke', () async {
    final artifact = File('build/code_editor_smoke/editor_frontend.evc');
    await artifact.parent.create(recursive: true);
    await compileCodeEditorFrontend(
      repositoryRoot: Directory.current.parent,
      artifact: artifact,
    );
    expect(await artifact.length(), greaterThan(0));
  });
}
