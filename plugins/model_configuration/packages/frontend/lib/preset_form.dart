/// Settings supplies only this draft's ordinary values and transient context.
/// The catalog observation is advisory; it is not a requirement for saving.
Map<String, Object> configurePresetForm(
  Map<String, Object?> values,
  Map<String, List<String>> contexts,
  String? changedField,
) {
  const effort = 'reasoning-effort';
  final field = <String, Object>{'enabled': true};
  final result = <String, Object>{
    'fields': <String, Object>{effort: field},
  };
  final choices = contexts['model'];
  final requested = values[effort];
  if (values['model'] == null) {
    field['enabled'] = false;
    field['choices'] = <String>[];
    field['guidance'] = 'Select a model before choosing a reasoning effort.';
  } else if (choices == null) {
    // Manual references and saved pairs without a fresh observation stay usable.
    field['guidance'] =
        'Effort support is unknown. Explicit choices are unverified.';
  } else {
    field['choices'] = choices;
    final status = choices.isEmpty
        ? 'This model reports no configurable explicit reasoning efforts.'
        : 'Explicit choices are the efforts reported by this model.';
    if (requested != null && !choices.contains(requested)) {
      if (changedField == 'model') {
        result['clear'] = effort;
        field['guidance'] =
            'The new model does not report support for the previous effort ($requested). Reset to Provider default. $status';
      } else {
        field['guidance'] =
            'The current effort ($requested) is not reported as supported. It is retained unless you choose another option. $status';
      }
    } else {
      field['guidance'] = status;
    }
  }
  return result;
}
