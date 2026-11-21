import 'package:adele_orchestration/adele_orchestration.dart';
import 'package:adele_orchestration/remote_run_model_preference.dart';
import 'package:model_configuration_contract/model_configuration_contract.dart';

/// Captures authored values only. The host resolves and retains the Run binding.
final class ModelPresetRunPreferenceBackend
    implements RemoteRunModelPreferenceService {
  const ModelPresetRunPreferenceBackend(this._selection, this._catalog);

  final ModelPresetSelectionService _selection;
  final ModelPresetCatalogService _catalog;

  @override
  Future<RemoteRunModelPreference?> captureRun(
    String sessionId,
    String runId,
  ) async {
    SessionId(sessionId);
    RunId(runId);

    final ModelPresetSelectionSnapshot selection;
    try {
      selection = await _selection.readSessionSelection(sessionId);
    } on Object {
      throw StateError('Model Preset selection could not be read.');
    }
    if (selection.sessionId != sessionId) {
      throw StateError('Model Preset selection does not match the Session.');
    }
    final selectedId = selection.selectedPresetId;
    if (selectedId == null) return null;

    final ModelPresetCatalogSnapshot catalog;
    try {
      catalog = await _catalog.readPresets();
    } on Object {
      throw StateError('Model Preset configuration could not be read.');
    }
    final preset = catalog.presets.singleWhere(
      (p) => p.presetId == selectedId,
      orElse: () => throw StateError(
        catalog.isComplete
            ? 'The selected Model Preset does not exist.'
            : 'The selected Model Preset was not observed in the incomplete catalog.',
      ),
    );
    // The public value enforces ProviderId, exact model and effort semantics.
    return RemoteRunModelPreference(
      providerId: preset.providerId,
      modelId: preset.modelId,
      reasoningEffort: preset.reasoningEffort,
    );
  }
}
