import 'dart:async';
import 'dart:io';

import 'package:adele_desktop/core/global_settings_service.dart';
import 'package:adele_desktop/ui/settings/global_settings_dialog.dart';
import 'package:adele_platform_storage/adele_platform_storage.dart';
import 'package:adele_plugin_api/adele_plugin_api.dart';
import 'package:adele_settings/adele_settings.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

final _collection = RecordCollectionId('jobs');
final _job = RecordTypeId('dev.example.records.job');
final _note = RecordTypeId('dev.example.records.note');
const _preference = 'dev.example.records.message';

void main() {
  late Directory temporary;
  late PlatformStorageRoots roots;
  late _ControlledService service;

  setUp(() async {
    temporary = await Directory.systemTemp.createTemp('adele-record-dialog-');
    roots = PlatformStorageRoots(
      operatingSystem: Platform.operatingSystem,
      configurationRoot: '${temporary.path}/config',
      localStateRoot: '${temporary.path}/state',
      localDataRoot: '${temporary.path}/data',
      cacheRoot: '${temporary.path}/cache',
    );
    service = _ControlledService(
      roots: roots,
      catalog: SettingsCatalog([
        SettingDefinition(
          id: SettingId(_preference),
          owner: SettingOwnerId('dev.example.records'),
          label: 'Editor Greeting',
          category: 'Editor',
          section: 'Welcome',
          type: const StringSettingType(),
          defaultValue: 'Original preference',
        ),
      ]),
      records: _catalog(),
    );
  });

  tearDown(() async {
    await service.close();
    await temporary.delete(recursive: true);
  });

  File file(String id) => File('${roots.configurationRoot}/jobs/$id.toml');

  Future<void> mount(
    WidgetTester tester, {
    List<String> recordIssues = const [],
  }) async {
    await tester.binding.setSurfaceSize(const Size(1000, 1100));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showDialog<void>(
                context: context,
                builder: (_) => GlobalSettingsDialog(
                  service: () async => service,
                  recordDeclarationIssues: () => recordIssues,
                ),
              ),
              child: const Text('Open settings'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open settings'));
    await tester.pump();
    await _until(tester, () => _enabled(tester, _key('settings-reload')));
  }

  Future<void> unmount(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  }

  Future<void> openRecords(WidgetTester tester) async {
    await _section(tester, 'Jobs');
    await _loaded(tester);
  }

  Future<void> add(WidgetTester tester, String id) async {
    await _tap(tester, _key('records-add-jobs'));
    await _enter(tester, _key('record-id-jobs'), id);
  }

  Future<void> fillRequired(WidgetTester tester, {String caption = ''}) async {
    await _include(tester, 'caption');
    if (caption.isNotEmpty) await _enter(tester, _input('caption'), caption);
    await _include(tester, 'enabled');
    await _choose(tester, _input('enabled'), 'False');
    await _include(tester, 'count');
    await _enter(tester, _input('count'), '0');
    await _include(tester, 'mode');
    await _choose(tester, _input('mode'), 'Compact label');
  }

  Future<void> create(WidgetTester tester) async {
    await _tap(tester, _key('record-create-jobs'));
    await _loaded(tester);
  }

  testWidgets(
    'all scalar forms require explicit presence and persist exact values',
    (tester) {
      return tester.runAsync(() async {
        await mount(tester);
        await openRecords(tester);
        expect(
          find.textContaining('nonsecret configuration, not credentials'),
          findsOneWidget,
        );
        expect(find.textContaining('Restart ADELE'), findsNothing);
        expect(Directory(roots.configurationRoot).existsSync(), isFalse);
        await add(tester, 'required-only');
        for (final field in ['caption', 'enabled', 'count', 'mode']) {
          expect(
            tester.widget<CheckboxListTile>(_presence(field)).value,
            isFalse,
          );
        }
        expect(
          tester.widget<DropdownButton<bool>>(_input('enabled')).value,
          isNull,
        );
        expect(
          tester.widget<DropdownButton<String>>(_input('mode')).value,
          isNull,
        );
        expect(_enabled(tester, _key('record-create-jobs')), isFalse);
        await _include(tester, 'caption');
        // Required means presence, not a separate nonempty-string policy.
        expect(
          tester.widget<TextField>(_input('caption')).controller!.text,
          '',
        );
        await _include(tester, 'enabled');
        expect(
          tester.widget<DropdownButton<bool>>(_input('enabled')).value,
          isNull,
        );
        expect(_enabled(tester, _key('record-create-jobs')), isFalse);
        await _choose(tester, _input('enabled'), 'False');
        await _include(tester, 'count');
        for (final invalid in ['', '1.5', '-1', '3', '9223372036854775808']) {
          await _enter(tester, _input('count'), invalid);
          expect(
            tester.widget<TextField>(_input('count')).decoration!.errorText,
            isNotNull,
          );
          expect(_enabled(tester, _key('record-create-jobs')), isFalse);
        }
        await _enter(tester, _input('count'), '0');
        await _include(tester, 'mode');
        expect(
          tester.widget<DropdownButton<String>>(_input('mode')).value,
          isNull,
        );
        expect(_enabled(tester, _key('record-create-jobs')), isFalse);
        await _choose(tester, _input('mode'), 'Compact label');
        expect(_enabled(tester, _key('record-create-jobs')), isTrue);
        for (final invalid in [
          '../outside',
          'Mixed-Case',
          'con',
          'bad_id',
          '',
        ]) {
          await _enter(tester, _key('record-id-jobs'), invalid);
          expect(_enabled(tester, _key('record-create-jobs')), isFalse);
        }
        await _enter(tester, _key('record-id-jobs'), 'required-only');
        await create(tester);
        final saved = (await service.loadRecords(_collection)).records.single;
        expect(saved.values, {
          'caption': '',
          'enabled': false,
          'count': 0,
          'mode': 'compact',
        });
        expect(find.text('required-only'), findsOneWidget);
        expect(
          file('required-only').readAsStringSync(),
          isNot(contains('Compact label')),
        );
        expect(
          file('required-only').readAsStringSync(),
          isNot(contains('optional')),
        );
        expect(File(service.filePath).existsSync(), isFalse);

        await add(tester, 'explicit-optionals');
        await fillRequired(tester, caption: 'Two lines\nSecond line');
        for (final field in [
          'optional-text',
          'optional-bool',
          'optional-int',
          'optional-enum',
        ]) {
          await _include(tester, field);
        }
        expect(
          tester.widget<DropdownButton<bool>>(_input('optional-bool')).value,
          isNull,
        );
        expect(
          tester.widget<DropdownButton<String>>(_input('optional-enum')).value,
          isNull,
        );
        await _choose(tester, _input('optional-bool'), 'False');
        await _enter(tester, _input('optional-int'), '0');
        await _choose(tester, _input('optional-enum'), 'Expanded label');
        await create(tester);
        final explicit = (await service.loadRecords(
          _collection,
        )).records.firstWhere((r) => r.id.value == 'explicit-optionals');
        expect(explicit.values, {
          'caption': 'Two lines\nSecond line',
          'enabled': false,
          'count': 0,
          'mode': 'compact',
          'optional-text': '',
          'optional-bool': false,
          'optional-int': 0,
          'optional-enum': 'expanded',
        });
        await unmount(tester);
      });
    },
    skip: !Platform.isLinux,
  );

  testWidgets('navigation retains scalar controls and per-type record drafts', (
    tester,
  ) {
    return tester.runAsync(() async {
      await mount(tester);
      expect(find.text('Preferences'), findsOneWidget);
      final preference = _key('setting-input-$_preference');
      await _enter(tester, preference, 'Retained preference');
      final scalarElement = tester.element(preference);
      final scalarController = tester.widget<TextField>(preference).controller;
      await _enter(tester, _key('settings-search'), 'Greeting');
      await openRecords(tester);
      await add(tester, 'draft-job');
      await _include(tester, 'caption');
      await _enter(tester, _input('caption'), 'Retained record');
      final recordElement = tester.element(_input('caption'));
      final recordController = tester
          .widget<TextField>(_input('caption'))
          .controller;
      await _choose(tester, _key('record-type-jobs'), 'Note');
      await _enter(tester, _key('record-id-jobs'), 'draft-note');
      await _include(tester, 'display-name');
      await _enter(tester, _input('display-name'), 'Note draft');
      await _choose(tester, _key('record-type-jobs'), 'Job');
      expect(tester.element(_input('caption')), same(recordElement));
      expect(
        tester.widget<TextField>(_input('caption')).controller,
        same(recordController),
      );
      expect(recordController!.text, 'Retained record');
      expect(
        tester.widget<TextField>(_key('record-id-jobs')).controller!.text,
        'draft-job',
      );
      await _section(tester, 'Preferences');
      expect(tester.element(preference), same(scalarElement));
      expect(
        tester.widget<TextField>(preference).controller,
        same(scalarController),
      );
      expect(scalarController!.text, 'Retained preference');
      expect(
        tester
            .widget<EditableText>(
              find.descendant(
                of: _key('settings-search'),
                matching: find.byType(EditableText),
              ),
            )
            .controller
            .text,
        'Greeting',
      );
      await openRecords(tester);
      expect(tester.element(_input('caption')), same(recordElement));
      expect(recordController.text, 'Retained record');
      expect(service.recordLoads, 1);
      expect(File(service.filePath).existsSync(), isFalse);
      expect(
        Directory(service.collectionPath(_collection)).existsSync(),
        isFalse,
      );
      await unmount(tester);
    });
  });

  testWidgets(
    'creating one type retains the other type draft and controls',
    (tester) {
      return tester.runAsync(() async {
        await mount(tester);
        await openRecords(tester);
        await add(tester, 'uncommitted-job');
        await _include(tester, 'caption');
        await _enter(
          tester,
          _input('caption'),
          'Retained across sibling creation',
        );
        final element = tester.element(_input('caption'));
        final controller = tester
            .widget<TextField>(_input('caption'))
            .controller;
        await _choose(tester, _key('record-type-jobs'), 'Note');
        await _enter(tester, _key('record-id-jobs'), 'committed-note');
        await create(tester);
        expect(file('committed-note').existsSync(), isTrue);
        await _tap(tester, _key('records-add-jobs'));
        expect(
          tester.widget<TextField>(_key('record-id-jobs')).controller!.text,
          '',
        );
        await _choose(tester, _key('record-type-jobs'), 'Job');
        expect(tester.element(_input('caption')), same(element));
        expect(
          tester.widget<TextField>(_input('caption')).controller,
          same(controller),
        );
        expect(controller!.text, 'Retained across sibling creation');
        expect(
          tester.widget<TextField>(_key('record-id-jobs')).controller!.text,
          'uncommitted-job',
        );
        expect(
          tester.widget<CheckboxListTile>(_presence('caption')).value,
          isTrue,
        );
        expect(file('uncommitted-job').existsSync(), isFalse);
        await unmount(tester);
      });
    },
    skip: !Platform.isLinux,
  );

  testWidgets(
    'hidden sections and record type forms cannot receive keyboard focus',
    (tester) {
      return tester.runAsync(() async {
        await mount(tester);
        await openRecords(tester);
        await add(tester, 'focus-draft');
        await _include(tester, 'caption');
        await _enter(tester, _input('caption'), 'Keep this');
        await _section(tester, 'Preferences');
        await _expectNoFocus(tester, ['record-', 'records-']);
        await openRecords(tester);
        await _choose(tester, _key('record-type-jobs'), 'Note');
        await _expectNoFocus(tester, [
          'setting-',
          'record-input-jobs-caption',
          'record-presence-jobs-caption',
        ]);
        await _choose(tester, _key('record-type-jobs'), 'Job');
        expect(
          tester.widget<TextField>(_input('caption')).controller!.text,
          'Keep this',
        );
        await unmount(tester);
      });
    },
  );

  testWidgets(
    'generic title metadata, immutable details and per-file diagnostics reload',
    (tester) {
      return tester.runAsync(() async {
        await service.createRecord(
          _job,
          ConfigurationRecordId('with-title'),
          _values(caption: 'Declared title'),
        );
        await service.createRecord(
          _note,
          ConfigurationRecordId('id-fallback'),
          {'display-name': 'Not a title heuristic'},
        );
        file('broken').writeAsStringSync('broken = [\n');
        file('unknown').writeAsStringSync(
          'record-version = 1\nrecord-type = "dev.missing.type"\n[values]\n',
        );
        await mount(tester);
        await openRecords(tester);
        expect(find.text('Declared title'), findsOneWidget);
        expect(find.text('id-fallback'), findsOneWidget);
        expect(find.text('Not a title heuristic'), findsNothing);
        expect(find.textContaining('broken.toml:'), findsOneWidget);
        expect(find.textContaining('unknown.toml:'), findsOneWidget);
        await _tap(tester, find.text('Declared title'));
        expect(find.text('Record ID: with-title'), findsOneWidget);
        expect(find.text('Record type: $_job'), findsOneWidget);
        expect(find.text('Enabled: false'), findsOneWidget);
        expect(find.text('Count: 0'), findsOneWidget);
        expect(find.text('Optional text: Not provided'), findsOneWidget);
        expect(find.text('Save'), findsNothing);
        expect(find.text('Delete'), findsNothing);
        expect(find.text('Reset'), findsNothing);
        file('with-title').writeAsStringSync(
          file(
            'with-title',
          ).readAsStringSync().replaceFirst('Declared title', 'External title'),
        );
        file('broken').deleteSync();
        await _tap(tester, _key('records-reload-jobs'));
        await _loaded(tester);
        expect(find.text('External title'), findsOneWidget);
        expect(find.text('Declared title'), findsNothing);
        expect(find.textContaining('broken.toml:'), findsNothing);
        expect(find.textContaining('unknown.toml:'), findsOneWidget);
        await unmount(tester);
      });
    },
    skip: !Platform.isLinux,
  );

  testWidgets(
    'scalar load failure leaves record navigation and declaration issues available',
    (tester) {
      return tester.runAsync(() async {
        File(service.filePath).parent.createSync(recursive: true);
        File(service.filePath).writeAsStringSync('broken = [\n');
        await mount(tester, recordIssues: ['Unavailable record declaration']);
        expect(find.textContaining('Could not load settings'), findsOneWidget);
        expect(
          find.textContaining('Record declarations unavailable'),
          findsNothing,
        );
        await openRecords(tester);
        expect(_enabled(tester, _key('records-add-jobs')), isTrue);
        expect(
          find.textContaining('Record declarations unavailable'),
          findsOneWidget,
        );
        await add(tester, 'independent');
        await fillRequired(tester);
        await create(tester);
        expect(file('independent').existsSync(), isTrue);
        expect(File(service.filePath).readAsStringSync(), 'broken = [\n');
        await unmount(tester);
      });
    },
    skip: !Platform.isLinux,
  );

  testWidgets(
    'narrow creation remains reachable with explicit optional absence',
    (tester) {
      return tester.runAsync(() async {
        await mount(tester);
        await openRecords(tester);
        await tester.binding.setSurfaceSize(const Size(400, 700));
        await tester.pumpAndSettle();
        await add(tester, 'narrow');
        await fillRequired(tester, caption: 'Narrow-screen draft');
        await _include(tester, 'optional-text');
        await _enter(
          tester,
          _input('optional-text'),
          'Remember after exclusion',
        );
        await _include(tester, 'optional-text');
        expect(
          tester.widget<TextField>(_input('optional-text')).enabled,
          isFalse,
        );
        await create(tester);
        expect(tester.takeException(), isNull);
        expect(
          (await service.loadRecords(
            _collection,
          )).records.single.values.containsKey('optional-text'),
          isFalse,
        );
        expect(
          tester.getSize(find.byType(Dialog)).width,
          lessThanOrEqualTo(400),
        );
        await unmount(tester);
      });
    },
    skip: !Platform.isLinux,
  );

  testWidgets(
    'record diagnostics remain separate when no collections are available',
    (tester) {
      return tester.runAsync(() async {
        final catalog = service.catalog;
        await service.close();
        service = _ControlledService(
          catalog: catalog,
          roots: roots,
          records: RecordCatalog([]),
        );
        await mount(
          tester,
          recordIssues: ['Conflicting collection declarations'],
        );
        expect(
          find.textContaining('Conflicting collection declarations'),
          findsNothing,
        );
        expect(_key('setting-input-$_preference'), findsOneWidget);
        await _section(tester, 'Record diagnostics');
        expect(
          find.textContaining(
            'Record declarations unavailable: Conflicting collection declarations',
          ),
          findsOneWidget,
        );
        expect(
          find.text('No readable records in this collection.'),
          findsNothing,
        );
        expect(find.text('Add'), findsNothing);
        expect(
          find.textContaining('Setting declarations unavailable:'),
          findsNothing,
        );
        await unmount(tester);
      });
    },
  );

  testWidgets(
    'duplicate record conflict never overwrites and Reload retains the draft',
    (tester) {
      return tester.runAsync(() async {
        await service.createRecord(_note, ConfigurationRecordId('occupied'), {
          'display-name': 'Existing note',
        });
        final before = file('occupied').readAsBytesSync();
        await mount(tester);
        await openRecords(tester);
        await add(tester, 'occupied');
        await fillRequired(tester, caption: 'Unsaved title');
        await create(tester);
        expect(find.textContaining('Not created:'), findsOneWidget);
        expect(file('occupied').readAsBytesSync(), before);
        expect(_enabled(tester, _key('record-create-jobs')), isFalse);
        expect(
          tester.widget<TextField>(_input('caption')).controller!.text,
          'Unsaved title',
        );
        await _tap(tester, _key('records-reload-jobs'));
        await _loaded(tester);
        expect(
          tester.widget<TextField>(_input('caption')).controller!.text,
          'Unsaved title',
        );
        expect(_enabled(tester, _key('record-create-jobs')), isTrue);
        await _enter(tester, _key('record-id-jobs'), 'different');
        await create(tester);
        expect(file('different').existsSync(), isTrue);
        expect(file('occupied').readAsBytesSync(), before);
        await unmount(tester);
      });
    },
    skip: !Platform.isLinux,
  );

  for (final lostAcknowledgement in [false, true]) {
    testWidgets(
      'unconfirmed ${lostAcknowledgement ? 'published' : 'failed'} creation requires Reload without losing draft',
      (tester) {
        return tester.runAsync(() async {
          await mount(tester);
          await openRecords(tester);
          await add(tester, 'uncertain');
          await fillRequired(tester, caption: 'Retained uncertain draft');
          service.loseAcknowledgement = lostAcknowledgement;
          if (!lostAcknowledgement) {
            File(roots.localStateRoot).writeAsStringSync('not a directory');
          }
          await create(tester);
          expect(
            find.textContaining('Could not confirm creation'),
            findsOneWidget,
          );
          expect(find.textContaining('Not created:'), findsNothing);
          expect(find.text('Created uncertain.'), findsNothing);
          expect(_key('record-jobs-uncertain'), findsNothing);
          expect(file('uncertain').existsSync(), lostAcknowledgement);
          expect(_enabled(tester, _key('record-create-jobs')), isFalse);
          expect(
            tester.widget<TextField>(_input('caption')).controller!.text,
            'Retained uncertain draft',
          );
          if (!lostAcknowledgement) File(roots.localStateRoot).deleteSync();
          service.loseAcknowledgement = false;
          await _tap(tester, _key('records-reload-jobs'));
          await _loaded(tester);
          expect(
            tester.widget<TextField>(_input('caption')).controller!.text,
            'Retained uncertain draft',
          );
          expect(_enabled(tester, _key('record-create-jobs')), isTrue);
          expect(
            _key('record-jobs-uncertain'),
            lostAcknowledgement ? findsOneWidget : findsNothing,
          );
          expect(service.creates, 1);
          await unmount(tester);
        });
      },
      skip: !Platform.isLinux,
    );
  }

  testWidgets(
    'confirmed actual persisted view survives a failed listing refresh',
    (tester) {
      return tester.runAsync(() async {
        await mount(tester);
        await openRecords(tester);
        await add(tester, 'requested-id');
        await fillRequired(tester, caption: 'Requested title');
        service.returnDifferentPersistedRecord = true;
        service.failRefreshAfterCreate = true;
        await create(tester);
        expect(find.text('Created actual-id.'), findsOneWidget);
        expect(find.text('Actual persisted title'), findsOneWidget);
        expect(find.textContaining('record was created, but'), findsOneWidget);
        expect(find.textContaining('Could not confirm creation'), findsNothing);
        expect(_key('record-jobs-actual-id'), findsOneWidget);
        expect(file('actual-id').existsSync(), isTrue);
        expect(file('requested-id').existsSync(), isFalse);
        expect(_enabled(tester, _key('records-add-jobs')), isFalse);
        await _tap(tester, _key('records-reload-jobs'));
        await _loaded(tester);
        expect(_enabled(tester, _key('records-add-jobs')), isTrue);
        expect(find.text('Actual persisted title'), findsOneWidget);
        await unmount(tester);
      });
    },
    skip: !Platform.isLinux,
  );

  testWidgets(
    'captured create and reload callbacks share synchronous admission',
    (tester) {
      return tester.runAsync(() async {
        await mount(tester);
        await openRecords(tester);
        await add(tester, 'single');
        await fillRequired(tester);
        var commit = tester
            .widget<ButtonStyleButton>(_key('record-create-jobs'))
            .onPressed!;
        var reload = tester
            .widget<ButtonStyleButton>(_key('records-reload-jobs'))
            .onPressed!;
        final reloadGate = Completer<void>();
        service.gate = reloadGate.future;
        try {
          reload();
          reload();
          commit();
          expect(service.recordLoads, 2);
          expect(service.creates, 0);
          await tester.pump();
          expect(_enabled(tester, _key('records-reload-jobs')), isFalse);
          expect(_enabled(tester, _key('record-create-jobs')), isFalse);
        } finally {
          service.gate = null;
          reloadGate.complete();
        }
        await _loaded(tester);
        commit = tester
            .widget<ButtonStyleButton>(_key('record-create-jobs'))
            .onPressed!;
        reload = tester
            .widget<ButtonStyleButton>(_key('records-reload-jobs'))
            .onPressed!;
        final createGate = Completer<void>();
        service.gate = createGate.future;
        try {
          commit();
          commit();
          reload();
          expect(service.creates, 1);
          expect(service.recordLoads, 2);
          await tester.pump();
          expect(_enabled(tester, _key('records-reload-jobs')), isFalse);
          expect(tester.widget<TextField>(_input('caption')).enabled, isFalse);
        } finally {
          service.gate = null;
          createGate.complete();
        }
        await _loaded(tester);
        expect(service.recordLoads, 3);
        expect(service.creates, 1);
        expect(file('single').existsSync(), isTrue);
        await unmount(tester);
      });
    },
    skip: !Platform.isLinux,
  );

  testWidgets('failed collection load is explicit and reload retries', (
    tester,
  ) {
    return tester.runAsync(() async {
      service.failNextLoad = true;
      await mount(tester);
      await openRecords(tester);
      expect(find.textContaining('Could not load records'), findsOneWidget);
      expect(
        find.text('No readable records in this collection.'),
        findsNothing,
      );
      expect(_enabled(tester, _key('records-add-jobs')), isFalse);
      await _tap(tester, _key('records-reload-jobs'));
      await _loaded(tester);
      expect(_enabled(tester, _key('records-add-jobs')), isTrue);
      expect(
        find.text('No readable records in this collection.'),
        findsOneWidget,
      );
      await unmount(tester);
    });
  });

  testWidgets(
    'closed dialog rejects captured scalar and record I/O callbacks',
    (tester) {
      return tester.runAsync(() async {
        await mount(tester);
        final scalarReload = tester
            .widget<ButtonStyleButton>(_key('settings-reload'))
            .onPressed!;
        final scalarSave = tester
            .widget<ButtonStyleButton>(_key('setting-save-$_preference'))
            .onPressed!;
        await openRecords(tester);
        await add(tester, 'not-admitted');
        await fillRequired(tester);
        final create = tester
            .widget<ButtonStyleButton>(_key('record-create-jobs'))
            .onPressed!;
        final reload = tester
            .widget<ButtonStyleButton>(_key('records-reload-jobs'))
            .onPressed!;
        Navigator.of(tester.element(find.byType(GlobalSettingsDialog))).pop();
        await tester.pumpAndSettle();
        scalarReload();
        scalarSave();
        create();
        reload();
        await tester.pump();
        expect(service.scalarLoads, 1);
        expect(service.recordLoads, 1);
        expect(service.creates, 0);
        expect(File(service.filePath).existsSync(), isFalse);
        expect(file('not-admitted').existsSync(), isFalse);
        await unmount(tester);
      });
    },
  );

  testWidgets(
    'closing pending creation leaves its admitted native write intact',
    (tester) {
      return tester.runAsync(() async {
        await mount(tester);
        await openRecords(tester);
        await add(tester, 'after-close');
        await fillRequired(tester, caption: 'Created after close');
        final gate = Completer<void>();
        service.gate = gate.future;
        try {
          tester
              .widget<ButtonStyleButton>(_key('record-create-jobs'))
              .onPressed!();
          await tester.pump();
          Navigator.of(tester.element(find.byType(GlobalSettingsDialog))).pop();
          await tester.pumpAndSettle();
        } finally {
          service.gate = null;
          gate.complete();
        }
        await _until(tester, () => file('after-close').existsSync());
        expect(tester.takeException(), isNull);
        await tester.tap(find.text('Open settings'));
        await tester.pump();
        await _until(tester, () => _enabled(tester, _key('settings-reload')));
        await openRecords(tester);
        expect(find.text('Created after close'), findsOneWidget);
        expect(service.creates, 1);
        await unmount(tester);
      });
    },
    skip: !Platform.isLinux,
  );
}

RecordCatalog _catalog() {
  final enumeration = EnumSettingType([
    SettingEnumOption('compact', label: 'Compact label'),
    SettingEnumOption('expanded', label: 'Expanded label'),
  ]);
  RecordFieldDefinition<Object> field(
    String id,
    String label,
    SettingType<Object> type, {
    bool required = false,
  }) => RecordFieldDefinition(
    id: RecordFieldId(id),
    label: label,
    type: type,
    required: required,
  );
  return RecordCatalog([
    RecordTypeDefinition(
      id: _job,
      owner: PluginId('dev.example.records'),
      collection: _collection,
      collectionLabel: 'Jobs',
      label: 'Job',
      description: 'A declaration-only test job, not an executing job.',
      displayField: RecordFieldId('caption'),
      fields: [
        field('caption', 'Caption', const StringSettingType(), required: true),
        field('enabled', 'Enabled', const BooleanSettingType(), required: true),
        field(
          'count',
          'Count',
          IntegerSettingType(minimum: 0, maximum: 2),
          required: true,
        ),
        field('mode', 'Mode', enumeration, required: true),
        field('optional-text', 'Optional text', const StringSettingType()),
        field('optional-bool', 'Optional boolean', const BooleanSettingType()),
        field('optional-int', 'Optional integer', IntegerSettingType()),
        field('optional-enum', 'Optional enumeration', enumeration),
      ],
    ),
    RecordTypeDefinition(
      id: _note,
      owner: PluginId('dev.example.records'),
      collection: _collection,
      collectionLabel: 'Jobs',
      label: 'Note',
      fields: [
        field('display-name', 'Display Name', const StringSettingType()),
      ],
    ),
  ]);
}

Map<String, Object> _values({String caption = ''}) => {
  'caption': caption,
  'enabled': false,
  'count': 0,
  'mode': 'compact',
};

// Faults wrap the real serialized service and native persistence, never fake DTOs.
final class _ControlledService extends GlobalSettingsService {
  _ControlledService({
    required super.catalog,
    required super.roots,
    required super.records,
  });

  Future<void>? gate;
  int scalarLoads = 0;
  int recordLoads = 0;
  int creates = 0;
  bool loseAcknowledgement = false;
  bool failRefreshAfterCreate = false;
  bool failNextLoad = false;
  bool returnDifferentPersistedRecord = false;

  @override
  Future<GlobalSettingsView> load() {
    scalarLoads++;
    return super.load();
  }

  @override
  Future<RecordCollectionView> loadRecords(
    RecordCollectionId collection,
  ) async {
    recordLoads++;
    await gate;
    if (failNextLoad) {
      failNextLoad = false;
      throw const FileSystemException('Controlled collection failure');
    }
    return super.loadRecords(collection);
  }

  @override
  Future<RecordView> createRecord(
    RecordTypeId type,
    ConfigurationRecordId id,
    Map<String, Object?> values,
  ) async {
    creates++;
    await gate;
    final saved = await super.createRecord(
      type,
      returnDifferentPersistedRecord ? ConfigurationRecordId('actual-id') : id,
      returnDifferentPersistedRecord
          ? {...values, 'caption': 'Actual persisted title'}
          : values,
    );
    if (loseAcknowledgement) {
      throw const FileSystemException('Creation acknowledgement lost');
    }
    if (failRefreshAfterCreate) failNextLoad = true;
    return saved;
  }
}

Finder _key(String value) => find.byKey(ValueKey(value));
Finder _input(String field) => _key('record-input-jobs-$field');
Finder _presence(String field) => _key('record-presence-jobs-$field');

Future<void> _tap(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pump();
}

Future<void> _enter(WidgetTester tester, Finder finder, String text) async {
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.enterText(finder, text);
  await tester.pump();
}

Future<void> _include(WidgetTester tester, String field) =>
    _tap(tester, _presence(field));

Future<void> _choose(WidgetTester tester, Finder finder, String label) async {
  await _tap(tester, finder);
  await tester.pumpAndSettle();
  await tester.tap(find.text(label).last);
  await tester.pump();
  await _until(
    tester,
    () => find.byType(LinearProgressIndicator).evaluate().isEmpty,
  );
}

Future<void> _section(WidgetTester tester, String label) =>
    _choose(tester, _key('settings-section'), label);

Future<void> _loaded(WidgetTester tester) =>
    _until(tester, () => _enabled(tester, _key('records-reload-jobs')));

bool _enabled(WidgetTester tester, Finder finder) =>
    finder.evaluate().isNotEmpty &&
    tester.widget<ButtonStyleButton>(finder).onPressed != null;

Future<void> _until(WidgetTester tester, bool Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 10));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('Settings operation did not settle.');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
    await tester.pump(const Duration(milliseconds: 20));
  }
  await tester.pumpAndSettle();
}

Future<void> _expectNoFocus(WidgetTester tester, List<String> prefixes) async {
  for (var i = 0; i < 24; i++) {
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    FocusManager.instance.primaryFocus?.context?.visitAncestorElements((
      element,
    ) {
      final key = element.widget.key;
      expect(
        key is ValueKey<String> && prefixes.any(key.value.startsWith),
        isFalse,
        reason: 'Hidden control received keyboard focus: $key',
      );
      return true;
    });
  }
}
