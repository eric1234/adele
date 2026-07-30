import 'dart:convert';
import 'dart:io';

final class PluginBuildDiagnostic {
  const PluginBuildDiagnostic({
    required this.stage,
    required this.command,
    required this.workingDirectory,
    required this.exitCode,
    required this.stdoutText,
    required this.stderrText,
  });

  final String stage;
  final List<String> command;
  final String workingDirectory;
  final int exitCode;
  final String stdoutText;
  final String stderrText;
}

final class PluginBuildResult {
  const PluginBuildResult({
    required this.buildId,
    required this.buildDirectory,
    required this.backendArtifact,
    required this.frontendArtifact,
    required this.diagnostics,
  });

  final String buildId;
  final Directory buildDirectory;
  final File backendArtifact;
  final File frontendArtifact;
  final List<PluginBuildDiagnostic> diagnostics;
}

final class PluginBuildFailure implements Exception {
  const PluginBuildFailure(this.message, {this.diagnostic});

  final String message;
  final PluginBuildDiagnostic? diagnostic;

  @override
  String toString() => 'PluginBuildFailure: $message';
}

final class DevelopmentPluginBuilder {
  const DevelopmentPluginBuilder();

  Future<PluginBuildResult> prepareBackend({
    required Directory repositoryRoot,
    required Directory pluginDirectory,
    required String dartExecutable,
    required String flutterExecutable,
    required String expectedDartVersion,
    required String expectedFlutterVersion,
  }) async {
    final Map<String, String> manifest = await _readManifest(pluginDirectory);
    final String pluginId = _required(manifest, 'id');
    final String backendRelative = _required(manifest, 'backend');
    final Directory backendDirectory = Directory(
      '${pluginDirectory.path}${Platform.pathSeparator}$backendRelative',
    );
    if (!backendDirectory.existsSync()) {
      throw PluginBuildFailure(
        'Backend package does not exist: ${backendDirectory.path}',
      );
    }

    final List<PluginBuildDiagnostic> diagnostics = <PluginBuildDiagnostic>[];
    final PluginBuildDiagnostic dartVersion = await _run(
      'configuration',
      dartExecutable,
      const <String>['--version'],
      repositoryRoot.path,
    );
    diagnostics.add(dartVersion);
    if (!dartVersion.stderrText.contains(expectedDartVersion) &&
        !dartVersion.stdoutText.contains(expectedDartVersion)) {
      throw PluginBuildFailure(
        'Dart toolchain mismatch; expected $expectedDartVersion.',
        diagnostic: dartVersion,
      );
    }
    final PluginBuildDiagnostic flutterVersion = await _run(
      'configuration',
      flutterExecutable,
      const <String>['--version', '--machine'],
      repositoryRoot.path,
    );
    diagnostics.add(flutterVersion);
    if (!flutterVersion.stdoutText.contains(
          '"frameworkVersion":"$expectedFlutterVersion"',
        ) &&
        !flutterVersion.stdoutText.contains(
          '"frameworkVersion": "$expectedFlutterVersion"',
        )) {
      throw PluginBuildFailure(
        'Flutter toolchain mismatch; expected $expectedFlutterVersion.',
        diagnostic: flutterVersion,
      );
    }

    final String buildId = DateTime.now()
        .toUtc()
        .microsecondsSinceEpoch
        .toString();
    final Directory buildDirectory = Directory(
      '${repositoryRoot.path}${Platform.pathSeparator}.dart_tool${Platform.pathSeparator}adele${Platform.pathSeparator}phase1${Platform.pathSeparator}plugins${Platform.pathSeparator}$pluginId${Platform.pathSeparator}builds${Platform.pathSeparator}$buildId',
    );
    await buildDirectory.create(recursive: true);
    final File backendArtifact = File(
      '${buildDirectory.path}${Platform.pathSeparator}backend.aot',
    );
    final File frontendArtifact = File(
      '${buildDirectory.path}${Platform.pathSeparator}frontend.evc',
    );

    final PluginBuildDiagnostic resolution = await _run(
      'dependency-resolution',
      dartExecutable,
      const <String>['pub', 'get'],
      backendDirectory.path,
    );
    diagnostics.add(resolution);
    _requireSuccess(resolution);
    final String entrypoint =
        '${backendDirectory.path}${Platform.pathSeparator}bin${Platform.pathSeparator}workspace_demo_backend.dart';
    final PluginBuildDiagnostic compilation = await _run(
      'backend-compilation',
      dartExecutable,
      <String>[
        'compile',
        'aot-snapshot',
        entrypoint,
        '-o',
        backendArtifact.path,
      ],
      backendDirectory.path,
    );
    diagnostics.add(compilation);
    await File(
      '${buildDirectory.path}${Platform.pathSeparator}backend.stdout.txt',
    ).writeAsString(compilation.stdoutText);
    await File(
      '${buildDirectory.path}${Platform.pathSeparator}backend.stderr.txt',
    ).writeAsString(compilation.stderrText);
    _requireSuccess(compilation);
    return PluginBuildResult(
      buildId: buildId,
      buildDirectory: buildDirectory,
      backendArtifact: backendArtifact,
      frontendArtifact: frontendArtifact,
      diagnostics: List<PluginBuildDiagnostic>.unmodifiable(diagnostics),
    );
  }

