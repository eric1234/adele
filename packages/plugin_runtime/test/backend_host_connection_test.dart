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

  test('parses optional declared failure type', () async {
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
        'error': {
          'declaredFailureType': 'sample.failure',
          'code': 'declared',
          'message': 'Declared failure',
          'details': {'reason': 'test'},
        },
      }));
    }
  });
}
''');
    addTearDown(fake.dispose);
    final PluginBackendHost host = await fake.start();
    await expectLater(
      host.startPlugin(pluginId: 'declared', artifactUri: Uri.file('/unused')),
      throwsA(
        isA<PluginRemoteFailure>()
            .having(
              (PluginRemoteFailure value) => value.declaredFailureType,
              'declaredFailureType',
              'sample.failure',
            )
            .having(
              (PluginRemoteFailure value) => value.details['reason'],
              'details',
              'test',
            ),
      ),
    );
    await host.close(graceful: false);
  });

  test(
    'does not return a stale connection when plugin fails during startup',
    () async {
      final _FakeHost fake = _FakeHost.create('''
import 'dart:io';
import 'package:plugin_runtime/plugin_runtime.dart';
void main() {
  stdout.add(encodeBackendHostFrame({'protocolVersion': 1, 'kind': 'hostHello'}));
  final decoder = BackendHostFrameDecoder();
  var starts = 0;
  stdin.listen((bytes) {
    for (final message in decoder.add(bytes)) {
      if (message['kind'] == 'startPlugin') {
        starts++;
        stdout.add([
          ...encodeBackendHostFrame({'protocolVersion': 1, 'kind': 'pluginReady', 'requestId': message['requestId'], 'pluginId': message['pluginId']}),
          if (starts == 1) ...encodeBackendHostFrame({'protocolVersion': 1, 'kind': 'pluginFailed', 'pluginId': message['pluginId'], 'requestIds': [], 'error': {'code': 'plugin_exited', 'message': 'exited during startup'}}),
        ]);
      } else if (message['kind'] == 'stopPlugin') {
        stdout.add(encodeBackendHostFrame({'protocolVersion': 1, 'kind': 'pluginStopped', 'requestId': message['requestId'], 'pluginId': message['pluginId']}));
      } else if (message['kind'] == 'shutdownHost') {
        stdout.add(encodeBackendHostFrame({'protocolVersion': 1, 'kind': 'hostStopped', 'requestId': message['requestId']}));
        exit(0);
      }
    }
  });
}
''');
      addTearDown(fake.dispose);
      final PluginBackendHost host = await fake.start();
      await expectLater(
        host.startPlugin(
          pluginId: 'racy',
          artifactUri: Uri.file('/unused.aot'),
        ),
        throwsA(isA<PluginRemoteFailure>()),
      );
      final PluginBackendConnection restarted = await host.startPlugin(
        pluginId: 'racy',
        artifactUri: Uri.file('/unused.aot'),
      );
      expect(restarted.isClosed, isFalse);
      await restarted.close();
      await host.close();
    },
  );

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

  test('fails plugin stop when the host exits during stop', () async {
    final _FakeHost fake = _FakeHost.create('''
import 'dart:io';
import 'package:plugin_runtime/plugin_runtime.dart';
void main() {
  stdout.add(encodeBackendHostFrame({'protocolVersion': 1, 'kind': 'hostHello'}));
  final decoder = BackendHostFrameDecoder();
  stdin.listen((bytes) {
    for (final message in decoder.add(bytes)) {
      if (message['kind'] == 'startPlugin') {
        stdout.add(encodeBackendHostFrame({'protocolVersion': 1, 'kind': 'pluginReady', 'requestId': message['requestId'], 'pluginId': message['pluginId']}));
      } else if (message['kind'] == 'stopPlugin') {
        exit(9);
      }
    }
  });
}
''');
    addTearDown(fake.dispose);
    final PluginBackendHost host = await fake.start();
    final PluginBackendConnection connection = await host.startPlugin(
      pluginId: 'stop-exit',
      artifactUri: Uri.file('/unused.aot'),
    );
    await expectLater(
      connection.close().timeout(const Duration(seconds: 5)),
      throwsA(isA<PluginConnectionClosed>()),
    );
    expect(connection.isClosed, isTrue);
    expect(host.isClosed, isTrue);
    await host.close();
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

  test(
    'removes pending requests after synchronous serialization failure',
    () async {
      final _FakeHost fake = _FakeHost.create('''
