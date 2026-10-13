import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:adele_configuration_store/adele_configuration_store.dart';
import 'package:adele_configuration_store/src/linux_directory.dart';
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

  group('record files', () {
    late ConfigurationStore settings;
    setUp(() {
      settings = store;
      store = settings.recordFile(collectionId: 'providers', recordId: 'work');
      file = File(store.filePath);
    });

    test(
      'derives only bounded lexical paths and retains the settings lock',
      () {
        expect(
          file.path,
          p.join(roots.configurationRoot, 'providers', 'work.toml'),
        );
        expect(store.lockPath, settings.lockPath);
        for (final invalid in [
          '',
          '.',
          '..',
          '../escape',
          '/absolute',
          r'a\b',
          'Work',
          'work.toml',
          'work_',
          'work ',
          'work.',
          'work\n',
          'work\x00',
          '1work',
          '-work',
          'work-',
          'two--words',
          'con',
          'prn',
          'aux',
          'nul',
          'com1',
          'lpt9',
          'a' * 65,
        ]) {
          expect(
            () => settings.recordFile(collectionId: invalid, recordId: 'work'),
            throwsArgumentError,
            reason: invalid,
          );
          expect(
            () => settings.recordFile(
              collectionId: 'providers',
              recordId: invalid,
            ),
            throwsArgumentError,
            reason: invalid,
          );
        }
        settings.recordFile(collectionId: 'a' * 64, recordId: 'two-words2');
        expect(root.listSync(), isEmpty);
      },
    );

    test('missing load, save and delete are checked artifact-free no-ops', () {
      final missing = store.load();
      expect(missing.exists, isFalse);
      expect(store.save(missing, missing.document), same(missing));
      expect(store.delete(missing), same(missing));
      expect(root.listSync(), isEmpty);
      seed('');
      expect(
        () => store.delete(missing),
        throwsA(isA<ConfigurationConflictException>()),
      );
      expect(Directory(roots.localStateRoot).existsSync(), isFalse);
    });

    test('independent files share the lock but not their byte baselines', () {
      final other = settings.recordFile(
        collectionId: 'providers',
        recordId: 'personal',
      );
      final work = store.load();
      final personal = other.load();
      final global = settings.load();
      final first = store.save(work, work.document.setScalar(['value'], 1));
      final lockInode = _inode(File(settings.lockPath));
      final second = other.save(
        personal,
        personal.document.setScalar(['value'], 2),
      );
      settings.save(global, global.document.setScalar(['value'], 3));
      store.save(first, first.document.setScalar(['value'], 4));
      expect(other.delete(second).exists, isFalse);
      expect(store.load().document.readScalar(['value']), 4);
      expect(settings.load().document.readScalar(['value']), 3);
      expect(_inode(File(settings.lockPath)), lockInode);
      expect(Directory(roots.localDataRoot).existsSync(), isFalse);
      expect(Directory(roots.cacheRoot).existsSync(), isFalse);
      expect(file.parent.listSync().map((entry) => p.basename(entry.path)), [
        'work.toml',
      ]);
      expect(() => other.save(first, first.document), throwsArgumentError);
      expect(() => other.delete(first), throwsArgumentError);
      expect(() => settings.delete(global), throwsStateError);
    });

    test(
      'create checks raw absence, even for malformed or empty existing files',
      () {
        final document = TomlDocument.parse('value = 1\n');
        for (final bytes in <List<int>>[
          [],
          utf8.encode('value =\n'),
          [0xff],
          utf8.encode('value = 0\n'),
        ]) {
          file.parent.createSync(recursive: true);
          file.writeAsBytesSync(bytes);
          expect(
            () => store.create(document),
            throwsA(isA<ConfigurationConflictException>()),
          );
          expect(file.readAsBytesSync(), bytes);
        }
        file.deleteSync();
        final empty = store.create(TomlDocument.parse(''));
        expect(empty.exists, isTrue);
        expect(file.lengthSync(), 0);
        expect(
          () => store.create(document),
          throwsA(isA<ConfigurationConflictException>()),
        );
        expect(store.delete(empty).exists, isFalse);
        final created = store.create(document);
        final missing = store.delete(created);
        expect(file.existsSync(), isFalse);
        store.save(missing, document);
        expect(store.load().document.source, document.source);
      },
    );

    test(
      'delete rejects stale bytes/existence without parsing or removing them',
      () {
        seed('value = 1\n');
        final loaded = store.load();
        for (final bytes in <List<int>>[
          utf8.encode('value = 2\n'),
          utf8.encode('value =\n'),
          [0xff],
          [],
        ]) {
          file.writeAsBytesSync(bytes);
          expect(
            () => store.delete(loaded),
            throwsA(isA<ConfigurationConflictException>()),
          );
          expect(file.readAsBytesSync(), bytes);
        }
        file.deleteSync();
        expect(
          () => store.delete(loaded),
          throwsA(isA<ConfigurationConflictException>()),
        );
        expect(file.existsSync(), isFalse);
      },
    );

    test(
      'record save uses existing permission and atomic cleanup behavior',
      () {
        var snapshot = store.create(TomlDocument.parse('value = 1\n'));
        expect(file.statSync().mode & 0x1ff, 0x180);
        for (final mode in ['640', '440']) {
          _chmod(file, mode);
          final value = snapshot.document.readScalar(['value']) as int;
          snapshot = store.save(
            snapshot,
            snapshot.document.setScalar(['value'], value + 1),
          );
          expect(file.statSync().mode & 0x1ff, int.parse(mode, radix: 8));
        }
        final inode = _inode(file);
        for (final boundary in ['write', 'open', 'rename']) {
          void fail(File staged) {
            if (boundary == 'write') staged.writeAsStringSync('partial');
            throw FileSystemException(
              'Injected record $boundary failure',
              staged.path,
            );
          }

          expect(
            () => IOOverrides.runWithIOOverrides(
              () => store.save(
                snapshot,
                snapshot.document.setScalar(['value'], 4),
              ),
              StagingOverrides(
                beforeWrite: boundary == 'write' ? fail : null,
                beforeOpen: boundary == 'open' ? fail : null,
                beforeRename: boundary == 'rename' ? fail : null,
              ),
            ),
            throwsA(isA<FileSystemException>()),
          );
          expect(file.readAsStringSync(), snapshot.document.source);
          expect(_inode(file), inode);
          expect(
            file.parent.listSync().map((entry) => p.basename(entry.path)),
            ['work.toml'],
          );
        }
        expect(
          () => IOOverrides.runWithIOOverrides(
            () => store.delete(snapshot),
            StagingOverrides(
              beforeDelete: (file) => throw FileSystemException(
                'Injected delete failure',
                file.path,
              ),
            ),
          ),
          throwsA(isA<FileSystemException>()),
        );
        expect(file.readAsStringSync(), snapshot.document.source);
        store.delete(snapshot);
        expect(file.parent.listSync(), isEmpty);
      },
    );

    test(
      'permissions fail explicitly for reads, enumeration and mutation',
      () async {
        seed('value = 1\n');
        final loaded = store.load();
        _chmod(file, '000');
        try {
          for (final action in <void Function()>[
            store.load,
            () => store.save(loaded, loaded.document),
            () => store.delete(loaded),
          ]) {
            expect(action, throwsA(isA<FileSystemException>()));
          }
        } finally {
          _chmod(file, '600');
        }
        _chmod(file.parent, '000');
        try {
          await expectLater(
            settings.listCollection('providers'),
            throwsA(isA<FileSystemException>()),
          );
          expect(store.load, throwsA(isA<FileSystemException>()));
        } finally {
          _chmod(file.parent, '700');
        }
        _chmod(file.parent, '500');
        try {
          expect(
            () => store.save(loaded, loaded.document.setScalar(['value'], 2)),
            throwsA(isA<FileSystemException>()),
          );
          expect(
            () => store.delete(loaded),
            throwsA(isA<FileSystemException>()),
          );
          expect(file.readAsStringSync(), loaded.document.source);
        } finally {
          _chmod(file.parent, '700');
        }
      },
    );

    test('record read validates native TOML and UTF-8 without repair', () {
      seed('value =\n');
      expect(store.load, throwsA(isA<TomlException>()));
      expect(file.readAsStringSync(), 'value =\n');
      file.writeAsBytesSync([0xff]);
      expect(store.load, throwsA(isA<FormatException>()));
      expect(file.readAsBytesSync(), [0xff]);
      expect(Directory(roots.localStateRoot).existsSync(), isFalse);
    });

    test('bounded record reads reject size before data and detect growth', () {
      seed('#${' ' * (ConfigurationStore.maxRecordBytes - 2)}\n');
      expect(
        store.load().document.source.length,
        ConfigurationStore.maxRecordBytes,
      );
      final handle = file.openSync(mode: FileMode.write);
      handle.truncateSync(ConfigurationStore.maxRecordBytes + 1);
      handle.closeSync();
      var reads = 0;
      for (final reportedLength in [null, 0]) {
        expect(
          () => IOOverrides.runWithIOOverrides(
            store.load,
            _ReadOverrides(file.path, reportedLength, (length) {
              expect(
                length,
                lessThanOrEqualTo(ConfigurationStore.maxRecordBytes + 1),
              );
              reads++;
            }),
          ),
          throwsA(
            isA<ConfigurationLimitException>().having(
              (e) => e.path,
              'path',
              file.path,
            ),
          ),
        );
        expect(reads, reportedLength == null ? 0 : 1);
      }
      expect(Directory(roots.localStateRoot).existsSync(), isFalse);
    });

    test('bounds cover every baseline check and UTF-8 before staging', () {
      final tooLarge = TomlDocument.parse(
        'value = "${'\u00e9' * (ConfigurationStore.maxRecordBytes ~/ 2)}"\n',
      );
      final absent = store.load();
      for (final action in <void Function()>[
        () => store.create(tooLarge),
        () => store.save(absent, tooLarge),
      ]) {
        expect(action, throwsA(isA<ConfigurationLimitException>()));
        expect(root.listSync(), isEmpty);
      }
      seed('value = 1\n');
      final loaded = store.load();
      final handle = file.openSync(mode: FileMode.write);
      handle.truncateSync(ConfigurationStore.maxRecordBytes + 1);
      handle.closeSync();
      for (final action in <void Function()>[
        () => store.save(loaded, loaded.document),
        () => store.save(loaded, loaded.document.setScalar(['value'], 2)),
        () => store.create(loaded.document),
        () => store.delete(loaded),
        () => store.delete(absent),
      ]) {
        expect(action, throwsA(isA<ConfigurationLimitException>()));
        expect(file.lengthSync(), ConfigurationStore.maxRecordBytes + 1);
      }
      file.writeAsStringSync(loaded.document.source);
      expect(
        () => IOOverrides.runWithIOOverrides(
          () => store.save(loaded, loaded.document.setScalar(['value'], 2)),
          StagingOverrides(
            beforeOpen: (_) => file.writeAsStringSync(
              '#${' ' * ConfigurationStore.maxRecordBytes}',
            ),
          ),
        ),
        throwsA(isA<ConfigurationLimitException>()),
      );
      expect(file.parent.listSync().map((entry) => p.basename(entry.path)), [
        'work.toml',
      ]);
      final settingsFile = File(settings.filePath)
        ..writeAsStringSync('#${' ' * ConfigurationStore.maxRecordBytes}');
      expect(settings.load().document.source.length, settingsFile.lengthSync());
    });

    test('only regular record files are read, changed or deleted', () async {
      final missing = store.load();
      Directory(file.path).createSync(recursive: true);
      for (final action in <void Function()>[
        store.load,
        () => store.save(missing, missing.document),
        () => store.create(TomlDocument.parse('value = 1\n')),
        () => store.delete(missing),
      ]) {
        expect(action, throwsA(isA<FileSystemException>()));
      }
      Directory(file.path).deleteSync();
      final result = Process.runSync('mkfifo', [file.path]);
      expect(result.exitCode, 0, reason: result.stderr.toString());
      expect(store.load, throwsA(isA<FileSystemException>()));
      final entries = await settings.listCollection('providers');
      expect(entries.single.type, FileSystemEntityType.pipe);
    });

    test(
      'record file symlinks are unsafe for every operation, even no-ops',
      () {
        final absent = store.load();
        seed('value = 1\n');
        final loaded = store.load();
        file.deleteSync();
        final target = File(p.join(root.path, 'target.toml'))
          ..writeAsStringSync('value = 1\n');
        for (final destination in [
          target.path,
          p.join(root.path, 'missing.toml'),
        ]) {
          final link = Link(file.path)..createSync(destination);
          for (final action in <void Function()>[
            store.load,
            () => store.save(loaded, loaded.document),
            () => store.save(loaded, loaded.document.setScalar(['value'], 2)),
            () => store.create(loaded.document),
            () => store.delete(loaded),
            () => store.delete(absent),
          ]) {
            expect(action, throwsA(isA<ConfigurationSymlinkException>()));
            expect(link.targetSync(), destination);
          }
          link.deleteSync();
        }
        expect(target.readAsStringSync(), 'value = 1\n');
        expect(Directory(roots.localStateRoot).existsSync(), isFalse);
      },
    );

    test(
      'collection symlinks fail but a configuration-root symlink works',
      () async {
        final missing = store.load();
        final target = Directory(p.join(root.path, 'external'))..createSync();
        Directory(roots.configurationRoot).createSync();
        final link = Link(file.parent.path)..createSync(target.path);
        for (final action in <void Function()>[
          store.load,
          () => store.create(TomlDocument.parse('value = 1\n')),
          () => store.save(missing, missing.document),
          () => store.delete(missing),
        ]) {
          expect(action, throwsA(isA<ConfigurationSymlinkException>()));
        }
        await expectLater(
          settings.listCollection('providers'),
          throwsA(isA<ConfigurationSymlinkException>()),
        );
        link.deleteSync();
        target.deleteSync();
        Link(file.parent.path).createSync(target.path);
        expect(store.load, throwsA(isA<ConfigurationSymlinkException>()));
        await expectLater(
          settings.listCollection('providers'),
          throwsA(isA<ConfigurationSymlinkException>()),
        );
        Link(file.parent.path).deleteSync();
        Directory(roots.configurationRoot).deleteSync();
        target.createSync();
        Link(roots.configurationRoot).createSync(target.path);
        final created = store.create(TomlDocument.parse('value = 1\n'));
        final updated = store.save(
          created,
          created.document.setScalar(['value'], 2),
        );
        expect(
          (await settings.listCollection('providers')).single.name,
          'work.toml',
        );
        expect(store.load().document.readScalar(['value']), 2);
        store.delete(updated);
        expect(Link(roots.configurationRoot).targetSync(), target.path);
      },
    );

    test(
      'collection and file links introduced during staging are rejected',
      () {
        seed('value = 1\n');
        final loaded = store.load();
        final target = File(p.join(root.path, 'target.toml'))
          ..writeAsStringSync(loaded.document.source);
        expect(
          () => IOOverrides.runWithIOOverrides(
            () => store.save(loaded, loaded.document.setScalar(['value'], 2)),
            StagingOverrides(
              beforeOpen: (_) {
                file.deleteSync();
                Link(file.path).createSync(target.path);
              },
            ),
          ),
          throwsA(isA<ConfigurationSymlinkException>()),
        );
        expect(target.readAsStringSync(), loaded.document.source);
        Link(file.path).deleteSync();
        seed(loaded.document.source);
        final moved = p.join(root.path, 'moved');
        expect(
          () => IOOverrides.runWithIOOverrides(
            () => store.save(loaded, loaded.document.setScalar(['value'], 2)),
            StagingOverrides(
              beforeOpen: (_) {
                file.parent.renameSync(moved);
                Link(file.parent.path).createSync(moved);
              },
            ),
          ),
          throwsA(isA<ConfigurationSymlinkException>()),
        );
        expect(
          File(p.join(moved, 'work.toml')).readAsStringSync(),
          loaded.document.source,
        );
        expect(
          Directory(moved).listSync().map((entry) => p.basename(entry.path)),
          ['work.toml'],
        );
      },
    );

    test(
      'enumeration is immediate, deterministic, unfiltered and artifact-free',
      () async {
        expect(await settings.listCollection('providers'), isEmpty);
        expect(root.listSync(), isEmpty);
        seed('not parsed');
        File(
          p.join(file.parent.path, 'Work.TOML'),
        ).writeAsStringSync('invalid');
        File(
          p.join(file.parent.path, 'notes.txt'),
        ).writeAsStringSync('retained');
        final nested = Directory(p.join(file.parent.path, 'nested'))
          ..createSync();
        File(
          p.join(nested.path, 'hidden.toml'),
        ).writeAsStringSync('not scanned');
        Link(p.join(file.parent.path, 'link.toml')).createSync(file.path);
        final entries = await settings.listCollection('providers');
        expect(entries.map((entry) => entry.name), [
          'Work.TOML',
          'link.toml',
          'nested',
          'notes.txt',
          'work.toml',
        ]);
        expect(entries.map((entry) => entry.type), [
          FileSystemEntityType.file,
          FileSystemEntityType.link,
          FileSystemEntityType.directory,
          FileSystemEntityType.file,
          FileSystemEntityType.file,
        ]);
        expect(() => entries.clear(), throwsUnsupportedError);
        expect(Directory(roots.localStateRoot).existsSync(), isFalse);
        await expectLater(
          settings.listCollection('../escape'),
          throwsArgumentError,
        );
      },
    );

    test(
      'collection aliases are explicit, including when canonical is missing',
      () async {
        Directory(roots.configurationRoot).createSync();
        for (final alias in [
          'Providers',
          'providers.',
          'providers ',
          'PROVIDERS. ',
        ]) {
          final directory = Directory(p.join(roots.configurationRoot, alias))
            ..createSync();
          for (final canonicalExists in [false, true]) {
            if (canonicalExists) file.parent.createSync();
            await expectLater(
              settings.listCollection('providers'),
              throwsA(
                isA<ConfigurationPathAliasException>().having(
                  (e) => e.aliasPath,
                  'aliasPath',
                  directory.path,
                ),
              ),
            );
            if (canonicalExists) file.parent.deleteSync();
          }
          directory.deleteSync();
        }
        expect(Directory(roots.localStateRoot).existsSync(), isFalse);
      },
    );

    test(
      'directory-wide listing errors never return a partial collection',
      () async {
        Directory(roots.configurationRoot).createSync();
        File(file.parent.path).writeAsStringSync('blocked');
        await expectLater(
          settings.listCollection('providers'),
          throwsA(isA<FileSystemException>()),
        );
        File(file.parent.path).deleteSync();
        Directory(roots.configurationRoot).deleteSync();
        File(roots.configurationRoot).writeAsStringSync('blocked root');
        await expectLater(
          settings.listCollection('providers'),
          throwsA(isA<FileSystemException>()),
        );
        expect(Directory(roots.localStateRoot).existsSync(), isFalse);
      },
    );

    test(
      'enumeration is bounded at both collection and configuration root',
      () async {
        file.parent.createSync(recursive: true);
        for (var i = 0; i < ConfigurationStore.maxCollectionEntries; i++) {
          File(p.join(file.parent.path, '$i.toml')).writeAsStringSync('');
        }
        expect(
          await settings.listCollection('providers'),
          hasLength(ConfigurationStore.maxCollectionEntries),
        );
        File(p.join(file.parent.path, 'extra')).writeAsStringSync('');
        await expectLater(
          settings.listCollection('providers'),
          throwsA(
            isA<ConfigurationLimitException>().having(
              (e) => e.path,
              'path',
              file.parent.path,
            ),
          ),
        );
        file.parent.deleteSync(recursive: true);
        for (var i = 0; i <= ConfigurationStore.maxCollectionEntries; i++) {
          File(p.join(roots.configurationRoot, '$i')).writeAsStringSync('');
        }
        await expectLater(
          settings.listCollection('providers'),
          throwsA(
            isA<ConfigurationLimitException>().having(
              (e) => e.path,
              'path',
              roots.configurationRoot,
            ),
          ),
        );
        expect(Directory(roots.localStateRoot).existsSync(), isFalse);
      },
    );

    test(
      'bounded Linux scans retain unusual user names and close on overflow',
      () async {
        file.parent.createSync(recursive: true);
        for (final name in ['.hidden', 'line\nbreak', 'caf\u00e9.toml']) {
          File(p.join(file.parent.path, name)).writeAsStringSync('keep');
        }
        File.fromRawPath(
          Uint8List.fromList([
            ...utf8.encode('${file.parent.path}/invalid-'),
            0xff,
          ]),
        ).writeAsStringSync('keep');
        final expected =
            file.parent
                .listSync(followLinks: false)
                .map((entry) => p.basename(entry.path))
                .toList()
              ..sort();
        expect(
          (await settings.listCollection(
            'providers',
          )).map((entry) => entry.name),
          expected,
        );
        final descriptors = Directory('/proc/self/fd').listSync().length;
        for (var index = 0; index < 100; index++) {
          expect(linuxDirectoryNames(file.parent.path, 1), hasLength(2));
        }
        expect(Directory('/proc/self/fd').listSync(), hasLength(descriptors));
        expect(
          () => linuxDirectoryNames('${file.parent.path}\u0000ignored', 1),
          throwsArgumentError,
        );
        expect(Directory(roots.localStateRoot).existsSync(), isFalse);
      },
    );

    test(
      'abandoned staging remains explicit user-visible debris, never adopted',
      () async {
        seed('value = 0\n');
        final kernel = await _prepareWriter(root);
        final writer = await _Writer.start(
          kernel,
          root.path,
          'pause',
          '1',
          'work',
        );
        await writer.expectLine('loaded');
        writer.process.stdin.writeln('save');
        await writer.expectLine('saving');
        await writer.expectLine('staged');
        writer.process.kill(ProcessSignal.sigkill);
        await writer.process.exitCode;
        final staging = file.parent.listSync().whereType<Directory>().single;
        final names = (await settings.listCollection(
          'providers',
        )).map((entry) => entry.name);
        expect(names, contains(p.basename(staging.path)));
        expect(names, hasLength(2));
        expect(file.readAsStringSync(), 'value = 0\n');
        expect(
          File(p.join(staging.path, 'work.toml')).readAsStringSync(),
          'value = 1\n',
        );
        expect(store.load().document.readScalar(['value']), 0);
      },
      timeout: const Timeout(Duration(minutes: 3)),
    );

    for (final modes in [
      ['pause', 'delete'],
      ['pause-delete', 'write'],
    ]) {
      test(
        'process ${modes.first} excludes stale record ${modes.last}',
        () async {
          seed('value = 0\n');
          final kernel = await _prepareWriter(root);
          final first = await _Writer.start(
            kernel,
            root.path,
            modes.first,
            '1',
            'work',
          );
          final second = await _Writer.start(
            kernel,
            root.path,
            modes.last,
            '2',
            'work',
          );
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
          expect(file.existsSync(), modes.first != 'pause-delete');
          if (file.existsSync()) expect(file.readAsStringSync(), 'value = 1\n');
        },
        timeout: const Timeout(Duration(minutes: 3)),
      );
    }

    for (final scope in ['collection', 'root']) {
      test(
        'two process creates cannot exceed the last $scope slot',
        () async {
          final directory = scope == 'collection'
              ? file.parent
              : Directory(roots.configurationRoot);
          directory.createSync(recursive: true);
          for (
            var index = 0;
            index < ConfigurationStore.maxCollectionEntries - 1;
            index++
          ) {
            File(
              p.join(directory.path, '.user-$index'),
            ).writeAsStringSync('keep');
          }
          final kernel = await _prepareWriter(root);
          final first = await _Writer.start(
            kernel,
            root.path,
            'pause-create',
            '1',
            'work',
          );
          final second = await _Writer.start(
            kernel,
            root.path,
            'create',
            '2',
            'personal',
            scope == 'root' ? 'agents' : 'providers',
          );
          await first.expectLine('loaded');
          await second.expectLine('loaded');
          first.process.stdin.writeln('save');
          await first.expectLine('saving');
          await first.expectLine('staged');
          final probe = await _Writer.start(kernel, root.path, 'probe');
          await probe.expectLine('locked');
          await probe.expectExit();
          second.process.stdin.writeln('save');
          await second.expectLine('saving');
          first.process.stdin.writeln('publish');
          await first.expectLine('committed');
          await second.expectLine('limit');
          await first.expectExit();
          await second.expectExit();
          expect(
            directory.listSync(),
            hasLength(ConfigurationStore.maxCollectionEntries),
          );
          expect(store.load().document.readScalar(['value']), 1);
          expect(
            File(p.join(file.parent.path, 'personal.toml')).existsSync(),
            isFalse,
          );
          expect(
            Directory(p.join(roots.configurationRoot, 'agents')).existsSync(),
            isFalse,
          );
          for (
            var index = 0;
            index < ConfigurationStore.maxCollectionEntries - 1;
            index++
          ) {
            expect(
              File(p.join(directory.path, '.user-$index')).readAsStringSync(),
              'keep',
            );
          }
        },
        timeout: const Timeout(Duration(minutes: 3)),
      );
    }

    test('absent-baseline save cannot bypass insertion capacity', () {
      file.parent.createSync(recursive: true);
      final baseline = store.load();
      for (
        var index = 0;
        index < ConfigurationStore.maxCollectionEntries;
        index++
      ) {
        File(p.join(file.parent.path, '$index')).writeAsStringSync('keep');
      }
      expect(
        () => store.save(baseline, baseline.document.setScalar(['value'], 1)),
        throwsA(isA<ConfigurationLimitException>()),
      );
      expect(file.existsSync(), isFalse);
      expect(
        file.parent.listSync(),
        hasLength(ConfigurationStore.maxCollectionEntries),
      );
    });

    for (final atCapacity in [false, true]) {
      for (final settingsWrite in [false, true]) {
        test(
          'listing excludes ${settingsWrite ? 'settings' : 'record'} staging at capacity=$atCapacity',
          () async {
            seed('value = 0\n');
            File(settings.filePath).writeAsStringSync('value = 0\n');
            final count = atCapacity
                ? ConfigurationStore.maxCollectionEntries
                : 1;
            for (var index = 1; index < count; index++) {
              File(
                p.join(file.parent.path, '.user-$index'),
              ).writeAsStringSync('keep');
            }
            if (atCapacity) {
              for (
                var index = 2;
                index < ConfigurationStore.maxCollectionEntries;
                index++
              ) {
                File(
                  p.join(roots.configurationRoot, '.root-$index'),
                ).writeAsStringSync('keep');
              }
            }
            final kernel = await _prepareWriter(root);
            final writer = await _Writer.start(
              kernel,
              root.path,
              'pause',
              '1',
              settingsWrite ? null : 'work',
            );
            await writer.expectLine('loaded');
            writer.process.stdin.writeln('save');
            await writer.expectLine('saving');
            await writer.expectLine('staged');
            final reader = await _Writer.start(kernel, root.path, 'list');
            await reader.expectLine('listing');
            // This handshake occurs at the real shared-lock call, not a timer.
            // Release before awaiting the scan which legitimately waits on it.
            await reader.expectLine('waiting');
            writer.process.stdin.writeln('publish');
            await writer.expectLine('committed');
            await reader.expectLine('listed:$count');
            await writer.expectExit();
            await reader.expectExit();
            expect(
              await settings.listCollection('providers'),
              hasLength(count),
            );
            expect(file.parent.listSync(), hasLength(count));
            expect(
              (settingsWrite ? settings : store).load().document.readScalar([
                'value',
              ]),
              1,
            );
          },
          timeout: const Timeout(Duration(minutes: 3)),
        );
      }
    }

    for (final mode in ['first-list', 'opening-list']) {
      test(
        'first writer appearing during $mode is rechecked under lock',
        () async {
          seed('value = 0\n');
          for (
            var index = 1;
            index < ConfigurationStore.maxCollectionEntries;
            index++
          ) {
            File(p.join(file.parent.path, '$index')).writeAsStringSync('keep');
          }
          final kernel = await _prepareWriter(root);
          final reader = await _Writer.start(kernel, root.path, mode);
          await reader.expectLine('listing');
          await reader.expectLine('unlocked');
          final writer = await _Writer.start(
            kernel,
            root.path,
            'pause',
            '1',
            'work',
          );
          await writer.expectLine('loaded');
          writer.process.stdin.writeln('save');
          await writer.expectLine('saving');
          await writer.expectLine('staged');
          reader.process.stdin.writeln('scan');
          await reader.expectLine('waiting');
          writer.process.stdin.writeln('publish');
          await writer.expectLine('committed');
          await reader.expectLine(
            'listed:${ConfigurationStore.maxCollectionEntries}',
          );
          await writer.expectExit();
          await reader.expectExit();
        },
        timeout: const Timeout(Duration(minutes: 3)),
      );
    }

    test(
      'failed staging at capacity cleans up without affecting later listings',
      () async {
        seed('value = 0\n');
        for (
          var index = 1;
          index < ConfigurationStore.maxCollectionEntries;
          index++
        ) {
          File(p.join(file.parent.path, '$index')).writeAsStringSync('keep');
        }
        final baseline = store.load();
        expect(
          () => IOOverrides.runWithIOOverrides(
            () =>
                store.save(baseline, baseline.document.setScalar(['value'], 1)),
            StagingOverrides(
              beforeRename: (_) =>
                  throw const FileSystemException('Injected rename failure'),
            ),
          ),
          throwsA(isA<FileSystemException>()),
        );
        expect(
          await settings.listCollection('providers'),
          hasLength(ConfigurationStore.maxCollectionEntries),
        );
        expect(
          file.parent.listSync(),
          hasLength(ConfigurationStore.maxCollectionEntries),
        );
        expect(file.readAsStringSync(), 'value = 0\n');
      },
    );

    test(
      'independently baselined records coordinate across processes without conflict',
      () async {
        seed('value = 0\n');
        final other = settings.recordFile(
          collectionId: 'providers',
          recordId: 'personal',
        );
        File(other.filePath).writeAsStringSync('value = 0\n');
        final kernel = await _prepareWriter(root);
        final first = await _Writer.start(
          kernel,
          root.path,
          'pause',
          '1',
          'work',
        );
        final second = await _Writer.start(
          kernel,
          root.path,
          'write',
          '2',
          'personal',
        );
        await first.expectLine('loaded');
        await second.expectLine('loaded');
        first.process.stdin.writeln('save');
        await first.expectLine('saving');
        await first.expectLine('staged');
        final probe = await _Writer.start(kernel, root.path, 'probe');
        await probe.expectLine('locked');
        await probe.expectExit();
        second.process.stdin.writeln('save');
        await second.expectLine('saving');
        first.process.stdin.writeln('publish');
        await first.expectLine('committed');
        await second.expectLine('committed');
        await first.expectExit();
        await second.expectExit();
        expect(store.load().document.readScalar(['value']), 1);
        expect(other.load().document.readScalar(['value']), 2);
        expect(file.parent.listSync(), hasLength(2));
      },
      timeout: const Timeout(Duration(minutes: 3)),
    );
  }, skip: !Platform.isLinux);
}

