import 'dart:convert';
import 'dart:io';

/// Discovers component inputs after bootstrap and contract generation.
///
/// Keep this coordinator SDK-only: the launcher must load before bootstrap.
Future<Map<String, List<String>>> discoverDesktopBuildInputs({
  required Directory repositoryRoot,
  required String dartExecutable,
  File? snapshot,
}) async {
  final root = repositoryRoot.absolute;
  final worker = File.fromUri(
    root.uri.resolve('tools/desktop_build_inputs_worker.dart'),
  );
  final ProcessResult result;
  try {
    result = await Process.run(
      dartExecutable,
      [snapshot?.path ?? worker.path, root.path],
      workingDirectory: root.path,
      runInShell: Platform.isWindows,
    );
  } on ProcessException catch (error) {
    throw StateError('Desktop build input discovery could not start: $error');
  }
  if (result.exitCode != 0) {
    throw StateError(
      'Desktop build input discovery failed (${result.exitCode}): '
      '${result.stderr}',
    );
  }
  final Object? decoded;
  try {
    decoded = jsonDecode(result.stdout.toString());
  } on FormatException catch (error) {
    throw StateError('Invalid desktop build input discovery JSON: $error');
  }
  if (decoded is! Map<String, dynamic> || decoded.isEmpty) {
    throw StateError('Desktop build input discovery returned no stage map.');
  }
  final inputs = <String, List<String>>{};
  for (final entry in decoded.entries) {
    final value = entry.value;
    if (entry.key.isEmpty || value is! List || value.isEmpty) {
      throw StateError('Invalid desktop build inputs for ${entry.key}.');
    }
    final paths = <String>{};
    for (final path in value) {
      if (path is! String ||
          path.isEmpty ||
          !File(path).isAbsolute ||
          !await File(path).exists()) {
        throw StateError(
          'Desktop build input must be an existing absolute file '
          '(${entry.key}): $path',
        );
      }
      paths.add(path);
    }
    inputs[entry.key] = paths.toList()..sort();
  }
  return inputs;
}
