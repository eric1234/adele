import 'dart:convert';
import 'dart:io';

import 'package:adele_capabilities/adele_capabilities.dart';
import 'package:adele_desktop/core/application_plugin_bootstrap.dart';
import 'package:adele_desktop/core/prepared_settings.dart';
import 'package:adele_desktop/frontend/application_frontend_bootstrap.dart';
import 'package:adele_desktop/frontend/owning_backend_bridge.dart';
import 'package:adele_desktop/frontend/session_content_inspection_bridge.dart';
import 'package:adele_desktop/frontend/structured_bridge_data.dart';
import 'package:adele_desktop/ui/inspection/activity_inspection_selection.dart';
import 'package:adele_desktop/ui/inspection/inspection_host.dart';
import 'package:adele_plugin_api/adele_plugin_api.dart';
import 'package:adele_product/adele_product.dart';
import 'package:adele_ui/adele_ui.dart';
import 'package:contract_codegen/contract_codegen.dart';
import 'package:dart_eval/dart_eval.dart';
import 'package:flutter/material.dart';
import 'package:flutter_eval/flutter_eval.dart';
import 'package:flutter_eval/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plugin_builder/plugin_builder.dart';
import 'package:plugin_runtime/plugin_runtime.dart';

const _library = 'package:content_backend_renderer/main.dart';
const _kind = 'fixture.content';
const _owner = 'test.content-owner';
const _foreign = 'test.foreign-owner';
const _bound = Duration(seconds: 10);

