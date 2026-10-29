import 'dart:convert';
import 'dart:math';

/// A persistable association identity, NOT a grant to read a credential.
///
/// Independent of plugin, record, account, display name and runtime generation.
/// Only trusted host code may use this app-private API.
final class CredentialReference {
  CredentialReference._(this.value);

  factory CredentialReference.generate() {
    final random = Random.secure();
    return CredentialReference._(
      'cred1_${List.generate(16, (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0')).join()}',
    );
  }

  factory CredentialReference.parse(String value) {
    if (value.length != 38 || !_format.hasMatch(value)) {
      throw const CredentialFailure(CredentialFailureKind.invalidReference);
    }
    return CredentialReference._(value);
  }

  static final _format = RegExp(r'^cred1_[0-9a-f]{32}$');
  final String value;

  @override
  bool operator ==(Object other) =>
      other is CredentialReference && value == other.value;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => value;
}

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

  /// No secret material is returned. An adapter may read one entry internally.
  /// Confirmed absence reconciles an uncertain mutation; presence alone cannot
  /// verify replacement contents.
  Future<bool> contains(CredentialReference reference) => _admit(() async {
    final present = await _storage.contains(reference);
    if (!present) _uncertain.remove(reference);
    return present;
  });

  /// Trusted-host-only retrieval. A successful read reconciles uncertain work.
  /// A missing credential on this machine does not invalidate its reference.
  Future<CredentialSecret?> read(CredentialReference reference) =>
      _admit(() async {
        final value = await _read(reference);
        _uncertain.remove(reference);
        return value;
      });

  /// Establish a fresh association. The caller allocates/retains the reference
  /// before admission so even an unacknowledged create can be reconciled.
  Future<void> store(CredentialReference reference, CredentialSecret secret) =>
      _admit(() => _write(reference, secret, replacing: false));

  Future<void> replace(
    CredentialReference reference,
    CredentialSecret secret,
  ) => _admit(() => _write(reference, secret, replacing: true));

  /// Already missing is a confirmed no-op. No other credential is touched.
  Future<void> delete(CredentialReference reference) => _admit(() async {
    _requireVerified(reference);
    if (!await _storage.contains(reference)) return;
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
    await _mutation(reference, () async {
      await _storage.write(reference, secret);
      if ((await _read(reference))?.reveal() != secret.reveal()) {
        throw const CredentialFailure(CredentialFailureKind.failed);
      }
    });
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
