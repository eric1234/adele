import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:adele_plugin_backend_support/adele_plugin_backend_support.dart';
import 'package:model_configuration_backend/model_configuration_backend.dart';
import 'package:model_configuration_contract/model_configuration_contract.dart';
import 'package:test/test.dart';

void main() {
  late AdeleHostRequestMultiplexer host;
  late ModelPresetCatalogBackend catalog;
  late Map<String, Object?> request;
  setUp(() {
    host = AdeleHostRequestMultiplexer(
      send: (message) {
        expect(message['hostContext'], 'captured');
        expect(message['serviceId'], backendConfigurationServiceId);
        expect(message['method'], 'currentRecords');
        expect(message['payload'], isEmpty);
        request = message;
      },
    );
    catalog = ModelPresetCatalogBackend(
      AdeleConfigurationClient(
        hostRequests: host,
        hostInfrastructureContext: 'captured',
      ),
    );
  });
  tearDown(() => host.close());

  Future<ModelPresetCatalogSnapshot> observe(Object response) {
    final result = catalog.readPresets();
    host.handleResponse({
      'kind': 'hostResponse',
      'requestId': request['requestId'],
      'ok': true,
      'payload': response,
    });
    return result;
  }

  const model = {
    'provider-id': ' Unknown:Provider ',
    'model-id': r'Model/V2$beta',
  };
  const required = {'name': '', 'model': model};
  Map<String, Object?> record(String id, Map<String, Object?> values) => {
    'id': id,
    'type': 'dev.adele.plugin.model-configuration.preset',
    'collection': 'model-presets',
    'values': values,
  };
  Future<ModelPresetCatalogSnapshot> read(
    List<Object> records, {
    bool complete = true,
  }) => observe({'records': records, 'isComplete': complete});

  test(
    'live observation preserves exact values, duplicate names and completeness',
    () async {
      for (final complete in [true, false]) {
        final empty = await read([], complete: complete);
        expect(empty.presets, isEmpty);
        expect(empty.isComplete, complete);
        final both = await read([
          record('z', {
            ...required,
            'reasoning-effort': 'none',
            'description': '',
          }),
          record('a', required),
        ], complete: complete);
        expect(both.isComplete, complete);
        expect(both.presets.map((p) => p.presetId), ['a', 'z']);
        expect(both.presets.map((p) => p.name), ['', '']);
        expect(both.presets.map((p) => p.description), [null, '']);
        expect(both.presets.map((p) => p.reasoningEffort), [null, 'none']);
        expect(both.presets.first.model.providerId, model['provider-id']);
        expect(both.presets.first.model.modelId, model['model-id']);
      }
    },
  );

  test(
    'schema fields, collection and every declared effort project successfully',
    () async {
      final uri = (await Isolate.resolvePackageUri(
        Uri.parse(
          'package:model_configuration_backend/model_configuration_backend.dart',
        ),
      ))!;
      final schema =
          jsonDecode(
                await File.fromUri(
                  uri.resolve('../../../records.schema.json'),
                ).readAsString(),
              )
              as Map<String, dynamic>;
      final type =
          (schema['recordTypes'] as List<dynamic>).single
              as Map<String, dynamic>;
      final fields = {
        for (final f
            in (type['fields'] as List<dynamic>).cast<Map<String, dynamic>>())
          f['id'] as String: f,
      };
      expect(fields.keys.toSet(), {
        ...required.keys,
        'description',
        'reasoning-effort',
      });
      expect(
        fields.values.where((f) => f['required'] == true).map((f) => f['id']),
        unorderedEquals(required.keys),
      );
      expect(
        fields.values.where((f) => f['type'] == 'string').map((f) => f['id']),
        unorderedEquals(['name', 'description']),
      );
      expect(fields['model']!['type'], 'struct');
      expect(fields['model']!['properties'], [
        for (final key in model.keys) {'id': key, 'type': 'string'},
      ]);
      expect(fields['reasoning-effort']!['type'], 'enum');
      for (final option
          in (fields['reasoning-effort']!['options'] as List<dynamic>)
              .cast<Map<String, dynamic>>()) {
        final effort = option['value'] as String;
        final snapshot = await read([
          {
            'type': type['id'],
            'collection': type['collection'],
            'id': 'work',
            'values': {...required, 'reasoning-effort': effort},
          },
        ]);
        expect(snapshot.presets.single.reasoningEffort, effort);
      }
    },
  );

  test(
    'unavailable authority does not fall back to a previous observation',
    () async {
      expect((await read([record('work', required)])).presets, hasLength(1));
      for (final kind in AdeleConfigurationFailureKind.values) {
        await expectLater(
          observe({'failure': kind.name}),
          throwsA(_failure('unavailable')),
        );
      }
      host.close();
      await expectLater(
        catalog.readPresets(),
        throwsA(_failure('unavailable')),
      );
    },
  );

  test(
    'foreign scope, schema drift, missing fields and invalid values fail closed',
    () async {
      final valid = record('valid', required);
      for (final malformed in [
        {...record('bad', required), 'type': 'other.plugin.type'},
        {...record('bad', required), 'collection': 'agents'},
        for (final key in required.keys)
          record('bad', {...required}..remove(key)),
        for (final key in [...required.keys, 'description', 'reasoning-effort'])
          record('bad', {...required, key: false}),
        record('bad', {'name': '', ...model}),
        for (final reference in [
          for (final key in model.keys) {...model}..remove(key),
          {...model, 'model-id': false},
          {...model, 'provider-id': 123},
          {...model, 'other': 'PRIVATE'},
        ])
          record('bad', {...required, 'model': reference}),
        record('bad', {...required, 'reasoning-effort': 'PRIVATE'}),
        record('bad', {...required, 'unexpected': 'PRIVATE'}),
      ]) {
        await expectLater(
          read([valid, malformed], complete: false),
          throwsA(_failure('invalid_observation')),
        );
      }
    },
  );
}

Matcher _failure(String code) => isA<ModelPresetCatalogFailure>()
    .having((f) => f.code, 'code', code)
    .having((f) => f.message, 'message', isNot(contains('PRIVATE')))
    .having((f) => f.details, 'details', isEmpty);
