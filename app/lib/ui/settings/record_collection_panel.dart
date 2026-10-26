import 'dart:async';

import 'package:adele_configuration_store/adele_configuration_store.dart';
import 'package:adele_settings/adele_settings.dart';
import 'package:flutter/material.dart';

import '../../core/global_settings_service.dart';
import 'scalar_input.dart';

final class RecordCollectionPanel extends StatefulWidget {
  const RecordCollectionPanel({
    super.key,
    required this.service,
    required this.collection,
    this.declarationIssues,
  });

  final GlobalSettingsService service;
  final RecordCollectionId collection;
  final List<String> Function()? declarationIssues;

  @override
  State<RecordCollectionPanel> createState() => _RecordCollectionPanelState();
}

final class _RecordCollectionPanelState extends State<RecordCollectionPanel> {
  late final _types = widget.service.records.definitions
      .where((definition) => definition.collection == widget.collection)
      .toList();
  late RecordTypeId _type = _types.first.id;
  List<RecordView> _records = const [];
  List<RecordDiagnosticView> _diagnostics = const [];
  bool _loaded = false;
  bool _busy = false;
  bool _requiresReload = false;
  bool _adding = false;
  final _draftGenerations = <RecordTypeId, int>{};
  String? _error;
  String? _created;

  @override
  void initState() {
    super.initState();
    unawaited(_reload());
  }

