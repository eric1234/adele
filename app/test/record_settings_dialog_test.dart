import 'dart:async';
import 'dart:io';

import 'package:adele_desktop/core/global_settings_service.dart';
import 'package:adele_desktop/core/record_apply_coordinator.dart';
import 'package:adele_desktop/editor/native_rich_document_editor.dart';
import 'package:adele_desktop/ui/settings/global_settings_dialog.dart';
import 'package:adele_platform_storage/adele_platform_storage.dart';
import 'package:adele_plugin_api/adele_plugin_api.dart';
import 'package:adele_settings/adele_settings.dart';
import 'package:appflowy_editor/appflowy_editor.dart' as rich;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plugin_runtime/plugin_runtime.dart';

import '../../tools/backend_artifacts.dart';
import 'native_rich_document_editor_test.dart'
    as native_input
    show control, frames, input, insertAtSelection;
import 'support/record_draft_id.dart';

final _collection = RecordCollectionId('jobs');
final _job = RecordTypeId('dev.example.records.job');
final _note = RecordTypeId('dev.example.records.note');
final _memo = RecordTypeId('dev.example.records.memo');
final _named = RecordTypeId('dev.example.records.named');
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
    GlobalSettingsService? settingsService,
    RecordApplication? application,
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
                  service: () async => settingsService ?? service,
                  recordApplication: () => application,
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

  Future<void> add(WidgetTester tester) =>
      _tap(tester, _key('records-add-jobs'));

  Future<void> fillRequired(WidgetTester tester, {String caption = ''}) async {
    if (caption.isNotEmpty) await _enter(tester, _input('caption'), caption);
    await _choose(tester, _input('enabled'), 'False');
    await _enter(tester, _input('count'), '0');
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
    'only the supported type reports runtime outcomes, independently of drafts and persistence',
    (tester) => tester.runAsync(() async {
      final application = RecordApplicationProbe(_job);
      final key = _jobKey('supported');
      await seed('supported', caption: 'same-title');
      await service.createRecord(
        _note,
        ConfigurationRecordId('same-title'),
        {},
      );
      await mount(tester, application: application);
      await openRecords(tester);
      expect(find.text('same-title'), findsNWidgets(2));
      expect(find.textContaining('No confirmed result'), findsOneWidget);
      await _edit(tester, 'same-title');
      await save(tester, 'same-title');
      await _edit(tester, 'supported');
      expect(application.saves, isEmpty);
      final original = file('supported').readAsBytesSync();
      await save(tester, 'supported'); // An acknowledged no-op still applies.
      expect(file('supported').readAsBytesSync(), original);
      expect(application.saves, [(key, false)]);
      expect(find.text('Runtime application: Applying...'), findsOneWidget);
      await _tap(tester, _key('record-edit-jobs-supported'));
      await _enter(tester, _editInput('supported', 'caption'), 'Draft');
      application.report(
        key,
        const RecordApplyOutcome(
          RecordApplyStatus.failed,
          'private-backend-diagnostic',
        ),
      );
      await tester.pump();
      expect(find.text('Runtime application: Not applied'), findsOneWidget);
      expect(find.textContaining('private-backend'), findsNothing);
      expect(_enabled(tester, _key('record-save-jobs-supported')), isTrue);
      await _section(tester, 'Preferences');
      await openRecords(tester);
      await _tap(tester, find.text('Retry application'));
      expect(application.retries, [key]);
      expect(application.saves, [(key, false)]);
      expect(service.updates, 2);
      expect(
        tester
            .widget<TextField>(_editInput('supported', 'caption'))
            .controller!
            .text,
        'Draft',
      );
      await unmount(tester);
      expect(application.observed, isFalse);
      application.report(
        key,
        const RecordApplyOutcome(
          RecordApplyStatus.applied,
          'ok',
          cleanupPending: true,
        ),
      );
      await mount(tester, application: application);
      await openRecords(tester);
      expect(find.text('Runtime application: Applied'), findsOneWidget);
      expect(
        find.textContaining('Cleanup of the previous configuration'),
        findsOneWidget,
      );
      expect(find.text('Retry application'), findsNothing);
      for (final code in [
        'publication_outcome_unknown',
        'apply_acknowledgement_unknown',
      ]) {
        application.report(
          key,
          RecordApplyOutcome(RecordApplyStatus.restartRequired, code),
        );
        await tester.pump();
        expect(
          find.text('Runtime application: Restart required'),
          findsOneWidget,
        );
        expect(
          find.textContaining('Restart ADELE before trying again'),
          findsOneWidget,
        );
        expect(find.textContaining(code), findsNothing);
        expect(find.text('Retry application'), findsNothing);
      }
      expect(service.updates, 2);
      await unmount(tester);
    }),
    skip: !Platform.isLinux,
  );

  testWidgets(
    'only the latest deletion is shown and retry survives reopening without another delete',
    (tester) => tester.runAsync(() async {
      final application = RecordApplicationProbe(_job);
      for (final id in ['first', 'second']) {
        await seed(id);
      }
      await mount(tester, application: application);
      await openRecords(tester);
      VoidCallback? previousRetry;
      for (final id in ['first', 'second']) {
        await _expand(tester, id);
        await _tap(tester, _key('record-delete-jobs-$id'));
        await _tap(tester, _key('record-delete-confirm-jobs-$id'));
        await _loaded(tester);
        final key = _jobKey(id);
        expect(application.saves.last, (key, true));
        application.report(
          key,
          const RecordApplyOutcome(
            RecordApplyStatus.unavailable,
            'backend_unavailable',
          ),
        );
        await tester.pump();
        expect(find.text('Deleted record: Job'), findsOneWidget);
        expect(find.text('Deleted Title $id.'), findsOneWidget);
        expect(find.text('Runtime application: Unavailable'), findsOneWidget);
        previousRetry?.call();
        expect(application.retries, isEmpty);
        previousRetry = tester
            .widget<TextButton>(
              find.widgetWithText(TextButton, 'Retry application'),
            )
            .onPressed!;
      }
      await unmount(tester);
      previousRetry!();
      expect(application.retries, isEmpty);
      await mount(tester, application: application);
      await openRecords(tester);
      expect(find.text('Deleted record: Job'), findsOneWidget);
      expect(_key('record-apply-jobs-$_job-first'), findsNothing);
      expect(_key('record-apply-jobs-$_job-second'), findsOneWidget);
      await _tap(tester, find.text('Retry application'));
      final latest = _jobKey('second');
      expect(application.retries, [latest]);
      expect(service.deletes, 2);
      expect(application.saves, [(_jobKey('first'), true), (latest, true)]);
      application.report(
        latest,
        const RecordApplyOutcome(RecordApplyStatus.noChange, 'already_absent'),
      );
      await tester.pump();
      expect(find.text('Runtime application: No change'), findsOneWidget);
      expect(find.text('Retry application'), findsNothing);
      await unmount(tester);
    }),
    skip: !Platform.isLinux,
  );

  testWidgets(
    'Reload does not attribute deletion outcomes or Retry to restored records',
    (tester) => tester.runAsync(() async {
      final application = RecordApplicationProbe(_job);
      final originals = <String, List<int>>{};
      for (final id in ['first', 'second']) {
        await seed(id);
        originals[id] = file(id).readAsBytesSync();
      }
      await mount(tester, application: application);
      await openRecords(tester);
      for (final id in originals.keys) {
        await _expand(tester, id);
        await _tap(tester, _key('record-delete-jobs-$id'));
        await _tap(tester, _key('record-delete-confirm-jobs-$id'));
        await _loaded(tester);
        application.report(
          _jobKey(id),
          id == 'first'
              ? const RecordApplyOutcome(RecordApplyStatus.applied, 'removed')
              : const RecordApplyOutcome(
                  RecordApplyStatus.unavailable,
                  'backend_unavailable',
                ),
        );
        await tester.pump();
      }
      final oldDeletionRetry = tester
          .widget<TextButton>(
            find.widgetWithText(TextButton, 'Retry application'),
          )
          .onPressed!;
      for (final original in originals.entries) {
        file(original.key).writeAsBytesSync(original.value);
      }
      await _tap(tester, _key('records-reload-jobs'));
      await _loaded(tester);
      for (final id in originals.keys) {
        expect(
          find.descendant(
            of: _key('record-jobs-$id'),
            matching: find.text('Runtime application: No confirmed result'),
          ),
          findsOneWidget,
        );
      }
      expect(find.textContaining('Deleted record:'), findsNothing);
      expect(find.text('Saved configuration'), findsNothing);
      expect(find.text('Retry application'), findsNothing);
      oldDeletionRetry();
      expect(application.retries, isEmpty);
      expect(application.saves, [
        (_jobKey('first'), true),
        (_jobKey('second'), true),
      ]);

      await _edit(tester, 'first');
      await save(tester, 'first');
      expect(application.saves.last, (_jobKey('first'), false));
      expect(find.text('Runtime application: Applying...'), findsOneWidget);
      await unmount(tester);
    }),
    skip: !Platform.isLinux,
  );

  group('published Agents in Global Settings', () {
    const pluginId = 'dev.adele.plugin.agent-configuration';
    final agents = RecordCollectionId('agents');
    final type = RecordTypeId('$pluginId.agent');
    late _ControlledService settings;
    late GlobalSettingsService reader;
    File agentFile([String id = 'reviewer']) =>
        File('${roots.configurationRoot}/agents/$id.toml');
    setUp(() async {
      await publishStockPluginInstallation(
        repositoryRoot: Directory.current.parent,
        installationDirectory: Directory(
          '${temporary.path}/installed/agent-configuration',
        ),
        pluginId: pluginId,
        displayName: 'Agent Configuration',
        backend: true, // Declare the component, but leave its artifact missing.
      );
      final prepared = await PreparedPluginCatalog.discover(
        '${temporary.path}/installed',
      );
      expect(prepared.issues.single.component?.name, 'backend');
      expect(prepared.installations.single.backendArtifactUri, isNull);
      expect(prepared.installations.single.frontend, isNull);
      settings = _ControlledService(
        catalog: prepared.settings,
        records: prepared.records,
        roots: roots,
      );
      addTearDown(settings.close);
      // Independent owner: reads real TOML without revoking the dialog's handle.
      reader = GlobalSettingsService(
        catalog: prepared.settings,
        records: prepared.records,
        roots: roots,
      );
      addTearDown(reader.close);
      expect(settings.records.collectionLabel(agents), 'Agents');
      expect(settings.records.definition(type).credentialSlots, isEmpty);
    });

    Future<void> loaded(WidgetTester tester) =>
        _until(tester, () => _enabled(tester, _key('records-reload-agents')));
    Future<void> open(WidgetTester tester) async {
      await mount(tester, settingsService: settings);
      await _section(tester, 'Agents');
      await loaded(tester);
    }

    Future<void> seedAgent(String instructions) async {
      await settings.createRecord(type, ConfigurationRecordId('reviewer'), {
        'name': 'Reviewer',
        'instructions': instructions,
      });
    }

    Future<void> edit(WidgetTester tester) async {
      await _edit(tester, 'reviewer', collection: 'agents');
    }

    Future<Map<String, Object?>> stored() async =>
        (await reader.loadRecords(agents)).records.single.values;
    final saveButton = _key('record-save-agents-reviewer');
    final createButton = _key('record-create-agents');
    Future<void> submit(WidgetTester tester, Finder button) async {
      expect(_enabled(tester, button), isTrue);
      await _richTap(tester, button);
      await loaded(tester);
    }

    testWidgets(
      'duplicate names and empty required Instructions save as distinct Agents',
      (tester) => tester.runAsync(() async {
        await seedAgent('Existing');
        await open(tester);
        await _tap(tester, _key('records-add-agents'));
        await _enter(tester, _key('record-input-agents-name'), 'Reviewer');
        final id = await inspectDraftId(tester);
        await submit(tester, createButton);
        final byId = {
          for (final record in (await reader.loadRecords(agents)).records)
            record.id.value: record.values,
        };
        expect(byId, {
          'reviewer': {'name': 'Reviewer', 'instructions': 'Existing'},
          id: {'name': 'Reviewer', 'instructions': ''},
        });
        await unmount(tester);
      }),
    );

    testWidgets(
      'creates, edits and reloads formatted instructions without a backend',
      (tester) => tester.runAsync(() async {
        await open(tester);
        expect(
          find.text('No readable records in this collection.'),
          findsOneWidget,
        );
        expect(Directory(roots.configurationRoot).existsSync(), isFalse);
        await _tap(tester, _key('records-add-agents'));
        final id = await inspectDraftId(tester);
        final suffix = 'agents-$id';
        final recordFile = agentFile(id);
        expect(find.text('Agent'), findsOneWidget);
        expect(_enabled(tester, createButton), isFalse);
        expect(find.byType(CheckboxListTile), findsNothing);
        final name = _key('record-input-agents-name');
        expect(tester.widget<TextField>(name).enabled, isTrue);
        expect(_scalarDecoration(tester, name).labelText, 'Name (Required)');
        expect(_scalarDecoration(tester, name).errorText, isNotEmpty);
        await _enter(tester, _key('record-input-agents-name'), '   ');
        expect(_enabled(tester, createButton), isFalse);
        final instructions = tester.widget<InputDecorator>(
          _instructions('agents'),
        );
        expect(instructions.decoration.labelText, 'Instructions (Required)');
        final creation = _instructionsOwner(tester, 'agents');
        expect(creation.editingEnabled, isTrue);
        expect(creation.snapshot()['markdown'], '');
        const markdown = '```dart\nreport();\n```\n\nReview **risks**';
        const values = {
          'name': 'Reviewer',
          'description': 'Reviews changes.',
          'when-to-use': 'Before merging.',
          'instructions': markdown,
        };
        await _enter(tester, _key('record-input-agents-name'), values['name']!);
        // Instructions require presence, not a nonblank Markdown document.
        expect(_enabled(tester, createButton), isTrue);
        for (final (field, label) in [
          ('description', 'Description'),
          ('when-to-use', 'When to Use'),
        ]) {
          final input = _key('record-input-agents-$field');
          expect(tester.widget<TextField>(input).enabled, isTrue);
          expect(_text(tester, input), isEmpty);
          expect(tester.widget<TextField>(input).decoration!.labelText, label);
          await _enter(tester, input, values[field]!);
        }
        final state = await _selectInstructions(tester, 'agents');
        await native_input.insertAtSelection(tester, '```dart');
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await native_input.frames(tester);
        await native_input.insertAtSelection(tester, 'report();');
        await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
        await native_input.frames(tester);
        await native_input.insertAtSelection(tester, 'Review risks');
        state.selection = rich.Selection.single(
          path: [1],
          startOffset: 7,
          endOffset: 12,
        );
        await native_input.frames(tester);
        await native_input.control(tester, LogicalKeyboardKey.keyB);
        await submit(tester, createButton);
        expect(creation.isDisposed, isTrue);
        expect(await stored(), values);
        expect(recordFile.existsSync(), isTrue);
        expect(recordFile.readAsStringSync(), contains('recordType = "$type"'));
        expect(find.text('Reviewer'), findsOneWidget);
        await _tap(tester, find.text('Reviewer'));
        await tester.pumpAndSettle();
        expect(find.text('Collection: agents'), findsOneWidget);
        expect(find.text('Record ID: $id'), findsOneWidget);
        expect(find.text('Record type: $type'), findsOneWidget);
        for (final field in settings.records.definition(type).fields) {
          expect(
            find.text('${field.label}: ${values[field.id.value]}'),
            findsOneWidget,
          );
        }
        expect(find.text('Credentials'), findsNothing);

        await _tap(tester, _key('record-edit-$suffix'));
        await _enter(
          tester,
          _key('record-input-$suffix-name'),
          'Renamed Reviewer',
        );
        await _enter(tester, _key('record-input-$suffix-description'), '');
        final existing = _instructionsOwner(tester, suffix);
        final editing = await _selectInstructions(tester, suffix, offset: 9);
        final code = editing.document.root.children.first;
        expect(code.type, 'code_block');
        expect(code.attributes['language'], 'dart');
        expect(code.delta!.toPlainText(), 'report();');
        await native_input.insertAtSelection(tester, ' // tested');
        await submit(tester, _key('record-save-$suffix'));
        expect(existing.isDisposed, isTrue);
        await _tap(tester, _key('records-reload-agents'));
        await loaded(tester);
        expect(await stored(), {
          'name': 'Renamed Reviewer',
          'when-to-use': values['when-to-use'],
          'instructions': markdown.replaceFirst(
            'report();',
            'report(); // tested',
          ),
        });
        expect(find.text('Renamed Reviewer'), findsOneWidget);
        expect(recordFile.existsSync(), isTrue);
        expect(recordFile.parent.listSync().map((entry) => entry.path), [
          recordFile.path,
        ]);
        await _tap(tester, _key('record-edit-$suffix'));
        final deleted = _instructionsOwner(tester, suffix);
        await _tap(tester, _key('record-delete-$suffix'));
        expect(find.byType(AlertDialog), findsOneWidget);
        await _tap(tester, _key('record-delete-confirm-$suffix'));
        await loaded(tester);
        expect(deleted.isDisposed, isTrue);
        await _tap(tester, _key('records-reload-agents'));
        await loaded(tester);
        expect(_key('record-$suffix'), findsNothing);
        expect(recordFile.existsSync(), isFalse);
        expect(
          find.text('No readable records in this collection.'),
          findsOneWidget,
        );
        expect(File(settings.filePath).existsSync(), isFalse);
        await unmount(tester);
      }),
    );

    for (final (kind, source) in [
      ('supported', '# Review\r\n\r\n~~~dart\r\n  report();  \r\n~~~\r\n'),
      ('unsupported', 'Review ![diagram](agent.png)\r\n\r\nEnd.  \r\n'),
    ]) {
      testWidgets(
        '$kind untouched Markdown survives a no-op and a rename exactly',
        (tester) => tester.runAsync(() async {
          await seedAgent(source);
          final file = agentFile();
          file.writeAsStringSync(
            '\n# Keep unknown data\nfuture = [1, 2]\n',
            mode: FileMode.append,
          );
          final before = file.readAsBytesSync();
          await open(tester);
          await edit(tester);
          final owner = _instructionsOwner(tester, 'agents-reviewer');
          expect(owner.snapshot()['markdown'], source);
          expect(owner.readOnly, kind == 'unsupported');
          if (kind == 'unsupported') {
            final field = _instructions('agents-reviewer');
            expect(
              find.descendant(
                of: field,
                matching: find.byType(rich.AppFlowyEditor),
              ),
              findsNothing,
            );
            expect(
              find.descendant(
                of: field,
                matching: find.textContaining('Read-only Markdown:'),
              ),
              findsOneWidget,
            );
            expect(
              find.descendant(of: field, matching: find.text(source)),
              findsOneWidget,
            );
          } else {
            await _selectInstructions(tester, 'agents-reviewer', offset: 3);
          }
          await submit(tester, saveButton);
          expect(file.readAsBytesSync(), before);
          await _tap(tester, _key('record-edit-agents-reviewer'));
          await _enter(
            tester,
            _key('record-input-agents-reviewer-name'),
            'New name',
          );
          await submit(tester, saveButton);
          expect(await stored(), {'name': 'New name', 'instructions': source});
          expect(
            file.readAsStringSync(),
            contains('# Keep unknown data\nfuture = [1, 2]'),
          );
          await unmount(tester);
        }),
      );
    }

    testWidgets(
      'collapse and section navigation retain native history; Cancel discards only the draft',
      (tester) => tester.runAsync(() async {
        const suffix = 'agents-reviewer';
        await seedAgent('Seed');
        final original = agentFile().readAsBytesSync();
        await open(tester);
        await edit(tester);
        final owner = _instructionsOwner(tester, suffix);
        final state = await _selectInstructions(tester, suffix, offset: 4);
        await native_input.insertAtSelection(tester, '!');
        expect(owner.snapshot()['markdown'], 'Seed!');
        await _richTap(tester, _recordTile('agents', 'reviewer'));
        expect(owner.editingEnabled, isFalse);
        await tester.pumpAndSettle();
        expect(_instructions(suffix), findsNothing);
        expect(tester.testTextInput.hasAnyClients, isFalse);
        await _tap(tester, _recordTile('agents', 'reviewer'));
        await tester.pumpAndSettle();
        expect(_instructionsOwner(tester, suffix), same(owner));
        expect(
          await _selectInstructions(tester, suffix, offset: 5),
          same(state),
        );
        await _richTap(tester, _key('settings-section'));
        await tester.pumpAndSettle();
        await _tap(tester, find.text('Preferences').last);
        await tester.pumpAndSettle();
        expect(_instructions(suffix), findsNothing);
        expect(tester.testTextInput.hasAnyClients, isFalse);
        await _section(tester, 'Agents');
        expect(_instructionsOwner(tester, suffix), same(owner));
        expect(
          await _selectInstructions(tester, suffix, offset: 5),
          same(state),
        );
        await native_input.control(tester, LogicalKeyboardKey.keyZ);
        expect(owner.snapshot()['markdown'], 'Seed');
        await native_input.control(tester, LogicalKeyboardKey.keyY);
        expect(owner.snapshot()['markdown'], 'Seed!');
        await _richTap(tester, _key('record-cancel-$suffix'));
        expect(owner.isDisposed, isTrue);
        expect(state.isDisposed, isTrue);
        expect(settings.updates, 0);
        expect(agentFile().readAsBytesSync(), original);
        await _tap(tester, _key('record-edit-$suffix'));
        final reopened = _instructionsOwner(tester, suffix);
        expect(reopened, isNot(same(owner)));
        expect(reopened.snapshot()['markdown'], 'Seed');
        await _selectInstructions(tester, suffix);
        await _richTap(tester, find.byTooltip('Close Settings'));
        await tester.pumpAndSettle();
        expect(reopened.isDisposed, isTrue);
        expect(tester.testTextInput.hasAnyClients, isFalse);
        expect(agentFile().readAsBytesSync(), original);
        await unmount(tester);
      }),
    );

    testWidgets(
      'a stale Save retains native edits without overwriting disk until confirmed Reload',
      (tester) => tester.runAsync(() async {
        const suffix = 'agents-reviewer';
        await seedAgent('Seed');
        await open(tester);
        await edit(tester);
        final owner = _instructionsOwner(tester, suffix);
        await _selectInstructions(tester, suffix, offset: 4);
        await native_input.insertAtSelection(tester, ' draft');
        final file = agentFile();
        file.writeAsStringSync(
          file.readAsStringSync().replaceFirst('Seed', 'External'),
        );
        final external = file.readAsBytesSync();
        await submit(tester, saveButton);
        expect(
          find.textContaining('this record changed on disk'),
          findsOneWidget,
        );
        expect(_enabled(tester, saveButton), isFalse);
        expect(file.readAsBytesSync(), external);
        expect(owner.isDisposed, isFalse);
        expect(owner.snapshot()['markdown'], 'Seed draft');
        await _tap(tester, _key('records-reload-agents'));
        await _tap(tester, _key('records-reload-cancel-agents'));
        await loaded(tester);
        expect(_instructionsOwner(tester, suffix), same(owner));
        await _tap(tester, _key('records-reload-agents'));
        await _tap(tester, _key('records-reload-confirm-agents'));
        await loaded(tester);
        expect(owner.isDisposed, isTrue);
        await _tap(tester, _key('record-edit-$suffix'));
        expect(
          _instructionsOwner(tester, suffix).snapshot()['markdown'],
          'External',
        );
        expect(file.readAsBytesSync(), external);
        await unmount(tester);
      }),
    );

    testWidgets(
      'IME composition refuses Create, including a previously enabled callback',
      (tester) => tester.runAsync(() async {
        await open(tester);
        await _tap(tester, _key('records-add-agents'));
        final id = await inspectDraftId(tester);
        await _enter(tester, _key('record-input-agents-name'), 'Writer');
        final create = tester
            .widget<ButtonStyleButton>(createButton)
            .onPressed!;
        final owner = _instructionsOwner(tester, 'agents');
        await _selectInstructions(tester, 'agents');
        final composing = await _compose(tester, 'x');
        expect(owner.snapshot()['error'], 'composition_pending');
        expect(_enabled(tester, createButton), isFalse);
        create();
        await native_input.frames(tester);
        expect(find.textContaining('Finish composing'), findsOneWidget);
        expect(settings.creates, 0);
        expect(agentFile(id).existsSync(), isFalse);
        expect(_instructionsOwner(tester, 'agents'), same(owner));
        // Leaving the active form suspends input; it does not commit the IME.
        await _richTap(tester, find.text('Back to records'));
        expect(owner.editingEnabled, isFalse);
        expect(owner.snapshot()['error'], 'composition_pending');
        await _richTap(tester, _key('records-add-agents'));
        expect(_instructionsOwner(tester, 'agents'), same(owner));
        expect(owner.editingEnabled, isTrue);
        expect(_enabled(tester, createButton), isFalse);
        // Reattach input; only an actual settled delta can clear the fence.
        await _selectInstructions(tester, 'agents', offset: 1);
        await native_input.input(tester, composing);
        await native_input.input(
          tester,
          composing.copyWith(composing: TextRange.empty),
        );
        await submit(tester, createButton);
        expect(await stored(), {'name': 'Writer', 'instructions': 'x'});
        expect(agentFile(id).existsSync(), isTrue);
        expect(settings.creates, 1);
        await unmount(tester);
      }),
    );

    testWidgets(
      'unserializable edit refuses Save without writing; native Undo recovers',
      (tester) => tester.runAsync(() async {
        const suffix = 'agents-reviewer';
        await seedAgent('Keep');
        final original = agentFile().readAsBytesSync();
        await open(tester);
        await edit(tester);
        final owner = _instructionsOwner(tester, suffix);
        final state = await _selectInstructions(tester, suffix, offset: 4);
        final save = tester.widget<ButtonStyleButton>(saveButton).onPressed!;
        // Exercise a document attribute the native shortcuts do not offer.
        await state.apply(
          state.transaction..formatText(
            state.document.root.children.single,
            0,
            4,
            {'underline': true},
          ),
        );
        await native_input.frames(tester);
        expect(owner.snapshot, throwsFormatException);
        expect(_enabled(tester, saveButton), isFalse);
        save();
        await native_input.frames(tester);
        expect(find.textContaining('Undo'), findsOneWidget);
        expect(settings.updates, 0);
        expect(agentFile().readAsBytesSync(), original);
        expect(_instructionsOwner(tester, suffix), same(owner));
        await native_input.control(tester, LogicalKeyboardKey.keyZ);
        expect(owner.snapshot()['markdown'], 'Keep');
        await _selectInstructions(tester, suffix, offset: 4);
        await native_input.insertAtSelection(tester, ' safe');
        await submit(tester, saveButton);
        expect(await stored(), {
          'name': 'Reviewer',
          'instructions': 'Keep safe',
        });
        expect(settings.updates, 1);
        await unmount(tester);
      }),
    );
  }, skip: !Platform.isLinux);

  testWidgets(
    'optional Markdown blocks Create during composition; settled edits persist and deleting text omits the field',
    (tester) => tester.runAsync(() async {
      await mount(tester);
      await openRecords(tester);
      await add(tester);
      await _choose(tester, _key('record-type-jobs'), 'Memo');
      final id = await inspectDraftId(tester);
      expect(find.byType(CheckboxListTile), findsNothing);
      final body = tester.widget<InputDecorator>(_input('body')).decoration;
      expect(body.labelText, 'Body (Required)');
      expect(body.enabled, isTrue);
      expect(body.errorText, isNull);
      expect(find.text('Memo text in Markdown.'), findsOneWidget);
      final owner = _instructionsOwner(tester, 'jobs');
      expect(owner.editingEnabled, isTrue);
      final button = _key('record-create-jobs');
      final staleCreate = tester.widget<ButtonStyleButton>(button).onPressed!;
      await _selectInstructions(tester, 'jobs');
      final composing = await _compose(tester, 'x');
      expect(_enabled(tester, button), isFalse);
      staleCreate();
      await native_input.frames(tester);
      expect(find.textContaining('Finish composing'), findsOneWidget);
      expect(service.creates, 0);
      expect(file(id).existsSync(), isFalse);
      await native_input.input(
        tester,
        composing.copyWith(composing: TextRange.empty),
      );
      expect(_enabled(tester, button), isTrue);
      await _richTap(tester, button);
      await _loaded(tester);
      expect(owner.isDisposed, isTrue);
      expect(file(id).existsSync(), isTrue);
      await _tap(tester, _key('records-reload-jobs'));
      await _loaded(tester);
      await _edit(tester, id);
      final editing = _instructionsOwner(tester, 'jobs-$id');
      expect(editing.snapshot()['markdown'], 'x');
      await _selectInstructions(tester, 'jobs-$id', offset: 1);
      await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
      await native_input.frames(tester);
      expect(editing.snapshot()['markdown'], '');
      await native_input.control(tester, LogicalKeyboardKey.keyZ);
      expect(editing.snapshot()['markdown'], 'x');
      await native_input.control(tester, LogicalKeyboardKey.keyY);
      expect(editing.snapshot()['markdown'], '');
      await _richTap(tester, _key('record-save-jobs-$id'));
      await _loaded(tester);
      final saved = (await service.loadRecords(_collection)).records.single;
      expect(saved.id, ConfigurationRecordId(id));
      expect(saved.values, {'body': ''});
      await unmount(tester);
    }),
    skip: !Platform.isLinux,
  );

  testWidgets(
    'explicit clear discards optional Markdown composition and fences the old input client',
    (tester) => tester.runAsync(() async {
      await mount(tester);
      await openRecords(tester);
      await add(tester);
      await _choose(tester, _key('record-type-jobs'), 'Memo');
      final id = await inspectDraftId(tester);
      final suffix = 'jobs-$id';
      await create(tester);
      final original = file(id).readAsBytesSync();
      expect(file(id).readAsStringSync(), isNot(contains('instructions')));
      await _edit(tester, id);
      final save = _key('record-save-$suffix');
      final staleSave = tester.widget<ButtonStyleButton>(save).onPressed!;
      final old = _instructionsOwner(tester, suffix);
      final oldState = await _selectInstructions(tester, suffix);
      final pending = await _compose(tester, 'pending');
      final client = tester.testTextInput.log.lastWhere(
        (call) => call.method == 'TextInput.setClient',
      );
      expect(_enabled(tester, save), isFalse);
      staleSave();
      await native_input.frames(tester);
      expect(service.updates, 0);
      expect(file(id).readAsBytesSync(), original);
      await _richTap(tester, _key('records-reload-jobs'));
      await _tap(tester, _key('records-reload-cancel-jobs'));
      await _loaded(tester);
      expect(old.snapshot()['error'], 'composition_pending');
      await _richTap(tester, _key('record-clear-$suffix-instructions'));
      final fresh = _instructionsOwner(tester, suffix);
      expect(old.isDisposed, isTrue);
      expect(fresh.editingEnabled, isTrue);
      expect(fresh.snapshot()['markdown'], '');
      await _selectInstructions(tester, suffix);
      // A delayed native commit and selection from the retired view cannot
      // restore the discarded text or detach the replacement's input client.
      oldState.selection = rich.Selection.collapsed(
        rich.Position(path: [0], offset: 0),
      );
      await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
        SystemChannels.textInput.name,
        SystemChannels.textInput.codec.encodeMethodCall(
          MethodCall('TextInputClient.updateEditingState', [
            (client.arguments as List).first,
            pending.copyWith(composing: TextRange.empty).toJSON(),
          ]),
        ),
        (_) {},
      );
      await native_input.frames(tester);
      expect(fresh.snapshot()['markdown'], '');
      expect(_enabled(tester, save), isTrue);
      expect(tester.testTextInput.hasAnyClients, isTrue);
      await _richTap(tester, save);
      await _loaded(tester);
      expect(service.updates, 1);
      expect(file(id).readAsBytesSync(), original);
      final saved = (await service.loadRecords(_collection)).records.single;
      expect(saved.values, {'body': ''});
      await unmount(tester);
    }),
    skip: !Platform.isLinux,
  );

  for (final (kind, source) in [
    ('empty', ''),
    ('unsupported', 'See ![diagram](memo.png)\r\n'),
  ]) {
    testWidgets(
      '$kind optional Markdown survives no-op and unrelated saves until explicitly removed',
      (tester) => tester.runAsync(() async {
        const suffix = 'jobs-preserved';
        await service.createRecord(_memo, ConfigurationRecordId('preserved'), {
          'body': '',
          'instructions': source,
        });
        final original = file('preserved').readAsBytesSync();
        await mount(tester);
        await openRecords(tester);
        await _edit(tester, 'preserved');
        final save = _key('record-save-$suffix');
        final editor = _instructionsOwner(tester, suffix);
        expect(editor.snapshot()['markdown'], source);
        expect(editor.readOnly, kind == 'unsupported');
        await _richTap(tester, save);
        await _loaded(tester);
        expect(file('preserved').readAsBytesSync(), original);
        await _tap(tester, _key('record-edit-$suffix'));
        await _selectMarkdown(tester, _editInput('preserved', 'body'));
        await native_input.insertAtSelection(tester, 'Other change');
        await _richTap(tester, save);
        await _loaded(tester);
        await _tap(tester, _key('records-reload-jobs'));
        await _loaded(tester);
        expect(
          find.text(
            'Instructions: ${source.isEmpty ? '(empty string)' : source}',
          ),
          findsOneWidget,
        );
        await _tap(tester, _key('record-edit-$suffix'));
        expect(
          _instructionsOwner(tester, suffix).snapshot()['markdown'],
          source,
        );
        await _richTap(tester, _key('record-clear-$suffix-instructions'));
        expect(_instructionsOwner(tester, suffix).editingEnabled, isTrue);
        await _richTap(tester, save);
        await _loaded(tester);
        final saved = (await service.loadRecords(_collection)).records.single;
        expect(saved.values, {'body': 'Other change'});
        await unmount(tester);
      }),
      skip: !Platform.isLinux,
    );
  }

  testWidgets(
    'Undo recovers an unserializable optional Markdown edit and reverting to absence is clean',
    (tester) => tester.runAsync(() async {
      const suffix = 'jobs-undo';
      await service.createRecord(_memo, ConfigurationRecordId('undo'), {
        'body': '',
      });
      final original = file('undo').readAsBytesSync();
      await mount(tester);
      await openRecords(tester);
      await _edit(tester, 'undo');
      final save = _key('record-save-$suffix');
      final oldSave = tester.widget<ButtonStyleButton>(save).onPressed!;
      final owner = _instructionsOwner(tester, suffix);
      final state = await _selectInstructions(tester, suffix);
      // The native shortcuts do not offer this unrepresentable attribute.
      await state.apply(
        state.transaction..insertText(
          state.document.root.children.single,
          0,
          'x',
          attributes: {'underline': true},
        ),
      );
      await native_input.frames(tester);
      expect(owner.snapshot, throwsFormatException);
      expect(_enabled(tester, save), isFalse);
      oldSave();
      await native_input.frames(tester);
      expect(service.updates, 0);
      expect(file('undo').readAsBytesSync(), original);
      await native_input.control(tester, LogicalKeyboardKey.keyZ);
      expect(owner.snapshot()['markdown'], '');
      expect(_enabled(tester, save), isTrue);
      await _richTap(tester, _key('records-reload-jobs'));
      expect(find.byType(AlertDialog), findsNothing);
      await _loaded(tester);
      expect(service.recordLoads, 2);
      expect(file('undo').readAsBytesSync(), original);
      await unmount(tester);
    }),
    skip: !Platform.isLinux,
  );

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
      expect(find.byType(CheckboxListTile), findsNothing);
      await _enter(
        tester,
        _editInput('original', 'caption'),
        'Renamed\nSecond line',
      );
      await _choose(tester, _editInput('original', 'enabled'), 'True');
      final saveBeforeInvalid = tester
          .widget<ButtonStyleButton>(_key('record-save-jobs-original'))
          .onPressed!;
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
      saveBeforeInvalid();
      await tester.pump();
      expect(
        service.updates,
        1,
      ); // Only the acknowledged no-op reached storage.
      expect(original.readAsBytesSync(), before);
      await _enter(tester, _editInput('original', 'count'), '2');
      await _choose(tester, _editInput('original', 'mode'), 'Expanded label');
      final optionalText = _editInput('original', 'optional-text');
      expect(_text(tester, optionalText), 'remove');
      await _enter(tester, optionalText, '');
      expect(_enabled(tester, _key('record-save-jobs-original')), isTrue);
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
      await _choose(tester, _editInput('original', 'optional-bool'), 'True');
      await _choose(tester, _editInput('original', 'optional-bool'), 'Not set');
      await _choose(tester, _editInput('original', 'optional-enum'), 'Not set');
      await _enter(tester, _editInput('original', 'optional-int'), '');
      await save(tester, 'original');
      expect(find.text('original'), findsOneWidget);
      final saved = (await service.loadRecords(_collection)).records.single;
      expect(saved.id, ConfigurationRecordId('original'));
      expect(saved.type, _job);
      expect(saved.collection, _collection);
      expect(saved.values, {
        'caption': '',
        'enabled': true,
        'count': 2,
        'mode': 'expanded',
      });
      await unmount(tester);
    }),
    skip: !Platform.isLinux,
  );

  testWidgets(
    'an explicitly stored empty text survives other edits; explicit removal is a dirty change',
    (tester) => tester.runAsync(() async {
      const id = 'empty';
      await service.createRecord(_job, ConfigurationRecordId(id), {
        ..._values(),
        'optional-text': '',
      });
      final original = file(id).readAsBytesSync();
      await mount(tester);
      await openRecords(tester);
      await _edit(tester, id);
      final text = _editInput(id, 'optional-text');
      expect(_text(tester, text), isEmpty);
      await save(tester, id);
      expect(file(id).readAsBytesSync(), original);
      await _tap(tester, _key('record-edit-jobs-$id'));
      await _enter(tester, _editInput(id, 'caption'), 'Unrelated');
      await save(tester, id);
      await _tap(tester, _key('records-reload-jobs'));
      await _loaded(tester);
      expect(find.text('Optional text: (empty string)'), findsOneWidget);
      await _tap(tester, _key('record-edit-jobs-$id'));
      await _tap(tester, _key('record-clear-jobs-$id-optional-text'));
      expect(_text(tester, text), isEmpty);
      await _tap(tester, _key('records-reload-jobs'));
      expect(find.text('Reload jobs?'), findsOneWidget);
      await _tap(tester, _key('records-reload-cancel-jobs'));
      await _loaded(tester);
      await save(tester, id);
      final saved = (await service.loadRecords(_collection)).records.single;
      expect(saved.values, _values(caption: 'Unrelated'));
      await unmount(tester);
    }),
    skip: !Platform.isLinux,
  );

  testWidgets(
    'malformed optional integer is dirty; reverting optional controls to absence needs no confirmation',
    (tester) => tester.runAsync(() async {
      const id = 'revert';
      await seed(id);
      final original = file(id).readAsBytesSync();
      await mount(tester);
      await openRecords(tester);
      await _edit(tester, id);
      final save = _key('record-save-jobs-$id');
      final oldSave = tester.widget<ButtonStyleButton>(save).onPressed!;
      final number = _editInput(id, 'optional-int');
      await _enter(tester, number, 'bad');
      expect(_scalarDecoration(tester, number).errorText, isNotNull);
      expect(_enabled(tester, save), isFalse);
      oldSave();
      await tester.pump();
      expect(service.updates, 0);
      final reload = _key('records-reload-jobs');
      await _tap(tester, reload);
      expect(find.text('Reload jobs?'), findsOneWidget);
      await _tap(tester, _key('records-reload-cancel-jobs'));
      await _loaded(tester);
      expect(_text(tester, number), 'bad');
      await _enter(tester, number, '');
      expect(_scalarDecoration(tester, number).errorText, isNull);
      expect(_enabled(tester, save), isTrue);
      final text = _editInput(id, 'optional-text');
      await _enter(tester, text, 'draft');
      await _enter(tester, text, '');
      for (final (field, choice) in [
        ('optional-bool', 'False'),
        ('optional-enum', 'Expanded label'),
      ]) {
        await _choose(tester, _editInput(id, field), choice);
        await _choose(tester, _editInput(id, field), 'Not set');
      }
      await _tap(tester, reload);
      expect(find.byType(AlertDialog), findsNothing);
      await _loaded(tester);
      expect(service.recordLoads, 2);
      expect(file(id).readAsBytesSync(), original);
      await unmount(tester);
    }),
    skip: !Platform.isLinux,
  );

  testWidgets(
    'duplicate display names have distinct, copyable IDs and independent files',
    (tester) => tester.runAsync(() async {
      final copies = <Object?>[];
      final messenger = tester.binding.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.setData') copies.add(call.arguments);
        return null;
      });
      addTearDown(
        () => messenger.setMockMethodCallHandler(SystemChannels.platform, null),
      );
      final application = RecordApplicationProbe(_job);
      await mount(tester, application: application);
      await openRecords(tester);
      const name = 'Duplicate title';
      final copy = find.byTooltip('Copy record ID');
      final ids = <String>[];
      for (var i = 0; i < 2; i++) {
        await add(tester);
        expect(find.textContaining('Record ID:'), findsNothing);
        expect(copy, findsNothing);
        expect(
          find.byWidgetPredicate(
            (w) => w is TextField && w.decoration?.labelText == 'Record ID',
          ),
          findsNothing,
        );
        final id = await inspectDraftId(tester);
        expect(
          ConfigurationRecordId(id).value,
          id,
        ); // The public portable grammar.
        expect(ids, isNot(contains(id)));
        ids.add(id);
        await fillRequired(tester, caption: name);
        await _tap(tester, find.text('Advanced details'));
        await tester.pumpAndSettle();
        expect(find.text('Record ID: $id'), findsOneWidget);
        await _tap(tester, copy);
        expect(copies.last, {'text': id});
        expect(file(id).existsSync(), isFalse);
        await create(tester);
        expect(find.text('Created $name.'), findsOneWidget);
        expect(
          find.textContaining(id),
          findsNothing,
        ); // Includes the row subtitle.
        expect(file(id).readAsStringSync(), contains(name));
      }
      final first = ids.first;
      final second = ids.last;
      expect(find.text(name), findsNWidgets(2));
      final sibling = file(second).readAsBytesSync();
      await _edit(tester, first);
      expect(find.text('Record ID: $first'), findsOneWidget);
      await _tap(tester, copy);
      expect(copies, [
        {'text': first},
        {'text': second},
        {'text': first},
      ]);
      await _enter(tester, _editInput(first, 'caption'), 'Renamed');
      await save(tester, first);
      expect(find.text('Saved Renamed.'), findsOneWidget);
      expect(file(first).readAsStringSync(), contains('Renamed'));
      expect(file(second).readAsBytesSync(), sibling);
      await _tap(tester, _key('record-delete-jobs-$first'));
      expect(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.textContaining('Record ID: $first'),
        ),
        findsOneWidget,
      );
      await _tap(tester, _key('record-delete-confirm-jobs-$first'));
      await _loaded(tester);
      expect(file(first).existsSync(), isFalse);
      expect(file(second).readAsBytesSync(), sibling);
      expect(find.text(name), findsOneWidget);
      expect(application.saves, [
        (_jobKey(first), false),
        (_jobKey(second), false),
        (_jobKey(first), false),
        (_jobKey(first), true),
      ]);
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
        'record-clear-jobs-first',
      ]);
      await _edit(tester, 'second');
      await _enter(tester, _editInput('second', 'caption'), 'Second draft');
      await add(tester);
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
      await add(tester);
      await _choose(tester, _key('record-type-jobs'), 'Note');
      await create(tester);
      expect(find.text('Created Note.'), findsOneWidget);
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
      await mount(tester);
      await openRecords(tester);
      await add(tester);
      await _choose(tester, _key('record-type-jobs'), 'Note');
      final id = await inspectDraftId(tester);
      await seed(id);
      await _tap(tester, _key('records-reload-jobs'));
      await _loaded(tester);
      await _edit(tester, id);
      final caption = _editInput(id, 'caption');
      await _enter(tester, caption, 'Existing dirty draft');
      final existing = tester.widget<TextField>(caption).controller;
      file(id).deleteSync(); // The UI still holds a live row and dirty draft.
      if (_enabled(tester, _key('record-create-jobs'))) {
        await create(tester);
        expect(find.textContaining('no write was attempted'), findsOneWidget);
      }
      expect(service.creates, 1); // Only the original seed was admitted.
      expect(file(id).existsSync(), isFalse);
      expect(_key('record-jobs-$id'), findsOneWidget);
      expect(tester.widget<TextField>(caption).controller, same(existing));
      expect(existing!.text, 'Existing dirty draft');
      await _tap(tester, _key('records-reload-jobs'));
      await _tap(tester, _key('records-reload-confirm-jobs'));
      await _loaded(tester);
      expect(_key('record-jobs-$id'), findsNothing);
      expect(await inspectDraftId(tester), id);
      expect(_enabled(tester, _key('record-create-jobs')), isTrue);
      await create(tester);
      expect(_key('record-jobs-$id'), findsOneWidget);
      expect(file(id).readAsStringSync(), contains('recordType = "$_note"'));
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
      await add(tester);
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
      expect(find.text('Deleted Same title.'), findsOneWidget);
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
          final application = RecordApplicationProbe(_job);
          application.report(
            _jobKey('uncertain'),
            const RecordApplyOutcome(RecordApplyStatus.applied, 'added'),
          );
          await mount(tester, application: application);
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
          expect(application.saves, isEmpty);
          expect(find.text('Runtime application: Applied'), findsNothing);
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
          expect(application.saves, [(_jobKey('independent'), false)]);
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
        final application = RecordApplicationProbe(_job);
        await mount(tester, application: application);
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
          expect(application.saves, isEmpty);
          expect(application.observed, isFalse);
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
        await _until(tester, () => application.saves.isNotEmpty);
        expect(application.saves, [(_jobKey('after-close'), deleting)]);
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
    'required controls validate immediately; optional inputs persist only supplied values',
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
        await add(tester);
        final requiredId = await inspectDraftId(tester);
        for (final (field, label) in [
          ('caption', 'Caption'),
          ('enabled', 'Enabled'),
          ('count', 'Count'),
          ('mode', 'Mode'),
        ]) {
          final decoration = _scalarDecoration(tester, _input(field));
          expect(decoration.labelText, '$label (Required)');
          expect(find.text('Help for $label.'), findsOneWidget);
          // All three unset typed fields report their own error at the same time.
          expect(
            decoration.errorText,
            field == 'caption' ? isNull : isNotEmpty,
            reason: label,
          );
        }
        const optional = [
          'optional-text',
          'optional-bool',
          'optional-int',
          'optional-enum',
        ];
        expect(find.byType(CheckboxListTile), findsNothing);
        for (final field in optional) {
          expect(_scalarDecoration(tester, _input(field)).errorText, isNull);
        }
        for (final field in [
          'caption',
          'count',
          'optional-text',
          'optional-int',
        ]) {
          final input = tester.widget<TextField>(_input(field));
          expect(input.enabled, isTrue);
          expect(input.controller!.text, '');
        }
        for (final field in ['optional-bool', 'optional-enum']) {
          expect(
            find.descendant(of: _input(field), matching: find.text('Not set')),
            findsOneWidget,
          );
        }
        final boolean = tester.widget<DropdownButton<bool>>(_input('enabled'));
        final enumeration = tester.widget<DropdownButton<String>>(
          _input('mode'),
        );
        expect(boolean.onChanged, isNotNull);
        expect(enumeration.onChanged, isNotNull);
        expect(boolean.value, isNull);
        expect(enumeration.value, isNull);
        expect(
          boolean.items!.map((item) => item.value),
          unorderedEquals([true, false]),
        );
        expect(enumeration.items!.map((item) => item.value), [
          'compact',
          'expanded',
        ]);
        expect(_enabled(tester, _key('record-create-jobs')), isFalse);
        await _choose(tester, _input('enabled'), 'False');
        expect(_scalarDecoration(tester, _input('enabled')).errorText, isNull);
        for (final invalid in ['', '1.5', '-1', '3', '9223372036854775808']) {
          await _enter(tester, _input('count'), invalid);
          expect(
            tester.widget<TextField>(_input('count')).decoration!.errorText,
            isNotNull,
          );
          expect(_enabled(tester, _key('record-create-jobs')), isFalse);
        }
        await _enter(tester, _input('count'), '0');
        expect(_scalarDecoration(tester, _input('count')).errorText, isNull);
        expect(
          tester.widget<DropdownButton<String>>(_input('mode')).value,
          isNull,
        );
        expect(_enabled(tester, _key('record-create-jobs')), isFalse);
        await _choose(tester, _input('mode'), 'Compact label');
        expect(_scalarDecoration(tester, _input('mode')).errorText, isNull);
        expect(_enabled(tester, _key('record-create-jobs')), isTrue);
        expect(await inspectDraftId(tester), requiredId);
        expect(service.creates, 0);
        expect(file(requiredId).existsSync(), isFalse);
        await create(tester);
        final saved = (await service.loadRecords(_collection)).records.single;
        expect(saved.id, ConfigurationRecordId(requiredId));
        expect(saved.values, {
          'caption': '',
          'enabled': false,
          'count': 0,
          'mode': 'compact',
        });
        expect(find.text(requiredId), findsOneWidget);
        expect(find.text('Created Job.'), findsOneWidget);
        expect(
          file(requiredId).readAsStringSync(),
          isNot(contains('Compact label')),
        );
        expect(
          file(requiredId).readAsStringSync(),
          isNot(contains('optional')),
        );
        expect(File(service.filePath).existsSync(), isFalse);

        await add(tester);
        final explicitId = await inspectDraftId(tester);
        await fillRequired(tester, caption: 'Two lines\nSecond line');
        final button = _key('record-create-jobs');
        final staleCreate = tester.widget<ButtonStyleButton>(button).onPressed!;
        for (final invalid in [
          'not a number',
          '1.5',
          '-1',
          '3',
          '9223372036854775808',
        ]) {
          await _enter(tester, _input('optional-int'), invalid);
          expect(
            _scalarDecoration(tester, _input('optional-int')).errorText,
            isNotNull,
            reason: invalid,
          );
          expect(_enabled(tester, button), isFalse);
        }
        staleCreate();
        await tester.pump();
        expect(service.creates, 1);
        expect(file(explicitId).existsSync(), isFalse);
        await _enter(tester, _input('optional-int'), '');
        expect(
          _scalarDecoration(tester, _input('optional-int')).errorText,
          isNull,
        );
        expect(_enabled(tester, button), isTrue);
        const whitespace = ' \t ';
        await _enter(tester, _input('optional-text'), whitespace);
        await _choose(tester, _input('optional-bool'), 'False');
        await _enter(tester, _input('optional-int'), '0');
        await _choose(tester, _input('optional-enum'), 'Expanded label');
        await create(tester);
        final explicit = (await service.loadRecords(
          _collection,
        )).records.firstWhere((r) => r.id.value == explicitId);
        expect(explicit.values, {
          'caption': 'Two lines\nSecond line',
          'enabled': false,
          'count': 0,
          'mode': 'compact',
          'optional-text': whitespace,
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
      await add(tester);
      final jobId = await inspectDraftId(tester);
      await _enter(tester, _input('caption'), 'Retained record');
      final recordElement = tester.element(_input('caption'));
      final recordController = tester
          .widget<TextField>(_input('caption'))
          .controller;
      await _choose(tester, _key('record-type-jobs'), 'Note');
      final noteId = await inspectDraftId(tester);
      expect(noteId, isNot(jobId));
      await _enter(tester, _input('display-name'), 'Note draft');
      await _choose(tester, _key('record-type-jobs'), 'Job');
      expect(tester.element(_input('caption')), same(recordElement));
      expect(
        tester.widget<TextField>(_input('caption')).controller,
        same(recordController),
      );
      expect(recordController!.text, 'Retained record');
      expect(await inspectDraftId(tester), jobId);
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
      expect(await inspectDraftId(tester), jobId);
      await _tap(tester, find.text('Back to records'));
      await add(tester);
      expect(await inspectDraftId(tester), jobId);
      await _choose(tester, _key('record-type-jobs'), 'Note');
      expect(await inspectDraftId(tester), noteId);
      expect(_text(tester, _input('display-name')), 'Note draft');
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
    'type switching fences old controls and sibling creation retains the other draft',
    (tester) {
      return tester.runAsync(() async {
        await mount(tester);
        await openRecords(tester);
        await add(tester);
        final jobId = await inspectDraftId(tester);
        await _enter(
          tester,
          _input('optional-text'),
          'Retained optional value',
        );
        await fillRequired(tester, caption: 'Retained across sibling creation');
        final element = tester.element(_input('caption'));
        final controller = tester
            .widget<TextField>(_input('caption'))
            .controller;
        final oldBoolean = tester
            .widget<DropdownButton<bool>>(_input('enabled'))
            .onChanged!;
        final oldMode = tester
            .widget<DropdownButton<String>>(_input('mode'))
            .onChanged!;
        final oldCreate = tester
            .widget<ButtonStyleButton>(_key('record-create-jobs'))
            .onPressed!;
        final selectType = tester
            .widget<DropdownButtonFormField<RecordTypeId>>(
              _key('record-type-jobs'),
            )
            .onChanged!;
        selectType(_note);
        oldBoolean(true);
        selectType(_job);
        oldMode('expanded');
        oldCreate();
        expect(service.creates, 0);
        await tester.pump();
        expect(
          tester.widget<DropdownButton<bool>>(_input('enabled')).value,
          isFalse,
        );
        expect(
          tester.widget<DropdownButton<String>>(_input('mode')).value,
          'compact',
        );
        await _choose(tester, _key('record-type-jobs'), 'Note');
        final noteId = await inspectDraftId(tester);
        await create(tester);
        expect(file(noteId).existsSync(), isTrue);
        await _tap(tester, _key('records-add-jobs'));
        expect(await inspectDraftId(tester), isNot(noteId));
        await _choose(tester, _key('record-type-jobs'), 'Job');
        expect(tester.element(_input('caption')), same(element));
        expect(
          tester.widget<TextField>(_input('caption')).controller,
          same(controller),
        );
        expect(controller!.text, 'Retained across sibling creation');
        expect(await inspectDraftId(tester), jobId);
        expect(
          _text(tester, _input('optional-text')),
          'Retained optional value',
        );
        expect(file(jobId).existsSync(), isFalse);
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
        await add(tester);
        await _enter(tester, _input('caption'), 'Keep this');
        await _section(tester, 'Preferences');
        await _expectNoFocus(tester, ['record-', 'records-']);
        await openRecords(tester);
        await _choose(tester, _key('record-type-jobs'), 'Note');
        await _expectNoFocus(tester, [
          'setting-',
          'record-input-jobs-caption',
          'record-input-jobs-optional-',
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
          'recordVersion = 2\nrecordId = "unknown"\nrecordType = "dev.missing.type"\n[values]\n',
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
        await add(tester);
        final id = await inspectDraftId(tester);
        await fillRequired(tester);
        await create(tester);
        expect(file(id).existsSync(), isTrue);
        expect(File(service.filePath).readAsStringSync(), 'broken = [\n');
        await unmount(tester);
      });
    },
    skip: !Platform.isLinux,
  );

  testWidgets(
    'narrow creation remains reachable after clearing an optional input',
    (tester) {
      return tester.runAsync(() async {
        await mount(tester);
        await openRecords(tester);
        await tester.binding.setSurfaceSize(const Size(400, 700));
        await tester.pumpAndSettle();
        await add(tester);
        await fillRequired(tester, caption: 'Narrow-screen draft');
        await _enter(tester, _input('optional-text'), 'Remove before creating');
        await _enter(tester, _input('optional-text'), '');
        expect(
          tester.widget<TextField>(_input('optional-text')).enabled,
          isTrue,
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

  group('declared creation filename', () {
    final button = _key('record-create-jobs');
    final source = _input('subject');
    final title = _input('title');

    Future<String> start(WidgetTester tester) async {
      await add(tester);
      await _choose(tester, _key('record-type-jobs'), 'Named document');
      return inspectDraftId(tester);
    }

    Future<void> reload(WidgetTester tester) async {
      await _tap(tester, _key('records-reload-jobs'));
      await _loaded(tester);
    }

    testWidgets(
      'field feedback uses observed filenames, not display titles or IDs',
      (tester) => tester.runAsync(() async {
        await seed('legacy', caption: 'Shared title');
        final occupied = file('legacy').renameSync(file('taken').path);
        final original = occupied.readAsBytesSync();
        file('broken').writeAsStringSync('broken = [');
        File('${occupied.parent.path}/ALIAS.TOML. ').writeAsStringSync('alias');
        await mount(tester);
        await openRecords(tester);
        final id = await start(tester);
        await _enter(tester, title, 'Shared title');
        await _enter(tester, source, 'Shared title');
        final staleCreate = tester.widget<ButtonStyleButton>(button).onPressed!;
        for (final input in ['---', 'con', '9 bad', 'line\nbreak']) {
          await _enter(tester, source, input);
          expect(_scalarDecoration(tester, source).errorText, isNotEmpty);
          expect(_enabled(tester, button), isFalse);
          staleCreate();
        }
        for (final input in ['Taken!', 'broken', 'Alias']) {
          await _enter(tester, source, input);
          expect(
            _scalarDecoration(tester, source).errorText,
            contains('in use'),
          );
          expect(_scalarDecoration(tester, title).errorText, isNull);
          expect(_enabled(tester, button), isFalse);
          staleCreate();
        }
        expect(service.creates, 1); // Only the seed reached the worker.
        expect(occupied.readAsBytesSync(), original);
        await _enter(tester, source, '  Current / Name  ');
        expect(_text(tester, title), 'Shared title');
        expect(await inspectDraftId(tester), id);
        expect(find.textContaining('current-name.toml'), findsNothing);
        await create(tester);
        final created = file('current-name');
        expect(created.readAsStringSync(), contains('recordId = "$id"'));
        expect(
          created.readAsStringSync(),
          contains('subject = "  Current / Name  "'),
        );
        expect(file(id).existsSync(), isFalse);
        expect(service.recordLoads, 1);
        expect(find.text('Shared title'), findsNWidgets(2));

        // Filename derivation is not validation of an existing record's fields.
        await _edit(tester, id);
        await _enter(tester, _editInput(id, 'subject'), '???');
        await save(tester, id);
        expect(created.readAsStringSync(), contains('subject = "???"'));
        await reload(tester);
        expect(_key('record-jobs-$id'), findsOneWidget);
        await _tap(tester, _key('record-delete-jobs-$id'));
        await _tap(tester, _key('record-delete-confirm-jobs-$id'));
        await _loaded(tester);
        expect(created.existsSync(), isFalse);
        await add(tester);
        final replacement = await inspectDraftId(tester);
        expect(replacement, isNot(id));
        await _enter(tester, title, 'Shared title');
        await _enter(tester, source, 'Current Name');
        await create(tester);
        expect(
          created.readAsStringSync(),
          contains('recordId = "$replacement"'),
        );
        await unmount(tester);
      }),
    );

    testWidgets(
      'newly discovered filename conflict allows correction only after Reload',
      (tester) => tester.runAsync(() async {
        await mount(tester);
        await openRecords(tester);
        final id = await start(tester);
        await _enter(tester, title, 'Keep this title');
        await _enter(tester, source, 'External');
        final staleCreate = tester.widget<ButtonStyleButton>(button).onPressed!;
        // No readable header. The explicit conflict still proves this call
        // did not publish, unlike an uncertain response for the same target.
        final occupant = file('external');
        occupant.parent.createSync(recursive: true);
        occupant.writeAsStringSync('broken = [');
        await create(tester);
        expect(find.textContaining('Not created:'), findsOneWidget);
        expect(_enabled(tester, button), isFalse);
        expect(_enabled(tester, _discardDraft), isFalse);
        staleCreate();
        expect(service.creates, 1);
        await reload(tester);
        expect(_scalarDecoration(tester, source).errorText, contains('in use'));
        await _enter(tester, source, 'New location');
        expect(_enabled(tester, button), isTrue);
        staleCreate();
        expect(service.creates, 1);
        expect(_text(tester, title), 'Keep this title');
        expect(await inspectDraftId(tester), id);
        await create(tester);
        expect(occupant.readAsStringSync(), 'broken = [');
        expect(
          file('new-location').readAsStringSync(),
          contains('recordId = "$id"'),
        );
        await unmount(tester);
      }),
    );

    testWidgets(
      'uncertain creation reconciles the submitted ID and target, not the edited name',
      (tester) => tester.runAsync(() async {
        final application = RecordApplicationProbe(_named);
        await mount(tester, application: application);
        await openRecords(tester);
        final id = await start(tester);
        await _enter(tester, title, 'Retained');
        await _enter(tester, source, 'First place');
        final staleCreate = tester.widget<ButtonStyleButton>(button).onPressed!;
        service.loseAcknowledgement = true;
        await create(tester);
        service.loseAcknowledgement = false;
        expect(
          find.textContaining('Could not confirm creation'),
          findsOneWidget,
        );
        expect(application.saves, isEmpty);
        final target = file('first-place');
        final moved = target.renameSync(file('elsewhere').path);
        await reload(tester);
        expect(_key('record-jobs-$id'), findsOneWidget);
        expect(_enabled(tester, button), isFalse);
        await _enter(tester, source, 'Second place');
        expect(_enabled(tester, button), isFalse);

        // The current candidate is free and no readable record claims the ID.
        // The attempted physical name still has an unidentified occupant.
        moved.deleteSync();
        final alias = File('${target.parent.path}/FIRST-PLACE.TOML');
        alias.writeAsStringSync('unknown occupant');
        await reload(tester);
        expect(_key('record-jobs-$id'), findsNothing);
        expect(
          find.textContaining('could not identify the occupant'),
          findsOneWidget,
        );
        expect(_scalarDecoration(tester, source).errorText, isNull);
        expect(_enabled(tester, button), isFalse);
        expect(_enabled(tester, _discardDraft), isTrue);
        staleCreate();
        expect(service.creates, 1);

        // A readable occupant with a different ID resolves that uncertainty.
        alias.deleteSync();
        await seed('first-place');
        await reload(tester);
        expect(_enabled(tester, button), isTrue);
        expect(file('second-place').existsSync(), isFalse);
        expect(_text(tester, title), 'Retained');
        expect(await inspectDraftId(tester), id);
        expect(application.saves, isEmpty);
        await create(tester);
        expect(service.creates, 3); // Two submissions and the external seed.
        expect(
          file('second-place').readAsStringSync(),
          contains('recordId = "$id"'),
        );
        expect(application.saves, hasLength(1));
        await unmount(tester);
      }),
    );
  }, skip: !Platform.isLinux);

  for (final malformed in [false, true]) {
    testWidgets(
      'filesystem conflict with ${malformed ? 'an unreadable' : 'a readable'} occupant keeps the draft until explicit discard',
      (tester) => tester.runAsync(() async {
        await mount(tester);
        await openRecords(tester);
        await add(tester);
        final id = await inspectDraftId(tester);
        await fillRequired(tester, caption: 'Unsaved title');
        final button = _key('record-create-jobs');
        final staleCreate = tester.widget<ButtonStyleButton>(button).onPressed!;
        final occupant = file(id);
        if (malformed) {
          occupant.parent.createSync(recursive: true);
          occupant.writeAsStringSync('broken = [\n');
        } else {
          await service.createRecord(_note, ConfigurationRecordId(id), {
            'display-name': 'Existing note',
          });
        }
        final before = occupant.readAsBytesSync();
        final seedWrites = service.creates;
        await create(tester);
        expect(find.textContaining('Not created:'), findsOneWidget);
        expect(service.creates, seedWrites + 1); // Reached the real writer.
        expect(occupant.readAsBytesSync(), before);
        expect(_enabled(tester, button), isFalse);
        expect(_enabled(tester, _discardDraft), isFalse);
        expect(await inspectDraftId(tester), id);
        await _tap(tester, _key('records-reload-jobs'));
        await _loaded(tester);
        expect(_text(tester, _input('caption')), 'Unsaved title');
        expect(await inspectDraftId(tester), id);
        expect(_enabled(tester, _discardDraft), isTrue);
        if (malformed) {
          expect(find.textContaining('$id.toml:'), findsOneWidget);
          // The diagnosed entry is still occupied in the loaded view. A stale
          // callback must not recreate its file even if it now disappears.
          occupant.deleteSync();
          staleCreate();
          await _loaded(tester);
          expect(occupant.existsSync(), isFalse);
          occupant.writeAsBytesSync(before);
        } else {
          expect(_key('record-jobs-$id'), findsOneWidget);
        }
        expect(service.creates, seedWrites + 1);
        await _choose(tester, _key('record-type-jobs'), 'Note');
        expect(_enabled(tester, _discardDraft), isFalse);
        await _choose(tester, _key('record-type-jobs'), 'Job');
        expect(await inspectDraftId(tester), id);
        await _tap(tester, _discardDraft);
        final freshId = await inspectDraftId(tester);
        expect(freshId, isNot(id));
        expect(_enabled(tester, _discardDraft), isFalse);
        expect(_text(tester, _input('caption')), isEmpty);
        expect(_enabled(tester, button), isFalse);
        await fillRequired(tester, caption: 'New draft');
        staleCreate();
        await tester.pump();
        expect(service.creates, seedWrites + 1);
        expect(file(freshId).existsSync(), isFalse);
        await create(tester);
        expect(file(freshId).readAsStringSync(), contains('New draft'));
        expect(occupant.readAsBytesSync(), before);
        await unmount(tester);
      }),
      skip: !Platform.isLinux,
    );
  }

  for (final lostAcknowledgement in [false, true]) {
    testWidgets(
      'unconfirmed ${lostAcknowledgement ? 'published' : 'failed'} creation requires Reload without losing draft',
      (tester) {
        return tester.runAsync(() async {
          final application = RecordApplicationProbe(_job);
          await mount(tester, application: application);
          await openRecords(tester);
          await add(tester);
          final id = await inspectDraftId(tester);
          const caption = 'Retained uncertain draft';
          await fillRequired(tester, caption: caption);
          final button = _key('record-create-jobs');
          final staleCreate = tester
              .widget<ButtonStyleButton>(button)
              .onPressed!;
          expect(_enabled(tester, _discardDraft), isFalse);
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
          expect(find.text('Created $caption.'), findsNothing);
          expect(_key('record-jobs-$id'), findsNothing);
          expect(file(id).existsSync(), lostAcknowledgement);
          expect(_enabled(tester, button), isFalse);
          expect(_enabled(tester, _discardDraft), isFalse);
          expect(_text(tester, _input('caption')), caption);
          expect(await inspectDraftId(tester), id);
          if (!lostAcknowledgement) File(roots.localStateRoot).deleteSync();
          service.loseAcknowledgement = false;
          service.failNextLoad = true;
          await _tap(tester, _key('records-reload-jobs'));
          await _loaded(tester);
          expect(find.textContaining('Could not load records'), findsOneWidget);
          expect(_enabled(tester, button), isFalse);
          expect(_enabled(tester, _discardDraft), isFalse);
          staleCreate();
          await tester.pump();
          expect(service.creates, 1);
          await _tap(tester, _key('records-reload-jobs'));
          await _loaded(tester);
          expect(_text(tester, _input('caption')), caption);
          expect(await inspectDraftId(tester), id);
          expect(_enabled(tester, _discardDraft), isTrue);
          expect(
            _key('record-jobs-$id'),
            lostAcknowledgement ? findsOneWidget : findsNothing,
          );
          expect(service.creates, 1);
          expect(application.saves, isEmpty);
          if (lostAcknowledgement) {
            final published = file(id).readAsBytesSync();
            await _tap(tester, _discardDraft);
            expect(await inspectDraftId(tester), isNot(id));
            expect(_text(tester, _input('caption')), isEmpty);
            expect(service.creates, 1);
            expect(file(id).readAsBytesSync(), published);
          } else {
            expect(_enabled(tester, button), isTrue);
            await create(tester);
            expect(application.saves, [(_jobKey(id), false)]);
            expect(file(id).readAsStringSync(), contains(caption));
            expect(service.creates, 2);
          }
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
        final application = RecordApplicationProbe(_job);
        await mount(tester, application: application);
        await openRecords(tester);
        await add(tester);
        final requestedId = await inspectDraftId(tester);
        await fillRequired(tester, caption: 'Requested title');
        service.returnDifferentPersistedRecord = true;
        service.failNextLoad = true;
        await create(tester);
        expect(application.saves, [(_jobKey('actual-id'), false)]);
        expect(find.text('Created Actual persisted title.'), findsOneWidget);
        expect(find.text('Actual persisted title'), findsOneWidget);
        expect(service.recordLoads, 1);
        expect(find.textContaining('Could not confirm creation'), findsNothing);
        expect(_key('record-jobs-actual-id'), findsOneWidget);
        expect(file('actual-id').existsSync(), isTrue);
        expect(file(requestedId).existsSync(), isFalse);
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
        final application = RecordApplicationProbe(_job);
        await mount(tester, application: application);
        await openRecords(tester);
        await add(tester);
        final id = await inspectDraftId(tester);
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
        void reenterOnAcknowledgement() {
          application.removeListener(reenterOnAcknowledgement);
          commit();
          reload();
        }

        application.addListener(reenterOnAcknowledgement);
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
        expect(application.saves, [(_jobKey(id), false)]);
        expect(file(id).existsSync(), isTrue);
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
        await add(tester);
        final id = await inspectDraftId(tester);
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
        expect(file(id).existsSync(), isFalse);
        await unmount(tester);
      });
    },
  );

  testWidgets(
    'closing pending creation leaves its admitted native write intact',
    (tester) {
      return tester.runAsync(() async {
        final application = RecordApplicationProbe(_job);
        await mount(tester, application: application);
        await openRecords(tester);
        await add(tester);
        final id = await inspectDraftId(tester);
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
        await _until(
          tester,
          () => file(id).existsSync() && application.saves.isNotEmpty,
        );
        expect(application.saves, [(_jobKey(id), false)]);
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

RecordApplyKey _jobKey(String id) =>
    (collection: _collection, type: _job, id: ConfigurationRecordId(id));

// Shared by the two Settings widget suites. Persistence and credential workflows
// stay real; only independent runtime notifications and requests are controlled.
final class RecordApplicationProbe extends ChangeNotifier
    implements RecordApplication {
  RecordApplicationProbe(this.type);
  final RecordTypeId type;
  final saves = <(RecordApplyKey, bool)>[];
  final retries = <RecordApplyKey>[];
  final reconciliations = <RecordApplyKey>[];
  final _outcomes =
      <RecordApplyKey, ({RecordApplyOutcome outcome, bool deleted})>{};
  RecordApplyKey? _deletion;
  bool get observed => hasListeners;

  void report(RecordApplyKey key, RecordApplyOutcome outcome, {bool? deleted}) {
    _outcomes[key] = (
      outcome: outcome,
      deleted: deleted ?? _outcomes[key]?.deleted ?? false,
    );
    notifyListeners();
  }

  @override
  bool supports(RecordApplyKey key) => key.type == type;
  @override
  void unconfirmed(RecordApplyKey key) {
    _outcomes.remove(key);
    if (_deletion == key) _deletion = null;
    notifyListeners();
  }

  @override
  RecordApplyOutcome? outcome(RecordApplyKey key, {bool? deleted}) {
    final entry = _outcomes[key];
    return deleted == null || deleted == entry?.deleted ? entry?.outcome : null;
  }

  @override
  RecordApplyKey? recentDeletion(RecordCollectionId collection) =>
      _deletion?.collection == collection ? _deletion : null;

  @override
  void saved(RecordApplyKey key, {bool deleted = false}) {
    saves.add((key, deleted));
    if (deleted) {
      _deletion = key;
    } else if (_deletion == key) {
      _deletion = null;
    }
    report(
      key,
      const RecordApplyOutcome(RecordApplyStatus.applying, 'pending'),
      deleted: deleted,
    );
  }

  @override
  void retry(RecordApplyKey key) {
    retries.add(key);
    report(
      key,
      const RecordApplyOutcome(RecordApplyStatus.applying, 'pending'),
    );
  }

  @override
  void reconciled(RecordApplyKey key) {
    reconciliations.add(key);
    if (_deletion == key) _deletion = null;
    report(
      key,
      const RecordApplyOutcome(RecordApplyStatus.notApplied, 'reconciled'),
      deleted: false,
    );
  }
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
    description: required ? 'Help for $label.' : null,
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
        field(
          'optional-int',
          'Optional integer',
          IntegerSettingType(minimum: 0, maximum: 2),
        ),
        field('optional-enum', 'Optional enumeration', enumeration),
      ],
    ),
    RecordTypeDefinition(
      id: _memo,
      owner: PluginId('dev.example.records'),
      collection: _collection,
      collectionLabel: 'Jobs',
      label: 'Memo',
      fields: [
        RecordFieldDefinition(
          id: RecordFieldId('body'),
          label: 'Body',
          description: 'Memo text in Markdown.',
          type: const StringSettingType(),
          required: true,
          editor: RecordFieldEditor.markdown,
        ),
        RecordFieldDefinition(
          id: RecordFieldId('instructions'),
          label: 'Instructions',
          type: const StringSettingType(),
          required: false,
          editor: RecordFieldEditor.markdown,
        ),
      ],
    ),
    RecordTypeDefinition(
      id: _named,
      owner: PluginId('dev.example.records'),
      collection: _collection,
      collectionLabel: 'Jobs',
      label: 'Named document',
      displayField: RecordFieldId('title'),
      filenameField: RecordFieldId('subject'),
      fields: [
        field('title', 'Title', const StringSettingType(), required: true),
        field('subject', 'Subject', const StringSettingType(), required: true),
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
Finder get _discardDraft => find.ancestor(
  of: find.text('Discard and start new draft'),
  matching: find.bySubtype<ButtonStyleButton>(),
);
String _text(WidgetTester tester, Finder input) =>
    tester.widget<TextField>(input).controller!.text;

InputDecoration _scalarDecoration(WidgetTester tester, Finder input) {
  final control = tester.widget(input);
  if (control case TextField(decoration: final decoration?)) return decoration;
  return tester
      .widget<InputDecorator>(
        find.ancestor(of: input, matching: find.byType(InputDecorator)),
      )
      .decoration;
}

Finder _input(String field) => _key('record-input-jobs-$field');
Finder _editInput(String id, String field) =>
    _key('record-input-jobs-$id-$field');

Finder _instructions(String suffix) =>
    _key('record-input-$suffix-instructions');

NativeRichDocumentEditor _instructionsOwner(
  WidgetTester tester,
  String suffix,
) => tester
    .widget<NativeRichDocumentEditorView>(
      find.descendant(
        of: _instructions(suffix),
        matching: find.byType(NativeRichDocumentEditorView),
      ),
    )
    .editor;

Future<rich.EditorState> _selectInstructions(
  WidgetTester tester,
  String suffix, {
  int offset = 0,
}) => _selectMarkdown(tester, _instructions(suffix), offset: offset);

Future<rich.EditorState> _selectMarkdown(
  WidgetTester tester,
  Finder field, {
  int offset = 0,
}) async {
  await tester.ensureVisible(field);
  await native_input.frames(tester);
  final editor = tester.widget<rich.AppFlowyEditor>(
    find.descendant(of: field, matching: find.byType(rich.AppFlowyEditor)),
  );
  editor.focusNode!.requestFocus();
  editor.editorState.selection = rich.Selection.collapsed(
    rich.Position(path: [0], offset: offset),
  );
  await native_input.frames(tester);
  expect(tester.testTextInput.hasAnyClients, isTrue);
  return editor.editorState;
}

Future<TextEditingValue> _compose(WidgetTester tester, String text) async {
  final initial = TextEditingValue.fromJSON(tester.testTextInput.editingState!);
  final start = initial.selection.start;
  final end = start + text.length;
  final composing = TextEditingValue(
    text: initial.text.replaceRange(start, initial.selection.end, text),
    selection: TextSelection.collapsed(offset: end),
    composing: TextRange(start: start, end: end),
  );
  await native_input.input(tester, composing);
  return composing;
}

// A focused native caret may keep scheduling frames while we scroll to the action.
Future<void> _richTap(WidgetTester tester, Finder target) async {
  await tester.ensureVisible(target);
  await native_input.frames(tester);
  await tester.tap(target);
  await native_input.frames(tester);
}

Finder _recordTile(String collection, String id) => find
    .descendant(
      of: _key('record-$collection-$id'),
      matching: find.byType(ListTile),
    )
    .first;

Future<void> _expand(
  WidgetTester tester,
  String id, {
  String collection = 'jobs',
}) async {
  await _tap(tester, _recordTile(collection, id));
  await tester.pumpAndSettle();
}

Future<void> _edit(
  WidgetTester tester,
  String id, {
  String collection = 'jobs',
}) async {
  await _expand(tester, id, collection: collection);
  await _tap(tester, _key('record-edit-$collection-$id'));
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
