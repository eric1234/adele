import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:adele_desktop/frontend/application_frontend_bootstrap.dart';
import 'package:adele_desktop/frontend/main_content_bridge.dart';
import 'package:adele_desktop/frontend/prepared_frontend.dart';
import 'package:adele_desktop/frontend/prepared_main_content_host.dart';
import 'package:adele_desktop/frontend/structured_bridge_data.dart';
import 'package:adele_desktop/ui/main_content/main_content_host.dart';
import 'package:adele_plugin_api/adele_plugin_api.dart';
import 'package:adele_product/adele_product.dart';
import 'package:adele_ui/adele_ui.dart';
import 'package:adele_ui/main_content_bridge.dart' as public_bridge;
import 'package:dart_eval/dart_eval.dart';
import 'package:dart_eval/dart_eval_bridge.dart';
import 'package:dart_eval/stdlib/core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_eval/flutter_eval.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plugin_runtime/plugin_runtime.dart';

const _library = 'package:prepared_panes/main.dart';
final _extensionId = ExtensionId('test.prepared-panes');

void main() {
  late Directory temporary;
  late File artifact;
  late Program program;
  var sequence = 0;

  setUpAll(() async {
    temporary = await Directory.systemTemp.createTemp('prepared-main-content-');
    program =
        (Compiler()
              ..addPlugin(flutterEvalPlugin)
              ..addPlugin(const MainContentDeclarations())
              ..entrypoints.add(_library))
            .compile({
              'prepared_panes': {'main.dart': _source},
              'adele_ui': {
                'main_content_bridge.dart': await File(
                  '../packages/ui/lib/main_content_bridge.dart',
                ).readAsString(),
              },
            });
    artifact = await File(
      '${temporary.path}/panes.evc',
    ).writeAsBytes(program.write());
  });
  tearDownAll(() => temporary.delete(recursive: true));

  late ExtensionRegistry extensions;
  late Session session;
  setUp(() {
    extensions = ExtensionRegistry();
    session = Session(
      id: SessionId('session'),
      taskId: TaskId('task'),
      strategyId: OrchestrationStrategyId('test.strategy'),
    );
    extensions.register(
      point: mainContentContributions,
      id: ExtensionId('test.independent'),
      value: MainContentContribution(
        order: 100,
        attach: (access) => access.open(
          MainContentPane(
            id: 'independent',
            title: 'Independent',
            createPresentation: () => const Text('Independent content'),
          ),
        ),
      ),
    );
  });

  Future<ApplicationFrontendBootstrap> activate({
    PreparedMainContentHost? host,
    String initialize = 'initializePanes',
    String entrypoint = 'buildPane',
  }) async {
    final root = await Directory(
      '${temporary.path}/case-${sequence++}',
    ).create();
    final installation = await Directory('${root.path}/plugin').create();
    await artifact.copy('${installation.path}/frontend.evc');
    await File(
      '${installation.path}/adele_plugin.installation.json',
    ).writeAsString(
      jsonEncode({
        'manifestVersion': 1,
        'metadata': {
          'id': 'test.prepared',
          'version': '1',
          'displayName': 'Panes',
        },
        'components': {
          'frontend': {
            'artifact': 'frontend.evc',
            'presentations': [
              {
                'role': 'mainContent',
                'extensionId': _extensionId.value,
                'order': 200,
                'library': _library,
                'initialize': initialize,
                'entrypoint': entrypoint,
              },
            ],
          },
        },
      }),
    );
    final catalog = await PreparedPluginCatalog.discover(root.path);
    expect(catalog.issues, isEmpty);
    final bootstrap = ApplicationFrontendBootstrap(
      extensions: extensions,
      mainContentHost: host,
    );
    addTearDown(bootstrap.close);
    await bootstrap.start(catalog);
    return bootstrap;
  }

  Widget host({Session? current, bool Function()? isCurrent}) => MaterialApp(
    home: Scaffold(
      body: MainContentHost(
        session: current ?? session,
        extensions: extensions,
        isCurrent: isCurrent,
      ),
    ),
  );

  test('public stubs and declarations do not provide native access', () {
    expect(public_bridge.readMainContentPanes, throwsUnsupportedError);
    expect(public_bridge.readMainContentContext, throwsUnsupportedError);
    expect(public_bridge.readMainContentPaneId, throwsUnsupportedError);
    expect(
      () => public_bridge.openMainContentPane('a', 'A', true),
      throwsUnsupportedError,
    );
    expect(
      () => public_bridge.setMainContentPaneTitle('a', 'A'),
      throwsUnsupportedError,
    );
    expect(
      () => public_bridge.setMainContentPaneOrder(['a']),
      throwsUnsupportedError,
    );
    expect(
      () => public_bridge.removeMainContentPane('a'),
      throwsUnsupportedError,
    );
    expect(
      () => public_bridge.focusMainContentPane('a', true),
      throwsUnsupportedError,
    );
    expect(
      () => const MainContentDeclarations().configureForRuntime(
        Runtime.ofProgram(program),
      ),
      throwsUnsupportedError,
    );
  });

  for (final missing in ['initialize', 'entrypoint']) {
    test(
      'activation validates $missing without invoking initialization',
      () async {
        var acquisitions = 0;
        final bootstrap = await activate(
          initialize: missing == 'initialize' ? 'missing' : 'initializePanes',
          entrypoint: missing == 'entrypoint' ? 'missing' : 'buildPane',
          host: PreparedMainContentHost(
            createBinding:
                ({
                  required installation,
                  required descriptor,
                  required session,
                  required paneId,
                }) {
                  acquisitions++;
                  return null;
                },
          ),
        );
        expect(
          bootstrap.generations.single.state,
          InstalledFrontendState.failed,
        );
        expect(extensions.discover(mainContentContributions), hasLength(1));
        expect(acquisitions, 0);
      },
    );
  }

  testWidgets(
    'default host mounts pure Flutter panes and preserves existing content',
    (tester) async {
      final bootstrap = await tester.runAsync(activate);
      expect(
        bootstrap!.generations.single.state,
        InstalledFrontendState.active,
      );
      await tester.pumpWidget(host());
      await tester.pumpAndSettle();
      final element = tester.element(find.text('body a'));
      _press(tester, 'Open from a');
      await tester.pumpAndSettle();
      expect(find.text('body b'), findsOneWidget);
      _press(tester, 'Rename a');
      await tester.pumpAndSettle();
      expect(find.text('Renamed a'), findsOneWidget);
      expect(tester.element(find.text('body a')), same(element));
      expect(find.text('Independent content'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'prepared requests validate data and fence removed same-ID panes immediately',
    (tester) async {
      final records = <_Binding>[];
      final prepared = PreparedMainContentHost(
        createBinding:
            ({
              required installation,
              required descriptor,
              required session,
              required paneId,
            }) {
              final record = _Binding(session, paneId);
              records.add(record);
              return record.binding;
            },
      );
      final bootstrap = await tester.runAsync(() => activate(host: prepared));
      expect(records, isEmpty);
      await tester.pumpWidget(host());
      await tester.pumpAndSettle();
      final a = records.single;
      expect(a.session, same(session));
      expect(a.call('context'), {
        'sessionId': session.id.value,
        'strategyId': session.strategyId.value,
        'taskId': session.taskId.value,
      });
      expect(a.call('paneId'), 'a');
      expect(a.call('panes'), [
        {'id': 'a', 'title': 'A', 'canClose': true},
      ]);
      expect(
        a.call('open', [$String('a'), $String('Duplicate'), $bool(false)]),
        isFalse,
      );
      expect(records, hasLength(1));
      expect(a.releases, 0);
      expect(a.focuses, 0);
      expect(a.call('panes'), [
        {'id': 'a', 'title': 'A', 'canClose': true},
      ]);
      expect(a.call('open', [$String('b'), $String('B'), $bool(true)]), isTrue);
      await tester.pumpAndSettle();
      final b = records.last;
      for (final (id, title) in [
        ('missing', 'New'),
        ('a', ''),
        ('a', 'bad\nline'),
      ]) {
        expect(a.call('rename', [$String(id), $String(title)]), isFalse);
      }
      expect(
        a.call('open', [$String('../bad'), $String('Bad'), $bool(true)]),
        isFalse,
      );
      expect(records, hasLength(2));
      expect(
        a.call('order', [
          wrapStructuredBridgeData(['a', 'a']),
        ]),
        isFalse,
      );
      expect(
        a.call('order', [
          wrapStructuredBridgeData(['b', 'a']),
        ]),
        isTrue,
      );
      expect((a.call('panes') as List).map((value) => (value as Map)['id']), [
        'b',
        'a',
      ]);
      expect(a.call('focus', [$String('missing'), $bool(true)]), isFalse);
      expect(a.call('focus', [$String('a'), $bool(false)]), isTrue);
      await tester.pump();
      expect(a.focuses, 0);
      expect(a.call('focus', [$String('a'), $bool(true)]), isTrue);
      await tester.pump();
      expect(a.focuses, 1);
      final staleRename = tester
          .widget<TextButton>(find.widgetWithText(TextButton, 'Rename a'))
          .onPressed!;
      expect(b.call('remove', [$String('a')]), isTrue);
      expect(a.releases, 1);
      expect(a.active!(), isFalse);
      expect(
        b.call('open', [$String('a'), $String('Replacement'), $bool(true)]),
        isTrue,
      );
      staleRename();
      expect(a.call('rename', [$String('a'), $String('Stale')]), isFalse);
      expect(a.call('panes'), isEmpty);
      expect(a.call('paneId'), '');
      expect(a.active!(), isFalse);
      await tester.pumpAndSettle();
      expect(a.releases, 1);
      expect(find.text('Replacement'), findsOneWidget);
      expect(find.text('Renamed a'), findsNothing);
      expect(records, hasLength(3));
      expect(records.last.runtimes.single, isNot(same(a.runtimes.single)));
      await bootstrap!.generations.single.retire(
        mainContentContributions,
        _extensionId,
      );
      expect(
        b.call('open', [$String('late'), $String('Late'), $bool(true)]),
        isFalse,
      );
      await tester.pumpAndSettle();
      expect(records.map((record) => record.releases), everyElement(1));
      await tester.pumpWidget(const SizedBox.shrink());
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'native readiness is captured once and pending removal cannot mount it later',
    (tester) async {
      final records = <_Binding>[];
      final ready = Completer<void>();
      final prepared = PreparedMainContentHost(
        createBinding:
            ({
              required installation,
              required descriptor,
              required session,
              required paneId,
            }) {
              final record = _Binding(session, paneId, ready: ready.future);
              records.add(record);
              return record.binding;
            },
      );
      await tester.runAsync(() => activate(host: prepared));
      await tester.pumpWidget(host());
      await tester.pumpAndSettle();
      expect(find.text('A'), findsOneWidget);
      expect(find.text('body a'), findsNothing);
      expect(records.single.runtimes, isEmpty);
      await tester.pumpWidget(const SizedBox.shrink());
      expect(records.single.releases, 1);
      ready.complete();
      await tester.pumpAndSettle();
      expect(records.single.runtimes, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('ready failure remains local and is observed before mounting', (
    tester,
  ) async {
    final ready = Completer<void>();
    final records = <_Binding>[];
    await tester.runAsync(
      () => activate(
        host: PreparedMainContentHost(
          createBinding:
              ({
                required installation,
                required descriptor,
                required session,
                required paneId,
              }) {
                final record = _Binding(session, paneId, ready: ready.future);
                records.add(record);
                return record.binding;
              },
        ),
      ),
    );
    await tester.pumpWidget(host());
    ready.completeError(StateError('private native diagnostic'));
    await tester.pumpAndSettle();
    expect(find.text('Frontend unavailable.'), findsOneWidget);
    expect(find.text('Independent content'), findsOneWidget);
    expect(records.single.runtimes, isEmpty);
    await tester.pumpWidget(const SizedBox.shrink());
    expect(records.single.releases, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('failed native bridge construction revokes its captured access', (
    tester,
  ) async {
    bool Function()? active;
    var releases = 0;
    await tester.runAsync(
      () => activate(
        host: PreparedMainContentHost(
          createBinding:
              ({
                required installation,
                required descriptor,
                required session,
                required paneId,
              }) => PreparedMainContentPaneBinding(
                createBridge: (isActive) {
                  active = isActive;
                  throw StateError('private native diagnostic');
                },
                release: () => releases++,
              ),
        ),
      ),
    );
    await tester.pumpWidget(host());
    await tester.pumpAndSettle();
    expect(active, isNotNull);
    expect(active!(), isFalse);
    expect(find.text('Frontend unavailable.'), findsOneWidget);
    expect(find.text('Independent content'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    expect(releases, 1);
    expect(tester.takeException(), isNull);
  });

  for (final bridgeFailure in [true, false]) {
    testWidgets('Session cleanup attempts every pane once with '
        '${bridgeFailure ? 'bridge' : 'native release'} failure', (
      tester,
    ) async {
      final firstError = StateError('first cleanup failure');
      final firstStack = StackTrace.fromString('first cleanup stack');
      final laterError = StateError('later cleanup failure');
      final laterStack = StackTrace.fromString('later cleanup stack');
      final otherSession = Session(
        id: SessionId('other-session'),
        taskId: session.taskId,
        strategyId: session.strategyId,
      );
      final records = <_Binding>[];
      final prepared = PreparedMainContentHost(
        createBinding:
            ({
              required installation,
              required descriptor,
              required session,
              required paneId,
            }) {
              final record = _Binding(
                session,
                paneId,
                invalidateFailure: bridgeFailure && paneId == 'a'
                    ? (firstError, firstStack)
                    : null,
                releaseFailure: !bridgeFailure && paneId == 'a'
                    ? (firstError, firstStack)
                    : (laterError, laterStack),
              );
              records.add(record);
              return record.binding;
            },
      );
      final generation = (await tester.runAsync(
        () => PreparedFrontend.load(artifact),
      ))!;
      final descriptor = PreparedMainContentPresentation(
        extensionId: _extensionId,
        order: 200,
        library: _library,
        initialize: 'initializePanes',
        entrypoint: 'buildPane',
      );
      final registration = extensions.register(
        point: mainContentContributions,
        id: _extensionId,
        value: prepared.createContribution(
          extensions: extensions,
          installation: PreparedPluginInstallation(
            metadata: PluginMetadata(
              id: PluginId('test.prepared'),
              version: '1',
              displayName: 'Panes',
            ),
            installationDirectory: temporary,
            backendArtifactUri: null,
          ),
          generation: generation,
          descriptor: descriptor,
          isActive: () => true,
        ),
      );
      addTearDown(registration.close);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Column(
              children: [
                for (final current in [session, otherSession])
                  Expanded(
                    child: MainContentHost(
                      session: current,
                      extensions: extensions,
                    ),
                  ),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      for (final record in records.toList()) {
        expect(
          record.call('open', [$String('b'), $String('B'), $bool(true)]),
          isTrue,
        );
      }
      await tester.pumpAndSettle();
      final departing = records.where((r) => identical(r.session, session));
      final other = records.where((r) => identical(r.session, otherSession));
      expect(departing.map((r) => r.paneId), ['a', 'b']);
      expect(other.map((r) => r.paneId), ['a', 'b']);
      Object? caught;
      StackTrace? caughtStack;
      try {
        prepared.unbind(session);
      } on Object catch (error, stack) {
        caught = error;
        caughtStack = stack;
      }
      expect(caught, same(firstError));
      expect(caughtStack.toString(), firstStack.toString());
      expect(departing.map((r) => r.releases), everyElement(1));
      expect(departing.map((r) => r.invalidations), everyElement(1));
      expect(departing.map((r) => r.siblingInvalidations), everyElement(1));
      for (final record in departing) {
        expect(record.active!(), isFalse);
        expect(record.call('context'), isEmpty);
        expect(record.call('rename', [$String('a'), $String('Late')]), isFalse);
      }
      expect(other.map((r) => r.releases), everyElement(0));
      expect(other.map((r) => r.invalidations), everyElement(0));
      expect(other.map((r) => r.active!()), everyElement(isTrue));
      expect(
        other.first.call('rename', [$String('b'), $String('Still live')]),
        isTrue,
      );
      prepared.unbind(session);

      final closing = prepared.close();
      expect(prepared.close(), same(closing));
      caught = null;
      caughtStack = null;
      try {
        await closing;
      } on Object catch (error, stack) {
        caught = error;
        caughtStack = stack;
      }
      expect(caught, same(firstError));
      expect(caughtStack.toString(), firstStack.toString());
      await expectLater(prepared.close(), throwsA(same(firstError)));
      prepared.unbind(otherSession);
      expect(records.map((r) => r.active!()), everyElement(isFalse));
      // Ordinary removal and generation retirement revisit the same lifetimes.
      generation.retainPresentations();
      generation.releasePresentations();
      await tester.pumpWidget(const SizedBox.shrink());
      generation.invalidate();
      expect(records.map((r) => r.releases), everyElement(1));
      expect(records.map((r) => r.invalidations), everyElement(1));
      expect(records.map((r) => r.siblingInvalidations), everyElement(1));
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets(
    'Session departure fences old runtimes and reattach initializes fresh panes',
    (tester) async {
      final records = <_Binding>[];
      var current = true;
      await tester.runAsync(
        () => activate(
          host: PreparedMainContentHost(
            createBinding:
                ({
                  required installation,
                  required descriptor,
                  required session,
                  required paneId,
                }) {
                  final record = _Binding(session, paneId);
                  records.add(record);
                  return record.binding;
                },
          ),
        ),
      );
      await tester.pumpWidget(host(isCurrent: () => current));
      await tester.pumpAndSettle();
      final old = records.single;
      current = false;
      expect(old.call('context'), isEmpty);
      expect(old.call('remove', [$String('a')]), isFalse);
      current = true;
      expect(old.call('remove', [$String('a')]), isFalse);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpWidget(host());
      await tester.pumpAndSettle();
      expect(old.releases, 1);
      expect(records, hasLength(2));
      expect(records.last.call('paneId'), 'a');
      await tester.pumpWidget(const SizedBox.shrink());
      expect(tester.takeException(), isNull);
    },
  );
}

void _press(WidgetTester tester, String label) => tester
    .widget<TextButton>(find.widgetWithText(TextButton, label))
    .onPressed!();

final class _Binding {
  _Binding(
    this.session,
    this.paneId, {
    this.ready,
    this.invalidateFailure,
    this.releaseFailure,
  });
  final Session session;
  final String paneId;
  final Future<void>? ready;
  final (Object, StackTrace)? invalidateFailure;
  final (Object, StackTrace)? releaseFailure;
  final List<Runtime> runtimes = [];
  bool Function()? active;
  var releases = 0;
  var focuses = 0;
  var invalidations = 0;
  var siblingInvalidations = 0;

  PreparedMainContentPaneBinding get binding => PreparedMainContentPaneBinding(
    ready: ready,
    createBridge: (isActive) {
      active = isActive;
      return PreparedFrontendBridges([
        _RecordingBridge(
          runtimes.add,
          onInvalidate: () {
            invalidations++;
            if (invalidateFailure case final failure?) {
              Error.throwWithStackTrace(failure.$1, failure.$2);
            }
          },
        ),
        _RecordingBridge((_) {}, onInvalidate: () => siblingInvalidations++),
      ]);
    },
    requestFocus: () => focuses++,
    release: () {
      releases++;
      if (releaseFailure case final failure?) {
        Error.throwWithStackTrace(failure.$1, failure.$2);
      }
    },
  );

  Object? call(String name, [List<$Value> arguments = const []]) {
    final value = runtimes.single.executeLib(_library, name, [
      for (final argument in arguments)
        argument is $bool ? argument.$value : argument,
    ]);
    return copyStructuredBridgeData(value);
  }
}

final class _RecordingBridge implements PreparedFrontendBridge {
  _RecordingBridge(this.record, {this.onInvalidate});
  final void Function(Runtime) record;
  final VoidCallback? onInvalidate;

  @override
  String get identifier => 'test.main-content-binding';
  @override
  void configureForCompile(BridgeDeclarationRegistry registry) {}
  @override
  void configureForRuntime(Runtime runtime) => record(runtime);
  @override
  void invalidate() => onInvalidate?.call();
}

const _source = '''
import 'package:flutter/material.dart';
import 'package:adele_ui/main_content_bridge.dart';

void initializePanes() { openMainContentPane('a', 'A', true); }
List<Map<String, dynamic>> panes() => readMainContentPanes();
Map<String, dynamic> context() => readMainContentContext();
String paneId() => readMainContentPaneId();
bool open(String id, String title, bool close) => openMainContentPane(id, title, close);
bool rename(String id, String title) => setMainContentPaneTitle(id, title);
bool order(List<String> ids) => setMainContentPaneOrder(ids);
bool remove(String id) => removeMainContentPane(id);
bool focus(String id, bool keyboard) => focusMainContentPane(id, keyboard);

Widget buildPane() {
  final id = readMainContentPaneId();
  return Column(children: [
    Text('body ' + id),
    TextButton(onPressed: () { openMainContentPane('b', 'B', true); }, child: Text('Open from ' + id)),
    TextButton(onPressed: () { setMainContentPaneTitle(id, 'Renamed ' + id); }, child: Text('Rename ' + id)),
  ]);
}
''';
