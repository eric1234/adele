import 'dart:io';

import 'package:adele_platform_storage/adele_platform_storage.dart';
import 'package:adele_plugin_backend_support/backend_local_state.dart';

/// Application-private, path-only lookup for one exact backend generation.
final class BackendLocalStateHost implements BackendLocalStateService {
  BackendLocalStateHost({
    required this.validateAccess,
    String Function()? localStateRoot,
  }) : _localStateRoot = localStateRoot ?? _resolveLocalStateRoot;

  final void Function() validateAccess;
  final String Function() _localStateRoot;

  @override
  Future<String> getLocalStateRoot() async {
    // Dispatchers can queue a request beyond transport admission and revocation.
    validateAccess();
    try {
      return _localStateRoot();
    } catch (_) {
      // Platform validation errors may contain private environment/path values.
      throw StateError('The backend local-state root is unavailable.');
    }
  }
}

String _resolveLocalStateRoot() => PlatformStorageRoots.resolve(
  operatingSystem: Platform.operatingSystem,
  environment: Platform.environment,
).localStateRoot;
