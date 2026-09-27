import 'dart:async';
import 'dart:io';

import 'package:adele_desktop/frontend/session_presentation_lifecycle_bridge.dart';
import 'package:adele_ui/session_presentation_lifecycle_bridge.dart'
    as public_bridge;
import 'package:dart_eval/dart_eval.dart';
import 'package:dart_eval/dart_eval_bridge.dart';
import 'package:dart_eval/stdlib/core.dart';
import 'package:flutter_test/flutter_test.dart';

const _library = 'package:lifecycle_probe/main.dart';

void main() {
  late Program program;
  setUpAll(() {
    final compiler = Compiler()
      ..addPlugin(const SessionPresentationLifecycleDeclarations())
      ..addPlugin(_Gate())
      ..entrypoints.add(_library);
    program = compiler.compile({
      'lifecycle_probe': {
        'main.dart': '''
import 'package:adele_ui/session_presentation_lifecycle_bridge.dart';
import 'package:gate/main.dart';
int calls = 0;
final callback = () async { calls++; return await waitForSave(); };
final other = () async => true;
void register() => registerSessionPrepareToDeactivate(callback);
void registerOther() => registerSessionPrepareToDeactivate(other);
void unregister() => unregisterSessionPrepareToDeactivate(callback);
void unregisterOther() => unregisterSessionPrepareToDeactivate(other);
int count() => calls;
Future<bool> broken() async { throw StateError('private interpreted failure'); }
void registerBroken() => registerSessionPrepareToDeactivate(broken);
Future<dynamic> malformed() async => 'not a boolean';
void registerMalformed() => registerSessionPrepareToDeactivate(malformed);
''',
      },
      'gate': {'main.dart': 'Future<bool> waitForSave() async => true;'},
      'adele_ui': {
        'session_presentation_lifecycle_bridge.dart': File(
          '${Directory.current.parent.path}/packages/ui/lib/session_presentation_lifecycle_bridge.dart',
        ).readAsStringSync(),
      },
    });
  });

  test('public stubs grant no native lifecycle access', () {
    Future<bool> callback() async => true;
    expect(
      () => public_bridge.registerSessionPrepareToDeactivate(callback),
      throwsUnsupportedError,
    );
    expect(
      () => public_bridge.unregisterSessionPrepareToDeactivate(callback),
      throwsUnsupportedError,
    );
  });

  test(
    'no hook succeeds; exact callback is awaited, rejected and retryable',
    () async {
      final gate = _Gate();
      final bridge = SessionPresentationLifecycleBridge(isActive: () => true);
      addTearDown(bridge.invalidate);
      final runtime = Runtime.ofProgram(program)
        ..addPlugin(bridge)
        ..addPlugin(gate);
      void invoke(String entry) => runtime.executeLib(_library, entry);
      await bridge.prepareToDeactivate();
      invoke('register');
      invoke('register');
      expect(() => invoke('registerOther'), throwsA(anything));
      invoke('unregisterOther');
      var completed = false;
      final pending = bridge.prepareToDeactivate().then(
        (_) => completed = true,
      );
      await Future<void>.delayed(Duration.zero);
      expect(completed, isFalse);
      expect(runtime.executeLib(_library, 'count'), 1);
      gate.pending.complete(true);
      await pending;
      gate.pending = Completer<bool>();
      final failed = expectLater(bridge.prepareToDeactivate(), _safeFailure);
      gate.pending.complete(false);
      await failed;
      gate.pending = Completer<bool>();
      final retry = bridge.prepareToDeactivate();
      gate.pending.complete(true);
      await retry;
      expect(runtime.executeLib(_library, 'count'), 3);
      invoke('unregister');
      await bridge.prepareToDeactivate();
      expect(runtime.executeLib(_library, 'count'), 3);
    },
  );

  for (final entry in ['register', 'registerBroken', 'registerMalformed']) {
    test('$entry failure stays safe on the native side', () async {
      final gate = _Gate();
      final bridge = SessionPresentationLifecycleBridge(isActive: () => true);
      addTearDown(bridge.invalidate);
      final runtime = Runtime.ofProgram(program)
        ..addPlugin(bridge)
        ..addPlugin(gate);
      runtime.executeLib(_library, entry);
      final failed = expectLater(bridge.prepareToDeactivate(), _safeFailure);
      if (entry == 'register') {
        gate.pending.completeError(StateError('private native failure'));
      }
      await failed;
    });
  }

  for (final retirement in [
    'invalidate',
    'liveness',
    'unregister',
    'reregister',
  ]) {
    test(
      '$retirement during callback rejects late success and clears exact hook',
      () async {
        var active = true;
        var invalidations = 0;
        final gate = _Gate();
        final bridge = SessionPresentationLifecycleBridge(
          isActive: () => active,
          onInvalidate: () => invalidations++,
        );
        addTearDown(bridge.invalidate);
        final runtime = Runtime.ofProgram(program)
          ..addPlugin(bridge)
          ..addPlugin(gate);
        runtime.executeLib(_library, 'register');
        final failed = expectLater(bridge.prepareToDeactivate(), _safeFailure);
        switch (retirement) {
          case 'invalidate':
            bridge.invalidate();
          case 'liveness':
            active = false;
          case 'unregister':
            runtime.executeLib(_library, 'unregister');
          case 'reregister':
            runtime.executeLib(_library, 'unregister');
            runtime.executeLib(_library, 'register');
        }
        gate.pending.complete(true);
        await failed;
        active = true;
        if (retirement == 'unregister' || retirement == 'reregister') {
          await bridge.prepareToDeactivate();
          expect(invalidations, 0);
        } else {
          await expectLater(bridge.prepareToDeactivate(), _safeFailure);
          expect(
            () => runtime.executeLib(_library, 'register'),
            throwsA(anything),
          );
          expect(invalidations, 1);
        }
        expect(
          runtime.executeLib(_library, 'count'),
          retirement == 'reregister' ? 2 : 1,
        );
      },
    );
  }

  test(
    'retirement before invocation prevents the callback from running',
    () async {
      var active = true;
      final bridge = SessionPresentationLifecycleBridge(isActive: () => active);
      final runtime = Runtime.ofProgram(program)
        ..addPlugin(bridge)
        ..addPlugin(_Gate());
      runtime.executeLib(_library, 'register');
      active = false;
      await expectLater(bridge.prepareToDeactivate(), _safeFailure);
      expect(runtime.executeLib(_library, 'count'), 0);
      active = true;
      await expectLater(bridge.prepareToDeactivate(), _safeFailure);
    },
  );
}

final _safeFailure = throwsA(
  isA<StateError>().having(
    (error) => error.message,
    'safe failure',
    'Session presentation could not prepare to deactivate.',
  ),
);

final class _Gate implements EvalPlugin {
  Completer<bool> pending = Completer<bool>();
  @override
  String get identifier => 'package:gate/main.dart';
  @override
  void configureForCompile(BridgeDeclarationRegistry registry) {
    registry.defineBridgeTopLevelFunction(
      const BridgeFunctionDeclaration(
        'package:gate/main.dart',
        'waitForSave',
        BridgeFunctionDef(
          returns: BridgeTypeAnnotation(
            BridgeTypeRef(CoreTypes.future, [
              BridgeTypeAnnotation(BridgeTypeRef(CoreTypes.bool)),
            ]),
          ),
        ),
      ),
    );
  }

  @override
  void configureForRuntime(Runtime runtime) {
    runtime.registerBridgeFunc(
      identifier,
      'waitForSave',
      (_, _, _) => $Future<$Value>.wrap(
        pending.future.then<$Value>((value) => $bool(value)),
      ),
    );
  }
}