  Future<void> activate(PluginBuildResult build) async {
    if (!build.backendArtifact.existsSync() ||
        !build.frontendArtifact.existsSync()) {
      throw const PluginBuildFailure(
        'Both backend and frontend artifacts must exist before activation.',
      );
    }
    final Directory pluginRoot = build.buildDirectory.parent.parent;
    final File current = File(
      '${pluginRoot.path}${Platform.pathSeparator}current.json',
    );
    await current.writeAsString(
      const JsonEncoder.withIndent('  ').convert(<String, Object?>{
        'buildId': build.buildId,
        'buildDirectory': build.buildDirectory.path,
        'backendArtifact': build.backendArtifact.path,
        'frontendArtifact': build.frontendArtifact.path,
      }),
    );
  }
}

Future<Map<String, String>> _readManifest(Directory pluginDirectory) async {
  final File file = File(
    '${pluginDirectory.path}${Platform.pathSeparator}adele_plugin.yaml',
  );
  if (!file.existsSync()) throw const PluginBuildFailure('Missing manifest.');
  final Map<String, String> values = <String, String>{};
  String? section;
  for (final String rawLine in await file.readAsLines()) {
    final String line = rawLine.trim();
    if (line.isEmpty || line.startsWith('#')) continue;
    if (line == 'packages:') {
      section = 'packages';
      continue;
    }
    final int separator = line.indexOf(':');
    if (separator < 1) continue;
    final String key = line.substring(0, separator).trim();
    final String value = line.substring(separator + 1).trim();
    values[section == 'packages' ? key : key] = value;
  }
  if (values['manifestVersion'] != '1') {
    throw const PluginBuildFailure('Unsupported manifest version.');
  }
  return values;
}

String _required(Map<String, String> values, String key) {
  final String? value = values[key];
  if (value == null || value.isEmpty) {
    throw PluginBuildFailure('Missing manifest field: $key.');
  }
  return value;
}

Future<PluginBuildDiagnostic> _run(
  String stage,
  String executable,
  List<String> arguments,
  String workingDirectory,
) async {
  final ProcessResult result = await Process.run(
    executable,
    arguments,
    workingDirectory: workingDirectory,
    runInShell: Platform.isWindows,
  );
  return PluginBuildDiagnostic(
    stage: stage,
    command: <String>[executable, ...arguments],
    workingDirectory: workingDirectory,
    exitCode: result.exitCode,
    stdoutText: result.stdout.toString(),
    stderrText: result.stderr.toString(),
  );
}

void _requireSuccess(PluginBuildDiagnostic diagnostic) {
  if (diagnostic.exitCode != 0) {
    throw PluginBuildFailure(
      '${diagnostic.stage} failed with exit code ${diagnostic.exitCode}.',
      diagnostic: diagnostic,
    );
  }
}
