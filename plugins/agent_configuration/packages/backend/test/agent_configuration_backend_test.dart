import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:adele_plugin_backend_support/adele_plugin_backend_support.dart';
import 'package:agent_configuration_backend/agent_configuration_backend.dart';
import 'package:agent_configuration_contract/agent_configuration_contract.dart';
import 'package:test/test.dart';

void main() {
  late String collection;
  late String type;
  late Map<String, String> requiredFields;
  late Map<String, String> optionalFields;
  setUpAll(() async {
    // Build minimum-presence and full-presence records from the real declaration.
    final library = (await Isolate.resolvePackageUri(
      Uri.parse(
        'package:agent_configuration_backend/agent_configuration_backend.dart',
      ),
    ))!;
    final file = File.fromUri(library.resolve('../../../records.schema.json'));
    final schema =
        jsonDecode(await file.readAsString()) as Map<String, dynamic>;
    final agent =
        (schema['recordTypes'] as List<dynamic>).single as Map<String, dynamic>;
    collection = agent['collection'] as String;
    type = agent['id'] as String;
    requiredFields = {};
    optionalFields = {};
    for (final field
        in (agent['fields'] as List<dynamic>).cast<Map<String, dynamic>>()) {
      expect(field['type'], 'string');
      final fields = (field['required'] as bool)
          ? requiredFields
          : optionalFields;
      fields[field['id'] as String] = '';
    }
  });

  Map<String, Object?> record(String id, Map<String, Object?> values) => {
    'collection': collection,
    'type': type,
    'id': id,
    'values': values,
  };

  late AdeleHostRequestMultiplexer host;
  late AgentCatalogBackend service;
  late List<Map<String, Object?>> requests;
  setUp(() {
    requests = [];
    host = AdeleHostRequestMultiplexer(send: requests.add);
    service = AgentCatalogBackend(
      AdeleConfigurationClient(
        hostRequests: host,
        hostInfrastructureContext: 'captured-generation',
      ),
    );
  });
  tearDown(() => host.close());

  Future<AgentCatalogSnapshot> read(Object? response) {
    final result = service.readAgents();
    host.handleResponse({
      'kind': 'hostResponse',
      'requestId': requests.last['requestId'],
      'ok': true,
      'payload': response,
    });
    return result;
  }

  test('empty and all-invalid observations remain distinguishable', () async {
    for (final isComplete in [true, false]) {
      final snapshot = await read({
        'records': <Object?>[],
        'isComplete': isComplete,
      });
      expect(snapshot.agents, isEmpty);
      expect(snapshot.isComplete, isComplete);
    }
    expect(requests, hasLength(2));
    for (final request in requests) {
      expect(request['hostContextKind'], 'infrastructure');
      expect(request['hostContext'], 'captured-generation');
      expect(request['serviceId'], backendConfigurationServiceId);
      expect(request['method'], 'currentRecords');
      expect(request['payload'], isEmpty);
    }
  });

  test(
    'partial observation retains exact healthy definitions in ID order',
    () async {
      const markdown = '  # Review\r\n\r\n```dart\ncheck();\n```  \n';
      final snapshot = await read({
        'records': [
          record('last', {
            ...requiredFields,
            ...optionalFields,
            'name': '  A  ',
            'instructions': markdown,
          }),
          record('first', requiredFields),
          record('intermediate', {...requiredFields, 'name': 'Z'}),
        ],
        'isComplete': false,
      });
      expect(snapshot.isComplete, isFalse);
      expect(snapshot.agents.map((agent) => agent.id), [
        'first',
        'intermediate',
        'last',
      ]);
      final first = snapshot.agents.first;
      expect(first.name, '');
      expect(first.instructions, '');
      expect(first.description, isNull);
      expect(first.whenToUse, isNull);
      final last = snapshot.agents.last;
      expect(last.name, '  A  ');
      expect(last.instructions, markdown);
      expect(last.description, '');
      expect(last.whenToUse, '');
      expect(snapshot.agents.clear, throwsUnsupportedError);
    },
  );

  test(
    'later reads reflect rename, edit, and deletion without changing prior snapshots',
    () async {
      Future<AgentCatalogSnapshot> named(String name, String instructions) =>
          read({
            'records': [
              record('work', {
                'name': name,
                'instructions': instructions,
                'description': 'Summary',
                'when-to-use': 'Review',
              }),
            ],
            'isComplete': true,
          });
      final initial = (await named('Original', 'First')).agents.single;
      final updated = (await named('Renamed', 'Second')).agents.single;
      expect(
        (await read({'records': <Object?>[], 'isComplete': true})).agents,
        isEmpty,
      );
      expect(initial.id, 'work');
      expect(updated.id, initial.id);
      expect((initial.name, initial.instructions), ('Original', 'First'));
      expect((updated.name, updated.instructions), ('Renamed', 'Second'));
      expect((updated.description, updated.whenToUse), ('Summary', 'Review'));
      expect(requests, hasLength(3));
    },
  );

  test(
    'unavailable authority or invalid transport cannot serve cached data',
    () async {
      final agent = record('kept', requiredFields);
      final healthy = await read({
        'records': [agent],
        'isComplete': true,
      });
      expect(healthy.agents.single.id, 'kept');
      for (final invalid in [
        {'failure': 'configurationUnavailable'},
        {'failure': 'notAuthorized'},
        {'failure': 'generationUnavailable'},
        {
          'records': [agent, agent],
          'isComplete': true,
        }, // duplicate identity
        {'records': '/private/record.toml', 'isComplete': false},
        {
          'records': [agent],
          'isComplete': 'invalid',
        },
      ]) {
        await expectLater(read(invalid), throwsA(_failure('unavailable')));
      }
      host.close();
      await expectLater(service.readAgents(), throwsA(_failure('unavailable')));
    },
  );

  test(
    'mis-scoped or malformed records fail the whole projection safely',
    () async {
      final agent = record('valid', requiredFields);
      final private = record('private-record', {
        'name': '/private/path',
        'instructions': 'private Markdown',
      });
      for (final malformed in [
        {...private, 'type': 'other.plugin.agent'},
        {...private, 'collection': 'elsewhere'},
        for (final key in requiredFields.keys)
          record('bad', {...requiredFields}..remove(key)),
        for (final key in {...requiredFields, ...optionalFields}.keys)
          record('bad', {...requiredFields, key: false}),
        record('bad', {...requiredFields, 'unexpected': 'private Markdown'}),
      ]) {
        await expectLater(
          read({
            'records': [agent, malformed],
            'isComplete': false,
          }),
          throwsA(_failure('invalid_observation')),
        );
      }
    },
  );
}

Matcher _failure(String code) => isA<AgentCatalogFailure>()
    .having((failure) => failure.code, 'code', code)
    .having(
      (failure) => failure.message,
      'message',
      code == 'unavailable'
          ? 'Agent configuration could not be read.'
          : 'Unexpected Agent record in the configuration observation.',
    )
    .having((failure) => failure.details, 'details', isEmpty);
