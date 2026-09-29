import 'dart:async';
import 'dart:io';

import 'package:command_tools_contract/command_tools_contract.dart';
import 'package:plugin_runtime/plugin_runtime.dart';

// Only the backend process and its output are fixtures. The generated service,
// owning-backend routing, stock EVC, and Console presentation host stay real.
Future<void> main() async {
  final output = _Output();
  final dispatcher = CommandOutputServiceDispatcher(output);
  final decoder = BackendHostFrameDecoder();
  var deliveredVersion = -1;
  void send(Map<String, Object?> frame) => stdout.add(
    encodeBackendHostFrame({
      'protocolVersion': backendHostProtocolVersion,
      ...frame,
    }),
  );

  send({'kind': 'hostHello'});
  await for (final bytes in stdin) {
    for (final frame in decoder.add(bytes)) {
      final route = {'pluginId': frame['pluginId']};
      switch (frame['kind']) {
        case 'startPlugin':
          send({
            'kind': 'pluginReady',
            'requestId': frame['requestId'],
            ...route,
          });
        case 'stopPlugin':
          await dispatcher.close();
          send({
            'kind': 'pluginStopped',
            'requestId': frame['requestId'],
            ...route,
          });
        case 'shutdownHost':
          send({'kind': 'hostStopped', 'requestId': frame['requestId']});
          await stdout.flush();
          return;
        case 'request' when frame['serviceId'] != commandOutputServiceId:
          if (frame['method'] == 'append') {
            output.append((frame['payload']! as Map)['text']! as String);
          }
          send({
            'kind': 'response',
            'requestId': frame['requestId'],
            ...route,
            'ok': true,
            'payload': {'deliveredVersion': deliveredVersion},
          });
        default:
          await dispatcher.handle(
            {
              for (final key in [
                'kind',
                'requestId',
                'method',
                'payload',
                'credit',
              ])
                if (frame.containsKey(key)) key: frame[key],
            },
            (reply) {
              if (reply['kind'] == 'streamItem') {
                deliveredVersion =
                    (reply['payload']! as Map)['version']! as int;
              }
              send({...reply, ...route});
            },
          );
      }
    }
  }
}

final class _Output implements CommandOutputService {
  final chunks = <CommandOutputChunk>[];
  final observers = <StreamController<CommandCaptureState>>{};
  int units = 0;

  void append(String text) {
    if (text.length > commandOutputChunkCodeUnits) {
      throw ArgumentError('Fixture append must fit one stored chunk.');
    }
    chunks.add(
      CommandOutputChunk(
        cursor: chunks.length + 1,
        stream: 'stdout',
        text: text,
      ),
    );
    units += text.length;
    for (final observer in observers) {
      observer.add(state);
    }
  }

  CommandCaptureState get state => CommandCaptureState(
    sessionId: 'a',
    runId: 'run',
    toolInvocationId: 'invocation',
    state: 'capturing',
    version: chunks.length,
    highWater: chunks.length,
    totalCodeUnits: units,
    program: 'fixture',
    argumentsJson: '[]',
    workingDirectory: '',
    environmentId: 'additional',
    timeoutSeconds: 30,
    termination: null,
    exitCode: null,
    failure: null,
  );

  @override
  Future<CommandCaptureState> getState(
    String sessionId,
    String runId,
    String toolInvocationId,
  ) async => state;

  @override
  Future<CommandOutputPage> readAfter(
    String sessionId,
    String runId,
    String toolInvocationId,
    int afterCursor,
    int maxChunks,
    int maxCodeUnits,
  ) async => CommandOutputPage(
    state: state,
    chunks: chunks.skip(afterCursor).take(maxChunks).toList(),
  );

  @override
  Future<CommandOutputPage> readBefore(
    String sessionId,
    String runId,
    String toolInvocationId,
    int? beforeCursor,
    int maxChunks,
    int maxCodeUnits,
  ) => throw StateError('Stock reader must reconstruct the accepted prefix.');

  @override
  Stream<CommandCaptureState> watch(
    String sessionId,
    String runId,
    String toolInvocationId,
  ) {
    late final StreamController<CommandCaptureState> observer;
    observer = StreamController<CommandCaptureState>(
      onListen: () {
        observers.add(observer);
        observer.add(state);
      },
      onCancel: () => observers.remove(observer),
    );
    return observer.stream;
  }
}
