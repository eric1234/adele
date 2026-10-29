part of 'global_settings_service.dart';

/// Local storage state only. None of these states assert provider authentication.
enum RecordCredentialStatus {
  noReference,
  missingLocal,
  stored,
  unavailable,
  invalid,
  failed,
  reconciliationRequired,
}

enum RecordCredentialFailureKind {
  closed,
  busy,
  invalidSlot,
  invalidSecret,
  staleRecord,
  configurationFailure,
  noReference,
  alreadyAttached,
  missingLocal,
  unavailable,
  invalid,
  storageFailure,
  reconciliationRequired,
}

/// Safe host result: no reference, protected envelope, or secret is projected.
final class RecordCredentialResult {
  const RecordCredentialResult(this.record, this.status);

  final RecordView record;
  final RecordCredentialStatus status;
}

/// Fixed diagnostics without a native cause or secret-bearing payload.
final class RecordCredentialFailure implements Exception {
  const RecordCredentialFailure(this.kind, {this.record});

  final RecordCredentialFailureKind kind;

  /// Latest acknowledged handle, including a reference saved before OS failure.
  /// Null after a configuration failure: explicitly Reload before proceeding.
  final RecordView? record;

  @override
  String toString() => 'RecordCredentialFailure(${kind.name})';
}

/// App-private association authority over CFG5's owner and P1's credential owner.
///
/// Callers supply only an owner-bound view, a declared slot and (for writes) a
/// secret. They cannot select a plugin owner, native key or credential reference.
/// No construction/startup I/O, automatic recovery, cross-store transaction or
/// cross-process keyring CAS is implied. Close this owner before its dependencies.
final class RecordCredentialService {
  RecordCredentialService({
    required GlobalSettingsService settings,
    required CredentialService credentials,
  }) : _settings = settings,
       _credentials = credentials;

  final GlobalSettingsService _settings;
  final CredentialService _credentials;
  final Set<(RecordCollectionId, ConfigurationRecordId)> _active = {};
  Future<void> _pending = Future<void>.value();
  Future<void>? _closing;

  Future<RecordCredentialResult> inspect(
    RecordView record,
    RecordCredentialSlotId slot,
  ) => _admit(record, slot, (workflow) => _inspect(workflow, reconcile: false));

  /// An explicit read reconciles uncertain OS outcomes, not a retry of a mutation.
  Future<RecordCredentialResult> reconcile(
    RecordView record,
    RecordCredentialSlotId slot,
  ) => _admit(record, slot, (workflow) => _inspect(workflow, reconcile: true));

  Future<RecordCredentialResult> attach(
    RecordView record,
    RecordCredentialSlotId slot,
    CredentialSecret secret,
  ) => _admit(record, slot, (workflow) async {
    if (workflow.reference != null) {
      throw const RecordCredentialFailure(
        RecordCredentialFailureKind.alreadyAttached,
      );
    }
    final reference = CredentialReference.generate();
    // Includes all binding metadata and JSON escaping in P1's UTF-8 byte bound.
    // Validate before either store is mutated, not just before the native write.
    final payload = workflow.payload(reference, secret);
    await workflow.setReference(reference);
    await _credentials.store(
      reference,
      payload,
      beforeMutation: workflow.beforeMutation,
    );
    await workflow.refresh();
    return RecordCredentialResult(
      workflow.record,
      RecordCredentialStatus.stored,
    );
  });

  Future<RecordCredentialResult> replace(
    RecordView record,
    RecordCredentialSlotId slot,
    CredentialSecret secret,
  ) => _admit(record, slot, (workflow) async {
    final reference = workflow.requireReference();
    final payload = workflow.payload(reference, secret);
    _requireReconciled(reference);
    if (!await _readBound(workflow)) {
      throw const RecordCredentialFailure(
        RecordCredentialFailureKind.missingLocal,
      );
    }
    // OS reads/unlock prompts may block. Check the same bytes again before write.
    await workflow.validate();
    await _credentials.replace(
      reference,
      payload,
      validateExisting: (value) => _validateBound(workflow, value),
      beforeMutation: workflow.beforeMutation,
    );
    await workflow.refresh();
    return RecordCredentialResult(
      workflow.record,
      RecordCredentialStatus.stored,
    );
  });