void _chmod(FileSystemEntity file, String mode) {
  final result = Process.runSync('chmod', [mode, file.path]);
  expect(result.exitCode, 0, reason: result.stderr.toString());
}

String _inode(File file) {
  final result = Process.runSync('stat', ['-c', '%d:%i', file.path]);
  expect(result.exitCode, 0, reason: result.stderr.toString());
  return result.stdout as String;
}

Future<String> _prepareWriter(Directory root) async {
  return prepareWriter(root);
}

typedef _Writer = ConfigurationWriter;

final class _ReadOverrides extends IOOverrides {
  _ReadOverrides(this.path, this.reportedLength, this.onRead);

  final String path;
  final int? reportedLength;
  final void Function(int) onRead;

  @override
  File createFile(String path) {
    final file = super.createFile(path);
    return path == this.path ? _ReadFile(file, this) : file;
  }
}

final class _ReadFile implements File {
  _ReadFile(this.file, this.overrides);

  final File file;
  final _ReadOverrides overrides;

  @override
  RandomAccessFile openSync({FileMode mode = FileMode.read}) =>
      _ReadHandle(file.openSync(mode: mode), overrides);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _ReadHandle implements RandomAccessFile {
  _ReadHandle(this.handle, this.overrides);

  final RandomAccessFile handle;
  final _ReadOverrides overrides;

  @override
  int lengthSync() => overrides.reportedLength ?? handle.lengthSync();

  @override
  Uint8List readSync(int bytes) {
    overrides.onRead(bytes);
    return handle.readSync(bytes);
  }

  @override
  void closeSync() => handle.closeSync();

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
