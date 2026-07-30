import 'dart:async';
import 'dart:isolate';

import 'package:plugin_runtime/plugin_runtime.dart';
import 'package:test/test.dart';

void main() {
  test('correlates concurrent out-of-order responses', () async {
    final ReceivePort commands = ReceivePort();
    final ReceivePort responses = ReceivePort();
    final PluginBackendConnection connection = PluginBackendConnection.testPeer(
      commandPort: commands.sendPort,
      responses: responses,
    );
    final List<Map<Object?, Object?>> requests = <Map<Object?, Object?>>[];
    final Completer<void> received = Completer<void>();
    commands.listen((Object? value) {
      requests.add((value as Map).cast<Object?, Object?>());
      if (requests.length == 2) received.complete();
    });

    final Future<Object?> first = connection.request(
      'first',
      const <String, Object?>{},
    );
    final Future<Object?> second = connection.request(
      'second',
      const <String, Object?>{},
    );
    await received.future.timeout(const Duration(seconds: 2));
    expect(requests[0]['requestId'], 1);
    expect(requests[1]['requestId'], 2);

    responses.sendPort.send(_success(2, 'second-result'));
    responses.sendPort.send(_success(1, 'first-result'));
    expect(await first.timeout(const Duration(seconds: 2)), 'first-result');
    expect(await second.timeout(const Duration(seconds: 2)), 'second-result');
    await connection.close(graceful: false);
    commands.close();
  });

  test('diagnoses unknown and duplicate response IDs', () async {
    final ReceivePort commands = ReceivePort();
    final ReceivePort responses = ReceivePort();
    final List<String> diagnostics = <String>[];
    final PluginBackendConnection connection = PluginBackendConnection.testPeer(
      commandPort: commands.sendPort,
      responses: responses,
      onDiagnostic: diagnostics.add,
    );

    final Future<Object?> result = connection.request(
      'test',
      const <String, Object?>{},
    );
    responses.sendPort.send(_success(99, null));
    responses.sendPort.send(_success(1, 'ok'));
    responses.sendPort.send(_success(1, 'duplicate'));
    expect(await result.timeout(const Duration(seconds: 2)), 'ok');
    await Future<void>.delayed(Duration.zero);
    expect(diagnostics, contains('Unknown or duplicate response ID 99.'));
    expect(diagnostics, contains('Unknown or duplicate response ID 1.'));
    await connection.close(graceful: false);
    commands.close();
  });

  test('decodes structured remote errors', () async {
    final ReceivePort commands = ReceivePort();
    final ReceivePort responses = ReceivePort();
    final PluginBackendConnection connection = PluginBackendConnection.testPeer(
      commandPort: commands.sendPort,
      responses: responses,
    );
    final Future<Object?> result = connection.request(
      'unknown',
      const <String, Object?>{},
    );
    responses.sendPort.send(<String, Object?>{
      'kind': 'response',
      'requestId': 1,
      'ok': false,
      'error': <String, Object?>{
        'code': 'unknown_method',
        'message': 'Unknown method.',
        'details': <String, Object?>{'method': 'unknown'},
      },
    });
    await expectLater(
      result.timeout(const Duration(seconds: 2)),
      throwsA(
        isA<PluginRemoteFailure>()
            .having((error) => error.code, 'code', 'unknown_method')
            .having((error) => error.details['method'], 'method', 'unknown'),
      ),
    );
    await connection.close(graceful: false);
    commands.close();
  });

  test('fails pending requests when the connection closes', () async {
    final ReceivePort commands = ReceivePort();
    final ReceivePort responses = ReceivePort();
    final PluginBackendConnection connection = PluginBackendConnection.testPeer(
      commandPort: commands.sendPort,
      responses: responses,
    );
    final Future<Object?> pending = connection.request(
      'never-completes',
      const <String, Object?>{},
    );
    final Future<void> expectation = expectLater(
      pending,
      throwsA(isA<PluginConnectionClosed>()),
    );
    await connection.close(graceful: false);
    await expectation;
    expect(connection.isClosed, isTrue);
    commands.close();
  });
}

Map<String, Object?> _success(int requestId, Object? payload) {
  return <String, Object?>{
    'kind': 'response',
    'requestId': requestId,
    'ok': true,
    'payload': payload,
  };
}
