import 'dart:io';

import 'package:adele_desktop/frontend/model_native_activity_bridge.dart';
import 'package:adele_ui/adele_ui.dart';
import 'package:dart_eval/dart_eval.dart';
import 'package:dart_eval/dart_eval_bridge.dart';
import 'package:flutter_test/flutter_test.dart';

const String _library = 'package:native_probe/main.dart';

void main() {
  late Program program;
  late ModelNativePresentation presentation;
  late ModelNativeActivityBridge bridge;
  late Runtime runtime;
  bool active = true;

  setUpAll(() {
    program =
        (Compiler()
              ..addPlugin(const ModelNativeActivityDeclarations())
              ..entrypoints.add(_library))
            .compile({
              'native_probe': {'main.dart': _probe},
              'adele_ui': {
                'model_native_activity_bridge.dart': File(
                  '${Directory.current.parent.path}/packages/ui/lib/model_native_activity_bridge.dart',
                ).readAsStringSync(),
              },
            });
  });

  setUp(() {
    active = true;
    presentation = ModelNativePresentation(
      kind: 'Not transported kind',
      compactText: 'Not transported',
      data: {
        'summaryParts': ['literal\u202Etext'],
        'truncated': false,
        'nested': [
          {'int': 3, 'double': 1.5, 'bool': true, 'null': null},
        ],
      },
    );
    bridge = ModelNativeActivityBridge(
      presentation: presentation,
      isActive: () => active,
    );
    runtime = Runtime(program.write().buffer.asByteData())..addPlugin(bridge);
  });
  tearDown(() => bridge.invalidate());

  Object? invoke(String function) {
    final Object? result = runtime.executeLib(_library, function);
    return result is $Value ? result.$reified : result;
  }

  test(
    'actual eval bridge carries only frozen primitive presentation data',
    () {
      expect(invoke('inspect'), presentation.data);
      expect(invoke('text'), 'literal\u202Etext');
      expect(invoke('hasAuthority'), false);
      expect(invoke('inspect').toString(), isNot(contains('Not transported')));
    },
  );

  for (final name in ['mutateMap', 'mutateList', 'mutateNestedMap']) {
    test('actual eval $name cannot alter a recursively frozen snapshot', () {
      expect(
        () => invoke(name),
        throwsA(
          predicate(
            (error) => error.toString().contains('Unsupported operation'),
          ),
        ),
      );
      expect(presentation.data['summaryParts'], ['literal\u202Etext']);
      expect((presentation.data['nested']! as List).single, {
        'int': 3,
        'double': 1.5,
        'bool': true,
        'null': null,
      });
    });
  }

  test('snapshot is detached from mutable inputs before eval reads', () {
    final parts = ['Captured'];
    final data = <String, Object?>{'summaryParts': parts, 'truncated': false};
    final captured = ModelNativeActivityBridge(
      presentation: ModelNativePresentation(
        kind: 'safe-fixture',
        compactText: 'Captured',
        data: data,
      ),
      isActive: () => true,
    );
    addTearDown(captured.invalidate);
    parts[0] = 'Changed';
    data.clear();
    final isolated = Runtime(program.write().buffer.asByteData())
      ..addPlugin(captured);
    final result = isolated.executeLib(_library, 'text') as $Value;
    expect(result.$reified, 'Captured');
  });

  for (final mode in ['invalidate', 'retire', 'throw']) {
    test('$mode permanently revokes reads with a bounded error', () {
      if (mode == 'invalidate') bridge.invalidate();
      if (mode == 'retire') active = false;
      if (mode == 'throw') {
        bridge.invalidate();
        bridge = ModelNativeActivityBridge(
          presentation: presentation,
          isActive: () => throw StateError('PRIVATE-LIVENESS-SECRET'),
        );
        runtime = Runtime(program.write().buffer.asByteData())
          ..addPlugin(bridge);
      }
      expect(
        () => invoke('text'),
        throwsA(
          predicate(
            (error) =>
                error.toString().contains(
                  'Model native activity inspection is unavailable.',
                ) &&
                !error.toString().contains('PRIVATE-LIVENESS-SECRET'),
          ),
        ),
      );
      active = true;
      // Use a fresh runtime: the eval pin cannot recover from host exceptions.
      runtime = Runtime(program.write().buffer.asByteData())..addPlugin(bridge);
      expect(() => invoke('text'), throwsA(anything));
    });
  }
}

const String _probe = r'''
import 'package:adele_ui/model_native_activity_bridge.dart';

Map<String, dynamic> inspect() => readModelNativeActivityData();
String text() => readModelNativeActivityData()['summaryParts'][0];
bool hasAuthority() {
  final Map<String, dynamic> data = readModelNativeActivityData();
  return data.containsKey('envelope') || data.containsKey('kind') ||
      data.containsKey('compatibility') || data.containsKey('compactText') ||
      data.containsKey('credentials') || data.containsKey('model') ||
      data.containsKey('tool') || data.containsKey('approval');
}
void mutateMap() { readModelNativeActivityData()['truncated'] = true; }
void mutateList() { readModelNativeActivityData()['summaryParts'].add('Changed'); }
void mutateNestedMap() {
  final Map<String, dynamic> nested = readModelNativeActivityData()['nested'][0];
  nested['int'] = 4;
}
''';
