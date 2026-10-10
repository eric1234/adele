import 'package:adele_ui/environment_capability_bridge.dart';
import 'package:adele_ui/main_content_bridge.dart';
import 'package:adele_ui/session_presentation_lifecycle_bridge.dart';
import 'package:diff_viewer_contract/diff_viewer_contract.dart';
import 'package:flutter/material.dart';

void initializeDiff() {
  final context = readMainContentContext();
  if (context['sessionId'] != null) {
    openMainContentPane('diff', 'Diff', false);
  }
}

Widget buildDiffPane() => DiffPane();

class DiffPane extends StatefulWidget {
  @override
  State<DiffPane> createState() => DiffPaneState();
}

class DiffPaneState extends State<DiffPane> {
  bool disposed = false;
  int revision = 0;
  String handle = '';
  String status = 'loading';
  List<List<String>> rows = [];
  bool sourcePending = false;
  String sourceMessage = '';
  Future<bool> Function() departure = () async => true;

  @override
  void initState() {
    super.initState();
    departure = () async {
      abandon();
      // Another pane can refuse departure. This pane stays refreshable then.
      setState(() {
        status = 'unavailable';
        rows = [];
      });
      return true;
    };
    registerSessionPrepareToDeactivate(departure);
    refresh();
  }

  void abandon() {
    revision++;
    sourceMessage = '';
    if (handle != '') {
      releaseEnvironmentCapabilityProvider(handle);
      handle = '';
    }
  }

  void refresh() async {
    if (disposed) return;
    abandon();
    final captured = revision;
    setState(() {
      status = 'loading';
      rows = [];
    });
    final selected = await resolveEnvironmentCapabilityProvider(
      'adele.diff.change-set-source',
      1,
      changeSetSourceServiceId,
      null,
    );
    if (disposed || captured != revision) {
      if (selected != null) releaseEnvironmentCapabilityProvider(selected);
      return;
    }
    if (selected == null) {
      setState(() {
        status = 'unavailable';
      });
      return;
    }
    handle = selected;
    final ChangeSetSourceServiceClient client = ChangeSetSourceServiceClient(
      EnvironmentCapabilityRequestChannel(selected),
    );
    final result = await settleEnvironmentCapabilityOperation(
      client.snapshotUnstaged(),
    );
    releaseEnvironmentCapabilityProvider(selected);
    if (disposed || captured != revision) return;
    handle = '';
    if (result[0] != true) {
      setState(() {
        status = 'error';
      });
      return;
    }
    final snapshot = result[1] as ChangeSetSnapshot;
    final List<List<String>> next = [];
    for (final file in snapshot.files) {
      final List<String> header = [
        'file',
        '${file.relativePath}  [${file.changeKind}]',
      ];
      if (file.contentStatus == 'text' &&
          (file.changeKind == 'added' ||
              file.changeKind == 'modified' ||
              file.changeKind == 'typeChanged')) {
        // Keep the typed path separate from the human-readable header.
        header.add(file.relativePath);
      }
      next.add(header);
      if (file.contentStatus != 'text') {
        next.add(['status', file.contentStatus]);
      }
      final detail = file.detail;
      if (detail != null) next.add(['status', detail]);
      for (final hunk in file.hunks) {
        next.add([
          'hunk',
          '@@ -${hunk.oldStart},${hunk.oldCount} +${hunk.newStart},${hunk.newCount} @@',
        ]);
        int oldLine = hunk.oldStart;
        int newLine = hunk.newStart;
        for (final line in hunk.lines) {
          String oldNumber = '';
          String newNumber = '';
          String prefix = ' ';
          if (line.kind != 'addition') {
            oldNumber = '$oldLine';
            oldLine++;
          }
          if (line.kind != 'deletion') {
            newNumber = '$newLine';
            newLine++;
          }
          if (line.kind == 'addition') prefix = '+';
          if (line.kind == 'deletion') prefix = '-';
          next.add([
            line.kind,
            '${oldNumber.padLeft(4)} ${newNumber.padLeft(4)} $prefix${line.text}',
          ]);
          if (line.noNewline) {
            next.add(['status', r'\ No newline at end of file']);
          }
        }
      }
    }
    setState(() {
      rows = next;
      status = snapshot.files.isEmpty ? 'clean' : 'ready';
    });
  }

  String sourceStatusMessage(String state) {
    if (state == 'success' || state == 'available') return '';
    if (state == 'ambiguous') return 'Multiple Source providers are available.';
    if (state == 'unavailable' || state == 'denied' || state == 'retired') {
      return 'Source is unavailable.';
    }
    return 'Unable to open file in Source.';
  }

  void openSource(String path, int captured) async {
    if (disposed ||
        captured != revision ||
        status != 'ready' ||
        sourcePending) {
      return;
    }
    final availability = sourceDisplayAvailability();
    if (availability != 'available') {
      final message = sourceStatusMessage(availability);
      setState(() {
        sourceMessage = message;
      });
      return;
    }
    setState(() {
      sourcePending = true;
      sourceMessage = '';
    });
    final result = await displaySourceFile(path);
    if (disposed) return;
    // Read bridged maps before entering a captured evaluator setState closure.
    final state = result['status'];
    final message = sourceStatusMessage(state is String ? state : 'failed');
    setState(() {
      sourcePending = false;
      if (captured == revision) sourceMessage = message;
    });
  }

  Widget sourceAction(String path, int captured) {
    final availability = sourceDisplayAvailability();
    if (availability == 'available' && !sourcePending) {
      return TextButton(
        onPressed: () => openSource(path, captured),
        child: Text('Open in Source'),
      );
    }
    // The evaluator pin uses a non-null callback for native TextButton bindings.
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Text(
        sourcePending
            ? 'Opening in Source...'
            : sourceStatusMessage(availability),
        style: TextStyle(color: Colors.grey),
      ),
    );
  }

  @override
  void dispose() {
    disposed = true;
    abandon();
    unregisterSessionPrepareToDeactivate(departure);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Row(
        children: [
          Expanded(flex: 1, child: Text('Unstaged changes')),
          TextButton(onPressed: refresh, child: Text('Refresh')),
        ],
      ),
      if (status == 'loading') Text('Loading unstaged changes...'),
      if (status == 'unavailable')
        Text('Diff unavailable for this Environment.'),
      if (status == 'clean') Text('No unstaged changes.'),
      if (status == 'error') Text('Unable to load unstaged changes.'),
      if (status == 'error' || status == 'unavailable')
        TextButton(onPressed: refresh, child: Text('Retry')),
      if (sourceMessage != '') Text(sourceMessage),
      Expanded(
        flex: 1,
        child: ListView.builder(
          itemCount: rows.length,
          itemBuilder: (context, index) {
            final row = rows[index];
            final captured = revision;
            final label = Text(
              row[1],
              style: TextStyle(fontFamily: 'monospace', fontSize: 12),
            );
            Color background = Colors.transparent;
            if (row[0] == 'addition') background = Color(0x1822aa55);
            if (row[0] == 'deletion') background = Color(0x18dd3344);
            if (row[0] == 'file') background = Color(0x18888888);
            return Container(
              color: background,
              padding: EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              child: row.length > 2
                  ? Row(
                      children: [
                        Expanded(flex: 2, child: label),
                        Expanded(
                          flex: 1,
                          child: sourceAction(row[2], captured),
                        ),
                      ],
                    )
                  : label,
            );
          },
        ),
      ),
    ],
  );
}
