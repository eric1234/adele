import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:ui' show IsolateNameServer;

import 'package:adele_configuration_store/adele_configuration_store.dart';
import 'package:adele_desktop/core/global_settings_service.dart';
import 'package:adele_desktop/frontend/prepared_settings.dart';
import 'package:adele_platform_storage/adele_platform_storage.dart';
import 'package:adele_settings/adele_settings.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plugin_runtime/plugin_runtime.dart';

void main() {
  const workerName = 'dev.adele.global-settings-owner';
  final owner = SettingOwnerId('dev.example.settings');
  final enabled = SettingId('${owner.value}.enabled');
  final limit = SettingId('${owner.value}.limit');
  final text = SettingId('${owner.value}.text');
  final mode = SettingId('${owner.value}.mode');
  final catalog = SettingsCatalog([
    SettingDefinition(
      id: enabled,
      owner: owner,
      label: 'Enabled',
      category: 'General',
      section: 'Display',
      type: const BooleanSettingType(),
      defaultValue: false,
    ),
    SettingDefinition(
      id: limit,
      owner: owner,
      label: 'Limit',
      category: 'General',
      section: 'Display',
      type: IntegerSettingType(minimum: 1, maximum: 10),
      defaultValue: 4,
    ),
    SettingDefinition(
      id: text,
      owner: owner,
      label: 'Text',
      category: 'General',
      section: 'Display',
      type: const StringSettingType(),
      defaultValue: '',
    ),
    SettingDefinition(
      id: mode,
      owner: owner,
      label: 'Mode',
      category: 'General',
      section: 'Display',
      type: EnumSettingType([
        SettingEnumOption('brief'),
        SettingEnumOption('detailed'),
      ]),
      defaultValue: 'brief',
    ),
  ]);
  late Directory temporary;
  late PlatformStorageRoots roots;
  late GlobalSettingsService service;
  late File file;

  GlobalSettingsService createOwner({SettingsCatalog? settings}) {
    final result = GlobalSettingsService(
      catalog: settings ?? catalog,
      roots: roots,
    );
    addTearDown(result.close);
    return result;
  }

  setUp(() {
    temporary = Directory.systemTemp.createTempSync('adele-settings-service-');
    roots = PlatformStorageRoots(
      operatingSystem: Platform.operatingSystem,
      configurationRoot: '${temporary.path}/config',
      localStateRoot: '${temporary.path}/state',
      localDataRoot: '${temporary.path}/data',
      cacheRoot: '${temporary.path}/cache',
    );
    addTearDown(() => temporary.deleteSync(recursive: true));
    service = createOwner();
    file = File(service.filePath);
  });

  void seed(String source) {
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(source);
  }

  void expectValue(
    GlobalSettingsView view,
    SettingId id,
    Object value,
    SettingValueSource source,
  ) {
    expect(view.failures.containsKey(id), isFalse);
    final actual = view.values[id]!;
    expect(actual.value, value);
    expect(actual.source, source);
    expect(actual.hasGlobalOverride, source == SettingValueSource.global);
  }

  test(
    'load resolves immutable defaults off the UI isolate without artifacts',
    () async {
      // These overrides do not cross the isolate boundary. A store load on the
      // caller would fail rather than silently performing synchronous UI I/O.
      final view = await IOOverrides.runZoned(
        service.load,
        createFile: (_) => throw StateError('File access on the UI isolate.'),
      );
      expect(service.catalog, same(catalog));
      expect(view.catalog, same(catalog));
      expect(service.filePath, '${roots.configurationRoot}/settings.toml');
      expectValue(view, enabled, false, SettingValueSource.defaultValue);
      expectValue(view, limit, 4, SettingValueSource.defaultValue);
      expect(view.failures, isEmpty);
      expect(() => view.values.clear(), throwsUnsupportedError);
      expect(
        () => view.failures[enabled] = StateError('fake'),
        throwsUnsupportedError,
      );
      final reset = await service.reset(view, enabled);
      expectValue(reset, enabled, false, SettingValueSource.defaultValue);
      expect(temporary.listSync(), isEmpty);
    },
  );

  test(
    'an empty catalog still reports an unreadable configuration file',
    () async {
      final empty = createOwner(settings: SettingsCatalog([]));
      file.parent.createSync(recursive: true);
      file.writeAsBytesSync([0xff]);
      await expectLater(empty.load(), throwsFormatException);
      expect(file.readAsBytesSync(), [0xff]);
    },
  );

  test('child isolates cannot create independent writer owners', () async {
    expect(await _rejectChildOwner(catalog, roots), isTrue);
  });

  test(
    'owners share one worker and final close waits for its ownership release',
    () async {
      await service.load();
      final port = IsolateNameServer.lookupPortByName(workerName);
      expect(port, isNotNull);
      final other = createOwner();
      await other.load();
      expect(IsolateNameServer.lookupPortByName(workerName), port);
      await service.close();
      expect(IsolateNameServer.lookupPortByName(workerName), port);
      await other.close();
      expect(IsolateNameServer.lookupPortByName(workerName), isNull);
      final successor = createOwner();
      await successor.load();
      expect(IsolateNameServer.lookupPortByName(workerName), isNot(port));
      await successor.close();
      expect(IsolateNameServer.lookupPortByName(workerName), isNull);
    },
  );

  test(
    'an independent root owner rejects worker startup and settles load and close',
    () async {
      await service.close();
      final blocker = ReceivePort();
      addTearDown(blocker.close);
      expect(
        IsolateNameServer.registerPortWithName(blocker.sendPort, workerName),
        isTrue,
      );
      addTearDown(() => IsolateNameServer.removePortNameMapping(workerName));
      final rejected = createOwner();
      await expectLater(rejected.load(), throwsStateError);
      await expectLater(rejected.load(), throwsStateError);
      await rejected.close();
      expect(IsolateNameServer.lookupPortByName(workerName), blocker.sendPort);
      IsolateNameServer.removePortNameMapping(workerName);
      expectValue(
        await createOwner().load(),
        enabled,
        false,
        SettingValueSource.defaultValue,
      );
    },
  );

  test(
    'reload invalidates an older view even when bytes are unchanged',
    () async {
      final stale = await service.load();
      final fresh = await service.load();
      await expectLater(
        service.reset(stale, enabled),
        throwsA(isA<ConfigurationConflictException>()),
      );
      expectValue(
        await service.reset(fresh, enabled),
        enabled,
        false,
        SettingValueSource.defaultValue,
      );
      expect(temporary.listSync(), isEmpty);
    },
  );

  for (final invalid in <(String, List<int>)>[
    ('UTF-8', [0xff]),
    ('TOML', utf8.encode('value =\n')),
  ]) {
    test(
      'failed ${invalid.$1} load revokes the previous baseline without repair',
      () async {
        final stale = await service.load();
        file.parent.createSync(recursive: true);
        file.writeAsBytesSync(invalid.$2);
        await expectLater(
          service.load(),
          invalid.$1 == 'UTF-8'
              ? throwsFormatException
              : throwsA(
                  isA<Exception>().having(
                    (error) => error.toString(),
                    'native parse error',
                    startsWith('TomlException(parse):'),
                  ),
                ),
        );
        expect(file.readAsBytesSync(), invalid.$2);
        file.deleteSync();
        // Restoring the original absence must not revive a pre-failure token.
        await expectLater(
          service.reset(stale, enabled),
          throwsA(isA<ConfigurationConflictException>()),
        );
        expectValue(
          await service.load(),
          enabled,
          false,
          SettingValueSource.defaultValue,
        );
        expect(Directory(roots.localStateRoot).existsSync(), isFalse);
      },
    );
  }

  test('filesystem load errors do not become an empty/default view', () async {
    Directory(file.path).createSync(recursive: true);
    await expectLater(service.load(), throwsA(isA<FileSystemException>()));
    expect(Directory(file.path).existsSync(), isTrue);
    expect(Directory(roots.localStateRoot).existsSync(), isFalse);
  });

  test(
    'transport send failure settles and does not poison later work',
    () async {
      final view = await service.load();
      final unsendable = ReceivePort();
      addTearDown(unsendable.close);
      await expectLater(
        service.save(view, enabled, unsendable),
        throwsArgumentError,
      );
      expectValue(
        await service.reset(view, enabled),
        enabled,
        false,
        SettingValueSource.defaultValue,
      );
    },
  );

  group('native conditional writes', () {
    test(
      'all scalar types persist, reconstruct and reset with exact provenance',
      () async {
        var view = await service.load();
        final initial = view;
        for (final entry in <(SettingId, Object)>[
          (enabled, true),
          (limit, 9),
          (text, 'first line\nsecond line'),
          (mode, 'detailed'),
        ]) {
          view = await service.save(view, entry.$1, entry.$2);
          expectValue(view, entry.$1, entry.$2, SettingValueSource.global);
        }
        expectValue(initial, enabled, false, SettingValueSource.defaultValue);
        await service.close();
        final reopened = createOwner();
        view = await reopened.load();
        expectValue(view, enabled, true, SettingValueSource.global);
        expectValue(view, limit, 9, SettingValueSource.global);
        expectValue(
          view,
          text,
          'first line\nsecond line',
          SettingValueSource.global,
        );
        expectValue(view, mode, 'detailed', SettingValueSource.global);
        view = await reopened.save(view, enabled, false);
        expectValue(view, enabled, false, SettingValueSource.global);
        expect(file.readAsStringSync(), contains('"${enabled.value}" = false'));
        view = await reopened.reset(view, enabled);
        expectValue(view, enabled, false, SettingValueSource.defaultValue);
        expect(file.readAsStringSync(), isNot(contains(enabled.value)));
        expect(Directory(roots.localDataRoot).existsSync(), isFalse);
        expect(Directory(roots.cacheRoot).existsSync(), isFalse);
        expect(file.parent.listSync().map((entry) => entry.path), [file.path]);
      },
    );

    test(
      'comments, unknown structures and unchanged bytes are preserved',
      () async {
        final original =
            '# keep header\n'
            '"${enabled.value}" = false # keep inline\n'
            '"dev.absent.values" = [1, 2] # keep unknown\n'
            "[unrelated]\ntext = 'literal'\n";
        seed(original);
        final time = DateTime.utc(2001);
        file.setLastModifiedSync(time);
        var view = await service.load();
        view = await service.save(view, enabled, false);
        expect(file.readAsStringSync(), original);
        expect(file.lastModifiedSync().toUtc(), time);
        expect(Directory(roots.localStateRoot).existsSync(), isFalse);
        view = await service.save(view, enabled, true);
        expect(
          file.readAsStringSync(),
          original.replaceFirst('= false', '= true'),
        );
        await service.reset(view, enabled);
        expect(
          file.readAsStringSync(),
          contains('"dev.absent.values" = [1, 2] # keep unknown'),
        );
        expect(
          file.readAsStringSync(),
          contains("[unrelated]\ntext = 'literal'\n"),
        );
      },
    );

    test(
      'same-owner and cross-owner stale views never silently merge',
      () async {
        final other = createOwner();
        final first = await service.load();
        final second = await other.load();
        await expectLater(other.save(first, limit, 7), throwsArgumentError);
        final winner = service.save(first, enabled, true);
        final rejected = expectLater(
          other.save(second, limit, 7),
          throwsA(isA<ConfigurationConflictException>()),
        );
        final saved = await winner;
        await rejected;
        expectValue(saved, enabled, true, SettingValueSource.global);
        expectValue(saved, limit, 4, SettingValueSource.defaultValue);
        await expectLater(
          service.reset(first, enabled),
          throwsA(isA<ConfigurationConflictException>()),
        );
        expect(file.readAsStringSync(), '"${enabled.value}" = true\n');
        await service.close();
        var refreshed = await other.load();
        refreshed = await other.save(refreshed, limit, 7);
        expectValue(refreshed, enabled, true, SettingValueSource.global);
        expectValue(refreshed, limit, 7, SettingValueSource.global);
      },
    );

    test(
      'external changes conflict even for no-op saves, without edited publication',
      () async {
        seed('"${enabled.value}" = false\n');
        final before = await service.load();
        final external = '${file.readAsStringSync()}external = 1 # keep\n';
        file.writeAsStringSync(external);
        await expectLater(
          service.save(before, enabled, false),
          throwsA(isA<ConfigurationConflictException>()),
        );
        await expectLater(
          service.save(before, enabled, true),
          throwsA(isA<ConfigurationConflictException>()),
        );
        expectValue(before, enabled, false, SettingValueSource.global);
        expect(file.readAsStringSync(), external);
        final reloaded = await service.load();
        final saved = await service.save(reloaded, enabled, true);
        expectValue(saved, enabled, true, SettingValueSource.global);
        expect(file.readAsStringSync(), contains('external = 1 # keep'));
      },
    );

    test(
      'invalid edits and I/O save failures leave disk and published view unchanged',
      () async {
        final before = await service.load();
        await expectLater(
          service.save(before, limit, 20),
          throwsA(isA<InvalidSettingValue>()),
        );
        await expectLater(
          service.save(before, mode, 'unknown'),
          throwsA(isA<InvalidSettingValue>()),
        );
        File(roots.localStateRoot).writeAsStringSync('not a directory');
        await expectLater(
          service.save(before, enabled, true),
          throwsA(isA<FileSystemException>()),
        );
        expect(file.existsSync(), isFalse);
        expectValue(before, enabled, false, SettingValueSource.defaultValue);
        File(roots.localStateRoot).deleteSync();
        expectValue(
          await service.save(before, enabled, true),
          enabled,
          true,
          SettingValueSource.global,
        );
      },
    );

    test(
      'invalid supported scalars remain failures and can be explicitly reset',
      () async {
        seed('"${enabled.value}" = "wrong type"\n"${limit.value}" = 99\n');
        var view = await service.load();
        expect(view.values.containsKey(enabled), isFalse);
        expect(view.failures[enabled], isA<InvalidSettingOverride>());
        expect(view.failures[limit], isA<InvalidSettingOverride>());
        expectValue(view, mode, 'brief', SettingValueSource.defaultValue);
        await expectLater(
          service.save(view, enabled, true),
          throwsA(isA<InvalidSettingOverride>()),
        );
        view = await service.reset(view, enabled);
        expectValue(view, enabled, false, SettingValueSource.defaultValue);
        expect(view.failures[limit], isA<InvalidSettingOverride>());
        view = await service.save(view, limit, 8);
        expectValue(view, limit, 8, SettingValueSource.global);
        expect(view.failures, isEmpty);
      },
    );

    for (final source in [
      '[true]',
      '{ value = true }',
      '1979-05-27T07:32:00Z',
    ]) {
      test(
        'unsupported $source cannot be silently repaired or reset',
        () async {
          final original = '"${enabled.value}" = $source # keep\n';
          seed(original);
          final view = await service.load();
          expect(view.failures[enabled], isA<InvalidSettingOverride>());
          await expectLater(
            service.save(view, enabled, true),
            throwsA(isA<InvalidSettingOverride>()),
          );
          await expectLater(
            service.reset(view, enabled),
            throwsA(isA<InvalidSettingOverride>()),
          );
          expect(file.readAsStringSync(), original);
          expect(Directory(roots.localStateRoot).existsSync(), isFalse);
        },
      );
    }

    test(
      'close fences immediately, drains admitted edits and permits a fresh lease',
      () async {
        final view = await service.load();
        final saving = service.save(view, enabled, true);
        final loading = service.load();
        final closing = service.close();
        expect(service.close(), same(closing));
        final successor = createOwner();
        await expectLater(service.load(), throwsStateError);
        await expectLater(service.save(view, limit, 8), throwsStateError);
        await expectLater(service.reset(view, enabled), throwsStateError);
        expectValue(await saving, enabled, true, SettingValueSource.global);
        expectValue(await loading, enabled, true, SettingValueSource.global);
        await closing;
        expectValue(
          await successor.load(),
          enabled,
          true,
          SettingValueSource.global,
        );
        await successor.close();
        expectValue(
          await createOwner().load(),
          enabled,
          true,
          SettingValueSource.global,
        );
      },
    );

    test(
      'close drains a lock-blocked native save without blocking the caller',
      () async {
        final view = await service.load();
        final lock = File(
          '${roots.localStateRoot}/configuration/settings.lock',
        );
        lock.parent.createSync(recursive: true);
        final helper = File(
          'test/support/settings_lock.dart',
        ).copySync('${temporary.path}/settings_lock.dart');
        final process = await Process.start(
          '${Platform.environment['FLUTTER_ROOT']!}/bin/cache/dart-sdk/bin/dart',
          [helper.path, lock.path],
          workingDirectory: temporary.path,
        );
        addTearDown(() async {
          process.kill();
          await process.exitCode;
        });
        final stderr = process.stderr.transform(utf8.decoder).join();
        expect(
          await process.stdout
              .transform(utf8.decoder)
              .transform(const LineSplitter())
              .first,
          'locked',
        );
        final saving = service.save(view, enabled, true);
        var closed = false;
        final closing = service.close().then((_) => closed = true);
        await expectLater(service.load(), throwsStateError);
        // The main isolate keeps processing while the worker waits on the actual
        // process lock. Closing must not kill that admitted transaction.
        await Future<void>.delayed(Duration.zero);
        expect(closed, isFalse);
        expect(file.existsSync(), isFalse);
        expect(IsolateNameServer.lookupPortByName(workerName), isNotNull);
        process.stdin.writeln('release');
        await process.stdin.flush();
        expect(await process.exitCode, 0, reason: await stderr);
        expectValue(await saving, enabled, true, SettingValueSource.global);
        await closing;
        expect(closed, isTrue);
        expect(IsolateNameServer.lookupPortByName(workerName), isNull);
        expect(file.readAsStringSync(), '"${enabled.value}" = true\n');
      },
    );

    test('file symlinks remain explicit write failures', () async {
      final target = File('${temporary.path}/managed.toml')
        ..writeAsStringSync('"${enabled.value}" = false\n');
      file.parent.createSync(recursive: true);
      Link(file.path).createSync(target.path);
      final view = await service.load();
      await expectLater(
        service.save(view, enabled, true),
        throwsA(isA<ConfigurationSymlinkException>()),
      );
      expectValue(view, enabled, false, SettingValueSource.global);
      expect(Link(file.path).existsSync(), isTrue);
      expect(target.readAsStringSync(), '"${enabled.value}" = false\n');
    });
  }, skip: !Platform.isLinux);

  test(
    'prepared snapshots reuse exact declarations and captured service values without discovery',
    () async {
      final installation = Directory('${temporary.path}/installed/probe')
        ..createSync(recursive: true);
      File('${installation.path}/settings.schema.json').writeAsStringSync(
        jsonEncode({
          'schemaVersion': 1,
          'definitions': [
            {
              'id': enabled.value,
              'type': 'boolean',
              'default': false,
              'label': 'Enabled',
              'category': 'General',
              'section': 'Display',
            },
          ],
        }),
      );
      File(
        '${installation.path}/adele_plugin.installation.json',
      ).writeAsStringSync(
        jsonEncode({
          'manifestVersion': 1,
          'metadata': {
            'id': owner.value,
            'version': '1',
            'displayName': 'Probe',
          },
          'settingsSchema': 'settings.schema.json',
          'components': <String, Object?>{},
        }),
      );
      final prepared = await PreparedPluginCatalog.discover(
        installation.parent.path,
      );
      expect(prepared.issues, isEmpty);
      final original = prepared.installations.single;
      final settings = createOwner(settings: prepared.settings);
      final view = await settings.load();
      installation.deleteSync(recursive: true);
      final captured = PreparedSettingsSnapshot.fromView(prepared, view);
      expect(captured.read(original, enabled.value).value, false);
      final unrelated = await service.load();
      expect(
        () => PreparedSettingsSnapshot.fromView(prepared, unrelated),
        throwsArgumentError,
      );
      final failure = StateError('failed startup load');
      final failed = PreparedSettingsSnapshot.fromFailure(prepared, failure);
      expect(
        () => failed.validateInstallation(original),
        throwsA(same(failure)),
      );
      if (Platform.isLinux) {
        await settings.save(view, enabled, true);
        expect(captured.read(original, enabled.value).value, false);
        expect(
          PreparedSettingsSnapshot.fromView(
            prepared,
            await settings.load(),
          ).read(original, enabled.value).value,
          true,
        );
      }
    },
  );
}

Future<bool> _rejectChildOwner(
  SettingsCatalog catalog,
  PlatformStorageRoots roots,
) => Isolate.run(() {
  try {
    GlobalSettingsService(catalog: catalog, roots: roots);
    return false;
  } on StateError {
    return true;
  }
});