import 'dart:io';
import 'package:plugin_runtime/plugin_runtime.dart';
void main() {
  stdout.add(encodeBackendHostFrame({'protocolVersion': 1, 'kind': 'hostHello'}));
  final decoder = BackendHostFrameDecoder();
  stdin.listen((bytes) {
    for (final message in decoder.add(bytes)) {
      if (message['kind'] == 'startPlugin') {
        stdout.add(encodeBackendHostFrame({'protocolVersion': 1, 'kind': 'pluginReady', 'requestId': message['requestId'], 'pluginId': message['pluginId']}));
      } else if (message['kind'] == 'stopPlugin') {
        stdout.add(encodeBackendHostFrame({'protocolVersion': 1, 'kind': 'pluginStopped', 'requestId': message['requestId'], 'pluginId': message['pluginId']}));
      } else if (message['kind'] == 'shutdownHost') {
        stdout.add(encodeBackendHostFrame({'protocolVersion': 1, 'kind': 'hostStopped', 'requestId': message['requestId']}));
        exit(0);
      }
    }
  });
}
''');
      addTearDown(fake.dispose);
      final List<String> diagnostics = <String>[];
      final PluginBackendHost host = await fake.start(
        onDiagnostic: diagnostics.add,
      );
      final PluginBackendConnection connection = await host.startPlugin(
        pluginId: 'serialize',
        artifactUri: Uri.file('/unused.aot'),
      );
      await expectLater(
        connection.request('bad', <String, Object?>{'value': Object()}),
        throwsA(isA<BackendHostProtocolException>()),
      );
      await connection.close();
      await host.close();
      expect(
        diagnostics.where((String value) => value.contains('response ID')),
        isEmpty,
      );
    },
  );

  test('kills and reaps host after malformed stdout', () async {
    final _FakeHost fake = _FakeHost.create('''
import 'dart:async';
import 'dart:io';
import 'package:plugin_runtime/plugin_runtime.dart';
Future<void> main() async {
  stdout.add(encodeBackendHostFrame({'protocolVersion': 1, 'kind': 'hostHello'}));
  await stdout.flush();
  final decoder = BackendHostFrameDecoder();
  var started = false;
  stdin.listen((bytes) async {
    for (final message in decoder.add(bytes)) {
      if (!started) {
        started = true;
        stdout.add(encodeBackendHostFrame({'protocolVersion': 1, 'kind': 'pluginReady', 'requestId': message['requestId'], 'pluginId': message['pluginId']}));
        await stdout.flush();
      } else {
        stdout.add([0, 0, 0, 1, 255]);
        await stdout.flush();
      }
    }
  });
  await Completer<void>().future;
}
''');
    addTearDown(fake.dispose);
    final PluginBackendHost host = await fake.start();
    final int pid = host.processId;
    final PluginBackendConnection connection = await host.startPlugin(
      pluginId: 'malformed',
      artifactUri: Uri.file('/unused.aot'),
    );
    await expectLater(
      connection.request('pending', const <String, Object?>{}),
      throwsA(
        isA<PluginConnectionClosed>().having(
          (PluginConnectionClosed value) => value.message,
          'message',
          contains('Malformed host output'),
        ),
      ),
    );
    expect(host.isClosed, isTrue);
    expect(connection.isClosed, isTrue);
    await host.close().timeout(const Duration(seconds: 2));
    final ProcessResult alive = await Process.run('kill', <String>[
      '-0',
      '$pid',
    ]);
    expect(alive.exitCode, isNot(0));
    await expectLater(
      host.startPlugin(pluginId: 'late', artifactUri: Uri.file('/unused.aot')),
      throwsA(isA<PluginConnectionClosed>()),
    );
  });

  test(
    'does not retain pending state after synchronous encoding failure',
    () async {
      final _FakeHost fake = _FakeHost.create('''
import 'dart:io';
import 'package:plugin_runtime/plugin_runtime.dart';
void main() {
  stdout.add(encodeBackendHostFrame({'protocolVersion': 1, 'kind': 'hostHello'}));
  final decoder = BackendHostFrameDecoder();
  stdin.listen((bytes) {
    for (final message in decoder.add(bytes)) {
      final kind = switch (message['kind']) {
        'startPlugin' => 'pluginReady',
        'stopPlugin' => 'pluginStopped',
        'shutdownHost' => 'hostStopped',
        _ => 'response',
      };
      stdout.add(encodeBackendHostFrame({
        'protocolVersion': 1,
        'kind': kind,
        'requestId': message['requestId'],
        'pluginId': message['pluginId'],
      }));
      if (message['kind'] == 'shutdownHost') exit(0);
    }
  });
}
''');
      addTearDown(fake.dispose);
      final PluginBackendHost host = await fake.start();
      final PluginBackendConnection connection = await host.startPlugin(
        pluginId: 'retryable',
        artifactUri: Uri.file('/unused.aot'),
      );
      await expectLater(
        connection.request('bad', <String, Object?>{'value': double.nan}),
        throwsA(isA<BackendHostProtocolException>()),
      );
      await connection.close();
      final PluginBackendConnection retried = await host.startPlugin(
        pluginId: 'retryable',
        artifactUri: Uri.file('/unused.aot'),
      );
      expect(retried.isClosed, isFalse);
      await host.close();
      expect(host.isClosed, isTrue);
    },
  );
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
