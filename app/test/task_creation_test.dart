import 'dart:async';
import 'dart:ui' show AppExitResponse;

import 'package:adele_capabilities/adele_capabilities.dart';
import 'package:adele_contract/adele_contract.dart';
import 'package:adele_core_extensions/adele_core_extensions.dart';
import 'package:adele_desktop/application.dart';
import 'package:adele_desktop/core/adele_runtime.dart';
import 'package:adele_desktop/core/application_plugin_bootstrap.dart';
import 'package:adele_desktop/core/product_lifecycle.dart';
import 'package:adele_desktop/ui/shell/adele_shell.dart';
import 'package:adele_desktop/ui/shell/task_title_form.dart';
import 'package:adele_environment/adele_environment.dart';
import 'package:adele_model_provider/adele_model_provider.dart'
    show modelProviderCapability;
import 'package:adele_plugin_api/adele_plugin_api.dart';
import 'package:adele_product/adele_product.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plugin_runtime/plugin_runtime.dart';

void main() {
  late AdeleRuntime runtime;
  late _RecordingIds ids;
  late _EnvironmentChannel channel;
  late int runtimeCreations;
  final Uri source = Uri.parse('file:///task-fixture/Project%20Name/');
  final ProviderId providerId = ProviderId('dev.adele.environment.task-test');

  setUp(() {
    ids = _RecordingIds();
    runtime = AdeleRuntime(ids: ids);
    channel = _EnvironmentChannel();
    runtimeCreations = 0;
    final ExtensionRegistration selector = runtime.extensions.register(
      point: projectSelectorContributions,
      id: ExtensionId('dev.adele.test.task-project-selector'),
      value: ProjectSelectorContribution(
        displayName: 'Open Test Project...',
        selectProject: () async => source,
      ),
    );
    addTearDown(selector.close);
    addTearDown(() {
      expect(ids.calls, isNot(contains('session')));
      expect(runtime.store.session(SessionId('session-1')), isNull);
      expect(runtime.store.sessionAuthority(SessionId('session-1')), isNull);
      expect(runtime.registry.providersFor(modelProviderCapability), isEmpty);
    });
  });

  AdeleRuntime createRuntime() {
    runtimeCreations++;
    return runtime;
  }

  CapabilityRegistration registerProvider() {
    final CapabilityRegistration registration = runtime.registry.register(
      provider: ProviderDescriptor(
        id: providerId,
        capability: environmentProviderCapability,
        pluginId: 'dev.adele.plugin.task-test',
        displayName: 'Test Environment',
        serviceId: environmentProviderServiceId,
      ),
      endpoint: AdeleRequestChannelEndpoint(
        channel: channel,
        serviceId: environmentProviderServiceId,
        isAvailable: () => true,
      ),
    );
    addTearDown(registration.close);
    return registration;
  }

  AdeleShell shell(WidgetTester tester) =>
      tester.widget<AdeleShell>(find.byType(AdeleShell));

  FilledButton button(WidgetTester tester, String label) =>
      tester.widget<FilledButton>(find.widgetWithText(FilledButton, label));

  Future<Project> openProject(WidgetTester tester) async {
    expect(find.text('No Project is open'), findsOneWidget);
    expect(find.text('New Task'), findsNothing);
    expect(ids.calls, isEmpty);
    expect(channel.calls, isEmpty);
    await tester.tap(find.text('Open Test Project...'));
    await tester.pumpAndSettle();
    final Project project = shell(tester).project!;
    expect(project.id, ProjectId('project-1'));
    expect(project.sourceLocation, source);
    expect(runtime.store.project(project.id), same(project));
    expect(find.text('Project is open'), findsOneWidget);
    expect(find.text('No Tasks yet'), findsOneWidget);
    expect(ids.calls, <String>['project']);
    return project;
  }

  Future<void> enterTitle(WidgetTester tester, String title) async {
    await tester.tap(find.text('New Task'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), title);
  }

  Future<void> disposeApplication(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    // Await the cached close future inside the widget's fake-async zone.
    await runtime.close();
    expect(runtime.plugins.state, ApplicationPluginState.closed);
    expect(tester.takeException(), isNull);
  }

  void expectUnpublished(WidgetTester tester, Project project, int attempt) {
    expect(shell(tester).project, same(project));
    expect(runtime.store.project(project.id), same(project));
    expect(runtime.store.task(TaskId('task-$attempt')), isNull);
    expect(
      runtime.store.environment(EnvironmentId('environment-$attempt')),
      isNull,
    );
    expect(
      runtime.store.primaryEnvironmentFor(TaskId('task-$attempt')),
      isNull,
    );
    expect(
      runtime.lifecycle.environmentRuntime.currentMaterialization(
        EnvironmentId('environment-$attempt'),
      ),
      isNull,
    );
  }

  testWidgets('creates one canonical Task through generated establishment', (
    tester,
  ) async {
    registerProvider();
    await tester.pumpWidget(AdeleApplication(createRuntime: createRuntime));
    final Project project = await openProject(tester);
    // No deployment defines: an independently registered provider is sufficient.
    expect(runtime.plugins.state, ApplicationPluginState.unconfigured);
    expect(button(tester, 'New Task').onPressed, isNotNull);
    expect(
      find.textContaining('Task Environment support is unavailable'),
      findsNothing,
    );
    await enterTitle(tester, '  Establish a Task  ');
    await tester.tap(find.text('Create Task'));
    await tester.pump();

    expect(ids.calls, <String>['project', 'task', 'environment']);
    expectUnpublished(tester, project, 1);
    expect(runtime.store.tasksFor(project.id), isEmpty);
    expect(shell(tester).task, isNull);
    expect(shell(tester).environment, isNull);
    final request = channel.calls.single;
    expect(request.method, environmentProviderServiceEstablishId);
    expect(request.payload, <String, Object?>{
      'context': <String, Object?>{
        'projectId': project.id.value,
        'projectSourceLocation': source.toString(),
        'taskId': 'task-1',
        'taskTitle': 'Establish a Task',
        'environmentId': 'environment-1',
        'environmentRole': 'primary',
        'providerId': providerId.value,
        'providerStateInitialized': false,
        'providerState': <String, Object?>{},
      },
    });
    channel.succeed();
    await tester.pumpAndSettle();

    final Task task = shell(tester).task!;
    final Environment environment = shell(tester).environment!;
    expect(task.id, TaskId('task-1'));
    expect(task.projectId, project.id);
    expect(task.title, 'Establish a Task');
    expect(environment.id, EnvironmentId('environment-1'));
    expect(environment.taskId, task.id);
    expect(environment.role, EnvironmentRole.primary);
    expect(environment.providerId, providerId);
    expect(environment.providerState, _EnvironmentChannel.providerState);
    expect(runtime.store.tasksFor(project.id), hasLength(1));
    expect(runtime.store.tasksFor(project.id).single, same(task));
    expect(runtime.store.task(task.id), same(task));
    expect(runtime.store.environment(environment.id), same(environment));
    expect(runtime.store.primaryEnvironmentFor(task.id), same(environment));
    final EnvironmentMaterialization materialization = runtime
        .lifecycle
        .environmentRuntime
        .currentMaterialization(environment.id)!;
    expect(materialization.environment, same(environment));
    expect(materialization.provider, isA<GeneratedEnvironmentProvider>());
    expect(materialization.validateBinding, returnsNormally);
    expect(shell(tester).environmentReady, isTrue);
    expect(find.text('Task: Establish a Task'), findsOneWidget);
    expect(find.text('Primary Environment ready'), findsOneWidget);
    expect(find.text('Environment: ${environment.id}'), findsOneWidget);
    expect(find.text('No Tasks yet'), findsNothing);
    expect(find.byType(TaskTitleForm), findsNothing);

    await tester.pumpWidget(AdeleApplication(createRuntime: createRuntime));
    await tester.pumpAndSettle();
    expect(runtimeCreations, 1);
    expect(shell(tester).project, same(project));
    expect(shell(tester).task, same(task));
    expect(shell(tester).environment, same(environment));
    expect(ids.calls, <String>['project', 'task', 'environment']);
    expect(channel.calls, hasLength(1));
    expect(tester.takeException(), isNull);
    await disposeApplication(tester);
  });

  testWidgets(
    'pending submission disables controls and rejects retained callbacks',
    (tester) async {
      registerProvider();
      await tester.pumpWidget(AdeleApplication(createRuntime: createRuntime));
      final Project project = await openProject(tester);
      await enterTitle(tester, 'Only one');
      final TaskTitleForm retained = tester.widget<TaskTitleForm>(
        find.byType(TaskTitleForm),
      );
      await tester.tap(find.text('Create Task'));
      retained.onSubmit('Duplicate before rebuild');
      await tester.pump();
      retained.onSubmit('Duplicate while pending');
      retained.onCancel();
      await tester.tap(find.text('Create Task'));
      await tester.pump();

      expect(ids.calls, <String>['project', 'task', 'environment']);
      expect(channel.calls, hasLength(1));
      expectUnpublished(tester, project, 1);
      expect(find.text('Creating Task...'), findsOneWidget);
      expect(button(tester, 'Create Task').onPressed, isNull);
      expect(
        tester
            .widget<TextButton>(find.widgetWithText(TextButton, 'Cancel'))
            .onPressed,
        isNull,
      );
      final TextField field = tester.widget<TextField>(find.byType(TextField));
      expect(field.enabled, isFalse);
      expect(field.onSubmitted, isNull);
      expect(field.controller!.text, 'Only one');
      channel.succeed();
      await tester.pumpAndSettle();
      retained.onSubmit('Duplicate after success');
      await tester.pump();
      expect(runtime.store.tasksFor(project.id), hasLength(1));
      expect(shell(tester).task!.title, 'Only one');
      expect(channel.calls, hasLength(1));
      expect(ids.calls, <String>['project', 'task', 'environment']);
      expect(tester.takeException(), isNull);
      await disposeApplication(tester);
    },
  );

  testWidgets('blank titles fail before identity allocation', (tester) async {
    registerProvider();
    await tester.pumpWidget(AdeleApplication(createRuntime: createRuntime));
    final Project project = await openProject(tester);
    await enterTitle(tester, '   ');
    await tester.tap(find.text('Create Task'));
    await tester.pumpAndSettle();
    expect(find.text('Task title must not be blank.'), findsOneWidget);
    tester.widget<TaskTitleForm>(find.byType(TaskTitleForm)).onSubmit('\t\n');
    await tester.pump();
    expect(ids.calls, <String>['project']);
    expect(channel.calls, isEmpty);
    expectUnpublished(tester, project, 1);
    expect(runtime.store.tasksFor(project.id), isEmpty);
    expect(shell(tester).task, isNull);
    expect(shell(tester).environment, isNull);
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      '   ',
    );
    expect(tester.takeException(), isNull);
    await disposeApplication(tester);
  });

  testWidgets('cancel abandons the form without allocating identities', (
    tester,
  ) async {
    registerProvider();
    await tester.pumpWidget(AdeleApplication(createRuntime: createRuntime));
    final Project project = await openProject(tester);
    await enterTitle(tester, 'Abandoned title');
    final TaskTitleForm retained = tester.widget<TaskTitleForm>(
      find.byType(TaskTitleForm),
    );
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    retained.onSubmit('Late cancelled submission');
    await tester.pump();
    expect(find.byType(TaskTitleForm), findsNothing);
    expect(button(tester, 'New Task').onPressed, isNotNull);
    expectUnpublished(tester, project, 1);
    expect(runtime.store.tasksFor(project.id), isEmpty);
    expect(ids.calls, <String>['project']);
    expect(channel.calls, isEmpty);
    await tester.tap(find.text('New Task'));
    await tester.pumpAndSettle();
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      isEmpty,
    );
    expect(tester.takeException(), isNull);
    await disposeApplication(tester);
  });

  testWidgets('failure preserves Project and title for a successful retry', (
    tester,
  ) async {
    registerProvider();
    await tester.pumpWidget(AdeleApplication(createRuntime: createRuntime));
    final Project project = await openProject(tester);
    await enterTitle(tester, '  Retry this title  ');
    await tester.tap(find.text('Create Task'));
    await tester.pump();
    channel.calls.single.result.completeError(
      StateError('establishment failed'),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('Could not create Task:'), findsOneWidget);
    expect(find.textContaining('establishment failed'), findsOneWidget);
    expect(find.text('Creating Task...'), findsNothing);
    expectUnpublished(tester, project, 1);
    expect(runtime.store.tasksFor(project.id), isEmpty);
    expect(shell(tester).task, isNull);
    expect(shell(tester).environment, isNull);
    expect(find.text('No Tasks yet'), findsOneWidget);
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      '  Retry this title  ',
    );
    expect(button(tester, 'Create Task').onPressed, isNotNull);

    await tester.showKeyboard(find.byType(TextField));
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();
    expect(find.textContaining('Could not create Task:'), findsNothing);
    expect(channel.calls, hasLength(2));
    channel.succeed(1);
    await tester.pumpAndSettle();
    final Task task = shell(tester).task!;
    final Environment environment = shell(tester).environment!;
    expect(task.id, TaskId('task-2'));
    expect(task.title, 'Retry this title');
    expect(environment.id, EnvironmentId('environment-2'));
    expect(runtime.store.tasksFor(project.id).single, same(task));
    expect(runtime.store.environment(environment.id), same(environment));
    expectUnpublished(tester, project, 1);
    expect(ids.calls, <String>[
      'project',
      'task',
      'environment',
      'task',
      'environment',
    ]);
    expect(find.text('Primary Environment ready'), findsOneWidget);
    expect(find.byType(TaskTitleForm), findsNothing);
    expect(tester.takeException(), isNull);
    await disposeApplication(tester);
  });

  testWidgets(
    'later failure preserves the previously presented Task and Environment',
    (tester) async {
      registerProvider();
      await tester.pumpWidget(AdeleApplication(createRuntime: createRuntime));
      final Project project = await openProject(tester);
      await enterTitle(tester, 'First Task');
      await tester.tap(find.text('Create Task'));
      await tester.pump();
      channel.succeed();
      await tester.pumpAndSettle();
      final Task task = shell(tester).task!;
      final Environment environment = shell(tester).environment!;
      await enterTitle(tester, 'Second Task');
      await tester.tap(find.text('Create Task'));
      await tester.pump();
      expect(shell(tester).task, same(task));
      expect(shell(tester).environment, same(environment));
      channel.calls.last.result.completeError(
        StateError('second establishment failed'),
      );
      await tester.pumpAndSettle();
      expectUnpublished(tester, project, 2);
      expect(runtime.store.tasksFor(project.id).single, same(task));
      expect(runtime.store.environment(environment.id), same(environment));
      expect(shell(tester).task, same(task));
      expect(shell(tester).environment, same(environment));
      expect(find.text('Task: First Task'), findsOneWidget);
      expect(find.text('Primary Environment ready'), findsOneWidget);
      expect(
        find.textContaining('second establishment failed'),
        findsOneWidget,
      );
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        'Second Task',
      );
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(shell(tester).task, same(task));
      expect(shell(tester).environment, same(environment));
      expect(find.textContaining('Could not create Task:'), findsNothing);
      expect(tester.takeException(), isNull);
      await disposeApplication(tester);
    },
  );

  for (final bool exit in <bool>[false, true]) {
    for (final bool succeeds in <bool>[false, true]) {
      testWidgets(
        'late ${succeeds ? 'success' : 'error'} after ${exit ? 'exit' : 'disposal'} does not present a Task',
        (tester) async {
          final CapabilityRegistration registration = registerProvider();
          await tester.pumpWidget(
            AdeleApplication(createRuntime: createRuntime),
          );
          final ExtensionBinding<ProjectSelectorContribution> stockSelector =
              runtime.extensions.discover(projectSelectorContributions).first;
          final Project project = await openProject(tester);
          await enterTitle(tester, 'Too late');
          final TaskTitleForm retained = tester.widget<TaskTitleForm>(
            find.byType(TaskTitleForm),
          );
          await tester.tap(find.text('Create Task'));
          await tester.pump();
          expect(channel.calls, hasLength(1));
          Future<AppExitResponse>? exiting;
          bool exitCompleted = false;
          if (exit) {
            exiting = tester.binding.handleRequestAppExit().then((response) {
              exitCompleted = true;
              return response;
            });
          } else {
            await tester.pumpWidget(const SizedBox.shrink());
          }
          retained.onSubmit('Duplicate while closing');
          retained.onCancel();
          await tester.pumpAndSettle();
          // Closing blocks presentation immediately but must drain establishment
          // before retiring runtime-owned resources.
          expect(exitCompleted, isFalse);
          expect(runtime.plugins.state, ApplicationPluginState.unconfigured);
          expect(stockSelector.validate, returnsNormally);
          expect(registration.isClosed, isFalse);
          expect(runtime.store.tasksFor(project.id), isEmpty);
          expect(
            runtime.store.environment(EnvironmentId('environment-1')),
            isNull,
          );
          expect(ids.calls, <String>['project', 'task', 'environment']);
          expect(channel.calls, hasLength(1));
          if (exit) {
            expect(shell(tester).project, same(project));
            expect(shell(tester).task, isNull);
            expect(shell(tester).environment, isNull);
            expect(find.byType(TaskTitleForm), findsOneWidget);
          } else {
            expect(find.byType(AdeleShell), findsNothing);
          }
          expect(find.textContaining('Could not create Task:'), findsNothing);
          // Independently retired providers still retain successful settlement.
          await registration.close();
          if (succeeds) {
            channel.succeed();
          } else {
            channel.calls.single.result.completeError(
              StateError('late establishment failed'),
            );
          }
          await tester.pumpAndSettle();
          if (exiting != null) {
            expect(await exiting, AppExitResponse.exit);
            expect(exitCompleted, isTrue);
          }
          expect(runtime.plugins.state, ApplicationPluginState.closed);
          expect(stockSelector.validate, throwsA(isA<StaleExtensionBinding>()));
          retained.onSubmit('Late duplicate');
          await tester.pump();

          expect(runtime.store.project(project.id), same(project));
          expect(ids.calls, <String>['project', 'task', 'environment']);
          expect(channel.calls, hasLength(1));
          if (succeeds) {
            // Successful provider settlement survives retirement; only presentation is ignored.
            final Task task = runtime.store.tasksFor(project.id).single;
            final Environment environment = runtime.store.primaryEnvironmentFor(
              task.id,
            )!;
            expect(
              environment.providerState,
              _EnvironmentChannel.providerState,
            );
            expect(
              runtime.lifecycle.environmentRuntime
                  .currentMaterialization(environment.id)!
                  .validateBinding,
              throwsA(isA<ProviderUnavailable>()),
            );
          } else {
            expect(runtime.store.tasksFor(project.id), isEmpty);
            expect(
              runtime.store.environment(EnvironmentId('environment-1')),
              isNull,
            );
          }
          if (exit) {
            expect(shell(tester).project, same(project));
            expect(shell(tester).task, isNull);
            expect(shell(tester).environment, isNull);
            expect(find.text('No Tasks yet'), findsOneWidget);
          } else {
            expect(find.byType(AdeleShell), findsNothing);
          }
          expect(find.text('Task: Too late'), findsNothing);
          expect(find.text('Primary Environment ready'), findsNothing);
          expect(find.textContaining('Could not create Task:'), findsNothing);
          expect(tester.takeException(), isNull);
          await disposeApplication(tester);
        },
      );
    }
  }

  testWidgets(
    'unconfigured backend still opens Project with New Task disabled',
    (tester) async {
      await tester.pumpWidget(AdeleApplication(createRuntime: createRuntime));
      final Project project = await openProject(tester);
      expect(runtime.plugins.state, ApplicationPluginState.unconfigured);
      expect(
        runtime.registry.providersFor(environmentProviderCapability),
        isEmpty,
      );
      expect(button(tester, 'New Task').onPressed, isNull);
      expect(
        find.textContaining('Task Environment support is unavailable'),
        findsOneWidget,
      );
      await tester.tap(find.text('New Task'));
      await tester.pump();
      expect(find.byType(TaskTitleForm), findsNothing);
      expectUnpublished(tester, project, 1);
      expect(ids.calls, <String>['project']);
      expect(channel.calls, isEmpty);
      expect(tester.takeException(), isNull);
      await disposeApplication(tester);
    },
  );

  testWidgets(
    'backend startup error still opens Project with New Task disabled',
    (tester) async {
      await tester.pumpWidget(
        AdeleApplication(
          createRuntime: createRuntime,
          bootstrapPlugins: (ApplicationPluginBootstrap plugins) async {
            expect(plugins, same(runtime.plugins));
            throw StateError('backend startup failed');
          },
        ),
      );
      final Project project = await openProject(tester);
      expect(find.textContaining('backend startup failed'), findsOneWidget);
      expect(button(tester, 'New Task').onPressed, isNull);
      expectUnpublished(tester, project, 1);
      expect(ids.calls, <String>['project']);
      expect(channel.calls, isEmpty);
      expect(tester.takeException(), isNull);
      await disposeApplication(tester);
    },
  );

  testWidgets(
    'asynchronous fake activation enables Task creation without remounting',
    (tester) async {
      final Completer<void> startup = Completer<void>();
      int bootstraps = 0;
      await tester.pumpWidget(
        AdeleApplication(
          createRuntime: createRuntime,
          bootstrapPlugins: (ApplicationPluginBootstrap plugins) async {
            bootstraps++;
            expect(plugins.registry, same(runtime.registry));
            await startup.future;
            registerProvider();
          },
        ),
      );
      final Project project = await openProject(tester);
      expect(button(tester, 'New Task').onPressed, isNull);
      startup.complete();
      await tester.pumpAndSettle();
      expect(runtimeCreations, 1);
      expect(bootstraps, 1);
      expect(shell(tester).project, same(project));
      expect(button(tester, 'New Task').onPressed, isNotNull);
      expect(
        find.textContaining('Task Environment support is unavailable'),
        findsNothing,
      );
      await enterTitle(tester, 'Activated asynchronously');
      await tester.tap(find.text('Create Task'));
      await tester.pump();
      channel.succeed();
      await tester.pumpAndSettle();
      expect(find.text('Task: Activated asynchronously'), findsOneWidget);
      expect(find.text('Primary Environment ready'), findsOneWidget);
      expect(
        runtime.store.tasksFor(project.id).single,
        same(shell(tester).task),
      );
      expect(ids.calls, <String>['project', 'task', 'environment']);
      expect(tester.takeException(), isNull);
      await disposeApplication(tester);
    },
  );

  testWidgets(
    'narrow mobile viewport supports editing, pending and ready states',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(360, 640));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      registerProvider();
      await tester.pumpWidget(AdeleApplication(createRuntime: createRuntime));
      final Project project = await openProject(tester);
      await enterTitle(
        tester,
        'A task title that wraps on a narrow mobile viewport',
      );
      await tester.ensureVisible(find.text('Create Task'));
      await tester.tap(find.text('Create Task'));
      await tester.pumpAndSettle();
      expect(find.text('Creating Task...'), findsOneWidget);
      expect(tester.takeException(), isNull);
      channel.succeed();
      await tester.pumpAndSettle();
      expect(find.text('Primary Environment ready'), findsOneWidget);
      expect(shell(tester).project, same(project));
      expect(
        runtime.store.tasksFor(project.id).single,
        same(shell(tester).task),
      );
      expect(tester.takeException(), isNull);
      await disposeApplication(tester);
    },
  );
}

