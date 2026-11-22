import 'dart:convert';
import 'dart:io';

import 'package:adele_desktop/core/global_settings_service.dart';
import 'package:adele_desktop/core/prepared_settings.dart';
import 'package:adele_desktop/frontend/application_frontend_bootstrap.dart';
import 'package:adele_desktop/frontend/settings_field_editor_bridge.dart';
import 'package:adele_desktop/frontend/structured_bridge_data.dart';
import 'package:adele_desktop/ui/settings/global_settings_dialog.dart';
import 'package:adele_platform_storage/adele_platform_storage.dart';
import 'package:adele_plugin_api/adele_plugin_api.dart';
import 'package:adele_settings/adele_settings.dart';
import 'package:dart_eval/dart_eval.dart';
import 'package:flutter/material.dart';
import 'package:flutter_eval/flutter_eval.dart';
import 'package:flutter_eval/widgets.dart' show $StatefulWidget$bridge;
import 'package:flutter_test/flutter_test.dart';
import 'package:plugin_runtime/plugin_runtime.dart';

import 'support/record_draft_id.dart';

const _plugin = 'dev.example.windows';
const _library = 'package:window_controls/editor.dart';
const _editor = '$_plugin.step';
const _missing = '$_plugin.uninstalled';
const _collection = 'windows';
final _type = RecordTypeId('$_plugin.window');

