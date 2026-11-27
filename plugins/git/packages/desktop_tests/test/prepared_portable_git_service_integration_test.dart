@TestOn('linux')
@Timeout(Duration(minutes: 4))
library;

import 'dart:convert';
import 'dart:io';

import 'package:adele_capabilities/adele_capabilities.dart';
import 'package:adele_desktop/core/environment_capability_selection.dart';
import 'package:adele_desktop/core/product_lifecycle.dart';
import 'package:adele_desktop/core/project_storage_host.dart';
import 'package:adele_environment/adele_environment.dart';
import 'package:adele_plugin_api/adele_plugin_api.dart';
import 'package:adele_product/adele_product.dart';
import 'package:adele_project_storage/adele_project_storage.dart';
import 'package:diff_viewer_contract/diff_viewer_contract.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:git_backend/git_backend.dart';
import 'package:plugin_runtime/plugin_runtime.dart';

import '../../../../../app/test/support/portable_git_probe_assertions.dart';
import '../../../../../app/test/support/portable_git_review_repository.dart';
import '../../../../../app/test/support/prepared_environment_capability_installation.dart';
import '../../../../../app/test/support/prepared_portable_git.dart';

void main() {
  final suite = PreparedPortableGit(
    stock: false,
    repositoryRoot: Directory.current.parent.parent.parent.parent,
  );
  setUpAll(suite.prepare);
  tearDownAll(suite.close);

  testWidgets(
    'G6a independent approval stages one hunk and unapproves without crossing same-path repositories',
    (tester) async {
      final repositories = await suite.reviewRepositories(tester);
      final before = (await tester.runAsync(() => reviewStates(repositories)))!;
      final fixture = await suite.mount(
        tester,
        additionalRoot: repositories['additional'],
        primaryRoot: repositories['primary'],
        approvalGrant: true,
        approvalProviderPresent: true,
        concurrent: true,
      );
      expect(fixture.connection, isNot(same(fixture.environmentConnection)));
      final selected = (await tester.runAsync(
        () => CapturedEnvironmentCapabilities(
          environmentRuntime: fixture.environmentRuntime,
          backends: fixture.backends,
          session: fixture.sessionA,
        ).resolve(reviewApprovalCapability),
      ))!;
      expect(selected.environment.id, EnvironmentId('additional'));
      expect(selected.environment.role, EnvironmentRole.additional);
      expect(selected.binding.provider.id.value, portableApprovalProvider);
      expect(fixture.callableOwner.associationFor(selected.binding), isNull);
      for (final pane in ['a', 'b']) {
        pressPaneButton(tester, 'Select approval', pane: pane);
        await waitForPaneText(tester, 'approval-selected', pane: pane);
        // A client without a snapshot selection must remain non-actionable.
        pressPaneButton(tester, 'Approve', pane: pane);
        pressPaneButton(tester, 'Unapprove', pane: pane);
        await waitForPaneText(tester, 'approval:idle', pane: pane);
        await selectChangeSetSource(tester, pane: pane);
        pressPaneButton(tester, 'Uncommitted', pane: pane);
        final snapshot = await paneSnapshot(tester, pane: pane);
        expect(snapshot, contains('review.txt|modified|text'));
        expect(snapshot.split('\n@@'), hasLength(3));
        expect(
          snapshot,
          contains(
            'addition:${pane == 'a' ? 'additional' : 'primary'} first change:false',
          ),
        );
      }
      expect(
        await tester.runAsync(
          () =>
              semanticCalls(fixture, serviceId: reviewApprovalHandlerServiceId),
        ),
        isEmpty,
      );
      expect(await tester.runAsync(() => reviewStates(repositories)), before);
      pressPaneButton(tester, 'Approve');
      await waitForPaneText(tester, 'approval:success');
      final approved = (await tester.runAsync(
        () => reviewStates(repositories),
      ))!;
      expectReviewIndex(
        approved,
        before,
        'additional',
        reviewContent('additional', first: true),
      );
      final calls = (await tester.runAsync(
        () => semanticCalls(fixture, serviceId: reviewApprovalHandlerServiceId),
      ))!;
      expect(calls, hasLength(1));
      expect(calls.single['method'], reviewApprovalHandlerServiceApproveHunkId);
      final selection = (calls.single['payload'] as Map)['selection'] as Map;
      expect(calls.single['payload'], {'selection': selection});
      expect(selection, {
        'relativePath': 'review.txt',
        'hunkIndex': 0,
        'expectedRevision': isA<String>().having(
          (value) => value.isNotEmpty,
          'not empty',
          isTrue,
        ),
      });
      await tester.runAsync(
        () => expectBufferedDenial(
          fixture,
          calls.single['hostInvocationContext'] as String,
        ),
      );
      // The EVC retains the exact old DTO; duplicate submission must not replay.
      pressPaneButton(tester, 'Approve');
      await waitForPaneText(tester, 'approval:unavailable');
      expect(await tester.runAsync(() => reviewStates(repositories)), approved);
      final probe =
          (await tester.runAsync(() => fixture.control('snapshot')))! as Map;
      expect(probe['failures'], ['stale_selection']);

      pressPaneButton(tester, 'Uncommitted');
      final partial = await paneSnapshot(tester);
      final staged = partial.split('\nstaged')[1].split('\nunstaged')[0];
      final unstaged = partial.split('\nunstaged')[1].split('\nconflicts')[0];
      expect(staged.split('\n@@'), hasLength(2));
      expect(unstaged.split('\n@@'), hasLength(2));
      expect(staged, contains('addition:additional first change:false'));
      expect(staged, isNot(contains('second change')));
      expect(unstaged, contains('addition:additional second change:false'));
      expect(unstaged, isNot(contains('first change')));
      pressPaneButton(tester, 'Unapprove');
      await waitForPaneText(tester, 'approval:success');
      expect(await tester.runAsync(() => reviewStates(repositories)), before);
      pressPaneButton(tester, 'Unapprove');
      await waitForPaneText(tester, 'approval:unavailable');
      expect(await tester.runAsync(() => reviewStates(repositories)), before);
      final duplicate =
          (await tester.runAsync(() => fixture.control('snapshot')))! as Map;
      expect(duplicate['failures'], ['stale_selection', 'stale_selection']);
      final allCalls = (await tester.runAsync(
        () => semanticCalls(fixture, serviceId: reviewApprovalHandlerServiceId),
      ))!;
      expect(allCalls.map((call) => call['method']), [
        reviewApprovalHandlerServiceApproveHunkId,
        reviewApprovalHandlerServiceApproveHunkId,
        reviewApprovalHandlerServiceUnapproveHunkId,
        reviewApprovalHandlerServiceUnapproveHunkId,
      ]);
      expect(
        allCalls.map((call) => call['hostInvocationContext']).toSet(),
        hasLength(4),
      );
      expect(
        ((allCalls.last['payload'] as Map)['selection']
            as Map)['expectedRevision'],
        isNot(selection['expectedRevision']),
      );
      final evidence = (await tester.runAsync(fixture.snapshot))!;
      expect(reviewWrites(evidence), hasLength(2));
      for (final write in reviewWrites(evidence)) {
        expect(write['environmentId'], 'additional');
        expect(write['cwd'], repositories['additional']);
        expect(write['exitCode'], 0);
      }
      expect(evidence['reads'], isEmpty);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'G6c1 independent generated file methods preserve other entries and reject consumed selections',
    (tester) async {
      final repositories = await suite.reviewRepositories(
        tester,
        wholeFile: true,
      );
      final before = (await tester.runAsync(() => reviewStates(repositories)))!;
      final partial = fileReviewContent('additional', staged: true);
      final working = fileReviewContent(
        'additional',
        staged: true,
        changed: true,
      );
      final original = fileReviewContent('additional');
      final fixture = await suite.mount(
        tester,
        additionalRoot: repositories['additional'],
        primaryRoot: repositories['primary'],
        approvalGrant: true,
        approvalProviderPresent: true,
        baselineCommit: before['additional']!['head']! as String,
        expectedBranchRef: 'refs/heads/main',
      );
      expect(fixture.connection, isNot(same(fixture.environmentConnection)));
      await selectChangeSetSource(tester);
      pressPaneButton(tester, 'Select approval');
      await waitForPaneText(tester, 'approval-selected');
      pressPaneButton(tester, 'Approve File');
      pressPaneButton(tester, 'Unapprove File');
      await waitForPaneText(tester, 'approval:idle');
      expect(
        await tester.runAsync(
          () =>
              semanticCalls(fixture, serviceId: reviewApprovalHandlerServiceId),
        ),
        isEmpty,
      );
      pressPaneButton(tester, 'Uncommitted');
      final initial = await paneSnapshot(tester);
      expect(initial.split('\n@@'), hasLength(7));
      expect(initial, contains('addition:additional staged change:false'));
      expect(initial, contains('addition:additional inserted first:false'));
      expect(initial, contains('deletion:additional line 54:false'));
      expect(initial, contains('addition:additional final replacement:false'));
      expect(initial, isNot(contains('primary')));

      pressPaneButton(tester, 'Approve File');
      await waitForPaneText(tester, 'approval:success');
      final approved = (await tester.runAsync(
        () => reviewStates(repositories),
      ))!;
      expectReviewIndex(
        approved,
        before,
        'additional',
        working,
        originalContent: partial,
      );
      await tester.runAsync(() async {
        final root = Directory(repositories['additional']!);
        expect(
          await runGit(root, ['rev-parse', ':review.txt']),
          reviewBlobOid(working),
        );
        expect(
          await runGit(root, ['cat-file', 'blob', reviewBlobOid(working)]),
          working.trim(),
        );
      });
      pressPaneButton(tester, 'Approve File');
      await waitForPaneText(tester, 'approval:unavailable');
      expect(await tester.runAsync(() => reviewStates(repositories)), approved);

      pressPaneButton(tester, 'Task');
      final staged = await paneSnapshot(tester);
      expect(staged, startsWith('snapshot\ncommitted\nstaged\nreview.txt'));
      expect(staged.split('\nunstaged')[1], isNot(contains('review.txt')));
      expect(staged, contains('untouched.txt|modified|text'));
      expect(staged, contains('z-other.txt|modified|text'));
      pressPaneButton(tester, 'Unapprove File');
      await waitForPaneText(tester, 'approval:success');
      final unapproved = (await tester.runAsync(
        () => reviewStates(repositories),
      ))!;
      expectReviewIndex(
        unapproved,
        before,
        'additional',
        original,
        originalContent: partial,
      );
      pressPaneButton(tester, 'Unapprove File');
      await waitForPaneText(tester, 'approval:unavailable');
      expect(
        await tester.runAsync(() => reviewStates(repositories)),
        unapproved,
      );
      pressPaneButton(tester, 'Uncommitted');
      final refreshed = await paneSnapshot(tester);
      expect(
        refreshed.split('\nstaged')[1].split('\nunstaged')[0],
        isNot(contains('review.txt')),
      );
      expect(
        refreshed.split('\nunstaged')[1],
        contains('review.txt|modified|text'),
      );
      expect(refreshed, contains('addition:additional staged change:false'));

      final calls = (await tester.runAsync(
        () => semanticCalls(fixture, serviceId: reviewApprovalHandlerServiceId),
      ))!;
      expect(calls.map((call) => call['method']), [
        reviewApprovalHandlerServiceApproveFileId,
        reviewApprovalHandlerServiceApproveFileId,
        reviewApprovalHandlerServiceUnapproveFileId,
        reviewApprovalHandlerServiceUnapproveFileId,
      ]);
      expect(
        calls.map((call) => call['hostInvocationContext']).toSet(),
        hasLength(4),
      );
      for (final call in calls) {
        expect(call['payload'], {
          'selection': {
            'relativePath': 'review.txt',
            'expectedRevision': isA<String>().having(
              (value) => value.isNotEmpty,
              'not empty',
              isTrue,
            ),
          },
        });
        await tester.runAsync(
          () => expectBufferedDenial(
            fixture,
            call['hostInvocationContext'] as String,
          ),
        );
      }
      expect(
        (calls.first['payload'] as Map)['selection'],
        isNot((calls.last['payload'] as Map)['selection']),
      );
      final probe =
          (await tester.runAsync(() => fixture.control('snapshot')))! as Map;
      expect(probe['failures'], ['stale_selection', 'stale_selection']);
      final evidence = (await tester.runAsync(fixture.snapshot))!;
      final writes = reviewWrites(evidence);
      expect(writes, hasLength(2));
      final applies = (evidence['processes'] as List)
          .cast<Map<Object?, Object?>>()
          .where((process) => (process['arguments'] as List).contains('apply'));
      expect(
        applies.map(
          (process) => (process['arguments'] as List).contains('--check'),
        ),
        [true, false, true, false],
      );
      for (var i = 0; i < writes.length; i++) {
        final write = writes[i];
        expect(write['environmentId'], 'additional');
        expect(write['providerId'], 'test.environment.a');
        expect(write['cwd'], repositories['additional']);
        expect(write['exitCode'], 0);
        final patch = utf8.decode(base64Decode(write['stdinBase64'] as String));
        expect(
          RegExp(r'^@@ ', multiLine: true).allMatches(patch),
          hasLength(i == 0 ? 3 : 4),
        );
        expect(
          patch,
          contains(
            'index ${reviewBlobOid(i == 0 ? partial : original)}..${reviewBlobOid(working)} 100644',
          ),
        );
        expect(
          write['arguments'] as List,
          i == 0 ? isNot(contains('--reverse')) : contains('--reverse'),
        );
      }
      await tester.runAsync(() async {
        final root = Directory(repositories['additional']!);
        expect(
          await runGit(root, ['rev-parse', ':review.txt']),
          reviewBlobOid(original),
        );
        expect(
          await runGit(root, ['cat-file', 'blob', reviewBlobOid(original)]),
          original.trim(),
        );
        expect(
          await File('${root.path}/review.txt').readAsBytes(),
          utf8.encode(working),
        );
      });
      expect(evidence['reads'], isEmpty);
      expect(
        fixture.environmentRuntime.currentMaterialization(
          EnvironmentId('primary'),
        ),
        isNull,
      );
      debugPrint(
        'Independent file review verified index ${reviewBlobOid(partial)} -> '
        '${reviewBlobOid(working)} -> ${reviewBlobOid(original)}; '
        'unchanged HEAD=${before['additional']!['head']} '
        'ref=${before['additional']!['branch']}; '
        'unchanged working hashes, primary and unrelated index entries.',
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'G6c3a generated whole-layer methods apply one mixed patch and preserve exact selected repository state',
    (tester) async {
      final repositories = await suite.reviewRepositories(
        tester,
        wholeLayer: true,
      );
      final before = (await tester.runAsync(() => reviewStates(repositories)))!;
      expect(
        before['additional']!['index'],
        contains(
          '${reviewBlobOid(fileReviewContent('additional', staged: true))} 0\treview.txt\u0000',
        ),
      );
      final fixture = await suite.mount(
        tester,
        additionalRoot: repositories['additional'],
        primaryRoot: repositories['primary'],
        approvalGrant: true,
        approvalProviderPresent: true,
        baselineCommit: before['additional']!['head']! as String,
        expectedBranchRef: 'refs/heads/main',
      );
      expect(fixture.connection, isNot(same(fixture.environmentConnection)));
      pressPaneButton(tester, 'Select approval');
      await waitForPaneText(tester, 'approval-selected');
      pressPaneButton(tester, 'Approve All');
      pressPaneButton(tester, 'Unapprove All');
      await waitForPaneText(tester, 'approval:idle');
      expect(
        await tester.runAsync(
          () =>
              semanticCalls(fixture, serviceId: reviewApprovalHandlerServiceId),
        ),
        isEmpty,
      );
      await selectChangeSetSource(tester);
      pressPaneButton(tester, 'Uncommitted');
      final initial = await paneSnapshot(tester);
      expect(initial, contains('review.txt|modified|text'));
      expect(initial, contains('$newFileReviewPath|added|text'));
      expect(initial, contains('$deletedFileReviewPath|deleted|text'));
      expect(initial, contains('z-other.txt|modified|text'));
      expect(initial, contains('untouched.txt|modified|text'));
      expect(initial, isNot(contains('primary')));

      pressPaneButton(tester, 'Approve All');
      await waitForPaneText(tester, 'approval:success');
      final approved = (await tester.runAsync(
        () => reviewStates(repositories),
      ))!;
      expectLayerReviewIndex(approved, before, approved: true);
      expect(
        reviewWrites((await tester.runAsync(fixture.snapshot))!),
        hasLength(1),
      );
      pressPaneButton(tester, 'Approve All');
      await waitForPaneText(tester, 'approval:unavailable');
      expect(await tester.runAsync(() => reviewStates(repositories)), approved);

      // Task decoding must retain the same layer-only token, not select a file.
      pressPaneButton(tester, 'Task');
      final staged = await paneSnapshot(tester);
      expect(staged, startsWith('snapshot\ncommitted\nstaged\n'));
      expect(staged.split('\nunstaged')[1], '\nconflicts');
      pressPaneButton(tester, 'Approve All');
      await waitForPaneText(tester, 'approval:unavailable');
      expect(
        await tester.runAsync(
          () =>
              semanticCalls(fixture, serviceId: reviewApprovalHandlerServiceId),
        ),
        hasLength(2),
        reason: 'An empty layer has no actionable revision.',
      );
      pressPaneButton(tester, 'Unapprove All');
      await waitForPaneText(tester, 'approval:success');
      final unapproved = (await tester.runAsync(
        () => reviewStates(repositories),
      ))!;
      expectLayerReviewIndex(unapproved, before, approved: false);
      pressPaneButton(tester, 'Unapprove All');
      await waitForPaneText(tester, 'approval:unavailable');
      expect(
        await tester.runAsync(() => reviewStates(repositories)),
        unapproved,
      );
      pressPaneButton(tester, 'Uncommitted');
      final refreshed = await paneSnapshot(tester);
      expect(refreshed, startsWith('snapshot\nstaged\nunstaged\n'));
      expect(refreshed, contains('untouched.txt|modified|text'));
      expect(refreshed, contains('$newFileReviewPath|added|text'));
      expect(refreshed, contains('$deletedFileReviewPath|deleted|text'));
      pressPaneButton(tester, 'Unapprove All');
      await waitForPaneText(tester, 'approval:unavailable');

      final calls = (await tester.runAsync(
        () => semanticCalls(fixture, serviceId: reviewApprovalHandlerServiceId),
      ))!;
      expect(calls.map((call) => call['method']), [
        reviewApprovalHandlerServiceApproveAllUnstagedId,
        reviewApprovalHandlerServiceApproveAllUnstagedId,
        reviewApprovalHandlerServiceUnapproveAllStagedId,
        reviewApprovalHandlerServiceUnapproveAllStagedId,
      ]);
      expect(
        calls.map((call) => call['hostInvocationContext']).toSet(),
        hasLength(4),
      );
      for (final call in calls) {
        expect(call['payload'], {
          'selection': {
            'expectedRevision': isA<String>().having(
              (value) => value.isNotEmpty,
              'not empty',
              isTrue,
            ),
          },
        });
        await tester.runAsync(
          () => expectBufferedDenial(
            fixture,
            call['hostInvocationContext'] as String,
          ),
        );
      }
      expect(
        (calls.first['payload'] as Map)['selection'],
        isNot((calls.last['payload'] as Map)['selection']),
      );
      final probe =
          (await tester.runAsync(() => fixture.control('snapshot')))! as Map;
      expect(probe['failures'], ['stale_selection', 'stale_selection']);
      final evidence = (await tester.runAsync(fixture.snapshot))!;
      final applies = (evidence['processes'] as List)
          .cast<Map<Object?, Object?>>()
          .where((process) => (process['arguments'] as List).contains('apply'))
          .toList();
      expect(
        applies.map(
          (process) => (process['arguments'] as List).contains('--check'),
        ),
        [true, false, true, false],
      );
      final writes = reviewWrites(evidence);
      expect(writes, hasLength(2));
      for (var i = 0; i < writes.length; i++) {
        final write = writes[i];
        expect(write['environmentId'], 'additional');
        expect(write['providerId'], 'test.environment.a');
        expect(write['cwd'], repositories['additional']);
        expect(write['exitCode'], 0);
        expect(write['stdinBase64'], applies[i * 2]['stdinBase64']);
        expect(
          write['arguments'] as List,
          i == 0 ? isNot(contains('--reverse')) : contains('--reverse'),
        );
        final patch = utf8.decode(base64Decode(write['stdinBase64'] as String));
        expect(
          RegExp(r'^diff --git ', multiLine: true).allMatches(patch),
          hasLength(i == 0 ? 4 : 5),
        );
        for (final path in [
          'review.txt',
          'z-other.txt',
          newFileReviewPath,
          deletedFileReviewPath,
        ]) {
          expect(patch, contains(path));
        }
        expect(
          patch,
          i == 0 ? isNot(contains('untouched.txt')) : contains('untouched.txt'),
        );
      }
      await tester.runAsync(() async {
        final root = Directory(repositories['additional']!);
        expect(
          await runGit(root, ['diff', '--cached', '--exit-code']),
          isEmpty,
        );
        for (final entry in layerReviewContents(
          'additional',
          approved: false,
        ).entries) {
          expect(
            await runGit(root, ['show', ':${entry.key}'], trim: false),
            entry.value,
          );
        }
        expect(
          await File('${root.path}/$deletedFileReviewPath').exists(),
          isFalse,
        );
      });
      expect(evidence['reads'], isEmpty);
      expect(
        fixture.environmentRuntime.currentMaterialization(
          EnvironmentId('primary'),
        ),
        isNull,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  for (final reverse in [false, true]) {
    testWidgets(
      'G6c3a stale ${reverse ? 'staged' : 'unstaged'} layer rejects an external edit without any index write',
      (tester) async {
        final repositories = await suite.reviewRepositories(
          tester,
          wholeLayer: true,
        );
        final fixture = await suite.mount(
          tester,
          additionalRoot: repositories['additional'],
          primaryRoot: repositories['primary'],
          approvalGrant: true,
          approvalProviderPresent: true,
        );
        await selectChangeSetSource(tester);
        pressPaneButton(tester, 'Uncommitted');
        await paneSnapshot(tester);
        pressPaneButton(tester, 'Select approval');
        await waitForPaneText(tester, 'approval-selected');
        final before = (await tester.runAsync(() async {
          await File(
            '${repositories['additional']}/z-other.txt',
          ).writeAsString('external edit outside the first file\n');
          if (reverse) {
            await runGit(Directory(repositories['additional']!), [
              'add',
              '--',
              'z-other.txt',
            ]);
          }
          return reviewStates(repositories);
        }))!;
        pressPaneButton(tester, reverse ? 'Unapprove All' : 'Approve All');
        await waitForPaneText(tester, 'approval:unavailable');
        final probe =
            (await tester.runAsync(() => fixture.control('snapshot')))! as Map;
        expect(probe['failures'], ['stale_selection']);
        expect(
          reviewWrites((await tester.runAsync(fixture.snapshot))!),
          isEmpty,
        );
        expect(await tester.runAsync(() => reviewStates(repositories)), before);
        final calls = (await tester.runAsync(
          () =>
              semanticCalls(fixture, serviceId: reviewApprovalHandlerServiceId),
        ))!;
        expect(calls, hasLength(1));
        expect(
          calls.single['method'],
          reverse
              ? reviewApprovalHandlerServiceUnapproveAllStagedId
              : reviewApprovalHandlerServiceApproveAllUnstagedId,
        );
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }

  testWidgets(
    'G6a stale EVC selection rejects a working-tree edit without index or unrelated writes',
    (tester) async {
      final repositories = await suite.reviewRepositories(tester);
      final fixture = await suite.mount(
        tester,
        additionalRoot: repositories['additional'],
        primaryRoot: repositories['primary'],
        approvalGrant: true,
        approvalProviderPresent: true,
      );
      await selectChangeSetSource(tester);
      pressPaneButton(tester, 'Uncommitted');
      await paneSnapshot(tester);
      pressPaneButton(tester, 'Select approval');
      await waitForPaneText(tester, 'approval-selected');
      final before = (await tester.runAsync(() async {
        await File('${repositories['additional']}/review.txt').writeAsString(
          '${reviewContent('additional', first: true, second: true)}external edit\n',
        );
        return reviewStates(repositories);
      }))!;
      pressPaneButton(tester, 'Approve');
      await waitForPaneText(tester, 'approval:unavailable');
      final probe =
          (await tester.runAsync(() => fixture.control('snapshot')))! as Map;
      expect(probe['failures'], ['stale_selection']);
      expect(reviewWrites((await tester.runAsync(fixture.snapshot))!), isEmpty);
      expect(await tester.runAsync(() => reviewStates(repositories)), before);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  for (final (side, termination, fileAction, reverse, wholeLayer) in [
    for (final side in ['environment', 'callable'])
      for (final termination in [false, true])
        (side, termination, false, false, false),
    ('environment', false, true, false, false),
    ('callable', false, true, true, false),
    for (final termination in [false, true]) ...[
      ('environment', termination, false, false, true),
      ('callable', termination, false, true, true),
    ],
  ]) {
    final action = wholeLayer
        ? (reverse ? 'Unapprove All' : 'Approve All')
        : fileAction
        ? (reverse ? 'Unapprove File' : 'Approve File')
        : 'Approve';
    final method = wholeLayer
        ? (reverse ? 'unapproveAllStaged' : 'approveAllUnstaged')
        : fileAction
        ? (reverse ? 'unapproveFile' : 'approveFile')
        : 'approve';
    testWidgets(
      '${wholeLayer
          ? 'G6c3a $action'
          : fileAction
          ? 'G6c1 $action'
          : 'G6a'} $side ${termination ? 'backend' : 'provider'} retirement after effect suppresses success without replay or rollback',
      (tester) async {
        final repositories = await suite.reviewRepositories(
          tester,
          wholeLayer: wholeLayer,
        );
        if (reverse) {
          await tester.runAsync(
            () => runGit(Directory(repositories['additional']!), [
              'add',
              if (wholeLayer) '--all' else ...['--', 'review.txt'],
            ]),
          );
        }
        final before = (await tester.runAsync(
          () => reviewStates(repositories),
        ))!;
        final fixture = await suite.mount(
          tester,
          additionalRoot: repositories['additional'],
          primaryRoot: repositories['primary'],
          approvalGrant: true,
          approvalProviderPresent: true,
        );
        await selectChangeSetSource(tester);
        pressPaneButton(tester, 'Uncommitted');
        await paneSnapshot(tester);
        pressPaneButton(tester, 'Select approval');
        await waitForPaneText(tester, 'approval-selected');
        await tester.runAsync(
          () => fixture.control('hold', {'key': 'after:$method'}),
        );
        pressPaneButton(tester, action);
        await tester.runAsync(() => fixture.wait(tester, 'after:$method'));
        final token = (await tester.runAsync(
          () => invocationToken(
            fixture,
            serviceId: reviewApprovalHandlerServiceId,
          ),
        ))!;
        final stale = paneCallback(tester, action);
        final effected = (await tester.runAsync(
          () => reviewStates(repositories),
        ))!;
        if (wholeLayer) {
          expectLayerReviewIndex(effected, before, approved: !reverse);
        } else {
          expectReviewIndex(
            effected,
            before,
            'additional',
            reviewContent(
              'additional',
              first: !reverse,
              second: fileAction && !reverse,
            ),
            originalContent: reverse
                ? reviewContent('additional', first: true, second: true)
                : null,
          );
        }
        final evidence = (await tester.runAsync(fixture.snapshot))!;
        expect(reviewWrites(evidence), hasLength(1));
        expect(reviewWrites(evidence).single['exitCode'], 0);
        await waitForPaneText(tester, 'approval:pending');
        final target = side == 'environment'
            ? fixture.environmentConnection
            : fixture.connection;
        final survivor = side == 'environment'
            ? fixture.connection
            : fixture.environmentConnection;
        if (termination) {
          await tester.runAsync(() async {
            await expectLater(
              fixture.controlOn(target, 'terminate'),
              throwsA(isA<PluginRemoteFailure>()),
            );
            await target.terminated.timeout(portableGitWait);
          });
          expect(target.isClosed, isTrue);
          expect(survivor.isClosed, isFalse);
          expect(fixture.backends.host!.isClosed, isFalse);
        } else {
          final binding = fixture.capabilities.resolve(
            side == 'environment'
                ? environmentProviderCapability
                : reviewApprovalCapability,
            providerId: ProviderId(
              side == 'environment'
                  ? 'test.environment.a'
                  : portableApprovalProvider,
            ),
          );
          await tester.runAsync(
            () =>
                (side == 'environment'
                        ? fixture.environmentOwner
                        : fixture.callableOwner)
                    .retireProvider(binding),
          );
          expect(
            () => binding.requestChannel,
            throwsA(isA<ProviderUnavailable>()),
          );
          fixture.environmentOwner.validate();
          fixture.callableOwner.validate();
        }
        // Retirement revokes authority immediately, but does not cancel B's
        // admitted unary operation. Publication is checked after settlement.
        await tester.runAsync(() async {
          expect(
            await fixture.controlOn(survivor, 'attackBuffered', {
              'token': token,
              'method':
                  authorizedEnvironmentBufferedProcessServiceCapturedIdentityId,
              'arguments': <String, Object?>{},
            }),
            {'ok': false},
          );
          if (!termination || side == 'environment') {
            await expectBufferedDenial(fixture, token);
            expect(
              await fixture.control('retainedBufferedIdentity', {
                'key': 'approval',
              }),
              {'ok': false},
            );
            expect(await reviewStates(repositories), effected);
            await fixture.control('release', {'key': 'after:$method'});
            await fixture.wait(tester, 'settled:$method');
          }
        });
        await waitForPaneText(tester, 'approval:unavailable');
        stale();
        await waitForPaneText(tester, 'approval:unavailable');
        await tester.runAsync(() async {
          if (!termination || side == 'environment') {
            expect(
              await semanticCalls(
                fixture,
                serviceId: reviewApprovalHandlerServiceId,
              ),
              hasLength(1),
            );
          }
          if (!termination || side == 'callable') {
            final after =
                await fixture.controlOn(
                      fixture.environmentConnection,
                      'snapshot',
                    )
                    as Map<Object?, Object?>;
            expect(after['processes'], evidence['processes']);
          }
          expect(await reviewStates(repositories), effected);
        });
        expect(find.text('approval:success'), findsNothing);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }

  testWidgets(
    'G6c3a departure never retargets an effected whole-layer request to the primary Session',
    (tester) async {
      final repositories = await suite.reviewRepositories(
        tester,
        wholeLayer: true,
      );
      final before = (await tester.runAsync(() => reviewStates(repositories)))!;
      final fixture = await suite.mount(
        tester,
        additionalRoot: repositories['additional'],
        primaryRoot: repositories['primary'],
        approvalGrant: true,
        approvalProviderPresent: true,
      );
      await selectChangeSetSource(tester);
      pressPaneButton(tester, 'Uncommitted');
      await paneSnapshot(tester);
      pressPaneButton(tester, 'Select approval');
      await waitForPaneText(tester, 'approval-selected');
      await tester.runAsync(
        () => fixture.control('hold', {'key': 'after:approveAllUnstaged'}),
      );
      final stale = paneCallback(tester, 'Approve All');
      pressPaneButton(tester, 'Approve All');
      await tester.runAsync(
        () => fixture.wait(tester, 'after:approveAllUnstaged'),
      );
      final token = (await tester.runAsync(
        () =>
            invocationToken(fixture, serviceId: reviewApprovalHandlerServiceId),
      ))!;
      final effected = (await tester.runAsync(
        () => reviewStates(repositories),
      ))!;
      expectLayerReviewIndex(effected, before, approved: true);
      fixture.frontends.unbind(fixture.sessionA);
      await tester.pumpWidget(fixture.widget(session: fixture.sessionB));
      await tester.pumpAndSettle();
      stale();
      await tester.runAsync(() async {
        await expectBufferedDenial(fixture, token);
        await fixture.control('release', {'key': 'after:approveAllUnstaged'});
        await fixture.wait(tester, 'settled:approveAllUnstaged');
      });
      await selectChangeSetSource(tester);
      pressPaneButton(tester, 'Uncommitted');
      expect(
        await paneSnapshot(tester),
        contains('addition:primary inserted first:false'),
      );
      expect(find.text('approval:success'), findsNothing);
      expect(
        await tester.runAsync(
          () =>
              semanticCalls(fixture, serviceId: reviewApprovalHandlerServiceId),
        ),
        hasLength(1),
      );
      final writes = reviewWrites((await tester.runAsync(fixture.snapshot))!);
      expect(writes, hasLength(1));
      expect(writes.single['environmentId'], 'additional');
      expect(writes.single['cwd'], repositories['additional']);
      expect(await tester.runAsync(() => reviewStates(repositories)), effected);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  for (final wholeLayer in [false, true]) {
    final action = wholeLayer ? 'Approve All' : 'Approve';
    final reverseAction = wholeLayer ? 'Unapprove All' : 'Unapprove';
    final method = wholeLayer ? 'approveAllUnstaged' : 'approve';
    testWidgets(
      '${wholeLayer ? 'G6c3a' : 'G6a'} same-ID replacement requires fresh approval access and never replays an effected old request',
      (tester) async {
        final repositories = await suite.reviewRepositories(
          tester,
          wholeLayer: wholeLayer,
        );
        final before = (await tester.runAsync(
          () => reviewStates(repositories),
        ))!;
        var fixture = await suite.mount(
          tester,
          additionalRoot: repositories['additional'],
          primaryRoot: repositories['primary'],
          approvalGrant: true,
          approvalProviderPresent: true,
        );
        await selectChangeSetSource(tester);
        pressPaneButton(tester, 'Uncommitted');
        await paneSnapshot(tester);
        pressPaneButton(tester, 'Select approval');
        await waitForPaneText(tester, 'approval-selected');
        final old = fixture;
        final oldApproval = old.capabilities.resolve(
          reviewApprovalCapability,
          providerId: ProviderId(portableApprovalProvider),
        );
        final oldEnvironment = old.capabilities.resolve(
          environmentProviderCapability,
          providerId: ProviderId('test.environment.a'),
        );
        final stale = paneCallback(tester, action);
        await tester.runAsync(
          () => old.control('hold', {'key': 'after:$method'}),
        );
        pressPaneButton(tester, action);
        await tester.runAsync(() => old.wait(tester, 'after:$method'));
        final token = (await tester.runAsync(
          () => invocationToken(old, serviceId: reviewApprovalHandlerServiceId),
        ))!;
        final effected = (await tester.runAsync(
          () => reviewStates(repositories),
        ))!;
        if (wholeLayer) {
          expectLayerReviewIndex(effected, before, approved: true);
        } else {
          expectReviewIndex(
            effected,
            before,
            'additional',
            reviewContent('additional', first: true),
          );
        }
        expect(
          reviewWrites((await tester.runAsync(old.snapshot))!),
          hasLength(1),
        );
        await tester.runAsync(old.backends.close);
        await waitForPaneText(tester, 'approval:unavailable');
        fixture = await suite.mount(
          tester,
          additionalRoot: repositories['additional'],
          primaryRoot: repositories['primary'],
          approvalGrant: true,
          approvalProviderPresent: true,
          registry: old.capabilities,
          present: false,
        );
        expect(fixture.connection, isNot(same(old.connection)));
        expect(
          fixture.environmentConnection,
          isNot(same(old.environmentConnection)),
        );
        expect(
          fixture.capabilities
              .resolve(
                reviewApprovalCapability,
                providerId: ProviderId(portableApprovalProvider),
              )
              .isSameRegistration(oldApproval),
          isFalse,
        );
        expect(
          fixture.capabilities
              .resolve(
                environmentProviderCapability,
                providerId: ProviderId('test.environment.a'),
              )
              .isSameRegistration(oldEnvironment),
          isFalse,
        );
        stale();
        await waitForPaneText(tester, 'approval:unavailable');
        await tester.runAsync(() => expectBufferedDenial(fixture, token));
        expect(
          await tester.runAsync(
            () => semanticCalls(
              fixture,
              serviceId: reviewApprovalHandlerServiceId,
            ),
          ),
          isEmpty,
        );
        expect(
          (await tester.runAsync(fixture.snapshot))!['processes'],
          isEmpty,
        );
        expect(
          await tester.runAsync(() => reviewStates(repositories)),
          effected,
        );
        await tester.pumpWidget(fixture.widget());
        await tester.pumpAndSettle();
        await selectChangeSetSource(tester);
        pressPaneButton(tester, 'Uncommitted');
        await paneSnapshot(tester);
        pressPaneButton(tester, 'Select approval');
        await waitForPaneText(tester, 'approval-selected');
        pressPaneButton(tester, reverseAction);
        await waitForPaneText(tester, 'approval:success');
        final restored = (await tester.runAsync(
          () => reviewStates(repositories),
        ))!;
        if (wholeLayer) {
          expectLayerReviewIndex(restored, before, approved: false);
        } else {
          expect(restored, before);
        }
        final calls = (await tester.runAsync(
          () =>
              semanticCalls(fixture, serviceId: reviewApprovalHandlerServiceId),
        ))!;
        expect(calls, hasLength(1));
        expect(
          calls.single['method'],
          wholeLayer
              ? reviewApprovalHandlerServiceUnapproveAllStagedId
              : reviewApprovalHandlerServiceUnapproveHunkId,
        );
        expect(calls.single['hostInvocationContext'], isNot(token));
        expect(
          reviewWrites((await tester.runAsync(fixture.snapshot))!),
          hasLength(1),
        );
        await tester.runAsync(
          () => expectBufferedDenial(
            fixture,
            calls.single['hostInvocationContext'] as String,
          ),
        );
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }

  testWidgets(
    'persisted Task anchors select exact nonprimary and primary Environments and shared Sessions',
    (tester) async {
      final durable = await suite.openDurable(
        tester,
        initialAnchors: {
          'additional': GitTaskComparisonAnchor(
            baselineCommit: suite.selectedBaseline,
            expectedBranchRef: selectedBranchRef,
          ),
          'primary': GitTaskComparisonAnchor(
            baselineCommit: suite.primaryBaseline,
            expectedBranchRef: 'refs/heads/main',
          ),
        },
      );
      final fixture = await suite.mount(
        tester,
        registry: durable.registry,
        lifecycle: durable.lifecycle,
        present: false,
      );
      expect(fixture.connection.pluginId, gitPluginId);
      expect(fixture.connection, isNot(same(fixture.environmentConnection)));
      final database = durable.lifecycle.databaseForSession(
        fixture.sessionA.id,
      )!;
      expect(
        database
            .queryPluginRows(
              'SELECT owner_id, version FROM adele_schema_versions WHERE owner_id=:owner',
              {':owner': gitPluginId},
            )
            .map((row) => row.values),
        [
          {'owner_id': gitPluginId, 'version': 1},
        ],
      );
      final retained = anchorRows(durable.lifecycle);
      expect(retained, [
        {
          'environment_id': 'additional',
          'baseline_commit': suite.selectedBaseline,
          'expected_branch_ref': selectedBranchRef,
        },
        {
          'environment_id': 'primary',
          'baseline_commit': suite.primaryBaseline,
          'expected_branch_ref': 'refs/heads/main',
        },
      ]);
      expect((await tester.runAsync(fixture.snapshot))!['processes'], isEmpty);
      await tester.pumpWidget(fixture.widget(concurrent: true));
      await tester.pumpAndSettle();
      for (final pane in ['a', 'b']) {
        await selectChangeSetSource(tester, pane: pane);
        pressPaneButton(tester, 'Task', pane: pane);
        final snapshot = await paneSnapshot(tester, pane: pane);
        if (pane == 'a') {
          expectAdditionalSnapshot(snapshot, scope: 'Task');
        } else {
          expect(
            snapshot,
            startsWith('snapshot\ncommitted\nstaged\nunstaged\n'),
          );
          expect(snapshot, contains('primary-only.txt|modified|text'));
          expect(snapshot, contains('deletion:old primary:false'));
          expect(snapshot, contains('addition:new primary:false'));
          expect(snapshot, isNot(contains('committed-only.txt')));
        }
      }
      final selected = (await tester.runAsync(
        () => CapturedEnvironmentCapabilities(
          environmentRuntime: fixture.environmentRuntime,
          backends: fixture.backends,
          session: fixture.sessionA,
        ).resolve(changeSetCapability),
      ))!;
      expect(selected.environment.id, EnvironmentId('additional'));
      expect(selected.environment.role, EnvironmentRole.additional);
      expect(selected.binding.provider.id.value, gitChangeSetSourceProviderId);
      expect(fixture.callableOwner.associationFor(selected.binding), isNull);
      fixture.callableOwner.validateProviderOwnership(selected.binding);
      fixture.environmentOwner.validateProviderOwnership(
        selected.materialization.binding,
      );

      final sibling = durable.lifecycle.store.session(
        SessionId('shared-session'),
      )!;
      expect(sibling, isNot(same(fixture.sessionA)));
      expect(
        durable.lifecycle.store
            .requireSessionAuthority(sibling.id)
            .environmentId,
        EnvironmentId('additional'),
      );
      fixture.frontends.unbind(fixture.sessionA);
      fixture.frontends.unbind(fixture.sessionB);
      await tester.pumpWidget(fixture.widget(session: sibling));
      await tester.pumpAndSettle();
      await selectChangeSetSource(tester);
      pressPaneButton(tester, 'Task');
      expectAdditionalSnapshot(await paneSnapshot(tester), scope: 'Task');
      expect(anchorRows(durable.lifecycle), retained);
      final calls = (await tester.runAsync(() => semanticCalls(fixture)))!;
      expect(calls, hasLength(3));
      expect(
        calls.map((call) => call['hostInvocationContext']).toSet(),
        hasLength(3),
      );
      for (final call in calls) {
        expect(call['method'], snapshotMethod('Task'));
        expect(call['payload'], isEmpty);
        await tester.runAsync(
          () => expectBufferedDenial(
            fixture,
            call['hostInvocationContext'] as String,
          ),
        );
      }
      final evidence = (await tester.runAsync(fixture.snapshot))!;
      expect(evidence['reads'], isEmpty);
      final processes = (evidence['processes'] as List)
          .cast<Map<Object?, Object?>>();
      expect(processes.map((process) => process['environmentId']).toSet(), {
        'additional',
        'primary',
      });
      for (final process in processes) {
        expect(process['cwd'], suite.roots[process['environmentId']]);
      }
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'persisted missing anchor never borrows primary and leaves Unstaged and Uncommitted usable',
    (tester) async {
      final durable = await suite.openDurable(
        tester,
        initialAnchors: {
          'primary': GitTaskComparisonAnchor(
            baselineCommit: suite.primaryBaseline,
            expectedBranchRef: 'refs/heads/main',
          ),
        },
      );
      final fixture = await suite.mount(
        tester,
        registry: durable.registry,
        lifecycle: durable.lifecycle,
        present: false,
      );
      final retained = anchorRows(durable.lifecycle);
      await tester.pumpWidget(fixture.widget());
      await tester.pumpAndSettle();
      for (final label in ['Wrong service', 'Missing provider']) {
        pressPaneButton(tester, label);
        await waitForPaneText(tester, 'selection:unavailable');
      }
      expect(await tester.runAsync(() => semanticCalls(fixture)), isEmpty);
      await selectChangeSetSource(tester);
      pressPaneButton(tester, 'Task');
      await waitForPaneText(tester, 'snapshot:unavailable');
      final probe =
          (await tester.runAsync(() => fixture.control('snapshot')))! as Map;
      expect(probe['failures'], ['baseline_unavailable']);
      expect((await tester.runAsync(fixture.snapshot))!['processes'], isEmpty);
      for (final scope in ['Unstaged', 'Uncommitted']) {
        pressPaneButton(tester, scope);
        expectAdditionalSnapshot(await paneSnapshot(tester), scope: scope);
      }
      expect(anchorRows(durable.lifecycle), retained);
      final processes =
          ((await tester.runAsync(fixture.snapshot))!['processes'] as List)
              .cast<Map<Object?, Object?>>();
      expect(processes, isNotEmpty);
      expect(
        processes.every((process) => process['environmentId'] == 'additional'),
        isTrue,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'persisted Task replacement and durable reopen retain old baseline after HEAD changes without reenrollment',
    (tester) async {
      final repository = (await tester.runAsync(() async {
        final name = 'persisted-reopen-${suite.nextSequence()}';
        await runGit(suite.temporary, [
          'clone',
          '--no-hardlinks',
          suite.committedRoot,
          name,
        ]);
        return Directory(
          '${suite.temporary.path}/$name',
        ).resolveSymbolicLinks();
      }))!;
      final durable = await suite.openDurable(
        tester,
        additionalRoot: repository,
        initialAnchors: {
          'additional': GitTaskComparisonAnchor(
            baselineCommit: suite.selectedBaseline,
            expectedBranchRef: selectedBranchRef,
          ),
        },
      );
      var fixture = await suite.mount(
        tester,
        registry: durable.registry,
        lifecycle: durable.lifecycle,
        additionalRoot: repository,
        present: false,
      );
      final identity = AuthorizedEnvironmentIdentity(
        sessionId: 'nonprimary-session',
        environmentId: 'additional',
      );
      final anchors = _anchorStore(durable.lifecycle, fixture);
      final retained = anchorRows(durable.lifecycle);
      await tester.pumpWidget(fixture.widget());
      await tester.pumpAndSettle();
      await selectChangeSetSource(tester);
      final old = fixture;
      final oldBinding = old.capabilities.resolve(
        changeSetCapability,
        providerId: ProviderId(gitChangeSetSourceProviderId),
      );
      final stale = paneCallback(tester, 'Task');
      await tester.runAsync(
        () => old.control('hold', {'key': 'process:completed'}),
      );
      pressPaneButton(tester, 'Task');
      await tester.runAsync(() => old.wait(tester, 'process:completed'));
      final token = (await tester.runAsync(() => invocationToken(old)))!;
      await tester.runAsync(() async {
        await expectBufferedDenial(
          old,
          token,
          service: projectStorageServiceId,
          method: projectStorageServiceQueryForSessionId,
          arguments: {
            'sessionId': identity.sessionId,
            'sql': 'SELECT 1',
            'parameters': <String, Object?>{},
            'accessMode': 'durable',
          },
        );
        expect(
          await old.controlOn(old.environmentConnection, 'attackBuffered', {
            'token': token,
          }),
          {'ok': false},
        );
        await old.backends.close();
        await expectLater(anchors.read(identity), throwsA(isA<Exception>()));
      });
      await waitForPaneText(tester, 'snapshot:unavailable');
      fixture = await suite.mount(
        tester,
        registry: durable.registry,
        lifecycle: durable.lifecycle,
        additionalRoot: repository,
        present: false,
      );
      expect(fixture.connection, isNot(same(old.connection)));
      expect(
        fixture.capabilities
            .resolve(
              changeSetCapability,
              providerId: ProviderId(gitChangeSetSourceProviderId),
            )
            .isSameRegistration(oldBinding),
        isFalse,
      );
      stale();
      await waitForPaneText(tester, 'snapshot:unavailable');
      await tester.runAsync(() => expectBufferedDenial(fixture, token));
      expect(await tester.runAsync(() => semanticCalls(fixture)), isEmpty);
      expect((await tester.runAsync(fixture.snapshot))!['processes'], isEmpty);
      await tester.pumpWidget(fixture.widget());
      await tester.pumpAndSettle();
      await selectChangeSetSource(tester);
      pressPaneButton(tester, 'Task');
      expectCommittedSnapshot(await paneSnapshot(tester));
      expect(anchorRows(durable.lifecycle), retained);
      final oldSession = fixture.sessionA;
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(() async {
        await fixture.close();
        await old.close();
        await durable.lifecycle.close();
        final root = Directory(repository);
        await File(
          '$repository/after-enrollment.txt',
        ).writeAsString('committed after enrollment\n');
        await runGit(root, ['add', '--all']);
        await runGit(root, [
          '-c',
          'user.name=Fixture',
          '-c',
          'user.email=fixture@example.invalid',
          'commit',
          '-m',
          'after enrollment',
        ]);
        expect(
          await runGit(root, ['rev-parse', 'HEAD']),
          isNot(suite.selectedBaseline),
        );
      });
      final reopened = await suite.openDurable(
        tester,
        backing: durable.backing,
      );
      expect(anchorRows(reopened.lifecycle), retained);
      fixture = await suite.mount(
        tester,
        registry: reopened.registry,
        lifecycle: reopened.lifecycle,
        additionalRoot: repository,
      );
      expect(fixture.sessionA, isNot(same(oldSession)));
      expect(fixture.sessionA.id, oldSession.id);
      expect((await tester.runAsync(fixture.snapshot))!['processes'], isEmpty);
      await selectChangeSetSource(tester);
      pressPaneButton(tester, 'Uncommitted');
      await waitForPaneText(tester, 'snapshot\nstaged\nunstaged\nconflicts');
      pressPaneButton(tester, 'Task');
      final snapshot = await paneSnapshot(tester);
      expectCommittedSnapshot(snapshot);
      expect(snapshot, contains('after-enrollment.txt|added|text'));
      expect(snapshot, contains('addition:committed after enrollment:false'));
      expect(snapshot, endsWith('\nstaged\nunstaged\nconflicts'));
      expect(anchorRows(reopened.lifecycle), retained);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'persisted temporary volatile Project retains its anchor across AOT replacement without reenrollment',
    (tester) async {
      // Reuse the harness's canonical volatile graph, without opening a Project
      // provider or starting this seed installation's backend/frontend owners.
      final seed = PreparedEnvironmentCapabilityInstallation(
        files: suite.temporary,
        independent: true,
        sourceLocation: Uri.parse('test:/volatile-portable-git'),
        environments: [
          for (final id in ['additional', 'primary'])
            Environment(
              id: EnvironmentId(id),
              taskId: TaskId('task'),
              role: id == 'additional'
                  ? EnvironmentRole.additional
                  : EnvironmentRole.primary,
              providerId: ProviderId(
                'test.environment.${id == 'additional' ? 'a' : 'b'}',
              ),
              providerState: {'root': suite.roots[id]},
            ),
        ],
      );
      addTearDown(seed.close);
      final lifecycle = ProductLifecycleCoordinator.generated(
        store: seed.environmentRuntime.store,
        registry: seed.capabilities,
        extensions: seed.extensions,
      );
      addTearDown(lifecycle.close);
      expect(lifecycle.databaseForSession(seed.sessionA.id), isNull);
      var fixture = await suite.mount(
        tester,
        registry: seed.capabilities,
        lifecycle: lifecycle,
        present: false,
      );
      final identity = AuthorizedEnvironmentIdentity(
        sessionId: fixture.sessionA.id.value,
        environmentId: 'additional',
      );
      final anchors = _anchorStore(lifecycle, fixture);
      await tester.runAsync(
        () => anchors.enrollForEnvironment(
          environmentId: identity.environmentId,
          anchor: GitTaskComparisonAnchor(
            baselineCommit: suite.selectedBaseline,
            expectedBranchRef: selectedBranchRef,
          ),
        ),
      );
      final database = lifecycle.databaseForSession(
        fixture.sessionA.id,
        accessMode: ProjectStorageAccessMode.durableOrTemporary,
      )!;
      final backing = File(database.path);
      expect(backing.existsSync(), isTrue);
      expect(database.path, isNot(startsWith(suite.temporary.absolute.path)));
      expect(lifecycle.databaseForSession(fixture.sessionA.id), isNull);
      await tester.pumpWidget(fixture.widget());
      await tester.pumpAndSettle();
      await selectChangeSetSource(tester);
      pressPaneButton(tester, 'Task');
      expectAdditionalSnapshot(await paneSnapshot(tester), scope: 'Task');

      final old = fixture;
      final oldBinding = old.capabilities.resolve(
        changeSetCapability,
        providerId: ProviderId(gitChangeSetSourceProviderId),
      );
      final token = (await tester.runAsync(() => invocationToken(old)))!;
      final stale = paneCallback(tester, 'Task');
      await tester.runAsync(() async {
        await old.backends.close();
        await expectLater(anchors.read(identity), throwsA(isA<Exception>()));
      });
      fixture = await suite.mount(
        tester,
        registry: seed.capabilities,
        lifecycle: lifecycle,
        present: false,
      );
      expect(fixture.connection, isNot(same(old.connection)));
      expect(
        fixture.capabilities
            .resolve(
              changeSetCapability,
              providerId: ProviderId(gitChangeSetSourceProviderId),
            )
            .isSameRegistration(oldBinding),
        isFalse,
      );
      stale();
      await waitForPaneText(tester, 'snapshot:unavailable');
      await tester.runAsync(() => expectBufferedDenial(fixture, token));
      expect(await tester.runAsync(() => semanticCalls(fixture)), isEmpty);
      expect((await tester.runAsync(fixture.snapshot))!['processes'], isEmpty);
      expect(
        lifecycle.databaseForSession(
          fixture.sessionA.id,
          accessMode: ProjectStorageAccessMode.durableOrTemporary,
        ),
        same(database),
      );
      expect(backing.existsSync(), isTrue);
      final retained = (await tester.runAsync(
        () => _anchorStore(lifecycle, fixture).read(identity),
      ))!;
      expect(retained.baselineCommit, suite.selectedBaseline);
      expect(retained.expectedBranchRef, selectedBranchRef);
      expect(lifecycle.databaseForSession(fixture.sessionA.id), isNull);
      await tester.pumpWidget(fixture.widget());
      await tester.pumpAndSettle();
      await selectChangeSetSource(tester);
      pressPaneButton(tester, 'Task');
      expectAdditionalSnapshot(await paneSnapshot(tester), scope: 'Task');
      final calls = (await tester.runAsync(() => semanticCalls(fixture)))!;
      expect(calls, hasLength(1));
      expect(calls.single['method'], snapshotMethod('Task'));
      expect(calls.single['payload'], isEmpty);
      expect(calls.single['hostInvocationContext'], isNot(token));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(() async {
        await fixture.close();
        await old.close();
        await lifecycle.close();
      });
      expect(backing.parent.existsSync(), isFalse);
    },
  );

  for (final scope in ['Unstaged', 'Uncommitted', 'Task']) {
    testWidgets(
      'real independent AOT repositories produce typed nonprimary EVC $scope changes',
      (tester) async {
        final fixture = await suite.mount(tester, concurrent: true);
        expect(fixture.connection, isNot(same(fixture.environmentConnection)));
        final selected = (await tester.runAsync(
          () => CapturedEnvironmentCapabilities(
            environmentRuntime: fixture.environmentRuntime,
            backends: fixture.backends,
            session: fixture.sessionA,
          ).resolve(changeSetCapability),
        ))!;
        expect(selected.environment.id.value, 'additional');
        expect(selected.environment.role, EnvironmentRole.additional);
        expect(
          selected.materialization.binding.provider.id.value,
          'test.environment.a',
        );
        expect(selected.binding.provider.id.value, 'test.callable.a');
        expect(fixture.callableOwner.associationFor(selected.binding), isNull);
        fixture.environmentOwner.validateProviderOwnership(
          selected.materialization.binding,
        );
        fixture.callableOwner.validateProviderOwnership(selected.binding);
        expect(
          () => fixture.environmentOwner.validateProviderOwnership(
            selected.binding,
          ),
          throwsStateError,
        );
        await selectChangeSetSource(tester);
        await selectChangeSetSource(tester, pane: 'b');
        final elapsed = Stopwatch()..start();
        pressPaneButton(tester, scope);
        final additional = await paneSnapshot(tester);
        elapsed.stop();
        expectAdditionalSnapshot(additional, scope: scope);
        final selectedCalls = (await tester.runAsync(
          () => semanticCalls(fixture),
        ))!;
        expect(selectedCalls, hasLength(1));
        expect(selectedCalls.single['method'], snapshotMethod(scope));
        expect(selectedCalls.single['payload'], isEmpty);
        final selectedEvidence = (await tester.runAsync(fixture.snapshot))!;
        final selectedProcesses = (selectedEvidence['processes'] as List)
            .cast<Map<Object?, Object?>>();
        expect(selectedProcesses, isNotEmpty);
        expect(
          selectedProcesses.every(
            (process) => process['environmentId'] == 'additional',
          ),
          isTrue,
        );
        debugPrint(
          'Prepared portable $scope layered fixture: '
          '${selectedProcesses.length} process requests, '
          '${elapsed.elapsedMilliseconds} ms (diagnostic only).',
        );
        pressPaneButton(tester, scope, pane: 'b');
        if (scope == 'Task') {
          // The single fixed B anchor belongs to the selected repository, not
          // this unrelated primary. No inference, substitution, or clean result.
          await waitForPaneText(tester, 'snapshot:unavailable', pane: 'b');
          expect(
            inPane('b', find.textContaining('primary-only.txt|')),
            findsNothing,
          );
          final probe =
              (await tester.runAsync(() => fixture.control('snapshot')))!
                  as Map;
          expect(probe['failures'], ['baseline_unavailable']);
        } else {
          final primary = await paneSnapshot(tester, pane: 'b');
          expect(
            primary,
            contains('primary-only.txt|modified|text\n@@1,1:1,1'),
          );
          expect(primary, contains('deletion:old primary:false'));
          expect(primary, contains('addition:new primary:false'));
          expect(primary, isNot(contains('selected')));
          expect(primary, isNot(contains('partial.txt')));
          expect(primary, isNot(contains('conflicted.txt')));
          if (scope == 'Uncommitted') {
            expect(
              primary,
              startsWith('snapshot\nstaged\nunstaged\nprimary-only.txt|'),
            );
            expect(primary, endsWith('\nconflicts'));
          }
        }
        final evidence = (await tester.runAsync(fixture.snapshot))!;
        expect(evidence['reads'], isEmpty);
        final processes = (evidence['processes'] as List)
            .cast<Map<Object?, Object?>>();
        expect(processes, isNotEmpty);
        final primaryProcesses = processes.skip(selectedProcesses.length);
        expect(primaryProcesses, isNotEmpty);
        expect(
          primaryProcesses.every(
            (process) => process['environmentId'] == 'primary',
          ),
          isTrue,
        );
        for (final process in processes) {
          expect(process['cwd'], suite.roots[process['environmentId']]);
          expect(process['exitCode'], isA<int>());
          expect(
            process['providerId'],
            process['environmentId'] == 'additional'
                ? 'test.environment.a'
                : 'test.environment.b',
          );
        }
        final calls = await tester.runAsync(() => semanticCalls(fixture));
        expect(calls, hasLength(2));
        expect(
          calls!.map((call) => call['hostInvocationContext']).toSet(),
          hasLength(2),
        );
        for (final call in calls) {
          expect(call['method'], snapshotMethod(scope));
          expect(call['payload'], isEmpty);
          await tester.runAsync(
            () => expectBufferedDenial(
              fixture,
              call['hostInvocationContext'] as String,
            ),
          );
        }
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }

  for (final count in [100, 160, 500, 900]) {
    testWidgets(
      'clean nonprimary prepared snapshots batch $count files across backends',
      (tester) async {
        final repository = (await tester.runAsync(() async {
          final root = await Directory(
            '${suite.temporary.path}/scaling-$count',
          ).create();
          await runGit(root, ['init', '--initial-branch=main']);
          await Directory('${root.path}/tracked').create();
          for (var i = 0; i < count; i++) {
            await File(
              '${root.path}/tracked/file $i.txt',
            ).writeAsString('clean selected $i\n');
          }
          await runGit(root, ['add', '--all']);
          await runGit(root, [
            '-c',
            'user.name=Fixture',
            '-c',
            'user.email=fixture@example.invalid',
            'commit',
            '-m',
            'baseline',
          ]);
          return root.resolveSymbolicLinks();
        }))!;
        final baseline = (await tester.runAsync(
          () => runGit(Directory(repository), ['rev-parse', 'HEAD']),
        ))!;
        var fixture = await suite.mount(
          tester,
          additionalRoot: repository,
          baselineCommit: baseline,
          expectedBranchRef: 'refs/heads/main',
        );
        expect(fixture.connection, isNot(same(fixture.environmentConnection)));
        await selectChangeSetSource(tester);
        var previousProcessCount = 0;
        var semanticCallCount = 0;
        var comparisonTaskMilliseconds = 0;
        var comparisonTaskProcesses = 0;
        for (final scope in ['Unstaged', 'Uncommitted', 'Task']) {
          final elapsed = Stopwatch()..start();
          pressPaneButton(tester, scope);
          await waitForPaneText(tester, switch (scope) {
            'Unstaged' => 'snapshot',
            'Task' => 'snapshot\ncommitted\nstaged\nunstaged\nconflicts',
            _ => 'snapshot\nstaged\nunstaged\nconflicts',
          });
          elapsed.stop();
          final evidence = (await tester.runAsync(fixture.snapshot))!;
          expect(evidence['reads'], isEmpty);
          final processes = (evidence['processes'] as List)
              .cast<Map<Object?, Object?>>();
          final requests = (evidence['requests'] as List)
              .cast<Map<Object?, Object?>>()
              .where(
                (request) =>
                    request['method'] ==
                    environmentProviderServiceRunBufferedProcessId,
              );
          expect(requests, hasLength(processes.length));
          final processCount = processes.length - previousProcessCount;
          if (scope == 'Task') {
            comparisonTaskMilliseconds = elapsed.elapsedMilliseconds;
            comparisonTaskProcesses = processCount;
          }
          final batches = (count + 127) ~/ 128;
          if (scope == 'Unstaged') {
            expect(processCount, 21 + 4 * batches);
          } else if (scope == 'Uncommitted') {
            expect(processCount, 27 + 4 * batches);
          } else {
            // Fixed anchor/tree validation plus the same working-file batches.
            // No subprocess per clean tracked object is permitted.
            expect(processCount, lessThanOrEqualTo(40 + 4 * batches));
          }
          debugPrint(
            'Prepared portable $scope $count clean files: '
            '$processCount process requests, '
            '${elapsed.elapsedMilliseconds} ms (diagnostic only).',
          );
          for (final process in processes) {
            expect(process['environmentId'], 'additional');
            expect(process['providerId'], 'test.environment.a');
            expect(process['cwd'], repository);
            expect(process['exitCode'], 0);
          }
          final calls = (await tester.runAsync(() => semanticCalls(fixture)))!;
          expect(calls, hasLength(++semanticCallCount));
          expect(calls.last['method'], snapshotMethod(scope));
          expect(calls.last['payload'], isEmpty);
          expect(
            calls.map((call) => call['hostInvocationContext']).toSet(),
            hasLength(semanticCallCount),
          );
          await tester.runAsync(
            () => expectBufferedDenial(
              fixture,
              calls.last['hostInvocationContext'] as String,
            ),
          );
          previousProcessCount = processes.length;
        }
        if (count >= 500) {
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.runAsync(fixture.close);
          final durable = await suite.openDurable(
            tester,
            additionalRoot: repository,
            initialAnchors: {
              'additional': GitTaskComparisonAnchor(
                baselineCommit: baseline,
                expectedBranchRef: 'refs/heads/main',
              ),
            },
          );
          fixture = await suite.mount(
            tester,
            registry: durable.registry,
            lifecycle: durable.lifecycle,
            additionalRoot: repository,
            present: false,
          );
          final anchors = _anchorStore(durable.lifecycle, fixture);
          final identity = AuthorizedEnvironmentIdentity(
            sessionId: fixture.sessionA.id.value,
            environmentId: 'additional',
          );
          final lookup = Stopwatch();
          await tester.runAsync(() async {
            lookup.start();
            expect((await anchors.read(identity)).baselineCommit, baseline);
            lookup.stop();
          });
          await tester.pumpWidget(fixture.widget());
          await tester.pumpAndSettle();
          await selectChangeSetSource(tester);
          final elapsed = Stopwatch()..start();
          pressPaneButton(tester, 'Task');
          await waitForPaneText(
            tester,
            'snapshot\ncommitted\nstaged\nunstaged\nconflicts',
          );
          elapsed.stop();
          final evidence = (await tester.runAsync(fixture.snapshot))!;
          final processes = evidence['processes'] as List;
          expect(processes, hasLength(comparisonTaskProcesses));
          expect(evidence['reads'], isEmpty);
          debugPrint(
            'Prepared persisted Task $count clean files: '
            '${processes.length} process requests (comparison unchanged), '
            '${lookup.elapsedMicroseconds} us native ProjectStorageHost anchor lookup, '
            '${elapsed.elapsedMilliseconds} ms full AOT/EVC snapshot, '
            '${elapsed.elapsedMilliseconds - comparisonTaskMilliseconds} ms '
            'versus comparison-only (diagnostic only; includes transport and scheduling).',
          );
          final calls = (await tester.runAsync(() => semanticCalls(fixture)))!;
          expect(calls, hasLength(1));
          expect(calls.single['method'], snapshotMethod('Task'));
          expect(calls.single['payload'], isEmpty);
        }
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }

  testWidgets(
    'Task retains committed-only nonprimary changes after Uncommitted is clean',
    (tester) async {
      final fixture = await suite.mount(
        tester,
        additionalRoot: suite.committedRoot,
      );
      await selectChangeSetSource(tester);
      pressPaneButton(tester, 'Uncommitted');
      await waitForPaneText(tester, 'snapshot\nstaged\nunstaged\nconflicts');
      var previousProcessCount =
          ((await tester.runAsync(fixture.snapshot))!['processes'] as List)
              .length;
      for (var refresh = 0; refresh < 2; refresh++) {
        final elapsed = Stopwatch()..start();
        pressPaneButton(tester, 'Task');
        final snapshot = await paneSnapshot(tester);
        elapsed.stop();
        final processCount =
            ((await tester.runAsync(fixture.snapshot))!['processes'] as List)
                .length;
        debugPrint(
          'Prepared portable Task committed-only: '
          '${processCount - previousProcessCount} process requests, '
          '${elapsed.elapsedMilliseconds} ms (diagnostic only).',
        );
        previousProcessCount = processCount;
        expectCommittedSnapshot(snapshot);
        expect(snapshot, endsWith('\nstaged\nunstaged\nconflicts'));
        expect(snapshot, isNot(contains('primary-only.txt')));
        final calls = (await tester.runAsync(() => semanticCalls(fixture)))!;
        expect(calls, hasLength(2 + refresh));
        expect(calls.first['method'], snapshotMethod('Uncommitted'));
        for (final call in calls.skip(1)) {
          expect(call['method'], snapshotMethod('Task'));
          expect(call['payload'], isEmpty);
        }
        expect(
          calls.map((call) => call['hostInvocationContext']).toSet(),
          hasLength(calls.length),
        );
        await tester.runAsync(
          () => expectBufferedDenial(
            fixture,
            calls.last['hostInvocationContext'] as String,
          ),
        );
      }
      final evidence = (await tester.runAsync(fixture.snapshot))!;
      expect(evidence['reads'], isEmpty);
      for (final process
          in (evidence['processes'] as List).cast<Map<Object?, Object?>>()) {
        expect(process['environmentId'], 'additional');
        expect(process['providerId'], 'test.environment.a');
        expect(process['cwd'], suite.committedRoot);
      }
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  for (final (invalid, code) in [
    ('missing anchor', 'baseline_unavailable'),
    ('empty baseline', 'invalid_baseline'),
    ('invalid baseline', 'invalid_baseline'),
    ('unavailable baseline', 'baseline_unavailable'),
    ('invalid branch', 'invalid_branch'),
    ('wrong branch', 'unexpected_branch'),
    ('detached HEAD', 'detached_head'),
  ]) {
    testWidgets('Task $invalid fails without inferring or replacing its anchor', (
      tester,
    ) async {
      var repository = suite.committedRoot;
      if (invalid == 'wrong branch' || invalid == 'detached HEAD') {
        repository = (await tester.runAsync(() async {
          final name = 'invalid-anchor-${suite.nextSequence()}';
          await runGit(suite.temporary, [
            'clone',
            '--no-hardlinks',
            suite.committedRoot,
            name,
          ]);
          final root = Directory('${suite.temporary.path}/$name');
          await runGit(root, [
            'checkout',
            if (invalid == 'wrong branch') ...[
              '-b',
              'unexpected-task',
            ] else
              '--detach',
          ]);
          return root.resolveSymbolicLinks();
        }))!;
      }
      final fixture = await suite.mount(
        tester,
        additionalRoot: repository,
        withTaskAnchor: invalid != 'missing anchor',
        baselineCommit: switch (invalid) {
          'empty baseline' => '',
          'invalid baseline' => 'HEAD',
          // A real but unrelated primary commit must not cause primary fallback.
          'unavailable baseline' => suite.primaryBaseline,
          _ => suite.selectedBaseline,
        },
        expectedBranchRef: invalid == 'invalid branch'
            ? 'HEAD'
            : selectedBranchRef,
      );
      await selectChangeSetSource(tester);
      pressPaneButton(tester, 'Task');
      await waitForPaneText(tester, 'snapshot:unavailable');
      final calls = (await tester.runAsync(() => semanticCalls(fixture)))!;
      expect(calls, hasLength(1));
      expect(calls.single['method'], snapshotMethod('Task'));
      expect(calls.single['payload'], isEmpty);
      final probe =
          (await tester.runAsync(() => fixture.control('snapshot')))! as Map;
      expect(probe['failures'], [code]);
      await tester.runAsync(
        () => expectBufferedDenial(
          fixture,
          calls.single['hostInvocationContext'] as String,
        ),
      );
      final failedEvidence = (await tester.runAsync(fixture.snapshot))!;
      if (invalid == 'missing anchor') {
        expect(failedEvidence['processes'], isEmpty);
      }
      // Optional Task metadata must not disable either existing scope, including
      // on the detached checkout. These calls still inspect the selected root.
      pressPaneButton(tester, 'Unstaged');
      await waitForPaneText(tester, 'snapshot');
      pressPaneButton(tester, 'Uncommitted');
      await waitForPaneText(tester, 'snapshot\nstaged\nunstaged\nconflicts');
      final allCalls = (await tester.runAsync(() => semanticCalls(fixture)))!;
      expect(allCalls.map((call) => call['method']), [
        snapshotMethod('Task'),
        snapshotMethod('Unstaged'),
        snapshotMethod('Uncommitted'),
      ]);
      expect(
        allCalls.every((call) => (call['payload'] as Map).isEmpty),
        isTrue,
      );
      final evidence = (await tester.runAsync(fixture.snapshot))!;
      expect(evidence['reads'], isEmpty);
      for (final process
          in (evidence['processes'] as List).cast<Map<Object?, Object?>>()) {
        expect(process['environmentId'], 'additional');
        expect(process['providerId'], 'test.environment.a');
        expect(process['cwd'], repository);
      }
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }
}

GitTaskAnchorStore _anchorStore(
  ProductLifecycleCoordinator lifecycle,
  PreparedEnvironmentCapabilityInstallation fixture,
) {
  final connection = fixture.connection;
  expect(connection.pluginId, gitPluginId);
  return GitTaskAnchorStore(
    ProjectStorageHost(
      lifecycle: lifecycle,
      owner: PluginId(connection.pluginId),
      validateAccess: connection.validateInfrastructureContext,
    ),
  );
}
