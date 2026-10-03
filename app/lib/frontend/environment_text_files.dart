import 'package:adele_capabilities/adele_capabilities.dart';
import 'package:adele_environment/adele_environment.dart';
import 'package:adele_product/adele_product.dart';

import '../core/product_lifecycle.dart';

/// User-initiated text-file access to one canonical Session's Environment.
/// Capture before awaiting presentation work; construction is provider-free.
final class CapturedEnvironmentTextFiles {
  factory CapturedEnvironmentTextFiles({
    required Session session,
    required EnvironmentRuntime environmentRuntime,
  }) {
    final store = environmentRuntime.store;
    if (!identical(store.session(session.id), session)) {
      throw ArgumentError('Text-file access requires the canonical Session.');
    }
    final authority = store.requireSessionAuthority(session.id);
    final task = store.task(session.taskId);
    final environment = store.environment(authority.environmentId);
    if (task == null ||
        store.project(task.projectId) == null ||
        authority.sessionId != session.id ||
        authority.taskId != task.id ||
        environment == null ||
        environment.taskId != task.id) {
      throw StateError('Session Environment graph is not canonical.');
    }
    return CapturedEnvironmentTextFiles._(
      session,
      environment,
      environmentRuntime,
    );
  }

  CapturedEnvironmentTextFiles._(this.session, this.environment, this._runtime);

  final Session session;
  final Environment environment;
  final EnvironmentRuntime _runtime;
  Future<EnvironmentMaterialization>? _materialization;

  EnvironmentId get environmentId => environment.id;

  /// Identity for plugin context, not a caller-selectable authority token.
  String get environmentKey => environmentId.value;

  Future<EnvironmentTextFile> read(String relativePath) => _perform(
    (materialization) =>
        materialization.provider.readFile(environmentId, relativePath),
  );

  Future<EnvironmentTextFileReplacement> replace(
    String relativePath,
    String replacementText,
    String expectedRevision,
  ) => _perform(
    (materialization) => materialization.provider.replaceExistingTextFile(
      environmentId,
      relativePath,
      replacementText,
      expectedRevision,
    ),
  );

  Future<T> _perform<T>(
    Future<T> Function(EnvironmentMaterialization) operation,
  ) async {
    try {
      // Never re-materialize this capture, including after a failed first attempt.
      final materialization = await (_materialization ??= _runtime.materialize(
        environmentId,
      ));
      final current = materialization.environment;
      if (current.id != environmentId ||
          current.taskId != environment.taskId ||
          current.role != environment.role ||
          current.providerId != environment.providerId) {
        throw StateError('Materialization changed the captured Environment.');
      }
      materialization.validateBinding();
      return await operation(materialization);
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
    } on CapabilityUnavailable catch (error) {
      throw AuthorizedEnvironmentBindingUnavailable(
        'The authorized Environment provider is unavailable.',
        cause: error,
      );
    } on CapabilityVersionUnavailable catch (error) {
      throw AuthorizedEnvironmentBindingUnavailable(
        'The authorized Environment provider version is unavailable.',
        cause: error,
      );
    }
  }
}