void main() {
  late List<int> bytes;
  late PlatformStorageRoots roots;
  late GlobalSettingsService settings;
  late GlobalSettingsService reader;
  late ApplicationFrontendBootstrap frontends;

  setUpAll(() async {
    final compiler = Compiler()
      ..addPlugin(flutterEvalPlugin)
      ..addPlugin(const SettingsFieldEditorDeclarations())
      ..entrypoints.add(_library);
    bytes = compiler.compile({
      'window_controls': {'editor.dart': _source},
      'adele_ui': {
        'settings_field_editor_bridge.dart': await File(
          '../packages/ui/lib/settings_field_editor_bridge.dart',
        ).readAsString(),
      },
    }).write();
  });

  setUp(() async {
    final temporary = await Directory.systemTemp.createTemp('field-editor-');
    addTearDown(() => temporary.delete(recursive: true));
    final installed = Directory('${temporary.path}/installed');
    final plugin = await Directory(
      '${installed.path}/fixture',
    ).create(recursive: true);
    await File('${plugin.path}/frontend.evc').writeAsBytes(bytes);
    await File('${plugin.path}/records.json').writeAsString(
      jsonEncode({
        'schemaVersion': 1,
        'recordTypes': [
          {
            'id': _type.value,
            'collection': _collection,
            'collectionLabel': 'Windows',
            'label': 'Window',
            'displayField': 'caption',
            'fields': [
              {
                'id': 'caption',
                'label': 'Caption',
                'type': 'string',
                'required': true,
              },
              for (final id in ['start', 'end'])
                {
                  'id': id,
                  'label': id,
                  'type': 'integer',
                  'required': true,
                  'minimum': 1,
                  'maximum': 8,
                  'editor': {'extensionId': _editor},
                },
              {
                'id': 'note',
                'label': 'Note',
                'type': 'string',
                'required': false,
                'editor': {'extensionId': _missing},
              },
            ],
          },
        ],
      }),
    );
    await File('${plugin.path}/adele_plugin.installation.json').writeAsString(
      jsonEncode({
        'manifestVersion': 1,
        'metadata': {'id': _plugin, 'version': '1', 'displayName': 'Fixture'},
        'recordsSchema': 'records.json',
        'components': {
          'frontend': {
            'artifact': 'frontend.evc',
            'presentations': [
              {
                'role': 'settingsFieldEditor',
                'extensionId': _editor,
                'library': _library,
                'entrypoint': 'editor',
              },
            ],
          },
        },
      }),
    );
    roots = PlatformStorageRoots(
      operatingSystem: Platform.operatingSystem,
      configurationRoot: '${temporary.path}/config',
      localStateRoot: '${temporary.path}/state',
      localDataRoot: '${temporary.path}/data',
      cacheRoot: '${temporary.path}/cache',
    );
    final prepared = await PreparedPluginCatalog.discover(installed.path);
    expect(prepared.issues, isEmpty);
    frontends = ApplicationFrontendBootstrap(
      extensions: ExtensionRegistry(),
      loadSettings: (catalog) =>
          PreparedSettingsSnapshot.load(catalog, roots: roots),
    );
    addTearDown(frontends.close);
    await frontends.start(prepared);
    final generation = frontends.generations.single;
    expect(
      generation.state,
      InstalledFrontendState.active,
      reason: '${generation.failure}',
    );
    GlobalSettingsService owner() => GlobalSettingsService(
      catalog: prepared.settings,
      records: prepared.records,
      roots: roots,
    );
    settings = owner();
    addTearDown(settings.close);
    // A readback through a separate lease cannot invalidate the dialog's handles.
    reader = owner();
    addTearDown(reader.close);
  });

  File file(String id) =>
      File('${roots.configurationRoot}/$_collection/$id.toml');
  Future<Map<String, Map<String, Object?>>> saved() async => {
    for (final record in (await reader.loadRecords(
      RecordCollectionId(_collection),
    )).records)
      record.id.value: record.values,
  };
  Future<void> seed(String id, Map<String, Object> values) =>
      settings.createRecord(_type, ConfigurationRecordId(id), values);

  Future<void> mount(WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(1000, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showDialog<void>(
                context: context,
                builder: (_) => GlobalSettingsDialog(
                  service: () async => settings,
                  frontends: frontends,
                ),
              ),
              child: const Text('Open settings'),
            ),
          ),
        ),
      ),
    );
    await _open(tester);
  }

  testWidgets(
    'compiled proposals are bounded draft edits; only Create writes TOML',
    (tester) => tester.runAsync(() async {
      await mount(tester);
      await _tap(tester, _key('records-add-$_collection'));
      final id = await inspectDraftId(tester);
      final start = _input('start');
      final end = _input('end');
      final create = _key('record-create-$_collection');
      await _enter(tester, _input('caption'), 'Morning');
      expect(_within(start, 'Draft: unset'), findsOneWidget);
      expect(
        _within(start, 'Validation: Expected a native Dart int.'),
        findsOneWidget,
      );
      expect(_enabled(tester, create), isFalse);
      await _tap(tester, _within(start, 'Use 99'));
      expect(_within(start, 'Result: Must be at most 8.'), findsOneWidget);
      expect(_within(start, 'Draft: unset'), findsOneWidget);
      expect(_enabled(tester, create), isFalse);

      final stale = _captureProposal(tester, start);
      await tester.tap(_within(start, 'Use 2'));
      _expectRejected(stale); // The revision advances before a frame.
      await tester.pump();
      expect(_within(start, 'Draft: 2'), findsOneWidget);
      expect(_within(end, 'Draft: unset'), findsOneWidget);
      await _tap(tester, _within(end, 'Use 4'));
      expect(_enabled(tester, create), isTrue);
      await _tap(tester, _within(end, 'Use text'));
      expect(
        _within(end, 'Result: Expected a native Dart int.'),
        findsOneWidget,
      );
      expect(_within(end, 'Draft: 4'), findsOneWidget);
      expect(_enabled(tester, create), isTrue); // The last valid draft won.
      expect(file(id).existsSync(), isFalse);
      expect(await saved(), isEmpty);
      await _tap(tester, create);
      await _ready(tester, 'records-reload-$_collection');
      expect(await saved(), {
        id: {'caption': 'Morning', 'start': 2, 'end': 4},
      });
      expect(file(id).readAsStringSync(), contains('recordType = "$_type"'));
      expect(file(id).readAsStringSync(), isNot(contains(_editor)));
      await _dismiss(tester);
    }),
    skip: !Platform.isLinux,
  );

  testWidgets(
    'concurrent records isolate compiled controls, Save and Cancel despite a missing editor',
    (tester) => tester.runAsync(() async {
      const early = {
        'caption': 'Early',
        'start': 1,
        'end': 3,
        'note': 'Keep verbatim',
      };
      const lateWindow = {'caption': 'Late', 'start': 6, 'end': 8};
      await seed('early', early);
      await seed('late', lateWindow);
      final original = file('early').readAsBytesSync();
      await mount(tester);
      await _edit(tester, 'early', 'Early');
      await _edit(tester, 'late', 'Late');
      final left = _input('start', 'early');
      final right = _input('end', 'late');
      final missing = _input('note', 'early');
      expect(
        _within(missing, 'Field editor unavailable: $_missing'),
        findsOneWidget,
      );
      expect(
        find.descendant(of: missing, matching: find.byType(TextField)),
        findsNothing,
      );
      await _tap(tester, _within(left, 'Use 4'));
      await _tap(tester, _within(right, 'Use 2'));
      expect(_within(left, 'Draft: 4'), findsOneWidget);
      expect(_within(_input('start', 'late'), 'Draft: 6'), findsOneWidget);
      expect(_within(_input('end', 'early'), 'Draft: 3'), findsOneWidget);
      expect(_within(right, 'Draft: 2'), findsOneWidget);
      await _enter(tester, _input('caption', 'late'), 'New title');
      // Positive control for the very callback retained in the fencing tests.
      expect(_captureProposal(tester, right)(), 'accepted');
      expect(await saved(), {'early': early, 'late': lateWindow});
      await _tap(tester, _key('record-save-$_collection-late'));
      await _ready(tester, 'records-reload-$_collection');
      expect(file('early').readAsBytesSync(), original);
      expect(file('late').readAsStringSync(), contains('New title'));
      expect(_within(left, 'Draft: 4'), findsOneWidget);
      await _tap(tester, _key('record-cancel-$_collection-early'));
      await _tap(tester, _key('record-edit-$_collection-early'));
      expect(_within(left, 'Draft: 1'), findsOneWidget);
      expect(file('early').readAsBytesSync(), original);
      // An unavailable editor does not disable generic controls or lose its value.
      await _enter(tester, _input('caption', 'early'), 'Rename only');
      await _tap(tester, _key('record-save-$_collection-early'));
      await _ready(tester, 'records-reload-$_collection');
      expect(await saved(), {
        'early': {...early, 'caption': 'Rename only'},
        'late': {...lateWindow, 'caption': 'New title', 'end': 7},
      });
      await _dismiss(tester);
    }),
    skip: !Platform.isLinux,
  );

  testWidgets(
    'navigation, dismissal and frontend retirement reject retained interpreted callbacks',
    (tester) => tester.runAsync(() async {
      const values = {'caption': 'Office', 'start': 1, 'end': 8};
      await seed('office', values);
      final original = file('office').readAsBytesSync();
      await mount(tester);
      await _edit(tester, 'office', 'Office');
      final start = _input('start', 'office');
      await _tap(tester, _within(start, 'Use 4'));
      final hidden = _captureProposal(tester, start);
      final select = tester
          .widget<DropdownButtonFormField<String>>(_key('settings-section'))
          .onChanged!;
      select('');
      select(_collection);
      _expectRejected(hidden); // No intervening frame is necessary.
      await tester.pumpAndSettle();
      expect(_within(start, 'Draft: 4'), findsOneWidget);

      final dismissed = _captureProposal(tester, start);
      await tester.tap(find.byTooltip('Close Settings'));
      _expectRejected(dismissed); // Before the exiting dialog is disposed.
      await tester.pumpAndSettle();
      expect(find.byType(GlobalSettingsDialog), findsNothing);
      await _open(tester);
      await _edit(tester, 'office', 'Office');
      _expectRejected(dismissed); // New dialog, same durable identity.
      expect(_within(start, 'Draft: 1'), findsOneWidget);

      await _tap(tester, _within(start, 'Use 2'));
      final retired = _captureProposal(tester, start);
      await frontends.generations.single.close();
      _expectRejected(retired);
      await tester.pumpAndSettle();
      expect(
        _within(start, 'Field editor unavailable: $_editor'),
        findsOneWidget,
      );
      expect(_within(start, 'Use 2'), findsNothing);
      expect(file('office').readAsBytesSync(), original);
      await _enter(tester, _input('caption', 'office'), 'After retirement');
      await _tap(tester, _key('record-save-$_collection-office'));
      await _ready(tester, 'records-reload-$_collection');
      expect(await saved(), {
        'office': {...values, 'caption': 'After retirement', 'start': 2},
      });
      await _dismiss(tester);
    }),
    skip: !Platform.isLinux,
  );
}

