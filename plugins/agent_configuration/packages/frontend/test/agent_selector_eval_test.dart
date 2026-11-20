import 'dart:async';
import 'dart:io';

import 'package:adele_contract/adele_contract.dart';
import 'package:adele_desktop/frontend/owning_backend_bridge.dart';
import 'package:adele_desktop/frontend/prepared_frontend.dart';
import 'package:adele_desktop/frontend/session_accessory_bridge.dart';
import 'package:agent_configuration_contract/agent_configuration_contract.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../../../app/tool/agent_configuration_frontend_compiler.dart';

const _session = 'session-opaque';
const _empty = 'No Agents configured. Create Agents in Global Settings.';
const _incomplete = 'Agent catalog is incomplete.';
const _unavailable = 'Agent catalog is unavailable.';
const _unconfirmed =
    'Change not confirmed. Refresh to check the current selection.';
const _private = 'PRIVATE: not selector display text';

void main() {
  late File artifact;
  late PreparedFrontend generation;
  late _Backend backend;

  setUpAll(() async {
    final directory = await Directory.systemTemp.createTemp('agent-selector-');
    addTearDown(() => directory.delete(recursive: true));
    artifact = File('${directory.path}/frontend.evc');
    await artifact.writeAsBytes(
      await compileAgentConfigurationFrontend(
        repositoryRoot: Directory.current.parent.parent.parent.parent,
      ),
    );
  });
  setUp(() async {
    generation = await PreparedFrontend.load(artifact);
    addTearDown(generation.invalidate);
    backend = _Backend();
  });

  Future<void> mount(WidgetTester tester) async {
    await tester.pumpWidget(_host(generation, backend));
    await tester.pumpAndSettle();
  }

  testWidgets('mount reads the captured Session without choosing a default', (
    tester,
  ) async {
    final gate = backend.selectionReadGate = Completer<void>();
    await mount(tester);
    expect(find.text('Loading Agents...'), findsOneWidget);
    expect(find.text('Agent: No Agent'), findsNothing);
    expect(backend.reads, [
      {'sessionId': _session},
    ]);
    expect(backend.writes, isEmpty);
    gate.complete();
    await tester.pumpAndSettle();
    expect(find.text('Agent: No Agent'), findsOneWidget);
    expect(find.text('Writer'), findsNothing);
    expect(backend.catalogReads, <Map<String, Object?>>[{}]);
    // An ordinary host rebuild and idle time do not poll or write a default.
    await mount(tester);
    await tester.pump(const Duration(minutes: 1));
    expect(backend.reads, hasLength(1));
    expect(backend.catalogReads, hasLength(1));
    expect(backend.writes, isEmpty);
  });

  testWidgets(
    'opening obtains current choices; stable IDs disambiguate names',
    (tester) async {
      await mount(tester);
      backend.agents = [
        _agent('beta', 'Writer'),
        _agent('blank', '  '),
        _agent('alpha', 'Writer'),
      ];
      await _tap(tester, 'Agent: No Agent');
      expect(backend.catalogReads, <Map<String, Object?>>[{}, {}]);
      expect(find.text('No Agent'), findsOneWidget);
      expect(find.text('Writer (alpha)'), findsOneWidget);
      expect(find.text('Writer (beta)'), findsOneWidget);
      expect(find.text('blank'), findsOneWidget);
      expect(
        tester.getTopLeft(find.text('Writer (alpha)')).dy,
        lessThan(tester.getTopLeft(find.text('Writer (beta)')).dy),
      );
      expect(find.textContaining(_private), findsNothing);
      await _tap(tester, 'Writer (beta)');
      expect(backend.writes, [_write('beta', 0)]);
      expect(find.text('No Agent'), findsNothing);
      expect(find.text('Agent: Writer (beta)'), findsOneWidget);
      await _tap(tester, 'Agent: Writer (beta)');
      await _tap(tester, 'Writer (alpha)');
      expect(find.text('Agent: Writer (alpha)'), findsOneWidget);
      expect(backend.writes, [_write('beta', 0), _write('alpha', 1)]);
    },
  );

  testWidgets(
    'selection is not optimistic; duplicate activation writes once, then clear uses the ack revision',
    (tester) async {
      backend.selection = _selection(null, 7);
      await mount(tester);
      await _tap(tester, 'Agent: No Agent');
      final gate = backend.writeGate = Completer<void>();
      // Two activations before Flutter can rebuild the enabled button. Merely
      // disabling it on the next frame would admit both writes.
      await tester.tap(find.text('Writer'));
      await tester.tap(find.text('Writer'));
      await tester.pumpAndSettle();
      expect(find.text('Saving selection...'), findsOneWidget);
      expect(find.text('Agent: Writer'), findsNothing);
      expect(backend.writes, [_write('author', 7)]);
      gate.complete();
      await tester.pumpAndSettle();
      expect(find.text('Agent: Writer'), findsOneWidget);
      await _tap(tester, 'Agent: Writer');
      await _tap(tester, 'No Agent');
      expect(find.text('Agent: No Agent'), findsOneWidget);
      expect(backend.writes, [_write('author', 7), _write(null, 8)]);
    },
  );

  testWidgets(
    'Refresh reflects create, rename and delete without mutating selection',
    (tester) async {
      backend.agents = [];
      await mount(tester);
      await _tap(tester, 'Agent: No Agent');
      expect(find.text(_empty), findsOneWidget);
      expect(find.text(_incomplete), findsNothing);
      backend.agents = [_agent('author', 'Writer')];
      await _tap(tester, 'Refresh');
      expect(find.text(_empty), findsNothing);
      await _tap(tester, 'Writer');
      backend.agents = [_agent('author', 'Renamed')];
      await _tap(tester, 'Refresh');
      expect(find.text('Agent: Renamed'), findsOneWidget);
      backend.agents = [];
      await _tap(tester, 'Refresh');
      expect(find.text('Agent: Missing Agent: author'), findsOneWidget);
      expect(find.text('Agent: No Agent'), findsNothing);
      expect(backend.writes, [_write('author', 0)]);
      await _tap(tester, 'Agent: Missing Agent: author');
      await _tap(tester, 'No Agent');
      expect(backend.writes, [_write('author', 0), _write(null, 1)]);
    },
  );

  testWidgets(
    'incomplete and unavailable are neither empty nor evidence of deletion',
    (tester) async {
      backend.selection = _selection('omitted', 4);
      backend.complete = false;
      await mount(tester);
      await _tap(tester, 'Agent: Unresolved Agent: omitted');
      expect(find.text('Writer'), findsOneWidget);
      expect(find.text(_incomplete), findsOneWidget);
      backend.agents = [];
      await _tap(tester, 'Refresh');
      expect(find.text('Writer'), findsNothing);
      expect(find.text(_incomplete), findsOneWidget);
      expect(find.text(_empty), findsNothing);
      backend.catalogFails = true;
      await _tap(tester, 'Refresh');
      expect(find.text(_unavailable), findsOneWidget);
      expect(find.text(_incomplete), findsNothing);
      expect(find.text(_empty), findsNothing);
      expect(find.textContaining('Missing Agent'), findsNothing);
      expect(find.text('Agent: Unresolved Agent: omitted'), findsOneWidget);
      expect(find.textContaining(_private), findsNothing);
      expect(backend.writes, isEmpty);
      // Clearing an acknowledged selection does not require a working catalog.
      await _tap(tester, 'No Agent');
      expect(backend.writes, [_write(null, 4)]);
      expect(find.text('Agent: No Agent'), findsOneWidget);
      // A partial catalog can still positively identify an observed record.
      backend.catalogFails = false;
      backend.agents = [_agent('author', 'Writer')];
      await _tap(tester, 'Agent: No Agent');
      await _tap(tester, 'Writer');
      expect(find.text('Agent: Writer'), findsOneWidget);
      expect(find.text(_incomplete), findsOneWidget);
      expect(backend.writes, [_write(null, 4), _write('author', 5)]);
    },
  );

  testWidgets(
    'failed selection read is not revision zero and cannot authorize a write',
    (tester) async {
      backend.selectionFails = true;
      await mount(tester);
      expect(find.text('Agent selection is unavailable.'), findsOneWidget);
      expect(find.text('Agent: No Agent'), findsNothing);
      expect(find.textContaining(_private), findsNothing);
      expect(find.text('Writer'), findsNothing);
      backend.selectionFails = false;
      backend.selection = _selection('author', 14);
      await tester.pump(const Duration(minutes: 1));
      expect(backend.reads, hasLength(1));
      expect(backend.writes, isEmpty);
      await _tap(tester, 'Refresh');
      expect(find.text('Agent: Writer'), findsOneWidget);
      await _tap(tester, 'Agent: Writer');
      await _tap(tester, 'No Agent');
      expect(backend.writes, [_write(null, 14)]);
    },
  );

  for (final code in ['stale_revision', 'outcome_uncertain']) {
    testWidgets(
      '$code does not replay or claim success; explicit refresh reconciles before the next write',
      (tester) async {
        backend.selection = _selection(null, 2);
        backend.agents = [
          _agent('author', 'Writer'),
          _agent('other', 'Reviewer'),
        ];
        await mount(tester);
        await _tap(tester, 'Agent: No Agent');
        final reads = backend.reads.length;
        final catalogs = backend.catalogReads.length;
        // In one case a different writer won; in the other the original write
        // commits and only its acknowledgement is lost.
        final uncertain = code == 'outcome_uncertain';
        if (!uncertain) backend.selection = _selection('other', 8);
        backend.writeFailure = code;
        await _tap(tester, 'Writer');
        expect(find.text(_unconfirmed), findsOneWidget);
        expect(find.text('Agent: Writer'), findsNothing);
        expect(find.textContaining(_private), findsNothing);
        backend.writeFailure = null;
        await tester.pump(const Duration(minutes: 1));
        expect(backend.writes, [_write('author', 2)]);
        expect(backend.reads, hasLength(reads));
        expect(backend.catalogReads, hasLength(catalogs));
        expect(find.text('No Agent'), findsNothing);
        backend.selectionFails = true;
        await _tap(tester, 'Refresh');
        expect(find.text(_unconfirmed), findsOneWidget);
        expect(find.text('No Agent'), findsNothing);
        expect(backend.writes, [_write('author', 2)]);
        backend.selectionFails = false;
        await _tap(tester, 'Refresh');
        final label = uncertain ? 'Agent: Writer' : 'Agent: Reviewer';
        expect(find.text(label), findsOneWidget);
        expect(find.text(_unconfirmed), findsNothing);
        expect(backend.reads, hasLength(reads + 2));
        expect(backend.writes, [_write('author', 2)]);
        await _tap(tester, label);
        await _tap(tester, 'No Agent');
        expect(backend.writes, [
          _write('author', 2),
          _write(null, uncertain ? 3 : 8),
        ]);
      },
    );
  }

  testWidgets('a read for a different Session is not a selection baseline', (
    tester,
  ) async {
    backend.selection = _selection('author', 5, session: 'not-presented');
    await mount(tester);
    expect(find.text('Agent selection is unavailable.'), findsOneWidget);
    expect(find.text('Agent: Writer'), findsNothing);
    expect(find.text('Agent: No Agent'), findsNothing);
    expect(backend.writes, isEmpty);
  });

  testWidgets('retirement rejects a still-visible choice before unmount', (
    tester,
  ) async {
    await mount(tester);
    await _tap(tester, 'Agent: No Agent');
    generation.invalidate();
    // Flutter has not rebuilt yet, and the button was enabled on the last frame.
    await tester.tap(find.text('Writer'));
    await tester.pumpAndSettle();
    expect(find.text('Frontend unavailable.'), findsOneWidget);
    expect(backend.writes, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a retired write cannot publish to the next Session', (
    tester,
  ) async {
    await mount(tester);
    await _tap(tester, 'Agent: No Agent');
    final gate = backend.writeGate = Completer<void>();
    await _tap(tester, 'Writer');
    expect(backend.writes, [_write('author', 0)]);
    // Retire before Flutter removes the old subtree/callbacks. A new
    // presentation has a distinct runtime even when it uses identical bytes.
    generation.invalidate();
    await tester.pumpAndSettle();
    expect(find.text('Frontend unavailable.'), findsOneWidget);
    final next = await tester.runAsync(() => PreparedFrontend.load(artifact));
    addTearDown(next!.invalidate);
    final other = _Backend(session: 'different-session');
    await tester.pumpWidget(_host(next, other));
    await tester.pumpAndSettle();
    gate.complete();
    await tester.pumpAndSettle();
    expect(find.text('Agent: No Agent'), findsOneWidget);
    expect(find.text('Agent: Writer'), findsNothing);
    expect(backend.writes, [_write('author', 0)]);
    expect(other.reads, [
      {'sessionId': 'different-session'},
    ]);
    expect(other.writes, isEmpty);
    expect(tester.takeException(), isNull);
  });
}

Future<void> _tap(WidgetTester tester, String label) async {
  await tester.tap(find.text(label));
  await tester.pumpAndSettle();
}

Widget _host(PreparedFrontend generation, _Backend backend) => MaterialApp(
  home: Scaffold(
    body: generation.createPresentation(
      key: ObjectKey(backend),
      library: agentConfigurationFrontendLibrary,
      entrypoint: 'buildAgentSelector',
      createBridge: () {
        final owning = OwningBackendBridge(
          channels: {
            agentSelectionServiceId: backend.selectionChannel,
            agentCatalogServiceId: backend.catalogChannel,
          },
          validateBinding: () {},
        );
        return PreparedFrontendBridges([
          SessionAccessoryBridge(
            sessionId: backend.session,
            validateAccess: () {},
            onEnd: owning.invalidate,
          ),
          owning,
        ]);
      },
    ),
  ),
);

AgentDefinition _agent(String id, String name) => AgentDefinition(
  id: id,
  name: name,
  description: null,
  whenToUse: null,
  instructions: _private,
);

AgentSelectionSnapshot _selection(
  String? id,
  int revision, {
  String session = _session,
}) => AgentSelectionSnapshot(
  sessionId: session,
  selectedAgentId: id,
  revision: revision,
);

Map<String, Object?> _write(String? id, int revision) => {
  'sessionId': _session,
  'selectedAgentId': id,
  'expectedRevision': revision,
};

final class _Backend implements AgentCatalogService, AgentSelectionService {
  _Backend({this.session = _session});
  final String session;
  late final selectionChannel = _Channel(AgentSelectionServiceDispatcher(this));
  late final catalogChannel = _Channel(AgentCatalogServiceDispatcher(this));
  List<Map<String, Object?>> get reads =>
      selectionChannel.payloads(agentSelectionServiceReadSessionSelectionId);
  List<Map<String, Object?>> get writes =>
      selectionChannel.payloads(agentSelectionServiceUpdateSessionSelectionId);
  List<Map<String, Object?>> get catalogReads =>
      catalogChannel.payloads(agentCatalogServiceReadAgentsId);
  late var selection = _selection(null, 0, session: session);
  var agents = [_agent('author', 'Writer')];
  var complete = true;
  var selectionFails = false;
  var catalogFails = false;
  String? writeFailure;
  Completer<void>? selectionReadGate;
  Completer<void>? writeGate;

  @override
  Future<AgentCatalogSnapshot> readAgents() async {
    if (catalogFails) {
      throw const AgentCatalogFailure(code: 'unavailable', message: _private);
    }
    return AgentCatalogSnapshot(agents: agents, isComplete: complete);
  }

  @override
  Future<AgentSelectionSnapshot> readSessionSelection(String sessionId) async {
    await selectionReadGate?.future;
    if (selectionFails) {
      throw const AgentSelectionFailure(
        code: 'storage_unavailable',
        message: _private,
      );
    }
    return selection;
  }

  @override
  Future<AgentSelectionSnapshot> updateSessionSelection(
    String sessionId,
    String? selectedAgentId,
    int expectedRevision,
  ) async {
    await writeGate?.future;
    final next = _selection(
      selectedAgentId,
      expectedRevision + 1,
      session: sessionId,
    );
    if (writeFailure case final code?) {
      if (code == 'outcome_uncertain') selection = next;
      throw AgentSelectionFailure(code: code, message: _private);
    }
    return selection = next;
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
