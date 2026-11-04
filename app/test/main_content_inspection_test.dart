import 'dart:async';
import 'dart:io';

import 'package:adele_capabilities/adele_capabilities.dart';
import 'package:adele_desktop/core/adele_runtime.dart';
import 'package:adele_desktop/frontend/contribution_bridge.dart';
import 'package:adele_desktop/frontend/main_content_bridge.dart';
import 'package:adele_desktop/frontend/prepared_frontend.dart';
import 'package:adele_desktop/frontend/prepared_main_content_host.dart';
import 'package:adele_desktop/frontend/prepared_session_services.dart';
import 'package:adele_desktop/frontend/structured_bridge_data.dart';
import 'package:adele_desktop/ui/execution/session_execution_controller.dart';
import 'package:adele_desktop/ui/main_content/main_content_host.dart';
import 'package:adele_environment/adele_environment.dart';
import 'package:adele_orchestration/adele_orchestration.dart';
import 'package:adele_plugin_api/adele_plugin_api.dart';
import 'package:adele_product/adele_product.dart';
import 'package:adele_ui/adele_ui.dart';
import 'package:dart_eval/dart_eval.dart';
import 'package:dart_eval/dart_eval_bridge.dart';
import 'package:dart_eval/stdlib/core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_eval/flutter_eval.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plugin_runtime/plugin_runtime.dart';

const _library = 'package:inspection_probe/main.dart';
const _kind = 'test.content';
const _occurrence = 'occurrence-1';
final _extensionId = ExtensionId('test.inspection-opener');