Finder _key(String key) => find.byKey(ValueKey(key));
Finder _input(String field, [String? id]) =>
    _key('record-input-$_collection${id == null ? '' : '-$id'}-$field');
Finder _within(Finder field, String text) =>
    find.descendant(of: field, matching: find.text(text));

// Exercise the actual Material callback after its owner departs, and check its
// return *inside the original EVC runtime*. Merely observing no file writes
// would not distinguish a rejected proposal from mutation of a detached draft.
String Function() _captureProposal(WidgetTester tester, Finder field) {
  final button = tester
      .widget<TextButton>(
        find.descendant(
          of: field,
          matching: find.widgetWithText(TextButton, 'Delayed 7'),
        ),
      )
      .onPressed!;
  final runtime = tester
      .widget<$StatefulWidget$bridge>(
        find.descendant(
          of: field,
          matching: find.byWidgetPredicate((w) => w is $StatefulWidget$bridge),
        ),
      )
      .$runtime;
  return () {
    button();
    return copyStructuredBridgeData(runtime.executeLib(_library, 'takeReceipt'))
        as String;
  };
}

void _expectRejected(String Function() propose) {
  final result = propose();
  expect(result, startsWith('rejected: '));
  expect(result, isNot('rejected: '));
}

bool _enabled(WidgetTester tester, Finder button) =>
    button.evaluate().isNotEmpty &&
    tester.widget<ButtonStyleButton>(button).onPressed != null;

