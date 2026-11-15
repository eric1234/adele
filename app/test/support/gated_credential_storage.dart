import 'dart:async';

import 'package:adele_desktop/core/credential_service.dart';

/// Holds an admitted storage operation while application shutdown drains its owner.
final class GatedCredentialStorage implements CredentialStorageAdapter {
  final entered = Completer<void>();
  final release = Completer<void>();
  var calls = 0;

  @override
  Future<bool> contains(CredentialReference reference) async {
    calls++;
    if (!entered.isCompleted) entered.complete();
    await release.future;
    return false;
  }

  @override
  Future<String?> read(CredentialReference reference) =>
      throw UnimplementedError();

  @override
  Future<void> write(CredentialReference reference, CredentialSecret secret) =>
      throw UnimplementedError();

  @override
  Future<void> delete(CredentialReference reference) =>
      throw UnimplementedError();
}