void main() {
  late Directory temporary;
  late File hostArtifact;
  late File backendArtifact;
  late File rendererArtifact;
  late String aotRuntime;
  var sequence = 0;

  setUpAll(() async {
    temporary = await Directory.systemTemp.createTemp('content-backend-');
    addTearDown(() => temporary.delete(recursive: true));
    final dart = _dartExecutable();
    aotRuntime = File(dart).parent.uri
        .resolve(Platform.isWindows ? 'dartaotruntime.exe' : 'dartaotruntime')
        .toFilePath();
    hostArtifact = File('${temporary.path}/host.aot');
    backendArtifact = File('${temporary.path}/backend.aot');
    for (final target in [
      (
        entrypoint: 'packages/plugin_backend_host/bin/adele_backend_host.dart',
        artifact: hostArtifact,
      ),
      (
        entrypoint: 'app/test/fixtures/session_content_inspection_backend.dart',
        artifact: backendArtifact,
      ),
    ]) {
      await compileAotSnapshot(
        dartExecutable: dart,
        workingDirectory: Directory.current.parent,
        entrypoint: target.entrypoint,
        artifact: target.artifact,
        stage: 'session-content-inspection-backend',
      );
    }
    final program =
        (Compiler()
              ..addPlugin(flutterEvalPlugin)
              ..addPlugin(const SessionContentInspectionDeclarations())
              ..addPlugin(const OwningBackendDeclarations())
              ..entrypoints.add(_library))
            .compile({
              'content_backend_renderer': {'main.dart': _rendererSource},
              'adele_contract': {
                'adele_contract.dart': evalContractSupportSource,
              },
              'adele_ui': {
                for (final file in [
                  'session_content_inspection_bridge.dart',
                  'owning_backend_bridge.dart',
                ])
                  file: await File('../packages/ui/lib/$file').readAsString(),
              },
            });
    rendererArtifact = await File(
      '${temporary.path}/renderer.evc',
    ).writeAsBytes(program.write());
  });

  Future<_Fixture> fixture(WidgetTester tester) async {
    final f = _Fixture(
      root: Directory('${temporary.path}/case-${sequence++}'),
      hostArtifact: hostArtifact,
      backendArtifact: backendArtifact,
      rendererArtifact: rendererArtifact,
      aotRuntime: aotRuntime,
    );
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(f.close);
    });
    await tester.binding.setSurfaceSize(const Size(1200, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.runAsync(f.install);
    await tester.runAsync(() => f.startBackends('owner-v1'));
    await tester.runAsync(() => f.startFrontends(f.backends.catalog!));
    await tester.pumpWidget(f.widget());
    await tester.pumpAndSettle();
    return f;
  }

  testWidgets(
    'compiled content reads only the exact installation and never retargets a retired backend',
    (tester) async {
      final f = await fixture(tester);
      final owner = f.connection(_owner);
      final foreign = f.connection(_foreign);
      final first = await f.open(tester, 'first');
      final firstRuntime = _runtime(tester, first);
      final firstProbe = _Probe(firstRuntime);
      expect(_invoke(firstRuntime, 'facts'), {
        'sessionId': 'session',
        'taskId': 'task',
        'strategyId': 'test.unavailable-strategy',
        'contentKind': _kind,
        'occurrenceId': 'first',
      });
      await _query(
        tester,
        first,
        'Read',
        'owner-v1|session/first|first content',
      );
      final second = await f.open(tester, 'second');
      await _query(
        tester,
        second,
        'Read',
        'owner-v1|session/second|second content',
      );
      expect(firstProbe.result, 'owner-v1|session/first|first content');

      // The private retrieval route really exists, but is not in backendServices.
      expect(
        await tester.runAsync(
          () => foreign
              .channelFor(
                foreign.defaultConfigurationContext,
                'fixture.private',
              )
              .request('read', {
                'sessionId': 'session',
                'occurrenceId': 'first',
              }),
        ),
        'foreign|session/first|first content',
      );
      await _query(tester, first, 'Undeclared', 'unavailable');
      await _query(tester, first, 'Control', 'unavailable');
      await _query(tester, first, 'Mutate', 'unavailable');
      final missing = await f.open(tester, 'first', kind: 'fixture.missing');
      await _query(tester, missing, 'Read', 'unavailable');
      final orphan = await f.open(tester, 'first', kind: 'fixture.orphan');
      await _query(tester, orphan, 'Read', 'unavailable');
      expect(await tester.runAsync(() => _audit(owner)), [
        _request('first'),
        _request('second'),
        _request('first', method: 'write'),
        _request('first', service: 'fixture.missing'),
      ]);
      expect(await tester.runAsync(() => _audit(foreign)), [
        _request('first', service: 'fixture.private'),
      ]);

      // Equal plugin IDs, paths and descriptors in a second discovery are not
      // the backend owner's exact authorized installation snapshot.
      await tester.runAsync(f.frontends.close);
      final foreignCatalog = (await tester.runAsync(
        () => PreparedPluginCatalog.discover(f.root.path),
      ))!;
      final actualInstallation = f.backends.catalog!.installations.singleWhere(
        (entry) => entry.metadata.id.value == _owner,
      );
      final copiedInstallation = foreignCatalog.installations.singleWhere(
        (entry) => entry.metadata.id.value == _owner,
      );
      expect(copiedInstallation.metadata.id, actualInstallation.metadata.id);
      expect(
        copiedInstallation.installationDirectory.path,
        actualInstallation.installationDirectory.path,
      );
      expect(copiedInstallation, isNot(same(actualInstallation)));
      expect(f.backends.backendForInstallation(copiedInstallation), isNull);
      await tester.runAsync(() => f.startFrontends(foreignCatalog));
      final wrong = await f.open(tester, 'first');
      await _query(tester, wrong, 'Read', 'unavailable');
      expect(await tester.runAsync(() => _audit(owner)), hasLength(4));

      await tester.runAsync(f.frontends.close);
      await tester.runAsync(() => f.startFrontends(f.backends.catalog!));
      final captured = await f.open(tester, 'first');
      final capturedRuntime = _runtime(tester, captured);
      final capturedProbe = _Probe(capturedRuntime);
      final cachedRead = _callback(tester, captured, 'Read');
      await _query(
        tester,
        captured,
        'Read',
        'owner-v1|session/first|first content',
      );
      final pending = await f.open(tester, 'held-disappearance');
      final pendingRuntime = _runtime(tester, pending);
      final pendingProbe = _Probe(pendingRuntime);
      _callback(tester, pending, 'Read')();
      await tester.runAsync(
        () => _control(owner, 'wait', {'key': 'session/held-disappearance'}),
      );
      expect(pendingProbe.completions, 0);
      await tester.runAsync(owner.close);
      await _settled(tester, pendingProbe, 1, 'unavailable');
      await _query(tester, captured, 'Read', 'unavailable');
      expect(captured.content!.isActive, isTrue);
      expect(f.backends.backendForInstallation(actualInstallation), isNull);

      final replacement = (await tester.runAsync(
        () => f.backends.host!.startPlugin(
          pluginId: _owner,
          artifactUri: backendArtifact.uri,
          arguments: ['unowned-replacement'],
        ),
      ))!;
      expect(replacement.pluginId, owner.pluginId);
      expect(replacement, isNot(same(owner)));
      expect(replacement.isClosed, isFalse);
      expect(
        () => replacement.channelFor(
          owner.defaultConfigurationContext,
          'fixture.content',
        ),
        throwsArgumentError,
      );
      expect(
        await tester.runAsync(
          () => replacement
              .channelFor(
                replacement.defaultConfigurationContext,
                'fixture.content',
              )
              .request('read', {
                'sessionId': 'session',
                'occurrenceId': 'first',
              }),
        ),
        'unowned-replacement|session/first|first content',
      );
      await _query(tester, captured, 'Read', 'unavailable');
      final absent = await f.open(tester, 'first');
      await _query(tester, absent, 'Read', 'unavailable');
      expect(await tester.runAsync(() => _audit(replacement)), [
        _request('first'),
      ]);
      expect(await tester.runAsync(() => _audit(foreign)), hasLength(1));

      // A new catalog/bootstrap and an explicit open may capture a new owner.
      // Neither the old card nor its retained callback may acquire it.
      final oldBinding = captured.content!.presenter;
      await tester.runAsync(f.frontends.close);
      await tester.runAsync(f.backends.close);
      await tester.runAsync(() => f.startBackends('owner-v2'));
      await tester.runAsync(() => f.startFrontends(f.backends.catalog!));
      final fresh = await f.open(tester, 'first');
      expect(fresh.id, isNot(same(captured.id)));
      expect(fresh.content!.presenter.id, oldBinding.id);
      expect(fresh.content!.presenter.isSameRegistration(oldBinding), isFalse);
      expect(captured.content!.isActive, isFalse);
      final completions = capturedProbe.completions;
      cachedRead();
      await _settled(tester, capturedProbe, completions + 1, 'unavailable');
      expect(
        await tester.runAsync(() => _audit(f.connection(_owner))),
        isEmpty,
      );
      await _query(
        tester,
        fresh,
        'Read',
        'owner-v2|session/first|first content',
      );
      expect(await tester.runAsync(() => _audit(f.connection(_owner))), [
        _request('first'),
      ]);
      expect(f.window.cards, contains(captured));
      expect(find.textContaining('unowned-replacement'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'dismissal and navigation fence admitted AOT reads before evaluator delivery',
    (tester) async {
      final f = await fixture(tester);
      final owner = f.connection(_owner);
      for (final departure in ['dismissal', 'navigation']) {
        final occurrence = 'held-$departure';
        final card = await f.open(tester, occurrence);
        final runtime = _runtime(tester, card);
        final probe = _Probe(runtime);
        final read = _callback(tester, card, 'Read');
        read();
        await tester.runAsync(
          () => _control(owner, 'wait', {'key': 'session/$occurrence'}),
        );
        expect(probe.completions, 0);
        expect(probe.result, 'pending');
        if (departure == 'dismissal') {
          final dismiss = find.descendant(
            of: find.byKey(ValueKey(card.id)).first,
            matching: find.byTooltip('Dismiss Inspection'),
          );
          await tester.ensureVisible(dismiss);
          await tester.tap(dismiss);
        } else {
          f.presented = f.other;
          f.window.presentSession(f.other);
        }
        expect(card.content!.isActive, isFalse);
        expect(f.window.cards, isEmpty);
        await tester.pumpAndSettle();
        await tester.runAsync(
          () => _control(owner, 'release', {'key': 'session/$occurrence'}),
        );
        // Observe the retained EVC, not just the now-unmounted widget. A native
        // success must settle as unavailable before reaching interpreted code.
        await _settled(tester, probe, 1, 'unavailable');
        read();
        await _settled(tester, probe, 2, 'unavailable');
        expect(find.textContaining('late $departure content'), findsNothing);
        expect(f.window.cards, isEmpty);
      }
      expect(await tester.runAsync(() => _audit(owner)), [
        _request('held-dismissal'),
        _request('held-navigation'),
      ]);
      expect(
        await tester.runAsync(() => _audit(f.connection(_foreign))),
        isEmpty,
      );
      final fresh = await f.open(tester, 'first');
      await _query(tester, fresh, 'Read', 'owner-v1|other/first|other content');
      expect(fresh.content!.session, same(f.other));
      expect(tester.takeException(), isNull);
    },
  );
}

final class _Fixture {
  _Fixture({
    required this.root,
    required this.hostArtifact,
    required this.backendArtifact,
    required this.rendererArtifact,
    required this.aotRuntime,
  }) {
    presented = session;
    window.presentSession(session);
  }

  final Directory root;
  final File hostArtifact;
  final File backendArtifact;
  final File rendererArtifact;
  final String aotRuntime;
  final capabilities = CapabilityRegistry();
  final extensions = ExtensionRegistry();
  final window = WindowInspection();
  final session = _session('session');
  final other = _session('other');
  final _backendOwners = <ApplicationPluginBootstrap>[];
  final _frontendOwners = <ApplicationFrontendBootstrap>[];
  late Session presented;
  ApplicationPluginBootstrap get backends => _backendOwners.last;
  ApplicationFrontendBootstrap get frontends => _frontendOwners.last;

  Future<void> install() async {
    for (final id in [_owner, _foreign, 'test.orphan']) {
      final directory = await Directory(
        '${root.path}/$id',
      ).create(recursive: true);
      if (id != 'test.orphan') {
        await backendArtifact.copy('${directory.path}/backend.aot');
      }
      if (id != _foreign) {
        await rendererArtifact.copy('${directory.path}/frontend.evc');
      }
      await File(
        '${directory.path}/adele_plugin.installation.json',
      ).writeAsString(
        jsonEncode({
          'manifestVersion': 1,
          'metadata': {'id': id, 'version': '1', 'displayName': id},
          'components': {
            if (id != 'test.orphan') 'backend': {'artifact': 'backend.aot'},
            if (id != _foreign)
              'frontend': {
                'artifact': 'frontend.evc',
                'presentations': [
                  if (id == _owner) ...[
                    _descriptor(_kind, 'fixture.content'),
                    _descriptor('fixture.missing', 'fixture.missing'),
                  ] else
                    _descriptor('fixture.orphan', 'fixture.content'),
                ],
              },
          },
        }),
      );
    }
  }

  Future<void> startBackends(String identity) async {
    final bootstrap = ApplicationPluginBootstrap(
      capabilities,
      extensions,
      loadSettings: (catalog) async =>
          PreparedSettingsSnapshot.resolve(catalog),
    );
    _backendOwners.add(bootstrap);
    await bootstrap.start(
      installationRoot: root.path,
      dartaotruntimeExecutable: aotRuntime,
      hostArtifactPath: hostArtifact.path,
      startupArguments: {
        _owner: [identity],
        _foreign: ['foreign'],
      },
    );
    expect(bootstrap.state, ApplicationPluginState.ready);
    expect(bootstrap.catalog!.issues, isEmpty);
    expect(bootstrap.backends, hasLength(2));
    for (final backend in bootstrap.backends) {
      expect(
        backend.state,
        InstalledBackendState.active,
        reason: '${backend.failure}',
      );
      // No strategy, model, Environment, capability or execution advertisement.
      expect(backend.connection!.capabilityExposures, isEmpty);
      expect(backend.connection!.extensionExposures, isEmpty);
    }
  }

  Future<void> startFrontends(PreparedPluginCatalog catalog) async {
    // No Session execution/services, Environment host or mutation API is wired.
    final bootstrap = ApplicationFrontendBootstrap(
      extensions: extensions,
      backends: backends,
      loadSettings: (catalog) async =>
          PreparedSettingsSnapshot.resolve(catalog),
    );
    _frontendOwners.add(bootstrap);
    await bootstrap.start(catalog);
    for (final frontend in bootstrap.generations) {
      expect(
        frontend.state,
        InstalledFrontendState.active,
        reason: '${frontend.failure}',
      );
    }
  }

  PluginBackendConnection connection(String id) => backends.backends
      .singleWhere((backend) => backend.installation.metadata.id.value == id)
      .connection!;

  Future<InspectionCard> open(
    WidgetTester tester,
    String occurrence, {
    String kind = _kind,
  }) async {
    expect(
      window.inspectContent(
        session: presented,
        kind: SessionContentKind(kind),
        occurrenceId: SessionContentOccurrenceId(occurrence),
        extensions: extensions,
      ),
      isTrue,
    );
    final card = window.cards.first;
    await tester.pumpAndSettle();
    expect(_runtime(tester, card), isA<Runtime>());
    return card;
  }

  Widget widget() => MaterialApp(
    home: Scaffold(
      body: SingleChildScrollView(
        child: ListenableBuilder(
          listenable: window,
          builder: (_, _) => InspectionStackHost(
            cards: window.cards,
            cardBuilder: (_, card) => InspectionHost(
              card: card,
              activity: null,
              heading: 'Fixture content',
              extensions: extensions,
              onCollapse: () => window.collapse(card.id),
              onExpand: () => window.expand(card.id),
              onDismiss: () => window.dismiss(card.id),
              onInspectOutput: (_) => fail('No activity or Run exists.'),
            ),
          ),
        ),
      ),
    ),
  );

  Future<void> close() async {
    window.dispose();
    for (final owner in _frontendOwners.reversed) {
      await owner.close();
    }
    for (final owner in _backendOwners.reversed) {
      await owner.close();
    }
  }
}

Session _session(String id) => Session(
  id: SessionId(id),
  taskId: TaskId('task'),
  strategyId: OrchestrationStrategyId('test.unavailable-strategy'),
);

Map<String, Object?> _descriptor(String kind, String service) =>
    PreparedSessionContentInspection(
      extensionId: ExtensionId('$kind.renderer'),
      contentKind: kind,
      library: _library,
      entrypoint: 'buildInspection',
      backendServices: [service],
    ).toJson();

Finder _inside(InspectionCard card, Finder matching) => find.descendant(
  of: find.byKey(ValueKey(card.id)).first,
  matching: matching,
);

Runtime _runtime(WidgetTester tester, InspectionCard card) => tester
    .widget<$StatefulWidget$bridge>(
      _inside(
        card,
        find.byWidgetPredicate((widget) => widget is $StatefulWidget$bridge),
      ),
    )
    .$runtime;

VoidCallback _callback(
  WidgetTester tester,
  InspectionCard card,
  String label,
) => tester
    .widget<TextButton>(_inside(card, find.widgetWithText(TextButton, label)))
    .onPressed!;

Object? _invoke(Runtime runtime, String entrypoint) =>
    copyStructuredBridgeData(runtime.executeLib(_library, entrypoint));

// Retain the EVC-owned result cell before a request starts. Reading the cell
// does not re-enter the interpreter while its async continuation is suspended.
final class _Probe {
  _Probe(Runtime runtime)
    : _cell = runtime.executeLib(_library, 'probe') as List<Object?>;

  final List<Object?> _cell;
  String get result => copyStructuredBridgeData(_cell[0]) as String;
  int get completions => copyStructuredBridgeData(_cell[1]) as int;
}

Future<void> _query(
  WidgetTester tester,
  InspectionCard card,
  String label,
  String expected,
) async {
  final runtime = _runtime(tester, card);
  final probe = _Probe(runtime);
  final count = probe.completions;
  _callback(tester, card, label)();
  await _settled(tester, probe, count + 1, expected);
  expect(_inside(card, find.text(expected)), findsOneWidget);
}

Future<void> _settled(
  WidgetTester tester,
  _Probe probe,
  int count,
  String expected,
) async {
  await tester.runAsync(() async {
    final deadline = DateTime.now().add(_bound);
    while (probe.completions != count && DateTime.now().isBefore(deadline)) {
      await Future<void>(() {});
      await tester.pump();
    }
  });
  await tester.pump();
  expect(probe.completions, count);
  expect(probe.result, expected);
}

Future<Object?> _control(
  PluginBackendConnection connection,
  String method, [
  Map<String, Object?> payload = const {},
]) => connection
    .channelFor(connection.defaultConfigurationContext, 'fixture.control')
    .request(method, payload)
    .timeout(_bound);

Future<List<Object?>> _audit(PluginBackendConnection connection) async =>
    List<Object?>.from(await _control(connection, 'snapshot') as List<Object?>);

Map<String, Object?> _request(
  String occurrence, {
  String method = 'read',
  String service = 'fixture.content',
}) => {
  'configurationContext': 'default',
  'serviceId': service,
  'method': method,
  'payload': {'sessionId': 'session', 'occurrenceId': occurrence},
  'hostInvocationContext': null,
};

String _dartExecutable() {
  final root = Platform.environment['FLUTTER_ROOT'];
  if (root != null) {
    final dart = File('$root/bin/cache/dart-sdk/bin/dart');
    if (dart.existsSync()) return dart.path;
  }
  var directory = File(Platform.resolvedExecutable).parent;
  while (!File('${directory.path}/dart-sdk/bin/dart').existsSync()) {
    if (directory.parent.path == directory.path) {
      throw StateError('Pinned Dart SDK not found.');
    }
    directory = directory.parent;
  }
  return '${directory.path}/dart-sdk/bin/dart';
}

const _rendererSource = r'''
import 'package:adele_ui/owning_backend_bridge.dart';
import 'package:adele_ui/session_content_inspection_bridge.dart';
import 'package:flutter/material.dart';

Map<String, dynamic> captured = {};
final List<dynamic> observation = ['idle', 0];
List<dynamic> probe() => observation;
Map<String, dynamic> facts() => readSessionContentInspectionContext();

Widget buildInspection() {
  captured = readSessionContentInspectionContext();
  return ContentInspection();
}

class ContentInspection extends StatefulWidget {
  @override
  State<ContentInspection> createState() => ContentInspectionState();
}

class ContentInspectionState extends State<ContentInspection> {
  String status = 'idle';
  bool disposed = false;

  Future<void> query(String service, String method) async {
    status = 'pending';
    observation[0] = status;
    if (!disposed) setState(() {});
    final payload = service == 'fixture.control'
        ? {'key': captured['sessionId'] + '/' + captured['occurrenceId']}
        : {
            'sessionId': captured['sessionId'],
            'occurrenceId': captured['occurrenceId'],
          };
    final response = await settleOwningBackendOperation(
      requestOwningBackend(service, method, payload),
    );
    status = response[0] == true ? response[1].toString() : 'unavailable';
    observation[0] = status;
    observation[1] = observation[1] + 1;
    if (!disposed) setState(() {});
  }

  @override
  void dispose() {
    disposed = true;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final service = captured['contentKind'] == 'fixture.missing'
        ? 'fixture.missing' : 'fixture.content';
    return Column(children: [
      Text(captured['sessionId'] + '/' + captured['occurrenceId']),
      Text(status),
      TextButton(
        onPressed: () { query(service, 'read'); },
        child: const Text('Read'),
      ),
      TextButton(
        onPressed: () { query('fixture.private', 'read'); },
        child: const Text('Undeclared'),
      ),
      TextButton(
        onPressed: () { query('fixture.control', 'release'); },
        child: const Text('Control'),
      ),
      TextButton(
        onPressed: () { query('fixture.content', 'write'); },
        child: const Text('Mutate'),
      ),
    ]);
  }
}
''';
