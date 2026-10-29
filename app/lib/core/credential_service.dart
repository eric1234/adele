import 'dart:convert';

import 'package:adele_credential_store/credential_reference.dart';

export 'package:adele_credential_store/credential_reference.dart';

/// Bounded opaque text. Deliberate host retrieval is through [reveal], not logs.
/// Dart strings are not zeroizable and this is not host-process isolation.
final class CredentialSecret {
  CredentialSecret(String value) : _value = value {
    if (!_valid(value)) {
      throw const CredentialFailure(CredentialFailureKind.invalidSecret);
    }
  }

  static const maximumBytes = 2560;
  final String _value;

  static bool _valid(String value) {
    if (value.isEmpty ||
        value.length > maximumBytes ||
        value.contains('\x00')) {
      return false;
    }
    // Reject unpaired UTF-16 surrogates rather than letting UTF-8 replace them.
    for (var i = 0; i < value.length; i++) {
      final unit = value.codeUnitAt(i);
      if (unit >= 0xd800 && unit <= 0xdbff) {
        if (++i == value.length) return false;
        final next = value.codeUnitAt(i);
        if (next < 0xdc00 || next > 0xdfff) return false;
      } else if (unit >= 0xdc00 && unit <= 0xdfff) {
        return false;
      }
    }
    return utf8.encode(value).length <= maximumBytes;
  }

  String reveal() => _value;

  @override
  String toString() => 'CredentialSecret([REDACTED])';
}

enum CredentialFailureKind {
  invalidReference,
  invalidSecret,
  closed,
  missing,
  alreadyExists,
  unavailable,
  failed,
  corruptData,
  verificationRequired,
}

/// Safe bounded diagnostics: never retains a native message, details or cause.
final class CredentialFailure implements Exception {
  const CredentialFailure(this.kind, {this.outcomeUncertain = false});

  final CredentialFailureKind kind;

  /// A mutation was invoked but its persistent outcome could not be confirmed.
  /// This does not assert either rollback or success. Do not blindly retry.
  final bool outcomeUncertain;

  @override
  String toString() =>
      'CredentialFailure(${kind.name}, outcomeUncertain: $outcomeUncertain)';
}

/// Narrow host-owned seam. Implementations must throw on inaccessible storage;
/// null/false mean successfully established absence, never an OS failure.
abstract interface class CredentialStorageAdapter {
  Future<bool> contains(CredentialReference reference);
  Future<String?> read(CredentialReference reference);
  Future<void> write(CredentialReference reference, CredentialSecret secret);
  Future<void> delete(CredentialReference reference);
}

/// One explicit host owner's serialized, uncached credential operations.
///
/// Constructing/closing performs no storage I/O. This is NOT cross-process CAS,
/// an OAuth refresh store, or a transaction with configuration/TOML persistence.
final class CredentialService {
  CredentialService(this._storage);

  final CredentialStorageAdapter _storage;
  final Set<CredentialReference> _uncertain = {};
  Future<void> _pending = Future<void>.value();
  Future<void>? _closing;

  /// Local mutation fence only; querying it performs no OS access or retry.
  bool requiresReconciliation(CredentialReference reference) =>
      _uncertain.contains(reference);

  /// No secret material is returned. An adapter may read one entry internally.
  /// Confirmed absence reconciles an uncertain mutation; presence alone cannot
  /// verify replacement contents.
  Future<bool> contains(CredentialReference reference) => _admit(() async {
    final present = await _storage.contains(reference);
    if (!present) _uncertain.remove(reference);
    return present;
  });

  /// Trusted-host-only retrieval. A successful read reconciles uncertain work.
  /// A protected-payload owner validates its envelope before the fence clears.
  /// A missing credential on this machine does not invalidate its reference.
  Future<CredentialSecret?> read(
    CredentialReference reference, {
    void Function(CredentialSecret)? validate,
    bool reconcile = true,
  }) => _admit(() async {
    if (!reconcile) _requireVerified(reference);
    final value = await _read(reference);
    if (value != null) validate?.call(value);
    _uncertain.remove(reference);
    return value;
  });

