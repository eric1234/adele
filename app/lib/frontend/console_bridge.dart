import 'dart:async';

import 'package:adele_ui/adele_ui.dart';
import 'package:dart_eval/dart_eval_bridge.dart';
import 'package:dart_eval/stdlib/core.dart';

import 'prepared_frontend.dart';
import 'structured_bridge_data.dart';
import 'terminal_projection_bridge.dart';

const _library = 'package:adele_ui/console_bridge.dart';
const _map = BridgeTypeAnnotation(
  BridgeTypeRef(CoreTypes.map, [
    BridgeTypeAnnotation(BridgeTypeRef(CoreTypes.string)),
    BridgeTypeAnnotation(BridgeTypeRef(CoreTypes.dynamic)),
  ]),
);

class ConsoleDeclarations implements EvalPlugin {
  const ConsoleDeclarations();

  @override
  String get identifier => _library;

  @override
  void configureForCompile(BridgeDeclarationRegistry registry) {
    const string = BridgeTypeAnnotation(BridgeTypeRef(CoreTypes.string));
    registry.defineBridgeTopLevelFunction(
      const BridgeFunctionDeclaration(
        _library,
        'openPreparedConsole',
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
            BridgeParameter('extensionId', string, false),
            BridgeParameter('key', string, false),
            BridgeParameter('title', string, false),
            BridgeParameter('data', _map, false),
          ],
        ),
      ),
    );
    for (final name in ['readConsoleContentData', 'readConsoleContentState']) {
      registry.defineBridgeTopLevelFunction(
        BridgeFunctionDeclaration(
          _library,
          name,
          const BridgeFunctionDef(returns: _map),
        ),
      );
    }
    registry.defineBridgeTopLevelFunction(
      const BridgeFunctionDeclaration(
        _library,
        'writeConsoleContentState',
        BridgeFunctionDef(
          returns: BridgeTypeAnnotation(BridgeTypeRef(CoreTypes.bool)),
          params: [BridgeParameter('state', _map, false)],
        ),
      ),
    );
  }

  @override
  void configureForRuntime(Runtime runtime) =>
      throw UnsupportedError('Use a presentation-scoped console bridge.');
}

/// Native bounded data, not a Runtime, widget, subscription, or callback from the
/// originating card. Fresh content views share only this logical state.
final class ConsoleContentState {
  ConsoleContentState(this.descriptor);

  final ConsoleContentDescriptor descriptor;
  final projection = TerminalProjectionRetention();
  Map<String, Object?> _state = const {};
  Map<String, Object?> get state => _state;

  void write(Map<String, Object?> state) =>
      _state = copyConsoleContentData(state);
  void clear() {
    _state = const {};
    projection.clear();
  }
}

final class ConsoleBridge extends ConsoleDeclarations
    implements PreparedFrontendBridge {
  ConsoleBridge({
    required bool Function() isActive,
    Future<void> Function(String extensionId, ConsoleContentDescriptor)? open,
    ConsoleContentState? content,
  }) : _isActive = isActive,
       _open = open,
       _content = content;

  final bool Function() _isActive;
  final Future<void> Function(String, ConsoleContentDescriptor)? _open;
  final ConsoleContentState? _content;
  final Zone _nativeZone = Zone.current;
  bool _active = true;
  bool _configured = false;

  bool get isActive {
    try {
      return _active && _isActive();
    } on Object {
      return false;
    }
  }

  Future<List<Object?>> open(
    String extensionId,
    ConsoleContentDescriptor data,
  ) async {
    try {
      if (!isActive || _open == null) {
        throw StateError('Console access retired.');
      }
      // Admission transfers values and exact host authority before awaiting. Card
      // closure after this point cannot retract an independently admitted tab.
      await _open(extensionId, data);
      return [true, null];
    } on Object {
      return [false, 'Console content is unavailable.'];
    }
  }

  Map<String, Object?> readData() =>
      isActive && _content != null ? _content.descriptor.data : const {};
  Map<String, Object?> readState() =>
      isActive && _content != null ? _content.state : const {};

  bool writeState(Map<String, Object?> state) {
    if (!isActive || _content == null) return false;
    try {
      _content.write(state);
      return true;
    } on Object {
      return false;
    }
  }

  @override
  void configureForRuntime(Runtime runtime) {
    if (_configured) throw StateError('Console bridge is already bound.');
    _configured = true;
    runtime.registerBridgeFunc(_library, 'openPreparedConsole', (_, _, args) {
      final completion = Completer<$Value>();
      _nativeZone.run(() async {
        try {
          if (!isActive) throw StateError('Console access retired.');
          final descriptor = ConsoleContentDescriptor(
            key: args[1]!.$value as String,
            metadata: ConsoleMetadata(title: args[2]!.$value as String),
            data: copyStructuredBridgeData(args[3]) as Map<String, Object?>,
          );
          completion.complete(
            wrapStructuredBridgeData(
              await open(args[0]!.$value as String, descriptor),
            ),
          );
        } on Object {
          completion.complete(
            wrapStructuredBridgeData([
              false,
              'Console content is unavailable.',
            ]),
          );
        }
      });
      return $Future<$Value>.wrap(completion.future);
    });
    runtime.registerBridgeFunc(
      _library,
      'readConsoleContentData',
      (_, _, _) => wrapStructuredBridgeData(readData()),
    );
    runtime.registerBridgeFunc(
      _library,
      'readConsoleContentState',
      (_, _, _) => wrapStructuredBridgeData(readState()),
    );
    runtime.registerBridgeFunc(_library, 'writeConsoleContentState', (
      _,
      _,
      args,
    ) {
      try {
        return $bool(
          writeState(copyStructuredBridgeData(args[0]) as Map<String, Object?>),
        );
      } on Object {
        return $bool(false);
      }
    });
  }

  @override
  void invalidate() => _active = false;
}
