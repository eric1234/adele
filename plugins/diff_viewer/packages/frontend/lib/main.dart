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
  List<List<String>> rows = [];
  Map<int, ReviewHunkSelection> approvals = {};
  Map<int, ReviewHunkSelection> unapprovals = {};
  Map<int, ReviewFileSelection> fileApprovals = {};
  Map<int, ReviewFileSelection> fileUnapprovals = {};
  ReviewLayerSelection? unstagedLayerSelection;
  ReviewLayerSelection? stagedLayerSelection;
  String reviewHandle = '';
  bool reviewPending = false;
  String reviewMessage = '';
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
    reviewMessage = '';
    invalidateReview();
    if (handle != '') {
      releaseEnvironmentCapabilityProvider(handle);
      handle = '';
    }
  }

  void invalidateReview() {
    approvals = {};
    unapprovals = {};
    fileApprovals = {};
    fileUnapprovals = {};
    unstagedLayerSelection = null;
    stagedLayerSelection = null;
    if (reviewHandle != '') {
      releaseEnvironmentCapabilityProvider(reviewHandle);
      reviewHandle = '';
    }
    // Pending tracks semantic settlement, not backend process quiescence.
    // Releasing access can fail the request without stopping admitted work.
  }

  void refresh() async {
    if (disposed) return;
    final canReview = !reviewPending;
    abandon();
    final captured = revision;
    final task = scope == 'task';
    final uncommitted = task || scope == 'uncommitted';
    setState(() {
      status = 'loading';
      rows = [];
    });
    final selected = await resolveEnvironmentBufferedProcessCapabilityProvider(
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
      appendFiles(next, snapshot.committed.files, 'committed');
      clean = snapshot.committed.files.isEmpty;
      if (clean) next.add(['status', 'No committed changes.']);
    }
    if (uncommitted) {
      final snapshot = task
          ? (result[1] as TaskChangeSetSnapshot).uncommitted
          : result[1] as UncommittedChangeSetSnapshot;
      if (snapshot.staged.layerReviewRevision != null) {
        stagedLayerSelection = ReviewLayerSelection(
          expectedRevision: snapshot.staged.layerReviewRevision!,
        );
      }
      if (snapshot.unstaged.layerReviewRevision != null) {
        unstagedLayerSelection = ReviewLayerSelection(
          expectedRevision: snapshot.unstaged.layerReviewRevision!,
        );
      }
      next.add(['section', 'Staged changes']);
      appendFiles(next, snapshot.staged.files, 'staged');
      if (snapshot.staged.files.isEmpty) {
        next.add(['status', 'No staged changes.']);
      }
      next.add(['section', 'Unstaged changes']);
      appendFiles(next, snapshot.unstaged.files, 'unstaged');
      if (snapshot.unstaged.files.isEmpty) {
        next.add(['status', 'No unstaged changes.']);
      }
      next.add(['section', 'Conflicts']);
      appendFiles(next, snapshot.conflicts, 'conflicts');
      if (snapshot.conflicts.isEmpty) next.add(['status', 'No conflicts.']);
      clean =
          clean &&
          snapshot.staged.files.isEmpty &&
          snapshot.unstaged.files.isEmpty &&
          snapshot.conflicts.isEmpty;
    } else {
      final snapshot = result[1] as ChangeSetSnapshot;
      if (snapshot.layerReviewRevision != null) {
        unstagedLayerSelection = ReviewLayerSelection(
          expectedRevision: snapshot.layerReviewRevision!,
        );
      }
      appendFiles(next, snapshot.files, 'unstaged');
      clean = snapshot.files.isEmpty;
    }
    if (!canReview) {
      // A snapshot started during mutation stays read-only even if releasing
      // access has already settled the old request. Only a later refresh opts in.
      invalidateReview();
      reviewMessage = 'Refresh again before reviewing these changes.';
    }
    setState(() {
      rows = next;
      status = clean ? 'clean' : 'ready';
    });
    if (approvals.isEmpty &&
        unapprovals.isEmpty &&
        fileApprovals.isEmpty &&
        fileUnapprovals.isEmpty &&
        unstagedLayerSelection == null &&
        stagedLayerSelection == null) {
      return;
    }
    final review = await resolveEnvironmentBufferedProcessCapabilityProvider(
      'adele.diff.review-approval',
      1,
      reviewApprovalHandlerServiceId,
      null,
    );
    if (disposed || captured != revision) {
      if (review != null) releaseEnvironmentCapabilityProvider(review);
      return;
    }
    setState(() {
      reviewHandle = review ?? '';
    });
  }

  void selectScope(String selected) {
    if (disposed || scope == selected) return;
    scope = selected;
    refresh();
  }

  void appendFiles(
    List<List<String>> next,
    List<ChangedFile> files,
    String layer,
  ) {
    for (final file in files) {
      final List<String> header = [
        'file',
        '${file.relativePath}  [${file.changeKind}]',
      ];
      if (layer == 'unstaged' &&
          file.contentStatus == 'text' &&
          (file.changeKind == 'added' ||
              file.changeKind == 'modified' ||
              file.changeKind == 'typeChanged')) {
        // Keep the typed path separate from the human-readable header.
        header.add(file.relativePath);
      }
      final fileRevision = file.fileReviewRevision;
      if ((layer == 'unstaged' || layer == 'staged') &&
          file.contentStatus == 'text' &&
          (file.changeKind == 'added' ||
              file.changeKind == 'deleted' ||
              (file.changeKind == 'modified' && file.hunks.isNotEmpty)) &&
          fileRevision != null) {
        // Certified empty additions/deletions need no displayed hunks.
        final selection = ReviewFileSelection(
          relativePath: file.relativePath,
          expectedRevision: fileRevision,
        );
        if (layer == 'unstaged') {
          fileApprovals[next.length] = selection;
        } else {
          fileUnapprovals[next.length] = selection;
        }
      }
      next.add(header);
      if (file.contentStatus != 'text') {
        next.add(['status', file.contentStatus]);
      }
      final detail = file.detail;
      if (detail != null) next.add(['status', detail]);
      for (int hunkIndex = 0; hunkIndex < file.hunks.length; hunkIndex++) {
        final hunk = file.hunks[hunkIndex];
        final expectedRevision = file.reviewRevision;
        if ((layer == 'unstaged' || layer == 'staged') &&
            file.changeKind == 'modified' &&
            file.contentStatus == 'text' &&
            expectedRevision != null) {
          final selection = ReviewHunkSelection(
            relativePath: file.relativePath,
            hunkIndex: hunkIndex,
            expectedRevision: expectedRevision,
          );
          if (layer == 'unstaged') {
            approvals[next.length] = selection;
          } else {
            unapprovals[next.length] = selection;
          }
        }
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
  }

  void reviewChange(Object selection, bool unapprove, int captured) async {
    if (disposed ||
        captured != revision ||
        status != 'ready' ||
        reviewHandle == '' ||
        reviewPending) {
      return;
    }
    final selected = reviewHandle;
    setState(() {
      reviewPending = true;
      reviewMessage = 'Review change pending...';
      if (selection is ReviewLayerSelection) {
        if (unapprove) {
          reviewMessage = 'Unapproving all staged changes...';
        } else {
          reviewMessage = 'Approving all unstaged changes...';
        }
      }
    });
    final client = ReviewApprovalHandlerServiceClient(
      EnvironmentCapabilityRequestChannel(selected),
    );
    Future<void> operation;
    if (selection is ReviewLayerSelection) {
      if (unapprove) {
        operation = client.unapproveAllStaged(selection);
      } else {
        operation = client.approveAllUnstaged(selection);
      }
    } else if (selection is ReviewFileSelection) {
      if (unapprove) {
        operation = client.unapproveFile(selection);
      } else {
        operation = client.approveFile(selection);
      }
    } else {
      final hunk = selection as ReviewHunkSelection;
      if (unapprove) {
        operation = client.unapproveHunk(hunk);
      } else {
        operation = client.approveHunk(hunk);
      }
    }
    final result = await settleEnvironmentCapabilityOperation(operation);
    releaseEnvironmentCapabilityProvider(selected);
    if (disposed) return;
    setState(() {
      reviewPending = false;
    });
    if (captured != revision) return;
    reviewHandle = '';
    invalidateReview();
    if (result[0] == true) {
      refresh();
    } else {
      setState(() {
        reviewMessage =
            'Review change not confirmed. Refresh before trying again.';
      });
    }
  }

  Widget reviewAction(Object selection, bool unapprove, int captured) {
    if (reviewPending) return Text('');
    if (!disposed && status == 'ready' && reviewHandle != '') {
      // The evaluator pin cannot reuse a branched primitive in a closure.
      if (unapprove) {
        if (selection is ReviewLayerSelection) {
          return TextButton(
            onPressed: () => reviewChange(selection, true, captured),
            child: Text('Unapprove All Staged'),
          );
        }
        return TextButton(
          onPressed: () => reviewChange(selection, true, captured),
          child: Text(
            selection is ReviewFileSelection ? 'Unapprove File' : 'Unapprove',
          ),
        );
      }
      if (selection is ReviewLayerSelection) {
        return TextButton(
          onPressed: () => reviewChange(selection, false, captured),
          child: Text('Approve All Unstaged'),
        );
      }
      return TextButton(
        onPressed: () => reviewChange(selection, false, captured),
        child: Text(
          selection is ReviewFileSelection ? 'Approve File' : 'Approve',
        ),
      );
    }
    return Text(
      'Review actions unavailable.',
      style: TextStyle(color: Colors.grey),
    );
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
      if (!disposed &&
          status == 'ready' &&
          reviewHandle != '' &&
          !reviewPending)
        Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (unstagedLayerSelection != null)
              reviewAction(unstagedLayerSelection!, false, revision),
            if (stagedLayerSelection != null)
              reviewAction(stagedLayerSelection!, true, revision),
          ],
        ),
      if (status == 'loading') Text('Loading $scope changes...'),
      if (status == 'unavailable')
        Text('Diff unavailable for this Environment.'),
      if (status == 'clean') Text('No $scope changes.'),
      if (status == 'error') Text('Unable to load $scope changes.'),
      if (status == 'error' || status == 'unavailable')
        TextButton(onPressed: refresh, child: Text('Retry')),
      if (sourceMessage != '') Text(sourceMessage),
      if (reviewMessage != '') Text(reviewMessage),
      Expanded(
        flex: 1,
        child: ListView.builder(
          itemCount: rows.length,
          // A typed native index keeps the evaluator's map keys boxed correctly.
          itemBuilder: (BuildContext context, int index) {
            final row = rows[index];
            final captured = revision;
            final approval = approvals[index];
            final unapproval = unapprovals[index];
            final fileApproval = fileApprovals[index];
            final fileUnapproval = fileUnapprovals[index];
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
            Widget content = label;
            if (row.length > 2 ||
                approval != null ||
                unapproval != null ||
                fileApproval != null ||
                fileUnapproval != null) {
              content = Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  label,
                  if (fileApproval != null)
                    reviewAction(fileApproval, false, captured),
                  if (fileUnapproval != null)
                    reviewAction(fileUnapproval, true, captured),
                  if (row.length > 2) sourceAction(row[2], captured),
                  if (approval != null) reviewAction(approval, false, captured),
                  if (unapproval != null)
                    reviewAction(unapproval, true, captured),
                ],
              );
            }
            return Container(
              color: background,
              padding: EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              child: content,
            );
          },
        ),
      ),
    ],
  );
}
