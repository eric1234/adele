import 'dart:ui' show AppExitResponse;

import 'package:adele_core_extensions/adele_core_extensions.dart';
import 'package:adele_desktop/application.dart';
import 'package:adele_desktop/core/adele_runtime.dart';
import 'package:adele_desktop/main.dart' as application;
import 'package:adele_environment/adele_environment.dart';
import 'package:adele_model_provider/adele_model_provider.dart';
import 'package:adele_model_tool/adele_model_tool.dart';
import 'package:adele_orchestration/adele_orchestration.dart';
import 'package:adele_plugin_api/adele_plugin_api.dart';
import 'package:chat_strategy_plugin/chat_strategy_plugin.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
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
