import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:adele_contract/adele_contract.dart';
import 'package:adele_desktop/frontend/backend_invocation_bridge.dart';
import 'package:adele_desktop/frontend/capability_access_bridge.dart';
import 'package:adele_desktop/frontend/interpreted_widget.dart';
import 'package:adele_desktop/frontend/prepared_frontend.dart';
import 'package:adele_desktop/frontend/presentation_dialog_bridge.dart';
import 'package:adele_desktop/frontend/settings_field_editor_bridge.dart';
import 'package:adele_desktop/frontend/structured_bridge_data.dart';
import 'package:adele_model_provider/adele_model_catalog.dart';
import 'package:adele_plugin_api/adele_plugin_api.dart';
import 'package:adele_ui/settings_field_editor.dart';
import 'package:dart_eval/dart_eval_bridge.dart';
import 'package:dart_eval/stdlib/core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../../../app/tool/model_configuration_frontend_compiler.dart';
import '../../../../../tools/stock_frontend_descriptors.dart';

const _library = 'package:adele_ui/capability_bridge.dart';
const _work = {'provider-id': 'test.work', 'model-id': 'same'};
const _home = {'provider-id': 'test.home', 'model-id': 'same'};

void main() {
  late Uint8List artifact;
  late _Observations access;
  late _Draft draft;

  setUpAll(() async {
    artifact = await compileModelConfigurationFrontend(
      repositoryRoot: Directory.current.parent.parent.parent.parent,
    );
  });

  setUp(() async {
    draft = _Draft();
    access = _Observations();
  });

  Future<void> mount(WidgetTester tester) async {
    final registry = ExtensionRegistry();
    final registration = registry.register(
      point: settingsFieldEditorContributions,
      id: ExtensionId('dev.test.editor'),
      value: SettingsFieldEditorContribution(
        createPresentation: (_) => throw UnimplementedError(),
      ),
    );
    addTearDown(registration.close);
    final bridge = PreparedFrontendBridges([
      SettingsFieldEditorBridge(
        draft: draft,
        binding: registry.discover(settingsFieldEditorContributions).single,
        isActive: () => true,
      ),
      PresentationDialogBridge(),
      access,
    ]);
    addTearDown(bridge.invalidate);
    final loaded = await loadInterpretedWidget(
      bytes: artifact,
      bridge: bridge,
      library:
          'package:model_configuration_frontend/model_reference_editor.dart',
      entrypoint: 'buildModelReferenceEditor',
    );
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: loaded.widget)));
    await tester.pumpAndSettle();
  }

  // Invoke the published operation in the compiled frontend, with no browser,
  // service, or field editor bridge installed in its runtime.
  Map<String, Object?> evaluate({
    Map<String, Object?> values = const {},
    List<String>? efforts,
    String? changedField,
  }) {
    final descriptor =
        stockFrontendExtensionDescriptors['dev.adele.plugin.model-configuration']!
            .singleWhere((item) => item['kind'] == 'settingsFormBehavior');
    final result = Runtime(ByteData.sublistView(artifact)).executeLib(
      descriptor['library']! as String,
      descriptor['entrypoint']! as String,
      [
        wrapStructuredBridgeData(values),
        wrapStructuredBridgeData({'model': ?efforts}),
        wrapStructuredBridgeData(changedField),
      ],
    );
    return copyStructuredBridgeData(result) as Map<String, Object?>;
  }

  Map<String, Object?> field(Map<String, Object?> result) =>
      (result['fields'] as Map)['reasoning-effort'] as Map<String, Object?>;

  test(
    'preset behavior distinguishes default, explicit none and unknown support',
    () {
      final beforeModel = evaluate();
      expect(field(beforeModel)['enabled'], isFalse);
      expect(field(beforeModel)['choices'], isEmpty);
      expect(beforeModel.containsKey('clear'), isFalse);

      for (final choices in [
        <String>[],
        ['none', 'medium'],
        ['low', 'high'],
      ]) {
        for (final requested in [null, 'none', 'high']) {
          final values = {'model': _work, 'reasoning-effort': ?requested};
          final unsupported = requested != null && !choices.contains(requested);
          for (final change in [null, 'model', 'name', 'reasoning-effort']) {
            final result = evaluate(
              values: values,
              efforts: choices,
              changedField: change,
            );
            final presentation = field(result);
            expect(presentation['enabled'], isTrue);
            expect(presentation['choices'], choices);
            if (unsupported && change == 'model') {
              expect(result['clear'], 'reasoning-effort');
              expect(
                presentation['guidance'],
                contains('Reset to Provider default'),
              );
            } else {
              expect(result.containsKey('clear'), isFalse);
              if (unsupported) {
                expect(presentation['guidance'], contains('retained'));
              }
            }
            if (choices.isEmpty) {
              expect(
                presentation['guidance'],
                contains('no configurable explicit'),
              );
            }
          }
          // A manual choice, or another draft restored from disk, has no
          // observation, even if the exact same pair just had known support.
          final unknown = evaluate(values: values, changedField: 'model');
          expect(unknown.containsKey('clear'), isFalse);
          expect(field(unknown)['enabled'], isTrue);
          expect(field(unknown).containsKey('choices'), isFalse);
          expect(field(unknown)['guidance'], contains('unverified'));
        }
      }
      expect(access.calls, isEmpty);
    },
  );

  testWidgets(
    'multi-account rows, local search, sorting and chips preserve the exact choice',
    (tester) async {
      draft.value = _work;
      await mount(tester);
      expect(find.text('same'), findsOneWidget);
      expect(
        find.text('Configured provider: Account (test.work)'),
        findsOneWidget,
      );
      expect(access.calls, isEmpty);
      await _tap(tester, 'Browse models...');
      expect(find.text('Selected: same / Account (test.work)'), findsOneWidget);
      expect(find.text('Luna'), findsNWidgets(2));
      expect(
        find.descendant(of: find.byType(Dialog), matching: find.text('same')),
        findsNWidgets(2),
      );
      expect(_chip('Account (test.work)'), findsOneWidget);
      expect(_chip('Account (test.home)'), findsOneWidget);
      expect(draft.proposals, isEmpty);
      expect(
        access.calls,
        unorderedEquals(['work', 'home', 'empty', 'failed']),
      );
      double y(String label) => tester.getTopLeft(find.text(label).first).dy;
      expect(y('Artemis'), lessThan(y('Luna')));
      await _tap(tester, 'Model (ascending)');
      expect(y('Luna'), lessThan(y('Artemis')));
      await _tap(tester, 'Configured provider');
      expect(find.text('Configured provider (ascending)'), findsOneWidget);
      await _tap(tester, 'Configured provider (ascending)');
      expect(find.text('Configured provider (descending)'), findsOneWidget);
      final search = find.byType(TextField);
      for (final (query, count) in [
        ('LuNa', 2),
        ('sAmE', 2),
        ('Account (test.home)', 1),
      ]) {
        await tester.enterText(search, query);
        await tester.pumpAndSettle();
        expect(find.text('Luna'), findsNWidgets(count));
        expect(find.text('Artemis'), findsNothing);
      }
      await tester.enterText(search, '');
      await tester.tap(_chip('Account (test.home)'));
      await tester.pumpAndSettle();
      await _tap(tester, 'Luna');
      expect(find.text('Selected: same / Account (test.home)'), findsOneWidget);
      expect(draft.value, _work);
      expect(access.calls, hasLength(4));
      await _tap(tester, 'Use model');
      expect(draft.proposals, [_home]);
      expect(draft.contexts, [<String>[]]);
      expect(access.calls, hasLength(4));
      expect(find.text('Model ID: same'), findsOneWidget);
      expect(find.text('Luna'), findsOneWidget);
      expect(access.handles, isEmpty);
    },
  );

  testWidgets(
    'same-model confirmation passes fresh evidence; manual confirmation drops it',
    (tester) async {
      draft.value = _work;
      await mount(tester);
      await _tap(tester, 'Browse models...');
      await _tap(tester, 'Use model');
      expect(draft.contexts.single, ['none', 'minimal', 'high']);
      expect(access.calls, hasLength(4));

      access.workEfforts = ['low'];
      await _tap(tester, 'Browse models...');
      await _tap(tester, 'Use model');
      expect(draft.proposals, [_work, _work]);
      expect(draft.contexts.last, ['low']);
      final result = evaluate(
        values: {'model': draft.value, 'reasoning-effort': 'high'},
        efforts: draft.contexts.last,
      );
      expect(field(result)['guidance'], contains('high'));
      expect(result.containsKey('clear'), isFalse);
      expect(access.calls, hasLength(8));

      await _tap(tester, 'Browse models...');
      await _tap(tester, 'Artemis');
      await _tap(tester, 'Use model');
      expect(
        draft.contexts.last,
        isNull,
        reason: 'Catalog row with unknown support',
      );
      await _tap(tester, 'Browse models...');
      await _tap(tester, 'Enter manually');
      await _tap(tester, 'Enter provider ID instead');
      await _tap(tester, 'Use reference');
      expect(draft.contexts.last, isNull);
      expect(
        access.calls,
        hasLength(16),
        reason: 'Only Browse starts requests',
      );
    },
  );

  testWidgets(
    'invalid metadata discards only that provider, including its prior selection',
    (tester) async {
      draft.value = _work;
      await mount(tester);
      await _tap(tester, 'Browse models...');
      final old = _button(tester, 'Use model');
      await _tap(tester, 'Provider status');
      // Each observation has a good first row. A malformed later row rejects
      // the whole snapshot, even if the first row matches the accepted draft.
      for (final (field, status) in <(Map<String, Object?>, String)>[
        for (final values in [
          ['future-private-effort'],
          ['none', 'none'],
          ['high', 'low'],
          List.filled(modelCatalogReasoningEffortNames.length + 1, 'none'),
        ])
          (
            {
              'supportedReasoningEfforts': {'values': values},
            },
            'Invalid reasoning effort metadata.',
          ),
        ({}, 'Catalog request failed.'),
        for (final text in ['  ', 'a\u0000b'])
          for (final key in ['displayName', 'description'])
            (
              {key: text, 'supportedReasoningEfforts': null},
              'Invalid model display metadata.',
            ),
        ({'supportedReasoningEfforts': []}, 'Catalog request failed.'),
        (
          {
            'supportedReasoningEfforts': {
              'values': [true],
            },
          },
          'Catalog request failed.',
        ),
      ]) {
        access.workTail = {
          'modelId': 'private-id',
          'displayName': null,
          'description': null,
          ...field,
        };
        await _tap(tester, 'Refresh');
        expect(find.text('Account (test.work): $status'), findsOneWidget);
        expect(find.text('Use model'), findsNothing);
        expect(find.textContaining('private'), findsNothing);
        expect(find.text('Luna'), findsOneWidget, reason: 'Healthy sibling');
        expect(access.handles.values, ['home']);
        old();
        await tester.pumpAndSettle();
        expect(draft.value, _work);
        expect(draft.proposals, isEmpty);
      }
      await _tap(tester, 'Provider status');
      await _tap(tester, 'Luna');
      await _tap(tester, 'Use model');
      expect(draft.proposals, [_home]);
      expect(access.handles, isEmpty);
    },
  );

  testWidgets(
    'partial discovery leaves healthy results usable; manual choices need no catalog',
    (tester) async {
      final slow = access.gates['home'] = Completer<void>();
      await mount(tester);
      expect(find.text('No model selected.'), findsOneWidget);
      await _tap(tester, 'Browse models...');
      expect(find.text('Artemis'), findsOneWidget);
      await _tap(tester, 'Provider status');
      for (final label in [
        'Account (test.home): Loading...',
        'Empty: Empty catalog.',
        'Broken: Catalog request failed.',
        'Offline: No catalog.',
      ]) {
        expect(find.text(label), findsOneWidget);
      }
      await tester.drag(
        find.text('Account (test.home): Loading...'),
        const Offset(0, -100),
      );
      await tester.pumpAndSettle();
      expect(find.text('Multiple: Ambiguous association.'), findsOneWidget);
      expect(find.textContaining('PRIVATE'), findsNothing);
      await _tap(tester, 'Artemis');
      await _tap(tester, 'Cancel');
      expect(draft.proposals, isEmpty);
      expect(access.handles, isEmpty);
      slow.complete();
      await tester.pumpAndSettle();
      await _tap(tester, 'Browse models...');
      await _tap(tester, 'Enter manually');
      final offline = _chip('Offline');
      await tester.drag(
        find.byWidgetPredicate(
          (widget) =>
              widget is ListView && widget.scrollDirection == Axis.horizontal,
        ),
        const Offset(-440, 0),
      );
      await tester.pumpAndSettle();
      await tester.ensureVisible(offline);
      await tester.tap(offline);
      await tester.enterText(find.byType(TextField), '  exact:manual  ');
      await tester.pumpAndSettle();
      await _tap(tester, 'Use reference');
      expect(draft.proposals, [
        {'provider-id': 'test.offline', 'model-id': '  exact:manual  '},
      ]);
      expect(draft.contexts, [null]);
      expect(access.calls.where((id) => id == 'offline'), isEmpty);
    },
  );

  testWidgets(
    'refresh fences old arrivals without multiplying pending requests',
    (tester) async {
      access.providers.clear();
      for (int i = 0; i < 7; i++) {
        access.providers['p$i'] = 'Provider $i';
        access.gates['p$i'] = Completer<void>();
      }
      await mount(tester);
      await _tap(tester, 'Browse models...');
      expect(access.calls, ['p0', 'p1', 'p2', 'p3']);
      await _tap(tester, 'Refresh');
      expect(access.calls, hasLength(4));
      expect(find.text('Use model'), findsNothing);
      // The first capture's response cannot publish a row. Its released worker
      // slot admits the new capture, whose response remains independently gated.
      final first = access.gates['p0']!;
      access.gates['p0'] = Completer<void>();
      first.complete();
      await tester.pumpAndSettle();
      expect(access.calls, ['p0', 'p1', 'p2', 'p3', 'p0']);
      expect(find.text('Luna'), findsNothing);
      await _tap(tester, 'Cancel');
      expect(access.handles, isEmpty);
      for (final gate in access.gates.values) {
        gate.complete();
      }
      await tester.pumpAndSettle();
      expect(access.calls, hasLength(5));
      expect(draft.proposals, isEmpty);
    },
  );

  testWidgets(
    'replacement, refresh, barrier dismissal and stale revisions fence retained choices',
    (tester) async {
      draft.value = _work;
      await mount(tester);
      await _tap(tester, 'Browse models...');
      final old = _button(tester, 'Use model');
      access.retire('work');
      old();
      await tester.pumpAndSettle();
      expect(
        find.text('Catalog changed; refresh to browse again.'),
        findsOneWidget,
      );
      expect(draft.proposals, isEmpty);
      await _tap(tester, 'Refresh');
      expect(find.text('Use model'), findsNothing);
      old();
      await tester.pumpAndSettle();
      expect(draft.proposals, isEmpty);
      await _tap(tester, 'Artemis');
      final dismissed = _button(tester, 'Use model');
      await tester.tapAt(const Offset(4, 4));
      dismissed(); // Before the exit transition has disposed the interpreted child.
      await tester.pumpAndSettle();
      expect(access.handles, isEmpty);
      await _tap(tester, 'Browse models...');
      dismissed();
      expect(draft.proposals, isEmpty);
      draft.revision++;
      await _tap(tester, 'Use model');
      expect(find.text('Field draft has changed.'), findsOneWidget);
      expect(draft.proposals, isEmpty);
      await _tap(tester, 'Cancel');
      expect(draft.value, _work);
    },
  );
}