  /// Establishes a transferred/partially attached reference only after confirmed
  /// local absence. Reuses that reference and never overwrites an existing value.
  Future<RecordCredentialResult> establishLocal(
    RecordView record,
    RecordCredentialSlotId slot,
    CredentialSecret secret,
  ) => _admit(record, slot, (workflow) async {
    final reference = workflow.requireReference();
    final payload = workflow.payload(reference, secret);
    _requireReconciled(reference);
    if (await _readBound(workflow)) {
      throw const RecordCredentialFailure(
        RecordCredentialFailureKind.alreadyAttached,
      );
    }
    await workflow.validate();
    await _credentials.store(
      reference,
      payload,
      beforeMutation: workflow.beforeMutation,
    );
    await workflow.refresh();
    return RecordCredentialResult(
      workflow.record,
      RecordCredentialStatus.stored,
    );
  });

  Future<RecordCredentialResult> forget(
    RecordView record,
    RecordCredentialSlotId slot,
  ) => _admit(record, slot, (workflow) async {
    final reference = workflow.requireReference();
    _requireReconciled(reference);
    final present = await _readBound(workflow);
    await workflow.validate();
    // Absence is already confirmed by the successful read. Never delete an
    // unverified value, including corrupt or foreign protected bindings.
    if (present) {
      await _credentials.delete(
        reference,
        validateExisting: (value) => _validateBound(workflow, value),
        beforeMutation: workflow.beforeMutation,
      );
    }
    await workflow.setReference(null);
    return RecordCredentialResult(
      workflow.record,
      RecordCredentialStatus.noReference,
    );
  });

  Future<RecordCredentialResult> _inspect(
    _RecordCredentialWorkflow workflow, {
    required bool reconcile,
  }) async {
    final reference = workflow.reference;
    if (reference == null) {
      return RecordCredentialResult(
        workflow.record,
        RecordCredentialStatus.noReference,
      );
    }
    if (!reconcile && _credentials.requiresReconciliation(reference)) {
      return RecordCredentialResult(
        workflow.record,
        RecordCredentialStatus.reconciliationRequired,
      );
    }
    final RecordCredentialStatus status;
    try {
      status = await _readBound(workflow, reconcile: reconcile)
          ? RecordCredentialStatus.stored
          : RecordCredentialStatus.missingLocal;
    } on CredentialFailure catch (failure) {
      return RecordCredentialResult(workflow.record, _status(failure));
    }
    if (reconcile) {
      await workflow.refresh();
    } else {
      await workflow.validate();
    }
    return RecordCredentialResult(workflow.record, status);
  }

  void _requireReconciled(CredentialReference reference) {
    if (_credentials.requiresReconciliation(reference)) {
      throw const RecordCredentialFailure(
        RecordCredentialFailureKind.reconciliationRequired,
      );
    }
  }

  Future<bool> _readBound(
    _RecordCredentialWorkflow workflow, {
    bool reconcile = false,
  }) async {
    final protected = await _credentials.read(
      workflow.requireReference(),
      validate: (value) => _validateBound(workflow, value),
      reconcile: reconcile,
    );
    return protected != null;
  }

  void _validateBound(
    _RecordCredentialWorkflow workflow,
    CredentialSecret protected,
  ) {
    try {
      final value = jsonDecode(protected.reveal());
      final binding = workflow.binding(workflow.requireReference());
      if (value is! Map<String, dynamic> ||
          value.length != binding.length + 1) {
        throw const FormatException();
      }
      for (final entry in binding.entries) {
        if (value[entry.key] != entry.value ||
            (entry.key == 'version' && value[entry.key] is! int)) {
          throw const FormatException();
        }
      }
      CredentialSecret(value['secret'] as String);
    } on Object {
      // Never retain decoder errors: FormatException may contain the input.
      throw const CredentialFailure(CredentialFailureKind.corruptData);
    }
  }

  Future<RecordCredentialResult> _admit(
    RecordView record,
    RecordCredentialSlotId slot,
    Future<RecordCredentialResult> Function(_RecordCredentialWorkflow)
    operation,
  ) {
    if (_closing != null || _settings._closing != null) {
      return Future.error(
        const RecordCredentialFailure(RecordCredentialFailureKind.closed),
      );
    }
    if (!identical(record._owner, _settings._identity)) {
      return Future.error(
        const RecordCredentialFailure(RecordCredentialFailureKind.staleRecord),
      );
    }
    final key = (record.collection, record.id);
    if (!_active.add(key)) {
      return Future.error(
        const RecordCredentialFailure(RecordCredentialFailureKind.busy),
      );
    }
    final result = _settings._pending
        .then(
          (_) => _settings._worker.exclusive(() async {
            final workflow = _RecordCredentialWorkflow(_settings, record, slot);
            try {
              await workflow.validate();
              return await operation(workflow);
            } on RecordCredentialFailure catch (error) {
              throw RecordCredentialFailure(
                error.kind,
                record: workflow.record,
              );
            } on CredentialFailure catch (error) {
              if (workflow.validationFailure case final failure?) {
                throw RecordCredentialFailure(failure);
              }
              throw RecordCredentialFailure(
                _failureKind(error),
                record: workflow.record,
              );
            } on ConfigurationConflictException {
              throw const RecordCredentialFailure(
                RecordCredentialFailureKind.staleRecord,
              );
            } on Object {
              // Filesystem/native/transport diagnostics must not reach presentation.
              throw const RecordCredentialFailure(
                RecordCredentialFailureKind.configurationFailure,
              );
            }
          }),
        )
        .whenComplete(() => _active.remove(key));
    final settled = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    _settings._pending = settled;
    _pending = settled;
    return result;
  }

