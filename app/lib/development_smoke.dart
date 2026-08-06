import 'dart:io';

import 'package:adele_desktop/development/development_plugin_runtime.dart';
import 'package:flutter/widgets.dart';
import 'package:resource_inspector_contract/resource_inspector_contract.dart';

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
    if (runtime.capabilityWidget == null ||
        runtime.capabilityRegistry
                .providersFor(resourceInspectCapability)
                .length !=
            2) {
      throw StateError('Capability smoke did not publish both providers.');
    }
    if (!builds.add(buildId)) throw StateError('Build ID was reused: $buildId');
    stdout.writeln(
      'ADELE_DEVELOPMENT_SMOKE cycle=$cycle build=$buildId hostPid=$hostPid status=running',
    );
    await runtime.stop();
    if (runtime.capabilityRegistry
        .providersFor(resourceInspectCapability)
        .isNotEmpty) {
      throw StateError('Capability registrations survived shutdown.');
    }
    stdout.writeln('ADELE_DEVELOPMENT_SMOKE cycle=$cycle status=stopped');
  }
  for (final String diagnostic in runtime.diagnostics) {
    stdout.writeln('ADELE_DEVELOPMENT_DIAGNOSTIC $diagnostic');
  }
  exit(0);
}
