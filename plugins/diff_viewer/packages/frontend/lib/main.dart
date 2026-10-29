import 'package:adele_ui/environment_capability_bridge.dart';
import 'package:adele_ui/main_content_bridge.dart';
import 'package:adele_ui/owning_backend_bridge.dart';
import 'package:adele_ui/session_feedback_bridge.dart';
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
  String sessionId = '';
  String environmentId = '';
  final ReviewDraftServiceClient draftClient = ReviewDraftServiceClient(
    OwningBackendRequestChannel(reviewDraftServiceId),
  );
  TextEditingController editor = TextEditingController();
  List<PendingReviewComment> comments = [];
  bool commentsLoaded = false;
  String commentStatus = 'loading';
  String commentMessage = '';
  bool commentPending = false;
  int commentRevision = 0;
  int editorRevision = 0;
  int displayedDraftRevision = -1;
  int submissionRevision = 0;
  bool submissionPending = false;
  bool submissionLoaded = false;
  bool acceptanceRetryAllowed = false;
  String submissionMessage = '';
  // ignore: avoid_init_to_null
  PreparedReviewSubmission? submission = null;
  // ignore: avoid_init_to_null
  ReviewSubmissionSummary? submissionSummary = null;
  // The evaluator pin requires explicit null initializers for boxed fields.
  // ignore: avoid_init_to_null
  ReviewCommentAnchor? editorAnchor = null;
  // ignore: avoid_init_to_null
  PendingReviewComment? editingComment = null;
  String originalText = '';
  bool editorInvalid = false;
  bool editorMultiline = false;
  Map<int, ReviewCommentAnchor> lineAnchors = {};
  Map<String, List<ChangedFile>> inspected = {};
  Future<bool> Function() departure = () async => true;

  @override
  void initState() {
    super.initState();
    final context = readMainContentContext();
    final session = context['sessionId'];
    final environment = context['environmentKey'];
    if (session is String) sessionId = session;
    if (environment is String) environmentId = environment;
    departure = () async {
      if (commentPending ||
          (editorAnchor != null && editor.text != originalText)) {
        setState(() {
          commentMessage =
              'Save or cancel the comment before leaving this Session.';
        });
        return false;
      }
      commentRevision++;
      editorRevision++;
      submissionRevision++;
      submissionPending = false;
      submissionLoaded = false;
      acceptanceRetryAllowed = false;
      commentStatus = 'unavailable';
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
    lineAnchors = {};
    inspected = {};
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
    reloadComments();
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
    final result = await settleEnvironmentCapabilityOperation(
      operation,
      selected,
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
    inspected[layer] = files;
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
        // Arithmetic materializes primitive counters from evaluated DTO fields.
        int oldLine = hunk.oldStart + 0;
        int newLine = hunk.newStart + 0;
        int oldRemaining = hunk.oldCount + 0;
        int newRemaining = hunk.newCount + 0;
        for (int lineIndex = 0; lineIndex < hunk.lines.length; lineIndex++) {
          final line = hunk.lines[lineIndex];
          String oldNumber = '';
          String newNumber = '';
          String prefix = ' ';
          final int oldPosition = oldLine;
          final int newPosition = newLine;
          final hasOld =
              (line.kind == 'deletion' || line.kind == 'context') &&
              oldRemaining > 0 &&
              oldLine > 0;
          final hasNew =
              (line.kind == 'addition' || line.kind == 'context') &&
              newRemaining > 0 &&
              newLine > 0;
          if (hasOld) {
            oldNumber = '$oldLine';
            oldLine++;
            oldRemaining--;
          }
          if (hasNew) {
            newNumber = '$newLine';
            newLine++;
            newRemaining--;
          }
          if (line.kind == 'addition') prefix = '+';
          if (line.kind == 'deletion') prefix = '-';
          ReviewCommentAnchor? anchor;
          if (line.kind == 'deletion') {
            anchor = anchorForLine(
              file,
              layer,
              hunkIndex,
              lineIndex,
              oldPosition,
              hasOld,
            );
          } else {
            anchor = anchorForLine(
              file,
              layer,
              hunkIndex,
              lineIndex,
              newPosition,
              hasNew,
            );
          }
          if (anchor != null) lineAnchors[next.length] = anchor;
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

  ReviewCommentAnchor? anchorForLine(
    ChangedFile file,
    String layer,
    int hunkIndex,
    int lineIndex,
    int position,
    bool sideExists,
  ) {
    final identity = file.commentComparisonIdentity;
    if (!sideExists ||
        environmentId == '' ||
        environmentId.length > ReviewDraftLimits.maxIdentityLength ||
        file.contentStatus != 'text' ||
        file.changeKind == 'conflicted' ||
        file.changeKind == 'unsupported' ||
        layer == 'conflicts' ||
        identity == null ||
        identity.trim().isEmpty ||
        identity.length > ReviewDraftLimits.maxComparisonIdentityLength ||
        identity.codeUnits.any((unit) => unit < 32 || unit > 126) ||
        hunkIndex > ReviewDraftLimits.maxHunkIndex ||
        lineIndex > ReviewDraftLimits.maxLineIndex ||
        position < 1 ||
        position > ReviewDraftLimits.maxLine) {
      return null;
    }
    final path = file.relativePath;
    if (path.length > ReviewDraftLimits.maxPathLength ||
        path.contains('\\') ||
        path.codeUnits.any((unit) => unit == 0) ||
        RegExp(r'^[A-Za-z]:').hasMatch(path) ||
        path
            .split('/')
            .any(
              (part) =>
                  part == '' || part == '.' || part == '..' || part == '.git',
            )) {
      return null;
    }
    final line = file.hunks[hunkIndex].lines[lineIndex];
    if (line.kind != 'addition' &&
        line.kind != 'deletion' &&
        line.kind != 'context') {
      return null;
    }
    final excerpt = line.noNewline ? line.text : '${line.text}\n';
    if (excerpt.length > ReviewDraftLimits.maxExcerptLength) {
      return null;
    }
    ReviewComparisonLayer comparisonLayer = ReviewComparisonLayer.unstaged;
    if (layer == 'staged') comparisonLayer = ReviewComparisonLayer.staged;
    if (layer == 'committed') comparisonLayer = ReviewComparisonLayer.committed;
    return ReviewCommentAnchor(
      environmentId: environmentId,
      relativePath: path,
      layer: comparisonLayer,
      side: line.kind == 'deletion'
          ? ReviewComparisonSide.oldSide
          : ReviewComparisonSide.newSide,
      startLine: position,
      endLine: position,
      comparisonIdentity: identity,
      sourceExcerpt: excerpt,
      hunkIndex: hunkIndex,
      lineIndex: lineIndex,
    );
  }

  String layerName(ReviewComparisonLayer layer) {
    if (layer == ReviewComparisonLayer.staged) return 'staged';
    if (layer == ReviewComparisonLayer.committed) return 'committed';
    return 'unstaged';
  }

  String locationLabel(ReviewCommentAnchor anchor) {
    final side = anchor.side == ReviewComparisonSide.oldSide ? 'old' : 'new';
    return '${anchor.relativePath} | ${layerName(anchor.layer)} | $side line ${anchor.startLine}';
  }

  String locationStatus(ReviewCommentAnchor anchor) {
    final layer = layerName(anchor.layer);
    if (anchor.environmentId != environmentId ||
        (status != 'ready' && status != 'clean') ||
        !inspected.containsKey(layer)) {
      return 'Outside current scope / not inspected';
    }
    if (anchor.layer != ReviewComparisonLayer.committed &&
        inspected.containsKey('conflicts')) {
      for (final file in inspected['conflicts']!) {
        if (file.relativePath == anchor.relativePath) {
          return 'Outside current scope / not inspected';
        }
      }
    }
    final files = inspected[layer]!;
    for (final file in files) {
      if (file.relativePath == anchor.relativePath) {
        // Incomplete evidence is not proof that the original source changed.
        if (file.commentComparisonIdentity == null) {
          return 'Outside current scope / not inspected';
        }
        if (file.commentComparisonIdentity != anchor.comparisonIdentity) {
          return 'Outdated location';
        }
        if (anchor.startLine != anchor.endLine) {
          return 'Outside current scope / not inspected';
        }
        if (anchor.hunkIndex < file.hunks.length) {
          final hunk = file.hunks[anchor.hunkIndex];
          final old = anchor.side == ReviewComparisonSide.oldSide;
          int position = hunk.newStart + 0;
          int remaining = hunk.newCount + 0;
          if (old) {
            position = hunk.oldStart + 0;
            remaining = hunk.oldCount + 0;
          }
          for (int index = 0; index < hunk.lines.length; index++) {
            final line = hunk.lines[index];
            final onSide =
                line.kind == 'context' ||
                (old ? line.kind == 'deletion' : line.kind == 'addition');
            if (index == anchor.lineIndex) {
              final excerpt = line.noNewline ? line.text : '${line.text}\n';
              if (onSide &&
                  remaining > 0 &&
                  position > 0 &&
                  position == anchor.startLine &&
                  excerpt == anchor.sourceExcerpt) {
                return 'Current location';
              }
              return 'Outdated location';
            }
            if (onSide) {
              position++;
              remaining--;
            }
          }
        }
        return 'Outdated location';
      }
    }
    // A successful complete scope with no original path proves its disappearance.
    // An unsupported inventory placeholder instead leaves inspection incomplete.
    for (final file in files) {
      if (file.changeKind == 'unsupported') {
        return 'Outside current scope / not inspected';
      }
    }
    return 'Outdated location';
  }

  bool canMutateComments() =>
      !disposed &&
      commentStatus == 'ready' &&
      !commentPending &&
      !submissionPending &&
      !commentsFrozen() &&
      !reviewPending;

  bool commentsFrozen() {
    final current = submissionSummary;
    return current != null &&
        (current.status == ReviewSubmissionStatus.prepared ||
            current.status == ReviewSubmissionStatus.deliveryPending);
  }

  Future<void> reloadComments() async {
    if (disposed || commentPending || submissionPending) return;
    submissionRevision++;
    commentRevision++;
    final captured = commentRevision;
    setState(() {
      commentStatus = 'loading';
      displayedDraftRevision = -1;
      submissionLoaded = false;
      acceptanceRetryAllowed = false;
    });
    final result = await settleOwningBackendOperation(
      draftClient.snapshot(sessionId),
    );
    if (disposed || captured != commentRevision) return;
    if (result[0] != true) {
      setState(() {
        commentStatus = 'unavailable';
        commentMessage =
            'Comment storage unavailable. Reload comments to try again.';
      });
      return;
    }
    final snapshot = result[1] as ReviewDraftSnapshot;
    if (snapshot.sessionId != sessionId) {
      setState(() {
        commentStatus = 'unavailable';
        commentMessage =
            'Comment storage unavailable. Reload comments to try again.';
      });
      return;
    }
    final selected = editingComment;
    if (selected != null) {
      bool matches = false;
      for (final comment in snapshot.comments) {
        if (comment.id == selected.id && comment.version == selected.version) {
          matches = true;
        }
      }
      if (!matches) editorInvalid = true;
    }
    setState(() {
      comments = snapshot.comments;
      displayedDraftRevision = snapshot.revision;
      submissionSummary = snapshot.currentReview;
      commentsLoaded = true;
      commentStatus = 'ready';
      commentMessage = '';
    });
    final review = await settleOwningBackendOperation(
      draftClient.readReview(sessionId),
    );
    if (disposed || captured != commentRevision || submissionPending) return;
    if (review[0] != true) {
      setState(() {
        submissionMessage =
            'Review state unavailable. Reload comments to reconcile.';
      });
      return;
    }
    // The evaluator pin's nullable DTO cast rejects null; branch before casting.
    final summary = snapshot.currentReview;
    if (review[1] == null) {
      if (summary != null) {
        inconsistentReviewSnapshot();
        return;
      }
      setState(() {
        submissionLoaded = true;
        submission = null;
        submissionMessage = '';
      });
      return;
    }
    final current = review[1] as PreparedReviewSubmission;
    // A recovered payload must describe the same handoff as the displayed
    // snapshot, not a newer frozen collection prepared between these reads.
    if (current.sessionId != sessionId ||
        summary == null ||
        summary.submissionId != current.submissionId ||
        summary.status != current.status ||
        summary.commentCount != current.commentCount ||
        summary.schedulingAttempt != current.schedulingAttempt ||
        summary.occurrenceId != current.occurrenceId ||
        summary.runId != current.runId) {
      inconsistentReviewSnapshot();
      return;
    }
    setState(() {
      submissionLoaded = true;
      rememberSubmission(current);
      submissionMessage = '';
    });
  }

  void inconsistentReviewSnapshot() {
    setState(() {
      submissionLoaded = false;
      submission = null;
      displayedDraftRevision = -1;
      commentStatus = 'unavailable';
      submissionMessage =
          'Review changed while loading. Reload comments before continuing.';
    });
  }

  void rememberSubmission(PreparedReviewSubmission current) {
    submission = current;
    submissionSummary = ReviewSubmissionSummary(
      submissionId: current.submissionId,
      status: current.status,
      commentCount: current.commentCount,
      schedulingAttempt: current.schedulingAttempt,
      occurrenceId: current.occurrenceId,
      runId: current.runId,
    );
  }

  bool canSubmitReview() {
    final current = submission;
    return !disposed &&
        submissionLoaded &&
        !submissionPending &&
        !commentPending &&
        commentStatus == 'ready' &&
        displayedDraftRevision >= 0 &&
        comments.isNotEmpty &&
        editorAnchor == null &&
        (current == null || current.status == ReviewSubmissionStatus.scheduled);
  }

  bool submissionActive(int captured) =>
      !disposed && captured == submissionRevision;

  void finishSubmission(String message, bool reload) async {
    setState(() {
      submissionPending = false;
      submissionMessage = message;
    });
    if (reload) {
      final reloaded = submissionRevision + 1;
      await reloadComments();
      if (!submissionActive(reloaded)) return;
      final current = submission;
      if (current == null ||
          current.status != ReviewSubmissionStatus.scheduled) {
        setState(() {
          submissionMessage = message;
        });
      }
    }
  }

  void unconfirmedSubmission() {
    setState(() {
      submissionPending = false;
      submissionLoaded = false;
      acceptanceRetryAllowed = false;
      displayedDraftRevision = -1;
      commentStatus = 'uncertain';
      submissionMessage =
          'Review change not confirmed. Reload comments to reconcile before retrying.';
    });
  }

  bool matchingReceipt(
    Map<String, Object?> result,
    PreparedReviewSubmission current,
  ) =>
      result['sessionId'] == current.sessionId &&
      result['submissionId'] == current.submissionId;

  // One explicit action owns this chain. Read/reconcile never dispatches delivery
  // or a Run, and every external effect follows its durable admission marker.
  void submitReview(String action, int epoch, int displayedRevision) async {
    if (!submissionActive(epoch) ||
        submissionPending ||
        commentPending ||
        !submissionLoaded ||
        editorAnchor != null) {
      return;
    }
    final availability = readSessionFeedbackAvailability();
    if (action == 'submit' &&
        (!canSubmitReview() ||
            displayedRevision != displayedDraftRevision ||
            availability['available'] != true ||
            availability['canStart'] != true)) {
      return;
    }
    PreparedReviewSubmission? current = submission;
    if (action != 'submit' && current == null) return;
    if (action == 'deliver' &&
        current!.status != ReviewSubmissionStatus.prepared) {
      return;
    }
    if (action == 'retryAcceptance' &&
        (!acceptanceRetryAllowed ||
            current!.status != ReviewSubmissionStatus.deliveryPending)) {
      return;
    }
    if (action == 'reconcileAcceptance' &&
        current!.status != ReviewSubmissionStatus.deliveryPending) {
      return;
    }
    if (action == 'run' && current!.status != ReviewSubmissionStatus.accepted) {
      return;
    }
    if (action == 'reconcileRun' &&
        current!.status != ReviewSubmissionStatus.schedulingPending &&
        current.status != ReviewSubmissionStatus.accepted) {
      return;
    }
    submissionRevision++;
    commentRevision++;
    final captured = submissionRevision;
    setState(() {
      submissionPending = true;
      acceptanceRetryAllowed = false;
      submissionMessage = 'Submitting review...';
    });

    if (action == 'submit') {
      final prepared = await settleOwningBackendOperation(
        draftClient.prepareReview(sessionId, displayedRevision),
      );
      if (!submissionActive(captured)) return;
      if (prepared[0] != true) {
        unconfirmedSubmission();
        return;
      }
      final preparation = prepared[1] as ReviewPreparationResult;
      if (preparation.submission == null) {
        final code = preparation.rejectionCode;
        if (code == 'submission_too_large') {
          setState(() {
            submissionPending = false;
          });
          final reloaded = submissionRevision + 1;
          await reloadComments();
          if (!submissionActive(reloaded)) return;
          setState(() {
            submissionMessage =
                'The complete saved review is too large to submit. Nothing was truncated or split. Edit or delete saved comments before trying again.';
          });
          return;
        }
        String message =
            'Review preparation rejected. Reload comments before trying again.';
        if (code == 'stale_draft') {
          message =
              'Saved comments changed. Reload comments before submitting review.';
        }
        if (code == 'empty_review') {
          message = 'No saved comments to submit. Reload comments.';
        }
        if (code == 'review_conflict') {
          message =
              'A saved review already exists. Reload comments to reconcile.';
        }
        if (code == 'counter_exhausted') {
          message =
              'Review submission limit reached. Reload comments to inspect saved state.';
        }
        setState(() {
          submissionPending = false;
          submissionLoaded = false;
          displayedDraftRevision = -1;
          commentStatus = 'unavailable';
          submissionMessage = message;
        });
        return;
      }
      final next = preparation.submission!;
      if (next.sessionId != sessionId ||
          next.status != ReviewSubmissionStatus.prepared) {
        unconfirmedSubmission();
        return;
      }
      current = next;
      setState(() {
        rememberSubmission(next);
      });
    }
    // The canonical string is backend-authored. Never decode, rebuild or narrow
    // it to the currently visible Git scope or the local editor contents.
    final prepared = current!;
    if (action == 'submit' || action == 'deliver') {
      final marked = await settleOwningBackendOperation(
        draftClient.markDeliveryAttempted(sessionId, prepared.submissionId),
      );
      if (!submissionActive(captured)) return;
      if (marked[0] != true) {
        unconfirmedSubmission();
        return;
      }
      final next = marked[1] as PreparedReviewSubmission;
      current = next;
      setState(() {
        rememberSubmission(next);
      });
    }

    if (action == 'submit' ||
        action == 'deliver' ||
        action == 'retryAcceptance' ||
        action == 'reconcileAcceptance') {
      Future<Map<String, Object?>> operation;
      if (action == 'reconcileAcceptance') {
        operation = lookupSessionFeedback(prepared.canonicalPayload);
      } else {
        operation = acceptSessionFeedback(prepared.canonicalPayload);
      }
      final settled = await settleOwningBackendOperation(operation);
      if (!submissionActive(captured)) return;
      if (settled[0] != true) {
        finishSubmission(
          'Review acceptance uncertain. Reconcile acceptance before retrying.',
          false,
        );
        return;
      }
      final result = settled[1] as Map<String, Object?>;
      final occurrence = result['occurrenceId'];
      if (result['status'] != 'accepted' ||
          !matchingReceipt(result, prepared) ||
          occurrence is! String ||
          occurrence == '') {
        final retry =
            action == 'reconcileAcceptance' &&
            result['status'] == 'absent' &&
            result['retryAllowed'] == true &&
            matchingReceipt(result, prepared);
        setState(() {
          acceptanceRetryAllowed = retry;
        });
        finishSubmission(
          retry
              ? 'Review not accepted. Retry sends the same saved review.'
              : 'Review acceptance uncertain. Reconcile acceptance before retrying.',
          false,
        );
        return;
      }
      final confirmed = await settleOwningBackendOperation(
        draftClient.confirmAcceptance(
          sessionId,
          prepared.submissionId,
          prepared.sessionId,
          // The evaluator does not promote bridged Object values after guards.
          result['occurrenceId'] as String,
        ),
      );
      if (!submissionActive(captured)) return;
      if (confirmed[0] != true) {
        unconfirmedSubmission();
        return;
      }
      final next = confirmed[1] as PreparedReviewSubmission;
      current = next;
      setState(() {
        rememberSubmission(next);
        displayedDraftRevision = -1;
        commentStatus = 'loading';
      });
      if (action == 'reconcileAcceptance') {
        finishSubmission('', true);
        return;
      }
    }

    final accepted = current;
    final reconcilingAccepted =
        action == 'reconcileRun' &&
        accepted.status == ReviewSubmissionStatus.accepted;
    final uncertainRunMessage = reconcilingAccepted
        ? 'Review accepted. Existing Run association not confirmed.'
        : 'Review accepted. Run scheduling uncertain. Reconcile Run; do not start again.';
    final occurrence = accepted.occurrenceId;
    if (occurrence == null) {
      unconfirmedSubmission();
      return;
    }
    if (action != 'reconcileRun') {
      final ready = readSessionFeedbackAvailability();
      if (ready['available'] != true || ready['canStart'] != true) {
        finishSubmission('Review accepted. Run not started.', true);
        return;
      }
      final marked = await settleOwningBackendOperation(
        draftClient.markSchedulingAttempted(
          sessionId,
          accepted.submissionId,
          occurrence,
        ),
      );
      if (!submissionActive(captured)) return;
      if (marked[0] != true) {
        unconfirmedSubmission();
        return;
      }
      final next = marked[1] as PreparedReviewSubmission;
      current = next;
      setState(() {
        rememberSubmission(next);
        submissionMessage = 'Review accepted. Starting Run...';
      });
    }
    Future<Map<String, Object?>> operation;
    int schedulingAttempt = current.schedulingAttempt + 0;
    if (action == 'reconcileRun') {
      operation = lookupSessionFeedbackRun(
        accepted.canonicalPayload,
        occurrence,
      );
    } else {
      operation = startSessionFeedbackRun(
        accepted.canonicalPayload,
        occurrence,
        schedulingAttempt,
      );
    }
    final settled = await settleOwningBackendOperation(operation);
    if (!submissionActive(captured)) return;
    if (settled[0] != true) {
      finishSubmission(uncertainRunMessage, !reconcilingAccepted);
      return;
    }
    final result = settled[1] as Map<String, Object?>;
    if (!matchingReceipt(result, accepted) ||
        result['occurrenceId'] != occurrence) {
      finishSubmission(uncertainRunMessage, !reconcilingAccepted);
      return;
    }
    final runId = result['runId'];
    Future<PreparedReviewSubmission> confirmation;
    if (result['status'] == 'scheduled' && runId is String && runId != '') {
      if (reconcilingAccepted) {
        // A normal Chat Run may already own this occurrence. Record its proven
        // association only after lookup, without dispatching another Run.
        final marked = await settleOwningBackendOperation(
          draftClient.markSchedulingAttempted(
            sessionId,
            accepted.submissionId,
            occurrence,
          ),
        );
        if (!submissionActive(captured)) return;
        if (marked[0] != true) {
          unconfirmedSubmission();
          return;
        }
        final next = marked[1] as PreparedReviewSubmission;
        schedulingAttempt = next.schedulingAttempt + 0;
        setState(() {
          rememberSubmission(next);
        });
      }
      confirmation = draftClient.confirmRunScheduled(
        sessionId,
        accepted.submissionId,
        occurrence,
        schedulingAttempt,
        result['runId'] as String,
      );
    } else if (!reconcilingAccepted &&
        result['status'] == 'not_started' &&
        result['retryAllowed'] == true) {
      confirmation = draftClient.confirmRunNotStarted(
        sessionId,
        accepted.submissionId,
        occurrence,
        schedulingAttempt,
      );
    } else {
      finishSubmission(uncertainRunMessage, !reconcilingAccepted);
      return;
    }
    final confirmed = await settleOwningBackendOperation(confirmation);
    if (!submissionActive(captured)) return;
    if (confirmed[0] != true) {
      unconfirmedSubmission();
      return;
    }
    final next = confirmed[1] as PreparedReviewSubmission;
    setState(() {
      rememberSubmission(next);
    });
    finishSubmission(
      next.status == ReviewSubmissionStatus.accepted
          ? 'Review accepted. Run not started.'
          : '',
      true,
    );
  }

  Widget submissionControls() {
    final current = submission;
    final epoch = submissionRevision;
    final displayed = displayedDraftRevision;
    final availability = readSessionFeedbackAvailability();
    final available = availability['available'] == true;
    final canStart = available && availability['canStart'] == true;
    final reason = availability['reason'];
    final actionable =
        submissionLoaded &&
        !submissionPending &&
        !commentPending &&
        editorAnchor == null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (commentsLoaded && displayed >= 0)
          Text('Saved comments revision: $displayed'),
        if (canSubmitReview() && canStart)
          TextButton(
            onPressed: () => submitReview('submit', epoch, displayed),
            child: Text('Submit Review'),
          ),
        if (commentsLoaded && comments.isNotEmpty && editorAnchor != null)
          Text('Save or cancel the open comment before submitting review.'),
        if (commentsLoaded && !canStart)
          Text(reason is String ? reason : 'Review submission unavailable.'),
        if (current != null &&
            current.status == ReviewSubmissionStatus.prepared)
          Text(
            'Saved review prepared (${current.commentCount} comments). Not delivered.',
          ),
        if (current != null &&
            current.status == ReviewSubmissionStatus.deliveryPending)
          Text('Review delivery attempted. Acceptance not confirmed.'),
        if (current != null &&
            current.status == ReviewSubmissionStatus.accepted)
          Text('Review accepted. Run scheduling not recorded.'),
        if (current != null &&
            current.status == ReviewSubmissionStatus.schedulingPending)
          Text('Review accepted. Run scheduling not confirmed.'),
        if (current != null &&
            current.status == ReviewSubmissionStatus.scheduled)
          Text('Review accepted. Run scheduled: ${current.runId}'),
        if (submissionMessage != '') Text(submissionMessage),
        if (actionable &&
            current != null &&
            current.status == ReviewSubmissionStatus.prepared &&
            available)
          TextButton(
            onPressed: () => submitReview('deliver', epoch, displayed),
            child: Text('Deliver prepared review'),
          ),
        if (actionable &&
            current != null &&
            current.status == ReviewSubmissionStatus.deliveryPending)
          TextButton(
            onPressed: () =>
                submitReview('reconcileAcceptance', epoch, displayed),
            child: Text('Reconcile acceptance'),
          ),
        if (actionable && acceptanceRetryAllowed && available)
          TextButton(
            onPressed: () => submitReview('retryAcceptance', epoch, displayed),
            child: Text('Retry same review'),
          ),
        if (actionable &&
            current != null &&
            current.status == ReviewSubmissionStatus.accepted &&
            canStart)
          TextButton(
            onPressed: () => submitReview('run', epoch, displayed),
            child: Text('Retry Run'),
          ),
        if (actionable &&
            current != null &&
            (current.status == ReviewSubmissionStatus.schedulingPending ||
                current.status == ReviewSubmissionStatus.accepted))
          TextButton(
            onPressed: () => submitReview('reconcileRun', epoch, displayed),
            child: Text('Reconcile Run'),
          ),
      ],
    );
  }

  void openComment(
    ReviewCommentAnchor anchor,
    PendingReviewComment? saved,
    int captured,
    int draftRevision,
  ) {
    if (!canMutateComments() ||
        draftRevision != commentRevision ||
        (saved == null && captured != revision)) {
      return;
    }
    if (editorAnchor != null) {
      // Reopening never replaces an active controller or its unsaved contents.
      setState(() {
        commentMessage = 'Save or cancel the open comment first.';
      });
      return;
    }
    final text = saved == null ? '' : saved.text;
    // The pin's text setter falls through to an unsupported superclass setter.
    // Replace only on explicit selection, never during refresh or row building.
    editor.dispose();
    editor = TextEditingController(text: text);
    setState(() {
      editorRevision++;
      editorAnchor = anchor;
      editingComment = saved;
      originalText = text;
      editorInvalid = false;
      editorMultiline = text.contains('\n') || text.contains('\r');
      commentMessage = '';
    });
  }

  void cancelComment(int captured) {
    if (disposed || commentPending || captured != editorRevision) return;
    setState(() {
      clearEditor();
    });
  }

  void clearEditor() {
    editorRevision++;
    editorAnchor = null;
    editingComment = null;
    originalText = '';
    editorInvalid = false;
    editorMultiline = false;
    editor.clear();
    commentMessage = '';
  }

  void saveComment(int captured) async {
    if (!canMutateComments() ||
        editorAnchor == null ||
        editorInvalid ||
        editorMultiline ||
        captured != editorRevision) {
      return;
    }
    final text = editor.text;
    if (text.trim().isEmpty ||
        text.length > ReviewDraftLimits.maxTextLength ||
        text.contains('\n') ||
        text.contains('\r')) {
      setState(() {
        commentMessage =
            'Enter a nonblank single-line comment (up to ${ReviewDraftLimits.maxTextLength} characters).';
      });
      return;
    }
    final selected = editingComment;
    final anchor = editorAnchor!;
    commentRevision++;
    final operationRevision = commentRevision;
    setState(() {
      commentPending = true;
      displayedDraftRevision = -1;
      commentMessage = 'Saving comment...';
    });
    Future<PendingReviewComment> operation;
    if (selected == null) {
      operation = draftClient.createComment(sessionId, anchor, text);
    } else {
      operation = draftClient.updateComment(
        sessionId,
        selected.id,
        selected.version,
        text,
      );
    }
    final result = await settleOwningBackendOperation(operation);
    if (disposed || operationRevision != commentRevision) return;
    if (result[0] != true) {
      unconfirmedComment();
      return;
    }
    setState(() {
      commentPending = false;
      clearEditor();
    });
    await reloadComments();
  }

  void deleteComment(PendingReviewComment selected, int captured) async {
    if (!canMutateComments() || captured != commentRevision) return;
    if (editorAnchor != null) {
      setState(() {
        commentMessage = 'Save or cancel the open comment first.';
      });
      return;
    }
    commentRevision++;
    final operationRevision = commentRevision;
    setState(() {
      commentPending = true;
      displayedDraftRevision = -1;
      commentMessage = 'Deleting comment...';
    });
    final result = await settleOwningBackendOperation(
      draftClient.deleteComment(sessionId, selected.id, selected.version),
    );
    if (disposed || operationRevision != commentRevision) return;
    if (result[0] != true) {
      unconfirmedComment();
      return;
    }
    setState(() {
      commentPending = false;
      commentMessage = '';
    });
    await reloadComments();
  }

  void unconfirmedComment() {
    setState(() {
      commentPending = false;
      commentStatus = 'uncertain';
      displayedDraftRevision = -1;
      editorInvalid = true;
      editorRevision++;
      commentMessage =
          'Comment change not confirmed. Reload comments before trying again.';
    });
  }

  Widget commentsToolbar() => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Text(
        commentsLoaded
            ? 'Pending review comments (${comments.length})'
            : 'Pending review comments',
      ),
      submissionControls(),
      if (commentStatus == 'loading') Text('Loading comments...'),
      if (commentsLoaded && commentStatus != 'ready')
        Text('Showing last confirmed comments.'),
      if (commentMessage != '') Text(commentMessage),
      if (!commentPending && !submissionPending)
        TextButton(onPressed: reloadComments, child: Text('Reload comments')),
    ],
  );

  Widget pendingComment(PendingReviewComment comment) {
    final captured = commentRevision;
    return Container(
      padding: EdgeInsets.all(8),
      color: Color(0x10888888),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(locationLabel(comment.anchor)),
          Text(comment.text),
          Text(locationStatus(comment.anchor)),
          Text(
            comment.anchor.sourceExcerpt,
            style: TextStyle(fontFamily: 'monospace', fontSize: 12),
          ),
          if (canMutateComments())
            Row(
              children: [
                TextButton(
                  onPressed: () =>
                      openComment(comment.anchor, comment, revision, captured),
                  child: Text('Edit'),
                ),
                TextButton(
                  onPressed: () => deleteComment(comment, captured),
                  child: Text('Delete'),
                ),
              ],
            ),
        ],
      ),
    );
  }

  Widget commentEditor() {
    final captured = editorRevision;
    final anchor = editorAnchor!;
    return Container(
      padding: EdgeInsets.all(8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            height: 36,
            child: SingleChildScrollView(child: Text(locationLabel(anchor))),
          ),
          Text(locationStatus(anchor)),
          SizedBox(
            height: 44,
            child: SingleChildScrollView(
              child: Text(
                anchor.sourceExcerpt,
                style: TextStyle(fontFamily: 'monospace', fontSize: 12),
              ),
            ),
          ),
          if (editorMultiline)
            SizedBox(
              height: 80,
              child: SingleChildScrollView(child: Text(editor.text)),
            ),
          if (editorMultiline)
            Text(
              'Multiline comments are readable but cannot be edited in this version.',
            ),
          if (!editorMultiline) Text('Single-line comment'),
          if (!editorMultiline)
            TextField(controller: editor, enabled: !commentPending),
          if (editorInvalid)
            Text(
              'Selection invalidated. Reload comments, then cancel and select a comment again. Your text is retained.',
            ),
          Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (canMutateComments() && !editorInvalid && !editorMultiline)
                TextButton(
                  onPressed: () => saveComment(captured),
                  child: Text('Save comment'),
                ),
              if (!commentPending)
                TextButton(
                  onPressed: () => cancelComment(captured),
                  child: Text('Cancel editing'),
                ),
            ],
          ),
        ],
      ),
    );
  }

  void reviewChange(Object selection, bool unapprove, int captured) async {
    if (disposed ||
        captured != revision ||
        status != 'ready' ||
        reviewHandle == '' ||
        reviewPending ||
        commentPending) {
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
    if (reviewPending || commentPending) return Text('');
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
    submissionRevision++;
    commentRevision++;
    editorRevision++;
    editor.dispose();
    abandon();
    unregisterSessionPrepareToDeactivate(departure);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ListView.builder(
    // Explicit editor selection reveals it at the top. Ordinary rebuilds and
    // refresh retain the list key and the state-owned text controller.
    key: Key('diff-$editorRevision'),
    itemCount:
        1 + comments.length + rows.length + (editorAnchor != null ? 1 : 0),
    itemBuilder: (BuildContext context, int index) {
      if (editorAnchor != null) {
        if (index == 0) return commentEditor();
        return paneRow(index - 1);
      }
      return paneRow(index);
    },
  );

  Widget paneRow(int index) {
    if (index == 0) return controls();
    if (index <= comments.length) return pendingComment(comments[index - 1]);
    return diffRow(index - comments.length - 1);
  }

  Widget controls() => Column(
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
          !reviewPending &&
          !commentPending)
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
      commentsToolbar(),
    ],
  );

  // The call boundary boxes the calculated index for the pin's typed maps.
  Widget diffRow(int rowIndex) {
    final row = rows[rowIndex];
    final captured = revision;
    final approval = approvals[rowIndex];
    final unapproval = unapprovals[rowIndex];
    final fileApproval = fileApprovals[rowIndex];
    final fileUnapproval = fileUnapprovals[rowIndex];
    final anchor = lineAnchors[rowIndex];
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
    if (anchor != null &&
        canMutateComments() &&
        comments.length < ReviewDraftLimits.maxComments) {
      content = Row(
        children: [
          Expanded(flex: 1, child: label),
          SizedBox(
            height: 28,
            child: TextButton(
              onPressed: () =>
                  openComment(anchor, null, captured, commentRevision),
              child: Text('Comment'),
            ),
          ),
        ],
      );
    }
    if (row.length > 2 ||
        approval != null ||
        unapproval != null ||
        fileApproval != null ||
        fileUnapproval != null) {
      content = Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          label,
          if (fileApproval != null) reviewAction(fileApproval, false, captured),
          if (fileUnapproval != null)
            reviewAction(fileUnapproval, true, captured),
          if (row.length > 2) sourceAction(row[2], captured),
          if (approval != null) reviewAction(approval, false, captured),
          if (unapproval != null) reviewAction(unapproval, true, captured),
        ],
      );
    }
    return Container(
      color: background,
      padding: EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      child: content,
    );
  }
}
