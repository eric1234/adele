import 'dart:convert';
import 'dart:io';
import 'dart:ui' show AppExitResponse;

import 'package:adele_capabilities/adele_capabilities.dart';
import 'package:adele_contract/adele_contract.dart';
import 'package:adele_core_extensions/adele_core_extensions.dart';
import 'package:adele_desktop/application.dart';
import 'package:adele_desktop/core/adele_runtime.dart';
import 'package:adele_desktop/core/application_plugin_bootstrap.dart';
import 'package:adele_desktop/main.dart' as application;
import 'package:adele_desktop/ui/session/session_presentation_host.dart';
import 'package:adele_desktop/ui/shell/adele_shell.dart';
import 'package:adele_environment/adele_environment.dart';
import 'package:adele_model_provider/adele_model_provider.dart';
import 'package:adele_model_tool/adele_model_tool.dart';
import 'package:adele_orchestration/adele_orchestration.dart';
import 'package:adele_plugin_api/adele_plugin_api.dart';
import 'package:adele_product/adele_product.dart';
import 'package:adele_ui/adele_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plugin_runtime/plugin_runtime.dart';

import '../../tools/stock_frontend_descriptors.dart';
import 'support/project_provider.dart';

void main() {
  for (final bool missing in [false, true]) {
    testWidgets(
      '${missing ? 'missing' : 'empty'} installation root boots without plugins and accepts a later selector',
      (WidgetTester tester) async {
        final Directory directory = Directory.systemTemp.createTempSync(
          'adele-empty-application-',
        );
        addTearDown(() => directory.deleteSync(recursive: true));
        final AdeleRuntime runtime = AdeleRuntime();
        addTearDown(runtime.close);
        final Uri source = directory.uri;
        late Future<void> starting;
        await tester.runAsync(() async {
          await tester.pumpWidget(
            AdeleApplication(
              createRuntime: () => runtime,
              bootstrapPlugins: (plugins) => starting = plugins.start(
                installationRoot: missing
                    ? '${directory.path}/missing'
                    : directory.path,
                dartaotruntimeExecutable: '${directory.path}/missing-runtime',
                hostArtifactPath: '${directory.path}/missing-host.aot',
              ),
            ),
          );
          await starting;
        });
        await tester.pumpAndSettle();
        expect(runtime.plugins.state, ApplicationPluginState.ready);
        expect(runtime.plugins.failure, isNull);
        expect(runtime.plugins.host, isNull);
        expect(runtime.plugins.catalog!.installations, isEmpty);
        expect(runtime.plugins.catalog!.issues, isEmpty);
        expect(runtime.plugins.backends, isEmpty);
        expect(
          runtime.extensions.discover(sessionPresentationContributions),
          isEmpty,
        );
        expect(
          runtime.extensions.discover(toolActivityInspectionContributions),
          isEmpty,
        );
        expect(
          runtime.extensions.discover(
            toolActivityCompactPresentationContributions,
          ),
          isEmpty,
        );
        expect(
          runtime.extensions.discover(
            modelNativeActivityPresentationContributions,
          ),
          isEmpty,
        );
        expect(
          runtime.extensions.discover(
            modelNativeActivityCompactPresentationContributions,
          ),
          isEmpty,
        );
        expect(find.text('ADELE'), findsOneWidget);
        expect(find.text('No Project is open'), findsOneWidget);
        expect(find.text('Open Local Directory...'), findsNothing);
        expect(
          runtime.registry.providersFor(environmentProviderCapability),
          isEmpty,
        );
        expect(runtime.registry.providersFor(modelProviderCapability), isEmpty);
        expect(runtime.extensions.discover(modelToolContributions), isEmpty);
        expect(runtime.extensions.discover(inferenceContextSources), isEmpty);

        expect(
          runtime.extensions.discover(orchestrationStrategyContributions),
          isEmpty,
        );
        expect(
          runtime.extensions.discover(projectSelectorContributions),
          isEmpty,
        );
        expect(
          find.text('No Project selectors are available.'),
          findsOneWidget,
        );
        expect(find.byType(FilledButton), findsNothing);
        expect(tester.takeException(), isNull);

        final provider = TestProjectProvider(runtime.registry);
        addTearDown(provider.close);
        final ExtensionRegistration selector = runtime.extensions.register(
          point: projectSelectorContributions,
          id: ExtensionId('dev.adele.test.empty-root-selector'),
          value: ProjectSelectorContribution(
            displayName: 'Open Test Project',
            projectProviderId: provider.providerId,
            selectProject: () async => source,
          ),
        );
        addTearDown(selector.close);
        await tester.pumpAndSettle();
        await tester.tap(find.text('Open Test Project'));
        await tester.pumpAndSettle();
        final Project project = tester
            .widget<AdeleShell>(find.byType(AdeleShell))
            .project!;
        expect(project.sourceLocation, source);
        expect(runtime.store.project(project.id), same(project));
        expect(provider.calls, [source]);
        expect(
          File.fromUri(
            source.resolve(TestProjectProvider.databaseRelativePath),
          ).existsSync(),
          isTrue,
        );
        expect(runtime.store.tasksFor(project.id), isEmpty);
        expect(find.text('Project is open'), findsOneWidget);
        expect(find.text('No Task selected'), findsOneWidget);
        expect(
          find.textContaining('Task Environment support is unavailable.'),
          findsOneWidget,
        );
        expect(find.textContaining('Starting Task Environment'), findsNothing);
        expect(tester.takeException(), isNull);

        expect(
          await tester.runAsync(tester.binding.handleRequestAppExit),
          AppExitResponse.exit,
        );
        expect(runtime.plugins.state, ApplicationPluginState.closed);
        expect(runtime.extensions.discover(modelToolContributions), isEmpty);
        expect(runtime.extensions.discover(inferenceContextSources), isEmpty);
        await selector.close();
        expect(
          runtime.extensions.discover(projectSelectorContributions),
          isEmpty,
        );
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
        expect(runtime.store.project(project.id), same(project));
        expect(tester.takeException(), isNull);
      },
      timeout: const Timeout(Duration(seconds: 45)),
    );
  }

  for (final bool backendFailure in [false, true]) {
    testWidgets(
      'owns discovered presentation with ${backendFailure ? 'failed' : 'absent'} backend',
      (WidgetTester tester) async {
        final Directory directory = Directory.systemTemp.createTempSync(
          'openai-activation-',
        );
        addTearDown(() => directory.deleteSync(recursive: true));
        // Loading prepared bytes is independent of per-view decoding and backend work.
        final installation = Directory('${directory.path}/openai')
          ..createSync();
        File('${installation.path}/frontend.evc').writeAsBytesSync([1, 2, 3]);
        if (backendFailure) {
          File('${installation.path}/backend.aot').writeAsBytesSync([0]);
        }
        File(
          '${installation.path}/adele_plugin.installation.json',
        ).writeAsStringSync(
          jsonEncode({
            'manifestVersion': 1,
            'metadata': {
              'id': 'dev.adele.openai',
              'version': '0.1.0',
              'displayName': 'OpenAI',
            },
            'components': {
              if (backendFailure) 'backend': {'artifact': 'backend.aot'},
              'frontend': {
                'artifact': 'frontend.evc',
                'presentations': stockFrontendDescriptors['dev.adele.openai'],
              },
            },
          }),
        );
        final AdeleRuntime runtime = AdeleRuntime();
        addTearDown(runtime.close);
        try {
          late Future<void> backendSettled;
          await tester.runAsync(() async {
            final activated = runtime.extensions.changes.firstWhere(
              (_) => runtime.extensions
                  .discover(modelNativeActivityPresentationContributions)
                  .isNotEmpty,
            );
            await tester.pumpWidget(
              AdeleApplication(
                createRuntime: () => runtime,
                bootstrapPlugins: (plugins) {
                  final starting = plugins.start(
                    installationRoot: directory.path,
                    dartaotruntimeExecutable:
                        '${directory.path}/missing-runtime',
                    hostArtifactPath: '${directory.path}/missing-host.aot',
                  );
                  backendSettled = backendFailure
                      ? expectLater(starting, throwsA(isA<ProcessException>()))
                      : starting;
                  return starting;
                },
              ),
            );
            await activated.timeout(const Duration(seconds: 10));
            await backendSettled;
          });
          await tester.pumpAndSettle();
          final binding = runtime.extensions
              .discover(modelNativeActivityPresentationContributions)
              .single;
          final compactBinding = runtime.extensions
              .discover(modelNativeActivityCompactPresentationContributions)
              .single;
          expect(binding.validate, returnsNormally);
          expect(compactBinding.validate, returnsNormally);
          expect(runtime.plugins.catalog!.installations, hasLength(1));
          expect(runtime.plugins.host, isNull);
          expect(
            runtime.plugins.state,
            backendFailure
                ? ApplicationPluginState.failed
                : ApplicationPluginState.ready,
          );
          expect(
            compactBinding.value.presentationKind,
            binding.value.presentationKind,
          );
          expect(runtime.extensions.discover(modelToolContributions), isEmpty);
          expect(find.text('No Project is open'), findsOneWidget);
          expect(tester.takeException(), isNull);
          await tester.runAsync(() async {
            final retired = runtime.extensions.changes.firstWhere(
              (_) =>
                  runtime.extensions
                      .discover(modelNativeActivityPresentationContributions)
                      .isEmpty &&
                  runtime.extensions
                      .discover(
                        modelNativeActivityCompactPresentationContributions,
                      )
                      .isEmpty,
            );
            await tester.pumpWidget(const SizedBox.shrink());
            await retired.timeout(const Duration(seconds: 10));
          });
          await tester.pumpAndSettle();
          expect(binding.validate, throwsA(isA<StaleExtensionBinding>()));
          expect(
            compactBinding.validate,
            throwsA(isA<StaleExtensionBinding>()),
          );
        } finally {
          // Settle failed bootstrap/frontend ownership before leaving the test zone.
          await tester.runAsync(() async {
            try {
              if (find.byType(AdeleApplication).evaluate().isNotEmpty) {
                await tester.binding.handleRequestAppExit();
              }
            } finally {
              await tester.pumpWidget(const SizedBox.shrink());
              await runtime.close();
            }
          });
          await tester.pumpAndSettle();
        }
      },
    );
  }

  testWidgets('normal entrypoint renders the pre-Project shell', (
    WidgetTester tester,
  ) async {
    application.main();
    await tester.pumpAndSettle();

    expect(find.text('ADELE'), findsOneWidget);
    expect(find.text('No Project is open'), findsOneWidget);
    expect(find.text('Open Local Directory...'), findsNothing);
    expect(find.text('No Project selectors are available.'), findsOneWidget);
    expect(find.text('No workspace is open'), findsNothing);
    expect(find.text('No plugins are loaded'), findsNothing);
    expect(find.text('Phase 0'), findsNothing);

    await tester.binding.setSurfaceSize(const Size(360, 640));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pump();
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('owns one provider-free runtime across rebuilds and disposal', (
    WidgetTester tester,
  ) async {
    final AdeleRuntime runtime = AdeleRuntime();
    int creations = 0;
    AdeleRuntime createRuntime() {
      creations++;
      return runtime;
    }

    expect(
      runtime.extensions.discover(modelToolContributions),
      isEmpty,
      reason: 'A bare runtime has no model tools before plugin bootstrap.',
    );
    await tester.pumpWidget(AdeleApplication(createRuntime: createRuntime));
    expect(
      runtime.extensions.discover(orchestrationStrategyContributions),
      isEmpty,
    );
    expect(
      runtime.registry.providersFor(environmentProviderCapability),
      isEmpty,
    );
    expect(runtime.registry.providersFor(modelProviderCapability), isEmpty);
    expect(runtime.extensions.discover(modelToolContributions), isEmpty);
    expect(runtime.extensions.discover(inferenceContextSources), isEmpty);
    expect(runtime.extensions.discover(projectSelectorContributions), isEmpty);
    expect(find.text('No Project selectors are available.'), findsOneWidget);
    expect(find.text('No Project is open'), findsOneWidget);

    await tester.pumpWidget(AdeleApplication(createRuntime: createRuntime));
    expect(creations, 1);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    expect(
      runtime.extensions.discover(orchestrationStrategyContributions),
      isEmpty,
    );
    expect(runtime.extensions.discover(inferenceContextSources), isEmpty);
    expect(runtime.extensions.discover(modelToolContributions), isEmpty);
    expect(runtime.extensions.discover(projectSelectorContributions), isEmpty);
  });

  testWidgets('graceful application exit awaits runtime retirement', (
    WidgetTester tester,
  ) async {
    late AdeleRuntime runtime;
    await tester.pumpWidget(
      AdeleApplication(createRuntime: () => runtime = AdeleRuntime()),
    );

    expect(await tester.binding.handleRequestAppExit(), AppExitResponse.exit);

    expect(
      runtime.extensions.discover(orchestrationStrategyContributions),
      isEmpty,
    );
    expect(runtime.extensions.discover(inferenceContextSources), isEmpty);
    expect(runtime.extensions.discover(modelToolContributions), isEmpty);
    expect(runtime.extensions.discover(projectSelectorContributions), isEmpty);
    await tester.pumpWidget(const SizedBox.shrink());
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'Session choices are explicit, usable and revalidated before publication',
    (tester) async {
      final runtime = AdeleRuntime();
      final source = Directory.systemTemp.createTempSync(
        'adele-session-project-',
      );
      final projectProvider = TestProjectProvider(runtime.registry);
      addTearDown(() async {
        if (runtime.plugins.state != ApplicationPluginState.closed) {
          await runtime.close();
        }
        await projectProvider.close();
        source.deleteSync(recursive: true);
      });
      final registrations = <ExtensionRegistration>[];
      addTearDown(() async {
        for (final registration in registrations) {
          await registration.close();
        }
      });
      final environment = runtime.registry.register(
        provider: ProviderDescriptor(
          id: ProviderId('dev.example.environment'),
          capability: environmentProviderCapability,
          pluginId: 'dev.example.environment',
          displayName: 'Test environment',
          serviceId: environmentProviderServiceId,
        ),
        endpoint: AdeleRequestChannelEndpoint(
          channel: _EnvironmentChannel(),
          serviceId: environmentProviderServiceId,
          isAvailable: () => true,
        ),
      );
      addTearDown(environment.close);
      registrations.add(
        runtime.extensions.register(
          point: projectSelectorContributions,
          id: ExtensionId('dev.example.selector'),
          value: ProjectSelectorContribution(
            displayName: 'Open fixture',
            projectProviderId: projectProvider.providerId,
            selectProject: () async => source.uri,
          ),
        ),
      );
      final presented = <Session>[];
      ExtensionRegistration presentation(String name, {bool strategy = true}) {
        final key = name.toLowerCase();
        final id = OrchestrationStrategyId('dev.example.$key');
        if (strategy) {
          registrations.add(
            runtime.extensions.register(
              point: orchestrationStrategyContributions,
              id: ExtensionId('dev.example.$key.strategy'),
              value: OrchestrationStrategyContribution(
                strategyId: id,
                materialize: (_) => throw StateError('No Run should start.'),
              ),
            ),
          );
        }
        final registration = runtime.extensions.register(
          point: sessionPresentationContributions,
          id: ExtensionId('dev.example.$key.presentation'),
          value: SessionPresentationContribution(
            strategyId: id,
            displayName: name,
            createPresentation: (session) {
              presented.add(session);
              return Text('$name presentation');
            },
          ),
        );
        registrations.add(registration);
        return registration;
      }

      await tester.pumpWidget(
        AdeleApplication(
          createRuntime: () => runtime,
          bootstrapPlugins: (_) async {},
        ),
      );
      await tester.tap(find.text('Open fixture'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('New Task'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'Generic task');
      await tester.tap(find.text('Create Task'));
      await tester.pumpAndSettle();
      expect(
        find.text('No Session presentations are available.'),
        findsOneWidget,
      );
      presentation('Unavailable', strategy: false);
      final first = presentation('First');
      presentation('Second');
      await tester.pumpAndSettle();
      expect(find.text('New Unavailable Session'), findsNothing);
      expect(find.text('New First Session'), findsOneWidget);
      expect(find.text('New Second Session'), findsOneWidget);
      final stale = tester
          .widget<FilledButton>(
            find.widgetWithText(FilledButton, 'New First Session'),
          )
          .onPressed!;
      await first.close();
      stale();
      await tester.pumpAndSettle();
      expect(find.byType(SessionPresentationHost), findsNothing);
      expect(presented, isEmpty);
      await tester.tap(find.text('New Second Session'));
      await tester.pumpAndSettle();
      expect(presented.single.strategyId.value, 'dev.example.second');
      expect(
        runtime.store.session(presented.single.id),
        same(presented.single),
      );
      expect(find.text('Second presentation'), findsOneWidget);
      expect(runtime.registry.providersFor(modelProviderCapability), isEmpty);
      await tester.binding.handleRequestAppExit();
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
  );
}

final class _EnvironmentChannel implements AdeleRequestChannel {
  @override
  Future<Object?> request(String method, Map<String, Object?> payload) async =>
      {'providerState': <String, Object?>{}};
}