void main() {
  group('native semantic Inspection opening', () {
    test('missing callback is denied, even with a copied Session identity', () {
      final bridge = MainContentBridge(
        context: const {'sessionId': 'not-authority'},
        isActive: () => true,
      );
      expect(bridge.inspectSessionContent(_kind, _occurrence), isFalse);
      expect(bridge.isActive, isTrue);
    });

    test(
      'validates identities and contains callback rejection and failure',
      () {
        final calls = <(SessionContentKind, SessionContentOccurrenceId)>[];
        var accepted = true;
        var fail = false;
        final bridge = MainContentBridge(
          context: const {},
          isActive: () => true,
          inspectSessionContent: (kind, occurrence) {
            calls.add((kind, occurrence));
            if (fail) throw StateError('private native diagnostic');
            return accepted;
          },
        );
        for (final invalid in [
          '',
          'invalid kind',
          'test.content\n',
          'test.\u00e9',
          'x' * 129,
        ]) {
          expect(bridge.inspectSessionContent(invalid, _occurrence), isFalse);
        }
        for (final invalid in [
          '',
          'invalid occurrence',
          'occurrence\n',
          '\u00e9',
          'x' * 257,
        ]) {
          expect(bridge.inspectSessionContent(_kind, invalid), isFalse);
        }
        expect(calls, isEmpty);
        expect(bridge.inspectSessionContent(_kind, _occurrence), isTrue);
        expect(calls.single.$1.value, _kind);
        expect(calls.single.$2.value, _occurrence);
        accepted = false;
        expect(bridge.inspectSessionContent(_kind, _occurrence), isFalse);
        fail = true;
        expect(bridge.inspectSessionContent(_kind, _occurrence), isFalse);
        expect(calls, hasLength(3));
        expect(bridge.isActive, isTrue);
      },
    );

    for (final invalidate in [false, true]) {
      test(
        'cached callback stays denied after ${invalidate ? 'invalidation' : 'observed retirement'}',
        () {
          var active = true;
          var calls = 0;
          final bridge = MainContentBridge(
            context: const {},
            isActive: () => active,
            inspectSessionContent: (_, _) {
              calls++;
              return true;
            },
          );
          final cached = bridge.inspectSessionContent;
          expect(cached(_kind, _occurrence), isTrue);
          if (invalidate) {
            bridge.invalidate();
          } else {
            active = false;
          }
          expect(cached(_kind, _occurrence), isFalse);
          active = true;
          expect(cached(_kind, _occurrence), isFalse);
          expect(calls, 1);
        },
      );
    }
  });

  group('mounted prepared semantic Inspection opening', () {
    late Directory temporary;
    late File artifact;

    setUpAll(() async {
      temporary = await Directory.systemTemp.createTemp('inspection-probe-');
      final program =
          (Compiler()
                ..addPlugin(flutterEvalPlugin)
                ..addPlugin(const MainContentDeclarations())
                ..addPlugin(const ContributionDeclarations())
                ..entrypoints.add(_library))
              .compile({
                'inspection_probe': {'main.dart': _source},
                'adele_ui': {
                  for (final library in [
                    'main_content_bridge',
                    'contribution_bridge',
                  ])
                    '$library.dart': await File(
                      '../packages/ui/lib/$library.dart',
                    ).readAsString(),
                },
              });
      artifact = await File(
        '${temporary.path}/probe.evc',
      ).writeAsBytes(program.write());
    });
    tearDownAll(() => temporary.delete(recursive: true));

    Future<_Fixture> fixture(
      WidgetTester tester, {
      bool canonicalRuntime = true,
      bool callback = true,
    }) async {
      final generation = (await tester.runAsync(
        () => PreparedFrontend.load(artifact),
      ))!;
      final result = _Fixture(
        generation,
        temporary,
        canonicalRuntime: canonicalRuntime,
        callback: callback,
      );
      addTearDown(result.close);
      return result;
    }

    testWidgets(
      'opted-in pane sends only validated content and its captured Session',
      (tester) async {
        final f = await fixture(tester);
        f.contribute(allowed: true);
        await tester.pumpWidget(f.widget());
        await tester.pumpAndSettle();
        expect(find.text('Init denied'), findsOneWidget);
        expect(f.requests, isEmpty);
        final eval = f.pane('first').runtime;
        expect(_request(eval, kind: 'invalid kind'), isFalse);
        expect(_request(eval, occurrence: 'invalid occurrence'), isFalse);
        expect(_request(eval, kind: 'x' * 129), isFalse);
        expect(_request(eval, occurrence: 'x' * 257), isFalse);
        expect(f.requests, isEmpty);
        expect(_request(eval), isTrue);
        expect(f.requests.single.$1, same(f.session));
        expect(f.requests.single.$2.value, _kind);
        expect(f.requests.single.$3.value, _occurrence);
        f.expectNoEnvironmentWork();
        await tester.pumpWidget(const SizedBox.shrink());
        expect(tester.takeException(), isNull);
      },
    );

    for (final denied in [
      'default declaration',
      'callback',
      'canonical runtime',
    ]) {
      testWidgets('missing $denied denies a mounted pane', (tester) async {
        final f = await fixture(
          tester,
          canonicalRuntime: denied != 'canonical runtime',
          callback: denied != 'callback',
        );
        f.contribute(allowed: denied != 'default declaration');
        await tester.pumpWidget(f.widget());
        await tester.pumpAndSettle();
        expect(_request(f.pane('first').runtime), isFalse);
        expect(f.requests, isEmpty);
        f.expectNoEnvironmentWork();
        await tester.pumpWidget(const SizedBox.shrink());
      });
    }

    testWidgets(
      'Session execution does not grant semantic Inspection opening',
      (tester) async {
        final f = await fixture(tester);
        final strategy = f.extensions.register(
          point: orchestrationStrategyContributions,
          id: ExtensionId('test.execution-strategy'),
          value: OrchestrationStrategyContribution(
            strategyId: f.session.strategyId,
            materialize: (_) => throw StateError('No Run should start.'),
          ),
        );
        addTearDown(strategy.close);
        final controller = SessionExecutionController(
          runtime: f.runtime,
          session: f.session,
          providerId: ProviderId('test.unavailable'),
          model: null,
        );
        addTearDown(controller.close);
        var executionBindings = 0;
        f.contribute(
          sessionExecution: true,
          services: PreparedSessionServices(
            extensions: f.extensions,
            backends: f.runtime.plugins,
            controllerForSession: (session, _) {
              expect(session, same(f.session));
              executionBindings++;
              return controller;
            },
            inspectActivity: (_, _) => false,
            isCurrent: (session) => identical(session, f.session),
          ),
        );
        await tester.pumpWidget(f.widget());
        await tester.pumpAndSettle();
        expect(executionBindings, 2);
        expect(find.text('Inspect first'), findsOneWidget);
        expect(find.text('Inspect second'), findsOneWidget);
        expect(find.text('Frontend unavailable.'), findsNothing);
        expect(_read(f.pane('first').runtime, 'paneId'), 'first');
        expect(_request(f.pane('first').runtime), isFalse);
        await tester.tap(find.widgetWithText(TextButton, 'Inspect first'));
        expect(f.requests, isEmpty);
        f.expectNoEnvironmentWork();
        await tester.pumpWidget(const SizedBox.shrink());
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'initializers, input actions and finite operations receive no opening callback',
      (tester) async {
        final f = await fixture(tester);
        f.contribute(allowed: true);
        await tester.pumpWidget(f.widget());
        await tester.pumpAndSettle();
        final eval = f.pane('first').runtime;
        expect(find.text('Init denied'), findsOneWidget);
        expect(
          copyStructuredBridgeData(
            await eval.executeLib(_library, 'probeOperation'),
          ),
          {'accepted': false},
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('Probe input'));
        await tester.pumpAndSettle();
        expect(find.text('Action denied'), findsOneWidget);
        await tester.tap(find.text('Action denied'));
        await tester.pumpAndSettle();
        expect(_read(eval, 'actionResult'), {'accepted': false});
        expect(f.requests, isEmpty);
        await tester.pumpWidget(const SizedBox.shrink());
        expect(tester.takeException(), isNull);
      },
    );

    for (final foreign in [false, true]) {
      testWidgets(
        '${foreign ? 'foreign canonical' : 'equal noncanonical'} Session cannot acquire a pane callback',
        (tester) async {
          final f = await fixture(tester);
          f.contribute(allowed: true);
          final other = _session(f.session.id.value);
          if (foreign) {
            final runtime = AdeleRuntime();
            addTearDown(runtime.close);
            _publish(runtime, [other]);
            expect(runtime.store.session(other.id), same(other));
          }
          await tester.pumpWidget(f.widget(session: other));
          await tester.pumpAndSettle();
          expect(f.panes, isEmpty);
          expect(f.requests, isEmpty);
          await tester.pumpWidget(const SizedBox.shrink());
          expect(tester.takeException(), isNull);
        },
      );
    }

    testWidgets(
      'removing one exact pane synchronously fences its cached callback, not its sibling or replacement',
      (tester) async {
        final f = await fixture(tester);
        f.contribute(allowed: true);
        await tester.pumpWidget(f.widget());
        await tester.pumpAndSettle();
        final old = f.pane('first').runtime;
        final sibling = f.pane('second').runtime;
        final cached = tester
            .widget<TextButton>(
              find.widgetWithText(TextButton, 'Inspect first'),
            )
            .onPressed!;
        cached();
        expect(f.requests, hasLength(1));
        expect(_read(old, 'removeFirst'), isTrue);
        cached();
        expect(_request(old), isFalse);
        expect(f.requests, hasLength(1));
        expect(_request(sibling), isTrue);
        expect(_read(sibling, 'openFirst'), isTrue);
        await tester.pumpAndSettle();
        final replacement = f.pane('first').runtime;
        expect(replacement, isNot(same(old)));
        cached();
        expect(_request(old), isFalse);
        expect(f.requests, hasLength(2));
        expect(_request(replacement), isTrue);
        expect(f.requests, hasLength(3));
        await tester.pumpWidget(const SizedBox.shrink());
        expect(tester.takeException(), isNull);
      },
    );

    for (final departure in [
      'unmount',
      'Session departure',
      'registration retirement',
      'generation retirement',
      'host unbind',
      'host close',
    ]) {
      testWidgets('$departure fences cached interpreted callbacks', (
        tester,
      ) async {
        final f = await fixture(tester);
        final registration = f.contribute(allowed: true);
        await tester.pumpWidget(f.widget());
        await tester.pumpAndSettle();
        final old = f.pane('first').runtime;
        final cached = tester
            .widget<TextButton>(
              find.widgetWithText(TextButton, 'Inspect first'),
            )
            .onPressed!;
        cached();
        expect(f.requests, hasLength(1));
        switch (departure) {
          case 'unmount':
            await tester.pumpWidget(const SizedBox.shrink());
            await tester.pumpWidget(f.widget());
          case 'Session departure':
            await tester.pumpWidget(f.widget(session: f.other));
          case 'registration retirement':
            final retiring = registration.close();
            expect(_request(old), isFalse);
            await retiring;
            f.contribute(allowed: true);
          case 'generation retirement':
            f.generation.invalidate();
          case 'host unbind':
            f.host.unbind(f.session);
          case 'host close':
            await tester.runAsync(() {
              final closing = f.host.close();
              expect(_request(old), isFalse);
              return closing;
            });
        }
        cached();
        expect(_request(old), isFalse);
        expect(f.requests, hasLength(1));
        await tester.pumpAndSettle();
        if (departure == 'unmount' ||
            departure == 'Session departure' ||
            departure == 'registration retirement') {
          expect(_request(f.pane('first').runtime), isTrue);
          expect(
            f.requests.last.$1,
            same(departure == 'Session departure' ? f.other : f.session),
          );
          cached();
          expect(f.requests, hasLength(2));
        }
        await tester.pumpWidget(const SizedBox.shrink());
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets(
      'attachment departure is fenced before the next widget frame and never revives',
      (tester) async {
        final f = await fixture(tester);
        f.contribute(allowed: true);
        await tester.pumpWidget(f.widget());
        await tester.pumpAndSettle();
        final eval = f.pane('first').runtime;
        f.attachmentCurrent = false;
        expect(_request(eval), isFalse);
        f.attachmentCurrent = true;
        expect(_request(eval), isFalse);
        expect(f.requests, isEmpty);
        await tester.pumpWidget(const SizedBox.shrink());
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'rejected window navigation and exit preflight do not latch pane access inactive',
      (tester) async {
        final f = await fixture(tester);
        f.contribute(allowed: true);
        await tester.pumpWidget(f.widget());
        await tester.pumpAndSettle();
        final eval = f.pane('first').runtime;
        f.interactive = false;
        expect(_request(eval), isFalse);
        expect(_read(eval, 'paneId'), 'first');
        f.interactive = true;
        expect(_request(eval), isTrue);
        final preflight = f.host.prepareToExit();
        expect(_request(eval), isFalse);
        expect(_read(eval, 'paneId'), 'first');
        expect(await preflight, isFalse);
        expect(_request(eval), isTrue);
        expect(f.requests, hasLength(2));
        await f.host.stopOperations();
        expect(_request(eval), isFalse);
        expect(_read(eval, 'paneId'), 'first');
        expect(f.requests, hasLength(2));
        await tester.pumpWidget(const SizedBox.shrink());
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'host exit confirmation blocks cached operations and decline preserves retained data',
      (tester) async {
        final f = await fixture(tester);
        f.contribute(allowed: true, acceptExit: true);
        await tester.pumpWidget(f.widget());
        await tester.pumpAndSettle();
        final pane = f.pane('first');
        final eval = pane.runtime;
        final cached = tester
            .widget<TextButton>(
              find.widgetWithText(TextButton, 'Inspect first'),
            )
            .onPressed!;
        Future<Object?> write(int count) async => copyStructuredBridgeData(
          await eval.executeLib(_library, 'writeOperation', [count]),
        );

        expect(await write(1), {'count': 1});
        cached();
        expect(f.requests, hasLength(1));
        final confirming = Completer<void>();
        final decision = Completer<bool>();
        final preflight = f.host.prepareToExit(
          confirmActiveWork: () {
            confirming.complete();
            return decision.future;
          },
        );
        await confirming.future;
        try {
          // Exercise the original evaluator/callback, not a disabled widget or
          // a freshly acquired attachment that could hide permanent retirement.
          cached();
          for (var i = 0; i < 2; i++) {
            expect(await write(2), {
              'ok': false,
              'message': 'Contribution operation is unavailable.',
            });
          }
          expect(f.requests, hasLength(1));
          expect(_read(eval, 'paneId'), 'first');
          expect(_read(eval, 'retainedData'), {'count': 1});
          expect(f.pane('first'), same(pane));
        } finally {
          decision.complete(false);
        }
        expect(await preflight, isFalse);
        expect(_read(eval, 'retainedData'), {'count': 1});
        cached();
        expect(f.requests, hasLength(2));
        expect(await write(2), {'count': 2});
        expect(_read(eval, 'retainedData'), {'count': 2});
        expect(f.pane('first'), same(pane));
        f.expectNoEnvironmentWork();
        await tester.pumpWidget(const SizedBox.shrink());
        expect(tester.takeException(), isNull);
      },
    );

    for (final mode in ['late-write', 'late-native']) {
      testWidgets(
        'prolonged $mode is revoked before recovery and Keep Working preserves the exact pane',
        (tester) async {
          final f = await fixture(tester);
          f.contribute(allowed: true, exitMode: mode);
          await tester.pumpWidget(f.widget());
          await tester.pumpAndSettle();
          final pane = f.pane('first');
          final eval = pane.runtime;
          expect(await _invoke(eval, 'writeOperation', [1]), {'count': 1});
          final initializations = _read(eval, 'initializations');
          final issues = <ExitPreflightIssue>[];
          final recovery = Completer<bool>();
          var confirmations = 0;
          var activeChecks = 0;
          f.confirm = (_, _) async {
            confirmations++;
            return true;
          };
          final pending = f.gated(
            () => f.host.prepareToExit(
              waitingThreshold: const Duration(seconds: 1),
              confirmIncomplete: (issue) {
                issues.add(issue);
                return recovery.future;
              },
              confirmActiveWork: () async {
                activeChecks++;
                return true;
              },
            ),
          );
          await tester.pump();
          expect(f.delays, hasLength(1));
          expect(await f.host.prepareToExit(), isFalse);
          expect(_request(eval), isFalse);
          await tester.pump(const Duration(seconds: 1));
          expect(issues, [ExitPreflightIssue.prolonged]);
          expect(await f.host.prepareToExit(), isFalse);

          // Neither the recovery choice nor cooperative plugin rejection is
          // required to fence an unconditional late native action.
          f.delays.single.release.complete();
          await tester.pump();
          await tester.pump(const Duration(seconds: 10));
          expect(confirmations, 0);
          expect(activeChecks, 0);
          expect(_read(eval, 'retainedData'), {'count': 1});
          expect(_read(eval, 'initializations'), initializations);
          expect(pane.focuses, 0);
          expect(pane.releases, 0);
          recovery.complete(false);
          expect(await pending, isFalse);
          expect(f.pane('first'), same(pane));
          expect(_request(eval), isTrue);
          expect(await _invoke(eval, 'writeOperation', [2]), {'count': 2});
          expect(_read(eval, 'retainedData'), {'count': 2});
          await tester.pumpWidget(const SizedBox.shrink());
          expect(tester.takeException(), isNull);
        },
      );
    }

    testWidgets(
      'an abandoned pending check cannot drain or reopen the next attempt',
      (tester) async {
        final f = await fixture(tester);
        f.contribute(allowed: true, exitMode: 'gate');
        await tester.pumpWidget(f.widget());
        await tester.pumpAndSettle();
        final pane = f.pane('first');
        final eval = pane.runtime;
        final issues = <ExitPreflightIssue>[];
        final first = f.gated(
          () => f.host.prepareToExit(
            waitingThreshold: const Duration(seconds: 1),
            confirmIncomplete: (issue) async {
              issues.add(issue);
              return false;
            },
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(seconds: 1));
        expect(issues, [ExitPreflightIssue.prolonged]);
        expect(await first, isFalse);
        expect(f.delays.single.release.isCompleted, isFalse);
        expect(await _invoke(eval, 'writeOperation', [3]), {'count': 3});
        expect(_request(eval), isTrue);

        var settled = false;
        final second = f.gated(
          () => f.host.prepareToExit().then((result) {
            settled = true;
            return result;
          }),
        );
        await tester.pump();
        expect(f.delays, hasLength(2));
        expect(f.exitCalls, [_extensionId.value, _extensionId.value]);
        expect(await f.host.prepareToExit(), isFalse);
        expect(_request(eval), isFalse);
        f.delays.first.release.complete();
        await tester.pump();
        expect(settled, isFalse);
        expect(_request(eval), isFalse);
        expect(await _invoke(eval, 'writeOperation', [4]), {
          'ok': false,
          'message': 'Contribution operation is unavailable.',
        });
        f.delays.last.release.complete();
        expect(await second, isTrue);
        expect(_read(eval, 'retainedData'), {'count': 3});
        expect(f.pane('first'), same(pane));
        expect(pane.releases, 0);
        await tester.pumpWidget(const SizedBox.shrink());
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'a plugin Future that never completes leaves Keep Working and a fresh exit usable',
      (tester) async {
        final f = await fixture(tester);
        f.contribute(allowed: true, exitMode: 'gate');
        await tester.pumpWidget(f.widget());
        await tester.pumpAndSettle();
        final pane = f.pane('first');
        final eval = pane.runtime;
        final issues = <ExitPreflightIssue>[];
        final pending = f.gated(
          () => f.host.prepareToExit(
            waitingThreshold: const Duration(seconds: 1),
            confirmIncomplete: (issue) async {
              issues.add(issue);
              return false;
            },
          ),
        );
        await tester.pump();
        expect(f.exitCalls, [_extensionId.value]);
        await tester.pump(const Duration(seconds: 1));
        expect(issues, [ExitPreflightIssue.prolonged]);
        expect(await pending, isFalse);
        expect(_request(eval), isTrue);
        expect(await _invoke(eval, 'writeOperation', [6]), {'count': 6});
        f.exitModes[_extensionId.value] = 'accept';
        expect(await f.host.prepareToExit(), isTrue);
        expect(f.exitCalls, [_extensionId.value, _extensionId.value]);
        expect(_read(eval, 'retainedData'), {'count': 6});
        expect(f.pane('first'), same(pane));
        expect(pane.releases, 0);
        expect(f.delays.single.release.isCompleted, isFalse);
        await tester.pumpWidget(const SizedBox.shrink());
        expect(tester.takeException(), isNull);
      },
    );

    for (final proceed in [false, true]) {
      testWidgets(
        'stuck ordinary drain is escapable and completion during recovery survives (exit=$proceed)',
        (tester) async {
          final f = await fixture(tester);
          f.contribute(allowed: true, exitMode: 'accept');
          await f.gated(() async {
            await tester.pumpWidget(f.widget());
            await tester.pumpAndSettle();
          });
          final pane = f.pane('first');
          final eval = pane.runtime;
          final ordinary = f.gated(
            () => _invoke(eval, 'startGatedOperation', [$String('gate'), 7]),
          );
          await tester.pump();
          expect(f.delays, hasLength(1));
          final decisions = <String>[];
          final issues = <ExitPreflightIssue>[];
          final recovery = Completer<bool>();
          final active = Completer<bool>();
          final pending = f.gated(
            () => f.host.prepareToExit(
              waitingThreshold: const Duration(seconds: 1),
              confirmIncomplete: (issue) {
                issues.add(issue);
                decisions.add('incomplete');
                return recovery.future;
              },
              confirmActiveWork: () {
                decisions.add('active');
                return active.future;
              },
            ),
          );
          await tester.pump();
          await tester.pump(const Duration(seconds: 1));
          expect(issues, [ExitPreflightIssue.prolonged]);
          expect(decisions, ['incomplete']);
          expect(f.exitCalls, isEmpty);
          expect(_request(eval), isFalse);
          f.delays.single.release.complete();
          expect(await ordinary, {'count': 7});
          expect(_read(eval, 'retainedData'), {'count': 7});
          expect(f.exitCalls, isEmpty);
          expect(pane.releases, 0);
          recovery.complete(proceed);
          await tester.pump();
          if (proceed) {
            expect(decisions, ['incomplete', 'active']);
            await tester.pump(const Duration(seconds: 20));
            expect(_request(eval), isFalse);
            expect(await f.host.prepareToExit(), isFalse);
            // Exit Anyway still requires the independent active-work choice.
            active.complete(false);
          }
          expect(await pending, isFalse);
          expect(_request(eval), isTrue);
          expect(f.pane('first'), same(pane));
          expect(_read(eval, 'retainedData'), {'count': 7});
          await tester.pumpWidget(const SizedBox.shrink());
          expect(tester.takeException(), isNull);
        },
      );
    }

    for (final mode in ['human', 'gated-human']) {
      testWidgets(
        'ordinary $mode confirmation pauses preflight before or after draining begins',
        (tester) async {
          final f = await fixture(tester);
          f.contribute(exitMode: 'accept');
          await f.gated(() async {
            await tester.pumpWidget(f.widget());
            await tester.pumpAndSettle();
          });
          final eval = f.pane('first').runtime;
          final human = Completer<bool>();
          var confirmations = 0;
          f.confirm = (_, _) {
            confirmations++;
            return human.future;
          };
          final ordinary = f.gated(
            () => _invoke(eval, 'startGatedOperation', [$String(mode), 8]),
          );
          await tester.pump();
          expect(confirmations, mode == 'human' ? 1 : 0);
          final issues = <ExitPreflightIssue>[];
          var settled = false;
          final pending = f.host
              .prepareToExit(
                waitingThreshold: const Duration(seconds: 1),
                confirmIncomplete: (issue) async {
                  issues.add(issue);
                  return false;
                },
              )
              .then((result) {
                settled = true;
                return result;
              });
          if (mode == 'gated-human') {
            await tester.pump(const Duration(milliseconds: 500));
            f.delays.single.release.complete();
            await tester.pump();
          }
          expect(confirmations, 1);
          await tester.pump(const Duration(seconds: 20));
          expect(settled, isFalse);
          expect(issues, isEmpty);
          expect(f.exitCalls, isEmpty);
          human.complete(true);
          expect(await ordinary, {'count': 8});
          expect(await pending, isTrue);
          expect(f.exitCalls, [_extensionId.value]);
          expect(_read(eval, 'retainedData'), {'count': 8});
          await tester.pumpWidget(const SizedBox.shrink());
          expect(tester.takeException(), isNull);
        },
      );
    }

    for (final override in [false, true]) {
      testWidgets(
        'ordinary confirmation waits behind recovery and active-work decisions (override=$override)',
        (tester) async {
          final f = await fixture(tester);
          f.contribute(exitMode: 'accept');
          await f.gated(() async {
            await tester.pumpWidget(f.widget());
            await tester.pumpAndSettle();
          });
          final eval = f.pane('first').runtime;
          final human = Completer<bool>();
          var confirmations = 0;
          f.confirm = (_, _) {
            confirmations++;
            return human.future;
          };
          final ordinary = _invoke(eval, 'startGatedOperation', [
            $String('gated-human'),
            12,
          ]);
          await tester.pump();
          final recovery = Completer<bool>();
          final active = Completer<bool>();
          final pending = f.host.prepareToExit(
            waitingThreshold: const Duration(seconds: 1),
            confirmIncomplete: (_) => recovery.future,
            confirmActiveWork: () => active.future,
          );
          await tester.pump(const Duration(seconds: 1));
          f.delays.single.release.complete();
          await tester.pump();
          expect(confirmations, 0);
          recovery.complete(override);
          await tester.pump();
          if (override) {
            expect(confirmations, 0);
            active.complete(false);
          }
          expect(await pending, isFalse);
          await tester.pump();
          expect(confirmations, 1);
          human.complete(true);
          expect(await ordinary, {'count': 12});
          expect(_read(eval, 'retainedData'), {'count': 12});
          expect(await f.host.prepareToExit(), isTrue);
          await tester.pumpWidget(const SizedBox.shrink());
          expect(tester.takeException(), isNull);
        },
      );
    }

    for (final accepted in [false, true]) {
      testWidgets(
        'plugin human decision beyond the threshold is respected ($accepted)',
        (tester) async {
          final f = await fixture(tester);
          f.contribute(exitMode: 'human');
          await tester.pumpWidget(f.widget());
          await tester.pumpAndSettle();
          final pane = f.pane('first');
          final initializations = _read(pane.runtime, 'initializations');
          final human = Completer<bool>();
          var confirmations = 0;
          var activeChecks = 0;
          final issues = <ExitPreflightIssue>[];
          f.confirm = (_, _) {
            confirmations++;
            return human.future;
          };
          var settled = false;
          final pending = f.host
              .prepareToExit(
                waitingThreshold: const Duration(seconds: 1),
                confirmIncomplete: (issue) async {
                  issues.add(issue);
                  return true;
                },
                confirmActiveWork: () async {
                  activeChecks++;
                  return true;
                },
              )
              .then((result) {
                settled = true;
                return result;
              });
          await tester.pump();
          expect(confirmations, 1);
          await tester.pump(const Duration(seconds: 20));
          expect(settled, isFalse);
          expect(issues, isEmpty);
          expect(activeChecks, 0);
          expect(pane.releases, 0);
          human.complete(accepted);
          expect(await pending, accepted);
          expect(activeChecks, accepted ? 1 : 0);
          expect(issues, isEmpty);
          expect(_read(pane.runtime, 'initializations'), initializations);
          expect(pane.focuses, 0);
          expect(pane.releases, 0);
          await tester.pumpWidget(const SizedBox.shrink());
          expect(tester.takeException(), isNull);
        },
      );
    }

    for (final mode in ['reject', 'malformed', 'exception']) {
      testWidgets(
        'exit $mode distinguishes refusal from safe unavailable recovery',
        (tester) async {
          final f = await fixture(tester);
          f.contribute(exitMode: mode);
          await tester.pumpWidget(f.widget());
          await tester.pumpAndSettle();
          final pane = f.pane('first');
          final issues = <ExitPreflightIssue>[];
          var activeChecks = 0;
          final accepted = await f.host.prepareToExit(
            confirmIncomplete: (issue) async {
              issues.add(issue);
              return true;
            },
            confirmActiveWork: () async {
              activeChecks++;
              return true;
            },
          );
          expect(accepted, mode != 'reject');
          expect(
            issues,
            mode == 'reject' ? isEmpty : [ExitPreflightIssue.unavailable],
          );
          expect(activeChecks, mode == 'reject' ? 0 : 1);
          expect(pane.releases, 0);
          expect(await _invoke(pane.runtime, 'writeOperation', [5]), {
            'count': 5,
          });
          await tester.pumpWidget(const SizedBox.shrink());
          expect(tester.takeException(), isNull);
        },
      );
    }

    testWidgets(
      'multiple participants share one nonhuman budget without early disposal or refresh',
      (tester) async {
        final f = await fixture(tester);
        f.contribute(exitMode: 'gate', id: 'test.first');
        f.contribute(exitMode: 'gate', id: 'test.second');
        await tester.pumpWidget(f.widget());
        await tester.pumpAndSettle();
        expect(f.panes, hasLength(4));
        final initializations = [
          for (final pane in f.panes) _read(pane.runtime, 'initializations'),
        ];
        final issues = <ExitPreflightIssue>[];
        final pending = f.gated(
          () => f.host.prepareToExit(
            waitingThreshold: const Duration(seconds: 1),
            confirmIncomplete: (issue) async {
              issues.add(issue);
              return false;
            },
          ),
        );
        await tester.pump();
        expect(f.exitCalls, ['test.first']);
        await tester.pump(const Duration(milliseconds: 600));
        f.delays.first.release.complete();
        await tester.pump();
        expect(f.exitCalls, ['test.first', 'test.second']);
        expect(f.delays, hasLength(2));
        expect(f.panes.map((pane) => pane.releases), everyElement(0));
        expect([
          for (final pane in f.panes) _read(pane.runtime, 'initializations'),
        ], initializations);
        await tester.pump(const Duration(milliseconds: 400));
        expect(issues, [ExitPreflightIssue.prolonged]);
        expect(await pending, isFalse);
        expect(f.delays.last.release.isCompleted, isFalse);
        expect(f.panes.map((pane) => pane.releases), everyElement(0));
        expect(f.panes.map((pane) => pane.focuses), everyElement(0));
        await tester.pumpWidget(const SizedBox.shrink());
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'ordinary drain and plugin checks share the same waiting budget',
      (tester) async {
        final f = await fixture(tester);
        f.contribute(exitMode: 'gate');
        await f.gated(() async {
          await tester.pumpWidget(f.widget());
          await tester.pumpAndSettle();
        });
        final eval = f.pane('first').runtime;
        final ordinary = f.gated(
          () => _invoke(eval, 'startGatedOperation', [$String('gate'), 9]),
        );
        await tester.pump();
        final issues = <ExitPreflightIssue>[];
        final pending = f.gated(
          () => f.host.prepareToExit(
            waitingThreshold: const Duration(seconds: 1),
            confirmIncomplete: (issue) async {
              issues.add(issue);
              return false;
            },
          ),
        );
        await tester.pump(const Duration(milliseconds: 600));
        expect(f.exitCalls, isEmpty);
        f.delays.single.release.complete();
        expect(await ordinary, {'count': 9});
        await tester.pump();
        expect(f.exitCalls, [_extensionId.value]);
        expect(f.delays, hasLength(2));
        await tester.pump(const Duration(milliseconds: 400));
        expect(issues, [ExitPreflightIssue.prolonged]);
        expect(await pending, isFalse);
        expect(_read(eval, 'retainedData'), {'count': 9});
        await tester.pumpWidget(const SizedBox.shrink());
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets('a newly registered exit participant requires a fresh check', (
      tester,
    ) async {
      final f = await fixture(tester);
      f.contribute(exitMode: 'gate', id: 'test.first');
      await tester.pumpWidget(f.widget());
      await tester.pumpAndSettle();
      final issues = <ExitPreflightIssue>[];
      final pending = f.gated(
        () => f.host.prepareToExit(
          confirmIncomplete: (issue) async {
            issues.add(issue);
            return false;
          },
        ),
      );
      await tester.pump();
      f.contribute(exitMode: 'accept', id: 'test.later');
      f.delays.single.release.complete();
      expect(await pending, isFalse);
      expect(issues, [ExitPreflightIssue.unavailable]);
      expect(f.exitCalls, ['test.first']);
      f.exitModes['test.first'] = 'accept';
      expect(await f.host.prepareToExit(), isTrue);
      expect(f.exitCalls, ['test.first', 'test.first', 'test.later']);
      await tester.pumpWidget(const SizedBox.shrink());
      expect(tester.takeException(), isNull);
    });

    for (final mode in ['gate', 'human']) {
      testWidgets(
        'retiring a pending $mode check reports unavailable and invalidates its dialog',
        (tester) async {
          final f = await fixture(tester);
          final registration = f.contribute(exitMode: mode);
          await tester.pumpWidget(f.widget());
          await tester.pumpAndSettle();
          final human = Completer<bool>();
          var invalidated = false;
          f.confirm = (_, ended) {
            ended.then((_) => invalidated = true);
            return human.future;
          };
          final issues = <ExitPreflightIssue>[];
          var activeChecks = 0;
          final pending = f.gated(
            () => f.host.prepareToExit(
              confirmIncomplete: (issue) async {
                issues.add(issue);
                return false;
              },
              confirmActiveWork: () async {
                activeChecks++;
                return true;
              },
            ),
          );
          await tester.pump();
          expect(f.exitCalls, [_extensionId.value]);
          expect(await f.host.prepareToExit(), isFalse);
          // Match activation retirement: revoke this descriptor, then close
          // its exact registration, rather than merely detaching its views.
          f.host.retire(f.descriptors.single);
          await registration.close();
          await tester.pump();
          expect(issues, [ExitPreflightIssue.unavailable]);
          expect(await pending, isFalse);
          expect(activeChecks, 0);
          if (mode == 'human') {
            expect(invalidated, isTrue);
            human.complete(true);
          } else {
            f.delays.single.release.complete();
          }
          await tester.pump();
          expect(issues, hasLength(1));
          f.contribute(exitMode: 'accept');
          await tester.pumpAndSettle();
          expect(await f.host.prepareToExit(), isTrue);
          expect(f.exitCalls, [_extensionId.value, _extensionId.value]);
          await tester.pumpWidget(const SizedBox.shrink());
          expect(tester.takeException(), isNull);
        },
      );
    }
  });
}

Object? _read(Runtime runtime, String entrypoint) =>
    copyStructuredBridgeData(runtime.executeLib(_library, entrypoint));

Future<Object?> _invoke(
  Runtime runtime,
  String entrypoint, [
  List<Object?> arguments = const [],
]) async => copyStructuredBridgeData(
  await runtime.executeLib(_library, entrypoint, arguments),
);

bool _request(
  Runtime runtime, {
  String kind = _kind,
  String occurrence = _occurrence,
}) =>
    copyStructuredBridgeData(
          runtime.executeLib(_library, 'request', [
            $String(kind),
            $String(occurrence),
          ]),
        )
        as bool;

Session _session(String id) => Session(
  id: SessionId(id),
  taskId: TaskId('task'),
  strategyId: OrchestrationStrategyId('test.unavailable'),
);

void _publish(AdeleRuntime runtime, List<Session> sessions) {
  final project = Project(
    id: ProjectId('project'),
    sourceLocation: Uri.parse('file:///inspection-probe'),
  );
  final task = Task(id: TaskId('task'), projectId: project.id, title: 'Task');
  runtime.store.publishRestoredProject(
    project: project,
    tasks: [task],
    environments: [
      Environment(
        id: EnvironmentId('environment'),
        taskId: task.id,
        role: EnvironmentRole.primary,
        providerId: ProviderId('test.unavailable'),
        providerState: const {},
      ),
    ],
    sessions: sessions,
    authorities: [
      for (final session in sessions)
        (session.id, EnvironmentId('environment')),
    ],
    runRecords: [],
  );
}

final class _Fixture {
  _Fixture(
    this.generation,
    Directory directory, {
    required bool canonicalRuntime,
    required bool callback,
  }) {
    _publish(runtime, [session, other]);
    host = PreparedMainContentHost(
      environmentRuntime: canonicalRuntime
          ? runtime.lifecycle.environmentRuntime
          : null,
      inspectSessionContent: callback
          ? (session, kind, occurrence) {
              if (!interactive) return false;
              requests.add((session, kind, occurrence));
              return true;
            }
          : null,
      confirm: (request, invalidated) => confirm(request, invalidated),
      createBinding:
          ({
            required installation,
            required descriptor,
            required session,
            required paneId,
          }) {
            final pane = _Pane(paneId);
            panes.add(pane);
            return PreparedMainContentPaneBinding(
              createBridge: (_) =>
                  _RecordingBridge((runtime) => pane.runtime = runtime),
              requestFocus: () => pane.focuses++,
              release: () => pane.releases++,
            );
          },
    );
    installation = PreparedPluginInstallation(
      metadata: PluginMetadata(
        id: PluginId('test.inspection-probe'),
        version: '1',
        displayName: 'Inspection probe',
      ),
      installationDirectory: directory,
      backendArtifactUri: null,
    );
  }

  final PreparedFrontend generation;
  final runtime = AdeleRuntime();
  final extensions = ExtensionRegistry();
  final session = _session('session');
  final other = _session('other');
  final panes = <_Pane>[];
  final requests =
      <(Session, SessionContentKind, SessionContentOccurrenceId)>[];
  final _registrations = <ExtensionRegistration>[];
  final descriptors = <PreparedMainContentPresentation>[];
  final exitModes = <String, String>{};
  final exitCalls = <String>[];
  final delays = <_GatedTimer>[];
  Future<bool> Function(Map<String, Object?>, Future<void>) confirm =
      (_, _) async => true;
  late final PreparedMainContentHost host;
  late final PreparedPluginInstallation installation;
  bool interactive = true;
  bool attachmentCurrent = true;

  _Pane pane(String id) => panes.lastWhere((pane) => pane.id == id);

  // Intercept only the fixture's distinctive EVC Future.delayed. All host
  // deadlines still use testWidgets' fake timers, while each plugin wait has
  // an independent Completer that can stay pending across exit attempts.
  T gated<T>(T Function() action) => runZoned(
    action,
    zoneSpecification: ZoneSpecification(
      createTimer: (self, parent, zone, duration, callback) {
        if (duration != const Duration(days: 1)) {
          return parent.createTimer(zone, duration, callback);
        }
        final timer = _GatedTimer(zone, callback);
        delays.add(timer);
        return timer;
      },
    ),
  );

  ExtensionRegistration contribute({
    bool allowed = false,
    bool sessionExecution = false,
    bool acceptExit = false,
    String? exitMode,
    String? id,
    PreparedSessionServices? services,
  }) {
    final descriptor = PreparedMainContentPresentation(
      extensionId: id == null ? _extensionId : ExtensionId(id),
      order: 100,
      library: _library,
      initialize: 'initialize',
      entrypoint: 'buildPane',
      canInspectSessionContent: allowed,
      sessionExecution: sessionExecution,
      retainedData: true,
      operations: {
        'probe': 'operation',
        'write': 'writeRetained',
        'gated': 'gatedOperation',
        'exit': exitMode != null
            ? 'preflightExit'
            : acceptExit
            ? 'acceptExit'
            : 'exit',
      },
      exitOperation: 'exit',
      actions: [
        PreparedMainContentAction(
          id: 'probe',
          label: 'Probe input',
          entrypoint: 'buildAction',
        ),
      ],
    );
    descriptors.add(descriptor);
    exitModes[descriptor.extensionId.value] = exitMode ?? 'accept';
    final registration = extensions.register(
      point: mainContentContributions,
      id: descriptor.extensionId,
      value: host.createContribution(
        extensions: extensions,
        installation: installation,
        generation: generation,
        descriptor: descriptor,
        isActive: () => true,
        services: services,
        readSetting: (key) {
          final name = descriptor.extensionId.value;
          if (key == 'exit-entered') exitCalls.add(name);
          return key == 'exit-mode' ? exitModes[name]! : name;
        },
      ),
    );
    _registrations.add(registration);
    return registration;
  }

  Widget widget({Session? session}) => MaterialApp(
    home: Scaffold(
      body: MainContentHost(
        session: session ?? this.session,
        extensions: extensions,
        actionCoordinator: host.actionCoordinator,
        isCurrent: () => attachmentCurrent,
      ),
    ),
  );

  void expectNoEnvironmentWork() {
    expect(
      runtime.registry.providersFor(environmentProviderCapability),
      isEmpty,
    );
    expect(
      runtime.lifecycle.environmentRuntime.currentMaterialization(
        EnvironmentId('environment'),
      ),
      isNull,
    );
    expect(runtime.store.runsForSession(session.id), isEmpty);
    expect(runtime.store.runsForSession(other.id), isEmpty);
  }

  Future<void> close() async {
    for (final registration in _registrations.reversed) {
      await registration.close();
    }
    await host.close();
    generation.invalidate();
    await runtime.close();
  }
}

final class _Pane {
  _Pane(this.id);
  final String id;
  late Runtime runtime;
  var focuses = 0;
  var releases = 0;
}

final class _GatedTimer implements Timer {
  _GatedTimer(Zone zone, void Function() callback) {
    release.future.then((_) {
      if (!isActive) return;
      isActive = false;
      tick = 1;
      zone.runGuarded(callback);
    });
  }

  final release = Completer<void>();
  @override
  bool isActive = true;
  @override
  int tick = 0;
  @override
  void cancel() => isActive = false;
}

final class _RecordingBridge implements PreparedFrontendBridge {
  _RecordingBridge(this.record);
  final void Function(Runtime) record;
  @override
  String get identifier => 'test.inspection-recording';
  @override
  void configureForCompile(BridgeDeclarationRegistry registry) {}
  @override
  void configureForRuntime(Runtime runtime) => record(runtime);
  @override
  void invalidate() {}
}

const _source = r'''
import 'package:flutter/material.dart';
import 'package:adele_ui/main_content_bridge.dart';
import 'package:adele_ui/contribution_bridge.dart';

bool request(String kind, String occurrence) => inspectSessionContent(kind, occurrence);
String paneId() => readMainContentPaneId();
bool removeFirst() => removeMainContentPane('first');
bool openFirst() => openMainContentPane('first', 'Replacement', true);

void initialize() {
  final previous = readContributionData('initializations');
  int count = previous['count'] ?? 0;
  writeContributionData('initializations', <String, dynamic>{'count': count + 1});
  final accepted = inspectSessionContent('test.content', 'initializer');
  if (readMainContentPanes().isEmpty) {
    openMainContentPane('first', accepted ? 'Init accepted' : 'Init denied', true);
    openMainContentPane('second', 'Sibling', true);
  }
}
Widget buildPane() => TextButton(
  onPressed: () { inspectSessionContent('test.content', 'cached'); },
  child: Text('Inspect ' + readMainContentPaneId()),
);
Future<Map<String, dynamic>> operation() async => <String, dynamic>{
  'accepted': inspectSessionContent('test.content', 'operation'),
};
Future<Map<String, dynamic>> probeOperation() async =>
    await invokeContributionOperation('probe', <String, dynamic>{});
Future<Map<String, dynamic>> exit() async => <String, dynamic>{'accepted': false};
Future<Map<String, dynamic>> acceptExit() async => <String, dynamic>{'accepted': true};
Map<String, dynamic> initializations() => readContributionData('initializations');
Future<bool> humanDecision() async => await confirmContribution(<String, dynamic>{
  'title': readPluginSetting('name'), 'message': 'Retained work',
  'acceptLabel': 'Continue', 'cancelLabel': 'Cancel',
});
Future<Map<String, dynamic>> preflightExit() async {
  String mode = readPluginSetting('exit-mode') as String;
  readPluginSetting('exit-entered');
  if (mode == 'gate' || mode == 'late-write' || mode == 'late-native' || mode == 'gated-human') {
    await Future.delayed(const Duration(days: 1));
  }
  if (mode == 'late-write') {
    writeContributionData('draft', <String, dynamic>{'count': 999});
  }
  if (mode == 'late-native') {
    await confirmContribution(<String, dynamic>{
      'title': 'Late native call', 'message': 'Must not open',
      'acceptLabel': 'Continue', 'cancelLabel': 'Cancel',
    });
    writeContributionData('draft', <String, dynamic>{'count': 999});
  }
  if (mode == 'human' || mode == 'gated-human') {
    final accepted = await humanDecision();
    return <String, dynamic>{'accepted': accepted, 'focus': 'first'};
  }
  if (mode == 'reject') return <String, dynamic>{'accepted': false};
  if (mode == 'malformed') return <String, dynamic>{'accepted': 'true', 'message': 'private /plugin/path'};
  if (mode == 'exception') throw StateError('private /plugin/path');
  return <String, dynamic>{'accepted': true, 'focus': 'first'};
}
Future<Map<String, dynamic>> gatedOperation() async {
  final args = readContributionArguments()!;
  String mode = args['mode'];
  if (mode != 'human') await Future.delayed(const Duration(days: 1));
  if (mode == 'human' || mode == 'gated-human') await humanDecision();
  writeContributionData('draft', <String, dynamic>{'count': args['count']});
  return <String, dynamic>{'count': args['count']};
}
Future<Map<String, dynamic>> startGatedOperation(String mode, int count) async =>
    await invokeContributionOperation('gated', <String, dynamic>{'mode': mode, 'count': count});
Map<String, dynamic> retainedData() => readContributionData('draft');
Future<Map<String, dynamic>> writeRetained() async {
  final next = <String, dynamic>{'count': readContributionArguments()!['count']};
  writeContributionData('draft', next);
  return next;
}
Future<Map<String, dynamic>> writeOperation(int count) async =>
    await invokeContributionOperation('write', <String, dynamic>{'count': count});
Map<String, dynamic> actionResult() => readContributionData('action-result');
Widget buildAction() => TextButton(
  onPressed: () {
    final accepted = inspectSessionContent('test.content', 'action');
    writeContributionData('action-result', <String, dynamic>{'accepted': accepted});
  },
  child: Text(inspectSessionContent('test.content', 'action-build') ? 'Action accepted' : 'Action denied'),
);
''';
