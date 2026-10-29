import 'package:adele_settings/adele_settings.dart';
import 'package:flutter/material.dart';

import '../../core/credential_service.dart';
import '../../core/global_settings_service.dart';

enum RecordCredentialAction {
  check,
  attach,
  replace,
  establishLocal,
  forget,
  reconcile;

  bool allowed(RecordCredentialStatus? status) => switch (this) {
    check => true,
    attach => status == RecordCredentialStatus.noReference,
    replace => status == RecordCredentialStatus.stored,
    establishLocal => status == RecordCredentialStatus.missingLocal,
    forget =>
      status == RecordCredentialStatus.stored ||
          status == RecordCredentialStatus.missingLocal,
    reconcile =>
      status == RecordCredentialStatus.reconciliationRequired ||
          status == RecordCredentialStatus.unavailable ||
          status == RecordCredentialStatus.failed,
  };
}

/// Transient secret entry, separate from retained nonsecret record drafts.
/// All association authority and I/O remain with the application coordinator.
final class RecordCredentialControls extends StatefulWidget {
  const RecordCredentialControls({
    super.key,
    required this.record,
    required this.slot,
    required this.active,
    required this.enabled,
    required this.pending,
    required this.status,
    required this.error,
    required this.onAction,
  });

  final RecordView record;
  final RecordCredentialSlotDefinition slot;
  final bool active;
  final bool enabled;
  final bool pending;
  final RecordCredentialStatus? status;
  final String? error;
  final Future<void> Function(RecordCredentialAction, CredentialSecret?)
  onAction;

  @override
  State<RecordCredentialControls> createState() =>
      _RecordCredentialControlsState();
}

final class _RecordCredentialControlsState
    extends State<RecordCredentialControls> {
  TextEditingController? _secret;
  RecordCredentialAction? _entryAction;
  String? _inputError;
  bool _submitting = false;

  ValueKey<String> _key(String action) => ValueKey(
    'credential-$action-${widget.record.collection}-${widget.record.id}-${widget.slot.id}',
  );

  bool get _enabled =>
      mounted && widget.active && widget.enabled && !_submitting;

  @override
  void didUpdateWidget(RecordCredentialControls oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!widget.active ||
        !widget.enabled ||
        !identical(oldWidget.record, widget.record)) {
      _discardInput();
    }
    if (!identical(oldWidget.record, widget.record)) _inputError = null;
  }

  void _discardInput() {
    _secret?.clear();
    _secret?.dispose();
    _secret = null;
    _entryAction = null;
  }

  @override
  void dispose() {
    _discardInput();
    super.dispose();
  }

  void _start(RecordCredentialAction action) {
    if (!_enabled || !action.allowed(widget.status)) return;
    setState(() {
      _discardInput();
      _secret = _SecretEditingController();
      _entryAction = action;
      _inputError = null;
    });
  }

  Future<void> _submit() async {
    final action = _entryAction;
    if (!_enabled || action == null || !action.allowed(widget.status)) return;
    _submitting = true;
    try {
      // This validates the input, not the full protected envelope's byte limit.
      // The coordinator validates that limit before either store is mutated.
      final secret = CredentialSecret(_secret!.text);
      setState(_discardInput);
      await widget.onAction(action, secret);
    } on CredentialFailure {
      if (mounted) {
        setState(() {
          _inputError = recordCredentialFailureMessage(
            RecordCredentialFailureKind.invalidSecret,
          );
        });
      }
    } finally {
      if (mounted) {
        setState(() {
          _discardInput();
          _submitting = false;
        });
      }
    }
  }

  Widget _action(
    String key,
    String label,
    RecordCredentialAction action, {
    bool entry = false,
  }) => TextButton(
    key: _key(key),
    onPressed: _enabled
        ? () {
            if (!_enabled || !action.allowed(widget.status)) return;
            if (entry) {
              _start(action);
            } else {
              setState(() {
                _discardInput();
                _inputError = null;
              });
              widget.onAction(action, null);
            }
          }
        : null,
    child: Text(label),
  );

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 12),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(widget.slot.label, style: Theme.of(context).textTheme.titleSmall),
        Text(switch (widget.slot.kind) {
          RecordCredentialKind.secretText => 'Secret text',
        }),
        Semantics(
          liveRegion: true,
          child: Text(switch (widget.status) {
            null => 'Credential status not checked',
            RecordCredentialStatus.noReference => 'No credential configured',
            RecordCredentialStatus.missingLocal =>
              'Credential missing on this machine',
            RecordCredentialStatus.stored => 'Credential stored locally',
            RecordCredentialStatus.unavailable =>
              'Secure storage unavailable or locked',
            RecordCredentialStatus.invalid =>
              'Stored credential or binding invalid',
            RecordCredentialStatus.failed =>
              'Could not determine credential status',
            RecordCredentialStatus.reconciliationRequired =>
              'Previous operation needs reconciliation',
          }),
        ),
        if (widget.pending) const Text('Credential operation pending'),
        if (_inputError ?? widget.error case final error?)
          Semantics(
            liveRegion: true,
            child: Text(
              error,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ),
        Wrap(
          spacing: 8,
          children: [
            _action(
              'check',
              'Check credential status',
              RecordCredentialAction.check,
            ),
            if (RecordCredentialAction.attach.allowed(widget.status))
              _action(
                'set',
                'Set credential',
                RecordCredentialAction.attach,
                entry: true,
              ),
            if (RecordCredentialAction.replace.allowed(widget.status))
              _action(
                'replace',
                'Replace credential',
                RecordCredentialAction.replace,
                entry: true,
              ),
            if (RecordCredentialAction.establishLocal.allowed(widget.status))
              _action(
                'establish',
                'Set credential on this machine',
                RecordCredentialAction.establishLocal,
                entry: true,
              ),
            if (RecordCredentialAction.forget.allowed(widget.status))
              _action(
                'forget',
                'Forget credential',
                RecordCredentialAction.forget,
              ),
            if (RecordCredentialAction.reconcile.allowed(widget.status))
              _action(
                'reconcile',
                'Reconcile',
                RecordCredentialAction.reconcile,
              ),
          ],
        ),
        if (_secret case final controller?) ...[
          TextField(
            key: _key('input'),
            controller: controller,
            enabled: _enabled,
            autofocus: true,
            obscureText: true,
            autocorrect: false,
            enableSuggestions: false,
            enableIMEPersonalizedLearning: false,
            smartDashesType: SmartDashesType.disabled,
            smartQuotesType: SmartQuotesType.disabled,
            autofillHints: null,
            decoration: InputDecoration(labelText: widget.slot.label),
            onSubmitted: (_) => _submit(),
          ),
          Wrap(
            spacing: 8,
            children: [
              FilledButton(
                key: _key('submit'),
                onPressed: _enabled ? _submit : null,
                child: const Text('Store credential'),
              ),
              TextButton(
                key: _key('cancel'),
                onPressed: _enabled
                    ? () {
                        if (_enabled) setState(_discardInput);
                      }
                    : null,
                child: const Text('Cancel'),
              ),
            ],
          ),
        ],
      ],
    ),
  );
}

