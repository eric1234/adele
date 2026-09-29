import 'dart:async';

import 'package:adele_ui/console_bridge.dart';
import 'package:adele_ui/inspection_display.dart';
import 'package:adele_ui/owning_backend_bridge.dart';
import 'package:adele_ui/terminal_projection_bridge.dart';
import 'package:command_tools_contract/command_tools_contract.dart';
import 'package:flutter/material.dart';

Widget buildRunCommandOutput() {
  final data = readConsoleContentData();
  return CommandOutputView(
    sessionId: data['sessionId'] as String,
    runId: data['runId'] as String,
    invocationId: data['toolInvocationId'] as String,
    title: data['title'] as String,
    expanded: true,
  );
}

/// Independent reader and emulator per presentation. Only scalar reading position
/// survives console unmount; a fresh emulator always reconstructs its prefix.
class CommandOutputView extends StatefulWidget {
  CommandOutputView({
    required this.sessionId,
    required this.runId,
    required this.invocationId,
    required this.title,
    this.expanded = false,
  });

  final String sessionId;
  final String runId;
  final String invocationId;
  final String title;
  final bool expanded;

  @override
  State<CommandOutputView> createState() =>
      _CommandOutputViewState(sessionId, runId, invocationId, title, expanded);
}

class _CommandOutputViewState extends State<CommandOutputView> {
  _CommandOutputViewState(
    this.sessionId,
    this.runId,
    this.invocationId,
    this.title,
    this.expanded,
  );

  final String sessionId;
  final String runId;
  final String invocationId;
  final String title;
  final bool expanded;
  final CommandOutputServiceClient client = CommandOutputServiceClient(
    OwningBackendRequestChannel(commandOutputServiceId),
  );
  // The pin misdeclares Stream.listen's result; retain it dynamically.
  dynamic subscription;
  void Function() projectionListener = () {};
  // Explicit nullable initializer is required by the pinned evaluator.
  // ignore: avoid_init_to_null
  CommandCaptureState? capture = null;
  List<CommandOutputChunk> page = <CommandOutputChunk>[];
  String projection = '';
  String failure = '';
  String openingFailure = '';
  bool disposed = false;
  bool draining = false;
  bool following = true;
  bool liveTail = true;
  bool replaying = true;
  bool resetPending = false;
  bool opening = false;
  int revision = 0;
  int cursor = 0;
  int chunkIndex = 0;
  int chunkOffset = 0;
  int consumedUnits = 0;
  int lines = 0;
  int knownLines = 0;
  int windowRows = 178;
  int rows = 20;
  int targetLines = -1;
  int targetUnits = -1;
  double restoreScroll = 0;

  @override
  void initState() {
    super.initState();
    projectionListener = () => projectionChanged();
    if (expanded) {
      final retained = readConsoleContentState();
      if (retained['following'] == false) {
        following = false;
        liveTail = retained['liveTail'] as bool;
        targetUnits = retained['codeUnits'] as int;
        restoreScroll = (retained['scrollOffset'] as num).toDouble();
        knownLines = retained['knownLines'] as int;
      }
    }
    final Stream<CommandCaptureState> changes = client.watch(
      sessionId,
      runId,
      invocationId,
    );
    subscription = changes.listen(
      (CommandCaptureState value) {
        if (disposed || failure.isNotEmpty) return;
        acceptState(value, false);
        drain();
      },
      onError: (Object error) {
        fail(
          'Output reader unavailable. Close and reopen to try fresh access.',
        );
      },
      onDone: () {
        final state = capture;
        if (!disposed &&
            failure.isEmpty &&
            (state == null ||
                state.state == 'absent' ||
                state.state == 'capturing')) {
          fail(
            'Live output observation ended. Stored output may be incomplete.',
          );
        }
      },
    );
  }

  void acceptState(CommandCaptureState value, bool pageSnapshot) {
    if (value.sessionId != sessionId ||
        value.runId != runId ||
        value.toolInvocationId != invocationId) {
      fail('Output association is unavailable.');
      return;
    }
    final previous = capture;
    // Pages may return an older snapshot than a concurrently delivered watch.
    if (previous == null ||
        value.version > previous.version ||
        (!pageSnapshot && value.version == previous.version)) {
      capture = value;
    }
    if (value.state == 'absent') replaying = false;
    if (projection.isEmpty && value.state != 'absent') {
      projection = requestTerminalProjection(expanded ? 20 : 6, !expanded);
      if (!following) {
        // Prefix restoration follows locally, but is not a live-end gesture.
        setTerminalProjectionFollow(projection, true, false);
      }
      final geometry = readTerminalProjection(projection);
      rows = geometry['rows'] as int;
      windowRows = (geometry['maxLines'] as int) - rows - 2;
      subscribeTerminalProjection(projection, projectionListener);
    }
    setState(() {});
  }

  void fail(String message) {
    if (disposed) return;
    failure = message;
    replaying = false;
    subscription?.cancel();
    setState(() {});
  }