  /// Establish a fresh association. The caller allocates/retains the reference
  /// before admission so even an unacknowledged create can be reconciled.
  Future<void> store(
    CredentialReference reference,
    CredentialSecret secret, {
    Future<void> Function()? beforeMutation,
  }) => _admit(
    () => _write(
      reference,
      secret,
      replacing: false,
      beforeMutation: beforeMutation,
    ),
  );

  Future<void> replace(
    CredentialReference reference,
    CredentialSecret secret, {
    void Function(CredentialSecret)? validateExisting,
    Future<void> Function()? beforeMutation,
  }) => _admit(
    () => _write(
      reference,
      secret,
      replacing: true,
      validateExisting: validateExisting,
      beforeMutation: beforeMutation,
    ),
  );

  /// Already missing is a confirmed no-op. No other credential is touched.
  Future<void> delete(
    CredentialReference reference, {
    void Function(CredentialSecret)? validateExisting,
    Future<void> Function()? beforeMutation,
  }) => _admit(() async {
    _requireVerified(reference);
    if (!await _storage.contains(reference)) return;
    await _validateExisting(reference, validateExisting);
    await beforeMutation?.call();
    await _mutation(reference, () async {
      await _storage.delete(reference);
      if (await _storage.contains(reference)) {
        throw const CredentialFailure(CredentialFailureKind.failed);
      }
    });
  });

  Future<CredentialSecret?> _read(CredentialReference reference) async {
    final value = await _storage.read(reference);
    if (value == null) return null;
    if (!CredentialSecret._valid(value)) {
      throw const CredentialFailure(CredentialFailureKind.corruptData);
    }
    return CredentialSecret(value);
  }

  Future<void> _write(
    CredentialReference reference,
    CredentialSecret secret, {
    required bool replacing,
    void Function(CredentialSecret)? validateExisting,
    Future<void> Function()? beforeMutation,
  }) async {
    _requireVerified(reference);
    final present = await _storage.contains(reference);
    if (present != replacing) {
      throw CredentialFailure(
        present
            ? CredentialFailureKind.alreadyExists
            : CredentialFailureKind.missing,
      );
    }
    await _validateExisting(reference, validateExisting);
    // A cross-service owner can revalidate after queue/preflight waits. A failed
    // guard has not invoked a mutation and must not create an uncertain fence.
    await beforeMutation?.call();
    await _mutation(reference, () async {
      await _storage.write(reference, secret);
      if ((await _read(reference))?.reveal() != secret.reveal()) {
        throw const CredentialFailure(CredentialFailureKind.failed);
      }
    });
  }

  Future<void> _validateExisting(
    CredentialReference reference,
    void Function(CredentialSecret)? validate,
  ) async {
    if (validate == null) return;
    final value = await _read(reference);
    if (value == null) {
      throw const CredentialFailure(CredentialFailureKind.missing);
    }
    // Recheck within this queue: another admitted host operation may have
    // changed the protected value since its association owner's earlier read.
    validate(value);
  }

  void _requireVerified(CredentialReference reference) {
    if (_uncertain.contains(reference)) {
      throw const CredentialFailure(
        CredentialFailureKind.verificationRequired,
        outcomeUncertain: true,
      );
    }
  }

  Future<void> _mutation(
    CredentialReference reference,
    Future<void> Function() operation,
  ) async {
    try {
      await operation();
    } on Object catch (error) {
      _uncertain.add(reference);
      throw CredentialFailure(
        error is CredentialFailure ? error.kind : CredentialFailureKind.failed,
        outcomeUncertain: true,
      );
    }
  }

  Future<T> _admit<T>(Future<T> Function() operation) {
    if (_closing != null) {
      return Future.error(
        const CredentialFailure(CredentialFailureKind.closed),
      );
    }
    final result = _pending.then((_) async {
      try {
        return await operation();
      } on CredentialFailure {
        rethrow;
      } on Object {
        throw const CredentialFailure(CredentialFailureKind.failed);
      }
    });
    _pending = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }

  /// Immediately fences new calls and drains all admitted work, including
  /// failures. Native calls are not canceled or automatically repeated.
  /// An OS unlock prompt can keep this pending; a timeout is not a rollback.
  Future<void> close() => _closing ??= _pending.then((_) => _uncertain.clear());
}
