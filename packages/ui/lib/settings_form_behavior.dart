import 'package:adele_plugin_api/adele_plugin_api.dart';

/// Selected by an exact record declaration and its live owning registration.
final settingsFormBehaviorContributions =
    ExtensionPoint<SettingsFormBehaviorContribution>(
      'dev.adele.ui.settings-form-behavior',
    );

/// Compile-time signature of an interpreted `settingsFormBehavior` entrypoint.
/// Return a map with `fields` and optional `clear`. Values in `fields` are maps
/// with optional `enabled` (bool), `choices` (list of strings) and `guidance`
/// (string). `clear` names one optional enum field. Omit absent keys, not nulls.
typedef SettingsFormBehaviorEntrypoint =
    Map<String, Object?> Function(
      Map<String, Object?> values,
      Map<String, List<String>> contexts,
      String? changedField,
    );

final class SettingsFormBehaviorContribution {
  const SettingsFormBehaviorContribution({required this.evaluate});

  /// Read-only draft values and transient string lists keyed by field ID.
  /// `changedField` is null on presentation or re-evaluation without user input.
  /// Evaluation must be synchronous, with no persistence or host operations.
  final SettingsFormPresentation Function(
    Map<String, Object?> values,
    Map<String, List<String>> contexts,
    String? changedField,
  )
  evaluate;
}

final class SettingsFormPresentation {
  SettingsFormPresentation({
    required Map<String, SettingsFieldPresentation> fields,
    this.clear,
  }) : fields = Map.unmodifiable(fields);

  /// Overrides only. Omitted fields retain their schema presentation.
  final Map<String, SettingsFieldPresentation> fields;

  /// Requests unsetting one optional enum in the draft on an actual user change.
  /// Hosts must validate the entire result against the schema before using it.
  final String? clear;
}

final class SettingsFieldPresentation {
  SettingsFieldPresentation({
    this.enabled = true,
    List<String>? choices,
    this.guidance,
  }) : choices = choices == null ? null : List.unmodifiable(choices);

  final bool enabled;

  /// Optional restriction to declared enum values. Null means unrestricted.
  final List<String>? choices;
  final String? guidance;
}
