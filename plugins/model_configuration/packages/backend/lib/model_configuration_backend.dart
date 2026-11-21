import 'package:adele_plugin_backend_support/adele_plugin_backend_support.dart';
import 'package:model_configuration_contract/model_configuration_contract.dart';

export 'src/model_preset_run_preference_backend.dart';
export 'src/model_preset_selection_backend.dart';

/// Projects one fresh observation from the captured infrastructure grant.
final class ModelPresetCatalogBackend implements ModelPresetCatalogService {
  const ModelPresetCatalogBackend(this._configuration);

  final AdeleConfigurationClient _configuration;

  @override
  Future<ModelPresetCatalogSnapshot> readPresets() async {
    final AdeleRecordObservation observation;
    try {
      observation = await _configuration.currentRecords();
    } on AdeleConfigurationFailure {
      throw const ModelPresetCatalogFailure(
        code: 'unavailable',
        message: 'Model Preset configuration could not be read.',
      );
    }
    try {
      final presets = observation.records.map(_project).toList()
        ..sort((a, b) => a.presetId.compareTo(b.presetId));
      return ModelPresetCatalogSnapshot(
        presets: presets,
        isComplete: observation.isComplete,
      );
    } on FormatException {
      throw _invalidObservation;
    }
  }
}

const _invalidObservation = ModelPresetCatalogFailure(
  code: 'invalid_observation',
  message: 'Unexpected Model Preset record in the configuration observation.',
);

ModelPresetDefinition _project(Map<String, Object> record) {
  if (record['type'] != 'dev.adele.plugin.model-configuration.preset' ||
      record['collection'] != 'model-presets') {
    throw _invalidObservation;
  }
  final values = record['values'] as Map<String, Object>;
  final name = values['name'];
  final provider = values['provider-id'];
  final model = values['model-id'];
  final description = values['description'];
  final effort = values['reasoning-effort'];
  if (name is! String ||
      provider is! String ||
      model is! String ||
      description is! String? ||
      effort is! String? ||
      !const {
        'name',
        'provider-id',
        'model-id',
        'description',
        'reasoning-effort',
      }.containsAll(values.keys)) {
    throw _invalidObservation;
  }
  return ModelPresetDefinition(
    presetId: record['id'] as String,
    name: name,
    providerId: provider,
    modelId: model,
    description: description,
    reasoningEffort: effort,
  );
}
