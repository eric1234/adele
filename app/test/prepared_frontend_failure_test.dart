import 'dart:io';

import 'package:adele_desktop/frontend/prepared_frontend.dart';
import 'package:dart_eval/dart_eval.dart';
import 'package:dart_eval/dart_eval_bridge.dart';
import 'package:dart_eval/stdlib/core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_eval/flutter_eval.dart';
import 'package:flutter_test/flutter_test.dart';

const String _library = 'package:failure_probe/main.dart';
const String _bridgeLibrary = 'package:failure_probe/bridge.dart';

void main() {
  late Directory temporary;
  late File artifact;
  late PreparedFrontend generation;

  setUpAll(() async {
    temporary = await Directory.systemTemp.createTemp(
      'adele-prepared-failure-',
    );
    artifact = File('${temporary.path}/failure.evc');
    final program =
        (Compiler()
              ..addPlugin(flutterEvalPlugin)
              ..addPlugin(_ProbeBridge('declarations'))
              ..entrypoints.add(_library))
            .compile({
              'failure_probe': {'main.dart': _frontend},
            });
    await artifact.writeAsBytes(program.write());
  });
  tearDownAll(() => temporary.delete(recursive: true));
  setUp(() async => generation = await PreparedFrontend.load(artifact));
  tearDown(() => generation.invalidate());

  Widget view(_ProbeBridge bridge, {String entrypoint = 'buildView'}) =>
      generation.createPresentation(
        key: ObjectKey(bridge),
        library: _library,
        entrypoint: entrypoint,
        createBridge: () => bridge,
      );
  Widget host(List<Widget> children) => MaterialApp(
    home: Scaffold(
      body: Column(
        children: [for (final child in children) Expanded(child: child)],
      ),
    ),
  );

  testWidgets(
    'one failure retires its view, disposes resources, and leaves siblings live',
    (tester) async {
      final first = _ProbeBridge('First');
      final second = _ProbeBridge('Second');
      await tester.pumpWidget(host([view(first), view(second)]));
      final failedElement = tester.element(find.byType(TextField).first);
      final retained = tester.element(find.byType(TextField).last);
      final controller = tester
          .widget<TextField>(find.byType(TextField).first)
          .controller!;
      final lateFailure = first.onFailure!;
      first.fail();
      expect(first.invalidations, 1);
      expect(first.listening, isFalse);
      expect(first.onFailure, isNull);
      await tester.pump();
      expect(find.text('Frontend unavailable.'), findsOneWidget);
      expect(find.text('First'), findsNothing);
      expect(find.text('Second'), findsOneWidget);
      expect(failedElement.mounted, isFalse);
      expect(tester.element(find.byType(TextField)), same(retained));
      expect(first.disposals, 1);
      expect(() => controller.addListener(() {}), throwsFlutterError);
      expect(second.invalidations, 0);
      expect(second.listening, isTrue);
      second.label = 'Second updated';
      second.changed();
      await tester.pump();
      expect(find.text('Second updated'), findsOneWidget);
      lateFailure();
      await tester.pump();
      expect(first.invalidations, 1);
      expect(first.disposals, 1);
      final third = _ProbeBridge('Fresh sibling');
      await tester.pumpWidget(host([view(first), view(second), view(third)]));
      expect(find.text('Fresh sibling'), findsOneWidget);
      expect(find.text('Frontend unavailable.'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
      lateFailure();
      expect(second.disposals, 1);
      expect(third.disposals, 1);
      expect(tester.takeException(), isNull);
    },
  );

  for (final entrypoint in ['buildFailedView', 'buildAsyncFailedView']) {
    testWidgets('failure during $entrypoint cannot mount its returned widget', (
      tester,
    ) async {
      final failed = _ProbeBridge('Never mounted');
      final sibling = _ProbeBridge('Sibling');
      await tester.pumpWidget(
        host([view(failed, entrypoint: entrypoint), view(sibling)]),
      );
      await tester.pump();
      expect(find.text('Frontend unavailable.'), findsOneWidget);
      expect(find.text('Never mounted'), findsNothing);
      expect(find.text('Sibling'), findsOneWidget);
      expect(failed.invalidations, 1);
      expect(failed.onFailure, isNull);
      expect(failed.listening, isFalse);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('host-build failure notification defers rebuilding safely', (
    tester,
  ) async {
    final bridge = _ProbeBridge('View');
    late StateSetter rebuild;
    bool fail = false;
    await tester.pumpWidget(
      host([
        StatefulBuilder(
          builder: (_, setState) {
            rebuild = setState;
            if (fail) bridge.fail();
            return view(bridge);
          },
        ),
      ]),
    );
    rebuild(() => fail = true);
    await tester.pump();
    await tester.pump();
    expect(find.text('Frontend unavailable.'), findsOneWidget);
    expect(find.text('View'), findsNothing);
    expect(bridge.disposals, 1);
    expect(bridge.listening, isFalse);
    expect(tester.takeException(), isNull);
  });

  for (final String phase in [
    'initState',
    'build',
    'later build',
    'native build cast',
    'createState',
    'stateless build',
  ]) {
    testWidgets('$phase failure retires only its prepared presentation', (
      tester,
    ) async {
      final originalErrorBuilder = ErrorWidget.builder;
      final originalErrorHandler = FlutterError.onError;
      final failing = _ProbeBridge('Failing')
        ..failBuild = phase == 'build'
        ..failNativeBuild = phase == 'native build cast';
      final sibling = _ProbeBridge('Sibling');
      await tester.pumpWidget(
        host([
          view(
            failing,
            entrypoint: switch (phase) {
              'initState' => 'buildInitFailure',
              'createState' => 'buildCreateStateFailure',
              'stateless build' => 'buildStatelessFailure',
              _ => 'buildView',
            },
          ),
          view(sibling),
        ]),
      );
      if (phase == 'later build') {
        expect(find.text('Failing'), findsOneWidget);
        failing.failBuild = true;
        failing.changed();
        await tester.pump();
      }
      await tester.pump();
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(find.text('Frontend unavailable.'), findsOneWidget);
      expect(find.text('Sibling'), findsOneWidget);
      expect(find.text('Failing'), findsNothing);
      expect(failing.invalidations, 1);
      expect(failing.listening, isFalse);
      expect(
        failing.disposals,
        phase == 'createState' || phase == 'stateless build' ? 0 : 1,
      );
      expect(sibling.invalidations, 0);
      expect(sibling.listening, isTrue);
      sibling.label = 'Sibling still live';
      sibling.changed();
      await tester.pump();
      expect(find.text('Sibling still live'), findsOneWidget);
      expect(ErrorWidget.builder, same(originalErrorBuilder));
      expect(FlutterError.onError, same(originalErrorHandler));
      await tester.pumpWidget(const SizedBox.shrink());
      expect(failing.listening, isFalse);
      expect(sibling.listening, isFalse);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('an unrelated native widget error is not intercepted', (
    tester,
  ) async {
    final bridge = _ProbeBridge('Unaffected');
    await tester.pumpWidget(
      host([
        view(bridge),
        Builder(builder: (_) => throw StateError('ordinary native failure')),
      ]),
    );
    expect(
      tester.takeException(),
      isA<StateError>().having(
        (error) => error.message,
        'message',
        'ordinary native failure',
      ),
    );
    expect(find.text('Unaffected'), findsOneWidget);
    expect(find.text('Frontend unavailable.'), findsNothing);
    expect(bridge.invalidations, 0);
    expect(bridge.listening, isTrue);
    await tester.pumpWidget(const SizedBox.shrink());
    expect(tester.takeException(), isNull);
  });

  for (final bool afterSuper in [false, true]) {
    testWidgets(
      'failing interpreted dispose ${afterSuper ? 'after' : 'before'} super still releases native State',
      (tester) async {
        final failing = _ProbeBridge('Removing');
        final sibling = _ProbeBridge('Sibling');
        await tester.pumpWidget(
          host([
            view(
              failing,
              entrypoint: afterSuper
                  ? 'buildDisposeFailureAfter'
                  : 'buildDisposeFailureBefore',
            ),
            view(sibling),
          ]),
        );
        final element = tester.element(find.byType(TextField).first);
        final controller = tester
            .widget<TextField>(find.byType(TextField).first)
            .controller!;
        await tester.pumpWidget(host([const SizedBox.shrink(), view(sibling)]));
        await tester.pump();
        expect(element.mounted, isFalse);
        expect(failing.listening, isFalse);
        expect(failing.invalidations, 1);
        expect(failing.disposals, 1);
        expect(() => controller.addListener(() {}), throwsFlutterError);
        expect(find.text('Sibling'), findsOneWidget);
        expect(sibling.invalidations, 0);
        sibling.label = 'Sibling still live';
        sibling.changed();
        await tester.pump();
        expect(find.text('Sibling still live'), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  }
}

class _ProbeBridge
    implements PreparedFrontendBridge, PreparedFrontendFailureSource {
  _ProbeBridge(this.label);
  String label;
  bool failBuild = false;
  bool failNativeBuild = false;
  int invalidations = 0;
  int disposals = 0;
  VoidCallback? _changed;
  bool get listening => _changed != null;
  @override
  VoidCallback? onFailure;
  void fail() => onFailure?.call();
  void changed() => _changed?.call();

  @override
  String get identifier => _bridgeLibrary;
  @override
  void configureForCompile(BridgeDeclarationRegistry registry) {
    for (final String name in [
      'readLabel',
      'shouldFailBuild',
      'recordDispose',
      'failView',
      'unwatch',
    ]) {
      registry.defineBridgeTopLevelFunction(
        BridgeFunctionDeclaration(
          _bridgeLibrary,
          name,
          BridgeFunctionDef(
            returns: BridgeTypeAnnotation(
              BridgeTypeRef(
                name == 'readLabel'
                    ? CoreTypes.string
                    : name == 'shouldFailBuild'
                    ? CoreTypes.bool
                    : CoreTypes.voidType,
              ),
            ),
          ),
        ),
      );
    }
    registry.defineBridgeTopLevelFunction(
      const BridgeFunctionDeclaration(
        _bridgeLibrary,
        'watch',
        BridgeFunctionDef(
          returns: BridgeTypeAnnotation(BridgeTypeRef(CoreTypes.voidType)),
          params: [
            BridgeParameter(
              'callback',
              BridgeTypeAnnotation(BridgeTypeRef(CoreTypes.function)),
              false,
            ),
          ],
        ),
      ),
    );
  }

  @override
  void configureForRuntime(Runtime runtime) {
    runtime
      ..registerBridgeFunc(
        _bridgeLibrary,
        'readLabel',
        (_, _, _) => $String(label),
      )
      ..registerBridgeFunc(_bridgeLibrary, 'shouldFailBuild', (_, _, _) {
        if (failNativeBuild) {
          // Reproduce the real integration failure at a native eval boundary.
          final dynamic invalid = 7;
          return invalid as $Value?;
        }
        return $bool(failBuild);
      })
      ..registerBridgeFunc(_bridgeLibrary, 'recordDispose', (_, _, _) {
        disposals++;
        return null;
      })
      ..registerBridgeFunc(_bridgeLibrary, 'failView', (_, _, _) {
        fail();
        return null;
      })
      ..registerBridgeFunc(_bridgeLibrary, 'watch', (_, _, args) {
        final callback = args.single! as EvalCallable;
        _changed = () => callback.call(runtime, null, const []);
        return null;
      })
      ..registerBridgeFunc(_bridgeLibrary, 'unwatch', (_, _, _) {
        _changed = null;
        return null;
      });
  }

  @override
  void invalidate() {
    invalidations++;
    _changed = null;
  }
}

const String _frontend = r'''
import 'package:flutter/material.dart';
import 'bridge.dart';

bool failInit = false;
bool failDisposeBefore = false;
bool failDisposeAfter = false;
Widget buildView() => Probe();
Widget buildFailedView() { failView(); return Probe(); }
Future<Widget> buildAsyncFailedView() async { failView(); return Probe(); }
Widget buildInitFailure() { failInit = true; return Probe(); }
Widget buildCreateStateFailure() => CreateStateFailure();
Widget buildStatelessFailure() => StatelessFailure();
Widget buildDisposeFailureBefore() { failDisposeBefore = true; return Probe(); }
Widget buildDisposeFailureAfter() { failDisposeAfter = true; return Probe(); }
class CreateStateFailure extends StatefulWidget {
  @override
  State<CreateStateFailure> createState() { throw StateError('fixture createState failure'); }
}
class StatelessFailure extends StatelessWidget {
  @override
  Widget build(BuildContext context) { throw StateError('fixture stateless failure'); }
}
class Probe extends StatefulWidget {
  @override
  State<Probe> createState() => ProbeState();
}
class ProbeState extends State<Probe> {
  final TextEditingController controller = TextEditingController();
  @override
  void initState() {
    super.initState();
    watch(() { setState(() {}); });
    if (failInit) throw StateError('fixture lifecycle failure');
  }
  @override
  Widget build(BuildContext context) {
    if (shouldFailBuild()) throw StateError('fixture lifecycle failure');
    return Column(mainAxisSize: MainAxisSize.min, children: <Widget>[
      Text(readLabel()), TextField(controller: controller),
    ]);
  }
  @override
  void dispose() {
    unwatch();
    controller.dispose();
    recordDispose();
    if (failDisposeBefore) throw StateError('fixture dispose before super');
    super.dispose();
    if (failDisposeAfter) throw StateError('fixture dispose after super');
  }
}
''';
