import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:adele_contract/adele_contract.dart';
import 'package:adele_desktop/frontend/backend_invocation_bridge.dart';
import 'package:adele_desktop/frontend/environment_capability_access_bridge.dart';
import 'package:adele_desktop/frontend/environment_capability_diagnostics.dart';
import 'package:adele_desktop/frontend/main_content_bridge.dart';
import 'package:adele_desktop/frontend/owning_backend_bridge.dart';
import 'package:adele_desktop/frontend/prepared_frontend.dart';
import 'package:adele_desktop/frontend/session_feedback_bridge.dart';
import 'package:adele_desktop/frontend/session_presentation_lifecycle_bridge.dart';
import 'package:adele_desktop/frontend/structured_bridge_data.dart';
import 'package:adele_orchestration/session_feedback.dart';
import 'package:adele_plugin_api/adele_plugin_api.dart';
import 'package:adele_ui/adele_ui.dart';
import 'package:dart_eval/dart_eval_bridge.dart';
import 'package:dart_eval/stdlib/core.dart';
import 'package:diff_viewer_contract/diff_viewer_contract.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../../../app/tool/diff_viewer_frontend_compiler.dart';

void main() {
  late Directory temporary;
  late File artifact;
  late PreparedFrontend frontend;
  late _Port port;
  late SessionPresentationLifecycleBridge lifecycle;
  late ExtensionRegistry sourceRegistry;
  late _Source source;
  late _DraftBackend draft;
  late _Feedback feedback;

  setUpAll(() async {
    temporary = await Directory.systemTemp.createTemp('diff-viewer-eval-');
    artifact = File('${temporary.path}/frontend.evc');
    await compileDiffViewerFrontend(
      repositoryRoot: Directory.current.parent.parent.parent.parent,
      sdkPath: diffViewerDartSdk(),
      artifact: artifact,
    );
  });
  tearDownAll(() => temporary.delete(recursive: true));
  setUp(() async {
    frontend = await PreparedFrontend.load(artifact);
    port = _Port();
    lifecycle = SessionPresentationLifecycleBridge(isActive: () => true);
    sourceRegistry = ExtensionRegistry();
    source = _Source();
    draft = _DraftBackend();
    feedback = _Feedback(draft.events);
  });
  tearDown(() async {
    frontend.invalidate();
    await port.close();
    await draft.close();
  });

  ExtensionRegistration registerSource({String id = 'test.source'}) {
    final registration = sourceRegistry.register(
      point: displaySourceFileContributions,
      id: ExtensionId(id),
      value: DisplaySourceFileContribution(display: source.display),
    );
    addTearDown(registration.close);
    return registration;
  }

  Future<void> mount(
    WidgetTester tester, {
    Key? key,
    bool withDraft = false,
    String sessionId = 'canonical',
    String environmentId = 'canonical-environment',
  }) async {
    final capturedDraft = draft;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: frontend.createPresentation(
            key: key,
            library: diffViewerFrontendLibrary,
            entrypoint: 'buildDiffPane',
            createBridge: () => PreparedFrontendBridges([
              MainContentBridge(
                context: {
                  'sessionId': sessionId,
                  'environmentKey': environmentId,
                },
                isActive: () => true,
                resolveSourceDisplay: DisplaySourceFileResolver(
                  sourceRegistry,
                ).resolve,
              ),
              lifecycle,
              port,
              _FeedbackPort(feedback, sessionId),
              OwningBackendBridge(
                channels: {if (withDraft) reviewDraftServiceId: capturedDraft},
                validateBinding: () {
                  if (!capturedDraft.active) {
                    throw StateError('private retired draft backend');
                  }
                },
              ),
            ]),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(
      find.text('Refresh'),
      findsOneWidget,
      reason:
          'Initial presentation: ${tester.widgetList<Text>(find.byType(Text)).map((text) => text.data).toList()}; snapshot calls=${port.methods}; draft calls=${draft.methods}',
    );
  }

  void setLayerReview({
    String stamp = 'old',
    bool individual = true,
    int hunks = 2,
  }) {
    port.service.value = _reviewSnapshot(
      layerRevision: '$stamp:unstaged:layer',
      revision: individual ? '$stamp:unstaged:hunk' : null,
      fileRevision: individual ? '$stamp:unstaged:file' : null,
      hunks: hunks,
    );
    port.service.uncommitted = _uncommitted(
      staged: _reviewSnapshot(
        layerRevision: '$stamp:staged:layer',
        revision: individual ? '$stamp:staged:hunk' : null,
        fileRevision: individual ? '$stamp:staged:file' : null,
        hunks: hunks,
      ),
      unstaged: port.service.value,
    );
    port.service.task = _task(
      committed: _reviewSnapshot(
        layerRevision: '$stamp:committed:never-select',
        revision: null,
        hunks: hunks,
      ),
      uncommitted: port.service.uncommitted,
    );
  }

  group('saved review submission', () {
    Future<void> mountReview(
      WidgetTester tester, {
      Size size = const Size(1100, 1800),
    }) async {
      await tester.binding.setSurfaceSize(size);
      addTearDown(() => tester.binding.setSurfaceSize(null));
      feedback.available = true;
      await mount(tester, withDraft: true);
    }

    Future<void> click(WidgetTester tester, String label) async {
      await tester.tap(find.widgetWithText(TextButton, label));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    }

    Future<void> remount(
      WidgetTester tester, {
      String session = 'canonical',
    }) async {
      await tester.pumpWidget(const SizedBox());
      final previous = port;
      addTearDown(previous.close);
      port = _Port();
      lifecycle = SessionPresentationLifecycleBridge(isActive: () => true);
      await mount(tester, withDraft: true, sessionId: session);
    }

    testWidgets(
      'submits all saved Session comments from clean Diff in durable order without Git rescan',
      (tester) async {
        draft.comments().addAll([
          _comment(
            text: ' exact first\r\nsecond ',
            anchor: _commentAnchor(
              side: ReviewComparisonSide.oldSide,
              startLine: 10,
              endLine: 12,
              excerpt: 'old\r\nsource',
            ),
          ),
          _comment(
            id: 'outside',
            sequence: 2,
            text: 'committed outside current scope',
            anchor: _commentAnchor(
              layer: ReviewComparisonLayer.committed,
              environmentId: 'original-environment',
            ),
          ),
          _comment(
            id: 'staged',
            sequence: 3,
            text: 'staged outdated location',
            anchor: _commentAnchor(layer: ReviewComparisonLayer.staged),
          ),
        ]);
        draft.revisions['canonical'] = 41;
        await mountReview(tester);
        expect(find.text('Saved comments revision: 41'), findsOneWidget);
        expect(find.text('Pending review comments (3)'), findsOneWidget);
        expect(find.text('No unstaged changes.'), findsOneWidget);
        final gitReads = List.of(port.methods);
        await click(tester, 'Submit Review');
        expect(
          draft.events,
          containsAllInOrder([
            reviewDraftServicePrepareReviewId,
            reviewDraftServiceMarkDeliveryAttemptedId,
            'acceptSessionFeedback',
            reviewDraftServiceConfirmAcceptanceId,
            reviewDraftServiceMarkSchedulingAttemptedId,
            'startSessionFeedbackRun',
            reviewDraftServiceConfirmRunScheduledId,
            reviewDraftServiceSnapshotId,
          ]),
        );
        expect(
          draft.payloads[draft.methods.indexOf(
            reviewDraftServicePrepareReviewId,
          )],
          {'sessionId': 'canonical', 'expectedRevision': 41},
        );
        final accepted = feedback.calls.first.payload;
        expect(feedback.calls.last.payload, accepted);
        expect(feedback.calls.last.occurrence, 'occurrence-1');
        final decoded = decodeSessionFeedbackSubmission(accepted);
        expect(decoded.comments.map((comment) => comment.id), [
          'saved-1',
          'outside',
          'staged',
        ]);
        expect(decoded.comments.first.text, ' exact first\r\nsecond ');
        expect(decoded.comments.first.anchor.sourceExcerpt, 'old\r\nsource');
        expect(decoded.comments.first.anchor.endLine, 12);
        expect(
          decoded.comments[1].anchor.environmentId,
          'original-environment',
        );
        expect(
          decoded.comments[1].anchor.layer,
          SessionFeedbackComparisonLayer.committed,
        );
        expect(draft.comments(), isEmpty);
        expect(find.text('Pending review comments (0)'), findsOneWidget);
        expect(
          find.text('Review accepted. Run scheduled: run-1'),
          findsOneWidget,
        );
        expect(port.methods, gitReads);
        expect(port.review.operations, isEmpty);
        expect(source.paths, isEmpty);
      },
    );

    for (final stage in [
      reviewDraftServicePrepareReviewId,
      reviewDraftServiceMarkDeliveryAttemptedId,
      reviewDraftServiceConfirmAcceptanceId,
      reviewDraftServiceMarkSchedulingAttemptedId,
      reviewDraftServiceConfirmRunScheduledId,
    ]) {
      testWidgets(
        'duplicate clicks and scope changes do not duplicate held $stage',
        (tester) async {
          draft.comments().add(_comment());
          await mountReview(tester);
          final button = tester.widget<TextButton>(
            find.widgetWithText(TextButton, 'Submit Review'),
          );
          final gate = Completer<void>();
          draft.handoffGates[stage] = gate;
          button.onPressed!();
          button.onPressed!();
          await tester.pumpAndSettle();
          expect(find.widgetWithText(TextButton, 'Delete'), findsNothing);
          await click(tester, 'Task / Branch');
          button.onPressed!();
          await tester.pumpAndSettle();
          expect(
            draft.methods.where((method) => method == stage),
            hasLength(1),
          );
          if (stage == reviewDraftServiceConfirmAcceptanceId) {
            expect(
              feedback.calls.where(
                (call) => call.method == 'startSessionFeedbackRun',
              ),
              isEmpty,
            );
          }
          gate.complete();
          await tester.pumpAndSettle();
          expect(feedback.calls.map((call) => call.method), [
            'acceptSessionFeedback',
            'startSessionFeedbackRun',
          ]);
          expect(
            draft.methods.where(
              (method) => method == reviewDraftServicePrepareReviewId,
            ),
            hasLength(1),
          );
          expect(
            find.text('Review accepted. Run scheduled: run-1'),
            findsOneWidget,
          );
          expect(tester.takeException(), isNull);
        },
      );
    }

    testWidgets(
      'unsaved editor and pending CRUD prohibit submission; save reloads revision before eligibility',
      (tester) async {
        draft.comments().add(_comment());
        port.service.value = _commentSnapshot();
        await mountReview(tester);
        final old = tester.widget<TextButton>(
          find.widgetWithText(TextButton, 'Submit Review'),
        );
        await click(tester, 'Edit');
        await tester.enterText(find.byType(TextField), 'unsaved replacement');
        old.onPressed!();
        await tester.pumpAndSettle();
        expect(feedback.calls, isEmpty);
        expect(find.widgetWithText(TextButton, 'Submit Review'), findsNothing);
        final write = draft.holdMutation();
        final read = draft.holdSnapshot();
        await click(tester, 'Save comment');
        old.onPressed!();
        write.complete();
        await tester.pumpAndSettle();
        expect(find.text('Loading comments...'), findsOneWidget);
        expect(find.widgetWithText(TextButton, 'Submit Review'), findsNothing);
        expect(feedback.calls, isEmpty);
        draft.revisions['canonical'] = 77;
        draft.comments().add(
          _comment(
            id: 'external',
            sequence: 2,
            text: 'authoritative external comment',
          ),
        );
        read.complete(
          ReviewDraftSnapshot(
            sessionId: 'canonical',
            revision: 77,
            comments: draft.comments(),
            currentReview: null,
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('authoritative external comment'), findsOneWidget);
        expect(find.text('Saved comments revision: 77'), findsOneWidget);
        expect(feedback.calls, isEmpty);
        await click(tester, 'Submit Review');
        expect(
          decodeSessionFeedbackSubmission(
            feedback.calls.first.payload,
          ).comments,
          hasLength(2),
        );
        expect(port.service.calls, 1);
      },
    );

    testWidgets(
      'stale displayed revision fails without loading and submitting unseen comments',
      (tester) async {
        draft.comments().add(_comment());
        await mountReview(tester);
        draft.comments().add(
          _comment(id: 'external', sequence: 2, text: 'unseen new comment'),
        );
        draft.revisions['canonical'] = 1;
        await click(tester, 'Submit Review');
        expect(feedback.calls, isEmpty);
        expect(draft.snapshots, hasLength(1));
        expect(find.text('unseen new comment'), findsNothing);
        expect(find.widgetWithText(TextButton, 'Submit Review'), findsNothing);
        await click(tester, 'Reload comments');
        expect(find.text('unseen new comment'), findsOneWidget);
        expect(feedback.calls, isEmpty);
        await click(tester, 'Submit Review');
        expect(
          decodeSessionFeedbackSubmission(
            feedback.calls.first.payload,
          ).comments,
          hasLength(2),
        );
      },
    );

    testWidgets(
      'typed oversized preparation preserves all comments and reloads for editing without resubmission',
      (tester) async {
        draft.comments().addAll([
          _comment(text: 'first complete comment'),
          _comment(id: 'second', sequence: 2, text: 'second complete comment'),
          _comment(id: 'third', sequence: 3, text: 'third complete comment'),
        ]);
        final original = List.of(draft.comments());
        draft.preparationRejection = 'submission_too_large';
        await mountReview(tester);
        final reads = List.of(port.methods);
        await click(tester, 'Submit Review');
        expect(
          find.text(
            'The complete saved review is too large to submit. Nothing was truncated or split. Edit or delete saved comments before trying again.',
          ),
          findsOneWidget,
        );
        expect(find.text('Pending review comments (3)'), findsOneWidget);
        expect(draft.comments(), orderedEquals(original));
        expect(draft.reviews, isEmpty);
        expect(draft.frozen, isEmpty);
        expect(draft.submissionSequence, 0);
        expect(draft.snapshots, hasLength(2));
        expect(
          draft.methods.where(
            (method) => method == reviewDraftServicePrepareReviewId,
          ),
          hasLength(1),
        );
        expect(feedback.calls, isEmpty);
        expect(port.methods, reads);
        await tester.tap(
          _savedCommentAction('second complete comment', 'Edit'),
        );
        await tester.pumpAndSettle();
        await tester.enterText(find.byType(TextField), 'shorter comment');
        await click(tester, 'Save comment');
        expect(draft.comments()[1].text, 'shorter comment');
        expect(
          draft.methods.where(
            (method) => method == reviewDraftServicePrepareReviewId,
          ),
          hasLength(1),
        );
        expect(feedback.calls, isEmpty);
      },
    );

    testWidgets(
      'unavailable feedback and empty pending collection never prepare',
      (tester) async {
        await mountReview(tester);
        expect(find.widgetWithText(TextButton, 'Submit Review'), findsNothing);
        draft.comments().add(_comment());
        feedback.available = false;
        feedback.reason = 'No compatible Session feedback target.';
        await click(tester, 'Reload comments');
        expect(
          find.text('No compatible Session feedback target.'),
          findsOneWidget,
        );
        expect(find.widgetWithText(TextButton, 'Submit Review'), findsNothing);
        expect(find.widgetWithText(TextButton, 'Edit'), findsOneWidget);
        expect(
          draft.methods,
          isNot(contains(reviewDraftServicePrepareReviewId)),
        );
        expect(feedback.calls, isEmpty);
      },
    );

    for (final reason in [
      'No model is configured for this Session.',
      'This Session is waiting for approval.',
    ]) {
      testWidgets(
        'initial Run unavailable: $reason never prepares or freezes comments',
        (tester) async {
          draft.comments().add(_comment());
          feedback.canStart = false;
          feedback.reason = reason;
          await mountReview(tester);
          expect(
            find.widgetWithText(TextButton, 'Submit Review'),
            findsNothing,
          );
          expect(find.text(reason), findsOneWidget);
          expect(find.widgetWithText(TextButton, 'Edit'), findsOneWidget);
          expect(find.widgetWithText(TextButton, 'Delete'), findsOneWidget);
          expect(draft.methods, [
            reviewDraftServiceSnapshotId,
            reviewDraftServiceReadReviewId,
          ]);
          expect(draft.reviews, isEmpty);
          expect(draft.comments(), hasLength(1));
          expect(feedback.calls, isEmpty);
        },
      );
    }

    testWidgets(
      'retained Submit callback rechecks Run availability before preparing',
      (tester) async {
        draft.comments().add(_comment());
        await mountReview(tester);
        final button = tester.widget<TextButton>(
          find.widgetWithText(TextButton, 'Submit Review'),
        );
        feedback.canStart = false;
        feedback.reason = 'This Session is waiting for approval.';
        button.onPressed!();
        await tester.pumpAndSettle();
        expect(
          draft.methods,
          isNot(contains(reviewDraftServicePrepareReviewId)),
        );
        expect(draft.reviews, isEmpty);
        expect(feedback.calls, isEmpty);
        await click(tester, 'Reload comments');
        expect(find.text(feedback.reason), findsOneWidget);
        expect(find.widgetWithText(TextButton, 'Edit'), findsOneWidget);
      },
    );

    testWidgets(
      'preaccepted freeze preserves Source and Git approval without replay',
      (tester) async {
        draft.comments().add(_comment());
        port.service.value = _reviewSnapshot(
          fileRevision: 'file:1',
          commentIdentity: 'comparison',
          hunks: 1,
        );
        registerSource();
        feedback.results['acceptSessionFeedback'] = {
          'status': 'uncertain',
          'occurrenceId': null,
        };
        await mountReview(tester);
        await click(tester, 'Submit Review');
        expect(find.widgetWithText(TextButton, 'Edit'), findsNothing);
        expect(find.widgetWithText(TextButton, 'Comment'), findsNothing);
        await click(tester, 'Open in Source');
        await click(tester, 'Approve File');
        expect(source.paths, ['review.txt']);
        expect(port.review.operations, ['approveFile']);
        expect(feedback.calls.map((call) => call.method), [
          'acceptSessionFeedback',
        ]);
        expect(find.text('Reconcile acceptance'), findsOneWidget);
      },
    );

    for (final retained in ReviewSubmissionStatus.values) {
      testWidgets(
        'remount $retained reads only and presents explicit recovery status',
        (tester) async {
          draft.reviews['canonical'] = _preparedReview(status: retained);
          draft.frozen['canonical'] = [_comment()];
          if (retained.index < ReviewSubmissionStatus.accepted.index) {
            draft.comments().add(_comment());
          }
          await mountReview(tester);
          expect(draft.methods, [
            reviewDraftServiceSnapshotId,
            reviewDraftServiceReadReviewId,
          ]);
          expect(feedback.calls, isEmpty);
          expect(
            find.widgetWithText(TextButton, 'Submit Review'),
            findsNothing,
          );
          if (retained == ReviewSubmissionStatus.prepared) {
            expect(find.text('Deliver prepared review'), findsOneWidget);
          }
          if (retained == ReviewSubmissionStatus.deliveryPending) {
            expect(find.text('Reconcile acceptance'), findsOneWidget);
          }
          if (retained == ReviewSubmissionStatus.accepted) {
            expect(find.text('Retry Run'), findsOneWidget);
          }
          if (retained == ReviewSubmissionStatus.schedulingPending) {
            expect(find.text('Reconcile Run'), findsOneWidget);
          }
          if (retained == ReviewSubmissionStatus.scheduled) {
            expect(
              find.text('Review accepted. Run scheduled: run-1'),
              findsOneWidget,
            );
          }
        },
      );
    }

    testWidgets(
      'a review prepared between snapshot and recovery read cannot deliver unseen comments',
      (tester) async {
        draft.comments().add(_comment(text: 'displayed comment'));
        final read = Completer<void>();
        draft.handoffGates[reviewDraftServiceReadReviewId] = read;
        await mountReview(tester);
        draft.comments().add(
          _comment(id: 'new', sequence: 2, text: 'new unseen comment'),
        );
        draft.revisions['canonical'] = 1;
        await draft.prepareReview('canonical', 1);
        read.complete();
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(
          find.text(
            'Review changed while loading. Reload comments before continuing.',
          ),
          findsOneWidget,
        );
        expect(find.text('Pending review comments (1)'), findsOneWidget);
        expect(find.text('new unseen comment'), findsNothing);
        expect(find.widgetWithText(TextButton, 'Submit Review'), findsNothing);
        expect(
          find.widgetWithText(TextButton, 'Deliver prepared review'),
          findsNothing,
        );
        expect(find.widgetWithText(TextButton, 'Edit'), findsNothing);
        expect(feedback.calls, isEmpty);
        await click(tester, 'Reload comments');
        expect(find.text('Pending review comments (2)'), findsOneWidget);
        expect(find.text('new unseen comment'), findsOneWidget);
        expect(
          find.widgetWithText(TextButton, 'Deliver prepared review'),
          findsOneWidget,
        );
        expect(feedback.calls, isEmpty);
      },
    );

    testWidgets(
      'acceptance between snapshot and recovery read cannot expose cleared comments as editable',
      (tester) async {
        draft.comments().add(_comment());
        draft.frozen['canonical'] = List.of(draft.comments());
        draft.reviews['canonical'] = _preparedReview();
        final read = Completer<void>();
        draft.handoffGates[reviewDraftServiceReadReviewId] = read;
        await mountReview(tester);
        await draft.markDeliveryAttempted('canonical', 'review-1');
        await draft.confirmAcceptance(
          'canonical',
          'review-1',
          'canonical',
          'occurrence-1',
        );
        read.complete();
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(
          find.text(
            'Review changed while loading. Reload comments before continuing.',
          ),
          findsOneWidget,
        );
        expect(find.widgetWithText(TextButton, 'Edit'), findsNothing);
        expect(find.widgetWithText(TextButton, 'Retry Run'), findsNothing);
        expect(find.widgetWithText(TextButton, 'Reconcile Run'), findsNothing);
        await click(tester, 'Reload comments');
        expect(find.text('Pending review comments (0)'), findsOneWidget);
        expect(
          find.widgetWithText(TextButton, 'Reconcile Run'),
          findsOneWidget,
        );
        expect(feedback.calls, isEmpty);
      },
    );

    testWidgets(
      'accepted remount reconciles an existing ordinary Run while busy without starting another',
      (tester) async {
        final accepted = _preparedReview(
          status: ReviewSubmissionStatus.accepted,
        );
        draft.reviews['canonical'] = accepted;
        feedback.canStart = false;
        feedback.reason = 'This Session already has an active Run.';
        await mountReview(tester);
        expect(feedback.calls, isEmpty);
        expect(find.widgetWithText(TextButton, 'Retry Run'), findsNothing);
        final lookup = Completer<Map<String, Object?>>();
        feedback.gates['lookupSessionFeedbackRun'] = lookup.future;
        final button = tester.widget<TextButton>(
          find.widgetWithText(TextButton, 'Reconcile Run'),
        );
        button.onPressed!();
        button.onPressed!();
        await tester.pumpAndSettle();
        expect(
          draft.reviews['canonical']!.status,
          ReviewSubmissionStatus.accepted,
        );
        expect(
          draft.methods,
          isNot(contains(reviewDraftServiceMarkSchedulingAttemptedId)),
        );
        lookup.complete({
          'status': 'scheduled',
          'sessionId': 'canonical',
          'submissionId': accepted.submissionId,
          'occurrenceId': accepted.occurrenceId,
          'runId': 'ordinary-run',
        });
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(feedback.calls.map((call) => call.method), [
          'lookupSessionFeedbackRun',
        ]);
        expect(feedback.calls.single.payload, accepted.canonicalPayload);
        expect(
          draft.events,
          containsAllInOrder([
            'lookupSessionFeedbackRun',
            reviewDraftServiceMarkSchedulingAttemptedId,
            reviewDraftServiceConfirmRunScheduledId,
          ]),
        );
        expect(draft.reviews['canonical']!.runId, 'ordinary-run');
        expect(draft.reviews['canonical']!.schedulingAttempt, 1);
        expect(
          find.text('Review accepted. Run scheduled: ordinary-run'),
          findsOneWidget,
        );
      },
    );

    for (final outcome in ['absent', 'uncertain', 'not_started', 'native']) {
      testWidgets(
        'accepted Run reconciliation $outcome creates no pending marker or start',
        (tester) async {
          draft.reviews['canonical'] = _preparedReview(
            status: ReviewSubmissionStatus.accepted,
          );
          if (outcome == 'native') {
            feedback.throwsOn = 'lookupSessionFeedbackRun';
          } else {
            feedback.results['lookupSessionFeedbackRun'] = {
              'status': outcome,
              'runId': null,
              'retryAllowed': true,
            };
          }
          await mountReview(tester);
          await click(tester, 'Reconcile Run');
          expect(
            draft.reviews['canonical']!.status,
            ReviewSubmissionStatus.accepted,
          );
          expect(draft.reviews['canonical']!.schedulingAttempt, 0);
          expect(draft.methods, [
            reviewDraftServiceSnapshotId,
            reviewDraftServiceReadReviewId,
          ]);
          expect(feedback.calls.map((call) => call.method), [
            'lookupSessionFeedbackRun',
          ]);
          expect(find.widgetWithText(TextButton, 'Retry Run'), findsOneWidget);
          expect(
            find.widgetWithText(TextButton, 'Reconcile Run'),
            findsOneWidget,
          );
        },
      );
    }

    testWidgets(
      'lost acceptance finalization acknowledgement cannot start a Run; remount remains read-only',
      (tester) async {
        draft.comments().add(_comment());
        draft.failAfterHandoff = reviewDraftServiceConfirmAcceptanceId;
        await mountReview(tester);
        await click(tester, 'Submit Review');
        expect(feedback.calls.map((call) => call.method), [
          'acceptSessionFeedback',
        ]);
        expect(draft.comments(), isEmpty);
        draft.failAfterHandoff = null;
        await remount(tester);
        expect(feedback.calls, hasLength(1));
        expect(
          find.text('Review accepted. Run scheduling not recorded.'),
          findsOneWidget,
        );
        await click(tester, 'Retry Run');
        expect(feedback.calls.map((call) => call.method), [
          'acceptSessionFeedback',
          'startSessionFeedbackRun',
        ]);
      },
    );

    for (final lost in [
      (reviewDraftServicePrepareReviewId, ReviewSubmissionStatus.prepared, 0),
      (
        reviewDraftServiceMarkDeliveryAttemptedId,
        ReviewSubmissionStatus.deliveryPending,
        0,
      ),
      (
        reviewDraftServiceMarkSchedulingAttemptedId,
        ReviewSubmissionStatus.schedulingPending,
        1,
      ),
      (
        reviewDraftServiceConfirmRunScheduledId,
        ReviewSubmissionStatus.scheduled,
        2,
      ),
    ]) {
      testWidgets(
        'lost ${lost.$1} acknowledgement stops the chain and remount never replays',
        (tester) async {
          draft.comments().add(_comment());
          draft.failAfterHandoff = lost.$1;
          await mountReview(tester);
          await click(tester, 'Submit Review');
          expect(feedback.calls, hasLength(lost.$3));
          expect(draft.reviews['canonical']!.status, lost.$2);
          draft.failAfterHandoff = null;
          final methods = draft.methods.length;
          await remount(tester);
          expect(draft.methods.skip(methods), [
            reviewDraftServiceSnapshotId,
            reviewDraftServiceReadReviewId,
          ]);
          expect(feedback.calls, hasLength(lost.$3));
          expect(
            find.widgetWithText(TextButton, 'Submit Review'),
            findsNothing,
          );
        },
      );
    }

    testWidgets(
      'native acceptance Future failure settles safely and positive lookup never auto-starts',
      (tester) async {
        draft.comments().add(_comment());
        feedback.throwsOn = 'acceptSessionFeedback';
        await mountReview(tester);
        await click(tester, 'Submit Review');
        expect(find.textContaining('private'), findsNothing);
        expect(find.text('Reconcile acceptance'), findsOneWidget);
        expect(draft.comments(), hasLength(1));
        feedback.throwsOn = null;
        feedback.canStart = false;
        await click(tester, 'Reconcile acceptance');
        expect(feedback.calls.map((call) => call.method), [
          'acceptSessionFeedback',
          'lookupSessionFeedback',
        ]);
        expect(draft.comments(), isEmpty);
        expect(
          find.text('Review accepted. Run scheduling not recorded.'),
          findsOneWidget,
        );
        expect(find.widgetWithText(TextButton, 'Retry Run'), findsNothing);
        feedback.canStart = true;
        await click(tester, 'Reload comments');
        expect(find.text('Retry Run'), findsOneWidget);
        await click(tester, 'Retry Run');
        expect(
          find.text('Review accepted. Run scheduled: run-1'),
          findsOneWidget,
        );
      },
    );

    testWidgets(
      'absence never unfreezes; only lookup permission enables explicit identical-payload retry',
      (tester) async {
        draft.comments().add(_comment());
        feedback.results['acceptSessionFeedback'] = {
          'status': 'uncertain',
          'occurrenceId': null,
        };
        feedback.results['lookupSessionFeedback'] = {
          'status': 'absent',
          'occurrenceId': null,
          'retryAllowed': false,
        };
        await mountReview(tester);
        await click(tester, 'Submit Review');
        await click(tester, 'Reconcile acceptance');
        expect(find.text('Retry same review'), findsNothing);
        expect(find.widgetWithText(TextButton, 'Edit'), findsNothing);
        expect(find.widgetWithText(TextButton, 'Delete'), findsNothing);
        expect(draft.comments(), hasLength(1));
        feedback.results['lookupSessionFeedback']!['retryAllowed'] = true;
        await click(tester, 'Reconcile acceptance');
        expect(
          feedback.calls.where(
            (call) => call.method == 'acceptSessionFeedback',
          ),
          hasLength(1),
        );
        feedback.results.remove('acceptSessionFeedback');
        await click(tester, 'Retry same review');
        final accepts = feedback.calls
            .where((call) => call.method == 'acceptSessionFeedback')
            .toList();
        expect(accepts, hasLength(2));
        expect(accepts[0].payload, accepts[1].payload);
        expect(
          draft.methods.where(
            (method) => method == reviewDraftServiceMarkDeliveryAttemptedId,
          ),
          hasLength(1),
        );
        expect(
          draft.methods.where(
            (method) => method == reviewDraftServicePrepareReviewId,
          ),
          hasLength(1),
        );
      },
    );

    testWidgets(
      'confirmed pre-start failure resets durably and requires explicit Retry Run',
      (tester) async {
        draft.comments().add(_comment());
        feedback.results['startSessionFeedbackRun'] = {
          'status': 'not_started',
          'runId': null,
          'retryAllowed': true,
        };
        await mountReview(tester);
        await click(tester, 'Submit Review');
        expect(
          draft.methods,
          contains(reviewDraftServiceConfirmRunNotStartedId),
        );
        expect(find.text('Review accepted. Run not started.'), findsOneWidget);
        expect(
          feedback.calls.where(
            (call) => call.method == 'startSessionFeedbackRun',
          ),
          hasLength(1),
        );
        feedback.results.remove('startSessionFeedbackRun');
        await click(tester, 'Retry Run');
        expect(
          feedback.calls.where(
            (call) => call.method == 'startSessionFeedbackRun',
          ),
          hasLength(2),
        );
        expect(
          feedback.calls
              .where((call) => call.method == 'startSessionFeedbackRun')
              .map((call) => call.attempt),
          [1, 2],
        );
        expect(
          feedback.calls.where(
            (call) => call.method == 'acceptSessionFeedback',
          ),
          hasLength(1),
        );
        expect(
          find.text('Review accepted. Run scheduled: run-1'),
          findsOneWidget,
        );
      },
    );

    testWidgets(
      'foreign acceptance and Run identities never finalize durable state',
      (tester) async {
        draft.comments().add(_comment());
        feedback.results['acceptSessionFeedback'] = {
          'sessionId': 'other-session',
        };
        await mountReview(tester);
        await click(tester, 'Submit Review');
        expect(
          draft.methods,
          isNot(contains(reviewDraftServiceConfirmAcceptanceId)),
        );
        expect(draft.comments(), hasLength(1));
        await click(tester, 'Reconcile acceptance');
        feedback.results['startSessionFeedbackRun'] = {
          'occurrenceId': 'other-occurrence',
        };
        await click(tester, 'Retry Run');
        expect(
          draft.methods,
          isNot(contains(reviewDraftServiceConfirmRunScheduledId)),
        );
        expect(find.text('Reconcile Run'), findsOneWidget);
        expect(find.text('Retry Run'), findsNothing);
      },
    );

    testWidgets(
      'ambiguous scheduling only looks up and does not retry from absent evidence',
      (tester) async {
        draft.comments().add(_comment());
        feedback.throwsOn = 'startSessionFeedbackRun';
        feedback.results['lookupSessionFeedbackRun'] = {
          'status': 'uncertain',
          'runId': null,
          'retryAllowed': false,
        };
        await mountReview(tester);
        await click(tester, 'Submit Review');
        expect(find.text('Retry Run'), findsNothing);
        expect(find.text('Reconcile Run'), findsOneWidget);
        await click(tester, 'Reconcile Run');
        expect(find.text('Retry Run'), findsNothing);
        expect(
          draft.methods,
          isNot(contains(reviewDraftServiceConfirmRunNotStartedId)),
        );
        feedback.throwsOn = null;
        feedback.results.remove('lookupSessionFeedbackRun');
        await click(tester, 'Reconcile Run');
        expect(
          feedback.calls.where(
            (call) => call.method == 'startSessionFeedbackRun',
          ),
          hasLength(1),
        );
        expect(
          find.text('Review accepted. Run scheduled: run-1'),
          findsOneWidget,
        );
      },
    );

    testWidgets(
      'acceptance remains visible without start availability and Git approval and Source remain independent',
      (tester) async {
        draft.comments().add(_comment());
        port.service.value = _reviewSnapshot(fileRevision: 'file:1', hunks: 1);
        registerSource();
        final accepted = Completer<Map<String, Object?>>();
        feedback.gates['acceptSessionFeedback'] = accepted.future;
        await mountReview(tester);
        await click(tester, 'Submit Review');
        feedback.canStart = false;
        feedback.reason = 'Run availability changed during acceptance.';
        accepted.complete({
          'status': 'accepted',
          'sessionId': 'canonical',
          'submissionId': 'review-1',
          'occurrenceId': 'occurrence-1',
        });
        await tester.pumpAndSettle();
        expect(find.text('Review accepted. Run not started.'), findsWidgets);
        expect(find.text(feedback.reason), findsOneWidget);
        expect(find.widgetWithText(TextButton, 'Retry Run'), findsNothing);
        expect(feedback.calls.map((call) => call.method), [
          'acceptSessionFeedback',
        ]);
        await click(tester, 'Open in Source');
        await click(tester, 'Approve File');
        expect(source.paths, ['review.txt']);
        expect(port.review.operations, ['approveFile']);
      },
    );

    testWidgets(
      'narrow submission and recovery controls remain reachable without overflow',
      (tester) async {
        draft.comments().add(_comment());
        final accepted = Completer<Map<String, Object?>>();
        feedback.gates['acceptSessionFeedback'] = accepted.future;
        await mountReview(tester, size: const Size(280, 800));
        for (final width in [280.0, 320.0, 480.0]) {
          await tester.binding.setSurfaceSize(Size(width, 800));
          await tester.pumpAndSettle();
          final button = find.widgetWithText(TextButton, 'Submit Review');
          expect(tester.getRect(button).right, lessThanOrEqualTo(width));
          expect(tester.getRect(button).left, greaterThanOrEqualTo(0));
          expect(tester.takeException(), isNull);
        }
        await click(tester, 'Submit Review');
        feedback.canStart = false;
        accepted.complete({
          'status': 'accepted',
          'sessionId': 'canonical',
          'submissionId': 'review-1',
          'occurrenceId': 'occurrence-1',
        });
        await tester.pumpAndSettle();
        expect(find.text('Review accepted. Run not started.'), findsWidgets);
      },
    );

    testWidgets(
      'departed acceptance cannot publish or schedule for a new Session',
      (tester) async {
        draft.comments().add(_comment());
        final gate = Completer<Map<String, Object?>>();
        feedback.gates['acceptSessionFeedback'] = gate.future;
        await mountReview(tester);
        final stale = tester.widget<TextButton>(
          find.widgetWithText(TextButton, 'Submit Review'),
        );
        stale.onPressed!();
        stale.onPressed!();
        await tester.pumpAndSettle();
        expect(feedback.calls, hasLength(1));
        await lifecycle.prepareToDeactivate();
        await remount(tester, session: 'other-session');
        gate.complete({
          'status': 'accepted',
          'sessionId': 'canonical',
          'submissionId': 'review-1',
          'occurrenceId': 'occurrence-1',
        });
        await tester.pumpAndSettle();
        stale.onPressed!();
        await tester.pumpAndSettle();
        expect(feedback.calls, hasLength(1));
        expect(
          draft.methods,
          isNot(contains(reviewDraftServiceConfirmAcceptanceId)),
        );
        expect(
          draft.reviews['canonical']!.status,
          ReviewSubmissionStatus.deliveryPending,
        );
        expect(find.text('Pending review comments (0)'), findsOneWidget);
        expect(find.textContaining('Review accepted.'), findsNothing);
        expect(tester.takeException(), isNull);
      },
    );
  });

  group('pending review comments', () {
    Future<void> mountComments(
      WidgetTester tester, {
      Size size = const Size(1100, 1800),
    }) async {
      await tester.binding.setSurfaceSize(size);
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await mount(tester, withDraft: true);
    }

    Future<void> save(WidgetTester tester, String text) async {
      expect(find.byType(TextField), findsOneWidget);
      await tester.enterText(find.byType(TextField), text);
      await tester.tap(find.widgetWithText(TextButton, 'Save comment'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    }

    Future<void> remountComments(WidgetTester tester, String sessionId) async {
      await tester.pumpWidget(const SizedBox());
      final previousPort = port;
      addTearDown(previousPort.close);
      port = _Port();
      port.service.value = _commentSnapshot();
      lifecycle = SessionPresentationLifecycleBridge(isActive: () => true);
      await mount(tester, withDraft: true, sessionId: sessionId);
    }

    Finder paneScroll() => find
        .descendant(
          of: find.byType(ListView),
          matching: find.byType(Scrollable),
        )
        .first;

    Future<void> reveal(
      WidgetTester tester,
      Finder target, {
      double delta = 200,
    }) async {
      await tester.scrollUntilVisible(target, delta, scrollable: paneScroll());
      await tester.pumpAndSettle();
      expect(target.hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);
    }

    for (final line in [
      ('shared context', ReviewComparisonSide.newSide, 20, 0),
      ('removed line', ReviewComparisonSide.oldSide, 11, 1),
      ('added line', ReviewComparisonSide.newSide, 21, 2),
    ]) {
      testWidgets(
        'captures exact ${line.$1} single-line anchor without approval',
        (tester) async {
          port.service.value = _commentSnapshot();
          await mountComments(tester);
          expect(
            find.widgetWithText(TextButton, 'Comment'),
            findsNWidgets(3),
            reason:
                'Visible: ${tester.widgetList<Text>(find.byType(Text)).map((text) => text.data).toList()}; draft=${draft.methods}; snapshots=${draft.snapshots}',
          );
          expect(find.text(r'\ No newline at end of file'), findsOneWidget);
          expect(port.reviewResolutions, 0);
          await tester.tap(_lineComment(line.$1));
          await tester.pumpAndSettle();
          await save(tester, '  exact \u03bb feedback  ');
          final created = draft.creates.single;
          expect(created.sessionId, 'canonical');
          expect(created.text, '  exact \u03bb feedback  ');
          final anchor = created.anchor;
          expect(anchor.environmentId, 'canonical-environment');
          expect(anchor.relativePath, 'dir/notes [deleted] "two words".txt');
          expect(anchor.layer, ReviewComparisonLayer.unstaged);
          expect(anchor.side, line.$2);
          expect(anchor.startLine, line.$3);
          expect(anchor.endLine, line.$3);
          expect(anchor.hunkIndex, 0);
          expect(anchor.lineIndex, line.$4);
          expect(anchor.sourceExcerpt, line.$4 == 2 ? line.$1 : '${line.$1}\n');
          expect(anchor.comparisonIdentity, 'comparison:original');
          expect(draft.methods, [
            reviewDraftServiceSnapshotId,
            reviewDraftServiceReadReviewId,
            reviewDraftServiceCreateCommentId,
            reviewDraftServiceSnapshotId,
            reviewDraftServiceReadReviewId,
          ]);
          expect(draft.payloads.first, {'sessionId': 'canonical'});
          expect(find.text('Pending review comments (1)'), findsOneWidget);
          expect(find.text('  exact \u03bb feedback  '), findsOneWidget);
          expect(port.review.operations, isEmpty);
          expect(source.paths, isEmpty);
        },
      );
    }

    for (final (kind, noNewline) in [
      ('added', false),
      ('added', true),
      ('deleted', false),
      ('deleted', true),
    ]) {
      testWidgets(
        '$kind zero opposite side captures CRLF noNewline=$noNewline excerpt unchanged',
        (tester) async {
          final addition = kind == 'added';
          port.service.value = _commentSnapshot(
            changeKind: kind,
            hunks: [
              DiffHunk(
                oldStart: addition ? 0 : 1,
                oldCount: addition ? 0 : 1,
                newStart: addition ? 1 : 0,
                newCount: addition ? 1 : 0,
                lines: [
                  DiffLine(
                    kind: addition ? 'addition' : 'deletion',
                    text: 'exact CRLF\r',
                    noNewline: noNewline,
                  ),
                ],
              ),
            ],
          );
          await mountComments(tester);
          expect(find.widgetWithText(TextButton, 'Comment'), findsOneWidget);
          await tester.tap(_lineComment('exact CRLF'));
          await tester.pumpAndSettle();
          await save(tester, 'line ending feedback');
          final anchor = draft.creates.single.anchor;
          expect(anchor.startLine, 1);
          expect(anchor.endLine, 1);
          expect(
            anchor.side,
            addition
                ? ReviewComparisonSide.newSide
                : ReviewComparisonSide.oldSide,
          );
          expect(
            anchor.sourceExcerpt,
            noNewline ? 'exact CRLF\r' : 'exact CRLF\r\n',
          );
          expect(anchor.lineIndex, 0);
          expect(
            find.text(r'\ No newline at end of file'),
            noNewline ? findsOneWidget : findsNothing,
          );
        },
      );
    }

    testWidgets(
      'coordinates remain original across hunks and no-newline display rows',
      (tester) async {
        port.service.value = _commentSnapshot(
          hunks: [
            DiffHunk(
              oldStart: 1,
              oldCount: 0,
              newStart: 1,
              newCount: 1,
              lines: const [
                DiffLine(kind: 'addition', text: 'first hunk', noNewline: true),
              ],
            ),
            DiffHunk(
              oldStart: 80,
              oldCount: 1,
              newStart: 91,
              newCount: 2,
              lines: const [
                DiffLine(
                  kind: 'context',
                  text: 'second context',
                  noNewline: true,
                ),
                DiffLine(
                  kind: 'addition',
                  text: 'second addition',
                  noNewline: false,
                ),
              ],
            ),
          ],
        );
        await mountComments(tester);
        await tester.tap(_lineComment('second addition'));
        await tester.pumpAndSettle();
        await save(tester, 'second hunk feedback');
        final anchor = draft.creates.single.anchor;
        expect(anchor.hunkIndex, 1);
        expect(anchor.lineIndex, 1);
        expect(anchor.startLine, 92);
        expect(anchor.sourceExcerpt, 'second addition\n');
      },
    );

    testWidgets(
      'inclusive maximum line and excerpt bounds remain commentable',
      (tester) async {
        final excerpt = 'x' * ReviewDraftLimits.maxExcerptLength;
        port.service.value = _commentSnapshot(
          hunks: [
            DiffHunk(
              oldStart: 0,
              oldCount: 0,
              newStart: ReviewDraftLimits.maxLine,
              newCount: 1,
              lines: [
                DiffLine(kind: 'addition', text: excerpt, noNewline: true),
              ],
            ),
          ],
        );
        await mountComments(tester);
        await tester.tap(find.widgetWithText(TextButton, 'Comment'));
        await tester.pumpAndSettle();
        await save(tester, 'at bounds');
        expect(
          draft.creates.single.anchor.startLine,
          ReviewDraftLimits.maxLine,
        );
        expect(draft.creates.single.anchor.sourceExcerpt, excerpt);
      },
    );

    testWidgets(
      'unsafe anchor bounds withhold comments without breaking readable diff',
      (tester) async {
        await mountComments(tester);
        for (final entry in [
          (0, 'zero line'),
          (ReviewDraftLimits.maxLine + 1, 'overflow line'),
          (1, 'x' * (ReviewDraftLimits.maxExcerptLength + 1)),
        ]) {
          port.service.value = _commentSnapshot(
            hunks: [
              DiffHunk(
                oldStart: 0,
                oldCount: 0,
                newStart: entry.$1,
                newCount: 1,
                lines: [
                  DiffLine(kind: 'addition', text: entry.$2, noNewline: false),
                ],
              ),
            ],
          );
          await tester.tap(find.text('Refresh'));
          await tester.pumpAndSettle();
          expect(find.widgetWithText(TextButton, 'Comment'), findsNothing);
          expect(find.textContaining(entry.$2), findsOneWidget);
          expect(tester.takeException(), isNull);
        }
        expect(draft.creates, isEmpty);
      },
    );

    testWidgets(
      'comment eligibility requires certified text independently of approval',
      (tester) async {
        await mountComments(tester);
        for (final entry in [
          ('modified', 'text', null),
          ('modified', 'binary', 'comparison'),
          ('modified', 'oversized', 'comparison'),
          ('modified', 'unsupported', 'comparison'),
          ('conflicted', 'text', 'comparison'),
          ('unsupported', 'text', 'comparison'),
        ]) {
          port.service.value = _commentSnapshot(
            changeKind: entry.$1,
            contentStatus: entry.$2,
            identity: entry.$3,
          );
          await tester.tap(find.text('Refresh'));
          await tester.pumpAndSettle();
          expect(
            find.widgetWithText(TextButton, 'Comment'),
            findsNothing,
            reason: '$entry',
          );
          expect(find.textContaining('[${entry.$1}]'), findsOneWidget);
          expect(tester.takeException(), isNull);
        }
        expect(draft.creates, isEmpty);
        expect(port.review.operations, isEmpty);
      },
    );

    testWidgets(
      'invalid paths and comparison identities never become comment selections',
      (tester) async {
        await mountComments(tester);
        for (final path in [
          '',
          '/absolute.txt',
          'a/../b',
          '.git/config',
          r'a\b',
          'C:drive.txt',
          'a//b',
          'bad\u0000path',
          'x' * (ReviewDraftLimits.maxPathLength + 1),
        ]) {
          port.service.value = _commentSnapshot(path: path);
          await tester.tap(find.text('Refresh'));
          await tester.pumpAndSettle();
          expect(
            find.widgetWithText(TextButton, 'Comment'),
            findsNothing,
            reason: path,
          );
          expect(tester.takeException(), isNull);
        }
        for (final identity in [
          '',
          ' ',
          'bad\nidentity',
          '\u03bb',
          'x' * (ReviewDraftLimits.maxComparisonIdentityLength + 1),
        ]) {
          port.service.value = _commentSnapshot(identity: identity);
          await tester.tap(find.text('Refresh'));
          await tester.pumpAndSettle();
          expect(
            find.widgetWithText(TextButton, 'Comment'),
            findsNothing,
            reason: identity,
          );
          expect(tester.takeException(), isNull);
        }
        expect(draft.creates, isEmpty);
      },
    );

    for (final layer in ReviewComparisonLayer.values) {
      testWidgets(
        '${layer.name} comments retain their own comparison and typed layer',
        (tester) async {
          port.service.task = _task(
            committed: _commentSnapshot(identity: 'committed:comparison'),
            uncommitted: _uncommitted(
              staged: _commentSnapshot(identity: 'staged:comparison'),
              unstaged: _commentSnapshot(identity: 'unstaged:comparison'),
              conflicts: _commentSnapshot(
                identity: 'conflict:never-comment',
              ).files,
            ),
          );
          await mountComments(tester);
          await tester.tap(find.widgetWithText(TextButton, 'Task / Branch'));
          await tester.pumpAndSettle();
          expect(find.widgetWithText(TextButton, 'Comment'), findsNWidgets(9));
          final index = layer == ReviewComparisonLayer.committed
              ? 0
              : layer == ReviewComparisonLayer.staged
              ? 3
              : 6;
          await tester.tap(
            find.widgetWithText(TextButton, 'Comment').at(index + 2),
          );
          await tester.pumpAndSettle();
          await save(tester, '${layer.name} feedback');
          expect(draft.creates.single.anchor.layer, layer);
          expect(
            draft.creates.single.anchor.comparisonIdentity,
            '${layer.name}:comparison',
          );
          expect(port.reviewResolutions, 0);
          expect(source.paths, isEmpty);
        },
      );
    }

    testWidgets(
      'same and different locations create distinct comments in authoritative order',
      (tester) async {
        port.service.value = _commentSnapshot();
        await mountComments(tester);
        for (final entry in [
          ('added line', 'same text'),
          ('added line', 'same text'),
          ('removed line', 'different location'),
        ]) {
          await tester.tap(_lineComment(entry.$1));
          await tester.pumpAndSettle();
          await save(tester, entry.$2);
        }
        expect(draft.comments().map((comment) => comment.id), [
          'authoritative-101',
          'authoritative-102',
          'authoritative-103',
        ]);
        expect(draft.comments().map((comment) => comment.sequence), [
          101,
          102,
          103,
        ]);
        expect(find.text('same text'), findsNWidgets(2));
        expect(find.text('different location'), findsOneWidget);
        expect(find.text('Pending review comments (3)'), findsOneWidget);
        expect(
          tester.getTopLeft(find.text('same text').last).dy,
          lessThan(tester.getTopLeft(find.text('different location')).dy),
        );
        expect(draft.snapshots, List.filled(4, 'canonical'));
        expect(port.service.calls, 1);
      },
    );

    testWidgets(
      'create update and delete reload authoritative revision without optimistic IDs',
      (tester) async {
        port.service.value = _commentSnapshot();
        draft.authoritativeText = 'server-created body';
        await mountComments(tester);
        await tester.tap(_lineComment('added line'));
        await tester.pumpAndSettle();
        await save(tester, 'submitted body');
        expect(find.text('server-created body'), findsOneWidget);
        await tester.tap(_savedCommentAction('server-created body', 'Edit'));
        await tester.pumpAndSettle();
        expect(
          tester.widget<TextField>(find.byType(TextField)).controller!.text,
          'server-created body',
        );
        draft.authoritativeText = 'server-updated body';
        await save(tester, 'edited body');
        expect(draft.updates.single, (
          sessionId: 'canonical',
          id: 'authoritative-101',
          version: 1,
          text: 'edited body',
        ));
        expect(find.text('server-updated body'), findsOneWidget);
        expect(find.text('server-created body'), findsNothing);
        await tester.tap(_savedCommentAction('server-updated body', 'Delete'));
        await tester.pumpAndSettle();
        expect(draft.deletes.single, (
          sessionId: 'canonical',
          id: 'authoritative-101',
          version: 2,
        ));
        expect(find.text('Pending review comments (0)'), findsOneWidget);
        expect(find.text('server-updated body'), findsNothing);
        expect(draft.snapshots, List.filled(4, 'canonical'));
        expect(port.service.calls, 1);
        expect(port.review.operations, isEmpty);
      },
    );

    testWidgets(
      'editing a middle comment preserves anchor ID sequence and sibling order',
      (tester) async {
        port.service.value = _commentSnapshot();
        draft.comments().addAll([
          _comment(id: 'a', text: 'first', sequence: 1),
          _comment(id: 'b', text: 'middle', sequence: 2),
          _comment(id: 'c', text: 'last', sequence: 3),
        ]);
        final original = draft.comments()[1];
        await mountComments(tester);
        await tester.tap(_savedCommentAction('middle', 'Edit'));
        await tester.pumpAndSettle();
        await save(tester, 'edited middle');
        expect(draft.comments().map((comment) => comment.id), ['a', 'b', 'c']);
        expect(draft.comments()[1].anchor, same(original.anchor));
        expect(draft.comments()[1].sequence, original.sequence);
        expect(draft.comments()[1].version, 4);
        expect(
          tester.getTopLeft(find.text('first')).dy,
          lessThan(tester.getTopLeft(find.text('edited middle')).dy),
        );
        expect(
          tester.getTopLeft(find.text('edited middle')).dy,
          lessThan(tester.getTopLeft(find.text('last')).dy),
        );
        await tester.tap(_savedCommentAction('edited middle', 'Delete'));
        await tester.pumpAndSettle();
        expect(draft.comments().map((comment) => comment.id), ['a', 'c']);
        expect(find.text('Pending review comments (2)'), findsOneWidget);
      },
    );

    testWidgets(
      'one retained editor survives refresh scope changes and lazy row disposal',
      (tester) async {
        port.service.value = _commentSnapshot();
        await mountComments(tester);
        await tester.tap(_lineComment('added line'));
        await tester.pumpAndSettle();
        await tester.enterText(find.byType(TextField), 'retained unsaved text');
        final controller = tester
            .widget<TextField>(find.byType(TextField))
            .controller;
        final listKey = tester.widget<ListView>(find.byType(ListView)).key;
        port.service.value = _commentSnapshot(
          identity: 'comparison:new',
          hunks: [
            DiffHunk(
              oldStart: 0,
              oldCount: 0,
              newStart: 1,
              newCount: 250,
              lines: [
                for (var index = 0; index < 250; index++)
                  DiffLine(
                    kind: 'addition',
                    text: 'lazy line $index',
                    noNewline: false,
                  ),
              ],
            ),
          ],
        );
        await tester.tap(find.text('Refresh'));
        await tester.pumpAndSettle();
        expect(tester.widget<ListView>(find.byType(ListView)).key, listKey);
        FocusManager.instance.primaryFocus?.unfocus();
        await tester.pumpAndSettle();
        await tester.drag(find.byType(ListView).first, const Offset(0, -5000));
        await tester.pumpAndSettle();
        expect(find.byType(TextField), findsNothing);
        expect(controller!.text, 'retained unsaved text');
        await reveal(tester, find.byType(TextField), delta: -500);
        expect(
          tester.widget<TextField>(find.byType(TextField)).controller,
          same(controller),
        );
        expect(controller.text, 'retained unsaved text');
        await tester.tap(find.widgetWithText(TextButton, 'Task / Branch'));
        await tester.pumpAndSettle();
        expect(tester.widget<ListView>(find.byType(ListView)).key, listKey);
        expect(
          tester.widget<TextField>(find.byType(TextField)).controller,
          same(controller),
        );
        expect(controller.text, 'retained unsaved text');
        await save(tester, controller.text);
        expect(
          draft.creates.single.anchor.comparisonIdentity,
          'comparison:original',
        );
        expect(draft.creates.single.anchor.startLine, 21);
        expect(draft.creates.single.anchor.sourceExcerpt, 'added line');
        expect(draft.snapshots, List.filled(4, 'canonical'));
      },
    );

    testWidgets(
      'unsaved text refuses departure and another selection until explicit cancel',
      (tester) async {
        port.service.value = _commentSnapshot();
        draft.comments().add(_comment());
        await mountComments(tester);
        final otherLine = tester.widget<TextButton>(
          _lineComment('removed line'),
        );
        await tester.tap(_lineComment('added line'));
        await tester.pumpAndSettle();
        await tester.enterText(find.byType(TextField), 'do not discard');
        otherLine.onPressed!();
        await tester.pumpAndSettle();
        expect(find.byType(TextField), findsOneWidget);
        expect(
          tester.widget<TextField>(find.byType(TextField)).controller!.text,
          'do not discard',
        );
        await expectLater(lifecycle.prepareToDeactivate(), throwsStateError);
        await tester.pumpAndSettle();
        expect(
          find.text('Save or cancel the comment before leaving this Session.'),
          findsOneWidget,
        );
        expect(
          tester.widget<TextField>(find.byType(TextField)).controller!.text,
          'do not discard',
        );
        expect(draft.creates, isEmpty);
        await tester.tap(find.widgetWithText(TextButton, 'Cancel editing'));
        await tester.pumpAndSettle();
        expect(find.byType(TextField), findsNothing);
        expect(find.text('saved feedback'), findsOneWidget);
        await lifecycle.prepareToDeactivate();
        expect(draft.creates, isEmpty);
      },
    );

    testWidgets(
      'empty whitespace and overlong comment text never start a mutation',
      (tester) async {
        port.service.value = _commentSnapshot();
        await mountComments(tester);
        await tester.tap(_lineComment('added line'));
        await tester.pumpAndSettle();
        for (final text in [
          '',
          '  \t  ',
          'x' * (ReviewDraftLimits.maxTextLength + 1),
        ]) {
          await tester.enterText(find.byType(TextField), text);
          final buttons = find.widgetWithText(TextButton, 'Save comment');
          if (buttons.evaluate().isNotEmpty) {
            tester.widget<TextButton>(buttons).onPressed?.call();
          }
          await tester.pumpAndSettle();
          expect(draft.creates, isEmpty);
          expect(tester.takeException(), isNull);
        }
        await save(tester, 'corrected feedback');
        expect(draft.creates.single.text, 'corrected feedback');
      },
    );

    testWidgets(
      'existing multiline body remains fully inspectable and cannot be overwritten',
      (tester) async {
        final body =
            'first line\r\n  second line\n${List.generate(40, (index) => 'line $index').join('\n')}\nlast line';
        port.service.value = _commentSnapshot();
        draft.comments().add(_comment(text: body));
        await mountComments(tester);
        expect(find.text(body), findsOneWidget);
        final edit = _savedCommentAction(body, 'Edit');
        final hasEditor = edit.evaluate().isNotEmpty;
        if (hasEditor) {
          await tester.tap(edit);
          await tester.pumpAndSettle();
        }
        expect(find.byType(TextField), findsNothing);
        expect(find.widgetWithText(TextButton, 'Save comment'), findsNothing);
        expect(find.text(body), findsWidgets);
        for (final text in tester.widgetList<Text>(find.text(body))) {
          expect(text.maxLines, isNull);
        }
        if (hasEditor) {
          final inspection = find
              .ancestor(
                of: find.text(body).first,
                matching: find.byType(SingleChildScrollView),
              )
              .first;
          await tester.drag(inspection, const Offset(0, -400));
          await tester.pumpAndSettle();
          final scrollable = find.descendant(
            of: inspection,
            matching: find.byType(Scrollable),
          );
          expect(
            tester.state<ScrollableState>(scrollable).position.pixels,
            greaterThan(0),
          );
        }
        expect(draft.updates, isEmpty);
        expect(draft.comments().single.text, body);
        final cancel = find.widgetWithText(TextButton, 'Cancel editing');
        if (cancel.evaluate().isNotEmpty) {
          await tester.tap(cancel);
          await tester.pumpAndSettle();
        }
        await tester.tap(_savedCommentAction(body, 'Delete'));
        await tester.pumpAndSettle();
        expect(draft.deletes.single.id, 'saved-1');
        expect(find.text('Pending review comments (0)'), findsOneWidget);
      },
    );

    for (final operation in ['create', 'update', 'delete']) {
      testWidgets(
        'pending $operation blocks duplicate mutations and departure, not reads or Source',
        (tester) async {
          registerSource();
          port.service.value = _commentSnapshot();
          draft.comments().add(_comment());
          await mountComments(tester);
          final reload = tester.widget<TextButton>(
            find.widgetWithText(TextButton, 'Reload comments'),
          );
          final otherDelete = tester.widget<TextButton>(
            _savedCommentAction('saved feedback', 'Delete'),
          );
          final gate = draft.holdMutation();
          late TextButton action;
          if (operation == 'delete') {
            action = tester.widget<TextButton>(
              _savedCommentAction('saved feedback', 'Delete'),
            );
          } else {
            await tester.tap(
              operation == 'create'
                  ? _lineComment('added line')
                  : _savedCommentAction('saved feedback', 'Edit'),
            );
            await tester.pumpAndSettle();
            await tester.enterText(find.byType(TextField), 'pending body');
            action = tester.widget<TextButton>(
              find.widgetWithText(TextButton, 'Save comment'),
            );
          }
          action.onPressed!();
          action.onPressed!();
          reload.onPressed!();
          otherDelete.onPressed!();
          await tester.pumpAndSettle();
          expect(
            draft.creates.length + draft.updates.length + draft.deletes.length,
            1,
          );
          expect(find.text('Pending review comments (1)'), findsOneWidget);
          expect(
            find.text('pending body'),
            operation == 'delete' ? findsNothing : findsWidgets,
          );
          await expectLater(lifecycle.prepareToDeactivate(), throwsStateError);
          await tester.pumpAndSettle();
          expect(
            find.text(
              'Save or cancel the comment before leaving this Session.',
            ),
            findsOneWidget,
          );
          await tester.tap(find.text('Open in Source'));
          await tester.pumpAndSettle();
          expect(source.paths, ['dir/notes [deleted] "two words".txt']);
          await tester.tap(find.text('Refresh'));
          await tester.pumpAndSettle();
          expect(port.service.calls, 2);
          expect(draft.snapshots, ['canonical']);
          action.onPressed!();
          await tester.pumpAndSettle();
          expect(
            draft.creates.length + draft.updates.length + draft.deletes.length,
            1,
          );
          gate.complete();
          await tester.pumpAndSettle();
          expect(
            find.text(
              'Pending review comments (${operation == 'create'
                  ? 2
                  : operation == 'delete'
                  ? 0
                  : 1})',
            ),
            findsOneWidget,
          );
          expect(draft.snapshots, List.filled(2, 'canonical'));
          expect(tester.takeException(), isNull);
        },
      );
    }

    for (final operation in ['create', 'update', 'delete']) {
      testWidgets(
        'uncertain $operation requires explicit reload and never replays a stale callback',
        (tester) async {
          port.service.value = _commentSnapshot();
          draft.comments().add(_comment());
          await mountComments(tester);
          draft.afterMutationFailure = const ReviewDraftFailure(
            code: 'outcome_uncertain',
            message: 'private lost acknowledgement',
          );
          late TextButton old;
          if (operation == 'delete') {
            old = tester.widget<TextButton>(
              _savedCommentAction('saved feedback', 'Delete'),
            );
          } else {
            await tester.tap(
              operation == 'create'
                  ? _lineComment('added line')
                  : _savedCommentAction('saved feedback', 'Edit'),
            );
            await tester.pumpAndSettle();
            await tester.enterText(find.byType(TextField), 'unconfirmed body');
            old = tester.widget<TextButton>(
              find.widgetWithText(TextButton, 'Save comment'),
            );
          }
          old.onPressed!();
          await tester.pumpAndSettle();
          expect(
            find.text(
              'Comment change not confirmed. Reload comments before trying again.',
            ),
            findsOneWidget,
          );
          expect(find.textContaining('private'), findsNothing);
          expect(draft.snapshots, ['canonical']);
          expect(find.text('Pending review comments (1)'), findsOneWidget);
          old.onPressed!();
          // Refresh explicitly rereads both sources, never replays the mutation.
          await tester.tap(find.text('Refresh'));
          await tester.pumpAndSettle();
          expect(
            draft.creates.length + draft.updates.length + draft.deletes.length,
            1,
          );
          expect(draft.snapshots, List.filled(2, 'canonical'));
          if (operation != 'delete') {
            expect(
              tester.widget<TextField>(find.byType(TextField)).controller!.text,
              'unconfirmed body',
            );
          }
          draft.afterMutationFailure = null;
          await tester.tap(find.widgetWithText(TextButton, 'Reload comments'));
          await tester.pumpAndSettle();
          expect(draft.snapshots, List.filled(3, 'canonical'));
          expect(
            find.text(
              'Pending review comments (${operation == 'create'
                  ? 2
                  : operation == 'delete'
                  ? 0
                  : 1})',
            ),
            findsOneWidget,
          );
          old.onPressed!();
          await tester.pumpAndSettle();
          expect(
            draft.creates.length + draft.updates.length + draft.deletes.length,
            1,
          );
          if (operation != 'delete') {
            expect(
              tester.widget<TextField>(find.byType(TextField)).controller!.text,
              'unconfirmed body',
            );
            final saveButton = find.widgetWithText(TextButton, 'Save comment');
            if (saveButton.evaluate().isNotEmpty) {
              tester.widget<TextButton>(saveButton).onPressed?.call();
            }
            await tester.pumpAndSettle();
            expect(
              draft.creates.length +
                  draft.updates.length +
                  draft.deletes.length,
              1,
            );
            await tester.tap(find.widgetWithText(TextButton, 'Cancel editing'));
            await tester.pumpAndSettle();
            await tester.tap(_savedCommentAction('unconfirmed body', 'Edit'));
            await tester.pumpAndSettle();
            await save(tester, 'explicit fresh edit');
            expect(draft.updates.last.version, operation == 'create' ? 1 : 4);
            expect(draft.comments().last.text, 'explicit fresh edit');
          }
          expect(tester.takeException(), isNull);
        },
      );
    }

    testWidgets(
      'stale update preserves unsaved text through failed and successful explicit reload',
      (tester) async {
        port.service.value = _commentSnapshot();
        draft.comments().add(_comment());
        await mountComments(tester);
        await tester.tap(_savedCommentAction('saved feedback', 'Edit'));
        await tester.pumpAndSettle();
        draft.comments()[0] = _comment(text: 'external change', version: 9);
        await save(tester, 'local unsaved edit');
        expect(draft.updates.single.version, 3);
        expect(
          find.text(
            'Comment change not confirmed. Reload comments before trying again.',
          ),
          findsOneWidget,
        );
        draft.snapshotFailure = StateError('private snapshot failure');
        await tester.tap(find.text('Reload comments'));
        await tester.pumpAndSettle();
        expect(
          tester.widget<TextField>(find.byType(TextField)).controller!.text,
          'local unsaved edit',
        );
        expect(draft.updates, hasLength(1));
        draft.snapshotFailure = null;
        await tester.tap(find.text('Reload comments'));
        await tester.pumpAndSettle();
        expect(find.text('external change'), findsOneWidget);
        expect(
          tester.widget<TextField>(find.byType(TextField)).controller!.text,
          'local unsaved edit',
        );
        expect(draft.updates, hasLength(1));
        await tester.tap(find.text('Cancel editing'));
        await tester.pumpAndSettle();
        await tester.tap(_savedCommentAction('external change', 'Edit'));
        await tester.pumpAndSettle();
        await save(tester, 'fresh explicit edit');
        expect(draft.updates.last.version, 9);
        expect(draft.comments().single.version, 10);
      },
    );

    testWidgets(
      'current outside and outdated labels never rewrite the retained anchor',
      (tester) async {
        port.service.value = _commentSnapshot();
        draft.comments().addAll([
          _comment(text: 'current comment'),
          _comment(
            id: 'outside',
            text: 'outside comment',
            sequence: 2,
            anchor: _commentAnchor(layer: ReviewComparisonLayer.committed),
          ),
          _comment(
            id: 'outdated',
            text: 'outdated comment',
            sequence: 3,
            anchor: _commentAnchor(identity: 'comparison:older'),
          ),
        ]);
        await mountComments(tester);
        expect(find.text('Current location'), findsOneWidget);
        expect(
          find.text('Outside current scope / not inspected'),
          findsOneWidget,
        );
        expect(find.text('Outdated location'), findsOneWidget);
        port.service.task = _task(
          committed: _commentSnapshot(),
          uncommitted: _uncommitted(
            unstaged: _commentSnapshot(identity: 'comparison:newer'),
          ),
        );
        await tester.tap(find.widgetWithText(TextButton, 'Task / Branch'));
        await tester.pumpAndSettle();
        expect(find.text('Current location'), findsOneWidget);
        expect(find.text('Outdated location'), findsNWidgets(2));
        expect(
          draft.comments().first.anchor.comparisonIdentity,
          'comparison:original',
        );
        expect(
          draft.comments().last.anchor.comparisonIdentity,
          'comparison:older',
        );
        expect(draft.updates, isEmpty);
        expect(draft.snapshots, List.filled(2, 'canonical'));
      },
    );

    for (final layer in ReviewComparisonLayer.values) {
      testWidgets(
        '${layer.name} scope classification separates working conflicts from inspected history',
        (tester) async {
          final conflict = _commentSnapshot(
            identity: null,
            changeKind: 'conflicted',
            contentStatus: 'unsupported',
            hunks: [],
          );
          port.service.value = conflict;
          port.service.uncommitted = _uncommitted(conflicts: conflict.files);
          port.service.task = _task(uncommitted: port.service.uncommitted);
          final saved = _comment(
            text: 'conflicted location feedback',
            anchor: _commentAnchor(layer: layer),
          );
          draft.comments().addAll([
            saved,
            _comment(
              id: 'missing-path',
              text: 'genuinely missing location',
              sequence: 2,
              anchor: _commentAnchor(layer: layer, path: 'missing.txt'),
            ),
          ]);
          await mountComments(tester);
          final conflictedCard = find
              .ancestor(
                of: find.text(saved.text),
                matching: find.byType(Column),
              )
              .first;
          for (final scope in [
            'Unstaged changes',
            'Uncommitted changes',
            'Task / Branch',
            'Unstaged changes',
          ]) {
            await tester.tap(find.widgetWithText(TextButton, scope));
            await tester.pumpAndSettle();
            final committedInspected =
                layer == ReviewComparisonLayer.committed &&
                scope == 'Task / Branch';
            expect(
              find.descendant(
                of: conflictedCard,
                matching: find.text('Outside current scope / not inspected'),
              ),
              committedInspected ? findsNothing : findsOneWidget,
            );
            expect(
              find.descendant(
                of: conflictedCard,
                matching: find.text('Outdated location'),
              ),
              committedInspected ? findsOneWidget : findsNothing,
            );
            expect(find.widgetWithText(TextButton, 'Comment'), findsNothing);
            if (scope == 'Task / Branch') {
              // Working conflicts cannot mask either inspected missing history
              // or the unrelated missing path in an ordinary comparison.
              expect(
                find.text('Outdated location'),
                findsNWidgets(committedInspected ? 2 : 1),
              );
            }
            expect(tester.takeException(), isNull);
          }
          final original = _commentSnapshot();
          port.service.task = _task(
            committed: original,
            uncommitted: _uncommitted(staged: original, unstaged: original),
          );
          await tester.tap(find.widgetWithText(TextButton, 'Task / Branch'));
          await tester.pumpAndSettle();
          expect(
            find.descendant(
              of: conflictedCard,
              matching: find.text('Current location'),
            ),
            findsOneWidget,
          );
          expect(find.text('Outdated location'), findsOneWidget);
          expect(draft.comments().first, same(saved));
          expect(
            draft.comments().first.anchor.comparisonIdentity,
            'comparison:original',
          );
          expect(draft.creates, isEmpty);
          expect(draft.updates, isEmpty);
          expect(draft.deletes, isEmpty);
        },
      );
    }

    testWidgets(
      'certified committed history remains commentable beside a same-path working conflict',
      (tester) async {
        final conflict = _commentSnapshot(
          identity: null,
          changeKind: 'conflicted',
          contentStatus: 'unsupported',
          hunks: [],
        );
        port.service.value = conflict;
        port.service.uncommitted = _uncommitted(conflicts: conflict.files);
        port.service.task = _task(
          committed: _commentSnapshot(),
          uncommitted: port.service.uncommitted,
        );
        final original = _comment(
          text: 'saved committed feedback',
          anchor: _commentAnchor(layer: ReviewComparisonLayer.committed),
        );
        draft.comments().add(original);
        await mountComments(tester);
        expect(
          find.text('Outside current scope / not inspected'),
          findsOneWidget,
        );
        await tester.tap(find.widgetWithText(TextButton, 'Task / Branch'));
        await tester.pumpAndSettle();
        expect(find.textContaining('[conflicted]'), findsOneWidget);
        expect(find.text('Current location'), findsOneWidget);
        expect(
          find.text('Outside current scope / not inspected'),
          findsNothing,
        );
        expect(find.text('Outdated location'), findsNothing);
        expect(find.widgetWithText(TextButton, 'Comment'), findsNWidgets(3));
        await tester.tap(_lineComment('added line'));
        await tester.pumpAndSettle();
        expect(find.text('Current location'), findsNWidgets(2));
        expect(
          find.text('Outside current scope / not inspected'),
          findsNothing,
        );
        await save(tester, 'new committed feedback');
        final created = draft.creates.single;
        expect(created.sessionId, 'canonical');
        expect(created.text, 'new committed feedback');
        expect(created.anchor.environmentId, 'canonical-environment');
        expect(created.anchor.relativePath, original.anchor.relativePath);
        expect(created.anchor.layer, ReviewComparisonLayer.committed);
        expect(created.anchor.side, ReviewComparisonSide.newSide);
        expect(created.anchor.startLine, 21);
        expect(created.anchor.endLine, 21);
        expect(created.anchor.hunkIndex, 0);
        expect(created.anchor.lineIndex, 2);
        expect(created.anchor.sourceExcerpt, 'added line');
        expect(created.anchor.comparisonIdentity, 'comparison:original');
        expect(draft.comments().map((comment) => comment.id), [
          'saved-1',
          'authoritative-101',
        ]);
        expect(draft.comments().map((comment) => comment.version), [3, 1]);
        expect(find.text('Pending review comments (2)'), findsOneWidget);
        expect(find.text('Current location'), findsNWidgets(2));
        expect(
          find.text('Outside current scope / not inspected'),
          findsNothing,
        );
        expect(draft.snapshots, List.filled(3, 'canonical'));

        port.service.task = _task(
          committed: _commentSnapshot(identity: 'comparison:committed-changed'),
          uncommitted: port.service.uncommitted,
        );
        await tester.tap(find.text('Refresh'));
        await tester.pumpAndSettle();
        expect(find.textContaining('[conflicted]'), findsOneWidget);
        expect(find.text('Outdated location'), findsNWidgets(2));
        expect(find.text('Current location'), findsNothing);
        expect(
          find.text('Outside current scope / not inspected'),
          findsNothing,
        );
        expect(find.text('saved committed feedback'), findsOneWidget);
        expect(find.text('new committed feedback'), findsOneWidget);
        expect(draft.comments().first, same(original));
        expect(draft.comments().last.anchor, same(created.anchor));
        expect(draft.updates, isEmpty);
        expect(draft.deletes, isEmpty);

        await tester.tap(
          _savedCommentAction('saved committed feedback', 'Edit'),
        );
        await tester.pumpAndSettle();
        expect(find.text('Outdated location'), findsNWidgets(3));
        await save(tester, 'edited historical feedback');
        expect(draft.updates.single, (
          sessionId: 'canonical',
          id: original.id,
          version: original.version,
          text: 'edited historical feedback',
        ));
        expect(draft.comments().first.anchor, same(original.anchor));
        expect(draft.comments().first.version, 4);
        expect(draft.comments().first.sequence, original.sequence);
        expect(draft.comments().last.anchor, same(created.anchor));
        expect(
          draft.comments().every(
            (comment) =>
                comment.anchor.comparisonIdentity == 'comparison:original',
          ),
          isTrue,
        );
        expect(find.text('Outdated location'), findsNWidgets(2));
        expect(find.text('edited historical feedback'), findsOneWidget);
        expect(draft.creates, hasLength(1));
        expect(draft.deletes, isEmpty);
        expect(draft.snapshots, List.filled(5, 'canonical'));
        expect(port.review.operations, isEmpty);
        expect(source.paths, isEmpty);
      },
    );

    testWidgets(
      'stored old-side context is current while unsupported ranges stay inspectable',
      (tester) async {
        port.service.value = _commentSnapshot();
        draft.comments().addAll([
          _comment(
            text: 'old context feedback',
            anchor: _commentAnchor(
              side: ReviewComparisonSide.oldSide,
              startLine: 10,
              lineIndex: 0,
              excerpt: 'shared context\n',
            ),
          ),
          _comment(
            id: 'range',
            text: 'range feedback',
            sequence: 2,
            anchor: _commentAnchor(
              startLine: 20,
              endLine: 21,
              lineIndex: 0,
              excerpt: 'shared context\nadded line',
            ),
          ),
        ]);
        await mountComments(tester);
        expect(find.text('Current location'), findsOneWidget);
        expect(
          find.text('Outside current scope / not inspected'),
          findsOneWidget,
        );
        expect(find.text('Outdated location'), findsNothing);
        expect(find.text('shared context\nadded line'), findsOneWidget);
        await tester.tap(_savedCommentAction('old context feedback', 'Edit'));
        await tester.pumpAndSettle();
        await save(tester, 'body edit only');
        expect(
          draft.comments().first.anchor.side,
          ReviewComparisonSide.oldSide,
        );
        expect(draft.comments().first.anchor.startLine, 10);
        expect(draft.comments().last.anchor.endLine, 21);
      },
    );

    testWidgets(
      'uninspected and other-Environment locations remain inspectable and editable without reanchoring',
      (tester) async {
        port.service.value = _commentSnapshot(identity: null);
        draft.comments().addAll([
          _comment(text: 'uninspected feedback'),
          _comment(
            id: 'other-environment',
            text: 'other Environment feedback',
            sequence: 2,
            anchor: _commentAnchor(environmentId: 'other-environment'),
          ),
        ]);
        await mountComments(tester);
        expect(
          find.text('Outside current scope / not inspected'),
          findsNWidgets(2),
        );
        expect(find.text('Outdated location'), findsNothing);
        await tester.tap(
          _savedCommentAction('other Environment feedback', 'Edit'),
        );
        await tester.pumpAndSettle();
        await save(tester, 'body-only change');
        final saved = draft.comments().last;
        expect(saved.anchor.environmentId, 'other-environment');
        expect(saved.anchor.comparisonIdentity, 'comparison:original');
        expect(saved.anchor.sourceExcerpt, 'added line');
        expect(draft.updates.single.sessionId, 'canonical');
        expect(port.review.operations, isEmpty);
        expect(source.paths, isEmpty);
      },
    );

    testWidgets(
      'latest explicit reload wins and a foreign Session snapshot is never rendered',
      (tester) async {
        port.service.value = _commentSnapshot();
        draft.comments().add(_comment());
        await mountComments(tester);
        final older = draft.holdSnapshot();
        await tester.tap(find.text('Reload comments'));
        await tester.pumpAndSettle();
        draft.comments()[0] = _comment(text: 'fresh snapshot', version: 8);
        await tester.tap(find.text('Reload comments'));
        await tester.pumpAndSettle();
        expect(find.text('fresh snapshot'), findsOneWidget);
        older.complete(
          ReviewDraftSnapshot(
            sessionId: 'canonical',
            revision: 0,
            comments: [_comment(text: 'late old snapshot')],
            currentReview: null,
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('fresh snapshot'), findsOneWidget);
        expect(find.text('late old snapshot'), findsNothing);
        final foreign = draft.holdSnapshot();
        await tester.tap(find.text('Reload comments'));
        await tester.pumpAndSettle();
        foreign.complete(
          ReviewDraftSnapshot(
            sessionId: 'foreign-session',
            revision: 0,
            comments: [_comment(text: 'foreign feedback')],
            currentReview: null,
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('foreign feedback'), findsNothing);
        expect(find.text('fresh snapshot'), findsOneWidget);
        expect(find.widgetWithText(TextButton, 'Edit'), findsNothing);
        expect(find.widgetWithText(TextButton, 'Comment'), findsNothing);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'Git approval preserves unsaved comment while pending comment blocks Git writes',
      (tester) async {
        port.service.value = _reviewSnapshot(
          hunks: 1,
          commentIdentity: 'independent:comment',
        );
        await mountComments(tester);
        await tester.tap(_lineComment('new-0'));
        await tester.pumpAndSettle();
        await tester.enterText(find.byType(TextField), 'independent feedback');
        final controller = tester
            .widget<TextField>(find.byType(TextField))
            .controller;
        final approvalGate = Completer<void>();
        addTearDown(() {
          if (!approvalGate.isCompleted) approvalGate.complete();
        });
        port.review.pending = approvalGate.future;
        final oldSave = tester.widget<TextButton>(
          find.widgetWithText(TextButton, 'Save comment'),
        );
        await tester.tap(find.text('Approve'));
        await tester.pumpAndSettle();
        oldSave.onPressed!();
        await tester.pumpAndSettle();
        expect(draft.creates, isEmpty);
        expect(controller!.text, 'independent feedback');
        approvalGate.complete();
        await tester.pumpAndSettle();
        expect(
          tester.widget<TextField>(find.byType(TextField)).controller,
          same(controller),
        );
        expect(draft.snapshots, List.filled(2, 'canonical'));
        final oldApprove = tester.widget<TextButton>(
          find.widgetWithText(TextButton, 'Approve'),
        );
        final commentGate = draft.holdMutation();
        await save(tester, controller.text);
        oldApprove.onPressed!();
        await tester.pumpAndSettle();
        expect(port.review.operations, ['approve']);
        commentGate.complete();
        await tester.pumpAndSettle();
        expect(
          draft.creates.single.anchor.comparisonIdentity,
          'independent:comment',
        );
        expect(draft.snapshots, List.filled(3, 'canonical'));
        expect(port.review.operations, ['approve']);
      },
    );

    testWidgets('comment controls and retained editor fit narrow panes', (
      tester,
    ) async {
      port.service.value = _commentSnapshot();
      draft.comments().add(_comment());
      await mountComments(tester);
      await tester.tap(_lineComment('added line'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'narrow feedback');
      for (final width in [320.0, 480.0, 900.0]) {
        await tester.binding.setSurfaceSize(Size(width, 1400));
        await tester.pumpAndSettle();
        for (final button in tester.widgetList<TextButton>(
          find.byType(TextButton),
        )) {
          final rect = tester.getRect(find.byWidget(button));
          expect(rect.left, greaterThanOrEqualTo(0));
          expect(rect.right, lessThanOrEqualTo(width));
        }
        expect(
          tester.widget<TextField>(find.byType(TextField)).controller!.text,
          'narrow feedback',
        );
        expect(tester.takeException(), isNull, reason: 'width=$width');
      }
      await save(tester, 'narrow feedback');
      expect(draft.creates.single.text, 'narrow feedback');
    });

    for (final height in [400.0, 277.0]) {
      testWidgets(
        '320x$height pane keeps virtualized draft and exposes Save and Cancel by scrolling',
        (tester) async {
          port.service.value = _commentSnapshot(
            hunks: [
              DiffHunk(
                oldStart: 0,
                oldCount: 0,
                newStart: 1,
                newCount: 250,
                lines: [
                  for (var index = 0; index < 250; index++)
                    DiffLine(
                      kind: 'addition',
                      text: 'short-pane line $index',
                      noNewline: false,
                    ),
                ],
              ),
            ],
          );
          port.service.task = _task(
            uncommitted: _uncommitted(unstaged: port.service.value),
          );
          await mountComments(tester, size: Size(320, height));
          final originalKey = tester
              .widget<ListView>(find.byType(ListView))
              .key;
          await reveal(tester, find.textContaining('short-pane line 80'));
          await tester.tap(_lineComment('short-pane line 80'));
          await tester.pumpAndSettle();
          final editorKey = tester.widget<ListView>(find.byType(ListView)).key;
          expect(editorKey, isNot(originalKey));
          expect(
            tester.state<ScrollableState>(paneScroll()).position.pixels,
            0,
          );
          await reveal(tester, find.byType(TextField));
          await tester.enterText(
            find.byType(TextField),
            'short-pane unsaved feedback',
          );
          final controller = tester
              .widget<TextField>(find.byType(TextField))
              .controller!;
          FocusManager.instance.primaryFocus?.unfocus();
          await tester.pumpAndSettle();
          await tester.drag(find.byType(ListView), const Offset(0, -2500));
          await tester.pumpAndSettle();
          expect(find.byType(TextField), findsNothing);
          expect(controller.text, 'short-pane unsaved feedback');
          expect(tester.widget<ListView>(find.byType(ListView)).key, editorKey);
          await reveal(tester, find.byType(TextField), delta: -200);
          expect(
            tester.widget<TextField>(find.byType(TextField)).controller,
            same(controller),
          );

          for (final action in ['Refresh', 'Task / Branch']) {
            await reveal(tester, find.widgetWithText(TextButton, action));
            final position = tester
                .state<ScrollableState>(paneScroll())
                .position;
            await tester.tap(find.widgetWithText(TextButton, action));
            await tester.pumpAndSettle();
            expect(
              tester.widget<ListView>(find.byType(ListView)).key,
              editorKey,
            );
            expect(
              tester.state<ScrollableState>(paneScroll()).position,
              same(position),
            );
            await reveal(tester, find.byType(TextField), delta: -200);
            expect(
              tester.widget<TextField>(find.byType(TextField)).controller,
              same(controller),
            );
            expect(controller.text, 'short-pane unsaved feedback');
          }
          await reveal(tester, find.widgetWithText(TextButton, 'Save comment'));
          final saveRect = tester.getRect(
            find.widgetWithText(TextButton, 'Save comment'),
          );
          expect(saveRect.top, greaterThanOrEqualTo(0));
          expect(saveRect.bottom, lessThanOrEqualTo(height));
          await tester.tap(find.widgetWithText(TextButton, 'Save comment'));
          await tester.pumpAndSettle();
          expect(draft.creates.single.text, 'short-pane unsaved feedback');
          expect(draft.creates.single.anchor.startLine, 81);
          expect(draft.creates.single.anchor.lineIndex, 80);
          expect(
            draft.creates.single.anchor.sourceExcerpt,
            'short-pane line 80\n',
          );
          expect(
            draft.creates.single.anchor.layer,
            ReviewComparisonLayer.unstaged,
          );
          expect(
            draft.creates.single.anchor.comparisonIdentity,
            'comparison:original',
          );
          expect(
            tester.widget<ListView>(find.byType(ListView)).key,
            isNot(editorKey),
          );
          expect(
            tester.state<ScrollableState>(paneScroll()).position.pixels,
            0,
          );
          await reveal(tester, find.text('short-pane unsaved feedback'));

          await reveal(tester, find.widgetWithText(TextButton, 'Edit'));
          await tester.tap(find.widgetWithText(TextButton, 'Edit'));
          await tester.pumpAndSettle();
          final cancelKey = tester.widget<ListView>(find.byType(ListView)).key;
          await reveal(tester, find.byType(TextField));
          await tester.enterText(
            find.byType(TextField),
            'discard only this edit',
          );
          await reveal(
            tester,
            find.widgetWithText(TextButton, 'Cancel editing'),
          );
          final cancelRect = tester.getRect(
            find.widgetWithText(TextButton, 'Cancel editing'),
          );
          expect(cancelRect.top, greaterThanOrEqualTo(0));
          expect(cancelRect.bottom, lessThanOrEqualTo(height));
          await tester.tap(find.widgetWithText(TextButton, 'Cancel editing'));
          await tester.pumpAndSettle();
          expect(
            tester.widget<ListView>(find.byType(ListView)).key,
            isNot(cancelKey),
          );
          expect(
            tester.state<ScrollableState>(paneScroll()).position.pixels,
            0,
          );
          expect(find.byType(TextField), findsNothing);
          expect(draft.comments().single.text, 'short-pane unsaved feedback');
          expect(draft.creates, hasLength(1));
          expect(draft.updates, isEmpty);
          expect(draft.deletes, isEmpty);
          expect(tester.takeException(), isNull);
        },
      );

      testWidgets(
        '320x$height pane exposes validation pending and uncertain recovery without losing input',
        (tester) async {
          port.service.value = _commentSnapshot();
          draft.comments().add(_comment());
          await mountComments(tester, size: Size(320, height));
          await reveal(tester, find.widgetWithText(TextButton, 'Edit'));
          await tester.tap(find.widgetWithText(TextButton, 'Edit'));
          await tester.pumpAndSettle();
          final editorKey = tester.widget<ListView>(find.byType(ListView)).key;
          await reveal(tester, find.byType(TextField));
          final controller = tester
              .widget<TextField>(find.byType(TextField))
              .controller!;
          await tester.enterText(find.byType(TextField), '   ');
          await reveal(tester, find.widgetWithText(TextButton, 'Save comment'));
          await tester.tap(find.widgetWithText(TextButton, 'Save comment'));
          await tester.pumpAndSettle();
          await reveal(
            tester,
            find.textContaining('Enter a nonblank single-line comment'),
          );
          expect(tester.widget<ListView>(find.byType(ListView)).key, editorKey);
          expect(draft.updates, isEmpty);
          await reveal(tester, find.byType(TextField), delta: -200);
          expect(
            tester.widget<TextField>(find.byType(TextField)).controller,
            same(controller),
          );
          await tester.enterText(
            find.byType(TextField),
            'short-pane local feedback',
          );
          FocusManager.instance.primaryFocus?.unfocus();
          await tester.pumpAndSettle();
          await reveal(tester, find.widgetWithText(TextButton, 'Save comment'));
          final oldSave = tester.widget<TextButton>(
            find.widgetWithText(TextButton, 'Save comment'),
          );
          final gate = draft.holdMutation();
          draft.afterMutationFailure = StateError('private lost response');
          await tester.tap(find.widgetWithText(TextButton, 'Save comment'));
          await tester.pumpAndSettle();
          await reveal(tester, find.text('Saving comment...'));
          expect(
            find.widgetWithText(TextButton, 'Cancel editing'),
            findsNothing,
          );
          expect(draft.updates, hasLength(1));
          await expectLater(lifecycle.prepareToDeactivate(), throwsStateError);
          await tester.pumpAndSettle();
          await reveal(
            tester,
            find.text(
              'Save or cancel the comment before leaving this Session.',
            ),
          );
          gate.complete();
          await tester.pumpAndSettle();
          final invalidKey = tester.widget<ListView>(find.byType(ListView)).key;
          expect(invalidKey, isNot(editorKey));
          expect(
            tester.state<ScrollableState>(paneScroll()).position.pixels,
            0,
          );
          expect(controller.text, 'short-pane local feedback');
          await reveal(
            tester,
            find.text(
              'Selection invalidated. Reload comments, then cancel and select a comment again. Your text is retained.',
            ),
          );
          await reveal(
            tester,
            find.text(
              'Comment change not confirmed. Reload comments before trying again.',
            ),
          );
          oldSave.onPressed!();
          await tester.pumpAndSettle();
          expect(draft.updates, hasLength(1));

          draft.afterMutationFailure = null;
          draft.snapshotFailure = StateError('private read failure');
          await reveal(
            tester,
            find.widgetWithText(TextButton, 'Reload comments'),
          );
          await tester.tap(find.widgetWithText(TextButton, 'Reload comments'));
          await tester.pumpAndSettle();
          await reveal(
            tester,
            find.text(
              'Comment storage unavailable. Reload comments to try again.',
            ),
            delta: -200,
          );
          expect(
            tester.widget<ListView>(find.byType(ListView)).key,
            invalidKey,
          );
          expect(controller.text, 'short-pane local feedback');
          draft.snapshotFailure = null;
          await reveal(
            tester,
            find.widgetWithText(TextButton, 'Reload comments'),
          );
          await tester.tap(find.widgetWithText(TextButton, 'Reload comments'));
          await tester.pumpAndSettle();
          expect(
            tester.widget<ListView>(find.byType(ListView)).key,
            invalidKey,
          );
          await reveal(tester, find.byType(TextField), delta: -200);
          expect(
            tester.widget<TextField>(find.byType(TextField)).controller,
            same(controller),
          );
          expect(controller.text, 'short-pane local feedback');
          expect(find.widgetWithText(TextButton, 'Save comment'), findsNothing);
          oldSave.onPressed!();
          await tester.pumpAndSettle();
          expect(draft.updates, hasLength(1));
          await reveal(
            tester,
            find.widgetWithText(TextButton, 'Cancel editing'),
          );
          await tester.tap(find.widgetWithText(TextButton, 'Cancel editing'));
          await tester.pumpAndSettle();
          await reveal(tester, find.widgetWithText(TextButton, 'Edit'));
          await tester.tap(find.widgetWithText(TextButton, 'Edit'));
          await tester.pumpAndSettle();
          await reveal(tester, find.byType(TextField));
          expect(
            tester.widget<TextField>(find.byType(TextField)).controller!.text,
            'short-pane local feedback',
          );
          await tester.enterText(
            find.byType(TextField),
            'explicitly confirmed edit',
          );
          draft.authoritativeText = 'server-confirmed short-pane edit';
          await reveal(tester, find.widgetWithText(TextButton, 'Save comment'));
          await tester.tap(find.widgetWithText(TextButton, 'Save comment'));
          await tester.pumpAndSettle();
          await reveal(tester, find.text('server-confirmed short-pane edit'));
          expect(draft.updates.map((update) => update.version), [3, 4]);
          expect(draft.comments().single.version, 5);
          expect(draft.updates.last.text, 'explicitly confirmed edit');
          expect(draft.snapshots, List.filled(4, 'canonical'));
          expect(draft.creates, isEmpty);
          expect(draft.deletes, isEmpty);
          expect(tester.takeException(), isNull);
        },
      );
    }

    for (final unavailable in ['missing', 'failed']) {
      testWidgets(
        '$unavailable draft service leaves Git approval and Source independent',
        (tester) async {
          registerSource();
          port.service.value = _reviewSnapshot(
            hunks: 1,
            commentIdentity: 'comment:eligible',
          );
          if (unavailable == 'failed') {
            draft.snapshotFailure = StateError('private storage failure');
          }
          await tester.binding.setSurfaceSize(const Size(1000, 1600));
          addTearDown(() => tester.binding.setSurfaceSize(null));
          await mount(tester, withDraft: unavailable != 'missing');
          expect(find.text('Approve'), findsOneWidget);
          expect(find.widgetWithText(TextButton, 'Comment'), findsNothing);
          expect(find.textContaining('private'), findsNothing);
          await tester.tap(find.text('Approve'));
          await tester.pumpAndSettle();
          expect(port.review.operations, ['approve']);
          await tester.tap(find.text('Open in Source'));
          await tester.pumpAndSettle();
          expect(source.paths, ['review.txt']);
          expect(draft.creates, isEmpty);
          expect(tester.takeException(), isNull);
        },
      );
    }

    for (final admitted in [false, true]) {
      testWidgets(
        'backend retirement fences ${admitted ? 'late' : 'new'} mutation without hiding diff',
        (tester) async {
          registerSource();
          port.service.value = _commentSnapshot();
          await mountComments(tester);
          await tester.tap(_lineComment('added line'));
          await tester.pumpAndSettle();
          await tester.enterText(find.byType(TextField), 'retired body');
          final old = tester.widget<TextButton>(
            find.widgetWithText(TextButton, 'Save comment'),
          );
          final gate = admitted ? draft.holdMutation() : null;
          if (admitted) {
            old.onPressed!();
            await tester.pumpAndSettle();
          }
          draft.active = false;
          if (admitted) {
            gate!.complete();
          } else {
            old.onPressed!();
          }
          await tester.pumpAndSettle();
          expect(draft.creates, hasLength(admitted ? 1 : 0));
          expect(find.text('Pending review comments (0)'), findsOneWidget);
          expect(
            find.text(
              'Comment change not confirmed. Reload comments before trying again.',
            ),
            findsOneWidget,
          );
          expect(find.textContaining('[modified]'), findsOneWidget);
          expect(
            tester.widget<TextField>(find.byType(TextField)).controller!.text,
            'retired body',
          );
          old.onPressed!();
          await tester.tap(find.text('Open in Source'));
          await tester.pumpAndSettle();
          expect(source.paths, ['dir/notes [deleted] "two words".txt']);
          expect(draft.creates, hasLength(admitted ? 1 : 0));
          expect(tester.takeException(), isNull);
        },
      );
    }

    for (final pending in ['snapshot', 'mutation']) {
      testWidgets(
        'Session isolation fences late $pending and remount rehydrates saved state',
        (tester) async {
          port.service.value = _commentSnapshot();
          draft
              .comments('other-session')
              .add(_comment(text: 'other Session feedback'));
          final snapshotGate = pending == 'snapshot'
              ? draft.holdSnapshot()
              : null;
          await mountComments(tester);
          Completer<void>? mutationGate;
          if (pending == 'mutation') {
            await tester.tap(_lineComment('added line'));
            await tester.pumpAndSettle();
            mutationGate = draft.holdMutation();
            await save(tester, 'canonical late feedback');
          }
          await remountComments(tester, 'other-session');
          expect(find.text('other Session feedback'), findsOneWidget);
          if (snapshotGate != null) {
            snapshotGate.complete(
              ReviewDraftSnapshot(
                sessionId: 'canonical',
                revision: 0,
                comments: [_comment(text: 'canonical late snapshot')],
                currentReview: null,
              ),
            );
          } else {
            mutationGate!.complete();
          }
          await tester.pumpAndSettle();
          expect(find.text('other Session feedback'), findsOneWidget);
          expect(find.text('canonical late feedback'), findsNothing);
          expect(find.text('canonical late snapshot'), findsNothing);
          expect(find.text('Pending review comments (1)'), findsOneWidget);
          expect(draft.updates, isEmpty);
          expect(draft.deletes, isEmpty);
          await remountComments(tester, 'canonical');
          if (pending == 'mutation') {
            expect(find.text('canonical late feedback'), findsOneWidget);
            expect(draft.creates.single.sessionId, 'canonical');
          }
          expect(find.text('other Session feedback'), findsNothing);
          expect(draft.snapshots, ['canonical', 'other-session', 'canonical']);
          expect(tester.takeException(), isNull);
        },
      );
    }
  });

  group('whole-layer review', () {
    Future<void> mountReview(
      WidgetTester tester, {
      double height = 1600,
    }) async {
      await tester.binding.setSurfaceSize(Size(900, height));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      return mount(tester);
    }

    for (final scope in [
      ('Unstaged changes', changeSetSourceServiceSnapshotUnstagedId),
      ('Uncommitted changes', changeSetSourceServiceSnapshotUncommittedId),
      ('Task / Branch', changeSetSourceServiceSnapshotTaskChangesId),
    ]) {
      for (final review in _layerReviewCases) {
        if (scope.$1 == 'Unstaged changes' && review.unapprove) continue;
        testWidgets(
          '${scope.$1} ${review.label} uses only the certified layer revision and one selected refresh',
          (tester) async {
            registerSource();
            setLayerReview();
            await mountReview(tester);
            await tester.tap(find.widgetWithText(TextButton, scope.$1));
            await tester.pumpAndSettle();
            expect(find.text('Approve All Unstaged'), findsOneWidget);
            expect(
              find.text('Unapprove All Staged'),
              scope.$1 == 'Unstaged changes' ? findsNothing : findsOneWidget,
            );
            expect(find.text('Approve File'), findsOneWidget);
            expect(find.text('Approve'), findsNWidgets(2));
            final old = tester.widget<TextButton>(
              find.widgetWithText(TextButton, review.label),
            );
            final snapshots = port.methods.length;
            final resolutions = port.reviewResolutions;
            final held = Completer<void>();
            port.review.pending = held.future;
            // A changed provider snapshot must not replace the displayed token.
            setLayerReview(stamp: 'fresh');
            old.onPressed!();
            old.onPressed!();
            await tester.pumpAndSettle();
            expect(port.review.methods, [review.method]);
            expect(port.review.operations, [review.operation]);
            expect(port.review.payloads.single, {
              'selection': {'expectedRevision': 'old:${review.layer}:layer'},
            });
            expect(
              port.review.layerSelections.single.expectedRevision,
              'old:${review.layer}:layer',
            );
            expect(port.review.fileSelections, isEmpty);
            expect(port.review.selections, isEmpty);
            expect(port.methods, hasLength(snapshots));
            expect(find.text(review.pendingMessage), findsOneWidget);
            _expectNoReviewActions();
            expect(source.paths, isEmpty);
            held.complete();
            await tester.pumpAndSettle();
            expect(port.methods.skip(snapshots), [scope.$2]);
            expect(port.reviewResolutions, resolutions + 1);
            expect(port.releases, contains('review-$resolutions'));
            expect(port.reviewHandles, hasLength(1));
            old.onPressed!();
            await tester.pumpAndSettle();
            expect(port.review.operations, [review.operation]);
            await tester.tap(find.widgetWithText(TextButton, review.label));
            await tester.pumpAndSettle();
            expect(port.review.methods, [review.method, review.method]);
            expect(port.review.payloads.last, {
              'selection': {'expectedRevision': 'fresh:${review.layer}:layer'},
            });
            expect(port.methods.skip(snapshots), [scope.$2, scope.$2]);
            await tester.tap(find.text('Open in Source'));
            await tester.pumpAndSettle();
            expect(source.paths, ['review.txt']);
            expect(tester.takeException(), isNull);
          },
        );
      }

      testWidgets(
        '${scope.$1} layer-only certification resolves review without individual selections or Source',
        (tester) async {
          setLayerReview(individual: false);
          await mountReview(tester);
          await tester.tap(find.widgetWithText(TextButton, scope.$1));
          await tester.pumpAndSettle();
          expect(port.reviewHandles, hasLength(1));
          expect(
            port.reviewResolutions,
            scope.$1 == 'Unstaged changes' ? 1 : 2,
          );
          expect(find.text('Approve'), findsNothing);
          expect(find.text('Approve File'), findsNothing);
          expect(find.text('Unapprove'), findsNothing);
          expect(find.text('Unapprove File'), findsNothing);
          expect(find.text('Open in Source'), findsNothing);
          expect(find.text('Source is unavailable.'), findsOneWidget);
          await tester.tap(find.text('Approve All Unstaged'));
          await tester.pumpAndSettle();
          expect(port.review.methods, [
            'diff.reviewApprovalHandler.approveAllUnstaged',
          ]);
          if (scope.$1 != 'Unstaged changes') {
            await tester.tap(find.text('Unapprove All Staged'));
            await tester.pumpAndSettle();
            expect(
              port.review.methods.last,
              'diff.reviewApprovalHandler.unapproveAllStaged',
            );
          }
          expect(source.paths, isEmpty);
          expect(tester.takeException(), isNull);
        },
      );

      testWidgets(
        '${scope.$1} null layer certification never infers All from files or other layers',
        (tester) async {
          await mountReview(tester);
          await tester.tap(find.widgetWithText(TextButton, scope.$1));
          await tester.pumpAndSettle();
          for (final snapshot in [
            ChangeSetSnapshot(files: [], layerReviewRevision: null),
            _reviewSnapshot(revision: null, fileRevision: 'eligible:file'),
            _reviewSnapshot(revision: null, contentStatus: 'unsupported'),
            ChangeSetSnapshot(files: [_conflict()], layerReviewRevision: null),
          ]) {
            port.service.value = snapshot;
            port.service.uncommitted = _uncommitted(
              staged: snapshot,
              unstaged: snapshot,
              conflicts: [_conflict()],
            );
            port.service.task = _task(
              committed: _reviewSnapshot(
                layerRevision: 'committed:never-select',
                revision: 'committed:hunk',
                fileRevision: 'committed:file',
              ),
              uncommitted: port.service.uncommitted,
            );
            final resolutions = port.reviewResolutions;
            await tester.tap(find.text('Refresh'));
            await tester.pumpAndSettle();
            expect(find.text('Approve All Unstaged'), findsNothing);
            expect(find.text('Unapprove All Staged'), findsNothing);
            final eligible = snapshot.files.any(
              (file) => file.fileReviewRevision != null,
            );
            expect(port.reviewResolutions, resolutions + (eligible ? 1 : 0));
            expect(
              find.text('Approve File'),
              eligible ? findsOneWidget : findsNothing,
            );
            expect(port.review.operations, isEmpty);
          }
          expect(tester.takeException(), isNull);
        },
      );
    }

    testWidgets(
      'one uncertified layer never borrows the other layer revision',
      (tester) async {
        await mountReview(tester);
        for (final scope in ['Uncommitted changes', 'Task / Branch']) {
          await tester.tap(find.widgetWithText(TextButton, scope));
          await tester.pumpAndSettle();
          for (final review in _layerReviewCases) {
            final certified = _reviewSnapshot(
              layerRevision: 'only:${review.layer}',
              revision: null,
            );
            final uncertified = _reviewSnapshot(revision: null);
            port.service.uncommitted = _uncommitted(
              staged: review.unapprove ? certified : uncertified,
              unstaged: review.unapprove ? uncertified : certified,
            );
            port.service.task = _task(uncommitted: port.service.uncommitted);
            await tester.tap(find.text('Refresh'));
            await tester.pumpAndSettle();
            expect(_reviewButtons(tester), hasLength(1));
            expect(find.text(review.label), findsOneWidget);
            await tester.tap(find.text(review.label));
            await tester.pumpAndSettle();
            expect(port.review.methods.last, review.method);
            expect(port.review.payloads.last, {
              'selection': {'expectedRevision': 'only:${review.layer}'},
            });
          }
        }
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets('17 eligible files retain file actions without a layer token', (
      tester,
    ) async {
      // The frontend consumes certification; it must neither synthesize a token
      // from eligible files nor hide their independent complete-file actions.
      port.service.value = ChangeSetSnapshot(
        layerReviewRevision: null,
        files: [
          for (var index = 0; index < 17; index++)
            ..._reviewSnapshot(
              path: 'empty-$index.txt',
              revision: null,
              fileRevision: 'file:$index',
              changeKind: 'added',
              hunks: 0,
            ).files,
        ],
      );
      port.service.uncommitted = _uncommitted(
        staged: port.service.value,
        unstaged: port.service.value,
      );
      port.service.task = _task(uncommitted: port.service.uncommitted);
      await mountReview(tester, height: 5200);
      await tester.tap(find.widgetWithText(TextButton, 'Task / Branch'));
      await tester.pumpAndSettle();
      expect(find.text('Approve All Unstaged'), findsNothing);
      expect(find.text('Unapprove All Staged'), findsNothing);
      expect(find.text('Approve File'), findsNWidgets(17));
      expect(find.text('Unapprove File'), findsNWidgets(17));
      expect(port.reviewHandles, hasLength(1));
      await tester.tap(find.widgetWithText(TextButton, 'Approve File').last);
      await tester.pumpAndSettle();
      expect(port.review.payloads.single, {
        'selection': {
          'relativePath': 'empty-16.txt',
          'expectedRevision': 'file:16',
        },
      });
      expect(port.review.layerSelections, isEmpty);
      expect(tester.takeException(), isNull);
    });

    for (final unavailable in [
      'missing',
      'denied',
      'ambiguous',
      'incompatible',
      'retired',
    ]) {
      testWidgets(
        '$unavailable review access leaves both layers and Source usable',
        (tester) async {
          registerSource();
          setLayerReview();
          port.reviewAvailability = unavailable;
          await mountReview(tester);
          await tester.tap(
            find.widgetWithText(TextButton, 'Uncommitted changes'),
          );
          await tester.pumpAndSettle();
          _expectNoReviewActions();
          expect(find.text('Review actions unavailable.'), findsWidgets);
          expect(find.text('review.txt  [modified]'), findsNWidgets(2));
          expect(port.handles, isEmpty);
          await tester.tap(find.text('Open in Source'));
          await tester.pumpAndSettle();
          expect(source.paths, ['review.txt']);
          expect(port.review.operations, isEmpty);
          port.reviewAvailability = 'available';
          await tester.tap(find.text('Refresh'));
          await tester.pumpAndSettle();
          expect(find.text('Approve All Unstaged'), findsOneWidget);
          expect(find.text('Unapprove All Staged'), findsOneWidget);
          expect(port.reviewHandles, hasLength(1));
          expect(port.review.operations, isEmpty);
          expect(tester.takeException(), isNull);
        },
      );
    }

    for (final action in _reviewActionLabels) {
      testWidgets('$action shares one pending gate with every review action', (
        tester,
      ) async {
        registerSource();
        setLayerReview();
        await mountReview(tester);
        await tester.tap(
          find.widgetWithText(TextButton, 'Uncommitted changes'),
        );
        await tester.pumpAndSettle();
        final buttons = _reviewButtons(tester);
        expect(buttons, hasLength(8));
        final snapshots = port.methods.length;
        final held = Completer<void>();
        port.review.pending = held.future;
        buttons
            .firstWhere((button) => (button.child! as Text).data == action)
            .onPressed!();
        for (final button in buttons) {
          button.onPressed!();
          button.onPressed!();
        }
        await tester.pumpAndSettle();
        expect(port.review.operations, hasLength(1));
        expect(port.methods, hasLength(snapshots));
        _expectNoReviewActions();
        expect(
          find.text(
            action == 'Approve All Unstaged'
                ? 'Approving all unstaged changes...'
                : action == 'Unapprove All Staged'
                ? 'Unapproving all staged changes...'
                : 'Review change pending...',
          ),
          findsOneWidget,
        );
        expect(find.text('review.txt  [modified]'), findsNWidgets(2));
        await tester.tap(find.text('Open in Source'));
        await tester.pumpAndSettle();
        expect(source.paths, ['review.txt']);
        held.complete();
        await tester.pumpAndSettle();
        expect(port.methods.skip(snapshots), [
          changeSetSourceServiceSnapshotUncommittedId,
        ]);
        expect(_reviewButtons(tester), hasLength(8));
        for (final button in buttons) {
          button.onPressed!();
        }
        await tester.pumpAndSettle();
        expect(port.review.operations, hasLength(1));
        expect(tester.takeException(), isNull);
      });
    }

    for (final review in _layerReviewCases) {
      for (final failure in [
        'stale_selection',
        'mutation_failed',
        'outcome_uncertain',
        'native',
      ]) {
        testWidgets(
          '${review.label} $failure requires explicit refresh, never substitutes a revision',
          (tester) async {
            setLayerReview();
            await mountReview(tester);
            await tester.tap(
              find.widgetWithText(TextButton, 'Uncommitted changes'),
            );
            await tester.pumpAndSettle();
            final snapshots = port.methods.length;
            final buttons = _reviewButtons(tester);
            port.review.failure = failure == 'native'
                ? StateError('private native failure')
                : ReviewApprovalFailure(
                    code: failure,
                    message: 'private review failure',
                  );
            setLayerReview(stamp: 'fresh');
            await tester.tap(find.text(review.label));
            await tester.pumpAndSettle();
            expect(find.text(_reviewFailure), findsOneWidget);
            expect(find.textContaining('private'), findsNothing);
            _expectNoReviewActions();
            expect(port.review.payloads.single, {
              'selection': {'expectedRevision': 'old:${review.layer}:layer'},
            });
            expect(port.methods, hasLength(snapshots));
            expect(port.handles, isEmpty);
            for (final button in buttons) {
              button.onPressed!();
            }
            await tester.pumpAndSettle();
            expect(port.review.operations, [review.operation]);
            port.review.failure = null;
            port.service.failure = true;
            await tester.tap(find.text('Refresh'));
            await tester.pumpAndSettle();
            expect(
              find.text('Unable to load uncommitted changes.'),
              findsOneWidget,
            );
            _expectNoReviewActions();
            expect(port.review.operations, [review.operation]);
            port.service.failure = false;
            await tester.tap(find.text('Retry'));
            await tester.pumpAndSettle();
            for (final button in buttons) {
              button.onPressed!();
            }
            await tester.pumpAndSettle();
            expect(port.review.operations, [review.operation]);
            await tester.tap(find.text(review.label));
            await tester.pumpAndSettle();
            expect(port.review.payloads.last, {
              'selection': {'expectedRevision': 'fresh:${review.layer}:layer'},
            });
            expect(port.review.methods, [review.method, review.method]);
            expect(
              port.methods.skip(snapshots),
              List.filled(3, changeSetSourceServiceSnapshotUncommittedId),
            );
            expect(tester.takeException(), isNull);
          },
        );
      }

      testWidgets(
        '${review.label} confirmed success followed by failed snapshot retries only the read',
        (tester) async {
          setLayerReview();
          await mountReview(tester);
          await tester.tap(find.widgetWithText(TextButton, 'Task / Branch'));
          await tester.pumpAndSettle();
          final snapshots = port.methods.length;
          port.service.failure = true;
          await tester.tap(find.text(review.label));
          await tester.pumpAndSettle();
          expect(find.text('Unable to load task changes.'), findsOneWidget);
          _expectNoReviewActions();
          expect(port.handles, isEmpty);
          expect(port.review.operations, [review.operation]);
          expect(port.methods.skip(snapshots), [
            changeSetSourceServiceSnapshotTaskChangesId,
          ]);
          port.service.failure = false;
          await tester.tap(find.text('Retry'));
          await tester.pumpAndSettle();
          expect(find.text(review.label), findsOneWidget);
          expect(
            port.methods.skip(snapshots),
            List.filled(2, changeSetSourceServiceSnapshotTaskChangesId),
          );
          expect(port.review.operations, [review.operation]);
          expect(tester.takeException(), isNull);
        },
      );

      for (final ending in ['refresh', 'scope']) {
        for (final fails in [false, true]) {
          for (final settlesBeforeSnapshot in [false, true]) {
            testWidgets(
              '${review.label} $ending during pending stays read-only failure=$fails settlementBeforeRead=$settlesBeforeSnapshot',
              (tester) async {
                setLayerReview();
                await mountReview(tester);
                await tester.tap(
                  find.widgetWithText(TextButton, 'Uncommitted changes'),
                );
                await tester.pumpAndSettle();
                final buttons = _reviewButtons(tester);
                final resolutions = port.reviewResolutions;
                final semantic = Completer<void>();
                port.review.pending = semantic.future;
                await tester.tap(find.text(review.label));
                await tester.pumpAndSettle();
                setLayerReview(stamp: 'fresh');
                final task = Completer<TaskChangeSetSnapshot>();
                final uncommitted = Completer<UncommittedChangeSetSnapshot>();
                if (ending == 'scope') {
                  port.service.pendingTask = task.future;
                  await tester.tap(
                    find.widgetWithText(TextButton, 'Task / Branch'),
                  );
                } else {
                  port.service.pendingUncommitted = uncommitted.future;
                  await tester.tap(find.text('Refresh'));
                }
                await tester.pumpAndSettle();
                expect(port.releases, contains('review-$resolutions'));
                expect(port.reviewHandles, isEmpty);
                // Neither ordering can make a read admitted during mutation eligible.
                if (settlesBeforeSnapshot) {
                  if (fails) {
                    semantic.completeError(StateError('private late failure'));
                  } else {
                    semantic.complete();
                  }
                  await tester.pumpAndSettle();
                }
                if (ending == 'scope') {
                  task.complete(port.service.task);
                } else {
                  uncommitted.complete(port.service.uncommitted);
                }
                await tester.pumpAndSettle();
                expect(find.text(_reviewRefreshRequired), findsOneWidget);
                _expectNoReviewActions();
                if (!settlesBeforeSnapshot) {
                  if (fails) {
                    semantic.completeError(StateError('private late failure'));
                  } else {
                    semantic.complete();
                  }
                  await tester.pumpAndSettle();
                }
                expect(find.text(_reviewRefreshRequired), findsOneWidget);
                expect(find.text(_reviewFailure), findsNothing);
                expect(find.text('Review change pending...'), findsNothing);
                expect(find.text(review.pendingMessage), findsNothing);
                _expectNoReviewActions();
                expect(port.reviewResolutions, resolutions);
                expect(port.handles, isEmpty);
                final snapshots = port.methods.length;
                for (final button in buttons) {
                  button.onPressed!();
                }
                await tester.pumpAndSettle();
                expect(port.review.operations, [review.operation]);
                expect(port.methods, hasLength(snapshots));
                await tester.tap(find.text('Refresh'));
                await tester.pumpAndSettle();
                expect(find.text(_reviewRefreshRequired), findsNothing);
                expect(_reviewButtons(tester), hasLength(8));
                expect(port.reviewResolutions, resolutions + 1);
                await tester.tap(find.text(review.label));
                await tester.pumpAndSettle();
                expect(port.review.payloads.last, {
                  'selection': {
                    'expectedRevision': 'fresh:${review.layer}:layer',
                  },
                });
                expect(
                  port.methods.skip(snapshots),
                  List.filled(
                    2,
                    ending == 'scope'
                        ? changeSetSourceServiceSnapshotTaskChangesId
                        : changeSetSourceServiceSnapshotUncommittedId,
                  ),
                );
                expect(tester.takeException(), isNull);
              },
            );
          }
        }
      }

      for (final ending in ['departure', 'dispose', 'frontend retirement']) {
        for (final fails in [false, true]) {
          testWidgets(
            '${review.label} $ending releases immediately and fences late failure=$fails',
            (tester) async {
              setLayerReview();
              await mountReview(tester);
              await tester.tap(
                find.widgetWithText(TextButton, 'Uncommitted changes'),
              );
              await tester.pumpAndSettle();
              final old = tester.widget<TextButton>(
                find.widgetWithText(TextButton, review.label),
              );
              final resolutions = port.reviewResolutions;
              final snapshots = port.methods.length;
              final held = Completer<void>();
              port.review.pending = held.future;
              old.onPressed!();
              await tester.pumpAndSettle();
              if (ending == 'departure') {
                await lifecycle.prepareToDeactivate();
              } else if (ending == 'dispose') {
                await tester.pumpWidget(const SizedBox());
              } else {
                frontend.invalidate();
              }
              await tester.pumpAndSettle();
              expect(port.releases, contains('review-$resolutions'));
              expect(port.handles, isEmpty);
              if (fails) {
                held.completeError(StateError('private late failure'));
              } else {
                held.complete();
              }
              await tester.pumpAndSettle();
              expect(port.review.operations, [review.operation]);
              expect(port.methods, hasLength(snapshots));
              expect(find.text(_reviewFailure), findsNothing);
              expect(find.text('review.txt  [modified]'), findsNothing);
              _expectNoReviewActions();
              if (ending == 'departure') {
                await tester.tap(find.text('Refresh'));
                await tester.pumpAndSettle();
                old.onPressed!();
                await tester.pumpAndSettle();
                expect(find.text(review.label), findsOneWidget);
                expect(port.review.operations, [review.operation]);
              }
              expect(tester.takeException(), isNull);
            },
          );
        }
      }

      for (final replace in [false, true]) {
        for (final admitted in [false, true]) {
          testWidgets(
            '${review.label} provider retirement replacement=$replace admitted=$admitted never migrates',
            (tester) async {
              setLayerReview();
              await mountReview(tester);
              await tester.tap(
                find.widgetWithText(TextButton, 'Uncommitted changes'),
              );
              await tester.pumpAndSettle();
              final original = port.review;
              final snapshots = port.methods.length;
              final resolutions = port.reviewResolutions;
              final old = tester.widget<TextButton>(
                find.widgetWithText(TextButton, review.label),
              );
              final held = Completer<void>();
              if (admitted) {
                original.pending = held.future;
                old.onPressed!();
                await tester.pumpAndSettle();
              }
              if (replace) {
                port.replaceReview();
                expect(port.review.id, original.id);
              } else {
                original.active = false;
              }
              if (admitted) {
                held.complete();
              } else {
                old.onPressed!();
              }
              await tester.pumpAndSettle();
              expect(find.text(_reviewFailure), findsOneWidget);
              expect(find.textContaining('private'), findsNothing);
              _expectNoReviewActions();
              expect(
                original.operations,
                admitted ? [review.operation] : isEmpty,
              );
              if (replace) expect(port.review.operations, isEmpty);
              expect(port.methods, hasLength(snapshots));
              expect(port.reviewResolutions, resolutions);
              expect(port.handles, isEmpty);
              await tester.tap(find.text('Refresh'));
              await tester.pumpAndSettle();
              old.onPressed!();
              await tester.pumpAndSettle();
              if (replace) {
                expect(port.review.operations, isEmpty);
                await tester.tap(find.text(review.label));
                await tester.pumpAndSettle();
                expect(port.review.methods, [review.method]);
                expect(port.review.payloads.single, {
                  'selection': {
                    'expectedRevision': 'old:${review.layer}:layer',
                  },
                });
              } else {
                _expectNoReviewActions();
                expect(port.handles, isEmpty);
              }
              expect(tester.takeException(), isNull);
            },
          );
        }
      }
    }

    for (final ending in [
      'refresh',
      'scope',
      'departure',
      'dispose',
      'retirement',
    ]) {
      testWidgets(
        'late layer-only review resolution releases unused access after $ending',
        (tester) async {
          setLayerReview(individual: false);
          final held = Completer<void>();
          port.reviewResolving = held.future;
          await mountReview(tester);
          expect(port.reviewResolutions, 1);
          expect(port.reviewHandles, isEmpty);
          if (ending == 'refresh') {
            port.service.value = _snapshot(path: 'fresh.txt');
            await tester.tap(find.text('Refresh'));
          } else if (ending == 'scope') {
            port.service.task = _task(committed: _snapshot(path: 'fresh.txt'));
            await tester.tap(find.widgetWithText(TextButton, 'Task / Branch'));
          } else if (ending == 'departure') {
            await lifecycle.prepareToDeactivate();
          } else if (ending == 'dispose') {
            await tester.pumpWidget(const SizedBox());
          } else {
            frontend.invalidate();
          }
          await tester.pumpAndSettle();
          held.complete();
          await tester.pumpAndSettle();
          expect(port.handles, isEmpty);
          expect(port.releases, contains('review-1'));
          expect(port.review.operations, isEmpty);
          _expectNoReviewActions();
          expect(tester.takeException(), isNull);
        },
      );
    }

    testWidgets(
      'All toolbar and individual actions remain usable in narrow panes',
      (tester) async {
        registerSource();
        setLayerReview(hunks: 1);
        await mountReview(tester);
        for (final width in [320.0, 480.0, 900.0]) {
          await tester.binding.setSurfaceSize(Size(width, 900));
          for (final scope in [
            'Unstaged changes',
            'Uncommitted changes',
            'Task / Branch',
          ]) {
            await tester.tap(find.widgetWithText(TextButton, scope));
            await tester.pumpAndSettle();
            expect(find.text('Approve All Unstaged'), findsOneWidget);
            expect(
              find.text('Unapprove All Staged'),
              scope == 'Unstaged changes' ? findsNothing : findsOneWidget,
            );
            for (final button in tester.widgetList<TextButton>(
              find.byType(TextButton),
            )) {
              final rect = tester.getRect(find.byWidget(button));
              expect(rect.left, greaterThanOrEqualTo(0));
              expect(rect.right, lessThanOrEqualTo(width));
            }
            await tester.tap(find.text('Approve All Unstaged'));
            await tester.pumpAndSettle();
            if (scope != 'Unstaged changes') {
              await tester.tap(find.text('Unapprove All Staged'));
              await tester.pumpAndSettle();
            }
            await tester.tap(find.text('Open in Source'));
            await tester.pumpAndSettle();
            expect(tester.takeException(), isNull, reason: '$width / $scope');
          }
        }
        expect(port.review.layerSelections, hasLength(15));
        expect(source.paths, List.filled(9, 'review.txt'));
      },
    );

    testWidgets(
      'Source pending does not block All and late Source feedback cannot replace refreshed review',
      (tester) async {
        registerSource();
        setLayerReview();
        await mountReview(tester);
        final sourceHeld = Completer<Map<String, Object?>>();
        final reviewHeld = Completer<void>();
        source.pending = sourceHeld.future;
        port.review.pending = reviewHeld.future;
        await tester.tap(find.text('Open in Source'));
        await tester.pumpAndSettle();
        expect(find.text('Approve All Unstaged'), findsOneWidget);
        await tester.tap(find.text('Approve All Unstaged'));
        await tester.pumpAndSettle();
        expect(port.review.operations, ['approveAllUnstaged']);
        expect(find.text('Opening in Source...'), findsOneWidget);
        reviewHeld.complete();
        await tester.pumpAndSettle();
        expect(port.service.calls, 2);
        expect(find.text('Approve All Unstaged'), findsOneWidget);
        sourceHeld.complete({'ok': false});
        await tester.pumpAndSettle();
        expect(find.text('Unable to open file in Source.'), findsNothing);
        expect(find.text('Open in Source'), findsOneWidget);
        expect(source.paths, ['review.txt']);
        expect(tester.takeException(), isNull);
      },
    );
  });

  testWidgets('review eligibility is independent of Source and snapshot scope', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(900, 1500));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    registerSource();
    await mount(tester);
    for (final scope in [
      'Unstaged changes',
      'Uncommitted changes',
      'Task / Branch',
    ]) {
      await tester.tap(find.widgetWithText(TextButton, scope));
      await tester.pumpAndSettle();
      for (final entry in [
        ('modified', 'text', 'hunk', 'file', 2, true, true),
        ('modified', 'text', 'hunk', null, 2, true, false),
        ('modified', 'text', null, 'file', 2, false, true),
        ('modified', 'text', null, null, 2, false, false),
        ('modified', 'text', 'hunk', 'file', 0, false, false),
        ('added', 'text', 'hunk', 'file', 2, false, true),
        ('added', 'text', null, 'file', 2, false, true),
        ('added', 'text', 'hunk', null, 2, false, false),
        ('added', 'text', null, null, 2, false, false),
        ('added', 'text', 'hunk', 'file', 0, false, true),
        ('added', 'text', null, 'file', 0, false, true),
        ('added', 'text', 'hunk', null, 0, false, false),
        ('added', 'binary', 'hunk', 'file', 2, false, false),
        ('added', 'oversized', 'hunk', 'file', 2, false, false),
        ('added', 'unsupported', 'hunk', 'file', 2, false, false),
        ('added', 'conflicted', 'hunk', 'file', 2, false, false),
        ('deleted', 'text', 'hunk', 'file', 2, false, true),
        ('deleted', 'text', null, 'file', 2, false, true),
        ('deleted', 'text', 'hunk', null, 2, false, false),
        ('deleted', 'text', null, null, 2, false, false),
        ('deleted', 'text', 'hunk', 'file', 0, false, true),
        ('deleted', 'text', null, 'file', 0, false, true),
        ('deleted', 'text', 'hunk', null, 0, false, false),
        ('deleted', 'text', null, null, 0, false, false),
        ('deleted', 'binary', 'hunk', 'file', 2, false, false),
        ('deleted', 'oversized', 'hunk', 'file', 2, false, false),
        ('deleted', 'unsupported', 'hunk', 'file', 2, false, false),
        ('deleted', 'conflicted', 'hunk', 'file', 2, false, false),
        ('typeChanged', 'text', 'hunk', 'file', 2, false, false),
        ('conflicted', 'text', 'hunk', 'file', 2, false, false),
        ('unsupported', 'text', 'hunk', 'file', 2, false, false),
        ('modified', 'binary', 'hunk', 'file', 2, false, false),
        ('modified', 'oversized', 'hunk', 'file', 2, false, false),
        ('modified', 'unsupported', 'hunk', 'file', 2, false, false),
        ('modified', 'conflicted', 'hunk', 'file', 2, false, false),
      ]) {
        port.service.value = _reviewSnapshot(
          changeKind: entry.$1,
          contentStatus: entry.$2,
          revision: entry.$3,
          fileRevision: entry.$4,
          hunks: entry.$5,
        );
        port.service.uncommitted = _uncommitted(
          staged: port.service.value,
          unstaged: port.service.value,
          // Neither historical nor conflict sections can acquire review actions,
          // even if a provider supplies a text-shaped entry with a revision.
          conflicts: port.service.value.files,
        );
        port.service.task = _task(
          committed: port.service.value,
          uncommitted: port.service.uncommitted,
        );
        final before = port.reviewResolutions;
        await tester.tap(find.text('Refresh'));
        await tester.pumpAndSettle();
        expect(
          find.text('Approve'),
          entry.$6 ? findsNWidgets(2) : findsNothing,
        );
        expect(
          find.text('Unapprove'),
          entry.$6 && scope != 'Unstaged changes'
              ? findsNWidgets(2)
              : findsNothing,
        );
        expect(
          find.text('Approve File'),
          entry.$7 ? findsOneWidget : findsNothing,
        );
        expect(
          find.text('Unapprove File'),
          entry.$7 && scope != 'Unstaged changes'
              ? findsOneWidget
              : findsNothing,
        );
        expect(port.reviewResolutions, before + (entry.$6 || entry.$7 ? 1 : 0));
        expect(port.reviewHandles.length, entry.$6 || entry.$7 ? 1 : 0);
        final canOpen =
            entry.$2 == 'text' &&
            ['modified', 'added', 'typeChanged'].contains(entry.$1);
        expect(
          find.text('Open in Source'),
          canOpen ? findsOneWidget : findsNothing,
        );
        expect(port.review.operations, isEmpty);
        expect(source.paths, isEmpty);
        expect(tester.takeException(), isNull, reason: '$scope / $entry');
      }
    }
  });

  for (final scope in [
    'Unstaged changes',
    'Uncommitted changes',
    'Task / Branch',
  ]) {
    testWidgets(
      '$scope preserves typed layer revision and original hunk index',
      (tester) async {
        await tester.binding.setSurfaceSize(const Size(900, 1500));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        registerSource();
        const path = 'dir/notes [deleted] two words.txt';
        port.service.value = _reviewSnapshot(
          path: path,
          revision: 'unstaged:token',
        );
        port.service.uncommitted = _uncommitted(
          staged: _reviewSnapshot(path: path, revision: 'staged:token'),
          unstaged: port.service.value,
          conflicts: _reviewSnapshot(
            path: path,
            revision: 'conflict:token',
          ).files,
        );
        port.service.task = _task(
          committed: _reviewSnapshot(path: path, revision: 'committed:token'),
          uncommitted: port.service.uncommitted,
        );
        await mount(tester);
        await tester.tap(find.widgetWithText(TextButton, scope));
        await tester.pumpAndSettle();
        final snapshots = port.methods.length;
        final resolutions = port.reviewResolutions;
        expect(port.review.operations, isEmpty);
        expect(find.text('Approve'), findsNWidgets(2));
        await tester.tap(find.widgetWithText(TextButton, 'Approve').at(1));
        await tester.pumpAndSettle();
        expect(port.review.operations, ['approve']);
        expect(port.review.payloads.single, {
          'selection': {
            'relativePath': path,
            'hunkIndex': 1,
            'expectedRevision': 'unstaged:token',
          },
        });
        expect(port.review.selections.single.hunkIndex, 1);
        expect(port.methods.length, snapshots + 1);
        expect(port.reviewResolutions, resolutions + 1);
        expect(port.releases, contains('review-$resolutions'));
        if (scope != 'Unstaged changes') {
          expect(find.text('Unapprove'), findsNWidgets(2));
          await tester.tap(find.widgetWithText(TextButton, 'Unapprove').at(1));
          await tester.pumpAndSettle();
          expect(port.review.operations, ['approve', 'unapprove']);
          expect(port.review.payloads.last, {
            'selection': {
              'relativePath': path,
              'hunkIndex': 1,
              'expectedRevision': 'staged:token',
            },
          });
          expect(port.methods.length, snapshots + 2);
        }
        expect(
          port.methods.last,
          scope == 'Unstaged changes'
              ? changeSetSourceServiceSnapshotUnstagedId
              : scope == 'Uncommitted changes'
              ? changeSetSourceServiceSnapshotUncommittedId
              : changeSetSourceServiceSnapshotTaskChangesId,
        );
        expect(source.paths, isEmpty);
        await tester.tap(find.text('Open in Source'));
        await tester.pumpAndSettle();
        expect(source.paths, [path]);
        expect(tester.takeException(), isNull);
      },
    );
  }

  for (final scope in [
    'Unstaged changes',
    'Uncommitted changes',
    'Task / Branch',
  ]) {
    for (final review in _reviewCases.where((review) => review.fileReview)) {
      testWidgets(
        '$scope sends typed ${review.name} paths and independent layer revisions',
        (tester) async {
          await tester.binding.setSurfaceSize(const Size(900, 1500));
          addTearDown(() => tester.binding.setSurfaceSize(null));
          registerSource();
          const path = 'dir/notes [deleted] "two words".txt';
          port.service.value = _reviewSnapshot(
            path: path,
            revision: 'hunk:unstaged',
            fileRevision: 'file:unstaged',
            changeKind: review.changeKind,
            hunks: review.hunks,
          );
          port.service.uncommitted = _uncommitted(
            staged: _reviewSnapshot(
              path: path,
              revision: 'hunk:staged',
              fileRevision: 'file:staged',
              changeKind: review.changeKind,
              hunks: review.hunks,
            ),
            unstaged: port.service.value,
            conflicts: _reviewSnapshot(
              path: path,
              fileRevision: 'file:conflict',
              changeKind: review.changeKind,
              hunks: review.hunks,
            ).files,
          );
          port.service.task = _task(
            committed: _reviewSnapshot(
              path: path,
              fileRevision: 'file:committed',
              changeKind: review.changeKind,
              hunks: review.hunks,
            ),
            uncommitted: port.service.uncommitted,
          );
          await mount(tester);
          await tester.tap(find.widgetWithText(TextButton, scope));
          await tester.pumpAndSettle();
          expect(
            find.text('$path  [${review.changeKind}]'),
            findsNWidgets(
              scope == 'Task / Branch'
                  ? 4
                  : scope == 'Uncommitted changes'
                  ? 3
                  : 1,
            ),
          );
          expect(
            find.textContaining('@@'),
            review.hunks == 0 ? findsNothing : findsWidgets,
          );
          expect(find.text('Approve File'), findsOneWidget);
          expect(
            find.text('Approve'),
            review.changeKind == 'modified' ? findsNWidgets(2) : findsNothing,
          );
          expect(
            find.text('Unapprove File'),
            scope == 'Unstaged changes' ? findsNothing : findsOneWidget,
          );
          expect(
            find.text('Unapprove'),
            scope != 'Unstaged changes' && review.changeKind == 'modified'
                ? findsNWidgets(2)
                : findsNothing,
          );
          final snapshots = port.methods.length;
          final selectedMethod = port.methods.last;
          final resolutions = port.reviewResolutions;
          expect(port.review.operations, isEmpty);
          await tester.tap(find.text('Approve File'));
          await tester.pumpAndSettle();
          expect(port.review.operations, ['approveFile']);
          expect(port.review.payloads.single, {
            'selection': {
              'relativePath': path,
              'expectedRevision': 'file:unstaged',
            },
          });
          expect(port.review.fileSelections.single.relativePath, path);
          expect(
            port.review.fileSelections.single.expectedRevision,
            'file:unstaged',
          );
          expect(port.review.selections, isEmpty);
          expect(port.methods.skip(snapshots), [selectedMethod]);
          expect(port.reviewResolutions, resolutions + 1);
          expect(port.releases, contains('review-$resolutions'));
          if (scope != 'Unstaged changes') {
            await tester.tap(find.text('Unapprove File'));
            await tester.pumpAndSettle();
            expect(port.review.operations, ['approveFile', 'unapproveFile']);
            expect(port.review.payloads.last, {
              'selection': {
                'relativePath': path,
                'expectedRevision': 'file:staged',
              },
            });
            expect(
              port.review.fileSelections.last.expectedRevision,
              'file:staged',
            );
            expect(port.methods.skip(snapshots), [
              selectedMethod,
              selectedMethod,
            ]);
          }
          if (review.changeKind == 'modified') {
            await tester.tap(find.widgetWithText(TextButton, 'Approve').last);
            await tester.pumpAndSettle();
            expect(port.review.operations.last, 'approve');
            expect(port.review.selections.single.hunkIndex, 1);
            expect(
              port.review.selections.single.expectedRevision,
              'hunk:unstaged',
            );
          } else {
            expect(find.text('Approve'), findsNothing);
            expect(find.text('Unapprove'), findsNothing);
            expect(port.review.selections, isEmpty);
          }
          expect(source.paths, isEmpty);
          if (review.changeKind == 'deleted') {
            expect(find.text('Open in Source'), findsNothing);
            expect(find.textContaining('+new-'), findsNothing);
            expect(
              find.text('   1      -old-0'),
              review.hunks == 0 ? findsNothing : findsWidgets,
            );
          } else {
            await tester.tap(find.text('Open in Source'));
            await tester.pumpAndSettle();
            expect(source.paths, [path]);
          }
          expect(tester.takeException(), isNull);
        },
      );
    }
  }

  for (final review in _reviewCases.where((review) => review.fileReview)) {
    testWidgets(
      'historical-only ${review.name} snapshots never acquire unused review access',
      (tester) async {
        port.service.task = _task(
          committed: _reviewSnapshot(
            revision: 'historical',
            fileRevision: 'historical:file',
            changeKind: review.changeKind,
            hunks: review.hunks,
          ),
          uncommitted: _uncommitted(
            conflicts: _reviewSnapshot(
              revision: 'conflict',
              fileRevision: 'conflict:file',
              changeKind: review.changeKind,
              hunks: review.hunks,
            ).files,
          ),
        );
        await mount(tester);
        await tester.tap(find.widgetWithText(TextButton, 'Task / Branch'));
        await tester.pumpAndSettle();
        expect(
          find.text('review.txt  [${review.changeKind}]'),
          findsNWidgets(2),
        );
        expect(find.text('Approve'), findsNothing);
        expect(find.text('Unapprove'), findsNothing);
        expect(find.text('Approve File'), findsNothing);
        expect(find.text('Unapprove File'), findsNothing);
        expect(find.text('Open in Source'), findsNothing);
        expect(port.reviewResolutions, 0);
        expect(port.handles, isEmpty);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      '${review.name} review controls fit narrow panes without overloading Source paths',
      (tester) async {
        addTearDown(() => tester.binding.setSurfaceSize(null));
        registerSource();
        port.service.value = _reviewSnapshot(
          path: 'dir/with spaces [modified].txt',
          fileRevision: 'file:revision',
          changeKind: review.changeKind,
          hunks: review.hunks,
        );
        port.service.uncommitted = _uncommitted(
          staged: port.service.value,
          unstaged: port.service.value,
        );
        await mount(tester);
        for (final scope in ['Unstaged changes', 'Uncommitted changes']) {
          await tester.tap(find.widgetWithText(TextButton, scope));
          await tester.pumpAndSettle();
          for (final width in [320.0, 480.0, 900.0]) {
            // Keep both lazy layers mounted below the comments toolbar.
            await tester.binding.setSurfaceSize(Size(width, 1400));
            await tester.pumpAndSettle();
            for (final label in [
              'Approve',
              'Unapprove',
              'Approve File',
              'Unapprove File',
              'Open in Source',
            ]) {
              for (final button
                  in find.widgetWithText(TextButton, label).evaluate()) {
                final rect = tester.getRect(find.byWidget(button.widget));
                expect(rect.left, greaterThanOrEqualTo(0));
                expect(rect.right, lessThanOrEqualTo(width));
              }
            }
            expect(
              find.text('Approve'),
              review.changeKind == 'modified' ? findsNWidgets(2) : findsNothing,
            );
            expect(find.text('Approve File'), findsOneWidget);
            expect(
              find.text('Unapprove File'),
              scope == 'Uncommitted changes' ? findsOneWidget : findsNothing,
            );
            expect(
              find.text('Open in Source'),
              review.changeKind == 'deleted' ? findsNothing : findsOneWidget,
            );
            expect(
              tester
                  .getTopLeft(find.widgetWithText(TextButton, 'Approve File'))
                  .dy,
              greaterThanOrEqualTo(
                tester
                    .getBottomLeft(
                      find
                          .text(
                            'dir/with spaces [modified].txt  [${review.changeKind}]',
                          )
                          .last,
                    )
                    .dy,
              ),
            );
            if (review.changeKind != 'deleted') {
              expect(
                tester
                    .getTopLeft(
                      find.widgetWithText(TextButton, 'Open in Source'),
                    )
                    .dy,
                greaterThanOrEqualTo(
                  tester
                      .getBottomLeft(
                        find.widgetWithText(TextButton, 'Approve File'),
                      )
                      .dy,
                ),
              );
              await tester.tap(find.text('Open in Source'));
              await tester.pumpAndSettle();
            }
            expect(tester.takeException(), isNull);
          }
        }
        expect(port.review.operations, isEmpty);
        expect(
          source.paths,
          review.changeKind == 'deleted'
              ? isEmpty
              : List.filled(6, 'dir/with spaces [modified].txt'),
        );
      },
    );

    testWidgets(
      'missing denied ambiguous and retired ${review.name} review access stays read-only',
      (tester) async {
        registerSource();
        port.service.value = _reviewSnapshot(
          fileRevision: 'file:revision',
          changeKind: review.changeKind,
          hunks: review.hunks,
        );
        port.reviewAvailability = 'missing';
        await mount(tester);
        for (final unavailable in [
          'missing',
          'denied',
          'ambiguous',
          'retired',
        ]) {
          port.reviewAvailability = unavailable;
          await tester.tap(find.text('Refresh'));
          await tester.pumpAndSettle();
          expect(find.text('Approve'), findsNothing);
          expect(find.text('Unapprove'), findsNothing);
          expect(find.text('Approve File'), findsNothing);
          expect(
            find.text('Review actions unavailable.'),
            findsNWidgets(review.changeKind == 'modified' ? 3 : 1),
          );
          expect(
            find.text('review.txt  [${review.changeKind}]'),
            findsOneWidget,
          );
          expect(port.handles, isEmpty);
          expect(port.review.operations, isEmpty);
          if (review.changeKind == 'deleted') {
            expect(find.text('Open in Source'), findsNothing);
          } else {
            await tester.tap(find.text('Open in Source'));
            await tester.pumpAndSettle();
          }
        }
        expect(
          source.paths,
          review.changeKind == 'deleted'
              ? isEmpty
              : List.filled(4, 'review.txt'),
        );
        port.reviewAvailability = 'available';
        await tester.tap(find.text('Refresh'));
        await tester.pumpAndSettle();
        expect(
          find.text('Approve'),
          review.changeKind == 'modified' ? findsNWidgets(2) : findsNothing,
        );
        expect(find.text('Approve File'), findsOneWidget);
        expect(port.review.operations, isEmpty);
        expect(port.reviewHandles, hasLength(1));
        await tester.pumpWidget(const SizedBox());
        expect(port.handles, isEmpty);
        expect(port.releases.where((handle) => handle.startsWith('review-')), [
          'review-6',
        ]);
        expect(tester.takeException(), isNull);
      },
    );
  }

  for (final review in _reviewCases) {
    final fileReview = review.fileReview;
    testWidgets(
      'successful ${review.name} review settles before exactly one fresh selected snapshot',
      (tester) async {
        port.service.uncommitted = _uncommitted(
          staged: _reviewSnapshot(
            fileRevision: 'file:revision',
            changeKind: review.changeKind,
            hunks: review.hunks,
          ),
        );
        await mount(tester);
        await tester.tap(
          find.widgetWithText(TextButton, 'Uncommitted changes'),
        );
        await tester.pumpAndSettle();
        final held = Completer<void>();
        port.review.pending = held.future;
        final snapshot = Completer<UncommittedChangeSetSnapshot>();
        port.service.pendingUncommitted = snapshot.future;
        final old = tester.widget<TextButton>(
          find
              .widgetWithText(
                TextButton,
                fileReview ? 'Unapprove File' : 'Unapprove',
              )
              .first,
        );
        old.onPressed!();
        old.onPressed!();
        await tester.pumpAndSettle();
        expect(port.review.operations, [
          fileReview ? 'unapproveFile' : 'unapprove',
        ]);
        expect(port.service.uncommittedCalls, 1);
        expect(find.text('review.txt  [${review.changeKind}]'), findsOneWidget);
        expect(
          find.text('  10      -old-0'),
          review.changeKind == 'modified' ? findsOneWidget : findsNothing,
        );
        expect(find.text('Review change pending...'), findsOneWidget);
        held.complete();
        await tester.pumpAndSettle();
        expect(port.service.uncommittedCalls, 2);
        expect(find.text('Loading uncommitted changes...'), findsOneWidget);
        expect(find.text('review.txt  [${review.changeKind}]'), findsNothing);
        expect(find.text('Unapprove'), findsNothing);
        expect(find.text('Unapprove File'), findsNothing);
        expect(port.reviewHandles, isEmpty);
        old.onPressed!();
        snapshot.complete(
          _uncommitted(
            unstaged: _reviewSnapshot(
              path: 'fresh.txt',
              revision: 'fresh',
              fileRevision: 'fresh:file',
              changeKind: review.changeKind,
              hunks: review.hunks,
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('fresh.txt  [${review.changeKind}]'), findsOneWidget);
        expect(
          find.text('Approve'),
          review.changeKind == 'modified' ? findsNWidgets(2) : findsNothing,
        );
        expect(find.text('Approve File'), findsOneWidget);
        expect(port.service.uncommittedCalls, 2);
        expect(port.service.calls, 1);
        expect(port.review.operations, [
          fileReview ? 'unapproveFile' : 'unapprove',
        ]);
        expect(tester.takeException(), isNull);
      },
    );
  }

  for (final review in _reviewCases) {
    for (final action
        in review.fileReview
            ? ['Approve File', 'Unapprove File']
            : ['Approve', 'Unapprove']) {
      for (final fails in [false, true]) {
        testWidgets(
          'refresh during pending $action ${review.name} stays read-only after late failure=$fails',
          (tester) async {
            await tester.binding.setSurfaceSize(const Size(900, 1500));
            addTearDown(() => tester.binding.setSurfaceSize(null));
            registerSource();
            final path = review.changeKind == 'deleted'
                ? 'deleted.txt'
                : review.changeKind == 'added'
                ? 'new.txt'
                : 'review.txt';
            port.service.uncommitted = _uncommitted(
              staged: ChangeSetSnapshot(
                layerReviewRevision: null,
                files: [
                  ..._reviewSnapshot(
                    revision: 'staged',
                    fileRevision: 'staged:file',
                  ).files,
                  ..._reviewSnapshot(
                    path: 'new.txt',
                    fileRevision: 'staged:new-file',
                    changeKind: 'added',
                    hunks: review.hunks,
                  ).files,
                  ..._reviewSnapshot(
                    path: 'deleted.txt',
                    fileRevision: 'staged:deleted-file',
                    changeKind: 'deleted',
                    hunks: review.hunks,
                  ).files,
                ],
              ),
              unstaged: ChangeSetSnapshot(
                layerReviewRevision: null,
                files: [
                  ..._reviewSnapshot(
                    revision: 'unstaged',
                    fileRevision: 'unstaged:file',
                  ).files,
                  ..._reviewSnapshot(
                    path: 'new.txt',
                    fileRevision: 'unstaged:new-file',
                    changeKind: 'added',
                    hunks: review.hunks,
                  ).files,
                  ..._reviewSnapshot(
                    path: 'deleted.txt',
                    fileRevision: 'unstaged:deleted-file',
                    changeKind: 'deleted',
                    hunks: review.hunks,
                  ).files,
                ],
              ),
            );
            await mount(tester);
            await tester.tap(
              find.widgetWithText(TextButton, 'Uncommitted changes'),
            );
            await tester.pumpAndSettle();
            final buttons = tester
                .widgetList<TextButton>(
                  find.byWidgetPredicate(
                    (widget) =>
                        widget is TextButton &&
                        widget.child is Text &&
                        [
                          'Approve',
                          'Unapprove',
                          'Approve File',
                          'Unapprove File',
                        ].contains((widget.child! as Text).data),
                  ),
                )
                .toList();
            expect(buttons, hasLength(10));
            final held = Completer<void>();
            port.review.pending = held.future;
            final matching = buttons.where(
              (button) => (button.child! as Text).data == action,
            );
            final selected = review.fileReview
                ? ['modified', 'added', 'deleted'].indexOf(review.changeKind)
                : 0;
            matching.elementAt(selected).onPressed!();
            for (final button in buttons) {
              button.onPressed!();
              button.onPressed!();
            }
            await tester.pumpAndSettle();
            expect(port.review.operations, hasLength(1));
            expect(port.service.uncommittedCalls, 1);
            expect(
              port.review.payloads.single['selection'],
              containsPair('relativePath', path),
            );
            if (review.fileReview) expect(port.review.selections, isEmpty);
            expect(find.text('Approve'), findsNothing);
            expect(find.text('Unapprove'), findsNothing);
            expect(find.text('Approve File'), findsNothing);
            expect(find.text('Unapprove File'), findsNothing);
            await tester.tap(
              find.widgetWithText(TextButton, 'Open in Source').last,
            );
            await tester.pumpAndSettle();
            expect(source.paths, ['new.txt']);
            expect(port.review.operations, hasLength(1));
            await tester.tap(find.text('Refresh'));
            await tester.pumpAndSettle();
            expect(port.releases, contains('review-1'));
            expect(port.reviewHandles, isEmpty);
            expect(port.reviewResolutions, 1);
            expect(find.text(_reviewRefreshRequired), findsOneWidget);
            expect(find.text('Review change pending...'), findsNothing);
            for (final button in buttons) {
              button.onPressed!();
            }
            expect(port.review.operations, hasLength(1));
            if (fails) {
              held.completeError(StateError('private late failure'));
            } else {
              held.complete();
            }
            await tester.pumpAndSettle();
            expect(find.text(_reviewFailure), findsNothing);
            expect(port.service.uncommittedCalls, 2);
            expect(find.text('Approve'), findsNothing);
            expect(find.text('Unapprove'), findsNothing);
            expect(find.text('Approve File'), findsNothing);
            expect(find.text('Unapprove File'), findsNothing);
            expect(find.text(_reviewRefreshRequired), findsOneWidget);
            expect(port.reviewHandles, isEmpty);
            expect(port.reviewResolutions, 1);
            buttons.first.onPressed!();
            await tester.pumpAndSettle();
            expect(port.review.operations, hasLength(1));
            await tester.tap(find.text('Refresh'));
            await tester.pumpAndSettle();
            expect(find.text(_reviewRefreshRequired), findsNothing);
            expect(find.text('Approve'), findsNWidgets(2));
            expect(find.text('Approve File'), findsNWidgets(3));
            expect(find.text('Unapprove File'), findsNWidgets(3));
            expect(port.reviewHandles.keys, ['review-2']);
            expect(port.service.uncommittedCalls, 3);
            await tester.tap(find.widgetWithText(TextButton, 'Approve').last);
            await tester.pumpAndSettle();
            expect(port.review.operations, hasLength(2));
            expect(port.review.selections.last.hunkIndex, 1);
            expect(port.service.uncommittedCalls, 4);
            expect(tester.takeException(), isNull);
          },
        );
      }
    }
  }

  for (final review in _reviewCases) {
    final fileReview = review.fileReview;
    for (final scopeSwitch in [false, true]) {
      testWidgets(
        'snapshot captures read-only eligibility before release settlement scope=$scopeSwitch ${review.name}',
        (tester) async {
          port.service.value = _reviewSnapshot(
            fileRevision: 'file:revision',
            changeKind: review.changeKind,
            hunks: review.hunks,
          );
          port.service.task = _task(
            uncommitted: _uncommitted(
              staged: _reviewSnapshot(
                fileRevision: 'file:staged',
                changeKind: review.changeKind,
                hunks: review.hunks,
              ),
            ),
          );
          await mount(tester);
          final semantic = Completer<void>();
          port.review.pending = semantic.future;
          await tester.tap(
            find
                .widgetWithText(
                  TextButton,
                  fileReview ? 'Approve File' : 'Approve',
                )
                .first,
          );
          await tester.pumpAndSettle();
          final unstaged = Completer<ChangeSetSnapshot>();
          final task = Completer<TaskChangeSetSnapshot>();
          if (scopeSwitch) {
            port.service.pendingTask = task.future;
            await tester.tap(find.widgetWithText(TextButton, 'Task / Branch'));
          } else {
            port.service.pending = unstaged.future;
            await tester.tap(find.text('Refresh'));
          }
          await tester.pumpAndSettle();
          expect(port.releases, contains('review-1'));
          // Released authority can settle the semantic request before admitted
          // process work stops. A snapshot already underway cannot opt in later.
          semantic.completeError(StateError('private released authority'));
          await tester.pumpAndSettle();
          if (scopeSwitch) {
            task.complete(port.service.task);
          } else {
            unstaged.complete(port.service.value);
          }
          await tester.pumpAndSettle();
          expect(
            find.text('review.txt  [${review.changeKind}]'),
            findsOneWidget,
          );
          expect(find.text('Approve'), findsNothing);
          expect(find.text('Unapprove'), findsNothing);
          expect(find.text('Review change pending...'), findsNothing);
          expect(find.text(_reviewRefreshRequired), findsOneWidget);
          expect(find.text('Approve File'), findsNothing);
          expect(find.text('Unapprove File'), findsNothing);
          expect(port.reviewResolutions, 1);
          expect(port.handles, isEmpty);
          expect(port.review.operations, [
            fileReview ? 'approveFile' : 'approve',
          ]);
          expect(port.methods, hasLength(2));
          await tester.tap(find.text('Refresh'));
          await tester.pumpAndSettle();
          expect(
            find.text(scopeSwitch ? 'Unapprove' : 'Approve'),
            review.changeKind == 'modified' ? findsNWidgets(2) : findsNothing,
          );
          expect(
            find.text(scopeSwitch ? 'Unapprove File' : 'Approve File'),
            findsOneWidget,
          );
          expect(find.text(_reviewRefreshRequired), findsNothing);
          expect(port.reviewResolutions, 2);
          expect(port.reviewHandles.keys, ['review-2']);
          expect(port.methods, hasLength(3));
          expect(port.review.operations, [
            fileReview ? 'approveFile' : 'approve',
          ]);
          expect(tester.takeException(), isNull);
        },
      );
    }
  }

  for (final review in _reviewCases) {
    final fileReview = review.fileReview;
    for (final unapprove in [false, true]) {
      final action = fileReview
          ? (unapprove ? 'Unapprove File' : 'Approve File')
          : (unapprove ? 'Unapprove' : 'Approve');
      final operation = fileReview
          ? (unapprove ? 'unapproveFile' : 'approveFile')
          : (unapprove ? 'unapprove' : 'approve');
      final scope = unapprove ? 'uncommitted' : 'unstaged';
      for (final failure in [
        'stale_selection',
        'mutation_failed',
        'outcome_uncertain',
        'native',
      ]) {
        testWidgets(
          '$failure disables stale $action ${review.name} until manual snapshot, never replays',
          (tester) async {
            await tester.binding.setSurfaceSize(const Size(900, 1500));
            addTearDown(() => tester.binding.setSurfaceSize(null));
            registerSource();
            port.service.value = _reviewSnapshot(
              fileRevision: 'file:revision',
              changeKind: review.changeKind,
              hunks: review.hunks,
            );
            port.service.uncommitted = _uncommitted(
              staged: port.service.value,
              unstaged: port.service.value,
            );
            await mount(tester);
            if (unapprove) {
              await tester.tap(
                find.widgetWithText(TextButton, 'Uncommitted changes'),
              );
              await tester.pumpAndSettle();
            }
            final snapshots = port.methods.length;
            port.review.failure = failure == 'native'
                ? StateError('private native diagnostic')
                : ReviewApprovalFailure(
                    code: failure,
                    message: 'private review diagnostic',
                  );
            final old = tester.widget<TextButton>(
              find.widgetWithText(TextButton, action).first,
            );
            old.onPressed!();
            await tester.pumpAndSettle();
            expect(find.text(_reviewFailure), findsOneWidget);
            expect(find.textContaining('private'), findsNothing);
            expect(find.text('Approve'), findsNothing);
            expect(find.text('Approve File'), findsNothing);
            expect(find.text('Unapprove'), findsNothing);
            expect(find.text('Unapprove File'), findsNothing);
            expect(
              find.text('review.txt  [${review.changeKind}]'),
              findsNWidgets(unapprove ? 2 : 1),
            );
            expect(
              find.text('  10      -old-0'),
              review.changeKind == 'modified'
                  ? findsNWidgets(unapprove ? 2 : 1)
                  : findsNothing,
            );
            expect(port.handles, isEmpty);
            expect(port.review.operations, [operation]);
            expect(port.methods, hasLength(snapshots));
            old.onPressed!();
            if (review.changeKind == 'deleted') {
              expect(find.text('Open in Source'), findsNothing);
              expect(source.paths, isEmpty);
            } else {
              await tester.tap(find.text('Open in Source'));
              await tester.pumpAndSettle();
              expect(source.paths, ['review.txt']);
            }
            expect(port.review.operations, [operation]);
            // Failed manual refresh cannot resurrect old selections or replay mutation.
            port.review.failure = null;
            port.service.failure = true;
            await tester.tap(find.text('Refresh'));
            await tester.pumpAndSettle();
            expect(find.text('Unable to load $scope changes.'), findsOneWidget);
            expect(find.text('Approve'), findsNothing);
            expect(port.review.operations, [operation]);
            expect(port.handles, isEmpty);
            port.service.failure = false;
            port.service.value = _reviewSnapshot(
              revision: 'fresh:manual',
              fileRevision: 'fresh:manual:file',
              changeKind: review.changeKind,
              hunks: review.hunks,
            );
            port.service.uncommitted = _uncommitted(
              staged: port.service.value,
              unstaged: port.service.value,
            );
            await tester.tap(find.text('Retry'));
            await tester.pumpAndSettle();
            expect(find.text(_reviewFailure), findsNothing);
            expect(
              find.text('Approve'),
              review.changeKind == 'modified' ? findsNWidgets(2) : findsNothing,
            );
            expect(find.text('Approve File'), findsOneWidget);
            expect(
              find.text('Unapprove File'),
              unapprove ? findsOneWidget : findsNothing,
            );
            old.onPressed!();
            await tester.pumpAndSettle();
            expect(port.review.operations, [operation]);
            await tester.tap(find.widgetWithText(TextButton, action).last);
            await tester.pumpAndSettle();
            expect(port.review.operations, [operation, operation]);
            if (fileReview) {
              expect(
                port.review.fileSelections.last.expectedRevision,
                'fresh:manual:file',
              );
            } else {
              expect(
                port.review.selections.last.expectedRevision,
                'fresh:manual',
              );
            }
            expect(port.methods, hasLength(snapshots + 3));
            expect(
              port.methods.skip(snapshots),
              everyElement(
                unapprove
                    ? changeSetSourceServiceSnapshotUncommittedId
                    : changeSetSourceServiceSnapshotUnstagedId,
              ),
            );
            expect(tester.takeException(), isNull);
          },
        );
      }

      testWidgets(
        'post-success snapshot failure Retry only reloads, never replays $action ${review.name}',
        (tester) async {
          port.service.value = _reviewSnapshot(
            fileRevision: 'file:revision',
            changeKind: review.changeKind,
            hunks: review.hunks,
          );
          port.service.uncommitted = _uncommitted(staged: port.service.value);
          await mount(tester);
          if (unapprove) {
            await tester.tap(
              find.widgetWithText(TextButton, 'Uncommitted changes'),
            );
            await tester.pumpAndSettle();
          }
          final snapshots = port.methods.length;
          port.service.failure = true;
          await tester.tap(find.widgetWithText(TextButton, action).first);
          await tester.pumpAndSettle();
          expect(find.text('Unable to load $scope changes.'), findsOneWidget);
          expect(find.text('Approve'), findsNothing);
          expect(port.review.operations, [operation]);
          expect(port.methods, hasLength(snapshots + 1));
          expect(port.handles, isEmpty);
          port.service.failure = false;
          await tester.tap(find.text('Retry'));
          await tester.pumpAndSettle();
          expect(
            find.text(unapprove ? 'Unapprove' : 'Approve'),
            review.changeKind == 'modified' ? findsNWidgets(2) : findsNothing,
          );
          expect(
            find.text(unapprove ? 'Unapprove File' : 'Approve File'),
            findsOneWidget,
          );
          expect(port.methods, hasLength(snapshots + 2));
          expect(port.review.operations, [operation]);
          expect(tester.takeException(), isNull);
        },
      );
    }
  }

  for (final review in _reviewCases.where((review) => review.fileReview)) {
    for (final ending in [
      'refresh',
      'scope',
      'departure',
      'dispose',
      'retirement',
    ]) {
      testWidgets(
        'late ${review.name} review resolution releases unused binding after $ending',
        (tester) async {
          final held = Completer<void>();
          port.reviewResolving = held.future;
          port.service.value = _reviewSnapshot(
            fileRevision: 'file:revision',
            changeKind: review.changeKind,
            hunks: review.hunks,
          );
          await mount(tester);
          expect(port.reviewResolutions, 1);
          expect(port.reviewHandles, isEmpty);
          expect(find.text('Approve'), findsNothing);
          expect(find.text('Approve File'), findsNothing);
          if (ending == 'refresh') {
            port.service.value = _snapshot(path: 'fresh.txt');
            await tester.tap(find.text('Refresh'));
          } else if (ending == 'scope') {
            port.service.task = _task(committed: _snapshot(path: 'fresh.txt'));
            await tester.tap(find.widgetWithText(TextButton, 'Task / Branch'));
          } else if (ending == 'departure') {
            await lifecycle.prepareToDeactivate();
          } else if (ending == 'dispose') {
            await tester.pumpWidget(const SizedBox());
          } else {
            frontend.invalidate();
          }
          await tester.pumpAndSettle();
          held.complete();
          await tester.pumpAndSettle();
          expect(port.handles, isEmpty);
          expect(port.releases, contains('review-1'));
          expect(port.review.operations, isEmpty);
          expect(find.text('Approve'), findsNothing);
          expect(find.text('Approve File'), findsNothing);
          expect(find.text(_reviewFailure), findsNothing);
          expect(tester.takeException(), isNull);
        },
      );
    }
  }

  for (final review in _reviewCases) {
    final fileReview = review.fileReview;
    final action = fileReview ? 'Approve File' : 'Approve';
    final operation = fileReview ? 'approveFile' : 'approve';
    for (final ending in ['scope', 'departure', 'dispose', 'retirement']) {
      for (final fails in [false, true]) {
        testWidgets(
          'pending $action ${review.name} $ending releases now and fences late failure=$fails',
          (tester) async {
            port.service.value = _reviewSnapshot(
              fileRevision: 'file:revision',
              changeKind: review.changeKind,
              hunks: review.hunks,
            );
            port.service.task = _task(
              uncommitted: _uncommitted(
                staged: _reviewSnapshot(
                  path: 'current.txt',
                  revision: 'current',
                  fileRevision: 'file:current',
                  changeKind: review.changeKind,
                  hunks: review.hunks,
                ),
              ),
            );
            await mount(tester);
            final old = tester.widget<TextButton>(
              find.widgetWithText(TextButton, action).first,
            );
            final held = Completer<void>();
            port.review.pending = held.future;
            old.onPressed!();
            await tester.pumpAndSettle();
            if (ending == 'scope') {
              await tester.tap(
                find.widgetWithText(TextButton, 'Task / Branch'),
              );
            } else if (ending == 'departure') {
              await lifecycle.prepareToDeactivate();
            } else if (ending == 'dispose') {
              await tester.pumpWidget(const SizedBox());
            } else {
              frontend.invalidate();
            }
            await tester.pumpAndSettle();
            expect(port.releases, contains('review-1'));
            expect(port.reviewHandles.containsKey('review-1'), isFalse);
            final snapshots = port.methods.length;
            if (ending == 'scope') {
              expect(find.text('Unapprove'), findsNothing);
              expect(find.text('Unapprove File'), findsNothing);
              expect(find.text('Review change pending...'), findsNothing);
              expect(find.text(_reviewRefreshRequired), findsOneWidget);
              expect(port.reviewResolutions, 1);
              expect(port.reviewHandles, isEmpty);
              old.onPressed!();
            }
            if (fails) {
              held.completeError(StateError('private late review'));
            } else {
              held.complete();
            }
            await tester.pumpAndSettle();
            expect(port.methods, hasLength(snapshots));
            expect(port.review.operations, [operation]);
            expect(find.text(_reviewFailure), findsNothing);
            expect(
              find.text('review.txt  [${review.changeKind}]'),
              findsNothing,
            );
            if (ending == 'scope') {
              expect(
                find.text('current.txt  [${review.changeKind}]'),
                findsOneWidget,
              );
              expect(find.text('Unapprove'), findsNothing);
              expect(find.text('Unapprove File'), findsNothing);
              expect(find.text(_reviewRefreshRequired), findsOneWidget);
              expect(port.reviewResolutions, 1);
              expect(port.reviewHandles, isEmpty);
              await tester.tap(find.text('Refresh'));
              await tester.pumpAndSettle();
              expect(
                find.text('Unapprove'),
                review.changeKind == 'modified'
                    ? findsNWidgets(2)
                    : findsNothing,
              );
              expect(find.text('Unapprove File'), findsOneWidget);
              expect(find.text(_reviewRefreshRequired), findsNothing);
              expect(port.reviewResolutions, 2);
              expect(port.reviewHandles.keys, ['review-2']);
              expect(port.review.operations, [operation]);
            } else {
              expect(port.handles, isEmpty);
            }
            if (ending == 'departure') {
              await tester.tap(find.text('Refresh'));
              await tester.pumpAndSettle();
              old.onPressed!();
              await tester.pumpAndSettle();
              expect(
                find.text('Approve'),
                review.changeKind == 'modified'
                    ? findsNWidgets(2)
                    : findsNothing,
              );
              expect(find.text('Approve File'), findsOneWidget);
              expect(port.review.operations, [operation]);
            }
            expect(tester.takeException(), isNull);
          },
        );
      }
    }

    for (final admitted in [false, true]) {
      testWidgets(
        'same-ID replacement never retargets captured $action ${review.name} admitted=$admitted',
        (tester) async {
          port.service.value = _reviewSnapshot(
            fileRevision: 'file:revision',
            changeKind: review.changeKind,
            hunks: review.hunks,
          );
          await mount(tester);
          final original = port.review;
          final old = tester.widget<TextButton>(
            find.widgetWithText(TextButton, action).first,
          );
          final held = Completer<void>();
          if (admitted) {
            original.pending = held.future;
            old.onPressed!();
            await tester.pumpAndSettle();
            expect(original.operations, [operation]);
          }
          port.replaceReview();
          expect(port.review.id, original.id);
          if (admitted) {
            held.complete();
          } else {
            old.onPressed!();
          }
          await tester.pumpAndSettle();
          expect(find.text(_reviewFailure), findsOneWidget);
          expect(find.text('Approve'), findsNothing);
          expect(find.text('Approve File'), findsNothing);
          expect(port.review.operations, isEmpty);
          expect(original.operations, admitted ? [operation] : isEmpty);
          expect(port.reviewResolutions, 1);
          expect(port.handles, isEmpty);
          expect(port.service.calls, 1);
          await tester.tap(find.text('Refresh'));
          await tester.pumpAndSettle();
          old.onPressed!();
          await tester.pumpAndSettle();
          expect(port.review.operations, isEmpty);
          await tester.tap(find.widgetWithText(TextButton, action).last);
          await tester.pumpAndSettle();
          expect(port.review.operations, [operation]);
          if (fileReview) {
            expect(
              port.review.fileSelections.single.expectedRevision,
              'file:revision',
            );
          } else {
            expect(port.review.selections.single.hunkIndex, 1);
          }
          expect(tester.takeException(), isNull);
        },
      );
    }

    testWidgets(
      '$action ${review.name} and Source pending operations remain independent',
      (tester) async {
        registerSource();
        const path = 'dir/notes [modified] with spaces.txt';
        port.service.value = ChangeSetSnapshot(
          layerReviewRevision: null,
          files: [
            ..._reviewSnapshot(
              path: path,
              fileRevision: 'file:revision',
              changeKind: review.changeKind,
              hunks: review.hunks,
            ).files,
            if (review.changeKind == 'deleted')
              ..._snapshot(path: 'existing.txt').files,
          ],
        );
        await mount(tester);
        final sourceHeld = Completer<Map<String, Object?>>();
        final reviewHeld = Completer<void>();
        source.pending = sourceHeld.future;
        port.review.pending = reviewHeld.future;
        await tester.tap(find.text('Open in Source'));
        await tester.pumpAndSettle();
        expect(
          find.text('Approve'),
          review.changeKind == 'modified' ? findsNWidgets(2) : findsNothing,
        );
        expect(find.text('Approve File'), findsOneWidget);
        await tester.tap(find.widgetWithText(TextButton, action).last);
        await tester.pumpAndSettle();
        if (fileReview) {
          expect(port.review.fileSelections.single.relativePath, path);
        } else {
          expect(port.review.selections.single.relativePath, path);
          expect(port.review.selections.single.hunkIndex, 1);
        }
        expect(source.paths, [
          review.changeKind == 'deleted' ? 'existing.txt' : path,
        ]);
        expect(find.text('Opening in Source...'), findsOneWidget);
        reviewHeld.complete();
        await tester.pumpAndSettle();
        expect(port.service.calls, 2);
        expect(source.paths, hasLength(1));
        sourceHeld.complete({'ok': false});
        await tester.pumpAndSettle();
        expect(find.text('Unable to open file in Source.'), findsNothing);
        expect(find.text('Open in Source'), findsOneWidget);
        expect(port.review.operations, [operation]);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'actual generated eval snapshot renders unified lines and releases access',
    (tester) async {
      port.service.value = _snapshot();
      await mount(tester);
      expect(find.text('notes.txt  [modified]'), findsOneWidget);
      expect(find.text('@@ -3,2 +3,2 @@'), findsOneWidget);
      expect(find.text('   3    3  shared'), findsOneWidget);
      expect(find.text('   4      -before'), findsOneWidget);
      expect(find.text('        4 +after'), findsOneWidget);
      expect(find.text(r'\ No newline at end of file'), findsOneWidget);
      expect(port.resolutions, 1);
      expect(port.service.calls, 1);
      expect(port.handles, isEmpty);
      expect(port.releases, ['handle-1']);
      expect(find.byType(TextField), findsNothing);
    },
  );

  testWidgets(
    'Open in Source passes raw unusual paths and Refresh never displays source',
    (tester) async {
      registerSource();
      final paths = [
        'dir/file with spaces.txt',
        'dir/name  [deleted] [modified].txt',
        'dir/quote" tab\t unicode-\u03bb\nname.txt',
      ];
      port.service.value = _snapshot(path: paths.first);
      await mount(tester);
      expect(source.paths, isEmpty);
      for (final path in paths) {
        port.service.value = _snapshot(path: path);
        await tester.tap(find.text('Refresh'));
        await tester.pumpAndSettle();
        expect(source.paths.length, paths.indexOf(path));
        expect(find.text('$path  [modified]'), findsOneWidget);
        await tester.tap(find.text('Open in Source'));
        await tester.pumpAndSettle();
        expect(source.paths.last, path);
        expect(find.text('Unable to open file in Source.'), findsNothing);
      }
      expect(source.paths, paths);
      expect(port.service.calls, 4);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('only known existing text file headers offer Open in Source', (
    tester,
  ) async {
    registerSource();
    await mount(tester);
    for (final scope in ['unstaged', 'uncommitted', 'task']) {
      if (scope != 'unstaged') {
        await tester.tap(
          find.widgetWithText(
            TextButton,
            scope == 'task' ? 'Task / Branch' : 'Uncommitted changes',
          ),
        );
        await tester.pumpAndSettle();
      }
      for (final entry in [
        ('modified', 'text', true),
        ('added', 'text', true),
        ('typeChanged', 'text', true),
        ('deleted', 'text', false),
        ('unsupported', 'text', false),
        ('conflicted', 'text', false),
        ('modified', 'binary', false),
        ('modified', 'oversized', false),
        ('modified', 'unsupported', false),
        ('modified', 'conflicted', false),
      ]) {
        port.service.value = ChangeSetSnapshot(
          layerReviewRevision: null,
          files: [
            ChangedFile(
              relativePath: 'file.txt',
              changeKind: entry.$1,
              contentStatus: entry.$2,
              detail: null,
              reviewRevision: null,
              fileReviewRevision: null,
              commentComparisonIdentity: null,
              hunks: [],
            ),
          ],
        );
        port.service.uncommitted = UncommittedChangeSetSnapshot(
          staged: port.service.value,
          unstaged: port.service.value,
          // Even text-shaped entries in the conflicts section are not current files.
          conflicts: port.service.value.files,
        );
        port.service.task = TaskChangeSetSnapshot(
          committed: port.service.value,
          uncommitted: port.service.uncommitted,
        );
        await tester.tap(find.text('Refresh'));
        await tester.pumpAndSettle();
        expect(
          find.text('file.txt  [${entry.$1}]'),
          findsNWidgets(
            scope == 'task'
                ? 4
                : scope == 'uncommitted'
                ? 3
                : 1,
          ),
        );
        expect(
          find.text('Open in Source'),
          entry.$3 ? findsOneWidget : findsNothing,
          reason: '$scope: ${entry.$1}/${entry.$2}',
        );
      }
    }
    expect(source.paths, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'missing and multiple Source providers stay explicit without choosing one',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(320, 600));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      port.service.value = _snapshot();
      await mount(tester);
      expect(find.text('Source is unavailable.'), findsOneWidget);
      expect(find.text('Open in Source'), findsNothing);
      final first = registerSource();
      await tester.tap(find.text('Refresh'));
      await tester.pumpAndSettle();
      final button = tester.widget<TextButton>(
        find.widgetWithText(TextButton, 'Open in Source'),
      );
      final second = registerSource(id: 'test.second-source');
      // A previously rendered callback must recheck current availability.
      button.onPressed!();
      await tester.pumpAndSettle();
      expect(
        find.text('Multiple Source providers are available.'),
        findsWidgets,
      );
      expect(find.text('Open in Source'), findsNothing);
      expect(source.paths, isEmpty);
      await first.close();
      await second.close();
      await tester.tap(find.text('Refresh'));
      await tester.pumpAndSettle();
      expect(find.text('Source is unavailable.'), findsOneWidget);
      expect(find.text('notes.txt  [modified]'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'pending source display suppresses duplicates and failure is nonfatal and retryable',
    (tester) async {
      registerSource();
      final held = Completer<Map<String, Object?>>();
      source.pending = held.future;
      port.service.value = _snapshot();
      await mount(tester);
      final button = tester.widget<TextButton>(
        find.widgetWithText(TextButton, 'Open in Source'),
      );
      button.onPressed!();
      button.onPressed!();
      await tester.pumpAndSettle();
      expect(source.paths, ['notes.txt']);
      expect(find.text('Opening in Source...'), findsOneWidget);
      expect(find.text('Open in Source'), findsNothing);
      held.complete({'ok': false, 'message': 'private source diagnostic'});
      await tester.pumpAndSettle();
      expect(find.text('Unable to open file in Source.'), findsOneWidget);
      expect(find.text('notes.txt  [modified]'), findsOneWidget);
      expect(find.text('   4      -before'), findsOneWidget);
      expect(find.textContaining('private source diagnostic'), findsNothing);
      expect(port.service.calls, 1);
      await tester.tap(find.text('Open in Source'));
      await tester.pumpAndSettle();
      expect(source.paths, ['notes.txt', 'notes.txt']);
      expect(find.text('Unable to open file in Source.'), findsNothing);
      expect(port.service.calls, 1);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('source exceptions become generic errors, not a failed Diff', (
    tester,
  ) async {
    registerSource();
    source.failure = true;
    port.service.value = _snapshot();
    await mount(tester);
    await tester.tap(find.text('Open in Source'));
    await tester.pumpAndSettle();
    expect(find.text('Unable to open file in Source.'), findsOneWidget);
    expect(find.text('notes.txt  [modified]'), findsOneWidget);
    expect(find.text('Unable to load unstaged changes.'), findsNothing);
    expect(find.textContaining('private source diagnostic'), findsNothing);
    expect(port.service.calls, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'refresh fences old source feedback and callbacks but retains pending suppression',
    (tester) async {
      registerSource();
      final held = Completer<Map<String, Object?>>();
      source.pending = held.future;
      port.service.value = _snapshot();
      await mount(tester);
      final oldButton = tester.widget<TextButton>(
        find.widgetWithText(TextButton, 'Open in Source'),
      );
      oldButton.onPressed!();
      await tester.pumpAndSettle();
      port.service.value = _snapshot(path: 'current.txt');
      await tester.tap(find.text('Refresh'));
      await tester.pumpAndSettle();
      expect(find.text('current.txt  [modified]'), findsOneWidget);
      expect(find.text('Opening in Source...'), findsOneWidget);
      expect(source.paths, ['notes.txt']);
      held.complete({'ok': false});
      await tester.pumpAndSettle();
      expect(find.text('Unable to open file in Source.'), findsNothing);
      oldButton.onPressed!();
      await tester.pumpAndSettle();
      expect(source.paths, ['notes.txt']);
      await tester.tap(find.text('Open in Source'));
      await tester.pumpAndSettle();
      expect(source.paths, ['notes.txt', 'current.txt']);
      expect(port.service.calls, 2);
      expect(tester.takeException(), isNull);
    },
  );

  for (final departing in [true, false]) {
    testWidgets('late source completion cannot update departed=$departing UI', (
      tester,
    ) async {
      registerSource();
      final held = Completer<Map<String, Object?>>();
      source.pending = held.future;
      port.service.value = _snapshot();
      await mount(tester);
      await tester.tap(find.text('Open in Source'));
      await tester.pumpAndSettle();
      if (departing) {
        await lifecycle.prepareToDeactivate();
      } else {
        await tester.pumpWidget(const SizedBox());
      }
      held.complete({'ok': false});
      await tester.pumpAndSettle();
      expect(find.text('Unable to open file in Source.'), findsNothing);
      expect(find.text('notes.txt  [modified]'), findsNothing);
      expect(source.paths, ['notes.txt']);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets(
    'loading, clean, unavailable, error and manual retry are truthful',
    (tester) async {
      final held = Completer<ChangeSetSnapshot>();
      port.service.pending = held.future;
      await mount(tester);
      expect(port.service.calls, 1);
      expect(find.text('Loading unstaged changes...'), findsOneWidget);
      expect(port.handles, hasLength(1));
      held.complete(ChangeSetSnapshot(files: [], layerReviewRevision: null));
      await tester.pumpAndSettle();
      expect(find.text('No unstaged changes.'), findsOneWidget);
      expect(port.handles, isEmpty);
      port.available = false;
      await tester.tap(find.text('Refresh'));
      await tester.pumpAndSettle();
      expect(
        find.text('Diff unavailable for this Environment.'),
        findsOneWidget,
      );
      expect(port.service.calls, 1);
      port.available = true;
      port.service.failure = true;
      await tester.tap(find.text('Retry'));
      await tester.pumpAndSettle();
      expect(find.text('Unable to load unstaged changes.'), findsOneWidget);
      expect(find.textContaining('private failure'), findsNothing);
      expect(port.handles, isEmpty);
      port.service.failure = false;
      port.service.value = _snapshot();
      await tester.tap(find.text('Retry'));
      await tester.pumpAndSettle();
      expect(find.text('notes.txt  [modified]'), findsOneWidget);
      expect(port.resolutions, 4);
      expect(port.service.calls, 3);
      expect(port.handles, isEmpty);
    },
  );

  testWidgets(
    'generated eval decoder rejects malformed nested DTOs and retry resolves anew',
    (tester) async {
      final diagnosticLines = <String>[];
      port.diagnostics = EnvironmentCapabilityDiagnostics(
        debugBuild: true,
        environment: {EnvironmentCapabilityDiagnostics.flag: '1'},
        sink: diagnosticLines.add,
      );
      port.wireResponse = {
        'layerReviewRevision': null,
        'files': [
          {
            'relativePath': 'invalid.txt',
            'changeKind': 'modified',
            'contentStatus': 'text',
            'detail': null,
            'reviewRevision': null,
            'fileReviewRevision': null,
            'commentComparisonIdentity': null,
            'hunks': [
              {
                'oldStart': 1,
                'oldCount': 1,
                'newStart': 1,
                'newCount': 1,
                'lines': [
                  {'kind': 'addition', 'text': 'invalid', 'noNewline': 'false'},
                ],
              },
            ],
          },
        ],
      };
      await mount(tester);
      expect(find.text('Unable to load unstaged changes.'), findsOneWidget);
      expect(port.handles, isEmpty);
      expect(port.settlementHandles, ['handle-1']);
      final failedRecords = _diagnosticRecords(diagnosticLines);
      expect(failedRecords.map((record) => record['phase']), [
        'response',
        'response-decoding',
      ]);
      expect(failedRecords.map((record) => record['outcome']), [
        'success',
        'failure',
      ]);
      expect(failedRecords.last['classification'], isA<String>());
      expect(failedRecords.map((record) => record['operation']), [1, 1]);
      expect(diagnosticLines.join(), isNot(contains('invalid.txt')));
      expect(diagnosticLines.join(), isNot(contains('noNewline')));
      expect(diagnosticLines.join(), isNot(contains('handle-1')));
      expect(find.textContaining('response-decoding'), findsNothing);
      port.wireResponse = null;
      await tester.tap(find.text('Retry'));
      await tester.pumpAndSettle();
      expect(find.text('No unstaged changes.'), findsOneWidget);
      expect(port.resolutions, 2);
      expect(port.settlementHandles, ['handle-1', 'handle-2']);
      expect(port.releases, ['handle-1', 'handle-2']);
      final retriedRecords = _diagnosticRecords(diagnosticLines).skip(2);
      expect(retriedRecords.map((record) => record['phase']), [
        'response',
        'response-decoding',
      ]);
      expect(retriedRecords.map((record) => record['outcome']), [
        'success',
        'success',
      ]);
      expect(retriedRecords.map((record) => record['operation']), [2, 2]);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'diagnostics distinguish invocation failure from generated response decoding',
    (tester) async {
      final diagnosticLines = <String>[];
      port.diagnostics = EnvironmentCapabilityDiagnostics(
        debugBuild: true,
        environment: {EnvironmentCapabilityDiagnostics.flag: '1'},
        sink: diagnosticLines.add,
      );
      port.service.failure = true;
      await mount(tester);
      expect(find.text('Unable to load unstaged changes.'), findsOneWidget);
      expect(find.textContaining('private'), findsNothing);
      expect(find.textContaining('invocation'), findsNothing);
      expect(port.handles, isEmpty);
      expect(port.releases, ['handle-1']);
      expect(port.settlementHandles, ['handle-1']);
      final record = _diagnosticRecords(diagnosticLines).single;
      expect(record['phase'], 'invocation');
      expect(record['outcome'], 'failure');
      expect(record['method'], changeSetSourceServiceSnapshotUnstagedId);
      expect(diagnosticLines.join(), isNot(contains('private failure')));
      expect(diagnosticLines.join(), isNot(contains('handle-1')));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'new refresh releases old access and ignores a late older snapshot',
    (tester) async {
      final old = Completer<ChangeSetSnapshot>();
      port.service.pending = old.future;
      await mount(tester);
      expect(port.service.calls, 1);
      port.service.value = _snapshot(path: 'new.txt');
      await tester.tap(find.text('Refresh'));
      await tester.pumpAndSettle();
      expect(find.text('new.txt  [modified]'), findsOneWidget);
      expect(port.handles, isEmpty);
      expect(port.releases, ['handle-1', 'handle-2']);
      old.complete(_snapshot(path: 'obsolete.txt'));
      await tester.pumpAndSettle();
      expect(find.text('new.txt  [modified]'), findsOneWidget);
      expect(find.textContaining('obsolete.txt'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'departure releases pending access without waiting and remains retryable',
    (tester) async {
      final old = Completer<ChangeSetSnapshot>();
      port.service.pending = old.future;
      await mount(tester);
      expect(port.service.calls, 1);
      await lifecycle.prepareToDeactivate();
      expect(port.handles, isEmpty);
      expect(port.releases, ['handle-1']);
      old.complete(_snapshot(path: 'departed.txt'));
      await tester.pumpAndSettle();
      expect(find.textContaining('departed.txt'), findsNothing);
      // A sibling can refuse navigation after this pane's accepted hook.
      port.service.value = _snapshot(path: 'retry.txt');
      await tester.tap(find.text('Refresh'));
      await tester.pumpAndSettle();
      expect(find.text('retry.txt  [modified]'), findsOneWidget);
    },
  );

  testWidgets(
    'dispose releases held snapshot and old completion never enters a new view',
    (tester) async {
      final old = Completer<ChangeSetSnapshot>();
      port.service.pending = old.future;
      await mount(tester);
      final previous = port;
      await tester.pumpWidget(const SizedBox());
      expect(previous.handles, isEmpty);
      expect(previous.releases, ['handle-1']);
      port = _Port()..service.value = _snapshot(path: 'current.txt');
      lifecycle = SessionPresentationLifecycleBridge(isActive: () => true);
      await mount(tester, key: const ValueKey('new-presentation'));
      old.complete(_snapshot(path: 'obsolete.txt'));
      await tester.pumpAndSettle();
      await previous.close();
      expect(find.text('current.txt  [modified]'), findsOneWidget);
      expect(find.textContaining('obsolete.txt'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'superseded pending resolution releases its late handle without reading',
    (tester) async {
      final resolution = Completer<void>();
      port.resolving = resolution.future;
      await mount(tester);
      expect(port.resolutions, 1);
      expect(port.service.calls, 0);
      await tester.tap(find.text('Refresh'));
      await tester.pumpAndSettle();
      expect(port.service.calls, 1);
      expect(find.text('No unstaged changes.'), findsOneWidget);
      resolution.complete();
      await tester.pumpAndSettle();
      expect(port.service.calls, 1);
      expect(port.handles, isEmpty);
      expect(port.releases, ['handle-2', 'handle-1']);
    },
  );

  testWidgets(
    'non-text statuses are explicit and large text builds rows lazily',
    (tester) async {
      port.service.value = ChangeSetSnapshot(
        layerReviewRevision: null,
        files: [
          for (final status in [
            'binary',
            'unsupported',
            'oversized',
            'conflicted',
          ])
            ChangedFile(
              relativePath: '$status.dat',
              changeKind: 'unsupported',
              contentStatus: status,
              detail: 'Not displayed: $status',
              reviewRevision: null,
              fileReviewRevision: null,
              commentComparisonIdentity: null,
              hunks: [],
            ),
        ],
      );
      await mount(tester);
      for (final status in [
        'binary',
        'unsupported',
        'oversized',
        'conflicted',
      ]) {
        expect(find.text(status), findsOneWidget);
        expect(find.text('Not displayed: $status'), findsOneWidget);
      }
      port.service.value = ChangeSetSnapshot(
        layerReviewRevision: null,
        files: [
          ChangedFile(
            relativePath: 'large.txt',
            changeKind: 'added',
            contentStatus: 'text',
            detail: null,
            reviewRevision: null,
            fileReviewRevision: null,
            commentComparisonIdentity: null,
            hunks: [
              DiffHunk(
                oldStart: 0,
                oldCount: 0,
                newStart: 1,
                newCount: 2000,
                lines: List.generate(
                  2000,
                  (index) => DiffLine(
                    kind: 'addition',
                    text: 'line-$index',
                    noNewline: false,
                  ),
                ),
              ),
            ],
          ),
        ],
      );
      await tester.tap(find.text('Refresh'));
      await tester.pumpAndSettle();
      expect(find.textContaining('+line-0'), findsOneWidget);
      expect(find.textContaining('+line-1999'), findsNothing);
      expect(tester.widgetList(find.byType(Text)).length, lessThan(100));
      port.service.uncommitted = _uncommitted(
        staged: port.service.value,
        unstaged: _snapshot(path: 'lower-layer.txt'),
      );
      await tester.tap(find.widgetWithText(TextButton, 'Uncommitted changes'));
      await tester.pumpAndSettle();
      expect(find.text('Staged changes'), findsOneWidget);
      expect(find.textContaining('+line-0'), findsOneWidget);
      expect(find.textContaining('+line-1999'), findsNothing);
      expect(find.text('lower-layer.txt  [modified]'), findsNothing);
      expect(find.text('Conflicts'), findsNothing);
      expect(tester.widgetList(find.byType(Text)).length, lessThan(100));
      port.service.task = TaskChangeSetSnapshot(
        committed: port.service.value,
        uncommitted: port.service.uncommitted,
      );
      await tester.tap(find.widgetWithText(TextButton, 'Task / Branch'));
      await tester.pumpAndSettle();
      expect(find.text('Committed changes'), findsOneWidget);
      expect(find.textContaining('+line-0'), findsOneWidget);
      expect(find.textContaining('+line-1999'), findsNothing);
      expect(find.text('Staged changes'), findsNothing);
      expect(find.text('Open in Source'), findsNothing);
      expect(tester.widgetList(find.byType(Text)).length, lessThan(100));
      await tester.drag(find.byType(ListView), const Offset(0, -600));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'scope defaults to Unstaged and preserves cancelling same-path layers',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(900, 1000));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      registerSource();
      const path = 'dir/two words [deleted]\t\u03bb.txt';
      port.service.value = _snapshot(path: 'default.txt');
      port.service.uncommitted = UncommittedChangeSetSnapshot(
        staged: _snapshot(path: path),
        unstaged: _snapshot(path: path, before: 'after', after: 'before'),
        conflicts: [_conflict()],
      );
      await mount(tester);
      expect(port.methods, [changeSetSourceServiceSnapshotUnstagedId]);
      expect(find.text('default.txt  [modified]'), findsOneWidget);
      expect(find.text('Staged changes'), findsNothing);
      expect(find.text('Conflicts'), findsNothing);
      await tester.tap(find.widgetWithText(TextButton, 'Uncommitted changes'));
      await tester.pumpAndSettle();
      expect(find.text('default.txt  [modified]'), findsNothing);
      expect(find.text('$path  [modified]'), findsNWidgets(2));
      expect(find.text('   4      -before'), findsOneWidget);
      expect(find.text('        4 +after'), findsOneWidget);
      expect(find.text('   4      -after'), findsOneWidget);
      expect(find.text('        4 +before'), findsOneWidget);
      expect(find.text('conflict.txt  [conflicted]'), findsOneWidget);
      expect(find.text('No uncommitted changes.'), findsNothing);
      final section = find.text('Unstaged changes').last;
      expect(
        tester.getTopLeft(find.text('Staged changes')).dy,
        lessThan(tester.getTopLeft(section).dy),
      );
      expect(
        tester.getTopLeft(section).dy,
        lessThan(tester.getTopLeft(find.text('Conflicts')).dy),
      );
      expect(find.text('Open in Source'), findsOneWidget);
      expect(
        tester.getTopLeft(find.text('Open in Source')).dy,
        greaterThan(tester.getTopLeft(section).dy),
      );
      await tester.tap(find.text('Open in Source'));
      await tester.pumpAndSettle();
      expect(source.paths, [path]);
      await tester.tap(find.widgetWithText(TextButton, 'Unstaged changes'));
      await tester.pumpAndSettle();
      expect(find.text('default.txt  [modified]'), findsOneWidget);
      expect(find.text('Conflicts'), findsNothing);
      expect(port.methods, [
        changeSetSourceServiceSnapshotUnstagedId,
        changeSetSourceServiceSnapshotUncommittedId,
        changeSetSourceServiceSnapshotUnstagedId,
      ]);
      expect(port.handles, isEmpty);
      expect(port.releases, ['handle-1', 'handle-2', 'handle-3']);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'Uncommitted loading, clean, unavailable, Retry and Refresh use chosen method',
    (tester) async {
      await mount(tester);
      final held = Completer<UncommittedChangeSetSnapshot>();
      port.service.pendingUncommitted = held.future;
      await tester.tap(find.widgetWithText(TextButton, 'Uncommitted changes'));
      await tester.pumpAndSettle();
      expect(find.text('Loading uncommitted changes...'), findsOneWidget);
      expect(port.handles, hasLength(1));
      held.complete(_uncommitted());
      await tester.pumpAndSettle();
      expect(find.text('No uncommitted changes.'), findsOneWidget);
      expect(find.text('No staged changes.'), findsOneWidget);
      expect(find.text('No unstaged changes.'), findsOneWidget);
      expect(find.text('No conflicts.'), findsOneWidget);
      expect(port.handles, isEmpty);
      port.available = false;
      await tester.tap(find.text('Refresh'));
      await tester.pumpAndSettle();
      expect(
        find.text('Diff unavailable for this Environment.'),
        findsOneWidget,
      );
      port.available = true;
      port.service.failure = true;
      await tester.tap(find.text('Retry'));
      await tester.pumpAndSettle();
      expect(find.text('Unable to load uncommitted changes.'), findsOneWidget);
      expect(find.textContaining('private failure'), findsNothing);
      expect(port.handles, isEmpty);
      port.service.failure = false;
      port.service.uncommitted = _uncommitted(conflicts: [_conflict()]);
      await tester.tap(find.text('Retry'));
      await tester.pumpAndSettle();
      expect(find.text('conflict.txt  [conflicted]'), findsOneWidget);
      expect(find.text('No uncommitted changes.'), findsNothing);
      port.service.uncommitted = _uncommitted(
        staged: _snapshot(path: 'staged-only.txt'),
      );
      await tester.tap(find.text('Refresh'));
      await tester.pumpAndSettle();
      expect(find.text('staged-only.txt  [modified]'), findsOneWidget);
      expect(find.text('No uncommitted changes.'), findsNothing);
      expect(find.text('Open in Source'), findsNothing);
      expect(port.service.calls, 1);
      expect(port.service.uncommittedCalls, 4);
      expect(
        port.methods.skip(1),
        everyElement(changeSetSourceServiceSnapshotUncommittedId),
      );
      expect(port.resolutions, 6);
      expect(port.handles, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'Task renders independent same-path layers from one generated call',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(900, 1000));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      registerSource();
      const path = 'dir/two words [deleted]\t\u03bb.txt';
      port.service.task = _task(
        committed: _snapshot(
          path: path,
          before: 'baseline',
          after: 'committed',
        ),
        uncommitted: _uncommitted(
          staged: _snapshot(path: path, before: 'committed', after: 'index'),
          unstaged: _snapshot(path: path, before: 'index', after: 'working'),
          conflicts: [_conflict()],
        ),
      );
      await mount(tester);
      expect(find.text('No unstaged changes.'), findsOneWidget);
      await tester.tap(find.widgetWithText(TextButton, 'Task / Branch'));
      await tester.pumpAndSettle();
      expect(port.methods, [
        changeSetSourceServiceSnapshotUnstagedId,
        changeSetSourceServiceSnapshotTaskChangesId,
      ]);
      expect(port.service.calls, 1);
      expect(port.service.uncommittedCalls, 0);
      expect(port.service.taskCalls, 1);
      expect(find.text('$path  [modified]'), findsNWidgets(3));
      expect(find.text('@@ -3,2 +3,2 @@'), findsNWidgets(3));
      expect(find.text('   3    3  shared'), findsNWidgets(3));
      expect(find.text('   4      -baseline'), findsOneWidget);
      expect(find.text('        4 +committed'), findsOneWidget);
      expect(find.text('   4      -committed'), findsOneWidget);
      expect(find.text('        4 +index'), findsOneWidget);
      expect(find.text('   4      -index'), findsOneWidget);
      expect(find.text('        4 +working'), findsOneWidget);
      expect(find.text(r'\ No newline at end of file'), findsNWidgets(3));
      final sections = [
        'Committed changes',
        'Staged changes',
        'Unstaged changes',
        'Conflicts',
      ];
      for (var index = 1; index < sections.length; index++) {
        expect(
          tester.getTopLeft(find.text(sections[index]).last).dy,
          greaterThan(
            tester.getTopLeft(find.text(sections[index - 1]).last).dy,
          ),
        );
      }
      expect(find.text('No task changes.'), findsNothing);
      expect(find.text('Open in Source'), findsOneWidget);
      expect(
        tester.getTopLeft(find.text('Open in Source')).dy,
        greaterThan(tester.getTopLeft(find.text('Unstaged changes').last).dy),
      );
      await tester.tap(find.text('Open in Source'));
      await tester.pumpAndSettle();
      expect(source.paths, [path]);
      expect(port.handles, isEmpty);
      expect(port.releases, ['handle-1', 'handle-2']);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('all scope controls and Refresh fit ordinary narrow panes', (
    tester,
  ) async {
    addTearDown(() => tester.binding.setSurfaceSize(null));
    registerSource();
    port.service.value = _snapshot();
    port.service.uncommitted = _uncommitted(unstaged: port.service.value);
    port.service.task = _task(uncommitted: port.service.uncommitted);
    await mount(tester);
    for (final width in [320.0, 480.0, 900.0]) {
      await tester.binding.setSurfaceSize(Size(width, 600));
      await tester.pumpAndSettle();
      for (final label in [
        'Unstaged changes',
        'Uncommitted changes',
        'Task / Branch',
      ]) {
        final button = find.widgetWithText(TextButton, label);
        await tester.tap(button);
        await tester.pumpAndSettle();
        expect(tester.getRect(button).left, greaterThanOrEqualTo(0));
        expect(tester.getRect(button).right, lessThanOrEqualTo(width));
        expect(
          tester.getTopLeft(find.widgetWithText(TextButton, 'Refresh')).dy,
          greaterThanOrEqualTo(tester.getBottomLeft(button).dy),
        );
        expect(find.text('notes.txt  [modified]'), findsOneWidget);
        expect(tester.takeException(), isNull, reason: '$width / $label');
      }
    }
  });

  testWidgets(
    'Task clean requires all layers empty and Refresh/Retry retain scope',
    (tester) async {
      await mount(tester);
      final held = Completer<TaskChangeSetSnapshot>();
      port.service.pendingTask = held.future;
      await tester.tap(find.widgetWithText(TextButton, 'Task / Branch'));
      await tester.pumpAndSettle();
      expect(find.text('Loading task changes...'), findsOneWidget);
      expect(port.handles, hasLength(1));
      held.complete(_task());
      await tester.pumpAndSettle();
      expect(find.text('No task changes.'), findsOneWidget);
      for (final text in [
        'No committed changes.',
        'No staged changes.',
        'No unstaged changes.',
        'No conflicts.',
      ]) {
        expect(find.text(text), findsOneWidget);
      }
      port.available = false;
      await tester.tap(find.text('Refresh'));
      await tester.pumpAndSettle();
      expect(
        find.text('Diff unavailable for this Environment.'),
        findsOneWidget,
      );
      port.available = true;
      port.service.failure = true;
      await tester.tap(find.text('Retry'));
      await tester.pumpAndSettle();
      expect(find.text('Unable to load task changes.'), findsOneWidget);
      expect(find.textContaining('private failure'), findsNothing);
      expect(port.handles, isEmpty);
      port.service.failure = false;
      port.service.task = _task(
        committed: _snapshot(path: 'committed-only.txt'),
      );
      await tester.tap(find.text('Retry'));
      await tester.pumpAndSettle();
      expect(find.text('committed-only.txt  [modified]'), findsOneWidget);
      expect(find.text('No task changes.'), findsNothing);
      expect(find.text('Open in Source'), findsNothing);
      for (final layer in ['staged', 'unstaged', 'conflicts']) {
        port.service.task = _task(
          uncommitted: _uncommitted(
            staged: layer == 'staged' ? _snapshot() : null,
            unstaged: layer == 'unstaged' ? _snapshot() : null,
            conflicts: layer == 'conflicts' ? [_conflict()] : [],
          ),
        );
        await tester.tap(find.text('Refresh'));
        await tester.pumpAndSettle();
        expect(find.text('No task changes.'), findsNothing);
      }
      expect(port.service.calls, 1);
      expect(port.service.uncommittedCalls, 0);
      expect(port.service.taskCalls, 6);
      expect(port.resolutions, 8);
      expect(
        port.methods.skip(1),
        everyElement(changeSetSourceServiceSnapshotTaskChangesId),
      );
      expect(port.handles, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'rapid three-scope switches and Task Refresh fence every older operation',
    (tester) async {
      final old = Completer<ChangeSetSnapshot>();
      final combined = Completer<UncommittedChangeSetSnapshot>();
      final task = Completer<TaskChangeSetSnapshot>();
      port.service.pending = old.future;
      await mount(tester);
      port.service.pendingUncommitted = combined.future;
      await tester.tap(find.widgetWithText(TextButton, 'Uncommitted changes'));
      await tester.pumpAndSettle();
      port.service.pendingTask = task.future;
      await tester.tap(find.widgetWithText(TextButton, 'Task / Branch'));
      await tester.pumpAndSettle();
      port.service.task = _task(committed: _snapshot(path: 'current.txt'));
      await tester.tap(find.text('Refresh'));
      await tester.pumpAndSettle();
      expect(find.text('current.txt  [modified]'), findsOneWidget);
      expect(port.handles, isEmpty);
      expect(port.releases, ['handle-1', 'handle-2', 'handle-3', 'handle-4']);
      task.complete(_task(committed: _snapshot(path: 'obsolete-task.txt')));
      combined.completeError(StateError('private obsolete failure'));
      old.complete(_snapshot(path: 'obsolete-unstaged.txt'));
      await tester.pumpAndSettle();
      expect(find.text('current.txt  [modified]'), findsOneWidget);
      expect(find.textContaining('obsolete'), findsNothing);
      expect(find.text('Unable to load task changes.'), findsNothing);
      expect(port.methods, [
        changeSetSourceServiceSnapshotUnstagedId,
        changeSetSourceServiceSnapshotUncommittedId,
        changeSetSourceServiceSnapshotTaskChangesId,
        changeSetSourceServiceSnapshotTaskChangesId,
      ]);
      expect(port.releases, hasLength(4));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'rapid pending scope resolutions admit only the latest Task request',
    (tester) async {
      final unstaged = Completer<void>();
      final uncommitted = Completer<void>();
      port.resolving = unstaged.future;
      await mount(tester);
      port.resolving = uncommitted.future;
      await tester.tap(find.widgetWithText(TextButton, 'Uncommitted changes'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, 'Task / Branch'));
      await tester.pumpAndSettle();
      expect(find.text('No task changes.'), findsOneWidget);
      uncommitted.complete();
      unstaged.complete();
      await tester.pumpAndSettle();
      expect(port.methods, [changeSetSourceServiceSnapshotTaskChangesId]);
      expect(port.releases, ['handle-3', 'handle-2', 'handle-1']);
      expect(port.handles, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  for (final initial in ['unstaged', 'uncommitted', 'task']) {
    final other = initial == 'unstaged' ? 'uncommitted' : 'unstaged';
    final button = initial == 'unstaged'
        ? 'Uncommitted changes'
        : 'Unstaged changes';
    for (final fails in [false, true]) {
      testWidgets(
        'switch from pending $initial snapshot ignores late failure=$fails',
        (tester) async {
          final old = Completer<ChangeSetSnapshot>();
          final combined = Completer<UncommittedChangeSetSnapshot>();
          final task = Completer<TaskChangeSetSnapshot>();
          if (initial == 'unstaged') port.service.pending = old.future;
          await mount(tester);
          if (initial == 'uncommitted') {
            port.service.pendingUncommitted = combined.future;
            await tester.tap(
              find.widgetWithText(TextButton, 'Uncommitted changes'),
            );
            await tester.pumpAndSettle();
          }
          if (initial == 'task') {
            port.service.pendingTask = task.future;
            await tester.tap(find.widgetWithText(TextButton, 'Task / Branch'));
            await tester.pumpAndSettle();
          }
          expect(find.text('Loading $initial changes...'), findsOneWidget);
          port.service.value = _snapshot(path: 'current.txt');
          port.service.uncommitted = _uncommitted(unstaged: port.service.value);
          await tester.tap(find.widgetWithText(TextButton, button));
          await tester.pumpAndSettle();
          expect(find.text('current.txt  [modified]'), findsOneWidget);
          expect(port.handles, isEmpty);
          final released = List<String>.of(port.releases);
          if (initial == 'unstaged') {
            if (fails) {
              old.completeError(StateError('private obsolete failure'));
            } else {
              old.complete(_snapshot(path: 'obsolete.txt'));
            }
          } else if (initial == 'uncommitted') {
            if (fails) {
              combined.completeError(StateError('private obsolete failure'));
            } else {
              combined.complete(
                _uncommitted(staged: _snapshot(path: 'obsolete.txt')),
              );
            }
          } else {
            if (fails) {
              task.completeError(StateError('private obsolete failure'));
            } else {
              task.complete(_task(committed: _snapshot(path: 'obsolete.txt')));
            }
          }
          await tester.pumpAndSettle();
          expect(find.text('current.txt  [modified]'), findsOneWidget);
          expect(find.textContaining('obsolete.txt'), findsNothing);
          expect(find.text('Unable to load $other changes.'), findsNothing);
          expect(port.releases, released);
          expect(
            port.methods.last,
            other == 'unstaged'
                ? changeSetSourceServiceSnapshotUnstagedId
                : changeSetSourceServiceSnapshotUncommittedId,
          );
          expect(tester.takeException(), isNull);
        },
      );
    }

    testWidgets(
      'switch from pending $initial resolution releases without invoking',
      (tester) async {
        final held = Completer<void>();
        if (initial == 'unstaged') port.resolving = held.future;
        await mount(tester);
        if (initial != 'unstaged') {
          port.resolving = held.future;
          await tester.tap(
            find.widgetWithText(
              TextButton,
              initial == 'task' ? 'Task / Branch' : 'Uncommitted changes',
            ),
          );
          await tester.pumpAndSettle();
        }
        final before = port.methods.length;
        await tester.tap(find.widgetWithText(TextButton, button));
        await tester.pumpAndSettle();
        expect(find.text('No $other changes.'), findsOneWidget);
        held.complete();
        await tester.pumpAndSettle();
        expect(port.methods, hasLength(before + 1));
        expect(port.handles, isEmpty);
        expect(port.releases, hasLength(port.resolutions));
        expect(tester.takeException(), isNull);
      },
    );
  }

  for (final resolving in [true, false]) {
    for (final departing in [true, false]) {
      testWidgets(
        'Uncommitted pending resolution=$resolving departure=$departing is fenced',
        (tester) async {
          await mount(tester);
          final resolution = Completer<void>();
          final snapshot = Completer<UncommittedChangeSetSnapshot>();
          if (resolving) {
            port.resolving = resolution.future;
          } else {
            port.service.pendingUncommitted = snapshot.future;
          }
          await tester.tap(
            find.widgetWithText(TextButton, 'Uncommitted changes'),
          );
          await tester.pumpAndSettle();
          if (departing) {
            await lifecycle.prepareToDeactivate();
          } else {
            await tester.pumpWidget(const SizedBox());
          }
          expect(port.handles, isEmpty);
          if (resolving) {
            resolution.complete();
          } else {
            snapshot.complete(
              _uncommitted(staged: _snapshot(path: 'departed.txt')),
            );
          }
          await tester.pumpAndSettle();
          expect(find.textContaining('departed.txt'), findsNothing);
          expect(port.service.uncommittedCalls, resolving ? 0 : 1);
          expect(port.handles, isEmpty);
          expect(port.releases, ['handle-1', 'handle-2']);
          if (departing) {
            port.service.uncommitted = _uncommitted(
              unstaged: _snapshot(path: 'retry.txt'),
            );
            await tester.tap(find.text('Retry'));
            await tester.pumpAndSettle();
            expect(find.text('retry.txt  [modified]'), findsOneWidget);
            expect(
              port.methods.last,
              changeSetSourceServiceSnapshotUncommittedId,
            );
          }
          expect(tester.takeException(), isNull);
        },
      );
    }
  }

  for (final resolving in [true, false]) {
    for (final ending in ['departure', 'dispose', 'retirement']) {
      testWidgets('Task pending resolution=$resolving is fenced on $ending', (
        tester,
      ) async {
        await mount(tester);
        final resolution = Completer<void>();
        final snapshot = Completer<TaskChangeSetSnapshot>();
        if (resolving) {
          port.resolving = resolution.future;
        } else {
          port.service.pendingTask = snapshot.future;
        }
        await tester.tap(find.widgetWithText(TextButton, 'Task / Branch'));
        await tester.pumpAndSettle();
        if (ending == 'departure') {
          await lifecycle.prepareToDeactivate();
        } else if (ending == 'dispose') {
          await tester.pumpWidget(const SizedBox());
        } else {
          frontend.invalidate();
          await tester.pumpAndSettle();
          expect(find.text('Frontend unavailable.'), findsOneWidget);
        }
        expect(port.handles, isEmpty);
        if (resolving) {
          resolution.complete();
        } else {
          snapshot.complete(_task(committed: _snapshot(path: 'departed.txt')));
        }
        await tester.pumpAndSettle();
        expect(find.textContaining('departed.txt'), findsNothing);
        expect(port.service.taskCalls, resolving ? 0 : 1);
        expect(port.handles, isEmpty);
        expect(port.releases, ['handle-1', 'handle-2']);
        if (ending == 'departure') {
          port.service.task = _task(committed: _snapshot(path: 'retry.txt'));
          await tester.tap(find.text('Retry'));
          await tester.pumpAndSettle();
          expect(find.text('retry.txt  [modified]'), findsOneWidget);
          expect(
            port.methods.last,
            changeSetSourceServiceSnapshotTaskChangesId,
          );
        }
        expect(tester.takeException(), isNull);
      });
    }
  }

  for (final target in ['Uncommitted changes', 'Task / Branch']) {
    testWidgets(
      '$target scope switch fences source callbacks and late feedback without duplicate admission',
      (tester) async {
        registerSource();
        final held = Completer<Map<String, Object?>>();
        source.pending = held.future;
        port.service.value = _snapshot();
        port.service.uncommitted = _uncommitted(
          unstaged: _snapshot(path: 'current.txt'),
        );
        port.service.task = _task(uncommitted: port.service.uncommitted);
        await mount(tester);
        final old = tester.widget<TextButton>(
          find.widgetWithText(TextButton, 'Open in Source'),
        );
        old.onPressed!();
        await tester.pumpAndSettle();
        await tester.tap(find.widgetWithText(TextButton, target));
        await tester.pumpAndSettle();
        expect(find.text('current.txt  [modified]'), findsOneWidget);
        expect(find.text('Opening in Source...'), findsOneWidget);
        old.onPressed!();
        expect(source.paths, ['notes.txt']);
        held.complete({'ok': false});
        await tester.pumpAndSettle();
        expect(find.text('Unable to open file in Source.'), findsNothing);
        old.onPressed!();
        await tester.pumpAndSettle();
        expect(source.paths, ['notes.txt']);
        await tester.tap(find.text('Open in Source'));
        await tester.pumpAndSettle();
        expect(source.paths, ['notes.txt', 'current.txt']);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'generated eval rejects incomplete Uncommitted layers and malformed nested values',
    (tester) async {
      await mount(tester);
      port.service.uncommitted = _uncommitted(
        staged: _snapshot(),
        unstaged: _snapshot(),
        conflicts: [_conflict()],
      );
      await tester.tap(find.widgetWithText(TextButton, 'Uncommitted changes'));
      await tester.pumpAndSettle();
      final wire = port.lastResponse! as Map<String, Object?>;
      for (final invalid in <Map<String, Object?>>[
        {...wire}..remove('staged'),
        {...wire}..remove('unstaged'),
        {...wire}..remove('conflicts'),
        {...wire, 'extra': true},
        {...wire, 'staged': null},
        {
          ...wire,
          'unstaged': {'files': 'invalid', 'layerReviewRevision': null},
        },
        {
          ...wire,
          'conflicts': [null],
        },
        for (final layer in ['staged', 'unstaged'])
          {
            ...wire,
            layer: {
              'layerReviewRevision': null,
              'files': [
                {...((wire[layer] as Map)['files'] as List).single as Map}
                  ..remove('detail'),
              ],
            },
          },
      ]) {
        port.wireResponse = invalid;
        await tester.tap(find.text('Refresh'));
        await tester.pumpAndSettle();
        expect(
          find.text('Unable to load uncommitted changes.'),
          findsOneWidget,
        );
        expect(find.text('notes.txt  [modified]'), findsNothing);
        expect(find.text('No uncommitted changes.'), findsNothing);
        expect(port.handles, isEmpty);
        port.wireResponse = null;
        await tester.tap(find.text('Retry'));
        await tester.pumpAndSettle();
        expect(find.text('notes.txt  [modified]'), findsNWidgets(2));
      }
      expect(
        port.methods.skip(1),
        everyElement(changeSetSourceServiceSnapshotUncommittedId),
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'generated eval rejects malformed Task components without partial results',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(900, 1000));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await mount(tester);
      port.service.task = _task(
        committed: _snapshot(),
        uncommitted: _uncommitted(
          staged: _snapshot(),
          unstaged: _snapshot(),
          conflicts: [_conflict()],
        ),
      );
      await tester.tap(find.widgetWithText(TextButton, 'Task / Branch'));
      await tester.pumpAndSettle();
      final wire = port.lastResponse! as Map<String, Object?>;
      final uncommitted = wire['uncommitted']! as Map<String, Object?>;
      final committed = wire['committed']! as Map<String, Object?>;
      final file = (committed['files']! as List).single as Map<String, Object?>;
      final hunk = (file['hunks']! as List).single as Map<String, Object?>;
      final line = (hunk['lines']! as List).first as Map<String, Object?>;
      for (final invalid in <Map<String, Object?>>[
        {...wire, 'extra': true},
        for (final field in ['committed', 'uncommitted']) ...[
          {...wire}..remove(field),
          {...wire, field: null},
          {...wire, field: 'invalid'},
          {...wire, field: <String, Object?>{}},
        ],
        for (final field in ['staged', 'unstaged', 'conflicts']) ...[
          {
            ...wire,
            'uncommitted': {...uncommitted}..remove(field),
          },
          {
            ...wire,
            'uncommitted': {...uncommitted, field: null},
          },
        ],
        {
          ...wire,
          'uncommitted': {
            ...uncommitted,
            'conflicts': [null],
          },
        },
        for (final layer in ['committed', 'staged', 'unstaged'])
          for (final bad in [
            {
              'layerReviewRevision': null,
              'files': [
                {...file}..remove('detail'),
              ],
            },
            {
              'layerReviewRevision': null,
              'files': [
                {
                  ...file,
                  'hunks': [
                    {
                      ...hunk,
                      'lines': [
                        {...line, 'noNewline': 'false'},
                      ],
                    },
                  ],
                },
              ],
            },
          ])
            if (layer == 'committed')
              {...wire, layer: bad}
            else
              {
                ...wire,
                'uncommitted': {...uncommitted, layer: bad},
              },
      ]) {
        port.wireResponse = invalid;
        await tester.tap(find.text('Refresh'));
        await tester.pumpAndSettle();
        expect(find.text('Unable to load task changes.'), findsOneWidget);
        expect(find.text('notes.txt  [modified]'), findsNothing);
        expect(find.text('No task changes.'), findsNothing);
        expect(port.handles, isEmpty);
        port.wireResponse = null;
        await tester.tap(find.text('Retry'));
        await tester.pumpAndSettle();
        expect(find.text('notes.txt  [modified]'), findsNWidgets(3));
      }
      expect(
        port.methods.skip(1),
        everyElement(changeSetSourceServiceSnapshotTaskChangesId),
      );
      expect(tester.takeException(), isNull);
    },
  );
}

const _reviewFailure =
    'Review change not confirmed. Refresh before trying again.';
const _reviewRefreshRequired = 'Refresh again before reviewing these changes.';

const _layerReviewCases = [
  (
    label: 'Approve All Unstaged',
    pendingMessage: 'Approving all unstaged changes...',
    operation: 'approveAllUnstaged',
    method: reviewApprovalHandlerServiceApproveAllUnstagedId,
    layer: 'unstaged',
    unapprove: false,
  ),
  (
    label: 'Unapprove All Staged',
    pendingMessage: 'Unapproving all staged changes...',
    operation: 'unapproveAllStaged',
    method: reviewApprovalHandlerServiceUnapproveAllStagedId,
    layer: 'staged',
    unapprove: true,
  ),
];

const _reviewActionLabels = [
  'Approve All Unstaged',
  'Unapprove All Staged',
  'Approve File',
  'Unapprove File',
  'Approve',
  'Unapprove',
];

List<TextButton> _reviewButtons(WidgetTester tester) => tester
    .widgetList<TextButton>(
      find.byWidgetPredicate(
        (widget) =>
            widget is TextButton &&
            widget.child is Text &&
            _reviewActionLabels.contains((widget.child! as Text).data),
      ),
    )
    .toList();

void _expectNoReviewActions() {
  for (final label in _reviewActionLabels) {
    expect(find.widgetWithText(TextButton, label), findsNothing);
  }
}

const _reviewCases = [
  (name: 'hunk', fileReview: false, changeKind: 'modified', hunks: 2),
  (name: 'modified file', fileReview: true, changeKind: 'modified', hunks: 2),
  (name: 'added file', fileReview: true, changeKind: 'added', hunks: 1),
  (name: 'empty added file', fileReview: true, changeKind: 'added', hunks: 0),
  (name: 'deleted file', fileReview: true, changeKind: 'deleted', hunks: 1),
  (
    name: 'empty deleted file',
    fileReview: true,
    changeKind: 'deleted',
    hunks: 0,
  ),
];

ChangeSetSnapshot _reviewSnapshot({
  String path = 'review.txt',
  String? revision = 'opaque:revision',
  String? fileRevision,
  String? layerRevision,
  String? commentIdentity,
  String changeKind = 'modified',
  String contentStatus = 'text',
  int hunks = 2,
}) => ChangeSetSnapshot(
  layerReviewRevision: layerRevision,
  files: [
    ChangedFile(
      relativePath: path,
      changeKind: changeKind,
      contentStatus: contentStatus,
      detail: null,
      reviewRevision: revision,
      fileReviewRevision: fileRevision,
      commentComparisonIdentity: commentIdentity,
      hunks: [
        for (var index = 0; index < hunks; index++)
          DiffHunk(
            oldStart: changeKind == 'added'
                ? 0
                : changeKind == 'deleted'
                ? 1 + index * 20
                : 10 + index * 20,
            oldCount: changeKind == 'added' ? 0 : 1,
            newStart: changeKind == 'added'
                ? 1 + index * 20
                : changeKind == 'deleted'
                ? 0
                : 10 + index * 20,
            newCount: changeKind == 'deleted' ? 0 : 1,
            lines: [
              if (changeKind != 'added')
                DiffLine(
                  kind: 'deletion',
                  text: 'old-$index',
                  noNewline: false,
                ),
              if (changeKind != 'deleted')
                DiffLine(
                  kind: 'addition',
                  text: 'new-$index',
                  noNewline: false,
                ),
            ],
          ),
      ],
    ),
  ],
);

ChangeSetSnapshot _snapshot({
  String path = 'notes.txt',
  String before = 'before',
  String after = 'after',
  String? commentIdentity,
}) => ChangeSetSnapshot(
  layerReviewRevision: null,
  files: [
    ChangedFile(
      relativePath: path,
      changeKind: 'modified',
      contentStatus: 'text',
      detail: null,
      reviewRevision: null,
      fileReviewRevision: null,
      commentComparisonIdentity: commentIdentity,
      hunks: [
        DiffHunk(
          oldStart: 3,
          oldCount: 2,
          newStart: 3,
          newCount: 2,
          lines: [
            const DiffLine(kind: 'context', text: 'shared', noNewline: false),
            DiffLine(kind: 'deletion', text: before, noNewline: false),
            DiffLine(kind: 'addition', text: after, noNewline: true),
          ],
        ),
      ],
    ),
  ],
);

UncommittedChangeSetSnapshot _uncommitted({
  ChangeSetSnapshot? staged,
  ChangeSetSnapshot? unstaged,
  List<ChangedFile> conflicts = const [],
}) => UncommittedChangeSetSnapshot(
  staged: staged ?? ChangeSetSnapshot(files: [], layerReviewRevision: null),
  unstaged: unstaged ?? ChangeSetSnapshot(files: [], layerReviewRevision: null),
  conflicts: conflicts,
);

ChangedFile _conflict() => ChangedFile(
  relativePath: 'conflict.txt',
  changeKind: 'conflicted',
  contentStatus: 'conflicted',
  detail: 'Unmerged index entries.',
  reviewRevision: null,
  fileReviewRevision: null,
  commentComparisonIdentity: null,
  hunks: [],
);

TaskChangeSetSnapshot _task({
  ChangeSetSnapshot? committed,
  UncommittedChangeSetSnapshot? uncommitted,
}) => TaskChangeSetSnapshot(
  committed:
      committed ?? ChangeSetSnapshot(files: [], layerReviewRevision: null),
  uncommitted: uncommitted ?? _uncommitted(),
);

ChangeSetSnapshot _commentSnapshot({
  String path = 'dir/notes [deleted] "two words".txt',
  String? identity = 'comparison:original',
  String changeKind = 'modified',
  String contentStatus = 'text',
  List<DiffHunk>? hunks,
}) => ChangeSetSnapshot(
  layerReviewRevision: null,
  files: [
    ChangedFile(
      relativePath: path,
      changeKind: changeKind,
      contentStatus: contentStatus,
      detail: null,
      reviewRevision: null,
      fileReviewRevision: null,
      commentComparisonIdentity: identity,
      hunks:
          hunks ??
          [
            DiffHunk(
              oldStart: 10,
              oldCount: 2,
              newStart: 20,
              newCount: 2,
              lines: const [
                DiffLine(
                  kind: 'context',
                  text: 'shared context',
                  noNewline: false,
                ),
                DiffLine(
                  kind: 'deletion',
                  text: 'removed line',
                  noNewline: false,
                ),
                DiffLine(kind: 'addition', text: 'added line', noNewline: true),
              ],
            ),
          ],
    ),
  ],
);

ReviewCommentAnchor _commentAnchor({
  String environmentId = 'canonical-environment',
  String path = 'dir/notes [deleted] "two words".txt',
  ReviewComparisonLayer layer = ReviewComparisonLayer.unstaged,
  ReviewComparisonSide side = ReviewComparisonSide.newSide,
  int startLine = 21,
  int? endLine,
  int lineIndex = 2,
  String identity = 'comparison:original',
  String excerpt = 'added line',
}) => ReviewCommentAnchor(
  environmentId: environmentId,
  relativePath: path,
  layer: layer,
  side: side,
  startLine: startLine,
  endLine: endLine ?? startLine,
  comparisonIdentity: identity,
  sourceExcerpt: excerpt,
  hunkIndex: 0,
  lineIndex: lineIndex,
);

PendingReviewComment _comment({
  String id = 'saved-1',
  String text = 'saved feedback',
  int version = 3,
  int sequence = 1,
  ReviewCommentAnchor? anchor,
}) => PendingReviewComment(
  id: id,
  anchor: anchor ?? _commentAnchor(),
  text: text,
  version: version,
  sequence: sequence,
);

Finder _lineComment(String excerpt) => find.descendant(
  of: find
      .ancestor(of: find.textContaining(excerpt), matching: find.byType(Row))
      .first,
  matching: find.widgetWithText(TextButton, 'Comment'),
);

Finder _savedCommentAction(String text, String action) => find.descendant(
  of: find.ancestor(of: find.text(text), matching: find.byType(Column)).first,
  matching: find.widgetWithText(TextButton, action),
);

ReviewSubmissionSummary _summary(PreparedReviewSubmission review) =>
    ReviewSubmissionSummary(
      submissionId: review.submissionId,
      status: review.status,
      commentCount: review.commentCount,
      schedulingAttempt: review.schedulingAttempt,
      occurrenceId: review.occurrenceId,
      runId: review.runId,
    );

PreparedReviewSubmission _preparedReview({
  String sessionId = 'canonical',
  String submissionId = 'review-1',
  ReviewSubmissionStatus status = ReviewSubmissionStatus.prepared,
  List<PendingReviewComment>? comments,
}) {
  final entries = comments ?? [_comment()];
  final value = SessionFeedbackSubmission(
    submissionId: submissionId,
    kind: SessionFeedbackKind.codeReview,
    comments: [
      for (final comment in entries)
        SessionFeedbackComment(
          id: comment.id,
          text: comment.text,
          sequence: comment.sequence,
          version: comment.version,
          anchor: SessionFeedbackAnchor(
            environmentId: comment.anchor.environmentId,
            relativePath: comment.anchor.relativePath,
            layer: SessionFeedbackComparisonLayer.values.byName(
              comment.anchor.layer.name,
            ),
            side: SessionFeedbackComparisonSide.values.byName(
              comment.anchor.side.name,
            ),
            startLine: comment.anchor.startLine,
            endLine: comment.anchor.endLine,
            comparisonIdentity: comment.anchor.comparisonIdentity,
            sourceExcerpt: comment.anchor.sourceExcerpt,
            hunkIndex: comment.anchor.hunkIndex,
            lineIndex: comment.anchor.lineIndex,
          ),
        ),
    ],
  );
  return PreparedReviewSubmission(
    sessionId: sessionId,
    submissionId: submissionId,
    canonicalPayload: encodeSessionFeedbackSubmission(value),
    status: status,
    commentCount: entries.length,
    schedulingAttempt:
        status.index >= ReviewSubmissionStatus.schedulingPending.index ? 1 : 0,
    occurrenceId: status.index >= ReviewSubmissionStatus.accepted.index
        ? 'occurrence-1'
        : null,
    runId: status == ReviewSubmissionStatus.scheduled ? 'run-1' : null,
  );
}

class _Feedback {
  _Feedback(this.events);
  final List<String> events;
  final calls =
      <({String method, String payload, String? occurrence, int? attempt})>[];
  bool available = false;
  bool canStart = true;
  String reason = 'Review submission unavailable.';
  final results = <String, Map<String, Object?>>{};
  final gates = <String, Future<Map<String, Object?>>>{};
  String? throwsOn;

  Future<Map<String, Object?>> invoke(
    String method,
    String session,
    String payload,
    String? occurrence,
    int? attempt,
  ) async {
    events.add(method);
    calls.add((
      method: method,
      payload: payload,
      occurrence: occurrence,
      attempt: attempt,
    ));
    final submission = decodeSessionFeedbackSubmission(payload);
    final pending = gates.remove(method);
    if (pending != null) return pending;
    if (throwsOn == method) throw StateError('private native feedback failure');
    return {
      'sessionId': session,
      'submissionId': submission.submissionId,
      'occurrenceId': occurrence ?? 'occurrence-1',
      'runId': method.contains('Run') ? 'run-1' : null,
      'status': method.contains('Run') ? 'scheduled' : 'accepted',
      ...?results[method],
    };
  }
}

// Actual compiled stock EVC plus a primitive public-bridge boundary. Native host
// authority and real durable storage are exercised by the application suite.
class _FeedbackPort extends SessionFeedbackDeclarations
    implements PreparedFrontendBridge {
  _FeedbackPort(this.feedback, this.sessionId);
  final _Feedback feedback;
  final String sessionId;
  final zone = Zone.current;

  @override
  void configureForRuntime(Runtime runtime) {
    const library = 'package:adele_ui/session_feedback_bridge.dart';
    runtime.registerBridgeFunc(
      library,
      'readSessionFeedbackAvailability',
      (_, _, _) => wrapStructuredBridgeData({
        'available': feedback.available,
        'canStart': feedback.canStart,
        'reason': feedback.reason,
      }),
    );
    for (final method in [
      'acceptSessionFeedback',
      'lookupSessionFeedback',
      'startSessionFeedbackRun',
      'lookupSessionFeedbackRun',
    ]) {
      runtime.registerBridgeFunc(library, method, (_, _, args) {
        final completion = Completer<$Value>();
        zone.run(() async {
          try {
            completion.complete(
              wrapStructuredBridgeData(
                await feedback.invoke(
                  method,
                  sessionId,
                  args[0]!.$value as String,
                  args.length > 1 ? args[1]!.$value as String : null,
                  args.length > 2 ? args[2]!.$value as int : null,
                ),
              ),
            );
          } on Object catch (error, stack) {
            completion.completeError(error, stack);
          }
        });
        return $Future<$Value>.wrap(completion.future);
      });
    }
  }

  @override
  void invalidate() {}
}

// Only native service behavior is substituted. The mounted EVC uses the actual
// generated client, generated native dispatcher and production owning bridge.
class _DraftBackend implements ReviewDraftService, AdeleRequestChannel {
  final _sessions = <String, List<PendingReviewComment>>{};
  final events = <String>[];
  final revisions = <String, int>{};
  final reviews = <String, PreparedReviewSubmission>{};
  final frozen = <String, List<PendingReviewComment>>{};
  final handoffGates = <String, Completer<void>>{};
  String? failBeforeHandoff;
  String? failAfterHandoff;
  String? preparationRejection;
  int submissionSequence = 0;
  final snapshots = <String>[];
  final creates =
      <({String sessionId, ReviewCommentAnchor anchor, String text})>[];
  final updates = <({String sessionId, String id, int version, String text})>[];
  final deletes = <({String sessionId, String id, int version})>[];
  final methods = <String>[];
  final payloads = <Map<String, Object?>>[];
  final _gates = <Completer<void>>[];
  final _snapshotGates = <Completer<ReviewDraftSnapshot>>[];
  final _sequences = <String, int>{};
  late final dispatcher = ReviewDraftServiceDispatcher(this, concurrent: true);
  bool active = true;
  Object? snapshotFailure;
  Object? mutationFailure;
  Object? afterMutationFailure;
  String? authoritativeText;
  Future<void>? _pendingMutation;
  Future<ReviewDraftSnapshot>? _pendingSnapshot;

  List<PendingReviewComment> comments([String sessionId = 'canonical']) =>
      _sessions.putIfAbsent(sessionId, () => []);

  Completer<void> holdMutation() {
    final gate = Completer<void>();
    _gates.add(gate);
    _pendingMutation = gate.future;
    return gate;
  }

  Completer<ReviewDraftSnapshot> holdSnapshot() {
    final gate = Completer<ReviewDraftSnapshot>();
    _snapshotGates.add(gate);
    _pendingSnapshot = gate.future;
    return gate;
  }

  @override
  Future<ReviewDraftSnapshot> snapshot(String sessionId) async {
    snapshots.add(sessionId);
    final pending = _pendingSnapshot;
    _pendingSnapshot = null;
    if (pending != null) return pending;
    if (snapshotFailure != null) throw snapshotFailure!;
    return ReviewDraftSnapshot(
      sessionId: sessionId,
      revision: revisions[sessionId] ?? 0,
      comments: comments(sessionId),
      currentReview: reviews[sessionId] == null
          ? null
          : _summary(reviews[sessionId]!),
    );
  }

  void _mutated(String sessionId) =>
      revisions.update(sessionId, (value) => value + 1, ifAbsent: () => 1);

  @override
  Future<PreparedReviewSubmission?> readReview(String sessionId) async =>
      reviews[sessionId];

  @override
  Future<ReviewPreparationResult> prepareReview(
    String sessionId,
    int expectedRevision,
  ) async {
    final rejection =
        preparationRejection ??
        (expectedRevision != (revisions[sessionId] ?? 0)
            ? 'stale_draft'
            : comments(sessionId).isEmpty
            ? 'empty_review'
            : (reviews[sessionId] != null &&
                  reviews[sessionId]!.status !=
                      ReviewSubmissionStatus.scheduled)
            ? 'review_conflict'
            : null);
    if (rejection != null) {
      return ReviewPreparationResult(
        submission: null,
        rejectionCode: rejection,
      );
    }
    frozen[sessionId] = List.of(comments(sessionId));
    final result = _preparedReview(
      sessionId: sessionId,
      submissionId: 'review-${++submissionSequence}',
      comments: frozen[sessionId],
    );
    _mutated(sessionId);
    reviews[sessionId] = result;
    return ReviewPreparationResult(submission: result, rejectionCode: null);
  }

  PreparedReviewSubmission _transition(
    String sessionId,
    String submissionId,
    ReviewSubmissionStatus from,
    ReviewSubmissionStatus to, {
    String? occurrenceId,
    String? runId,
  }) {
    final previous = reviews[sessionId]!;
    if (previous.submissionId != submissionId || previous.status != from) {
      throw StateError('private transition conflict');
    }
    return reviews[sessionId] = PreparedReviewSubmission(
      sessionId: sessionId,
      submissionId: submissionId,
      canonicalPayload: previous.canonicalPayload,
      commentCount: previous.commentCount,
      schedulingAttempt: to == ReviewSubmissionStatus.schedulingPending
          ? previous.schedulingAttempt + 1
          : previous.schedulingAttempt,
      status: to,
      occurrenceId: occurrenceId ?? previous.occurrenceId,
      runId: runId ?? previous.runId,
    );
  }

  @override
  Future<PreparedReviewSubmission> markDeliveryAttempted(
    String sessionId,
    String submissionId,
  ) async => _transition(
    sessionId,
    submissionId,
    ReviewSubmissionStatus.prepared,
    ReviewSubmissionStatus.deliveryPending,
  );

  @override
  Future<PreparedReviewSubmission> confirmAcceptance(
    String sessionId,
    String submissionId,
    String receiptSessionId,
    String occurrenceId,
  ) async {
    if (sessionId != receiptSessionId) throw StateError('foreign receipt');
    final previous = reviews[sessionId]!;
    if (previous.status == ReviewSubmissionStatus.accepted &&
        previous.occurrenceId == occurrenceId) {
      return previous;
    }
    final result = _transition(
      sessionId,
      submissionId,
      ReviewSubmissionStatus.deliveryPending,
      ReviewSubmissionStatus.accepted,
      occurrenceId: occurrenceId,
    );
    final ids = frozen[sessionId]!.map((comment) => comment.id).toSet();
    comments(sessionId).removeWhere((comment) => ids.contains(comment.id));
    _mutated(sessionId);
    return result;
  }

  @override
  Future<PreparedReviewSubmission> markSchedulingAttempted(
    String sessionId,
    String submissionId,
    String occurrenceId,
  ) async => _transition(
    sessionId,
    submissionId,
    ReviewSubmissionStatus.accepted,
    ReviewSubmissionStatus.schedulingPending,
    occurrenceId: occurrenceId,
  );

  @override
  Future<PreparedReviewSubmission> confirmRunScheduled(
    String sessionId,
    String submissionId,
    String occurrenceId,
    int expectedAttempt,
    String runId,
  ) async {
    if (reviews[sessionId]!.schedulingAttempt != expectedAttempt) {
      throw StateError('private old attempt');
    }
    return _transition(
      sessionId,
      submissionId,
      ReviewSubmissionStatus.schedulingPending,
      ReviewSubmissionStatus.scheduled,
      occurrenceId: occurrenceId,
      runId: runId,
    );
  }

  @override
  Future<PreparedReviewSubmission> confirmRunNotStarted(
    String sessionId,
    String submissionId,
    String occurrenceId,
    int expectedAttempt,
  ) async {
    if (reviews[sessionId]!.schedulingAttempt != expectedAttempt) {
      throw StateError('private old attempt');
    }
    return _transition(
      sessionId,
      submissionId,
      ReviewSubmissionStatus.schedulingPending,
      ReviewSubmissionStatus.accepted,
      occurrenceId: occurrenceId,
    );
  }

  Future<void> _admit() async {
    final pending = _pendingMutation;
    _pendingMutation = null;
    if (pending != null) await pending;
    if (mutationFailure != null) throw mutationFailure!;
  }

  @override
  Future<PendingReviewComment> createComment(
    String sessionId,
    ReviewCommentAnchor anchor,
    String text,
  ) async {
    creates.add((sessionId: sessionId, anchor: anchor, text: text));
    await _admit();
    final sequence = (_sequences[sessionId] ?? 100) + 1;
    _sequences[sessionId] = sequence;
    final result = _comment(
      id: 'authoritative-$sequence',
      anchor: anchor,
      text: authoritativeText ?? text,
      version: 1,
      sequence: sequence,
    );
    comments(sessionId).add(result);
    _mutated(sessionId);
    if (afterMutationFailure != null) throw afterMutationFailure!;
    return result;
  }

  @override
  Future<PendingReviewComment> updateComment(
    String sessionId,
    String commentId,
    int expectedVersion,
    String text,
  ) async {
    updates.add((
      sessionId: sessionId,
      id: commentId,
      version: expectedVersion,
      text: text,
    ));
    await _admit();
    final entries = comments(sessionId);
    final index = entries.indexWhere((comment) => comment.id == commentId);
    if (index < 0 || entries[index].version != expectedVersion) {
      throw const ReviewDraftFailure(
        code: 'stale_comment',
        message: 'private stale comment',
      );
    }
    final previous = entries[index];
    final result = _comment(
      id: previous.id,
      anchor: previous.anchor,
      text: authoritativeText ?? text,
      version: previous.version + 1,
      sequence: previous.sequence,
    );
    entries[index] = result;
    _mutated(sessionId);
    if (afterMutationFailure != null) throw afterMutationFailure!;
    return result;
  }

  @override
  Future<void> deleteComment(
    String sessionId,
    String commentId,
    int expectedVersion,
  ) async {
    deletes.add((
      sessionId: sessionId,
      id: commentId,
      version: expectedVersion,
    ));
    await _admit();
    final entries = comments(sessionId);
    final index = entries.indexWhere((comment) => comment.id == commentId);
    if (index < 0 || entries[index].version != expectedVersion) {
      throw const ReviewDraftFailure(
        code: 'stale_comment',
        message: 'private stale comment',
      );
    }
    entries.removeAt(index);
    _mutated(sessionId);
    if (afterMutationFailure != null) throw afterMutationFailure!;
  }

  @override
  Future<Object?> request(String method, Map<String, Object?> payload) async {
    methods.add(method);
    payloads.add(payload);
    events.add(method);
    final gate = handoffGates.remove(method);
    if (gate != null) await gate.future;
    if (failBeforeHandoff == method) {
      throw StateError('private handoff rejection');
    }
    final result = await dispatcher.dispatch({
      'kind': 'request',
      'requestId': methods.length,
      'method': method,
      'payload': payload,
    });
    if (result['ok'] != true) {
      throw StateError('private draft failure: ${result['error']}');
    }
    if (failAfterHandoff == method) {
      throw StateError('private lost handoff acknowledgement');
    }
    return result['payload'];
  }

  Future<void> close() async {
    for (final gate in _gates) {
      if (!gate.isCompleted) gate.complete();
    }
    for (final gate in _snapshotGates) {
      if (!gate.isCompleted) {
        gate.complete(
          ReviewDraftSnapshot(
            sessionId: 'canonical',
            revision: 0,
            comments: [],
            currentReview: null,
          ),
        );
      }
    }
    await dispatcher.close();
  }
}

class _Service implements ChangeSetSourceService {
  ChangeSetSnapshot value = ChangeSetSnapshot(
    files: [],
    layerReviewRevision: null,
  );
  UncommittedChangeSetSnapshot uncommitted = _uncommitted();
  TaskChangeSetSnapshot task = _task();
  Future<ChangeSetSnapshot>? pending;
  Future<UncommittedChangeSetSnapshot>? pendingUncommitted;
  Future<TaskChangeSetSnapshot>? pendingTask;
  bool failure = false;
  int calls = 0;
  int uncommittedCalls = 0;
  int taskCalls = 0;
  @override
  Future<ChangeSetSnapshot> snapshotUnstaged() async {
    calls++;
    final held = pending;
    pending = null;
    if (held != null) return held;
    if (failure) {
      throw const ChangeSetFailure(code: 'failed', message: 'private failure');
    }
    return value;
  }

  @override
  Future<UncommittedChangeSetSnapshot> snapshotUncommitted() async {
    uncommittedCalls++;
    final held = pendingUncommitted;
    pendingUncommitted = null;
    if (held != null) return held;
    if (failure) {
      throw const ChangeSetFailure(code: 'failed', message: 'private failure');
    }
    return uncommitted;
  }

  @override
  Future<TaskChangeSetSnapshot> snapshotTaskChanges() async {
    taskCalls++;
    final held = pendingTask;
    pendingTask = null;
    if (held != null) return held;
    if (failure) {
      throw const ChangeSetFailure(code: 'failed', message: 'private failure');
    }
    return task;
  }
}

class _Source {
  final List<String> paths = [];
  Future<Map<String, Object?>>? pending;
  bool failure = false;

  Future<Map<String, Object?>> display(String path) async {
    paths.add(path);
    final held = pending;
    pending = null;
    if (held != null) return held;
    if (failure) throw StateError('private source diagnostic');
    return {'ok': true, 'private': 'private source diagnostic'};
  }
}

class _ReviewProvider
    implements ReviewApprovalHandlerService, AdeleRequestChannel {
  // Replacements deliberately reuse this identity, never the captured object.
  final String id = 'test.review-provider';
  bool active = true;
  Object? failure;
  Future<void>? pending;
  final List<String> operations = [];
  final List<ReviewHunkSelection> selections = [];
  final List<ReviewFileSelection> fileSelections = [];
  final List<ReviewLayerSelection> layerSelections = [];
  final List<String> methods = [];
  final List<Map<String, Object?>> payloads = [];
  late final dispatcher = ReviewApprovalHandlerServiceDispatcher(
    this,
    concurrent: true,
  );

  Future<void> apply(String operation, Object selection) async {
    operations.add(operation);
    if (selection is ReviewFileSelection) {
      fileSelections.add(selection);
    } else if (selection is ReviewLayerSelection) {
      layerSelections.add(selection);
    } else {
      selections.add(selection as ReviewHunkSelection);
    }
    final held = pending;
    pending = null;
    if (held != null) await held;
    if (failure != null) throw failure!;
  }

  @override
  Future<void> approveHunk(ReviewHunkSelection selection) =>
      apply('approve', selection);

  @override
  Future<void> unapproveHunk(ReviewHunkSelection selection) =>
      apply('unapprove', selection);

  @override
  Future<void> approveFile(ReviewFileSelection selection) =>
      apply('approveFile', selection);

  @override
  Future<void> unapproveFile(ReviewFileSelection selection) =>
      apply('unapproveFile', selection);

  @override
  Future<void> approveAllUnstaged(ReviewLayerSelection selection) =>
      apply('approveAllUnstaged', selection);

  @override
  Future<void> unapproveAllStaged(ReviewLayerSelection selection) =>
      apply('unapproveAllStaged', selection);

  @override
  Future<Object?> request(String method, Map<String, Object?> payload) async {
    if (!active) throw StateError('private retired provider');
    expectSync(
      method,
      isIn([
        reviewApprovalHandlerServiceApproveHunkId,
        reviewApprovalHandlerServiceUnapproveHunkId,
        reviewApprovalHandlerServiceApproveFileId,
        reviewApprovalHandlerServiceUnapproveFileId,
        reviewApprovalHandlerServiceApproveAllUnstagedId,
        reviewApprovalHandlerServiceUnapproveAllStagedId,
      ]),
    );
    methods.add(method);
    payloads.add(payload);
    final result = await dispatcher.dispatch({
      'kind': 'request',
      'requestId': payloads.length,
      'method': method,
      'payload': payload,
    });
    if (!active) throw StateError('private retired provider');
    if (result['ok'] != true) {
      throw StateError('private review failure: ${result['error']}');
    }
    return result['payload'];
  }
}

// Test-only request port: real generated native/eval codecs and production
// settlement, but deliberately no host revocation so the pane's epoch is tested.
// Canonical contextual authority and AOT are covered by the app integration.
class _Port extends EnvironmentCapabilityAccessDeclarations
    implements PreparedFrontendBridge, AdeleRequestChannel {
  final _Service service = _Service();
  late final dispatcher = ChangeSetSourceServiceDispatcher(
    service,
    concurrent: true,
  );
  final Set<String> handles = {};
  final List<String> releases = [];
  final Map<String, _ReviewProvider> reviewHandles = {};
  final List<_ReviewProvider> reviewProviders = [_ReviewProvider()];
  _ReviewProvider get review => reviewProviders.last;
  String reviewAvailability = 'available';
  int reviewResolutions = 0;
  Future<void>? reviewResolving;
  final Zone zone = Zone.current;
  int resolutions = 0;
  bool available = true;
  bool active = true;
  Map<String, Object?>? wireResponse;
  Object? lastResponse;
  final List<String> methods = [];
  Future<void>? resolving;
  EnvironmentCapabilityDiagnostics? diagnostics;
  EnvironmentCapabilityDiagnostic? _requestDiagnostic;
  final Map<String, EnvironmentCapabilityDiagnostic?> _diagnosticRequests = {};
  final Map<String, int> _requestCounts = {};
  final List<String?> settlementHandles = [];
  late final transport = BackendInvocationBridge(
    channelFor: (handle) =>
        reviewHandles[handle] ?? (handles.contains(handle) ? this : null),
    validateAdmission: () {},
    validateSettlement: () {},
    isPresentationActive: () => active,
    beginDiagnostic: (method) => _requestDiagnostic = diagnostics?.begin(
      service: method.startsWith('$reviewApprovalHandlerServiceId.')
          ? reviewApprovalHandlerServiceId
          : changeSetSourceServiceId,
      method: method,
      provider: 'dev.adele.test.snapshot',
      environmentProvider: 'dev.adele.test.environment',
      grant: 'bufferedProcess',
    ),
  );

  @override
  void configureForRuntime(Runtime runtime) {
    const library = 'package:adele_ui/environment_capability_bridge.dart';
    runtime
      ..registerBridgeFunc(
        library,
        'resolveEnvironmentBufferedProcessCapabilityProvider',
        (_, _, args) {
          final isReview = args[0]!.$value == reviewApprovalCapability.id.value;
          expectSync(
            args[0]!.$value,
            isReview
                ? reviewApprovalCapability.id.value
                : changeSetSourceCapability.id.value,
          );
          expectSync(args[1]!.$value, 1);
          expectSync(
            args[2]!.$value,
            isReview
                ? reviewApprovalHandlerServiceId
                : changeSetSourceServiceId,
          );
          expectSync(args[3]!.$value, isNull);
          final handle = isReview
              ? 'review-${++reviewResolutions}'
              : 'handle-${++resolutions}';
          final wait = isReview ? reviewResolving : resolving;
          final provider = review;
          if (isReview) {
            reviewResolving = null;
          } else {
            resolving = null;
          }
          final completion = Completer<$Value>();
          zone.run(() async {
            if (wait != null) await wait;
            final eligible = isReview
                ? reviewAvailability == 'available' && provider.active
                : available;
            if (eligible) {
              handles.add(handle);
              if (isReview) reviewHandles[handle] = provider;
            }
            completion.complete(
              wrapStructuredBridgeData(eligible ? handle : null),
            );
          });
          return $Future<$Value>.wrap(completion.future);
        },
      )
      ..registerBridgeFunc(library, 'releaseEnvironmentCapabilityProvider', (
        _,
        _,
        args,
      ) {
        final handle = args[0]!.$value as String;
        final removed = handles.remove(handle);
        reviewHandles.remove(handle);
        if (removed) releases.add(handle);
        return $bool(removed);
      })
      ..registerBridgeFunc(library, 'requestEnvironmentCapability', (
        _,
        _,
        args,
      ) {
        final result = transport.evalRequest(runtime, args);
        final handle = args[0]!.$value as String;
        _requestCounts.update(handle, (count) => count + 1, ifAbsent: () => 1);
        _diagnosticRequests[handle] = _requestDiagnostic;
        return result;
      })
      ..registerBridgeFunc(library, 'settleEnvironmentCapabilityOperation', (
        _,
        _,
        args,
      ) {
        final handle = args.length > 1 ? args[1]?.$value as String? : null;
        settlementHandles.add(handle);
        return BackendInvocationBridge.settleOperation(
          runtime,
          args,
          diagnostic: _requestCounts[handle] == 1
              ? _diagnosticRequests[handle]
              : null,
        );
      });
  }

  void replaceReview() {
    review.active = false;
    reviewProviders.add(_ReviewProvider());
  }

  Future<void> close() async {
    await dispatcher.close();
    for (final provider in reviewProviders) {
      await provider.dispatcher.close();
    }
  }

  @override
  Future<Object?> request(String method, Map<String, Object?> payload) async {
    expectSync(
      method,
      isIn([
        changeSetSourceServiceSnapshotUnstagedId,
        changeSetSourceServiceSnapshotUncommittedId,
        changeSetSourceServiceSnapshotTaskChangesId,
      ]),
    );
    methods.add(method);
    expectSync(payload, isEmpty);
    if (wireResponse != null) return wireResponse;
    final result = await dispatcher.dispatch({
      'kind': 'request',
      'requestId': resolutions,
      'method': method,
      'payload': payload,
    });
    if (result['ok'] != true) throw StateError('private failure');
    return lastResponse = result['payload'];
  }

  @override
  void invalidate() {
    active = false;
    transport.invalidate();
  }
}

List<Map<String, dynamic>> _diagnosticRecords(List<String> lines) => [
  for (final line in lines)
    jsonDecode(line.substring('[adele.environment-capability] '.length))
        as Map<String, dynamic>,
];
