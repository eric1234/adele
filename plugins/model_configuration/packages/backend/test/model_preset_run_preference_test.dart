import 'package:adele_model_provider/adele_model_catalog.dart';
import 'package:adele_model_provider/adele_model_provider.dart';
import 'package:adele_orchestration/adele_orchestration.dart';
import 'package:model_configuration_backend/model_configuration_backend.dart';
import 'package:model_configuration_contract/model_configuration_contract.dart';
import 'package:test/test.dart';

void main() {
  late _Sources sources;
  late ModelPresetRunPreferenceBackend backend;
  setUp(() {
    sources = _Sources();
    backend = ModelPresetRunPreferenceBackend(sources, sources);
  });
  tearDown(() => expect(sources.writes, 0));

  test(
    'untouched and cleared selections abstain without reading records',
    () async {
      sources.observe = () => throw StateError(_private);
      for (final revision in [0, 3]) {
        sources.selection = _selection(null, revision: revision);
        expect(await backend.captureRun('session', 'run-$revision'), isNull);
      }
      expect(sources.sessionReads, ['session', 'session']);
      expect(sources.catalogReads, 0);
    },
  );

  test(
    'invalid Session or Run identity is rejected before selection',
    () async {
      for (final (session, run) in [
        ('', 'run'),
        (' session', 'run'),
        ('session', ''),
        ('session', 'run '),
      ]) {
        await expectLater(
          backend.captureRun(session, run),
          throwsFormatException,
        );
      }
      expect(sources.sessionReads, isEmpty);
      expect(sources.catalogReads, 0);
    },
  );

  test('even a null selection must belong to the requested Session', () async {
    sources.selection = _selection(null, session: 'other');
    await expectLater(
      backend.captureRun('session', 'run'),
      _stateFailure('Model Preset selection does not match the Session.'),
    );
    expect(sources.catalogReads, 0);
  });

  test(
    'returns exact authored configuration without provider or credential lookup',
    () async {
      final efforts = [null, ...ModelReasoningEffort.values];
      for (final (i, effort) in efforts.indexed) {
        sources.observe = () => _catalog([
          // Same editable name, different record ID.
          _preset(id: 'other', model: 'do-not-use'),
          _preset(effort: effort?.name),
        ], complete: false);
        final result = (await backend.captureRun('session', 'run-$i'))!;
        expect(result.providerId, _unregisteredProvider);
        expect(result.modelId, _model);
        expect(result.reasoningEffort, effort?.name);
        expect(sources.catalogReads, i + 1);
        expect(sources.sessionReads, List.filled(i + 1, 'session'));
      }
    },
  );

  test(
    'invalid authored provider or model cannot become an abstention or be repaired',
    () async {
      for (final (provider, model) in [
        ('', _model),
        (' $_unregisteredProvider', _model),
        (_unregisteredProvider.toUpperCase(), _model),
        (_private, _model),
        ('a.${'b' * RunModelPreference.maxProviderIdLength}', _model),
        (_unregisteredProvider, ''),
        (_unregisteredProvider, '  '),
        (_unregisteredProvider, '$_private\nmodel'),
        (_unregisteredProvider, 'x' * (modelCatalogMaxModelIdLength + 1)),
      ]) {
        sources.observe = () =>
            _catalog([_preset(provider: provider, model: model)]);
        await expectLater(
          backend.captureRun('session', 'run'),
          throwsA(
            isA<RunModelPreferenceFailure>()
                .having(
                  (f) => f.kind,
                  'kind',
                  RunModelPreferenceFailureKind.malformed,
                )
                .having(
                  (f) => f.toString(),
                  'safe diagnostic',
                  'Malformed Run model preference.',
                ),
          ),
        );
      }
    },
  );

  test(
    'deletion leaves the stored ID unresolved until it is observed again',
    () async {
      final original = (await backend.captureRun('session', 'run-a'))!;
      final stored = sources.selection;
      for (final complete in [true, false]) {
        sources.observe = () =>
            _catalog([_preset(id: 'other')], complete: complete);
        await expectLater(
          backend.captureRun('session', 'run-without-definition'),
          _stateFailure(
            complete
                ? 'The selected Model Preset does not exist.'
                : 'The selected Model Preset was not observed in the incomplete catalog.',
          ),
        );
      }
      sources.observe = () => _catalog([_preset(model: 'new-model')]);
      final recreated = (await backend.captureRun('session', 'run-b'))!;
      expect(recreated.modelId, 'new-model');
      expect(original.modelId, _model);
      expect(sources.catalogReads, 4);
      expect(sources.selection, same(stored));
    },
  );

  test(
    'read failures discard private diagnostics and never use a previous result',
    () async {
      expect(await backend.captureRun('session', 'first'), isNotNull);
      sources.selectionFailure = StateError(_private);
      await expectLater(
        backend.captureRun('session', 'selection-failure'),
        _stateFailure('Model Preset selection could not be read.'),
      );
      expect(sources.catalogReads, 1);
      sources.selectionFailure = null;
      sources.observe = () => throw StateError(_private);
      await expectLater(
        backend.captureRun('session', 'catalog-failure'),
        _stateFailure('Model Preset configuration could not be read.'),
      );
      expect(sources.catalogReads, 2);
    },
  );

  test('malformed definition or ambiguous selected ID fails closed', () async {
    sources.observe = () => _catalog([_preset(effort: _private)]);
    await expectLater(
      backend.captureRun('session', 'bad-definition'),
      _stateFailure('Model Preset configuration could not be read.'),
    );
    sources.observe = () => _catalog([_preset(), _preset(model: _private)]);
    await expectLater(
      backend.captureRun('session', 'ambiguous'),
      throwsA(
        isA<StateError>().having(
          (e) => e.toString(),
          'safe diagnostic',
          isNot(contains(_private)),
        ),
      ),
    );
  });
}

