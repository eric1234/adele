import 'dart:convert';
import 'dart:io';

import 'editor_fixture_io.dart';

final richEditorDigests = FixtureTextDigests();

/// Creates a local AppFlowy source archive and its preparation inputs in [root].
Future<File> createRichEditorDependencyFixture(
  Directory root, {
  bool additionalPatch = false,
}) async {
  final metadata = Directory('${root.path}/third_party/appflowy_editor')
    ..createSync(recursive: true);
  final helper = File('${root.path}/tools/rich_editor_dependency.dart');
  helper.parent.createSync(recursive: true);
  File('tools/rich_editor_dependency.dart').copySync(helper.path);
  final input = Directory('${root.path}/rich-archive-input')..createSync();
  final files = {
    'pubspec.yaml': 'name: appflowy_editor\nversion: 6.2.0\n',
    'LICENSE': 'fixture license retained verbatim\n',
    'lib/editor.dart': 'one\n',
    'build/archived-input': 'not disposable\n',
    'pubspec.lock': 'archived lock stays immutable\n',
    'tool.sh': '#!/bin/sh\nexit 0\n',
  };
  for (final entry in files.entries) {
    final file = File('${input.path}/${entry.key}');
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(entry.value);
  }
  await runEditorFixtureCommand('chmod', ['755', '${input.path}/tool.sh']);
  final archive = File('${root.path}/rich-fixture.tar.gz');
  await runEditorFixtureCommand('tar', [
    '-czf',
    archive.path,
    '-C',
    input.path,
    '.',
  ]);
  for (final (name, before, after) in [
    ('01.patch', 'one', 'two'),
    if (additionalPatch) ('02.patch', 'two', 'three'),
  ]) {
    File('${metadata.path}/$name').writeAsStringSync('''
diff --git a/lib/editor.dart b/lib/editor.dart
--- a/lib/editor.dart
+++ b/lib/editor.dart
@@ -1 +1 @@
-$before
+$after
''');
  }
  files['lib/editor.dart'] = additionalPatch ? 'three\n' : 'two\n';
  final expected = <String, String>{'build': 'directory', 'lib': 'directory'};
  for (final path in files.keys) {
    expected[path] =
        '${await richEditorDigests.sha256(files[path]!)}:${path == 'tool.sh' ? 73 : 0}';
  }
  final canonical = {
    for (final path in expected.keys.toList()..sort()) path: expected[path],
  };
  File('${metadata.path}/preparation.json').writeAsStringSync(
    jsonEncode({
      'schema': 1,
      'package': 'appflowy_editor',
      'version': '6.2.0',
      'archiveUrl': archive.uri.toString(),
      'archiveSha256': (await runEditorFixtureCommand('sha256sum', [
        archive.path,
      ])).stdout.toString().split(' ').first,
      'preparedTreeSha256': await richEditorDigests.sha256(
        jsonEncode(canonical),
      ),
      'patches': ['01.patch', if (additionalPatch) '02.patch'],
    }),
  );
  return archive;
}
