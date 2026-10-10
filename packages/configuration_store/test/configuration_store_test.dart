import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:adele_configuration_store/adele_configuration_store.dart';
import 'package:adele_platform_storage/adele_platform_storage.dart';
import 'package:adele_toml_document/adele_toml_document.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'support.dart';

void main() {
  late Directory root;
  late PlatformStorageRoots roots;
  late ConfigurationStore store;
  late File file;

  setUp(() {
    root = Directory.systemTemp.createTempSync('adele-configuration-');
    roots = rootsAt(root.path);
    store = ConfigurationStore(roots);
    file = File(store.filePath);
  });
  tearDown(() => root.deleteSync(recursive: true));

  void seed(String source) {
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(source);
  }

  void expectOnlyConfiguration() => expect(
    file.parent.listSync().map((entity) => p.basename(entity.path)),
    ['settings.toml'],
  );

  group('loading', () {
    test('missing configuration is empty without any filesystem creation', () {
      final snapshot = store.load();
      expect(snapshot.exists, isFalse);
      expect(snapshot.document.source, '');
      expect(root.listSync(), isEmpty);
    });

    test('valid content retains comments and unknown TOML fields exactly', () {
      const source = '# header\r\nvalue = 1 # keep\r\nunknown = [1, 2]\r\n';
      seed(source);
      final snapshot = store.load();
      expect(snapshot.exists, isTrue);
      expect(snapshot.document.readScalar(['value']), 1);
      expect(snapshot.document.source, source);
      expectOnlyConfiguration();
      expect(Directory(roots.localStateRoot).existsSync(), isFalse);
    });

    test('malformed TOML exposes native diagnostics without repair', () {
      const source = 'value =\n';
      seed(source);
      expect(
        store.load,
        throwsA(
          isA<TomlException>()
              .having((error) => error.kind, 'kind', TomlFailureKind.parse)
              .having(
                (error) => error.message,
                'diagnostic',
                contains('line 1'),
              ),
        ),
      );
      expect(file.readAsStringSync(), source);
      expectOnlyConfiguration();
      expect(Directory(roots.localStateRoot).existsSync(), isFalse);
    });

    test('invalid UTF-8 fails explicitly without replacement characters', () {
      file.parent.createSync(recursive: true);
      file.writeAsBytesSync([0xff]);
      expect(store.load, throwsA(isA<FormatException>()));
      expect(file.readAsBytesSync(), [0xff]);
    });

    test(
      'a directory at the file location is an I/O error, not empty TOML',
      () {
        Directory(file.path).createSync(recursive: true);
        expect(store.load, throwsA(isA<FileSystemException>()));
        expect(Directory(roots.localStateRoot).existsSync(), isFalse);
      },
    );

    test('a non-directory parent is an I/O error, not an absent file', () {
      File(roots.configurationRoot).writeAsStringSync('not a directory');
      expect(store.load, throwsA(isA<FileSystemException>()));
      expect(Directory(roots.localStateRoot).existsSync(), isFalse);
    });

    test('permission denial remains an OS read error', () {
      seed('value = 1\n');
      _chmod(file, '000');
      try {
        // This assertion deliberately requires an unprivileged test runner.
        expect(
          store.load,
          throwsA(
            isA<FileSystemException>().having(
              (error) => error.osError?.errorCode,
              'EACCES',
              13,
            ),
          ),
        );
      } finally {
        _chmod(file, '600');
      }
    }, skip: !Platform.isLinux);
  });

  group('saving', () {
    test('creates, reloads and updates across independent store instances', () {
      final empty = store.load();
      final first = store.save(empty, empty.document.setScalar(['value'], 1));
      expect(first.exists, isTrue);
      expect(first.document.readScalar(['value']), 1);
      final other = ConfigurationStore(roots);
      final loaded = other.load();
      expect(loaded.document.source, first.document.source);
      final second = other.save(
        loaded,
        loaded.document.setScalar(['value'], 2),
      );
      expect(store.load().document.source, second.document.source);
      // The successful result is itself the next valid baseline.
      other.save(second, second.document.setScalar(['value'], 3));
      expect(store.load().document.readScalar(['value']), 3);
      expectOnlyConfiguration();
    });

    test('an empty absent no-op does not materialize any directories', () {
      final empty = store.load();
      expect(store.save(empty, empty.document), same(empty));
      expect(root.listSync(), isEmpty);
    });

    test('an unchanged save retains mtime, bytes and file identity', () {
      seed('# comment\r\nvalue = 0x10\r\n');
      final marker = DateTime.utc(2001);
      file.setLastModifiedSync(marker);
      final before = _inode(file);
      final original = store.load();
      final unchanged = original.document.setScalar(['value'], 16);
      expect(store.save(original, unchanged), same(original));
      expect(file.lastModifiedSync().toUtc(), marker);
      expect(_inode(file), before);
      expect(file.readAsStringSync(), original.document.source);
      expect(Directory(roots.localStateRoot).existsSync(), isFalse);
    });

    test('scalar edits retain unrelated comments, keys and value spelling', () {
      const source =
          '# header\nvalue = 1 # keep\nunknown = [1, 2]\n'
          "[other] # table\nname  = 'literal'\n";
      seed(source);
      final snapshot = store.load();
      store.save(snapshot, snapshot.document.setScalar(['value'], 2));
      expect(
        file.readAsStringSync(),
        source.replaceFirst('value = 1', 'value = 2'),
      );
      expectOnlyConfiguration();
    });

    test(
      'failed document edits leave the file and loaded document untouched',
      () {
        seed('value = 1\n');
        final snapshot = store.load();
        expect(
          () => snapshot.document.setScalar(['value'], 'wrong type'),
          throwsA(isA<TomlException>()),
        );
        expect(file.readAsStringSync(), 'value = 1\n');
        expect(snapshot.document.source, 'value = 1\n');
        expectOnlyConfiguration();
        expect(Directory(roots.localStateRoot).existsSync(), isFalse);
      },
    );

    test('first save is private and replacements preserve permission bits', () {
      final empty = store.load();
      store.save(empty, empty.document.setScalar(['value'], 1));
      expect(file.statSync().mode & 0x1ff, 0x180); // 0600
      for (final mode in ['600', '640', '440']) {
        _chmod(file, mode);
        final snapshot = store.load();
        final value = snapshot.document.readScalar(['value']) as int;
        final oldInode = _inode(file);
        store.save(snapshot, snapshot.document.setScalar(['value'], value + 1));
        expect(file.statSync().mode & 0x1ff, int.parse(mode, radix: 8));
        expect(_inode(file), isNot(oldInode));
        expectOnlyConfiguration();
      }
    });

    for (final boundary in ['write', 'open', 'rename']) {
      test('failed $boundary cleans staging without changing the original', () {
        seed('value = 1\n');
        final snapshot = store.load();
        final inode = _inode(file);
        void fail(File staged) {
          if (boundary == 'write') staged.writeAsStringSync('partial');
          throw FileSystemException('Injected $boundary failure', staged.path);
        }

        expect(
          () => IOOverrides.runWithIOOverrides(
            () =>
                store.save(snapshot, snapshot.document.setScalar(['value'], 2)),
            StagingOverrides(
              beforeWrite: boundary == 'write' ? fail : null,
              beforeOpen: boundary == 'open' ? fail : null,
              beforeRename: boundary == 'rename' ? fail : null,
            ),
          ),
          throwsA(isA<FileSystemException>()),
        );
        expect(file.readAsStringSync(), 'value = 1\n');
        expect(_inode(file), inode);
        expectOnlyConfiguration();
        // The lock is released on failure and the baseline is still valid.
        store.save(snapshot, snapshot.document.setScalar(['value'], 3));
        expectOnlyConfiguration();
      });
    }

    test('local state failures do not change the configuration', () {
      seed('value = 1\n');
      File(roots.localStateRoot).writeAsStringSync('blocked');
      final snapshot = store.load();
      expect(
        () => store.save(snapshot, snapshot.document.setScalar(['value'], 2)),
        throwsA(isA<FileSystemException>()),
      );
      expect(file.readAsStringSync(), 'value = 1\n');
      expectOnlyConfiguration();
    });

    test(
      'lock inode is stable and coordination stays outside configuration',
      () {
        final snapshot = store.load();
        final first = store.save(
          snapshot,
          snapshot.document.setScalar(['value'], 1),
        );
        final lock = File(store.lockPath);
        final inode = _inode(lock);
        store.save(first, first.document.setScalar(['value'], 2));
        expect(_inode(lock), inode);
        expect(p.isWithin(roots.localStateRoot, lock.path), isTrue);
        expect(lock.readAsBytesSync(), isEmpty);
        expectOnlyConfiguration();
        expect(Directory(roots.localDataRoot).existsSync(), isFalse);
        expect(Directory(roots.cacheRoot).existsSync(), isFalse);
        expect(
          Directory(roots.localStateRoot)
              .listSync(recursive: true)
              .whereType<File>()
              .map((file) => file.path),
          [store.lockPath],
        );
      },
    );
  }, skip: !Platform.isLinux);

  group('conflicts', () {
    test(
      'independent snapshots conflict and an explicit reload enables retry',
      () {
        seed('value = 1\nother = 1\n');
        final otherStore = ConfigurationStore(roots);
        final first = store.load();
        final stale = otherStore.load();
        expect(first.document.source, stale.document.source);
        store.save(first, first.document.setScalar(['value'], 2));
        expect(
          () => otherStore.save(stale, stale.document.setScalar(['other'], 2)),
          throwsA(isA<ConfigurationConflictException>()),
        );
        expect(file.readAsStringSync(), 'value = 2\nother = 1\n');
        final fresh = otherStore.load();
        otherStore.save(fresh, fresh.document.setScalar(['other'], 2));
        expect(file.readAsStringSync(), 'value = 2\nother = 2\n');
        expectOnlyConfiguration();
      },
    );

    test(
      'external content changes conflict even with identical mtime and size',
      () {
        seed('value = 1\n');
        final snapshot = store.load();
        final modified = file.lastModifiedSync();
        file.writeAsStringSync('value = 2\n');
        file.setLastModifiedSync(modified);
        expect(
          () => store.save(snapshot, snapshot.document.setScalar(['value'], 3)),
          throwsA(isA<ConfigurationConflictException>()),
        );
        expect(file.readAsStringSync(), 'value = 2\n');
      },
    );

    test('a stale no-op also conflicts', () {
      seed('value = 1\n');
      final snapshot = store.load();
      file.writeAsStringSync('value = 2\n');
      expect(
        () => store.save(snapshot, snapshot.document),
        throwsA(isA<ConfigurationConflictException>()),
      );
      expect(Directory(roots.localStateRoot).existsSync(), isFalse);
    });

    test('externally created empty file conflicts with a missing baseline', () {
      final snapshot = store.load();
      seed('');
      expect(
        () => store.save(snapshot, snapshot.document.setScalar(['value'], 1)),
        throwsA(isA<ConfigurationConflictException>()),
      );
      expect(file.readAsStringSync(), '');
    });

    test('external removal conflicts without recreating the file', () {
      seed('value = 1\n');
      final snapshot = store.load();
      file.deleteSync();
      expect(
        () => store.save(snapshot, snapshot.document.setScalar(['value'], 2)),
        throwsA(isA<ConfigurationConflictException>()),
      );
      expect(file.parent.listSync(), isEmpty);
    });

    test(
      'external malformed changes produce conflict, not overwrite or repair',
      () {
        seed('value = 1\n');
        final snapshot = store.load();
        file.writeAsStringSync('value =\n');
        expect(
          () => store.save(snapshot, snapshot.document.setScalar(['value'], 2)),
          throwsA(isA<ConfigurationConflictException>()),
        );
        expect(file.readAsStringSync(), 'value =\n');
      },
    );

    test(
      'external changes during staging are detected and staging is removed',
      () {
        seed('value = 1\n');
        final snapshot = store.load();
        expect(
          () => IOOverrides.runWithIOOverrides(
            () =>
                store.save(snapshot, snapshot.document.setScalar(['value'], 2)),
            StagingOverrides(
              beforeOpen: (_) => file.writeAsStringSync('value = 3\n'),
            ),
          ),
          throwsA(isA<ConfigurationConflictException>()),
        );
        expect(file.readAsStringSync(), 'value = 3\n');
        expectOnlyConfiguration();
      },
    );

    test('a baseline cannot accidentally be used for another file', () {
      final snapshot = store.load();
      final other = ConfigurationStore(rootsAt(p.join(root.path, 'other')));
      expect(
        () => other.save(snapshot, snapshot.document.setScalar(['value'], 1)),
        throwsArgumentError,
      );
      expect(root.listSync(), isEmpty);
    });

    test(
      'cooperating processes hold a stable lock through publication',
      () async {
        seed('value = 0\n');
        final kernel = await _prepareWriter(root);
        final first = await _Writer.start(kernel, root.path, 'pause', '1');
        final second = await _Writer.start(kernel, root.path, 'write', '2');
        await first.expectLine('loaded');
        await second.expectLine('loaded');
        first.process.stdin.writeln('save');
        await first.expectLine('saving');
        await first.expectLine('staged');
        expect(file.readAsStringSync(), 'value = 0\n');
        final probe = await _Writer.start(kernel, root.path, 'probe');
        await probe.expectLine('locked');
        await probe.expectExit();
        second.process.stdin.writeln('save');
        await second.expectLine('saving');
        first.process.stdin.writeln('publish');
        await first.expectLine('committed');
        await second.expectLine('conflict');
        await first.expectExit();
        await second.expectExit();
        expect(file.readAsStringSync(), 'value = 1\n');
        expectOnlyConfiguration();
      },
      timeout: const Timeout(Duration(minutes: 3)),
    );
  }, skip: !Platform.isLinux);

  group('symlinks', () {
    test('a symlinked configuration root supports reads and replacement', () {
      final target = Directory(p.join(root.path, 'dotfiles'))..createSync();
      Link(roots.configurationRoot).createSync(target.path);
      seed('value = 1\n');
      final snapshot = store.load();
      store.save(snapshot, snapshot.document.setScalar(['value'], 2));
      expect(Link(roots.configurationRoot).targetSync(), target.path);
      expect(
        File(p.join(target.path, 'settings.toml')).readAsStringSync(),
        'value = 2\n',
      );
      expectOnlyConfiguration();
    });

    test('a file symlink is readable but changed saves never replace it', () {
      final target = File(p.join(root.path, 'dotfile.toml'))
        ..writeAsStringSync('value = 1\n');
      file.parent.createSync();
      final link = Link(file.path)..createSync(target.path);
      final snapshot = store.load();
      expect(snapshot.document.readScalar(['value']), 1);
      expect(store.save(snapshot, snapshot.document), same(snapshot));
      expect(
        () => store.save(snapshot, snapshot.document.setScalar(['value'], 2)),
        throwsA(isA<ConfigurationSymlinkException>()),
      );
      expect(link.targetSync(), target.path);
      expect(target.readAsStringSync(), 'value = 1\n');
      expectOnlyConfiguration();
      expect(Directory(roots.localStateRoot).existsSync(), isFalse);
    });

    test(
      'a dangling file symlink fails to load rather than looking absent',
      () {
        file.parent.createSync();
        final target = p.join(root.path, 'absent.toml');
        final link = Link(file.path)..createSync(target);
        expect(store.load, throwsA(isA<FileSystemException>()));
        expect(link.targetSync(), target);
        expectOnlyConfiguration();
      },
    );

    test('a file symlink introduced during staging is not replaced', () {
      seed('value = 1\n');
      final snapshot = store.load();
      final target = File(p.join(root.path, 'dotfile.toml'))
        ..writeAsStringSync('value = 1\n');
      expect(
        () => IOOverrides.runWithIOOverrides(
          () => store.save(snapshot, snapshot.document.setScalar(['value'], 2)),
          StagingOverrides(
            beforeOpen: (_) {
              file.deleteSync();
              Link(file.path).createSync(target.path);
            },
          ),
        ),
        throwsA(isA<ConfigurationSymlinkException>()),
      );
      expect(Link(file.path).targetSync(), target.path);
      expect(target.readAsStringSync(), 'value = 1\n');
      expectOnlyConfiguration();
    });
  }, skip: !Platform.isLinux);
}

