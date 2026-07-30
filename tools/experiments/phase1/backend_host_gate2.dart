// ignore_for_file: depend_on_referenced_packages

import 'dart:async';
import 'dart:io';

import 'package:plugin_backend_host/plugin_backend_host.dart';

Future<void> main(List<String> arguments) async {
  final Process process = await Process.start(arguments[0], <String>[
    arguments[1],
  ], runInShell: false);
  final BackendHostFrameDecoder decoder = BackendHostFrameDecoder();
  final StreamController<Map<String, Object?>> incoming =
      StreamController<Map<String, Object?>>();
  process.stdout.listen((List<int> bytes) {
    for (final Map<String, Object?> message in decoder.add(bytes)) {
      incoming.add(message);
    }
  });
  process.stderr.transform(SystemEncoding().decoder).listen((String value) {
    stderr.write('host-stderr=$value');
  });
  final StreamIterator<Map<String, Object?>> messages =
      StreamIterator<Map<String, Object?>>(incoming.stream);
  stdout.writeln('host=${await _next(messages)}');

  int requestId = 1;
  Future<Map<String, Object?>> command(Map<String, Object?> message) async {
    process.stdin.add(
      encodeBackendHostFrame(<String, Object?>{
        'protocolVersion': backendHostProtocolVersion,
        'requestId': requestId++,
        ...message,
      }),
    );
    await process.stdin.flush();
    return _next(messages);
  }

  final Map<String, Object?> start = await command(<String, Object?>{
    'kind': 'startPlugin',
    'pluginId': 'dev.adele.workspace-demo',
    'artifactUri': File(arguments[2]).absolute.uri.toString(),
    'arguments': <String>[arguments[3]],
  });
  stdout.writeln('start=$start');
  final Map<String, Object?> listing = await command(<String, Object?>{
    'kind': 'request',
    'pluginId': 'dev.adele.workspace-demo',
    'method': 'workspaceDemo.listDirectory',
    'payload': <String, Object?>{
      'resource': <String, Object?>{
        'uri': Directory(arguments[3]).absolute.uri.toString(),
        'mediaType': null,
      },
    },
  });
  stdout.writeln('listing=$listing');
  stdout.writeln(
    'stop=${await command(<String, Object?>{'kind': 'stopPlugin', 'pluginId': 'dev.adele.workspace-demo'})}',
  );
  stdout.writeln(
    'restart=${await command(<String, Object?>{
      'kind': 'startPlugin',
      'pluginId': 'dev.adele.workspace-demo',
      'artifactUri': File(arguments[2]).absolute.uri.toString(),
      'arguments': <String>[arguments[3]],
    })}',
  );
  stdout.writeln(
    'restop=${await command(<String, Object?>{'kind': 'stopPlugin', 'pluginId': 'dev.adele.workspace-demo'})}',
  );
  stdout.writeln(
    'shutdown=${await command(<String, Object?>{'kind': 'shutdownHost'})}',
  );
  await process.stdin.close();
  stdout.writeln(
    'exitCode=${await process.exitCode.timeout(const Duration(seconds: 5))}',
  );
  await incoming.close();
}

Future<Map<String, Object?>> _next(
  StreamIterator<Map<String, Object?>> messages,
) async {
  if (!await messages.moveNext().timeout(const Duration(seconds: 10))) {
    throw StateError('Backend host output ended.');
  }
  return messages.current;
}