Finder _chip(String label) => find.widgetWithText(ChoiceChip, label);
VoidCallback _button(WidgetTester tester, String label) => tester
    .widget<TextButton>(find.widgetWithText(TextButton, label))
    .onPressed!;
Future<void> _tap(WidgetTester tester, String label) async {
  final text = find.text(label);
  expect(text, findsOneWidget);
  await tester.ensureVisible(text);
  await tester.tap(text);
  await tester.pumpAndSettle();
}

class _Draft implements SettingsFieldDraft {
  @override
  int revision = 0;
  @override
  Object? value;
  @override
  bool get enabled => true;
  @override
  String? get error => null;
  final proposals = <Object?>[];
  final contexts = <List<String>?>[];
  @override
  String? propose(int revision, Object? value, {List<String>? context}) {
    expect(revision, this.revision++);
    proposals.add(value);
    contexts.add(context);
    this.value = value;
    return null;
  }
}

// A deterministic observation source for the compiled plugin. Actual backend
// ownership, grants and association capture are tested by hosting/integration.
class _Observations extends CapabilityAccessDeclarations
    implements PreparedFrontendBridge {
  final providers = {
    'work': 'Account',
    'home': 'Account',
    'failed': 'Broken',
    'empty': 'Empty',
    'offline': 'Offline',
    'many': 'Multiple',
  };
  final handles = <String, String>{};
  final stale = <String>{};
  final gates = <String, Completer<void>>{};
  final calls = <String>[];
  List<String> workEfforts = ['none', 'minimal', 'high'];
  Map<String, Object?>? workTail;
  int capture = 0;
  void retire(String id) =>
      stale.addAll(handles.keys.where((h) => handles[h] == id));

  List<Map<String, Object?>> observe(bool capturing) {
    if (capturing) capture++;
    final result = <Map<String, Object?>>[];
    for (final provider in providers.entries) {
      final entry = <String, Object?>{
        'providerId': 'test.${provider.key}',
        'displayName': provider.value,
      };
      if (capturing) {
        final status = switch (provider.key) {
          'offline' => 'missing',
          'many' => 'ambiguous',
          _ => 'ready',
        };
        entry['status'] = status;
        if (status == 'ready') {
          final handle = '${provider.key}:$capture';
          handles[handle] = provider.key;
          entry['handle'] = handle;
        }
      }
      result.add(entry);
    }
    return result;
  }

  late final transport = BackendInvocationBridge(
    channelFor: (h) => _Channel(this, handles[h]!),
    validateAdmission: () {},
    validateSettlement: () {},
    isPresentationActive: () => true,
  );

  @override
  void configureForRuntime(Runtime runtime) {
    runtime
      ..registerBridgeFunc(
        _library,
        'observeAssociatedProviders',
        (_, _, args) =>
            wrapStructuredBridgeData(observe(args.last!.$value as bool)),
      )
      ..registerBridgeFunc(
        _library,
        'isCapabilityProviderCurrent',
        (_, _, args) => $bool(
          handles.containsKey(args.single!.$value) &&
              !stale.contains(args.single!.$value),
        ),
      )
      ..registerBridgeFunc(
        _library,
        'releaseCapabilityProvider',
        (_, _, args) => $bool(handles.remove(args.single!.$value) != null),
      )
      ..registerBridgeFunc(
        _library,
        'requestCapability',
        (runtime, _, args) => transport.evalRequest(runtime, args),
      )
      ..registerBridgeFunc(
        _library,
        'settleCapabilityOperation',
        (runtime, _, args) =>
            BackendInvocationBridge.settleOperation(runtime, args),
      );
  }

  @override
  void invalidate() {
    handles.clear();
    transport.invalidate();
  }
}

class _Channel implements AdeleRequestChannel {
  _Channel(this.access, this.id);
  final _Observations access;
  final String id;
  @override
  Future<Object?> request(String method, Map<String, Object?> payload) async {
    expect(method, modelCatalogServiceListModelsId);
    expect(payload, isEmpty);
    access.calls.add(id);
    await access.gates[id]?.future;
    if (id == 'failed') throw StateError('PRIVATE backend diagnostic');
    return {
      'models': [
        if (id != 'empty')
          {
            'modelId': 'same',
            'displayName': 'Luna',
            'description': null,
            'supportedReasoningEfforts': {
              'values': id == 'work' ? access.workEfforts : <String>[],
            },
          },
        if (id == 'work')
          access.workTail ??
              {
                'modelId': 'Artemis',
                'displayName': null,
                'description': null,
                'supportedReasoningEfforts': null,
              },
      ],
    };
  }
}
