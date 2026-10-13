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
  String scope = 'unstaged';
  String status = 'loading';
  // Action rows retain source path at 2, then review label, revision,
  // granularity, raw path and hunk index at 3..7. Never parse display paths.
  List<List<String>> rows = [];
  bool sourcePending = false;
  String sourceMessage = '';
  String reviewHandle = '';
  bool reviewPending = false;
  bool reviewBlocked = false;
  String reviewMessage = '';
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
    reviewMessage = '';
    reviewBlocked = false;
    if (handle != '') {
      releaseEnvironmentCapabilityProvider(handle);
      handle = '';
    }
    if (reviewHandle != '') {
      // Release fences publication, not independently admitted provider effects.
      releaseEnvironmentCapabilityProvider(reviewHandle);
      reviewHandle = '';
    }
  }

  void refresh() async {
    if (disposed) return;
    abandon();
    final captured = revision;
    final task = scope == 'task';
    final uncommitted = task || scope == 'uncommitted';
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
    // Keep the selected Future in a local: nested conditionals misbox on the pin.
    Future<Object?> operation;
    if (task) {
      operation = client.snapshotTaskChanges();
    } else if (uncommitted) {
      operation = client.snapshotUncommitted();
    } else {
      operation = client.snapshotUnstaged();
    }
    final result = await settleEnvironmentCapabilityOperation(operation);
    releaseEnvironmentCapabilityProvider(selected);
    if (disposed || captured != revision) return;
    handle = '';
    if (result[0] != true) {
      setState(() {
        status = 'error';
      });
      return;
    }
    final List<List<String>> next = [];
    bool clean = true;
    if (task) {
      final snapshot = result[1] as TaskChangeSetSnapshot;
      next.add(['section', 'Committed changes']);
      appendFiles(next, snapshot.committed.files, false, '', null);
      clean = snapshot.committed.files.isEmpty;
      if (clean) next.add(['status', 'No committed changes.']);
    }
    if (uncommitted) {
      final snapshot = task
          ? (result[1] as TaskChangeSetSnapshot).uncommitted
          : result[1] as UncommittedChangeSetSnapshot;
      appendLayer(
        next,
        snapshot.staged,
        'Staged changes',
        'Unapprove',
        false,
        snapshot.conflicts.isEmpty,
      );
      if (snapshot.staged.files.isEmpty) {
        next.add(['status', 'No staged changes.']);
      }
      appendLayer(
        next,
        snapshot.unstaged,
        'Unstaged changes',
        'Approve',
        true,
        snapshot.conflicts.isEmpty,
      );
      if (snapshot.unstaged.files.isEmpty) {
        next.add(['status', 'No unstaged changes.']);
      }
      next.add(['section', 'Conflicts']);
      appendFiles(next, snapshot.conflicts, false, '', null);
      if (snapshot.conflicts.isEmpty) next.add(['status', 'No conflicts.']);
      clean =
          clean &&
          snapshot.staged.files.isEmpty &&
          snapshot.unstaged.files.isEmpty &&
          snapshot.conflicts.isEmpty;
    } else {
      final snapshot = result[1] as ChangeSetSnapshot;
      appendLayer(next, snapshot, '', 'Approve', true, true);
      clean = snapshot.files.isEmpty;
    }
    setState(() {
      rows = next;
      status = clean ? 'clean' : 'ready';
    });
    for (final row in next) {
      if (row.length > 3) {
        resolveReview(captured);
        return;
      }
    }
  }

  void selectScope(String selected) {
    if (disposed || scope == selected) return;
    scope = selected;
    refresh();
  }

  void appendFiles(
    List<List<String>> next,
    List<ChangedFile> files,
    bool currentWorking,
    String verb,
    String? expectedRevision,
  ) {
    for (final file in files) {
      final List<String> header = [
        'file',
        '${file.relativePath}  [${file.changeKind}]',
        '',
      ];
      if (currentWorking &&
          file.contentStatus == 'text' &&
          (file.changeKind == 'added' ||
              file.changeKind == 'modified' ||
              file.changeKind == 'typeChanged')) {
        // Keep the typed path separate from the human-readable header.
        header[2] = file.relativePath;
      }
      final eligible =
          verb != '' &&
          expectedRevision != null &&
          expectedRevision != '' &&
          reviewEligible(file);
      if (eligible) {
        header.addAll([
          '$verb File',
          expectedRevision,
          'file',
          file.relativePath,
          '',
        ]);
      }
      next.add(header);
      if (file.contentStatus != 'text') {
        next.add(['status', file.contentStatus]);
      }
      final detail = file.detail;
      if (detail != null) next.add(['status', detail]);
      for (int hunkIndex = 0; hunkIndex < file.hunks.length; hunkIndex++) {
        final hunk = file.hunks[hunkIndex];
        final List<String> hunkRow = [
          'hunk',
          '@@ -${hunk.oldStart},${hunk.oldCount} +${hunk.newStart},${hunk.newCount} @@',
          '',
        ];
        if (eligible) {
          hunkRow.addAll([
            verb,
            expectedRevision,
            'hunk',
            file.relativePath,
            '$hunkIndex',
          ]);
        }
        next.add(hunkRow);
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
  }

  bool reviewEligible(ChangedFile file) =>
      file.reviewEligible &&
      file.contentStatus == 'text' &&
      (file.changeKind == 'added' ||
          file.changeKind == 'modified' ||
          file.changeKind == 'deleted');

  void appendLayer(
    List<List<String>> next,
    ChangeSetSnapshot snapshot,
    String label,
    String verb,
    bool currentWorking,
    bool wholeLayer,
  ) {
    final expectedRevision = snapshot.reviewRevision;
    bool eligible =
        expectedRevision != null &&
        expectedRevision != '' &&
        snapshot.files.isNotEmpty &&
        wholeLayer;
    for (final file in snapshot.files) {
      if (!reviewEligible(file)) eligible = false;
    }
    final List<String> section = ['section', label, ''];
    if (eligible) {
      section.addAll([
        currentWorking ? 'Approve All Unstaged' : 'Unapprove All Staged',
        expectedRevision!,
        'layer',
        '',
        '',
      ]);
    }
    if (label != '' || eligible) next.add(section);
    appendFiles(next, snapshot.files, currentWorking, verb, expectedRevision);
  }

  void resolveReview(int captured) async {
    final selected = await resolveEnvironmentReviewCapability(
      'adele.diff.review-approval',
      1,
      reviewApprovalServiceId,
      null,
    );
    if (disposed || captured != revision) {
      if (selected != null) releaseEnvironmentCapabilityProvider(selected);
      return;
    }
    if (selected != null) {
      setState(() {
        reviewHandle = selected;
      });
    }
  }

  void changeReview(List<String> row, int captured) async {
    if (disposed ||
        captured != revision ||
        status != 'ready' ||
        reviewHandle == '' ||
        reviewPending ||
        reviewBlocked) {
      return;
    }
    final client = ReviewApprovalServiceClient(
      EnvironmentCapabilityRequestChannel(reviewHandle),
    );
    // Nullable conditional expressions misbox on the pinned evaluator.
    String? path;
    int? hunkIndex;
    if (row[5] != 'layer') path = row[6];
    if (row[5] == 'hunk') hunkIndex = int.parse(row[7]);
    final selection = ReviewSelection(
      expectedRevision: row[4],
      granularity: row[5],
      relativePath: path,
      hunkIndex: hunkIndex,
    );
    setState(() {
      reviewPending = true;
      reviewMessage = '';
    });
    Future<Object?> operation;
    if (row[3].startsWith('Unapprove')) {
      operation = client.unapprove(selection);
    } else {
      operation = client.approve(selection);
    }
    final result = await settleEnvironmentCapabilityOperation(operation);
    if (disposed) return;
    setState(() {
      reviewPending = false;
    });
    if (captured != revision) return;
    String outcome = 'failed';
    if (result[0] == true) {
      outcome = (result[1] as ReviewApprovalResult).status;
    }
    if (outcome == 'applied') {
      refresh();
      return;
    }
    String message =
        'Unable to update review approval. Refresh to check changes.';
    if (outcome == 'stale') {
      message = 'Changes are stale. Refresh before reviewing again.';
    } else if (outcome == 'ineligible') {
      message =
          'Changes are not eligible for review approval. Refresh to check changes.';
    }
    releaseEnvironmentCapabilityProvider(reviewHandle);
    setState(() {
      reviewHandle = '';
      reviewBlocked = true;
      reviewMessage = message;
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
          Expanded(
            flex: 1,
            child: TextButton(
              onPressed: () => selectScope('unstaged'),
              child: Text(
                'Unstaged changes',
                style: TextStyle(
                  fontWeight: scope == 'unstaged'
                      ? FontWeight.bold
                      : FontWeight.normal,
                ),
              ),
            ),
          ),
          Expanded(
            flex: 1,
            child: TextButton(
              onPressed: () => selectScope('uncommitted'),
              child: Text(
                'Uncommitted changes',
                style: TextStyle(
                  fontWeight: scope == 'uncommitted'
                      ? FontWeight.bold
                      : FontWeight.normal,
                ),
              ),
            ),
          ),
          Expanded(
            flex: 1,
            child: TextButton(
              onPressed: () => selectScope('task'),
              child: Text(
                'Task / Branch',
                style: TextStyle(
                  fontWeight: scope == 'task'
                      ? FontWeight.bold
                      : FontWeight.normal,
                ),
              ),
            ),
          ),
        ],
      ),
      TextButton(onPressed: refresh, child: Text('Refresh')),
      if (status == 'loading') Text('Loading $scope changes...'),
      if (status == 'unavailable')
        Text('Diff unavailable for this Environment.'),
      if (status == 'clean') Text('No $scope changes.'),
      if (status == 'error') Text('Unable to load $scope changes.'),
      if (status == 'error' || status == 'unavailable')
        TextButton(onPressed: refresh, child: Text('Retry')),
      if (sourceMessage != '') Text(sourceMessage),
      if (reviewPending) Text('Updating review approval...'),
      if (reviewMessage != '') Text(reviewMessage),
      Expanded(
        flex: 1,
        child: ListView.builder(
          itemCount: rows.length,
          itemBuilder: (context, index) {
            final row = rows[index];
            final captured = revision;
            final hasSource = row.length > 2 && row[2] != '';
            final hasReview =
                row.length > 3 &&
                reviewHandle != '' &&
                !reviewPending &&
                !reviewBlocked;
            if (row[0] == 'section' && row[1] == '' && !hasReview) {
              return SizedBox();
            }
            final label = Text(
              row[1],
              style: row[0] == 'section'
                  ? TextStyle(fontSize: 14, fontWeight: FontWeight.bold)
                  : TextStyle(fontFamily: 'monospace', fontSize: 12),
            );
            Color background = Colors.transparent;
            if (row[0] == 'addition') background = Color(0x1822aa55);
            if (row[0] == 'deletion') background = Color(0x18dd3344);
            if (row[0] == 'file') background = Color(0x18888888);
            if (row[0] == 'section') background = Color(0x28888888);
            return Container(
              color: background,
              padding: EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              child: hasSource || hasReview
                  ? Row(
                      children: [
                        Expanded(flex: 2, child: label),
                        Expanded(
                          flex: 1,
                          child: Column(
                            children: [
                              if (hasSource) sourceAction(row[2], captured),
                              if (hasReview)
                                TextButton(
                                  onPressed: () => changeReview(row, captured),
                                  child: Text(row[3]),
                                ),
                            ],
                          ),
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
