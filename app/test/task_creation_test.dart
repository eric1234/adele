import 'dart:async';
import 'dart:io';
import 'dart:ui' show AppExitResponse;

import 'package:adele_capabilities/adele_capabilities.dart';
import 'package:adele_contract/adele_contract.dart';
import 'package:adele_core_extensions/adele_core_extensions.dart';
import 'package:adele_desktop/application.dart';
import 'package:adele_desktop/core/application_plugin_bootstrap.dart';
import 'package:adele_desktop/core/product_lifecycle.dart';
import 'package:adele_desktop/terminal/native_adele_runtime.dart';
import 'package:adele_desktop/ui/shell/adele_shell.dart';
import 'package:adele_environment/adele_environment.dart';
import 'package:adele_model_provider/adele_model_provider.dart'
    show modelProviderCapability;
import 'package:adele_plugin_api/adele_plugin_api.dart';
import 'package:adele_product/adele_product.dart';
import 'package:adele_ui/adele_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plugin_runtime/plugin_runtime.dart';

import '../tool/task_browser_frontend_compiler.dart';
import 'support/prepared_frontend_installations.dart';
import 'support/project_provider.dart';

void main() {
  late NativeAdeleRuntime runtime;
  late _RecordingIds ids;
  late _EnvironmentChannel channel;
  late int runtimeCreations;
  late Uri source;
  late Directory artifacts;
  late Directory installations;
  final ProviderId providerId = ProviderId('dev.adele.environment.task-test');

  setUpAll(() async {
    artifacts = await Directory.systemTemp.createTemp('adele-task-browser-');
    final artifact = await File('${artifacts.path}/frontend.evc').writeAsBytes(
      await compileTaskBrowserFrontend(
        repositoryRoot: Directory.current.parent,
      ),
    );
    installations = await prepareFrontendInstallations(
      root: Directory('${artifacts.path}/installed'),
      artifacts: {'dev.adele.plugin.task-browser': artifact},
    );
    final catalog = await PreparedPluginCatalog.discover(installations.path);
    expect(catalog.issues, isEmpty);
  });
  tearDownAll(() => artifacts.delete(recursive: true));

  setUp(() {
    ids = _RecordingIds();
    runtime = NativeAdeleRuntime(ids: ids);
    final directory = Directory.systemTemp.createTempSync(
      'adele-task-project-',
    );
    source = (Directory('${directory.path}/Project Name')..createSync()).uri;
    final projectProvider = TestProjectProvider(runtime.registry);
    addTearDown(() async {
      await TestWidgetsFlutterBinding.instance.runAsync(() async {
        if (runtime.plugins.state != ApplicationPluginState.closed) {
          await runtime.close();
        }
        await projectProvider.close();
        directory.deleteSync(recursive: true);
      });
    });
    channel = _EnvironmentChannel();
    runtimeCreations = 0;
    final ExtensionRegistration selector = runtime.extensions.register(
      point: projectSelectorContributions,
      id: ExtensionId('dev.adele.test.task-project-selector'),
      value: ProjectSelectorContribution(
        displayName: 'Open Test Project...',
        projectProviderId: testProjectProviderId,
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

  NativeAdeleRuntime createRuntime() {
    runtimeCreations++;
    return runtime;
  }

  Future<void> mountApplication(
    WidgetTester tester, {
    Future<void> Function(ApplicationPluginBootstrap)? afterBootstrap,
  }) async {
    await tester.runAsync(() async {
      final registered = runtime.extensions.changes.firstWhere(
        (_) => runtime.extensions.discover(taskBrowserContributions).isNotEmpty,
      );
      await tester.pumpWidget(
        AdeleApplication(
          createRuntime: createRuntime,
          bootstrapPlugins: (plugins) async {
            await plugins.start(installationRoot: installations.path);
            await afterBootstrap?.call(plugins);
          },
        ),
      );
      await registered.timeout(const Duration(seconds: 10));
    });
    await tester.pumpAndSettle();
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

  VoidCallback action(WidgetTester tester, String label) => tester
      .widget<TextButton>(find.widgetWithText(TextButton, label))
      .onPressed!;

  Finder actionButton(String label) => find.widgetWithText(
    label == 'New Task' ? ElevatedButton : TextButton,
    label,
  );

  Finder titleField() => find.descendant(
    of: find
        .ancestor(of: find.text('Task title'), matching: find.byType(Card))
        .first,
    matching: find.byType(TextField),
  );

  void expectBrowserSelection(
    WidgetTester tester,
    Task task,
    Environment environment,
  ) {
    expect(shell(tester).task, same(task));
    expect(shell(tester).environment, same(environment));
    expect(shell(tester).sessionContent, isNull);
    expect(find.text(task.title), findsWidgets);
    expect(find.text('Environment: ${environment.id}'), findsOneWidget);
    expect(find.textContaining(environment.providerId.value), findsOneWidget);
    expect(runtime.store.sessionsForTask(task.id), isEmpty);
  }

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
    expect(
      File.fromUri(
        source.resolve(TestProjectProvider.databaseRelativePath),
      ).existsSync(),
      isTrue,
    );
    expect(find.text('Task Browser'), findsOneWidget);
    expect(shell(tester).task, isNull);
    expect(shell(tester).environment, isNull);
    expect(
      find.text('No Tasks yet. Create a Task to get started.'),
      findsOneWidget,
    );
    expect(ids.calls, <String>['project']);
    return project;
  }

  Future<void> enterTitle(WidgetTester tester, String title) async {
    if (find.text('Back to Tasks').evaluate().isNotEmpty) {
      await tester.tap(find.text('Back to Tasks'));
      await tester.pumpAndSettle();
    }
    await tester.tap(find.text('New Task'));
    await tester.pumpAndSettle();
    await tester.enterText(titleField(), title);
    await tester.pumpAndSettle();
  }

  Future<void> disposeApplication(WidgetTester tester) async {
    // Prepared bootstrap owns real async resources, including shutdown streams.
    await tester.runAsync(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      await runtime.close();
    });
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
    await mountApplication(tester);
    final Project project = await openProject(tester);
    // No deployment defines: an independently registered provider is sufficient.
    expect(runtime.plugins.state, ApplicationPluginState.ready);
    expect(actionButton('New Task'), findsOneWidget);
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
    expectBrowserSelection(tester, task, environment);
    expect(find.text('No Task selected'), findsNothing);
    expect(find.text('Task title'), findsNothing);

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

  testWidgets('reopened Tasks remain unselected until explicitly browsed', (
    tester,
  ) async {
    registerProvider();
    final project = await runtime.lifecycle.openProject(
      sourceLocation: source,
      provider: runtime.lifecycle.resolveProjectProvider(testProjectProviderId),
    );
    final creating = runtime.lifecycle.createTask(
      projectId: project.id,
      title: 'Retained Task',
    );
    channel.succeed();
    final created = await creating;
    await runtime.close();

    runtime = NativeAdeleRuntime(ids: ids);
    final projectProvider = TestProjectProvider(runtime.registry);
    addTearDown(projectProvider.close);
    final selector = runtime.extensions.register(
      point: projectSelectorContributions,
      id: ExtensionId('dev.adele.test.reopened-project-selector'),
      value: ProjectSelectorContribution(
        displayName: 'Reopen Project',
        projectProviderId: projectProvider.providerId,
        selectProject: () async => source,
      ),
    );
    addTearDown(selector.close);
    await mountApplication(tester);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Reopen Project'));
    await tester.pumpAndSettle();

    expect(shell(tester).project!.id, project.id);
    expect(runtime.store.task(created.task.id)!.title, 'Retained Task');
    expect(
      runtime.store.environment(created.environment.id)!.providerState,
      created.environment.providerState,
    );
    expect(
      runtime.lifecycle.environmentRuntime.currentMaterialization(
        created.environment.id,
      ),
      isNull,
    );
    expect(shell(tester).task, isNull);
    expect(shell(tester).environment, isNull);
    expect(find.text('Retained Task'), findsOneWidget);
    expect(find.text('New Task'), findsOneWidget);
    expect(ids.calls, ['project', 'task', 'environment']);
    expect(channel.calls, hasLength(1));
    await tester.tap(find.widgetWithText(ListTile, 'Retained Task'));
    await tester.pumpAndSettle();
    expectBrowserSelection(
      tester,
      runtime.store.task(created.task.id)!,
      runtime.store.environment(created.environment.id)!,
    );
    expect(
      runtime.lifecycle.environmentRuntime.currentMaterialization(
        created.environment.id,
      ),
      isNull,
    );
    expect(ids.calls, ['project', 'task', 'environment']);
    expect(channel.calls, hasLength(1));
    await disposeApplication(tester);
  });

  testWidgets(
    'local search and Task selection do not establish new product state',
    (tester) async {
      registerProvider();
      await mountApplication(tester);
      final project = await openProject(tester);
      for (final title in ['First Task', 'Second Task']) {
        await enterTitle(tester, title);
        await tester.tap(find.text('Create Task'));
        await tester.pump();
        channel.succeed(channel.calls.length - 1);
        await tester.pumpAndSettle();
      }
      final tasks = runtime.store.tasksFor(project.id);
      final search = find.byType(TextField);
      await tester.enterText(search, 'FIRST');
      await tester.pumpAndSettle();
      expect(find.widgetWithText(ListTile, 'First Task'), findsOneWidget);
      expect(find.widgetWithText(ListTile, 'Second Task'), findsNothing);
      expect(shell(tester).task, same(tasks.last));
      await tester.tap(find.widgetWithText(ListTile, 'First Task'));
      await tester.pumpAndSettle();
      expectBrowserSelection(
        tester,
        tasks.first,
        runtime.store.primaryEnvironmentFor(tasks.first.id)!,
      );
      await tester.enterText(search, 'no matching title');
      await tester.pumpAndSettle();
      expect(find.text('No Tasks match your search.'), findsOneWidget);
      expect(shell(tester).task, same(tasks.first));
      expect(runtime.store.tasksFor(project.id), tasks);
      expect(channel.calls, hasLength(2));
      expect(ids.calls, [
        'project',
        'task',
        'environment',
        'task',
        'environment',
      ]);
      expect(tester.takeException(), isNull);
      await disposeApplication(tester);
    },
  );

  for (final (pending, restoreBeforeSettlement) in [
    (false, false),
    (true, false),
    (true, true),
  ]) {
    testWidgets(
      'ambiguous browsers revoke retained controls${pending ? ' during establishment' : ''}${restoreBeforeSettlement ? ' and refresh a new view' : ''}',
      (tester) async {
        registerProvider();
        await mountApplication(tester);
        final project = await openProject(tester);
        await enterTitle(tester, 'Retired presentation');
        final submit = action(tester, 'Create Task');
        if (pending) {
          submit();
          await tester.pump();
          expect(channel.calls, hasLength(1));
        }
        var substituteCalls = 0;
        final duplicate = runtime.extensions.register(
          point: taskBrowserContributions,
          id: ExtensionId('dev.adele.test.duplicate-browser'),
          value: TaskBrowserContribution(
            displayName: 'Duplicate browser',
            createPresentation: (_) {
              substituteCalls++;
              return const Text('Must not substitute a browser');
            },
          ),
        );
        addTearDown(duplicate.close);
        await tester.pumpAndSettle();
        expect(
          find.textContaining('Task Browser is ambiguous'),
          findsOneWidget,
        );
        expect(find.text('New Task'), findsNothing);
        submit();
        await tester.pump();
        if (pending) {
          if (restoreBeforeSettlement) {
            await duplicate.close();
            await tester.pumpAndSettle();
            expect(find.text('Task Browser'), findsOneWidget);
            expect(
              find.widgetWithText(ListTile, 'Retired presentation'),
              findsNothing,
            );
          }
          channel.succeed();
          await tester.pumpAndSettle();
          if (restoreBeforeSettlement) {
            expect(
              find.widgetWithText(ListTile, 'Retired presentation'),
              findsOneWidget,
            );
          }
        }
        expect(substituteCalls, 0);
        expect(shell(tester).project, same(project));
        expect(shell(tester).task, isNull);
        expect(shell(tester).environment, isNull);
        expect(runtime.store.tasksFor(project.id), hasLength(pending ? 1 : 0));
        expect(channel.calls, hasLength(pending ? 1 : 0));
        expect(
          ids.calls,
          pending ? ['project', 'task', 'environment'] : ['project'],
        );
        await duplicate.close();
        await tester.pumpAndSettle();
        expect(find.text('Task Browser'), findsOneWidget);
        expect(find.text('Task title'), findsNothing);
        expect(shell(tester).task, isNull);
        submit();
        await tester.pump();
        expect(channel.calls, hasLength(pending ? 1 : 0));
        expect(tester.takeException(), isNull);
        await disposeApplication(tester);
      },
    );
  }

  testWidgets(
    'pending submission disables controls and rejects retained callbacks',
    (tester) async {
      registerProvider();
      await mountApplication(tester);
      final Project project = await openProject(tester);
      await enterTitle(tester, 'Only one');
      final submit = action(tester, 'Create Task');
      final cancel = tester
          .widget<TextButton>(find.widgetWithText(TextButton, 'Cancel'))
          .onPressed!;
      await tester.tap(find.text('Create Task'));
      submit();
      await tester.pump();
      submit();
      cancel();
      await tester.tap(find.text('Create Task'));
      await tester.pump();

      expect(ids.calls, <String>['project', 'task', 'environment']);
      expect(channel.calls, hasLength(1));
      expectUnpublished(tester, project, 1);
      expect(find.text('Creating Task...'), findsOneWidget);
      expect(actionButton('Create Task'), findsNothing);
      expect(actionButton('Cancel'), findsNothing);
      final TextField field = tester.widget<TextField>(titleField());
      expect(field.enabled, isFalse);
      field.onSubmitted?.call('Duplicate from retained keyboard callback');
      expect(field.controller!.text, 'Only one');
      channel.succeed();
      await tester.pumpAndSettle();
      submit();
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
    await mountApplication(tester);
    final Project project = await openProject(tester);
    await enterTitle(tester, '   ');
    await tester.tap(find.text('Create Task'));
    await tester.pumpAndSettle();
    expect(actionButton('Create Task'), findsNothing);
    tester.widget<TextField>(titleField()).onSubmitted!('\t\n');
    await tester.pump();
    expect(ids.calls, <String>['project']);
    expect(channel.calls, isEmpty);
    expectUnpublished(tester, project, 1);
    expect(runtime.store.tasksFor(project.id), isEmpty);
    expect(shell(tester).task, isNull);
    expect(shell(tester).environment, isNull);
    expect(tester.widget<TextField>(titleField()).controller!.text, '   ');
    expect(tester.takeException(), isNull);
    await disposeApplication(tester);
  });

  testWidgets('cancel abandons the form without allocating identities', (
    tester,
  ) async {
    registerProvider();
    await mountApplication(tester);
    final Project project = await openProject(tester);
    await enterTitle(tester, 'Abandoned title');
    final submit = action(tester, 'Create Task');
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    submit();
    await tester.pump();
    expect(find.text('Task title'), findsNothing);
    expect(actionButton('New Task'), findsOneWidget);
    expectUnpublished(tester, project, 1);
    expect(runtime.store.tasksFor(project.id), isEmpty);
    expect(ids.calls, <String>['project']);
    expect(channel.calls, isEmpty);
    await tester.tap(find.text('New Task'));
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(titleField()).controller!.text, isEmpty);
    expect(tester.takeException(), isNull);
    await disposeApplication(tester);
  });

  testWidgets('failure preserves Project and title for a successful retry', (
    tester,
  ) async {
    registerProvider();
    await mountApplication(tester);
    final Project project = await openProject(tester);
    await enterTitle(tester, '  Retry this title  ');
    await tester.tap(find.text('Create Task'));
    await tester.pump();
    channel.calls.single.result.completeError(
      StateError('establishment failed'),
    );
    await tester.pumpAndSettle();

    expect(
      find.text('Task Browser action could not be completed.'),
      findsOneWidget,
    );
    expect(find.textContaining('establishment failed'), findsNothing);
    expect(find.text('Creating Task...'), findsNothing);
    expectUnpublished(tester, project, 1);
    expect(runtime.store.tasksFor(project.id), isEmpty);
    expect(shell(tester).task, isNull);
    expect(shell(tester).environment, isNull);
    expect(
      tester.widget<TextField>(titleField()).controller!.text,
      '  Retry this title  ',
    );
    expect(actionButton('Create Task'), findsOneWidget);

    await tester.showKeyboard(titleField());
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();
    expect(
      find.text('Task Browser action could not be completed.'),
      findsNothing,
    );
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
    expectBrowserSelection(tester, task, environment);
    expect(find.text('Task title'), findsNothing);
    expect(tester.takeException(), isNull);
    await disposeApplication(tester);
  });

  testWidgets(
    'later failure preserves the previously presented Task and Environment',
    (tester) async {
      registerProvider();
      await mountApplication(tester);
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
      expectBrowserSelection(tester, task, environment);
      expect(
        find.text('Task Browser action could not be completed.'),
        findsOneWidget,
      );
      expect(
        tester.widget<TextField>(titleField()).controller!.text,
        'Second Task',
      );
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(shell(tester).task, same(task));
      expect(shell(tester).environment, same(environment));
      expect(
        find.text('Task Browser action could not be completed.'),
        findsNothing,
      );
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
          await mountApplication(tester);
          final Project project = await openProject(tester);
          await enterTitle(tester, 'Too late');
          final submit = action(tester, 'Create Task');
          final cancel = tester
              .widget<TextButton>(find.widgetWithText(TextButton, 'Cancel'))
              .onPressed!;
          // Keep native exit observers, settlement, and cleanup in one scope.
          await tester.runAsync(() async {
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
            submit();
            cancel();
            await tester.pumpAndSettle();
            // Closing blocks presentation immediately but must drain establishment
            // before retiring runtime-owned resources.
            expect(exitCompleted, isFalse);
            expect(runtime.plugins.state, ApplicationPluginState.ready);
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
              expect(titleField(), findsOneWidget);
            } else {
              expect(find.byType(AdeleShell), findsNothing);
            }
            expect(
              find.text('Task Browser action could not be completed.'),
              findsNothing,
            );
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
              await exiting.timeout(const Duration(seconds: 10));
            } else if (runtime.plugins.state != ApplicationPluginState.closed) {
              await runtime.plugins.changes
                  .firstWhere((state) => state == ApplicationPluginState.closed)
                  .timeout(const Duration(seconds: 10));
            }
            if (exiting != null) {
              expect(await exiting, AppExitResponse.exit);
              expect(exitCompleted, isTrue);
            }
            expect(runtime.plugins.state, ApplicationPluginState.closed);
            submit();
            await tester.pump();

            expect(runtime.store.project(project.id), same(project));
            expect(ids.calls, <String>['project', 'task', 'environment']);
            expect(channel.calls, hasLength(1));
            if (succeeds) {
              // Successful provider settlement survives retirement; only presentation is ignored.
              final Task task = runtime.store.tasksFor(project.id).single;
              final Environment environment = runtime.store
                  .primaryEnvironmentFor(task.id)!;
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
            } else {
              expect(find.byType(AdeleShell), findsNothing);
            }
            expect(find.text('Environment: environment-1'), findsNothing);
            expect(
              find.text('Task Browser action could not be completed.'),
              findsNothing,
            );
            expect(tester.takeException(), isNull);
            await tester.pumpWidget(const SizedBox.shrink());
            await runtime.close();
            expect(runtime.plugins.state, ApplicationPluginState.closed);
            expect(tester.takeException(), isNull);
          });
        },
      );
    }
  }

  testWidgets(
    'empty backend composition opens Project but cannot establish a Task',
    (tester) async {
      await mountApplication(tester);
      final Project project = await openProject(tester);
      expect(runtime.plugins.state, ApplicationPluginState.ready);
      expect(
        runtime.registry.providersFor(environmentProviderCapability),
        isEmpty,
      );
      await enterTitle(tester, 'No provider');
      await tester.tap(find.text('Create Task'));
      await tester.pumpAndSettle();
      expect(
        find.text('Task Browser action could not be completed.'),
        findsOneWidget,
      );
      expect(
        tester.widget<TextField>(titleField()).controller!.text,
        'No provider',
      );
      expectUnpublished(tester, project, 1);
      expect(ids.calls, <String>['project']);
      expect(channel.calls, isEmpty);
      expect(tester.takeException(), isNull);
      await disposeApplication(tester);
    },
  );

  testWidgets(
    'backend startup error opens Project but cannot establish a Task',
    (tester) async {
      await mountApplication(
        tester,
        afterBootstrap: (ApplicationPluginBootstrap plugins) async {
          expect(plugins, same(runtime.plugins));
          throw StateError('backend startup failed');
        },
      );
      final Project project = await openProject(tester);
      await enterTitle(tester, 'Failed startup');
      await tester.tap(find.text('Create Task'));
      await tester.pumpAndSettle();
      expect(
        find.text('Task Browser action could not be completed.'),
        findsOneWidget,
      );
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
      await mountApplication(
        tester,
        afterBootstrap: (ApplicationPluginBootstrap plugins) async {
          bootstraps++;
          expect(plugins.registry, same(runtime.registry));
          await startup.future;
          registerProvider();
        },
      );
      final Project project = await openProject(tester);
      await enterTitle(tester, 'Activated asynchronously');
      startup.complete();
      await tester.pumpAndSettle();
      expect(runtimeCreations, 1);
      expect(bootstraps, 1);
      expect(shell(tester).project, same(project));
      expect(actionButton('New Task'), findsOneWidget);
      expect(
        find.textContaining('Task Environment support is unavailable'),
        findsNothing,
      );
      await tester.tap(find.text('Create Task'));
      await tester.pump();
      channel.succeed();
      await tester.pumpAndSettle();
      expectBrowserSelection(
        tester,
        shell(tester).task!,
        shell(tester).environment!,
      );
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
      await mountApplication(tester);
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
      expectBrowserSelection(
        tester,
        shell(tester).task!,
        shell(tester).environment!,
      );
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
