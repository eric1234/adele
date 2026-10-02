import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import '../../tools/code_editor_dependency.dart';

// Shared with the launcher fixture: real local tar/patch/hash operations, no
// network, Flutter, pub resolution, or Rust compiler.
// Run directly with the pinned Dart SDK and explicit FLUTTER_ROOT, not the
// maintained launcher test target, which also verifies production preparation.
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
        '${await _sha256(expectedFiles[path]!)}:${path == 'cargokit/build_pod.sh' ? 0x49 : 0}';
  }
  File('${metadata.path}/preparation.json').writeAsStringSync(
    jsonEncode({
      'schema': 1,
      'package': 'code_forge',
      'version': '10.14.0',
      'rust': '1.93.0',
      'flutterRustBridge': '2.13.0',
      'generatedBindingHash': 434014572,
      'preparedTreeSha256': await _sha256(jsonEncode(expectedHashes)),
      'archiveUrl': archive.uri.toString(),
      'archiveSha256': (hash.stdout as String).split(' ').first,
      'patches': ['01.patch', '02.patch', if (additionalPatch) '03.patch'],
      'runnerLock': 'runner.lock.template',
    }),
  );
  return archive;
}

final _fixtureDigests = <String, Future<String>>{};

Future<String> _sha256(String text) =>
    _fixtureDigests.putIfAbsent(text, () async {
      final process = await Process.start('sha256sum', []);
      final output = process.stdout.transform(utf8.decoder).join();
      final error = process.stderr.transform(utf8.decoder).join();
      process.stdin.add(utf8.encode(text));
      await process.stdin.close();
      if (await process.exitCode != 0) throw StateError(await error);
      return (await output).split(' ').first;
    });

