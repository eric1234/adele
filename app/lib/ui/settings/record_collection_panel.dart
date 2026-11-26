import 'dart:async';
import 'dart:math';

import 'package:adele_configuration_store/adele_configuration_store.dart';
import 'package:adele_plugin_api/adele_plugin_api.dart';
import 'package:adele_settings/adele_settings.dart';
import 'package:adele_settings_host/adele_settings_host.dart'
    show ConfigurationRecordCredentialsPresent;
import 'package:adele_ui/settings_form_behavior.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/credential_service.dart';
import '../../core/global_settings_service.dart';
import '../../core/record_apply_coordinator.dart';
import '../../editor/native_rich_document_editor.dart';
import '../../frontend/application_frontend_bootstrap.dart';
import 'record_credential_controls.dart';
import 'record_field_editor_host.dart';
import 'scalar_input.dart';

part 'record_form_behavior.dart';

final class RecordCollectionPanel extends StatefulWidget {
  const RecordCollectionPanel({
    super.key,
    required this.service,
    required this.collection,
    this.frontends,
    this.sectionRevision,
    this.credentialAssociations,
    this.recordApplication,
    this.active = true,
    this.declarationIssues,
  });

  final GlobalSettingsService service;
  final RecordCollectionId collection;
  final ApplicationFrontendBootstrap? frontends;
  final int Function()? sectionRevision;
  final RecordCredentialService? credentialAssociations;
  final RecordApplication? recordApplication;
  final bool active;
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
  final _credentialStatuses =
      <
        (ConfigurationRecordId, RecordCredentialSlotId),
        RecordCredentialStatus
      >{};
  final _credentialErrors =
      <(ConfigurationRecordId, RecordCredentialSlotId), String>{};
  (ConfigurationRecordId, RecordCredentialSlotId)? _pendingCredential;
  List<RecordView> _records = const [];
  List<RecordDiagnosticView> _diagnostics = const [];
  bool _loaded = false;
  bool _busy = false;
  bool _confirming = false;
  bool _requiresReload = false;
  _RecordDraft? _blockedCreation;
  bool get _creationRequiresReload => _blockedCreation != null;
  bool _adding = false;
  int _formRevision = 0;
  int _reloadRevision = 0;
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

  // A hidden form may become visible again before Flutter rebuilds it. Fence
  // the old controls at navigation / operation admission, not at disposal.
  (int?, int) _formScope() => (widget.sectionRevision?.call(), _formRevision);

  void _beginOperation() {
    _formRevision++;
    _busy = true;
  }

  bool _current(RecordView record) =>
      _records.any((candidate) => identical(candidate, record));

  void _invalidateCredentials(ConfigurationRecordId id) {
    _credentialStatuses.removeWhere((key, _) => key.$1 == id);
    _credentialErrors.removeWhere((key, _) => key.$1 == id);
  }

  // Keep siblings' handles and nonsecret drafts. Only acknowledged results may
  // advance a record's baseline, including a partially completed attachment.
  void _replaceRecord(RecordView previous, RecordView? saved) {
    _records = [
      for (final current in _records)
        if (identical(current, previous)) ?saved else current,
    ];
    if (!identical(previous, saved)) _invalidateCredentials(previous.id);
  }