const _private = '/private/records SELECT credential-reference';
const _unregisteredProvider = 'dev.adele.unregistered.account-42';
const _model = '  Org/Model.v2+Fine:Tuned@beta  ';

Matcher _stateFailure(String message) => throwsA(
  isA<StateError>().having((e) => e.message, 'safe diagnostic', message),
);

ModelPresetDefinition _preset({
  String id = 'review',
  String provider = _unregisteredProvider,
  String model = _model,
  String? effort,
}) => ModelPresetDefinition(
  presetId: id,
  name: 'review',
  description: _private,
  model: ModelPresetModelReference(providerId: provider, modelId: model),
  reasoningEffort: effort,
);

ModelPresetCatalogSnapshot _catalog(
  List<ModelPresetDefinition> records, {
  bool complete = true,
}) => ModelPresetCatalogSnapshot(presets: records, isComplete: complete);

ModelPresetSelectionSnapshot _selection(
  String? id, {
  String session = 'session',
  int revision = 1,
}) => ModelPresetSelectionSnapshot(
  sessionId: session,
  selectedPresetId: id,
  revision: revision,
);

final class _Sources
    implements ModelPresetCatalogService, ModelPresetSelectionService {
  ModelPresetSelectionSnapshot selection = _selection('review');
  Object? selectionFailure;
  ModelPresetCatalogSnapshot Function() observe = () => _catalog([_preset()]);
  final sessionReads = <String>[];
  int catalogReads = 0;
  int writes = 0;

  @override
  Future<ModelPresetCatalogSnapshot> readPresets() async {
    catalogReads++;
    return observe();
  }

  @override
  Future<ModelPresetSelectionSnapshot> readSessionSelection(
    String sessionId,
  ) async {
    sessionReads.add(sessionId);
    if (selectionFailure case final error?) throw error;
    return selection;
  }

  @override
  Future<ModelPresetSelectionSnapshot> updateSessionSelection(
    String sessionId,
    String? selectedPresetId,
    int expectedRevision,
  ) async {
    writes++;
    throw UnsupportedError('Capture must never change the stored selection.');
  }
}
