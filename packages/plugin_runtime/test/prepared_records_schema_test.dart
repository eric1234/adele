import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:adele_plugin_api/adele_plugin_api.dart';
import 'package:adele_settings/adele_settings.dart';
import 'package:plugin_runtime/plugin_runtime.dart';
import 'package:test/test.dart';

void main() {
  late Directory temporary;
  late Directory root;
  setUp(() async {
    temporary = await Directory.systemTemp.createTemp('prepared records ');
    root = await Directory.fromUri(
      temporary.uri.resolve('installations/'),
    ).create();
  });
  tearDown(() => temporary.delete(recursive: true));

  Future<Directory> install(
    String name, {
    String id = 'org.example.plugin',
    Object? schema = const {'schemaVersion': 1, 'recordTypes': <Object?>[]},
    Object? reference = 'records.schema.json',
    bool declareRecords = true,
    bool settings = true,
    Map<String, Object?> components = _components,
  }) async {
    final directory = await Directory.fromUri(
      root.uri.resolve('$name/'),
    ).create();
    await File.fromUri(
      directory.uri.resolve('adele_plugin.installation.json'),
    ).writeAsString(
      jsonEncode({
        'manifestVersion': 1,
        'metadata': {'id': id, 'version': '1', 'displayName': 'Example'},
        'components': components,
        if (declareRecords) 'recordsSchema': reference,
        if (settings) 'settingsSchema': 'settings.schema.json',
      }),
    );
    await File.fromUri(
      directory.uri.resolve('records.schema.json'),
    ).writeAsString(jsonEncode(schema));
    await File.fromUri(
      directory.uri.resolve('settings.schema.json'),
    ).writeAsString(
      jsonEncode({
        'schemaVersion': 1,
        'definitions': [
          {
            'id': '$id.enabled',
            'type': 'boolean',
            'default': true,
            'label': 'Enabled',
            'category': 'General',
            'section': 'Output',
          },
        ],
      }),
    );
    for (final artifact in ['backend.aot', 'frontend.evc']) {
      await File.fromUri(
        directory.uri.resolve(artifact),
      ).writeAsString('Not executable; discovery must not load code.');
    }
    return directory;
  }

  void rejected(PreparedPluginCatalog catalog) {
    expect(
      catalog.installations,
      hasLength(1),
      reason: catalog.issues.join('\n'),
    );
    final installation = catalog.installations.single;
    expect(installation.recordsSchema, isNull);
    expect(catalog.records.definitions, isEmpty);
    expect(installation.settingsSchema, isNotNull);
    expect(catalog.settings.definitions, hasLength(1));
    expect(installation.backendArtifactUri, isNotNull);
    expect(installation.frontend, isNotNull);
    final issue = catalog.issues.single;
    expect(issue.isRecordsSchemaIssue, isTrue);
    expect(issue.isSettingsSchemaIssue, isFalse);
    expect(issue.component, isNull);
    expect(issue.pluginId, installation.metadata.id);
    expect(
      issue.installationDirectory.uri,
      installation.installationDirectory.uri,
    );
    expect(issue.message.toLowerCase(), contains('records schema'));
  }

  for (final records in [false, true]) {
    for (final settings in [false, true]) {
      for (final backend in [false, true]) {
        for (final frontend in [false, true]) {
          test(
            'independent records=$records settings=$settings backend=$backend frontend=$frontend',
            () async {
              final directory = await install(
                'plugin',
                declareRecords: records,
                settings: settings,
                schema: _schema([
                  {
                    ..._type(),
                    'credentialSlots': [_slot()],
                  },
                ]),
                components: {
                  if (backend) 'backend': _components['backend'],
                  if (frontend) 'frontend': _components['frontend'],
                },
              );
              final catalog = await PreparedPluginCatalog.discover(root.path);
              expect(catalog.issues, isEmpty);
              final installation = catalog.installations.single;
              expect(
                installation.backendArtifactUri,
                backend ? isNotNull : isNull,
              );
              expect(installation.frontend, frontend ? isNotNull : isNull);
              expect(
                installation.settingsSchema,
                settings ? isNotNull : isNull,
              );
              expect(installation.recordsSchema, records ? isNotNull : isNull);
              expect(installation.backendConsumedRecordTypes, isEmpty);
              expect(installation.backendConsumedCredentialSlots, isEmpty);
              expect(
                () => installation.backendConsumedCredentialSlots.clear(),
                throwsUnsupportedError,
              );
              expect(
                () => installation.backendConsumedRecordTypes.clear(),
                throwsUnsupportedError,
              );
              expect(catalog.records.definitions, hasLength(records ? 1 : 0));
              if (records) {
                expect(
                  installation.recordsSchema!.artifactUri,
                  directory.uri.resolve('records.schema.json'),
                );
                expect(
                  catalog.records.definitions.single.owner,
                  installation.metadata.id,
                );
              }
            },
          );
        }
      }
    }
  }

  test('empty and missing roots and empty record schemas are valid', () async {
    for (final path in ['', root.path, '${root.path}/missing']) {
      expect(
        (await PreparedPluginCatalog.discover(path)).records.definitions,
        isEmpty,
      );
    }
    await install('empty');
    final catalog = await PreparedPluginCatalog.discover(root.path);
    expect(catalog.issues, isEmpty);
    expect(catalog.installations.single.recordsSchema, isNotNull);
    expect(catalog.records.definitions, isEmpty);
  });

  test(
    'backend record opt-in snapshots and roundtrips exact owned IDs',
    () async {
      final ids = ['org.example.plugin.z', 'org.example.plugin.api'];
      final directory = await install(
        'plugin',
        schema: _schema([
          for (final id in ids)
            {
              ..._type(id: id),
              'credentialSlots': [_slot()],
            },
        ]),
        components: _recordConsumer(ids),
      );
      final catalog = await PreparedPluginCatalog.discover(root.path);
      expect(catalog.issues, isEmpty);
      final parsed = catalog.installations.single;
      expect(parsed.backendArtifactUri, isNotNull);
      expect(parsed.frontend, isNotNull);
      expect(parsed.backendConsumedCapabilities, hasLength(1));
      expect(parsed.backendConsumedRecordTypes.map((id) => id.value), ids);
      expect(parsed.backendConsumedCredentialSlots, isEmpty);
      final input = parsed.backendConsumedRecordTypes.toList();
      PreparedPluginInstallation construct({
        Iterable<RecordTypeId>? types,
        String owner = 'org.example.plugin',
        bool backend = true,
        bool schema = true,
      }) => PreparedPluginInstallation(
        metadata: PluginMetadata(
          id: PluginId(owner),
          version: '1',
          displayName: 'Consumer',
        ),
        installationDirectory: directory,
        backendArtifactUri: backend ? parsed.backendArtifactUri : null,
        backendConsumedRecordTypes: types ?? input,
        recordsSchema: schema ? parsed.recordsSchema : null,
      );
      final installation = construct();
      input.clear();
      expect(
        installation.backendConsumedRecordTypes,
        parsed.backendConsumedRecordTypes,
      );
      expect(
        () => parsed.backendConsumedRecordTypes.clear(),
        throwsUnsupportedError,
      );
      expect(
        () =>
            installation.backendConsumedRecordTypes[0] = RecordTypeId(ids.last),
        throwsUnsupportedError,
      );
      final json = installation.backendConsumedRecordTypesToJson();
      expect(json, ids);
      await File.fromUri(
        directory.uri.resolve('adele_plugin.installation.json'),
      ).writeAsString(
        jsonEncode({
          'manifestVersion': 1,
          'metadata': {
            'id': 'org.example.plugin',
            'version': '1',
            'displayName': 'Example',
          },
          'recordsSchema': 'records.schema.json',
          'components': _recordConsumer(json),
        }),
      );
      final roundtrip = await PreparedPluginCatalog.discover(root.path);
      expect(roundtrip.issues, isEmpty);
      expect(
        roundtrip.installations.single.backendConsumedRecordTypesToJson(),
        ids,
      );
      json[0] = 'org.other.type';
      json.clear();
      expect(installation.backendConsumedRecordTypesToJson(), ids);
      final id = parsed.backendConsumedRecordTypes.first;
      for (final invalid in [
        () => construct(types: [id, id]),
        () => construct(types: [id], backend: false),
        () => construct(types: [id], schema: false),
        () => construct(types: [id], owner: 'org.example'),
        () => construct(types: [id], owner: 'org.other'),
        () => construct(types: [RecordTypeId('org.example.plugin.unknown')]),
      ]) {
        expect(invalid, throwsFormatException);
      }
      expect(
        construct(
          types: [],
          backend: false,
          schema: false,
        ).backendConsumedRecordTypes,
        isEmpty,
      );
    },
  );

  final invalidConsumption = <String, Object?>{
    for (final value in <Object?>[null, false, '', 1, {}])
      'non-array ${jsonEncode(value)}': value,
    for (final value in <Object?>[
      null,
      false,
      1,
      [],
      {},
      '',
      ' ',
      'api',
      'Org.example.api',
      'org.example..api',
      'org.example.plugin.api ',
      'org.example.plugin.api\n',
      {'id': 'org.example.plugin.api'},
      {'collection': 'providers'},
      {'type': 'org.example.plugin.api', 'owner': 'org.example.plugin'},
    ])
      'entry ${jsonEncode(value)}': ['org.example.plugin.api', value],
    'duplicate IDs': ['org.example.plugin.api', 'org.example.plugin.api'],
    'unknown same-namespace type': ['org.example.plugin.unknown'],
  };
  for (final entry in invalidConsumption.entries) {
    test('invalid record opt-in ${entry.key} disables only backend', () async {
      await install(
        'plugin',
        schema: _schema([_type()]),
        components: _recordConsumer(entry.value),
      );
      final catalog = await PreparedPluginCatalog.discover(root.path);
      final installation = catalog.installations.single;
      expect(installation.backendArtifactUri, isNull);
      expect(installation.backendConsumedCapabilities, isEmpty);
      expect(installation.backendConsumedRecordTypes, isEmpty);
      expect(installation.frontend, isNotNull);
      expect(catalog.records.definitions, hasLength(1));
      expect(catalog.settings.definitions, hasLength(1));
      expect(catalog.issues.single.component, PreparedPluginComponent.backend);
      expect(catalog.issues.single.isRecordsSchemaIssue, isFalse);
    });
  }

  for (final reverse in [false, true]) {
    for (final foreign in [
      'org.example.plugin.child.api',
      'org.example.plugin-other.api',
      'org.other.plugin.api',
    ]) {
      test('record opt-in rejects foreign $foreign reverse=$reverse', () async {
        await install(
          reverse ? 'z' : 'a',
          schema: _schema([_type()]),
          components: _recordConsumer([foreign]),
        );
        await install(
          reverse ? 'a' : 'z',
          id: foreign.substring(0, foreign.lastIndexOf('.')),
          schema: _schema([_type(id: foreign)]),
          components: _recordConsumer([foreign]),
        );
        final catalog = await PreparedPluginCatalog.discover(root.path);
        expect(catalog.installations, hasLength(2));
        expect(catalog.records.definitions, hasLength(2));
        expect(
          catalog.records.definitions
              .map((type) => type.collection.value)
              .toSet(),
          {'providers'},
        );
        final owner = catalog.installations.singleWhere(
          (item) => item.metadata.id.value == 'org.example.plugin',
        );
        final sibling = catalog.installations.singleWhere(
          (item) => !identical(item, owner),
        );
        expect(owner.backendArtifactUri, isNull);
        expect(owner.backendConsumedRecordTypes, isEmpty);
        expect(owner.frontend, isNotNull);
        expect(owner.settingsSchema, isNotNull);
        expect(owner.recordsSchema, isNotNull);
        expect(sibling.backendArtifactUri, isNotNull);
        expect(sibling.backendConsumedRecordTypesToJson(), [foreign]);
        expect(catalog.issues.single.pluginId, owner.metadata.id);
        expect(
          catalog.issues.single.component,
          PreparedPluginComponent.backend,
        );
      });
    }
  }

  test(
    'multiple owners share collections with exact nested declarations',
    () async {
      const owners = {
        'org.example.plugin': 'org.example.plugin.child.parent-type',
        'org.example.plugin.child': 'org.example.plugin.child.api',
        'org.other.plugin': 'org.other.plugin.api',
      };
      for (final entry in owners.entries) {
        await install(
          entry.key,
          id: entry.key,
          schema: _schema([_type(id: entry.value)]),
          components: _recordConsumer([entry.value]),
        );
      }
      final catalog = await PreparedPluginCatalog.discover(root.path);
      expect(catalog.issues, isEmpty);
      expect(catalog.records.definitions, hasLength(3));
      for (final installation in catalog.installations) {
        expect(installation.backendConsumedRecordTypesToJson(), [
          owners[installation.metadata.id.value],
        ]);
        expect(
          installation.recordsSchema!.definitions.single.owner,
          installation.metadata.id,
        );
        expect(installation.backendArtifactUri, isNotNull);
      }
    },
  );

  for (final failure in [
    'absent',
    'missing',
    'malformed',
    'partial',
    'unreadable',
  ]) {
    for (final optIn in [false, true]) {
      test(
        'record schema $failure with opt-in=$optIn fails closed locally',
        () async {
          final directory = await install(
            'plugin',
            declareRecords: failure != 'absent',
            reference: failure == 'missing'
                ? 'missing.json'
                : 'records.schema.json',
            schema: failure == 'malformed'
                ? false
                : _schema([_type(), if (failure == 'partial') false]),
            components: _recordConsumer([if (optIn) 'org.example.plugin.api']),
          );
          final catalog = failure == 'unreadable'
              ? await IOOverrides.runWithIOOverrides(
                  () => PreparedPluginCatalog.discover(root.path),
                  _UnreadableSchema(
                    directory.uri.resolve('records.schema.json').toFilePath(),
                  ),
                )
              : await PreparedPluginCatalog.discover(root.path);
          final installation = catalog.installations.single;
          expect(installation.recordsSchema, isNull);
          expect(installation.frontend, isNotNull);
          expect(installation.settingsSchema, isNotNull);
          expect(installation.backendArtifactUri, optIn ? isNull : isNotNull);
          expect(installation.backendConsumedRecordTypes, isEmpty);
          expect(
            catalog.issues.where((issue) => issue.isRecordsSchemaIssue),
            hasLength(failure == 'absent' ? 0 : 1),
          );
          expect(
            catalog.issues.where(
              (issue) => issue.component == PreparedPluginComponent.backend,
            ),
            hasLength(optIn ? 1 : 0),
          );
        },
      );
    }
  }

  for (final count in [
    0,
    PreparedPluginInstallation.maxBackendConsumedRecordTypes,
    PreparedPluginInstallation.maxBackendConsumedRecordTypes + 1,
  ]) {
    test('record opt-in count $count at discovery and construction', () async {
      final ids = [
        for (var index = 0; index < count; index++)
          'org.example.plugin.t-$index',
      ];
      final directory = await install(
        'plugin',
        schema: _schema([for (final id in ids) _type(id: id)]),
        components: _recordConsumer(ids),
      );
      final catalog = await PreparedPluginCatalog.discover(root.path);
      final parsed = catalog.installations.single;
      PreparedPluginInstallation construct() => PreparedPluginInstallation(
        metadata: parsed.metadata,
        installationDirectory: directory,
        backendArtifactUri: directory.uri.resolve('backend.aot'),
        recordsSchema: parsed.recordsSchema,
        backendConsumedRecordTypes: ids.map(RecordTypeId.new),
      );
      expect(parsed.recordsSchema!.definitions, hasLength(count));
      expect(parsed.frontend, isNotNull);
      if (count <= PreparedPluginInstallation.maxBackendConsumedRecordTypes) {
        expect(catalog.issues, isEmpty);
        expect(parsed.backendConsumedRecordTypesToJson(), ids);
        expect(construct().backendConsumedRecordTypesToJson(), ids);
      } else {
        expect(
          catalog.issues.single.component,
          PreparedPluginComponent.backend,
        );
        expect(catalog.issues.single.message, contains('must not exceed'));
        expect(parsed.backendArtifactUri, isNull);
        expect(parsed.backendConsumedRecordTypes, isEmpty);
        expect(construct, throwsFormatException);
      }
    });
  }

  for (final extra in [0, 1]) {
    test('record opt-in ID length boundary plus $extra', () async {
      final id =
          'org.example.plugin.${'x' * (PreparedRecordsSchema.maxIdLength - 'org.example.plugin.'.length)}';
      final requested = '$id${'x' * extra}';
      final directory = await install(
        'plugin',
        schema: _schema([_type(id: id)]),
        components: _recordConsumer([requested]),
      );
      final catalog = await PreparedPluginCatalog.discover(root.path);
      final parsed = catalog.installations.single;
      PreparedPluginInstallation construct() => PreparedPluginInstallation(
        metadata: parsed.metadata,
        installationDirectory: directory,
        backendArtifactUri: directory.uri.resolve('backend.aot'),
        recordsSchema: parsed.recordsSchema,
        backendConsumedRecordTypes: [RecordTypeId(requested)],
      );
      if (extra == 0) {
        expect(catalog.issues, isEmpty);
        expect(construct().backendConsumedRecordTypesToJson(), [id]);
      } else {
        expect(
          catalog.issues.single.component,
          PreparedPluginComponent.backend,
        );
        expect(catalog.issues.single.message, contains('UTF-16'));
        expect(construct, throwsFormatException);
      }
    });
  }

  for (final failure in ['artifact', 'capabilities', 'frontend']) {
    test(
      'record opt-in remains component-local with invalid $failure',
      () async {
        final components = _recordConsumer(['org.example.plugin.api']);
        if (failure == 'frontend') {
          components['frontend'] = {
            'artifact': 'frontend.evc',
            'presentations': false,
          };
        } else {
          (components['backend']! as Map<String, Object?>)[failure == 'artifact'
              ? 'artifact'
              : 'consumesCapabilities'] = failure == 'artifact'
              ? 'missing.aot'
              : false;
        }
        await install(
          'plugin',
          schema: _schema([_type()]),
          components: components,
        );
        final catalog = await PreparedPluginCatalog.discover(root.path);
        final parsed = catalog.installations.single;
        expect(
          parsed.backendArtifactUri,
          failure == 'frontend' ? isNotNull : isNull,
        );
        expect(
          parsed.backendConsumedRecordTypesToJson(),
          failure == 'frontend' ? ['org.example.plugin.api'] : isEmpty,
        );
        expect(parsed.recordsSchema, isNotNull);
        expect(parsed.settingsSchema, isNotNull);
        expect(
          catalog.issues.single.component,
          failure == 'frontend'
              ? PreparedPluginComponent.frontend
              : PreparedPluginComponent.backend,
        );
      },
    );
  }

  test(
    'credential opt-in snapshots and roundtrips exact types and slots',
    () async {
      const types = ['org.example.plugin.z', 'org.example.plugin.api'];
      final declarations = [
        _credentialDeclaration(
          recordType: types.first,
          slots: ['token', 'api-key'],
        ),
        _credentialDeclaration(),
      ];
      final directory = await install(
        'plugin',
        schema: _schema([
          for (final id in types)
            {
              ..._type(id: id),
              'credentialSlots': [
                _slot(),
                _slot(id: 'token'),
                _slot(id: 'unused'),
              ],
            },
        ]),
        components: _credentialConsumer(declarations, types: types),
      );
      final catalog = await PreparedPluginCatalog.discover(root.path);
      expect(catalog.issues, isEmpty);
      final parsed = catalog.installations.single;
      expect(parsed.backendArtifactUri, isNotNull);
      expect(parsed.frontend, isNotNull);
      expect(parsed.backendConsumedCapabilities, hasLength(1));
      expect(parsed.backendConsumedRecordTypesToJson(), types);
      expect(parsed.backendConsumedCredentialSlotsToJson(), declarations);
      final slots = [
        RecordCredentialSlotId('token'),
        RecordCredentialSlotId('api-key'),
      ];
      final entry = PreparedBackendCredentialSlots(
        recordType: RecordTypeId(types.first),
        slots: slots,
      );
      final input = [entry, parsed.backendConsumedCredentialSlots.last];
      PreparedPluginInstallation construct({
        Iterable<PreparedBackendCredentialSlots>? credentials,
        Iterable<RecordTypeId>? consumedTypes,
        String owner = 'org.example.plugin',
        bool backend = true,
        bool schema = true,
      }) => PreparedPluginInstallation(
        metadata: PluginMetadata(
          id: PluginId(owner),
          version: '1',
          displayName: 'Consumer',
        ),
        installationDirectory: directory,
        backendArtifactUri: backend ? parsed.backendArtifactUri : null,
        recordsSchema: schema ? parsed.recordsSchema : null,
        backendConsumedRecordTypes:
            consumedTypes ?? parsed.backendConsumedRecordTypes,
        backendConsumedCredentialSlots: credentials ?? input,
      );
      final installation = construct();
      slots.clear();
      input.clear();
      expect(installation.backendConsumedCredentialSlotsToJson(), declarations);
      expect(
        () => installation.backendConsumedCredentialSlots.clear(),
        throwsUnsupportedError,
      );
      expect(() => entry.slots.clear(), throwsUnsupportedError);
      expect(
        () => entry.slots[0] = RecordCredentialSlotId('unused'),
        throwsUnsupportedError,
      );
      final json = installation.backendConsumedCredentialSlotsToJson();
      await File.fromUri(
        directory.uri.resolve('adele_plugin.installation.json'),
      ).writeAsString(
        jsonEncode({
          'manifestVersion': 1,
          'metadata': {
            'id': 'org.example.plugin',
            'version': '1',
            'displayName': 'Example',
          },
          'recordsSchema': 'records.schema.json',
          'components': _credentialConsumer(json, types: types),
        }),
      );
      final roundtrip = await PreparedPluginCatalog.discover(root.path);
      expect(roundtrip.issues, isEmpty);
      expect(
        roundtrip.installations.single.backendConsumedCredentialSlotsToJson(),
        declarations,
      );
      (json.first['slots']! as List<String>).clear();
      json.first['recordType'] = 'org.other.api';
      json.clear();
      expect(installation.backendConsumedCredentialSlotsToJson(), declarations);
      for (final invalid in [
        () => construct(credentials: [entry, entry]),
        () => construct(credentials: [entry], backend: false),
        () => construct(credentials: [entry], schema: false),
        () => construct(credentials: [entry], owner: 'org.example'),
        () => construct(credentials: [entry], consumedTypes: []),
        () => construct(
          credentials: [
            PreparedBackendCredentialSlots(
              recordType: entry.recordType,
              slots: [RecordCredentialSlotId('unknown')],
            ),
          ],
        ),
        () => PreparedBackendCredentialSlots(
          recordType: entry.recordType,
          slots: [entry.slots.first, entry.slots.first],
        ),
      ]) {
        expect(invalid, throwsFormatException);
      }
      expect(
        construct(
          credentials: [],
          consumedTypes: [],
          backend: false,
          schema: false,
        ).backendConsumedCredentialSlots,
        isEmpty,
      );
      await File.fromUri(
        directory.uri.resolve('records.schema.json'),
      ).writeAsString('{}');
      expect(installation.backendConsumedCredentialSlotsToJson(), declarations);
    },
  );

  final invalidCredentialConsumption = <String, Object?>{
    for (final value in <Object?>[null, false, '', 1, {}])
      'non-array ${jsonEncode(value)}': value,
    for (final value in <Object?>[null, false, '', 1, [], {}])
      'entry ${jsonEncode(value)}': [_credentialDeclaration(), value],
    for (final key in ['recordType', 'slots'])
      'missing $key': [_credentialDeclaration()..remove(key)],
    for (final key in [
      'owner',
      'collection',
      'type',
      'reference',
      'secret',
      'unknown',
    ])
      'extra $key': [
        {..._credentialDeclaration(), key: 'not metadata'},
      ],
    for (final value in <Object?>[
      null,
      false,
      1,
      [],
      {},
      '',
      'api',
      'Org.example.api',
      'org.example..api',
      'org.example.plugin.api ',
      'org.example.plugin.api\n',
      'org.example.plugin.${'x' * 257}',
    ])
      'recordType ${jsonEncode(value)}': [
        {..._credentialDeclaration(), 'recordType': value},
      ],
    for (final value in <Object?>[null, false, '', 1, {}])
      'slots ${jsonEncode(value)}': [_credentialDeclaration(slots: value)],
    for (final value in <Object?>[
      null,
      false,
      1,
      [],
      {},
      '',
      ' ',
      'API-key',
      'api.key',
      'api_key',
      'api--key',
      'api-key ',
      'api-key\n',
      'x' * 65,
    ])
      'slot ${jsonEncode(value)}': [
        _credentialDeclaration(slots: ['api-key', value]),
      ],
    'duplicate slots': [
      _credentialDeclaration(slots: ['api-key', 'api-key']),
    ],
    'duplicate types disjoint slots': [
      _credentialDeclaration(),
      _credentialDeclaration(slots: ['token']),
    ],
    'duplicate types empty slots': [
      _credentialDeclaration(slots: []),
      _credentialDeclaration(slots: []),
    ],
    'unknown slot': [
      _credentialDeclaration(slots: ['unknown']),
    ],
    'ordinary field is not a slot': [
      _credentialDeclaration(slots: ['display-name']),
    ],
    'unknown type': [
      _credentialDeclaration(recordType: 'org.example.plugin.unknown'),
    ],
    'unconsumed declared type': [
      _credentialDeclaration(recordType: 'org.example.plugin.other'),
    ],
    'slot of another type': [
      _credentialDeclaration(slots: ['foreign-slot']),
    ],
  };
  for (final entry in invalidCredentialConsumption.entries) {
    test(
      'invalid credential opt-in ${entry.key} disables only backend',
      () async {
        await install(
          'plugin',
          schema: _schema([
            {
              ..._type(),
              'credentialSlots': [_slot(), _slot(id: 'token')],
            },
            {
              ..._type(id: 'org.example.plugin.other'),
              'credentialSlots': [_slot(id: 'foreign-slot')],
            },
          ]),
          components: _credentialConsumer(entry.value),
        );
        final catalog = await PreparedPluginCatalog.discover(root.path);
        final installation = catalog.installations.single;
        expect(installation.backendArtifactUri, isNull);
        expect(installation.backendConsumedCapabilities, isEmpty);
        expect(installation.backendConsumedRecordTypes, isEmpty);
        expect(installation.backendConsumedCredentialSlots, isEmpty);
        expect(installation.frontend, isNotNull);
        expect(catalog.records.definitions, hasLength(2));
        expect(catalog.settings.definitions, hasLength(1));
        expect(
          catalog.issues.single.component,
          PreparedPluginComponent.backend,
        );
        expect(catalog.issues.single.isRecordsSchemaIssue, isFalse);
        expect(catalog.issues.single.message.length, lessThan(256));
      },
    );
  }

  for (final omitted in [false, true]) {
    test(
      'credential opt-in requires record consumption omitted=$omitted',
      () async {
        final components = _credentialConsumer([
          _credentialDeclaration(),
        ], types: []);
        if (omitted) {
          (components['backend']! as Map<String, Object?>).remove(
            'consumesRecordTypes',
          );
        }
        await install(
          'plugin',
          schema: _schema([
            {
              ..._type(),
              'credentialSlots': [_slot()],
            },
          ]),
          components: components,
        );
        final catalog = await PreparedPluginCatalog.discover(root.path);
        expect(catalog.installations.single.backendArtifactUri, isNull);
        expect(catalog.installations.single.frontend, isNotNull);
        expect(
          catalog.issues.single.component,
          PreparedPluginComponent.backend,
        );
      },
    );
  }

  for (final reverse in [false, true]) {
    test(
      'credential opt-in cannot borrow a nested owner slot reverse=$reverse',
      () async {
        await install(
          reverse ? 'z' : 'a',
          id: 'org.example',
          schema: _schema([
            {
              ..._type(),
              'credentialSlots': [_slot()],
            },
          ]),
          components: _credentialConsumer([
            _credentialDeclaration(slots: ['token']),
          ]),
        );
        await install(
          reverse ? 'a' : 'z',
          schema: _schema([
            {
              ..._type(),
              'credentialSlots': [_slot(id: 'token')],
            },
          ]),
          components: _credentialConsumer([
            _credentialDeclaration(slots: ['token']),
          ]),
        );
        final catalog = await PreparedPluginCatalog.discover(root.path);
        final parent = catalog.installations.singleWhere(
          (item) => item.metadata.id.value == 'org.example',
        );
        final child = catalog.installations.singleWhere(
          (item) => item.metadata.id.value == 'org.example.plugin',
        );
        expect(parent.backendArtifactUri, isNull);
        expect(parent.frontend, isNotNull);
        expect(parent.recordsSchema, isNotNull);
        expect(child.backendArtifactUri, isNotNull);
        expect(
          child.backendConsumedCredentialSlots.single.slots.single.value,
          'token',
        );
        expect(catalog.issues.single.pluginId, parent.metadata.id);
        expect(() => catalog.records, throwsA(isA<DuplicateRecordTypeId>()));
      },
    );
    for (final foreign in [
      'org.example.plugin.child.api',
      'org.example.plugin-other.api',
      'org.other.plugin.api',
    ]) {
      test(
        'credential opt-in rejects foreign $foreign reverse=$reverse',
        () async {
          await install(
            reverse ? 'z' : 'a',
            schema: _schema([
              {
                ..._type(),
                'credentialSlots': [_slot()],
              },
            ]),
            components: _credentialConsumer([
              _credentialDeclaration(recordType: foreign),
            ]),
          );
          await install(
            reverse ? 'a' : 'z',
            id: foreign.substring(0, foreign.lastIndexOf('.')),
            schema: _schema([
              {
                ..._type(id: foreign),
                'credentialSlots': [_slot()],
              },
            ]),
            components: _credentialConsumer(
              [_credentialDeclaration(recordType: foreign)],
              types: [foreign],
            ),
          );
          final catalog = await PreparedPluginCatalog.discover(root.path);
          expect(catalog.records.definitions, hasLength(2));
          final owner = catalog.installations.singleWhere(
            (item) => item.metadata.id.value == 'org.example.plugin',
          );
          final sibling = catalog.installations.singleWhere(
            (item) => !identical(item, owner),
          );
          expect(owner.backendArtifactUri, isNull);
          expect(owner.frontend, isNotNull);
          expect(sibling.backendArtifactUri, isNotNull);
          expect(
            sibling.backendConsumedCredentialSlots.single.recordType.value,
            foreign,
          );
          expect(catalog.issues.single.pluginId, owner.metadata.id);
        },
      );
    }
  }

  for (final failure in [
    'absent',
    'missing',
    'malformed',
    'partial',
    'unreadable',
  ]) {
    for (final optIn in [false, true]) {
      test(
        'credential schema $failure with opt-in=$optIn fails locally',
        () async {
          final directory = await install(
            'plugin',
            declareRecords: failure != 'absent',
            reference: failure == 'missing'
                ? 'missing.json'
                : 'records.schema.json',
            schema: failure == 'malformed'
                ? false
                : _schema([
                    {
                      ..._type(),
                      'credentialSlots': [_slot()],
                    },
                    if (failure == 'partial') false,
                  ]),
            components: _credentialConsumer([
              if (optIn) _credentialDeclaration(),
            ], types: []),
          );
          final catalog = failure == 'unreadable'
              ? await IOOverrides.runWithIOOverrides(
                  () => PreparedPluginCatalog.discover(root.path),
                  _UnreadableSchema(
                    directory.uri.resolve('records.schema.json').toFilePath(),
                  ),
                )
              : await PreparedPluginCatalog.discover(root.path);
          final installation = catalog.installations.single;
          expect(installation.recordsSchema, isNull);
          expect(installation.settingsSchema, isNotNull);
          expect(installation.frontend, isNotNull);
          expect(installation.backendArtifactUri, optIn ? isNull : isNotNull);
          expect(installation.backendConsumedCredentialSlots, isEmpty);
          expect(
            catalog.issues.where((issue) => issue.isRecordsSchemaIssue),
            hasLength(failure == 'absent' ? 0 : 1),
          );
          expect(
            catalog.issues.where(
              (issue) => issue.component == PreparedPluginComponent.backend,
            ),
            hasLength(optIn ? 1 : 0),
          );
        },
      );
    }
  }

  for (final dimension in ['types', 'slots']) {
    final limit = dimension == 'types'
        ? PreparedPluginInstallation.maxBackendConsumedCredentialSlotTypes
        : PreparedRecordsSchema.maxCredentialSlots;
    for (final count in [0, limit, limit + 1]) {
      test(
        'credential opt-in $dimension count $count at discovery and construction',
        () async {
          final ids = [
            for (
              var index = 0;
              index < (dimension == 'types' ? count.clamp(0, limit) : 1);
              index++
            )
              'org.example.plugin.t-$index',
          ];
          final slots = [
            for (
              var index = 0;
              index < (dimension == 'slots' ? count.clamp(0, limit) : 1);
              index++
            )
              'slot-$index',
          ];
          final declarations = [
            for (
              var index = 0;
              index < (dimension == 'types' ? count : 1);
              index++
            )
              _credentialDeclaration(
                recordType: ids[index % ids.length],
                slots: dimension == 'slots' && count > limit
                    ? [...slots, 'overflow']
                    : slots,
              ),
          ];
          final directory = await install(
            'plugin',
            schema: _schema([
              for (final id in ids)
                {
                  ..._type(id: id),
                  'credentialSlots': [
                    for (final slot in slots) _slot(id: slot),
                  ],
                },
            ]),
            components: _credentialConsumer(declarations, types: ids),
          );
          final catalog = await PreparedPluginCatalog.discover(root.path);
          final parsed = catalog.installations.single;
          PreparedPluginInstallation construct() => PreparedPluginInstallation(
            metadata: parsed.metadata,
            installationDirectory: directory,
            backendArtifactUri: directory.uri.resolve('backend.aot'),
            recordsSchema: parsed.recordsSchema,
            backendConsumedRecordTypes: ids.map(RecordTypeId.new),
            backendConsumedCredentialSlots: declarations.map(
              (value) => PreparedBackendCredentialSlots(
                recordType: RecordTypeId(value['recordType']! as String),
                slots: (value['slots']! as List<String>).map(
                  RecordCredentialSlotId.new,
                ),
              ),
            ),
          );
          expect(parsed.recordsSchema, isNotNull);
          expect(parsed.frontend, isNotNull);
          if (count <= limit) {
            expect(catalog.issues, isEmpty);
            expect(parsed.backendConsumedCredentialSlotsToJson(), declarations);
            expect(
              construct().backendConsumedCredentialSlotsToJson(),
              declarations,
            );
          } else {
            expect(
              catalog.issues.single.component,
              PreparedPluginComponent.backend,
            );
            expect(parsed.backendArtifactUri, isNull);
            expect(parsed.backendConsumedCredentialSlots, isEmpty);
            expect(construct, throwsFormatException);
          }
        },
      );
    }
  }

  test(
    'credential opt-in accepts exact type and slot ID length bounds',
    () async {
      final type =
          'org.example.plugin.${'x' * (PreparedRecordsSchema.maxIdLength - 'org.example.plugin.'.length)}';
      final slot = 'x' * 64;
      await install(
        'plugin',
        schema: _schema([
          {
            ..._type(id: type),
            'credentialSlots': [_slot(id: slot)],
          },
        ]),
        components: _credentialConsumer(
          [
            _credentialDeclaration(recordType: type, slots: [slot]),
          ],
          types: [type],
        ),
      );
      final catalog = await PreparedPluginCatalog.discover(root.path);
      expect(catalog.issues, isEmpty);
      final parsed = catalog.installations.single;
      expect(
        parsed.backendConsumedCredentialSlots.single.recordType.value,
        type,
      );
      expect(
        parsed.backendConsumedCredentialSlots.single.slots.single.value,
        slot,
      );
      expect(
        () => PreparedBackendCredentialSlots(
          recordType: RecordTypeId('${type}x'),
          slots: [],
        ),
        throwsFormatException,
      );
    },
  );

  for (final failure in [
    'artifact',
    'capabilities',
    'recordTypes',
    'frontend',
    'settings',
  ]) {
    test(
      'credential opt-in remains component-local with invalid $failure',
      () async {
        final components = _credentialConsumer([_credentialDeclaration()]);
        if (failure == 'frontend') {
          components['frontend'] = {
            'artifact': 'frontend.evc',
            'presentations': false,
          };
        } else if (failure != 'settings') {
          (components['backend']! as Map<String, Object?>)[switch (failure) {
            'artifact' => 'artifact',
            'capabilities' => 'consumesCapabilities',
            _ => 'consumesRecordTypes',
          }] = failure == 'artifact'
              ? 'missing.aot'
              : false;
        }
        final directory = await install(
          'plugin',
          schema: _schema([
            {
              ..._type(),
              'credentialSlots': [_slot()],
            },
          ]),
          components: components,
        );
        if (failure == 'settings') {
          await File.fromUri(
            directory.uri.resolve('settings.schema.json'),
          ).writeAsString('{}');
        }
        final catalog = await PreparedPluginCatalog.discover(root.path);
        final parsed = catalog.installations.single;
        final healthyBackend = failure == 'frontend' || failure == 'settings';
        expect(parsed.backendArtifactUri, healthyBackend ? isNotNull : isNull);
        expect(
          parsed.backendConsumedCredentialSlotsToJson(),
          healthyBackend ? [_credentialDeclaration()] : isEmpty,
        );
        expect(parsed.recordsSchema, isNotNull);
        expect(catalog.issues, hasLength(1));
        expect(
          catalog.issues.single.component,
          failure == 'settings'
              ? isNull
              : failure == 'frontend'
              ? PreparedPluginComponent.frontend
              : PreparedPluginComponent.backend,
        );
      },
    );
  }

  test(
    'all field types retain ordered metadata and shared scalar validation',
    () async {
      final directory = await install(
        'plugin',
        schema: _schema([
          _type(id: 'org.example.plugin.z'),
          {
            ..._type(),
            'description': 'Type\nprose',
            'fields': [
              {..._field(id: 'text'), 'description': 'Field\nprose'},
              {
                ..._field(id: 'mode', type: 'enum'),
                'required': true,
                'options': [
                  {'value': 'verbose', 'label': '  Detailed  '},
                  {'value': 'brief'},
                ],
              },
              {
                ..._field(id: 'count', type: 'integer'),
                'minimum': 1,
                'maximum': 3,
              },
              _field(id: 'enabled', type: 'boolean'),
            ],
          },
        ]),
      );
      final catalog = await PreparedPluginCatalog.discover(root.path);
      expect(catalog.issues, isEmpty);
      final schema = catalog.installations.single.recordsSchema!;
      expect(schema.definitions.map((type) => type.id.value), [
        'org.example.plugin.api',
        'org.example.plugin.z',
      ]);
      expect(() => schema.definitions.clear(), throwsUnsupportedError);
      final type = catalog.records.definition(
        RecordTypeId('org.example.plugin.api'),
      );
      expect(type.collection.value, 'providers');
      expect(type.collectionLabel, 'Providers');
      expect(type.label, 'API');
      expect(type.description, 'Type\nprose');
      expect(type.displayField, isNull);
      expect(type.fields.map((field) => field.id.value), [
        'text',
        'mode',
        'count',
        'enabled',
      ]);
      expect(type.fields.first.description, 'Field\nprose');
      expect(type.fields.first.required, isFalse);
      expect(type.fields[1].required, isTrue);
      expect(
        (type.fields[1].type as EnumSettingType).options.map(
          (option) => option.value,
        ),
        ['verbose', 'brief'],
      );
      expect(
        (type.fields[1].type as EnumSettingType).options.first.label,
        '  Detailed  ',
      );
      expect((type.fields[2].type as IntegerSettingType).minimum, 1);
      expect((type.fields[2].type as IntegerSettingType).maximum, 3);
      expect(
        type.validate(ConfigurationRecordId('work'), {
          'text': '\n\u0000',
          'mode': 'brief',
          'count': 2,
          'enabled': false,
          'unknown': Object(),
        }),
        {'text': '\n\u0000', 'mode': 'brief', 'count': 2, 'enabled': false},
      );
      expect(
        () => type.validate(ConfigurationRecordId('work'), {
          'mode': 'brief',
          'count': 4,
        }),
        throwsA(isA<InvalidRecordValue>()),
      );
      await File.fromUri(
        directory.uri.resolve('records.schema.json'),
      ).writeAsString('{}');
      expect(catalog.records.definitions, schema.definitions);
    },
  );

  test(
    'display metadata is optional and captures a declared string field',
    () async {
      final directory = await install(
        'plugin',
        schema: _schema([
          _type(id: 'org.example.plugin.legacy'),
          {
            ..._type(),
            'displayField': 'title',
            'fields': [
              _field(id: 'enabled', type: 'boolean'),
              {..._field(id: 'title'), 'required': true},
            ],
          },
        ]),
      );
      final catalog = await PreparedPluginCatalog.discover(root.path);
      expect(catalog.issues, isEmpty);
      final type = catalog.records.definition(
        RecordTypeId('org.example.plugin.api'),
      );
      expect(type.displayField, RecordFieldId('title'));
      expect(type.fields.map((field) => field.id.value), ['enabled', 'title']);
      expect(catalog.records.definitions.last.displayField, isNull);
      expect(type.validate(ConfigurationRecordId('work'), {'title': ''}), {
        'title': '',
      });
      await File.fromUri(
        directory.uri.resolve('records.schema.json'),
      ).writeAsString('{}');
      expect(
        catalog.records.definitions.first.displayField,
        RecordFieldId('title'),
      );
    },
  );

  test(
    'credential slots are optional ordered metadata isolated by record type',
    () async {
      final directory = await install(
        'plugin',
        schema: _schema([
          {
            ..._type(id: 'org.example.plugin.z'),
            'credentialSlots': [_slot(label: 'Other API key')],
          },
          {
            ..._type(),
            'credentialSlots': [
              _slot(id: 'token', label: '  Token  '),
              _slot(),
            ],
          },
          _type(id: 'org.example.plugin.legacy'),
          {
            ..._type(id: 'org.example.plugin.empty'),
            'credentialSlots': <Object>[],
          },
        ]),
      );
      final catalog = await PreparedPluginCatalog.discover(root.path);
      expect(catalog.issues, isEmpty);
      final records = catalog.records;
      final type = records.definition(RecordTypeId('org.example.plugin.api'));
      expect(type.credentialSlots.map((slot) => slot.id.value), [
        'token',
        'api-key',
      ]);
      expect(type.credentialSlots.map((slot) => slot.label), [
        '  Token  ',
        'API key',
      ]);
      expect(
        type.credentialSlots.every(
          (slot) => slot.kind == RecordCredentialKind.secretText,
        ),
        isTrue,
      );
      expect(() => type.credentialSlots.clear(), throwsUnsupportedError);
      expect(type.fields.single.id, RecordFieldId('display-name'));
      expect(type.validate(ConfigurationRecordId('work'), {}), isEmpty);
      expect(
        records
            .definition(RecordTypeId('org.example.plugin.z'))
            .credentialSlots
            .single
            .label,
        'Other API key',
      );
      for (final id in ['legacy', 'empty']) {
        final slots = records
            .definition(RecordTypeId('org.example.plugin.$id'))
            .credentialSlots;
        expect(slots, isEmpty);
        expect(() => slots.clear(), throwsUnsupportedError);
      }
      await File.fromUri(
        directory.uri.resolve('records.schema.json'),
      ).writeAsString('{}');
      expect(
        catalog.records.definition(type.id).credentialSlots,
        type.credentialSlots,
      );
    },
  );

  test(
    'real OpenAI schema declares display-name and credential slot without code',
    () async {
      var repository = Directory.current;
      while (!File.fromUri(
        repository.uri.resolve('tools/adele.dart'),
      ).existsSync()) {
        if (repository.parent.path == repository.path) {
          throw StateError('Repository root not found.');
        }
        repository = repository.parent;
      }
      final source = await File.fromUri(
        repository.uri.resolve('plugins/openai/records.schema.json'),
      ).readAsString();
      await install(
        'openai',
        id: 'dev.adele.openai',
        schema: jsonDecode(source),
        components: {},
        settings: false,
      );
      final catalog = await PreparedPluginCatalog.discover(root.path);
      expect(catalog.issues, isEmpty);
      final type = catalog.records.definitions.single;
      expect(type.id, RecordTypeId('dev.adele.openai.api-key'));
      expect(type.displayField, RecordFieldId('display-name'));
      final slot = type.credentialSlots.single;
      expect(slot.id, RecordCredentialSlotId('api-key'));
      expect(slot.label, 'API key');
      expect(slot.kind, RecordCredentialKind.secretText);
      expect(type.fields.map((field) => field.id.value), [
        'display-name',
        'endpoint',
      ]);
      expect(
        type.fields.every((field) => field.type is StringSettingType),
        isTrue,
      );
      expect(type.fields.first.required, isTrue);
      expect(type.fields.last.required, isFalse);
      expect(catalog.installations.single.backendArtifactUri, isNull);
      expect(catalog.installations.single.frontend, isNull);
      expect(
        type.validate(ConfigurationRecordId('work'), {'display-name': 'Work'}),
        {'display-name': 'Work'},
      );
    },
  );

  test(
    'descriptions retain arbitrary text unlike single-line labels',
    () async {
      final descriptions = ['', '  ', 'Line\n\tprose\u0000\u2028\u2029'];
      await install(
        'plugin',
        schema: _schema([
          for (var index = 0; index < descriptions.length; index++)
            {
              ..._type(id: 'org.example.plugin.t-$index'),
              'description': descriptions[index],
              'fields': [
                {..._field(), 'description': descriptions[index]},
              ],
            },
        ]),
      );
      final catalog = await PreparedPluginCatalog.discover(root.path);
      expect(catalog.issues, isEmpty);
      expect(
        catalog.records.definitions.map((type) => type.description),
        descriptions,
      );
      expect(
        catalog.records.definitions.map(
          (type) => type.fields.single.description,
        ),
        descriptions,
      );
    },
  );

  test('local schema IDs accept the exact 64-character boundary', () async {
    final id = 'x' * 64;
    await install(
      'plugin',
      schema: _schema([
        {
          ..._type(),
          'collection': id,
          'displayField': id,
          'fields': [
            {..._field(id: id), 'required': true},
          ],
          'credentialSlots': [_slot(id: id)],
        },
      ]),
    );
    final catalog = await PreparedPluginCatalog.discover(root.path);
    expect(catalog.issues, isEmpty);
    expect(catalog.records.definitions.single.collection.value, id);
    expect(catalog.records.definitions.single.fields.single.id.value, id);
    expect(catalog.records.definitions.single.displayField, RecordFieldId(id));
    expect(
      catalog.records.definitions.single.credentialSlots.single.id.value,
      id,
    );
  });

  for (final value in [-9223372036854775808, 9223372036854775807]) {
    test('record bounds preserve native integer extreme $value', () async {
      await install(
        'plugin',
        schema: _schema([
          {
            ..._type(),
            'fields': [
              {..._field(type: 'integer'), 'minimum': value, 'maximum': value},
            ],
          },
        ]),
      );
      final catalog = await PreparedPluginCatalog.discover(root.path);
      expect(catalog.issues, isEmpty);
      final type = catalog.records.definitions.single;
      expect(
        type.validate(ConfigurationRecordId('work'), {'display-name': value}),
        {'display-name': value},
      );
    });
  }

  test(
    'record asset byte bound measures UTF-8 bytes, not text length',
    () async {
      final document = _schema([
        {
          ..._type(),
          'fields': [
            for (
              var index = 0;
              index < PreparedRecordsSchema.maxFields;
              index++
            )
              {
                ..._field(id: 'f-$index'),
                'description':
                    '\u00e9' * PreparedRecordsSchema.maxDescriptionLength,
              },
          ],
        },
      ]);
      final text = jsonEncode(document);
      expect(text.length, lessThan(PreparedRecordsSchema.maxBytes));
      expect(
        utf8.encode(text).length,
        greaterThan(PreparedRecordsSchema.maxBytes),
      );
      await install('plugin', schema: document);
      final catalog = await PreparedPluginCatalog.discover(root.path);
      rejected(catalog);
      expect(catalog.issues.single.message, contains('bytes'));
    },
  );

  test(
    'programmatic installations cannot relabel another record schema owner',
    () async {
      final directory = await install('plugin', schema: _schema([_type()]));
      final schema = (await PreparedPluginCatalog.discover(
        root.path,
      )).installations.single.recordsSchema!;
      PreparedPluginInstallation installation(String owner) =>
          PreparedPluginInstallation(
            metadata: PluginMetadata(
              id: PluginId(owner),
              version: '1',
              displayName: 'Example',
            ),
            installationDirectory: directory,
            backendArtifactUri: null,
            recordsSchema: schema,
          );
      expect(installation('org.example.plugin').recordsSchema, same(schema));
      expect(() => installation('org.example'), throwsFormatException);
      expect(() => installation('org.other.plugin'), throwsFormatException);
    },
  );

  test(
    'broken settings and executable components retain healthy records',
    () async {
      final directory = await install(
        'broken',
        schema: _schema([_type()]),
        components: {
          'backend': {'artifact': 'missing'},
          'frontend': {'artifact': 'frontend.evc', 'presentations': false},
        },
      );
      await File.fromUri(
        directory.uri.resolve('settings.schema.json'),
      ).writeAsString('{}');
      final catalog = await PreparedPluginCatalog.discover(root.path);
      final installation = catalog.installations.single;
      expect(installation.recordsSchema, isNotNull);
      expect(catalog.records.definitions, hasLength(1));
      expect(installation.settingsSchema, isNull);
      expect(installation.backendArtifactUri, isNull);
      expect(installation.frontend, isNull);
      expect(catalog.issues, hasLength(3));
      expect(
        catalog.issues.every((issue) => !issue.isRecordsSchemaIssue),
        isTrue,
      );
    },
  );

  for (final component in ['backend', 'frontend']) {
    test(
      'recordsSchema is installation-only, not $component metadata',
      () async {
        await install(
          'plugin',
          declareRecords: false,
          components: {
            ..._components,
            component: {
              ..._components[component]! as Map<String, Object?>,
              'recordsSchema': 'records.schema.json',
            },
          },
        );
        final catalog = await PreparedPluginCatalog.discover(root.path);
        expect(catalog.installations.single.recordsSchema, isNull);
        expect(catalog.issues.single.component?.name, component);
        expect(catalog.issues.single.isRecordsSchemaIssue, isFalse);
      },
    );
  }

  test(
    'malformed metadata-only record schema preserves the installation',
    () async {
      await install('plugin', schema: false, components: {}, settings: false);
      final catalog = await PreparedPluginCatalog.discover(root.path);
      expect(catalog.installations, hasLength(1));
      expect(catalog.records.definitions, isEmpty);
      expect(catalog.issues.single.isRecordsSchemaIssue, isTrue);
    },
  );

  final badSchemas = <String, Object?>{
    'not object': [],
    'null': null,
    'missing version': {'recordTypes': <Object?>[]},
    'missing types': {'schemaVersion': 1},
    'unknown envelope': {..._schema([]), 'owner': 'org.other'},
    'slots at envelope': {
      ..._schema([]),
      'credentialSlots': [_slot()],
    },
    'settings envelope': {'schemaVersion': 1, 'definitions': <Object?>[]},
    for (final version in [null, false, '1', 1.0, 0, -1, 2])
      'version $version ${version.runtimeType}': {
        ..._schema([]),
        'schemaVersion': version,
      },
    for (final types in <Object?>[null, false, 'types', 1, {}])
      'types $types': {'schemaVersion': 1, 'recordTypes': types},
  };
  for (final entry in badSchemas.entries) {
    test('rejects schema ${entry.key}', () async {
      await install('plugin', schema: entry.value);
      rejected(await PreparedPluginCatalog.discover(root.path));
    });
  }

  final badTypes = <String, Object?>{
    'not object': [],
    'null': null,
    for (final field in _type().keys) 'missing $field': _type()..remove(field),
    for (final field in ['owner', 'default', 'nullable', 'validate', 'unknown'])
      'extra $field': {..._type(), field: true},
    for (final id in [
      'org.example.plugin',
      'org.example.plugin2.api',
      'org.example.plugin-other.api',
      'org.other.api',
      'Api',
      'org..api',
    ])
      'bad ID $id': _type(id: id),
    for (final collection in [
      null,
      1,
      'Providers',
      'a.b',
      'a_b',
      'con',
      'lpt9',
      '../a',
      'x' * 65,
    ])
      'collection $collection': {..._type(), 'collection': collection},
    for (final field in ['label', 'collectionLabel'])
      for (final text in [
        null,
        false,
        '',
        ' ',
        'two\nlines',
        'a\u0000b',
        'a\u2028b',
      ])
        '$field $text': {..._type(), field: text},
    'description null': {..._type(), 'description': null},
    'description object': {..._type(), 'description': <String, Object?>{}},
    for (final displayField in <Object?>[
      null,
      false,
      1,
      [],
      {},
      '',
      ' display-name',
      'Display-name',
      'display.name',
      'x' * 65,
      'missing',
    ])
      'displayField ${jsonEncode(displayField)}': {
        ..._type(),
        'displayField': displayField,
        'fields': [
          {..._field(), 'required': true},
        ],
      },
    'displayField with no fields': {
      ..._type(),
      'displayField': 'display-name',
      'fields': <Object?>[],
    },
    'displayField optional string': {
      ..._type(),
      'displayField': 'display-name',
    },
    for (final kind in ['boolean', 'integer', 'enum'])
      'displayField $kind': {
        ..._type(),
        'displayField': 'display-name',
        'fields': [
          {
            ..._field(type: kind),
            'required': true,
            if (kind == 'enum')
              'options': [
                {'value': 'name'},
              ],
          },
        ],
      },
    for (final fields in <Object?>[null, false, {}, 'fields'])
      'fields $fields': {..._type(), 'fields': fields},
    'duplicate fields': {
      ..._type(),
      'fields': [_field(), _field()],
    },
    for (final slots in <Object?>[null, false, {}, 'slots', 1])
      'credentialSlots $slots': {..._type(), 'credentialSlots': slots},
    'duplicate credential slots': {
      ..._type(),
      'credentialSlots': [_slot(), _slot(label: 'Different label')],
    },
  };
  for (final entry in badTypes.entries) {
    test('rejects whole schema for record type ${entry.key}', () async {
      await install(
        'plugin',
        schema: _schema([_type(id: 'org.example.plugin.valid'), entry.value]),
      );
      rejected(await PreparedPluginCatalog.discover(root.path));
    });
  }

  final badFields = <String, Object?>{
    'not object': [],
    'null': null,
    for (final key in _field().keys) 'missing $key': _field()..remove(key),
    for (final key in [
      'default',
      'owner',
      'nullable',
      'secret',
      'credentialSlots',
      'displayField',
      'validate',
      'unknown',
      'minimum',
      'options',
    ])
      'unsupported $key': {..._field(), key: true},
    for (final id in [null, 1, 'UPPER', 'a.b', 'a_b', 'a-', 'x' * 65])
      'ID $id': {..._field(), 'id': id},
    for (final type in [
      null,
      false,
      'number',
      'array',
      'object',
      'String',
      'secret-text',
    ])
      'type $type': {..._field(), 'type': type},
    for (final required in <Object?>[null, 0, 'true', [], {}])
      'required $required': {..._field(), 'required': required},
    for (final text in [null, 1, '', ' ', 'a\nb', 'a\u0000b'])
      'label $text': {..._field(), 'label': text},
    'null description': {..._field(), 'description': null},
    for (final bound in ['minimum', 'maximum'])
      for (final value in <Object?>[null, false, '1', 1.0, [], {}])
        '$bound $value': {..._field(type: 'integer'), bound: value},
    'inverted bounds': {..._field(type: 'integer'), 'minimum': 3, 'maximum': 1},
    'enum missing options': _field(type: 'enum'),
    for (final options in <Object?>[
      null,
      {},
      [],
      [null],
      ['one'],
      [<String, Object?>{}],
      [
        {'value': 'one', 'extra': true},
      ],
      [
        {'value': ''},
      ],
      [
        {'value': ' one'},
      ],
      [
        {'value': 'one\ntwo'},
      ],
      [
        {'value': 'one', 'label': null},
      ],
      [
        {'value': 'one', 'label': ''},
      ],
      [
        {'value': 'one'},
        {'value': 'one'},
      ],
    ])
      'options ${jsonEncode(options)}': {
        ..._field(type: 'enum'),
        'options': options,
      },
  };
  for (final entry in badFields.entries) {
    test('rejects whole schema for field ${entry.key}', () async {
      await install(
        'plugin',
        schema: _schema([
          _type(id: 'org.example.plugin.valid'),
          {
            ..._type(),
            'fields': [_field(id: 'valid'), entry.value],
          },
        ]),
      );
      rejected(await PreparedPluginCatalog.discover(root.path));
    });
  }

  final badSlots = <String, Object?>{
    'not object': [],
    'null': null,
    for (final key in _slot().keys) 'missing $key': _slot()..remove(key),
    for (final key in [
      'description',
      'required',
      'default',
      'value',
      'secret',
      'reference',
      'type',
      'unknown',
    ])
      'unsupported $key': {..._slot(), key: true},
    for (final id in <Object?>[
      null,
      false,
      1,
      '',
      'UPPER',
      'a.b',
      'a_b',
      'a-',
      'a--b',
      '1a',
      '../a',
      'a/b',
      ' a',
      'a ',
      'a\n',
      'a\u0000',
      'caf\u00e9',
      'x' * 65,
    ])
      'ID ${jsonEncode(id)}': {..._slot(), 'id': id},
    for (final label in <Object?>[
      null,
      1,
      '',
      ' ',
      '\t',
      'a\nb',
      'a\rb',
      'a\u0000b',
      'a\u007fb',
      'a\u0085b',
      'a\u2028b',
      'a\u2029b',
      'x' * 129,
    ])
      'label ${jsonEncode(label)}': {..._slot(), 'label': label},
    for (final kind in <Object?>[
      null,
      false,
      1,
      [],
      {},
      '',
      'secretText',
      'Secret-text',
      ' secret-text',
      'string',
      'oauth',
    ])
      'kind ${jsonEncode(kind)}': {..._slot(), 'kind': kind},
  };
  for (final entry in badSlots.entries) {
    test('rejects whole schema for credential slot ${entry.key}', () async {
      await install(
        'plugin',
        schema: _schema([
          {
            ..._type(id: 'org.example.plugin.valid'),
            'credentialSlots': [_slot()],
          },
          {
            ..._type(),
            'credentialSlots': [_slot(id: 'valid'), entry.value],
          },
        ]),
      );
      rejected(await PreparedPluginCatalog.discover(root.path));
    });
  }

  for (final conflicting in [false, true]) {
    test(
      'same-schema ${conflicting ? 'collection labels' : 'duplicate types'} reject whole schema',
      () async {
        await install(
          'plugin',
          schema: _schema([
            _type(),
            {
              ..._type(
                id: conflicting
                    ? 'org.example.plugin.other'
                    : 'org.example.plugin.api',
              ),
              if (conflicting) 'collectionLabel': 'Other',
            },
          ]),
        );
        rejected(await PreparedPluginCatalog.discover(root.path));
      },
    );
  }

  for (final reverse in [false, true]) {
    for (final conflict in [false, true]) {
      test(
        'cross-installation aggregation conflict=$conflict reverse=$reverse',
        () async {
          await install(
            reverse ? 'z' : 'a',
            id: 'org.example',
            schema: _schema([_type()]),
          );
          await install(
            reverse ? 'a' : 'z',
            schema: _schema([
              {
                ..._type(
                  id: conflict
                      ? 'org.example.plugin.other'
                      : 'org.example.plugin.api',
                ),
                if (conflict) 'collectionLabel': 'Other',
              },
            ]),
          );
          final catalog = await PreparedPluginCatalog.discover(root.path);
          expect(catalog.issues, isEmpty);
          expect(catalog.installations, hasLength(2));
          expect(catalog.settings.definitions, hasLength(2));
          expect(
            () => catalog.records,
            throwsA(
              conflict
                  ? isA<ConflictingRecordCollectionLabel>()
                  : isA<DuplicateRecordTypeId>(),
            ),
          );
        },
      );
    }
  }

  test('catalog aggregation orders type IDs, not installations', () async {
    await install(
      'a',
      id: 'org.example.z',
      schema: _schema([_type(id: 'org.example.z.type')]),
    );
    await install(
      'z',
      id: 'org.example.a',
      schema: _schema([_type(id: 'org.example.a.type')]),
    );
    final catalog = await PreparedPluginCatalog.discover(root.path);
    expect(catalog.issues, isEmpty);
    expect(catalog.records.definitions.map((type) => type.id.value), [
      'org.example.a.type',
      'org.example.z.type',
    ]);
  });

  test(
    'duplicate plugin identities contribute no record definitions',
    () async {
      await install('a', schema: _schema([_type()]));
      await install('z', schema: false);
      final catalog = await PreparedPluginCatalog.discover(root.path);
      expect(catalog.installations, isEmpty);
      expect(catalog.records.definitions, isEmpty);
      expect(
        catalog.issues.where((issue) => issue.isRecordsSchemaIssue),
        hasLength(1),
      );
      expect(
        catalog.issues.where(
          (issue) => issue.message.contains('Duplicate PluginId'),
        ),
        hasLength(2),
      );
    },
  );

  for (final extra in [0, 1]) {
    test('credential slot count boundary plus $extra', () async {
      await install(
        'plugin',
        schema: _schema([
          {
            ..._type(),
            'credentialSlots': [
              for (
                var index = 0;
                index < PreparedRecordsSchema.maxCredentialSlots + extra;
                index++
              )
                _slot(id: 'key-$index', label: 'x' * 128),
            ],
          },
        ]),
      );
      final catalog = await PreparedPluginCatalog.discover(root.path);
      if (extra == 0) {
        expect(catalog.issues, isEmpty);
        expect(
          catalog.records.definitions.single.credentialSlots,
          hasLength(PreparedRecordsSchema.maxCredentialSlots),
        );
      } else {
        rejected(catalog);
      }
    });
    for (final kind in ['types', 'fields', 'options']) {
      test('$kind count boundary plus $extra', () async {
        final count =
            switch (kind) {
              'types' => PreparedRecordsSchema.maxRecordTypes,
              'fields' => PreparedRecordsSchema.maxFields,
              _ => PreparedRecordsSchema.maxEnumOptions,
            } +
            extra;
        await install(
          'plugin',
          schema: _schema(
            kind == 'types'
                ? [
                    for (var index = 0; index < count; index++)
                      _type(id: 'org.example.plugin.t-$index'),
                  ]
                : [
                    {
                      ..._type(),
                      'fields': kind == 'fields'
                          ? [
                              for (var index = 0; index < count; index++)
                                _field(id: 'f-$index'),
                            ]
                          : [
                              {
                                ..._field(type: 'enum'),
                                'options': [
                                  for (var index = 0; index < count; index++)
                                    {'value': 'v-$index'},
                                ],
                              },
                            ],
                    },
                  ],
          ),
        );
        final catalog = await PreparedPluginCatalog.discover(root.path);
        if (extra == 0) {
          expect(catalog.issues, isEmpty);
        } else {
          rejected(catalog);
        }
      });
    }
    for (final kind in [
      'id',
      'collectionLabel',
      'label',
      'description',
      'field label',
      'field description',
      'option value',
      'option label',
    ]) {
      test('$kind length boundary plus $extra', () async {
        final count =
            (kind == 'id'
                ? PreparedRecordsSchema.maxIdLength
                : kind.endsWith('description')
                ? PreparedRecordsSchema.maxDescriptionLength
                : PreparedRecordsSchema.maxLabelLength) +
            extra;
        final text = 'x' * count;
        final type = _type();
        if (kind.startsWith('field ')) {
          type['fields'] = [
            {..._field(), kind.substring(6): text},
          ];
        } else if (kind.startsWith('option ')) {
          type['fields'] = [
            {
              ..._field(type: 'enum'),
              'options': [
                {
                  'value': kind == 'option value' ? text : 'value',
                  if (kind == 'option label') 'label': text,
                },
              ],
            },
          ];
        } else {
          type[kind] = kind == 'id'
              ? 'org.example.plugin.${'x' * (count - 'org.example.plugin.'.length)}'
              : text;
        }
        await install('plugin', schema: _schema([type]));
        final catalog = await PreparedPluginCatalog.discover(root.path);
        if (extra == 0) {
          expect(catalog.issues, isEmpty);
        } else {
          rejected(catalog);
        }
      });
    }
    test('bounded schema read plus $extra bytes', () async {
      final directory = await install('plugin');
      final document = jsonEncode(_schema([]));
      await File.fromUri(
        directory.uri.resolve('records.schema.json'),
      ).writeAsString(
        '$document${' ' * (PreparedRecordsSchema.maxBytes - document.length + extra)}',
      );
      final catalog = await PreparedPluginCatalog.discover(root.path);
      if (extra == 0) {
        expect(catalog.issues, isEmpty);
      } else {
        rejected(catalog);
      }
    });
  }

  for (final source in [
    '',
    '{',
    'null',
    '\ufeff{}',
    for (final value in ['9223372036854775808', '-9223372036854775809', '1e0'])
      jsonEncode(
        _schema([
          {
            ..._type(),
            'fields': [
              {..._field(type: 'integer'), 'minimum': 'NUMBER'},
            ],
          },
        ]),
      ).replaceFirst('"NUMBER"', value),
  ]) {
    test('malformed JSON or non-native bound ${jsonEncode(source)}', () async {
      final directory = await install('plugin');
      await File.fromUri(
        directory.uri.resolve('records.schema.json'),
      ).writeAsString(source);
      rejected(await PreparedPluginCatalog.discover(root.path));
    });
  }

  test('invalid UTF-8 rejects records only', () async {
    final directory = await install('plugin');
    await File.fromUri(
      directory.uri.resolve('records.schema.json'),
    ).writeAsBytes([0xff]);
    rejected(await PreparedPluginCatalog.discover(root.path));
  });

  for (final reference in <Object?>[
    null,
    1,
    false,
    [],
    {},
    '',
    ' ',
    '/',
    '/tmp/records.json',
    '../records.json',
    'nested/../../records.json',
    './records.json',
    'nested/../records.json',
    'nested//records.json',
    'nested/./records.json',
    'nested/',
    r'C:\records.json',
    'C:/records.json',
    r'nested\records.json',
    '//server/records.json',
    'file:records.json',
    'file:///tmp/records.json',
    'https://example.com/records.json',
    'records.json?query',
    'records.json#fragment',
    '%2e%2e/records.json',
    'records.json\u0000',
    'bad|name.json',
    'bad*.json',
    'missing.json',
  ]) {
    test('rejects record schema path ${jsonEncode(reference)}', () async {
      await install('plugin', reference: reference);
      rejected(await PreparedPluginCatalog.discover(root.path));
    });
  }

  test(
    'unreadable schema preserves sibling declarations and components',
    () async {
      final directory = await install('plugin');
      final catalog = await IOOverrides.runWithIOOverrides(
        () => PreparedPluginCatalog.discover(root.path),
        _UnreadableSchema(
          directory.uri.resolve('records.schema.json').toFilePath(),
        ),
      );
      rejected(catalog);
      expect(
        catalog.issues.single.message,
        contains('Unable to read records schema'),
      );
      expect(catalog.issues.single.message, contains('Injected read failure'));
    },
  );

  test('directories and FIFOs are rejected before schema reads', () async {
    final directory = await install('plugin', reference: 'folder');
    await Directory.fromUri(directory.uri.resolve('folder/')).create();
    rejected(await PreparedPluginCatalog.discover(root.path));
    if (Platform.isLinux) {
      await Directory.fromUri(directory.uri.resolve('folder/')).delete();
      expect(
        (await Process.run('mkfifo', ['${directory.path}/folder'])).exitCode,
        0,
      );
      rejected(await PreparedPluginCatalog.discover(root.path));
    }
  });

  group(
    'record schema symlinks',
    () {
      for (final ancestor in [false, true]) {
        test('escape rejected with ancestor=$ancestor', () async {
          final directory = await install(
            'plugin',
            reference: ancestor ? 'linked/records.json' : 'linked.json',
          );
          final outside = await Directory.fromUri(
            temporary.uri.resolve('outside/'),
          ).create();
          final file = await File.fromUri(
            outside.uri.resolve('records.json'),
          ).writeAsString(jsonEncode(_schema([])));
          await Link.fromUri(
            directory.uri.resolve(ancestor ? 'linked' : 'linked.json'),
          ).create(ancestor ? outside.path : file.path);
          rejected(await PreparedPluginCatalog.discover(root.path));
        });
      }
      test(
        'confined link and linked root retain canonical schema URI',
        () async {
          final directory = await install('plugin', reference: 'linked.json');
          await Link.fromUri(
            directory.uri.resolve('linked.json'),
          ).create('records.schema.json');
          final rootLink = await Link.fromUri(
            temporary.uri.resolve('root-link'),
          ).create(root.path);
          final catalog = await PreparedPluginCatalog.discover(rootLink.path);
          expect(catalog.issues, isEmpty);
          expect(
            catalog.installations.single.recordsSchema!.artifactUri,
            directory.uri.resolve('records.schema.json'),
          );
        },
      );
      test('dangling link rejects schema', () async {
        final directory = await install('plugin', reference: 'linked.json');
        await Link.fromUri(
          directory.uri.resolve('linked.json'),
        ).create('missing.json');
        rejected(await PreparedPluginCatalog.discover(root.path));
      });
    },
    skip: Platform.isWindows ? 'Symlink creation requires privileges.' : false,
  );
}

