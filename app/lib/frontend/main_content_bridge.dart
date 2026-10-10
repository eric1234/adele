import 'dart:async';

import 'package:adele_plugin_api/adele_plugin_api.dart';
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
      ('sourceDisplayAvailability', string, const <BridgeParameter>[]),
      (
        'displaySourceFile',
        const BridgeTypeAnnotation(
          BridgeTypeRef(CoreTypes.future, [structuredBridgeMapType]),
        ),
        const [BridgeParameter('relativePath', string, false)],
      ),
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
      throw UnsupportedError('Use a scoped MainContentBridge.');
}

/// A view, initialization or finite operation over captured workbench context.
/// Collection requests additionally require the exact live attachment access.
final class MainContentBridge extends MainContentDeclarations
    implements PreparedFrontendBridge {
  MainContentBridge({
    MainContentAccess? access,
    required Map<String, Object?> context,
    required bool Function() isActive,
    void Function(String id, String title, bool canClose)? open,
    String paneId = '',
    ExtensionBinding<DisplaySourceFileContribution> Function()?
    resolveSourceDisplay,
  }) : _access = access,
       _context = Map.unmodifiable(context),
       _isActive = isActive,
       _open = open,
       _paneId = paneId,
       _resolveSourceDisplay = resolveSourceDisplay;

  final MainContentAccess? _access;
  final Map<String, Object?> _context;
  final bool Function() _isActive;
  final void Function(String, String, bool)? _open;
  final String _paneId;
  final ExtensionBinding<DisplaySourceFileContribution> Function()?
  _resolveSourceDisplay;
  final Zone _nativeZone = Zone.current;
  bool _active = true;
  bool _configured = false;

  bool get isActive {
    if (!_active) return false;
    try {
      if (_isActive() && (_access?.isActive ?? true)) return true;
    } on Object {
      // A failed liveness check permanently revokes this runtime's access.
    }
    invalidate();
    return false;
  }

  List<Map<String, Object?>> readPanes() {
    try {
      return _nativeZone.run(() {
        if (!isActive || _access == null) return const <Map<String, Object?>>[];
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
    return _context;
  }

  String sourceDisplayAvailability() => _nativeZone.run(() {
    if (!isActive) return 'retired';
    if (_resolveSourceDisplay == null) return 'denied';
    try {
      _resolveSourceDisplay().validate();
      return 'available';
    } on DisplaySourceFileUnavailable {
      return 'unavailable';
    } on AmbiguousDisplaySourceFile {
      return 'ambiguous';
    } on StaleExtensionBinding {
      return 'retired';
    } on Object {
      return 'unavailable';
    }
  });

  Future<Map<String, Object?>> displaySourceFile(String relativePath) =>
      _nativeZone.run(() async {
        if (!isActive) return const {'status': 'retired'};
        if (_resolveSourceDisplay == null) return const {'status': 'denied'};
        try {
          // Resolve and admit synchronously against the captured attachment. No
          // re-resolution, including after a selected registration is replaced.
          final binding = _resolveSourceDisplay();
          final result = await binding.value.display(relativePath);
          binding.validate();
          if (!isActive) return const {'status': 'retired'};
          return {'status': result['ok'] == false ? 'failed' : 'success'};
        } on DisplaySourceFileUnavailable {
          return {'status': isActive ? 'unavailable' : 'retired'};
        } on AmbiguousDisplaySourceFile {
          return {'status': isActive ? 'ambiguous' : 'retired'};
        } on StaleExtensionBinding {
          return const {'status': 'retired'};
        } on Object {
          return {'status': isActive ? 'failed' : 'retired'};
        }
      });

  bool _request(void Function() action) {
    try {
      return _nativeZone.run(() {
        if (!isActive || _access == null) return false;
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
        'sourceDisplayAvailability',
        (_, _, _) => $String(sourceDisplayAvailability()),
      )
      ..registerBridgeFunc(
        _library,
        'displaySourceFile',
        (_, _, args) => _nativeZone.run(
          () => $Future<$Value>.wrap(
            displaySourceFile(
              args.single!.$value as String,
            ).then(wrapStructuredBridgeData),
          ),
        ),
      )
      ..registerBridgeFunc(
        _library,
        'openMainContentPane',
        (_, _, args) => $bool(
          _request(
            () => _open!(
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
            () => _access!.setTitle(
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
            _access!.setOrder(List<String>.unmodifiable(data.cast<String>()));
          }),
        ),
      )
      ..registerBridgeFunc(
        _library,
        'removeMainContentPane',
        (_, _, args) => $bool(
          _request(() => _access!.remove(args.single!.$value as String)),
        ),
      )
      ..registerBridgeFunc(
        _library,
        'focusMainContentPane',
        (_, _, args) => $bool(
          _request(
            () => _access!.focus(
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
