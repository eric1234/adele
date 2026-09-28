import 'dart:async';

import 'package:dart_eval/dart_eval_bridge.dart';
import 'package:dart_eval/stdlib/core.dart';

import 'prepared_frontend.dart';
import 'structured_bridge_data.dart';

const _library = 'package:adele_ui/environment_terminal_bridge.dart';

class EnvironmentTerminalDeclarations implements EvalPlugin {
  const EnvironmentTerminalDeclarations();

  @override
  String get identifier => _library;

  @override
  void configureForCompile(BridgeDeclarationRegistry registry) {
    const string = BridgeTypeAnnotation(BridgeTypeRef(CoreTypes.string));
    const boolean = BridgeTypeAnnotation(BridgeTypeRef(CoreTypes.bool));
    registry.defineBridgeTopLevelFunction(
      const BridgeFunctionDeclaration(
        _library,
        'openEnvironmentTerminal',
        BridgeFunctionDef(
          returns: BridgeTypeAnnotation(
            BridgeTypeRef(CoreTypes.future, [
              BridgeTypeAnnotation(
                BridgeTypeRef(CoreTypes.list, [
                  BridgeTypeAnnotation(BridgeTypeRef(CoreTypes.dynamic)),
                ]),
              ),
            ]),
          ),
          params: [
            BridgeParameter('label', string, false),
            BridgeParameter('liveCloseMessage', string, false),
            BridgeParameter('followTitle', boolean, false),
            BridgeParameter('removeAfterExit', boolean, false),
          ],
        ),
      ),
    );
  }

  @override
  void configureForRuntime(Runtime runtime) =>
      throw UnsupportedError('Use an admitted console operation bridge.');
}

/// Validated contribution policy, copied out of a short-lived evaluator.
final class TerminalContentPolicy {
  TerminalContentPolicy({
    required this.label,
    required this.liveCloseMessage,
    required this.followTitle,
    required this.removeAfterExit,
  }) {
    for (final (text, limit) in [(label, 80), (liveCloseMessage, 512)]) {
      if (text.trim().isEmpty ||
          text.length > limit ||
          text.contains(
            RegExp(r'[\x00-\x1f\x7f-\x9f\u202a-\u202e\u2066-\u2069]'),
          )) {
        throw const FormatException('Invalid terminal content policy.');
      }
    }
  }

  final String label;
  final String liveCloseMessage;
  final bool followTitle;
  final bool removeAfterExit;
}

/// One admitted creation action, with no caller-selected Environment or handles.
final class EnvironmentTerminalBridge extends EnvironmentTerminalDeclarations
    implements PreparedFrontendBridge {
  EnvironmentTerminalBridge({
    required bool Function() isActive,
    required Future<void> Function(TerminalContentPolicy) create,
  }) : _isActive = isActive,
       _create = create;

  final bool Function() _isActive;
  final Future<void> Function(TerminalContentPolicy) _create;
  final Zone _nativeZone = Zone.current;
  bool _active = true;
  bool _used = false;
  bool _configured = false;

  @override
  void configureForRuntime(Runtime runtime) {
    if (_configured) throw StateError('Terminal operation is already bound.');
    _configured = true;
    runtime.registerBridgeFunc(_library, 'openEnvironmentTerminal', (
      _,
      _,
      args,
    ) {
      final completion = Completer<$Value>();
      _nativeZone.run(() async {
        try {
          if (!_active || _used || !_isActive()) {
            throw StateError('Console creation access is unavailable.');
          }
          _used = true;
          final policy = TerminalContentPolicy(
            label: args[0]!.$value as String,
            liveCloseMessage: args[1]!.$value as String,
            followTitle: args[2]!.$value as bool,
            removeAfterExit: args[3]!.$value as bool,
          );
          await _create(policy);
          completion.complete(wrapStructuredBridgeData([true, null]));
        } on Object {
          completion.complete(
            wrapStructuredBridgeData([
              false,
              'Terminal creation could not be completed.',
            ]),
          );
        }
      });
      return $Future<$Value>.wrap(completion.future);
    });
  }

  @override
  void invalidate() => _active = false;
}
