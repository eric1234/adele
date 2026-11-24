import 'package:adele_settings/adele_settings.dart';
import 'package:adele_ui/adele_ui.dart';
import 'package:dart_eval/stdlib/core.dart';
import 'package:plugin_runtime/plugin_runtime.dart';

import 'prepared_frontend.dart';
import 'structured_bridge_data.dart';

SettingsFormPresentation evaluateSettingsFormBehavior(
  PreparedFrontend generation,
  PreparedSettingsFormBehaviorExtension descriptor,
  Map<String, Object?> values,
  Map<String, List<String>> contexts,
  String? changedField,
) => generation.evaluateData(
  library: descriptor.library,
  entrypoint: descriptor.entrypoint,
  arguments: [
    wrapStructuredBridgeData(values),
    wrapStructuredBridgeData(contexts),
    wrapStructuredBridgeData(changedField),
  ],
  decodeResult: _decode,
);

const _invalid = FormatException('Invalid settings form presentation.');

/// Only descend into known, bounded containers. In particular, never ask an
/// arbitrary eval object to reify itself or recursively visit unexpected data.
SettingsFormPresentation _decode(Object? result) {
  final form = _map(result, 2, const {'fields', 'clear'});
  final fields = <String, SettingsFieldPresentation>{};
  for (final entry in _map(
    form['fields'],
    PreparedRecordsSchema.maxFields,
  ).entries) {
    final field = RecordFieldId(entry.key).value;
    final props = _map(entry.value, 3, const {
      'enabled',
      'choices',
      'guidance',
    });
    final enabled = switch (props['enabled']) {
      $bool(:final $value) => $value,
      final bool value => value,
      null when !props.containsKey('enabled') => true,
      _ => throw _invalid,
    };
    List<String>? choices;
    if (props.containsKey('choices')) {
      final raw = props['choices'];
      final items = raw is $List ? raw.$value : raw;
      if (items is! List<Object?> ||
          items.length > PreparedRecordsSchema.maxEnumOptions) {
        throw _invalid;
      }
      choices = [
        for (final item in items)
          _text(item, PreparedRecordsSchema.maxLabelLength),
      ];
      if (choices.toSet().length != choices.length) throw _invalid;
    }
    fields[field] = SettingsFieldPresentation(
      enabled: enabled,
      choices: choices,
      guidance: props.containsKey('guidance')
          ? _text(props['guidance'], PreparedRecordsSchema.maxDescriptionLength)
          : null,
    );
  }
  return SettingsFormPresentation(
    fields: fields,
    clear: form.containsKey('clear')
        ? RecordFieldId(_text(form['clear'], 64)).value
        : null,
  );
}

Map<String, Object?> _map(Object? value, int max, [Set<String>? keys]) {
  final raw = value is $Map ? value.$value : value;
  if (raw is! Map<Object?, Object?> || raw.length > max) throw _invalid;
  final copy = <String, Object?>{};
  for (final entry in raw.entries) {
    final key = _text(entry.key, 64);
    if ((keys != null && !keys.contains(key)) || copy.containsKey(key)) {
      throw _invalid;
    }
    copy[key] = entry.value;
  }
  return copy;
}

String _text(Object? value, int max) {
  final text = value is $String ? value.$value : value;
  if (text is! String || text.length > max) throw _invalid;
  return text;
}
