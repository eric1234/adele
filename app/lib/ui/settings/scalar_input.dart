import 'package:adele_settings/adele_settings.dart';
import 'package:flutter/material.dart';

/// Presentation only: callers retain drafts and use their declaration validator.
final class ScalarInput extends StatelessWidget {
  const ScalarInput({
    super.key,
    required this.inputKey,
    required this.type,
    required this.label,
    required this.value,
    this.text,
    required this.enabled,
    required this.onChanged,
    this.error,
    this.booleanDropdown = false,
    this.choices,
    this.unsetLabel,
  });

  final Key inputKey;
  final SettingType<Object> type;
  final String label;
  final Object? value;
  final TextEditingController? text;
  final bool enabled;
  final ValueChanged<Object?> onChanged;
  final String? error;
  final bool booleanDropdown;
  final List<String>? choices;
  final String? unsetLabel;

  @override
  Widget build(BuildContext context) => switch (type) {
    BooleanSettingType() when !booleanDropdown => Align(
      alignment: Alignment.centerLeft,
      child: Semantics(
        label: label,
        child: Switch(
          key: inputKey,
          value: value! as bool,
          onChanged: enabled ? onChanged : null,
        ),
      ),
    ),
    BooleanSettingType() => InputDecorator(
      decoration: InputDecoration(labelText: label, errorText: error),
      child: DropdownButton<bool>(
        key: inputKey,
        isExpanded: true,
        value: value as bool?,
        hint: const Text('Choose a value'),
        items: [
          if (unsetLabel != null)
            DropdownMenuItem<bool>(child: Text(unsetLabel!)),
          const DropdownMenuItem(value: true, child: Text('True')),
          const DropdownMenuItem(value: false, child: Text('False')),
        ],
        onChanged: enabled ? onChanged : null,
      ),
    ),
    IntegerSettingType() => TextField(
      key: inputKey,
      controller: text,
      enabled: enabled,
      keyboardType: const TextInputType.numberWithOptions(signed: true),
      decoration: InputDecoration(labelText: label, errorText: error),
      onChanged: (value) => onChanged(int.tryParse(value, radix: 10)),
    ),
    StringSettingType() => TextField(
      key: inputKey,
      controller: text,
      enabled: enabled,
      minLines: 2,
      maxLines: null,
      keyboardType: TextInputType.multiline,
      decoration: InputDecoration(labelText: label, errorText: error),
      onChanged: onChanged,
    ),
    EnumSettingType(:final options) => InputDecorator(
      decoration: InputDecoration(labelText: label, errorText: error),
      child: DropdownButton<String>(
        key: inputKey,
        isExpanded: true,
        value: value as String?,
        hint: const Text('Choose a value'),
        items: [
          if (unsetLabel != null)
            DropdownMenuItem<String>(child: Text(unsetLabel!)),
          for (final option in options)
            if (choices == null || choices!.contains(option.value))
              DropdownMenuItem(
                value: option.value,
                child: Text(option.label ?? option.value),
              )
            else if (value == option.value)
              DropdownMenuItem(
                value: option.value,
                enabled: false,
                child: Text('${option.label ?? option.value} (unavailable)'),
              ),
        ],
        onChanged: enabled ? onChanged : null,
      ),
    ),
  };
}