void main() {
  late Directory root;
  late File archive;
  late Directory source;
  setUp(() async {
    root = Directory.systemTemp.createTempSync('adele codeforge ');
    archive = await createCodeEditorDependencyFixture(root);
    source = Directory('${root.path}/.adele/dependencies/code_forge');
  });
  tearDown(() => root.deleteSync(recursive: true));

  Future<Directory> prepare({bool reprepare = false}) =>
      prepareCodeEditorSource(root, archive: archive, reprepare: reprepare);

  for (final mask in ['027', '077']) {
    test(
      'fresh preparation preserves archive execute bits with umask $mask',
      () async {
        archive = await createCodeEditorDependencyFixture(
          root,
          executableInput: true,
        );
        final result = await Process.run('sh', [
          '-c',
          'umask "\$1"; shift; exec "\$@"',
          'prepare-with-umask',
          mask,
          Platform.resolvedExecutable,
          File('tools/adele.dart').absolute.path,
          'prepare-code-editor',
          '--archive',
          archive.path,
        ], workingDirectory: root.path);
        expect(
          result.exitCode,
          0,
          reason: '${result.stdout}\n${result.stderr}',
        );
        expect(
          File('${source.path}/cargokit/build_pod.sh').statSync().mode & 0x49,
          0x49,
        );
        await prepare();
      },
    );
  }

  for (final mutation in ['none', 'source', 'inputs', 'missing-source']) {
    test(
      'native build holds source before native lease and rechecks $mutation',
      () async {
        await prepare();
        final fixture = await _createNativeBuildFixture(root);
        final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
        final process = await Process.start(
          Platform.resolvedExecutable,
          [fixture.driver.path],
          workingDirectory: root.path,
          environment: {
            ...fixture.environment,
            'ADELE_TEST_CARGO_GATE': '${server.port}',
          },
        );
        final output = process.stdout.transform(utf8.decoder).join();
        final errors = process.stderr.transform(utf8.decoder).join();
        Socket? gate;
        try {
          gate = await server.first.timeout(const Duration(seconds: 10));
          await expectLater(prepare(reprepare: true), _throwsBusy);
          await expectLater(
            withCodeEditorSource(
              root,
              (_) async => fail('source lease escaped'),
            ),
            _throwsBusy,
          );
          final competing = await Process.run(
            Platform.resolvedExecutable,
            [fixture.driver.path],
            workingDirectory: root.path,
            environment: fixture.environment,
          );
          expect(competing.exitCode, 1);
          expect(competing.stderr, contains('source preparation is busy'));
          switch (mutation) {
            case 'source':
              File('${source.path}/lib/code.dart').writeAsStringSync('altered');
            case 'inputs':
              final helper = File(
                '${root.path}/tools/code_editor_dependency.dart',
              );
              helper.writeAsStringSync(
                '${helper.readAsStringSync()}\n// changed input\n',
              );
            case 'missing-source':
              source.deleteSync(recursive: true);
          }
          await gate.close();
          final code = await process.exitCode;
          final stdoutText = await output;
          final stderrText = await errors;
          expect(
            code,
            mutation == 'none' ? 0 : 1,
            reason: '$stdoutText\n$stderrText',
          );
          if (mutation == 'none') {
            expect(
              stdoutText.trim(),
              endsWith('/x86_64-unknown-linux-gnu/release'),
            );
          } else {
            expect(stderrText, contains('CodeForge checkout'));
            expect(stdoutText, isNot(contains('Prepared CodeForge')));
          }
          if (mutation == 'missing-source') {
            expect(source.existsSync(), isFalse);
          }
        } finally {
          gate?.destroy();
          await server.close();
          process.kill();
          await process.exitCode;
        }
        // Success and verification failures must release both leases.
        await prepare(reprepare: true);
        final retried = await Process.run(
          Platform.resolvedExecutable,
          [fixture.driver.path],
          workingDirectory: root.path,
          environment: fixture.environment,
        );
        expect(retried.exitCode, 0, reason: '${retried.stderr}');
      },
    );
  }

  for (final omitLibrary in [false, true]) {
    test(
      'native target is explicit and old host output cannot substitute (omit=$omitLibrary)',
      () async {
        await prepare();
        final state =
            jsonDecode(
                  File(
                    '${source.path}/.adele-preparation.json',
                  ).readAsStringSync(),
                )
                as Map;
        final target =
            '${source.parent.path}/code_forge-native/${state['identity']}';
        final stale = File('$target/release/libcode_forge.so');
        stale.parent.createSync(recursive: true);
        stale.writeAsStringSync('stale host-layout artifact');
        final fixture = await _createNativeBuildFixture(root);
        final result = await Process.run(
          Platform.resolvedExecutable,
          [fixture.driver.path],
          workingDirectory: root.path,
          environment: {
            ...fixture.environment,
            'CARGO_BUILD_TARGET': 'aarch64-unknown-linux-gnu',
            if (omitLibrary) 'ADELE_TEST_OMIT_NATIVE_LIBRARY': '1',
          },
        );
        expect(
          jsonDecode(
            File('${root.path}/native-arguments.json').readAsStringSync(),
          ),
          [
            'run',
            '1.93.0',
            'cargo',
            'build',
            '--locked',
            '--release',
            '--manifest-path',
            '${source.path}/rust/Cargo.toml',
            '--target-dir',
            target,
            '--target',
            'x86_64-unknown-linux-gnu',
          ],
        );
        expect(
          result.exitCode,
          omitLibrary ? 1 : 0,
          reason: '${result.stderr}',
        );
        if (omitLibrary) {
          expect(result.stderr, contains('native build produced no library'));
        } else {
          expect(
            result.stdout.toString().trim(),
            '$target/x86_64-unknown-linux-gnu/release',
          );
          expect(
            File(
              '$target/x86_64-unknown-linux-gnu/release/libcode_forge.so',
            ).readAsStringSync(),
            'fresh native fixture',
          );
        }
        expect(stale.readAsStringSync(), 'stale host-layout artifact');
      },
    );
  }

  test(
    'clean preparation applies ordered patches and publishes complete source',
    () async {
      expect((await prepare()).path, source.path);
      expect(
        File('${source.path}/lib/code.dart').readAsStringSync(),
        'three\n',
      );
      expect(
        File(
          '${source.path}/cargokit/build_tool/runner.lock',
        ).readAsStringSync(),
        contains(jsonEncode('${source.path}/cargokit/build_tool')),
      );
      final state =
          jsonDecode(
                File(
                  '${source.path}/.adele-preparation.json',
                ).readAsStringSync(),
              )
              as Map;
      expect(
        (state['files'] as Map).keys,
        containsAll([
          'pubspec.yaml',
          'lib/code.dart',
          'rust/Cargo.toml',
          'rust/Cargo.lock',
          'cargokit/build_tool/pubspec.lock',
          'cargokit/build_tool/runner.lock',
          'build/archived-source.txt',
        ]),
      );
      expect(
        root
            .listSync(recursive: true)
            .whereType<Directory>()
            .where((entry) => entry.path.contains('.code_forge-stage-')),
        isEmpty,
      );
    },
  );

  test(
    'cache hit checks content without republishing or needing the archive',
    () async {
      await prepare();
      final state = File('${source.path}/.adele-preparation.json');
      state.setLastModifiedSync(DateTime.utc(2000));
      final modified = state.lastModifiedSync();
      archive.deleteSync();
      expect((await prepare()).path, source.path);
      expect(state.lastModifiedSync(), modified);
    },
  );

  test(
    'patches apply inside an ignored checkout in a parent git repository',
    () async {
      final git = await Process.run('git', ['init', '--quiet', root.path]);
      expect(git.exitCode, 0, reason: '${git.stderr}');
      File('${root.path}/.gitignore').writeAsStringSync('.adele/\n');
      await prepare();
      expect(
        File('${source.path}/lib/code.dart').readAsStringSync(),
        'three\n',
      );
    },
  );

  for (final path in [
    'lib/code.dart',
    'rust/Cargo.lock',
    'cargokit/build_tool/pubspec.lock',
    'build/archived-source.txt',
  ]) {
    test(
      'cache rejects changed immutable $path, without replacing consumers',
      () async {
        await prepare();
        final file = File('${source.path}/$path')..writeAsStringSync('altered');
        await expectLater(
          prepare(),
          throwsA(
            isA<StateError>().having(
              (e) => e.message,
              'message',
              contains('Stale or altered'),
            ),
          ),
        );
        expect(file.readAsStringSync(), 'altered');
      },
    );
  }

  test('missing and unexpected immutable files are rejected', () async {
    await prepare();
    File('${source.path}/lib/code.dart').deleteSync();
    await expectLater(prepare(), throwsStateError);
    File('${source.path}/lib/code.dart').writeAsStringSync('three\n');
    File('${source.path}/lib/injected.dart').writeAsStringSync('unexpected');
    await expectLater(prepare(), throwsStateError);
  });

  test(
    'modified source plus forged local ledger still fails the tracked tree digest',
    () async {
      await prepare();
      File('${source.path}/lib/code.dart').writeAsStringSync('forged\n');
      final ledger = File('${source.path}/.adele-preparation.json');
      final state = jsonDecode(ledger.readAsStringSync()) as Map;
      (state['files'] as Map)['lib/code.dart'] =
          '${await _sha256('forged\n')}:0';
      ledger.writeAsStringSync(jsonEncode(state));
      await expectLater(
        prepare(),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            contains('prepared tree checksum mismatch'),
          ),
        ),
      );
      expect(
        File('${source.path}/lib/code.dart').readAsStringSync(),
        'forged\n',
      );
    },
  );

  test(
    'fresh source cannot publish against a wrong trusted tree digest',
    () async {
      final file = File('${root.path}/third_party/code_forge/preparation.json');
      final config = jsonDecode(file.readAsStringSync()) as Map;
      config['preparedTreeSha256'] = 'wrong';
      file.writeAsStringSync(jsonEncode(config));
      await expectLater(
        prepare(),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            contains('prepared tree checksum mismatch'),
          ),
        ),
      );
      expect(source.existsSync(), isFalse);
    },
  );

  test('only explicit generated paths can change after preparation', () async {
    await prepare();
    for (final path in [
      '.dart_tool/config.json',
      'rust/target/release/output',
      'build/new-output',
      'pubspec.lock',
      'cargokit/build_tool/.dart_tool/config.json',
    ]) {
      final file = File('${source.path}/$path');
      file.parent.createSync(recursive: true);
      file.writeAsStringSync('generated');
    }
    await prepare();
  });

  for (final path in ['01.patch', 'runner.lock.template', 'preparation.json']) {
    test(
      'changed $path identity is an explicit stale error, not fallback',
      () async {
        await prepare();
        final file = File('${root.path}/third_party/code_forge/$path');
        file.writeAsStringSync('${file.readAsStringSync()}\n');
        await expectLater(
          prepare(),
          throwsA(
            isA<StateError>().having(
              (e) => e.message,
              'message',
              contains('Preparation inputs changed'),
            ),
          ),
        );
        expect(
          File('${source.path}/lib/code.dart').readAsStringSync(),
          'three\n',
        );
      },
    );
  }

  test('patch order is part of identity', () async {
    await prepare();
    final file = File('${root.path}/third_party/code_forge/preparation.json');
    final config = jsonDecode(file.readAsStringSync()) as Map;
    config['patches'] = ['02.patch', '01.patch'];
    file.writeAsStringSync(jsonEncode(config));
    await expectLater(prepare(), throwsStateError);
  });

  test(
    'binding hash mismatch fails before publication without Cargo',
    () async {
      final file = File('${root.path}/third_party/code_forge/preparation.json');
      final config = jsonDecode(file.readAsStringSync()) as Map;
      config['generatedBindingHash'] = 1;
      file.writeAsStringSync(jsonEncode(config));
      await expectLater(
        prepare(),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            contains('FRB binding identity'),
          ),
        ),
      );
      expect(source.existsSync(), isFalse);
    },
  );

  test(
    'missing verification manifest cannot turn a directory into a cache hit',
    () async {
      await prepare();
      File('${source.path}/.adele-preparation.json').deleteSync();
      await expectLater(prepare(), throwsStateError);
      expect(
        File('${source.path}/lib/code.dart').readAsStringSync(),
        'three\n',
      );
    },
  );

  test('failed patch never publishes partial source or falls back', () async {
    File(
      '${root.path}/third_party/code_forge/02.patch',
    ).writeAsStringSync('not a patch');
    await expectLater(prepare(), throwsStateError);
    expect(source.existsSync(), isFalse);
    expect(source.parent.listSync().whereType<Directory>(), isEmpty);
  });

  test(
    'archive checksum failure precedes extraction and publication',
    () async {
      archive.writeAsStringSync('not the approved archive');
      await expectLater(
        prepare(),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('archive checksum mismatch'),
          ),
        ),
      );
      expect(source.existsSync(), isFalse);
    },
  );

  test(
    'interrupted staging is discarded without treating it as source',
    () async {
      final stage = Directory(
        '${source.parent.path}/.code_forge-stage-interrupted',
      )..createSync(recursive: true);
      File('${stage.path}/pubspec.yaml').writeAsStringSync('partial');
      await prepare();
      expect(stage.existsSync(), isFalse);
      expect(
        File('${source.path}/lib/code.dart').readAsStringSync(),
        'three\n',
      );
    },
  );

  test('source symlink cannot redirect a prepared checkout', () async {
    source.parent.createSync(recursive: true);
    Link(source.path).createSync('${root.path}/archive-input');
    await expectLater(prepare(), throwsStateError);
    expect(Link(source.path).existsSync(), isTrue);
  });

  test('explicit reprepare applies a changed ordered patch set', () async {
    await prepare();
    final ledger = File('${source.path}/.adele-preparation.json');
    final previousState = ledger.readAsStringSync();
    archive = await createCodeEditorDependencyFixture(
      root,
      additionalPatch: true,
    );
    await expectLater(prepare(), throwsStateError);
    expect(ledger.readAsStringSync(), previousState);
    await prepare(reprepare: true);
    expect(File('${source.path}/lib/code.dart').readAsStringSync(), 'four\n');
    expect(ledger.readAsStringSync(), isNot(previousState));
    await prepare();
    expect(
      source.parent.listSync().whereType<Directory>().map(
        (entry) => entry.path,
      ),
      [source.path],
    );
  });

  test('explicit reprepare accepts changed helper input identity', () async {
    await prepare();
    final ledger = File('${source.path}/.adele-preparation.json');
    final previousState = ledger.readAsStringSync();
    final helper = File('${root.path}/tools/code_editor_dependency.dart');
    helper.writeAsStringSync(
      '${helper.readAsStringSync()}\n// changed input\n',
    );
    await expectLater(prepare(), throwsStateError);
    await prepare(reprepare: true);
    expect(ledger.readAsStringSync(), isNot(previousState));
    await prepare();
  });

  for (final corruption in ['content', 'ledger', 'directory', 'file', 'link']) {
    test('only explicit reprepare replaces existing $corruption', () async {
      await prepare();
      switch (corruption) {
        case 'content':
          File('${source.path}/lib/code.dart').writeAsStringSync('altered');
        case 'ledger':
          File('${source.path}/.adele-preparation.json').deleteSync();
        case 'directory':
          source.deleteSync(recursive: true);
          source.createSync();
          File('${source.path}/arbitrary').writeAsStringSync('untracked');
        case 'file':
          source.deleteSync(recursive: true);
          File(source.path).writeAsStringSync('not a checkout');
        case 'link':
          source.deleteSync(recursive: true);
          Link(source.path).createSync('${root.path}/archive-input');
      }
      await expectLater(prepare(), throwsStateError);
      await prepare(reprepare: true);
      expect(
        File('${source.path}/lib/code.dart').readAsStringSync(),
        'three\n',
      );
      // Replacing a link must never patch or remove its target.
      expect(
        File('${root.path}/archive-input/lib/code.dart').readAsStringSync(),
        'one\n',
      );
      await prepare();
    });
  }

  for (final failure in ['archive', 'patch', 'tree', 'binding']) {
    test(
      'failed reprepare $failure preserves but never consumes old source',
      () async {
        await prepare();
        final ledger = File('${source.path}/.adele-preparation.json');
        final previousState = ledger.readAsStringSync();
        archive = await createCodeEditorDependencyFixture(
          root,
          additionalPatch: true,
        );
        final metadata = File(
          '${root.path}/third_party/code_forge/preparation.json',
        );
        final config = jsonDecode(metadata.readAsStringSync()) as Map;
        switch (failure) {
          case 'archive':
            archive.writeAsStringSync('untrusted archive');
          case 'patch':
            File(
              '${root.path}/third_party/code_forge/03.patch',
            ).writeAsStringSync('invalid patch');
          case 'tree':
            config['preparedTreeSha256'] = 'wrong';
            metadata.writeAsStringSync(jsonEncode(config));
          case 'binding':
            config['generatedBindingHash'] = 1;
            metadata.writeAsStringSync(jsonEncode(config));
        }
        await expectLater(prepare(reprepare: true), throwsStateError);
        expect(ledger.readAsStringSync(), previousState);
        expect(
          File('${source.path}/lib/code.dart').readAsStringSync(),
          'three\n',
        );
        var consumed = false;
        await expectLater(
          withCodeEditorSource(root, (_) async => consumed = true),
          throwsStateError,
        );
        expect(consumed, isFalse);
        expect(
          source.parent.listSync().whereType<Directory>().map(
            (entry) => entry.path,
          ),
          [source.path],
        );
      },
    );
  }

  test(
    'publication failure rolls back existing source without fallback',
    () async {
      await prepare();
      final ledger = File('${source.path}/.adele-preparation.json');
      final previousState = ledger.readAsStringSync();
      archive = await createCodeEditorDependencyFixture(
        root,
        additionalPatch: true,
      );
      var attempted = false;
      await expectLater(
        IOOverrides.runWithIOOverrides(
          () => prepare(reprepare: true),
          _PublicationOverride((directory, path) async {
            attempted = true;
            expect(source.existsSync(), isFalse);
            expect(
              File('${directory.path}/lib/code.dart').readAsStringSync(),
              'four\n',
            );
            expect(
              File('${directory.path}/.adele-preparation.json').existsSync(),
              isTrue,
            );
            throw const FileSystemException('injected publication failure');
          }),
        ),
        throwsA(isA<FileSystemException>()),
      );
      expect(attempted, isTrue);
      expect(ledger.readAsStringSync(), previousState);
      expect(
        File('${source.path}/lib/code.dart').readAsStringSync(),
        'three\n',
      );
      await expectLater(
        withCodeEditorSource(root, (_) async => fail('stale source consumed')),
        throwsStateError,
      );
      expect(
        source.parent.listSync().whereType<Directory>().map(
          (entry) => entry.path,
        ),
        [source.path],
      );
      await prepare(reprepare: true);
      await prepare();
    },
  );

  test('reprepare holds the lease through staging and publication', () async {
    await prepare();
    archive = await createCodeEditorDependencyFixture(
      root,
      additionalPatch: true,
    );
    final driver = File('${root.path}/consume.dart')
      ..writeAsStringSync('''
import 'dart:io';
import 'tools/code_editor_dependency.dart';
Future<void> main() async {
  try {
    await withCodeEditorSource(Directory.current, (_) async {
      throw StateError('must not consume source during replacement');
    });
  } catch (error) { stderr.writeln(error); exitCode = 1; }
}
''');
    Future<void> checkExcluded() async {
      await expectLater(prepare(reprepare: true), _throwsBusy);
      final consumer = await Process.run(Platform.resolvedExecutable, [
        driver.path,
      ], workingDirectory: root.path);
      expect(consumer.exitCode, 1);
      expect(consumer.stderr, contains('busy'));
    }

    final stagedContents = <String>[];
    await IOOverrides.runWithIOOverrides(
      () => prepare(reprepare: true),
      _PublicationOverride(
        (directory, path) async {
          expect(source.existsSync(), isFalse);
          expect(
            File('${directory.path}/lib/code.dart').readAsStringSync(),
            'four\n',
          );
          expect(
            File('${directory.path}/.adele-preparation.json').existsSync(),
            isTrue,
          );
          await checkExcluded();
          return directory.rename(path);
        },
        beforeManifest: (directory) async {
          stagedContents.add(
            File('${directory.path}/lib/code.dart').readAsStringSync(),
          );
          expect(
            File('${source.path}/lib/code.dart').readAsStringSync(),
            'three\n',
          );
          await checkExcluded();
        },
      ),
    );
    expect(stagedContents, ['one\n', 'four\n']);
    await withCodeEditorSource(root, (leased) async {
      expect(File('${leased.path}/lib/code.dart').readAsStringSync(), 'four\n');
    });
  });

  test(
    'inputs changing during staging preserve the old checkout and fail closed',
    () async {
      await prepare();
      final ledger = File('${source.path}/.adele-preparation.json');
      final previousState = ledger.readAsStringSync();
      await expectLater(
        IOOverrides.runWithIOOverrides(
          () => prepare(reprepare: true),
          _PublicationOverride(
            (_, _) async => throw StateError('must not reach publication'),
            beforeManifest: (_) async {
              final helper = File(
                '${root.path}/tools/code_editor_dependency.dart',
              );
              helper.writeAsStringSync(
                '${helper.readAsStringSync()}\n// changed while preparing\n',
              );
            },
          ),
        ),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            contains('inputs changed during preparation'),
          ),
        ),
      );
      expect(ledger.readAsStringSync(), previousState);
      await expectLater(prepare(), throwsStateError);
    },
  );

  test(
    'same-process consumer lease refuses preparation and reentrant aliases',
    () async {
      await withCodeEditorSource(root, (leased) async {
        expect(leased.path, source.path);
        await expectLater(prepare(reprepare: true), _throwsBusy);
        await expectLater(prepare(), _throwsBusy);
        await expectLater(
          withCodeEditorSource(Directory('${root.path}/.'), (_) async {}),
          _throwsBusy,
        );
        expect(
          File('${source.path}/lib/code.dart').readAsStringSync(),
          'three\n',
        );
      }, archive: archive);
      await prepare(reprepare: true);
    },
  );

  test('consumer failure releases the lease', () async {
    await expectLater(
      withCodeEditorSource(
        root,
        (_) async => throw StateError('consumer failed'),
        archive: archive,
      ),
      throwsStateError,
    );
    await prepare(reprepare: true);
  });

  test(
    'cross-process consumer lease prevents replacement until released',
    () async {
      await prepare();
      final driver = File('${root.path}/consume.dart')
        ..writeAsStringSync('''
import 'dart:io';
import 'tools/code_editor_dependency.dart';
Future<void> main() async {
  await withCodeEditorSource(Directory.current, (source) async {
    stdout.writeln('consuming');
    await stdin.drain<void>();
    stdout.writeln(File('\${source.path}/lib/code.dart').readAsStringSync().trim());
  });
}
''');
      final process = await Process.start(Platform.resolvedExecutable, [
        driver.path,
      ], workingDirectory: root.path);
      final lines = StreamIterator(
        process.stdout.transform(utf8.decoder).transform(const LineSplitter()),
      );
      final errors = process.stderr.transform(utf8.decoder).join();
      try {
        expect(await lines.moveNext(), isTrue);
        expect(lines.current, 'consuming');
        archive = await createCodeEditorDependencyFixture(
          root,
          additionalPatch: true,
        );
        await expectLater(prepare(reprepare: true), _throwsBusy);
        expect(
          File('${source.path}/lib/code.dart').readAsStringSync(),
          'three\n',
        );
        await process.stdin.close();
        expect(await lines.moveNext(), isTrue);
        expect(lines.current, 'three');
        expect(await process.exitCode, 0, reason: await errors);
      } finally {
        process.kill();
        await process.exitCode;
        await lines.cancel();
      }
      await prepare(reprepare: true);
      expect(File('${source.path}/lib/code.dart').readAsStringSync(), 'four\n');
      await prepare();
    },
  );

  for (final archiveFirst in [false, true]) {
    test('CLI reprepare accepts archiveFirst=$archiveFirst', () async {
      await prepare();
      archive = await createCodeEditorDependencyFixture(
        root,
        additionalPatch: true,
      );
      final result = await Process.run(Platform.resolvedExecutable, [
        File('tools/adele.dart').absolute.path,
        'prepare-code-editor',
        if (!archiveFirst) '--reprepare',
        '--archive',
        archive.path,
        if (archiveFirst) '--reprepare',
      ], workingDirectory: root.path);
      expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
      expect(File('${source.path}/lib/code.dart').readAsStringSync(), 'four\n');
      await prepare();
    });
  }

  test(
    'CLI refuses duplicate, unknown and incomplete preparation options',
    () async {
      for (final options in [
        ['--reprepare', '--reprepare'],
        ['--archive'],
        ['--archive', '--reprepare'],
        ['--archive', archive.path, '--archive', archive.path],
        ['--repair'],
      ]) {
        final result = await Process.run(Platform.resolvedExecutable, [
          File('tools/adele.dart').absolute.path,
          'prepare-code-editor',
          ...options,
        ], workingDirectory: root.path);
        expect(result.exitCode, isNot(0));
        expect(
          result.stderr,
          contains('takes only [--reprepare] [--archive FILE]'),
        );
        expect(source.parent.existsSync(), isFalse);
      }
    },
  );

  test(
    'a separate process lock prevents concurrent preparation; death releases it',
    () async {
      final driver = File('${root.path}/hold.dart')
        ..writeAsStringSync('''
import 'dart:io';
Future<void> main() async {
  final file = File('.adele/dependencies/code_forge-source.lock');
  file.parent.createSync(recursive: true);
  final handle = await file.open(mode: FileMode.append);
  await handle.lock(FileLock.exclusive);
  stdout.writeln('locked');
  await stdin.drain<void>();
  await handle.close();
}
''');
      final process = await Process.start(Platform.resolvedExecutable, [
        driver.path,
      ], workingDirectory: root.path);
      final ready = process.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .first;
      try {
        expect(await ready, 'locked');
        await expectLater(
          prepare(),
          throwsA(
            isA<StateError>().having(
              (e) => e.message,
              'message',
              contains('busy'),
            ),
          ),
        );
        expect(source.existsSync(), isFalse);
      } finally {
        process.kill(ProcessSignal.sigkill);
        await process.exitCode;
      }
      await prepare();
    },
  );

  test('concurrent initial preparations publish once or report busy', () async {
    final driver = File('${root.path}/prepare.dart')
      ..writeAsStringSync('''
import 'dart:io';
import 'tools/code_editor_dependency.dart';
Future<void> main() async {
  try { await prepareCodeEditorSource(Directory.current, archive: File('fixture.tar.gz')); }
  catch (error) { stderr.writeln(error); exitCode = 1; }
}
''');
    final results = await Future.wait(
      List.generate(
        3,
        (_) => Process.run(Platform.resolvedExecutable, [
          driver.path,
        ], workingDirectory: root.path),
      ),
    );
    expect(results.where((r) => r.exitCode == 0), isNotEmpty);
    for (final result in results.where((r) => r.exitCode != 0)) {
      expect(result.stderr, contains('busy'));
    }
    await prepare();
    expect(File('${source.path}/lib/code.dart').readAsStringSync(), 'three\n');
  });

  test(
    'production metadata pins archive, bridge, compiler and retained patches',
    () {
      final config =
          jsonDecode(
                File(
                  'third_party/code_forge/preparation.json',
                ).readAsStringSync(),
              )
              as Map;
      expect(config['version'], '10.14.0');
      expect(
        config['archiveSha256'],
        'bddb3fe2001e4dd1653b32fc2752b9d4f60c7cb78f2a02165ea45ee60a867b61',
      );
      expect(config['flutterRustBridge'], '2.13.0');
      expect(config['generatedBindingHash'], 434014572);
      expect(config['rust'], '1.93.0');
      expect(config['preparedTreeSha256'], matches(RegExp(r'^[a-f0-9]{64}$')));
      expect(config['patches'], [
        '01-compatibility-build.patch',
        '02-correctness.patch',
      ]);
      for (final (original, copy) in [
        ('compatibility.patch', '01-compatibility-build.patch'),
        ('cargokit_runner.lock.template', 'cargokit_runner.lock.template'),
      ]) {
        expect(
          File('third_party/code_forge/$copy').readAsBytesSync(),
          File('tools/code_editor_probe/fixtures/$original').readAsBytesSync(),
        );
      }
      for (final patch in config['patches'] as List) {
        expect(File('third_party/code_forge/$patch').existsSync(), isTrue);
      }
    },
  );
}

