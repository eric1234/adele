@Timeout(Duration(minutes: 3))
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' show AppExitResponse;

import 'package:adele_capabilities/adele_capabilities.dart';
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
import 'package:plugin_builder/plugin_builder.dart';
import 'package:plugin_runtime/plugin_runtime.dart';

import '../tool/local_directory_project_frontend_compiler.dart';
import 'support/prepared_frontend_installations.dart';
import 'support/project_provider.dart';

const _localDirectoryProjectPluginId =
    'dev.adele.plugin.local-directory-project';

void main() {
  late AdeleRuntime runtime;
  late _RecordingIds ids;
  late Directory temporary;
  late Directory installations;
  late Directory frontendOnly;
  late Directory source;
  late File frontendArtifact;
  late File backendArtifact;
  late String dartaotruntime;
  late _DirectoryPicker picker;
  var preparedMounted = false;

  setUpAll(() async {
    temporary = await Directory.systemTemp.createTemp('adele-project-opening-');
    final repository = Directory.current.parent;
    frontendArtifact = await File('${temporary.path}/frontend.evc')
        .writeAsBytes(
          await compileLocalDirectoryProjectFrontend(
            repositoryRoot: Directory.current.parent,
          ),
        );
    final dart = _dartExecutable();
    dartaotruntime = File.fromUri(
      File(dart).parent.uri.resolve(
        Platform.isWindows ? 'dartaotruntime.exe' : 'dartaotruntime',
      ),
    ).path;
    backendArtifact = File('${temporary.path}/backend.aot');
    for (final (entrypoint, artifact) in [
      (
        'packages/plugin_backend_host/bin/adele_backend_host.dart',
        File('${temporary.path}/host.aot'),
      ),
      (
        'plugins/local_directory_project/packages/backend/bin/local_directory_project_backend.dart',
        backendArtifact,
      ),
    ]) {
      await compileAotSnapshot(
        dartExecutable: dart,
        workingDirectory: repository,
        entrypoint: entrypoint,
        artifact: artifact,
        stage: 'project-opening',
      );
    }
    installations = await prepareFrontendInstallations(
      root: Directory('${temporary.path}/installed'),
      artifacts: {_localDirectoryProjectPluginId: frontendArtifact},
      backendArtifacts: {_localDirectoryProjectPluginId: backendArtifact},
    );
    frontendOnly = await prepareFrontendInstallations(
      root: Directory('${temporary.path}/frontend-only'),
      artifacts: {_localDirectoryProjectPluginId: frontendArtifact},
    );
  });
  tearDownAll(() => temporary.delete(recursive: true));

  setUp(() {
    preparedMounted = false;
    ids = _RecordingIds();
    runtime = AdeleRuntime(ids: ids);
    final directory = Directory.systemTemp.createTempSync(
      'adele-project-source-',
    );
    source = Directory('${directory.path}/Project Name')..createSync();
    addTearDown(() async {
      if (runtime.plugins.state != ApplicationPluginState.closed) {
        await runtime.close();
      }
      directory.deleteSync(recursive: true);
    });
    final original = FileSelectorPlatform.instance;
    FileSelectorPlatform.instance = picker = _DirectoryPicker();
    addTearDown(() => FileSelectorPlatform.instance = original);
  });

  Future<void> mountPreparedSelector(
    WidgetTester tester, {
    AdeleRuntime Function()? createRuntime,
    Directory? installationRoot,
    bool hasBackend = true,
  }) async {
    preparedMounted = true;
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
            installationRoot: (installationRoot ?? installations).path,
            dartaotruntimeExecutable: dartaotruntime,
            hostArtifactPath: '${temporary.path}/host.aot',
          ),
        ),
      );
      await starting;
      expect(runtime.plugins.state, ApplicationPluginState.ready);
      await registered.timeout(const Duration(seconds: 10));
    });
    await tester.pumpAndSettle();
    expect(runtime.plugins.state, ApplicationPluginState.ready);
    expect(runtime.plugins.host, hasBackend ? isNotNull : isNull);
    expect(runtime.plugins.backends, hasLength(hasBackend ? 1 : 0));
    if (hasBackend) {
      expect(
        runtime.plugins.backends.single.state,
        InstalledBackendState.active,
      );
    }
    expect(runtime.plugins.catalog!.issues, isEmpty);
    expect(runtime.plugins.catalog!.installations, hasLength(1));
    expect(
      runtime.plugins.catalog!.installations.single.metadata.id.value,
      _localDirectoryProjectPluginId,
    );
    expect(
      runtime.extensions.discover(projectSelectorContributions).single.id.value,
      'dev.adele.plugin.local-directory-project.project-selector',
    );
    expect(find.text('Open Local Directory...'), findsOneWidget);
    expect(
      picker.calls,
      0,
      reason: 'Activation must not invoke the native picker.',
    );
  }

  ExtensionRegistration registerSelector(
    Future<Uri?> Function() select, {
    ProviderId? providerId,
  }) {
    final ExtensionRegistration registration = runtime.extensions.register(
      point: projectSelectorContributions,
      id: ExtensionId('dev.adele.test.project-selector'),
      value: ProjectSelectorContribution(
        displayName: 'Open Test Source...',
        projectProviderId: providerId ?? testProjectProviderId,
        selectProject: select,
      ),
    );
    // This test owns its additional contribution, not the stock runtime.
    addTearDown(registration.close);
    return registration;
  }

  TestProjectProvider registerProvider({
    ProviderId? providerId,
    String pluginId = 'dev.adele.plugin.test-project',
    Future<ProjectBacking> Function(Uri)? prepare,
  }) {
    final provider = TestProjectProvider(
      runtime.registry,
      providerId: providerId,
      pluginId: pluginId,
      prepare: prepare,
    );
    addTearDown(provider.close);
    return provider;
  }

  Future<void> settleOpening(WidgetTester tester) async {
    await tester.runAsync(() async {
      final deadline = DateTime.now().add(const Duration(seconds: 10));
      await tester.pump();
      while (find.text('Selecting Project...').evaluate().isNotEmpty &&
          DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
        await tester.pump();
      }
      expect(find.text('Selecting Project...'), findsNothing);
    });
    await tester.pumpAndSettle();
  }

  Future<void> disposeApplication(WidgetTester tester) async {
    Future<void> dispose() async {
      await tester.pumpWidget(const SizedBox.shrink());
      await runtime.close();
    }

    // Prepared startup and child-process shutdown run outside fake async; public
    // fixtures keep their completed bootstrap futures in the widget test zone.
    if (preparedMounted) {
      await tester.runAsync(dispose);
    } else {
      await dispose();
    }
    await tester.pumpAndSettle();
  }

  void expectNoProject(WidgetTester tester) {
    expect(runtime.store.project(ProjectId('selected-1')), isNull);
    expect(tester.widget<AdeleShell>(find.byType(AdeleShell)).project, isNull);
    expect(find.text('No Project is open'), findsOneWidget);
    expect(find.text('Project is open'), findsNothing);
    expect(tester.takeException(), isNull);
  }

  for (final native in [true, false]) {
    testWidgets(
      'opens one durable Project and retains it: ${native ? 'prepared' : 'public'} selector',
      (WidgetTester tester) async {
        int selections = 0;
        int runtimeCreations = 0;
        final Uri uri = source.uri;
        if (native) {
          picker.pick = () async {
            selections++;
            return '${source.parent.path}/./Project Name/';
          };
        } else {
          registerProvider();
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
          await tester.pumpWidget(
            AdeleApplication(createRuntime: createRuntime),
          );
          expect(find.text('Open Local Directory...'), findsNothing);
        }
        expect(ids.calls, isEmpty);

        await tester.tap(
          find.text(native ? 'Open Local Directory...' : 'Open Test Source...'),
        );
        await settleOpening(tester);

        final Project project = tester
            .widget<AdeleShell>(find.byType(AdeleShell))
            .project!;
        expect(project.id, ProjectId('selected-1'));
        expect(project.sourceLocation, uri);
        expect(runtime.store.project(project.id), same(project));
        expect(
          File.fromUri(
            source.uri.resolve(
              native
                  ? '.adele/data.db'
                  : TestProjectProvider.databaseRelativePath,
            ),
          ).existsSync(),
          isTrue,
        );
        expect(ids.calls, <String>['project']);
        expect(selections, 1);
        expect(picker.calls, native ? 1 : 0);
        expect(find.text('No Project is open'), findsNothing);
        expect(find.text('Open Test Source...'), findsNothing);
        expect(find.text('Project Name'), findsOneWidget);
        expect(find.text(uri.toString()), findsOneWidget);
        expect(find.text('Project is open'), findsOneWidget);
        expect(find.text('No Task selected'), findsOneWidget);
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
        expect(find.text('No Task selected'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await disposeApplication(tester);
      },
    );
  }

  testWidgets(
    'prepared selector reopens persisted identity after application restart',
    (tester) async {
      picker.pick = () async => source.path;
      await mountPreparedSelector(tester);
      await tester.tap(find.text('Open Local Directory...'));
      await settleOpening(tester);
      final original = tester
          .widget<AdeleShell>(find.byType(AdeleShell))
          .project!;
      await disposeApplication(tester);

      ids = _RecordingIds()..failProject = true;
      runtime = AdeleRuntime(ids: ids);
      picker.calls = 0;
      await mountPreparedSelector(tester);
      await tester.tap(find.text('Open Local Directory...'));
      await settleOpening(tester);
      final reopened = tester
          .widget<AdeleShell>(find.byType(AdeleShell))
          .project!;
      expect(reopened.id, original.id);
      expect(reopened.sourceLocation, original.sourceLocation);
      expect(reopened, isNot(same(original)));
      expect(runtime.store.project(reopened.id), same(reopened));
      expect(ids.calls, isEmpty);
      expect(find.text('Project is open'), findsOneWidget);
      await disposeApplication(tester);
    },
  );

  testWidgets('no selectors renders an unavailable state', (tester) async {
    await tester.pumpWidget(AdeleApplication(createRuntime: () => runtime));

    expectNoProject(tester);
    expect(find.text('No Project selectors are available.'), findsOneWidget);
    expect(find.byType(FilledButton), findsNothing);
    expect(ids.calls, isEmpty);
    await disposeApplication(tester);
  });

  testWidgets(
    'missing named provider does not invoke a selector or fall back',
    (tester) async {
      final other = registerProvider(
        providerId: ProviderId('dev.adele.project.other'),
      );
      var selections = 0;
      registerSelector(() async {
        selections++;
        return source.uri;
      });
      await tester.pumpWidget(AdeleApplication(createRuntime: () => runtime));
      await tester.tap(find.text('Open Test Source...'));
      await tester.pumpAndSettle();

      expectNoProject(tester);
      expect(find.textContaining('Could not open Project:'), findsOneWidget);
      expect(selections, 0);
      expect(other.calls, isEmpty);
      expect(ids.calls, isEmpty);
      expect(source.listSync(), isEmpty);
      await disposeApplication(tester);
    },
  );

  testWidgets('non-local backing is unsupported, not a volatile Project', (
    tester,
  ) async {
    final provider = registerProvider();
    final uri = Uri.parse(
      'catalog://team/Project%20Name?revision=stable#details',
    );
    registerSelector(() async => uri);
    await tester.pumpWidget(AdeleApplication(createRuntime: () => runtime));
    await tester.tap(find.text('Open Test Source...'));
    await tester.pumpAndSettle();

    expectNoProject(tester);
    expect(provider.calls, [uri]);
    expect(ids.calls, isEmpty);
    expect(source.listSync(), isEmpty);
    expect(find.textContaining('Could not open Project:'), findsOneWidget);
    await disposeApplication(tester);
  });

  testWidgets('cancellation never invokes source preparation', (tester) async {
    final provider = registerProvider();
    var selections = 0;
    registerSelector(() async {
      selections++;
      return null;
    });
    await tester.pumpWidget(AdeleApplication(createRuntime: () => runtime));
    for (var invocation = 0; invocation < 2; invocation++) {
      await tester.tap(find.text('Open Test Source...'));
      await tester.pumpAndSettle();
      expectNoProject(tester);
      expect(find.textContaining('Could not open Project:'), findsNothing);
    }
    expect(selections, 2);
    expect(provider.calls, isEmpty);
    expect(ids.calls, isEmpty);
    expect(source.listSync(), isEmpty);
    await disposeApplication(tester);
  });

  for (final spoof in [false, true]) {
    testWidgets(
      'prepared frontend without backend rejects ${spoof ? 'same-PluginId provider spoof' : 'missing provider'}',
      (tester) async {
        final provider = spoof
            ? registerProvider(
                providerId: ProviderId('dev.adele.project.local-directory'),
                pluginId: _localDirectoryProjectPluginId,
              )
            : null;
        await mountPreparedSelector(
          tester,
          installationRoot: frontendOnly,
          hasBackend: false,
        );
        await tester.tap(find.text('Open Local Directory...'));
        await tester.pumpAndSettle();
        expectNoProject(tester);
        expect(find.textContaining('Could not open Project:'), findsOneWidget);
        expect(picker.calls, 0);
        expect(provider?.calls ?? [], isEmpty);
        expect(ids.calls, isEmpty);
        expect(source.listSync(), isEmpty);
        await disposeApplication(tester);
      },
    );
  }

  testWidgets(
    'active owning backend rejects an unrelated provider registration',
    (tester) async {
      final provider = registerProvider(
        pluginId: _localDirectoryProjectPluginId,
      );
      late Directory root;
      await tester.runAsync(() async {
        root = await prepareFrontendInstallations(
          root: Directory('${source.parent.path}/wrong-provider'),
          artifacts: {_localDirectoryProjectPluginId: frontendArtifact},
          backendArtifacts: {_localDirectoryProjectPluginId: backendArtifact},
        );
        final manifest = File(
          '${root.path}/$_localDirectoryProjectPluginId/adele_plugin.installation.json',
        );
        final data =
            jsonDecode(await manifest.readAsString()) as Map<String, dynamic>;
        data['components']['frontend']['extensions'][0]['projectProviderId'] =
            provider.providerId.value;
        await manifest.writeAsString(jsonEncode(data));
      });
      await mountPreparedSelector(tester, installationRoot: root);
      expect(
        runtime.registry.providersFor(projectProviderCapability),
        hasLength(2),
      );
      await tester.tap(find.text('Open Local Directory...'));
      await tester.pumpAndSettle();

      expectNoProject(tester);
      expect(
        find.textContaining('provider does not belong to the owning backend'),
        findsOneWidget,
      );
      expect(provider.calls, isEmpty);
      expect(picker.calls, 0);
      expect(ids.calls, isEmpty);
      expect(source.listSync(), isEmpty);
      await disposeApplication(tester);
    },
  );

  test(
    'owning backend requires the exact shared installation snapshot',
    () async {
      await runtime.plugins.start(
        installationRoot: installations.path,
        dartaotruntimeExecutable: dartaotruntime,
        hostArtifactPath: '${temporary.path}/host.aot',
      );
      final frontends = ApplicationFrontendBootstrap(
        extensions: runtime.extensions,
      );
      addTearDown(frontends.close);
      final otherSnapshot = await PreparedPluginCatalog.discover(
        installations.path,
      );
      await frontends.start(otherSnapshot);
      final selector = runtime.extensions
          .discover(projectSelectorContributions)
          .single;
      final provider = runtime.lifecycle.resolveProjectProvider(
        selector.value.projectProviderId,
      );
      expect(
        otherSnapshot.installations.single.metadata.id,
        runtime.plugins.catalog!.installations.single.metadata.id,
      );
      expect(
        otherSnapshot.installations.single,
        isNot(same(runtime.plugins.catalog!.installations.single)),
      );
      expect(
        () => frontends.validateProjectProvider(
          selector,
          provider,
          runtime.plugins,
        ),
        throwsStateError,
      );
      expect(picker.calls, 0);
      expect(ids.calls, isEmpty);
      expect(source.listSync(), isEmpty);
    },
  );

  testWidgets(
    'backend replacement during native picking cannot rebind the operation',
    (tester) async {
      final selection = Completer<String?>();
      picker.pick = () => selection.future;
      await mountPreparedSelector(tester);
      final providerId = runtime.extensions
          .discover(projectSelectorContributions)
          .single
          .value
          .projectProviderId;
      final captured = runtime.lifecycle.resolveProjectProvider(providerId);
      await tester.tap(find.text('Open Local Directory...'));
      await tester.pump();
      expect(picker.calls, 1);
      await tester.runAsync(() async {
        final retired = runtime.plugins.changes.firstWhere(
          (_) =>
              runtime.registry.providersFor(projectProviderCapability).isEmpty,
        );
        await runtime.plugins.backends.single.connection!.close();
        await retired.timeout(const Duration(seconds: 10));
      });
      final replacement = registerProvider(
        providerId: providerId,
        pluginId: _localDirectoryProjectPluginId,
      );
      selection.complete(source.path);
      await tester.pumpAndSettle();

      expectNoProject(tester);
      expect(
        () => captured.endpointAs<CapabilityEndpoint>(),
        throwsA(isA<ProviderUnavailable>()),
      );
      expect(find.textContaining('Could not open Project:'), findsOneWidget);
      expect(replacement.calls, isEmpty);
      expect(ids.calls, isEmpty);
      expect(source.listSync(), isEmpty);
      await disposeApplication(tester);
    },
  );

  for (final replace in [false, true]) {
    testWidgets(
      'provider ${replace ? 'replacement' : 'retirement'} during selection cannot rebind or publish',
      (tester) async {
        final selection = Completer<Uri?>();
        final provider = registerProvider();
        registerSelector(() => selection.future);
        await tester.pumpWidget(AdeleApplication(createRuntime: () => runtime));
        await tester.tap(find.text('Open Test Source...'));
        await tester.pump();
        expect(find.text('Selecting Project...'), findsOneWidget);
        await provider.registration.close();
        final replacement = replace ? registerProvider() : null;
        selection.complete(source.uri);
        await tester.pumpAndSettle();

        expectNoProject(tester);
        expect(find.textContaining('Could not open Project:'), findsOneWidget);
        expect(provider.calls, isEmpty);
        expect(replacement?.calls ?? [], isEmpty);
        expect(ids.calls, isEmpty);
        expect(source.listSync(), isEmpty);
        await disposeApplication(tester);
      },
    );
  }

  for (final retireProvider in [false, true]) {
    testWidgets(
      '${retireProvider ? 'provider' : 'selector'} retirement during preparation rejects late backing',
      (tester) async {
        final prepared = Completer<ProjectBacking>();
        final provider = registerProvider(prepare: (_) => prepared.future);
        final selector = registerSelector(() async => source.uri);
        await tester.pumpWidget(AdeleApplication(createRuntime: () => runtime));
        await tester.tap(find.text('Open Test Source...'));
        await tester.pump();
        expect(provider.calls, [source.uri]);
        expect(ids.calls, isEmpty);
        if (retireProvider) {
          await provider.registration.close();
          registerProvider();
        } else {
          await selector.close();
          registerSelector(
            () async => throw StateError('No selector fallback'),
          );
        }
        prepared.complete(
          ProjectBacking(
            sourceLocation: source.uri,
            databaseRelativePath: TestProjectProvider.databaseRelativePath,
          ),
        );
        await tester.pumpAndSettle();

        expectNoProject(tester);
        expect(find.textContaining('Could not open Project:'), findsOneWidget);
        expect(provider.calls, hasLength(1));
        expect(ids.calls, isEmpty);
        expect(source.listSync(), isEmpty);
        await disposeApplication(tester);
      },
    );
  }

  testWidgets('cancellation is a no-op and permits another invocation', (
    tester,
  ) async {
    await mountPreparedSelector(tester);

    for (int invocation = 0; invocation < 2; invocation++) {
      await tester.tap(find.text('Open Local Directory...'));
      await tester.pumpAndSettle();
      expectNoProject(tester);
      expect(ids.calls, isEmpty);
      expect(source.listSync(), isEmpty);
      expect(find.textContaining('Could not open Project'), findsNothing);
      expect(find.text('Selecting Project...'), findsNothing);
    }
    expect(picker.calls, 2);
    await disposeApplication(tester);
  });

  testWidgets(
    'selector error does not create a Project or substitute a selector',
    (tester) async {
      int fallbackCalls = 0;
      await mountPreparedSelector(tester);
      final fallbackProvider = registerProvider();
      registerSelector(() async {
        fallbackCalls++;
        return source.uri;
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
      expect(fallbackProvider.calls, isEmpty);
      expect(picker.calls, 1);
      await disposeApplication(tester);
    },
  );

  testWidgets('lifecycle failure preserves the pre-Project state', (
    tester,
  ) async {
    ids.failProject = true;
    registerProvider();
    registerSelector(() async => source.uri);
    await tester.pumpWidget(AdeleApplication(createRuntime: () => runtime));
    await tester.tap(find.text('Open Test Source...'));
    await tester.pumpAndSettle();

    expectNoProject(tester);
    expect(ids.calls, <String>['project']);
    expect(find.textContaining('Project creation failed'), findsOneWidget);
    await disposeApplication(tester);
  });

  testWidgets(
    'pending selection disables actions and rejects duplicate invocation',
    (tester) async {
      final selection = Completer<String?>();
      picker.pick = () => selection.future;
      await mountPreparedSelector(tester);
      await tester.runAsync(() async {
        registerProvider();
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
      selection.complete(source.path);
      await settleOpening(tester);
      expect(ids.calls, <String>['project']);
      expect(find.text('No Task selected'), findsOneWidget);
      await disposeApplication(tester);
    },
  );

  testWidgets('retired selector cannot publish an in-flight result', (
    tester,
  ) async {
    final selection = Completer<Uri?>();
    final provider = registerProvider();
    final registration = registerSelector(() => selection.future);
    await tester.pumpWidget(AdeleApplication(createRuntime: () => runtime));
    final selector = runtime.extensions
        .discover(projectSelectorContributions)
        .single;
    await tester.tap(find.text('Open Test Source...'));
    await tester.pump();
    await registration.close();
    await tester.pump();
    expect(find.text('Open Test Source...'), findsNothing);
    expect(find.text('No Project selectors are available.'), findsOneWidget);
    selection.complete(source.uri);
    await tester.pumpAndSettle();

    expectNoProject(tester);
    expect(ids.calls, isEmpty);
    expect(selector.validate, throwsA(isA<StaleExtensionBinding>()));
    expect(find.textContaining('Could not open Project:'), findsOneWidget);
    expect(provider.calls, isEmpty);
    expect(source.listSync(), isEmpty);
    await disposeApplication(tester);
  });

  for (final bool exit in <bool>[false, true]) {
    testWidgets(
      'late preparation after ${exit ? 'exit' : 'disposal'} drains without opening a database',
      (tester) async {
        final prepared = Completer<ProjectBacking>();
        final provider = registerProvider(prepare: (_) => prepared.future);
        final backing = ProjectBacking(
          sourceLocation: source.uri,
          databaseRelativePath: TestProjectProvider.databaseRelativePath,
        );
        try {
          registerSelector(() async => source.uri);
          await tester.pumpWidget(
            AdeleApplication(createRuntime: () => runtime),
          );
          await tester.tap(find.text('Open Test Source...'));
          await tester.pump();
          expect(provider.calls, [source.uri]);
          Future<AppExitResponse>? exiting;
          if (exit) {
            exiting = tester.binding.handleRequestAppExit();
          } else {
            await tester.pumpWidget(const SizedBox.shrink());
          }
          await tester.pump();
          expect(runtime.plugins.state, ApplicationPluginState.closed);
          expect(prepared.isCompleted, isFalse);
          expect(ids.calls, isEmpty);
          prepared.complete(backing);
          await tester.pumpAndSettle();
          if (exiting != null) expect(await exiting, AppExitResponse.exit);
          expect(runtime.plugins.state, ApplicationPluginState.closed);
          expect(runtime.store.project(ProjectId('selected-1')), isNull);
          expect(ids.calls, isEmpty);
          expect(source.listSync(), isEmpty);
          expect(find.textContaining('Could not open Project:'), findsNothing);
          expect(tester.takeException(), isNull);
        } finally {
          // Release the provider inside fake async even when an assertion fails.
          if (!prepared.isCompleted) prepared.complete(backing);
          await tester.pumpAndSettle();
          await disposeApplication(tester);
        }
      },
      timeout: const Timeout(Duration(seconds: 30)),
    );

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
        selection.complete(source.path);
        await tester.pumpAndSettle();

        expect(ids.calls, isEmpty);
        expect(runtime.store.project(ProjectId('selected-1')), isNull);
        expect(selector.validate, throwsA(isA<StaleExtensionBinding>()));
        expect(picker.calls, 1);
        expect(tester.takeException(), isNull);
        await disposeApplication(tester);
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

String _dartExecutable() {
  final flutterRoot = Platform.environment['FLUTTER_ROOT'];
  if (flutterRoot != null) {
    final executable = File.fromUri(
      Directory(flutterRoot).uri.resolve(
        'bin/cache/dart-sdk/bin/${Platform.isWindows ? 'dart.exe' : 'dart'}',
      ),
    );
    if (executable.existsSync()) return executable.path;
  }
  final executable = File(Platform.resolvedExecutable);
  if (executable.parent.path.endsWith(
    '${Platform.pathSeparator}dart-sdk${Platform.pathSeparator}bin',
  )) {
    return executable.path;
  }
  throw StateError('Unable to locate the Dart SDK executable for AOT tests.');
}
