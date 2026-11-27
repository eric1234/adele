@TestOn('linux')
@Timeout(Duration(minutes: 4))
library;

import 'dart:io';

import 'package:adele_capabilities/adele_capabilities.dart';
import 'package:adele_contract/adele_contract.dart';
import 'package:adele_desktop/core/environment_capability_invocation.dart';
import 'package:adele_desktop/core/environment_capability_selection.dart';
import 'package:adele_environment/adele_environment.dart';
import 'package:diff_viewer_contract/diff_viewer_contract.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plugin_runtime/plugin_runtime.dart';

import 'support/portable_git_probe_assertions.dart';
import 'support/portable_git_review_repository.dart';
import 'support/prepared_portable_git.dart';

void main() {
  final suite = PreparedPortableGit(
    stock: false,
    repositoryRoot: Directory.current.parent,
  );
  setUpAll(suite.prepare);
  tearDownAll(suite.close);

  for (final denial in [
    'frontend declaration',
    'provider permission',
    'absent provider',
  ]) {
    testWidgets(
      'G6a/G6c3a $denial denies approval independently of snapshot access',
      (tester) async {
        final repositories = await suite.reviewRepositories(
          tester,
          wholeLayer: true,
        );
        final before = (await tester.runAsync(
          () => reviewStates(repositories),
        ))!;
        final fixture = await suite.mount(
          tester,
          additionalRoot: repositories['additional'],
          primaryRoot: repositories['primary'],
          approvalGrant: denial != 'frontend declaration',
          approvalProviderPermission: denial != 'provider permission',
          approvalProviderPresent: denial != 'absent provider',
        );
        pressPaneButton(tester, 'Select approval');
        await waitForPaneText(tester, 'approval-selection:unavailable');
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
        await selectChangeSetSource(tester);
        pressPaneButton(tester, 'Uncommitted');
        expect(
          await paneSnapshot(tester),
          contains('addition:additional inserted first:false'),
        );
        pressPaneButton(tester, 'Approve');
        pressPaneButton(tester, 'Approve File');
        pressPaneButton(tester, 'Unapprove File');
        pressPaneButton(tester, 'Approve All');
        pressPaneButton(tester, 'Unapprove All');
        await waitForPaneText(tester, 'approval:idle');
        expect(
          await tester.runAsync(
            () => semanticCalls(
              fixture,
              serviceId: reviewApprovalHandlerServiceId,
            ),
          ),
          isEmpty,
        );
        expect(await tester.runAsync(() => reviewStates(repositories)), before);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }

  testWidgets(
    'G6a malformed approval transport cannot inject selectors or bypass native selection bounds',
    (tester) async {
      final repositories = await suite.reviewRepositories(tester);
      final before = (await tester.runAsync(() => reviewStates(repositories)))!;
      final fixture = await suite.mount(
        tester,
        additionalRoot: repositories['additional'],
        primaryRoot: repositories['primary'],
        approvalProviderPresent: true,
        present: false,
      );
      // Trusted test-side injection uses the existing host admission helper.
      // C never receives a raw request channel or authority selectors.
      await tester.runAsync(() async {
        final selected = await CapturedEnvironmentCapabilities(
          environmentRuntime: fixture.environmentRuntime,
          backends: fixture.backends,
          session: fixture.sessionA,
        ).resolve(reviewApprovalCapability);
        final valid = <String, Object?>{
          'relativePath': 'review.txt',
          'hunkIndex': 0,
          'expectedRevision': 'opaque-test-revision',
        };
        final payloads = <Map<String, Object?>>[
          {},
          {'selection': null},
          {
            'selection': {'relativePath': 'review.txt', 'hunkIndex': 0},
          },
          for (final path in [
            '',
            '/review.txt',
            '../review.txt',
            'a/../review.txt',
            'a\u0000b',
            'x' * 4097,
          ])
            {
              'selection': {...valid, 'relativePath': path},
            },
          for (final index in <Object>[-1, 8192, '0', 0.5])
            {
              'selection': {...valid, 'hunkIndex': index},
            },
          for (final revision in <Object?>[
            null,
            '',
            'bad\nrevision',
            'x' * 257,
          ])
            {
              'selection': {...valid, 'expectedRevision': revision},
            },
          for (final field in [
            'environmentId',
            'sessionId',
            'repository',
            'providerId',
            'rawPatch',
            'hostInvocationContext',
          ]) ...[
            {'selection': valid, field: 'primary'},
            {
              'selection': {...valid, field: 'primary'},
            },
          ],
        ];
        for (final method in [
          reviewApprovalHandlerServiceApproveHunkId,
          reviewApprovalHandlerServiceUnapproveHunkId,
        ]) {
          for (final payload in payloads) {
            await expectLater(
              invokeEnvironmentCapabilityWithBufferedProcess(
                selection: selected,
                backends: fixture.backends,
                serviceId: reviewApprovalHandlerServiceId,
                invoke: (channel) => channel.request(method, payload),
              ),
              throwsA(
                isA<AdeleRemoteFailure>().having(
                  (error) => error.code,
                  'code',
                  'invalid_request',
                ),
              ),
            );
          }
        }
        final calls = await semanticCalls(
          fixture,
          serviceId: reviewApprovalHandlerServiceId,
        );
        expect(calls, hasLength(payloads.length * 2));
        expect(
          calls.map((call) => call['hostInvocationContext']).toSet(),
          hasLength(calls.length),
        );
        for (final call in calls) {
          await expectBufferedDenial(
            fixture,
            call['hostInvocationContext'] as String,
          );
        }
        final probe = await fixture.control('snapshot') as Map;
        expect(
          probe['failures'],
          isEmpty,
          reason: 'Malformed DTOs never enter the implementation.',
        );
        expect((await fixture.snapshot())['processes'], isEmpty);
        expect(await reviewStates(repositories), before);
      });
    },
  );

  for (final denial in [
    'frontend declaration',
    'provider permission',
    'absent provider',
  ]) {
    testWidgets('$denial prevents portable Git admission without fallback', (
      tester,
    ) async {
      final fixture = await suite.mount(
        tester,
        processGrant: denial != 'frontend declaration',
        providerPermission: denial != 'provider permission',
        providerPresent: denial != 'absent provider',
      );
      pressPaneButton(tester, 'Select');
      await waitForPaneText(tester, 'selection:unavailable');
      expect(await tester.runAsync(() => semanticCalls(fixture)), isEmpty);
      expect((await tester.runAsync(fixture.snapshot))!['processes'], isEmpty);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  for (final scope in ['Unstaged', 'Uncommitted', 'Task']) {
    testWidgets(
      '$scope wrong service and explicit missing provider do not select the available provider',
      (tester) async {
        final fixture = await suite.mount(tester);
        for (final label in ['Wrong service', 'Missing provider']) {
          pressPaneButton(tester, label);
          await waitForPaneText(tester, 'selection:unavailable');
        }
        expect(await tester.runAsync(() => semanticCalls(fixture)), isEmpty);
        expect(
          (await tester.runAsync(fixture.snapshot))!['processes'],
          isEmpty,
        );
        await selectChangeSetSource(tester);
        pressPaneButton(tester, scope);
        expectAdditionalSnapshot(await paneSnapshot(tester), scope: scope);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );

    for (final noFacet in [true, false]) {
      testWidgets(
        '$scope ${noFacet ? 'absent process facet' : 'explicit unavailable Environment'} never falls back to primary',
        (tester) async {
          final fixture = await suite.mount(
            tester,
            noBufferedFacet: noFacet,
            unavailable: !noFacet,
            concurrent: true,
          );
          await selectChangeSetSource(tester);
          pressPaneButton(tester, scope);
          await waitForPaneText(tester, 'snapshot:unavailable');
          expect(
            (await tester.runAsync(fixture.snapshot))!['processes'],
            isEmpty,
          );
          await selectChangeSetSource(tester, pane: 'b');
          pressPaneButton(tester, scope, pane: 'b');
          if (scope == 'Task') {
            await waitForPaneText(tester, 'snapshot:unavailable', pane: 'b');
          } else {
            expect(
              await paneSnapshot(tester, pane: 'b'),
              contains('primary-only.txt|modified|text'),
            );
          }
          final processes =
              ((await tester.runAsync(fixture.snapshot))!['processes'] as List)
                  .cast<Map<Object?, Object?>>();
          expect(processes, isNotEmpty);
          expect(
            processes.every((process) => process['environmentId'] == 'primary'),
            isTrue,
          );
          await tester.pumpWidget(const SizedBox.shrink());
        },
      );
    }
  }

  testWidgets(
    'pending Task grants no extra services or foreign activation authority',
    (tester) async {
      final fixture = await suite.mount(tester);
      await selectChangeSetSource(tester);
      await tester.runAsync(
        () => fixture.control('hold', {'key': 'process:completed'}),
      );
      pressPaneButton(tester, 'Task');
      await tester.runAsync(() => fixture.wait(tester, 'process:completed'));
      final token = (await tester.runAsync(() => invocationToken(fixture)))!;
      await tester.runAsync(() async {
        expect(
          await fixture.controlOn(
            fixture.environmentConnection,
            'attackBuffered',
            {'token': token},
          ),
          {'ok': false},
        );
        for (final (service, method, arguments) in [
          (
            authorizedEnvironmentReadServiceId,
            authorizedEnvironmentReadServiceReadFileId,
            <String, Object?>{'relativePath': 'committed-only.txt'},
          ),
          (
            authorizedEnvironmentMutationServiceId,
            'authorizedEnvironmentMutation.writeFile',
            <String, Object?>{},
          ),
          (
            authorizedEnvironmentProcessServiceId,
            'authorizedEnvironmentProcess.run',
            <String, Object?>{},
          ),
          ('projectStorage', 'projectStorage.query', <String, Object?>{}),
          ('unlisted', 'unlisted.call', <String, Object?>{}),
        ]) {
          await expectBufferedDenial(
            fixture,
            token,
            service: service,
            method: method,
            arguments: arguments,
          );
        }
        await fixture.control('release', {'key': 'process:completed'});
      });
      expectAdditionalSnapshot(await paneSnapshot(tester), scope: 'Task');
      final calls = (await tester.runAsync(() => semanticCalls(fixture)))!;
      expect(calls, hasLength(1));
      expect(calls.single['method'], snapshotMethod('Task'));
      expect(calls.single['payload'], isEmpty);
      await tester.runAsync(() => expectBufferedDenial(fixture, token));
      final evidence = (await tester.runAsync(fixture.snapshot))!;
      expect(evidence['reads'], isEmpty);
      expect(
        (evidence['processes'] as List).cast<Map<Object?, Object?>>().every(
          (process) => process['environmentId'] == 'additional',
        ),
        isTrue,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  for (final scope in ['Unstaged', 'Uncommitted', 'Task']) {
    for (final side in ['environment', 'callable']) {
      testWidgets(
        '$scope exact $side retirement fences outstanding real process result',
        (tester) async {
          final fixture = await suite.mount(tester, concurrent: true);
          await selectChangeSetSource(tester);
          await selectChangeSetSource(tester, pane: 'b');
          final environment = fixture.capabilities.resolve(
            environmentProviderCapability,
            providerId: ProviderId('test.environment.a'),
          );
          final callable = fixture.capabilities.resolve(
            changeSetCapability,
            providerId: ProviderId('test.callable.a'),
          );
          final target = side == 'environment' ? environment : callable;
          final owner = side == 'environment'
              ? fixture.environmentOwner
              : fixture.callableOwner;
          await tester.runAsync(
            () => fixture.control('hold', {'key': 'process:completed'}),
          );
          pressPaneButton(tester, scope);
          await tester.runAsync(
            () => fixture.wait(tester, 'process:completed'),
          );
          final token = (await tester.runAsync(
            () => invocationToken(fixture),
          ))!;
          final stale = paneCallback(tester, scope);
          await tester.runAsync(() => owner.retireProvider(target));
          await waitForPaneText(tester, 'snapshot:unavailable');
          expect(
            () => target.requestChannel,
            throwsA(isA<ProviderUnavailable>()),
          );
          fixture.environmentOwner.validate();
          fixture.callableOwner.validate();
          expect(fixture.connection.isClosed, isFalse);
          expect(fixture.environmentConnection.isClosed, isFalse);
          await tester.runAsync(() => expectBufferedDenial(fixture, token));
          stale();
          pressPaneButton(tester, 'Select');
          await waitForPaneText(tester, 'selection:unavailable');
          await tester.runAsync(() async {
            await fixture.control('release', {'key': 'process:completed'});
            await fixture.wait(tester, 'settled:${scope.toLowerCase()}');
          });
          pressPaneButton(tester, scope, pane: 'b');
          if (side == 'environment' && scope != 'Task') {
            expect(
              await paneSnapshot(tester, pane: 'b'),
              contains('primary-only.txt|modified|text'),
            );
          } else {
            await waitForPaneText(tester, 'snapshot:unavailable', pane: 'b');
          }
          expect(
            inPane('a', find.textContaining('file with spaces.txt|')),
            findsNothing,
          );
          final processes =
              ((await tester.runAsync(fixture.snapshot))!['processes'] as List)
                  .cast<Map<Object?, Object?>>();
          expect(
            processes.where(
              (process) => process['environmentId'] == 'additional',
            ),
            hasLength(1),
          );
          final calls = (await tester.runAsync(() => semanticCalls(fixture)))!;
          expect(calls, hasLength(side == 'environment' ? 2 : 1));
          expect(
            calls.every((call) => call['method'] == snapshotMethod(scope)),
            isTrue,
          );
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox.shrink());
        },
      );
    }

    testWidgets(
      '$scope departure suppresses outstanding snapshot without moving its authority',
      (tester) async {
        final fixture = await suite.mount(tester);
        await selectChangeSetSource(tester);
        await tester.runAsync(
          () => fixture.control('hold', {'key': 'process:completed'}),
        );
        pressPaneButton(tester, scope);
        await tester.runAsync(() => fixture.wait(tester, 'process:completed'));
        final token = (await tester.runAsync(() => invocationToken(fixture)))!;
        final stale = paneCallback(tester, scope);
        fixture.frontends.unbind(fixture.sessionA);
        await tester.pumpWidget(fixture.widget(session: fixture.sessionB));
        await tester.pumpAndSettle();
        stale();
        await tester.runAsync(() async {
          await expectBufferedDenial(fixture, token);
          await fixture.control('release', {'key': 'process:completed'});
          await fixture.wait(tester, 'settled:${scope.toLowerCase()}');
        });
        expect(
          await tester.runAsync(() => semanticCalls(fixture)),
          hasLength(1),
        );
        expect(find.textContaining('file with spaces.txt|'), findsNothing);
        await selectChangeSetSource(tester);
        pressPaneButton(tester, scope);
        if (scope == 'Task') {
          await waitForPaneText(tester, 'snapshot:unavailable');
        } else {
          expect(
            await paneSnapshot(tester),
            contains('primary-only.txt|modified|text'),
          );
        }
        final processes =
            ((await tester.runAsync(fixture.snapshot))!['processes'] as List)
                .cast<Map<Object?, Object?>>();
        expect(
          processes.where(
            (process) => process['environmentId'] == 'additional',
          ),
          hasLength(1),
        );
        expect(
          processes
              .skip(1)
              .every((process) => process['environmentId'] == 'primary'),
          isTrue,
        );
        final calls = (await tester.runAsync(() => semanticCalls(fixture)))!;
        expect(calls, hasLength(2));
        expect(
          calls.map((call) => call['hostInvocationContext']).toSet(),
          hasLength(2),
        );
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );

    testWidgets(
      '$scope same-ID replacement never revives a retained generated client or token',
      (tester) async {
        var fixture = await suite.mount(tester);
        await selectChangeSetSource(tester);
        final old = fixture;
        final oldBinding = old.capabilities.resolve(
          changeSetCapability,
          providerId: ProviderId('test.callable.a'),
        );
        final oldEnvironment = old.capabilities.resolve(
          environmentProviderCapability,
          providerId: ProviderId('test.environment.a'),
        );
        final stale = paneCallback(tester, scope);
        await tester.runAsync(
          () => old.control('hold', {'key': 'process:completed'}),
        );
        pressPaneButton(tester, scope);
        await tester.runAsync(() => old.wait(tester, 'process:completed'));
        final token = (await tester.runAsync(() => invocationToken(old)))!;
        await tester.runAsync(old.backends.close);
        await waitForPaneText(tester, 'snapshot:unavailable');
        fixture = await suite.mount(
          tester,
          present: false,
          registry: old.capabilities,
        );
        expect(fixture.connection, isNot(same(old.connection)));
        expect(
          fixture.capabilities
              .resolve(
                changeSetCapability,
                providerId: ProviderId('test.callable.a'),
              )
              .isSameRegistration(oldBinding),
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
        await waitForPaneText(tester, 'snapshot:unavailable');
        await tester.runAsync(() => expectBufferedDenial(fixture, token));
        expect(await tester.runAsync(() => semanticCalls(fixture)), isEmpty);
        expect(
          (await tester.runAsync(fixture.snapshot))!['processes'],
          isEmpty,
        );
        await tester.pumpWidget(fixture.widget());
        await tester.pumpAndSettle();
        await selectChangeSetSource(tester);
        pressPaneButton(tester, scope);
        expectAdditionalSnapshot(await paneSnapshot(tester), scope: scope);
        final calls = (await tester.runAsync(() => semanticCalls(fixture)))!;
        expect(calls, hasLength(1));
        expect(calls.single['method'], snapshotMethod(scope));
        expect(calls.single['payload'], isEmpty);
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
}
