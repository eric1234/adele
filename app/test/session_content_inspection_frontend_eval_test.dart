import 'dart:convert';
import 'dart:io';

import 'package:adele_capabilities/adele_capabilities.dart';
import 'package:adele_desktop/core/adele_runtime.dart';
import 'package:adele_desktop/core/application_plugin_bootstrap.dart';
import 'package:adele_desktop/core/prepared_settings.dart';
import 'package:adele_desktop/frontend/application_frontend_bootstrap.dart';
import 'package:adele_desktop/frontend/main_content_bridge.dart';
import 'package:adele_desktop/frontend/prepared_frontend.dart';
import 'package:adele_desktop/frontend/prepared_main_content_host.dart';
import 'package:adele_desktop/frontend/prepared_session_services.dart';
import 'package:adele_desktop/frontend/session_content_inspection_bridge.dart';
import 'package:adele_desktop/frontend/structured_bridge_data.dart';
import 'package:adele_desktop/ui/inspection/activity_inspection_selection.dart';
import 'package:adele_desktop/ui/inspection/inspection_host.dart';
import 'package:adele_desktop/ui/main_content/main_content_host.dart';
import 'package:adele_environment/adele_environment.dart';
import 'package:adele_orchestration/adele_orchestration.dart';
import 'package:adele_plugin_api/adele_plugin_api.dart';
import 'package:adele_product/adele_product.dart';
import 'package:adele_ui/adele_ui.dart';
import 'package:dart_eval/dart_eval.dart';
import 'package:dart_eval/dart_eval_bridge.dart';
import 'package:flutter/material.dart';
import 'package:flutter_eval/flutter_eval.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plugin_runtime/plugin_runtime.dart';

const _producerLibrary = 'package:content_producer/main.dart';
const _rendererLibrary = 'package:content_renderer/main.dart';
const _kind = 'test.semantic-note';
final _producerId = ExtensionId('test.content-producer');
final _rendererId = ExtensionId('test.content-renderer');

