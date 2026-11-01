import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' show AppExitResponse;

import 'package:adele_capabilities/adele_capabilities.dart';
import 'package:adele_core_extensions/adele_core_extensions.dart';
import 'package:adele_desktop/application.dart';
import 'package:adele_desktop/core/application_plugin_bootstrap.dart';
import 'package:adele_desktop/core/project_database.dart';
import 'package:adele_desktop/frontend/contribution_bridge.dart';
import 'package:adele_desktop/frontend/main_content_bridge.dart';
import 'package:adele_desktop/frontend/prepared_frontend.dart';
import 'package:adele_desktop/frontend/prepared_main_content_host.dart';
import 'package:adele_desktop/frontend/session_content_inspection_bridge.dart';
import 'package:adele_desktop/frontend/session_presentation_lifecycle_bridge.dart';
import 'package:adele_desktop/frontend/task_browser_bridge.dart';
import 'package:adele_desktop/terminal/native_adele_runtime.dart';
import 'package:adele_desktop/ui/inspection/activity_inspection_selection.dart';
import 'package:adele_desktop/ui/inspection/inspection_host.dart';
import 'package:adele_desktop/ui/main_content/main_content_host.dart';
import 'package:adele_desktop/ui/shell/adele_shell.dart';
import 'package:adele_environment/adele_environment.dart';
import 'package:adele_orchestration/adele_orchestration.dart';
import 'package:adele_platform_storage/adele_platform_storage.dart';
import 'package:adele_plugin_api/adele_plugin_api.dart';
import 'package:adele_product/adele_product.dart';
import 'package:adele_ui/adele_ui.dart';
import 'package:dart_eval/dart_eval.dart';
import 'package:dart_eval/dart_eval_bridge.dart';
import 'package:flutter/material.dart';
import 'package:flutter_eval/flutter_eval.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plugin_runtime/plugin_runtime.dart';

import 'support/project_provider.dart';

const _producerLibrary = 'package:application_content_producer/main.dart';
const _rendererLibrary = 'package:application_content_renderer/main.dart';
const _kind = 'test.application-content';
const _nativeKind = 'test.application-native-content';

