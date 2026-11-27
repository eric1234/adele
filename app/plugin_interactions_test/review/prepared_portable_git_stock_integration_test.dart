@TestOn('linux')
@Timeout(Duration(minutes: 4))
library;

import 'dart:convert';
import 'dart:io';

import 'package:adele_contract/adele_contract.dart';
import 'package:adele_desktop/core/environment_capability_selection.dart';
import 'package:adele_environment/adele_environment.dart';
import 'package:adele_product/adele_product.dart';
import 'package:diff_viewer_contract/diff_viewer_contract.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:git_backend/git_backend.dart';

import '../../test/support/portable_git_review_repository.dart';
import '../../test/support/prepared_environment_capability_installation.dart';
import '../../test/support/prepared_portable_git.dart';

void main() {
  final suite = PreparedPortableGit(
    stock: true,
    repositoryRoot: Directory.current.parent,
  );
  setUpAll(suite.prepare);
  tearDownAll(suite.close);

  testWidgets(
    'actual stock Git and Diff approve and unapprove through independent Environment AOT without Task anchors',
    (tester) async {
      final repositories = await suite.reviewRepositories(tester);
      final before = (await tester.runAsync(() => reviewStates(repositories)))!;
      final durable = await suite.openDurable(
        tester,
        additionalRoot: repositories['additional'],
        primaryRoot: repositories['primary'],
      );
      final database = durable.lifecycle.databaseForEnvironment(
        EnvironmentId('additional'),
      )!;
      const anchorTable =
          "SELECT name FROM sqlite_master WHERE name='adele_git_task_anchors'";
      expect(database.queryPluginRows(anchorTable, const {}), isEmpty);
      final fixture = await suite.mount(
        tester,
        registry: durable.registry,
        lifecycle: durable.lifecycle,
        additionalRoot: repositories['additional'],
        primaryRoot: repositories['primary'],
      );
      expect(fixture.connection.pluginId, gitPluginId);
      expect(fixture.connection, isNot(same(fixture.environmentConnection)));
      final approval = fixture.capabilities.resolve(reviewApprovalCapability);
      expect(approval.provider.id.value, gitReviewApprovalProviderId);
      expect(fixture.callableOwner.associationFor(approval), isNull);
      expect(fixture.callableOwner.isEnvironmentBound(approval), isTrue);

      final approve = inPane('a', find.widgetWithText(TextButton, 'Approve'));
      final unapprove = inPane(
        'a',
        find.widgetWithText(TextButton, 'Unapprove'),
      );
      await waitForFinder(tester, approve, count: 2);
      expect(approve, findsNWidgets(2));
      expect(unapprove, findsNothing);
      expect(find.textContaining('+additional first change'), findsOneWidget);
      expect(find.textContaining('+additional second change'), findsOneWidget);
      expect(find.textContaining('primary first change'), findsNothing);
      await tester.runAsync(() => tester.tap(approve.first));
      await waitForFinder(tester, approve);
      expect(find.textContaining('+additional first change'), findsNothing);
      expect(find.textContaining('+additional second change'), findsOneWidget);
      expectReviewIndex(
        (await tester.runAsync(() => reviewStates(repositories)))!,
        before,
        'additional',
        reviewContent('additional', first: true),
      );
      expect(
        reviewWrites((await tester.runAsync(() => _stockEvidence(fixture)))!),
        hasLength(1),
      );

      pressPaneButton(tester, 'Uncommitted changes');
      await waitForFinder(tester, unapprove);
      expect(approve, findsOneWidget);
      expect(find.text('review.txt  [modified]'), findsNWidgets(2));
      final unstagedY = tester
          .getTopLeft(find.text('Unstaged changes').last)
          .dy;
      expect(
        tester.getTopLeft(find.textContaining('+additional first change')).dy,
        lessThan(unstagedY),
      );
      expect(
        tester.getTopLeft(find.textContaining('+additional second change')).dy,
        greaterThan(unstagedY),
      );
      await tester.runAsync(() => tester.tap(unapprove));
      await _stockVisible(tester, 'No staged changes');
      await waitForFinder(tester, approve, count: 2);
      expect(approve, findsNWidgets(2));
      expect(unapprove, findsNothing);
      expect(find.text('review.txt  [modified]'), findsOneWidget);
      expect(find.textContaining('+additional first change'), findsOneWidget);
      expect(find.textContaining('+additional second change'), findsOneWidget);
      expect(await tester.runAsync(() => reviewStates(repositories)), before);
      for (final entry in repositories.entries) {
        expect(
          await tester.runAsync(
            () => File('${entry.value}/review.txt').readAsBytes(),
          ),
          utf8.encode(reviewContent(entry.key, first: true, second: true)),
        );
      }
      final evidence = (await tester.runAsync(() => _stockEvidence(fixture)))!;
      final writes = reviewWrites(evidence);
      expect(writes, hasLength(2));
      expect(writes.first['arguments'] as List, isNot(contains('--reverse')));
      expect(writes.last['arguments'] as List, contains('--reverse'));
      for (final write in writes) {
        expect(write['exitCode'], 0);
      }
      for (final process
          in (evidence['processes'] as List).cast<Map<Object?, Object?>>()) {
        expect(process['environmentId'], 'additional');
        expect(process['providerId'], 'test.environment.a');
        expect(process['cwd'], repositories['additional']);
      }
      expect(
        fixture.environmentRuntime.currentMaterialization(
          EnvironmentId('primary'),
        ),
        isNull,
      );
      expect(database.queryPluginRows(anchorTable, const {}), isEmpty);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'G6c3b stock bulk controls roundtrip mixed changes through independent Environment AOT without Task anchors',
    (tester) async {
      final repositories = await suite.reviewRepositories(
        tester,
        wholeLayer: true,
      );
      final before = (await tester.runAsync(() => reviewStates(repositories)))!;
      final durable = await suite.openDurable(
        tester,
        additionalRoot: repositories['additional'],
        primaryRoot: repositories['primary'],
      );
      final database = durable.lifecycle.databaseForEnvironment(
        EnvironmentId('additional'),
      )!;
      const anchorTable =
          "SELECT name FROM sqlite_master WHERE name='adele_git_task_anchors'";
      expect(database.queryPluginRows(anchorTable, const {}), isEmpty);
      final fixture = await suite.mount(
        tester,
        registry: durable.registry,
        lifecycle: durable.lifecycle,
        additionalRoot: repositories['additional'],
        primaryRoot: repositories['primary'],
        withTaskAnchor: false,
      );
      tester.view.physicalSize = const Size(1600, 5000);
      await tester.pump();
      expect(fixture.connection.pluginId, gitPluginId);
      expect(fixture.connection, isNot(same(fixture.environmentConnection)));
      final approval = fixture.capabilities.resolve(reviewApprovalCapability);
      expect(approval.provider.id.value, gitReviewApprovalProviderId);
      expect(fixture.callableOwner.associationFor(approval), isNull);
      expect(fixture.callableOwner.isEnvironmentBound(approval), isTrue);
      expect(
        durable.lifecycle.store
            .requireSessionAuthority(fixture.sessionA.id)
            .environmentId,
        EnvironmentId('additional'),
      );
      final approve = inPane(
        'a',
        find.widgetWithText(TextButton, 'Approve All Unstaged'),
      );
      final unapprove = inPane(
        'a',
        find.widgetWithText(TextButton, 'Unapprove All Staged'),
      );
      await waitForFinder(tester, approve);
      await waitForFinder(
        tester,
        find.widgetWithText(TextButton, 'Approve File'),
        count: 4,
      );
      for (final header in [
        'review.txt  [modified]',
        'z-other.txt  [modified]',
        '$newFileReviewPath  [added]',
        '$deletedFileReviewPath  [deleted]',
      ]) {
        expect(find.text(header), findsOneWidget);
      }
      expect(unapprove, findsNothing);
      expect(find.widgetWithText(TextButton, 'Approve'), findsWidgets);
      expect(find.textContaining('primary'), findsNothing);
      final staleApprove = tester.widget<TextButton>(approve).onPressed!;
      await tester.runAsync(() => tester.tap(approve));
      await _stockVisible(tester, 'No unstaged changes');
      expect(approve, findsNothing);
      final approved = (await tester.runAsync(
        () => reviewStates(repositories),
      ))!;
      expectLayerReviewIndex(approved, before, approved: true);
      staleApprove();
      await tester.pump();
      expect(await tester.runAsync(() => reviewStates(repositories)), approved);
      expect(
        reviewWrites((await tester.runAsync(() => _stockEvidence(fixture)))!),
        hasLength(1),
      );

      pressPaneButton(tester, 'Uncommitted changes');
      await waitForFinder(tester, unapprove);
      await waitForFinder(
        tester,
        find.widgetWithText(TextButton, 'Unapprove File'),
        count: 5,
      );
      expect(find.widgetWithText(TextButton, 'Unapprove'), findsWidgets);
      expect(approve, findsNothing);
      await _stockVisible(tester, 'No unstaged changes');
      final staleUnapprove = tester.widget<TextButton>(unapprove).onPressed!;
      await tester.runAsync(() => tester.tap(unapprove));
      await _stockVisible(tester, 'No staged changes');
      await waitForFinder(tester, approve);
      await waitForFinder(
        tester,
        find.widgetWithText(TextButton, 'Approve File'),
        count: 5,
      );
      expect(unapprove, findsNothing);
      expect(find.widgetWithText(TextButton, 'Unapprove File'), findsNothing);
      final unstagedY = tester
          .getTopLeft(find.text('Unstaged changes').last)
          .dy;
      for (final header in [
        'review.txt  [modified]',
        'z-other.txt  [modified]',
        'untouched.txt  [modified]',
        '$newFileReviewPath  [added]',
        '$deletedFileReviewPath  [deleted]',
      ]) {
        expect(find.text(header), findsOneWidget);
        expect(tester.getTopLeft(find.text(header)).dy, greaterThan(unstagedY));
      }
      final unapproved = (await tester.runAsync(
        () => reviewStates(repositories),
      ))!;
      expectLayerReviewIndex(unapproved, before, approved: false);
      staleApprove();
      staleUnapprove();
      await tester.pump();
      expect(
        await tester.runAsync(() => reviewStates(repositories)),
        unapproved,
      );
      final evidence = (await tester.runAsync(() => _stockEvidence(fixture)))!;
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
      for (final process
          in (evidence['processes'] as List).cast<Map<Object?, Object?>>()) {
        expect(process['environmentId'], 'additional');
        expect(process['providerId'], 'test.environment.a');
        expect(process['cwd'], repositories['additional']);
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
      expect(
        fixture.environmentRuntime.currentMaterialization(
          EnvironmentId('primary'),
        ),
        isNull,
      );
      expect(database.queryPluginRows(anchorTable, const {}), isEmpty);
      expect(
        durable.lifecycle.store.runsForSession(fixture.sessionA.id),
        isEmpty,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  for (final empty in [false, true]) {
    testWidgets(
      'G6c2a stock ${empty ? 'empty file' : 'new text file'} approval roundtrip uses independent Environment AOT without Task anchors',
      (tester) async {
        const path = newFileReviewPath;
        final content = empty
            ? ''
            : 'Independent new text\nFinal line without newline';
        final repositories = await suite.reviewRepositories(
          tester,
          newFileContent: content,
        );
        final before = (await tester.runAsync(
          () => reviewStates(repositories),
        ))!;
        await tester.runAsync(
          () => _expectNewFileIndex(
            repositories,
            before,
            content,
            approved: false,
          ),
        );
        final durable = await suite.openDurable(
          tester,
          additionalRoot: repositories['additional'],
          primaryRoot: repositories['primary'],
        );
        final database = durable.lifecycle.databaseForEnvironment(
          EnvironmentId('additional'),
        )!;
        const anchorTable =
            "SELECT name FROM sqlite_master WHERE name='adele_git_task_anchors'";
        expect(database.queryPluginRows(anchorTable, const {}), isEmpty);
        final fixture = await suite.mount(
          tester,
          registry: durable.registry,
          lifecycle: durable.lifecycle,
          additionalRoot: repositories['additional'],
          primaryRoot: repositories['primary'],
          withTaskAnchor: false,
        );
        expect(fixture.connection.pluginId, gitPluginId);
        expect(fixture.connection, isNot(same(fixture.environmentConnection)));
        final approval = fixture.capabilities.resolve(reviewApprovalCapability);
        expect(approval.provider.id.value, gitReviewApprovalProviderId);
        expect(fixture.callableOwner.associationFor(approval), isNull);
        expect(fixture.callableOwner.isEnvironmentBound(approval), isTrue);
        expect(
          durable.lifecycle.store
              .requireSessionAuthority(fixture.sessionA.id)
              .environmentId,
          EnvironmentId('additional'),
        );
        final approve = inPane(
          'a',
          find.widgetWithText(TextButton, 'Approve File'),
        );
        final unapprove = inPane(
          'a',
          find.widgetWithText(TextButton, 'Unapprove File'),
        );
        await waitForFinder(tester, approve);
        expect(find.text('$path  [added]'), findsOneWidget);
        expect(find.widgetWithText(TextButton, 'Approve'), findsNothing);
        expect(find.widgetWithText(TextButton, 'Unapprove'), findsNothing);
        expect(
          find.textContaining('@@ -'),
          empty ? findsNothing : findsOneWidget,
        );
        if (!empty) {
          expect(find.textContaining('+Independent new text'), findsOneWidget);
          expect(
            find.textContaining('+Final line without newline'),
            findsOneWidget,
          );
        }
        final staleApprove = tester.widget<TextButton>(approve).onPressed!;
        await tester.runAsync(() => tester.tap(approve));
        await _stockVisible(tester, 'No unstaged changes');
        expect(approve, findsNothing);
        await tester.runAsync(
          () => _expectNewFileIndex(
            repositories,
            before,
            content,
            approved: true,
          ),
        );
        final approved = (await tester.runAsync(
          () => reviewStates(repositories),
        ))!;
        staleApprove();
        await tester.pump();
        expect(
          await tester.runAsync(() => reviewStates(repositories)),
          approved,
        );
        expect(
          reviewWrites((await tester.runAsync(() => _stockEvidence(fixture)))!),
          hasLength(1),
        );

        pressPaneButton(tester, 'Uncommitted changes');
        await waitForFinder(tester, unapprove, count: 2);
        expect(find.text('$path  [added]'), findsOneWidget);
        // The other file action belongs to the unrelated staged sentinel.
        expect(find.widgetWithText(TextButton, 'Unapprove'), findsOneWidget);
        expect(
          tester.getTopLeft(find.text('$path  [added]')).dy,
          lessThan(tester.getTopLeft(find.text('Unstaged changes').last).dy),
        );
        final staleUnapprove = tester
            .widget<TextButton>(unapprove.first)
            .onPressed!;
        await tester.runAsync(() => tester.tap(unapprove.first));
        await waitForFinder(tester, approve);
        expect(unapprove, findsOneWidget);
        expect(find.text('$path  [added]'), findsOneWidget);
        expect(
          tester.getTopLeft(find.text('$path  [added]')).dy,
          greaterThan(tester.getTopLeft(find.text('Unstaged changes').last).dy),
        );
        expect(
          find.textContaining('+additional unrelated staged sentinel'),
          findsOneWidget,
        );
        expect(find.textContaining('Primary'), findsNothing);
        await tester.runAsync(
          () => _expectNewFileIndex(
            repositories,
            before,
            content,
            approved: false,
          ),
        );
        staleUnapprove();
        await tester.pump();
        expect(await tester.runAsync(() => reviewStates(repositories)), before);
        final evidence = (await tester.runAsync(
          () => _stockEvidence(fixture),
        ))!;
        final writes = reviewWrites(evidence);
        expect(writes, hasLength(2));
        expect(writes.first['arguments'] as List, isNot(contains('--reverse')));
        expect(writes.last['arguments'] as List, contains('--reverse'));
        for (final write in writes) {
          expect(write['exitCode'], 0);
        }
        for (final process
            in (evidence['processes'] as List).cast<Map<Object?, Object?>>()) {
          expect(process['environmentId'], 'additional');
          expect(process['providerId'], 'test.environment.a');
          expect(process['cwd'], repositories['additional']);
        }
        expect(
          fixture.environmentRuntime.currentMaterialization(
            EnvironmentId('primary'),
          ),
          isNull,
        );
        expect(database.queryPluginRows(anchorTable, const {}), isEmpty);
        expect(
          durable.lifecycle.store.runsForSession(fixture.sessionA.id),
          isEmpty,
        );
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }

  for (final empty in [false, true]) {
    testWidgets(
      'G6c2b stock ${empty ? 'empty tracked file' : 'executable text file'} deletion approval roundtrip uses independent Environment AOT without Task anchors',
      (tester) async {
        const path = deletedFileReviewPath;
        final content = empty
            ? ''
            : 'Independent deletion HEAD\nFinal line without newline';
        final mode = empty ? '100644' : '100755';
        final repositories = await suite.reviewRepositories(
          tester,
          deletedFileContent: content,
        );
        final before = (await tester.runAsync(
          () => reviewStates(repositories),
        ))!;
        await tester.runAsync(
          () => _expectDeletedFileIndex(
            repositories,
            before,
            content,
            mode,
            approved: false,
          ),
        );
        final durable = await suite.openDurable(
          tester,
          additionalRoot: repositories['additional'],
          primaryRoot: repositories['primary'],
        );
        final database = durable.lifecycle.databaseForEnvironment(
          EnvironmentId('additional'),
        )!;
        const anchorTable =
            "SELECT name FROM sqlite_master WHERE name='adele_git_task_anchors'";
        expect(database.queryPluginRows(anchorTable, const {}), isEmpty);
        final fixture = await suite.mount(
          tester,
          registry: durable.registry,
          lifecycle: durable.lifecycle,
          additionalRoot: repositories['additional'],
          primaryRoot: repositories['primary'],
          withTaskAnchor: false,
        );
        expect(fixture.connection.pluginId, gitPluginId);
        expect(fixture.connection, isNot(same(fixture.environmentConnection)));
        expect(fixture.environmentConnection.pluginId, environmentPluginId);
        final approval = fixture.capabilities.resolve(reviewApprovalCapability);
        expect(approval.provider.id.value, gitReviewApprovalProviderId);
        expect(fixture.callableOwner.associationFor(approval), isNull);
        expect(fixture.callableOwner.isEnvironmentBound(approval), isTrue);
        expect(
          durable.lifecycle.store
              .requireSessionAuthority(fixture.sessionA.id)
              .environmentId,
          EnvironmentId('additional'),
        );
        final approve = inPane(
          'a',
          find.widgetWithText(TextButton, 'Approve File'),
        );
        final unapprove = inPane(
          'a',
          find.widgetWithText(TextButton, 'Unapprove File'),
        );
        await waitForFinder(tester, approve);
        expect(find.text('$path  [deleted]'), findsOneWidget);
        expect(find.widgetWithText(TextButton, 'Approve'), findsNothing);
        expect(find.widgetWithText(TextButton, 'Unapprove'), findsNothing);
        expect(find.widgetWithText(TextButton, 'Open in Source'), findsNothing);
        expect(
          find.textContaining('@@ -'),
          empty ? findsNothing : findsOneWidget,
        );
        if (!empty) {
          expect(
            find.textContaining('-Independent deletion HEAD'),
            findsOneWidget,
          );
          expect(
            find.textContaining('-Final line without newline'),
            findsOneWidget,
          );
        }
        final staleApprove = tester.widget<TextButton>(approve).onPressed!;
        await tester.runAsync(() => tester.tap(approve));
        await _stockVisible(tester, 'No unstaged changes');
        expect(approve, findsNothing);
        await tester.runAsync(
          () => _expectDeletedFileIndex(
            repositories,
            before,
            content,
            mode,
            approved: true,
          ),
        );
        final approved = (await tester.runAsync(
          () => reviewStates(repositories),
        ))!;
        staleApprove();
        await tester.pump();
        expect(
          await tester.runAsync(() => reviewStates(repositories)),
          approved,
        );
        expect(
          reviewWrites((await tester.runAsync(() => _stockEvidence(fixture)))!),
          hasLength(1),
        );

        pressPaneButton(tester, 'Uncommitted changes');
        await waitForFinder(tester, unapprove, count: 2);
        expect(find.text('$path  [deleted]'), findsOneWidget);
        // Only the unrelated staged sentinel has a hunk action.
        expect(find.widgetWithText(TextButton, 'Unapprove'), findsOneWidget);
        expect(find.widgetWithText(TextButton, 'Open in Source'), findsNothing);
        expect(
          tester.getTopLeft(find.text('$path  [deleted]')).dy,
          greaterThan(tester.getTopLeft(find.text('Staged changes')).dy),
        );
        expect(
          tester.getTopLeft(find.text('$path  [deleted]')).dy,
          lessThan(tester.getTopLeft(find.text('Unstaged changes').last).dy),
        );
        final staleUnapprove = tester
            .widget<TextButton>(unapprove.first)
            .onPressed!;
        await tester.runAsync(() => tester.tap(unapprove.first));
        await waitForFinder(tester, approve);
        expect(unapprove, findsOneWidget);
        expect(find.text('$path  [deleted]'), findsOneWidget);
        expect(
          tester.getTopLeft(find.text('$path  [deleted]')).dy,
          greaterThan(tester.getTopLeft(find.text('Unstaged changes').last).dy),
        );
        expect(
          find.textContaining('+additional unrelated staged deletion sentinel'),
          findsOneWidget,
        );
        expect(find.textContaining('Primary'), findsNothing);
        expect(find.widgetWithText(TextButton, 'Approve'), findsNothing);
        expect(find.widgetWithText(TextButton, 'Open in Source'), findsNothing);
        await tester.runAsync(
          () => _expectDeletedFileIndex(
            repositories,
            before,
            content,
            mode,
            approved: false,
          ),
        );
        staleUnapprove();
        await tester.pump();
        expect(await tester.runAsync(() => reviewStates(repositories)), before);
        final evidence = (await tester.runAsync(
          () => _stockEvidence(fixture),
        ))!;
        final writes = reviewWrites(evidence);
        expect(writes, hasLength(2));
        expect(writes.first['arguments'] as List, isNot(contains('--reverse')));
        expect(writes.last['arguments'] as List, contains('--reverse'));
        for (final write in writes) {
          expect(write['exitCode'], 0);
        }
        for (final process
            in (evidence['processes'] as List).cast<Map<Object?, Object?>>()) {
          expect(process['environmentId'], 'additional');
          expect(process['providerId'], 'test.environment.a');
          expect(process['cwd'], repositories['additional']);
        }
        expect(
          fixture.environmentRuntime.currentMaterialization(
            EnvironmentId('primary'),
          ),
          isNull,
        );
        expect(database.queryPluginRows(anchorTable, const {}), isEmpty);
        expect(
          durable.lifecycle.store.runsForSession(fixture.sessionA.id),
          isEmpty,
        );
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }

  for (final count in [100, 500, 900]) {
    testWidgets(
      'actual stock Git and Diff use independent Environment AOT for $count clean files and layered changes',
      (tester) async {
        final repository = (await tester.runAsync(() async {
          final root = await Directory(
            '${suite.temporary.path}/stock-$count',
          ).create();
          await runGit(root, ['init', '--initial-branch=main']);
          await Directory('${root.path}/tracked').create();
          for (var i = 0; i < count; i++) {
            await File(
              '${root.path}/tracked/file $i.txt',
            ).writeAsString('baseline $i\n');
          }
          await runGit(root, ['add', '--all']);
          await runGit(root, [
            '-c',
            'user.name=Fixture',
            '-c',
            'user.email=fixture@example.invalid',
            'commit',
            '-m',
            'stock route baseline',
          ]);
          return root.resolveSymbolicLinks();
        }))!;
        final baseline = (await tester.runAsync(
          () => runGit(Directory(repository), ['rev-parse', 'HEAD']),
        ))!;
        final durable = await suite.openDurable(
          tester,
          additionalRoot: repository,
          initialAnchors: {
            'additional': GitTaskComparisonAnchor(
              baselineCommit: baseline,
              expectedBranchRef: 'refs/heads/main',
            ),
            'primary': GitTaskComparisonAnchor(
              baselineCommit: suite.primaryBaseline,
              expectedBranchRef: 'refs/heads/main',
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
        final retained = anchorRows(durable.lifecycle);
        expect(fixture.connection.pluginId, gitPluginId);
        expect(fixture.connection, isNot(same(fixture.environmentConnection)));
        expect(
          fixture.capabilities.providersFor(environmentProviderCapability),
          hasLength(3),
        );
        final binding = fixture.capabilities.resolve(changeSetCapability);
        expect(binding.provider.id.value, gitChangeSetSourceProviderId);
        expect(fixture.callableOwner.associationFor(binding), isNull);
        expect(fixture.callableOwner.isEnvironmentBound(binding), isTrue);
        expect(
          fixture.callableOwner.allowsEnvironmentHostService(
            binding,
            AdeleEnvironmentHostService.bufferedProcess,
          ),
          isTrue,
        );
        expect(
          fixture.callableOwner.allowsEnvironmentHostService(
            binding,
            AdeleEnvironmentHostService.read,
          ),
          isFalse,
        );
        var previousCount = 0;
        final batches = (count + 127) ~/ 128;
        for (final (scope, clean, expected) in [
          ('Unstaged changes', 'No unstaged changes', 21 + 4 * batches),
          ('Uncommitted changes', 'No uncommitted changes', 27 + 4 * batches),
          ('Task / Branch', 'No task changes', 36 + 4 * batches),
        ]) {
          final elapsed = Stopwatch()..start();
          if (previousCount == 0) {
            await tester.pumpWidget(fixture.widget());
          } else {
            pressPaneButton(tester, scope);
          }
          await _stockVisible(tester, clean);
          elapsed.stop();
          final evidence = (await tester.runAsync(
            () => _stockEvidence(fixture),
          ))!;
          final processes = (evidence['processes'] as List)
              .cast<Map<Object?, Object?>>();
          final requests = processes.length - previousCount;
          expect(requests, expected);
          for (final process in processes) {
            expect(process['environmentId'], 'additional');
            expect(process['providerId'], 'test.environment.a');
            expect(process['cwd'], repository);
            expect(process['exitCode'], 0);
          }
          debugPrint(
            'Actual stock $scope $count clean files: $requests process requests, '
            '${elapsed.elapsedMilliseconds} ms (diagnostic only).',
          );
          previousCount = processes.length;
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
        expect(
          selected.materialization.binding.provider.id.value,
          'test.environment.a',
        );
        expect(
          fixture.environmentRuntime.currentMaterialization(
            EnvironmentId('primary'),
          ),
          isNull,
        );
        expect(
          fixture.environmentRuntime.store
              .environment(EnvironmentId('additional'))!
              .providerState,
          {'root': repository},
        );

        for (final committed in [false, true]) {
          await tester.runAsync(() async {
            final file = File('$repository/tracked/file 0.txt');
            if (committed) {
              await file.writeAsString('committed layer\n');
              await runGit(Directory(repository), ['add', '--all']);
              await runGit(Directory(repository), [
                '-c',
                'user.name=Fixture',
                '-c',
                'user.email=fixture@example.invalid',
                'commit',
                '-m',
                'after retained anchor',
              ]);
            }
            await file.writeAsString('staged layer\n');
            await runGit(Directory(repository), ['add', '--all']);
            await file.writeAsString('working layer\n');
          });
          int? firstCount;
          for (var refresh = 0; refresh < 2; refresh++) {
            final elapsed = Stopwatch()..start();
            pressPaneButton(
              tester,
              refresh == 1
                  ? 'Refresh'
                  : committed
                  ? 'Task / Branch'
                  : 'Uncommitted changes',
            );
            await _stockVisible(tester, '+working layer');
            elapsed.stop();
            expect(
              find.text('tracked/file 0.txt  [modified]'),
              findsNWidgets(committed ? 3 : 2),
            );
            expect(find.textContaining('+staged layer'), findsOneWidget);
            expect(find.textContaining('-staged layer'), findsOneWidget);
            expect(find.textContaining('-baseline 0'), findsOneWidget);
            if (committed) {
              expect(find.textContaining('+committed layer'), findsOneWidget);
              expect(find.textContaining('-committed layer'), findsOneWidget);
            }
            final evidence = (await tester.runAsync(
              () => _stockEvidence(fixture),
            ))!;
            final total = (evidence['processes'] as List).length;
            final requests = total - previousCount;
            if (firstCount != null) expect(requests, firstCount);
            firstCount = requests;
            // Fixed rendered-file work, not a subprocess for every clean file.
            expect(requests, (committed ? 66 : 42) + 4 * batches);
            debugPrint(
              'Actual stock ${committed ? 'committed+staged+unstaged' : 'staged+unstaged'} '
              '$count files refresh $refresh: $requests process requests, '
              '${elapsed.elapsedMilliseconds} ms (diagnostic only).',
            );
            previousCount = total;
            expect(anchorRows(durable.lifecycle), retained);
          }
        }
        if (count == 100) {
          final oldSession = fixture.sessionA;
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.runAsync(() async {
            await fixture.close();
            await durable.lifecycle.close();
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
          await _stockVisible(tester, '+working layer');
          pressPaneButton(tester, 'Task / Branch');
          await _stockVisible(tester, '+committed layer');
          expect(find.textContaining('-baseline 0'), findsOneWidget);
          fixture.frontends.unbind(fixture.sessionA);
          await tester.pumpWidget(fixture.widget(session: fixture.sessionB));
          await _stockVisible(tester, '+new primary');
          pressPaneButton(tester, 'Task / Branch');
          await _stockVisible(tester, 'No committed changes');
          expect(find.textContaining('tracked/file 0.txt'), findsNothing);
          expect(anchorRows(reopened.lifecycle), retained);
        }
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }

  testWidgets(
    'actual stock layers retain conflicts and unsupported files without Source authority',
    (tester) async {
      final link = Link('${suite.roots['additional']}/unsupported-link.txt');
      await tester.runAsync(() => link.create('file with spaces.txt'));
      addTearDown(() async {
        if (await link.exists()) await link.delete();
      });
      final durable = await suite.openDurable(
        tester,
        initialAnchors: {
          'additional': GitTaskComparisonAnchor(
            baselineCommit: suite.selectedBaseline,
            expectedBranchRef: selectedBranchRef,
          ),
        },
      );
      final fixture = await suite.mount(
        tester,
        registry: durable.registry,
        lifecycle: durable.lifecycle,
      );
      // Eligibility assertions inspect every lazy row across all four layers,
      // including the extra header controls, rather than only the viewport.
      tester.view.physicalSize = const Size(1600, 5000);
      await tester.pump();
      await _stockVisible(tester, '+new selected');
      final retained = anchorRows(durable.lifecycle);
      for (final scope in [
        'Unstaged changes',
        'Uncommitted changes',
        'Task / Branch',
      ]) {
        if (scope != 'Unstaged changes') {
          pressPaneButton(tester, scope);
          await _stockVisible(tester, '+new staged');
          expect(find.text('Conflicts'), findsOneWidget);
        }
        expect(find.text('conflicted.txt  [conflicted]'), findsOneWidget);
        expect(find.text('conflicted'), findsOneWidget);
        expect(
          find.text('unsupported-link.txt  [unsupported]'),
          findsOneWidget,
        );
        expect(find.text('unsupported'), findsOneWidget);
        expect(
          find.textContaining('Symbolic links and special working files'),
          findsOneWidget,
        );
        expect(find.textContaining('<<<<<<<'), findsNothing);
        expect(find.text('Open in Source'), findsNothing);
        expect(find.text('Source is unavailable.'), findsWidgets);
        await waitForFinder(
          tester,
          find.widgetWithText(TextButton, 'Approve'),
          count: 4,
        );
        // Only the four ordinary modified paths have reviewable hunks. The
        // ordinary deletion adds one file-only action in each mutable layer.
        expect(find.widgetWithText(TextButton, 'Approve'), findsNWidgets(4));
        expect(
          find.widgetWithText(TextButton, 'Unapprove'),
          scope == 'Unstaged changes' ? findsNothing : findsNWidgets(4),
        );
        expect(
          find.widgetWithText(TextButton, 'Approve File'),
          findsNWidgets(5),
        );
        expect(find.text('deleted.txt  [deleted]'), findsOneWidget);
        expect(
          find.widgetWithText(TextButton, 'Unapprove File'),
          scope == 'Unstaged changes' ? findsNothing : findsNWidgets(5),
        );
        expect(
          find.text('staged deleted.txt  [deleted]'),
          scope == 'Unstaged changes' ? findsNothing : findsOneWidget,
        );
        if (scope == 'Task / Branch') {
          // An unmerged path keeps its independent committed change, not an
          // invented staged/unstaged text patch from the conflict workfile.
          expect(find.text('conflicted.txt  [modified]'), findsOneWidget);
          expect(find.textContaining('-base conflict'), findsOneWidget);
          expect(
            find.textContaining('+$selectedBranch conflict'),
            findsOneWidget,
          );
        }
        expect(anchorRows(durable.lifecycle), retained);
      }
      final evidence = (await tester.runAsync(() => _stockEvidence(fixture)))!;
      expect(reviewWrites(evidence), isEmpty);
      for (final process
          in (evidence['processes'] as List).cast<Map<Object?, Object?>>()) {
        expect(process['environmentId'], 'additional');
        expect(process['providerId'], 'test.environment.a');
      }
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'actual stock Task without a selected anchor does not borrow primary or disable other scopes',
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
      );
      await _stockVisible(tester, '+new selected');
      final retained = anchorRows(durable.lifecycle);
      final before =
          ((await tester.runAsync(() => _stockEvidence(fixture)))!['processes']
                  as List)
              .length;
      pressPaneButton(tester, 'Task / Branch');
      await _stockVisible(tester, 'Unable to load');
      expect(find.textContaining('No task changes'), findsNothing);
      expect(
        ((await tester.runAsync(() => _stockEvidence(fixture)))!['processes']
            as List),
        hasLength(before),
      );
      pressPaneButton(tester, 'Uncommitted changes');
      await _stockVisible(tester, '+new staged');
      expect(find.textContaining('+new selected'), findsOneWidget);
      expect(anchorRows(durable.lifecycle), retained);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}

Future<void> _expectNewFileIndex(
  Map<String, String> roots,
  Map<String, Map<String, Object>> before,
  String content, {
  required bool approved,
}) async {
  const path = newFileReviewPath;
  const suffix = '\t$path';
  expect(
    (before['additional']!['index']! as String)
        .split('\u0000')
        .where((entry) => entry.endsWith(suffix)),
    isEmpty,
  );
  final current = await reviewStates(roots);
  final entries = (current['additional']!['index']! as String)
      .split('\u0000')
      .where((entry) => entry.isNotEmpty)
      .toList();
  final oid = reviewBlobOid(content);
  expect(
    entries.where((entry) => entry.endsWith(suffix)),
    approved ? ['100644 $oid 0$suffix'] : isEmpty,
  );
  expect({
    ...current,
    'additional': {
      ...current['additional']!,
      'index': entries
          .where((entry) => !entry.endsWith(suffix))
          .map((entry) => '$entry\u0000')
          .join(),
    },
  }, before);
  final root = Directory(roots['additional']!);
  expect(
    await runGit(root, [
      'status',
      '--porcelain=v1',
      '-z',
      '--',
      path,
    ], trim: false),
    '${approved ? 'A ' : '??'} $path\u0000',
  );
  expect(await File('${root.path}/$path').readAsBytes(), utf8.encode(content));
  if (approved) {
    expect(await runGit(root, ['cat-file', 'blob', oid], trim: false), content);
  }
}

Future<void> _expectDeletedFileIndex(
  Map<String, String> roots,
  Map<String, Map<String, Object>> before,
  String content,
  String mode, {
  required bool approved,
}) async {
  const path = deletedFileReviewPath;
  final oid = reviewBlobOid(content);
  final entry = '$mode $oid 0\t$path\u0000';
  final originalIndex = before['additional']!['index']! as String;
  expect(
    originalIndex.split('\u0000'),
    contains(entry.substring(0, entry.length - 1)),
  );
  expect(await reviewStates(roots), {
    ...before,
    'additional': {
      ...before['additional']!,
      'index': approved ? originalIndex.replaceFirst(entry, '') : originalIndex,
    },
  });
  final root = Directory(roots['additional']!);
  expect(
    await runGit(root, ['ls-tree', '-z', 'HEAD', '--', path], trim: false),
    '$mode blob $oid\t$path\u0000',
  );
  expect(
    await runGit(root, ['ls-files', '--stage', '-z', '--', path], trim: false),
    approved ? '' : entry,
  );
  expect(
    await runGit(root, [
      'status',
      '--porcelain=v1',
      '-z',
      '--',
      path,
    ], trim: false),
    '${approved ? 'D ' : ' D'} $path\u0000',
  );
  expect(await runGit(root, ['cat-file', 'blob', oid], trim: false), content);
  if (!approved) {
    expect(await runGit(root, ['show', ':$path'], trim: false), content);
  }
  expect(
    await FileSystemEntity.type('${root.path}/$path', followLinks: false),
    FileSystemEntityType.notFound,
  );
}

Future<Map<Object?, Object?>> _stockEvidence(
  PreparedEnvironmentCapabilityInstallation fixture,
) async {
  // Stock Git exposes no probe. Observe only the independent process owner.
  final evidence =
      (await fixture.controlOn(fixture.environmentConnection, 'snapshot'))!
          as Map<Object?, Object?>;
  expect(evidence['reads'], isEmpty);
  final requests = (evidence['requests'] as List)
      .cast<Map<Object?, Object?>>()
      .where(
        (request) =>
            request['method'] == environmentProviderServiceRunBufferedProcessId,
      );
  expect(requests, hasLength((evidence['processes'] as List).length));
  return evidence;
}

Future<void> _stockVisible(WidgetTester tester, String text) =>
    waitForFinder(tester, inPane('a', find.textContaining(text)));
