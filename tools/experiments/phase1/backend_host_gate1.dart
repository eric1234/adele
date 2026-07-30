// ignore_for_file: depend_on_referenced_packages

import 'dart:async';
import 'dart:io';

import 'package:plugin_backend_host/plugin_backend_host.dart';

Future<void> main(List<String> arguments) async {
  final Process process = await Process.start(arguments[0], <String>[
    arguments[1],
  ], runInShell: false);
  final BackendHostFrameDecoder decoder = BackendHostFrameDecoder();
  final StreamController<Map<String, Object?>> messages =
      StreamController<Map<String, Object?>>();
  process.stdout.listen((List<int> bytes) {
    for (final Map<String, Object?> message in decoder.add(bytes)) {
      messages.add(message);
    }
  });
  process.stderr.transform(SystemEncoding().decoder).listen(stderr.write);
  final StreamIterator<Map<String, Object?>> iterator =
      StreamIterator<Map<String, Object?>>(messages.stream);
  await iterator.moveNext().timeout(const Duration(seconds: 5));
  stdout.writeln('hello=${iterator.current}');
  process.stdin.add(
    encodeBackendHostFrame(<String, Object?>{
      'protocolVersion': backendHostProtocolVersion,
      'kind': 'shutdownHost',
      'requestId': 1,
    }),
  );
  await process.stdin.flush();
  await iterator.moveNext().timeout(const Duration(seconds: 5));
  stdout.writeln('stopped=${iterator.current}');
  await process.stdin.close();
  final int code = await process.exitCode.timeout(const Duration(seconds: 5));
  stdout.writeln('exitCode=$code');
  await messages.close();
}
