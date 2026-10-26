import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:ui' show IsolateNameServer;

import 'package:adele_configuration_store/adele_configuration_store.dart';
import 'package:adele_desktop/core/global_settings_service.dart';
import 'package:adele_desktop/frontend/prepared_settings.dart';
import 'package:adele_platform_storage/adele_platform_storage.dart';
import 'package:adele_plugin_api/adele_plugin_api.dart';
import 'package:adele_settings/adele_settings.dart';
import 'package:adele_settings_host/adele_settings_host.dart';
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

  GlobalSettingsService createOwner({
    SettingsCatalog? settings,
    RecordCatalog? records,
  }) {
    final result = GlobalSettingsService(
      catalog: settings ?? catalog,
      roots: roots,
      records: records,
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

  group('configuration records', () {
    final collection = RecordCollectionId('jobs');
    final type = RecordTypeId('${owner.value}.job');
    final first = ConfigurationRecordId('first');
    final second = ConfigurationRecordId('second');
    final records = RecordCatalog([
      RecordTypeDefinition(
        id: type,
        owner: PluginId(owner.value),
        collection: collection,
        collectionLabel: 'Jobs',
        label: 'Job',
        fields: [
          RecordFieldDefinition(
            id: RecordFieldId('name'),
            label: 'Name',
            type: const StringSettingType(),
            required: true,
          ),
          RecordFieldDefinition(
            id: RecordFieldId('enabled'),
            label: 'Enabled',
            type: const BooleanSettingType(),
            required: false,
          ),
          RecordFieldDefinition(
            id: RecordFieldId('count'),
            label: 'Count',
            type: IntegerSettingType(minimum: 0, maximum: 10),
            required: false,
          ),
          RecordFieldDefinition(
            id: RecordFieldId('mode'),
            label: 'Mode',
            type: EnumSettingType([
              SettingEnumOption('brief'),
              SettingEnumOption('detailed'),
            ]),
            required: false,
          ),
        ],
      ),
    ]);
    late GlobalSettingsService recordService;

    setUp(() => recordService = createOwner(records: records));

    File recordFile(ConfigurationRecordId id) =>
        File('${recordService.collectionPath(collection)}/${id.value}.toml');

    String recordSource(String values, {RecordTypeId? recordType}) =>
        'recordVersion = 1\nrecordType = "${recordType ?? type}"\n\n'
        '[values]\n$values';

    void seedRecord(ConfigurationRecordId id, String source) {
      recordFile(id).parent.createSync(recursive: true);
      recordFile(id).writeAsStringSync(source);
    }

    test(
      'empty declarations and absent collections create no artifacts',
      () async {
        expect(service.records.definitions, isEmpty);
        expect(recordService.records, same(records));
        expect(
          recordService.collectionPath(collection),
          '${roots.configurationRoot}/jobs',
        );
        await expectLater(service.loadRecords(collection), throwsArgumentError);
        // I/O overrides stay in this isolate. The real worker must do the scan.
        final view = await IOOverrides.runZoned(
          () => recordService.loadRecords(collection),
          createFile: (_) => throw StateError('File access on the UI isolate.'),
          createDirectory: (_) =>
              throw StateError('Directory access on the UI isolate.'),
        );
        expect(view.records, isEmpty);
        expect(view.diagnostics, isEmpty);
        expect(() => view.records.clear(), throwsUnsupportedError);
        expect(() => view.diagnostics.clear(), throwsUnsupportedError);
        expect(temporary.listSync(), isEmpty);
      },
    );

    test(
      'malformed siblings retain attributable diagnostics and bytes',
      () async {
        seedRecord(first, recordSource('name = "Healthy"\nunknown = [1, 2]\n'));
        final sources = <String, List<int>>{
          'Bad.toml': utf8.encode(recordSource('name = "Bad ID"\n')),
          'broken.toml': utf8.encode('invalid = ['),
          'invalid-utf8.toml': [0xff],
          'invalid-value.toml': utf8.encode(recordSource('name = true\n')),
          'missing-name.toml': utf8.encode(recordSource('enabled = false\n')),
          'notes.txt': utf8.encode('not a record'),
          'unknown.toml': utf8.encode(
            recordSource(
              'name = "Unavailable"\n',
              recordType: RecordTypeId('dev.absent.job'),
            ),
          ),
        };
        for (final entry in sources.entries) {
          File(
            '${recordFile(first).parent.path}/${entry.key}',
          ).writeAsBytesSync(entry.value);
        }
        final healthyBytes = recordFile(first).readAsBytesSync();
        final view = await recordService.loadRecords(collection);
        expect(view.records.single.id, first);
        expect(view.records.single.type, type);
        expect(view.records.single.values, {'name': 'Healthy'});
        expect(
          () => view.records.single.values.clear(),
          throwsUnsupportedError,
        );
        expect(view.diagnostics.map((item) => item.fileName), sources.keys);
        expect(view.diagnostics[0].recordId, isNull);
        expect(view.diagnostics[1].recordId, ConfigurationRecordId('broken'));
        expect(view.diagnostics[1].message, contains('TomlException(parse)'));
        expect(view.diagnostics[2].message, contains('FormatException'));
        expect(view.diagnostics[3].message, contains('InvalidRecordValue'));
        expect(
          view.diagnostics[4].message,
          contains('Required field is missing'),
        );
        expect(view.diagnostics[5].recordId, isNull);
        expect(view.diagnostics[6].message, contains('RecordTypeNotFound'));
        for (final entry in sources.entries) {
          expect(
            File(
              '${recordFile(first).parent.path}/${entry.key}',
            ).readAsBytesSync(),
            entry.value,
          );
        }
        expect(recordFile(first).readAsBytesSync(), healthyBytes);
        expect(Directory(roots.localStateRoot).existsSync(), isFalse);
      },
    );

    test(
      'host revalidates unknown types and invalid fields without writing',
      () async {
        await expectLater(
          recordService.createRecord(RecordTypeId('dev.absent.job'), first, {
            'name': 'Unknown',
          }),
          throwsA(isA<RecordTypeNotFound>()),
        );
        for (final values in <Map<String, Object?>>[
          {},
          {'name': null},
          {'name': true},
          {'name': 'Name', 'enabled': 'true'},
          {'name': 'Name', 'count': -1},
          {'name': 'Name', 'mode': 'unknown'},
        ]) {
          await expectLater(
            recordService.createRecord(type, first, values),
            throwsA(
              isA<InvalidRecordValue>()
                  .having((error) => error.collection, 'collection', collection)
                  .having((error) => error.recordId, 'record ID', first),
            ),
          );
        }
        await expectLater(
          recordService.createRecord(type, first, {
            'name': 'Name',
            'unknown': 1,
          }),
          throwsA(isA<ConfigurationRecordFormatException>()),
        );
        for (final invalid in ['../escape', 'Bad', 'con', 'trailing.']) {
          expect(
            () => recordService.createRecord(
              type,
              ConfigurationRecordId(invalid),
              {'name': 'Name'},
            ),
            throwsFormatException,
          );
        }
        expect((await recordService.loadRecords(collection)).records, isEmpty);
        expect(temporary.listSync(), isEmpty);
      },
    );

    test(
      'collection scan failures reject rather than replacing a valid view',
      () async {
        seedRecord(first, recordSource('name = "Retained"\n'));
        final before = await recordService.loadRecords(collection);
        recordFile(first).parent.deleteSync(recursive: true);
        final obstruction = File(recordService.collectionPath(collection))
          ..writeAsStringSync('not a directory');
        await expectLater(
          recordService.loadRecords(collection),
          throwsA(isA<FileSystemException>()),
        );
        expect(before.records.single.values, {'name': 'Retained'});
        expect(obstruction.readAsStringSync(), 'not a directory');
        obstruction.deleteSync();
        seedRecord(first, recordSource('name = "Reloaded"\n'));
        expect(
          (await recordService.loadRecords(collection)).records.single.values,
          {'name': 'Reloaded'},
        );
        expect(Directory(roots.localStateRoot).existsSync(), isFalse);
      },
    );

    test(
      'native creation snapshots input and persists all scalar types off UI',
      () async {
        seed(
          '# scalar and unknown content stay untouched\nunrelated = [1, 2]\n',
        );
        final scalarBytes = file.readAsBytesSync();
        final values = <String, Object?>{
          'name': '',
          'enabled': false,
          'count': 0,
          'mode': 'detailed',
        };
        final creating = IOOverrides.runZoned(
          () => recordService.createRecord(type, first, values),
          createFile: (_) => throw StateError('File access on the UI isolate.'),
          createDirectory: (_) =>
              throw StateError('Directory access on the UI isolate.'),
        );
        values['name'] = 'Changed after admission';
        final created = await creating;
        expect(created.id, first);
        expect(created.type, type);
        expect(created.values, {
          'name': '',
          'enabled': false,
          'count': 0,
          'mode': 'detailed',
        });
        expect(() => created.values['name'] = 'Edited', throwsUnsupportedError);
        final firstBytes = recordFile(first).readAsBytesSync();
        final other = await recordService.createRecord(type, second, {
          'name': 'Second\nline',
        });
        expect(other.values, {'name': 'Second\nline'});
        expect(recordFile(first).readAsBytesSync(), firstBytes);
        await recordService.close();
        await service.close();
        expect(IsolateNameServer.lookupPortByName(workerName), isNull);
        final reopened = createOwner(records: records);
        final loaded = await reopened.loadRecords(collection);
        expect(loaded.records.map((record) => record.id), [first, second]);
        expect(loaded.records.first.values, created.values);
        expect(loaded.records.last.values, other.values);
        expect(loaded.diagnostics, isEmpty);
        expect(file.readAsBytesSync(), scalarBytes);
        expect(recordFile(first).readAsBytesSync(), firstBytes);
        expect(Directory(roots.localDataRoot).existsSync(), isFalse);
        expect(Directory(roots.cacheRoot).existsSync(), isFalse);
        expect(recordFile(first).parent.listSync(), hasLength(2));
      },
      skip: !Platform.isLinux,
    );

    test(
      'duplicate IDs preserve valid, malformed and unknown-type occupants',
      () async {
        final unknown = ConfigurationRecordId('unknown');
        seedRecord(first, recordSource('name = "Original"\n'));
        seedRecord(second, 'malformed = [');
        seedRecord(
          unknown,
          recordSource(
            'name = "Unavailable"\n',
            recordType: RecordTypeId('dev.absent.job'),
          ),
        );
        for (final id in [first, second, unknown]) {
          final bytes = recordFile(id).readAsBytesSync();
          await expectLater(
            recordService.createRecord(type, id, {'name': 'Replacement'}),
            throwsA(
              isA<ConfigurationConflictException>().having(
                (error) => error.path,
                'path',
                recordFile(id).path,
              ),
            ),
          );
          expect(recordFile(id).readAsBytesSync(), bytes);
        }
        final view = await recordService.loadRecords(collection);
        expect(view.records.single.values, {'name': 'Original'});
        expect(view.diagnostics.map((item) => item.recordId), [
          second,
          unknown,
        ]);
        expect(file.existsSync(), isFalse);
      },
      skip: !Platform.isLinux,
    );

    test(
      'separate owners serialize record and scalar requests and preserve baselines',
      () async {
        final other = createOwner(records: records);
        final initial = await service.load();
        final stale = await other.load();
        final port = IsolateNameServer.lookupPortByName(workerName);
        final completions = <String>[];
        final creating = recordService
            .createRecord(type, first, {'name': 'First'})
            .then((value) {
              completions.add('create');
              return value;
            });
        final saving = service.save(initial, enabled, true).then((value) {
          completions.add('save');
          return value;
        });
        final listing = other.loadRecords(collection).then((value) {
          completions.add('list');
          return value;
        });
        expect((await creating).id, first);
        final saved = await saving;
        expectValue(saved, enabled, true, SettingValueSource.global);
        expect((await listing).records.single.id, first);
        expect(completions, ['create', 'save', 'list']);
        expect(IsolateNameServer.lookupPortByName(workerName), port);
        await expectLater(
          other.save(stale, limit, 8),
          throwsA(isA<ConfigurationConflictException>()),
        );
        await expectLater(service.loadRecords(collection), throwsArgumentError);
        expectValue(
          await service.reset(saved, enabled),
          enabled,
          false,
          SettingValueSource.defaultValue,
        );
        await recordService.close();
        final refreshed = await other.load();
        await other.loadRecords(collection);
        expect(
          (await other.createRecord(type, second, {'name': 'Second'})).id,
          second,
        );
        // Successful record reads/creates do not revoke a scalar edit baseline.
        expectValue(
          await other.save(refreshed, limit, 8),
          limit,
          8,
          SettingValueSource.global,
        );
        expect(IsolateNameServer.lookupPortByName(workerName), port);
      },
      skip: !Platform.isLinux,
    );

    test(
      'close fences and drains lock-blocked records plus another owner scalar save',
      () async {
        final initial = await service.load();
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
        final creating = recordService.createRecord(type, first, {
          'name': 'Drained',
        });
        final saving = service.save(initial, enabled, true);
        final listing = recordService.loadRecords(collection);
        final recordClosing = recordService.close();
        final scalarClosing = service.close();
        expect(recordService.close(), same(recordClosing));
        var closed = false;
        final closing = Future.wait([
          recordClosing,
          scalarClosing,
        ]).then((_) => closed = true);
        await expectLater(
          recordService.loadRecords(collection),
          throwsStateError,
        );
        await expectLater(
          recordService.createRecord(type, second, {'name': 'Late'}),
          throwsStateError,
        );
        await expectLater(recordService.load(), throwsStateError);
        await expectLater(service.save(initial, limit, 8), throwsStateError);
        // The existing process-lock fixture gates real native I/O, not a fake store.
        await Future<void>.delayed(Duration.zero);
        expect(closed, isFalse);
        expect(file.existsSync(), isFalse);
        expect(recordFile(first).existsSync(), isFalse);
        expect(IsolateNameServer.lookupPortByName(workerName), isNotNull);
        process.stdin.writeln('release');
        await process.stdin.flush();
        expect(await process.exitCode, 0, reason: await stderr);
        expect((await creating).values, {'name': 'Drained'});
        expectValue(await saving, enabled, true, SettingValueSource.global);
        expect((await listing).records.single.id, first);
        await closing;
        expect(closed, isTrue);
        expect(IsolateNameServer.lookupPortByName(workerName), isNull);
        expect(recordFile(second).existsSync(), isFalse);
        final successor = createOwner(records: records);
        expect(
          (await successor.loadRecords(collection)).records.single.id,
          first,
        );
        expectValue(
          await successor.load(),
          enabled,
          true,
          SettingValueSource.global,
        );
      },
      skip: !Platform.isLinux,
    );
  });

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
