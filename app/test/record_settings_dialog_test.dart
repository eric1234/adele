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

  Future<void> seed(String id, {String? caption}) async {
    await service.createRecord(
      _job,
      ConfigurationRecordId(id),
      _values(caption: caption ?? 'Title $id'),
    );
  }

  Future<void> save(WidgetTester tester, String id) async {
    await _tap(tester, _key('record-save-jobs-$id'));
    await _loaded(tester);
  }

  testWidgets(
    'existing scalar edits validate presence and preserve immutable identity and unknown data',
    (tester) => tester.runAsync(() async {
      await seed('original');
      final original = file('original');
      final withUnknownValues = original.readAsStringSync().replaceFirst(
        '[values]',
        '# Header comment\nunknown-header = "retain"\n[values]\n'
            '# Value comment\nunknown-value = [1, 2]\noptional-text = "remove"',
      );
      original.writeAsStringSync(
        '$withUnknownValues\n[unknown-table]\nflag = true\n',
      );
      final before = original.readAsBytesSync();
      await mount(tester);
      await openRecords(tester);
      await _edit(tester, 'original');
      expect(find.text('Collection: jobs'), findsOneWidget);
      expect(find.text('Record ID: original'), findsOneWidget);
      expect(find.text('Record type: $_job'), findsOneWidget);
      expect(_key('record-id-jobs-original'), findsNothing);
      expect(_key('record-type-jobs-original'), findsNothing);
      await save(tester, 'original');
      expect(original.readAsBytesSync(), before);
      await _tap(tester, _key('record-edit-jobs-original'));
      await _enter(
        tester,
        _editInput('original', 'caption'),
        'Renamed\nSecond line',
      );
      await _choose(tester, _editInput('original', 'enabled'), 'True');
      for (final invalid in ['', '1.5', '-1', '3', '9223372036854775808']) {
        await _enter(tester, _editInput('original', 'count'), invalid);
        expect(_enabled(tester, _key('record-save-jobs-original')), isFalse);
        expect(
          tester
              .widget<TextField>(_editInput('original', 'count'))
              .decoration!
              .errorText,
          isNotNull,
        );
      }
      await _enter(tester, _editInput('original', 'count'), '2');
      await _choose(tester, _editInput('original', 'mode'), 'Expanded label');
      await _tap(tester, _editPresence('original', 'caption'));
      expect(_enabled(tester, _key('record-save-jobs-original')), isFalse);
      await _tap(tester, _editPresence('original', 'caption'));
      await _tap(tester, _editPresence('original', 'optional-text'));
      for (final field in ['optional-bool', 'optional-int', 'optional-enum']) {
        await _tap(tester, _editPresence('original', field));
      }
      expect(
        tester
            .widget<DropdownButton<bool>>(
              _editInput('original', 'optional-bool'),
            )
            .value,
        isNull,
      );
      expect(_enabled(tester, _key('record-save-jobs-original')), isFalse);
      await _choose(tester, _editInput('original', 'optional-bool'), 'False');
      await _enter(tester, _editInput('original', 'optional-int'), '0');
      await _choose(
        tester,
        _editInput('original', 'optional-enum'),
        'Compact label',
      );
      await save(tester, 'original');
      expect(find.text('Renamed\nSecond line'), findsOneWidget);
      expect(find.text('Optional text: Not provided'), findsOneWidget);
      expect(find.text('Optional boolean: false'), findsOneWidget);
      expect(find.text('Optional integer: 0'), findsOneWidget);
      expect(find.text('Optional enumeration: compact'), findsOneWidget);
      expect(service.recordLoads, 1);
      final changed = original.readAsStringSync();
      for (final preserved in [
        '# Header comment',
        'unknown-header = "retain"',
        '# Value comment',
        'unknown-value = [1, 2]',
        '[unknown-table]\nflag = true',
      ]) {
        expect(changed, contains(preserved));
      }
      expect(changed, isNot(contains('optional-text')));
      expect(changed, isNot(contains('Expanded label')));
      await _tap(tester, _key('record-edit-jobs-original'));
      await _enter(tester, _editInput('original', 'caption'), '');
      await _tap(tester, _editPresence('original', 'optional-text'));
      await save(tester, 'original');
      expect(find.text('original'), findsOneWidget);
      expect(find.text('Optional text: (empty string)'), findsOneWidget);
      final saved = (await service.loadRecords(_collection)).records.single;
      expect(saved.id, ConfigurationRecordId('original'));
      expect(saved.type, _job);
      expect(saved.collection, _collection);
      expect(saved.values, {
        'caption': '',
        'enabled': true,
        'count': 2,
        'mode': 'expanded',
        'optional-text': '',
        'optional-bool': false,
        'optional-int': 0,
        'optional-enum': 'compact',
      });
      await unmount(tester);
    }),
    skip: !Platform.isLinux,
  );

  testWidgets(
    'existing drafts survive collapse and navigation with hidden focus excluded and local Cancel',
    (tester) => tester.runAsync(() async {
      await seed('first');
      await seed('second');
      await mount(tester);
      await _enter(
        tester,
        _key('setting-input-$_preference'),
        'Preference draft',
      );
      await openRecords(tester);
      await _edit(tester, 'first');
      await _enter(tester, _editInput('first', 'caption'), 'First draft');
      final element = tester.element(_editInput('first', 'caption'));
      final controller = tester
          .widget<TextField>(_editInput('first', 'caption'))
          .controller!;
      final staleSave = tester
          .widget<ButtonStyleButton>(_key('record-save-jobs-first'))
          .onPressed!;
      await _expand(tester, 'first');
      await tester.pumpAndSettle();
      expect(_editInput('first', 'caption'), findsNothing);
      await _expectNoFocus(tester, [
        'record-input-jobs-first',
        'record-presence-jobs-first',
      ]);
      await _edit(tester, 'second');
      await _enter(tester, _editInput('second', 'caption'), 'Second draft');
      await add(tester, 'creation-draft');
      await _include(tester, 'caption');
      await _enter(tester, _input('caption'), 'Creation draft');
      await _section(tester, 'Preferences');
      await _expectNoFocus(tester, ['record-', 'records-']);
      expect(
        tester
            .widget<TextField>(_key('setting-input-$_preference'))
            .controller!
            .text,
        'Preference draft',
      );
      await openRecords(tester);
      await _expand(tester, 'first');
      expect(tester.element(_editInput('first', 'caption')), same(element));
      expect(
        tester.widget<TextField>(_editInput('first', 'caption')).controller,
        same(controller),
      );
      expect(controller.text, 'First draft');
      await _tap(tester, _key('record-cancel-jobs-second'));
      expect(controller.text, 'First draft');
      expect(
        tester.widget<TextField>(_input('caption')).controller!.text,
        'Creation draft',
      );
      expect(file('second').readAsStringSync(), contains('Title second'));
      await _tap(tester, _key('record-cancel-jobs-first'));
      await _tap(tester, _key('record-edit-jobs-first'));
      staleSave();
      await tester.pump();
      expect(service.updates, 0);
      expect(
        tester
            .widget<TextField>(_editInput('first', 'caption'))
            .controller!
            .text,
        'Title first',
      );
      expect(service.recordLoads, 1);
      await unmount(tester);
    }),
    skip: !Platform.isLinux,
  );

  testWidgets(
    'create update and delete keep independent existing drafts and handles usable',
    (tester) => tester.runAsync(() async {
      for (final id in ['first', 'second', 'third']) {
        await seed(id);
      }
      await mount(tester);
      await openRecords(tester);
      await _edit(tester, 'first');
      await _enter(tester, _editInput('first', 'caption'), 'Saved first');
      await _edit(tester, 'second');
      await _enter(tester, _editInput('second', 'caption'), 'Saved second');
      final second = tester
          .widget<TextField>(_editInput('second', 'caption'))
          .controller;
      await add(tester, 'new-note');
      await _choose(tester, _key('record-type-jobs'), 'Note');
      await _enter(tester, _key('record-id-jobs'), 'new-note');
      await create(tester);
      expect(service.recordLoads, 1);
      expect(
        tester.widget<TextField>(_editInput('second', 'caption')).controller,
        same(second),
      );
      await save(tester, 'first');
      await _expand(tester, 'third');
      await _tap(tester, _key('record-delete-jobs-third'));
      await _tap(tester, _key('record-delete-confirm-jobs-third'));
      await _loaded(tester);
      expect(file('third').existsSync(), isFalse);
      expect(
        tester.widget<TextField>(_editInput('second', 'caption')).controller,
        same(second),
      );
      await save(tester, 'second');
      expect(file('second').readAsStringSync(), contains('Saved second'));
      expect(file('first').readAsStringSync(), contains('Saved first'));
      expect(service.recordLoads, 1);
      expect(service.updates, 2);
      expect(service.deletes, 1);
      expect(find.textContaining('Not saved:'), findsNothing);
      await unmount(tester);
    }),
    skip: !Platform.isLinux,
  );

  testWidgets(
    'worker validation failure is correctable without Reload or optimistic display',
    (tester) => tester.runAsync(() async {
      await seed('correctable');
      await mount(tester);
      await openRecords(tester);
      await _edit(tester, 'correctable');
      await _enter(
        tester,
        _editInput('correctable', 'caption'),
        'Corrected title',
      );
      service.rejectNextUpdate = true;
      await save(tester, 'correctable');
      expect(
        find.textContaining('Not saved: correct the values.'),
        findsOneWidget,
      );
      expect(_enabled(tester, _key('record-save-jobs-correctable')), isTrue);
      expect(find.text('Title correctable'), findsOneWidget);
      expect(
        file('correctable').readAsStringSync(),
        contains('Title correctable'),
      );
      await save(tester, 'correctable');
      expect(find.text('Corrected title'), findsOneWidget);
      expect(service.recordLoads, 1);
      expect(service.updates, 2);
      await unmount(tester);
    }),
    skip: !Platform.isLinux,
  );

  testWidgets(
    'Create cannot replace a still-listed identity and draft after external deletion',
    (tester) => tester.runAsync(() async {
      await seed('reused');
      await mount(tester);
      await openRecords(tester);
      await _edit(tester, 'reused');
      await _enter(
        tester,
        _editInput('reused', 'caption'),
        'Existing dirty draft',
      );
      final existing = tester
          .widget<TextField>(_editInput('reused', 'caption'))
          .controller;
      file('reused').deleteSync();
      await add(tester, 'reused');
      await _choose(tester, _key('record-type-jobs'), 'Note');
      await _enter(tester, _key('record-id-jobs'), 'reused');
      await create(tester);
      expect(service.creates, 1); // Only the original seed was admitted.
      expect(file('reused').existsSync(), isFalse);
      expect(_key('record-jobs-reused'), findsOneWidget);
      expect(find.textContaining('no write was attempted'), findsOneWidget);
      expect(
        tester.widget<TextField>(_editInput('reused', 'caption')).controller,
        same(existing),
      );
      expect(existing!.text, 'Existing dirty draft');
      await _tap(tester, _key('records-reload-jobs'));
      await _tap(tester, _key('records-reload-confirm-jobs'));
      await _loaded(tester);
      expect(_key('record-jobs-reused'), findsNothing);
      expect(
        tester.widget<TextField>(_key('record-id-jobs')).controller!.text,
        'reused',
      );
      await create(tester);
      expect(_key('record-jobs-reused'), findsOneWidget);
      expect(
        file('reused').readAsStringSync(),
        contains('recordType = "$_note"'),
      );
      expect(service.creates, 2);
      await unmount(tester);
    }),
    skip: !Platform.isLinux,
  );

  for (final deleting in [false, true]) {
    testWidgets(
      '${deleting ? 'delete' : 'no-op update'} conflict fences only the captured record until Reload',
      (tester) => tester.runAsync(() async {
        await seed('conflict');
        await seed('independent');
        await mount(tester);
        await openRecords(tester);
        await _edit(tester, 'conflict');
        final staleSave = tester
            .widget<ButtonStyleButton>(_key('record-save-jobs-conflict'))
            .onPressed!;
        file('conflict').writeAsStringSync(
          file(
            'conflict',
          ).readAsStringSync().replaceFirst('Title conflict', 'External value'),
        );
        final external = file('conflict').readAsBytesSync();
        if (deleting) {
          await _tap(tester, _key('record-delete-jobs-conflict'));
          await _tap(tester, _key('record-delete-confirm-jobs-conflict'));
          await _loaded(tester);
        } else {
          await save(tester, 'conflict');
        }
        expect(
          find.textContaining(
            'Not ${deleting ? 'deleted' : 'saved'}: this record changed on disk.',
          ),
          findsOneWidget,
        );
        expect(file('conflict').readAsBytesSync(), external);
        expect(_enabled(tester, _key('record-save-jobs-conflict')), isFalse);
        expect(_enabled(tester, _key('record-delete-jobs-conflict')), isFalse);
        staleSave();
        await tester.pump();
        expect(service.updates, deleting ? 0 : 1);
        await _edit(tester, 'independent');
        await _enter(
          tester,
          _editInput('independent', 'caption'),
          'Independent change',
        );
        await save(tester, 'independent');
        expect(
          file('independent').readAsStringSync(),
          contains('Independent change'),
        );
        await _tap(tester, _key('record-cancel-jobs-conflict'));
        expect(_enabled(tester, _key('record-edit-jobs-conflict')), isFalse);
        expect(_enabled(tester, _key('record-delete-jobs-conflict')), isFalse);
        await _tap(tester, _key('records-reload-jobs'));
        await _loaded(tester);
        expect(find.text('External value'), findsOneWidget);
        expect(_enabled(tester, _key('record-edit-jobs-conflict')), isTrue);
        staleSave();
        await tester.pump();
        expect(service.updates, deleting ? 1 : 2);
        await unmount(tester);
      }),
      skip: !Platform.isLinux,
    );
  }

  testWidgets(
    'Reload confirms dirty existing drafts and retains all controls and lists on read failure',
    (tester) => tester.runAsync(() async {
      await seed('first');
      await seed('second');
      await mount(tester);
      await _enter(
        tester,
        _key('setting-input-$_preference'),
        'Unrelated preference',
      );
      await openRecords(tester);
      for (final id in ['first', 'second']) {
        await _edit(tester, id);
        await _enter(tester, _editInput(id, 'caption'), 'Draft $id');
      }
      final first = tester
          .widget<TextField>(_editInput('first', 'caption'))
          .controller;
      final second = tester
          .widget<TextField>(_editInput('second', 'caption'))
          .controller;
      final staleSave = tester
          .widget<ButtonStyleButton>(_key('record-save-jobs-first'))
          .onPressed!;
      await add(tester, 'creation');
      await _include(tester, 'caption');
      await _enter(tester, _input('caption'), 'Creation retained');
      final creation = tester.widget<TextField>(_input('caption')).controller;
      await _tap(tester, _key('records-reload-jobs'));
      expect(find.text('Reload jobs?'), findsOneWidget);
      await _tap(tester, _key('records-reload-cancel-jobs'));
      await _loaded(tester);
      expect(service.recordLoads, 1);
      service.failNextLoad = true;
      await _tap(tester, _key('records-reload-jobs'));
      await _tap(tester, _key('records-reload-confirm-jobs'));
      await _loaded(tester);
      expect(find.textContaining('Could not load records'), findsOneWidget);
      expect(_key('record-jobs-first'), findsOneWidget);
      expect(_key('record-jobs-second'), findsOneWidget);
      expect(
        tester.widget<TextField>(_editInput('first', 'caption')).controller,
        same(first),
      );
      expect(
        tester.widget<TextField>(_editInput('second', 'caption')).controller,
        same(second),
      );
      expect(first!.text, 'Draft first');
      expect(second!.text, 'Draft second');
      expect(
        tester.widget<TextField>(_input('caption')).controller,
        same(creation),
      );
      expect(_enabled(tester, _key('record-save-jobs-first')), isFalse);
      staleSave();
      await tester.pump();
      expect(service.updates, 0);
      await _tap(tester, _key('records-reload-jobs'));
      await _tap(tester, _key('records-reload-confirm-jobs'));
      await _loaded(tester);
      expect(_editInput('first', 'caption'), findsNothing);
      expect(_editInput('second', 'caption'), findsNothing);
      expect(
        tester.widget<TextField>(_input('caption')).controller,
        same(creation),
      );
      expect(creation!.text, 'Creation retained');
      await _tap(tester, _key('record-edit-jobs-first'));
      staleSave();
      await tester.pump();
      expect(service.updates, 0);
      expect(
        tester
            .widget<TextField>(_editInput('first', 'caption'))
            .controller!
            .text,
        'Title first',
      );
      await _section(tester, 'Preferences');
      expect(
        tester
            .widget<TextField>(_key('setting-input-$_preference'))
            .controller!
            .text,
        'Unrelated preference',
      );
      await unmount(tester);
    }),
    skip: !Platform.isLinux,
  );

  testWidgets(
    'Delete confirms exact identity with safe Cancel autofocus and modal-only Escape',
    (tester) => tester.runAsync(() async {
      await seed('target', caption: 'Same title');
      await seed('sibling', caption: 'Same title');
      file('target').writeAsStringSync(
        '${file('target').readAsStringSync()}\nunknown = [1, 2]\n',
      );
      final sibling = file('sibling').readAsBytesSync();
      await mount(tester);
      await openRecords(tester);
      await _edit(tester, 'target');
      await _enter(
        tester,
        _editInput('target', 'caption'),
        'Unsaved renamed title',
      );
      final remove = tester
          .widget<ButtonStyleButton>(_key('record-delete-jobs-target'))
          .onPressed!;
      final reload = tester
          .widget<ButtonStyleButton>(_key('records-reload-jobs'))
          .onPressed!;
      remove();
      remove();
      reload();
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsOneWidget);
      final confirmation = find.descendant(
        of: find.byType(AlertDialog),
        matching: find.textContaining('Title: Same title'),
      );
      expect(confirmation, findsOneWidget);
      final message = tester.widget<Text>(confirmation).data!;
      for (final exact in [
        'Record ID: target',
        'Record type: $_job',
        'Collection: jobs',
        'entire record file',
        'unknown data',
      ]) {
        expect(message, contains(exact));
      }
      expect(message, isNot(contains('Unsaved renamed title')));
      expect(
        tester
            .widget<TextButton>(_key('record-delete-cancel-jobs-target'))
            .autofocus,
        isTrue,
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await _loaded(tester);
      expect(find.byType(AlertDialog), findsNothing);
      expect(service.deletes, 0);
      expect(file('target').existsSync(), isTrue);
      await _tap(tester, _key('record-delete-jobs-target'));
      await tester.pumpAndSettle();
      final staleConfirm = tester
          .widget<ButtonStyleButton>(_key('record-delete-confirm-jobs-target'))
          .onPressed!;
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await _loaded(tester);
      expect(find.byType(GlobalSettingsDialog), findsOneWidget);
      expect(find.byType(AlertDialog), findsNothing);
      staleConfirm();
      await tester.pump();
      expect(service.deletes, 0);
      expect(
        tester
            .widget<TextField>(_editInput('target', 'caption'))
            .controller!
            .text,
        'Unsaved renamed title',
      );
      await _tap(tester, _key('record-delete-jobs-target'));
      await tester.pumpAndSettle();
      final confirm = tester
          .widget<ButtonStyleButton>(_key('record-delete-confirm-jobs-target'))
          .onPressed!;
      final gate = Completer<void>();
      service.gate = gate.future;
      try {
        confirm();
        confirm();
        remove();
        reload();
        await tester.pump();
        expect(service.deletes, 1);
        expect(service.recordLoads, 1);
        expect(file('target').existsSync(), isTrue);
        expect(_key('record-jobs-target'), findsOneWidget);
      } finally {
        service.gate = null;
        gate.complete();
      }
      await _loaded(tester);
      expect(file('target').existsSync(), isFalse);
      expect(_key('record-jobs-target'), findsNothing);
      expect(file('sibling').readAsBytesSync(), sibling);
      expect(find.text('Deleted target.'), findsOneWidget);
      remove();
      confirm();
      await tester.pump();
      expect(service.deletes, 1);
      expect(find.byType(GlobalSettingsDialog), findsOneWidget);
      await unmount(tester);
    }),
    skip: !Platform.isLinux,
  );

  for (final deleting in [false, true]) {
    for (final published in [false, true]) {
      testWidgets(
        'unconfirmed ${published ? 'published' : 'failed'} ${deleting ? 'deletion' : 'update'} retains draft and fences only that record',
        (tester) => tester.runAsync(() async {
          await seed('uncertain');
          await seed('independent');
          await mount(tester);
          await openRecords(tester);
          await _edit(tester, 'uncertain');
          await _enter(
            tester,
            _editInput('uncertain', 'caption'),
            'Uncertain draft',
          );
          final staleSave = tester
              .widget<ButtonStyleButton>(_key('record-save-jobs-uncertain'))
              .onPressed!;
          service.failMutation = !published;
          service.loseUpdateAcknowledgement = published && !deleting;
          service.loseDeleteAcknowledgement = published && deleting;
          if (deleting) {
            await _tap(tester, _key('record-delete-jobs-uncertain'));
            await _tap(tester, _key('record-delete-confirm-jobs-uncertain'));
            await _loaded(tester);
          } else {
            await save(tester, 'uncertain');
          }
          expect(
            find.textContaining(
              'Could not confirm ${deleting ? 'deletion' : 'save'}.',
            ),
            findsOneWidget,
          );
          expect(
            find.textContaining('operation may have been published'),
            findsOneWidget,
          );
          expect(find.text('Title uncertain'), findsOneWidget);
          expect(_key('record-jobs-uncertain'), findsOneWidget);
          expect(
            tester
                .widget<TextField>(_editInput('uncertain', 'caption'))
                .controller!
                .text,
            'Uncertain draft',
          );
          expect(_enabled(tester, _key('record-save-jobs-uncertain')), isFalse);
          expect(
            _enabled(tester, _key('record-delete-jobs-uncertain')),
            isFalse,
          );
          expect(file('uncertain').existsSync(), !(deleting && published));
          if (!deleting) {
            expect(
              file('uncertain').readAsStringSync(),
              contains(published ? 'Uncertain draft' : 'Title uncertain'),
            );
          }
          staleSave();
          await tester.pump();
          expect(service.updates, deleting ? 0 : 1);
          service.failMutation = false;
          service.loseUpdateAcknowledgement = false;
          service.loseDeleteAcknowledgement = false;
          await _edit(tester, 'independent');
          await _enter(
            tester,
            _editInput('independent', 'caption'),
            'Independent saved',
          );
          await save(tester, 'independent');
          await _tap(tester, _key('records-reload-jobs'));
          await _tap(tester, _key('records-reload-confirm-jobs'));
          await _loaded(tester);
          expect(_editInput('uncertain', 'caption'), findsNothing);
          expect(
            _key('record-jobs-uncertain'),
            deleting && published ? findsNothing : findsOneWidget,
          );
          expect(
            find.text(
              published && !deleting ? 'Uncertain draft' : 'Title uncertain',
            ),
            deleting && published ? findsNothing : findsOneWidget,
          );
          expect(find.text('Independent saved'), findsOneWidget);
          await unmount(tester);
        }),
        skip: !Platform.isLinux,
      );
    }
  }

  testWidgets(
    'captured update callbacks are synchronously admitted once and old views stay fenced',
    (tester) => tester.runAsync(() async {
      await seed('single');
      await mount(tester);
      await openRecords(tester);
      await _edit(tester, 'single');
      await _enter(tester, _editInput('single', 'caption'), 'New title');
      final commit = tester
          .widget<ButtonStyleButton>(_key('record-save-jobs-single'))
          .onPressed!;
      final remove = tester
          .widget<ButtonStyleButton>(_key('record-delete-jobs-single'))
          .onPressed!;
      final reload = tester
          .widget<ButtonStyleButton>(_key('records-reload-jobs'))
          .onPressed!;
      final gate = Completer<void>();
      service.gate = gate.future;
      try {
        commit();
        commit();
        remove();
        reload();
        await tester.pump();
        expect(service.updates, 1);
        expect(service.deletes, 0);
        expect(service.recordLoads, 1);
        expect(file('single').readAsStringSync(), contains('Title single'));
        expect(find.text('Title single'), findsOneWidget);
        expect(find.byType(AlertDialog), findsNothing);
      } finally {
        service.gate = null;
        gate.complete();
      }
      await _loaded(tester);
      await _tap(tester, _key('record-edit-jobs-single'));
      commit();
      remove();
      await tester.pump();
      expect(service.updates, 1);
      expect(service.deletes, 0);
      expect(find.byType(AlertDialog), findsNothing);
      final currentCommit = tester
          .widget<ButtonStyleButton>(_key('record-save-jobs-single'))
          .onPressed!;
      final currentDelete = tester
          .widget<ButtonStyleButton>(_key('record-delete-jobs-single'))
          .onPressed!;
      Navigator.of(tester.element(find.byType(GlobalSettingsDialog))).pop();
      await tester.pumpAndSettle();
      currentCommit();
      currentDelete();
      reload();
      await tester.pump();
      expect(service.updates, 1);
      expect(service.deletes, 0);
      expect(service.recordLoads, 1);
      await unmount(tester);
    }),
    skip: !Platform.isLinux,
  );

  for (final deleting in [false, true]) {
    testWidgets(
      'dialog close does not cancel admitted ${deleting ? 'delete' : 'update'}',
      (tester) => tester.runAsync(() async {
        await seed('after-close');
        await mount(tester);
        await openRecords(tester);
        await _edit(tester, 'after-close');
        await _enter(
          tester,
          _editInput('after-close', 'caption'),
          'Saved after close',
        );
        if (deleting) {
          await _tap(tester, _key('record-delete-jobs-after-close'));
          await tester.pumpAndSettle();
        }
        final gate = Completer<void>();
        service.gate = gate.future;
        try {
          tester
              .widget<ButtonStyleButton>(
                _key(
                  deleting
                      ? 'record-delete-confirm-jobs-after-close'
                      : 'record-save-jobs-after-close',
                ),
              )
              .onPressed!();
          await tester.pump();
          Navigator.of(tester.element(find.byType(GlobalSettingsDialog))).pop();
          await tester.pumpAndSettle();
        } finally {
          service.gate = null;
          gate.complete();
        }
        await _until(
          tester,
          () => deleting
              ? !file('after-close').existsSync()
              : file(
                  'after-close',
                ).readAsStringSync().contains('Saved after close'),
        );
        expect(tester.takeException(), isNull);
        await tester.tap(find.text('Open settings'));
        await tester.pump();
        await _until(tester, () => _enabled(tester, _key('settings-reload')));
        await openRecords(tester);
        expect(
          _key('record-jobs-after-close'),
          deleting ? findsNothing : findsOneWidget,
        );
        expect(
          find.text('Saved after close'),
          deleting ? findsNothing : findsOneWidget,
        );
        await unmount(tester);
      }),
      skip: !Platform.isLinux,
    );
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
        expect(_enabled(tester, _key('record-edit-jobs-with-title')), isTrue);
        expect(_enabled(tester, _key('record-delete-jobs-with-title')), isTrue);
        expect(find.text('Collection: jobs'), findsOneWidget);
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
    'confirmed creation uses its returned view without a handle-revoking refresh',
    (tester) {
      return tester.runAsync(() async {
        await mount(tester);
        await openRecords(tester);
        await add(tester, 'requested-id');
        await fillRequired(tester, caption: 'Requested title');
        service.returnDifferentPersistedRecord = true;
        service.failNextLoad = true;
        await create(tester);
        expect(find.text('Created actual-id.'), findsOneWidget);
        expect(find.text('Actual persisted title'), findsOneWidget);
        expect(service.recordLoads, 1);
        expect(find.textContaining('Could not confirm creation'), findsNothing);
        expect(_key('record-jobs-actual-id'), findsOneWidget);
        expect(file('actual-id').existsSync(), isTrue);
        expect(file('requested-id').existsSync(), isFalse);
        expect(_enabled(tester, _key('records-add-jobs')), isTrue);
        await _tap(tester, _key('records-reload-jobs'));
        await _loaded(tester);
        expect(find.textContaining('Could not load records'), findsOneWidget);
        expect(find.text('Actual persisted title'), findsOneWidget);
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
        expect(service.recordLoads, 2);
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
  int updates = 0;
  int deletes = 0;
  bool loseAcknowledgement = false;
  bool loseUpdateAcknowledgement = false;
  bool loseDeleteAcknowledgement = false;
  bool failMutation = false;
  bool rejectNextUpdate = false;
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
    return saved;
  }

  @override
  Future<RecordView> updateRecord(
    RecordView expected,
    Map<String, Object?> values,
  ) async {
    updates++;
    await gate;
    if (rejectNextUpdate) {
      rejectNextUpdate = false;
      // The real worker rejects this before persistence and retains its handle.
      return super.updateRecord(expected, {...values, 'count': -1});
    }
    if (failMutation) {
      throw const FileSystemException('Controlled update failure');
    }
    final saved = await super.updateRecord(expected, values);
    if (loseUpdateAcknowledgement) {
      throw const FileSystemException('Update acknowledgement lost');
    }
    return saved;
  }

  @override
  Future<void> deleteRecord(RecordView expected) async {
    deletes++;
    await gate;
    if (failMutation) {
      throw const FileSystemException('Controlled delete failure');
    }
    await super.deleteRecord(expected);
    if (loseDeleteAcknowledgement) {
      throw const FileSystemException('Delete acknowledgement lost');
    }
  }
}

Finder _key(String value) => find.byKey(ValueKey(value));
Finder _input(String field) => _key('record-input-jobs-$field');
Finder _presence(String field) => _key('record-presence-jobs-$field');
Finder _editInput(String id, String field) =>
    _key('record-input-jobs-$id-$field');
Finder _editPresence(String id, String field) =>
    _key('record-presence-jobs-$id-$field');

Future<void> _expand(WidgetTester tester, String id) async {
  await _tap(
    tester,
    find
        .descendant(
          of: _key('record-jobs-$id'),
          matching: find.byType(ListTile),
        )
        .first,
  );
  await tester.pumpAndSettle();
}

Future<void> _edit(WidgetTester tester, String id) async {
  await _expand(tester, id);
  await _tap(tester, _key('record-edit-jobs-$id'));
}

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
