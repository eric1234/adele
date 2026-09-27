import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:adele_contract/adele_contract.dart';
import 'package:git_environment_backend/src/pty/pty_session.dart';

// An independently compiled backend fixture, not linked into the shared host.
Future<void> main(List<String> arguments, Object? bootstrapMessage) async {
  final bootstrap = bootstrapMessage! as Map<Object?, Object?>;
  final bootstrapPort = bootstrap['bootstrapPort']! as SendPort;
  final responsePort = bootstrap['responsePort']! as SendPort;
  final commands = ReceivePort();
  GitPtySession? session;
  var reading = false;
  var writing = false;
  var writes = 0;
  bootstrapPort.send({
    'kind': 'ready',
    'commandPort': commands.sendPort,
    'pluginBackendProtocolVersion': adelePluginBackendProtocolVersion,
  });

  Future<void> handle(Map<Object?, Object?> message) async {
    try {
      final payload = (message['payload'] as Map?) ?? {};
      final Object? result;
      switch (message['method']) {
        case 'open':
          if (session != null) throw StateError('Fixture already has a PTY.');
          session = await GitPtySession.start(
            helperPath: payload['helper'] as String? ?? arguments.single,
            executable: payload['executable'] as String,
            arguments: (payload['arguments']! as List).cast<String>(),
            workingDirectory: payload['cwd'] as String,
            environment: Map<String, String>.from(
              payload['environment']! as Map,
            ),
            rows: 24,
            columns: 80,
          );
          result = session!.pid;
        case 'read':
          reading = true;
          try {
            result = await session!.read();
          } finally {
            reading = false;
          }
        case 'write':
          writing = true;
          try {
            await session!.write(
              Uint8List.fromList((payload['bytes']! as List).cast<int>()),
            );
            writes++;
          } finally {
            writing = false;
          }
          result = null;
        case 'pending':
          result = {'reading': reading, 'writing': writing, 'writes': writes};
        case 'duplex':
          var received = 0;
          var valid = true;
          final drain = () async {
            while (true) {
              final bytes = await session!.read();
              if (bytes == null) break;
              for (final byte in bytes) {
                if (byte != (received ~/ 64) % 251) valid = false;
                received++;
              }
            }
          }();
          final send = () async {
            for (var i = 0; i < 3; i++) {
              await session!.write(
                Uint8List.fromList(
                  List.generate(16384, (n) => (i * 16384 + n) % 251),
                ),
              );
            }
          }();
          await Future.wait([drain, send]);
          result = {
            'bytes': received,
            'valid': valid,
            'exit': await session!.exitCode,
          };
        case 'resize':
          await session!.resize(
            rows: payload['rows'] as int,
            columns: payload['columns'] as int,
          );
          result = null;
        case 'exit':
          result = await session!.exitCode;
        case 'close':
          await session!.close();
          result = null;
        case 'probe':
          final ordinary = await Process.run('/bin/sh', [
            '-c',
            'printf ordinary; exit 23',
          ]);
          result = {
            'pid': pid,
            'cwd': Directory.current.path,
            'sentinel': Platform.environment['ADELE_PTY_SENTINEL'],
            'ordinaryExit': ordinary.exitCode,
            'ordinaryOutput': ordinary.stdout,
          };
        case 'shutdown':
          await session?.close();
          commands.close();
          result = null;
        default:
          throw StateError('Unknown fixture method.');
      }
      responsePort.send({
        'kind': 'response',
        'requestId': message['requestId'],
        'ok': true,
        'payload': result,
      });
    } on Object catch (error) {
      responsePort.send({
        'kind': 'response',
        'requestId': message['requestId'],
        'ok': false,
        'error': {'code': 'pty_fixture_failed', 'message': error.toString()},
      });
    }
  }

  await for (final raw in commands) {
    unawaited(handle(raw! as Map<Object?, Object?>));
  }
}
