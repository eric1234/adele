import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:adele_desktop/frontend/application_frontend_bootstrap.dart';
import 'package:adele_desktop/frontend/settings_field_editor_bridge.dart';
import 'package:adele_plugin_api/adele_plugin_api.dart';
import 'package:adele_ui/adele_ui.dart';
import 'package:dart_eval/dart_eval.dart';
import 'package:dart_eval/dart_eval_bridge.dart' show $Value;
import 'package:flutter/widgets.dart';
import 'package:flutter_eval/flutter_eval.dart';
import 'package:flutter_eval/widgets.dart' show $StatelessWidget$bridge;
import 'package:flutter_test/flutter_test.dart';
import 'package:plugin_runtime/plugin_runtime.dart';

const _owner = 'test.editor';
const _library = 'package:ed/main.dart';
final _editor = ExtensionId('$_owner.view');
final _other = ExtensionId('$_owner.other');

void main() {
  late Uint8List bytes;
  late Directory root;
  late ExtensionRegistry registry;
  late ApplicationFrontendBootstrap frontends;

  setUpAll(() {
    bytes =
        (Compiler()
              ..addPlugin(flutterEvalPlugin)
              ..addPlugin(const SettingsFieldEditorDeclarations())
              ..entrypoints.add(_library))
            .compile({
              'ed': {
                'main.dart': '''
import 'package:flutter/widgets.dart';
import 'package:adele_ui/settings_field_editor_bridge.dart';
Widget editor() => Label();
class Label extends StatelessWidget {
  @override
  Widget build(BuildContext context) => Text(readSettingsFieldValue() as String);
}
String? cycle() {
  final map = <String, dynamic>{};
  map['self'] = map;
  return proposeSettingsFieldValue(readSettingsFieldRevision(), map);
}
String? submit() => proposeSettingsFieldValue(0, 'edited');
String? error() => readSettingsFieldError();
bool enabled() => settingsFieldEditingEnabled();
''',
              },
              'adele_ui': {
                'settings_field_editor_bridge.dart': File(
                  '../packages/ui/lib/settings_field_editor_bridge.dart',
                ).readAsStringSync(),
              },
            })
            .write();
  });

  setUp(() async {
    root = await Directory.systemTemp.createTemp('prepared-field-editor-');
    registry = ExtensionRegistry();
    frontends = ApplicationFrontendBootstrap(extensions: registry);
  });
  tearDown(() async {
    await frontends.close();
    await root.delete(recursive: true);
  });

  Future<PreparedPluginCatalog> install(
    List<ExtensionId> ids, {
    String entrypoint = 'editor',
  }) async {
    final directory = await Directory('${root.path}/owner').create();
    await File('${directory.path}/frontend.evc').writeAsBytes(bytes);
    await File('${directory.path}/records.json').writeAsString(
      jsonEncode({
        'schemaVersion': 1,
        'recordTypes': [
          {
            'id': '$_owner.record',
            'collection': 'records',
            'collectionLabel': 'Records',
            'label': 'Record',
            'fields': [
              {
                'id': 'name',
                'label': 'Name',
                'required': true,
                'type': 'string',
                'editor': {'extensionId': _editor.value},
              },
            ],
          },
        ],
      }),
    );
    await File(
      '${directory.path}/adele_plugin.installation.json',
    ).writeAsString(
      jsonEncode({
        'manifestVersion': 1,
        'metadata': {'id': _owner, 'version': '1', 'displayName': 'Fixture'},
        'recordsSchema': 'records.json',
        'components': {
          'frontend': {
            'artifact': 'frontend.evc',
            'presentations': [
              for (final id in ids)
                {
                  'role': 'settingsFieldEditor',
                  'extensionId': id.value,
                  'library': _library,
                  'entrypoint': entrypoint,
                },
            ],
          },
        },
      }),
    );
    return PreparedPluginCatalog.discover(root.path);
  }

  ExtensionRegistration spoof() => registry.register(
    point: settingsFieldEditorContributions,
    id: _editor,
    value: SettingsFieldEditorContribution(
      createPresentation: (_) => fail('Impostor factory invoked.'),
    ),
  );

  test(
    'resolution requires the field declaration in this exact snapshot',
    () async {
      final catalog = await install([_editor, _other]);
      expect(catalog.issues, isEmpty);
      await frontends.start(catalog);
      final type = catalog.records.definitions.single;
      final copied = (await PreparedPluginCatalog.discover(
        root.path,
      )).records.definitions.single;
      expect(copied.id, type.id);
      expect(copied, isNot(same(type)));
      expect(
        frontends.resolveSettingsFieldEditor(copied, copied.fields.single),
        isNull,
      );
      expect(
        frontends.resolveSettingsFieldEditor(type, copied.fields.single),
        isNull,
      );
      final field = type.fields.single;
      final binding = frontends.resolveSettingsFieldEditor(type, field)!;
      expect(
        frontends.generations.single.registrations.any((r) => r.owns(binding)),
        isTrue,
      );

      await frontends.generations.single.retire(
        settingsFieldEditorContributions,
        _editor,
      );
      final replacement = spoof();
      addTearDown(replacement.close);
      expect(
        registry
            .discover(settingsFieldEditorContributions)
            .any(replacement.owns),
        isTrue,
      );
      expect(binding.validate, throwsA(isA<StaleExtensionBinding>()));
      expect(frontends.resolveSettingsFieldEditor(type, field), isNull);
    },
  );

  test(
    'duplicate registration rolls back sibling without adopting impostor',
    () async {
      final catalog = await install([_other, _editor]);
      final impostor = spoof();
      addTearDown(impostor.close);
      await frontends.start(catalog);
      expect(
        frontends.generations.single.failure,
        isA<ExtensionRegistrationException>(),
      );
      expect(
        impostor.owns(
          registry.discover(settingsFieldEditorContributions).single,
        ),
        isTrue,
      );
      final type = catalog.records.definitions.single;
      expect(
        frontends.resolveSettingsFieldEditor(type, type.fields.single),
        isNull,
      );
    },
  );

  test('nested namespace does not belong to the parent installation', () async {
    final catalog = await install([ExtensionId('$_owner.nested.view')]);
    expect(catalog.issues, isNotEmpty);
    await frontends.start(catalog);
    expect(registry.discover(settingsFieldEditorContributions), isEmpty);
  });

  test(
    'an absent EVC entrypoint leaves the declaration, not a factory',
    () async {
      final catalog = await install([_editor], entrypoint: 'missing');
      expect(catalog.issues, isEmpty);
      await frontends.start(catalog);
      expect(frontends.generations.single.state, InstalledFrontendState.failed);
      expect(registry.discover(settingsFieldEditorContributions), isEmpty);
      final type = catalog.records.definitions.single;
      expect(
        frontends.resolveSettingsFieldEditor(type, type.fields.single),
        isNull,
      );
    },
  );

  testWidgets('cyclic data, stale revisions and retired views cannot write', (
    tester,
  ) async {
    final binding = (await tester.runAsync(() async {
      final catalog = await install([_editor]);
      await frontends.start(catalog);
      final type = catalog.records.definitions.single;
      return frontends.resolveSettingsFieldEditor(type, type.fields.single)!;
    }))!;
    final draft = _Draft();
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: binding.value.createPresentation(draft),
      ),
    );
    expect(find.text('original'), findsOneWidget);
    final runtime = tester
        .widget<$StatelessWidget$bridge>(
          find.byWidgetPredicate((w) => w is $StatelessWidget$bridge),
        )
        .$runtime;
    Object? call(String name) {
      final value = runtime.executeLib(_library, name);
      return value is $Value ? value.$value : value;
    }

    expect(call('enabled'), true);
    expect(
      call('error'),
      isA<String>().having((s) => s.length, 'length', lessThanOrEqualTo(256)),
    );
    expect(call('cycle'), isA<String>());
    expect(draft.calls, 0);
    expect(call('submit'), isNull);
    expect(draft.value, 'edited');
    expect(call('submit'), isA<String>());
    expect(draft.calls, 1);

    final close = frontends.generations.single.registrations.single.close();
    expect(call('enabled'), false);
    // A retained callback with a valid revision still cannot reach the draft.
    draft.revision = 0;
    expect(call('submit'), isA<String>());
    expect(draft.calls, 1);
    await close;
    await tester.pump();
    expect(find.text('original'), findsNothing);
    expect(find.text('Frontend unavailable.'), findsOneWidget);
  });
}

class _Draft implements SettingsFieldDraft {
  int calls = 0;
  @override
  int revision = 0;
  @override
  Object? value = 'original';
  @override
  bool get enabled => true;
  @override
  String get error => 'x' * 300;
  @override
  String? propose(int revision, Object? value) {
    calls++;
    this.revision++;
    this.value = value;
    return null;
  }
}
