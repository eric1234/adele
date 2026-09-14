import 'dart:io';

import 'package:adele_desktop/frontend/prepared_frontend.dart';
import 'package:adele_desktop/frontend/tool_activity_inspection_bridge.dart';
import 'package:adele_orchestration/adele_orchestration.dart';
import 'package:adele_ui/adele_ui.dart';
import 'package:dart_eval/dart_eval.dart';
import 'package:dart_eval/dart_eval_bridge.dart';
import 'package:flutter/material.dart';
import 'package:flutter_eval/flutter_eval.dart';
import 'package:flutter_test/flutter_test.dart';

const String _library = 'package:inspection_probe/main.dart';

void main() {
  late Program program;
  late Directory temporary;
  late File artifact;
  late _Source source;
  late ToolActivityInspectionBridge bridge;
  late Runtime runtime;
  bool active = true;

  setUpAll(() async {
    temporary = await Directory.systemTemp.createTemp('adele-tool-inspection-');
    final root = Directory.current.parent.path;
    program =
        (Compiler()
              ..addPlugin(flutterEvalPlugin)
              ..addPlugin(const ToolActivityInspectionDeclarations())
              ..entrypoints.add(_library))
            .compile({
              'inspection_probe': {'main.dart': _probe},
              'adele_ui': {
                for (final name in [
                  'tool_activity_inspection_bridge',
                  'inspection_display',
                ])
                  '$name.dart': File(
                    '$root/packages/ui/lib/$name.dart',
                  ).readAsStringSync(),
              },
            });
    artifact = File('${temporary.path}/inspection.evc');
    await artifact.writeAsBytes(program.write());
  });

  tearDownAll(() => temporary.delete(recursive: true));

  setUp(() {
    active = true;
    source = _Source();
    bridge = ToolActivityInspectionBridge(
      source: source,
      isActive: () => active,
    );
    runtime = Runtime(program.write().buffer.asByteData())
      ..addPlugin(flutterEvalPlugin)
      ..addPlugin(bridge);
  });

  tearDown(() {
    bridge.invalidate();
    source.dispose();
  });

  Object? invoke(String function) {
    final Object? value = runtime.executeLib(_library, function);
    return value is $Value ? value.$reified : value;
  }

  List<Object?> inspect() => (invoke('inspect') as List)
      .map((value) => value is $Value ? value.$reified : value)
      .toList();

  test('compiled stubs transport precisely primitive snapshot fields', () {
    expect(inspect(), [
      'prepared',
      null,
      null,
      '',
      'literal\u202Epath',
      3,
      1.5,
      true,
      null,
      'nested',
      false,
    ]);
    source.value = _activity(
      changes: [
        const ToolActivityChange(
          sequence: 3,
          kind: ToolActivityKind.executionStarted,
        ),
        ToolActivityChange(
          sequence: 4,
          kind: ToolActivityKind.progress,
          progress: ToolProgress(content: 'Not transported'),
        ),
      ],
    );
    expect(inspect().first, 'executionStarted');
    source.value = _activity(
      changes: [
        ToolActivityChange(
          sequence: 3,
          kind: ToolActivityKind.progress,
          progress: ToolProgress(content: 'Progress only'),
        ),
      ],
    );
    expect(inspect().first, 'prepared');
    source.value = _activity(terminal: true);
    expect(inspect().take(4), [
      'completed',
      'failure',
      'domain',
      'Model result',
    ]);
    expect(inspect().last, true);
    expect(invoke('inspectOutcome'), 'opaque nested evidence');
  });

  test('old snapshots stay immutable and do not track later source updates', () {
    invoke('retain');
    source.value = _activity(terminal: true);
    expect(invoke('retainedLifecycle'), 'prepared');
    expect(inspect().first, 'completed');
    for (final name in [
      'mutateArguments',
      'mutateNestedMap',
      'mutateNestedList',
      'mutateHostData',
      'mutateNestedHostData',
    ]) {
      // This eval pin cannot resume a runtime after an uncaught host exception.
      final mutationBridge = ToolActivityInspectionBridge(
        source: source,
        isActive: () => true,
      );
      addTearDown(mutationBridge.invalidate);
      final mutationRuntime = Runtime(program.write().buffer.asByteData())
        ..addPlugin(flutterEvalPlugin)
        ..addPlugin(mutationBridge);
      expect(
        () => mutationRuntime.executeLib(_library, name),
        throwsA(
          predicate(
            (error) => error.toString().contains('Unsupported operation'),
          ),
        ),
        reason: name,
      );
      expect(invoke('inspectOutcome'), 'opaque nested evidence');
      expect(inspect()[4], 'literal\u202Epath');
    }
  });

  test(
    'compiled display helper escapes controls without changing bridge data',
    () {
      expect(invoke('display'), r'literal\u202Epath');
      expect(inspect()[4], 'literal\u202Epath');
      expect(invoke('displayControls'), r'\n\\n\u200D\uDB40\uDC7F');
      expect(invoke('displayFallback'), 'Environment root');
      expect(invoke('displayUnicode'), '\u00E9 e\u0301 \u{1F600}');
      expect(invoke('displayEmpty'), '');
    },
  );

  testWidgets('changes are lazy and coalesced post-frame', (tester) async {
    invoke('listen');
    final int reads = source.reads;
    source.value = _activity(terminal: true);
    for (int i = 0; i < 100; i++) {
      source.notifyListeners();
    }
    expect(invoke('count'), 0);
    expect(source.reads, reads);
    await tester.pump();
    expect(invoke('count'), 1);
    expect(source.reads, reads + 1);
    expect(invoke('latestLifecycle'), 'completed');
    expect(tester.takeException(), isNull);
  });

  testWidgets('unsubscribe and replacement suppress queued old callbacks', (
    tester,
  ) async {
    invoke('listen');
    source.notifyListeners();
    invoke('stop');
    invoke('listen');
    await tester.pump();
    expect(invoke('count'), 0);
    source.notifyListeners();
    await tester.pump();
    expect(invoke('count'), 1);
    invoke('stop');
    expect(source.listening, isFalse);
    source.notifyListeners();
    await tester.pump();
    expect(invoke('count'), 1);
  });

  for (final bool invalidate in [true, false]) {
    testWidgets(
      '${invalidate ? 'invalidation' : 'stale liveness'} revokes reads and queued callbacks',
      (tester) async {
        invoke('listen');
        final int reads = source.reads;
        source.notifyListeners();
        if (invalidate) {
          bridge.invalidate();
        } else {
          active = false;
        }
        await tester.pump();
        expect(invoke('count'), 0);
        expect(source.reads, reads);
        expect(source.listening, isFalse);
        expect(() => invoke('inspect'), throwsA(anything));
        active = true;
        invoke('listen');
        expect(source.listening, isFalse);
        expect(() => invoke('inspect'), throwsA(anything));
        expect(source.reads, reads);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('callback failure is reported once, bounded, and detached', (
    tester,
  ) async {
    invoke('listenBroken');
    source.notifyListeners();
    await tester.pump();
    final error = tester.takeException();
    expect(error, isA<FlutterError>());
    expect(error.toString(), contains('Tool activity inspection failed.'));
    expect(error.toString(), isNot(contains('private callback detail')));
    expect(source.listening, isFalse);
    source.notifyListeners();
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(() => invoke('inspect'), throwsA(anything));
  });

  test('source failure and retirement during snapshot read revoke access', () {
    source.fail = true;
    expect(
      () => invoke('inspect'),
      throwsA(
        predicate(
          (error) =>
              error.toString().contains(
                'Tool activity inspection is unavailable.',
              ) &&
              !error.toString().contains('private source detail'),
        ),
      ),
    );
    source.fail = false;
    expect(() => invoke('inspect'), throwsA(anything));
    expect(source.reads, 1);

    final lateBridge = ToolActivityInspectionBridge(
      source: source,
      isActive: () => active,
    );
    addTearDown(lateBridge.invalidate);
    final lateRuntime = Runtime(program.write().buffer.asByteData())
      ..addPlugin(flutterEvalPlugin)
      ..addPlugin(lateBridge);
    source.onRead = () => active = false;
    expect(
      () => lateRuntime.executeLib(_library, 'inspect'),
      throwsA(anything),
    );
  });

  test(
    'a failed liveness check notifies its owner without reading the source',
    () {
      int failures = 0;
      final failing = ToolActivityInspectionBridge(
        source: source,
        isActive: () => throw StateError('private liveness detail'),
      )..onFailure = () => failures++;
      addTearDown(failing.invalidate);
      final failedRuntime = Runtime(program.write().buffer.asByteData())
        ..addPlugin(flutterEvalPlugin)
        ..addPlugin(failing);
      expect(
        () => failedRuntime.executeLib(_library, 'inspect'),
        throwsA(anything),
      );
      expect(failures, 1);
      expect(source.reads, 0);
      expect(source.listening, isFalse);
    },
  );

  testWidgets(
    'prepared frontend renders generic nested data and retains state during changes',
    (tester) async {
      final generation = (await tester.runAsync(
        () => PreparedFrontend.load(artifact),
      ))!;
      addTearDown(generation.invalidate);
      Widget host() => MaterialApp(
        home: Scaffold(
          body: generation.createPresentation(
            key: ObjectKey(source),
            library: _library,
            entrypoint: 'buildInspection',
            createBridge: () => ToolActivityInspectionBridge(
              source: source,
              isActive: () => active,
            ),
          ),
        ),
      );
      await tester.pumpWidget(host());
      expect(find.text(r'prepared: literal\u202Epath'), findsOneWidget);
      await tester.enterText(find.byType(TextField), 'Retained state');
      final controller = tester
          .widget<TextField>(find.byType(TextField))
          .controller;
      source.value = _activity(terminal: true);
      source.notifyListeners();
      source.notifyListeners();
      await tester.pump();
      await tester.pump();
      expect(find.text(r'completed: literal\u202Epath'), findsOneWidget);
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller,
        same(controller),
      );
      expect(controller!.text, 'Retained state');
      source.notifyListeners();
      final reads = source.reads;
      generation.invalidate();
      await tester.pump();
      expect(find.text('Frontend unavailable.'), findsOneWidget);
      expect(source.listening, isFalse);
      expect(source.reads, reads);
      expect(tester.takeException(), isNull);
    },
  );

  for (final bool sourceFailure in [false, true]) {
    testWidgets(
      '${sourceFailure ? 'source' : 'interpreted'} callback failure removes only its prepared view',
      (tester) async {
        final generation = (await tester.runAsync(
          () => PreparedFrontend.load(artifact),
        ))!;
        addTearDown(generation.invalidate);
        final sibling = _Source();
        addTearDown(sibling.dispose);
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: Column(
                children: [
                  generation.createPresentation(
                    key: const ValueKey('failing'),
                    library: _library,
                    entrypoint: sourceFailure
                        ? 'buildReadingCallback'
                        : 'buildCallbackFailure',
                    createBridge: () => ToolActivityInspectionBridge(
                      source: source,
                      isActive: () => true,
                    ),
                  ),
                  generation.createPresentation(
                    key: const ValueKey('sibling'),
                    library: _library,
                    entrypoint: 'buildInspection',
                    createBridge: () => ToolActivityInspectionBridge(
                      source: sibling,
                      isActive: () => true,
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
        expect(find.byType(TextField), findsNWidgets(2));
        final failedElement = tester.element(find.byType(TextField).first);
        final retained = tester.element(find.byType(TextField).last);
        final controller = tester
            .widget<TextField>(find.byType(TextField).first)
            .controller!;
        source.fail = sourceFailure;
        source.notifyListeners();
        await tester.pump();
        expect(source.listening, isFalse);
        await tester.pump();
        expect(find.text('Frontend unavailable.'), findsOneWidget);
        expect(failedElement.mounted, isFalse);
        expect(find.byType(TextField), findsOneWidget);
        expect(tester.element(find.byType(TextField)), same(retained));
        expect(() => controller.addListener(() {}), throwsFlutterError);
        expect(sibling.listening, isTrue);
        sibling.value = _activity(terminal: true);
        sibling.notifyListeners();
        await tester.pump();
        await tester.pump();
        expect(find.text(r'completed: literal\u202Epath'), findsOneWidget);
        final reads = source.reads;
        source.notifyListeners();
        await tester.pump();
        expect(source.reads, reads);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'prepared entrypoint read failure is bounded and unmount revokes subscriptions',
    (tester) async {
      final generation = (await tester.runAsync(
        () => PreparedFrontend.load(artifact),
      ))!;
      addTearDown(generation.invalidate);
      source.fail = true;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: generation.createPresentation(
              library: _library,
              entrypoint: 'buildFailingInspection',
              createBridge: () => ToolActivityInspectionBridge(
                source: source,
                isActive: () => true,
              ),
            ),
          ),
        ),
      );
      expect(find.text('Frontend unavailable.'), findsOneWidget);
      expect(source.listening, isFalse);
      expect(tester.takeException(), isNull);

      source.fail = false;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: generation.createPresentation(
              library: _library,
              entrypoint: 'buildInspection',
              createBridge: () => ToolActivityInspectionBridge(
                source: source,
                isActive: () => true,
              ),
            ),
          ),
        ),
      );
      expect(source.listening, isTrue);
      source.notifyListeners();
      final reads = source.reads;
      await tester.pumpWidget(const SizedBox.shrink());
      expect(source.listening, isFalse);
      expect(source.reads, reads);
      source.notifyListeners();
      await tester.pump();
      expect(tester.takeException(), isNull);
    },
  );
}

class _Source extends ChangeNotifier implements ToolActivityInspectionSource {
  ToolInvocationActivity value = _activity();
  int reads = 0;
  bool fail = false;
  VoidCallback? onRead;
  bool get listening => hasListeners;
  @override
  ToolInvocationActivity get snapshot {
    reads++;
    onRead?.call();
    if (fail) throw StateError('private source detail');
    return value;
  }
}

ToolInvocationActivity _activity({
  bool terminal = false,
  List<ToolActivityChange>? changes,
}) => ToolInvocationActivity(
  id: ToolInvocationId('tool-1'),
  preparedSequence: 2,
  modelInvocationId: ModelInvocationId('model-1'),
  proposalSequence: 1,
  toolId: ToolId('dev.adele.test.arbitrary-tool'),
  alias: 'unrelated_alias',
  providerCallId: 'call-1',
  canonicalArguments: const {
    'path': 'literal\u202Epath',
    'integer': 3,
    'double': 1.5,
    'boolean': true,
    'nullable': null,
    'nested': [
      {'value': 'nested'},
    ],
  },
  changes:
      changes ??
      (terminal
          ? [
              const ToolActivityChange(
                sequence: 3,
                kind: ToolActivityKind.completed,
              ),
            ]
          : []),
  outcome: terminal
      ? ToolOutcomeActivity(
          disposition: ToolOutcomeDisposition.failure,
          failureKind: ToolFailureKind.domain,
          effectCertainty: EffectCertainty.knownNotOccurred,
          modelContent: 'Model result',
          hostData: const {
            'opaque': [
              {'value': 'opaque nested evidence'},
            ],
          },
        )
      : null,
);

const String _probe = r'''
import 'package:adele_ui/tool_activity_inspection_bridge.dart';
import 'package:adele_ui/inspection_display.dart';
import 'package:flutter/material.dart';

int calls = 0;
String latest = '';
ToolActivityInspectionSnapshot? retained = null;

List<dynamic> inspect() {
  final ToolActivityInspectionSnapshot snapshot = readToolActivitySnapshot();
  final Map<String, dynamic> args = snapshot.canonicalArguments;
  return <dynamic>[
    snapshot.lifecycle, snapshot.disposition, snapshot.failureKind,
    snapshot.modelContent, args['path'], args['integer'], args['double'],
    args['boolean'], args['nullable'], args['nested'][0]['value'],
    snapshot.hostData.isNotEmpty,
  ];
}
String inspectOutcome() => readToolActivitySnapshot().hostData['opaque'][0]['value'];
void retain() { retained = readToolActivitySnapshot(); }
String retainedLifecycle() => retained!.lifecycle;
void mutateArguments() { readToolActivitySnapshot().canonicalArguments['path'] = 'changed'; }
void mutateNestedMap() {
  final Map<String, dynamic> nested = readToolActivitySnapshot().canonicalArguments['nested'][0];
  nested['value'] = 'changed';
}
void mutateNestedList() { readToolActivitySnapshot().canonicalArguments['nested'].add('changed'); }
void mutateHostData() { readToolActivitySnapshot().hostData['opaque'] = 'changed'; }
void mutateNestedHostData() {
  final Map<String, dynamic> nested = readToolActivitySnapshot().hostData['opaque'][0];
  nested['value'] = 'changed';
}
String display() => inspectionDisplayText(readToolActivitySnapshot().canonicalArguments['path']);
String displayControls() => inspectionDisplayText('\n\\n\u200D\u{E007F}');
String displayFallback() {
  final dynamic directory = readToolActivitySnapshot().canonicalArguments['missing'];
  return inspectionDisplayText(directory is String ? directory : 'Environment root');
}
String displayUnicode() => inspectionDisplayText('\u00E9 e\u0301 \u{1F600}');
String displayEmpty() => inspectionDisplayText('');
void listen() {
  subscribeToolActivityChanges(() {
    calls++;
    latest = readToolActivitySnapshot().lifecycle;
  });
}
void listenBroken() { subscribeToolActivityChanges(() { throw StateError('private callback detail'); }); }
void stop() { unsubscribeToolActivityChanges(); }
int count() => calls;
String latestLifecycle() => latest;

Widget buildInspection() => InspectionProbe();
bool failCallback = false;
bool readCallback = false;
Widget buildCallbackFailure() {
  failCallback = true;
  return InspectionProbe();
}
Widget buildReadingCallback() {
  readCallback = true;
  return InspectionProbe();
}
Widget buildFailingInspection() => Text(readToolActivitySnapshot().lifecycle);
class InspectionProbe extends StatefulWidget {
  @override
  State<InspectionProbe> createState() => InspectionProbeState();
}
class InspectionProbeState extends State<InspectionProbe> {
  final TextEditingController controller = TextEditingController();
  @override
  void initState() {
    super.initState();
    subscribeToolActivityChanges(() {
      if (failCallback) throw StateError('private callback detail');
      if (readCallback) readToolActivitySnapshot();
      setState(() {});
    });
  }
  @override
  Widget build(BuildContext context) {
    final ToolActivityInspectionSnapshot snapshot = readToolActivitySnapshot();
    return Column(mainAxisSize: MainAxisSize.min, children: <Widget>[
      Text('${snapshot.lifecycle}: ${inspectionDisplayText(snapshot.canonicalArguments['path'])}'),
      TextField(controller: controller),
    ]);
  }
  @override
  void dispose() {
    unsubscribeToolActivityChanges();
    controller.dispose();
    super.dispose();
  }
}
''';
