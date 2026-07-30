import 'dart:async';
import 'dart:io';
import 'dart:isolate';

Future<void> main(List<String> arguments) async {
  if (arguments.length != 1) {
    stderr.writeln('Usage: host.dart <backend-aot-path>');
    exitCode = 64;
    return;
  }

  final ReceivePort bootstrap = ReceivePort();
  final ReceivePort errors = ReceivePort();
  final ReceivePort exits = ReceivePort();
  final Uri artifactUri = File(arguments.single).absolute.uri;

  stdout.writeln('artifactUri=$artifactUri');
  final Isolate isolate = await Isolate.spawnUri(
    artifactUri,
    const <String>[],
    bootstrap.sendPort,
    onError: errors.sendPort,
    onExit: exits.sendPort,
  );

  try {
    final Object? ready = await bootstrap.first.timeout(
      const Duration(seconds: 5),
    );
    if (ready is! Map || ready['commandPort'] is! SendPort) {
      throw StateError('Invalid bootstrap message: $ready');
    }
    final SendPort commandPort = ready['commandPort'] as SendPort;
    stdout.writeln('handshake=ready');

    final Map<Object?, Object?> ping = await _request(commandPort, 1, 'ping');
    stdout.writeln('ping=$ping');

    final Map<Object?, Object?> unknown = await _request(
      commandPort,
      2,
      'unknown',
    );
    stdout.writeln('unknown=$unknown');

    final Map<Object?, Object?> shutdown = await _request(
      commandPort,
      3,
      'shutdown',
    );
    stdout.writeln('shutdown=$shutdown');
    await exits.first.timeout(const Duration(seconds: 5));
    stdout.writeln('exit=observed');

    if (ping['ok'] != true || unknown['ok'] != false) {
      throw StateError('Unexpected responses.');
    }
  } finally {
    isolate.kill(priority: Isolate.immediate);
    bootstrap.close();
    errors.close();
    exits.close();
  }
}

Future<Map<Object?, Object?>> _request(
  SendPort commandPort,
  int requestId,
  String method,
) async {
  final ReceivePort response = ReceivePort();
  try {
    commandPort.send(<String, Object?>{
      'kind': 'request',
      'requestId': requestId,
      'method': method,
      'payload': <String, Object?>{},
      'replyPort': response.sendPort,
    });
    final Object? message = await response.first.timeout(
      const Duration(seconds: 5),
    );
    if (message is! Map) throw StateError('Invalid response: $message');
    return message;
  } finally {
    response.close();
  }
}
