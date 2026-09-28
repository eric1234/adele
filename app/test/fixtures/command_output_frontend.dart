import 'package:adele_ui/owning_backend_bridge.dart';
import 'package:command_tools_contract/command_tools_contract.dart';
import 'package:flutter/material.dart';

const sessionId = 'FIXTURE_SESSION';
const runId = 'FIXTURE_RUN';
const invocationId = 'FIXTURE_INVOCATION';

Widget buildView() => CommandOutputFixture();

/// A transport probe, deliberately not the stock output viewer.
class CommandOutputFixture extends StatefulWidget {
  @override
  State<CommandOutputFixture> createState() => CommandOutputFixtureState();
}

class CommandOutputFixtureState extends State<CommandOutputFixture> {
  final client = CommandOutputServiceClient(
    OwningBackendRequestChannel(commandOutputServiceId),
  );
  // The pinned evaluator misdeclares Stream.listen's compile-time return type.
  dynamic subscription;
  String captureState = 'loading';
  int cursor = 0;
  int highWater = 0;
  int codeUnits = 0;
  bool draining = false;
  bool disposed = false;
  String failure = '';
  final seen = <String, bool>{};
  final tails = <String, String>{};

  @override
  void initState() {
    super.initState();
    subscription = client
        .watch(sessionId, runId, invocationId)
        .listen(
          (CommandCaptureState state) {
            if (disposed) return;
            captureState = state.state;
            highWater = state.highWater;
            drain();
          },
          onError: (Object error) {
            if (disposed) return;
            setState(() {
              failure = error.toString();
            });
          },
        );
  }

  void drain() {
    if (draining || disposed) return;
    if (cursor >= highWater) {
      setState(() {});
      return;
    }
    draining = true;
    // Keep rejected unary Futures at PreparedFrontend's failure boundary on the pin.
    client.readAfter(sessionId, runId, invocationId, cursor, 16, 65536).then((
      CommandOutputPage page,
    ) {
      if (disposed) return;
      if (page.chunks.isEmpty) {
        throw StateError('Missing committed output.');
      }
      for (final chunk in page.chunks) {
        if (chunk.cursor != cursor + 1) {
          throw StateError('Non-contiguous page.');
        }
        if (chunk.text.length > 4096) {
          throw StateError('Unbounded chunk.');
        }
        cursor = chunk.cursor;
        codeUnits += chunk.text.length;
        final text = (tails[chunk.stream] ?? '') + chunk.text;
        for (final stage in ['START', 'MIDDLE', 'LATE', 'HIDDEN']) {
          final marker = '${chunk.stream}:$stage';
          if (text.contains(marker)) seen[marker] = true;
        }
        tails[chunk.stream] = text.length > 64
            ? text.substring(text.length - 64)
            : text;
      }
      draining = false;
      drain();
    });
  }

  @override
  void dispose() {
    disposed = true;
    subscription?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Column(
    children: <Widget>[
      Text('state:$captureState'),
      Text('cursor:$cursor'),
      Text('codeUnits:$codeUnits'),
      Text('failure:$failure'),
      for (final stream in ['stdout', 'stderr'])
        for (final stage in ['START', 'MIDDLE', 'LATE', 'HIDDEN'])
          Text('$stream:$stage=${seen['$stream:$stage'] == true}'),
    ],
  );
}
