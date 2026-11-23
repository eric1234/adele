import 'package:adele_plugin_api/adele_plugin_api.dart';
import 'package:adele_settings/adele_settings.dart';
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

  static $Value _boxScalar(Object? value) => switch (value) {
    null => const $null(),
    bool() => $bool(value),
    int() => $int(value),
    String() => $String(value),
    _ => throw StateError(_invalid),
  };

  // Do not use recursive $reified: even a self-referential eval collection is
  // just an invalid leaf. Bound work before copying or examining property keys.
  static Object? _proposal($Value? value) {
    Object? scalar(Object? box) => switch (box) {
      null || $null() => null,
      $bool() => box.$value,
      $int() => box.$value,
      $String() => box.$value,
      _ => throw const FormatException(_invalid),
    };

    if (value is! $Map) return scalar(value);
    final entries = value.$value;
    if (entries.isEmpty ||
        entries.length > StructuredRecordFieldType.maxProperties) {
      throw const FormatException(_invalid);
    }
    final copy = <String, Object>{};
    for (final entry in entries.entries) {
      final key = scalar(entry.key);
      final child = scalar(entry.value);
      if (key is! String ||
          key.length > 64 ||
          child == null ||
          (child is String &&
              child.length > StructuredRecordFieldType.maxStringLength)) {
        throw const FormatException(_invalid);
      }
      // RecordFieldId enforces the shared local-key grammar. The actual field
      // declaration then checks its exact keys, types, and per-property bounds.
      copy[RecordFieldId(key).value] = child;
    }
    return Map<String, Object>.unmodifiable(copy);
  }

  @override
  void configureForRuntime(Runtime runtime) {
    runtime
      ..registerBridgeFunc(_library, 'readSettingsFieldValue', (_, _, _) {
        final value = _liveDraft?.value;
        if (value is Map<String, Object>) {
          return $Map.wrap(
            Map<$Value, $Value>.unmodifiable({
              for (final entry in value.entries)
                $String(entry.key): _boxScalar(entry.value),
            }),
          );
        }
        return _boxScalar(value);
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
          try {
            return _message(draft.propose(revision, _proposal(proposed)));
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
