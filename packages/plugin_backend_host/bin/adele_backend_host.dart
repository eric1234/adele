import 'dart:async';
import 'dart:io';

import 'package:plugin_backend_host/plugin_backend_host.dart';

Future<void> main() async {
  final BackendHostFrameDecoder decoder = BackendHostFrameDecoder();
  final StreamController<Map<String, Object?>> messages =
      StreamController<Map<String, Object?>>();
  late final StreamSubscription<List<int>> stdinSubscription;
  stdinSubscription = stdin.listen(
    (List<int> bytes) {
      try {
        for (final Map<String, Object?> message in decoder.add(bytes)) {
          messages.add(message);
        }
      } on Object catch (error, stackTrace) {
        stderr.writeln('backend-host protocol failure: $error\n$stackTrace');
        exitCode = 65;
        messages.close();
      }
    },
    onDone: messages.close,
    onError: messages.addError,
    cancelOnError: true,
  );

  final AdeleBackendHost host = AdeleBackendHost(send: _send);
  _send(<String, Object?>{
    'protocolVersion': backendHostProtocolVersion,
    'kind': 'hostHello',
  });
  await for (final Map<String, Object?> message in messages.stream) {
    if (!await host.handle(message)) {
      await stdinSubscription.cancel();
      await messages.close();
      await stdout.flush();
      return;
    }
  }
}

void _send(Map<String, Object?> message) {
  stdout.add(encodeBackendHostFrame(message));
}
