import 'dart:async';
import 'dart:io';

import 'package:plugin_runtime/plugin_runtime.dart';
import 'package:test/test.dart';

void main() {
  test(
    'stdin EOF stops active plugins and exits the host',
    () async {
      final String repository = Directory.current.parent.parent.path;
      final Directory artifacts = Directory(
        '$repository/.dart_tool/adele/development-runtime/stdin-eof-test',
      )..createSync(recursive: true);
      final String dart = Platform.resolvedExecutable;
      final String dartaotruntime = '${File(dart).parent.path}/dartaotruntime';
      final File hostArtifact = File('${artifacts.path}/host.aot');
      final File pluginArtifact = File('${artifacts.path}/plugin.aot');
      await _compile(
        dart,
        '$repository/packages/plugin_backend_host/bin/adele_backend_host.dart',
        hostArtifact.path,
        repository,
      );
      await _compile(
        dart,
        '$repository/packages/plugin_backend_host/test/fixtures/crashing_backend.dart',
        pluginArtifact.path,
        repository,
      );
      final Process process = await Process.start(dartaotruntime, <String>[
        hostArtifact.path,
      ], runInShell: false);
      addTearDown(() {
        process.kill(ProcessSignal.sigkill);
      });
      final BackendHostFrameDecoder decoder = BackendHostFrameDecoder();
      final StreamController<Map<String, Object?>> messages =
          StreamController<Map<String, Object?>>();
      process.stdout.listen((List<int> bytes) {
        for (final Map<String, Object?> message in decoder.add(bytes)) {
          messages.add(message);
        }
      });
      final StreamIterator<Map<String, Object?>> iterator =
          StreamIterator<Map<String, Object?>>(messages.stream);
      expect((await _next(iterator))['kind'], 'hostHello');
      process.stdin.add(
        encodeBackendHostFrame(<String, Object?>{
          'protocolVersion': backendHostProtocolVersion,
          'kind': 'startPlugin',
          'requestId': 1,
          'pluginId': 'eof-plugin',
          'defaultConfigurationContext': 'default',
          'artifactUri': pluginArtifact.uri.toString(),
          'arguments': <String>['acknowledge-hang'],
        }),
      );
      await process.stdin.flush();
      expect((await _next(iterator))['kind'], 'pluginReady');
      await process.stdin.close();
      expect(await process.exitCode.timeout(const Duration(seconds: 8)), 0);
      await iterator.cancel();
      await messages.close();
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
}

Future<Map<String, Object?>> _next(
  StreamIterator<Map<String, Object?>> iterator,
) async {
  if (!await iterator.moveNext().timeout(const Duration(seconds: 5))) {
    throw StateError('Backend host output ended unexpectedly.');
  }
  return iterator.current;
}

Future<void> _compile(
  String dart,
  String entrypoint,
  String output,
  String workingDirectory,
) async {
  final ProcessResult result = await Process.run(dart, <String>[
    'compile',
    'aot-snapshot',
    entrypoint,
    '-o',
    output,
  ], workingDirectory: workingDirectory);
  if (result.exitCode != 0) throw StateError(result.stderr.toString());
}