final _throwsBusy = throwsA(
  isA<StateError>().having(
    (error) => error.message,
    'message',
    contains('busy'),
  ),
);

Future<({File driver, Map<String, String> environment})>
_createNativeBuildFixture(Directory root) async {
  final driver = File('${root.path}/native-build.dart')
    ..writeAsStringSync('''
import 'dart:io';
import 'tools/code_editor_dependency.dart';
Future<void> main() async {
  try {
    stdout.writeln((await buildNativeCodeEditorForTests(Directory.current)).path);
  } catch (error) { stderr.writeln(error); exitCode = 1; }
}
''');
  final fake = File('${root.path}/fake-cargo.dart')
    ..writeAsStringSync(r'''
import 'dart:convert';
import 'dart:io';
Future<void> main(List<String> arguments) async {
  File('native-arguments.json').writeAsStringSync(jsonEncode(arguments));
  if (Platform.environment['RUST_MIN_STACK'] != '16777216') exit(97);
  if (Platform.environment['ADELE_TEST_CARGO_GATE'] case final port?) {
    final gate = await Socket.connect(InternetAddress.loopbackIPv4, int.parse(port));
    await gate.drain<void>();
    await gate.close();
  }
  if (Platform.environment['ADELE_TEST_OMIT_NATIVE_LIBRARY'] == '1') return;
  final target = arguments[arguments.indexOf('--target-dir') + 1];
  final targetIndex = arguments.indexOf('--target');
  final triple = targetIndex == -1
      ? Platform.environment['CARGO_BUILD_TARGET']
      : arguments[targetIndex + 1];
  final library = File('$target/${triple == null ? '' : '$triple/'}release/libcode_forge.so');
  library.parent.createSync(recursive: true);
  library.writeAsStringSync('fresh native fixture');
}
''');
  final bin = Directory('${root.path}/bin')..createSync();
  final rustup = File('${bin.path}/rustup')
    ..writeAsStringSync(
      '#!/bin/sh\nexec "${Platform.resolvedExecutable}" "${fake.path}" "\$@"\n',
    );
  final mode = await Process.run('chmod', ['755', rustup.path]);
  if (mode.exitCode != 0) throw StateError('${mode.stderr}');
  return (
    driver: driver,
    environment: {'PATH': '${bin.path}:${Platform.environment['PATH']}'},
  );
}

