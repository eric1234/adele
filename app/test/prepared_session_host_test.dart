import 'dart:io';

import 'package:adele_capabilities/adele_capabilities.dart';
import 'package:adele_desktop/core/adele_runtime.dart';
import 'package:adele_desktop/frontend/prepared_frontend.dart';
import 'package:adele_desktop/frontend/prepared_session_host.dart';
import 'package:adele_desktop/frontend/session_execution_bridge.dart';
import 'package:adele_desktop/frontend/session_presentation_lifecycle_bridge.dart';
import 'package:adele_desktop/ui/execution/session_execution_controller.dart';
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
      ..addPlugin(const SessionExecutionDeclarations())
      ..addPlugin(const SessionPresentationLifecycleDeclarations())
      ..entrypoints.add(_library);
    final program = compiler.compile({
      'session_probe': {
        'main.dart': '''
import 'package:flutter/material.dart';
import 'package:adele_ui/session_execution_bridge.dart';
import 'package:adele_ui/session_presentation_lifecycle_bridge.dart';
bool ready = false;
Future<bool> prepare() async {
  await Future.delayed(Duration(milliseconds: 10));
  return ready;
}
Widget buildView() {
  registerSessionPrepareToDeactivate(prepare);
  return TextButton(onPressed: () {
    currentSessionId();
    ready = true;
  }, child: Text('Acknowledge'));
}
Widget withoutHook() => Text('No pending state');
''',
      },
      'adele_ui': {
        for (final name in [
          'session_execution_bridge.dart',
          'session_presentation_lifecycle_bridge.dart',
        ])
          name: File(
            '${Directory.current.parent.path}/packages/ui/lib/$name',
          ).readAsStringSync(),
      },
    });
    temporary = await Directory.systemTemp.createTemp('adele-session-host-');
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
    testWidgets('host unbind/reopen revokes exact actions with hook=$hook', (
      tester,
    ) async {
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
      final controller = SessionExecutionController(
        runtime: runtime,
        session: session,
        providerId: ProviderId('dev.example.model'),
        model: null,
      );
      addTearDown(controller.close);
      final host = PreparedSessionHost(
        extensions: runtime.extensions,
        backends: runtime.plugins,
        controllerForSession: (_) => controller,
        inspectActivity: (_, _) => false,
      );
      addTearDown(host.close);
      final descriptor = PreparedSessionPresentation(
        extensionId: ExtensionId('dev.example.presentation'),
        strategyId: strategyId,
        displayName: 'Fixture',
        library: _library,
        entrypoint: hook ? 'buildView' : 'withoutHook',
      );
      final contribution = SessionPresentationContribution(
        strategyId: strategyId,
        displayName: 'Fixture',
        createPresentation: (_) => throw StateError('Use the exact host.'),
      );
      final registration = runtime.extensions.register(
        point: sessionPresentationContributions,
        id: descriptor.extensionId,
        value: contribution,
      );
      addTearDown(registration.close);
      final selection = host.resolve(
        SessionPresentationResolver(runtime.extensions).resolve(strategyId),
      );
      Widget presentation() => host.createPresentation(
        generation: generation,
        contribution: contribution,
        descriptor: descriptor,
        session: session,
        isActive: () => true,
      );
      Widget mount() => MaterialApp(home: Scaffold(body: presentation()));
      await host.prepareToDeactivate(session);
      host.bind(session, selection);
      await host.prepareToDeactivate(session);
      await tester.pumpWidget(mount());
      await tester.pumpAndSettle();
      VoidCallback? oldAction;
      Future<void>? interrupted;
      if (hook) {
        final rejected = expectLater(
          host.prepareToDeactivate(session),
          throwsStateError,
        );
        await tester.pump(const Duration(milliseconds: 10));
        await rejected;
        oldAction = tester
            .widget<TextButton>(find.byType(TextButton))
            .onPressed!;
        oldAction();
        final accepted = host.prepareToDeactivate(session);
        await tester.pump(const Duration(milliseconds: 10));
        await accepted;
        interrupted = expectLater(
          host.prepareToDeactivate(session),
          throwsStateError,
        );
      } else {
        await host.prepareToDeactivate(session);
      }
      host.unbind(session);
      expect(presentation, throwsStateError);
      expect(
        controller.isClosed,
        isFalse,
        reason: 'The parent owns execution teardown.',
      );
      host.bind(session, selection);
      if (oldAction != null) expect(oldAction, throwsA(anything));
      await tester.pumpWidget(mount());
      await tester.pumpAndSettle();
      if (interrupted != null) {
        await tester.pump(const Duration(milliseconds: 10));
        await interrupted;
      }
      if (hook) {
        final rejected = expectLater(
          host.prepareToDeactivate(session),
          throwsStateError,
        );
        await tester.pump(const Duration(milliseconds: 10));
        await rejected;
        // Old widget disposal must not remove the reopened presentation's hook.
        await tester.tap(find.text('Acknowledge'));
        final accepted = host.prepareToDeactivate(session);
        await tester.pump(const Duration(milliseconds: 10));
        await accepted;
        expect(oldAction!, throwsA(anything));
      } else {
        await host.prepareToDeactivate(session);
      }
      await tester.pumpWidget(const SizedBox.shrink());
      await host.prepareToDeactivate(session);
      expect(controller.isClosed, isFalse);
      expect(tester.takeException(), isNull);
    });
  }
}