  Future<void> _reload() async {
    if (!mounted || _busy) return;
    // Admission covers the confirmation as well as the eventual read.
    setState(() {
      _beginOperation();
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
        _reloadRevision++;
        _credentialStatuses.clear();
        _credentialErrors.clear();
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
        _credentialStatuses.clear();
        _credentialErrors.clear();
        _records = view.records;
        _diagnostics = view.diagnostics;
        _loaded = true;
        _requiresReload = false;
        _blockedCreation?.reconciled = true;
        _blockedCreation = null;
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

  bool _creationCurrent(_RecordDraft draft) =>
      _enabled &&
      widget.active &&
      !_creationRequiresReload &&
      _adding &&
      identical(_creationDrafts[_type], draft);

  bool _blocksCreation(ConfigurationRecordId id) =>
      RecordCollectionView.blocksCreation(id, _records, _diagnostics);

  Future<void> _create(_RecordDraft draft, Map<String, Object> values) async {
    final definition = draft.definition;
    final id = draft.id;
    if (!_creationCurrent(draft)) return;
    // Keep the observed ID or initial file location occupied until Reload,
    // even if an external deletion has since made it available.
    if (_blocksCreation(id)) {
      if (draft.reconciled) return;
      setState(() {
        _formRevision++;
        _blockedCreation = draft;
        _creationError =
            'Not created: this record ID or its initial filename is already in use. '
            'Reload to reconcile current records before creating again. '
            'Your drafts are retained; no write was attempted.';
      });
      return;
    }
    setState(() {
      _beginOperation();
      _creationError = null;
      _message = null;
    });
    final application = widget.recordApplication;
    RecordView? acknowledged;
    try {
      acknowledged = await widget.service.createRecord(
        definition.id,
        id,
        values,
      );
    } on ConfigurationConflictException catch (error) {
      if (!mounted) return;
      setState(() {
        _blockedCreation = draft;
        _creationError =
            'Not created: the record ID or its initial filename is occupied or changed on disk. '
            'No existing file was overwritten. Reload before creating again.\n$error';
      });
      return;
    } on InvalidRecordValue catch (error) {
      if (mounted) {
        setState(
          () => _creationError = 'Not created: correct the values.\n$error',
        );
      }
      return;
    } on Object catch (error) {
      application?.unconfirmed((
        collection: definition.collection,
        type: definition.id,
        id: id,
      ));
      if (!mounted) return;
      setState(() {
        _blockedCreation = draft;
        _creationError =
            'Could not confirm creation. Your draft is retained. '
            'Reload to check persisted records before creating again.\n$error';
      });
      return;
    } finally {
      // The worker gate has released. Notify only on acknowledged success,
      // before releasing UI admission or consulting the dialog's lifetime.
      if (acknowledged != null) _saved(application, acknowledged);
      if (mounted) setState(() => _busy = false);
    }
    final saved = acknowledged;
    if (!mounted) return;
    setState(() {
      // The returned handle is usable; a collection read would revoke siblings.
      _records = [..._records, saved]
        ..sort((a, b) => a.id.value.compareTo(b.id.value));
      _message =
          'Created ${_displayName(saved, definition) ?? definition.label}.';
      _adding = false;
      _creationDrafts[definition.id] = _RecordDraft(definition);
      draft.dispose();
    });
  }

  void _edit(RecordView record) {
    if (!_enabled ||
        !_current(record) ||
        _fencedRecords.contains(record.id) ||
        _drafts.containsKey(record.id)) {
      return;
    }
    setState(() {
      _formRevision++;
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
    final application = widget.recordApplication;
    RecordView? acknowledged;
    setState(() {
      _beginOperation();
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
      if (deleting) {
        await widget.service.deleteRecord(record);
        acknowledged = record;
      } else {
        acknowledged = await widget.service.updateRecord(record, values!);
      }
    } on ConfigurationRecordCredentialsPresent {
      if (!mounted) return;
      setState(() {
        _recordErrors[record.id] =
            'Record not deleted: credential associations must be removed first. '
            'Use Check credential status and Forget credential for declared slots. '
            'If unknown credential entries remain, manual TOML correction may be '
            'necessary. No deletion was attempted; the record and drafts are kept.';
      });
      return;
    } on ConfigurationConflictException catch (error) {
      application?.unconfirmed(_applyKey(record));
      if (!mounted) return;
      setState(() {
        _fencedRecords.add(record.id);
        _invalidateCredentials(record.id);
        _recordErrors[record.id] =
            'Not ${deleting ? 'deleted' : 'saved'}: this record changed on disk. '
            'Your draft is retained. Reload before changing this record again.\n$error';
      });
      return;
    } on InvalidRecordValue catch (error) {
      if (mounted) {
        setState(() {
          _recordErrors[record.id] = 'Not saved: correct the values.\n$error';
        });
      }
      return;
    } on Object catch (error) {
      application?.unconfirmed(_applyKey(record));
      if (!mounted) return;
      setState(() {
        _fencedRecords.add(record.id);
        _invalidateCredentials(record.id);
        _recordErrors[record.id] =
            'Could not confirm ${deleting ? 'deletion' : 'save'}. '
            'The operation may have been published. Your draft is retained. '
            'Reload to check persisted state before changing this record again.\n$error';
      });
      return;
    } finally {
      if (acknowledged != null) {
        _saved(application, acknowledged, deleted: deleting);
      }
      if (mounted) {
        setState(() {
          _busy = false;
          _confirming = false;
        });
      }
    }
    if (!mounted) return;
    setState(() {
      _replaceRecord(record, deleting ? null : acknowledged);
      _drafts.remove(record.id)?.dispose();
      final definition = widget.service.records.definition(record.type);
      final name = _displayName(acknowledged!, definition) ?? definition.label;
      _message = '${deleting ? 'Deleted' : 'Saved'} $name.';
    });
  }

  Future<void> _credentialOperation(
    RecordView record,
    RecordCredentialSlotDefinition slot,
    RecordCredentialAction action,
    CredentialSecret? secret,
  ) async {
    final service = widget.credentialAssociations;
    final application = widget.recordApplication;
    final key = (record.id, slot.id);
    if (service == null ||
        !_enabled ||
        !_current(record) ||
        _fencedRecords.contains(record.id) ||
        !action.allowed(_credentialStatuses[key])) {
      return;
    }
    setState(() {
      _beginOperation();
      _confirming = action == RecordCredentialAction.forget;
      _pendingCredential = key;
    });
    RecordCredentialResult? acknowledged;
    try {
      if (_confirming) {
        final definition = widget.service.records.definition(record.type);
        final confirmed = await _confirm(
          context,
          title: 'Forget credential?',
          message:
              'Title: ${_recordTitle(record, definition)}\n'
              'Record ID: ${record.id}\n'
              'Credential slot: ${slot.label}\n\n'
              'This removes local protected credential material and detaches '
              'the association. The configuration record and its ordinary '
              'values are kept. This is not Delete Record.',
          confirmLabel: 'Forget credential',
          confirmKey:
              'credential-forget-confirm-${record.collection}-${record.id}-${slot.id}',
          cancelKey:
              'credential-forget-cancel-${record.collection}-${record.id}-${slot.id}',
        );
        if (!mounted || !confirmed) return;
      }
      setState(() {
        _confirming = false;
        _credentialErrors.remove(key);
      });
      acknowledged = await switch (action) {
        RecordCredentialAction.check => service.inspect(record, slot.id),
        RecordCredentialAction.reconcile => service.reconcile(record, slot.id),
        RecordCredentialAction.attach => service.attach(
          record,
          slot.id,
          secret!,
        ),
        RecordCredentialAction.replace => service.replace(
          record,
          slot.id,
          secret!,
        ),
        RecordCredentialAction.establishLocal => service.establishLocal(
          record,
          slot.id,
          secret!,
        ),
        RecordCredentialAction.forget => service.forget(record, slot.id),
      };
    } on RecordCredentialFailure catch (failure) {
      if (!failure.preservesApplyState &&
          action != RecordCredentialAction.check &&
          action != RecordCredentialAction.reconcile) {
        application?.unconfirmed(_applyKey(record));
      }
      if (!mounted) return;
      setState(() {
        if (failure.record case final acknowledged?) {
          _replaceRecord(record, acknowledged);
        }
        final kind = failure.kind;
        if (kind == RecordCredentialFailureKind.staleRecord ||
            kind == RecordCredentialFailureKind.configurationFailure) {
          _fencedRecords.add(record.id);
          _invalidateCredentials(record.id);
        } else {
          _credentialStatuses[key] = switch (kind) {
            RecordCredentialFailureKind.noReference =>
              RecordCredentialStatus.noReference,
            RecordCredentialFailureKind.missingLocal =>
              RecordCredentialStatus.missingLocal,
            RecordCredentialFailureKind.unavailable =>
              RecordCredentialStatus.unavailable,
            RecordCredentialFailureKind.invalid ||
            RecordCredentialFailureKind.invalidSlot =>
              RecordCredentialStatus.invalid,
            RecordCredentialFailureKind.reconciliationRequired =>
              RecordCredentialStatus.reconciliationRequired,
            _ => RecordCredentialStatus.failed,
          };
        }
        _credentialErrors[key] = recordCredentialFailureMessage(kind);
      });
      return;
    } on Object {
      if (action != RecordCredentialAction.check &&
          action != RecordCredentialAction.reconcile) {
        application?.unconfirmed(_applyKey(record));
      }
      if (!mounted) return;
      setState(() {
        // An unexpected acknowledgement failure cannot establish a new baseline.
        // Never render an exception that might contain native or secret data.
        _fencedRecords.add(record.id);
        _invalidateCredentials(record.id);
        _credentialErrors[key] = recordCredentialFailureMessage(
          RecordCredentialFailureKind.configurationFailure,
        );
      });
      return;
    } finally {
      if (acknowledged != null) {
        _credentialAcknowledged(application, acknowledged, action);
      }
      if (mounted) {
        setState(() {
          _busy = false;
          _confirming = false;
          _pendingCredential = null;
        });
      }
    }
    final result = acknowledged;
    if (!mounted) return;
    setState(() {
      _replaceRecord(record, result.record);
      _credentialStatuses[key] = result.status;
      _recordErrors.remove(record.id);
    });
  }

  static void _credentialAcknowledged(
    RecordApplication? application,
    RecordCredentialResult result,
    RecordCredentialAction action,
  ) {
    switch (action) {
      case RecordCredentialAction.check:
        break;
      case RecordCredentialAction.reconcile:
        // A validated reconciliation issues a fresh handle. Locked, invalid,
        // uncertain and no-reference inspections do not authorize an apply.
        final key = _applyKey(result.record);
        if ((result.status == RecordCredentialStatus.stored ||
                result.status == RecordCredentialStatus.missingLocal) &&
            application != null &&
            application.supports(key)) {
          application.reconciled(key);
        }
      case RecordCredentialAction.attach ||
          RecordCredentialAction.replace ||
          RecordCredentialAction.establishLocal ||
          RecordCredentialAction.forget:
        _saved(application, result.record);
    }
  }

  @override
  Widget build(BuildContext context) {
    final application = widget.recordApplication;
    return application == null
        ? _collection(context)
        : ListenableBuilder(
            listenable: application,
            builder: (context, _) => _collection(context),
          );
  }

  Widget _collection(BuildContext context) {
    final collection = widget.collection;
    final creationEnabled = _enabled && !_creationRequiresReload;
    final deletion = widget.recordApplication?.recentDeletion(collection);
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
                  'Plugins that support live application report its outcome '
                  'separately from saving.',
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
                if (deletion != null &&
                    !_records.any((record) => _applyKey(record) == deletion))
                  ?_applyFeedback(deletion),
                Align(
                  alignment: Alignment.centerLeft,
                  child: FilledButton.icon(
                    key: ValueKey('records-add-$collection'),
                    onPressed: creationEnabled && !_adding
                        ? () {
                            if (_enabled && !_creationRequiresReload) {
                              setState(() {
                                _formRevision++;
                                _adding = true;
                              });
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
                                        if (_enabled &&
                                            value != null &&
                                            value != _type) {
                                          setState(() {
                                            _formRevision++;
                                            _type = value;
                                          });
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
                                          setState(() {
                                            _formRevision++;
                                            _adding = false;
                                          });
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

  Widget? _applyFeedback(RecordApplyKey key, {RecordView? record}) {
    final application = widget.recordApplication;
    if (application == null || !application.supports(key)) return null;
    final deleted = record == null;
    final outcome = application.outcome(key, deleted: deleted);
    bool canRetry() =>
        _enabled &&
        widget.active &&
        identical(widget.recordApplication, application) &&
        (record == null
            ? application.recentDeletion(key.collection) == key &&
                  !_records.any((current) => _applyKey(current) == key)
            : _current(record) && !_fencedRecords.contains(record.id)) &&
        switch (application.outcome(key, deleted: deleted)?.status) {
          RecordApplyStatus.failed ||
          RecordApplyStatus.unavailable ||
          RecordApplyStatus.notApplied => true,
          _ => false,
        };

    final status = outcome?.status;
    final suffix = '${key.collection}-${key.type}-${key.id}';
    return Padding(
      key: ValueKey('record-apply-$suffix'),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Semantics(
            liveRegion: true,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (record == null)
                  Text(
                    'Deleted record: ${widget.service.records.definition(key.type).label}',
                  )
                else if (outcome != null)
                  const Text('Saved configuration'),
                Text(switch (status) {
                  null => 'Runtime application: No confirmed result',
                  RecordApplyStatus.applying =>
                    'Runtime application: Applying...',
                  RecordApplyStatus.applied => 'Runtime application: Applied',
                  RecordApplyStatus.noChange =>
                    'Runtime application: No change',
                  RecordApplyStatus.failed || RecordApplyStatus.notApplied =>
                    'Runtime application: Not applied',
                  RecordApplyStatus.unavailable =>
                    'Runtime application: Unavailable',
                  RecordApplyStatus.restartRequired =>
                    'Runtime application: Restart required',
                }),
                if (outcome?.cleanupPending ?? false)
                  const Text(
                    'Cleanup of the previous configuration is pending.',
                  ),
                if (status == RecordApplyStatus.restartRequired)
                  const Text(
                    'The runtime outcome is unknown. Restart ADELE before trying again.',
                  )
                else if (status == RecordApplyStatus.unavailable ||
                    status == RecordApplyStatus.failed)
                  const Text(
                    'Retry when ready, or restart ADELE if the problem persists.',
                  ),
              ],
            ),
          ),
          if (status == RecordApplyStatus.failed ||
              status == RecordApplyStatus.unavailable ||
              status == RecordApplyStatus.notApplied)
            TextButton(
              key: ValueKey('record-apply-retry-$suffix'),
              onPressed: canRetry()
                  ? () {
                      if (canRetry()) application.retry(key);
                    }
                  : null,
              child: const Text('Retry application'),
            ),
        ],
      ),
    );
  }

  Widget _creationForm(RecordTypeDefinition type, bool enabled) {
    final draft = _creationDrafts[type.id]!;
    final reconciled =
        draft.reconciled && !_creationRequiresReload && !_requiresReload;
    final occupied = reconciled && _blocksCreation(draft.id);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (reconciled) ...[
          Text(
            occupied
                ? 'Reload found this record ID or its initial filename in use. Inspect the collection before starting a new draft.'
                : 'Reload finished. Inspect the collection before retrying this draft or starting another.',
          ),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              onPressed: enabled
                  ? () {
                      if (!_creationCurrent(draft)) return;
                      setState(() {
                        _formRevision++;
                        _creationDrafts[type.id] = _RecordDraft(type);
                        draft.dispose();
                      });
                    }
                  : null,
              child: const Text('Discard and start new draft'),
            ),
          ),
        ],
        _RecordForm(
          draft: draft,
          frontends: widget.frontends,
          formScope: _formScope,
          reloadRevision: _reloadRevision,
          active: widget.active && _adding && type.id == _type,
          enabled: enabled && _adding && type.id == _type,
          onChanged: () => setState(() {}),
          onSubmit: occupied ? null : (values) => _create(draft, values),
        ),
      ],
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
      onExpansionChanged: () => setState(() => _formRevision++),
      applyFeedback: _applyFeedback(_applyKey(record), record: record),
      credentials: (expanded) => [
        for (final slot
            in widget.service.records.definition(record.type).credentialSlots)
          RecordCredentialControls(
            key: ValueKey(
              'credential-slot-${record.collection}-${record.id}-${slot.id}',
            ),
            record: record,
            slot: slot,
            active: widget.active && expanded,
            enabled: enabled && widget.credentialAssociations != null,
            pending: _pendingCredential == (record.id, slot.id) && !_confirming,
            status: _credentialStatuses[(record.id, slot.id)],
            error: _credentialErrors[(record.id, slot.id)],
            onAction: (action, secret) =>
                _credentialOperation(record, slot, action, secret),
          ),
      ],
      onEdit: enabled ? () => _edit(record) : null,
      onDelete: enabled ? () => _mutate(record) : null,
      editor: draft == null
          ? null
          : (expanded) => _RecordForm(
              key: ObjectKey(draft),
              draft: draft,
              frontends: widget.frontends,
              formScope: _formScope,
              reloadRevision: _reloadRevision,
              active: widget.active && expanded,
              enabled: enabled,
              onChanged: () => setState(() {}),
              onSubmit: (values) =>
                  _mutate(record, draft: draft, values: values),
              onCancel: _busy ? null : () => _cancel(record, draft),
            ),
    );
  }
}

final class _RecordDraft extends ChangeNotifier {
  _RecordDraft(this.definition, {this.record}) : id = record?.id ?? _newId() {
    for (final field in definition.fields) {
      final value = record?.values[field.id.value];
      if (field.editor == RecordFieldEditor.markdown) {
        markdown[field.id] = NativeRichDocumentEditor(
          markdown: value as String? ?? '',
        )..addListener(notifyListeners);
      } else if (field.editor == null &&
          (field.type is StringSettingType ||
              field.type is IntegerSettingType)) {
        text[field.id] = TextEditingController(text: value?.toString() ?? '');
      } else {
        if (value != null) {
          _typed[field.id] = field.snapshotValue(value);
        } else if (field.required && field.type is StringSettingType) {
          _typed[field.id] = '';
        }
        continue;
      }
      if (!field.required && value == '') _restoredEmpty.add(field.id);
    }
  }

  final RecordTypeDefinition definition;
  final RecordView? record;
  final ConfigurationRecordId id;
  bool reconciled = false;
  // Text and documents are read from their owners, never from a cached parse.
  // Only a restored empty string needs distinguishing from an empty control.
  final _restoredEmpty = <RecordFieldId>{};
  final _typed = <RecordFieldId, Object>{};
  final clearRevisions = <RecordFieldId, int>{};
  final text = <RecordFieldId, TextEditingController>{};
  final markdown = <RecordFieldId, NativeRichDocumentEditor>{};
  bool disposed = false;

  void clear(RecordFieldDefinition<Object> field) {
    assert(!field.required);
    clearRevisions.update(field.id, (n) => n + 1, ifAbsent: () => 1);
    _typed.remove(field.id);
    _restoredEmpty.remove(field.id);
    if (markdown[field.id] case final editor?) {
      // Explicit discard (including unsettled input) retires the owner. Normal
      // deletion in the document keeps its owner and Undo history instead.
      editor.dispose();
      markdown[field.id] = NativeRichDocumentEditor(markdown: '')
        ..addListener(notifyListeners);
    }
  }

  void editScalar(RecordFieldDefinition<Object> field, Object? value) {
    if (text.containsKey(field.id)) {
      _restoredEmpty.remove(field.id);
    } else if (value != null) {
      _typed[field.id] = value;
    } else if (!field.required) {
      clear(field);
    }
  }

  bool get dirty {
    final before = record!.values;
    final now = snapshot();
    return before.length != now.length ||
        now.entries.any(
          (entry) =>
              !before.containsKey(entry.key) ||
              !recordFieldValuesEqual(entry.value, before[entry.key]),
        );
  }

  static ConfigurationRecordId _newId() {
    final random = Random.secure();
    final hex = List.generate(
      16,
      (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
    return ConfigurationRecordId('r-$hex');
  }

  Map<String, Object?> snapshot({Map<RecordFieldId, String>? errors}) {
    // Absent fields have no key. An unrepresentable draft is present with
    // null, so behavior can observe it but record validation rejects it.
    final values = <String, Object?>{};
    for (final field in definition.fields) {
      Object? value;
      String? error;
      if (text[field.id] case final controller?) {
        final raw = controller.text;
        if (!field.required &&
            raw.isEmpty &&
            !_restoredEmpty.contains(field.id)) {
          continue;
        }
        value = field.type is IntegerSettingType
            ? int.tryParse(raw, radix: 10)
            : raw;
      } else if (markdown[field.id] case final editor?) {
        try {
          value = editor.snapshot()['markdown'];
          if (value == null) {
            error = 'Finish composing text before saving.';
          } else if (value == '' &&
              !field.required &&
              !(editor.revision == 0 && _restoredEmpty.contains(field.id))) {
            continue;
          }
        } on FormatException catch (failure) {
          error =
              'Cannot save this Markdown: ${failure.message} Edit it or use Undo.';
        }
      } else {
        value = _typed[field.id];
        if (value == null && !field.required) continue;
      }
      values[field.id.value] = value;
      if (errors != null) {
        error ??= field.valueError(value);
        if (error != null) errors[field.id] = error;
      }
    }
    return Map.unmodifiable(values);
  }

  Map<String, Object> validate() => definition.validate(id, snapshot());

  @override
  void dispose() {
    disposed = true;
    for (final controller in text.values) {
      controller.dispose();
    }
    for (final editor in markdown.values) {
      editor.dispose();
    }
    super.dispose();
  }
}

final class _RecordForm extends StatelessWidget {
  const _RecordForm({
    super.key,
    required this.draft,
    required this.frontends,
    required this.formScope,
    required this.reloadRevision,
    required this.active,
    required this.enabled,
    required this.onChanged,
    required this.onSubmit,
    this.onCancel,
  });

  final _RecordDraft draft;
  final ApplicationFrontendBootstrap? frontends;
  final (int?, int) Function() formScope;
  final int reloadRevision;
  final bool active;
  final bool enabled;
  final VoidCallback onChanged;
  final ValueChanged<Map<String, Object>>? onSubmit;
  final VoidCallback? onCancel;

  @override
  Widget build(BuildContext context) {
    if (active && draft.definition.formBehavior != null) {
      return _BehaviorHost(
        key: ValueKey((draft, frontends, formScope().$1, reloadRevision)),
        form: this,
      );
    }
    return _body(context, null);
  }

  Widget _body(BuildContext context, _BehaviorHostState? behavior) {
    if (draft.markdown.isEmpty) return _controls(context, behavior);
    for (final field in draft.definition.fields) {
      draft.markdown[field.id]?.setEditingEnabled(
        active && enabled && (behavior?.allows(field) ?? true),
      );
    }
    // Composition completion can make Save safe without a document change.
    return ListenableBuilder(
      listenable: draft,
      builder: (context, _) => _controls(context, behavior),
    );
  }

  Widget _controls(BuildContext context, _BehaviorHostState? behavior) {
    final definition = draft.definition;
    final record = draft.record;
    final suffix =
        '${definition.collection}${record == null ? '' : '-${record.id}'}';
    final errors = <RecordFieldId, String>{};
    final values = draft.snapshot(errors: errors);
    final scope = formScope();
    final route = ModalRoute.of(context);
    bool current() =>
        active &&
        !draft.disposed &&
        (route?.isActive ?? true) &&
        formScope() == scope;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(definition.label),
        if (definition.description case final description?) Text(description),
        if (behavior?.unavailable == true)
          const Text(
            'Form customization unavailable. Showing declared controls.',
          ),
        for (final field in definition.fields)
          _field(
            context,
            field,
            suffix,
            values,
            errors[field.id],
            current,
            behavior,
          ),
        Wrap(
          spacing: 8,
          children: [
            FilledButton(
              key: ValueKey(
                'record-${record == null ? 'create' : 'save'}-$suffix',
              ),
              onPressed: active && enabled && errors.isEmpty && onSubmit != null
                  ? () {
                      if (!current()) return;
                      // Revalidate current controls rather than stale build values.
                      try {
                        onSubmit!(draft.validate());
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
                onPressed: active && onCancel != null
                    ? () {
                        if (current()) onCancel!();
                      }
                    : null,
                child: const Text('Cancel'),
              ),
          ],
        ),
        if (record == null)
          ExpansionTile(
            title: const Text('Advanced details'),
            children: [_RecordIdentity(draft.id)],
          ),
      ],
    );
  }

  Widget _field(
    BuildContext context,
    RecordFieldDefinition<Object> field,
    String suffix,
    Map<String, Object?> values,
    String? error,
    bool Function() current,
    _BehaviorHostState? behavior,
  ) {
    final id = field.id.value;
    final revision = draft.clearRevisions[field.id];
    bool fieldCurrent() =>
        current() && draft.clearRevisions[field.id] == revision;
    bool editable() => active && enabled && (behavior?.allows(field) ?? true);
    void changed([List<String>? context]) {
      behavior?.changed(field, context);
      onChanged();
    }

    final label = field.required ? '${field.label} (Required)' : field.label;
    final inputKey = ValueKey('record-input-$suffix-$id');
    final editor = field.editor;
    final controller = draft.text[field.id];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (editor != null)
          InputDecorator(
            key: inputKey,
            decoration: InputDecoration(
              labelText: label,
              floatingLabelBehavior: FloatingLabelBehavior.always,
              enabled: editable(),
              errorText: error,
              errorMaxLines: 4,
            ),
            child: switch (editor) {
              _ when !active => const SizedBox.shrink(),
              ContributedRecordFieldEditor(:final extensionId) =>
                RecordFieldEditorHost(
                  key: ValueKey((
                    frontends,
                    draft,
                    id,
                    formScope(),
                    editable(),
                    revision,
                  )),
                  definition: draft.definition,
                  field: field,
                  extensionId: extensionId,
                  frontends: frontends,
                  canEdit: editable(),
                  isCurrent: () =>
                      fieldCurrent() && (behavior == null || behavior.mounted),
                  readValue: () => draft._typed[field.id],
                  permitsValue: (value) =>
                      editable() && (behavior?.offers(field, value) ?? true),
                  acceptValue: (value, context) {
                    draft._typed[field.id] = value;
                    changed(context);
                  },
                ),
              _ => SizedBox(
                height: 220,
                child: draft.markdown[field.id]!.buildView(),
              ),
            },
          )
        else if (field.type case final SettingType<Object> scalar)
          ScalarInput(
            inputKey: inputKey,
            type: scalar,
            label: label,
            value: values[id],
            text: controller,
            enabled: editable(),
            choices: behavior?.fields[id]?.choices,
            unsetLabel: field.required ? null : field.unsetLabel ?? 'Not set',
            booleanDropdown: true,
            error: error,
            onChanged: (value) {
              if (!fieldCurrent() || !editable()) return;
              if (value != null && !(behavior?.offers(field, value) ?? true)) {
                return;
              }
              draft.editScalar(field, value);
              changed();
            },
          ),
        if (!field.required &&
            values.containsKey(id) &&
            (editor != null || values[id] == ''))
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              key: ValueKey('record-clear-$suffix-$id'),
              onPressed: editable()
                  ? () {
                      if (!fieldCurrent() ||
                          !editable() ||
                          (controller != null && controller.text.isNotEmpty)) {
                        return;
                      }
                      draft.clear(field);
                      changed();
                    }
                  : null,
              child: Text(
                values[id] == ''
                    ? 'Remove empty value'
                    : 'Remove ${field.label}',
              ),
            ),
          ),
        if (behavior?.fields[id]?.guidance case final guidance?)
          Semantics(liveRegion: true, child: Text(guidance))
        else if (field.description case final description?)
          Text(description, style: Theme.of(context).textTheme.bodySmall),
        const SizedBox(height: 8),
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
    required this.credentials,
    required this.onExpansionChanged,
    this.applyFeedback,
    this.editor,
    this.error,
  });

  final RecordView record;
  final RecordTypeDefinition definition;
  final VoidCallback? onEdit;
  final VoidCallback? onDelete;
  final List<Widget> Function(bool expanded) credentials;
  final VoidCallback onExpansionChanged;
  final Widget? applyFeedback;
  final Widget Function(bool expanded)? editor;
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
    final details = ExpansionTile(
      maintainState: true,
      onExpansionChanged: (expanded) {
        setState(() => _expanded = expanded);
        widget.onExpansionChanged();
      },
      title: Text(_recordTitle(record, definition)),
      subtitle: Text(definition.label),
      childrenPadding: const EdgeInsets.all(16),
      expandedCrossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ExcludeFocus(
          excluding: !_expanded,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SelectableText('Collection: ${record.collection}'),
              _RecordIdentity(record.id),
              SelectableText('Record type: ${record.type}'),
              if (widget.error case final error?) _diagnostic(context, error),
              if (widget.editor case final editor?)
                editor(_expanded)
              else ...[
                for (final field in definition.fields)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: SelectableText(
                      _describeField(
                        field.label,
                        record.values[field.id.value],
                      ),
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
              if (definition.credentialSlots.isNotEmpty) ...[
                const Divider(),
                Text(
                  'Credentials',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const Text(
                  'Credentials use OS-protected storage. Stored locally does not '
                  'mean authenticated, even after configuration is applied.',
                ),
                ...widget.credentials(_expanded),
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
    );
    return Card(
      child: widget.applyFeedback == null
          ? details
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [details, ?widget.applyFeedback],
            ),
    );
  }
}

RecordApplyKey _applyKey(RecordView record) =>
    (collection: record.collection, type: record.type, id: record.id);

void _saved(
  RecordApplication? application,
  RecordView record, {
  bool deleted = false,
}) {
  final key = _applyKey(record);
  if (application != null && application.supports(key)) {
    application.saved(key, deleted: deleted);
  }
}

final class _RecordIdentity extends StatelessWidget {
  const _RecordIdentity(this.id);

  final ConfigurationRecordId id;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      Expanded(child: SelectableText('Record ID: $id')),
      IconButton(
        tooltip: 'Copy record ID',
        icon: const Icon(Icons.copy),
        onPressed: () => Clipboard.setData(ClipboardData(text: id.value)),
      ),
    ],
  );
}

String _recordTitle(RecordView record, RecordTypeDefinition definition) =>
    _displayName(record, definition) ?? record.id.value;

String _describeField(String label, Object? value) {
  String scalar(Object? value) => switch (value) {
    null => 'Not provided',
    '' => '(empty string)',
    _ => value.toString(),
  };
  if (value is Map<String, Object>) {
    return [
      '$label:',
      for (final e in value.entries) '  ${e.key}: ${scalar(e.value)}',
    ].join('\n');
  }
  return '$label: ${scalar(value)}';
}

String? _displayName(RecordView record, RecordTypeDefinition definition) {
  final display = record.values[definition.displayField?.value];
  return display is String && display.trim().isNotEmpty ? display : null;
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
