import 'dart:async';

import 'package:adele_ui/adele_ui.dart';
import 'package:dart_eval/dart_eval_bridge.dart';
import 'package:dart_eval/stdlib/core.dart';
import 'package:flutter/widgets.dart';

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
    const integer = BridgeTypeAnnotation(BridgeTypeRef(CoreTypes.int));
    const boolean = BridgeTypeAnnotation(BridgeTypeRef(CoreTypes.bool));
    const voidType = BridgeTypeAnnotation(BridgeTypeRef(CoreTypes.voidType));
    const listener = BridgeParameter(
      'listener',
      BridgeTypeAnnotation(BridgeTypeRef(CoreTypes.function)),
      false,
    );
    for (final (name, returns, params) in [
      ('readConsoleInteraction', integer, const <BridgeParameter>[]),
      (
        'isConsoleInteractionActive',
        boolean,
        const [BridgeParameter('epoch', integer, false)],
      ),
      ('subscribeConsoleInteraction', voidType, const [listener]),
      ('unsubscribeConsoleInteraction', voidType, const [listener]),
    ]) {
      registry.defineBridgeTopLevelFunction(
        BridgeFunctionDeclaration(
          _library,
          name,
          BridgeFunctionDef(returns: returns, params: params),
        ),
      );
    }
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
    implements PreparedFrontendBridge, PreparedFrontendFailureSource {
  ConsoleBridge({
    required bool Function() isActive,
    Future<void> Function(String extensionId, ConsoleContentDescriptor)? open,
    ConsoleContentState? content,
    ConsolePresentationAccess? presentation,
  }) : _isActive = isActive,
       _open = open,
       _content = content,
       _presentation = presentation;

  final bool Function() _isActive;
  final Future<void> Function(String, ConsoleContentDescriptor)? _open;
  final ConsoleContentState? _content;
  final ConsolePresentationAccess? _presentation;
  final Zone _nativeZone = Zone.current;
  final Map<EvalCallable, VoidCallback> _listeners = Map.identity();
  ConsoleInteractionAccess? _interaction;
  int _epoch = 0;
  int _nextEpoch = 0;
  bool _active = true;
  bool _configured = false;
  bool _scheduled = false;

  @override
  VoidCallback? onFailure;

  bool get isActive {
    try {
      return _active && _isActive() && (_presentation?.isActive ?? true);
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

  int readInteraction() {
    if (!isActive) return 0;
    final presentation = _presentation;
    if (presentation == null) return 0;
    final interaction = presentation.interaction;
    if (interaction == null || !interaction.isActive) {
      _interaction = null;
      _epoch = 0;
      return 0;
    }
    if (!identical(interaction, _interaction)) {
      _interaction = interaction;
      _epoch = ++_nextEpoch;
    }
    return _epoch;
  }

  bool isInteractionActive(int epoch) =>
      epoch > 0 && epoch == readInteraction();

  void _interactionChanged() {
    if (!isActive) {
      invalidate();
      return;
    }
    readInteraction();
    if (_scheduled || _listeners.isEmpty) return;
    _scheduled = true;
    final queued = Map.of(_listeners);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scheduled = false;
      for (final entry in queued.entries) {
        if (!isActive) return;
        if (!identical(_listeners[entry.key], entry.value)) continue;
        try {
          entry.value();
        } on Object {
          invalidate();
          onFailure?.call();
          return;
        }
      }
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  @override
  void configureForRuntime(Runtime runtime) {
    if (_configured) throw StateError('Console bridge is already bound.');
    _configured = true;
    if (_active) _presentation?.changes.addListener(_interactionChanged);
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
    runtime.registerBridgeFunc(
      _library,
      'readConsoleInteraction',
      (_, _, _) => $int(readInteraction()),
    );
    runtime.registerBridgeFunc(
      _library,
      'isConsoleInteractionActive',
      (_, _, args) => $bool(isInteractionActive(args.single!.$value as int)),
    );
    runtime.registerBridgeFunc(_library, 'subscribeConsoleInteraction', (
      _,
      _,
      args,
    ) {
      if (!isActive) return null;
      final listener = args.single! as EvalCallable;
      _listeners.putIfAbsent(
        listener,
        () =>
            () => listener.call(runtime, null, const []),
      );
      return null;
    });
    runtime.registerBridgeFunc(_library, 'unsubscribeConsoleInteraction', (
      _,
      _,
      args,
    ) {
      _listeners.remove(args.single! as EvalCallable);
      return null;
    });
  }

  @override
  void invalidate() {
    if (!_active) return;
    _active = false;
    _presentation?.changes.removeListener(_interactionChanged);
    _interaction = null;
    _epoch = 0;
    _listeners.clear();
  }
}
