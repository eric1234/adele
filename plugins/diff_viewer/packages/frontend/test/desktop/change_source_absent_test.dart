@Timeout(Duration(minutes: 5))
library;

import 'dart:io';

import 'package:adele_desktop/core/adele_runtime.dart';
import 'package:adele_desktop/core/application_plugin_bootstrap.dart';
import 'package:adele_desktop/core/prepared_settings.dart';
import 'package:adele_desktop/core/product_lifecycle.dart';
import 'package:adele_desktop/frontend/application_frontend_bootstrap.dart';
import 'package:adele_desktop/frontend/prepared_main_content_host.dart';
import 'package:adele_desktop/frontend/prepared_session_services.dart';
import 'package:adele_desktop/ui/main_content/main_content_host.dart';
import 'package:adele_orchestration/adele_orchestration.dart';
import 'package:diff_viewer_contract/diff_viewer_contract.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../../../../app/test/support/prepared_frontend_installations.dart';
import '../../../../../../app/test/support/selection_sessions.dart';
import '../../../../../../app/tool/diff_viewer_frontend_compiler.dart';

void main() {
  const pluginId = 'dev.adele.diff-viewer';
  late AdeleRuntime runtime;
  late SelectionGraph graph;
  late PreparedMainContentHost mainContent;

  setUp(() async {
    final root = await Directory.systemTemp.createTemp('diff-frontend-only-');
    addTearDown(() => root.delete(recursive: true));
    final artifact = File('${root.path}/frontend.evc');
    await compileDiffViewerFrontend(
      repositoryRoot: Directory.current.parent.parent.parent.parent,
      sdkPath: diffViewerDartSdk(),
      artifact: artifact,
    );
    final installations = await prepareFrontendInstallations(
      root: Directory('${root.path}/installed'),
      artifacts: {pluginId: artifact},
    );

    // Establish through the product lifecycle, then retire the establishment
    // provider. Selection is canonical even without a live backend to restore it.
    runtime = AdeleRuntime();
    addTearDown(runtime.close);
    graph = await createSelectionSessions(
      runtime,
      runtime.lifecycle.createProject(root.uri),
      OrchestrationStrategyId('test.uninstalled-strategy'),
    );
    final environmentRuntime = runtime.lifecycle.environmentRuntime;
    expect(
      CapturedSessionEnvironment(
        session: graph.session,
        environmentRuntime: environmentRuntime,
      ).environment,
      same(graph.environment),
    );
    final backends = runtime.plugins;
    backends.configureSettingsLoader(
      (catalog) async => PreparedSettingsSnapshot.resolve(catalog),
    );
    await backends.start(installationRoot: installations.path);
    expect(backends.state, ApplicationPluginState.ready);
    expect(backends.failure, isNull);
    expect(backends.catalog!.issues, isEmpty);
    expect(backends.backends, isEmpty);
    expect(runtime.registry.providersFor(changeSetSourceCapability), isEmpty);

    mainContent = PreparedMainContentHost(
      environmentRuntime: environmentRuntime,
    );
    final frontends = ApplicationFrontendBootstrap(
      extensions: runtime.extensions,
      backends: backends,
      mainContentHost: mainContent,
      loadSettings: backends.settingsForCatalog,
      sessionServices: PreparedSessionServices(
        extensions: runtime.extensions,
        backends: backends,
        isCurrent: (session) => identical(session, graph.session),
        controllerForSession: (_, _) =>
            throw StateError('Unexpected execution'),
        inspectActivity: (_, _) => false,
      ),
    );
    addTearDown(frontends.close);
    await frontends.start(backends.catalog!);
    final activation = frontends.generations.single;
    expect(activation.installation.metadata.id.value, pluginId);
    expect(
      activation.state,
      InstalledFrontendState.active,
      reason: '${activation.failure}',
    );
  });

  testWidgets(
    'frontend-only installation retains Diff when change source is absent',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: MainContentHost(
              session: graph.session,
              extensions: runtime.extensions,
              actionCoordinator: mainContent.actionCoordinator,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      void expectUnavailable(String clean) {
        expect(find.text('Diff'), findsOneWidget);
        expect(
          find.text('Diff unavailable for this Environment.'),
          findsOneWidget,
        );
        expect(find.textContaining(clean), findsNothing);
        expect(runtime.plugins.backends, isEmpty);
      }

      expectUnavailable('No unstaged changes');
      for (final (control, clean) in [
        ('Refresh', 'No unstaged changes'),
        ('Uncommitted changes', 'No uncommitted changes'),
        ('Task / Branch', 'No task changes'),
      ]) {
        final button = find.widgetWithText(TextButton, control);
        expect(tester.widget<TextButton>(button).onPressed, isNotNull);
        await tester.tap(button);
        await tester.pumpAndSettle();
        // All three scopes have the same unavailable message. Check that the
        // active scope actually changed, not just that stale text stayed put.
        final selected = control == 'Refresh' ? 'Unstaged changes' : control;
        expect(
          tester.widget<Text>(find.text(selected)).style?.fontWeight,
          FontWeight.bold,
        );
        expectUnavailable(clean);
      }
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
