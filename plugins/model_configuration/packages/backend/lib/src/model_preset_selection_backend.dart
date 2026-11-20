import 'package:adele_project_storage/adele_project_storage.dart';
import 'package:model_configuration_contract/model_configuration_contract.dart';

final class ModelPresetSelectionBackend implements ModelPresetSelectionService {
  const ModelPresetSelectionBackend(this._storage, this._catalog);

  final ProjectStorageService _storage;
  final ModelPresetCatalogService _catalog;

  static const _mode = ProjectStorageAccessMode.durableOrTemporary;
  static const _schema =
      '''
CREATE TABLE adele_model_preset_selections (
  session_id TEXT NOT NULL PRIMARY KEY REFERENCES adele_product_sessions(id),
  selected_preset_id TEXT CHECK (
    selected_preset_id IS NULL OR typeof(selected_preset_id) = 'text'),
  revision INTEGER NOT NULL CHECK (
    typeof(revision) = 'integer' AND
    revision BETWEEN 1 AND ${ModelPresetSelectionLimits.maxRevision})
);
''';

  @override
  Future<ModelPresetSelectionSnapshot> readSessionSelection(
    String sessionId,
  ) async {
    final ModelPresetSelectionSnapshot empty;
    try {
      empty = ModelPresetSelectionSnapshot(
        sessionId: sessionId,
        selectedPresetId: null,
        revision: 0,
      );
    } on FormatException {
      throw _failure('invalid_request', 'Invalid Session identity.');
    }
    final List<RelationalRow> rows;
    try {
      await _storage.ensureSchemaForSession(sessionId, [_schema], _mode);
      rows = await _storage.queryForSession(
        sessionId,
        '''SELECT session_id, selected_preset_id, revision FROM adele_model_preset_selections
           WHERE session_id = :session LIMIT 2''',
        {':session': sessionId},
        _mode,
      );
    } on Object {
      throw _failure(
        'storage_unavailable',
        'Model Preset selection storage is unavailable.',
      );
    }
    if (rows.isEmpty) return empty;
    final row = rows.first.values;
    final revision = row['revision'];
    final preset = row['selected_preset_id'];
    try {
      if (rows.length != 1 ||
          row.length != 3 ||
          row['session_id'] != sessionId ||
          !row.containsKey('selected_preset_id') ||
          preset is! String? ||
          revision is! int ||
          revision < 1) {
        throw const FormatException();
      }
      return ModelPresetSelectionSnapshot(
        sessionId: sessionId,
        selectedPresetId: preset,
        revision: revision,
      );
    } on FormatException {
      throw _failure(
        'corrupt_state',
        'Stored Model Preset selection is invalid.',
      );
    }
  }

  @override
  Future<ModelPresetSelectionSnapshot> updateSessionSelection(
    String sessionId,
    String? selectedPresetId,
    int expectedRevision,
  ) async {
    final ModelPresetSelectionSnapshot next;
    const max = ModelPresetSelectionLimits.maxRevision;
    try {
      if (expectedRevision < 0 || expectedRevision > max) {
        throw const FormatException();
      }
      next = ModelPresetSelectionSnapshot(
        sessionId: sessionId,
        selectedPresetId: selectedPresetId,
        revision: expectedRevision == max ? max : expectedRevision + 1,
      );
    } on FormatException {
      throw _failure(
        'invalid_request',
        'Invalid Model Preset selection request.',
      );
    }
    final current = await readSessionSelection(sessionId);
    if (current.revision != expectedRevision) {
      throw _failure(
        'stale_revision',
        'Model Preset selection changed. Read it again.',
      );
    }
    if (expectedRevision == max) {
      throw _failure(
        'revision_exhausted',
        'Model Preset selection revision limit reached.',
      );
    }
    if (selectedPresetId != null) {
      final ModelPresetCatalogSnapshot catalog;
      try {
        catalog = await _catalog.readPresets();
      } on ModelPresetCatalogFailure {
        throw _failure(
          'catalog_unavailable',
          'Model Preset configuration could not be read.',
        );
      }
      if (!catalog.presets.any((p) => p.presetId == selectedPresetId)) {
        throw catalog.isComplete
            ? _failure(
                'preset_not_found',
                'The requested Model Preset does not exist.',
              )
            : _failure(
                'catalog_incomplete',
                'The Model Preset catalog observation is incomplete.',
              );
      }
    }
    final change = RelationalStatement(
      sql: expectedRevision == 0
          ? '''INSERT INTO adele_model_preset_selections (session_id, selected_preset_id, revision)
             VALUES (:session, :preset, :next)'''
          : '''UPDATE adele_model_preset_selections SET selected_preset_id = :preset, revision = :next
             WHERE session_id = :session AND revision = :expected''',
      parameters: {
        ':session': sessionId,
        ':preset': selectedPresetId,
        ':next': next.revision,
        if (expectedRevision != 0) ':expected': expectedRevision,
      },
      expectedRows: 1,
    );
    try {
      await _storage.transactionForSession(sessionId, [change], _mode);
    } on Object {
      // The transport cannot distinguish a CAS loser from a lost commit reply.
      throw _failure(
        'outcome_uncertain',
        'The selection write was not acknowledged. Read it before another change.',
      );
    }
    return next;
  }
}

ModelPresetSelectionFailure _failure(String code, String message) =>
    ModelPresetSelectionFailure(code: code, message: message);
