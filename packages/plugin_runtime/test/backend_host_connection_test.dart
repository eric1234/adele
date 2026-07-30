import 'dart:async';
import 'dart:io';

import 'package:plugin_runtime/plugin_runtime.dart';
import 'package:test/test.dart';

void main() {
  test('times out startup and terminates the host', () async {
    final _FakeHost fake = _FakeHost.create('''
import 'dart:io';
void main() => stdin.listen((_) {});
''');
    addTearDown(fake.dispose);
    await expectLater(
      fake.start(startupTimeout: const Duration(milliseconds: 100)),
      throwsA(isA<TimeoutException>()),
    );
  });

  test('forces termination after graceful shutdown timeout', () async {
    final _FakeHost fake = _FakeHost.create('''
import 'dart:io';
import 'package:plugin_runtime/plugin_runtime.dart';
void main() {
  stdout.add(encodeBackendHostFrame({'protocolVersion': 1, 'kind': 'hostHello'}));
  stdin.listen((_) {});
}
''');
    addTearDown(fake.dispose);
    final List<String> diagnostics = <String>[];
    final PluginBackendHost host = await fake.start(
      onDiagnostic: diagnostics.add,
      shutdownTimeout: const Duration(milliseconds: 100),
    );
    await host.close();
    expect(host.isClosed, isTrue);
    expect(
      diagnostics.any((String value) => value.contains('shutdown failed')),
      isTrue,
    );
  });

  test('reports structured plugin startup errors', () async {
    final _FakeHost fake = _FakeHost.create('''
import 'dart:io';
import 'package:plugin_runtime/plugin_runtime.dart';
void main() {
  stdout.add(encodeBackendHostFrame({'protocolVersion': 1, 'kind': 'hostHello'}));
  final decoder = BackendHostFrameDecoder();
  stdin.listen((bytes) {
    for (final message in decoder.add(bytes)) {
      stdout.add(encodeBackendHostFrame({
        'protocolVersion': 1,
        'kind': 'error',
        'requestId': message['requestId'],
        'pluginId': message['pluginId'],
        'error': {'code': 'plugin_start_failed', 'message': 'bad artifact'},
      }));
    }
  });
}
''');
    addTearDown(fake.dispose);
    final PluginBackendHost host = await fake.start();
    await expectLater(
      host.startPlugin(
        pluginId: 'broken',
        artifactUri: Uri.file('/missing.aot'),
      ),
      throwsA(
        isA<PluginRemoteFailure>().having(
          (PluginRemoteFailure value) => value.code,
          'code',
          'plugin_start_failed',
        ),
      ),
    );
    await host.close(graceful: false);
  });

  test('fails pending requests when the host exits', () async {
    final _FakeHost fake = _FakeHost.create('''
import 'dart:io';
import 'package:plugin_runtime/plugin_runtime.dart';
void main() {
  stdout.add(encodeBackendHostFrame({'protocolVersion': 1, 'kind': 'hostHello'}));
  final decoder = BackendHostFrameDecoder();
  var started = false;
  stdin.listen((bytes) {
    for (final message in decoder.add(bytes)) {
      if (!started) {
        started = true;
        stdout.add(encodeBackendHostFrame({'protocolVersion': 1, 'kind': 'pluginReady', 'requestId': message['requestId'], 'pluginId': message['pluginId']}));
      } else {
        exit(7);
      }
    }
  });
}
''');
    addTearDown(fake.dispose);
    final PluginBackendHost host = await fake.start();
    final PluginBackendConnection connection = await host.startPlugin(
      pluginId: 'test',
      artifactUri: Uri.file('/unused.aot'),
    );
    await expectLater(
      connection.request('pending', const <String, Object?>{}),
      throwsA(isA<PluginConnectionClosed>()),
    );
    expect(host.isClosed, isTrue);
  });

  test('diagnoses unknown response IDs', () async {
    final _FakeHost fake = _FakeHost.create('''
import 'dart:io';
import 'package:plugin_runtime/plugin_runtime.dart';
void main() {
  stdout.add(encodeBackendHostFrame({'protocolVersion': 1, 'kind': 'hostHello'}));
  stdout.add(encodeBackendHostFrame({'protocolVersion': 1, 'kind': 'response', 'requestId': 999, 'ok': true}));
  stdin.listen((_) {});
}
''');
    addTearDown(fake.dispose);
    final List<String> diagnostics = <String>[];
    final PluginBackendHost host = await fake.start(
      onDiagnostic: diagnostics.add,
    );
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(diagnostics, contains('Unknown or duplicate host response ID 999.'));
    await host.close(graceful: false);
  });
}

final class _FakeHost {
  _FakeHost._(this.directory, this.script);

  final Directory directory;
  final File script;

  static _FakeHost create(String source) {
    final Directory directory = Directory(
      '${Directory.current.path}/.dart_tool/test-hosts/${DateTime.now().microsecondsSinceEpoch}',
    )..createSync(recursive: true);
    final File script = File('${directory.path}/host.dart')
      ..writeAsStringSync(source);
    return _FakeHost._(directory, script);
  }

  Future<PluginBackendHost> start({
    PluginDiagnosticSink? onDiagnostic,
    Duration startupTimeout = const Duration(seconds: 5),
    Duration shutdownTimeout = const Duration(seconds: 2),
  }) {
    return _start(onDiagnostic, startupTimeout, shutdownTimeout);
  }

  Future<PluginBackendHost> _start(
    PluginDiagnosticSink? onDiagnostic,
    Duration startupTimeout,
    Duration shutdownTimeout,
  ) async {
    final File artifact = File('${directory.path}/host.aot');
    final ProcessResult compilation = await Process.run(
      Platform.resolvedExecutable,
      <String>['compile', 'aot-snapshot', script.path, '-o', artifact.path],
      workingDirectory: Directory.current.path,
    );
    if (compilation.exitCode != 0) {
      throw StateError('Fake host compilation failed: ${compilation.stderr}');
    }
    return PluginBackendHost.start(
      dartaotruntimeExecutable:
          '${File(Platform.resolvedExecutable).parent.path}/dartaotruntime',
      hostArtifactPath: artifact.path,
      onDiagnostic: onDiagnostic,
      startupTimeout: startupTimeout,
      shutdownTimeout: shutdownTimeout,
    );
  }

  void dispose() {
    if (directory.existsSync()) directory.deleteSync(recursive: true);
  }
}