  Future<void> _reload() async {
    if (!mounted || _busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final view = await widget.service.loadRecords(widget.collection);
      if (!mounted) return;
      setState(() {
        _records = view.records;
        _diagnostics = view.diagnostics;
        _loaded = true;
        _requiresReload = false;
      });
    } on Object catch (error) {
      if (!mounted) return;
      setState(() {
        _requiresReload = true;
        _error =
            'Could not load records. Last loaded records, if any, remain shown. '
            'Correct the collection files manually, then Reload.\n$error';
      });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _create(
    RecordTypeDefinition definition,
    ConfigurationRecordId id,
    Map<String, Object> values,
  ) async {
    if (!mounted ||
        _busy ||
        _requiresReload ||
        !_loaded ||
        !_adding ||
        definition.id != _type) {
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
      _created = null;
    });
    try {
      final saved = await widget.service.createRecord(
        definition.id,
        id,
        values,
      );
      if (!mounted) return;
      // A committed result is authoritative even when the following read fails.
      setState(() {
        _records = [
          for (final record in _records)
            if (record.id != saved.id) record,
          saved,
        ]..sort((a, b) => a.id.value.compareTo(b.id.value));
        _created = 'Created ${saved.id}.';
        _adding = false;
        _draftGenerations.update(
          definition.id,
          (value) => value + 1,
          ifAbsent: () => 1,
        );
      });
      try {
        final view = await widget.service.loadRecords(widget.collection);
        if (!mounted) return;
        setState(() {
          _records = view.records;
          _diagnostics = view.diagnostics;
        });
      } on Object catch (error) {
        if (!mounted) return;
        setState(() {
          _requiresReload = true;
          _error =
              'The record was created, but the collection could not be refreshed. '
              'The confirmed record remains shown. Reload the collection.\n$error';
        });
      }
    } on ConfigurationConflictException catch (error) {
      if (!mounted) return;
      setState(() {
        _requiresReload = true;
        _error =
            'Not created: the record ID is already occupied or changed on disk. '
            'No existing file was overwritten. Reload before creating again.\n$error';
      });
    } on Object catch (error) {
      if (!mounted) return;
      setState(() {
        _requiresReload = true;
        _error =
            'Could not confirm creation. Your draft is retained. '
            'Reload to check persisted records before creating again.\n$error';
      });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final collection = widget.collection;
    final enabled = _loaded && !_busy && !_requiresReload;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (_busy)
          const LinearProgressIndicator(
            semanticsLabel: 'Record operation pending',
          ),
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text(
                  'These records store nonsecret configuration, not credentials. '
                  'Creating a record does not activate or configure a running service.',
                ),
                for (final issue
                    in widget.declarationIssues?.call() ?? <String>[])
                  _diagnostic(
                    context,
                    'Record declarations unavailable: $issue\n'
                    'Correct the installation and restart ADELE.',
                  ),
                if (_error case final error?) _diagnostic(context, error),
                if (_created case final message?)
                  Semantics(liveRegion: true, child: Text(message)),
                Align(
                  alignment: Alignment.centerLeft,
                  child: FilledButton.icon(
                    key: ValueKey('records-add-$collection'),
                    onPressed: enabled && !_adding
                        ? () => setState(() => _adding = true)
                        : null,
                    icon: const Icon(Icons.add),
                    label: const Text('Add'),
                  ),
                ),
                Offstage(
                  key: ValueKey('record-creation-$collection'),
                  offstage: !_adding,
                  child: ExcludeFocus(
                    excluding: !_adding,
                    child: Card(
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Text(
                              'Add record',
                              style: Theme.of(context).textTheme.titleMedium,
                            ),
                            if (_types.length > 1)
                              DropdownButtonFormField<RecordTypeId>(
                                key: ValueKey('record-type-$collection'),
                                initialValue: _type,
                                isExpanded: true,
                                decoration: const InputDecoration(
                                  labelText: 'Record type',
                                ),
                                items: [
                                  for (final type in _types)
                                    DropdownMenuItem(
                                      value: type.id,
                                      child: Text(type.label),
                                    ),
                                ],
                                onChanged: enabled
                                    ? (value) {
                                        if (value != null) {
                                          setState(() => _type = value);
                                        }
                                      }
                                    : null,
                              ),
                            for (final type in _types)
                              Offstage(
                                key: ValueKey(
                                  '${type.id}:${_draftGenerations[type.id] ?? 0}',
                                ),
                                offstage: type.id != _type,
                                child: ExcludeFocus(
                                  excluding: type.id != _type,
                                  child: _RecordCreationForm(
                                    definition: type,
                                    enabled:
                                        enabled && _adding && type.id == _type,
                                    onCreate: (id, values) =>
                                        _create(type, id, values),
                                  ),
                                ),
                              ),
                            Align(
                              alignment: Alignment.centerLeft,
                              child: TextButton(
                                onPressed: _busy
                                    ? null
                                    : () => setState(() => _adding = false),
                                child: const Text('Back to records'),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
                if (_loaded && _records.isEmpty)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 16),
                    child: Text('No readable records in this collection.'),
                  ),
                for (final record in _records)
                  _RecordDetails(
                    record: record,
                    definition: widget.service.records.definition(record.type),
                  ),
                for (final diagnostic in _diagnostics)
                  _diagnostic(
                    context,
                    '${diagnostic.fileName}: ${diagnostic.message}',
                  ),
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
              SelectableText(
                widget.service.collectionPath(collection),
                style: Theme.of(context).textTheme.bodySmall,
              ),
              Align(
                alignment: Alignment.centerRight,
                child: TextButton.icon(
                  key: ValueKey('records-reload-$collection'),
                  onPressed: _busy ? null : _reload,
                  icon: const Icon(Icons.refresh),
                  label: const Text('Reload'),
                ),
              ),
              const Text(
                'Reload reads current records and keeps your creation draft.',
              ),
            ],
          ),
        ),
      ],
    );
  }
}

final class _RecordCreationForm extends StatefulWidget {
  const _RecordCreationForm({
    required this.definition,
    required this.enabled,
    required this.onCreate,
  });

  final RecordTypeDefinition definition;
  final bool enabled;
  final void Function(ConfigurationRecordId, Map<String, Object>) onCreate;

  @override
  State<_RecordCreationForm> createState() => _RecordCreationFormState();
}

final class _RecordCreationFormState extends State<_RecordCreationForm> {
  final _id = TextEditingController();
  final _present = <RecordFieldId>{};
  final _values = <RecordFieldId, Object?>{};
  late final _text = {
    for (final field in widget.definition.fields)
      field.id: TextEditingController(),
  };

