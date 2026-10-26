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
                schema: _schema([_type()]),
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
    'real OpenAI schema declares its display-name without executable code',
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
        },
      ]),
    );
    final catalog = await PreparedPluginCatalog.discover(root.path);
    expect(catalog.issues, isEmpty);
    expect(catalog.records.definitions.single.collection.value, id);
    expect(catalog.records.definitions.single.fields.single.id.value, id);
    expect(catalog.records.definitions.single.displayField, RecordFieldId(id));
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
      'displayField',
      'validate',
      'unknown',
      'minimum',
      'options',
    ])
      'unsupported $key': {..._field(), key: true},
    for (final id in [null, 1, 'UPPER', 'a.b', 'a_b', 'a-', 'x' * 65])
      'ID $id': {..._field(), 'id': id},
    for (final type in [null, false, 'number', 'array', 'object', 'String'])
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
