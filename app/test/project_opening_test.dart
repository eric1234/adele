import 'dart:async';
import 'dart:io';
import 'dart:ui' show AppExitResponse;

import 'package:adele_core_extensions/adele_core_extensions.dart';
import 'package:adele_desktop/application.dart';
import 'package:adele_desktop/core/adele_runtime.dart';
import 'package:adele_desktop/core/application_plugin_bootstrap.dart';
import 'package:adele_desktop/core/product_lifecycle.dart';
import 'package:adele_desktop/frontend/application_frontend_bootstrap.dart';
import 'package:adele_desktop/ui/shell/adele_shell.dart';
import 'package:adele_environment/adele_environment.dart';
import 'package:adele_model_provider/adele_model_provider.dart';
import 'package:adele_plugin_api/adele_plugin_api.dart';
import 'package:adele_product/adele_product.dart';
import 'package:file_selector_platform_interface/file_selector_platform_interface.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plugin_runtime/plugin_runtime.dart';

import '../tool/local_directory_frontend_compiler.dart';
import 'support/prepared_frontend_installations.dart';

const _selectorPluginId = 'dev.adele.plugin.local-directory-project-selector';

void main() {
  late AdeleRuntime runtime;
  late _RecordingIds ids;
  late Directory temporary;
  late Directory installations;
  late _DirectoryPicker picker;

  setUpAll(() async {
    temporary = await Directory.systemTemp.createTemp('adele-project-opening-');
    final artifact = await File('${temporary.path}/selector.evc').writeAsBytes(
      await compileLocalDirectoryFrontend(
        repositoryRoot: Directory.current.parent,
      ),
    );
    installations = await prepareFrontendInstallations(
      root: Directory('${temporary.path}/installed'),
      artifacts: {_selectorPluginId: artifact},
    );
  });
  tearDownAll(() => temporary.delete(recursive: true));

  setUp(() {
    ids = _RecordingIds();
    runtime = AdeleRuntime(ids: ids);
    final original = FileSelectorPlatform.instance;
    FileSelectorPlatform.instance = picker = _DirectoryPicker();
    addTearDown(() => FileSelectorPlatform.instance = original);
  });

  Future<void> mountPreparedSelector(
    WidgetTester tester, {
    AdeleRuntime Function()? createRuntime,
  }) async {
    await tester.runAsync(() async {
      final registered = runtime.extensions.changes.firstWhere(
        (_) => runtime.extensions
            .discover(projectSelectorContributions)
            .isNotEmpty,
      );
      late Future<void> starting;
      await tester.pumpWidget(
        AdeleApplication(
          createRuntime: createRuntime ?? () => runtime,
          bootstrapPlugins: (plugins) => starting = plugins.start(
            installationRoot: installations.path,
            dartaotruntimeExecutable: '${temporary.path}/missing-runtime',
            hostArtifactPath: '${temporary.path}/missing-host.aot',
          ),
        ),
      );
      await starting;
      expect(runtime.plugins.state, ApplicationPluginState.ready);
      expect(
        runtime.extensions.discover(projectSelectorContributions),
        isEmpty,
      );
      // Render the settled backend state before asynchronous EVC registration.
      await tester.pump();
      expect(find.text('No Project selectors are available.'), findsOneWidget);
      await registered.timeout(const Duration(seconds: 10));
    });
    await tester.pumpAndSettle();
    expect(runtime.plugins.state, ApplicationPluginState.ready);
    expect(runtime.plugins.host, isNull);
    expect(runtime.plugins.backends, isEmpty);
    expect(runtime.plugins.catalog!.issues, isEmpty);
    expect(runtime.plugins.catalog!.installations, hasLength(1));
    expect(find.text('Open Local Directory...'), findsOneWidget);
    expect(
      picker.calls,
      0,
      reason: 'Activation must not invoke the native picker.',
    );
  }

  ExtensionRegistration registerSelector(Future<Uri?> Function() select) {
    final ExtensionRegistration registration = runtime.extensions.register(
      point: projectSelectorContributions,
      id: ExtensionId('dev.adele.test.project-selector'),
      value: ProjectSelectorContribution(
        displayName: 'Open Test Source...',
        selectProject: select,
      ),
    );
    // This test owns its additional contribution, not the stock runtime.
    addTearDown(registration.close);
    return registration;
  }

  void expectNoProject(WidgetTester tester) {
    expect(runtime.store.project(ProjectId('selected-1')), isNull);
    expect(tester.widget<AdeleShell>(find.byType(AdeleShell)).project, isNull);
    expect(find.text('No Project is open'), findsOneWidget);
    expect(find.text('Project is open'), findsNothing);
    expect(tester.takeException(), isNull);
  }

  for (final String source in <String>[
    'file:///source/Project%20Name/',
    'catalog://team/Project%20Name?revision=stable#details',
  ]) {
    testWidgets('opens one canonical Project and retains it: $source', (
      WidgetTester tester,
    ) async {
      int selections = 0;
      int runtimeCreations = 0;
      final Uri uri = Uri.parse(source);
      final native = uri.scheme == 'file';
      if (native) {
        picker.pick = () async {
          selections++;
          return '/source/./Project Name/';
        };
      } else {
        registerSelector(() async {
          selections++;
          return uri;
        });
      }
      AdeleRuntime createRuntime() {
        runtimeCreations++;
        return runtime;
      }

      if (native) {
        await mountPreparedSelector(tester, createRuntime: createRuntime);
      } else {
        await tester.pumpWidget(AdeleApplication(createRuntime: createRuntime));
        expect(find.text('Open Local Directory...'), findsNothing);
      }
      expect(ids.calls, isEmpty);

      await tester.tap(
        find.text(native ? 'Open Local Directory...' : 'Open Test Source...'),
      );
      await tester.pumpAndSettle();

      final Project project = tester
          .widget<AdeleShell>(find.byType(AdeleShell))
          .project!;
      expect(project.id, ProjectId('selected-1'));
      expect(project.sourceLocation, uri);
      expect(runtime.store.project(project.id), same(project));
      expect(ids.calls, <String>['project']);
      expect(selections, 1);
      expect(picker.calls, native ? 1 : 0);
      expect(find.text('No Project is open'), findsNothing);
      expect(find.text('Open Test Source...'), findsNothing);
      expect(find.text('Project Name'), findsOneWidget);
      expect(find.text(uri.toString()), findsOneWidget);
      expect(find.text('Project is open'), findsOneWidget);
      expect(find.text('No Tasks yet'), findsOneWidget);
      expect(runtime.store.tasksFor(project.id), isEmpty);
      expect(
        runtime.registry.providersFor(environmentProviderCapability),
        isEmpty,
      );
      expect(runtime.registry.providersFor(modelProviderCapability), isEmpty);

      await tester.pumpWidget(AdeleApplication(createRuntime: createRuntime));
      expect(runtimeCreations, 1);
      expect(
        tester.widget<AdeleShell>(find.byType(AdeleShell)).project,
        same(project),
      );
      expect(ids.calls, <String>['project']);
      await tester.binding.setSurfaceSize(const Size(360, 640));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pump();
      expect(find.text('No Tasks yet'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    });
  }

  testWidgets('no selectors renders an unavailable state', (tester) async {
    await tester.pumpWidget(AdeleApplication(createRuntime: () => runtime));

    expectNoProject(tester);
    expect(find.text('No Project selectors are available.'), findsOneWidget);
    expect(find.byType(FilledButton), findsNothing);
    expect(ids.calls, isEmpty);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('cancellation is a no-op and permits another invocation', (
    tester,
  ) async {
    await mountPreparedSelector(tester);

    for (int invocation = 0; invocation < 2; invocation++) {
      await tester.tap(find.text('Open Local Directory...'));
      await tester.pumpAndSettle();
      expectNoProject(tester);
      expect(ids.calls, isEmpty);
      expect(find.textContaining('Could not open Project'), findsNothing);
      expect(find.text('Selecting Project...'), findsNothing);
    }
    expect(picker.calls, 2);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'selector error does not create a Project or substitute a selector',
    (tester) async {
      int fallbackCalls = 0;
      await mountPreparedSelector(tester);
      registerSelector(() async {
        fallbackCalls++;
        return Uri.parse('catalog://fallback/');
      });
      picker.pick = () async => throw StateError('picker failed');
      await tester.pump();
      await tester.tap(find.text('Open Local Directory...'));
      await tester.pumpAndSettle();

      expectNoProject(tester);
      expect(ids.calls, isEmpty);
      expect(
        find.textContaining('Could not open Project: Bad state: picker failed'),
        findsOneWidget,
      );
      expect(find.text('Open Test Source...'), findsOneWidget);
      expect(fallbackCalls, 0);
      expect(picker.calls, 1);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('lifecycle failure preserves the pre-Project state', (
    tester,
  ) async {
    ids.failProject = true;
    registerSelector(() async => Uri.parse('file:///source/'));
    await tester.pumpWidget(AdeleApplication(createRuntime: () => runtime));
    await tester.tap(find.text('Open Test Source...'));
    await tester.pumpAndSettle();

    expectNoProject(tester);
    expect(ids.calls, <String>['project']);
    expect(find.textContaining('Project creation failed'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'pending selection disables actions and rejects duplicate invocation',
    (tester) async {
      final selection = Completer<String?>();
      picker.pick = () => selection.future;
      await mountPreparedSelector(tester);
      await tester.runAsync(() async {
        registerSelector(
          () async => throw StateError('Must not invoke a second selector'),
        );
      });
      await tester.pumpAndSettle();
      expect(
        tester.getTopLeft(find.text('Open Local Directory...')).dy,
        lessThan(tester.getTopLeft(find.text('Open Test Source...')).dy),
      );
      await tester.tap(find.text('Open Local Directory...'));
      await tester.tap(find.text('Open Local Directory...'));
      await tester.pump();

      expect(picker.calls, 1);
      expect(ids.calls, isEmpty);
      expect(find.text('Selecting Project...'), findsOneWidget);
      for (final FilledButton button in tester.widgetList<FilledButton>(
        find.byType(FilledButton),
      )) {
        expect(button.onPressed, isNull);
      }
      selection.complete('/source/');
      await tester.pumpAndSettle();
      expect(ids.calls, <String>['project']);
      expect(find.text('No Tasks yet'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('retired selector cannot publish an in-flight result', (
    tester,
  ) async {
    final selection = Completer<String?>();
    picker.pick = () => selection.future;
    final frontends = ApplicationFrontendBootstrap(
      extensions: runtime.extensions,
    );
    addTearDown(frontends.close);
    await tester.runAsync(() async {
      await frontends.start(
        await PreparedPluginCatalog.discover(installations.path),
      );
    });
    await tester.pumpWidget(AdeleApplication(createRuntime: () => runtime));
    final selector = runtime.extensions
        .discover(projectSelectorContributions)
        .single;
    await tester.tap(find.text('Open Local Directory...'));
    await tester.pump();
    await frontends.generations.single.retire(
      projectSelectorContributions,
      selector.id,
    );
    await tester.pump();
    expect(find.text('Open Local Directory...'), findsNothing);
    expect(find.text('No Project selectors are available.'), findsOneWidget);
    selection.complete('/source/');
    await tester.pumpAndSettle();

    expectNoProject(tester);
    expect(ids.calls, isEmpty);
    expect(selector.validate, throwsA(isA<StaleExtensionBinding>()));
    expect(find.textContaining('Could not open Project:'), findsOneWidget);
    expect(picker.calls, 1);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  for (final bool exit in <bool>[false, true]) {
    testWidgets(
      'late selection after ${exit ? 'exit' : 'disposal'} is ignored',
      (tester) async {
        final selection = Completer<String?>();
        picker.pick = () => selection.future;
        await mountPreparedSelector(tester);
        final selector = runtime.extensions
            .discover(projectSelectorContributions)
            .single;
        await tester.tap(find.text('Open Local Directory...'));
        await tester.pump();

        if (exit) {
          expect(
            await tester.runAsync(tester.binding.handleRequestAppExit),
            AppExitResponse.exit,
          );
        } else {
          await tester.runAsync(() async {
            final retired = runtime.extensions.changes.firstWhere(
              (_) => runtime.extensions
                  .discover(projectSelectorContributions)
                  .isEmpty,
            );
            await tester.pumpWidget(const SizedBox.shrink());
            await retired.timeout(const Duration(seconds: 10));
          });
        }
        await tester.pump();
        expect(selection.isCompleted, isFalse);
        expect(runtime.plugins.state, ApplicationPluginState.closed);
        selection.complete('/source/');
        await tester.pumpAndSettle();

        expect(ids.calls, isEmpty);
        expect(runtime.store.project(ProjectId('selected-1')), isNull);
        expect(selector.validate, throwsA(isA<StaleExtensionBinding>()));
        expect(picker.calls, 1);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }
}

final class _DirectoryPicker extends FileSelectorPlatform {
  int calls = 0;
  Future<String?> Function() pick = () async => null;

  @override
  Future<String?> getDirectoryPathWithOptions(FileDialogOptions options) {
    calls++;
    return pick();
  }
}

final class _RecordingIds implements ProductIdSource {
  final List<String> calls = <String>[];
  bool failProject = false;

  @override
  ProjectId nextProjectId() {
    calls.add('project');
    if (failProject) throw StateError('Project creation failed');
    return ProjectId('selected-${calls.length}');
  }

  @override
  TaskId nextTaskId() => throw StateError('Must not create a Task');

  @override
  EnvironmentId nextEnvironmentId() =>
      throw StateError('Must not create an Environment');

  @override
  SessionId nextSessionId() => throw StateError('Must not create a Session');
}
