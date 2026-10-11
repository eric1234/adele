import 'dart:async';

import 'package:adele_configuration_store/adele_configuration_store.dart';
import 'package:adele_settings/adele_settings.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/global_settings_service.dart';

/// Application-owned presentation; the shared host service owns all disk work.
final class GlobalSettingsDialog extends StatefulWidget {
  const GlobalSettingsDialog({
    super.key,
    required this.service,
    this.declarationIssues,
  });

  final Future<GlobalSettingsService> Function() service;
  final List<String> Function()? declarationIssues;

  @override
  State<GlobalSettingsDialog> createState() => _GlobalSettingsDialogState();
}

final class _GlobalSettingsDialogState extends State<GlobalSettingsDialog> {
  GlobalSettingsService? _service;
  GlobalSettingsView? _view;
  bool _busy = true;
  bool _requiresReload = false;
  String? _error;
  String _query = '';
  int _reloadGeneration = 0;

  @override
  void initState() {
    super.initState();
    unawaited(_reload());
  }

  Future<void> _reload() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final service = _service ??= await widget.service();
      final view = await service.load();
      if (!mounted) return;
      setState(() {
        _view = view;
        _requiresReload = false;
        _reloadGeneration++;
      });
    } on Object catch (error) {
      if (!mounted) return;
      setState(() {
        _view = null;
        _error =
            'Could not load settings. $error\n'
            'Correct the configuration file manually, then Reload. '
            'Changes to installed declarations require restarting ADELE.';
      });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _commit(SettingId id, Object? value) async {
    final expected = _view;
    if (_busy || _requiresReload || expected == null) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final saved = value == null
          ? await _service!.reset(expected, id)
          : await _service!.save(expected, id, value);
      if (mounted) setState(() => _view = saved);
    } on ConfigurationConflictException catch (error) {
      if (!mounted) return;
      setState(() {
        _requiresReload = true;
        _error =
            'Not saved: configuration changed on disk. '
            'Reload before editing again. No external changes were overwritten.\n'
            '$error';
      });
    } on Object catch (error) {
      if (!mounted) return;
      setState(() {
        _requiresReload = true;
        _error =
            'Could not confirm the save. Last loaded values remain shown. '
            'Reload to check persisted values before editing again.\n$error\n'
            'If the stored value has an unsupported TOML type, '
            'correct it manually and Reload.';
      });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final definitions = [...?_service?.catalog.definitions]
      ..sort((a, b) {
        final category = a.category.compareTo(b.category);
        if (category != 0) return category;
        final section = a.section.compareTo(b.section);
        if (section != 0) return section;
        final label = a.label.compareTo(b.label);
        return label != 0 ? label : a.id.value.compareTo(b.id.value);
      });
    String? category;
    String? section;
    var matches = 0;
    final rows = <Widget>[];
    if (_view case final view?) {
      for (final definition in definitions) {
        final visible = [
          definition.label,
          definition.category,
          definition.section,
          definition.description ?? '',
          definition.id.value,
        ].any((text) => text.toLowerCase().contains(_query));
        if (visible) matches++;
        if (visible && category != definition.category) {
          category = definition.category;
          section = null;
          rows.add(
            Padding(
              padding: const EdgeInsets.only(top: 16, bottom: 8),
              child: Text(category, style: theme.textTheme.titleLarge),
            ),
          );
        }
        if (visible && section != definition.section) {
          section = definition.section;
          rows.add(Text(section, style: theme.textTheme.titleMedium));
        }
        rows.add(
          // Filtering must not silently discard another setting's unsaved draft.
          Offstage(
            key: ValueKey('${definition.id}:$_reloadGeneration'),
            offstage: !visible,
            child: ExcludeFocus(
              excluding: !visible,
              child: _SettingEditor(
                definition: definition,
                resolved: view.values[definition.id],
                failure: view.failures[definition.id],
                enabled: visible && !_busy && !_requiresReload,
                onSave: (value) => _commit(definition.id, value),
                onReset: () => _commit(definition.id, null),
              ),
            ),
          ),
        );
      }
    }
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): () =>
            Navigator.of(context).pop(),
      },
      child: Dialog(
        insetPadding: const EdgeInsets.all(16),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 760, maxHeight: 760),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 12, 8, 0),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        'Global Settings',
                        style: theme.textTheme.titleLarge,
                      ),
                    ),
                    IconButton(
                      tooltip: 'Close Settings',
                      onPressed: () => Navigator.of(context).pop(),
                      icon: const Icon(Icons.close),
                    ),
                  ],
                ),
              ),
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 20, vertical: 8),
                child: Text('Restart ADELE to apply configuration changes.'),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: TextField(
                  key: const ValueKey('settings-search'),
                  decoration: const InputDecoration(
                    labelText: 'Search settings',
                    prefixIcon: Icon(Icons.search),
                  ),
                  onChanged: (value) =>
                      setState(() => _query = value.trim().toLowerCase()),
                ),
              ),
              if (_busy)
                const Padding(
                  padding: EdgeInsets.only(top: 8),
                  child: LinearProgressIndicator(
                    semanticsLabel: 'Settings operation pending',
                  ),
                ),
              Expanded(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      for (final issue
                          in widget.declarationIssues?.call() ?? <String>[])
                        _diagnostic(
                          context,
                          'Setting declarations unavailable: $issue\n'
                          'Correct the installation and restart ADELE.',
                        ),
                      if (_error case final error?) _diagnostic(context, error),
                      if (_view != null && matches == 0)
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 24),
                          child: Text(
                            _service!.catalog.definitions.isEmpty
                                ? 'No settings are available from installed plugins.'
                                : 'No settings match your search.',
                          ),
                        ),
                      ...rows,
                    ],
                  ),
                ),
              ),
              const Divider(height: 1),
              Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (_service case final service?)
                      SelectableText(
                        service.filePath,
                        style: theme.textTheme.bodySmall,
                      ),
                    Align(
                      alignment: Alignment.centerRight,
                      child: TextButton.icon(
                        key: const ValueKey('settings-reload'),
                        onPressed: _busy ? null : _reload,
                        icon: const Icon(Icons.refresh),
                        label: const Text('Reload'),
                      ),
                    ),
                    const Text(
                      'Reload discards unsaved edits and reads the current file.',
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

Widget _diagnostic(BuildContext context, String message) => Padding(
  padding: const EdgeInsets.symmetric(vertical: 8),
  child: Semantics(
    liveRegion: true,
    child: Text(
      message,
      style: TextStyle(color: Theme.of(context).colorScheme.error),
    ),
  ),
);

final class _SettingEditor extends StatefulWidget {
  const _SettingEditor({
    required this.definition,
    required this.resolved,
    required this.failure,
    required this.enabled,
    required this.onSave,
    required this.onReset,
  });

  final SettingDefinition<Object> definition;
  final ResolvedSetting<Object>? resolved;
  final Object? failure;
  final bool enabled;
  final ValueChanged<Object> onSave;
  final VoidCallback onReset;

  @override
  State<_SettingEditor> createState() => _SettingEditorState();
}

final class _SettingEditorState extends State<_SettingEditor> {
  final _text = TextEditingController();
  Object? _draft;
  String? _validation;

  @override
  void initState() {
    super.initState();
    _resetDraft();
  }

  @override
  void didUpdateWidget(_SettingEditor oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.resolved?.value != oldWidget.resolved?.value ||
        widget.resolved?.source != oldWidget.resolved?.source ||
        widget.failure.toString() != oldWidget.failure.toString()) {
      _resetDraft();
    }
  }

  void _resetDraft() {
    _draft = widget.resolved?.value;
    _text.text = _draft?.toString() ?? '';
    _validation = null;
  }

  void _edit(Object? value) {
    setState(() {
      _draft = value;
      try {
        widget.definition.validate(value);
        _validation = null;
      } on InvalidSettingValue catch (error) {
        _validation = error.message;
      }
    });
  }

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final definition = widget.definition;
    final resolved = widget.resolved;
    final inputKey = ValueKey('setting-input-${definition.id}');
    final changed = _draft != resolved?.value;
    return Card(
      key: ValueKey('setting-${definition.id}'),
      margin: const EdgeInsets.symmetric(vertical: 8),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              definition.label,
              style: Theme.of(context).textTheme.titleMedium,
            ),
            if (definition.description case final description?)
              Padding(
                padding: const EdgeInsets.only(top: 4, bottom: 8),
                child: Text(description),
              ),
            if (resolved != null) ...[
              Text(resolved.hasGlobalOverride ? 'Global' : 'Default'),
              Text('Effective value: ${resolved.value}'),
              const SizedBox(height: 8),
              switch (definition.type) {
                BooleanSettingType() => Align(
                  alignment: Alignment.centerLeft,
                  child: Semantics(
                    label: definition.label,
                    child: Switch(
                      key: inputKey,
                      value: _draft! as bool,
                      onChanged: widget.enabled ? _edit : null,
                    ),
                  ),
                ),
                IntegerSettingType() => TextField(
                  key: inputKey,
                  controller: _text,
                  enabled: widget.enabled,
                  keyboardType: const TextInputType.numberWithOptions(
                    signed: true,
                  ),
                  decoration: InputDecoration(
                    labelText: definition.label,
                    errorText: _validation,
                  ),
                  onChanged: (text) => _edit(int.tryParse(text, radix: 10)),
                ),
                StringSettingType() => TextField(
                  key: inputKey,
                  controller: _text,
                  enabled: widget.enabled,
                  minLines: 2,
                  maxLines: null,
                  keyboardType: TextInputType.multiline,
                  decoration: InputDecoration(
                    labelText: definition.label,
                    errorText: _validation,
                  ),
                  onChanged: _edit,
                ),
                EnumSettingType(:final options) => DropdownButton<String>(
                  key: inputKey,
                  isExpanded: true,
                  value: _draft! as String,
                  items: [
                    for (final option in options)
                      DropdownMenuItem(
                        value: option.value,
                        child: Text(option.label ?? option.value),
                      ),
                  ],
                  onChanged: widget.enabled ? _edit : null,
                ),
              },
              if (changed) const Text('Unsaved change'),
            ] else ...[
              const Text('Global override is invalid; no effective value.'),
              _diagnostic(context, '${widget.failure}'),
              const Text(
                'Reset a supported scalar override, or correct the TOML file manually.',
              ),
            ],
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                FilledButton(
                  key: ValueKey('setting-save-${definition.id}'),
                  onPressed:
                      widget.enabled &&
                          resolved != null &&
                          _draft != null &&
                          _validation == null &&
                          (changed || !resolved.hasGlobalOverride)
                      ? () => widget.onSave(definition.validate(_draft))
                      : null,
                  child: const Text('Save'),
                ),
                TextButton(
                  key: ValueKey('setting-reset-${definition.id}'),
                  onPressed:
                      widget.enabled &&
                          (resolved?.hasGlobalOverride == true ||
                              widget.failure != null)
                      ? widget.onReset
                      : null,
                  child: const Text('Reset'),
                ),
              ],
            ),
            if (resolved?.hasGlobalOverride == false)
              const Text(
                'Save creates a Global override, even when equal to the default.',
              ),
          ],
        ),
      ),
    );
  }
}
