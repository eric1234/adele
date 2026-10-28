import 'dart:math';

import 'package:dart_eval/dart_eval_bridge.dart';
import 'package:dart_eval/stdlib/core.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_eval/widgets.dart';

import '../editor/native_rich_document_editor.dart';
import 'prepared_frontend.dart';
import 'structured_bridge_data.dart';

const _library = 'package:adele_ui/rich_document_editor_bridge.dart';

/// Compile-time ABI only: declares no native owners or runtime authority.
class RichDocumentEditorDeclarations implements EvalPlugin {
  const RichDocumentEditorDeclarations();

  @override
  String get identifier => _library;

  @override
  void configureForCompile(BridgeDeclarationRegistry registry) {
    const string = BridgeTypeAnnotation(BridgeTypeRef(CoreTypes.string));
    const map = BridgeTypeAnnotation(
      BridgeTypeRef(CoreTypes.map, [
        string,
        BridgeTypeAnnotation(BridgeTypeRef(CoreTypes.dynamic)),
      ]),
    );
    const voidType = BridgeTypeAnnotation(BridgeTypeRef(CoreTypes.voidType));
    const handle = BridgeParameter('handle', string, false);
    const listener = BridgeParameter(
      'listener',
      BridgeTypeAnnotation(BridgeTypeRef(CoreTypes.function)),
      false,
    );
    for (final (name, returns, params) in [
      (
        'createRichDocumentEditor',
        string,
        const [
          BridgeParameter('markdown', string, false),
          BridgeParameter(
            'readOnly',
            BridgeTypeAnnotation(BridgeTypeRef(CoreTypes.bool)),
            false,
          ),
        ],
      ),
      (
        'buildRichDocumentEditor',
        const BridgeTypeAnnotation($Widget.$type),
        const [handle],
      ),
      ('snapshotRichDocumentEditor', map, const [handle]),
      ('subscribeRichDocumentEditor', voidType, const [handle, listener]),
      ('unsubscribeRichDocumentEditor', voidType, const [handle, listener]),
      ('releaseRichDocumentEditor', voidType, const [handle]),
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
  void configureForRuntime(Runtime runtime) => throw UnsupportedError(
    'Use a presentation-scoped RichDocumentEditorBridge.',
  );
}

/// Owns a bounded set of editors and one captured evaluator. Unlike a
/// host-selected code editor, these owners end with their creating presentation.
final class RichDocumentEditorBridge extends RichDocumentEditorDeclarations
    implements PreparedFrontendBridge, PreparedFrontendFailureSource {
  RichDocumentEditorBridge({required bool Function() isActive})
    : _isActive = isActive;

  final bool Function() _isActive;
  final Map<String, _Editor> _editors = {};
  Runtime? _runtime;
  bool _active = true;

  @override
  VoidCallback? onFailure;

  bool get _available {
    if (!_active) return false;
    try {
      if (_isActive() && _active) return true;
    } on Object {
      // A failed liveness check permanently revokes this presentation.
    }
    invalidate();
    return false;
  }

  void _validate() {
    if (!_available) {
      throw StateError('Rich document editor presentation is retired.');
    }
  }

  _Editor _resolve(Object? handle) {
    _validate();
    final editor = _editors[handle];
    if (editor == null) {
      throw StateError('Editor handle was not issued to this presentation.');
    }
    return editor;
  }

  @override
  void configureForRuntime(Runtime runtime) {
    if (_runtime != null) {
      throw StateError('Rich document editor bridge is already bound.');
    }
    _validate();
    _runtime = runtime;
    runtime
      ..registerBridgeFunc(_library, 'createRichDocumentEditor', (_, _, args) {
        _validate();
        if (_editors.length >= 16) {
          throw StateError('Rich document editor limit reached.');
        }
        final random = Random.secure();
        final handle = List.generate(
          24,
          (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
        ).join();
        final editor = _Editor(
          NativeRichDocumentEditor(
            markdown: args[0]!.$value as String,
            readOnly: args[1]!.$value as bool,
          ),
        );
        editor.changed = () => _changed(handle, editor);
        editor.owner.addListener(editor.changed);
        _editors[handle] = editor;
        return $String(handle);
      })
      ..registerBridgeFunc(_library, 'buildRichDocumentEditor', (_, _, args) {
        final editor = _resolve(args.single!.$value);
        return $Widget.wrap(editor.view ??= editor.owner.buildView());
      })
      ..registerBridgeFunc(_library, 'snapshotRichDocumentEditor', (
        _,
        _,
        args,
      ) {
        final owner = _resolve(args.single!.$value).owner;
        Map<String, Object?> snapshot;
        try {
          snapshot = owner.snapshot();
        } on FormatException {
          snapshot = {
            'markdown': null,
            'revision': owner.revision,
            'readOnly': owner.readOnly,
            'unsupportedReason': owner.unsupportedReason,
            'error': 'unsupported_serialization',
          };
        }
        _validate();
        return wrapStructuredBridgeData(snapshot);
      })
      ..registerBridgeFunc(_library, 'subscribeRichDocumentEditor', (
        _,
        _,
        args,
      ) {
        _resolve(args[0]!.$value).listeners.add(args[1]! as EvalCallable);
        return null;
      })
      ..registerBridgeFunc(_library, 'unsubscribeRichDocumentEditor', (
        _,
        _,
        args,
      ) {
        if (!_available) return null;
        _resolve(args[0]!.$value).listeners.remove(args[1]! as EvalCallable);
        return null;
      })
      ..registerBridgeFunc(_library, 'releaseRichDocumentEditor', (_, _, args) {
        if (!_available) return null;
        final handle = args.single!.$value;
        final editor = _resolve(handle);
        _editors.remove(handle);
        editor.dispose();
        return null;
      });
  }

  void _changed(String handle, _Editor editor) {
    // A failed liveness check disposes owners, which cannot happen inside their
    // ChangeNotifier dispatch. Check after the frame, even without subscribers.
    if (!_active || editor.scheduled) return;
    editor.scheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      editor.scheduled = false;
      if (!_available || !identical(_editors[handle], editor)) return;
      for (final listener in editor.listeners.toList()) {
        if (!_available || !identical(_editors[handle], editor)) return;
        if (!editor.listeners.contains(listener)) continue;
        try {
          listener.call(_runtime!, null, const []);
        } on Object {
          if (_active) {
            invalidate();
            onFailure?.call();
          }
          return;
        }
      }
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  // PreparedFrontend calls this even while retaining already-mounted exit UI.
  @override
  void invalidate() {
    if (!_active) return;
    _active = false;
    final editors = _editors.values.toList();
    _editors.clear();
    for (final editor in editors) {
      editor.dispose();
    }
  }
}

final class _Editor {
  _Editor(this.owner);

  final NativeRichDocumentEditor owner;
  final Set<EvalCallable> listeners = Set.identity();
  late final VoidCallback changed;
  Widget? view;
  bool scheduled = false;

  void dispose() {
    listeners.clear();
    owner.removeListener(changed);
    view = null;
    owner.dispose();
  }
}
