import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import '../../tools/rich_editor_dependency.dart';

// Shared launcher fixture: real tar/git/hash/curl operations, no network or SDK
// package resolution. Names do not collide with the separate CodeForge fixture.
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
  await _run('chmod', ['755', '${input.path}/tool.sh']);
  final archive = File('${root.path}/rich-fixture.tar.gz');
  await _run('tar', ['-czf', archive.path, '-C', input.path, '.']);
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
        '${await _sha256(files[path]!)}:${path == 'tool.sh' ? 73 : 0}';
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
      'archiveSha256': (await _run('sha256sum', [
        archive.path,
      ])).stdout.toString().split(' ').first,
      'preparedTreeSha256': await _sha256(jsonEncode(canonical)),
      'patches': ['01.patch', if (additionalPatch) '02.patch'],
    }),
  );
  return archive;
}

void main() {
  late Directory root;
  late Directory source;
  late File archive;
  setUp(() async {
    root = Directory.systemTemp.createTempSync('adele appflowy ');
    archive = await createRichEditorDependencyFixture(root);
    source = Directory('${root.path}/.adele/dependencies/appflowy_editor');
  });
  tearDown(() => root.deleteSync(recursive: true));

  Future<Directory> prepare({bool reprepare = false}) =>
      prepareRichEditorSource(root, archive: archive, reprepare: reprepare);
  File file(String path) => File('${source.path}/$path');
  File getMetadata() =>
      File('${root.path}/third_party/appflowy_editor/preparation.json');
  void changeMetadata(String key, Object value) {
    final metadata = getMetadata();
    final config = jsonDecode(metadata.readAsStringSync()) as Map;
    config[key] = value;
    metadata.writeAsStringSync(jsonEncode(config));
  }

  test(
    'fresh source applies patch inside ignored Git tree, then reuses without archive',
    () async {
      await _run('git', ['init', '--quiet', root.path]);
      File('${root.path}/.gitignore').writeAsStringSync('.adele/\n');
      expect((await prepare()).path, source.path);
      expect(file('lib/editor.dart').readAsStringSync(), 'two\n');
      expect(
        file('LICENSE').readAsStringSync(),
        'fixture license retained verbatim\n',
      );
      expect(file('tool.sh').statSync().mode & 0x49, 73);
      final ledger = file('.adele-preparation.json');
      ledger.setLastModifiedSync(DateTime.utc(2000));
      archive.deleteSync();
      expect((await prepareRichEditorSource(root)).path, source.path);
      expect(ledger.lastModifiedSync().toUtc(), DateTime.utc(2000));
    },
  );

  test(
    'file URL download uses the same pinned archive without network',
    () async {
      await prepareRichEditorSource(root);
      expect(file('lib/editor.dart').readAsStringSync(), 'two\n');
    },
  );

  for (final path in [
    'lib/editor.dart',
    'LICENSE',
    'build/archived-input',
    'pubspec.lock',
  ]) {
    test(
      'changed immutable $path fails without repair or consumption',
      () async {
        await prepare();
        file(path).writeAsStringSync('changed');
        await expectLater(
          prepare(),
          _throws('Immutable source content changed'),
        );
        await expectLater(
          withRichEditorSource(root, (_) async => fail('fallback')),
          _throws('No fallback'),
        );
        expect(file(path).readAsStringSync(), 'changed');
      },
    );
  }

  for (final mutation in [
    'missing',
    'extra',
    'empty-directory',
    'link',
    'mode',
    'ledger',
    'root-link',
  ]) {
    test('cache rejects $mutation without silent replacement', () async {
      await prepare();
      switch (mutation) {
        case 'missing':
          file('lib/editor.dart').deleteSync();
        case 'extra':
          file('lib/extra.dart').writeAsStringSync('extra');
        case 'empty-directory':
          Directory('${source.path}/extra').createSync();
        case 'link':
          file('lib/editor.dart').deleteSync();
          Link(
            file('lib/editor.dart').path,
          ).createSync('${root.path}/rich-archive-input/lib/editor.dart');
        case 'mode':
          await _run('chmod', ['644', file('tool.sh').path]);
        case 'ledger':
          file('.adele-preparation.json').deleteSync();
        case 'root-link':
          source.deleteSync(recursive: true);
          Link(source.path).createSync('${root.path}/rich-archive-input');
      }
      await expectLater(prepare(), _throws('Stale or altered'));
    });
  }

  test(
    'forged local ledger cannot bless tampering or hide archived build inputs',
    () async {
      await prepare();
      final ledger = file('.adele-preparation.json');
      final state = jsonDecode(ledger.readAsStringSync()) as Map;
      file('lib/editor.dart').writeAsStringSync('forged\n');
      (state['files'] as Map)['lib/editor.dart'] =
          '${await _sha256('forged\n')}:0';
      (state['files'] as Map).remove('build/archived-input');
      file('build/archived-input').writeAsStringSync('hidden');
      ledger.writeAsStringSync(jsonEncode(state));
      await expectLater(prepare(), _throws('prepared tree checksum mismatch'));
    },
  );

  test(
    'new build and pub output is disposable, archived counterparts are not',
    () async {
      await prepare();
      for (final path in [
        '.dart_tool/config.json',
        'build/generated/output',
        '.flutter-plugins',
        '.flutter-plugins-dependencies',
      ]) {
        final output = file(path);
        output.parent.createSync(recursive: true);
        output.writeAsStringSync('generated');
      }
      await prepare();
      file('build/archived-input').deleteSync();
      await expectLater(prepare(), _throws('Immutable source content changed'));
    },
  );

  for (final path in [
    'third_party/appflowy_editor/01.patch',
    'third_party/appflowy_editor/preparation.json',
    'tools/rich_editor_dependency.dart',
  ]) {
    test('changed $path requires deliberate reprepare', () async {
      await prepare();
      final input = File('${root.path}/$path');
      input.writeAsStringSync('${input.readAsStringSync()}\n');
      await expectLater(prepare(), _throws('Preparation inputs changed'));
      await prepare(reprepare: true);
      await prepare();
    });
  }

  for (final path in [
    'third_party/appflowy_editor/01.patch',
    'tools/rich_editor_dependency.dart',
  ]) {
    test('symlinked immutable preparation input $path is refused', () async {
      final input = File('${root.path}/$path');
      final moved = input.renameSync('${input.path}.original');
      Link(input.path).createSync(moved.path);
      await expectLater(prepare(), _throws('non-regular'));
      expect(source.existsSync(), isFalse);
    });
  }

  test('symlinked source parent cannot redirect publication', () async {
    Directory('${root.path}/.adele').createSync();
    Link(
      '${root.path}/.adele/dependencies',
    ).createSync('${root.path}/rich-archive-input');
    await expectLater(prepare(), _throws('directory is not regular'));
    expect(
      Directory('${root.path}/rich-archive-input/appflowy_editor').existsSync(),
      isFalse,
    );
  });

  test('archive checksum is checked before extraction', () async {
    archive.writeAsStringSync('not approved');
    await expectLater(prepare(), _throws('archive checksum mismatch'));
    expect(source.existsSync(), isFalse);
    expect(source.parent.listSync().whereType<Directory>(), isEmpty);
  });

  test(
    'trusted archive containing a link is rejected before extraction',
    () async {
      Link('${root.path}/rich-archive-input/linked').createSync('/outside');
      await _run('tar', [
        '-czf',
        archive.path,
        '-C',
        '${root.path}/rich-archive-input',
        '.',
      ]);
      changeMetadata(
        'archiveSha256',
        (await _run('sha256sum', [
          archive.path,
        ])).stdout.toString().split(' ').first,
      );
      await expectLater(prepare(), _throws('links or special entries'));
      expect(source.existsSync(), isFalse);
    },
  );

  test(
    'deliberate reprepare applies new ordered patches and removes old outputs',
    () async {
      await prepare();
      final previous = file('.adele-preparation.json').readAsStringSync();
      file('build/generated').writeAsStringSync('old output');
      archive = await createRichEditorDependencyFixture(
        root,
        additionalPatch: true,
      );
      await expectLater(prepare(), _throws('Preparation inputs changed'));
      expect(file('.adele-preparation.json').readAsStringSync(), previous);
      await prepare(reprepare: true);
      expect(file('lib/editor.dart').readAsStringSync(), 'three\n');
      expect(file('build/generated').existsSync(), isFalse);
      await prepare();
      expect(
        source.parent.listSync().whereType<Directory>().map((d) => d.path),
        [source.path],
      );
    },
  );

  for (final corruption in ['content', 'file', 'link']) {
    test(
      'only deliberate reprepare repairs $corruption, leaving link target untouched',
      () async {
        await prepare();
        switch (corruption) {
          case 'content':
            file('lib/editor.dart').writeAsStringSync('changed');
          case 'file':
            source.deleteSync(recursive: true);
            File(source.path).writeAsStringSync('not a directory');
          case 'link':
            source.deleteSync(recursive: true);
            Link(source.path).createSync('${root.path}/rich-archive-input');
        }
        await expectLater(prepare(), throwsStateError);
        await prepare(reprepare: true);
        expect(file('lib/editor.dart').readAsStringSync(), 'two\n');
        expect(
          File(
            '${root.path}/rich-archive-input/lib/editor.dart',
          ).readAsStringSync(),
          'one\n',
        );
      },
    );
  }

  for (final failure in ['archive', 'patch', 'tree', 'version', 'order']) {
    test(
      'failed reprepare $failure preserves old tree but never falls back',
      () async {
        await prepare();
        final previous = file('.adele-preparation.json').readAsStringSync();
        archive = await createRichEditorDependencyFixture(
          root,
          additionalPatch: true,
        );
        switch (failure) {
          case 'archive':
            archive.writeAsStringSync('corrupted');
          case 'patch':
            File(
              '${root.path}/third_party/appflowy_editor/02.patch',
            ).writeAsStringSync('invalid patch');
          case 'tree':
            changeMetadata('preparedTreeSha256', '0' * 64);
          case 'version':
            changeMetadata('version', '9.9.9');
          case 'order':
            changeMetadata('patches', ['02.patch', '01.patch']);
        }
        await expectLater(prepare(reprepare: true), throwsStateError);
        expect(file('.adele-preparation.json').readAsStringSync(), previous);
        expect(file('lib/editor.dart').readAsStringSync(), 'two\n');
        await expectLater(
          withRichEditorSource(root, (_) async => fail('fallback')),
          throwsStateError,
        );
        expect(
          source.parent.listSync().whereType<Directory>().map((d) => d.path),
          [source.path],
        );
      },
    );
  }

  test('publication failure rolls back without returning old source', () async {
    await prepare();
    final previous = file('.adele-preparation.json').readAsStringSync();
    archive = await createRichEditorDependencyFixture(
      root,
      additionalPatch: true,
    );
    var attempted = false;
    await expectLater(
      IOOverrides.runWithIOOverrides(
        () => prepare(reprepare: true),
        _StageOverride(
          publish: (directory, path) async {
            attempted = true;
            expect(source.existsSync(), isFalse);
            expect(
              File('${directory.path}/lib/editor.dart').readAsStringSync(),
              'three\n',
            );
            throw const FileSystemException('injected publication failure');
          },
        ),
      ),
      throwsA(isA<FileSystemException>()),
    );
    expect(attempted, isTrue);
    expect(file('.adele-preparation.json').readAsStringSync(), previous);
    await expectLater(prepare(), throwsStateError);
    await prepare(reprepare: true);
  });

  test('input mutation during staging cannot publish', () async {
    await prepare();
    final previous = file('.adele-preparation.json').readAsStringSync();
    await expectLater(
      IOOverrides.runWithIOOverrides(
        () => prepare(reprepare: true),
        _StageOverride(
          beforeManifest: () {
            final helper = File(
              '${root.path}/tools/rich_editor_dependency.dart',
            );
            helper.writeAsStringSync('${helper.readAsStringSync()}\n');
          },
        ),
      ),
      _throws('inputs changed during preparation'),
    );
    expect(file('.adele-preparation.json').readAsStringSync(), previous);
  });

  test(
    'same-process lease rejects reentrancy and aliases, releases on failure',
    () async {
      await expectLater(
        withRichEditorSource(root, (leased) async {
          expect(leased.path, source.path);
          await expectLater(prepare(reprepare: true), _throws('busy'));
          await expectLater(
            withRichEditorSource(Directory('${root.path}/.'), (_) async {}),
            _throws('busy'),
          );
          throw StateError('consumer failed');
        }, archive: archive),
        _throws('consumer failed'),
      );
      await prepare(reprepare: true);
    },
  );

  test(
    'separate process lease excludes replacement and process death releases it',
    () async {
      await prepare();
      final driver = File('${root.path}/consume.dart')
        ..writeAsStringSync('''
import 'dart:io';
import 'tools/rich_editor_dependency.dart';
Future<void> main() async {
  await withRichEditorSource(Directory.current, (_) async {
    stdout.writeln('leased');
    await stdin.drain<void>();
  });
}
''');
      final process = await Process.start(Platform.resolvedExecutable, [
        driver.path,
      ], workingDirectory: root.path);
      final errors = process.stderr.transform(utf8.decoder).join();
      try {
        expect(
          await process.stdout
              .transform(utf8.decoder)
              .transform(const LineSplitter())
              .first
              .timeout(const Duration(seconds: 10)),
          'leased',
        );
        await expectLater(prepare(reprepare: true), _throws('busy'));
        await expectLater(
          withRichEditorSource(root, (_) async => fail('lease escaped')),
          _throws('busy'),
        );
      } finally {
        process.kill(ProcessSignal.sigkill);
        await process.exitCode.timeout(const Duration(seconds: 10));
        await errors;
      }
      await prepare(reprepare: true);
    },
  );

  test('production metadata and patch stay pinned and source-only', () {
    final config =
        jsonDecode(
              File(
                'third_party/appflowy_editor/preparation.json',
              ).readAsStringSync(),
            )
            as Map;
    expect(config['version'], '6.2.0');
    expect(
      config['archiveUrl'],
      'https://pub.dev/api/archives/appflowy_editor-6.2.0.tar.gz',
    );
    expect(
      config['archiveSha256'],
      'c2367acdd93c7eeefaf6c58e5fed1a1c62cf02b8368102b786b5c6a0d1c583cf',
    );
    expect(config['preparedTreeSha256'], matches(RegExp(r'^[a-f0-9]{64}$')));
    expect(config['patches'], [
      '01-remove-unused-device-info.patch',
      '02-compatible-file-picker.patch',
      '03-compatible-image.patch',
      '04-selection-lifecycle.patch',
    ]);
    final patch = File(
      'third_party/appflowy_editor/${(config['patches'] as List).first}',
    ).readAsStringSync();
    expect(
      RegExp(r'^diff --git ', multiLine: true).allMatches(patch),
      hasLength(2),
    );
    expect(patch, contains('-  device_info_plus: "^11.0.0"'));
    expect(patch, contains('-  static int androidSDKVersion = -1;'));
    expect(patch, isNot(contains('-import \'package:keyboard_height_plugin')));
    expect(
      File('tools/rich_editor_dependency.dart').readAsStringSync(),
      isNot(contains("import 'package:")),
    );
  });
}

