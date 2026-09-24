import 'dart:async';
import 'dart:io';

import 'package:dart_eval/dart_eval.dart';
import 'package:dart_eval/dart_eval_bridge.dart';
import 'package:dart_eval/stdlib/core.dart';
import 'package:flutter_test/flutter_test.dart';

const _library =
    'package:local_directory_project_frontend/local_directory_project_frontend.dart';
const _bridgeLibrary = 'package:adele_ui/directory_picker_bridge.dart';

void main() {
  late Program program;
  late _Picker picker;
  late Runtime runtime;

  setUpAll(() {
    program =
        (Compiler()
              ..addPlugin(_Picker())
              ..entrypoints.add(_library))
            .compile({
              'local_directory_project_frontend': {
                'local_directory_project_frontend.dart': File(
                  'lib/local_directory_project_frontend.dart',
                ).readAsStringSync(),
              },
            });
  });

  setUp(() {
    picker = _Picker();
    runtime = Runtime(program.write().buffer.asByteData())..addPlugin(picker);
  });

  Future<Object?> select() async {
    final result = runtime.executeLib(_library, 'selectProject') as $Value;
    final Object? value = await (result.$value as Future<Object?>);
    return value is $Value ? value.$reified : value;
  }

  for (final (path, expected) in [
    ('/selected project', 'file:///selected%20project/'),
    ('/selected project/', 'file:///selected%20project/'),
    ('/parent/../selected project/.', 'file:///selected%20project/'),
    ('/../../selected project', 'file:///selected%20project/'),
    ('/', 'file:///'),
    ('/a#b?c%20', 'file:///a%23b%3Fc%2520/'),
    ('/not-created/project', 'file:///not-created/project/'),
    (r'C:\selected project', 'file:///C:/selected%20project/'),
    (r'C:\parent\..\selected project\.', 'file:///C:/selected%20project/'),
    ('C:/parent/../selected project/', 'file:///C:/selected%20project/'),
    ('C:\\', 'file:///C:/'),
    (
      r'\\server\share\selected project',
      'file://server/share/selected%20project/',
    ),
    (
      r'\\server\share\parent\..\selected project',
      'file://server/share/selected%20project/',
    ),
  ]) {
    test(
      'evaluated selector converts $path to a normalized file URI',
      () async {
        picker.pick = () async => path;
        expect(picker.calls, 0);
        expect(await select(), expected);
        expect(picker.calls, 1);
      },
    );
  }

  test('null is cancellation, not a URI', () async {
    expect(await select(), isNull);
    expect(picker.calls, 1);
  });

  for (final path in [
    '',
    'relative',
    '.',
    '../project',
    r'C:project',
    r'\project',
  ]) {
    test('evaluated selector rejects empty or relative path "$path"', () async {
      picker.pick = () async => path;
      await expectLater(
        select(),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            contains(path.isEmpty ? 'empty path' : 'relative path'),
          ),
        ),
      );
      expect(picker.calls, 1);
    });
  }

  test('selection awaits the picker before converting its result', () async {
    final pending = Completer<String?>();
    picker.pick = () => pending.future;
    bool settled = false;
    final result = select().then((value) {
      settled = true;
      return value;
    });
    await Future<void>.delayed(Duration.zero);
    expect(picker.calls, 1);
    expect(settled, isFalse);
    pending.complete('/selected project');
    expect(await result, 'file:///selected%20project/');
  });

  for (final synchronous in [false, true]) {
    test(
      'picker failure remains an error (synchronous: $synchronous)',
      () async {
        final failure = StateError('picker failed');
        picker.pick = synchronous
            ? () => throw failure
            : () async => throw failure;
        await expectLater(
          select(),
          throwsA(
            synchronous
                ? isA<Exception>().having(
                    (error) => error.toString(),
                    'message',
                    contains('picker failed'),
                  )
                : same(failure),
          ),
        );
        expect(picker.calls, 1);
      },
    );
  }
}

final class _Picker implements EvalPlugin {
  int calls = 0;
  Future<String?> Function() pick = () async => null;

  @override
  String get identifier => _bridgeLibrary;

  @override
  void configureForCompile(BridgeDeclarationRegistry registry) {
    registry.defineBridgeTopLevelFunction(
      const BridgeFunctionDeclaration(
        _bridgeLibrary,
        'pickDirectory',
        BridgeFunctionDef(
          returns: BridgeTypeAnnotation(
            BridgeTypeRef(CoreTypes.future, [
              BridgeTypeAnnotation(
                BridgeTypeRef(CoreTypes.string),
                nullable: true,
              ),
            ]),
          ),
        ),
      ),
    );
  }

  @override
  void configureForRuntime(Runtime runtime) {
    runtime.registerBridgeFunc(_bridgeLibrary, 'pickDirectory', (_, _, _) {
      calls++;
      return $Future.wrap(
        pick().then<$Value>(
          (path) => path == null ? const $null() : $String(path),
        ),
      );
    });
  }
}
