import 'dart:io';

import 'package:adele_capabilities/adele_capabilities.dart';
import 'package:adele_desktop/core/adele_runtime.dart';
import 'package:adele_desktop/frontend/main_content_bridge.dart';
import 'package:adele_desktop/frontend/prepared_frontend.dart';
import 'package:adele_desktop/frontend/prepared_main_content_host.dart';
import 'package:adele_desktop/frontend/prepared_session_services.dart';
import 'package:adele_desktop/frontend/session_execution_bridge.dart';
import 'package:adele_desktop/frontend/session_presentation_lifecycle_bridge.dart';
import 'package:adele_desktop/ui/execution/run_execution_status.dart';
import 'package:adele_desktop/ui/execution/session_execution_controller.dart';
import 'package:adele_desktop/ui/main_content/main_content_host.dart';
import 'package:adele_orchestration/adele_orchestration.dart';
import 'package:adele_plugin_api/adele_plugin_api.dart';
import 'package:adele_product/adele_product.dart';
import 'package:adele_ui/adele_ui.dart';
import 'package:dart_eval/dart_eval.dart';
import 'package:flutter/material.dart';
import 'package:flutter_eval/flutter_eval.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plugin_runtime/plugin_runtime.dart';

const _library = 'package:session_probe/main.dart';

