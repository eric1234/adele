import 'dart:io';

import 'package:adele_desktop/application.dart';
import 'package:adele_desktop/phase1/development_plugin_controller.dart';
import 'package:adele_desktop/ui/shell/phase1_shell.dart';
import 'package:flutter/widgets.dart';

Future<void> main(List<String> arguments) async {
  Widget? home;
  if (const bool.fromEnvironment('ADELE_PHASE1_ENABLED')) {
    try {
      final DevelopmentPluginController controller =
          DevelopmentPluginController(Phase1Configuration.fromEnvironment());
      home = Phase1Shell(controller: controller);
      runApp(AdeleApplication(home: home));
      if (arguments.contains('--phase1-smoke')) {
        await controller.buildAndStart();
        for (final String diagnostic in controller.diagnostics) {
          stdout.writeln('ADELE_PHASE1_DIAGNOSTIC $diagnostic');
        }
        if (controller.phase != 'running' ||
            controller.interpretedWidget == null) {
          throw StateError(controller.lastFailure ?? 'Phase 1 smoke failed.');
        }
        stdout.writeln(
          'ADELE_PHASE1_SMOKE build=${controller.buildId} status=running',
        );
        await controller.stop();
        stdout.writeln('ADELE_PHASE1_SMOKE status=stopped');
        exit(0);
      }
      return;
    } on Object catch (error) {
      home = Phase1ConfigurationError(error: error.toString());
    }
  }
  runApp(AdeleApplication(home: home));
}
