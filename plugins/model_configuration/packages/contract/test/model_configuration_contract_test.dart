import 'package:adele_contract/adele_contract.dart';
import 'package:adele_model_provider/adele_model_provider.dart' as model;
import 'package:model_configuration_contract/model_configuration_contract.dart';
import 'package:test/test.dart';

void main() {
  test('empty observations preserve completeness', () async {
    expect(modelPresetCatalogServiceId, 'modelPresetCatalog');
    for (final complete in [false, true]) {
      final channel = _Channel({
        'presets': <Object?>[],
        'isComplete': complete,
      });
      final result = await ModelPresetCatalogServiceClient(
        channel,
      ).readPresets();
      expect(channel.calls.single.$1, 'modelPresetCatalog.readPresets');
      expect(channel.calls.single.$2, isEmpty);
      expect(result.presets, isEmpty);
      expect(result.isComplete, complete);
    }
  });

  test(
    'preserves canonical efforts, independent IDs and authored strings',
    () async {
      final efforts = [
        null,
        ...model.ModelReasoningEffort.values.map((e) => e.name),
      ];
      final records = [
        for (var i = 0; i < efforts.length; i++)
          {
            ..._preset,
            'presetId': 'work-$i',
            'reasoningEffort': efforts[i],
            'description': i == 0 ? null : '',
          },
      ];
      final snapshot = await ModelPresetCatalogServiceClient(
        _Channel({'presets': records, 'isComplete': false}),
      ).readPresets();
      records.first.clear();
      records.clear();
      expect(snapshot.isComplete, isFalse);
      expect(snapshot.presets.map((p) => p.reasoningEffort), efforts);
      expect(
        snapshot.presets.map((p) => p.reasoningEffort),
        containsAll([null, 'none']),
      );
      for (final (i, preset) in snapshot.presets.indexed) {
        expect(preset.presetId, 'work-$i');
        expect(preset.name, _preset['name']);
        expect(preset.description, i == 0 ? null : '');
        expect(preset.model.providerId, _model['providerId']);
        expect(preset.model.modelId, _model['modelId']);
      }
      final input = [...snapshot.presets];
      final copied = ModelPresetCatalogSnapshot(
        presets: input,
        isComplete: true,
      );
      input.clear();
      expect(copied.presets, snapshot.presets);
      expect(copied.presets.clear, throwsUnsupportedError);
    },
  );

  test(
    'malformed catalog data is rejected without echoing a private value',
    () async {
      const secret = '/private/record-contents';
      for (final response in [
        null,
        {'presets': <Object?>[]},
        {'presets': <String, Object?>{}, 'isComplete': true},
        {'presets': <Object?>[], 'isComplete': 1},
        {'presets': <Object?>[], 'isComplete': true, 'foreign': secret},
        for (final invalid in [
          for (final key in _preset.keys) {..._preset}..remove(key),
          {..._preset, 'foreign': secret},
          {..._preset, 'presetId': secret},
          {..._preset, ..._model}..remove('model'),
          for (final reference in [
            null,
            'unqualified',
            for (final key in _model.keys) {..._model}..remove(key),
            {..._model, 'providerId': null},
            {..._model, 'modelId': 7},
            {..._model, 'foreign': secret},
          ])
            {..._preset, 'model': reference},
          {..._preset, 'description': false},
          {..._preset, 'reasoningEffort': secret},
          {..._preset, 'reasoningEffort': 'NONE'},
        ])
          {
            'presets': [invalid],
            'isComplete': false,
          },
      ]) {
        await expectLater(
          ModelPresetCatalogServiceClient(_Channel(response)).readPresets(),
          throwsA(
            isA<AdeleProtocolException>()
                .having(
                  (e) => e.toString(),
                  'sanitized',
                  isNot(contains(secret)),
                )
                .having((e) => e.toString().length, 'bounded', lessThan(512)),
          ),
        );
      }
    },
  );

  test('read, select and clear carry only identity and revision', () async {
    expect(modelPresetSelectionServiceId, 'modelPresetSelection');
    const session = 'session-A';
    final id = 'p' * 64;
    for (final (selected, revision) in <(String?, int)>[
      (null, 0),
      (id, 1),
      (null, ModelPresetSelectionLimits.maxRevision),
    ]) {
      final channel = _Channel({
        'sessionId': session,
        'selectedPresetId': selected,
        'revision': revision,
      });
      final client = ModelPresetSelectionServiceClient(channel);
      final result = revision == 0
          ? await client.readSessionSelection(session)
          : await client.updateSessionSelection(
              session,
              selected,
              revision - 1,
            );
      expect(result.sessionId, session);
      expect(result.selectedPresetId, selected);
      expect(result.revision, revision);
      expect(
        channel.calls.single.$1,
        revision == 0
            ? 'modelPresetSelection.readSessionSelection'
            : 'modelPresetSelection.updateSessionSelection',
      );
      expect(channel.calls.single.$2, {
        'sessionId': session,
        if (revision != 0) ...{
          'selectedPresetId': selected,
          'expectedRevision': revision - 1,
        },
      });
    }
  });

  test(
    'selection decoding enforces required fields, portable IDs and revisions',
    () async {
      const valid = {
        'sessionId': 'session',
        'selectedPresetId': null,
        'revision': 0,
      };
      for (final invalid in [
        for (final key in valid.keys) {...valid}..remove(key),
        {...valid, 'binding': 'not-a-selection'},
        for (final session in ['', ' s', 's ', 's' * 513])
          {...valid, 'sessionId': session},
        for (final revision in [
          -1,
          0.0,
          '0',
          ModelPresetSelectionLimits.maxRevision + 1,
        ])
          {...valid, 'revision': revision},
        {...valid, 'selectedPresetId': 'work'},
        for (final id in ['', 'UPPER', 'con', '../bad', 'p' * 65])
          {...valid, 'selectedPresetId': id, 'revision': 1},
      ]) {
        await expectLater(
          ModelPresetSelectionServiceClient(
            _Channel(invalid),
          ).readSessionSelection('session'),
          throwsA(isA<AdeleProtocolException>()),
        );
      }
    },
  );

  test(
    'dispatch rejects malformed updates before invoking selection',
    () async {
      final service = _FailingSelection();
      final dispatcher = ModelPresetSelectionServiceDispatcher(service);
      addTearDown(dispatcher.close);
      const valid = {
        'sessionId': 'session',
        'selectedPresetId': null,
        'expectedRevision': 0,
      };
      for (final invalid in [
        for (final key in valid.keys) {...valid}..remove(key),
        {...valid, 'providerId': '/private/config'},
        {...valid, 'selectedPresetId': 42},
      ]) {
        final response = await dispatcher.dispatch({
          'kind': 'request',
          'requestId': 1,
          'method': modelPresetSelectionServiceUpdateSessionSelectionId,
          'payload': invalid,
        });
        expect(response['ok'], isFalse);
        expect((response['error']! as Map)['code'], 'invalid_request');
        expect(response.toString(), isNot(contains('/private/config')));
      }
      expect(service.updates, 0);
      final failed = await dispatcher.dispatch({
        'kind': 'request',
        'requestId': 1,
        'method': modelPresetSelectionServiceUpdateSessionSelectionId,
        'payload': valid,
      });
      expect(service.updates, 1);
      expect(failed['ok'], isFalse);
      expect(failed['error'], {
        'declaredFailureType': 'modelPresetSelection.failure',
        'code': 'outcome_uncertain',
        'message': 'Write not acknowledged.',
        'details': <String, Object?>{},
      });
    },
  );
}

final class _FailingSelection implements ModelPresetSelectionService {
  int updates = 0;

  @override
  Future<ModelPresetSelectionSnapshot> readSessionSelection(String sessionId) =>
      throw UnimplementedError();

  @override
  Future<ModelPresetSelectionSnapshot> updateSessionSelection(
    String sessionId,
    String? selectedPresetId,
    int expectedRevision,
  ) async {
    updates++;
    throw const ModelPresetSelectionFailure(
      code: 'outcome_uncertain',
      message: 'Write not acknowledged.',
    );
  }
}

const _model = {
  'providerId': ' Configured:provider/V2 ',
  'modelId': ' org/Model.Mixed@v1+fine:tuned ',
};
const _preset = {
  'presetId': 'work',
  'name': 'Draft',
  'description': null,
  'model': _model,
  'reasoningEffort': null,
};

final class _Channel implements AdeleRequestChannel {
  _Channel(this.response);
  final Object? response;
  final calls = <(String, Map<String, Object?>)>[];

  @override
  Future<Object?> request(String method, Map<String, Object?> payload) async {
    calls.add((method, payload));
    return response;
  }
}
