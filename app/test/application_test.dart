import 'dart:convert';
import 'dart:io';
import 'dart:ui' show AppExitResponse;

import 'package:adele_core_extensions/adele_core_extensions.dart';
import 'package:adele_desktop/application.dart';
import 'package:adele_desktop/core/adele_runtime.dart';
import 'package:adele_desktop/core/application_plugin_bootstrap.dart';
import 'package:adele_desktop/main.dart' as application;
import 'package:adele_desktop/ui/shell/adele_shell.dart';
import 'package:adele_environment/adele_environment.dart';
import 'package:adele_model_provider/adele_model_provider.dart';
import 'package:adele_model_tool/adele_model_tool.dart';
import 'package:adele_orchestration/adele_orchestration.dart';
import 'package:adele_plugin_api/adele_plugin_api.dart';
import 'package:adele_product/adele_product.dart';
import 'package:adele_ui/adele_ui.dart';
import 'package:chat_strategy_plugin/chat_strategy_plugin.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../tools/stock_frontend_descriptors.dart';

void main() {
  for (final bool missing in [false, true]) {
    testWidgets(
      '${missing ? 'missing' : 'empty'} installation root keeps Project selection usable',
      (WidgetTester tester) async {
        final Directory directory = Directory.systemTemp.createTempSync(
          'adele-empty-application-',
        );
        addTearDown(() => directory.deleteSync(recursive: true));
        final AdeleRuntime runtime = AdeleRuntime();
        addTearDown(runtime.close);
        final Uri source = Uri.parse('https://example.test/SelectedProject');
        final ExtensionRegistration selector = runtime.extensions.register(
          point: projectSelectorContributions,
          id: ExtensionId('dev.adele.test.empty-root-selector'),
          value: ProjectSelectorContribution(
            displayName: 'Open Test Project',
            selectProject: () async => source,
          ),
        );
        addTearDown(selector.close);
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
        expect(find.text('Open Local Directory...'), findsOneWidget);
        expect(
          runtime.registry.providersFor(environmentProviderCapability),
          isEmpty,
        );
        expect(runtime.registry.providersFor(modelProviderCapability), isEmpty);
        expect(
          runtime.extensions.discover(modelToolContributions),
          hasLength(3),
        );
        expect(
          runtime.extensions.discover(inferenceContextSources),
          hasLength(1),
        );

        await tester.tap(find.text('Open Test Project'));
        await tester.pumpAndSettle();
        final Project project = tester
            .widget<AdeleShell>(find.byType(AdeleShell))
            .project!;
        expect(project.sourceLocation, source);
        expect(runtime.store.project(project.id), same(project));
        expect(runtime.store.tasksFor(project.id), isEmpty);
        expect(find.text('Project is open'), findsOneWidget);
        expect(find.text('No Tasks yet'), findsOneWidget);
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
                  dartaotruntimeExecutable: '${directory.path}/missing-runtime',
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
        expect(
          runtime.extensions.discover(modelToolContributions),
          hasLength(3),
        );
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
        expect(compactBinding.validate, throwsA(isA<StaleExtensionBinding>()));
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
    expect(find.text('Open Local Directory...'), findsOneWidget);
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
    late AdeleRuntime runtime;
    int creations = 0;
    AdeleRuntime createRuntime() {
      creations++;
      return runtime = AdeleRuntime();
    }

    await tester.pumpWidget(AdeleApplication(createRuntime: createRuntime));
    final ResolvedOrchestrationStrategy strategy = runtime
        .lifecycle
        .strategyResolver
        .resolve(chatStrategyId);
    expect(
      runtime.registry.providersFor(environmentProviderCapability),
      isEmpty,
    );
    expect(runtime.registry.providersFor(modelProviderCapability), isEmpty);
    expect(runtime.extensions.discover(modelToolContributions), hasLength(3));
    expect(runtime.extensions.discover(inferenceContextSources), hasLength(1));
    final ExtensionBinding<ProjectSelectorContribution> selector = runtime
        .extensions
        .discover(projectSelectorContributions)
        .single;
    expect(find.text(selector.value.displayName), findsOneWidget);
    expect(find.text('No Project is open'), findsOneWidget);

    await tester.pumpWidget(AdeleApplication(createRuntime: createRuntime));
    expect(creations, 1);
    expect(strategy.validateBinding, returnsNormally);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    expect(
      runtime.extensions.discover(orchestrationStrategyContributions),
      isEmpty,
    );
    expect(runtime.extensions.discover(inferenceContextSources), isEmpty);
    expect(runtime.extensions.discover(modelToolContributions), isEmpty);
    expect(runtime.extensions.discover(projectSelectorContributions), isEmpty);
    expect(selector.validate, throwsA(isA<StaleExtensionBinding>()));
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
}