void main() {
  late Directory temporary;
  late File artifact;
  late PreparedFrontend generation;
  setUpAll(() async {
    final compiler = Compiler()
      ..addPlugin(flutterEvalPlugin)
      ..addPlugin(const MainContentDeclarations())
      ..addPlugin(const SessionExecutionDeclarations())
      ..addPlugin(const SessionPresentationLifecycleDeclarations())
      ..entrypoints.add(_library);
    final program = compiler.compile({
      'session_probe': {
        'main.dart': '''
import 'package:flutter/material.dart';
import 'package:adele_ui/main_content_bridge.dart';
import 'package:adele_ui/session_execution_bridge.dart';
import 'package:adele_ui/session_presentation_lifecycle_bridge.dart';
bool ready = false;
void initialize() {
  openMainContentPane('a', 'A', true);
  openMainContentPane('b', 'B', true);
}
Future<bool> prepare() async {
  await Future.delayed(Duration(milliseconds: 10));
  return ready;
}
Widget buildView() {
  registerSessionPrepareToDeactivate(prepare);
  return TextButton(onPressed: () {
    currentSessionId();
    ready = true;
  }, child: Text('Acknowledge ' + readMainContentPaneId()));
}
Widget withoutHook() => Column(children: [
  Text('No pending state ' + readMainContentPaneId()),
  TextButton(onPressed: () { openSessionRunActivity('missing'); },
    child: Text('Open activity')),
  buildSessionExecutionStatus(),
]);
Widget lifecycleOnly() {
  registerSessionPrepareToDeactivate(prepare);
  return TextButton(onPressed: () { ready = true; },
    child: Text('Acknowledge ' + readMainContentPaneId()));
}
''',
      },
      'adele_ui': {
        for (final name in [
          'main_content_bridge.dart',
          'session_execution_bridge.dart',
          'session_presentation_lifecycle_bridge.dart',
        ])
          name: File('../packages/ui/lib/$name').readAsStringSync(),
      },
    });
    temporary = await Directory.systemTemp.createTemp(
      'adele-session-services-',
    );
    artifact = await File(
      '${temporary.path}/probe.evc',
    ).writeAsBytes(program.write());
  });
  tearDownAll(() => temporary.delete(recursive: true));
  setUp(() async {
    generation = await PreparedFrontend.load(artifact);
    addTearDown(generation.invalidate);
  });

  for (final hook in [false, true]) {
    testWidgets(
      'per-pane services revoke exact views, not execution; hook=$hook',
      (tester) async {
        final runtime = AdeleRuntime();
        addTearDown(runtime.close);
        final strategyId = OrchestrationStrategyId('dev.example.strategy');
        final strategy = runtime.extensions.register(
          point: orchestrationStrategyContributions,
          id: ExtensionId('dev.example.strategy'),
          value: OrchestrationStrategyContribution(
            strategyId: strategyId,
            materialize: (_) => throw StateError('No Run should start.'),
          ),
        );
        addTearDown(strategy.close);
        final project = runtime.lifecycle.createProject(
          Uri.parse('file:///fixture/'),
        );
        final task = Task(
          id: TaskId('task'),
          projectId: project.id,
          title: 'Fixture',
        );
        runtime.store.publishTaskWithPrimaryEnvironment(
          task,
          Environment(
            id: EnvironmentId('environment'),
            taskId: task.id,
            role: EnvironmentRole.primary,
            providerId: ProviderId('dev.example.environment'),
            providerState: const {},
          ),
        );
        final session = runtime.lifecycle.createSession(
          taskId: task.id,
          strategyId: strategyId,
        );
        SessionExecutionController? controller;
        var allocations = 0;
        final services = PreparedSessionServices(
          extensions: runtime.extensions,
          backends: runtime.plugins,
          controllerForSession: (canonical, pin) {
            allocations++;
            expect(canonical, same(session));
            expect(
              pin,
              isNull,
              reason: 'Independent services do not impose a pin.',
            );
            return controller = SessionExecutionController(
              runtime: runtime,
              session: canonical,
              providerId: ProviderId('dev.example.model'),
              model: null,
              // Model a core owner already pinned independently of its frontend.
              strategy: OrchestrationStrategyResolver(
                runtime.extensions,
              ).resolve(strategyId),
            );
          },
          lookupControllerForSession: (_) => controller,
          inspectActivity: (_, _) => false,
          isCurrent: (_) => true,
        );
        addTearDown(() async => controller?.close());
        final host = PreparedMainContentHost();
        addTearDown(host.close);
        final descriptor = PreparedMainContentPresentation(
          extensionId: ExtensionId('dev.example.presentation'),
          order: 100,
          library: _library,
          initialize: 'initialize',
          entrypoint: hook ? 'buildView' : 'withoutHook',
          sessionExecution: true,
        );
        final installation = PreparedPluginInstallation(
          metadata: PluginMetadata(
            id: PluginId('dev.example.plugin'),
            version: '1',
            displayName: 'Fixture',
          ),
          installationDirectory: temporary,
          backendArtifactUri: null,
        );
        final contribution = host.createContribution(
          extensions: runtime.extensions,
          installation: installation,
          generation: generation,
          descriptor: descriptor,
          services: services,
          isActive: () => true,
        );
        final registration = runtime.extensions.register(
          point: mainContentContributions,
          id: descriptor.extensionId,
          value: contribution,
        );
        addTearDown(registration.close);
        Widget mount() => MaterialApp(
          home: Scaffold(
            body: MainContentHost(
              key: UniqueKey(),
              session: session,
              extensions: runtime.extensions,
            ),
          ),
        );
        await host.prepareToDeactivate(session);
        expect(allocations, 0);
        await tester.pumpWidget(mount());
        await tester.pumpAndSettle();
        expect(allocations, 1);
        if (!hook) {
          expect(find.byType(RunExecutionStatus), findsNWidgets(2));
          expect(
            tester
                .widgetList<RunExecutionStatus>(find.byType(RunExecutionStatus))
                .every((status) => !status.enabled),
            isTrue,
          );
        }
        final execution = controller!;
        final view = runtime.extensions
            .discover(mainContentContributions)
            .single;
        expect(
          () => services.bind(
            view,
            session: Session(
              id: session.id,
              taskId: session.taskId,
              strategyId: session.strategyId,
            ),
            isActive: () => true,
          ),
          throwsStateError,
        );
        final foreign = ExtensionRegistry()
          ..register(
            point: mainContentContributions,
            id: view.id,
            value: view.value,
          );
        expect(
          () => services.bind(
            foreign.discover(mainContentContributions).single,
            session: session,
            isActive: () => true,
          ),
          throwsStateError,
        );

        VoidCallback? oldAction;
        Future<void>? interrupted;
        if (hook) {
          Future<void> settle({bool rejected = false}) async {
            final pending = host.prepareToDeactivate(session);
            final checked = rejected
                ? expectLater(pending, throwsStateError)
                : pending;
            await tester.pump(const Duration(milliseconds: 10));
            await tester.pump(const Duration(milliseconds: 10));
            await checked;
          }

          await settle(rejected: true);
          oldAction = tester
              .widget<TextButton>(
                find.widgetWithText(TextButton, 'Acknowledge a'),
              )
              .onPressed!;
          oldAction();
          // A's accepted hook cannot hide B's still-pending state.
          await settle(rejected: true);
          await tester.tap(find.text('Acknowledge b'));
          await settle();
          final changed = expectLater(
            host.prepareToDeactivate(session),
            throwsStateError,
          );
          final addedDescriptor = PreparedMainContentPresentation(
            extensionId: ExtensionId('dev.example.later'),
            order: 200,
            library: _library,
            initialize: 'initialize',
            entrypoint: 'lifecycleOnly',
          );
          final added = runtime.extensions.register(
            point: mainContentContributions,
            id: addedDescriptor.extensionId,
            value: host.createContribution(
              extensions: runtime.extensions,
              installation: installation,
              generation: generation,
              descriptor: addedDescriptor,
              isActive: () => true,
            ),
          );
          // New actual presentations must not evade an in-flight departure.
          await tester.pump();
          await tester.pump();
          expect(find.text('Acknowledge a'), findsNWidgets(2));
          await tester.pumpAndSettle();
          await changed;
          await added.close();
          await tester.pumpAndSettle();
          await settle();
          interrupted = expectLater(
            host.prepareToDeactivate(session),
            throwsStateError,
          );
        } else {
          await host.prepareToDeactivate(session);
        }
        host.unbind(session);
        expect(execution.isClosed, isFalse);
        if (oldAction != null) expect(oldAction, throwsA(anything));
        await tester.pumpWidget(mount());
        await tester.pumpAndSettle();
        if (interrupted != null) await interrupted;
        expect(controller, same(execution));
        expect(allocations, 1);
        if (hook) {
          final rejected = expectLater(
            host.prepareToDeactivate(session),
            throwsStateError,
          );
          await tester.pump(const Duration(milliseconds: 10));
          await rejected;
          await tester.tap(find.text('Acknowledge a'));
          await tester.tap(find.text('Acknowledge b'));
          final accepted = host.prepareToDeactivate(session);
          await tester.pump(const Duration(milliseconds: 10));
          await tester.pump(const Duration(milliseconds: 10));
          await accepted;
        } else {
          final openActivity = tester
              .widget<TextButton>(
                find.widgetWithText(TextButton, 'Open activity').first,
              )
              .onPressed!;
          final display = tester.element(find.text('No pending state a'));
          expect(generation.retainPresentations, returnsNormally);
          expect(openActivity, throwsA(anything));
          await tester.runAsync(() async {
            await execution.close();
            await host.close();
          });
          await tester.pump();
          expect(
            tester.element(find.text('No pending state a')),
            same(display),
          );
          expect(find.byType(RunExecutionStatus), findsNWidgets(2));
          expect(find.text('Frontend unavailable.'), findsNothing);
          await tester.pumpWidget(const SizedBox.shrink());
          expect(tester.takeException(), isNull);
          return;
        }
        await tester.pumpWidget(const SizedBox.shrink());
        await host.prepareToDeactivate(session);
        await registration.close();
        expect(
          () => services.bind(view, session: session, isActive: () => true),
          throwsA(isA<StaleExtensionBinding>()),
        );
        expect(execution.capturedStrategy!.validateBinding, returnsNormally);
        final freshRegistration = runtime.extensions.register(
          point: mainContentContributions,
          id: descriptor.extensionId,
          value: contribution,
        );
        addTearDown(freshRegistration.close);
        final fresh = runtime.extensions
            .discover(mainContentContributions)
            .single;
        services
            .bind(fresh, session: session, isActive: () => true)
            .invalidate();
        await strategy.close();
        final replacement = runtime.extensions.register(
          point: orchestrationStrategyContributions,
          id: ExtensionId('dev.example.strategy'),
          value: OrchestrationStrategyContribution(
            strategyId: strategyId,
            materialize: (_) =>
                throw StateError('Must not substitute a new backend.'),
          ),
        );
        addTearDown(replacement.close);
        expect(
          () => services.bind(fresh, session: session, isActive: () => true),
          throwsA(isA<StaleExtensionBinding>()),
        );
        expect(execution.isClosed, isFalse);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'lifecycle hooks require neither execution services nor a strategy',
    (tester) async {
      final extensions = ExtensionRegistry();
      final session = Session(
        id: SessionId('offline'),
        taskId: TaskId('task'),
        strategyId: OrchestrationStrategyId('dev.missing.strategy'),
      );
      final host = PreparedMainContentHost();
      addTearDown(host.close);
      final descriptor = PreparedMainContentPresentation(
        extensionId: ExtensionId('dev.example.lifecycle'),
        order: 100,
        library: _library,
        initialize: 'initialize',
        entrypoint: 'lifecycleOnly',
      );
      final registration = extensions.register(
        point: mainContentContributions,
        id: descriptor.extensionId,
        value: host.createContribution(
          extensions: extensions,
          installation: PreparedPluginInstallation(
            metadata: PluginMetadata(
              id: PluginId('dev.example.plugin'),
              version: '1',
              displayName: 'Fixture',
            ),
            installationDirectory: temporary,
            backendArtifactUri: null,
          ),
          generation: generation,
          descriptor: descriptor,
          isActive: () => true,
        ),
      );
      addTearDown(registration.close);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: MainContentHost(session: session, extensions: extensions),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final rejected = expectLater(
        host.prepareToDeactivate(session),
        throwsStateError,
      );
      await tester.pump(const Duration(milliseconds: 10));
      await rejected;
      await tester.tap(find.text('Acknowledge a'));
      await tester.tap(find.byTooltip('Close B'));
      // Closing the unsettled pane removes its hook before a rebuild.
      final accepted = host.prepareToDeactivate(session);
      await tester.pump(const Duration(milliseconds: 10));
      await tester.pump(const Duration(milliseconds: 10));
      await accepted;
      await tester.pumpWidget(const SizedBox.shrink());
      await host.prepareToDeactivate(session);
      expect(tester.takeException(), isNull);
    },
  );
}
