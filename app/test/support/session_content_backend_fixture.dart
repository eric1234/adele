import 'dart:io';

import 'package:plugin_builder/plugin_builder.dart';
import 'package:plugin_runtime/plugin_runtime.dart';

typedef ContentBackendArtifacts = ({File host, File backend, String runtime});

Future<ContentBackendArtifacts> compileContentBackend(
  Directory temporary,
) async {
  final dart = _dartExecutable();
  final host = File('${temporary.path}/host.aot');
  final backend = File('${temporary.path}/backend.aot');
  for (final (entrypoint, artifact) in [
    ('packages/plugin_backend_host/bin/adele_backend_host.dart', host),
    ('app/test/fixtures/session_content_inspection_backend.dart', backend),
  ]) {
    await compileAotSnapshot(
      dartExecutable: dart,
      workingDirectory: Directory.current.parent,
      entrypoint: entrypoint,
      artifact: artifact,
      stage: 'session-content-backend',
    );
  }
  return (
    host: host,
    backend: backend,
    runtime: File(dart).parent.uri
        .resolve(Platform.isWindows ? 'dartaotruntime.exe' : 'dartaotruntime')
        .toFilePath(),
  );
}

Future<Object?> contentBackendControl(
  PluginBackendConnection connection,
  String method, [
  Map<String, Object?> payload = const {},
]) => connection
    .channelFor(connection.defaultConfigurationContext, 'fixture.control')
    .request(method, payload)
    .timeout(const Duration(seconds: 10));

String _dartExecutable() {
  final root = Platform.environment['FLUTTER_ROOT'];
  if (root != null) {
    final dart = File('$root/bin/cache/dart-sdk/bin/dart');
    if (dart.existsSync()) return dart.path;
  }
  var directory = File(Platform.resolvedExecutable).parent;
  while (!File('${directory.path}/dart-sdk/bin/dart').existsSync()) {
    if (directory.parent.path == directory.path) {
      throw StateError('Pinned Dart SDK not found.');
    }
    directory = directory.parent;
  }
  return '${directory.path}/dart-sdk/bin/dart';
}