final class _RecordingIds implements ProductIdSource {
  final List<String> calls = <String>[];
  int _tasks = 0;
  int _environments = 0;

  @override
  ProjectId nextProjectId() {
    calls.add('project');
    return ProjectId('project-1');
  }

  @override
  TaskId nextTaskId() {
    calls.add('task');
    return TaskId('task-${++_tasks}');
  }

  @override
  EnvironmentId nextEnvironmentId() {
    calls.add('environment');
    return EnvironmentId('environment-${++_environments}');
  }

  @override
  SessionId nextSessionId() {
    calls.add('session');
    throw StateError('Task creation must not allocate a Session');
  }
}

final class _EnvironmentChannel implements AdeleRequestChannel {
  static const Map<String, Object?> providerState = <String, Object?>{
    'transport': 'established',
    'fixture': 'task-creation',
  };
  final List<
    ({String method, Map<String, Object?> payload, Completer<Object?> result})
  >
  calls = [];

  @override
  Future<Object?> request(String method, Map<String, Object?> payload) {
    expect(method, environmentProviderServiceEstablishId);
    final Completer<Object?> result = Completer<Object?>();
    calls.add((method: method, payload: payload, result: result));
    return result.future;
  }

  void succeed([int index = 0]) => calls[index].result.complete(
    <String, Object?>{'providerState': providerState},
  );
}
