import 'dart:io';

import 'package:adele_capabilities/adele_capabilities.dart';
import 'package:adele_desktop/core/adele_runtime.dart';
import 'package:adele_desktop/frontend/contribution_bridge.dart';
import 'package:adele_desktop/frontend/main_content_bridge.dart';
import 'package:adele_desktop/frontend/prepared_frontend.dart';
import 'package:adele_desktop/frontend/prepared_main_content_host.dart';
import 'package:adele_desktop/frontend/prepared_session_services.dart';
import 'package:adele_desktop/frontend/structured_bridge_data.dart';
import 'package:adele_desktop/ui/execution/session_execution_controller.dart';
import 'package:adele_desktop/ui/main_content/main_content_host.dart';
import 'package:adele_environment/adele_environment.dart';
import 'package:adele_orchestration/adele_orchestration.dart';
import 'package:adele_plugin_api/adele_plugin_api.dart';
import 'package:adele_product/adele_product.dart';
import 'package:adele_ui/adele_ui.dart';
import 'package:dart_eval/dart_eval.dart';
import 'package:dart_eval/dart_eval_bridge.dart';
import 'package:dart_eval/stdlib/core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_eval/flutter_eval.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plugin_runtime/plugin_runtime.dart';

const _library = 'package:inspection_probe/main.dart';
const _kind = 'test.content';
const _occurrence = 'occurrence-1';
final _extensionId = ExtensionId('test.inspection-opener');