Matcher _throws(String text) => throwsA(
  isA<StateError>().having((e) => e.message, 'message', contains(text)),
);

Future<ProcessResult> _run(String command, List<String> args) async {
  final result = await Process.run(
    command,
    args,
  ).timeout(const Duration(seconds: 15));
  if (result.exitCode != 0) {
    throw StateError('${result.stdout}\n${result.stderr}');
  }
  return result;
}

final _digests = <String, Future<String>>{};
Future<String> _sha256(String text) => _digests.putIfAbsent(text, () async {
  final process = await Process.start('sha256sum', []);
  final output = process.stdout.transform(utf8.decoder).join();
  final errors = process.stderr.transform(utf8.decoder).join();
  process.stdin.add(utf8.encode(text));
  await process.stdin.close();
  if (await process.exitCode != 0) throw StateError(await errors);
  return (await output).split(' ').first;
});

// Fault injection at actual I/O boundaries, without production testing hooks.
final class _StageOverride extends IOOverrides {
  _StageOverride({this.publish, this.beforeManifest});
  final Future<Directory> Function(Directory, String)? publish;
  final void Function()? beforeManifest;

  @override
  Future<FileSystemEntityType> fseGetType(
    String path,
    bool followLinks,
  ) async => super.fseGetTypeSync(path, followLinks);

  @override
  Directory createDirectory(String path) {
    final directory = super.createDirectory(path);
    return path.contains('.appflowy_editor-stage-') && path.endsWith('/source')
        ? _StageDirectory(directory, publish, beforeManifest)
        : directory;
  }
}

class _StageDirectory implements Directory {
  _StageDirectory(this.directory, this.publish, this.beforeManifest);
  final Directory directory;
  final Future<Directory> Function(Directory, String)? publish;
  final void Function()? beforeManifest;
  @override
  String get path => directory.path;
  @override
  Directory get parent => directory.parent;
  @override
  void createSync({bool recursive = false}) =>
      directory.createSync(recursive: recursive);
  @override
  Stream<FileSystemEntity> list({
    bool recursive = false,
    bool followLinks = true,
  }) async* {
    beforeManifest?.call();
    yield* directory.list(recursive: recursive, followLinks: followLinks);
  }

  @override
  Future<Directory> rename(String path) =>
      publish?.call(directory, path) ?? directory.rename(path);
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
