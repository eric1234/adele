import 'dart:async';
import 'dart:io';

import 'package:adele_capabilities/adele_capabilities.dart';
import 'package:adele_desktop/core/application_plugin_bootstrap.dart';
import 'package:adele_desktop/core/global_settings_service.dart';
import 'package:adele_desktop/core/model_catalog_choices.dart';
import 'package:adele_desktop/core/model_provider_choices.dart';
import 'package:adele_desktop/core/record_apply_coordinator.dart';
import 'package:adele_desktop/editor/native_rich_document_editor.dart';
import 'package:adele_desktop/ui/settings/global_settings_dialog.dart';
import 'package:adele_model_provider/adele_model_catalog.dart';
import 'package:adele_model_provider/adele_model_provider.dart'
    show ModelReasoningEffort;
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

final _collection = RecordCollectionId('jobs');
final _job = RecordTypeId('dev.example.records.job');
final _note = RecordTypeId('dev.example.records.note');
const _preference = 'dev.example.records.message';
const ModelProviderChoice _firstProvider = (
  id: 'dev.example.inference.route-7',
  displayName: 'Workspace provider',
  pluginId: 'dev.example.local',
);
const ModelProviderChoice _secondProvider = (
  id: 'dev.example.inference.account-42',
  displayName: 'Workspace provider',
  pluginId: 'dev.example.remote',
);
const _chooseProvider = 'Choose configured provider...';
const _refreshProviders = 'Refresh providers';
const _unknownProvider =
    'This ID is not currently available for guided selection.';