void main() {
  late Directory temporary;
  late File producerArtifact;
  late File rendererArtifact;
  var fixtureSequence = 0;

  setUpAll(() async {
    temporary = await Directory.systemTemp.createTemp(
      'session-content-inspection-',
    );
    // Separate compilers and source inventories: neither frontend links the
    // other's implementation, and neither receives a native widget substitute.
    final producer =
        (Compiler()
              ..addPlugin(flutterEvalPlugin)
              ..addPlugin(const MainContentDeclarations())
              ..entrypoints.add(_producerLibrary))
            .compile({
              'content_producer': {'main.dart': _producerSource},
              'adele_ui': {
                'main_content_bridge.dart': await File(
                  '../packages/ui/lib/main_content_bridge.dart',
                ).readAsString(),
              },
            });
    producerArtifact = await File(
      '${temporary.path}/producer.evc',
    ).writeAsBytes(producer.write());
    final renderer =
        (Compiler()
              ..addPlugin(flutterEvalPlugin)
              ..addPlugin(const SessionContentInspectionDeclarations())
              ..entrypoints.add(_rendererLibrary))
            .compile({
              'content_renderer': {'main.dart': _rendererSource},
              'adele_ui': {
                'session_content_inspection_bridge.dart': await File(
                  '../packages/ui/lib/session_content_inspection_bridge.dart',
                ).readAsString(),
              },
            });
    rendererArtifact = await File(
      '${temporary.path}/renderer.evc',
    ).writeAsBytes(renderer.write());
  });
  tearDownAll(() => temporary.delete(recursive: true));

  Future<_Fixture> fixture(
    WidgetTester tester, {
    bool allowed = true,
    bool includeRenderer = true,
  }) async {
    final f = _Fixture(
      directory: Directory('${temporary.path}/fixture-${fixtureSequence++}'),
      producerArtifact: producerArtifact,
      rendererArtifact: rendererArtifact,
    );
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(f.close);
    });
    await tester.binding.setSurfaceSize(const Size(1400, 1100));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.runAsync(
      () => f.start(allowed: allowed, includeRenderer: includeRenderer),
    );
    await tester.pumpWidget(f.widget());
    await tester.pumpAndSettle();
    expect(find.text('Initializer denied'), findsOneWidget);
    expect(find.text('Producer session'), findsOneWidget);
    expect(f.window.cards, isEmpty);
    expect(
      f.admissions,
      isEmpty,
      reason: 'Initialization has no opening grant.',
    );
    f.expectNoExecution();
    return f;
  }

  testWidgets(
    'independent compiled producer and renderer inspect two occurrences without a Run',
    (tester) async {
      final f = await fixture(tester);
      expect(f.frontends.generations, hasLength(2));
      expect(f.producer.installation, isNot(same(f.renderer.installation)));
      expect(
        f.producer.installation.frontend!.artifactUri,
        isNot(f.renderer.installation.frontend!.artifactUri),
      );
      final producerElement = tester.element(find.text('Producer session'));
      await tester.tap(find.text('Inspect first'));
      await tester.pumpAndSettle();
      expect(f.accepted(), isTrue);
      final first = f.window.cards.single;
      final firstTarget = first.target as SessionContentInspectionTarget;
      expect(firstTarget.sessionId, f.session.id);
      expect(firstTarget.kind, SessionContentKind(_kind));
      expect(
        firstTarget.occurrenceId,
        SessionContentOccurrenceId('occurrence-1'),
      );
      expect(first.content!.session, same(f.session));
      expect(first.content!.isActive, isTrue);
      expect(find.text('Renderer session/occurrence-1'), findsOneWidget);
      expect(find.text('Kind $_kind'), findsOneWidget);
      expect(
        find.text('Task task; strategy test.unavailable-strategy'),
        findsOneWidget,
      );
      expect(find.text('Facts only: 5'), findsOneWidget);
      expect(find.text('ACTIVITY'), findsNothing);
      expect(
        tester.widget<InspectionHost>(find.byType(InspectionHost)).activity,
        isNull,
      );

      await tester.tap(find.text('Local occurrence-1'));
      await tester.pumpAndSettle();
      final firstElement = tester.element(
        find.text('Local count occurrence-1: 1'),
      );
      await tester.tap(find.text('Inspect second'));
      await tester.pumpAndSettle();
      final second = f.window.cards.first;
      expect(f.window.cards.last, same(first));
      expect(second.id, isNot(same(first.id)));
      expect(second.content, isNot(same(first.content)));
      expect(find.text('Renderer session/occurrence-2'), findsOneWidget);
      expect(find.text('Local count occurrence-2: 0'), findsOneWidget);
      expect(find.text('Local count occurrence-1: 1'), findsOneWidget);
      expect(
        f.admissions.map((request) => request.$1),
        everyElement(same(f.session)),
      );
      expect(f.admissions.map((request) => request.$3.value), [
        'occurrence-1',
        'occurrence-2',
      ]);

      await _control(tester, first, 'Collapse Inspection');
      expect(f.window.cards.last.isCollapsed, isTrue);
      expect(first.content!.isActive, isTrue);
      expect(find.text('Renderer session/occurrence-1'), findsNothing);
      expect(find.text('Renderer session/occurrence-2'), findsOneWidget);
      await _control(tester, first, 'Expand Inspection');
      expect(
        tester.element(find.text('Local count occurrence-1: 1')),
        same(firstElement),
      );
      expect(f.window.cards.last.content, same(first.content));

      await _control(tester, first, 'Dismiss Inspection');
      expect(first.content!.isActive, isFalse);
      expect(f.window.cards.single.id, same(second.id));
      await tester.tap(find.text('Inspect first'));
      await tester.pumpAndSettle();
      final reopened = f.window.cards.first;
      expect(reopened.id, isNot(same(first.id)));
      expect(reopened.content, isNot(same(first.content)));
      expect(reopened.content!.isActive, isTrue);
      expect(find.text('Local count occurrence-1: 0'), findsOneWidget);
      expect(find.text('Renderer session/occurrence-2'), findsOneWidget);
      expect(
        tester.element(find.text('Producer session')),
        same(producerElement),
      );
      expect(
        f.window.cards.every(
          (card) => card.target is SessionContentInspectionTarget,
        ),
        isTrue,
      );
      f.expectNoExecution();
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'compiled content and existing activity keep independent card lifetimes',
    (tester) async {
      final f = await fixture(tester);
      await tester.tap(find.text('Inspect first'));
      await tester.pumpAndSettle();
      final content = f.window.cards.single;
      f.openActivity();
      await tester.pumpAndSettle();
      final activity = f.window.cards.first;
      expect(activity.target, isA<ActivityGroupInspectionTarget>());
      expect(activity.content, isNull);
      expect(find.text('ACTIVITY'), findsOneWidget);
      expect(find.text('Existing activity'), findsOneWidget);
      expect(find.text('Renderer session/occurrence-1'), findsOneWidget);
      await _control(tester, activity, 'Collapse Inspection');
      expect(content.content!.isActive, isTrue);
      await tester.runAsync(f.renderer.close);
      await tester.pumpAndSettle();
      expect(content.content!.isActive, isFalse);
      expect(find.text('Content Inspection is unavailable.'), findsOneWidget);
      expect(find.text('Existing activity'), findsOneWidget);
      expect(find.text('Producer session'), findsOneWidget);
      await _control(tester, content, 'Dismiss Inspection');
      await _control(tester, activity, 'Expand Inspection');
      expect(f.window.cards.single.id, same(activity.id));
      expect(f.activity!.models.single.settlement, ModelSettlement.completed);
      expect(f.activity!.state, RunState.completed);
      f.expectNoExecution();
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'missing and ambiguous presenters reject opens without choosing a fallback',
    (tester) async {
      final f = await fixture(tester, includeRenderer: false);
      await tester.tap(find.text('Inspect first'));
      await tester.pumpAndSettle();
      expect(f.accepted(), isFalse);
      expect(f.window.cards, isEmpty);
      final renderer = (await tester.runAsync(f.addRenderer))!;
      await tester.tap(find.text('Inspect first'));
      await tester.pumpAndSettle();
      expect(f.accepted(), isTrue);
      final original = f.window.cards.single;
      await tester.runAsync(
        () => f.addRenderer(id: ExtensionId('test.other-content-renderer')),
      );
      await tester.tap(find.text('Inspect second'));
      await tester.pumpAndSettle();
      expect(f.accepted(), isFalse);
      expect(f.window.cards.single, same(original));
      expect(find.text('Renderer session/occurrence-1'), findsOneWidget);
      expect(find.text('Renderer session/occurrence-2'), findsNothing);
      await tester.runAsync(renderer.close);
      await tester.tap(find.text('Inspect second'));
      await tester.pumpAndSettle();
      expect(f.accepted(), isTrue);
      expect(original.content!.isActive, isFalse);
      expect(find.text('Renderer session/occurrence-2'), findsOneWidget);
      expect(find.text('Content Inspection is unavailable.'), findsOneWidget);
      f.expectNoExecution();
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'retired exact presenter never migrates to a same-ID prepared replacement',
    (tester) async {
      final f = await fixture(tester);
      await tester.tap(find.text('Inspect first'));
      await tester.pumpAndSettle();
      final old = f.window.cards.single;
      final binding = old.content!.presenter;
      final closing = f.renderer.registrations.single.close();
      expect(old.content!.isActive, isFalse);
      expect(binding.validate, throwsA(isA<StaleExtensionBinding>()));
      await closing;
      await tester.runAsync(f.addRenderer);
      await tester.pumpAndSettle();
      expect(f.window.cards.single, same(old));
      expect(find.text('Renderer session/occurrence-1'), findsNothing);
      expect(find.text('Content Inspection is unavailable.'), findsOneWidget);
      await tester.tap(find.text('Inspect first'));
      await tester.pumpAndSettle();
      final fresh = f.window.cards.first;
      expect(fresh.content!.presenter.id, binding.id);
      expect(fresh.content!.presenter.isSameRegistration(binding), isFalse);
      expect(fresh.id, isNot(same(old.id)));
      expect(find.text('Renderer session/occurrence-1'), findsOneWidget);
      expect(find.text('Content Inspection is unavailable.'), findsOneWidget);
      expect(f.renderer.state, InstalledFrontendState.active);
      f.expectNoExecution();
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'canonical Session navigation clears cards and permanently denies old EVC callbacks',
    (tester) async {
      final f = await fixture(tester);
      final oldRuntime = f.paneRuntime;
      final oldAction = tester
          .widget<TextButton>(find.widgetWithText(TextButton, 'Inspect first'))
          .onPressed!;
      await tester.tap(find.text('Inspect first'));
      await tester.pumpAndSettle();
      final old = f.window.cards.single;
      await tester.pumpWidget(f.widget(session: f.other));
      await tester.pumpAndSettle();
      expect(f.window.cards, isEmpty);
      expect(old.content!.isActive, isFalse);
      oldAction();
      expect(f.accepted(oldRuntime), isFalse);
      expect(f.admissions, hasLength(1));
      await tester.tap(find.text('Inspect first'));
      await tester.pumpAndSettle();
      expect(find.text('Renderer other/occurrence-1'), findsOneWidget);
      expect(f.window.cards.single.content!.session, same(f.other));
      await tester.pumpWidget(f.widget(session: f.session));
      await tester.pumpAndSettle();
      oldAction();
      expect(f.accepted(oldRuntime), isFalse);
      expect(f.window.cards, isEmpty);
      await tester.tap(find.text('Inspect second'));
      await tester.pumpAndSettle();
      expect(find.text('Renderer session/occurrence-2'), findsOneWidget);
      f.expectNoExecution();
      expect(tester.takeException(), isNull);
    },
  );

  for (final retireFrontend in [false, true]) {
    testWidgets(
      '${retireFrontend ? 'frontend retirement' : 'origin disposal'} denies cached opens without retiring admitted content',
      (tester) async {
        final f = await fixture(tester);
        final oldRuntime = f.paneRuntime;
        final oldAction = tester
            .widget<TextButton>(
              find.widgetWithText(TextButton, 'Inspect first'),
            )
            .onPressed!;
        await tester.tap(find.text('Inspect first'));
        await tester.pumpAndSettle();
        final content = f.window.cards.single;
        if (retireFrontend) {
          await tester.runAsync(f.producer.close);
        } else {
          await tester.pumpWidget(f.widget(showProducer: false));
        }
        await tester.pumpAndSettle();
        oldAction();
        expect(f.accepted(oldRuntime), isFalse);
        expect(f.admissions, hasLength(1));
        expect(f.window.cards.single, same(content));
        expect(content.content!.isActive, isTrue);
        expect(find.text('Renderer session/occurrence-1'), findsOneWidget);
        if (!retireFrontend) {
          await tester.pumpWidget(f.widget());
          await tester.pumpAndSettle();
          oldAction();
          expect(f.accepted(oldRuntime), isFalse);
          await tester.tap(find.text('Inspect second'));
          await tester.pumpAndSettle();
          expect(find.text('Renderer session/occurrence-2'), findsOneWidget);
        }
        f.expectNoExecution();
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'an undeclared compiled pane cannot borrow the installed renderer',
    (tester) async {
      final f = await fixture(tester, allowed: false);
      expect(
        f.extensions.discover(sessionContentInspectionContributions),
        hasLength(1),
      );
      await tester.tap(find.text('Inspect first'));
      await tester.pumpAndSettle();
      expect(f.accepted(), isFalse);
      expect(f.admissions, isEmpty);
      expect(f.window.cards, isEmpty);
      expect(find.textContaining('Renderer '), findsNothing);
      f.expectNoExecution();
      expect(tester.takeException(), isNull);
    },
  );
}

Future<void> _control(
  WidgetTester tester,
  InspectionCard card,
  String tooltip,
) async {
  final control = find.descendant(
    of: find.byKey(ValueKey(card.id)).first,
    matching: find.byTooltip(tooltip),
  );
  await tester.ensureVisible(control);
  await tester.tap(control);
  await tester.pumpAndSettle();
}

final class _Fixture {
  _Fixture({
    required this.directory,
    required this.producerArtifact,
    required this.rendererArtifact,
  }) {
    final project = Project(
      id: ProjectId('project'),
      sourceLocation: Uri.parse('file:///session-content-inspection'),
    );
    final task = Task(id: session.taskId, projectId: project.id, title: 'Task');
    runtime.store.publishRestoredProject(
      project: project,
      tasks: [task],
      environments: [
        for (final role in EnvironmentRole.values)
          Environment(
            id: EnvironmentId(role.name),
            taskId: task.id,
            role: role,
            providerId: ProviderId('test.unavailable-environment'),
            providerState: const {},
          ),
      ],
      sessions: [session, other],
      authorities: [
        (session.id, EnvironmentId('additional')),
        (other.id, EnvironmentId('primary')),
      ],
      runRecords: [],
    );
    presented = session;
    window.presentSession(session);
    backends = ApplicationPluginBootstrap(runtime.registry, extensions);
    host = PreparedMainContentHost(
      environmentRuntime: runtime.lifecycle.environmentRuntime,
      inspectSessionContent: (captured, kind, occurrenceId) {
        admissions.add((captured, kind, occurrenceId));
        return window.inspectContent(
          session: captured,
          kind: kind,
          occurrenceId: occurrenceId,
          extensions: extensions,
        );
      },
      createBinding:
          ({
            required installation,
            required descriptor,
            required session,
            required paneId,
          }) => PreparedMainContentPaneBinding(
            createBridge: (_) =>
                _RecordingBridge((value) => paneRuntime = value),
          ),
    );
    frontends = ApplicationFrontendBootstrap(
      extensions: extensions,
      backends: backends,
      mainContentHost: host,
      sessionServices: PreparedSessionServices(
        extensions: extensions,
        backends: backends,
        controllerForSession: (_, _) {
          executionAcquisitions++;
          throw StateError('Content Inspection must not acquire execution.');
        },
        inspectActivity: (_, _) =>
            throw StateError('No activity-opening grant.'),
        isCurrent: (value) => identical(value, presented),
      ),
      loadSettings: (catalog) async =>
          PreparedSettingsSnapshot.resolve(catalog),
    );
  }

  final Directory directory;
  final File producerArtifact;
  final File rendererArtifact;
  final runtime = AdeleRuntime();
  ExtensionRegistry get extensions => runtime.extensions;
  final session = _session('session');
  final other = _session('other');
  final window = WindowInspection();
  final admissions =
      <(Session, SessionContentKind, SessionContentOccurrenceId)>[];
  final _additionalFrontends = <ApplicationFrontendBootstrap>[];
  late final ApplicationPluginBootstrap backends;
  late final PreparedMainContentHost host;
  late final ApplicationFrontendBootstrap frontends;
  late Session presented;
  late Runtime paneRuntime;
  var executionAcquisitions = 0;
  RunActivitySnapshot? activity;

  InstalledFrontendActivation get producer => frontends.generations.singleWhere(
    (generation) =>
        generation.installation.metadata.id.value == 'test.producer',
  );
  InstalledFrontendActivation get renderer => frontends.generations.singleWhere(
    (generation) =>
        generation.installation.metadata.id.value == 'test.renderer',
  );

  Future<void> start({
    required bool allowed,
    required bool includeRenderer,
  }) async {
    final root = Directory('${directory.path}/installed');
    await _install(
      root,
      'producer',
      producerArtifact,
      PreparedMainContentPresentation(
        extensionId: _producerId,
        order: 100,
        library: _producerLibrary,
        initialize: 'initialize',
        entrypoint: 'buildProducer',
        canInspectSessionContent: allowed,
      ).toJson(),
    );
    if (includeRenderer) {
      await _install(
        root,
        'renderer',
        rendererArtifact,
        _rendererDescriptor(_rendererId),
      );
    }
    final catalog = await PreparedPluginCatalog.discover(root.path);
    expect(catalog.issues, isEmpty);
    await frontends.start(catalog);
    expect(
      frontends.generations.map((generation) => generation.state),
      everyElement(InstalledFrontendState.active),
    );
  }

  Future<InstalledFrontendActivation> addRenderer({ExtensionId? id}) async {
    final root = Directory(
      '${directory.path}/extra-${_additionalFrontends.length}',
    );
    await _install(
      root,
      'renderer',
      rendererArtifact,
      _rendererDescriptor(id ?? _rendererId),
    );
    final catalog = await PreparedPluginCatalog.discover(root.path);
    expect(catalog.issues, isEmpty);
    final owner = ApplicationFrontendBootstrap(
      extensions: extensions,
      backends: backends,
      loadSettings: (catalog) async =>
          PreparedSettingsSnapshot.resolve(catalog),
    );
    _additionalFrontends.add(owner);
    await owner.start(catalog);
    expect(owner.generations.single.state, InstalledFrontendState.active);
    return owner.generations.single;
  }

  bool accepted([Runtime? captured]) =>
      copyStructuredBridgeData(
            (captured ?? paneRuntime).executeLib(
              _producerLibrary,
              'lastResult',
            ),
          )
          as bool;

  Widget widget({Session? session, bool showProducer = true}) {
    presented = session ?? this.session;
    window.presentSession(presented);
    return MaterialApp(
      home: Scaffold(
        body: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: showProducer
                  ? MainContentHost(
                      session: presented,
                      extensions: extensions,
                      actionCoordinator: host.actionCoordinator,
                    )
                  : const SizedBox.shrink(),
            ),
            Expanded(
              child: SingleChildScrollView(
                child: ListenableBuilder(
                  listenable: window,
                  builder: (_, _) => InspectionStackHost(
                    cards: window.cards,
                    cardBuilder: (_, card) => InspectionHost(
                      card: card,
                      activity: card.target is ActivityInspectionTarget
                          ? activity
                          : null,
                      heading: 'Existing activity',
                      extensions: extensions,
                      onCollapse: () => window.collapse(card.id),
                      onExpand: () => window.expand(card.id),
                      onDismiss: () => window.dismiss(card.id),
                      onInspectOutput: (_) =>
                          fail('The activity fixture has no outputs.'),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  void openActivity() {
    // Native execution evidence is used only in the mixed-card regression,
    // never to manufacture a Run for the semantic-content opening path.
    final model = ModelInvocationId('existing-model');
    activity = RunActivitySnapshot(
      runId: RunId('existing-run'),
      sessionId: session.id,
      state: RunState.completed,
      sequence: 2,
      models: [
        ModelInvocationActivity(
          id: model,
          startSequence: 1,
          terminalSequence: 2,
          settlement: ModelSettlement.completed,
          outputs: const [],
        ),
      ],
      tools: const [],
    );
    expect(
      window.inspectActivity(
        session: session,
        activity: activity!,
        modelInvocationId: model,
      ),
      isTrue,
    );
  }

  void expectNoExecution() {
    expect(executionAcquisitions, 0);
    expect(backends.backends, isEmpty);
    expect(backends.host, isNull);
    expect(extensions.discover(orchestrationStrategyContributions), isEmpty);
    expect(
      runtime.registry.providersFor(environmentProviderCapability),
      isEmpty,
    );
    for (final session in [this.session, other]) {
      expect(runtime.store.session(session.id), same(session));
      expect(runtime.store.runsForSession(session.id), isEmpty);
    }
    for (final role in EnvironmentRole.values) {
      expect(
        runtime.lifecycle.environmentRuntime.currentMaterialization(
          EnvironmentId(role.name),
        ),
        isNull,
      );
    }
  }

  Future<void> close() async {
    window.dispose();
    for (final owner in _additionalFrontends.reversed) {
      await owner.close();
    }
    await frontends.close();
    await backends.close();
    await runtime.close();
  }
}

Session _session(String id) => Session(
  id: SessionId(id),
  taskId: TaskId('task'),
  strategyId: OrchestrationStrategyId('test.unavailable-strategy'),
);

Map<String, Object?> _rendererDescriptor(ExtensionId id) =>
    PreparedSessionContentInspection(
      extensionId: id,
      contentKind: _kind,
      library: _rendererLibrary,
      entrypoint: 'buildInspection',
    ).toJson();

Future<void> _install(
  Directory root,
  String name,
  File artifact,
  Map<String, Object?> descriptor,
) async {
  final installation = await Directory(
    '${root.path}/$name',
  ).create(recursive: true);
  await artifact.copy('${installation.path}/frontend.evc');
  await File(
    '${installation.path}/adele_plugin.installation.json',
  ).writeAsString(
    jsonEncode({
      'manifestVersion': 1,
      'metadata': {'id': 'test.$name', 'version': '1', 'displayName': name},
      'components': {
        'frontend': {
          'artifact': 'frontend.evc',
          'presentations': [descriptor],
        },
      },
    }),
  );
}

final class _RecordingBridge implements PreparedFrontendBridge {
  _RecordingBridge(this.record);
  final void Function(Runtime) record;
  @override
  String get identifier => 'test.content-runtime-recording';
  @override
  void configureForCompile(BridgeDeclarationRegistry registry) {}
  @override
  void configureForRuntime(Runtime runtime) => record(runtime);
  @override
  void invalidate() {}
}

const _producerSource = r'''
import 'package:flutter/material.dart';
import 'package:adele_ui/main_content_bridge.dart';

bool accepted = false;
bool lastResult() => accepted;
void initialize() {
  final opened = inspectSessionContent('test.semantic-note', 'initializer');
  openMainContentPane('producer', opened ? 'Initializer opened' : 'Initializer denied', false);
}
Widget buildProducer() => Column(children: [
  Text('Producer ' + readMainContentContext()['sessionId']),
  TextButton(
    onPressed: () {
      accepted = inspectSessionContent('test.semantic-note', 'occurrence-1');
    },
    child: const Text('Inspect first'),
  ),
  TextButton(
    onPressed: () {
      accepted = inspectSessionContent('test.semantic-note', 'occurrence-2');
    },
    child: const Text('Inspect second'),
  ),
]);
''';

const _rendererSource = r'''
import 'package:flutter/material.dart';
import 'package:adele_ui/session_content_inspection_bridge.dart';

Widget buildInspection() => ContentInspection();
class ContentInspection extends StatefulWidget {
  @override
  State<ContentInspection> createState() => ContentInspectionState();
}
class ContentInspectionState extends State<ContentInspection> {
  int count = 0;
  @override
  Widget build(BuildContext context) {
    final facts = readSessionContentInspectionContext();
    final occurrence = facts['occurrenceId'] as String;
    return Column(children: [
      Text('Renderer ' + facts['sessionId'] + '/' + occurrence),
      Text('Kind ' + facts['contentKind']),
      Text('Task ' + facts['taskId'] + '; strategy ' + facts['strategyId']),
      Text('Facts only: ' + facts.length.toString()),
      Text('Local count ' + occurrence + ': ' + count.toString()),
      TextButton(
        onPressed: () { setState(() { count++; }); },
        child: Text('Local ' + occurrence),
      ),
    ]);
  }
}
''';