const _components = <String, Object?>{
  'backend': {'artifact': 'backend.aot'},
  'frontend': {'artifact': 'frontend.evc', 'presentations': <Object?>[]},
};
Map<String, Object?> _recordConsumer(Object? types) => {
  ..._components,
  'backend': {
    'artifact': 'backend.aot',
    'consumesRecordTypes': types,
    'consumesCapabilities': [
      {'id': 'org.example.read', 'majorVersion': 1},
    ],
  },
};
Map<String, Object?> _credentialDeclaration({
  String recordType = 'org.example.plugin.api',
  Object? slots = const ['api-key'],
}) => {'recordType': recordType, 'slots': slots};
Map<String, Object?> _credentialConsumer(
  Object? declarations, {
  Object? types = const ['org.example.plugin.api'],
}) {
  final components = _recordConsumer(types);
  (components['backend']! as Map<String, Object?>)['consumesCredentialSlots'] =
      declarations;
  return components;
}

Map<String, Object?> _schema(List<Object?> types) => {
  'schemaVersion': 1,
  'recordTypes': types,
};
Map<String, Object?> _type({String id = 'org.example.plugin.api'}) => {
  'id': id,
  'collection': 'providers',
  'collectionLabel': 'Providers',
  'label': 'API',
  'fields': [_field()],
};
Map<String, Object?> _field({
  String id = 'display-name',
  String type = 'string',
}) => {'id': id, 'label': 'Name', 'type': type, 'required': false};

Map<String, Object?> _slot({String id = 'api-key', String label = 'API key'}) =>
    {'id': id, 'label': label, 'kind': 'secret-text'};

final class _UnreadableSchema extends IOOverrides {
  _UnreadableSchema(this.path);
  final String path;
  final Zone _zone = Zone.current;
  @override
  Future<FileSystemEntityType> fseGetType(String path, bool followLinks) =>
      _zone.run(() => FileSystemEntity.type(path, followLinks: followLinks));
  @override
  File createFile(String path) {
    final file = super.createFile(path);
    return path == this.path ? _UnreadableFile(file) : file;
  }
}

final class _UnreadableFile implements File {
  _UnreadableFile(this.file);
  final File file;
  @override
  String get path => file.path;
  @override
  Uri get uri => file.uri;
  @override
  Future<String> resolveSymbolicLinks() => file.resolveSymbolicLinks();
  @override
  Stream<List<int>> openRead([int? start, int? end]) =>
      Stream.error(FileSystemException('Injected read failure', path));
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