  @override
  void dispose() {
    _id.dispose();
    for (final text in _text.values) {
      text.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final definition = widget.definition;
    final collection = definition.collection;
    ConfigurationRecordId? id;
    Map<String, Object>? validated;
    String? idError;
    InvalidRecordValue? fieldError;
    try {
      id = ConfigurationRecordId(_id.text);
      validated = definition.validate(id, {
        for (final field in definition.fields)
          if (_present.contains(field.id)) field.id.value: _values[field.id],
      });
    } on FormatException catch (error) {
      if (_id.text.isNotEmpty) idError = error.message;
    } on InvalidRecordValue catch (error) {
      fieldError = error;
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(definition.label),
        if (definition.description case final description?) Text(description),
        TextField(
          key: ValueKey('record-id-$collection'),
          controller: _id,
          enabled: widget.enabled,
          decoration: InputDecoration(
            labelText: 'Record ID',
            helperText:
                'Stable identity within this collection, not a display name.',
            helperMaxLines: 3,
            errorText: idError,
          ),
          onChanged: (_) => setState(() {}),
        ),
        const Padding(
          padding: EdgeInsets.symmetric(vertical: 8),
          child: Text(
            'Include each value explicitly. Required fields must be included; '
            'false, zero and empty strings are values, not absence.',
          ),
        ),
        for (final field in definition.fields) ...[
          CheckboxListTile(
            key: ValueKey('record-presence-$collection-${field.id}'),
            contentPadding: EdgeInsets.zero,
            controlAffinity: ListTileControlAffinity.leading,
            title: Text(
              'Include ${field.label} (${field.required ? 'required' : 'optional'})',
            ),
            subtitle: field.description == null
                ? null
                : Text(field.description!),
            value: _present.contains(field.id),
            onChanged: widget.enabled
                ? (present) {
                    setState(() {
                      if (present == true) {
                        _present.add(field.id);
                        if (field.type is StringSettingType) {
                          _values[field.id] = _text[field.id]!.text;
                        } else if (field.type is IntegerSettingType) {
                          _values[field.id] = int.tryParse(
                            _text[field.id]!.text,
                            radix: 10,
                          );
                        }
                      } else {
                        _present.remove(field.id);
                      }
                    });
                  }
                : null,
          ),
          ScalarInput(
            inputKey: ValueKey('record-input-$collection-${field.id}'),
            type: field.type,
            label: field.label,
            value: _values[field.id],
            text: _text[field.id]!,
            enabled: widget.enabled && _present.contains(field.id),
            allowUnsetBoolean: true,
            error: fieldError?.fieldId == field.id ? fieldError!.message : null,
            onChanged: (value) => setState(() => _values[field.id] = value),
          ),
          const SizedBox(height: 8),
        ],
        Align(
          alignment: Alignment.centerLeft,
          child: FilledButton(
            key: ValueKey('record-create-$collection'),
            onPressed: widget.enabled && validated != null
                ? () => widget.onCreate(id!, validated!)
                : null,
            child: const Text('Create'),
          ),
        ),
      ],
    );
  }
}

final class _RecordDetails extends StatelessWidget {
  const _RecordDetails({required this.record, required this.definition});

  final RecordView record;
  final RecordTypeDefinition definition;

  @override
  Widget build(BuildContext context) {
    final display = record.values[definition.displayField?.value];
    final title = display is String && display.trim().isNotEmpty
        ? display
        : record.id.value;
    return Card(
      key: ValueKey('record-${definition.collection}-${record.id}'),
      child: ExpansionTile(
        title: Text(title),
        subtitle: Text('${definition.label} | ${record.id}'),
        childrenPadding: const EdgeInsets.all(16),
        expandedCrossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SelectableText('Record ID: ${record.id}'),
          SelectableText('Record type: ${record.type}'),
          for (final field in definition.fields)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: SelectableText(
                '${field.label}: ${record.values.containsKey(field.id.value) ? (record.values[field.id.value] == '' ? '(empty string)' : record.values[field.id.value]) : 'Not provided'}',
              ),
            ),
        ],
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