// Fault injection at the actual filesystem publication boundary, not a second
// preparation implementation or production test hook. Other IO remains real.
final class _PublicationOverride extends IOOverrides {
  _PublicationOverride(this.publish, {this.beforeManifest});

  final Future<Directory> Function(Directory, String) publish;
  final Future<void> Function(Directory)? beforeManifest;

  @override
  Future<FileSystemEntityType> fseGetType(
    String path,
    bool followLinks,
  ) async =>
      // Dart 3.10's default async override omits the native path terminator.
      super.fseGetTypeSync(path, followLinks);

  @override
  Directory createDirectory(String path) {
    final directory = super.createDirectory(path);
    return path.contains('.code_forge-stage-') && path.endsWith('/source')
        ? _PublicationDirectory(directory, publish, beforeManifest)
        : directory;
  }
}

class _PublicationDirectory implements Directory {
  _PublicationDirectory(this.directory, this.publish, this.beforeManifest);

  final Directory directory;
  final Future<Directory> Function(Directory, String) publish;
  final Future<void> Function(Directory)? beforeManifest;

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
    await beforeManifest?.call(directory);
    yield* directory.list(recursive: recursive, followLinks: followLinks);
  }

  @override
  Future<Directory> rename(String newPath) => publish(directory, newPath);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
