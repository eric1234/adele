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
        final Set<String> builds = <String>{};
        for (int cycle = 1; cycle <= 3; cycle++) {
          await controller.buildAndStart();
          if (controller.phase != 'running' ||
              controller.interpretedWidget == null ||
              controller.buildId == null ||
              controller.backendHostProcessId == null) {
            throw StateError(controller.lastFailure ?? 'Phase 1 smoke failed.');
          }
          if (!builds.add(controller.buildId!)) {
            throw StateError('Build ID was reused: ${controller.buildId}');
          }
          stdout.writeln(
            'ADELE_PHASE1_SMOKE cycle=$cycle build=${controller.buildId} hostPid=${controller.backendHostProcessId} status=running',
          );
          await controller.stop();
          stdout.writeln('ADELE_PHASE1_SMOKE cycle=$cycle status=stopped');
        }
        for (final String diagnostic in controller.diagnostics) {
          stdout.writeln('ADELE_PHASE1_DIAGNOSTIC $diagnostic');
        }
        exit(0);
      }
      return;
    } on Object catch (error) {
      home = Phase1ConfigurationError(error: error.toString());
    }
  }
  runApp(AdeleApplication(home: home));
}