  static RecordCredentialStatus _status(CredentialFailure failure) {
    if (failure.outcomeUncertain ||
        failure.kind == CredentialFailureKind.verificationRequired) {
      return RecordCredentialStatus.reconciliationRequired;
    }
    return switch (failure.kind) {
      CredentialFailureKind.unavailable => RecordCredentialStatus.unavailable,
      CredentialFailureKind.corruptData => RecordCredentialStatus.invalid,
      _ => RecordCredentialStatus.failed,
    };
  }

  static RecordCredentialFailureKind _failureKind(CredentialFailure failure) {
    if (failure.outcomeUncertain ||
        failure.kind == CredentialFailureKind.verificationRequired) {
      return RecordCredentialFailureKind.reconciliationRequired;
    }
    return switch (failure.kind) {
      CredentialFailureKind.invalidSecret =>
        RecordCredentialFailureKind.invalidSecret,
      CredentialFailureKind.unavailable =>
        RecordCredentialFailureKind.unavailable,
      CredentialFailureKind.corruptData => RecordCredentialFailureKind.invalid,
      CredentialFailureKind.missing => RecordCredentialFailureKind.missingLocal,
      _ => RecordCredentialFailureKind.storageFailure,
    };
  }

  /// Fence immediately, then drain admitted workflows before closing dependencies.
  /// A blocked OS unlock prompt cannot be canceled or rolled back by a timeout.
  Future<void> close() => _closing ??= _pending;
}

/// No native documents cross this boundary. Each request retains the same owner
/// and its private worker revision, even across a keyring wait.
final class _RecordCredentialWorkflow {
  _RecordCredentialWorkflow(this.settings, this.record, this.slot);

  final GlobalSettingsService settings;
  RecordView record;
  final RecordCredentialSlotId slot;
  late String owner;
  CredentialReference? reference;
  RecordCredentialFailureKind? validationFailure;

  Future<void> beforeMutation() async {
    try {
      await validate();
    } on Object catch (error) {
      // P1 sanitizes callback failures. Retain only the safe classification so
      // the association result still requests Reload, not keyring reconciliation.
      validationFailure = error is ConfigurationConflictException
          ? RecordCredentialFailureKind.staleRecord
          : RecordCredentialFailureKind.configurationFailure;
      rethrow;
    }
  }

  Future<Object?> _request(
    _Operation operation, {
    CredentialReference? reference,
  }) => settings._worker._request(
    _Request(
      owner: settings._owner,
      operation: operation,
      catalog: settings.catalog,
      records: settings.records,
      roots: settings._roots,
      revision: record._revision,
      collection: record.collection,
      recordType: record.type,
      recordId: record.id,
      credentialSlot: slot,
      credentialReference: reference,
    ),
  );

  Future<void> validate() async {
    final value =
        await _request(_Operation.inspectCredential) as _CredentialValues;
    owner = value.owner;
    reference = value.reference;
  }

  Future<void> setReference(CredentialReference? value) async {
    final saved =
        await _request(_Operation.setCredentialReference, reference: value)
            as _RecordValues;
    record = RecordView._(settings._identity, saved);
    reference = value;
  }

  Future<void> refresh() async {
    final saved = await _request(_Operation.refreshRecord) as _RecordValues;
    record = RecordView._(settings._identity, saved);
  }

  CredentialReference requireReference() =>
      reference ??
      (throw const RecordCredentialFailure(
        RecordCredentialFailureKind.noReference,
      ));

  Map<String, Object> binding(CredentialReference reference) => {
    'version': 1,
    'owner': owner,
    'type': record.type.value,
    'collection': record.collection.value,
    'record': record.id.value,
    'slot': slot.value,
    'reference': reference.value,
  };

  CredentialSecret payload(
    CredentialReference reference,
    CredentialSecret secret,
  ) => CredentialSecret(
    jsonEncode({...binding(reference), 'secret': secret.reveal()}),
  );
}
