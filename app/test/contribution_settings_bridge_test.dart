import 'dart:io';

import 'package:adele_desktop/frontend/contribution_bridge.dart';
import 'package:adele_ui/contribution_bridge.dart' as public_bridge;
import 'package:dart_eval/dart_eval.dart';
import 'package:dart_eval/dart_eval_bridge.dart';
import 'package:dart_eval/stdlib/core.dart';
import 'package:flutter_test/flutter_test.dart';

const _library = 'package:settings_consumer/main.dart';

void main() {
  late Program program;
  late RetainedContribution owner;

  setUpAll(() async {
    program =
        (Compiler()
              ..addPlugin(const ContributionDeclarations())
              ..entrypoints.add(_library))
            .compile({
              'settings_consumer': {
                'main.dart': '''
import 'package:adele_ui/contribution_bridge.dart';
Object read(String id) => readPluginSetting(id);
List<String> keys() => readContributionKeys();
Future<bool> createLegacy() => createContributionCodeEditor('old', '', 'plain');
Future<bool> createWithFolding() => createContributionCodeEditor('new', '', 'plain', true);
''',
              },
              'adele_ui': {
                'contribution_bridge.dart': await File(
                  '../packages/ui/lib/contribution_bridge.dart',
                ).readAsString(),
              },
            });
  });

  setUp(() => owner = RetainedContribution());
  tearDown(() => owner.dispose());

  Runtime bind({
    Object Function(String)? readSetting,
    bool Function()? active,
  }) {
    final bridge = ContributionBridge(
      owner: owner,
      isActive: active ?? () => true,
      retainedData: false,
      nativeCodeEditor: false,
      readSetting: readSetting,
    );
    addTearDown(bridge.invalidate);
    return Runtime.ofProgram(program)..addPlugin(bridge);
  }

  Object? read(Runtime runtime, String id) {
    final value = runtime.executeLib(_library, 'read', [$String(id)]);
    return value is $Value ? value.$reified : value;
  }

  test('public setting stub has no native authority', () {
    expect(
      () => public_bridge.readPluginSetting('test.owner.enabled'),
      throwsUnsupportedError,
    );
  });

  test(
    'host-validated scalars need neither retained-data nor editor grants',
    () {
      final values = <String, Object>{
        'test.owner.enabled': true,
        'test.owner.disabled': false,
        'test.owner.count': 3,
        'test.owner.text': 'label',
        'test.owner.choice': 'compact',
      };
      final runtime = bind(
        readSetting: (id) =>
            values[id] ?? (throw StateError('Undeclared setting.')),
      );
      for (final entry in values.entries) {
        expect(read(runtime, entry.key), entry.value);
      }
      expect(() => runtime.executeLib(_library, 'keys'), throwsA(anything));
    },
  );

  test('missing, foreign, and invalid settings never return a fallback', () {
    expect(() => read(bind(), 'test.owner.enabled'), throwsA(anything));
    final runtime = bind(
      readSetting: (_) => throw StateError('Denied setting.'),
    );
    for (final id in ['test.foreign.enabled', 'test.owner.unknown']) {
      expect(() => read(runtime, id), throwsA(anything));
    }
    expect(
      () => read(bind(readSetting: (_) => <String>[]), 'test.owner.enabled'),
      throwsA(anything),
    );
  });

  test('retired access is denied before invoking its captured reader', () {
    var active = true;
    var reads = 0;
    final runtime = bind(
      active: () => active,
      readSetting: (_) {
        reads++;
        return true;
      },
    );
    expect(read(runtime, 'test.owner.enabled'), isTrue);
    active = false;
    expect(() => read(runtime, 'test.owner.enabled'), throwsA(anything));
    active = true;
    expect(() => read(runtime, 'test.owner.enabled'), throwsA(anything));
    expect(reads, 1);
    final afterClose = bind(readSetting: (_) => true);
    owner.dispose();
    expect(() => read(afterClose, 'test.owner.enabled'), throwsA(anything));
  });

  test(
    'editor bridge supports both three and four positional arguments',
    () async {
      for (final entrypoint in ['createLegacy', 'createWithFolding']) {
        final value = bind().executeLib(_library, entrypoint) as $Value;
        final result = await (value.$value as Future);
        expect(result is $Value ? result.$reified : result, isFalse);
      }
    },
  );
}
