import 'dart:async';

import 'package:adele_desktop/frontend/interpreted_widget.dart';
import 'package:dart_eval/dart_eval.dart';
import 'package:dart_eval/dart_eval_bridge.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_eval/flutter_eval.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  for (final bool asynchronous in <bool>[false, true]) {
    testWidgets(
      'retains runtime and reifies a ${asynchronous ? 'future' : 'synchronous'} widget',
      (WidgetTester tester) async {
        final _Bridge bridge = _Bridge();
        final Compiler compiler = Compiler()
          ..addPlugin(flutterEvalPlugin)
          ..addPlugin(bridge)
          ..entrypoints.add('package:probe/main.dart');
        final Program program = compiler.compile({
          'probe': {
            'main.dart':
                '''
import 'package:flutter/widgets.dart';
${asynchronous ? 'Future<Widget>' : 'Widget'} buildWidget() ${asynchronous ? 'async' : ''} {
  return Text('Interpreted widget');
}
''',
          },
        });
        final FutureOr<InterpretedWidget> pending = loadInterpretedWidget(
          bytes: program.write(),
          bridge: bridge,
          library: 'package:probe/main.dart',
          entrypoint: 'buildWidget',
        );
        expect(pending is Future<InterpretedWidget>, asynchronous);
        final InterpretedWidget loaded = await pending;
        expect(loaded.runtime, same(bridge.runtime));
        await tester.pumpWidget(
          Directionality(
            textDirection: TextDirection.ltr,
            child: loaded.widget,
          ),
        );
        expect(find.text('Interpreted widget'), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  }
}

class _Bridge implements EvalPlugin {
  Runtime? runtime;

  @override
  String get identifier => 'dev.adele.test.loader';

  @override
  void configureForCompile(BridgeDeclarationRegistry registry) {}

  @override
  void configureForRuntime(Runtime runtime) => this.runtime = runtime;
}