// Flutter includes the controller in TextField/EditableText diagnostics, even
// for obscured fields. Do not inherit ValueNotifier's secret-bearing toString.
final class _SecretEditingController extends TextEditingController {
  @override
  String toString() => 'SecretEditingController([REDACTED])';
}

String recordCredentialFailureMessage(
  RecordCredentialFailureKind kind,
) => switch (kind) {
  RecordCredentialFailureKind.busy =>
    'Another credential operation is pending for this record. Check again after it settles.',
  RecordCredentialFailureKind.closed =>
    'Credential operations are unavailable because ADELE is shutting down.',
  RecordCredentialFailureKind.invalidSlot =>
    'This credential slot is not available in the current declaration. Correct the installation and restart ADELE.',
  RecordCredentialFailureKind.invalidSecret =>
    'Credential not stored: enter nonempty valid text without NUL characters. The complete protected credential, including binding metadata, must fit the secure-storage size limit.',
  RecordCredentialFailureKind.staleRecord =>
    'This record changed or its handle is stale. Reload is required before another operation. Unsaved record drafts are retained; no automatic retry was made.',
  RecordCredentialFailureKind.configurationFailure =>
    'Could not confirm the configuration state. Reload is required before another operation. Secure storage may already have changed; drafts are retained and no automatic retry was made.',
  RecordCredentialFailureKind.noReference =>
    'No credential is associated with this slot. Set a credential explicitly.',
  RecordCredentialFailureKind.alreadyAttached =>
    'A credential association or protected value already exists. Check credential status before choosing another action; it was not replaced.',
  RecordCredentialFailureKind.missingLocal =>
    'The credential is missing on this machine. Set it on this machine using the existing association, or Forget credential to detach it.',
  RecordCredentialFailureKind.unavailable =>
    'Secure storage is unavailable or locked, not confirmed missing. The association may have been saved. Check credential status after storage becomes available.',
  RecordCredentialFailureKind.invalid =>
    'The stored credential or protected binding is invalid. Replacement and deletion are blocked; it will not be repaired automatically.',
  RecordCredentialFailureKind.storageFailure =>
    'Secure storage failed. The association may have been saved. Check credential status or reconcile before choosing another action; no automatic retry was made.',
  RecordCredentialFailureKind.reconciliationRequired =>
    'The previous credential operation has an uncertain outcome. Use Reconcile to check local storage, then choose the next action. Reconciliation does not retry the operation.',
};
