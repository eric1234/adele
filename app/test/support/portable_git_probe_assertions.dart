import 'package:adele_environment/adele_environment.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'portable_git_review_repository.dart';
import 'prepared_environment_capability_installation.dart';
import 'prepared_portable_git.dart';

String snapshotMethod(String scope) =>
    '$changeSetService.snapshot${scope == 'Task' ? 'TaskChanges' : scope}';

Future<List<Map<Object?, Object?>>> semanticCalls(
  PreparedEnvironmentCapabilityInstallation fixture, {
  String serviceId = changeSetService,
}) async {
  final snapshot = (await fixture.control('snapshot'))! as Map;
  return (snapshot['requests'] as List)
      .cast<Map<Object?, Object?>>()
      .where((call) => call['serviceId'] == serviceId)
      .toList();
}

Future<String> invocationToken(
  PreparedEnvironmentCapabilityInstallation fixture, {
  String serviceId = changeSetService,
}) async =>
    (await semanticCalls(
          fixture,
          serviceId: serviceId,
        )).last['hostInvocationContext']
        as String;

Future<void> expectBufferedDenial(
  PreparedEnvironmentCapabilityInstallation fixture,
  String token, {
  String? service,
  String? method,
  Map<String, Object?>? arguments,
}) async {
  expect(
    await fixture.control('attackBuffered', {
      'token': token,
      'service': ?service,
      // Identity must fail at host authority, not A's executable allowlist.
      'method':
          method ??
          authorizedEnvironmentBufferedProcessServiceCapturedIdentityId,
      'arguments': arguments ?? <String, Object?>{},
    }),
    {'ok': false},
  );
}

Future<void> waitForPaneText(
  WidgetTester tester,
  String text, {
  String pane = 'a',
}) async => waitForFinder(tester, inPane(pane, find.text(text)));

Future<void> selectChangeSetSource(
  WidgetTester tester, {
  String pane = 'a',
}) async {
  pressPaneButton(tester, 'Select', pane: pane);
  await waitForPaneText(tester, 'selected', pane: pane);
}

Future<String> paneSnapshot(WidgetTester tester, {String pane = 'a'}) async {
  final finder = inPane(
    pane,
    find.byWidgetPredicate(
      (widget) =>
          widget is Text && (widget.data?.startsWith('snapshot\n') ?? false),
    ),
  );
  await waitForFinder(tester, finder);
  return tester.widget<Text>(finder).data!;
}

void expectAdditionalSnapshot(String snapshot, {String scope = 'Unstaged'}) {
  final unstaged = scope == 'Unstaged'
      ? snapshot
      : snapshot.split('\nunstaged\n')[1].split('\nconflicts\n')[0];
  expect(unstaged, contains('file with spaces.txt|modified|text\n@@1,1:1,1'));
  expect(unstaged, contains('deletion:old selected:false'));
  expect(unstaged, contains('addition:new selected:false'));
  expect(unstaged, contains('deleted.txt|deleted|text\n@@1,1:0,0'));
  expect(unstaged, contains('deletion:deleted selected:false'));
  expect(unstaged, contains('line\nname.txt|added|text\n@@0,0:1,1'));
  expect(unstaged, contains('addition:added selected:false'));
  expect(snapshot, isNot(contains('primary')));
  if (scope == 'Unstaged') {
    expect(snapshot, isNot(contains('staged-only.txt')));
    return;
  }
  final staged = snapshot.split('\nstaged\n')[1].split('\nunstaged\n')[0];
  final conflicts = snapshot.split('\nconflicts\n')[1];
  expect(staged, contains('staged-only.txt|modified|text\n@@1,1:1,1'));
  expect(staged, contains('deletion:old staged:false'));
  expect(staged, contains('addition:new staged:false'));
  expect(staged, contains('added\nstaged.txt|added|text\n@@0,0:1,1'));
  expect(staged, contains('addition:added staged:false'));
  expect(staged, contains('staged deleted.txt|deleted|text\n@@1,1:0,0'));
  expect(staged, contains('deletion:deleted staged:false'));
  expect(staged, contains('partial.txt|modified|text\n@@1,1:1,1'));
  expect(staged, contains('deletion:head partial:false'));
  expect(staged, contains('addition:index partial:false'));
  expect(unstaged, contains('partial.txt|modified|text\n@@1,1:1,1'));
  expect(unstaged, contains('deletion:index partial:false'));
  expect(unstaged, contains('addition:work partial:false'));
  expect(staged, contains('cancel.txt|modified|text\n@@1,1:1,1'));
  expect(staged, contains('deletion:head cancellation:false'));
  expect(staged, contains('addition:index cancellation:false'));
  expect(unstaged, contains('cancel.txt|modified|text\n@@1,1:1,1'));
  expect(unstaged, contains('deletion:index cancellation:false'));
  expect(unstaged, contains('addition:head cancellation:false'));
  expect(staged, isNot(contains('file with spaces.txt')));
  expect(unstaged, isNot(contains('staged-only.txt')));
  expect(unstaged, isNot(contains('staged deleted.txt')));
  expect(unstaged, isNot(contains('added\nstaged.txt')));
  expect(staged, isNot(contains('conflicted.txt')));
  expect(unstaged, isNot(contains('conflicted.txt')));
  expect(conflicts, 'conflicted.txt|conflicted|conflicted');
  if (scope == 'Task') {
    expectCommittedSnapshot(snapshot);
    expect(staged, contains('three-layer.txt|modified|text\n@@1,1:1,1'));
    expect(staged, contains('deletion:head layer:false'));
    expect(staged, contains('addition:index layer:false'));
    expect(unstaged, contains('three-layer.txt|modified|text\n@@1,1:1,1'));
    expect(unstaged, contains('deletion:index layer:false'));
    expect(unstaged, contains('addition:baseline layer:false'));
  }
}

void expectCommittedSnapshot(String snapshot) {
  expect(snapshot, startsWith('snapshot\ncommitted\n'));
  final committed = snapshot.split('\ncommitted\n')[1].split('\nstaged')[0];
  expect(committed, contains('committed-only.txt|modified|text\n@@1,1:1,1'));
  expect(committed, contains('deletion:baseline committed:false'));
  expect(committed, contains('addition:head committed:false'));
  expect(committed, contains('committed added.txt|added|text\n@@0,0:1,1'));
  expect(committed, contains('addition:head added:false'));
  expect(committed, contains('committed deleted.txt|deleted|text\n@@1,1:0,0'));
  expect(committed, contains('deletion:baseline deleted:false'));
  expect(committed, contains('three-layer.txt|modified|text\n@@1,1:1,1'));
  expect(committed, contains('deletion:baseline layer:false'));
  expect(committed, contains('addition:head layer:false'));
  // A currently unmerged path retains its independent committed change too.
  expect(committed, contains('conflicted.txt|modified|text\n@@1,1:1,1'));
  expect(committed, contains('deletion:base conflict:false'));
  expect(committed, contains('addition:$selectedBranch conflict:false'));
  expect(committed, isNot(contains('index layer')));
  expect(committed, isNot(contains('staged-only.txt')));
  expect(committed, isNot(contains('file with spaces.txt')));
}
