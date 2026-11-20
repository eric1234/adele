/// Model Configuration's owning-backend services. Neither resolves a Run binding.
library;

import 'package:adele_contract/adele_contract.dart';
import 'package:adele_model_provider/adele_model_provider.dart' as model;
import 'package:adele_settings/adele_settings.dart' as settings;

part 'model_configuration_contract.g.dart';

@AdeleService('modelPresetCatalog')
abstract interface class ModelPresetCatalogService {
  @AdeleMethod('readPresets')
  Future<ModelPresetCatalogSnapshot> readPresets();
}

@AdeleValue('modelPresetCatalog.definition')
final class ModelPresetDefinition {
  ModelPresetDefinition({
    required this.presetId,
    required this.name,
    required this.description,
    required this.providerId,
    required this.modelId,
    required this.reasoningEffort,
  }) {
    _validatePresetId(presetId);
    if (reasoningEffort != null &&
        !model.ModelReasoningEffort.values.any(
          (e) => e.name == reasoningEffort,
        )) {
      throw const FormatException('Invalid Model Preset reasoning effort.');
    }
  }

  final String presetId;
  final String name;
  final String? description;
  final String providerId;
  final String modelId;

  /// Canonical effort name, or null when no effort was authored.
  final String? reasoningEffort;
}

void _validatePresetId(String id) {
  try {
    settings.ConfigurationRecordId(id);
  } on FormatException {
    throw const FormatException('Invalid Model Preset record ID.');
  }
}

@AdeleValue('modelPresetCatalog.snapshot')
final class ModelPresetCatalogSnapshot {
  ModelPresetCatalogSnapshot({
    required List<ModelPresetDefinition> presets,
    required this.isComplete,
  }) : presets = List<ModelPresetDefinition>.unmodifiable(presets);

  /// Current definitions in stable record ID order; names need not be unique.
  final List<ModelPresetDefinition> presets;

  /// False when records were omitted, even if [presets] is empty.
  final bool isComplete;
}

@AdeleFailure('modelPresetCatalog.failure')
final class ModelPresetCatalogFailure implements Exception {
  const ModelPresetCatalogFailure({
    required this.code,
    required this.message,
    this.details = const {},
  });

  final String code;
  final String message;
  final Map<String, Object?> details;
}

abstract final class ModelPresetSelectionLimits {
  static const int maxSessionIdLength = 512;
  static const int maxRevision = 2147483647;
}

@AdeleService('modelPresetSelection')
abstract interface class ModelPresetSelectionService {
  @AdeleMethod('readSessionSelection')
  Future<ModelPresetSelectionSnapshot> readSessionSelection(String sessionId);

  /// Null explicitly clears the selection. Reconcile an uncertain write by
  /// reading; never automatically retry it.
  @AdeleMethod('updateSessionSelection')
  Future<ModelPresetSelectionSnapshot> updateSessionSelection(
    String sessionId,
    String? selectedPresetId,
    int expectedRevision,
  );
}

@AdeleValue('modelPresetSelection.snapshot')
final class ModelPresetSelectionSnapshot {
  ModelPresetSelectionSnapshot({
    required this.sessionId,
    required this.selectedPresetId,
    required this.revision,
  }) {
    if (sessionId.isEmpty ||
        sessionId.trim() != sessionId ||
        sessionId.length > ModelPresetSelectionLimits.maxSessionIdLength ||
        revision < 0 ||
        revision > ModelPresetSelectionLimits.maxRevision ||
        (revision == 0 && selectedPresetId != null)) {
      throw const FormatException('Invalid Model Preset selection snapshot.');
    }
    if (selectedPresetId != null) _validatePresetId(selectedPresetId!);
  }

  final String sessionId;

  /// May identify a subsequently deleted preset. Null is no preference.
  final String? selectedPresetId;

  /// Zero denotes no stored row; an explicit clear has a positive revision.
  final int revision;
}

@AdeleFailure('modelPresetSelection.failure')
final class ModelPresetSelectionFailure implements Exception {
  const ModelPresetSelectionFailure({
    required this.code,
    required this.message,
    this.details = const {},
  });

  final String code;
  final String message;
  final Map<String, Object?> details;
}
