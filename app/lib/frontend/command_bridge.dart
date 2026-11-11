import 'dart:async';

import 'package:dart_eval/dart_eval_bridge.dart';
import 'package:dart_eval/stdlib/core.dart';
import 'package:flutter/services.dart';

import 'prepared_frontend.dart';

const _bridgeLibrary = 'package:adele_ui/command_bridge.dart';

/// Compile-only declarations grant no native access.
class CommandDeclarations implements EvalPlugin {
  const CommandDeclarations();

  @override
  String get identifier => _bridgeLibrary;

  @override
  void configureForCompile(BridgeDeclarationRegistry registry) {
    registry.defineBridgeTopLevelFunction(
      const BridgeFunctionDeclaration(
        _bridgeLibrary,
        'writeCommandClipboard',
        BridgeFunctionDef(
          returns: BridgeTypeAnnotation(
            BridgeTypeRef(CoreTypes.future, [
              BridgeTypeAnnotation(BridgeTypeRef(CoreTypes.bool)),
            ]),
          ),
          params: [
            BridgeParameter(
              'text',
              BridgeTypeAnnotation(BridgeTypeRef(CoreTypes.string)),
              false,
            ),
          ],
        ),
      ),
    );
    registry.defineBridgeTopLevelFunction(
      const BridgeFunctionDeclaration(
        _bridgeLibrary,
        'showCommandFeedback',
        BridgeFunctionDef(
          returns: BridgeTypeAnnotation(BridgeTypeRef(CoreTypes.voidType)),
          params: [
            BridgeParameter(
              'message',
              BridgeTypeAnnotation(BridgeTypeRef(CoreTypes.string)),
              false,
            ),
          ],
        ),
      ),
    );
  }

  @override
  void configureForRuntime(Runtime runtime) =>
      throw UnsupportedError('Use an operation-scoped CommandBridge.');
}

/// Native authority belongs to one admitted operation, never an eval global.
final class CommandBridge extends CommandDeclarations
    implements PreparedFrontendBridge {
  CommandBridge({
    required this.clipboardWrite,
    required this.feedback,
    required void Function() validateOperation,
    void Function(String)? showFeedback,
  }) : _validateOperation = validateOperation,
       _showFeedback = showFeedback;

  final bool clipboardWrite;
  final bool feedback;
  final void Function() _validateOperation;
  final void Function(String)? _showFeedback;
  final Zone _nativeZone = Zone.current;
  bool _active = true;

  void _validate(String text) {
    if (!_active) throw StateError('The Command operation is retired.');
    _validateOperation();
    if (text.length > 16384) {
      throw const FormatException('Command text exceeds its size limit.');
    }
  }

  Future<bool> writeClipboard(String text) async {
    _validate(text);
    if (!clipboardWrite) {
      throw StateError('Clipboard writing was not declared.');
    }
    var copied = false;
    try {
      await Clipboard.setData(ClipboardData(text: text));
      copied = true;
    } on Object {
      // Platform diagnostics may contain copied text; expose only the outcome.
    }
    _validate(text);
    return copied;
  }

  void showFeedback(String message) {
    _validate(message);
    if (!feedback) throw StateError('Command feedback was not declared.');
    _showFeedback?.call(message);
  }

  @override
  void configureForRuntime(Runtime runtime) {
    runtime.registerBridgeFunc(_bridgeLibrary, 'writeCommandClipboard', (
      _,
      _,
      args,
    ) {
      // Relay host futures into the operation's guarded eval zone, as with the
      // picker bridge. Native failures never carry platform diagnostics to eval.
      final completion = Completer<$Value>();
      _nativeZone.run(() {
        writeClipboard((args[0]! as $String).$value).then(
          (copied) => completion.complete($bool(copied)),
          onError: completion.completeError,
        );
      });
      completion.future.ignore();
      return $Future<$Value>.wrap(completion.future);
    });
    runtime.registerBridgeFunc(_bridgeLibrary, 'showCommandFeedback', (
      _,
      _,
      args,
    ) {
      showFeedback((args[0]! as $String).$value);
      return const $null();
    });
  }

  @override
  void invalidate() => _active = false;
}
