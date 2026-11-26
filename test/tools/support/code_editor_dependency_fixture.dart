import 'dart:convert';
import 'dart:io';

import 'editor_fixture_io.dart';

final codeEditorDigests = FixtureTextDigests();

/// Creates a local CodeForge source archive and its preparation inputs in [root].
Future<File> createCodeEditorDependencyFixture(
  Directory root, {
  bool additionalPatch = false,
  bool executableInput = false,
}) async {
  final metadata = Directory('${root.path}/third_party/code_forge')
    ..createSync(recursive: true);
  final helper = File('${root.path}/tools/code_editor_dependency.dart');
  helper.parent.createSync(recursive: true);
  File('tools/code_editor_dependency.dart').copySync(helper.path);
  final input = Directory('${root.path}/archive-input')..createSync();
  final originalFiles = {
    'pubspec.yaml':
        'name: code_forge\nversion: 10.14.0\ndependencies:\n  flutter_rust_bridge: 2.13.0\n',
    'lib/code.dart': 'one\n',
    'lib/src/rust/frb_generated.dart':
        "String get codegenVersion => '2.13.0';\nint get rustContentHash => 434014572;\n",
    'rust/src/frb_generated.rs':
        'pub(crate) const FLUTTER_RUST_BRIDGE_CODEGEN_VERSION: &str = "2.13.0";\npub(crate) const FLUTTER_RUST_BRIDGE_CODEGEN_CONTENT_HASH: i32 = 434014572;\n',
    'rust/Cargo.toml': '[package]\nname = "code_forge"\n',
    'rust/Cargo.lock': '# immutable native lock\n',
    'cargokit/build_tool/pubspec.lock': '# immutable helper lock\n',
    if (executableInput) 'cargokit/build_pod.sh': '#!/bin/sh\nexit 0\n',
    'build/archived-source.txt': 'archived files are not disposable\n',
  };
  for (final entry in originalFiles.entries) {
    final file = File('${input.path}/${entry.key}');
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(entry.value);
  }
  if (executableInput) {
    final mode = await Process.run('chmod', [
      '755',
      '${input.path}/cargokit/build_pod.sh',
    ]);
    if (mode.exitCode != 0) throw StateError('${mode.stderr}');
  }
  final archive = File('${root.path}/fixture.tar.gz');
  final tar = await Process.run('tar', [
    '-czf',
    archive.path,
    '-C',
    input.path,
    '.',
  ]);
  if (tar.exitCode != 0) throw StateError('${tar.stderr}');
  final hash = await Process.run('sha256sum', [archive.path]);
  if (hash.exitCode != 0) throw StateError('${hash.stderr}');
  for (final (name, before, after) in [
    ('01.patch', 'one', 'two'),
    ('02.patch', 'two', 'three'),
    if (additionalPatch) ('03.patch', 'three', 'four'),
  ]) {
    File('${metadata.path}/$name').writeAsStringSync('''
diff --git a/lib/code.dart b/lib/code.dart
--- a/lib/code.dart
+++ b/lib/code.dart
@@ -1 +1 @@
-$before
+$after
''');
  }
  const runnerTemplate = 'path: "@CODEFORGE_BUILD_TOOL@"\n';
  File(
    '${metadata.path}/runner.lock.template',
  ).writeAsStringSync(runnerTemplate);
  final expectedFiles = {
    ...originalFiles,
    'lib/code.dart': additionalPatch ? 'four\n' : 'three\n',
    'cargokit/build_tool/runner.lock': runnerTemplate,
  };
  final expectedHashes = <String, String>{};
  for (final path in expectedFiles.keys.toList()..sort()) {
    expectedHashes[path] =
        '${await codeEditorDigests.sha256(expectedFiles[path]!)}:${path == 'cargokit/build_pod.sh' ? 0x49 : 0}';
  }
  File('${metadata.path}/preparation.json').writeAsStringSync(
    jsonEncode({
      'schema': 1,
      'package': 'code_forge',
      'version': '10.14.0',
      'rust': '1.93.0',
      'flutterRustBridge': '2.13.0',
      'generatedBindingHash': 434014572,
      'preparedTreeSha256': await codeEditorDigests.sha256(
        jsonEncode(expectedHashes),
      ),
      'archiveUrl': archive.uri.toString(),
      'archiveSha256': (hash.stdout as String).split(' ').first,
      'patches': ['01.patch', '02.patch', if (additionalPatch) '03.patch'],
      'runnerLock': 'runner.lock.template',
    }),
  );
  return archive;
}
