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
    required this.text,
    required this.enabled,
    required this.onChanged,
    this.error,
    this.allowUnsetBoolean = false,
  });

  final Key inputKey;
  final SettingType<Object> type;
  final String label;
  final Object? value;
  final TextEditingController text;
  final bool enabled;
  final ValueChanged<Object?> onChanged;
  final String? error;
  final bool allowUnsetBoolean;

  @override
  Widget build(BuildContext context) => switch (type) {
    BooleanSettingType() when !allowUnsetBoolean => Align(
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
        items: const [
          DropdownMenuItem(value: false, child: Text('False')),
          DropdownMenuItem(value: true, child: Text('True')),
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
          for (final option in options)
            DropdownMenuItem(
              value: option.value,
              child: Text(option.label ?? option.value),
            ),
        ],
        onChanged: enabled ? onChanged : null,
      ),
    ),
  };
}