const _unavailableProviders = 'Provider discovery is temporarily unavailable.';
const _emptyProviders = 'No configured providers are currently available.';

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
    DiscoverModelProviders? modelProviders,
    DiscoverModels? discoverModels,
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
                  modelProviders: modelProviders,
                  discoverModels: discoverModels,
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
        expect(find.text('Deleted record: $id'), findsOneWidget);
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
      expect(find.text('Deleted record: first'), findsNothing);
      expect(find.text('Deleted record: second'), findsOneWidget);
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
    File agentFile() => File('${roots.configurationRoot}/agents/reviewer.toml');
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
      'creates, edits and reloads formatted instructions without a backend',
      (tester) => tester.runAsync(() async {
        final recordFile = agentFile();
        await open(tester);
        expect(
          find.text('No readable records in this collection.'),
          findsOneWidget,
        );
        expect(Directory(roots.configurationRoot).existsSync(), isFalse);
        await _tap(tester, _key('records-add-agents'));
        await _enter(tester, _key('record-id-agents'), 'reviewer');
        expect(find.text('Agent'), findsOneWidget);
        expect(_enabled(tester, createButton), isFalse);
        const markdown = '```dart\nreport();\n```\n\nReview **risks**';
        const values = {
          'name': 'Reviewer',
          'description': 'Reviews changes.',
          'when-to-use': 'Before merging.',
          'instructions': markdown,
        };
        for (final field in settings.records.definition(type).fields) {
          final presence = _key('record-presence-agents-${field.id}');
          final input = _key('record-input-agents-${field.id}');
          expect(tester.widget<CheckboxListTile>(presence).value, isFalse);
          if (field.id.value == 'instructions') continue;
          expect(
            tester.widget<TextField>(input).decoration!.labelText,
            field.label,
          );
          await _tap(tester, presence);
          await _enter(tester, input, values[field.id.value]!);
        }
        expect(_enabled(tester, createButton), isFalse);
        await _tap(tester, _key('record-presence-agents-instructions'));
        expect(
          _enabled(tester, createButton),
          isTrue,
        ); // Present empty is valid.
        final creation = _instructionsOwner(tester, 'agents');
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
        expect(find.text('Record ID: reviewer'), findsOneWidget);
        expect(find.text('Record type: $type'), findsOneWidget);
        for (final field in settings.records.definition(type).fields) {
          expect(
            find.text('${field.label}: ${values[field.id.value]}'),
            findsOneWidget,
          );
        }
        expect(find.text('Credentials'), findsNothing);

        await _tap(tester, _key('record-edit-agents-reviewer'));
        await _enter(
          tester,
          _key('record-input-agents-reviewer-name'),
          'Renamed Reviewer',
        );
        final existing = _instructionsOwner(tester, 'agents-reviewer');
        final editing = await _selectInstructions(
          tester,
          'agents-reviewer',
          offset: 9,
        );
        final code = editing.document.root.children.first;
        expect(code.type, 'code_block');
        expect(code.attributes['language'], 'dart');
        expect(code.delta!.toPlainText(), 'report();');
        await native_input.insertAtSelection(tester, ' // tested');
        await submit(tester, saveButton);
        expect(existing.isDisposed, isTrue);
        await _tap(tester, _key('records-reload-agents'));
        await loaded(tester);
        expect(await stored(), {
          ...values,
          'name': 'Renamed Reviewer',
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
        await _tap(tester, _key('record-edit-agents-reviewer'));
        final deleted = _instructionsOwner(tester, 'agents-reviewer');
        await _tap(tester, _key('record-delete-agents-reviewer'));
        expect(find.byType(AlertDialog), findsOneWidget);
        await _tap(tester, _key('record-delete-confirm-agents-reviewer'));
        await loaded(tester);
        expect(deleted.isDisposed, isTrue);
        await _tap(tester, _key('records-reload-agents'));
        await loaded(tester);
        expect(_key('record-agents-reviewer'), findsNothing);
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
        await _enter(tester, _key('record-id-agents'), 'reviewer');
        for (final field in ['name', 'instructions']) {
          await _tap(tester, _key('record-presence-agents-$field'));
        }
        final create = tester
            .widget<ButtonStyleButton>(createButton)
            .onPressed!;
        final owner = _instructionsOwner(tester, 'agents');
        await _selectInstructions(tester, 'agents');
        final initial = TextEditingValue.fromJSON(
          tester.testTextInput.editingState!,
        );
        final at = initial.selection.start;
        final composing = TextEditingValue(
          text: initial.text.replaceRange(at, initial.selection.end, 'x'),
          selection: TextSelection.collapsed(offset: at + 1),
          composing: TextRange(start: at, end: at + 1),
        );
        await native_input.input(tester, composing);
        expect(owner.snapshot()['error'], 'composition_pending');
        expect(_enabled(tester, createButton), isFalse);
        create();
        await native_input.frames(tester);
        expect(find.textContaining('Finish composing'), findsOneWidget);
        expect(settings.creates, 0);
        expect(agentFile().existsSync(), isFalse);
        expect(_instructionsOwner(tester, 'agents'), same(owner));
        final presence = _key('record-presence-agents-instructions');
        await _richTap(tester, presence);
        expect(owner.editingEnabled, isFalse);
        expect(owner.snapshot()['error'], 'composition_pending');
        await _richTap(tester, presence);
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
        expect(await stored(), {'name': '', 'instructions': 'x'});
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
    'Global Settings persists published Model Presets without applying them',
    (tester) => tester.runAsync(() async {
      const pluginId = 'dev.adele.plugin.model-configuration';
      final installed = Directory('${temporary.path}/installed');
      await publishStockPluginInstallation(
        repositoryRoot: Directory.current.parent,
        installationDirectory: Directory(
          '${installed.path}/model-configuration',
        ),
        pluginId: pluginId,
        displayName: 'Model Configuration',
      );
      final plugins = ApplicationPluginBootstrap(
        CapabilityRegistry(),
        ExtensionRegistry(),
      );
      addTearDown(plugins.close);
      await plugins.start(installationRoot: installed.path);
      final prepared = plugins.catalog!;
      // The absent expected backend blocks Run preparation, not record CRUD.
      expect(prepared.issues.single.isRunModelPreferenceSourceIssue, isTrue);
      final settings = _ControlledService(
        catalog: prepared.settings,
        records: prepared.records,
        roots: roots,
      );
      addTearDown(settings.close);
      final application = RecordApplyCoordinator(plugins, prepared);
      addTearDown(application.close);

      final collection = RecordCollectionId('model-presets');
      final type = RecordTypeId('$pluginId.preset');
      const id = 'review';
      final key = (
        collection: collection,
        type: type,
        id: ConfigurationRecordId(id),
      );
      final row = '$collection-$id';
      final creation = _key('record-creation-$collection');
      final existing = _key('record-$row');
      final recordFile = File(
        '${roots.configurationRoot}/$collection/$id.toml',
      );
      final reload = _key('records-reload-$collection');
      final edit = _key('record-edit-$row');
      final save = _key('record-save-$row');
      Future<void> loaded() => _until(tester, () => _enabled(tester, reload));
      Future<void> submit(Finder button) async {
        await _tap(tester, button);
        await loaded();
      }

      void expectNoApplication() {
        expect(find.textContaining('Runtime application:'), findsNothing);
        expect(find.text('Retry application'), findsNothing);
        expect(application.outcome(key), isNull);
        expect(application.recentDeletion(collection), isNull);
      }

      await mount(
        tester,
        settingsService: settings,
        application: application,
        modelProviders: () => const [_firstProvider, _secondProvider],
      );
      await _section(tester, 'Model Presets');
      await loaded();
      final empty = find.text('No readable records in this collection.');
      expect(empty, findsOneWidget);
      expect(Directory(roots.configurationRoot).existsSync(), isFalse);
      expect(application.supports(key), isFalse);

      await _tap(tester, _key('records-add-$collection'));
      await _enter(tester, _key('record-id-$collection'), id);
      expect(find.text('Model Preset'), findsOneWidget);
      final create = _key('record-create-$collection');
      for (final (field, label, value) in [
        ('name', 'Name', 'Code Review'),
        ('model-id', 'Model ID', 'review-model-v1'),
      ]) {
        expect(find.text('Include $label (required)'), findsOneWidget);
        expect(_enabled(tester, create), isFalse);
        await _tap(tester, _key('record-presence-$collection-$field'));
        await _enter(tester, _key('record-input-$collection-$field'), value);
      }
      expect(find.text('Include Provider ID (required)'), findsOneWidget);
      expect(_enabled(tester, create), isFalse);
      await _tap(tester, _key('record-presence-$collection-provider-id'));
      final providerInput = _key('record-input-$collection-provider-id');
      expect(_text(tester, providerInput), ''); // No default provider.
      expect(_enabled(tester, create), isTrue); // Present empty is a string.
      expect(_choiceRow(creation, _secondProvider), findsNothing);
      await _tap(tester, find.text(_chooseProvider));
      for (final choice in [_firstProvider, _secondProvider]) {
        _expectChoice(tester, creation, choice, selected: false);
      }
      await _tap(tester, _choiceRow(creation, _secondProvider));
      expect(_choiceRow(creation, _secondProvider), findsNothing);
      expect(_text(tester, providerInput), _secondProvider.id);
      expect(settings.creates, 0);
      expect(Directory(roots.configurationRoot).existsSync(), isFalse);
      expect(find.text('Include Description (optional)'), findsOneWidget);
      expect(find.text('Include Reasoning Effort (optional)'), findsOneWidget);
      expect(_enabled(tester, create), isTrue);
      await submit(create);
      await _tap(tester, find.text('Code Review'));
      await tester.pumpAndSettle();
      expect(find.text('Record type: $type'), findsOneWidget);
      expect(find.text('Provider ID: ${_secondProvider.id}'), findsOneWidget);
      expect(find.text('Model ID: review-model-v1'), findsOneWidget);
      expect(find.text('Description: Not provided'), findsOneWidget);
      expect(find.text('Reasoning Effort: Not provided'), findsOneWidget);
      final original = recordFile.readAsStringSync();
      expect(original, contains(_secondProvider.id));
      expect(original, isNot(contains(_secondProvider.displayName)));
      expect(original, isNot(contains(_secondProvider.pluginId)));
      expect(original, isNot(contains('reasoning-effort')));
      expectNoApplication();

      await settings.createRecord(type, ConfigurationRecordId('sibling'), {
        'name': 'Sibling',
        'provider-id': _secondProvider.id,
        'model-id': 'other-model',
      });
      final siblingFile = File('${recordFile.parent.path}/sibling.toml');
      final siblingBytes = siblingFile.readAsBytesSync();
      await submit(reload);
      await _tap(tester, edit);
      final editingProvider = _key('record-input-$row-provider-id');
      final known = find.text(
        'Configured provider: ${_secondProvider.displayName}',
      );
      expect(known, findsOneWidget);
      expect(_choiceRow(existing, _secondProvider), findsNothing);
      await _tap(tester, find.text(_chooseProvider));
      expect(
        tester.widget<ListTile>(_choiceRow(existing, _secondProvider)).selected,
        isTrue,
      );
      // A near match is still an opaque, unknown ID, even after a guided pick.
      final manual = ' ${_secondProvider.id} ';
      for (final nearMatch in [_secondProvider.id.toUpperCase(), manual]) {
        await _enter(tester, editingProvider, nearMatch);
        expect(find.text(_unknownProvider), findsOneWidget);
        expect(known, findsNothing);
        for (final choice in [_firstProvider, _secondProvider]) {
          expect(
            tester.widget<ListTile>(_choiceRow(existing, choice)).selected,
            isFalse,
          );
        }
      }
      final name = _key('record-input-$row-name');
      final effortPresence = _key('record-presence-$row-reasoning-effort');
      expect(tester.widget<CheckboxListTile>(effortPresence).value, isFalse);
      await _enter(tester, name, 'Detailed Review');
      await _tap(tester, _key('record-presence-$row-description'));
      await _enter(
        tester,
        _key('record-input-$row-description'),
        'Review pending changes.',
      );
      await _section(tester, 'Preferences');
      expect(name, findsNothing);
      expect(recordFile.readAsStringSync(), original);
      await _section(tester, 'Model Presets');
      expect(_text(tester, editingProvider), manual);
      expect(find.text(_unknownProvider), findsOneWidget);
      expect(_text(tester, name), 'Detailed Review');
      expect(settings.updates, 0);
      await submit(save);
      expect(
        recordFile.readAsStringSync(),
        isNot(contains('reasoning-effort')),
      );
      await submit(reload);
      expect(find.text('Detailed Review'), findsOneWidget);
      expect(find.text('Record ID: $id'), findsOneWidget);
      expect(find.text('Provider ID: $manual'), findsOneWidget);
      expect(find.text('Description: Review pending changes.'), findsOneWidget);
      expect(find.text('Reasoning Effort: Not provided'), findsOneWidget);
      expect(
        recordFile.parent.listSync().map((entry) => entry.path),
        unorderedEquals([recordFile.path, siblingFile.path]),
      );
      expect(siblingFile.readAsBytesSync(), siblingBytes);
      expectNoApplication();

      await _tap(tester, edit);
      await _tap(tester, effortPresence);
      final effort = _key('record-input-$row-reasoning-effort');
      final menu = tester.widget<DropdownButton<String>>(effort);
      expect(menu.value, isNull);
      expect(_enabled(tester, save), isFalse);
      expect(
        menu.items!.map((item) => item.value),
        ModelReasoningEffort.values.map((effort) => effort.name),
      );
      await _choose(tester, effort, 'None');
      await _tap(tester, find.text(_chooseProvider));
      await _tap(tester, _choiceRow(existing, _firstProvider));
      expect(_text(tester, editingProvider), _firstProvider.id);
      await submit(save);
      expectNoApplication();

      // An external edit makes a real worker reread observable, not just a repaint.
      recordFile.writeAsStringSync(
        recordFile.readAsStringSync().replaceFirst(
          'review-model-v1',
          'review-model-v2',
        ),
      );
      expect(find.text('Model ID: review-model-v1'), findsOneWidget);
      await submit(reload);
      expect(find.text('Provider ID: ${_firstProvider.id}'), findsOneWidget);
      expect(find.text('Description: Review pending changes.'), findsOneWidget);
      expect(find.text('Model ID: review-model-v2'), findsOneWidget);
      expect(find.text('Reasoning Effort: none'), findsOneWidget);

      await _tap(tester, _key('record-delete-$row'));
      await submit(_key('record-delete-confirm-$row'));
      expect(recordFile.existsSync(), isFalse);
      expectNoApplication();
      await submit(reload);
      expect(_key('record-$row'), findsNothing);
      expect(find.text('Sibling'), findsOneWidget);
      expect(siblingFile.readAsBytesSync(), siblingBytes);
      expect(File(settings.filePath).existsSync(), isFalse);
      await unmount(tester);
    }),
    skip: !Platform.isLinux,
  );

  testWidgets(
    'refresh observes new, replaced and retired choices without reloading or rewriting a hinted note',
    (tester) => tester.runAsync(() async {
      const id = 'routed';
      await service.createRecord(_note, ConfigurationRecordId(id), {
        'destination': _firstProvider.id,
      });
      final original = file(id).readAsBytesSync();
      var choices = [_firstProvider];
      await mount(tester, modelProviders: () => choices);
      await openRecords(tester);
      await _edit(tester, id);
      final form = _key('record-jobs-$id');
      final input = _editInput(id, 'destination');
      final first = _choiceRow(form, _firstProvider);
      final second = _choiceRow(form, _secondProvider);
      expect(first, findsNothing);
      expect(
        find.text('Configured provider: ${_firstProvider.displayName}'),
        findsOneWidget,
      );
      await _tap(tester, find.text(_chooseProvider));
      expect(tester.widget<ListTile>(first).selected, isTrue);
      expect(second, findsNothing);

      final replacement = (
        id: _firstProvider.id,
        displayName: 'Replacement configuration',
        pluginId: 'dev.example.replacement',
      );
      choices = [replacement, _secondProvider];
      await _tap(tester, find.text(_refreshProviders));
      _expectChoice(tester, form, replacement, selected: true);
      expect(tester.widget<ListTile>(second).selected, isFalse);

      choices = [_secondProvider];
      await _tap(tester, find.text(_refreshProviders));
      expect(first, findsNothing);
      expect(tester.widget<ListTile>(second).selected, isFalse);
      expect(find.text(_unknownProvider), findsOneWidget);
      expect(_text(tester, input), _firstProvider.id);
      await _tap(tester, second);
      expect(_text(tester, input), _secondProvider.id);
      // The newly selected provider can also retire before this draft is saved.
      await _tap(tester, find.text(_chooseProvider));
      choices = [];
      await _tap(tester, find.text(_refreshProviders));
      expect(second, findsNothing);
      expect(find.text(_emptyProviders), findsOneWidget);
      expect(_text(tester, input), _secondProvider.id);
      expect(service.recordLoads, 1);
      expect(service.updates, 0);
      expect(file(id).readAsBytesSync(), original);

      // Guided selection dirties the same draft that guards collection Reload.
      final reload = _key('records-reload-jobs');
      await _tap(tester, reload);
      await _tap(tester, _key('records-reload-cancel-jobs'));
      await _loaded(tester);
      expect(_text(tester, input), _secondProvider.id);
      await _tap(tester, reload);
      await _tap(tester, _key('records-reload-confirm-jobs'));
      await _loaded(tester);
      expect(input, findsNothing);
      await _tap(tester, _key('record-edit-jobs-$id'));
      expect(_text(tester, input), _firstProvider.id);
      expect(find.text(_emptyProviders), findsOneWidget);
      expect(file(id).readAsBytesSync(), original);
      await unmount(tester);
    }),
    skip: !Platform.isLinux,
  );

  testWidgets(
    'empty and unavailable discovery allow exact manual values without exposing an error',
    (tester) => tester.runAsync(() async {
      const diagnostic = 'private-backend-diagnostic-42';
      List<ModelProviderChoice>? choices;
      var throwOnDiscovery = false;
      await mount(
        tester,
        modelProviders: () {
          if (throwOnDiscovery) throw StateError(diagnostic);
          return choices;
        },
      );
      await openRecords(tester);
      await _tap(tester, _key('records-add-jobs'));
      await _choose(tester, _key('record-type-jobs'), 'Note');
      const id = 'manual';
      await _enter(tester, _key('record-id-jobs'), id);
      final input = _input('destination');
      final createButton = _key('record-create-jobs');
      expect(
        tester.widget<CheckboxListTile>(_presence('destination')).value,
        isFalse,
      );
      expect(_enabled(tester, createButton), isTrue);
      expect(find.text(_chooseProvider), findsNothing);
      await _include(tester, 'destination');
      expect(_text(tester, input), '');
      expect(find.text(_unavailableProviders), findsOneWidget);
      await _tap(tester, find.text(_chooseProvider));

      choices = [];
      await _tap(tester, find.text(_refreshProviders));
      expect(find.text(_emptyProviders), findsOneWidget);
      expect(find.text(_unavailableProviders), findsNothing);
      const manual = '  Mixed/Case\n Future ID  ';
      await _enter(tester, input, manual);
      expect(_enabled(tester, createButton), isTrue);
      throwOnDiscovery = true;
      await _tap(tester, find.text(_refreshProviders));
      expect(find.text(_unavailableProviders), findsOneWidget);
      expect(find.text(_emptyProviders), findsNothing);
      expect(find.text(_unknownProvider), findsNothing);
      expect(find.textContaining(diagnostic), findsNothing);
      expect(tester.takeException(), isNull);
      expect(_text(tester, input), manual);
      expect(_enabled(tester, createButton), isTrue);
      expect(service.creates, 0);
      await create(tester);

      final saved = file(id).readAsBytesSync();
      await _edit(tester, id);
      expect(_text(tester, _editInput(id, 'destination')), manual);
      await _enter(tester, _editInput(id, 'destination'), 'Discard this');
      await _tap(tester, _key('record-cancel-jobs-$id'));
      expect(_editInput(id, 'destination'), findsNothing);
      expect(file(id).readAsBytesSync(), saved);
      expect(service.updates, 0);
      expect((await service.loadRecords(_collection)).records.single.values, {
        'destination': manual,
      });
      await unmount(tester);
    }),
    skip: !Platform.isLinux,
  );

  group('linked model catalog', () {
    final choose = find.widgetWithText(TextButton, 'Choose model...');
    final refresh = find.ancestor(
      of: find.text('Refresh models'),
      matching: find.bySubtype<TextButton>(),
    );
    final row = _key('model-choice-Second/EXACT');
    const stored = '  Unlisted / model\nID  ';
    final snapshot = ModelCatalogSnapshot(
      models: [
        ModelCatalogEntry(
          modelId: 'z-last',
          displayName: 'Shared name',
          description: null,
        ),
        ModelCatalogEntry(
          modelId: 'Second/EXACT',
          displayName: 'Shared name',
          description: 'D' * 4000,
        ),
        ModelCatalogEntry(
          modelId: 'Shared name',
          displayName: 'N' * 250,
          description: null,
        ),
      ],
    );
    ModelDiscoveryResult success({
      bool Function()? current,
      Stream<void>? changes,
    }) => ModelDiscoveryResult.success(
      snapshot,
      isCurrent: current ?? () => true,
      changes: changes,
    );

    Future<void> seedNote(String id) async {
      await service.createRecord(_note, ConfigurationRecordId(id), {
        'destination': _firstProvider.id,
        'engine': stored,
      });
    }

    testWidgets(
      'query is explicit; choosing an exact ID only edits this draft until Save',
      (tester) => tester.runAsync(() async {
        await seedNote('edit-me');
        await seedNote('sibling');
        final before = file('edit-me').readAsBytesSync();
        final sibling = file('sibling').readAsBytesSync();
        final requests = <String>[];
        final pending = Completer<ModelDiscoveryResult>();
        await mount(
          tester,
          discoverModels: (id) {
            requests.add(id);
            return pending.future;
          },
        );
        await openRecords(tester);
        await _edit(tester, 'edit-me');
        final model = _editInput('edit-me', 'engine');
        final provider = _editInput('edit-me', 'destination');
        // Discovery uses the linked *unsaved* string, not the stored route.
        await _enter(tester, provider, _secondProvider.id);
        expect(requests, isEmpty);
        expect(_text(tester, model), stored);
        await _tap(tester, choose);
        expect(requests, [_secondProvider.id]);
        expect(find.text('Loading models...'), findsOneWidget);
        await _enter(tester, model, ' typed while waiting ');
        expect(_enabled(tester, _key('record-save-jobs-edit-me')), isTrue);
        pending.complete(success());
        await _until(tester, () => row.evaluate().isNotEmpty);
        expect(_text(tester, model), ' typed while waiting ');
        expect(
          tester.getTopLeft(_key('model-choice-z-last')).dy,
          lessThan(tester.getTopLeft(row).dy),
        );
        for (final id in ['z-last', 'Second/EXACT']) {
          final tile = _key('model-choice-$id');
          expect(
            find.descendant(of: tile, matching: find.text('Shared name')),
            findsOneWidget,
          );
          expect(
            find.descendant(of: tile, matching: find.text(id)),
            findsOneWidget,
          );
          expect(tester.widget<ListTile>(tile).selected, isFalse);
        }
        expect(tester.widget<Text>(find.text('D' * 4000)).maxLines, 2);
        expect(tester.widget<Text>(find.text('N' * 250)).maxLines, 1);
        await _tap(tester, row);
        expect(_text(tester, model), 'Second/EXACT');
        expect(_text(tester, provider), _secondProvider.id);
        expect(file('edit-me').readAsBytesSync(), before);
        expect(service.updates, 0);
        expect(service.recordLoads, 1);
        await save(tester, 'edit-me');
        expect(service.updates, 1);
        expect(requests, [_secondProvider.id]);
        expect(file('sibling').readAsBytesSync(), sibling);
        final saved = await service.loadRecords(_collection);
        expect(
          saved.records.firstWhere((r) => r.id.value == 'edit-me').values,
          {'destination': _secondProvider.id, 'engine': 'Second/EXACT'},
        );
        await unmount(tester);
      }),
    );

    testWidgets(
      'optional fields and safe catalog outcomes never constrain manual creation',
      (tester) => tester.runAsync(() async {
        const diagnostic = 'private-backend-diagnostic-42';
        final responses = <ModelDiscoveryResult>[
          const ModelDiscoveryResult.unavailable(),
          const ModelDiscoveryResult.unsupported(),
          const ModelDiscoveryResult.ambiguous(),
          ModelDiscoveryResult.success(
            ModelCatalogSnapshot(models: []),
            isCurrent: () => true,
          ),
        ];
        final requests = <String>[];
        await mount(
          tester,
          discoverModels: (id) async {
            requests.add(id);
            if (responses.isEmpty) throw StateError(diagnostic);
            return responses.removeAt(0);
          },
        );
        await openRecords(tester);
        await add(tester, 'manual-model');
        await _choose(tester, _key('record-type-jobs'), 'Note');
        await _enter(tester, _key('record-id-jobs'), 'manual-model');
        expect(choose, findsNothing); // An excluded model is not edited.
        await _include(tester, 'engine');
        await _enter(tester, _input('engine'), stored);
        expect(_enabled(tester, choose), isFalse);
        await _include(tester, 'destination');
        expect(
          _enabled(tester, choose),
          isFalse,
        ); // Present but empty provider.
        const provider = '  Mixed/Case Provider  ';
        await _enter(tester, _input('destination'), provider);
        await _include(tester, 'destination');
        expect(
          _enabled(tester, choose),
          isFalse,
        ); // No retained controller authority.
        await _include(tester, 'destination');
        expect(requests, isEmpty);
        for (final message in [
          'Model discovery is unavailable for this provider.',
          'This provider does not support model discovery.',
          'More than one model catalog is associated with this provider.',
          'This provider reported no models.',
          'Could not load models. Refresh to try again or enter a model ID manually.',
        ]) {
          await _tap(tester, requests.isEmpty ? choose : refresh);
          await _until(tester, () => find.text(message).evaluate().isNotEmpty);
          expect(_text(tester, _input('engine')), stored);
          expect(_enabled(tester, _key('record-create-jobs')), isTrue);
          expect(find.textContaining(diagnostic), findsNothing);
        }
        expect(service.creates, 0);
        await create(tester);
        expect(requests, List.filled(5, provider));
        expect((await service.loadRecords(_collection)).records.single.values, {
          'destination': provider,
          'engine': stored,
        });
        await unmount(tester);
      }),
    );

    testWidgets(
      'provider edits, refreshes and registration retirement fence late results and stale taps',
      (tester) => tester.runAsync(() async {
        await seedNote('routed');
        final requests = <String>[];
        final pending = <Completer<ModelDiscoveryResult>>[];
        await mount(
          tester,
          modelProviders: () => [_firstProvider, _secondProvider],
          discoverModels: (id) {
            requests.add(id);
            final request = Completer<ModelDiscoveryResult>();
            pending.add(request);
            return request.future;
          },
        );
        await openRecords(tester);
        await _edit(tester, 'routed');
        final model = _editInput('routed', 'engine');
        final provider = tester
            .widget<TextField>(_editInput('routed', 'destination'))
            .controller!;
        final open = tester.widget<TextButton>(choose).onPressed!;
        open();
        open(); // A captured button does not admit a second request.
        provider.text = _secondProvider.id;
        provider.text = _firstProvider.id;
        open(); // Changed back, but this control still belongs to the old scope.
        pending.single.complete(success());
        await tester.pump();
        expect(choose, findsOneWidget);
        expect(row, findsNothing);
        expect(requests, [_firstProvider.id]);
        await _tap(tester, choose);
        final first = pending.last;
        await _tap(tester, find.text(_chooseProvider));
        await _tap(tester, _key('provider-choice-${_secondProvider.id}'));
        expect(choose, findsOneWidget);
        await _tap(tester, choose);
        final second = pending.last;
        await _tap(
          tester,
          refresh,
        ); // This newer request supersedes both others.
        final changes = StreamController<void>.broadcast(sync: true);
        addTearDown(changes.close);
        var current = true;
        final live = success(current: () => current, changes: changes.stream);
        pending.last.complete(live);
        await _until(tester, () => row.evaluate().isNotEmpty);
        first.complete(const ModelDiscoveryResult.failed());
        second.complete(const ModelDiscoveryResult.unsupported());
        await tester.pump();
        expect(requests, [
          _firstProvider.id,
          _firstProvider.id,
          _secondProvider.id,
          _secondProvider.id,
        ]);
        expect(changes.hasListener, isTrue);
        final tap = tester.widget<ListTile>(row).onTap!;
        // Retirement need not have delivered its change notification yet.
        current = false;
        tap();
        expect(_text(tester, model), stored);
        await tester.pump();
        expect(row, findsNothing);
        expect(changes.hasListener, isFalse);
        await _tap(tester, refresh);
        pending.last.complete(live); // Retired before successful delivery.
        await _until(
          tester,
          () => find
              .text('Model discovery is unavailable for this provider.')
              .evaluate()
              .isNotEmpty,
        );
        expect(row, findsNothing);
        await _tap(tester, refresh);
        current = true;
        pending.last.complete(live);
        await _until(tester, () => row.evaluate().isNotEmpty);
        changes.add(
          null,
        ); // An unrelated change does not discard current choices.
        await tester.pump();
        expect(row, findsOneWidget);
        current = false;
        changes.add(null);
        await tester.pump();
        expect(row, findsNothing);
        expect(changes.hasListener, isFalse);
        expect(_text(tester, model), stored);
        expect(service.updates, 0);
        await unmount(tester);
      }),
    );

    testWidgets(
      'hidden, replaced, reloaded and closed forms reject earlier controls before the next frame',
      (tester) => tester.runAsync(() async {
        await seedNote('edit-me');
        final initial = file('edit-me').readAsBytesSync();
        var queries = 0;
        await mount(
          tester,
          discoverModels: (_) async {
            queries++;
            return success();
          },
        );
        await openRecords(tester);
        await _edit(tester, 'edit-me');
        final model = _editInput('edit-me', 'engine');
        for (final action in [
          'provider',
          'provider presence',
          'model presence',
          'section',
          'collapse',
          'cancel',
          'reload',
          'close',
        ]) {
          await _tap(tester, choose);
          await _until(tester, () => row.evaluate().isNotEmpty);
          final oldRefresh = tester.widget<TextButton>(refresh).onPressed!;
          final oldSelection = tester.widget<ListTile>(row).onTap!;
          final controller = tester.widget<TextField>(model).controller!;
          final count = queries;
          switch (action) {
            case 'provider':
              final provider = tester
                  .widget<TextField>(_editInput('edit-me', 'destination'))
                  .controller!;
              provider.text = _secondProvider.id;
              provider.text = _firstProvider.id;
            case 'provider presence' || 'model presence':
              final field = action == 'provider presence'
                  ? 'destination'
                  : 'engine';
              final toggle = tester
                  .widget<CheckboxListTile>(_editPresence('edit-me', field))
                  .onChanged!;
              toggle(false);
              toggle(true);
            case 'section':
              final select = tester
                  .widget<DropdownButtonFormField<String>>(
                    _key('settings-section'),
                  )
                  .onChanged!;
              select('');
              select('jobs');
            case 'collapse':
              final expand = tester
                  .widget<ExpansionTile>(find.byType(ExpansionTile))
                  .onExpansionChanged!;
              expand(false);
              expand(true);
            case 'cancel':
              tester
                  .widget<TextButton>(_key('record-cancel-jobs-edit-me'))
                  .onPressed!();
            case 'reload':
              tester
                  .widget<ButtonStyleButton>(_key('records-reload-jobs'))
                  .onPressed!();
            case 'close':
              Navigator.of(
                tester.element(find.byType(GlobalSettingsDialog)),
              ).pop();
          }
          oldRefresh();
          oldSelection();
          expect(controller.text, stored, reason: action);
          expect(queries, count, reason: action);
          await tester.pump();
          if (action == 'close') await tester.pumpAndSettle();
          expect(row, findsNothing, reason: action);
          if (action == 'cancel' || action == 'reload') {
            await _loaded(tester);
            await _tap(tester, _key('record-edit-jobs-edit-me'));
          }
        }
        expect(service.updates, 0);
        expect(file('edit-me').readAsBytesSync(), initial);
        await unmount(tester);
      }),
    );
  }, skip: !Platform.isLinux);

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
          final application = RecordApplicationProbe(_job);
          await mount(tester, application: application);
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
          expect(application.saves, isEmpty);
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
        await add(tester, 'requested-id');
        await fillRequired(tester, caption: 'Requested title');
        service.returnDifferentPersistedRecord = true;
        service.failNextLoad = true;
        await create(tester);
        expect(application.saves, [(_jobKey('actual-id'), false)]);
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
        final application = RecordApplicationProbe(_job);
        await mount(tester, application: application);
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
        await _until(
          tester,
          () =>
              file('after-close').existsSync() && application.saves.isNotEmpty,
        );
        expect(application.saves, [(_jobKey('after-close'), false)]);
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
        RecordFieldDefinition(
          id: RecordFieldId('engine'),
          label: 'Engine',
          type: const StringSettingType(),
          required: false,
          editor: RecordFieldEditor.modelCatalog,
          providerField: RecordFieldId('destination'),
        ),
        RecordFieldDefinition(
          id: RecordFieldId('destination'),
          label: 'Destination',
          type: const StringSettingType(),
          required: false,
          editor: RecordFieldEditor.modelProvider,
        ),
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
Finder _choiceRow(Finder form, ModelProviderChoice choice) =>
    find.descendant(of: form, matching: _key('provider-choice-${choice.id}'));
void _expectChoice(
  WidgetTester tester,
  Finder form,
  ModelProviderChoice choice, {
  required bool selected,
}) {
  final row = _choiceRow(form, choice);
  expect(tester.widget<ListTile>(row).selected, selected);
  expect(
    find.descendant(of: row, matching: find.text(choice.displayName)),
    findsOneWidget,
  );
  for (final detail in [choice.id, choice.pluginId]) {
    expect(
      find.descendant(of: row, matching: find.textContaining(detail)),
      findsOneWidget,
    );
  }
}

String _text(WidgetTester tester, Finder input) =>
    tester.widget<TextField>(input).controller!.text;
Finder _input(String field) => _key('record-input-jobs-$field');
Finder _presence(String field) => _key('record-presence-jobs-$field');
Finder _editInput(String id, String field) =>
    _key('record-input-jobs-$id-$field');
Finder _editPresence(String id, String field) =>
    _key('record-presence-jobs-$id-$field');

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
}) async {
  final field = _instructions(suffix);
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
