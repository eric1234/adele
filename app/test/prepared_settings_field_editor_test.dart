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
import 'package:adele_ui/adele_ui.dart' show settingsFormBehaviorContributions;
import 'package:dart_eval/dart_eval.dart';
import 'package:flutter/material.dart';
import 'package:flutter_eval/flutter_eval.dart';
import 'package:flutter_eval/widgets.dart' show $StatefulWidget$bridge;
import 'package:flutter_test/flutter_test.dart';
import 'package:plugin_runtime/plugin_runtime.dart';

const _plugin = 'dev.example.windows';
const _library = 'package:window_controls/editor.dart';
const _editor = '$_plugin.step';
const _layoutEditor = '$_plugin.layout';
const _behavior = '$_plugin.finishes';
const _unavailable =
    'Form customization unavailable. Showing declared controls.';
const _missing = '$_plugin.uninstalled';
const _collection = 'windows';
final _type = RecordTypeId('$_plugin.window');
final _layoutType = RecordTypeId('$_plugin.zoned');
const _layout = {'name': 'stacked', 'columns': 2, 'locked': true};

void main() {
  late List<int> bytes;
  late PlatformStorageRoots roots;
  late _DialogService settings;
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
            'filenameField': 'caption',
            'formBehavior': _behavior,
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
              {
                'id': 'finish',
                'label': 'Finish',
                'type': 'enum',
                'required': false,
                'unsetLabel': 'No finish',
                'options': [
                  for (final value in ['matte', 'satin', 'gloss'])
                    {'value': value},
                ],
              },
              {
                'id': 'offset',
                'label': 'Offset',
                'type': 'integer',
                'required': false,
                'minimum': 1,
                'maximum': 8,
                'editor': {'extensionId': _editor},
              },
              {
                'id': 'width',
                'label': 'Width',
                'type': 'integer',
                'required': false,
              },
            ],
          },
          {
            'id': _layoutType.value,
            'collection': _collection,
            'collectionLabel': 'Windows',
            'label': 'Zoned window',
            'displayField': 'caption',
            'formBehavior': '$_plugin.not-installed',
            'fields': [
              {
                'id': 'caption',
                'label': 'Caption',
                'type': 'string',
                'required': true,
              },
              {
                'id': 'layout',
                'label': 'Layout',
                'type': 'struct',
                'required': true,
                'editor': {'extensionId': _layoutEditor},
                'properties': [
                  {'id': 'name', 'type': 'string'},
                  {
                    'id': 'columns',
                    'type': 'integer',
                    'minimum': 1,
                    'maximum': 8,
                  },
                  {'id': 'locked', 'type': 'boolean'},
                ],
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
            'extensions': [
              {
                'kind': 'settingsFormBehavior',
                'extensionId': _behavior,
                'library': _library,
                'entrypoint': 'finishes',
              },
            ],
            'presentations': [
              {
                'role': 'settingsFieldEditor',
                'extensionId': _editor,
                'library': _library,
                'entrypoint': 'editor',
              },
              {
                'role': 'settingsFieldEditor',
                'extensionId': _layoutEditor,
                'library': _library,
                'entrypoint': 'layoutEditor',
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
    _DialogService owner() => _DialogService(
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
      final start = _input('start');
      final end = _input('end');
      final create = _key('record-create-$_collection');
      expect(_within(start, 'Build edit: rejected'), findsOneWidget);
      expect(_choices(tester), unorderedEquals([null, 'matte', 'satin']));
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
      final beforeInvalidName = tester
          .widget<ButtonStyleButton>(create)
          .onPressed!;
      await _enter(tester, _input('caption'), '---');
      expect(_enabled(tester, create), isFalse);
      beforeInvalidName();
      await _enter(tester, _input('caption'), 'Morning / shift');
      expect(_within(start, 'Draft: 2'), findsOneWidget);
      expect(_within(end, 'Draft: 4'), findsOneWidget);
      expect(_enabled(tester, create), isTrue);
      final namedFile = file('morning-shift');
      expect(namedFile.existsSync(), isFalse);
      expect(await saved(), isEmpty);
      await _tap(tester, create);
      await _ready(tester, 'records-reload-$_collection');
      final record = (await saved()).entries.single;
      final id = record.key;
      expect(_key('record-$_collection-$id'), findsOneWidget);
      expect(record.value, {
        'caption': 'Morning / shift',
        'start': 2,
        'end': 4,
      });
      final document = namedFile.readAsStringSync();
      expect(document, contains('recordId = "$id"'));
      expect(document, contains('recordType = "$_type"'));
      expect(document, isNot(contains(_editor)));
      expect(file(id).existsSync(), isFalse);
      await _dismiss(tester);
    }),
    skip: !Platform.isLinux,
  );

  testWidgets(
    'optional compiled editor supplies an absent value; only the host clears it',
    (tester) => tester.runAsync(() async {
      const id = 'office';
      const baseline = {'caption': 'Office', 'start': 2, 'end': 4};
      await seed(id, baseline);
      await mount(tester);
      await _edit(tester, id, 'Office');
      final offset = _input('offset', id);
      final clear = _key('record-clear-$_collection-$id-offset');
      final save = _key('record-save-$_collection-$id');
      void expectUnset() {
        expect(_within(offset, 'Draft: unset'), findsOneWidget);
        expect(_within(offset, 'Validation: valid'), findsOneWidget);
        expect(_within(offset, 'Build edit: rejected'), findsOneWidget);
        expect(_enabled(tester, save), isTrue);
      }

      expect(_key('record-presence-$_collection-$id-offset'), findsNothing);
      expectUnset();
      final supply = _captureProposal(tester, offset);
      await _tap(tester, _within(offset, 'Use 99'));
      expect(_within(offset, 'Result: Must be at most 8.'), findsOneWidget);
      expectUnset();
      expect(supply(), 'accepted'); // Rejection did not consume the revision.
      await tester.pump();
      expect(find.text('Offset: 7 / offset / satin'), findsOneWidget);
      expect(await saved(), {id: baseline});
      await _tap(tester, save);
      await _ready(tester, 'records-reload-$_collection');
      expect(await saved(), {
        id: {...baseline, 'offset': 7},
      });

      await _tap(tester, _key('record-edit-$_collection-$id'));
      expect(_within(offset, 'Draft: 7'), findsOneWidget);
      await _tap(tester, _within(offset, 'Propose null'));
      expect(
        _within(offset, 'Result: Expected a native Dart int.'),
        findsOneWidget,
      );
      expect(_within(offset, 'Draft: 7'), findsOneWidget);
      // Re-publish context on this form so the host clear must also remove it.
      expect(
        _captureProposal(tester, offset, label: 'Observe matte')(),
        'accepted',
      );
      await tester.pump();
      expect(find.text('Offset: 7 / initial / matte'), findsOneWidget);
      final stale = _captureProposal(tester, offset);
      await tester.ensureVisible(clear);
      await tester.tap(clear);
      _expectRejected(stale); // No rebuild or disposal has happened yet.
      await tester.pump();
      expectUnset();
      expect(find.text('Offset: absent / offset / unknown'), findsOneWidget);
      _expectRejected(stale);
      expect(await saved(), {
        id: {...baseline, 'offset': 7},
      });
      // A fresh editor can still supply a value; the retained one cannot.
      await _tap(tester, _within(offset, 'Use 2'));
      expect(_within(offset, 'Draft: 2'), findsOneWidget);
      _expectRejected(stale);
      await _tap(tester, clear);
      expectUnset();
      await _tap(tester, save);
      await _ready(tester, 'records-reload-$_collection');
      expect(await saved(), {id: baseline});
      expect(file(id).readAsStringSync(), isNot(contains('offset =')));
      await _dismiss(tester);
    }),
    skip: !Platform.isLinux,
  );

  testWidgets(
    'compiled behavior distinguishes absence, zero and invalid optional input on every edit',
    (tester) => tester.runAsync(() async {
      const id = 'office';
      const baseline = {
        'caption': 'Office',
        'start': 2,
        'end': 4,
        'width': 3,
        'finish': 'satin',
      };
      await seed(id, baseline);
      await mount(tester);
      await _edit(tester, id, 'Office');
      final width = _input('width', id);
      final caption = _input('caption', id);
      final save = _key('record-save-$_collection-$id');
      expect(find.text('Width: 3 / initial'), findsOneWidget);
      await _enter(
        tester,
        caption,
        'Renamed',
      ); // Keep the draft dirty throughout.
      expect(find.text('Width: 3 / caption'), findsOneWidget);

      final choose = _finish(tester, id).onChanged!;
      await _enter(tester, width, '0');
      expect(find.text('Width: 0 / width'), findsOneWidget);
      expect(_choices(tester, id), unorderedEquals([null, 'gloss']));
      choose('matte'); // The prior callback cannot bypass the new restriction.
      await tester.pump();
      expect(_finish(tester, id).value, 'satin');
      expect(_enabled(tester, save), isTrue);
      await _enter(tester, width, '');
      expect(find.text('Width: absent / width'), findsOneWidget);
      expect(_choices(tester, id), unorderedEquals([null, 'matte', 'satin']));
      expect(_enabled(tester, save), isTrue);
      await _enter(tester, width, 'broken');
      expect(find.text('Width: invalid / width'), findsOneWidget);
      expect(_enabled(tester, save), isFalse);
      await _enter(tester, width, '3'); // Return to the original field value.
      expect(find.text('Width: 3 / width'), findsOneWidget);
      expect(_enabled(tester, save), isTrue);

      final offset = _input('offset', id);
      final beforePause = _captureProposal(tester, offset);
      await _enter(tester, caption, 'paused');
      expect(tester.widget<TextField>(width).enabled, isFalse);
      expect(_finish(tester, id).onChanged, isNull);
      expect(_within(offset, 'Editing disabled'), findsOneWidget);
      _expectRejected(beforePause);
      await _enter(tester, caption, 'bad field');
      expect(find.text(_unavailable), findsOneWidget);
      expect(find.textContaining('Width: 3 /'), findsNothing);
      expect(tester.widget<TextField>(width).enabled, isTrue);
      expect(tester.widget<TextField>(width).controller!.text, '3');
      expect(_within(offset, 'Draft: unset'), findsOneWidget);
      expect(_finish(tester, id).value, 'satin');
      expect(
        _choices(tester, id),
        unorderedEquals([null, 'matte', 'satin', 'gloss']),
      );
      _finish(tester, id).onChanged!('gloss');
      await tester.pump();
      expect(_finish(tester, id).value, 'gloss');
      expect(await saved(), {id: baseline});
      await _tap(tester, save);
      await _ready(tester, 'records-reload-$_collection');
      expect(await saved(), {
        id: {...baseline, 'caption': 'bad field', 'finish': 'gloss'},
      });
      await _dismiss(tester);
    }),
    skip: !Platform.isLinux,
  );

  testWidgets(
    'compiled behavior observes initial values, every edit, reversion and copied same-value context',
    (tester) => tester.runAsync(() async {
      const id = 'office';
      const baseline = {
        'caption': 'Office',
        'start': 2,
        'end': 4,
        'finish': 'gloss',
      };
      await seed(id, baseline);
      await mount(tester);
      await _edit(tester, id, 'Office');
      void guidance(String caption, String changed, String observed) => expect(
        find.text('Window: $caption / $changed / $observed'),
        findsOneWidget,
      );
      final caption = _input('caption', id);
      final start = _input('start', id);
      guidance('Office', 'initial', 'unknown');
      for (final next in ['First edit', 'Already dirty', 'paused', 'Office']) {
        await _enter(tester, caption, next);
        guidance(next, 'caption', 'unknown');
        expect(_finish(tester, id).onChanged != null, next != 'paused');
      }
      final choose = _finish(tester, id).onChanged!;
      final observe = _captureProposal(tester, start, label: 'Observe matte');
      final bad = _captureProposal(tester, start, label: 'Invalid observation');
      _expectRejected(bad);
      expect(observe(), 'accepted'); // Rejection did not consume the revision.
      // Now filtered out; even the pre-frame callback cannot set it.
      choose('satin');
      _expectRejected(observe);
      await tester.pump();
      guidance('Office', 'initial', 'matte'); // Value unchanged, fresh context.
      expect(_within(start, 'Draft: 2'), findsOneWidget);
      expect(_choices(tester, id), isNot(contains('satin')));
      expect(_finish(tester, id).value, 'gloss');
      await _enter(tester, caption, 'Later');
      // Plugin mutated its list after submit.
      guidance('Later', 'caption', 'matte');
      _expectRejected(
        _captureProposal(tester, start, label: 'Invalid observation'),
      );
      await tester.pump();
      guidance('Later', 'caption', 'matte');
      expect(_within(start, 'Draft: 2'), findsOneWidget);
      // A same-value proposal with no context removes a previous observation.
      await _tap(tester, _within(start, 'Use 2'));
      guidance('Later', 'initial', 'unknown');
      expect(_choices(tester, id), contains('satin'));
      expect(await saved(), {id: baseline});
      await _tap(tester, _key('record-save-$_collection-$id'));
      await _ready(tester, 'records-reload-$_collection');
      // Neither filtering nor editing other fields silently unsets an unsupported value.
      expect(await saved(), {
        id: {...baseline, 'caption': 'Later'},
      });
      expect(file(id).readAsStringSync(), isNot(contains('matte')));
      await _dismiss(tester);
    }),
    skip: !Platform.isLinux,
  );

  testWidgets(
    'malformed overrides and illegal clear requests fall back atomically; explicit clear is draft-only',
    (tester) => tester.runAsync(() async {
      const id = 'office';
      const baseline = {
        'caption': 'clear on open',
        'start': 2,
        'end': 4,
        'finish': 'satin',
      };
      await seed(id, baseline);
      await mount(tester);
      await _edit(tester, id, 'clear on open');
      final caption = _input('caption', id);
      final save = _key('record-save-$_collection-$id');
      final finish = _input('finish', id);
      expect(_key('record-presence-$_collection-$id-finish'), findsNothing);
      // Even a valid optional target cannot be cleared by opening a form.
      expect(find.text(_unavailable), findsOneWidget);
      expect(_finish(tester, id).value, 'satin');
      await _enter(tester, caption, 'New caption');
      expect(_choices(tester, id), unorderedEquals([null, 'matte', 'satin']));
      for (final invalid in [
        'bad field',
        'bad choices',
        'choices on text',
        'duplicate choices',
        'bad shape',
        'bad clear',
        'non-enum clear',
        'foreign clear',
      ]) {
        await _enter(tester, caption, invalid);
        expect(find.text(_unavailable), findsOneWidget, reason: invalid);
        expect(find.textContaining('Window: $invalid'), findsNothing);
        expect(
          _choices(tester, id),
          unorderedEquals([null, 'matte', 'satin', 'gloss']),
        );
        expect(_finish(tester, id).value, 'satin');
        expect(_enabled(tester, save), isTrue);
      }
      await _enter(tester, caption, 'clear');
      expect(find.text(_unavailable), findsNothing);
      expect(_finish(tester, id).value, isNull);
      expect(_choices(tester, id), unorderedEquals([null, 'matte', 'satin']));
      await _tap(tester, finish);
      await tester.pumpAndSettle();
      await _tap(tester, find.text('satin').last);
      await tester.pumpAndSettle();
      expect(_finish(tester, id).value, 'satin');
      await _tap(tester, finish);
      await tester.pumpAndSettle();
      await _tap(tester, find.text('No finish').last);
      await tester.pumpAndSettle();
      expect(_finish(tester, id).value, isNull);
      expect(await saved(), {id: baseline});
      await _tap(tester, save);
      await _ready(tester, 'records-reload-$_collection');
      expect(await saved(), {
        id: {'caption': 'clear', 'start': 2, 'end': 4},
      });
      expect(
        file('clear-on-open').readAsStringSync(),
        isNot(contains('finish =')),
      );
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
      await _tap(tester, _key('records-add-$_collection'));
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
      expect(
        _captureProposal(tester, left, label: 'Observe matte')(),
        'accepted',
      );
      await tester.pump();
      expect(_choices(tester, 'early'), unorderedEquals([null, 'matte']));
      expect(
        _choices(tester, 'late'),
        unorderedEquals([null, 'matte', 'satin']),
      );
      expect(_captureProposal(tester, _input('start'))(), 'accepted');
      await tester.pump();
      expect(_choices(tester), unorderedEquals([null, 'satin']));
      expect(_choices(tester, 'early'), unorderedEquals([null, 'matte']));
      // Positive control for the very callback retained in the fencing tests.
      expect(_captureProposal(tester, right)(), 'accepted');
      expect(await saved(), {'early': early, 'late': lateWindow});
      await _tap(tester, _key('record-save-$_collection-late'));
      await _ready(tester, 'records-reload-$_collection');
      expect(file('early').readAsBytesSync(), original);
      expect(file('late').readAsStringSync(), contains('New title'));
      expect(_within(left, 'Draft: 4'), findsOneWidget);
      expect(_choices(tester), unorderedEquals([null, 'satin']));
      final cancelled = _captureProposal(tester, left);
      final absent = _captureProposal(tester, _input('offset', 'early'));
      tester
          .widget<ButtonStyleButton>(_key('record-cancel-$_collection-early'))
          .onPressed!();
      _expectRejected(cancelled);
      _expectRejected(absent);
      await tester.pump();
      await _tap(tester, _key('record-edit-$_collection-early'));
      expect(_within(left, 'Draft: 1'), findsOneWidget);
      _expectRejected(absent);
      expect(
        _within(_input('offset', 'early'), 'Draft: unset'),
        findsOneWidget,
      );
      expect(
        _choices(tester, 'early'),
        unorderedEquals([null, 'matte', 'satin']),
      );
      expect(file('early').readAsBytesSync(), original);
      // An unavailable editor does not disable generic controls or lose its value.
      await _enter(tester, _input('caption', 'early'), 'Rename only');
      await _tap(tester, _key('record-save-$_collection-early'));
      await _ready(tester, 'records-reload-$_collection');
      expect(await saved(), {
        'early': {...early, 'caption': 'Rename only'},
        'late': {...lateWindow, 'caption': 'New title', 'end': 7},
      });
      final reloaded = _captureProposal(tester, _input('start'));
      tester
          .widget<ButtonStyleButton>(_key('records-reload-$_collection'))
          .onPressed!();
      _expectRejected(reloaded); // Reload admission, before the next frame.
      await tester.pump();
      await _ready(tester, 'records-reload-$_collection');
      expect(_within(_input('start'), 'Draft: 7'), findsOneWidget);
      expect(_choices(tester), unorderedEquals([null, 'matte', 'satin']));
      _expectRejected(reloaded);
      await _dismiss(tester);
    }),
    skip: !Platform.isLinux,
  );

  testWidgets(
    'compiled structured proposals are complete immutable replacements until Create',
    (tester) => tester.runAsync(() async {
      await mount(tester);
      await _tap(tester, _key('records-add-$_collection'));
      tester
          .widget<DropdownButtonFormField<RecordTypeId>>(
            _key('record-type-$_collection'),
          )
          .onChanged!(_layoutType);
      await tester.pumpAndSettle();
      final layout = _input('layout');
      expect(find.text(_unavailable), findsOneWidget);
      final create = _key('record-create-$_collection');
      expect(_enabled(tester, create), isFalse);
      expect(_within(layout, 'Layout: unset'), findsOneWidget);
      final original = _captureProposal(
        tester,
        layout,
        label: 'Delayed layout',
      );
      await _tap(tester, _within(layout, 'Set layout'));
      // The editor mutates its own proposed map after submitting it. Only the
      // complete original value is visible to the next interpreted read.
      expect(_within(layout, 'Layout: stacked / 2 / true'), findsOneWidget);
      _expectRejected(original);
      expect(_enabled(tester, create), isTrue);
      final afterAcceptance = _captureProposal(
        tester,
        layout,
        label: 'Delayed layout',
      );
      for (final invalid in [
        'Partial',
        'Extra',
        'Wrong type',
        'Out of range',
      ]) {
        await _tap(tester, _within(layout, invalid));
        expect(_within(layout, 'Result: rejected'), findsOneWidget);
        expect(_within(layout, 'Layout: stacked / 2 / true'), findsOneWidget);
      }
      // Rejections neither dirtied another field nor consumed the revision.
      expect(afterAcceptance(), 'accepted');
      expect(await saved(), isEmpty);
      await _tap(tester, create);
      await _ready(tester, 'records-reload-$_collection');
      final record = (await saved()).entries.single;
      expect(_key('record-$_collection-${record.key}'), findsOneWidget);
      expect(record.value, {'caption': '', 'layout': _layout});
      expect(
        file(record.key).readAsStringSync(),
        contains('recordId = "${record.key}"'),
      );
      _expectRejected(afterAcceptance);
      await _dismiss(tester);
    }),
    skip: !Platform.isLinux,
  );

  testWidgets(
    'structured dirty detection is structural; navigation and retirement fence old editors',
    (tester) => tester.runAsync(() async {
      const id = 'office';
      final reload = _key('records-reload-$_collection');
      final layout = _input('layout', id);
      final baseline = {'caption': 'Office', 'layout': _layout};
      await settings.createRecord(
        _layoutType,
        ConfigurationRecordId(id),
        baseline,
      );
      final original = file(id).readAsBytesSync();
      await mount(tester);
      await _edit(tester, id, 'Office');
      final same = _captureProposal(tester, layout, label: 'Delayed layout');
      expect(
        same(),
        'accepted',
      ); // A fresh map, equal properties in another order.
      await _tap(tester, reload);
      await _ready(tester, 'records-reload-$_collection'); // No discard prompt.
      _expectRejected(same);
      await _tap(tester, _key('record-edit-$_collection-$id'));
      await _tap(tester, _within(layout, 'Set wide layout'));
      await _tap(tester, reload);
      await _tap(tester, _key('records-reload-cancel-$_collection'));
      await _ready(tester, 'records-reload-$_collection');
      expect(_within(layout, 'Layout: wide / 4 / false'), findsOneWidget);
      final old = _captureProposal(tester, layout, label: 'Delayed layout');
      final navigate = tester
          .widget<DropdownButtonFormField<String>>(_key('settings-section'))
          .onChanged!;
      navigate('');
      navigate(_collection);
      _expectRejected(
        old,
      ); // Leaving and returning before any intervening frame.
      await tester.pumpAndSettle();
      expect(_within(layout, 'Layout: wide / 4 / false'), findsOneWidget);
      await _tap(tester, _key('record-cancel-$_collection-$id'));
      await _tap(tester, _key('record-edit-$_collection-$id'));
      expect(_within(layout, 'Layout: stacked / 2 / true'), findsOneWidget);
      final retired = _captureProposal(tester, layout, label: 'Delayed layout');
      await frontends.generations.single.close();
      _expectRejected(retired);
      await tester.pumpAndSettle();
      expect(
        _within(layout, 'Field editor unavailable: $_layoutEditor'),
        findsOneWidget,
      );
      expect(file(id).readAsBytesSync(), original);
      await _enter(tester, _input('caption', id), 'New title');
      await _tap(tester, _key('record-save-$_collection-$id'));
      await _ready(tester, 'records-reload-$_collection');
      expect(await saved(), {
        id: {...baseline, 'caption': 'New title'},
      });
      expect(
        find.text('Layout:\n  name: stacked\n  columns: 2\n  locked: true'),
        findsOneWidget,
      );
      await _dismiss(tester);
    }),
    skip: !Platform.isLinux,
  );

  for (final lostReply in [false, true]) {
    testWidgets(
      '${lostReply ? "Unconfirmed" : "Stale"} structured Save is fenced until deliberate Reload',
      (tester) => tester.runAsync(() async {
        const id = 'office';
        final layout = _input('layout', id);
        final save = _key('record-save-$_collection-$id');
        await settings.createRecord(_layoutType, ConfigurationRecordId(id), {
          'caption': 'Office',
          'layout': _layout,
        });
        await mount(tester);
        await _edit(tester, id, 'Office');
        await _tap(tester, _within(layout, 'Set wide layout'));
        final previous = _captureProposal(
          tester,
          layout,
          label: 'Delayed layout',
        );
        final oldSave = tester.widget<ButtonStyleButton>(save).onPressed!;
        if (lostReply) {
          settings.loseUpdateReply = true;
        } else {
          final record = file(id);
          record.writeAsStringSync(
            record.readAsStringSync().replaceFirst('stacked', 'external'),
          );
        }
        await _tap(tester, save);
        await _ready(tester, 'records-reload-$_collection');
        expect(
          find.textContaining(
            lostReply
                ? 'Could not confirm save'
                : 'this record changed on disk',
          ),
          findsOneWidget,
        );
        expect(_enabled(tester, save), isFalse);
        expect(_within(layout, 'Layout: wide / 4 / false'), findsOneWidget);
        _expectRejected(previous);
        _expectRejected(
          _captureProposal(tester, layout, label: 'Delayed layout'),
        );
        oldSave();
        expect(settings.updates, 1);
        expect(await saved(), {
          id: {
            'caption': 'Office',
            'layout': lostReply
                ? {'name': 'wide', 'columns': 4, 'locked': false}
                : {..._layout, 'name': 'external'},
          },
        });
        await _tap(tester, _key('records-reload-$_collection'));
        await _tap(tester, _key('records-reload-confirm-$_collection'));
        await _ready(tester, 'records-reload-$_collection');
        await _tap(tester, _key('record-edit-$_collection-$id'));
        expect(_enabled(tester, save), isTrue);
        expect(
          _within(
            layout,
            lostReply
                ? 'Layout: wide / 4 / false'
                : 'Layout: external / 2 / true',
          ),
          findsOneWidget,
        );
        _expectRejected(previous);
        expect(settings.updates, 1);
        await _dismiss(tester);
      }),
      skip: !Platform.isLinux,
    );
  }

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
      expect(
        _captureProposal(tester, start, label: 'Observe matte')(),
        'accepted',
      );
      await tester.pump();
      expect(_choices(tester, 'office'), unorderedEquals([null, 'matte']));
      final hidden = _captureProposal(tester, start);
      final offset = _input('offset', 'office');
      final hiddenOptional = _captureProposal(tester, offset);
      final select = tester
          .widget<DropdownButtonFormField<String>>(_key('settings-section'))
          .onChanged!;
      select('');
      select(_collection);
      _expectRejected(hidden); // No intervening frame is necessary.
      _expectRejected(hiddenOptional);
      await tester.pumpAndSettle();
      expect(_within(start, 'Draft: 4'), findsOneWidget);
      expect(_within(offset, 'Draft: unset'), findsOneWidget);
      expect(
        _choices(tester, 'office'),
        unorderedEquals([null, 'matte', 'satin']),
      );

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
      expect(
        _captureProposal(tester, start, label: 'Observe matte')(),
        'accepted',
      );
      await tester.pump();
      expect(_choices(tester, 'office'), unorderedEquals([null, 'matte']));
      // Retiring just the behavior restores ordinary inputs; the field editor
      // remains independently live and no previous observation is replayed.
      await frontends.generations.single.retire(
        settingsFormBehaviorContributions,
        ExtensionId(_behavior),
      );
      await tester.pumpAndSettle();
      expect(find.text(_unavailable), findsOneWidget);
      expect(
        _choices(tester, 'office'),
        unorderedEquals([null, 'matte', 'satin', 'gloss']),
      );
      final retired = _captureProposal(tester, start);
      final retiredOptional = _captureProposal(tester, offset);
      await frontends.generations.single.close();
      _expectRejected(retired);
      _expectRejected(retiredOptional);
      await tester.pumpAndSettle();
      expect(
        _within(start, 'Field editor unavailable: $_editor'),
        findsOneWidget,
      );
      expect(_within(start, 'Use 2'), findsNothing);
      expect(
        _within(offset, 'Field editor unavailable: $_editor'),
        findsOneWidget,
      );
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

final class _DialogService extends GlobalSettingsService {
  _DialogService({
    required super.catalog,
    required super.roots,
    required super.records,
  });
  bool loseUpdateReply = false;
  int updates = 0;

  @override
  Future<RecordView> updateRecord(
    RecordView expected,
    Map<String, Object?> values,
  ) async {
    updates++;
    final saved = await super.updateRecord(expected, values);
    if (loseUpdateReply) {
      throw const FileSystemException('Acknowledgement lost');
    }
    return saved;
  }
}

Finder _key(String key) => find.byKey(ValueKey(key));
Finder _input(String field, [String? id]) =>
    _key('record-input-$_collection${id == null ? '' : '-$id'}-$field');
DropdownButton<String> _finish(WidgetTester tester, [String? id]) =>
    tester.widget<DropdownButton<String>>(_input('finish', id));
Iterable<String?> _choices(WidgetTester tester, [String? id]) => _finish(
  tester,
  id,
).items!.where((item) => item.enabled).map((item) => item.value);
Finder _within(Finder field, String text) =>
    find.descendant(of: field, matching: find.text(text));

// Exercise the actual Material callback after its owner departs, and check its
// return *inside the original EVC runtime*. Merely observing no file writes
// would not distinguish a rejected proposal from mutation of a detached draft.
String Function() _captureProposal(
  WidgetTester tester,
  Finder field, {
  String label = 'Delayed 7',
}) {
  final button = tester
      .widget<TextButton>(
        find.descendant(
          of: field,
          matching: find.widgetWithText(TextButton, label),
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
  await tester.pump(); // Initial behavior evaluation is admitted after mount.
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
Widget layoutEditor() => LayoutEditor();

String describe(Map<String, Object?> values, String id) {
  if (!values.containsKey(id)) return 'absent';
  final value = values[id];
  return value == null ? 'invalid' : value.toString();
}

Map<String, Object> finishes(Map<String, Object?> values, Map<String, List<String>> contexts, String? changedField) {
  final caption = values['caption'] as String? ?? '';
  final observed = contexts['start'];
  final options = observed ?? (values['width'] == 0 ? <String>['gloss'] : <String>['matte', 'satin']);
  final which = changedField ?? 'initial';
  final field = <String, Object>{
    'enabled': caption != 'paused',
    'choices': options,
    'guidance': 'Window: ' + caption + ' / ' + which + ' / ' + (observed == null ? 'unknown' : observed.join(',')),
  };
  final offsetContext = contexts['offset'];
  final fields = <String, Object>{
    'finish': field,
    'width': <String, Object>{
      'enabled': caption != 'paused',
      'guidance': 'Width: ' + describe(values, 'width') + ' / ' + which,
    },
    'offset': <String, Object>{
      'enabled': caption != 'paused',
      'guidance': 'Offset: ' + describe(values, 'offset') + ' / ' + which + ' / ' + (offsetContext == null ? 'unknown' : offsetContext.join(',')),
    },
  };
  final result = <String, Object>{'fields': fields};
  if (caption == 'bad field') fields['foreign'] = <String, Object>{'enabled': false};
  if (caption == 'bad choices') field['choices'] = <String>['matte', 'undeclared'];
  if (caption == 'duplicate choices') field['choices'] = <String>['matte', 'matte'];
  if (caption == 'choices on text') fields['caption'] = <String, Object>{'choices': options};
  if (caption == 'bad shape') field['enabled'] = 'yes';
  if (caption == 'bad clear') result['clear'] = 'caption';
  if (caption == 'non-enum clear') result['clear'] = 'note';
  if (caption == 'foreign clear') result['clear'] = 'outside';
  if (caption == 'bad field' || caption == 'bad choices' || caption == 'bad shape' ||
      caption == 'duplicate choices' || caption == 'choices on text' ||
      (caption == 'clear on open' && changedField == null) ||
      (caption == 'clear' && changedField == 'caption')) result['clear'] = 'finish';
  return result;
}
class LayoutEditor extends StatefulWidget {
  @override
  State<LayoutEditor> createState() => LayoutEditorState();
}
class LayoutEditorState extends State<LayoutEditor> {
  String result = 'not invoked';
  void setLayout(int revision, Object? value) {
    result = proposeSettingsFieldValue(revision, value) == null ? 'accepted' : 'rejected';
    setState(() {});
  }
  @override
  Widget build(BuildContext context) {
    final rev = readSettingsFieldRevision();
    final value = readSettingsFieldValue();
    String summary = 'unset';
    if (value != null) {
      final map = value as Map;
      summary = (map['name'] as String) + ' / ' + map['columns'].toString() + ' / ' + map['locked'].toString();
    }
    return Column(children: <Widget>[
      Text('Layout: ' + summary), Text('Result: ' + result),
      TextButton(onPressed: () {
        final map = <String, Object>{'columns':2, 'locked':true, 'name':'stacked'};
        setLayout(rev, map);
        map['name'] = 'changed after proposal';
      }, child: Text('Set layout')),
      TextButton(onPressed: () => setLayout(rev, <String, Object>{'columns':4, 'locked':false, 'name':'wide'}), child: Text('Set wide layout')),
      TextButton(onPressed: () => setLayout(rev, <String, Object>{'columns':3}), child: Text('Partial')),
      TextButton(onPressed: () => setLayout(rev, <String, Object>{'columns':3, 'locked':true, 'name':'new', 'caption':'out of scope'}), child: Text('Extra')),
      TextButton(onPressed: () => setLayout(rev, <String, Object>{'columns':'3', 'locked':true, 'name':'new'}), child: Text('Wrong type')),
      TextButton(onPressed: () => setLayout(rev, <String, Object>{'columns':9, 'locked':true, 'name':'new'}), child: Text('Out of range')),
      TextButton(onPressed: () {
        final rejected = proposeSettingsFieldValueWithContext(rev, <String, Object>{'locked':true, 'columns':2, 'name':'stacked'}, <String>['layout context']);
        receipt = rejected == null ? 'accepted' : 'rejected: ' + rejected;
      }, child: Text('Delayed layout')),
    ]);
  }
}
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
    String buildEdit = 'not attempted';
    if (value == null) {
      final rejected = proposeSettingsFieldValueWithContext(revision, 8, <String>['gloss']);
      buildEdit = rejected == null ? 'accepted' : 'rejected';
    }
    return Column(children: <Widget>[
      Text('Build edit: ' + buildEdit),
      Text('Draft: ' + (value == null ? 'unset' : value.toString())),
      Text('Validation: ' + error),
      Text('Result: ' + result),
      Row(children: <Widget>[
        TextButton(onPressed: () => propose(revision, 2), child: Text('Use 2')),
        TextButton(onPressed: () => propose(revision, 4), child: Text('Use 4')),
        TextButton(onPressed: () => propose(revision, 99), child: Text('Use 99')),
        TextButton(onPressed: () => propose(revision, '4'), child: Text('Use text')),
        TextButton(onPressed: () {
          final rejected = proposeSettingsFieldValueWithContext(revision, 7, <String>['satin']);
          receipt = rejected == null ? 'accepted' : 'rejected: ' + rejected;
        }, child: Text('Delayed 7')),
      ]),
      TextButton(onPressed: () => propose(revision, null), child: Text('Propose null')),
      Row(children: <Widget>[
        TextButton(onPressed: () {
          final observed = <String>['matte'];
          final error = proposeSettingsFieldValueWithContext(revision, value, observed);
          receipt = error == null ? 'accepted' : 'rejected: ' + error;
          observed[0] = 'gloss';
          if (error == null) setState(() {});
        }, child: Text('Observe matte')),
        TextButton(onPressed: () {
          final observed = <String>[];
          for (int i = 0; i < 33; i++) observed.add('matte');
          final error = proposeSettingsFieldValueWithContext(revision, 8, observed);
          receipt = error == null ? 'accepted' : 'rejected: ' + error;
        }, child: Text('Invalid observation')),
      ]),
    ]);
  }
}
''';