  void projectionChanged() {
    if (disposed || projection.isEmpty || failure.isNotEmpty) return;
    final state = readTerminalProjection(projection);
    if (state['following'] == false && (following || replaying)) {
      following = false;
      replaying = false;
      targetLines = -1;
      targetUnits = -1;
      revision++;
    } else if (state['following'] == true &&
        !following &&
        !replaying &&
        liveTail) {
      // Only the native user-return transition can re-enable a frozen live
      // projection. Explicit windows and programmatic replay never take it.
      follow();
      return;
    }
    remember();
    setState(() {});
  }

  void remember([bool includeReplay = false]) {
    if (!expanded ||
        disposed ||
        projection.isEmpty ||
        (replaying && !includeReplay)) {
      return;
    }
    final state = readTerminalProjection(projection);
    writeConsoleContentState(<String, dynamic>{
      'following': following,
      'liveTail': liveTail,
      'codeUnits': consumedUnits,
      'knownLines': knownLines,
      'scrollOffset': state['scrollOffset'],
    });
  }

  /// One drain owns at most four stored chunks and one 1,024-unit feed. Watch
  /// notifications only update extent/state; they never enqueue another chain.
  Future<void> drain() async {
    if (draining || disposed || failure.isNotEmpty || projection.isEmpty) {
      return;
    }
    draining = true;
    while (!disposed && failure.isEmpty) {
      if (resetPending) {
        resetPending = false;
        resetTerminalProjection(projection);
        cursor = 0;
        chunkIndex = 0;
        chunkOffset = 0;
        consumedUnits = 0;
        lines = 0;
        page = <CommandOutputChunk>[];
      }
      if (!following && !replaying) {
        settleDrain();
        return;
      }
      if ((targetLines >= 0 && lines >= targetLines) ||
          (targetUnits >= 0 && consumedUnits >= targetUnits)) {
        finishHistory();
        settleDrain();
        return;
      }
      final native = readTerminalProjection(projection);
      if (native['following'] == false) {
        // User scrolling freezes the native projection synchronously, including
        // while a generated read was in flight. No text/cursor is discarded.
        following = false;
        replaying = false;
        settleDrain();
        return;
      }
      if (chunkIndex >= page.length) {
        page = <CommandOutputChunk>[];
        chunkIndex = 0;
        if (cursor >= capture!.highWater) {
          if (!following) {
            finishHistory();
          } else {
            replaying = false;
          }
          settleDrain();
          return;
        }
        replaying = true;
        setState(() {});
        final requested = revision;
        final result = await settleOwningBackendOperation(
          client.readAfter(sessionId, runId, invocationId, cursor, 4, 16384),
        );
        if (disposed) return;
        if (failure.isNotEmpty) {
          settleDrain();
          return;
        }
        if (requested != revision) {
          draining = false;
          drain();
          return;
        }
        if (result[0] != true) {
          fail(
            'Stored output could not be read. Close and reopen to try fresh access.',
          );
          settleDrain();
          return;
        }
        final next = result[1] as CommandOutputPage;
        acceptState(next.state, true);
        if (failure.isNotEmpty) {
          settleDrain();
          return;
        }
        if (next.chunks.isEmpty) {
          // We requested only a known committed extent, so empty is a gap here,
          // never evidence of command completion.
          fail('Committed output is unavailable.');
          settleDrain();
          return;
        }
        page = next.chunks;
      }
      final chunk = page[chunkIndex];
      if (chunk.cursor != cursor + 1 ||
          chunk.text.isEmpty ||
          chunk.text.length > 4096 ||
          (chunk.stream != 'stdout' && chunk.stream != 'stderr')) {
        fail('Stored output continuity is unavailable.');
        settleDrain();
        return;
      }
      int end = chunkOffset + 1024;
      if (end > chunk.text.length) end = chunk.text.length;
      if (targetUnits >= 0 && end - chunkOffset > targetUnits - consumedUnits) {
        end = chunkOffset + targetUnits - consumedUnits;
      }
      if (end < chunk.text.length && end > chunkOffset) {
        final unit = chunk.text.codeUnitAt(end - 1);
        if (unit >= 55296 && unit <= 56319) end--;
      }
      int budget = rows;
      if (targetLines >= 0 && targetLines - lines < budget) {
        budget = targetLines - lines;
      }
      final accepted = feedTerminalProjection(
        projection,
        chunk.text.substring(chunkOffset, end),
        budget,
      );
      if (accepted == 0) {
        if (readTerminalProjection(projection)['following'] == false) {
          following = false;
          replaying = false;
        } else {
          fail('Output rendering is unavailable.');
        }
        settleDrain();
        return;
      }
      if (accepted < 0 || accepted > end - chunkOffset) {
        fail('Output rendering continuity is unavailable.');
        settleDrain();
        return;
      }
      chunkOffset += accepted;
      consumedUnits += accepted;
      if (chunkOffset == chunk.text.length) {
        cursor = chunk.cursor;
        chunkOffset = 0;
        chunkIndex++;
      }
      final applied = readTerminalProjection(projection);
      lines = applied['lineAdvances'] as int;
      if (lines > knownLines) knownLines = lines;
      setState(() {});
      // Give input, scroll, dismissal and rendering a turn between bounded feeds.
      final active = await yieldTerminalProjection(projection);
      if (!active) return;
    }
    settleDrain();
  }

