import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:adele_desktop/frontend/application_frontend_bootstrap.dart';
import 'package:adele_desktop/frontend/settings_field_editor_bridge.dart';
import 'package:adele_plugin_api/adele_plugin_api.dart';
import 'package:adele_ui/adele_ui.dart';
import 'package:dart_eval/dart_eval.dart';
import 'package:dart_eval/dart_eval_bridge.dart' show $Value;
import 'package:dart_eval/stdlib/core.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_eval/flutter_eval.dart';
import 'package:flutter_eval/widgets.dart' show $StatelessWidget$bridge;
import 'package:flutter_test/flutter_test.dart';
import 'package:plugin_runtime/plugin_runtime.dart';

const _owner = 'test.editor';
const _library = 'package:ed/main.dart';
final _editor = ExtensionId('$_owner.view');
final _other = ExtensionId('$_owner.other');
final _behavior = ExtensionId('$_owner.form');

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
String? proposeObject(Object? value) => proposeSettingsFieldValue(readSettingsFieldRevision(), value);
String? proposeContext(List<String> context) => proposeSettingsFieldValueWithContext(readSettingsFieldRevision(), 'observation', context);
Future<String> deferred() async => 'not a synchronous presentation';
Object behavior(Map<String, Object?> values, Map<String, List<String>> contexts, String? changed) {
  if (changed == 'probe') {
    // Sharing an artifact with an editor must not grant its bridge to a pure operation.
    proposeSettingsFieldValue(0, 'attempted write');
  }
  if (changed == 'mutate') values['name'] = 'attempted write';
  if (changed == 'async') return deferred();
  if (changed == 'over budget') {
    // Finite, so removing the host instruction budget cannot hang the suite.
    int count = 0;
    while (count < 150000) { count++; }
  }
  return <String, Object>{'fields': <String, Object>{
    'name': <String, Object>{'guidance': values['name'] as String},
  }};
}
Object? read() => readSettingsFieldValue();
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
    String? behaviorEntrypoint,
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
            'formBehavior': _behavior.value,
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
            if (behaviorEntrypoint != null)
              'extensions': [
                {
                  'kind': 'settingsFormBehavior',
                  'extensionId': _behavior.value,
                  'library': _library,
                  'entrypoint': behaviorEntrypoint,
                },
              ],
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

  ExtensionRegistration spoofBehavior() => registry.register(
    point: settingsFormBehaviorContributions,
    id: _behavior,
    value: SettingsFormBehaviorContribution(
      evaluate: (_, _, _) => fail('Impostor behavior invoked.'),
    ),
  );

  test(
    'a behavior cannot adopt a matching registration without its owner descriptor',
    () async {
      final catalog = await install([_editor]);
      final impostor = spoofBehavior();
      addTearDown(impostor.close);
      await frontends.start(catalog);
      expect(frontends.generations.single.state, InstalledFrontendState.active);
      final type = catalog.records.definitions.single;
      expect(frontends.resolveSettingsFormBehavior(type), isNull);
    },
  );

  test(
    'pure behavior is bound to the exact schema, generation and authority',
    () async {
      final catalog = await install([_editor], behaviorEntrypoint: 'behavior');
      expect(catalog.issues, isEmpty);
      await frontends.start(catalog);
      final type = catalog.records.definitions.single;
      final copied = (await PreparedPluginCatalog.discover(
        root.path,
      )).records.definitions.single;
      expect(copied.id, type.id);
      expect(frontends.resolveSettingsFormBehavior(copied), isNull);
      final binding = frontends.resolveSettingsFormBehavior(type)!;
      final evaluate = binding.value.evaluate;
      expect(
        evaluate({'name': 'Own draft'}, {}, null).fields['name']!.guidance,
        'Own draft',
      );
      final values = {'name': 'Own draft'};
      for (final invalid in ['probe', 'mutate', 'async', 'over budget']) {
        expect(
          () => evaluate(values, {}, invalid),
          throwsA(
            isA<FormatException>().having(
              (e) => e.message,
              'message',
              isNot(contains('Own draft')),
            ),
          ),
          reason: invalid,
        );
        expect(values, {'name': 'Own draft'});
        expect(
          evaluate(values, {}, null).fields['name']!.guidance,
          'Own draft',
        );
      }

      await frontends.generations.single.retire(
        settingsFormBehaviorContributions,
        _behavior,
      );
      final replacement = spoofBehavior();
      addTearDown(replacement.close);
      expect(
        replacement.owns(
          registry.discover(settingsFormBehaviorContributions).single,
        ),
        isTrue,
      );
      expect(frontends.resolveSettingsFormBehavior(type), isNull);
      expect(binding.validate, throwsA(isA<StaleExtensionBinding>()));
      expect(() => evaluate({'name': 'New draft'}, {}, null), throwsStateError);
      // The field editor in the very same artifact is independently owned.
      expect(
        frontends.resolveSettingsFieldEditor(type, type.fields.single),
        isNotNull,
      );
    },
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

    Object? propose($Value proposal) {
      final result = runtime.executeLib(_library, 'proposeObject', [proposal]);
      return result is $Value ? result.$value : result;
    }

    final boundary = <$Value, $Value>{
      for (var i = 0; i < 16; i++) $String('k$i'): $int(i),
    };
    for (final invalid in [
      $Map.wrap({...boundary, $String('extra'): $int(0)}),
      $Map.wrap({$String('x'): $String('s' * 65537)}),
      $Map.wrap({$String('bad.key'): $int(0)}),
      $Map.wrap({$int(0): $bool(false)}),
      $Map.wrap({$String('x'): const $null()}),
      $Map.wrap({$String('x'): $double(1.5)}),
      $Map.wrap({
        $String('x'): $List.wrap([$String('no')]),
      }),
      $List.wrap([$int(0)]),
    ]) {
      expect(propose(invalid), 'Invalid field value.');
    }
    expect(draft.calls, 1); // Transport rejects all of these before validation.
    boundary[$String('k0')] = $String('s' * 65536);
    expect(propose($Map.wrap(boundary)), isNull);
    final snapshot = draft.value! as Map<String, Object>;
    boundary.clear();
    expect(snapshot.length, 16);
    expect(snapshot['k0'], hasLength(65536));
    expect(() => snapshot.clear(), throwsUnsupportedError);
    final read = runtime.executeLib(_library, 'read') as $Map;
    expect(read.$value[$String('k15')], isA<$int>());
    expect(() => read.$value.clear(), throwsUnsupportedError);

    Object? proposeContext(List<$Value> context) {
      final result = runtime.executeLib(_library, 'proposeContext', [
        $List.wrap(context),
      ]);
      return result is $Value ? result.$value : result;
    }

    final context = List<$Value>.filled(32, $String('a' * 128));
    for (final invalid in [
      [...context, $String('extra')],
      [$String('a' * 129)],
      [$int(3)],
    ]) {
      expect(proposeContext(invalid), isA<String>());
      expect(draft.calls, 2);
      expect(draft.value, same(snapshot));
    }
    expect(proposeContext(context), isNull);
    context[0] = $String('changed after the call');
    expect(draft.context, List.filled(32, 'a' * 128));
    expect(draft.context!.clear, throwsUnsupportedError);
    expect(proposeContext([]), isNull);
    expect(draft.context, isEmpty);

    final close = frontends.generations.single.registrations.single.close();
    expect(call('enabled'), false);
    // A retained callback with a valid revision still cannot reach the draft.
    draft.revision = 0;
    expect(call('submit'), isA<String>());
    expect(proposeContext([]), isA<String>());
    expect(draft.calls, 4);
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
  List<String>? context;
  @override
  String? propose(int revision, Object? value, {List<String>? context}) {
    calls++;
    this.revision++;
    this.value = value;
    this.context = context;
    return null;
  }
}
