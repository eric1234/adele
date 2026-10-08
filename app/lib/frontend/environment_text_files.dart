import 'package:adele_capabilities/adele_capabilities.dart';
import 'package:adele_environment/adele_environment.dart';
import 'package:adele_product/adele_product.dart';

import '../core/product_lifecycle.dart';

/// User-initiated text-file access to one canonical Session's Environment.
/// Capture before awaiting presentation work; construction is provider-free.
final class CapturedEnvironmentTextFiles {
  CapturedEnvironmentTextFiles({
    required Session session,
    required EnvironmentRuntime environmentRuntime,
  }) : _captured = CapturedSessionEnvironment(
         session: session,
         environmentRuntime: environmentRuntime,
       );

  final CapturedSessionEnvironment _captured;

  Session get session => _captured.session;
  Environment get environment => _captured.environment;
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
      final materialization = await _captured.materialize();
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
