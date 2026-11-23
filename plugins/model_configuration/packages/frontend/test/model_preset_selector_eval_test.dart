import 'dart:async';
import 'dart:io';

import 'package:adele_contract/adele_contract.dart';
import 'package:adele_desktop/frontend/owning_backend_bridge.dart';
import 'package:adele_desktop/frontend/prepared_frontend.dart';
import 'package:adele_desktop/frontend/session_accessory_bridge.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:model_configuration_contract/model_configuration_contract.dart';

import '../../../../../app/tool/model_configuration_frontend_compiler.dart';

const _session = 'session-A';
const _clear = 'No Model Preset';
const _unselected = 'Model Preset: $_clear';
const _empty =
    'No Model Presets configured. Create Model Presets in Global Settings.';
const _incomplete = 'Model Preset catalog is incomplete.';
const _catalogUnavailable = 'Model Preset catalog is unavailable.';
const _selectionUnavailable = 'Model Preset selection is unavailable.';
const _unconfirmed =
    'Change not confirmed. Refresh to check the current selection.';
const _private = 'PRIVATE-backend-diagnostic';

void main() {
  late File artifact;
  late PreparedFrontend frontend;
  late _Backend backend;

  setUpAll(() async {
    final directory = await Directory.systemTemp.createTemp('preset-selector-');
    addTearDown(() => directory.delete(recursive: true));
    artifact = File('${directory.path}/frontend.evc');
    await artifact.writeAsBytes(
      await compileModelConfigurationFrontend(
        repositoryRoot: Directory.current.parent.parent.parent.parent,
      ),
    );
  });
  setUp(() async {
    frontend = await PreparedFrontend.load(artifact);
    addTearDown(frontend.invalidate);
    backend = _Backend();
  });

  Future<void> mount(WidgetTester tester, [_Backend? owner]) async {
    await tester.pumpWidget(_host(frontend, owner ?? backend));
    await tester.pumpAndSettle();
  }

  testWidgets(
    'mount reads the captured Session; empty stays empty on rebuild',
    (tester) async {
      backend.presets = [];
      final gate = backend.readGate = Completer<void>();
      await mount(tester);
      expect(find.text('Loading Model Presets...'), findsOneWidget);
      expect(find.text(_unselected), findsNothing);
      expect(backend.reads, [
        {'sessionId': _session},
      ]);
      gate.complete();
      await tester.pumpAndSettle();
      expect(find.text(_unselected), findsOneWidget);
      expect(find.text(_empty), findsOneWidget);
      expect(
        find.text('Model Preset changes apply to newly prepared Runs.'),
        findsOneWidget,
      );
      await mount(tester);
      await tester.pump(const Duration(minutes: 1));
      expect(backend.reads, hasLength(1));
      expect(backend.catalogReads, <Map<String, Object?>>[{}]);
      expect(backend.writes, isEmpty);
    },
  );

  testWidgets('Refresh exposes creates, renames and deletion without writing', (
    tester,
  ) async {
    backend.presets = [];
    await mount(tester);
    await _tap(tester, _unselected);
    expect(find.text(_empty), findsOneWidget);
    backend.presets = [_preset('work', 'Writer')];
    await _tap(tester, 'Refresh');
    expect(backend.reads, hasLength(2));
    expect(backend.catalogReads, hasLength(3));
    expect(find.text(_empty), findsNothing);
    await _tap(tester, 'Writer');
    backend.presets = [_preset('work', 'Renamed')];
    await _tap(tester, 'Refresh');
    expect(find.text('Model Preset: Renamed'), findsOneWidget);
    backend.presets = [];
    await _tap(tester, 'Refresh');
    expect(
      find.text('Model Preset: Missing Model Preset: work'),
      findsOneWidget,
    );
    expect(find.text(_unselected), findsNothing);
    expect(backend.writes, [_write('work', 0)]);
  });

  testWidgets('opening reads fresh choices; equal labels sort by stable ID', (
    tester,
  ) async {
    await mount(tester);
    backend.presets = [
      _preset('beta', 'Draft'),
      _preset('blank', '  '),
      _preset('alpha', 'Draft'),
    ];
    await _tap(tester, _unselected);
    expect(backend.catalogReads, <Map<String, Object?>>[{}, {}]);
    expect(backend.reads, hasLength(1));
    expect(find.text('Writer'), findsNothing);
    double row(String label) => tester.getTopLeft(find.text(label)).dy;
    expect(row('Draft (alpha)'), lessThan(row('Draft (beta)')));
    expect(row('Draft (beta)'), lessThan(row('blank')));
    await _tap(tester, 'Draft (beta)');
    expect(backend.writes, [_write('beta', 0)]);
    expect(find.text('Model Preset: Draft (beta)'), findsOneWidget);
    await _tap(tester, 'Model Preset: Draft (beta)');
    await _tap(tester, 'Draft (alpha)');
    expect(backend.writes, [_write('beta', 0), _write('alpha', 1)]);
  });

  testWidgets(
    'clipped names and the unselected option remain distinct choices',
    (tester) async {
      final prefix = 'M' * 50;
      final clipped = '${'M' * 37}...';
      backend.presets = [
        _preset('long-b', '${prefix}B'),
        _preset('long-a', '${prefix}A'),
        _preset('named-none', _clear),
      ];
      await mount(tester);
      await _tap(tester, _unselected);
      expect(find.textContaining(prefix), findsNothing);
      expect(find.text('$clipped (long-a)'), findsOneWidget);
      expect(find.text('$clipped (long-b)'), findsOneWidget);
      expect(find.text(_clear), findsOneWidget);
      await _tap(tester, '$clipped (long-b)');
      await _tap(tester, 'Model Preset: $clipped (long-b)');
      await tester.scrollUntilVisible(find.text('$_clear (named-none)'), 64);
      await _tap(tester, '$_clear (named-none)');
      await _tap(tester, 'Model Preset: $_clear (named-none)');
      await _tap(tester, _clear);
      expect(find.text(_unselected), findsOneWidget);
      expect(backend.writes, [
        _write('long-b', 0),
        _write('named-none', 1),
        _write(null, 2),
      ]);
    },
  );

  testWidgets(
    'details show compact authored values and distinguish unspecified effort from none',
    (tester) async {
      backend.selected = _selection('work', 1);
      await mount(tester);
      expect(find.text('Configured provider:  Local:Work/V2 '), findsOneWidget);
      expect(
        find.text('Configured model:  Org/Model.Mixed+v2 '),
        findsOneWidget,
      );
      expect(find.text('Requested effort: unspecified'), findsOneWidget);
      for (final effort in ['none', 'high']) {
        backend.presets = [
          _preset(
            'work',
            'Writer',
            effort: effort,
            model: 'x' * 200,
            provider: 'P' * 200,
          ),
        ];
        await _tap(tester, 'Refresh');
        expect(find.text('Requested effort: $effort'), findsOneWidget);
        expect(find.text('Requested effort: unspecified'), findsNothing);
        expect(find.text('Configured model: ${'x' * 37}...'), findsOneWidget);
        expect(
          find.text('Configured provider: ${'P' * 37}...'),
          findsOneWidget,
        );
      }
      expect(backend.writes, isEmpty);
    },
  );

  testWidgets(
    'partial catalogs can identify a choice but cannot establish deletion',
    (tester) async {
      backend.selected = _selection('omitted', 6);
      backend.complete = false;
      backend.presets = [];
      await mount(tester);
      const unresolved = 'Model Preset: Unresolved Model Preset: omitted';
      expect(find.text(unresolved), findsOneWidget);
      expect(find.text(_incomplete), findsOneWidget);
      expect(find.text(_empty), findsNothing);
      expect(find.text(_unselected), findsNothing);
      backend.presets = [_preset('work', 'Writer')];
      await _tap(tester, unresolved);
      await _tap(tester, 'Writer');
      expect(find.text('Model Preset: Writer'), findsOneWidget);
      expect(find.text(_incomplete), findsOneWidget);
      expect(backend.writes, [_write('work', 6)]);
    },
  );

  testWidgets(
    'catalog failure is not empty or missing; an acknowledged selection can still be cleared',
    (tester) async {
      backend.selected = _selection('work', 4);
      await mount(tester);
      backend.catalogFails = true;
      await _tap(tester, 'Model Preset: Writer');
      expect(
        find.text('Model Preset: Unresolved Model Preset: work'),
        findsOneWidget,
      );
      expect(find.text(_catalogUnavailable), findsOneWidget);
      expect(find.text(_empty), findsNothing);
      expect(find.text('Writer'), findsNothing);
      expect(find.textContaining('Missing Model Preset'), findsNothing);
      expect(find.textContaining(_private), findsNothing);
      expect(backend.writes, isEmpty);
      await _tap(tester, _clear);
      expect(find.text(_unselected), findsOneWidget);
      expect(backend.writes, [_write(null, 4)]);
    },
  );

  testWidgets('a failed read or wrong Session is unknown, not revision zero', (
    tester,
  ) async {
    backend.readFails = true;
    await mount(tester);
    expect(find.text(_selectionUnavailable), findsOneWidget);
    expect(find.text(_unselected), findsNothing);
    expect(find.textContaining(_private), findsNothing);
    backend.readFails = false;
    backend.selected = _selection('work', 7, session: 'session-B');
    await _tap(tester, 'Refresh');
    expect(find.text(_selectionUnavailable), findsOneWidget);
    expect(find.text('Model Preset: Writer'), findsNothing);
    expect(find.text(_clear), findsNothing);
    expect(backend.writes, isEmpty);
    backend.selected = _selection('work', 21);
    await _tap(tester, 'Refresh');
    await _tap(tester, 'Model Preset: Writer');
    await _tap(tester, _clear);
    expect(backend.writes, [_write(null, 21)]);
  });

  testWidgets(
    'two activations admit one update; only the acknowledgement permits the next change',
    (tester) async {
      backend.selected = _selection(null, 7);
      await mount(tester);
      await _tap(tester, _unselected);
      final gate = backend.ackGate = Completer<void>();
      // Both taps reach the enabled control before its next frame.
      await tester.tap(find.text('Writer'));
      await tester.tap(find.text('Writer'));
      await tester.pumpAndSettle();
      expect(find.text('Saving selection...'), findsOneWidget);
      expect(find.text('Model Preset: Writer'), findsNothing);
      expect(backend.writes, [_write('work', 7)]);
      gate.complete();
      await tester.pumpAndSettle();
      await _tap(tester, 'Model Preset: Writer');
      await _tap(tester, _clear);
      expect(find.text(_unselected), findsOneWidget);
      expect(backend.writes, [_write('work', 7), _write(null, 8)]);
    },
  );

  testWidgets('a retained choice cannot borrow the revision read by Refresh', (
    tester,
  ) async {
    backend.selected = _selection(null, 2);
    await mount(tester);
    await _tap(tester, _unselected);
    final chooseAtTwo = _button(tester, 'Writer');
    backend.selected = _selection(null, 5);
    await _tap(tester, 'Refresh');
    chooseAtTwo();
    await tester.pumpAndSettle();
    expect(backend.writes, isEmpty);
    await _tap(tester, 'Writer');
    expect(backend.writes, [_write('work', 5)]);
  });

  for (final failure in ['stale_revision', 'outcome_uncertain']) {
    testWidgets('$failure requires explicit reconciliation, never replay', (
      tester,
    ) async {
      backend.selected = _selection(null, 2);
      backend.presets.add(_preset('other', 'Reviewer'));
      await mount(tester);
      await _tap(tester, _unselected);
      final committed = failure == 'outcome_uncertain';
      if (!committed) backend.selected = _selection('other', 13);
      backend.writeFailure = failure;
      await _tap(tester, 'Writer');
      expect(find.text(_unconfirmed), findsOneWidget);
      expect(find.text('Model Preset: Writer'), findsNothing);
      expect(find.textContaining(_private), findsNothing);
      expect(find.text(_clear), findsNothing);
      backend.writeFailure = null;
      await tester.pump(const Duration(minutes: 1));
      expect(backend.reads, hasLength(1));
      expect(backend.catalogReads, hasLength(2));
      expect(backend.writes, [_write('work', 2)]);
      backend.readFails = true;
      await _tap(tester, 'Refresh');
      expect(find.text(_unconfirmed), findsOneWidget);
      backend.readFails = false;
      await _tap(tester, 'Refresh');
      expect(find.text(_unconfirmed), findsNothing);
      final current = committed
          ? 'Model Preset: Writer'
          : 'Model Preset: Reviewer';
      await _tap(tester, current);
      await _tap(tester, _clear);
      expect(backend.writes, [
        _write('work', 2),
        _write(null, committed ? 3 : 13),
      ]);
    });
  }

  testWidgets(
    'a successful reply for another Session is not an acknowledgement',
    (tester) async {
      await mount(tester);
      await _tap(tester, _unselected);
      backend.writeReply = _selection('work', 1, session: 'session-B');
      await _tap(tester, 'Writer');
      expect(find.text(_unconfirmed), findsOneWidget);
      expect(find.text('Model Preset: Writer'), findsNothing);
      await _tap(tester, 'Refresh');
      expect(find.text(_unconfirmed), findsNothing);
      expect(find.text('Model Preset: Writer'), findsOneWidget);
      expect(backend.writes, [_write('work', 0)]);
    },
  );

  testWidgets(
    'an admitted update can commit without publishing its late reply to the next Session',
    (tester) async {
      await mount(tester);
      await _tap(tester, _unselected);
      final gate = backend.ackGate = Completer<void>();
      await _tap(tester, 'Writer');
      expect(backend.selected.selectedPresetId, 'work');
      final next = _Backend(session: 'session-B');
      await mount(tester, next);
      gate.complete();
      await tester.pumpAndSettle();
      expect(find.text(_unselected), findsOneWidget);
      expect(find.text('Model Preset: Writer'), findsNothing);
      expect(backend.writes, [_write('work', 0)]);
      expect(next.reads, [
        {'sessionId': 'session-B'},
      ]);
      expect(next.writes, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('retired owning-backend access cannot target a replacement', (
    tester,
  ) async {
    await mount(tester);
    await _tap(tester, _unselected);
    final oldChoice = _button(tester, 'Writer');
    backend.owning.invalidate();
    oldChoice();
    await tester.pumpAndSettle();
    expect(backend.writes, isEmpty);
    final replacement = _Backend();
    await mount(tester, replacement);
    await _tap(tester, _unselected);
    oldChoice();
    await tester.pumpAndSettle();
    expect(backend.writes, isEmpty);
    expect(replacement.writes, isEmpty);
    await _tap(tester, 'Writer');
    expect(replacement.writes, [_write('work', 0)]);
    expect(tester.takeException(), isNull);
  });
}

Future<void> _tap(WidgetTester tester, String label) async {
  final text = find.text(label);
  expect(text, findsOneWidget);
  await tester.ensureVisible(text);
  await tester.tap(text);
  await tester.pumpAndSettle();
}

VoidCallback _button(WidgetTester tester, String label) => tester
    .widget<TextButton>(find.widgetWithText(TextButton, label))
    .onPressed!;

Widget _host(PreparedFrontend frontend, _Backend backend) => MaterialApp(
  home: Scaffold(
    body: frontend.createPresentation(
      key: ObjectKey(backend),
      library: modelConfigurationFrontendLibrary,
      entrypoint: 'buildModelPresetSelector',
      createBridge: () => PreparedFrontendBridges([
        SessionAccessoryBridge(
          sessionId: backend.session,
          validateAccess: () {},
          onEnd: backend.owning.invalidate,
        ),
        backend.owning,
      ]),
    ),
  ),
);

ModelPresetDefinition _preset(
  String id,
  String name, {
  String? effort,
  String provider = ' Local:Work/V2 ',
  String model = ' Org/Model.Mixed+v2 ',
}) => ModelPresetDefinition(
  presetId: id,
  name: name,
  description: null,
  model: ModelPresetModelReference(providerId: provider, modelId: model),
  reasoningEffort: effort,
);

ModelPresetSelectionSnapshot _selection(
  String? id,
  int revision, {
  String session = _session,
}) => ModelPresetSelectionSnapshot(
  sessionId: session,
  selectedPresetId: id,
  revision: revision,
);

Map<String, Object?> _write(String? id, int revision) => {
  'sessionId': _session,
  'selectedPresetId': id,
  'expectedRevision': revision,
};

final class _Backend
    implements ModelPresetCatalogService, ModelPresetSelectionService {
  _Backend({this.session = _session});
  final String session;
  late final selectionChannel = _Channel(
    ModelPresetSelectionServiceDispatcher(this),
  );
  late final catalogChannel = _Channel(
    ModelPresetCatalogServiceDispatcher(this),
  );
  late final owning = OwningBackendBridge(
    channels: {
      modelPresetCatalogServiceId: catalogChannel,
      modelPresetSelectionServiceId: selectionChannel,
    },
    validateBinding: () {},
  );
  List<Map<String, Object?>> get reads => selectionChannel.payloads(
    modelPresetSelectionServiceReadSessionSelectionId,
  );
  List<Map<String, Object?>> get writes => selectionChannel.payloads(
    modelPresetSelectionServiceUpdateSessionSelectionId,
  );
  List<Map<String, Object?>> get catalogReads =>
      catalogChannel.payloads(modelPresetCatalogServiceReadPresetsId);
  late var selected = _selection(null, 0, session: session);
  var presets = [_preset('work', 'Writer')];
  var complete = true;
  var readFails = false;
  var catalogFails = false;
  String? writeFailure;
  ModelPresetSelectionSnapshot? writeReply;
  Completer<void>? readGate;
  Completer<void>? ackGate;

  @override
  Future<ModelPresetCatalogSnapshot> readPresets() async {
    if (catalogFails) {
      throw const ModelPresetCatalogFailure(
        code: 'unavailable',
        message: _private,
      );
    }
    return ModelPresetCatalogSnapshot(presets: presets, isComplete: complete);
  }

  @override
  Future<ModelPresetSelectionSnapshot> readSessionSelection(
    String sessionId,
  ) async {
    await readGate?.future;
    if (readFails) {
      throw const ModelPresetSelectionFailure(
        code: 'storage_unavailable',
        message: _private,
      );
    }
    return selected;
  }

  @override
  Future<ModelPresetSelectionSnapshot> updateSessionSelection(
    String sessionId,
    String? selectedPresetId,
    int expectedRevision,
  ) async {
    final next = _selection(
      selectedPresetId,
      expectedRevision + 1,
      session: sessionId,
    );
    if (writeFailure == null || writeFailure == 'outcome_uncertain') {
      selected = next;
    }
    await ackGate?.future;
    if (writeFailure case final code?) {
      throw ModelPresetSelectionFailure(code: code, message: _private);
    }
    return writeReply ?? next;
  }
}

final class _Channel implements AdeleRequestChannel {
  _Channel(this.dispatcher);
  final AdeleBackendDispatcher dispatcher;
  final calls = <(String, Map<String, Object?>)>[];

  List<Map<String, Object?>> payloads(String method) => [
    for (final call in calls)
      if (call.$1 == method) call.$2,
  ];

  @override
  Future<Object?> request(String method, Map<String, Object?> payload) async {
    calls.add((method, payload));
    final response = await dispatcher.dispatch({
      'kind': 'request',
      'requestId': calls.length,
      'method': method,
      'payload': payload,
    });
    if (response['ok'] != true) {
      throw _WireFailure(response['error']! as Map<String, Object?>);
    }
    return response['payload'];
  }
}

final class _WireFailure implements AdeleRemoteFailure {
  const _WireFailure(this.error);
  final Map<String, Object?> error;
  @override
  String? get declaredFailureType => error['declaredFailureType'] as String?;
  @override
  String get code => error['code']! as String;
  @override
  String get message => error['message']! as String;
  @override
  Map<String, Object?> get details => error['details']! as Map<String, Object?>;
}
