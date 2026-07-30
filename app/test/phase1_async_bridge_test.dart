import 'package:dart_eval/dart_eval.dart';
import 'package:dart_eval/dart_eval_bridge.dart';
import 'package:dart_eval/stdlib/core.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('awaits a typed bridged future', () async {
    final Compiler compiler = Compiler()..addPlugin(const _AsyncProbePlugin());
    final Program program = compiler.compile(<String, Map<String, String>>{
      'probe': <String, String>{
        'main.dart': '''
import 'package:adele_phase1_bridge/bridge.dart';

Future<String> loadMarker() async {
  final value = await phase1Marker();
  return 'interpreted:' + value;
}
''',
      },
    });
    final Runtime runtime = Runtime(program.write().buffer.asByteData())
      ..addPlugin(const _AsyncProbePlugin());
    final Object? result = runtime.executeLib(
      'package:probe/main.dart',
      'loadMarker',
    );
    expect(result, isA<Future<Object?>>());
    final Object? awaited = await (result! as Future<Object?>);
    expect((awaited! as $Value).$reified, 'interpreted:host');
  });
}

final class _AsyncProbePlugin implements EvalPlugin {
  const _AsyncProbePlugin();

  @override
  String get identifier => 'package:adele_phase1_bridge';

  @override
  void configureForCompile(BridgeDeclarationRegistry registry) {
    registry.defineBridgeTopLevelFunction(
      const BridgeFunctionDeclaration(
        'package:adele_phase1_bridge/bridge.dart',
        'phase1Marker',
        BridgeFunctionDef(
          returns: BridgeTypeAnnotation(BridgeTypeRef(CoreTypes.future)),
        ),
      ),
    );
  }

  @override
  void configureForRuntime(Runtime runtime) {
    runtime.registerBridgeFunc(
      'package:adele_phase1_bridge/bridge.dart',
      'phase1Marker',
      (Runtime runtime, $Value? target, List<$Value?> arguments) {
        return $Future<$Value?>.wrap(Future<$Value?>.value($String('host')));
      },
    );
  }
}
