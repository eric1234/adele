import 'dart:io';

import 'package:adele_desktop/development/development_plugin_runtime.dart';
import 'package:flutter/widgets.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final DevelopmentPluginRuntime runtime = DevelopmentPluginRuntime(
    DevelopmentRuntimeConfiguration.fromEnvironment(),
  );
  final Set<String> builds = <String>{};
  for (int cycle = 1; cycle <= 3; cycle++) {
    await runtime.buildAndStart();
    final String? buildId = runtime.buildId;
    final int? hostPid = runtime.hostProcessId;
    if (buildId == null ||
        hostPid == null ||
        runtime.interpretedWidget == null) {
      throw StateError('Development smoke did not start completely.');
    }
    if (!builds.add(buildId)) throw StateError('Build ID was reused: $buildId');
    stdout.writeln(
      'ADELE_DEVELOPMENT_SMOKE cycle=$cycle build=$buildId hostPid=$hostPid status=running',
    );
    await runtime.stop();
    stdout.writeln('ADELE_DEVELOPMENT_SMOKE cycle=$cycle status=stopped');
  }
  for (final String diagnostic in runtime.diagnostics) {
    stdout.writeln('ADELE_DEVELOPMENT_DIAGNOSTIC $diagnostic');
  }
  exit(0);
}
