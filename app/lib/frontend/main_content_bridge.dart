import 'dart:async';

import 'package:adele_ui/adele_ui.dart';
import 'package:dart_eval/dart_eval_bridge.dart';
import 'package:dart_eval/stdlib/core.dart';

import 'prepared_frontend.dart';
import 'structured_bridge_data.dart';

const _library = 'package:adele_ui/main_content_bridge.dart';

/// Compilation declares the ABI without acquiring collection or native access.
class MainContentDeclarations implements EvalPlugin {
  const MainContentDeclarations();

  @override
  String get identifier => _library;

  @override
  void configureForCompile(BridgeDeclarationRegistry registry) {
    const string = BridgeTypeAnnotation(BridgeTypeRef(CoreTypes.string));
    const boolean = BridgeTypeAnnotation(BridgeTypeRef(CoreTypes.bool));
    const strings = BridgeTypeAnnotation(
      BridgeTypeRef(CoreTypes.list, [string]),
    );
    const panes = BridgeTypeAnnotation(
      BridgeTypeRef(CoreTypes.list, [
        BridgeTypeAnnotation(
          BridgeTypeRef(CoreTypes.map, [
            string,
            BridgeTypeAnnotation(BridgeTypeRef(CoreTypes.dynamic)),
          ]),
        ),
      ]),
    );
    const id = BridgeParameter('id', string, false);
    const title = BridgeParameter('title', string, false);
    for (final (name, returns, params) in [
      ('readMainContentPanes', panes, const <BridgeParameter>[]),
      (
        'readMainContentContext',
        structuredBridgeMapType,
        const <BridgeParameter>[],
      ),
      ('readMainContentPaneId', string, const <BridgeParameter>[]),
      (
        'openMainContentPane',
        boolean,
        const [id, title, BridgeParameter('canClose', boolean, false)],
      ),
      ('setMainContentPaneTitle', boolean, const [id, title]),
      (
        'setMainContentPaneOrder',
        boolean,
        const [BridgeParameter('ids', strings, false)],
      ),
      ('removeMainContentPane', boolean, const [id]),
      (
        'focusMainContentPane',
        boolean,
        const [id, BridgeParameter('keyboardFocus', boolean, false)],
      ),
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
      throw UnsupportedError('Use an attachment-scoped MainContentBridge.');
}

/// A short-lived initialization or mounted pane, never a retained evaluator
/// service. All requests stay on the captured collection and native error zone.
final class MainContentBridge extends MainContentDeclarations
    implements PreparedFrontendBridge {
  MainContentBridge({
    required MainContentAccess access,
    required bool Function() isActive,
    required void Function(String id, String title, bool canClose) open,
    String paneId = '',
  }) : _access = access,
       _isActive = isActive,
       _open = open,
       _paneId = paneId;

  final MainContentAccess _access;
  final bool Function() _isActive;
  final void Function(String, String, bool) _open;
  final String _paneId;
  final Zone _nativeZone = Zone.current;
  bool _active = true;
  bool _configured = false;

  bool get isActive {
    if (!_active) return false;
    try {
      if (_isActive() && _access.isActive) return true;
    } on Object {
      // A failed liveness check permanently revokes this runtime's access.
    }
    invalidate();
    return false;
  }

  List<Map<String, Object?>> readPanes() {
    try {
      return _nativeZone.run(() {
        if (!isActive) return const <Map<String, Object?>>[];
        return List<Map<String, Object?>>.unmodifiable([
          for (final pane in _access.panes)
            Map<String, Object?>.unmodifiable({
              'id': pane.id,
              'title': pane.title,
              'canClose': pane.canClose,
            }),
        ]);
      });
    } on Object {
      return const [];
    }
  }

  String readPaneId() => isActive ? _paneId : '';

  Map<String, Object?> readContext() {
    if (!isActive) return const {};
    final session = _access.session;
    return Map<String, Object?>.unmodifiable({
      'sessionId': session.id.value,
      'strategyId': session.strategyId.value,
      'taskId': session.taskId.value,
    });
  }

  bool _request(void Function() action) {
    try {
      return _nativeZone.run(() {
        if (!isActive) return false;
        action();
        return true;
      });
    } on Object {
      // Native validation/cleanup diagnostics must not escape eval callbacks.
      return false;
    }
  }

  @override
  void configureForRuntime(Runtime runtime) {
    if (_configured) throw StateError('Main Content bridge is already bound.');
    _configured = true;
    runtime
      ..registerBridgeFunc(
        _library,
        'readMainContentContext',
        (_, _, _) => wrapStructuredBridgeData(readContext()),
      )
      ..registerBridgeFunc(_library, 'readMainContentPanes', (_, _, _) {
        try {
          return wrapStructuredBridgeData(readPanes());
        } on Object {
          return wrapStructuredBridgeData(const []);
        }
      })
      ..registerBridgeFunc(
        _library,
        'readMainContentPaneId',
        (_, _, _) => $String(readPaneId()),
      )
      ..registerBridgeFunc(
        _library,
        'openMainContentPane',
        (_, _, args) => $bool(
          _request(
            () => _open(
              args[0]!.$value as String,
              args[1]!.$value as String,
              args[2]!.$value as bool,
            ),
          ),
        ),
      )
      ..registerBridgeFunc(
        _library,
        'setMainContentPaneTitle',
        (_, _, args) => $bool(
          _request(
            () => _access.setTitle(
              args[0]!.$value as String,
              args[1]!.$value as String,
            ),
          ),
        ),
      )
      ..registerBridgeFunc(
        _library,
        'setMainContentPaneOrder',
        (_, _, args) => $bool(
          _request(() {
            final data = copyStructuredBridgeData(args.single);
            if (data is! List<Object?> || data.any((id) => id is! String)) {
              throw const FormatException('Pane order must be a string list.');
            }
            _access.setOrder(List<String>.unmodifiable(data.cast<String>()));
          }),
        ),
      )
      ..registerBridgeFunc(
        _library,
        'removeMainContentPane',
        (_, _, args) => $bool(
          _request(() => _access.remove(args.single!.$value as String)),
        ),
      )
      ..registerBridgeFunc(
        _library,
        'focusMainContentPane',
        (_, _, args) => $bool(
          _request(
            () => _access.focus(
              args[0]!.$value as String,
              keyboardFocus: args[1]!.$value as bool,
            ),
          ),
        ),
      );
  }

  @override
  void invalidate() => _active = false;
}
