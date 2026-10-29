import 'dart:isolate';

import 'package:adele_credential_store/adele_credential_store.dart';

import 'credential_service.dart';

CredentialService createNativeCredentialService() =>
    CredentialService(const NativeCredentialStorageAdapter());

/// Trusted-host adapter. Construction performs no native call or keyring access.
/// Each admitted operation uses a background isolate and an explicitly owned
/// native store. Neither a failed initialization nor a decrypted value is cached.
final class NativeCredentialStorageAdapter implements CredentialStorageAdapter {
  const NativeCredentialStorageAdapter();

  @override
  Future<bool> contains(CredentialReference reference) =>
      _run(() => NativeCredentialStore.contains(reference.value));

  @override
  Future<String?> read(CredentialReference reference) =>
      _run(() => NativeCredentialStore.read(reference.value));

  @override
  Future<void> write(CredentialReference reference, CredentialSecret secret) =>
      _run(() => NativeCredentialStore.write(reference.value, secret.reveal()));

  @override
  Future<void> delete(CredentialReference reference) =>
      _run(() => NativeCredentialStore.delete(reference.value));

  Future<T> _run<T>(T Function() operation) async {
    try {
      return await Isolate.run(operation);
    } on NativeCredentialFailure catch (error) {
      throw CredentialFailure(switch (error.kind) {
        NativeCredentialFailureKind.invalidReference =>
          CredentialFailureKind.invalidReference,
        NativeCredentialFailureKind.invalidSecret =>
          CredentialFailureKind.invalidSecret,
        NativeCredentialFailureKind.unavailable =>
          CredentialFailureKind.unavailable,
        NativeCredentialFailureKind.corruptData =>
          CredentialFailureKind.corruptData,
        NativeCredentialFailureKind.failed => CredentialFailureKind.failed,
      });
    } on Object {
      // Includes asset loading/isolate failures; never forward their details.
      throw const CredentialFailure(CredentialFailureKind.failed);
    }
  }
}
