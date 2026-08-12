import 'dart:async';
import 'dart:io';

import 'package:plugin_runtime/plugin_runtime.dart';
import 'package:test/test.dart';

void main() {
  test('times out startup and terminates the host', () async {
    final _FakeHost fake = _FakeHost.create('''
import 'dart:async';
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
  stdout.add(encodeBackendHostFrame({'protocolVersion': backendHostProtocolVersion, 'kind': 'hostHello'}));
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
  stdout.add(encodeBackendHostFrame({'protocolVersion': backendHostProtocolVersion, 'kind': 'hostHello'}));
  final decoder = BackendHostFrameDecoder();
  stdin.listen((bytes) {
    for (final message in decoder.add(bytes)) {
      stdout.add(encodeBackendHostFrame({
        'protocolVersion': backendHostProtocolVersion,
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
  stdout.add(encodeBackendHostFrame({'protocolVersion': backendHostProtocolVersion, 'kind': 'hostHello'}));
  final decoder = BackendHostFrameDecoder();
  stdin.listen((bytes) {
    for (final message in decoder.add(bytes)) {
      stdout.add(encodeBackendHostFrame({
        'protocolVersion': backendHostProtocolVersion,
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
    final List<String> diagnostics = <String>[];
    final PluginBackendHost host = await fake.start(
      onDiagnostic: (String message) {
        diagnostics.add(message);
        stderr.writeln(message);
      },
    );
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

  for (final entry in <String, String>{
    'missing details': '',
    'non-map details': "'details': 'invalid',",
  }.entries) {
    test('rejects declared failure with ${entry.key}', () async {
      final _FakeHost fake = _FakeHost.create('''
import 'dart:io';
import 'package:plugin_runtime/plugin_runtime.dart';
void main() {
  stdout.add(encodeBackendHostFrame({'protocolVersion': backendHostProtocolVersion, 'kind': 'hostHello'}));
  final decoder = BackendHostFrameDecoder();
  stdin.listen((bytes) {
    for (final message in decoder.add(bytes)) {
      stdout.add(encodeBackendHostFrame({
        'protocolVersion': backendHostProtocolVersion,
        'kind': 'error',
        'requestId': message['requestId'],
        'pluginId': message['pluginId'],
        'error': {
          'declaredFailureType': 'sample.failure',
          'code': 'declared',
          'message': 'Declared failure',
          ${entry.value}
        },
      }));
    }
  });
}
''');
      addTearDown(fake.dispose);
      final PluginBackendHost host = await fake.start();
      await expectLater(
        host.startPlugin(
          pluginId: 'malformed-declared',
          artifactUri: Uri.file('/unused'),
        ),
        throwsA(
          isA<PluginRemoteFailure>()
              .having(
                (PluginRemoteFailure value) => value.code,
                'code',
                'invalid_response',
              )
              .having(
                (PluginRemoteFailure value) => value.declaredFailureType,
                'declaredFailureType',
                isNull,
              ),
        ),
      );
      await host.close(graceful: false);
    });
  }

  test(
    'does not return a stale connection when plugin fails during startup',
    () async {
      final _FakeHost fake = _FakeHost.create('''
import 'dart:io';
import 'package:plugin_runtime/plugin_runtime.dart';
void main() {
  stdout.add(encodeBackendHostFrame({'protocolVersion': backendHostProtocolVersion, 'kind': 'hostHello'}));
  final decoder = BackendHostFrameDecoder();
  var starts = 0;
  stdin.listen((bytes) {
    for (final message in decoder.add(bytes)) {
      if (message['kind'] == 'startPlugin') {
        starts++;
        stdout.add([
          ...encodeBackendHostFrame({'protocolVersion': backendHostProtocolVersion, 'kind': 'pluginReady', 'requestId': message['requestId'], 'pluginId': message['pluginId']}),
          if (starts == 1) ...encodeBackendHostFrame({'protocolVersion': backendHostProtocolVersion, 'kind': 'pluginFailed', 'pluginId': message['pluginId'], 'requestIds': [], 'error': {'code': 'plugin_exited', 'message': 'exited during startup'}}),
        ]);
      } else if (message['kind'] == 'stopPlugin') {
        stdout.add(encodeBackendHostFrame({'protocolVersion': backendHostProtocolVersion, 'kind': 'pluginStopped', 'requestId': message['requestId'], 'pluginId': message['pluginId']}));
      } else if (message['kind'] == 'shutdownHost') {
        stdout.add(encodeBackendHostFrame({'protocolVersion': backendHostProtocolVersion, 'kind': 'hostStopped', 'requestId': message['requestId']}));
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

  test(
    'reports structured connection termination when the host exits',
    () async {
      final _FakeHost fake = _FakeHost.create('''
import 'dart:io';
import 'package:plugin_runtime/plugin_runtime.dart';
void main() {
  stdout.add(encodeBackendHostFrame({'protocolVersion': backendHostProtocolVersion, 'kind': 'hostHello'}));
  final decoder = BackendHostFrameDecoder();
  var started = false;
  stdin.listen((bytes) {
    for (final message in decoder.add(bytes)) {
      if (!started) {
        started = true;
        stdout.add(encodeBackendHostFrame({'protocolVersion': backendHostProtocolVersion, 'kind': 'pluginReady', 'requestId': message['requestId'], 'pluginId': message['pluginId']}));
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
      expect(await connection.terminated, isA<PluginConnectionClosed>());
      expect(host.isClosed, isTrue);
    },
  );

  test('fails plugin stop when the host exits during stop', () async {
    final _FakeHost fake = _FakeHost.create('''
import 'dart:io';
import 'package:plugin_runtime/plugin_runtime.dart';
void main() {
  stdout.add(encodeBackendHostFrame({'protocolVersion': backendHostProtocolVersion, 'kind': 'hostHello'}));
  final decoder = BackendHostFrameDecoder();
  stdin.listen((bytes) {
    for (final message in decoder.add(bytes)) {
      if (message['kind'] == 'startPlugin') {
        stdout.add(encodeBackendHostFrame({'protocolVersion': backendHostProtocolVersion, 'kind': 'pluginReady', 'requestId': message['requestId'], 'pluginId': message['pluginId']}));
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
  stdout.add(encodeBackendHostFrame({'protocolVersion': backendHostProtocolVersion, 'kind': 'hostHello'}));
  stdout.add(encodeBackendHostFrame({'protocolVersion': backendHostProtocolVersion, 'kind': 'response', 'requestId': 999, 'ok': true}));
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
  stdout.add(encodeBackendHostFrame({'protocolVersion': backendHostProtocolVersion, 'kind': 'hostHello'}));
  final decoder = BackendHostFrameDecoder();
  stdin.listen((bytes) {
    for (final message in decoder.add(bytes)) {
      if (message['kind'] == 'startPlugin') {
        stdout.add(encodeBackendHostFrame({'protocolVersion': backendHostProtocolVersion, 'kind': 'pluginReady', 'requestId': message['requestId'], 'pluginId': message['pluginId']}));
      } else if (message['kind'] == 'stopPlugin') {
        stdout.add(encodeBackendHostFrame({'protocolVersion': backendHostProtocolVersion, 'kind': 'pluginStopped', 'requestId': message['requestId'], 'pluginId': message['pluginId']}));
      } else if (message['kind'] == 'shutdownHost') {
        stdout.add(encodeBackendHostFrame({'protocolVersion': backendHostProtocolVersion, 'kind': 'hostStopped', 'requestId': message['requestId']}));
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
  stdout.add(encodeBackendHostFrame({'protocolVersion': backendHostProtocolVersion, 'kind': 'hostHello'}));
  await stdout.flush();
  final decoder = BackendHostFrameDecoder();
  var started = false;
  stdin.listen((bytes) async {
    for (final message in decoder.add(bytes)) {
      if (!started) {
        started = true;
        stdout.add(encodeBackendHostFrame({'protocolVersion': backendHostProtocolVersion, 'kind': 'pluginReady', 'requestId': message['requestId'], 'pluginId': message['pluginId']}));
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
  stdout.add(encodeBackendHostFrame({'protocolVersion': backendHostProtocolVersion, 'kind': 'hostHello'}));
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
        'protocolVersion': backendHostProtocolVersion,
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

  test('streams ordered items with pause, resume, and cancellation', () async {
    final _FakeHost fake = _FakeHost.create('''
import 'dart:io';
import 'package:plugin_runtime/plugin_runtime.dart';
void main() {
  stdout.add(encodeBackendHostFrame({'protocolVersion': backendHostProtocolVersion, 'kind': 'hostHello'}));
  final decoder = BackendHostFrameDecoder();
  final sequences = <int, int>{};
  final pendingCredits = <int>{};
  stdin.listen((bytes) {
    for (final message in decoder.add(bytes)) {
      if (message['kind'] == 'startPlugin') {
        stdout.add(encodeBackendHostFrame({'protocolVersion': backendHostProtocolVersion, 'kind': 'pluginReady', 'requestId': message['requestId'], 'pluginId': message['pluginId']}));
      } else if (message['kind'] == 'streamOpen') {
        final id = message['requestId'] as int;
        sequences[id] = 0;
        if (pendingCredits.remove(id)) {
          sequences[id] = 1;
          stdout.add(encodeBackendHostFrame({'protocolVersion': backendHostProtocolVersion, 'kind': 'streamItem', 'requestId': id, 'pluginId': message['pluginId'], 'payload': 0}));
        }
      } else if (message['kind'] == 'streamCredit') {
        final id = message['requestId'] as int;
        final sequence = sequences[id];
        if (sequence == null) {
          pendingCredits.add(id);
          continue;
        }
        sequences[id] = sequence + 1;
        stdout.add(encodeBackendHostFrame({'protocolVersion': backendHostProtocolVersion, 'kind': 'streamItem', 'requestId': id, 'pluginId': message['pluginId'], 'payload': sequence}));
      } else if (message['kind'] == 'streamCancel') {
        final id = message['requestId'] as int;
        sequences.remove(id);
        stdout.add(encodeBackendHostFrame({'protocolVersion': backendHostProtocolVersion, 'kind': 'streamCancelled', 'requestId': id, 'pluginId': message['pluginId']}));
      } else if (message['kind'] == 'stopPlugin') {
        stdout.add(encodeBackendHostFrame({'protocolVersion': backendHostProtocolVersion, 'kind': 'pluginStopped', 'requestId': message['requestId'], 'pluginId': message['pluginId']}));
      } else if (message['kind'] == 'shutdownHost') {
        stdout.add(encodeBackendHostFrame({'protocolVersion': backendHostProtocolVersion, 'kind': 'hostStopped', 'requestId': message['requestId']}));
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
      pluginId: 'streaming',
      artifactUri: Uri.file('/unused.aot'),
    );
    final List<int> items = <int>[];
    late final StreamSubscription<Object?> subscription;
    final Completer<void> first = Completer<void>();
    subscription = connection.stream('events', const {}).listen((event) {
      items.add(event! as int);
      if (items.length == 1) {
        subscription.pause();
        first.complete();
      }
    });
    await first.future.timeout(
      const Duration(seconds: 2),
      onTimeout: () {
        fail('No first stream item. Diagnostics: $diagnostics');
      },
    );
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(items, <int>[0]);
    subscription.resume();
    while (items.length < 2) {
      await Future<void>.delayed(Duration.zero);
    }
    await subscription.cancel().timeout(const Duration(seconds: 2));
    expect(items, <int>[0, 1]);
    await connection.close();
    await host.close();
  });

  test('host disappearance errors an active stream', () async {
    final _FakeHost fake = _FakeHost.create('''
import 'dart:io';
import 'package:plugin_runtime/plugin_runtime.dart';
void main() {
  stdout.add(encodeBackendHostFrame({'protocolVersion': backendHostProtocolVersion, 'kind': 'hostHello'}));
  final decoder = BackendHostFrameDecoder();
  stdin.listen((bytes) {
    for (final message in decoder.add(bytes)) {
      if (message['kind'] == 'startPlugin') {
        stdout.add(encodeBackendHostFrame({'protocolVersion': backendHostProtocolVersion, 'kind': 'pluginReady', 'requestId': message['requestId'], 'pluginId': message['pluginId']}));
      } else if (message['kind'] == 'streamOpen') {
        exit(7);
      }
    }
  });
}
''');
    addTearDown(fake.dispose);
    final PluginBackendHost host = await fake.start();
    final PluginBackendConnection connection = await host.startPlugin(
      pluginId: 'vanishing',
      artifactUri: Uri.file('/unused.aot'),
    );
    await expectLater(
      connection.stream('events', const <String, Object?>{}),
      emitsError(isA<PluginConnectionClosed>()),
    );
  });

  test('pause before first item does not grant duplicate credit', () async {
    final _FakeHost fake = _FakeHost.create('''
import 'dart:io';
import 'package:plugin_runtime/plugin_runtime.dart';
void main() {
  stdout.add(encodeBackendHostFrame({'protocolVersion': backendHostProtocolVersion, 'kind': 'hostHello'}));
  final decoder = BackendHostFrameDecoder();
  var credits = 0;
  stdin.listen((bytes) {
    for (final message in decoder.add(bytes)) {
      if (message['kind'] == 'startPlugin') {
        stdout.add(encodeBackendHostFrame({'protocolVersion': backendHostProtocolVersion, 'kind': 'pluginReady', 'requestId': message['requestId'], 'pluginId': message['pluginId']}));
      } else if (message['kind'] == 'streamCredit') {
        credits++;
        if (credits > 1) stdout.add(encodeBackendHostFrame({'protocolVersion': backendHostProtocolVersion, 'kind': 'diagnostic', 'stage': 'test', 'message': 'duplicate-credit'}));
      } else if (message['kind'] == 'streamCancel') {
        stdout.add(encodeBackendHostFrame({'protocolVersion': backendHostProtocolVersion, 'kind': 'streamCancelled', 'requestId': message['requestId'], 'pluginId': message['pluginId']}));
      }
    }
  });
}
''');
    addTearDown(fake.dispose);
    final diagnostics = <String>[];
    final PluginBackendHost host = await fake.start(
      onDiagnostic: (message) {
        diagnostics.add(message);
      },
    );
    final connection = await host.startPlugin(
      pluginId: 'paused',
      artifactUri: Uri.file('/unused.aot'),
    );
    final subscription = connection.stream('events', const {}).listen((_) {});
    subscription.pause();
    subscription.resume();
    subscription.pause();
    subscription.resume();
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(diagnostics, isNot(contains(contains('duplicate-credit'))));
    await subscription.cancel();
    await host.close(graceful: false);
  });

  test('cancellation timeout retires its plugin generation', () async {
    final _FakeHost fake = _FakeHost.create('''
import 'dart:io';
import 'package:plugin_runtime/plugin_runtime.dart';
void main() {
  stdout.add(encodeBackendHostFrame({'protocolVersion': backendHostProtocolVersion, 'kind': 'hostHello'}));
  final decoder = BackendHostFrameDecoder();
  stdin.listen((bytes) {
    for (final message in decoder.add(bytes)) {
      if (message['kind'] == 'startPlugin') {
        stdout.add(encodeBackendHostFrame({'protocolVersion': backendHostProtocolVersion, 'kind': 'pluginReady', 'requestId': message['requestId'], 'pluginId': message['pluginId']}));
      } else if (message['kind'] == 'stopPlugin') {
        stdout.add(encodeBackendHostFrame({'protocolVersion': backendHostProtocolVersion, 'kind': 'pluginStopped', 'requestId': message['requestId'], 'pluginId': message['pluginId']}));
      } else if (message['kind'] == 'shutdownHost') {
        stdout.add(encodeBackendHostFrame({'protocolVersion': backendHostProtocolVersion, 'kind': 'hostStopped', 'requestId': message['requestId']}));
        exit(0);
      }
    }
  });
}
''');
    addTearDown(fake.dispose);
    final PluginBackendHost host = await fake.start(
      shutdownTimeout: const Duration(milliseconds: 50),
    );
    final connection = await host.startPlugin(
      pluginId: 'stuck',
      artifactUri: Uri.file('/unused.aot'),
    );
    final subscription = connection.stream('events', const {}).listen((_) {});
    await subscription.cancel().timeout(const Duration(seconds: 1));
    expect(connection.isClosed, isTrue);
    await connection.terminated.timeout(const Duration(seconds: 1));
    final replacement = await host.startPlugin(
      pluginId: 'stuck',
      artifactUri: Uri.file('/unused.aot'),
    );
    expect(replacement.isClosed, isFalse);
    await replacement.close();
    await host.close();
  });

  test(
    'lazy streams reject stale owner generations before remote open',
    () async {
      final _FakeHost fake = _FakeHost.create('''
import 'dart:io';
import 'package:plugin_runtime/plugin_runtime.dart';
void main() {
  stdout.add(encodeBackendHostFrame({'protocolVersion': backendHostProtocolVersion, 'kind': 'hostHello'}));
  final decoder = BackendHostFrameDecoder();
  var opens = 0;
  stdin.listen((bytes) {
    for (final message in decoder.add(bytes)) {
      if (message['kind'] == 'startPlugin') {
        stdout.add(encodeBackendHostFrame({'protocolVersion': backendHostProtocolVersion, 'kind': 'pluginReady', 'requestId': message['requestId'], 'pluginId': message['pluginId']}));
      } else if (message['kind'] == 'stopPlugin') {
        stdout.add(encodeBackendHostFrame({'protocolVersion': backendHostProtocolVersion, 'kind': 'pluginStopped', 'requestId': message['requestId'], 'pluginId': message['pluginId']}));
      } else if (message['kind'] == 'streamOpen') {
        opens++;
      } else if (message['kind'] == 'streamCredit') {
        stdout.add(encodeBackendHostFrame({'protocolVersion': backendHostProtocolVersion, 'kind': 'streamDone', 'requestId': message['requestId'], 'pluginId': message['pluginId']}));
      } else if (message['kind'] == 'request') {
        stdout.add(encodeBackendHostFrame({'protocolVersion': backendHostProtocolVersion, 'kind': 'response', 'requestId': message['requestId'], 'pluginId': message['pluginId'], 'ok': true, 'payload': opens}));
      } else if (message['kind'] == 'shutdownHost') {
        stdout.add(encodeBackendHostFrame({'protocolVersion': backendHostProtocolVersion, 'kind': 'hostStopped', 'requestId': message['requestId']}));
        exit(0);
      }
    }
  });
}
''');
      addTearDown(fake.dispose);
      final PluginBackendHost host = await fake.start();
      final generationA = await host.startPlugin(
        pluginId: 'same-id',
        artifactUri: Uri.file('/unused.aot'),
      );
      final staleWithoutReplacement = generationA.stream('events', const {});
      final staleWithReplacement = generationA.stream('events', const {});
      await generationA.close();
      await expectLater(
        staleWithoutReplacement,
        emitsError(isA<PluginConnectionClosed>()),
      );
      final generationB = await host.startPlugin(
        pluginId: 'same-id',
        artifactUri: Uri.file('/unused.aot'),
      );
      await expectLater(
        staleWithReplacement,
        emitsError(isA<PluginConnectionClosed>()),
      );
      expect(await generationB.request('open-count', const {}), 0);
      await expectLater(generationB.stream('events', const {}), emitsDone);
      expect(await generationB.request('open-count', const {}), 1);
      await generationB.close();
      await host.close();
    },
  );

  test('generic host errors terminate correlated streams', () async {
    final _FakeHost fake = _FakeHost.create('''
import 'dart:io';
import 'package:plugin_runtime/plugin_runtime.dart';
void main() {
  stdout.add(encodeBackendHostFrame({'protocolVersion': backendHostProtocolVersion, 'kind': 'hostHello'}));
  final decoder = BackendHostFrameDecoder();
  stdin.listen((bytes) {
    for (final message in decoder.add(bytes)) {
      if (message['kind'] == 'startPlugin') {
        stdout.add(encodeBackendHostFrame({'protocolVersion': backendHostProtocolVersion, 'kind': 'pluginReady', 'requestId': message['requestId'], 'pluginId': message['pluginId']}));
      } else if (message['kind'] == 'streamOpen') {
        stdout.add(encodeBackendHostFrame({'protocolVersion': backendHostProtocolVersion, 'kind': 'error', 'requestId': message['requestId'], 'pluginId': message['pluginId'], 'error': {'code': 'invalid_command', 'message': 'Method is empty.'}}));
      } else if (message['kind'] == 'request') {
        stdout.add(encodeBackendHostFrame({'protocolVersion': backendHostProtocolVersion, 'kind': 'response', 'requestId': message['requestId'], 'pluginId': message['pluginId'], 'ok': true, 'payload': 'alive'}));
      } else if (message['kind'] == 'stopPlugin') {
        stdout.add(encodeBackendHostFrame({'protocolVersion': backendHostProtocolVersion, 'kind': 'pluginStopped', 'requestId': message['requestId'], 'pluginId': message['pluginId']}));
      } else if (message['kind'] == 'shutdownHost') {
        stdout.add(encodeBackendHostFrame({'protocolVersion': backendHostProtocolVersion, 'kind': 'hostStopped', 'requestId': message['requestId']}));
        exit(0);
      }
    }
  });
}
''');
    addTearDown(fake.dispose);
    final host = await fake.start();
    final connection = await host.startPlugin(
      pluginId: 'stream-error',
      artifactUri: Uri.file('/unused.aot'),
    );
    await expectLater(
      connection.stream('', const {}),
      emitsError(
        isA<PluginRemoteFailure>().having(
          (failure) => failure.code,
          'code',
          'invalid_command',
        ),
      ),
    );
    expect(await connection.request('ping', const {}), 'alive');
    await connection.close();
    await host.close();
  });

  test('cancellation timeout joins exact in-flight plugin stop', () async {
    final _FakeHost fake = _FakeHost.create('''
import 'dart:io';
import 'package:plugin_runtime/plugin_runtime.dart';
void main() {
  stdout.add(encodeBackendHostFrame({'protocolVersion': backendHostProtocolVersion, 'kind': 'hostHello'}));
  final decoder = BackendHostFrameDecoder();
  Map<String, Object?>? pendingStop;
  var gatedStopUsed = false;
  stdin.listen((bytes) {
    for (final message in decoder.add(bytes)) {
      if (message['kind'] == 'startPlugin') {
        stdout.add(encodeBackendHostFrame({'protocolVersion': backendHostProtocolVersion, 'kind': 'pluginReady', 'requestId': message['requestId'], 'pluginId': message['pluginId']}));
      } else if (message['kind'] == 'stopPlugin') {
        if (message['pluginId'] == 'joining-stop' && !gatedStopUsed) {
          gatedStopUsed = true;
          pendingStop = message;
          stdout.add(encodeBackendHostFrame({'protocolVersion': backendHostProtocolVersion, 'kind': 'diagnostic', 'stage': 'test', 'message': 'stop-started'}));
        } else {
          stdout.add(encodeBackendHostFrame({'protocolVersion': backendHostProtocolVersion, 'kind': 'pluginStopped', 'requestId': message['requestId'], 'pluginId': message['pluginId']}));
        }
      } else if (message['kind'] == 'request' && message['method'] == 'release-stop') {
        final stop = pendingStop!;
        pendingStop = null;
        stdout.add(encodeBackendHostFrame({'protocolVersion': backendHostProtocolVersion, 'kind': 'pluginStopped', 'requestId': stop['requestId'], 'pluginId': stop['pluginId']}));
        stdout.add(encodeBackendHostFrame({'protocolVersion': backendHostProtocolVersion, 'kind': 'response', 'requestId': message['requestId'], 'pluginId': message['pluginId'], 'ok': true, 'payload': true}));
      } else if (message['kind'] == 'request') {
        stdout.add(encodeBackendHostFrame({'protocolVersion': backendHostProtocolVersion, 'kind': 'response', 'requestId': message['requestId'], 'pluginId': message['pluginId'], 'ok': true, 'payload': 'alive'}));
      } else if (message['kind'] == 'shutdownHost') {
        stdout.add(encodeBackendHostFrame({'protocolVersion': backendHostProtocolVersion, 'kind': 'hostStopped', 'requestId': message['requestId']}));
        exit(0);
      }
    }
  });
}
''');
    addTearDown(fake.dispose);
    final stopStarted = Completer<void>();
    final host = await fake.start(
      shutdownTimeout: const Duration(milliseconds: 50),
      onDiagnostic: (message) {
        if (message.contains('stop-started') && !stopStarted.isCompleted) {
          stopStarted.complete();
        }
      },
    );
    final generationA = await host.startPlugin(
      pluginId: 'joining-stop',
      artifactUri: Uri.file('/unused.aot'),
    );
    final release = await host.startPlugin(
      pluginId: 'release',
      artifactUri: Uri.file('/unused.aot'),
    );
    final subscription = generationA.stream('events', const {}).listen((_) {});
    bool cancellationDone = false;
    final cancelling = subscription.cancel().then(
      (_) => cancellationDone = true,
    );
    final stopping = host.stopPlugin('joining-stop', expected: generationA);
    await stopStarted.future;
    await Future<void>.delayed(const Duration(milliseconds: 75));
    expect(cancellationDone, isFalse);
    await release.request('release-stop', const {});
    await Future.wait<void>(<Future<void>>[cancelling, stopping]);
    final generationB = await host.startPlugin(
      pluginId: 'joining-stop',
      artifactUri: Uri.file('/unused.aot'),
    );
    await generationA.close();
    expect(await generationB.request('ping', const {}), 'alive');
    await generationB.close();
    await release.close();
    await host.close();
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