  // Explicit exits avoid the pinned evaluator's nested async loop jumps.
  void settleDrain() {
    draining = false;
    if (!disposed) {
      remember();
      setState(() {});
    }
  }

  void finishHistory() {
    replaying = false;
    following = false;
    targetLines = -1;
    targetUnits = -1;
    setTerminalProjectionFollow(projection, false, liveTail);
    scrollTerminalProjection(projection, restoreScroll);
  }

  void history(int endLine) {
    if (disposed || projection.isEmpty || failure.isNotEmpty) return;
    revision++;
    liveTail = false;
    following = false;
    replaying = true;
    targetLines = endLine < windowRows ? windowRows : endLine;
    targetUnits = -1;
    restoreScroll = 0;
    resetPending = true;
    setTerminalProjectionFollow(projection, true, false);
    remember(true);
    setState(() {});
    drain();
  }

  void follow() {
    if (disposed || projection.isEmpty || failure.isNotEmpty) return;
    revision++;
    liveTail = true;
    following = true;
    replaying = true;
    targetLines = -1;
    targetUnits = -1;
    setTerminalProjectionFollow(projection, true, true);
    // Retain the user's new mode even if this view hides during catch-up. The
    // position still describes only text accepted by this projection.
    remember(true);
    setState(() {});
    drain();
  }

  Future<void> showMore() async {
    if (disposed || opening) return;
    opening = true;
    openingFailure = '';
    setState(() {});
    // Length-delimited opaque key, scoped again by exact owner and Session in
    // the host. Identical argv never participates in output identity.
    final result = await openPreparedConsole(
      'dev.adele.plugin.command-tools.output',
      '${runId.length}:$runId${invocationId.length}:$invocationId',
      title,
      <String, dynamic>{
        'sessionId': sessionId,
        'runId': runId,
        'toolInvocationId': invocationId,
        'title': title,
      },
    );
    if (disposed) return;
    opening = false;
    if (result[0] != true) openingFailure = 'Expanded output is unavailable.';
    setState(() {});
  }

  @override
  void dispose() {
    disposed = true;
    revision++;
    subscription?.cancel();
    if (projection.isNotEmpty) {
      unsubscribeTerminalProjection(projection, projectionListener);
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = capture;
    String status = 'Connecting to output...';
    if (failure.isNotEmpty) status = 'Output state unavailable.';
    if (state != null) {
      status = 'Capture: ${state.state}';
      if (state.state == 'absent') {
        status = 'No output capture has been admitted.';
      }
      if (state.state == 'complete' && state.highWater == 0) {
        status = 'Capture complete: no output.';
      }
      if (state.state == 'failed' || state.state == 'interrupted') {
        status =
            'Capture incomplete (${state.state}); committed output remains available.';
      }
      if (state.termination != null) {
        status =
            '$status | Process: ${state.termination} | Exit: ${state.exitCode ?? 'Not reported'}';
      }
    }
    String readingStatus = 'Reading history';
    if (following) readingStatus = 'Following output';
    if (replaying) readingStatus = 'Replaying output...';
    final controls = <Widget>[
      Text(status, maxLines: 2, overflow: TextOverflow.ellipsis),
      if (failure.isNotEmpty) Text(failure, maxLines: 2),
      if (projection.isNotEmpty) Text(readingStatus),
      if (expanded && projection.isNotEmpty)
        SizedBox(
          height: 40,
          child: ListView(
            scrollDirection: Axis.horizontal,
            children: <Widget>[
              TextButton(
                onPressed: () => history(windowRows),
                child: Text('Beginning'),
              ),
              TextButton(
                onPressed: () => history(lines - windowRows),
                child: Text('Earlier'),
              ),
              TextButton(
                onPressed: () => history(knownLines ~/ 2),
                child: Text('Middle'),
              ),
              TextButton(
                onPressed: () => history(lines + windowRows),
                child: Text('Later'),
              ),
              IconButton(
                tooltip: 'Follow output',
                onPressed: () {
                  if (!following || replaying) follow();
                },
                icon: Icon(Icons.arrow_downward),
              ),
            ],
          ),
        ),
    ];
    if (expanded) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          ...controls,
          if (projection.isNotEmpty)
            Expanded(flex: 1, child: buildTerminalProjection(projection)),
        ],
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        ...controls,
        if (projection.isNotEmpty)
          SizedBox(height: 128, child: buildTerminalProjection(projection)),
        if (state != null && state.state != 'absent')
          TextButton(onPressed: () => showMore(), child: Text('Show more')),
        if (openingFailure.isNotEmpty)
          Text(inspectionDisplayText(openingFailure)),
      ],
    );
  }
}
