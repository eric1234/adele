/// Optional provider-neutral model discovery, separate from inference.
library;

import 'package:adele_capabilities/adele_capabilities.dart' as capabilities;
import 'package:adele_contract/adele_contract.dart';

part 'adele_model_catalog.g.dart';

final capabilities.CapabilityKey modelCatalogCapability =
    capabilities.CapabilityKey(
      id: capabilities.CapabilityId('dev.adele.model.catalog'),
      majorVersion: 1,
    );

const int modelCatalogMaxModels = 1024;
const int modelCatalogMaxModelIdLength = 1024;
const int modelCatalogMaxDisplayNameLength = 256;
const int modelCatalogMaxDescriptionLength = 4096;

/// Aggregate UTF-16 text bound, leaving room for JSON escaping and envelopes.
const int modelCatalogMaxTextLength = 1024 * 1024;

/// Provider-reported metadata, not proof of text/tool inference compatibility.
@AdeleValue('modelCatalog.entry')
final class ModelCatalogEntry {
  ModelCatalogEntry({
    required this.modelId,
    required this.displayName,
    required this.description,
  }) {
    _validateText(modelId, modelCatalogMaxModelIdLength, 'Model ID');
    if (modelId.codeUnits.any((unit) => unit < 0x20 || unit == 0x7f)) {
      throw const FormatException(
        'Model ID must not contain control characters.',
      );
    }
    if (displayName != null) {
      _validateText(
        displayName!,
        modelCatalogMaxDisplayNameLength,
        'Model display name',
      );
    }
    if (description != null) {
      _validateText(
        description!,
        modelCatalogMaxDescriptionLength,
        'Model description',
      );
    }
  }

  /// Exact provider inference identifier, preserved without normalization.
  final String modelId;
  final String? displayName;
  final String? description;
}

/// One finite observation; empty success is distinct from failed discovery.
@AdeleValue('modelCatalog.snapshot')
final class ModelCatalogSnapshot {
  ModelCatalogSnapshot({required List<ModelCatalogEntry> models})
    : models = List<ModelCatalogEntry>.unmodifiable(models) {
    if (this.models.length > modelCatalogMaxModels) {
      throw const FormatException(
        'Model catalog exceeds the model count limit.',
      );
    }
    final Set<String> ids = <String>{};
    var textLength = 0;
    for (final ModelCatalogEntry model in this.models) {
      if (!ids.add(model.modelId)) {
        throw const FormatException(
          'Model catalog contains duplicate model IDs.',
        );
      }
      textLength +=
          model.modelId.length +
          (model.displayName?.length ?? 0) +
          (model.description?.length ?? 0);
      if (textLength > modelCatalogMaxTextLength) {
        throw const FormatException(
          'Model catalog exceeds the total text limit.',
        );
      }
    }
  }

  final List<ModelCatalogEntry> models;
}

@AdeleService('modelCatalog')
abstract interface class ModelCatalogService {
  /// Observes the exact resolved configured route, with no account selector.
  /// Repeated calls may observe changes; a snapshot promises no future availability.
  @AdeleMethod('listModels')
  Future<ModelCatalogSnapshot> listModels();
}

/// Safe semantic discovery failure, not resolution or malformed-wire failure.
///
/// Codes: `authentication`, `rate_limited`, `unsupported_discovery`,
/// `unavailable`, `transport`, `malformed_response`, and `provider_failure`.
/// Providers must use caller-safe messages and empty details, never raw exceptions,
/// credentials, endpoints, response bodies, or other sensitive provider diagnostics.
/// Unexpected exceptions retain generated opaque `internal_error` behavior.
@AdeleFailure('modelCatalog.failure')
final class ModelCatalogFailure implements Exception {
  const ModelCatalogFailure({
    required this.code,
    required this.message,
    this.details = const <String, Object?>{},
  });

  final String code;
  final String message;
  final Map<String, Object?> details;

  @override
  String toString() => 'ModelCatalogFailure($code): $message';
}

void _validateText(String value, int maxLength, String label) {
  if (value.length > maxLength ||
      value.trim().isEmpty ||
      value.contains('\u0000')) {
    throw FormatException(
      '$label must be nonblank, bounded, and contain no NUL.',
    );
  }
}
