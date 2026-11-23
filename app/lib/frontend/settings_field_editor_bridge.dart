import 'package:adele_plugin_api/adele_plugin_api.dart';
import 'package:adele_ui/adele_ui.dart';
import 'package:dart_eval/dart_eval_bridge.dart';
import 'package:dart_eval/stdlib/core.dart';
import 'package:flutter/foundation.dart';

import 'prepared_frontend.dart';

const _library = 'package:adele_ui/settings_field_editor_bridge.dart';
const _unavailable = 'Field editor unavailable.';
const _invalid = 'Invalid field value.';

/// Build-time declarations have no draft or registration authority.
class SettingsFieldEditorDeclarations implements EvalPlugin {
  const SettingsFieldEditorDeclarations();

  @override
  String get identifier => _library;

  @override
  void configureForCompile(BridgeDeclarationRegistry registry) {
    const value = BridgeTypeAnnotation(
      BridgeTypeRef(CoreTypes.object),
      nullable: true,
    );
    const revision = BridgeTypeAnnotation(BridgeTypeRef(CoreTypes.int));
    const message = BridgeTypeAnnotation(
      BridgeTypeRef(CoreTypes.string),
      nullable: true,
    );
    const noArgs = <BridgeParameter>[];
    for (final (name, returns, params) in [
      ('readSettingsFieldValue', value, noArgs),
      ('readSettingsFieldRevision', revision, noArgs),
      (
        'settingsFieldEditingEnabled',
        const BridgeTypeAnnotation(BridgeTypeRef(CoreTypes.bool)),
        noArgs,
      ),
      ('readSettingsFieldError', message, noArgs),
      (
        'proposeSettingsFieldValue',
        message,
        const [
          BridgeParameter('revision', revision, false),
          BridgeParameter('value', value, false),
        ],
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
  void configureForRuntime(Runtime runtime) => throw UnsupportedError(
    'Use a per-presentation SettingsFieldEditorBridge.',
  );
}

/// One mounted editor on one exact registration. Even a retained eval callback
/// loses the reference to its draft when the view unmounts or the owner retires.
final class SettingsFieldEditorBridge extends SettingsFieldEditorDeclarations
    implements PreparedFrontendBridge, PreparedFrontendFailureSource {
  SettingsFieldEditorBridge({
    required SettingsFieldDraft draft,
    required ExtensionBinding<SettingsFieldEditorContribution> binding,
    required bool Function() isActive,
  }) : _draft = draft,
       _isActive = isActive {
    _detach = binding.onRetire(invalidate);
  }

  SettingsFieldDraft? _draft;
  bool Function()? _isActive;
  VoidCallback? _detach;
  @override
  VoidCallback? onFailure;

  SettingsFieldDraft? get _liveDraft {
    if (_isActive?.call() == true) return _draft;
    invalidate();
    return null;
  }

  static $Value _message(String? text) => text == null
      ? const $null()
      : $String(text.length <= 256 ? text : _invalid);

  @override
  void configureForRuntime(Runtime runtime) {
    runtime
      ..registerBridgeFunc(_library, 'readSettingsFieldValue', (_, _, _) {
        return switch (_liveDraft?.value) {
          null => const $null(),
          final bool value => $bool(value),
          final int value => $int(value),
          final String value => $String(value),
          _ => throw StateError(_invalid),
        };
      })
      ..registerBridgeFunc(
        _library,
        'readSettingsFieldRevision',
        (_, _, _) => $int(_liveDraft?.revision ?? -1),
      )
      ..registerBridgeFunc(
        _library,
        'settingsFieldEditingEnabled',
        (_, _, _) => $bool(_liveDraft?.enabled ?? false),
      )
      ..registerBridgeFunc(_library, 'readSettingsFieldError', (_, _, _) {
        final draft = _liveDraft;
        return _message(draft == null ? _unavailable : draft.error);
      })
      ..registerBridgeFunc(_library, 'proposeSettingsFieldValue', (_, _, args) {
        final draft = _liveDraft;
        if (draft == null || !draft.enabled) return $String(_unavailable);
        if (args case [$int($value: final revision), final proposed]) {
          if (revision != draft.revision) {
            return $String('Field draft has changed.');
          }
          // Only unwrap known scalar boxes. In particular, a cyclic eval List
          // or Map must be rejected without even looking at its contents.
          final Object? scalar;
          switch (proposed) {
            case null || $null():
              scalar = null;
            case $bool():
              scalar = proposed.$value;
            case $int():
              scalar = proposed.$value;
            case $String():
              scalar = proposed.$value;
            default:
              return $String(_invalid);
          }
          try {
            return _message(draft.propose(revision, scalar));
          } on Object {
            return $String(_invalid);
          }
        }
        return $String(_invalid);
      });
  }

  @override
  void invalidate() {
    if (_draft == null) return;
    _draft = null;
    _isActive = null;
    _detach?.call();
    _detach = null;
    final notify = onFailure;
    onFailure = null;
    notify?.call();
  }
}
