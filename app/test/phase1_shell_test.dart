import 'dart:io';

import 'package:adele_desktop/application.dart';
import 'package:adele_desktop/phase1/development_plugin_controller.dart';
import 'package:adele_desktop/ui/shell/phase1_shell.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('shows Phase 1 controls and inactive diagnostics', (
    WidgetTester tester,
  ) async {
    final Directory root = Directory.systemTemp.createTempSync(
      'adele-phase1-shell-',
    );
    addTearDown(() => root.deleteSync(recursive: true));
    final DevelopmentPluginController controller = DevelopmentPluginController(
      Phase1Configuration(
        repositoryRoot: root,
        pluginDirectory: root,
        developmentDirectory: root,
        dartExecutable: '${root.path}/dart',
        flutterExecutable: '${root.path}/flutter',
      ),
    );
    await tester.pumpWidget(
      AdeleApplication(home: Phase1Shell(controller: controller)),
    );
    expect(find.text('Build and start'), findsOneWidget);
    expect(find.text('Stop'), findsOneWidget);
    expect(find.text('Rebuild and reload'), findsOneWidget);
    expect(find.text('Build phase: inactive'), findsOneWidget);
    expect(find.text('Connection: disconnected'), findsOneWidget);
  });

  testWidgets('renders app-visible configuration failures', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      const AdeleApplication(
        home: Phase1ConfigurationError(error: 'Missing development directory'),
      ),
    );
    expect(
      find.textContaining('Missing development directory'),
      findsOneWidget,
    );
  });
}