void main() {
  late List<int> producer;
  late List<int> renderer;

  setUpAll(() async {
    producer =
        (Compiler()
              ..addPlugin(flutterEvalPlugin)
              ..addPlugin(const MainContentDeclarations())
              ..addPlugin(const ContributionDeclarations())
              ..addPlugin(const SessionPresentationLifecycleDeclarations())
              ..addPlugin(const TaskBrowserDeclarations())
              ..entrypoints.add(_producerLibrary))
            .compile({
              'application_content_producer': {'main.dart': _producerSource},
              'adele_ui': {
                for (final library in [
                  'main_content_bridge',
                  'contribution_bridge',
                  'session_presentation_lifecycle_bridge',
                  'task_browser_bridge',
                ])
                  '$library.dart': await File(
                    '../packages/ui/lib/$library.dart',
                  ).readAsString(),
              },
            })
            .write();
    renderer =
        (Compiler()
              ..addPlugin(flutterEvalPlugin)
              ..addPlugin(const SessionContentInspectionDeclarations())
              ..entrypoints.add(_rendererLibrary))
            .compile({
              'application_content_renderer': {'main.dart': _rendererSource},
              'adele_ui': {
                'session_content_inspection_bridge.dart': await File(
                  '../packages/ui/lib/session_content_inspection_bridge.dart',
                ).readAsString(),
              },
            })
            .write();
  });

  Future<_Fixture> mount(
    WidgetTester tester, {
    PreparedMainContentHost? mainContentHost,
    Duration exitTimeout = const Duration(seconds: 5),
  }) async {
    await tester.binding.setSurfaceSize(const Size(1400, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final fixture = await _Fixture.create(producer, renderer);
    await fixture.mount(
      tester,
      mainContentHost: mainContentHost,
      exitTimeout: exitTimeout,
    );
    return fixture;
  }

  testWidgets(
    'application content Inspection rejects pending navigation, survives cancellation and clears on departure',
    (tester) => tester.runAsync(() async {
      final f = await mount(tester);
      try {
        final producerElement = tester.element(find.text('Producer session'));
        final cachedOpen = tester
            .widget<TextButton>(
              find.widgetWithText(TextButton, 'Inspect content'),
            )
            .onPressed!;
        await tester.tap(find.text('Inspect content'));
        await tester.pumpAndSettle();
        final first = _cards(tester).single;
        expect(first.target, isA<SessionContentInspectionTarget>());
        expect(first.content!.session, same(f.session));
        expect(first.content!.kind, SessionContentKind(_kind));
        expect(
          first.content!.occurrenceId,
          SessionContentOccurrenceId('note-1'),
        );
        expect(first.content!.isActive, isTrue);
        expect(find.text('Renderer session/note-1'), findsOneWidget);
        expect(
          tester.widget<InspectionHost>(find.byType(InspectionHost)).activity,
          isNull,
        );

        // Invoke the captured EVC callback before IgnorePointer or the pane host
        // can reconcile. Only the application's live admission gate can deny it.
        tester.widget<AdeleShell>(find.byType(AdeleShell)).onTask!();
        cachedOpen();
        expect(first.content!.isActive, isTrue);
        // Navigation deliberately animates a progress indicator until settlement.
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        expect(find.text('Leave content?'), findsOneWidget);
        expect(_cards(tester), [same(first)]);
        expect(f.window.snapshot.session, same(f.session));
        expect(
          tester.element(find.text('Producer session')),
          same(producerElement),
        );

        await tester.tap(find.text('Stay here'));
        await tester.pumpAndSettle();
        expect(
          tester.widget<AdeleShell>(find.byType(AdeleShell)).navigating,
          isFalse,
        );
        expect(first.content!.isActive, isTrue);
        expect(
          tester.element(find.text('Producer session')),
          same(producerElement),
        );
        cachedOpen();
        await tester.pumpAndSettle();
        final second = _cards(tester).first;
        expect(_cards(tester), [same(second), same(first)]);
        expect(second.id, isNot(same(first.id)));
        expect(second.content!.session, same(f.session));
        expect(find.text('Renderer session/note-1'), findsNWidgets(2));

        tester.widget<AdeleShell>(find.byType(AdeleShell)).onTask!();
        cachedOpen();
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        expect(_cards(tester), [same(second), same(first)]);
        await tester.tap(find.text('Leave now'));
        await tester.pumpAndSettle();
        expect(f.window.snapshot.session, isNull);
        expect(first.content!.isActive, isFalse);
        expect(second.content!.isActive, isFalse);
        expect(find.byType(InspectionStackHost), findsNothing);
        expect(find.byType(MainContentHost), findsNothing);
        cachedOpen();
        await tester.pumpAndSettle();
        expect(find.byType(InspectionStackHost), findsNothing);

        await tester.tap(find.text('Open canonical Session'));
        await tester.pumpAndSettle();
        expect(f.window.snapshot.session, same(f.session));
        cachedOpen();
        await tester.pumpAndSettle();
        expect(find.byType(InspectionStackHost), findsNothing);
        await tester.tap(find.text('Inspect content'));
        await tester.pumpAndSettle();
        expect(_cards(tester).single.id, isNot(same(first.id)));
        expect(_cards(tester).single.content!.isActive, isTrue);
        expect(find.text('Renderer session/note-1'), findsOneWidget);
        f.expectNoExecution();
        expect(tester.takeException(), isNull);
      } finally {
        await f.close(tester);
      }
    }),
  );

  testWidgets(
    'accepted application exit immediately revokes native content contexts while retained cards and cleanup drain',
    (tester) => tester.runAsync(() async {
      final f = await mount(tester);
      try {
        final contexts = <SessionContentInspectionContext>[];
        var revocations = 0;
        f.registrations.add(
          f.runtime.extensions.register(
            point: sessionContentInspectionContributions,
            id: ExtensionId('test.application-native-renderer'),
            value: SessionContentInspectionContribution(
              kind: SessionContentKind(_nativeKind),
              createPresentation: (context) {
                contexts.add(context);
                context.addListener(() {
                  expect(context.isActive, isFalse);
                  revocations++;
                });
                return const Text('Native content display');
              },
            ),
          ),
        );
        await tester.pumpAndSettle();
        final cachedOpen = tester
            .widget<TextButton>(
              find.widgetWithText(TextButton, 'Inspect native'),
            )
            .onPressed!;
        await tester.tap(find.text('Inspect native'));
        await tester.pumpAndSettle();
        final first = contexts.single;
        expect(first.session, same(f.session));
        expect(first.isActive, isTrue);

        final canceled = tester.binding.handleRequestAppExit();
        await tester.pumpAndSettle();
        expect(find.text('Leave content?'), findsOneWidget);
        cachedOpen();
        await tester.pump();
        expect(contexts, [same(first)]);
        expect(first.isActive, isTrue);
        expect(revocations, 0);
        expect(f.closeEntered.isCompleted, isFalse);
        await tester.tap(find.text('Stay here'));
        expect(await canceled, AppExitResponse.cancel);
        await tester.pumpAndSettle();
        cachedOpen();
        await tester.pumpAndSettle();
        expect(contexts, hasLength(2));
        expect(contexts.every((context) => context.isActive), isTrue);
        expect(f.window.snapshot.session, same(f.session));
        final cards = _cards(tester);
        final retainedHost = tester.element(find.byType(InspectionStackHost));
        final binding = SessionContentInspectionResolver(
          f.runtime.extensions,
        ).resolve(SessionContentKind(_nativeKind));
        List<bool>? activeAtCleanup;
        f.onCleanup = () {
          activeAtCleanup = [for (final context in contexts) context.isActive];
        };

        var exited = false;
        final exiting = tester.binding.handleRequestAppExit().then((response) {
          exited = true;
          return response;
        });
        await tester.pumpAndSettle();
        expect(contexts.every((context) => context.isActive), isTrue);
        await tester.tap(find.text('Leave now'));
        await f.closeEntered.future;
        expect(activeAtCleanup, [false, false]);
        expect(contexts.every((context) => !context.isActive), isTrue);
        expect(revocations, 2);
        expect(f.window.isActive, isFalse);
        expect(exited, isFalse);
        expect(f.runtime.plugins.state, ApplicationPluginState.ready);
        expect(binding.validate, returnsNormally);
        expect(retainedHost.mounted, isTrue);
        expect(_cards(tester), cards);
        cachedOpen();
        await tester.pumpAndSettle();
        expect(contexts, hasLength(2));
        expect(_cards(tester), cards);
        expect(
          tester.element(find.byType(InspectionStackHost)),
          same(retainedHost),
        );
        expect(find.text('Producer session'), findsOneWidget);
        f.expectNoExecution();

        f.cleanup.complete();
        expect(await exiting, AppExitResponse.exit);
        expect(f.runtime.plugins.state, ApplicationPluginState.closed);
        expect(revocations, 2);
        expect(tester.takeException(), isNull);
      } finally {
        await f.close(tester);
      }
    }),
  );

  testWidgets(
    'accepted application exit retains the ordinary Task Browser snapshot before closing authority',
    (tester) => tester.runAsync(() async {
      final f = await mount(tester);
      try {
        tester.widget<AdeleShell>(find.byType(AdeleShell)).onTask!();
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        await tester.tap(find.text('Leave now'));
        await tester.pumpAndSettle();
        expect(f.window.snapshot.session, isNull);
        final browser = tester.element(find.text('Open canonical Session'));

        final exiting = tester.binding.handleRequestAppExit();
        await tester.pumpAndSettle();
        await tester.tap(find.text('Leave now'));
        await f.closeEntered.future.timeout(const Duration(seconds: 2));
        expect(f.window.isActive, isFalse);
        expect(f.cleanup.isCompleted, isFalse);
        await tester.pumpAndSettle();
        expect(
          tester.element(find.text('Open canonical Session')),
          same(browser),
        );
        expect(tester.takeException(), isNull);

        f.cleanup.complete();
        expect(await exiting, AppExitResponse.exit);
        expect(f.runtime.plugins.state, ApplicationPluginState.closed);
        expect(tester.takeException(), isNull);
      } finally {
        await f.close(tester);
      }
    }),
  );

  testWidgets(
    'accepted application exit bounds throwing retention and independently retires resources',
    (tester) => tester.runAsync(() async {
      final failure = StateError('fixture presentation retention failed');
      final released = Completer<void>();
      late _Fixture f;
      Future<AppExitResponse>? repeated;
      final bridge = _RetentionBridge(() {
        // Snapshot readers remain live, but a reentrant exit already joins the
        // accepted deadline instead of reentering reversible preflight.
        expect(f.window.snapshot.session, same(f.session));
        repeated = tester.binding.handleRequestAppExit();
        throw failure;
      });
      final host = PreparedMainContentHost(
        confirm: (_) async => true,
        createBinding:
            ({
              required installation,
              required descriptor,
              required session,
              required paneId,
            }) => PreparedMainContentPaneBinding(
              createBridge: (_) => bridge,
              release: released.complete,
            ),
      );
      const deadline = Duration(milliseconds: 100);
      f = await mount(tester, mainContentHost: host, exitTimeout: deadline);
      try {
        final exiting = tester.binding.handleRequestAppExit();
        await f.closeEntered.future.timeout(const Duration(seconds: 2));
        expect(f.window.isActive, isFalse);
        expect(f.cleanup.isCompleted, isFalse);
        expect(bridge.retentions, 1);
        expect(repeated, isNotNull);

        expect(
          await exiting.timeout(const Duration(seconds: 2)),
          AppExitResponse.exit,
        );
        expect(await repeated!, AppExitResponse.exit);
        expect(f.cleanup.isCompleted, isFalse);
        expect(
          tester.takeException(),
          isA<TimeoutException>().having(
            (error) => error.duration,
            'duration',
            deadline,
          ),
        );
        await released.future.timeout(const Duration(seconds: 2));
        await f.runtime.close().timeout(const Duration(seconds: 2));
        expect(f.runtime.plugins.state, ApplicationPluginState.closed);
        expect(
          f.runtime.extensions.discover(mainContentContributions),
          isEmpty,
        );
        expect(
          f.runtime.extensions.discover(sessionContentInspectionContributions),
          isEmpty,
        );

        // The eventual retention failure is observed without reopening shutdown
        // or reporting a second error after the deadline already won.
        f.cleanup.complete();
        await tester.pumpAndSettle();
        expect(
          await tester.binding.handleRequestAppExit(),
          AppExitResponse.exit,
        );
        expect(bridge.retentions, 1);
        expect(tester.takeException(), isNull);
      } finally {
        if (!f.cleanup.isCompleted) f.cleanup.complete();
        await tester.pumpWidget(const SizedBox.shrink());
        await f.close(tester);
      }
    }),
  );
}

List<InspectionCard> _cards(WidgetTester tester) =>
    tester.widget<InspectionStackHost>(find.byType(InspectionStackHost)).cards;

final class _Fixture {
  _Fixture(this.directory);

  final Directory directory;
  final runtime = NativeAdeleRuntime();
  final registrations = <ExtensionRegistration>[];
  final cleanup = Completer<void>();
  final closeEntered = Completer<void>();
  late TestProjectProvider provider;
  late WindowSessionContext window;
  late Session session;
  VoidCallback? onCleanup;

  static Future<_Fixture> create(List<int> producer, List<int> renderer) async {
    final f = _Fixture(
      await Directory.systemTemp.createTemp('application-content-inspection-'),
    );
    f.provider = TestProjectProvider(f.runtime.registry);
    final database = ProjectDatabase.open(
      ProjectBacking(
        sourceLocation: f.directory.uri,
        databaseRelativePath: TestProjectProvider.databaseRelativePath,
      ),
    );
    try {
      final project = database.openProject(
        sourceLocation: f.directory.uri,
        nextProjectId: () => ProjectId('project'),
      );
      final task = Task(
        id: TaskId('task'),
        projectId: project.id,
        title: 'Content task',
      );
      final environment = Environment(
        id: EnvironmentId('environment'),
        taskId: task.id,
        role: EnvironmentRole.primary,
        providerId: ProviderId('test.unavailable-environment'),
        providerState: const {},
      );
      database.insertTaskWithPrimaryEnvironment(task, environment);
      database.insertSessionWithAuthority(
        Session(
          id: SessionId('session'),
          taskId: task.id,
          strategyId: OrchestrationStrategyId('test.unavailable-strategy'),
        ),
        environment.id,
      );
    } finally {
      database.close();
    }
    f.registrations.add(
      f.runtime.extensions.register(
        point: projectSelectorContributions,
        id: ExtensionId('test.application-content-selector'),
        value: ProjectSelectorContribution(
          displayName: 'Open content Project',
          projectProviderId: f.provider.providerId,
          selectProject: () async => f.directory.uri,
        ),
      ),
    );
    await f.install('producer', producer, [
      PreparedMainContentPresentation(
        extensionId: ExtensionId('test.application-content-producer'),
        order: 100,
        library: _producerLibrary,
        initialize: 'initialize',
        entrypoint: 'buildProducer',
        canInspectSessionContent: true,
        retainedData: true,
        operations: const {'leave': 'prepareLeave'},
        exitOperation: 'leave',
      ).toJson(),
      {
        'role': 'taskBrowser',
        'extensionId': 'test.application-content-browser',
        'displayName': 'Content browser',
        'library': _producerLibrary,
        'entrypoint': 'buildBrowser',
      },
    ]);
    await f.install('renderer', renderer, [
      PreparedSessionContentInspection(
        extensionId: ExtensionId('test.application-content-renderer'),
        contentKind: _kind,
        library: _rendererLibrary,
        entrypoint: 'buildInspection',
      ).toJson(),
    ]);
    return f;
  }

  Future<void> install(
    String name,
    List<int> bytes,
    List<Map<String, Object?>> descriptors,
  ) async {
    final installation = await Directory(
      '${directory.path}/installed/$name',
    ).create(recursive: true);
    await File('${installation.path}/frontend.evc').writeAsBytes(bytes);
    await File(
      '${installation.path}/adele_plugin.installation.json',
    ).writeAsString(
      jsonEncode({
        'manifestVersion': 1,
        'metadata': {'id': 'test.$name', 'version': '1', 'displayName': name},
        'components': {
          'frontend': {
            'artifact': 'frontend.evc',
            'presentations': descriptors,
          },
        },
      }),
    );
  }

  Future<void> mount(
    WidgetTester tester, {
    PreparedMainContentHost? mainContentHost,
    Duration exitTimeout = const Duration(seconds: 5),
  }) async {
    final registered = runtime.extensions.changes.firstWhere(
      (_) =>
          runtime.extensions.discover(mainContentContributions).isNotEmpty &&
          runtime.extensions.discover(taskBrowserContributions).isNotEmpty &&
          runtime.extensions
              .discover(sessionContentInspectionContributions)
              .isNotEmpty,
    );
    late Future<void> starting;
    await tester.pumpWidget(
      AdeleApplication(
        createRuntime: () => runtime,
        mainContentHost: mainContentHost,
        exitTimeout: exitTimeout,
        readChatGptConfiguration: () => null,
        configurationRoots: PlatformStorageRoots(
          operatingSystem: Platform.operatingSystem,
          configurationRoot: '${directory.path}/config',
          localStateRoot: '${directory.path}/state',
          localDataRoot: '${directory.path}/data',
          cacheRoot: '${directory.path}/cache',
        ),
        attachSessionContext: (context) {
          window = context;
          return () {
            onCleanup?.call();
            closeEntered.complete();
            return cleanup.future;
          };
        },
        bootstrapPlugins: (plugins) => starting = plugins.start(
          installationRoot: '${directory.path}/installed',
        ),
      ),
    );
    await starting;
    await registered.timeout(const Duration(seconds: 10));
    await tester.pumpAndSettle();
    expect(runtime.plugins.catalog!.issues, isEmpty);
    await tester.tap(find.text('Open content Project'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Open canonical Session'));
    await tester.pumpAndSettle();
    session = runtime.store.session(SessionId('session'))!;
    expect(window.snapshot.session, same(session));
    expect(
      tester.widget<MainContentHost>(find.byType(MainContentHost)).session,
      same(session),
    );
    expect(find.text('Producer session'), findsOneWidget);
    expect(find.byType(InspectionStackHost), findsNothing);
    expectNoExecution();
  }

  void expectNoExecution() {
    expect(runtime.store.session(session.id), same(session));
    expect(runtime.store.runsForSession(session.id), isEmpty);
    expect(runtime.plugins.backends, isEmpty);
    expect(runtime.plugins.host, isNull);
    expect(
      runtime.extensions.discover(orchestrationStrategyContributions),
      isEmpty,
    );
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
  }

  Future<void> close(WidgetTester tester) async {
    if (!cleanup.isCompleted) cleanup.complete();
    if (window.isActive) {
      final exiting = tester.binding.handleRequestAppExit();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.text('Leave now'));
      expect(await exiting, AppExitResponse.exit);
    }
    await tester.pumpWidget(const SizedBox.shrink());
    await runtime.close();
    for (final registration in registrations.reversed) {
      await registration.close();
    }
    await provider.close();
    await tester.pumpAndSettle();
    await directory.delete(recursive: true);
  }
}

final class _RetentionBridge
    implements PreparedFrontendBridge, PreparedFrontendRetainable {
  _RetentionBridge(this.retain);

  final VoidCallback retain;
  int retentions = 0;

  @override
  String get identifier => 'test.application-retention';
  @override
  void configureForCompile(BridgeDeclarationRegistry registry) {}
  @override
  void configureForRuntime(Runtime runtime) {}
  @override
  void invalidate() {}
  @override
  void retainPresentation() {
    if (retentions != 0) return;
    retentions++;
    retain();
  }
}

const _producerSource = r'''
import 'package:flutter/material.dart';
import 'package:adele_ui/main_content_bridge.dart';
import 'package:adele_ui/contribution_bridge.dart';
import 'package:adele_ui/session_presentation_lifecycle_bridge.dart';
import 'package:adele_ui/task_browser_bridge.dart';

Widget buildBrowser() => TextButton(
  onPressed: () async {
    await selectTask('task');
    await openSession('session');
  },
  child: const Text('Open canonical Session'),
);
void initialize() {
  if (readMainContentPanes().isEmpty) {
    openMainContentPane('producer', 'Content producer', false);
  }
}
Future<bool> prepareToDeactivate() async {
  final result = await invokeContributionOperation('leave', <String, dynamic>{});
  return result['accepted'] == true;
}
Future<Map<String, dynamic>> prepareLeave() async {
  final accepted = await confirmContribution(<String, dynamic>{
    'title': 'Leave content?',
    'message': 'Settle this test presentation before departure.',
    'acceptLabel': 'Leave now',
    'cancelLabel': 'Stay here',
  });
  return <String, dynamic>{'accepted': accepted};
}
Widget buildProducer() {
  registerSessionPrepareToDeactivate(prepareToDeactivate);
  return Column(children: [
    Text('Producer ' + readMainContentContext()['sessionId']),
    TextButton(
      onPressed: () { inspectSessionContent('test.application-content', 'note-1'); },
      child: const Text('Inspect content'),
    ),
    TextButton(
      onPressed: () { inspectSessionContent('test.application-native-content', 'native-1'); },
      child: const Text('Inspect native'),
    ),
  ]);
}
''';

const _rendererSource = r'''
import 'package:flutter/material.dart';
import 'package:adele_ui/session_content_inspection_bridge.dart';
Widget buildInspection() {
  final facts = readSessionContentInspectionContext();
  return Text('Renderer ' + facts['sessionId'] + '/' + facts['occurrenceId']);
}
''';
