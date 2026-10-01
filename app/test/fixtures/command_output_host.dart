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
          output.releaseReads();
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
          final payload = frame['payload']! as Map;
          final invocation = payload['invocation'] as String? ?? 'invocation';
          switch (frame['method']) {
            case 'append':
              output.append(payload['text']! as String);
            case 'hold':
              output.gates[invocation] = Completer<void>();
            case 'release':
              output.releaseReads(invocation);
            case 'releaseAndHoldNext':
              final previous = output.gates[invocation]!;
              output.gates[invocation] = Completer<void>();
              previous.complete();
            case 'failNextRead':
              output.failNext.add(invocation);
          }
          send({
            'kind': 'response',
            'requestId': frame['requestId'],
            ...route,
            'ok': true,
            'payload': {
              'deliveredVersion': deliveredVersion,
              'watches': output.watches,
              'observers': output.observers.values.toList(),
              'cursors': output.cursors,
              'activeReads': output.activeReads,
              'maximumReads': output.maximumReads,
              'maximumPageChunks': output.maximumPageChunks,
              'maximumPageUnits': output.maximumPageUnits,
              'units': output.units,
              'highWater': output.chunks.length,
            },
          });
        default:
          // A held generated read must not block control/barrier requests.
          unawaited(
            dispatcher.handle(
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
            ),
          );
      }
    }
  }
}

final class _Output implements CommandOutputService {
  final chunks = <CommandOutputChunk>[];
  final observers = <StreamController<CommandCaptureState>, String>{};
  final watches = <String, int>{};
  final cursors = <String, List<int>>{};
  final activeReads = <String, int>{};
  final maximumReads = <String, int>{};
  final gates = <String, Completer<void>>{};
  final failNext = <String>{};
  int units = 0;
  int maximumPageChunks = 0;
  int maximumPageUnits = 0;

  void releaseReads([String? invocation]) {
    for (final id in gates.keys.toList()) {
      if (invocation == null || id == invocation) {
        gates.remove(id)!.complete();
      }
    }
  }

  void append(String text) {
    for (var offset = 0; offset < text.length;) {
      var end = offset + commandOutputChunkCodeUnits;
      if (end > text.length) end = text.length;
      if (end < text.length &&
          text.codeUnitAt(end - 1) >= 0xd800 &&
          text.codeUnitAt(end - 1) <= 0xdbff) {
        end--;
      }
      chunks.add(
        CommandOutputChunk(
          cursor: chunks.length + 1,
          stream: 'stdout',
          text: text.substring(offset, end),
        ),
      );
      offset = end;
    }
    units += text.length;
    for (final entry in observers.entries) {
      entry.key.add(state(entry.value));
    }
  }

  CommandCaptureState state(String invocation) => CommandCaptureState(
    sessionId: 'a',
    runId: 'run',
    toolInvocationId: invocation,
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
  ) async => state(toolInvocationId);

  @override
  Future<CommandOutputPage> readAfter(
    String sessionId,
    String runId,
    String toolInvocationId,
    int afterCursor,
    int maxChunks,
    int maxCodeUnits,
  ) async {
    if (maxChunks != 4 || maxCodeUnits != 16384) {
      throw StateError('Stock reader exceeded its bounded page request.');
    }
    (cursors[toolInvocationId] ??= []).add(afterCursor);
    final active = activeReads.update(
      toolInvocationId,
      (value) => value + 1,
      ifAbsent: () => 1,
    );
    if (active > (maximumReads[toolInvocationId] ?? 0)) {
      maximumReads[toolInvocationId] = active;
    }
    final page = CommandOutputPage(
      state: state(toolInvocationId),
      chunks: chunks.skip(afterCursor).take(maxChunks).toList(),
    );
    if (page.chunks.length > maximumPageChunks) {
      maximumPageChunks = page.chunks.length;
    }
    final pageUnits = page.chunks.fold<int>(
      0,
      (sum, chunk) => sum + chunk.text.length,
    );
    if (pageUnits > maximumPageUnits) maximumPageUnits = pageUnits;
    try {
      await gates[toolInvocationId]?.future;
      if (failNext.remove(toolInvocationId)) {
        throw StateError('SECRET fixture storage failure');
      }
      return page;
    } finally {
      activeReads[toolInvocationId] = activeReads[toolInvocationId]! - 1;
    }
  }

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
        watches.update(
          toolInvocationId,
          (value) => value + 1,
          ifAbsent: () => 1,
        );
        observers[observer] = toolInvocationId;
        observer.add(state(toolInvocationId));
      },
      onCancel: () => observers.remove(observer),
    );
    return observer.stream;
  }
}
