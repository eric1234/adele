import 'dart:async';

import 'package:adele_configuration_store/adele_configuration_store.dart';
import 'package:adele_settings/adele_settings.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

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
  late final _creationDrafts = {
    for (final type in _types) type.id: _RecordDraft(type),
  };
  // Collection identity belongs to this panel; drafts outlive collapsed tiles.
  final _drafts = <ConfigurationRecordId, _RecordDraft>{};
  final _recordErrors = <ConfigurationRecordId, String>{};
  final _fencedRecords = <ConfigurationRecordId>{};
  List<RecordView> _records = const [];
  List<RecordDiagnosticView> _diagnostics = const [];
  bool _loaded = false;
  bool _busy = false;
  bool _confirming = false;
  bool _requiresReload = false;
  bool _creationRequiresReload = false;
  bool _adding = false;
  String? _error;
  String? _creationError;
  String? _message;

  @override
  void initState() {
    super.initState();
    unawaited(_reload());
  }

  @override
  void dispose() {
    for (final draft in [..._drafts.values, ..._creationDrafts.values]) {
      draft.dispose();
    }
    super.dispose();
  }

  bool get _enabled => mounted && _loaded && !_busy && !_requiresReload;

  bool _current(RecordView record) =>
      _records.any((candidate) => identical(candidate, record));

  Future<void> _reload() async {
    if (!mounted || _busy) return;
    // Admission covers the confirmation as well as the eventual read.
    setState(() {
      _busy = true;
      _confirming = _drafts.values.any((draft) => draft.dirty);
    });
    try {
      if (_confirming) {
        final confirmed = await _confirm(
          context,
          title: 'Reload ${widget.collection}?',
          message:
              'A successful Reload discards unsaved edits to existing records in '
              'this collection. Creation drafts and other settings are kept. '
              'If the read fails, your drafts remain available.',
          confirmLabel: 'Discard edits and Reload',
          confirmKey: 'records-reload-confirm-${widget.collection}',
          cancelKey: 'records-reload-cancel-${widget.collection}',
        );
        if (!mounted || !confirmed) return;
      }
      setState(() {
        _confirming = false;
        _error = null;
      });
      final view = await widget.service.loadRecords(widget.collection);
      if (!mounted) return;
      setState(() {
        for (final draft in _drafts.values) {
          draft.dispose();
        }
        _drafts.clear();
        _recordErrors.clear();
        _fencedRecords.clear();
        _records = view.records;
        _diagnostics = view.diagnostics;
        _loaded = true;
        _requiresReload = false;
        _creationRequiresReload = false;
        _creationError = null;
        _message = null;
      });
    } on Object catch (error) {
      if (!mounted) return;
      setState(() {
        _requiresReload = true;
        _error =
            'Could not load records. Last loaded records and drafts remain shown. '
            'Correct the collection files manually, then Reload.\n$error';
      });
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _confirming = false;
        });
      }
    }
  }

  Future<void> _create(
    _RecordDraft draft,
    ConfigurationRecordId id,
    Map<String, Object> values,
  ) async {
    final definition = draft.definition;
    if (!_enabled ||
        _creationRequiresReload ||
        !_adding ||
        definition.id != _type ||
        !identical(_creationDrafts[definition.id], draft)) {
      return;
    }
    // Do not replace a displayed identity (and its draft) through Create even
    // when an external deletion has made the file available again.
    if (_records.any((record) => record.id == id)) {
      setState(() {
        _creationRequiresReload = true;
        _creationError =
            'Not created: this record ID is already in the loaded collection. '
            'Reload to reconcile current records before creating again. '
            'Your drafts are retained; no write was attempted.';
      });
      return;
    }
    setState(() {
      _busy = true;
      _creationError = null;
      _message = null;
    });
    try {
      final saved = await widget.service.createRecord(
        definition.id,
        id,
        values,
      );
      if (!mounted) return;
      setState(() {
        // The returned handle is usable; a collection read would revoke siblings.
        _records = [..._records, saved]
          ..sort((a, b) => a.id.value.compareTo(b.id.value));
        _message = 'Created ${saved.id}.';
        _adding = false;
        _creationDrafts[definition.id] = _RecordDraft(definition);
        draft.dispose();
      });
    } on ConfigurationConflictException catch (error) {
      if (!mounted) return;
      setState(() {
        _creationRequiresReload = true;
        _creationError =
            'Not created: the record ID is already occupied or changed on disk. '
            'No existing file was overwritten. Reload before creating again.\n$error';
      });
    } on InvalidRecordValue catch (error) {
      if (mounted) {
        setState(
          () => _creationError = 'Not created: correct the values.\n$error',
        );
      }
    } on Object catch (error) {
      if (!mounted) return;
      setState(() {
        _creationRequiresReload = true;
        _creationError =
            'Could not confirm creation. Your draft is retained. '
            'Reload to check persisted records before creating again.\n$error';
      });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _edit(RecordView record) {
    if (!_enabled ||
        !_current(record) ||
        _fencedRecords.contains(record.id) ||
        _drafts.containsKey(record.id)) {
      return;
    }
    setState(() {
      _drafts[record.id] = _RecordDraft(
        widget.service.records.definition(record.type),
        record: record,
      );
    });
  }

  void _cancel(RecordView record, _RecordDraft draft) {
    if (!mounted ||
        _busy ||
        !_current(record) ||
        !identical(_drafts[record.id], draft)) {
      return;
    }
    setState(() {
      _drafts.remove(record.id);
      draft.dispose();
      if (!_fencedRecords.contains(record.id)) _recordErrors.remove(record.id);
    });
  }

  Future<void> _mutate(
    RecordView record, {
    _RecordDraft? draft,
    Map<String, Object>? values,
  }) async {
    if (!_enabled ||
        !_current(record) ||
        _fencedRecords.contains(record.id) ||
        (draft != null && !identical(_drafts[record.id], draft))) {
      return;
    }
    final deleting = draft == null;
    setState(() {
      _busy = true;
      _confirming = deleting;
    });
    try {
      if (deleting) {
        final definition = widget.service.records.definition(record.type);
        final confirmed = await _confirm(
          context,
          title: 'Delete record?',
          message:
              'Title: ${_recordTitle(record, definition)}\n'
              'Record ID: ${record.id}\n'
              'Record type: ${record.type}\n'
              'Collection: ${record.collection}\n\n'
              'This deletes the entire record file, including unknown data and '
              'any unsaved edits to this record. This cannot be undone.',
          confirmLabel: 'Delete',
          confirmKey: 'record-delete-confirm-${record.collection}-${record.id}',
          cancelKey: 'record-delete-cancel-${record.collection}-${record.id}',
        );
        if (!mounted || !confirmed) return;
      }
      setState(() {
        _confirming = false;
        _recordErrors.remove(record.id);
        _message = null;
      });
      final RecordView? saved;
      if (deleting) {
        await widget.service.deleteRecord(record);
        saved = null;
      } else {
        saved = await widget.service.updateRecord(record, values!);
      }
      if (!mounted) return;
      setState(() {
        _records = [
          for (final current in _records)
            if (identical(current, record)) ?saved else current,
        ];
        _drafts.remove(record.id)?.dispose();
        _message = '${deleting ? 'Deleted' : 'Saved'} ${record.id}.';
      });
    } on ConfigurationConflictException catch (error) {
      if (!mounted) return;
      setState(() {
        _fencedRecords.add(record.id);
        _recordErrors[record.id] =
            'Not ${deleting ? 'deleted' : 'saved'}: this record changed on disk. '
            'Your draft is retained. Reload before changing this record again.\n$error';
      });
    } on InvalidRecordValue catch (error) {
      if (mounted) {
        setState(() {
          _recordErrors[record.id] = 'Not saved: correct the values.\n$error';
        });
      }
    } on Object catch (error) {
      if (!mounted) return;
      setState(() {
        _fencedRecords.add(record.id);
        _recordErrors[record.id] =
            'Could not confirm ${deleting ? 'deletion' : 'save'}. '
            'The operation may have been published. Your draft is retained. '
            'Reload to check persisted state before changing this record again.\n$error';
      });
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _confirming = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final collection = widget.collection;
    final creationEnabled = _enabled && !_creationRequiresReload;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (_busy && !_confirming)
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
                  'Changing a record does not activate or configure a running service.',
                ),
                for (final issue
                    in widget.declarationIssues?.call() ?? <String>[])
                  _diagnostic(
                    context,
                    'Record declarations unavailable: $issue\n'
                    'Correct the installation and restart ADELE.',
                  ),
                if (_error case final error?) _diagnostic(context, error),
                if (_creationError case final error?)
                  _diagnostic(context, error),
                if (_message case final message?)
                  Semantics(liveRegion: true, child: Text(message)),
                Align(
                  alignment: Alignment.centerLeft,
                  child: FilledButton.icon(
                    key: ValueKey('records-add-$collection'),
                    onPressed: creationEnabled && !_adding
                        ? () {
                            if (_enabled && !_creationRequiresReload) {
                              setState(() => _adding = true);
                            }
                          }
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
                                onChanged: creationEnabled
                                    ? (value) {
                                        if (_enabled && value != null) {
                                          setState(() => _type = value);
                                        }
                                      }
                                    : null,
                              ),
                            for (final type in _types)
                              Offstage(
                                key: ObjectKey(_creationDrafts[type.id]),
                                offstage: type.id != _type,
                                child: ExcludeFocus(
                                  excluding: type.id != _type,
                                  child: _creationForm(type, creationEnabled),
                                ),
                              ),
                            Align(
                              alignment: Alignment.centerLeft,
                              child: TextButton(
                                onPressed: _busy
                                    ? null
                                    : () {
                                        if (mounted && !_busy) {
                                          setState(() => _adding = false);
                                        }
                                      },
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
                for (final record in _records) _details(record),
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
                'Reload reads current records, discards existing-record edits '
                'after confirmation, and keeps creation drafts.',
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _creationForm(RecordTypeDefinition type, bool enabled) {
    final draft = _creationDrafts[type.id]!;
    return _RecordForm(
      draft: draft,
      enabled: enabled && _adding && type.id == _type,
      onChanged: () => setState(() {}),
      onSubmit: (id, values) => _create(draft, id, values),
    );
  }

  Widget _details(RecordView record) {
    final draft = _drafts[record.id];
    final enabled = _enabled && !_fencedRecords.contains(record.id);
    return _RecordDetails(
      key: ValueKey('record-${record.collection}-${record.id}'),
      record: record,
      definition: widget.service.records.definition(record.type),
      error: _recordErrors[record.id],
      onEdit: enabled ? () => _edit(record) : null,
      onDelete: enabled ? () => _mutate(record) : null,
      editor: draft == null
          ? null
          : _RecordForm(
              key: ObjectKey(draft),
              draft: draft,
              enabled: enabled,
              onChanged: () => setState(() {}),
              onSubmit: (_, values) =>
                  _mutate(record, draft: draft, values: values),
              onCancel: _busy ? null : () => _cancel(record, draft),
            ),
    );
  }
}

final class _RecordDraft {
  _RecordDraft(this.definition, {this.record}) {
    for (final field in definition.fields) {
      final value = record?.values[field.id.value];
      if (record?.values.containsKey(field.id.value) ?? false) {
        present.add(field.id);
        values[field.id] = value;
      }
      text[field.id] = TextEditingController(text: value?.toString() ?? '');
    }
  }

  final RecordTypeDefinition definition;
  final RecordView? record;
  final id = TextEditingController();
  final present = <RecordFieldId>{};
  final values = <RecordFieldId, Object?>{};
  final text = <RecordFieldId, TextEditingController>{};
  bool disposed = false;

  bool get dirty => definition.fields.any((field) {
    final before = record!.values;
    if (present.contains(field.id) != before.containsKey(field.id.value)) {
      return true;
    }
    final value = before[field.id.value];
    // Invalid or temporarily excluded text is still a draft worth retaining.
    if (field.type is StringSettingType || field.type is IntegerSettingType) {
      return text[field.id]!.text != (value?.toString() ?? '');
    }
    return values[field.id] != value;
  });

  Map<String, Object> validate(ConfigurationRecordId recordId) =>
      definition.validate(recordId, {
        for (final field in definition.fields)
          if (present.contains(field.id)) field.id.value: values[field.id],
      });

  void dispose() {
    disposed = true;
    id.dispose();
    for (final controller in text.values) {
      controller.dispose();
    }
  }
}

final class _RecordForm extends StatelessWidget {
  const _RecordForm({
    super.key,
    required this.draft,
    required this.enabled,
    required this.onChanged,
    required this.onSubmit,
    this.onCancel,
  });

  final _RecordDraft draft;
  final bool enabled;
  final VoidCallback onChanged;
  final void Function(ConfigurationRecordId, Map<String, Object>) onSubmit;
  final VoidCallback? onCancel;

  @override
  Widget build(BuildContext context) {
    final definition = draft.definition;
    final record = draft.record;
    final suffix =
        '${definition.collection}${record == null ? '' : '-${record.id}'}';
    ConfigurationRecordId? id;
    Map<String, Object>? validated;
    String? idError;
    InvalidRecordValue? fieldError;
    try {
      id = record?.id ?? ConfigurationRecordId(draft.id.text);
      validated = draft.validate(id);
    } on FormatException catch (error) {
      if (draft.id.text.isNotEmpty) idError = error.message;
    } on InvalidRecordValue catch (error) {
      fieldError = error;
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(definition.label),
        if (definition.description case final description?) Text(description),
        if (record == null)
          TextField(
            key: ValueKey('record-id-$suffix'),
            controller: draft.id,
            enabled: enabled,
            decoration: InputDecoration(
              labelText: 'Record ID',
              helperText:
                  'Stable identity within this collection, not a display name.',
              helperMaxLines: 3,
              errorText: idError,
            ),
            onChanged: (_) => onChanged(),
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
            key: ValueKey('record-presence-$suffix-${field.id}'),
            contentPadding: EdgeInsets.zero,
            controlAffinity: ListTileControlAffinity.leading,
            title: Text(
              'Include ${field.label} (${field.required ? 'required' : 'optional'})',
            ),
            subtitle: field.description == null
                ? null
                : Text(field.description!),
            value: draft.present.contains(field.id),
            onChanged: enabled
                ? (present) {
                    if (draft.disposed) return;
                    if (present == true) {
                      draft.present.add(field.id);
                      if (field.type is StringSettingType) {
                        draft.values[field.id] = draft.text[field.id]!.text;
                      } else if (field.type is IntegerSettingType) {
                        draft.values[field.id] = int.tryParse(
                          draft.text[field.id]!.text,
                          radix: 10,
                        );
                      }
                    } else {
                      draft.present.remove(field.id);
                    }
                    onChanged();
                  }
                : null,
          ),
          ScalarInput(
            inputKey: ValueKey('record-input-$suffix-${field.id}'),
            type: field.type,
            label: field.label,
            value: draft.values[field.id],
            text: draft.text[field.id]!,
            enabled: enabled && draft.present.contains(field.id),
            allowUnsetBoolean: true,
            error: fieldError?.fieldId == field.id ? fieldError!.message : null,
            onChanged: (value) {
              if (draft.disposed) return;
              draft.values[field.id] = value;
              onChanged();
            },
          ),
          const SizedBox(height: 8),
        ],
        Wrap(
          spacing: 8,
          children: [
            FilledButton(
              key: ValueKey(
                'record-${record == null ? 'create' : 'save'}-$suffix',
              ),
              onPressed: enabled && validated != null
                  ? () {
                      if (draft.disposed) return;
                      // Revalidate current controls rather than stale build values.
                      try {
                        final currentId =
                            record?.id ?? ConfigurationRecordId(draft.id.text);
                        onSubmit(currentId, draft.validate(currentId));
                      } on FormatException catch (_) {
                        onChanged();
                      } on InvalidRecordValue catch (_) {
                        onChanged();
                      }
                    }
                  : null,
              child: Text(record == null ? 'Create' : 'Save'),
            ),
            if (record != null)
              TextButton(
                key: ValueKey('record-cancel-$suffix'),
                onPressed: onCancel,
                child: const Text('Cancel'),
              ),
          ],
        ),
      ],
    );
  }
}

final class _RecordDetails extends StatefulWidget {
  const _RecordDetails({
    super.key,
    required this.record,
    required this.definition,
    required this.onEdit,
    required this.onDelete,
    this.editor,
    this.error,
  });

  final RecordView record;
  final RecordTypeDefinition definition;
  final VoidCallback? onEdit;
  final VoidCallback? onDelete;
  final Widget? editor;
  final String? error;

  @override
  State<_RecordDetails> createState() => _RecordDetailsState();
}

final class _RecordDetailsState extends State<_RecordDetails> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final record = widget.record;
    final definition = widget.definition;
    return Card(
      child: ExpansionTile(
        maintainState: true,
        onExpansionChanged: (expanded) => setState(() => _expanded = expanded),
        title: Text(_recordTitle(record, definition)),
        subtitle: Text('${definition.label} | ${record.id}'),
        childrenPadding: const EdgeInsets.all(16),
        expandedCrossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ExcludeFocus(
            excluding: !_expanded,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SelectableText('Collection: ${record.collection}'),
                SelectableText('Record ID: ${record.id}'),
                SelectableText('Record type: ${record.type}'),
                if (widget.error case final error?) _diagnostic(context, error),
                if (widget.editor case final editor?)
                  editor
                else ...[
                  for (final field in definition.fields)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: SelectableText(
                        '${field.label}: ${record.values.containsKey(field.id.value) ? (record.values[field.id.value] == '' ? '(empty string)' : record.values[field.id.value]) : 'Not provided'}',
                      ),
                    ),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton(
                      key: ValueKey(
                        'record-edit-${record.collection}-${record.id}',
                      ),
                      onPressed: widget.onEdit,
                      child: const Text('Edit'),
                    ),
                  ),
                ],
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton(
                    key: ValueKey(
                      'record-delete-${record.collection}-${record.id}',
                    ),
                    onPressed: widget.onDelete,
                    child: const Text('Delete'),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

String _recordTitle(RecordView record, RecordTypeDefinition definition) {
  final display = record.values[definition.displayField?.value];
  return display is String && display.trim().isNotEmpty
      ? display
      : record.id.value;
}

Future<bool> _confirm(
  BuildContext context, {
  required String title,
  required String message,
  required String confirmLabel,
  required String confirmKey,
  required String cancelKey,
}) async {
  var answered = false;
  return await showDialog<bool>(
        context: context,
        builder: (context) {
          void finish(bool result) {
            if (answered ||
                !context.mounted ||
                ModalRoute.of(context)?.isCurrent != true) {
              return;
            }
            answered = true;
            Navigator.of(context).pop(result);
          }

          return CallbackShortcuts(
            bindings: {
              const SingleActivator(LogicalKeyboardKey.escape): () =>
                  finish(false),
            },
            child: AlertDialog(
              title: Text(title),
              content: SingleChildScrollView(child: Text(message)),
              actions: [
                TextButton(
                  key: ValueKey(cancelKey),
                  autofocus: true,
                  onPressed: () => finish(false),
                  child: const Text('Cancel'),
                ),
                FilledButton(
                  key: ValueKey(confirmKey),
                  onPressed: () => finish(true),
                  child: Text(confirmLabel),
                ),
              ],
            ),
          );
        },
      ) ??
      false;
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
