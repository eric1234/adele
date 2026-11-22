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
  Object? get value;
  int get revision;
  bool get enabled;
  String? get error;

  /// Proposes a scalar against the revision observed by the editor. Returns
  /// null on acceptance, or a user-facing rejection without changing the value.
  String? propose(int revision, Object? value);
}
