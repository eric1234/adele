import 'dart:async';
import 'dart:io';

import 'package:adele_contract/adele_contract.dart';
import 'package:adele_desktop/frontend/command_bridge.dart';
import 'package:adele_desktop/frontend/owning_backend_bridge.dart';
import 'package:adele_desktop/frontend/prepared_frontend.dart';
import 'package:dart_eval/dart_eval.dart';
import 'package:dart_eval/stdlib/core.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:session_evaluator_contract/session_evaluator_contract.dart';

import '../../../../../app/tool/session_evaluator_frontend_compiler.dart';

const _library =
    'package:session_evaluator_frontend/session_evaluator_frontend.dart';
const _path = '/private/evaluations/session/README.md';
const _success = 'Evaluation handoff README path copied to clipboard.';
const _failure = 'The evaluation handoff could not be prepared.';

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  final root = Directory.current.parent.parent.parent.parent;
  late Directory temporary;
  late File artifact;
  late PreparedFrontend frontend;
  late _Channel channel;
  late List<String> clipboard;
  late List<String> feedback;
  late bool clipboardFails;
  Completer<void>? clipboardGate;

  setUpAll(() async {
    temporary = await Directory.systemTemp.createTemp('session-evaluator-evc-');
    artifact = File('${temporary.path}/frontend.evc');
    await artifact.writeAsBytes(
      await compileSessionEvaluatorFrontend(repositoryRoot: root),
    );
  });
  tearDownAll(() => temporary.delete(recursive: true));

  setUp(() async {
    frontend = await PreparedFrontend.load(artifact);
    channel = _Channel();
    clipboard = [];
    feedback = [];
    clipboardFails = false;
    clipboardGate = null;
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method != 'Clipboard.setData') {
          throw StateError('Unexpected platform operation: ${call.method}');
        }
        clipboard.add((call.arguments as Map)['text'] as String);
        await clipboardGate?.future;
        if (clipboardFails) {
          throw PlatformException(code: 'SECRET platform diagnostic');
        }
        return null;
      },
    );
  });
  tearDown(() async {
    frontend.invalidate();
    if (clipboardGate case final gate? when !gate.isCompleted) gate.complete();
    if (!channel.listened.isCompleted) {
      await channel.controller.stream.listen(null).cancel();
    }
    await channel.controller.close();
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      null,
    );
  });

  Future<void> invoke() => frontend.invoke<void>(
    library: _library,
    entrypoint: 'prepareEvaluationHandoff',
    arguments: [$String('captured-session')],
    createBridge: () => PreparedFrontendBridges([
      OwningBackendBridge(
        channels: {sessionEvaluationHandoffServiceId: channel},
        validateBinding: () {},
      ),
      CommandBridge(
        clipboardWrite: true,
        feedback: true,
        validateOperation: () {},
        showFeedback: feedback.add,
      ),
    ]),
    decodeResult: (value) => expect(value == null || value is $null, isTrue),
  );

  test('native StreamIterator helper cannot compile with the pinned EVC', () {
    final source = File(
      '${root.path}/plugins/session_evaluator/packages/contract/lib/src/read_session_evaluation_handoff.dart',
    ).readAsStringSync();
    expect(
      () => (Compiler()..entrypoints.add('package:native_helper/read.dart'))
          .compile({
            'native_helper': {'read.dart': source},
          }),
      throwsA(
        predicate<Object>(
          (error) => error.toString().contains('StreamIterator'),
        ),
      ),
    );
  });

  test(
    'waits for EOF and OS acknowledgement before reporting success',
    () async {
      clipboardGate = Completer<void>();
      final operation = invoke();
      await channel.listened.future;
      expect(
        channel.calls.single.$1,
        sessionEvaluationHandoffServicePrepareSessionId,
      );
      expect(channel.calls.single.$2, {'sessionId': 'captured-session'});
      channel.controller.add(_path);
      await _flush();
      expect(clipboard, isEmpty);
      expect(feedback, isEmpty);
      await channel.controller.close();
      await _flush();
      expect(clipboard, [_path]);
      expect(feedback, isEmpty);
      clipboardGate!.complete();
      await operation;
      expect(feedback, [_success]);
      expect(channel.cancellations, 1);
    },
  );

  for (final path in [
    '/README.md',
    '/state/with space/#literal%20/README.md',
    '/state/one/../README.md',
    r'C:\state\evaluations\session\README.md',
    'C:/state/evaluations/session/README.md',
    r'\\server\share\evaluations\session\README.md',
  ]) {
    test('preserves native accepted path $path exactly', () async {
      final native = StreamIterator(Stream.value(path));
      expect(await readSessionEvaluationHandoff(native), path);
      await native.cancel();
      final operation = invoke();
      await channel.listened.future;
      channel.controller.add(path);
      await channel.controller.close();
      await operation;
      expect(clipboard, [path]);
      expect(feedback, [_success]);
    });
  }

  for (final path in [
    '',
    'README.md',
    'relative/README.md',
    r'C:relative\README.md',
    r'\current-drive\README.md',
    'https://example.test/README.md',
    '/state/summary.json',
    '$_path\u0000',
    '$_path/',
    'C:/bad?/README.md',
  ]) {
    test(
      'rejects native malformed path ${path.codeUnits} and cancels',
      () async {
        final native = StreamIterator(Stream.value(path));
        await expectLater(
          readSessionEvaluationHandoff(native),
          throwsA(anyOf(isA<FormatException>(), isA<ArgumentError>())),
        );
        await native.cancel();
        final operation = invoke();
        await channel.listened.future;
        channel.controller.add(path);
        await operation;
        expect(channel.cancellations, 1);
        expect(clipboard, isEmpty);
        expect(feedback, [_failure]);
      },
    );
  }

  for (final value in [
    null,
    4,
    <String, Object?>{'path': _path},
  ]) {
    test('generated decoder rejects non-string ${value.runtimeType}', () async {
      final operation = invoke();
      await channel.listened.future;
      channel.controller.add(value);
      await operation;
      expect(channel.cancellations, 1);
      expect(clipboard, isEmpty);
      expect(feedback, [_failure]);
    });
  }

  test('empty successful EOF is not a prepared handoff', () async {
    final operation = invoke();
    await channel.listened.future;
    await channel.controller.close();
    await operation;
    expect(clipboard, isEmpty);
    expect(feedback, [_failure]);
  });

  test(
    'extra completion cancels before EOF and never copies the first',
    () async {
      final operation = invoke();
      await channel.listened.future;
      channel.controller.add(_path);
      channel.controller.add('/other/README.md');
      await operation;
      expect(channel.cancellations, 1);
      expect(clipboard, isEmpty);
      expect(feedback, [_failure]);
    },
  );

  for (final afterValue in [false, true]) {
    test(
      'stream error afterValue=$afterValue never publishes success',
      () async {
        final operation = invoke();
        await channel.listened.future;
        if (afterValue) channel.controller.add(_path);
        channel.controller.addError(StateError('SECRET backend diagnostic'));
        await operation;
        expect(channel.cancellations, 1);
        expect(clipboard, isEmpty);
        expect(feedback, [_failure]);
      },
    );
  }

  test('clipboard failure reports the completed path, never success', () async {
    clipboardFails = true;
    final operation = invoke();
    await channel.listened.future;
    channel.controller.add(_path);
    await channel.controller.close();
    await operation;
    expect(clipboard, [_path]);
    expect(feedback, [
      'Handoff prepared, but the path could not be copied:\n$_path',
    ]);
  });

  for (final afterValue in [false, true]) {
    test(
      'retirement afterValue=$afterValue cancels without clipboard',
      () async {
        final operation = invoke();
        final failure = expectLater(
          operation,
          throwsA(
            predicate<Object>((error) => error.toString().contains('retired')),
          ),
        );
        await channel.listened.future;
        if (afterValue) channel.controller.add(_path);
        await _flush();
        frontend.invalidate();
        await failure;
        await _flush();
        expect(channel.cancellations, 1);
        expect(clipboard, isEmpty);
        expect(feedback, isEmpty);
      },
    );
  }

  test('retirement during OS write suppresses late success', () async {
    clipboardGate = Completer<void>();
    final operation = invoke();
    final failure = expectLater(operation, throwsA(isA<StateError>()));
    await channel.listened.future;
    channel.controller.add(_path);
    await channel.controller.close();
    await _flush();
    expect(clipboard, [_path]);
    frontend.invalidate();
    clipboardGate!.complete();
    await failure;
    await _flush();
    expect(feedback, isEmpty);
  });
}

Future<void> _flush() => Future<void>.delayed(Duration.zero);

final class _Channel implements AdeleStreamChannel {
  _Channel() {
    controller = StreamController<Object?>(
      onListen: listened.complete,
      onCancel: () => cancellations++,
    );
  }

  final listened = Completer<void>();
  late final StreamController<Object?> controller;
  final calls = <(String, Map<String, Object?>)>[];
  int cancellations = 0;

  @override
  Future<Object?> request(String method, Map<String, Object?> payload) =>
      throw StateError('Unexpected unary request.');

  @override
  Stream<Object?> stream(String method, Map<String, Object?> payload) {
    calls.add((method, payload));
    return controller.stream;
  }
}