void main() {
  group('native semantic Inspection opening', () {
    test('missing callback is denied, even with a copied Session identity', () {
      final bridge = MainContentBridge(
        context: const {'sessionId': 'not-authority'},
        isActive: () => true,
      );
      expect(bridge.inspectSessionContent(_kind, _occurrence), isFalse);
      expect(bridge.isActive, isTrue);
    });

    test(
      'validates identities and contains callback rejection and failure',
      () {
        final calls = <(SessionContentKind, SessionContentOccurrenceId)>[];
        var accepted = true;
        var fail = false;
        final bridge = MainContentBridge(
          context: const {},
          isActive: () => true,
          inspectSessionContent: (kind, occurrence) {
            calls.add((kind, occurrence));
            if (fail) throw StateError('private native diagnostic');
            return accepted;
          },
        );
        for (final invalid in [
          '',
          'invalid kind',
          'test.content\n',
          'test.\u00e9',
          'x' * 129,
        ]) {
          expect(bridge.inspectSessionContent(invalid, _occurrence), isFalse);
        }
        for (final invalid in [
          '',
          'invalid occurrence',
          'occurrence\n',
          '\u00e9',
          'x' * 257,
        ]) {
          expect(bridge.inspectSessionContent(_kind, invalid), isFalse);
        }
        expect(calls, isEmpty);
        expect(bridge.inspectSessionContent(_kind, _occurrence), isTrue);
        expect(calls.single.$1.value, _kind);
        expect(calls.single.$2.value, _occurrence);
        accepted = false;
        expect(bridge.inspectSessionContent(_kind, _occurrence), isFalse);
        fail = true;
        expect(bridge.inspectSessionContent(_kind, _occurrence), isFalse);
        expect(calls, hasLength(3));
        expect(bridge.isActive, isTrue);
      },
    );

    for (final invalidate in [false, true]) {
      test(
        'cached callback stays denied after ${invalidate ? 'invalidation' : 'observed retirement'}',
        () {
          var active = true;
          var calls = 0;
          final bridge = MainContentBridge(
            context: const {},
            isActive: () => active,
            inspectSessionContent: (_, _) {
              calls++;
              return true;
            },
          );
          final cached = bridge.inspectSessionContent;
          expect(cached(_kind, _occurrence), isTrue);
          if (invalidate) {
            bridge.invalidate();
          } else {
            active = false;
          }
          expect(cached(_kind, _occurrence), isFalse);
          active = true;
          expect(cached(_kind, _occurrence), isFalse);
          expect(calls, 1);
        },
      );
    }
  });

  group('mounted prepared semantic Inspection opening', () {
    late Directory temporary;
    late File artifact;

    setUpAll(() async {
      temporary = await Directory.systemTemp.createTemp('inspection-probe-');
      final program =
          (Compiler()
                ..addPlugin(flutterEvalPlugin)
                ..addPlugin(const MainContentDeclarations())
                ..addPlugin(const ContributionDeclarations())
                ..entrypoints.add(_library))
              .compile({
                'inspection_probe': {'main.dart': _source},
                'adele_ui': {
                  for (final library in [
                    'main_content_bridge',
                    'contribution_bridge',
                  ])
                    '$library.dart': await File(
                      '../packages/ui/lib/$library.dart',
                    ).readAsString(),
                },
              });
      artifact = await File(
        '${temporary.path}/probe.evc',
      ).writeAsBytes(program.write());
    });
    tearDownAll(() => temporary.delete(recursive: true));

    Future<_Fixture> fixture(
      WidgetTester tester, {
      bool canonicalRuntime = true,
      bool callback = true,
    }) async {
      final generation = (await tester.runAsync(
        () => PreparedFrontend.load(artifact),
      ))!;
      final result = _Fixture(
        generation,
        temporary,
        canonicalRuntime: canonicalRuntime,
        callback: callback,
      );
      addTearDown(result.close);
      return result;
    }

    testWidgets(
      'opted-in pane sends only validated content and its captured Session',
      (tester) async {
        final f = await fixture(tester);
        f.contribute(allowed: true);
        await tester.pumpWidget(f.widget());
        await tester.pumpAndSettle();
        expect(find.text('Init denied'), findsOneWidget);
        expect(f.requests, isEmpty);
        final eval = f.pane('first').runtime;
        expect(_request(eval, kind: 'invalid kind'), isFalse);
        expect(_request(eval, occurrence: 'invalid occurrence'), isFalse);
        expect(_request(eval, kind: 'x' * 129), isFalse);
        expect(_request(eval, occurrence: 'x' * 257), isFalse);
        expect(f.requests, isEmpty);
        expect(_request(eval), isTrue);
        expect(f.requests.single.$1, same(f.session));
        expect(f.requests.single.$2.value, _kind);
        expect(f.requests.single.$3.value, _occurrence);
        f.expectNoEnvironmentWork();
        await tester.pumpWidget(const SizedBox.shrink());
        expect(tester.takeException(), isNull);
      },
    );

    for (final denied in [
      'default declaration',
      'callback',
      'canonical runtime',
    ]) {
      testWidgets('missing $denied denies a mounted pane', (tester) async {
        final f = await fixture(
          tester,
          canonicalRuntime: denied != 'canonical runtime',
          callback: denied != 'callback',
        );
        f.contribute(allowed: denied != 'default declaration');
        await tester.pumpWidget(f.widget());
        await tester.pumpAndSettle();
        expect(_request(f.pane('first').runtime), isFalse);
        expect(f.requests, isEmpty);
        f.expectNoEnvironmentWork();
        await tester.pumpWidget(const SizedBox.shrink());
      });
    }

    testWidgets(
      'Session execution does not grant semantic Inspection opening',
      (tester) async {
        final f = await fixture(tester);
        final strategy = f.extensions.register(
          point: orchestrationStrategyContributions,
          id: ExtensionId('test.execution-strategy'),
          value: OrchestrationStrategyContribution(
            strategyId: f.session.strategyId,
            materialize: (_) => throw StateError('No Run should start.'),
          ),
        );
        addTearDown(strategy.close);
        final controller = SessionExecutionController(
          runtime: f.runtime,
          session: f.session,
          providerId: ProviderId('test.unavailable'),
          model: null,
        );
        addTearDown(controller.close);
        var executionBindings = 0;
        f.contribute(
          sessionExecution: true,
          services: PreparedSessionServices(
            extensions: f.extensions,
            backends: f.runtime.plugins,
            controllerForSession: (session, _) {
              expect(session, same(f.session));
              executionBindings++;
              return controller;
            },
            inspectActivity: (_, _) => false,
            isCurrent: (session) => identical(session, f.session),
          ),
        );
        await tester.pumpWidget(f.widget());
        await tester.pumpAndSettle();
        expect(executionBindings, 2);
        expect(find.text('Inspect first'), findsOneWidget);
        expect(find.text('Inspect second'), findsOneWidget);
        expect(find.text('Frontend unavailable.'), findsNothing);
        expect(_read(f.pane('first').runtime, 'paneId'), 'first');
        expect(_request(f.pane('first').runtime), isFalse);
        await tester.tap(find.widgetWithText(TextButton, 'Inspect first'));
        expect(f.requests, isEmpty);
        f.expectNoEnvironmentWork();
        await tester.pumpWidget(const SizedBox.shrink());
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'initializers, input actions and finite operations receive no opening callback',
      (tester) async {
        final f = await fixture(tester);
        f.contribute(allowed: true);
        await tester.pumpWidget(f.widget());
        await tester.pumpAndSettle();
        final eval = f.pane('first').runtime;
        expect(find.text('Init denied'), findsOneWidget);
        expect(
          copyStructuredBridgeData(
            await eval.executeLib(_library, 'probeOperation'),
          ),
          {'accepted': false},
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('Probe input'));
        await tester.pumpAndSettle();
        expect(find.text('Action denied'), findsOneWidget);
        await tester.tap(find.text('Action denied'));
        await tester.pumpAndSettle();
        expect(_read(eval, 'actionResult'), {'accepted': false});
        expect(f.requests, isEmpty);
        await tester.pumpWidget(const SizedBox.shrink());
        expect(tester.takeException(), isNull);
      },
    );

    for (final foreign in [false, true]) {
      testWidgets(
        '${foreign ? 'foreign canonical' : 'equal noncanonical'} Session cannot acquire a pane callback',
        (tester) async {
          final f = await fixture(tester);
          f.contribute(allowed: true);
          final other = _session(f.session.id.value);
          if (foreign) {
            final runtime = AdeleRuntime();
            addTearDown(runtime.close);
            _publish(runtime, [other]);
            expect(runtime.store.session(other.id), same(other));
          }
          await tester.pumpWidget(f.widget(session: other));
          await tester.pumpAndSettle();
          expect(f.panes, isEmpty);
          expect(f.requests, isEmpty);
          await tester.pumpWidget(const SizedBox.shrink());
          expect(tester.takeException(), isNull);
        },
      );
    }

    testWidgets(
      'removing one exact pane synchronously fences its cached callback, not its sibling or replacement',
      (tester) async {
        final f = await fixture(tester);
        f.contribute(allowed: true);
        await tester.pumpWidget(f.widget());
        await tester.pumpAndSettle();
        final old = f.pane('first').runtime;
        final sibling = f.pane('second').runtime;
        final cached = tester
            .widget<TextButton>(
              find.widgetWithText(TextButton, 'Inspect first'),
            )
            .onPressed!;
        cached();
        expect(f.requests, hasLength(1));
        expect(_read(old, 'removeFirst'), isTrue);
        cached();
        expect(_request(old), isFalse);
        expect(f.requests, hasLength(1));
        expect(_request(sibling), isTrue);
        expect(_read(sibling, 'openFirst'), isTrue);
        await tester.pumpAndSettle();
        final replacement = f.pane('first').runtime;
        expect(replacement, isNot(same(old)));
        cached();
        expect(_request(old), isFalse);
        expect(f.requests, hasLength(2));
        expect(_request(replacement), isTrue);
        expect(f.requests, hasLength(3));
        await tester.pumpWidget(const SizedBox.shrink());
        expect(tester.takeException(), isNull);
      },
    );

    for (final departure in [
      'unmount',
      'Session departure',
      'registration retirement',
      'generation retirement',
      'host unbind',
      'host close',
    ]) {
      testWidgets('$departure fences cached interpreted callbacks', (
        tester,
      ) async {
        final f = await fixture(tester);
        final registration = f.contribute(allowed: true);
        await tester.pumpWidget(f.widget());
        await tester.pumpAndSettle();
        final old = f.pane('first').runtime;
        final cached = tester
            .widget<TextButton>(
              find.widgetWithText(TextButton, 'Inspect first'),
            )
            .onPressed!;
        cached();
        expect(f.requests, hasLength(1));
        switch (departure) {
          case 'unmount':
            await tester.pumpWidget(const SizedBox.shrink());
            await tester.pumpWidget(f.widget());
          case 'Session departure':
            await tester.pumpWidget(f.widget(session: f.other));
          case 'registration retirement':
            final retiring = registration.close();
            expect(_request(old), isFalse);
            await retiring;
            f.contribute(allowed: true);
          case 'generation retirement':
            f.generation.invalidate();
          case 'host unbind':
            f.host.unbind(f.session);
          case 'host close':
            await tester.runAsync(() {
              final closing = f.host.close();
              expect(_request(old), isFalse);
              return closing;
            });
        }
        cached();
        expect(_request(old), isFalse);
        expect(f.requests, hasLength(1));
        await tester.pumpAndSettle();
        if (departure == 'unmount' ||
            departure == 'Session departure' ||
            departure == 'registration retirement') {
          expect(_request(f.pane('first').runtime), isTrue);
          expect(
            f.requests.last.$1,
            same(departure == 'Session departure' ? f.other : f.session),
          );
          cached();
          expect(f.requests, hasLength(2));
        }
        await tester.pumpWidget(const SizedBox.shrink());
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets(
      'attachment departure is fenced before the next widget frame and never revives',
      (tester) async {
        final f = await fixture(tester);
        f.contribute(allowed: true);
        await tester.pumpWidget(f.widget());
        await tester.pumpAndSettle();
        final eval = f.pane('first').runtime;
        f.attachmentCurrent = false;
        expect(_request(eval), isFalse);
        f.attachmentCurrent = true;
        expect(_request(eval), isFalse);
        expect(f.requests, isEmpty);
        await tester.pumpWidget(const SizedBox.shrink());
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'rejected window navigation and exit preflight do not latch pane access inactive',
      (tester) async {
        final f = await fixture(tester);
        f.contribute(allowed: true);
        await tester.pumpWidget(f.widget());
        await tester.pumpAndSettle();
        final eval = f.pane('first').runtime;
        f.interactive = false;
        expect(_request(eval), isFalse);
        expect(_read(eval, 'paneId'), 'first');
        f.interactive = true;
        expect(_request(eval), isTrue);
        final preflight = f.host.prepareToExit();
        expect(_request(eval), isFalse);
        expect(_read(eval, 'paneId'), 'first');
        expect(await preflight, isFalse);
        expect(_request(eval), isTrue);
        expect(f.requests, hasLength(2));
        await f.host.stopOperations();
        expect(_request(eval), isFalse);
        expect(_read(eval, 'paneId'), 'first');
        expect(f.requests, hasLength(2));
        await tester.pumpWidget(const SizedBox.shrink());
        expect(tester.takeException(), isNull);
      },
    );
  });
}

Object? _read(Runtime runtime, String entrypoint) =>
    copyStructuredBridgeData(runtime.executeLib(_library, entrypoint));

bool _request(
  Runtime runtime, {
  String kind = _kind,
  String occurrence = _occurrence,
}) =>
    copyStructuredBridgeData(
          runtime.executeLib(_library, 'request', [
            $String(kind),
            $String(occurrence),
          ]),
        )
        as bool;

Session _session(String id) => Session(
  id: SessionId(id),
  taskId: TaskId('task'),
  strategyId: OrchestrationStrategyId('test.unavailable'),
);

void _publish(AdeleRuntime runtime, List<Session> sessions) {
  final project = Project(
    id: ProjectId('project'),
    sourceLocation: Uri.parse('file:///inspection-probe'),
  );
  final task = Task(id: TaskId('task'), projectId: project.id, title: 'Task');
  runtime.store.publishRestoredProject(
    project: project,
    tasks: [task],
    environments: [
      Environment(
        id: EnvironmentId('environment'),
        taskId: task.id,
        role: EnvironmentRole.primary,
        providerId: ProviderId('test.unavailable'),
        providerState: const {},
      ),
    ],
    sessions: sessions,
    authorities: [
      for (final session in sessions)
        (session.id, EnvironmentId('environment')),
    ],
    runRecords: [],
  );
}

final class _Fixture {
  _Fixture(
    this.generation,
    Directory directory, {
    required bool canonicalRuntime,
    required bool callback,
  }) {
    _publish(runtime, [session, other]);
    host = PreparedMainContentHost(
      environmentRuntime: canonicalRuntime
          ? runtime.lifecycle.environmentRuntime
          : null,
      inspectSessionContent: callback
          ? (session, kind, occurrence) {
              if (!interactive) return false;
              requests.add((session, kind, occurrence));
              return true;
            }
          : null,
      createBinding:
          ({
            required installation,
            required descriptor,
            required session,
            required paneId,
          }) {
            final pane = _Pane(paneId);
            panes.add(pane);
            return PreparedMainContentPaneBinding(
              createBridge: (_) =>
                  _RecordingBridge((runtime) => pane.runtime = runtime),
            );
          },
    );
    installation = PreparedPluginInstallation(
      metadata: PluginMetadata(
        id: PluginId('test.inspection-probe'),
        version: '1',
        displayName: 'Inspection probe',
      ),
      installationDirectory: directory,
      backendArtifactUri: null,
    );
  }

  final PreparedFrontend generation;
  final runtime = AdeleRuntime();
  final extensions = ExtensionRegistry();
  final session = _session('session');
  final other = _session('other');
  final panes = <_Pane>[];
  final requests =
      <(Session, SessionContentKind, SessionContentOccurrenceId)>[];
  final _registrations = <ExtensionRegistration>[];
  late final PreparedMainContentHost host;
  late final PreparedPluginInstallation installation;
  bool interactive = true;
  bool attachmentCurrent = true;

  _Pane pane(String id) => panes.lastWhere((pane) => pane.id == id);

  ExtensionRegistration contribute({
    bool allowed = false,
    bool sessionExecution = false,
    PreparedSessionServices? services,
  }) {
    final descriptor = PreparedMainContentPresentation(
      extensionId: _extensionId,
      order: 100,
      library: _library,
      initialize: 'initialize',
      entrypoint: 'buildPane',
      canInspectSessionContent: allowed,
      sessionExecution: sessionExecution,
      retainedData: true,
      operations: const {'probe': 'operation', 'exit': 'exit'},
      exitOperation: 'exit',
      actions: [
        PreparedMainContentAction(
          id: 'probe',
          label: 'Probe input',
          entrypoint: 'buildAction',
        ),
      ],
    );
    final registration = extensions.register(
      point: mainContentContributions,
      id: descriptor.extensionId,
      value: host.createContribution(
        extensions: extensions,
        installation: installation,
        generation: generation,
        descriptor: descriptor,
        isActive: () => true,
        services: services,
      ),
    );
    _registrations.add(registration);
    return registration;
  }

  Widget widget({Session? session}) => MaterialApp(
    home: Scaffold(
      body: MainContentHost(
        session: session ?? this.session,
        extensions: extensions,
        actionCoordinator: host.actionCoordinator,
        isCurrent: () => attachmentCurrent,
      ),
    ),
  );

  void expectNoEnvironmentWork() {
    expect(
      runtime.registry.providersFor(environmentProviderCapability),
      isEmpty,
    );
    expect(
      runtime.lifecycle.environmentRuntime.currentMaterialization(
        EnvironmentId('environment'),
      ),
      isNull,
    );
    expect(runtime.store.runsForSession(session.id), isEmpty);
    expect(runtime.store.runsForSession(other.id), isEmpty);
  }

  Future<void> close() async {
    for (final registration in _registrations.reversed) {
      await registration.close();
    }
    await host.close();
    generation.invalidate();
    await runtime.close();
  }
}

final class _Pane {
  _Pane(this.id);
  final String id;
  late Runtime runtime;
}

final class _RecordingBridge implements PreparedFrontendBridge {
  _RecordingBridge(this.record);
  final void Function(Runtime) record;
  @override
  String get identifier => 'test.inspection-recording';
  @override
  void configureForCompile(BridgeDeclarationRegistry registry) {}
  @override
  void configureForRuntime(Runtime runtime) => record(runtime);
  @override
  void invalidate() {}
}

const _source = r'''
import 'package:flutter/material.dart';
import 'package:adele_ui/main_content_bridge.dart';
import 'package:adele_ui/contribution_bridge.dart';

bool request(String kind, String occurrence) => inspectSessionContent(kind, occurrence);
String paneId() => readMainContentPaneId();
bool removeFirst() => removeMainContentPane('first');
bool openFirst() => openMainContentPane('first', 'Replacement', true);

void initialize() {
  final accepted = inspectSessionContent('test.content', 'initializer');
  if (readMainContentPanes().isEmpty) {
    openMainContentPane('first', accepted ? 'Init accepted' : 'Init denied', true);
    openMainContentPane('second', 'Sibling', true);
  }
}
Widget buildPane() => TextButton(
  onPressed: () { inspectSessionContent('test.content', 'cached'); },
  child: Text('Inspect ' + readMainContentPaneId()),
);
Future<Map<String, dynamic>> operation() async => <String, dynamic>{
  'accepted': inspectSessionContent('test.content', 'operation'),
};
Future<Map<String, dynamic>> probeOperation() async =>
    await invokeContributionOperation('probe', <String, dynamic>{});
Future<Map<String, dynamic>> exit() async => <String, dynamic>{'accepted': false};
Map<String, dynamic> actionResult() => readContributionData('action-result');
Widget buildAction() => TextButton(
  onPressed: () {
    final accepted = inspectSessionContent('test.content', 'action');
    writeContributionData('action-result', <String, dynamic>{'accepted': accepted});
  },
  child: Text(inspectSessionContent('test.content', 'action-build') ? 'Action accepted' : 'Action denied'),
);
''';
