import 'package:adele_capabilities/adele_capabilities.dart';
import 'package:adele_environment/adele_environment.dart';
import 'package:adele_model_tool/adele_model_tool.dart';
import 'package:adele_plugin_api/adele_plugin_api.dart';
import 'package:adele_product/adele_product.dart';
import 'package:agent_kernel/agent_kernel.dart'
    show ModelToolComposer, ToolCatalog;

import 'product_lifecycle.dart';

Future<ToolCatalog> buildModelToolCatalogForSession({
  required SessionId sessionId,
  required EnvironmentRuntime environmentRuntime,
  required ExtensionRegistry extensions,
}) => ModelToolComposer(extensions).materialize(
  SessionModelToolHostContext(
    sessionId: sessionId,
    environmentRuntime: environmentRuntime,
  ),
);

final class SessionModelToolHostContext implements ModelToolHostContext {
  SessionModelToolHostContext({
    required this.sessionId,
    required EnvironmentRuntime environmentRuntime,
  }) : _environmentRuntime = environmentRuntime;

  @override
  final SessionId sessionId;
  final EnvironmentRuntime _environmentRuntime;

  @override
  Future<T> requireHostService<T extends Object>() async {
    if (T == AuthorizedEnvironmentFileSystem) {
      return await _environmentFileSystem() as T;
    }
    throw StateError('No Session host service is registered for $T.');
  }

  Future<AuthorizedEnvironmentFileSystem> _environmentFileSystem() async {
    final SessionEnvironmentAuthority authority = _environmentRuntime.store
        .requireSessionAuthority(sessionId);
    final EnvironmentMaterialization materialization = await _environmentRuntime
        .materialize(authority.environmentId);
    if (materialization.environment.taskId != authority.taskId) {
      throw StateError(
        'Session $sessionId has inconsistent Task and Environment authority.',
      );
    }
    return _SessionEnvironmentFileSystem(
      authority: authority,
      materialization: materialization,
    );
  }
}

final class _SessionEnvironmentFileSystem
    implements AuthorizedEnvironmentFileSystem {
  const _SessionEnvironmentFileSystem({
    required SessionEnvironmentAuthority authority,
    required EnvironmentMaterialization materialization,
  }) : _authority = authority,
       _materialization = materialization;

  final SessionEnvironmentAuthority _authority;
  final EnvironmentMaterialization _materialization;

  @override
  SessionId get sessionId => _authority.sessionId;

  @override
  EnvironmentId get environmentId => _authority.environmentId;

  @override
  void validateBinding() {
    try {
      _materialization.validateBinding();
    } on ProviderUnavailable catch (error) {
      if (error.stale) {
        throw AuthorizedEnvironmentBindingStale(
          'The authorized Environment provider generation is stale.',
          cause: error,
        );
      }
      throw AuthorizedEnvironmentBindingUnavailable(
        'The authorized Environment provider is unavailable.',
        cause: error,
      );
    } on ProviderEndpointUnavailable catch (error) {
      throw AuthorizedEnvironmentBindingUnavailable(
        'The authorized Environment provider endpoint is unavailable.',
        cause: error,
      );
    }
  }

  @override
  Future<EnvironmentTextFile> readFile(String relativePath) async {
    validateBinding();
    try {
      return await _materialization.provider.readFile(
        _authority.environmentId,
        relativePath,
      );
    } on ProviderUnavailable catch (error) {
      if (error.stale) {
        throw AuthorizedEnvironmentBindingStale(
          'The authorized Environment provider generation is stale.',
          cause: error,
        );
      }
      throw AuthorizedEnvironmentBindingUnavailable(
        'The authorized Environment provider is unavailable.',
        cause: error,
      );
    } on ProviderEndpointUnavailable catch (error) {
      throw AuthorizedEnvironmentBindingUnavailable(
        'The authorized Environment provider endpoint is unavailable.',
        cause: error,
      );
    }
  }

  @override
  Future<EnvironmentDirectoryListing> readDirectory(String relativePath) async {
    validateBinding();
    try {
      return await _materialization.provider.readDirectory(
        _authority.environmentId,
        relativePath,
      );
    } on ProviderUnavailable catch (error) {
      if (error.stale) {
        throw AuthorizedEnvironmentBindingStale(
          'The authorized Environment provider generation is stale.',
          cause: error,
        );
      }
      throw AuthorizedEnvironmentBindingUnavailable(
        'The authorized Environment provider is unavailable.',
        cause: error,
      );
    } on ProviderEndpointUnavailable catch (error) {
      throw AuthorizedEnvironmentBindingUnavailable(
        'The authorized Environment provider endpoint is unavailable.',
        cause: error,
      );
    }
  }
}
