import 'package:adele_plugin_api/adele_plugin_api.dart';
import 'package:flutter/widgets.dart';

/// Editors are selected by an installed record field, not by discovery order.
final settingsFieldEditorContributions =
    ExtensionPoint<SettingsFieldEditorContribution>(
      'dev.adele.ui.settings-field-editor',
    );

final class SettingsFieldEditorContribution {
  const SettingsFieldEditorContribution({required this.createPresentation});

  final Widget Function(SettingsFieldDraft draft) createPresentation;
}

/// A host-owned field in one form draft, not a record or a persistence API.
abstract interface class SettingsFieldDraft {
  /// The scalar or immutable flat `Map<String, Object>` in this field, or null
  /// if no value is set. Structured values have only their declared properties.
  Object? get value;
  int get revision;
  bool get enabled;
  String? get error;

  /// Replaces the entire field against the revision observed by the editor.
  /// Returns null on acceptance, or a user-facing rejection without changing
  /// the value or revision. A structured proposal supplies all its properties;
  /// the host validates and snapshots them, never retaining caller-owned data.
  /// Optional [context] is a transient list of at most 32 strings of at most
  /// 128 code units each. It accompanies this accepted field revision only;
  /// omitting it replaces any previous context. It is not a stored value.
  String? propose(int revision, Object? value, {List<String>? context});

  static const maxContextItems = 32;
  static const maxContextItemLength = 128;
}