void _chmod(File file, String mode) {
  final result = Process.runSync('chmod', [mode, file.path]);
  expect(result.exitCode, 0, reason: result.stderr.toString());
}

String _inode(File file) {
  final result = Process.runSync('stat', ['-c', '%d:%i', file.path]);
  expect(result.exitCode, 0, reason: result.stderr.toString());
  return result.stdout as String;
}

Future<String> _prepareWriter(Directory root) async {
  // Reuse assets prepared by `dart test`. Nested `dart run` invocations on this
  // SDK recopy bundled libraries, unsafe while the parent has them mapped.
  final sdk = File(Platform.resolvedExecutable).parent.parent.path;
  final kernel = p.join(root.path, 'writer.dill');
  final result = await Process.run(p.join(sdk, 'bin', 'dartaotruntime'), [
    p.join(sdk, 'bin', 'snapshots', 'gen_kernel_aot.dart.snapshot'),
    '--platform=${p.join(sdk, 'lib', '_internal', 'vm_platform_strong.dill')}',
    '--packages=${(await Isolate.packageConfig)!.toFilePath()}',
    '--native-assets=${p.absolute('.dart_tool', 'native_assets.yaml')}',
    '--output=$kernel',
    'test/fixtures/writer.dart',
  ]);
  expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
  return kernel;
}

final class _Writer {
  _Writer(this.process)
    : lines = StreamIterator(
        process.stdout.transform(utf8.decoder).transform(const LineSplitter()),
      ),
      errors = process.stderr.transform(utf8.decoder).join();

  final Process process;
  final StreamIterator<String> lines;
  final Future<String> errors;

  static Future<_Writer> start(
    String kernel,
    String root,
    String mode, [
    String? value,
  ]) async {
    final writer = _Writer(
      await Process.start(Platform.resolvedExecutable, [
        '--disable-dart-dev',
        kernel,
        root,
        mode,
        ?value,
      ]),
    );
    addTearDown(() async {
      writer.process.kill(ProcessSignal.sigkill);
      await writer.process.exitCode;
      await writer.lines.cancel();
    });
    return writer;
  }

  Future<void> expectLine(String expected) async {
    expect(await lines.moveNext().timeout(const Duration(minutes: 1)), isTrue);
    expect(lines.current, expected);
  }

  Future<void> expectExit() async {
    await process.stdin.close();
    final code = await process.exitCode.timeout(const Duration(minutes: 1));
    expect(code, 0, reason: await errors);
    expect(await errors, isEmpty);
  }
}