Future<void> _ready(WidgetTester tester, String key) async {
  final deadline = DateTime.now().add(const Duration(seconds: 10));
  while (!_enabled(tester, _key(key))) {
    if (DateTime.now().isAfter(deadline)) fail('$key did not become ready.');
    await Future<void>.delayed(const Duration(milliseconds: 10));
    await tester.pump(const Duration(milliseconds: 20));
  }
  await tester.pumpAndSettle();
}

Future<void> _tap(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pump();
}

Future<void> _enter(WidgetTester tester, Finder input, String text) async {
  await tester.ensureVisible(input);
  await tester.enterText(input, text);
  await tester.pump();
}

Future<void> _open(WidgetTester tester) async {
  await _tap(tester, find.text('Open settings'));
  await _ready(tester, 'settings-reload');
  await _tap(tester, _key('settings-section'));
  await tester.pumpAndSettle();
  await tester.tap(find.text('Windows').last);
  await tester.pump();
  await _ready(tester, 'records-reload-$_collection');
}

Future<void> _edit(WidgetTester tester, String id, String title) async {
  await _tap(tester, find.text(title));
  await tester.pumpAndSettle();
  await _tap(tester, _key('record-edit-$_collection-$id'));
}

Future<void> _dismiss(WidgetTester tester) async {
  await _tap(tester, find.byTooltip('Close Settings'));
  await tester.pumpAndSettle();
  expect(find.byType(GlobalSettingsDialog), findsNothing);
  expect(tester.takeException(), isNull);
}

const _source = r'''
import 'package:flutter/material.dart';
import 'package:adele_ui/settings_field_editor_bridge.dart';

String receipt = 'not invoked';
String takeReceipt() {
  final result = receipt;
  receipt = 'not invoked';
  return result;
}
Widget editor() => StepEditor();
class StepEditor extends StatefulWidget {
  @override
  State<StepEditor> createState() => StepEditorState();
}
class StepEditorState extends State<StepEditor> {
  String result = 'not invoked';
  void propose(int revision, Object? value) {
    result = proposeSettingsFieldValue(revision, value) ?? 'accepted';
    setState(() {});
  }
  @override
  Widget build(BuildContext context) {
    final revision = readSettingsFieldRevision();
    final value = readSettingsFieldValue();
    final error = readSettingsFieldError() ?? 'valid';
    if (!settingsFieldEditingEnabled()) return Text('Editing disabled');
    return Column(children: <Widget>[
      Text('Draft: ' + (value == null ? 'unset' : value.toString())),
      Text('Validation: ' + error),
      Text('Result: ' + result),
      Row(children: <Widget>[
        TextButton(onPressed: () => propose(revision, 2), child: Text('Use 2')),
        TextButton(onPressed: () => propose(revision, 4), child: Text('Use 4')),
        TextButton(onPressed: () => propose(revision, 99), child: Text('Use 99')),
        TextButton(onPressed: () => propose(revision, '4'), child: Text('Use text')),
        TextButton(onPressed: () {
          final rejected = proposeSettingsFieldValue(revision, 7);
          receipt = rejected == null ? 'accepted' : 'rejected: ' + rejected;
        }, child: Text('Delayed 7')),
      ]),
    ]);
  }
}
''';
