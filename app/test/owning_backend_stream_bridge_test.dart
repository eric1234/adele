import 'dart:async';
import 'dart:io';

import 'package:adele_contract/adele_contract.dart';
import 'package:adele_desktop/frontend/owning_backend_bridge.dart';
import 'package:adele_desktop/frontend/prepared_frontend.dart';
import 'package:contract_codegen/contract_codegen.dart';
import 'package:dart_eval/dart_eval.dart';
import 'package:flutter/material.dart';
import 'package:flutter_eval/flutter_eval.dart';
import 'package:flutter_test/flutter_test.dart';

const _library = 'package:stream_fixture/main.dart';

void main() {
  late Directory temporary;
  late File artifact;
  late PreparedFrontend frontend;

  setUpAll(() async {
    final parent = await Directory('.dart_tool').create(recursive: true);
    temporary = await parent.createTemp('adele-stream-evc-');
    artifact = File('${temporary.path}/stream.evc');
    var sdk = File(Platform.resolvedExecutable).parent;
    while (!File('${sdk.path}/dart-sdk/lib/core/core.dart').existsSync()) {
      if (sdk.parent.path == sdk.path) {
        throw StateError('Pinned SDK not found.');
      }
      sdk = sdk.parent;
    }
    final source = File(
      '${temporary.path}/owning_backend_stream_contract.dart',
    );
    await source.writeAsString(
      await File(
        'test/fixtures/owning_backend_stream_contract.dart.txt',
      ).readAsString(),
    );
    final generated = await ContractGenerator(
      sdkPath: '${sdk.path}/dart-sdk',
    ).generateEvalClient(source);
    final compiler = Compiler()
      ..addPlugin(flutterEvalPlugin)
      ..addPlugin(const OwningBackendDeclarations())
      ..entrypoints.addAll([
        _library,
        'package:stream_fixture/contract.dart',
        'package:adele_contract/adele_contract.dart',
      ]);
    final program = compiler.compile({
      'stream_fixture': {
        'main.dart': await File(
          'test/fixtures/owning_backend_stream_frontend.dart.txt',
        ).readAsString(),
        'contract.dart': generated,
      },
      'adele_contract': {'adele_contract.dart': evalContractSupportSource},
      'adele_ui': {
        'owning_backend_bridge.dart': await File(
          '../packages/ui/lib/owning_backend_bridge.dart',
        ).readAsString(),
      },
    });
    await artifact.writeAsBytes(program.write());
  });
  tearDownAll(() => temporary.delete(recursive: true));
  setUp(() async => frontend = await PreparedFrontend.load(artifact));
  tearDown(() => frontend.invalidate());

  Future<OwningBackendBridge> mount(
    WidgetTester tester,
    _Channel channel, {
    void Function()? validate,
    String entrypoint = 'buildView',
  }) async {
    final bridge = OwningBackendBridge(
      channels: {'fixture.stream': channel},
      validateBinding: validate ?? () {},
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: frontend.createPresentation(
            library: _library,
            entrypoint: entrypoint,
            createBridge: () => bridge,
          ),
        ),
      ),
    );
    await tester.pump();
    return bridge;
  }

  testWidgets('generated DTO stream crosses actual prepared EVC', (
    tester,
  ) async {
    final channel = _Channel();
    await mount(tester, channel);
    expect(find.text('idle'), findsOneWidget);
    expect(channel.opens, 0);
    await tester.tap(find.text('Listen'));
    await tester.pump();
    expect(channel.opens, 1);
    channel.events.add({'sequence': 1, 'text': 'generated'});
    await tester.pump();
    expect(find.text('1:generated'), findsOneWidget);
    await channel.events.close();
    await tester.pump();
    await tester.pump();
    expect(
      tester.widgetList<Text>(find.byType(Text)).map((text) => text.data),
      contains('1:generated:done'),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('unary remains usable alongside streams', (tester) async {
    final channel = _Channel();
    await mount(tester, channel);
    await tester.tap(find.text('Read'));
    await tester.pump();
    expect(find.text('0:unary'), findsOneWidget);
    expect(channel.opens, 0);
  });

  testWidgets(
    'safe settlement preserves generated DTOs and hides native failures',
    (tester) async {
      final channel = _Channel();
      await mount(tester, channel);
      await tester.tap(find.text('Read settled'));
      await tester.pump();
      expect(find.text('settled:0:unary'), findsOneWidget);
      channel.failRead = true;
      await tester.tap(find.text('Read settled'));
      await tester.pump();
      expect(find.text('settled:unavailable'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('safe settlement rejects a result admitted before retirement', (
    tester,
  ) async {
    final channel = _Channel()..pendingRead = Completer<Object?>();
    final bridge = await mount(tester, channel);
    await tester.tap(find.text('Read settled'));
    await tester.pump();
    bridge.invalidate();
    channel.pendingRead!.complete({
      'sequence': 1,
      'text': 'late-private-result',
    });
    await tester.pump();
    expect(find.text('settled:unavailable'), findsOneWidget);
    expect(find.textContaining('late-private-result'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  for (final nullData in [true, false]) {
    testWidgets('explicit null stream callbacks with nullData=$nullData', (
      tester,
    ) async {
      final channel = _Channel();
      await mount(tester, channel);
      await tester.tap(
        find.text(nullData ? 'Null Data' : 'Null Error And Done'),
      );
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(channel.opens, 1);
      channel.events.add({'sequence': 1, 'text': 'generated'});
      await tester.pump();
      expect(find.text(nullData ? 'idle' : '1:generated'), findsOneWidget);
      await channel.events.close();
      await tester.pump();
      expect(
        find.text(nullData ? 'null-data:done' : '1:generated'),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('watch callbacks can call generated unary clients', (
    tester,
  ) async {
    final channel = _Channel();
    await mount(tester, channel, entrypoint: 'buildReadingView');
    await tester.tap(find.text('Listen'));
    for (var sequence = 1; sequence <= 3; sequence++) {
      channel.events.add({'sequence': sequence, 'text': 'notification'});
      await tester.pump();
      await tester.pump();
      expect(find.text('0:unary'), findsOneWidget);
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('pause resume and cancel reach the producer', (tester) async {
    final channel = _Channel();
    await mount(tester, channel);
    await tester.tap(find.text('Listen'));
    await tester.tap(find.text('Pause'));
    await tester.pump();
    expect(channel.events.isPaused, isTrue);
    channel.events.add({'sequence': 1, 'text': 'paused'});
    await tester.pump();
    expect(find.text('idle'), findsOneWidget);
    await tester.tap(find.text('Resume'));
    await tester.pump();
    expect(find.text('1:paused'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pump();
    expect(channel.cancels, 1);
    channel.events.add({'sequence': 2, 'text': 'late'});
    await tester.pump();
    expect(find.text('1:paused'), findsOneWidget);
  });

  for (final hangs in [false, true]) {
    testWidgets(
      'native cancel still reports ${hangs ? 'timed out' : 'rejected'} cleanup',
      (tester) async {
        final cancellation = Completer<void>();
        final channel = _Channel(onCancel: () => cancellation.future);
        final bridge = OwningBackendBridge(
          channels: {'fixture.stream': channel},
          validateBinding: () {},
        );
        addTearDown(bridge.invalidate);
        final subscription = bridge
            .stream('fixture.stream', 'fixture.stream.watch', {
              'scope': 'captured',
            })
            .listen((_) {});
        final failure = StateError('SECRET cleanup diagnostic');
        final check = expectLater(
          subscription.cancel(),
          throwsA(hangs ? isA<TimeoutException>() : same(failure)),
        );
        expect(channel.cancels, 1);
        expect(channel.events.hasListener, isFalse);
        if (!hangs) cancellation.completeError(failure);
        await tester.pump(const Duration(seconds: 3));
        await check;
        if (hangs) cancellation.completeError(failure);
        unawaited(channel.events.close());
        await tester.pump();
        expect(channel.cancels, 1);
        expect(tester.takeException(), isNull);
      },
    );

    for (final revoke in ['consumer cancel', 'disposal', 'retirement']) {
      testWidgets(
        'generated EVC $revoke contains ${hangs ? 'hung' : 'rejected'} producer cancellation',
        (tester) async {
          final cancellation = Completer<void>();
          final channel = _Channel(onCancel: () => cancellation.future);
          final unrelated = _Channel();
          final independent = (await tester.runAsync(
            () => PreparedFrontend.load(artifact),
          ))!;
          addTearDown(independent.invalidate);
          final subject = frontend.createPresentation(
            library: _library,
            entrypoint: 'buildView',
            createBridge: () => OwningBackendBridge(
              channels: {'fixture.stream': channel},
              validateBinding: () {},
            ),
          );
          final sibling = independent.createPresentation(
            library: _library,
            entrypoint: 'buildView',
            createBridge: () => OwningBackendBridge(
              channels: {'fixture.stream': unrelated},
              validateBinding: () {},
            ),
          );
          const subjectKey = ValueKey('subject');
          const siblingKey = ValueKey('sibling');
          Widget views({bool showSubject = true}) => MaterialApp(
            home: Scaffold(
              body: Row(
                children: [
                  Expanded(
                    child: SizedBox(
                      key: subjectKey,
                      child: showSubject ? subject : const SizedBox.shrink(),
                    ),
                  ),
                  Expanded(
                    child: SizedBox(key: siblingKey, child: sibling),
                  ),
                ],
              ),
            ),
          );
          Finder subjectText(String text) => find.descendant(
            of: find.byKey(subjectKey),
            matching: find.text(text),
          );
          Finder siblingText(String text) => find.descendant(
            of: find.byKey(siblingKey),
            matching: find.text(text),
          );

          await tester.pumpWidget(views());
          await tester.tap(subjectText('Listen'));
          await tester.tap(siblingText('Listen'));
          channel.events.add({'sequence': 1, 'text': 'before'});
          unrelated.events.add({'sequence': 1, 'text': 'independent'});
          await tester.pump();
          expect(subjectText('1:before'), findsOneWidget);
          expect(siblingText('1:independent'), findsOneWidget);

          switch (revoke) {
            case 'consumer cancel':
              await tester.tap(subjectText('Cancel'));
              // Repeated consumer cancellation must reuse the same cleanup.
              await tester.tap(subjectText('Cancel'));
            case 'disposal':
              await tester.pumpWidget(views(showSubject: false));
            case 'retirement':
              frontend.retainPresentations();
          }
          expect(channel.cancels, 1);
          expect(channel.opens, 1);
          expect(channel.events.hasListener, isFalse);
          expect(unrelated.events.hasListener, isTrue);
          expect(cancellation.isCompleted, isFalse);
          channel.events.add({'sequence': 2, 'text': 'late-before-cleanup'});
          unrelated.events.add({'sequence': 2, 'text': 'still-live'});
          await tester.pump();
          expect(find.textContaining('late-before-cleanup'), findsNothing);
          expect(siblingText('2:still-live'), findsOneWidget);
          if (revoke != 'disposal') {
            expect(subjectText('1:before'), findsOneWidget);
          }
          if (revoke == 'consumer cancel') {
            expect(subjectText('cancel:pending'), findsOneWidget);
          }

          if (!hangs) {
            cancellation.completeError(StateError('SECRET cleanup diagnostic'));
          }
          // Advance Flutter's fake clock beyond the unchanged native 2s bound.
          await tester.pump(const Duration(seconds: 3));
          await tester.pump();
          if (revoke == 'consumer cancel') {
            expect(subjectText('cancel:settled'), findsOneWidget);
          }
          if (hangs) {
            expect(cancellation.isCompleted, isFalse);
            // A rejection after the timeout must also remain observed.
            cancellation.completeError(StateError('SECRET late cleanup'));
          }
          channel.events.add({'sequence': 3, 'text': 'late-after-cleanup'});
          unrelated.events.add({'sequence': 3, 'text': 'unaffected'});
          await tester.pump();
          await tester.pump();
          expect(siblingText('3:unaffected'), findsOneWidget);
          expect(find.textContaining('late-after-cleanup'), findsNothing);
          expect(find.textContaining('SECRET'), findsNothing);
          expect(find.text('Frontend unavailable.'), findsNothing);
          expect(tester.takeException(), isNull);
          expect(channel.opens, 1);
          expect(channel.cancels, 1);
          expect(unrelated.opens, 1);
          expect(unrelated.cancels, 0);
          if (revoke != 'disposal') {
            expect(subjectText('1:before'), findsOneWidget);
          }

          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pump();
          expect(channel.cancels, 1);
          expect(unrelated.cancels, 1);
          unawaited(channel.events.close());
          unawaited(unrelated.events.close());
          await tester.pump();
          expect(tester.takeException(), isNull);
        },
      );
    }
  }

  for (final malformed in [false, true]) {
    testWidgets(
      '${malformed ? 'malformed generated DTO' : 'native error'} affects only observation',
      (tester) async {
        final channel = _Channel();
        await mount(tester, channel);
        await tester.tap(find.text('Listen'));
        if (malformed) {
          channel.events.add({'sequence': 'bad', 'text': 'secret'});
        } else {
          channel.events.addError(StateError('SECRET native diagnostic'));
        }
        await tester.pump();
        await tester.pump();
        expect(
          find.text(
            malformed
                ? 'error:Invalid backend stream item.:done'
                : 'error:Backend stream unavailable.:done',
          ),
          findsOneWidget,
        );
        expect(find.text('Frontend unavailable.'), findsNothing);
        expect(channel.cancels, 1);
        await tester.tap(find.text('Read'));
        await tester.pump();
        expect(find.text('0:unary'), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('retirement cancels paused observation and fences late events', (
    tester,
  ) async {
    final channel = _Channel();
    final bridge = await mount(tester, channel);
    await tester.tap(find.text('Listen'));
    await tester.tap(find.text('Pause'));
    channel.events.add({'sequence': 1, 'text': 'queued'});
    frontend.retainPresentations();
    await tester.pump();
    expect(channel.cancels, 1);
    channel.events.add({'sequence': 2, 'text': 'late'});
    await tester.tap(find.text('Resume'));
    await tester.pump();
    expect(find.text('idle'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await expectLater(
      bridge.request('fixture.stream', 'read', {}),
      throwsStateError,
    );
  });

  test('stream admission is lazy and rejects undeclared services', () async {
    var validations = 0;
    final channel = _Channel();
    final bridge = OwningBackendBridge(
      channels: {'fixture.stream': channel},
      validateBinding: () {
        validations++;
      },
    );
    final stream = bridge.stream('missing', 'watch', {});
    expect(validations, 0);
    expect(channel.opens, 0);
    await expectLater(stream, emitsError(isA<StateError>()));
    expect(channel.opens, 0);
    bridge.invalidate();
  });

  test(
    'stream preserves failure and done when producer cancellation rejects',
    () async {
      final channel = _Channel(failCancel: true);
      final bridge = OwningBackendBridge(
        channels: {'fixture.stream': channel},
        validateBinding: () {},
      );
      final primary = StateError('primary');
      final check = expectLater(
        bridge.stream('fixture.stream', 'fixture.stream.watch', {
          'scope': 'captured',
        }),
        emitsInOrder([emitsError(same(primary)), emitsDone]),
      );
      channel.events.addError(primary);
      await check;
      expect(channel.cancels, 1);
      bridge.invalidate();
    },
  );
  test('retirement during delivery cancels before deferred done', () async {
    final channel = _Channel();
    final bridge = OwningBackendBridge(
      channels: {'fixture.stream': channel},
      validateBinding: () {},
    );
    final done = Completer<void>();
    var items = 0;
    bridge
        .stream('fixture.stream', 'fixture.stream.watch', {'scope': 'captured'})
        .listen((_) {
          items++;
          bridge.invalidate();
        }, onDone: done.complete);
    channel.events.add({'sequence': 1, 'text': 'item'});
    channel.events.add({'sequence': 2, 'text': 'late'});
    await done.future;
    expect(items, 1);
    expect(channel.cancels, 1);
  });
}

class _Channel implements AdeleStreamChannel {
  _Channel({bool failCancel = false, Future<void> Function()? onCancel}) {
    events = StreamController<Object?>(
      onCancel: () {
        cancels++;
        if (failCancel) throw StateError('SECRET cleanup diagnostic');
        return onCancel?.call();
      },
    );
  }
  late final StreamController<Object?> events;
  int opens = 0;
  int cancels = 0;
  bool failRead = false;
  Completer<Object?>? pendingRead;

  @override
  Stream<Object?> stream(String method, Map<String, Object?> payload) {
    expectSync(method, 'fixture.stream.watch');
    expectSync(payload, {'scope': 'captured'});
    opens++;
    return events.stream;
  }

  @override
  Future<Object?> request(String method, Map<String, Object?> payload) async {
    if (failRead) throw StateError('SECRET backend diagnostic');
    if (pendingRead case final pending?) return pending.future;
    return {'sequence': 0, 'text': 'unary'};
  }
}
