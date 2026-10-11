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
    temporary = await Directory.systemTemp.createTemp('prepared settings ');
    root = await Directory.fromUri(
      temporary.uri.resolve('installations/'),
    ).create();
  });
  tearDown(() => temporary.delete(recursive: true));

  Future<Directory> install(
    String name, {
    String id = 'org.example.plugin',
    Object? schema = const {'schemaVersion': 1, 'definitions': <Object?>[]},
    Object? reference = 'settings.schema.json',
    bool declareSchema = true,
    Map<String, Object?> components = const {},
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
        if (declareSchema) 'settingsSchema': reference,
      }),
    );
    await File.fromUri(
      directory.uri.resolve('settings.schema.json'),
    ).writeAsString(jsonEncode(schema));
    for (final artifact in ['backend.aot', 'frontend.evc']) {
      await File.fromUri(directory.uri.resolve(artifact)).writeAsString(
        'Not executable: schema discovery must not load components.',
      );
    }
    return directory;
  }

  void expectRejected(PreparedPluginCatalog catalog, {bool components = true}) {
    expect(
      catalog.installations,
      hasLength(1),
      reason: catalog.issues.join('\n'),
    );
    final installation = catalog.installations.single;
    expect(installation.settingsSchema, isNull);
    expect(catalog.settings.definitions, isEmpty);
    expect(installation.backendArtifactUri, components ? isNotNull : isNull);
    expect(installation.frontend, components ? isNotNull : isNull);
    final issue = catalog.issues.single;
    expect(issue.isSettingsSchemaIssue, isTrue);
    expect(issue.component, isNull);
    expect(issue.pluginId, installation.metadata.id);
    expect(
      issue.installationDirectory.uri,
      installation.installationDirectory.uri,
    );
    expect(issue.message.toLowerCase(), contains('settings schema'));
  }

  for (final backend in [false, true]) {
    for (final frontend in [false, true]) {
      for (final declareSchema in [false, true]) {
        test(
          'independent schema=$declareSchema backend=$backend frontend=$frontend',
          () async {
            final directory = await install(
              'plugin',
              declareSchema: declareSchema,
              schema: _schema([_definition()]),
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
            if (declareSchema) {
              expect(
                installation.settingsSchema!.artifactUri,
                directory.uri.resolve('settings.schema.json'),
              );
              expect(
                catalog.settings.definitions.single.owner,
                SettingOwnerId('org.example.plugin'),
              );
            } else {
              expect(installation.settingsSchema, isNull);
              expect(catalog.settings.definitions, isEmpty);
            }
          },
        );
      }
    }
  }

  test(
    'empty roots and empty schemas assemble empty settings catalogs',
    () async {
      for (final path in ['', root.path, '${root.path}/missing']) {
        expect(
          (await PreparedPluginCatalog.discover(path)).settings.definitions,
          isEmpty,
        );
      }
      await install('empty');
      final catalog = await PreparedPluginCatalog.discover(root.path);
      expect(catalog.issues, isEmpty);
      expect(catalog.installations.single.settingsSchema, isNotNull);
      expect(catalog.settings.definitions, isEmpty);
    },
  );

  test(
    'CFG3 scalars retain metadata, constraints, typed resolution, and snapshots',
    () async {
      final directory = await install(
        'scalar',
        schema: _schema([
          _definition(
            id: 'org.example.plugin.text',
            type: 'string',
            defaultValue: '',
          ),
          {
            ..._definition(
              id: 'org.example.plugin.mode',
              type: 'enum',
              defaultValue: 'brief',
            ),
            'options': [
              {'value': 'verbose', 'label': '  Detailed  '},
              {'value': 'brief'},
            ],
          },
          {
            ..._definition(
              id: 'org.example.plugin.count',
              type: 'integer',
              defaultValue: 2,
            ),
            'minimum': 1,
            'maximum': 3,
            'label': '  Count  ',
            'description': 'Two lines.\nAnother line.',
          },
          _definition(),
        ]),
      );
      final catalog = await PreparedPluginCatalog.discover(root.path);
      expect(catalog.issues, isEmpty);
      final schema = catalog.installations.single.settingsSchema!;
      expect(schema.definitions.map((definition) => definition.id.value), [
        'org.example.plugin.count',
        'org.example.plugin.enabled',
        'org.example.plugin.mode',
        'org.example.plugin.text',
      ]);
      expect(() => schema.definitions.clear(), throwsUnsupportedError);
      final settings = catalog.settings;
      expect(settings.definitions, schema.definitions);
      expect(() => settings.definitions.clear(), throwsUnsupportedError);
      final count = settings.definition(SettingId('org.example.plugin.count'));
      expect(count.type, isA<IntegerSettingType>());
      expect((count.type as IntegerSettingType).minimum, 1);
      expect((count.type as IntegerSettingType).maximum, 3);
      expect(count.label, '  Count  ');
      expect(count.category, 'General');
      expect(count.section, 'Output');
      expect(count.description, 'Two lines.\nAnother line.');
      final inherited = settings.resolve<int>(count.id);
      expect(inherited.value, 2);
      expect(inherited.source, SettingValueSource.defaultValue);
      expect(inherited.hasGlobalOverride, isFalse);
      final explicit = settings.resolve<int>(
        count.id,
        globalOverrides: {count.id: 2},
      );
      expect(explicit.source, SettingValueSource.global);
      expect(explicit.hasGlobalOverride, isTrue);
      expect(
        () => settings.resolve<int>(count.id, globalOverrides: {count.id: 4}),
        throwsA(isA<InvalidSettingOverride>()),
      );
      expect(
        settings.resolve<bool>(SettingId('org.example.plugin.enabled')).value,
        isTrue,
      );
      expect(
        settings.resolve<String>(SettingId('org.example.plugin.text')).value,
        '',
      );
      final mode = settings.definition(SettingId('org.example.plugin.mode'));
      expect(settings.resolve<String>(mode.id).value, 'brief');
      final options = (mode.type as EnumSettingType).options;
      expect(options.map((option) => option.value), ['verbose', 'brief']);
      expect(options.first.label, '  Detailed  ');
      expect(options.last.label, isNull);
      expect(() => options.clear(), throwsUnsupportedError);
      await File.fromUri(
        directory.uri.resolve('settings.schema.json'),
      ).writeAsString('{}');
      expect(catalog.settings.definitions, schema.definitions);
    },
  );

  test('ordinary string defaults stay unconstrained text', () async {
    final text = ' \n\u0000${'x' * 10000}';
    await install(
      'text',
      schema: _schema([_definition(type: 'string', defaultValue: text)]),
    );
    final catalog = await PreparedPluginCatalog.discover(root.path);
    expect(catalog.issues, isEmpty);
    expect(catalog.settings.definitions.single.defaultValue, text);
  });

  test(
    'nested setting IDs and one-sided integer bounds use CFG3 semantics',
    () async {
      await install(
        'nested',
        schema: _schema([
          {
            ..._definition(
              id: 'org.example.plugin.nested.lower',
              type: 'integer',
              defaultValue: 1,
            ),
            'minimum': 1,
          },
          {
            ..._definition(
              id: 'org.example.plugin.nested.upper',
              type: 'integer',
              defaultValue: -1,
            ),
            'maximum': -1,
          },
          {..._definition(defaultValue: false), 'description': ''},
        ]),
      );
      final catalog = await PreparedPluginCatalog.discover(root.path);
      expect(catalog.issues, isEmpty);
      final settings = catalog.settings;
      expect(
        settings
            .definition(SettingId('org.example.plugin.nested.lower'))
            .validate(9223372036854775807),
        9223372036854775807,
      );
      expect(
        settings
            .definition(SettingId('org.example.plugin.nested.upper'))
            .validate(-9223372036854775808),
        -9223372036854775808,
      );
      expect(
        settings.resolve<bool>(SettingId('org.example.plugin.enabled')).value,
        isFalse,
      );
    },
  );

  test(
    'programmatic installations cannot relabel another schema owner',
    () async {
      final directory = await install(
        'plugin',
        schema: _schema([_definition()]),
      );
      final schema = (await PreparedPluginCatalog.discover(
        root.path,
      )).installations.single.settingsSchema!;
      PreparedPluginInstallation installation(String id) =>
          PreparedPluginInstallation(
            metadata: PluginMetadata(
              id: PluginId(id),
              version: '1',
              displayName: 'Example',
            ),
            installationDirectory: directory,
            backendArtifactUri: null,
            settingsSchema: schema,
          );
      expect(installation('org.example.plugin').settingsSchema, same(schema));
      expect(() => installation('org.example'), throwsFormatException);
      expect(() => installation('org.other.plugin'), throwsFormatException);
    },
  );

  for (final component in ['backend', 'frontend']) {
    test('schema references are not accepted inside $component', () async {
      await install(
        'wrong-scope',
        declareSchema: false,
        components: {
          ..._components,
          component: {
            ..._components[component]! as Map<String, Object?>,
            'settingsSchema': 'settings.schema.json',
          },
        },
      );
      final catalog = await PreparedPluginCatalog.discover(root.path);
      expect(catalog.installations.single.settingsSchema, isNull);
      expect(catalog.settings.definitions, isEmpty);
      expect(catalog.issues.single.component?.name, component);
      expect(catalog.issues.single.isSettingsSchemaIssue, isFalse);
    });
  }

  for (final value in [-9223372036854775808, 9223372036854775807]) {
    test('native integer extreme $value is preserved exactly', () async {
      await install(
        'integer',
        schema: _schema([
          {
            ..._definition(type: 'integer', defaultValue: value),
            'minimum': value,
            'maximum': value,
          },
        ]),
      );
      final catalog = await PreparedPluginCatalog.discover(root.path);
      expect(catalog.issues, isEmpty);
      expect(catalog.settings.definitions.single.defaultValue, value);
    });
  }

  test(
    'aggregation sorts setting IDs, not directories, labels, or schema order',
    () async {
      await install(
        'a',
        id: 'org.example.zulu',
        schema: _schema([
          _definition(id: 'org.example.zulu.z'),
          _definition(id: 'org.example.zulu.a'),
        ]),
      );
      await install(
        'z',
        id: 'org.example.alpha',
        schema: _schema([_definition(id: 'org.example.alpha.enabled')]),
      );
      final catalog = await PreparedPluginCatalog.discover(root.path);
      expect(catalog.issues, isEmpty);
      expect(
        catalog.installations.map(
          (installation) => installation.metadata.id.value,
        ),
        ['org.example.zulu', 'org.example.alpha'],
      );
      expect(
        catalog.settings.definitions.map((definition) => definition.id.value),
        [
          'org.example.alpha.enabled',
          'org.example.zulu.a',
          'org.example.zulu.z',
        ],
      );
    },
  );

  test(
    'same-schema duplicate IDs reject the entire schema, not a partial catalog',
    () async {
      await install(
        'duplicate',
        components: _components,
        schema: _schema([
          _definition(id: 'org.example.plugin.unique'),
          _definition(),
          _definition(type: 'string', defaultValue: 'different'),
        ]),
      );
      final catalog = await PreparedPluginCatalog.discover(root.path);
      expectRejected(catalog);
      expect(catalog.issues.single.message, contains('DuplicateSettingId'));
      expect(
        catalog.issues.single.message,
        contains('org.example.plugin.enabled'),
      );
    },
  );

  for (final reverse in [false, true]) {
    test(
      'cross-plugin duplicate IDs explicitly fail aggregation, reverse=$reverse',
      () async {
        await install(
          reverse ? 'z' : 'a',
          id: 'org.example',
          components: _components,
          schema: _schema([_definition()]),
        );
        await install(
          reverse ? 'a' : 'z',
          components: _components,
          schema: _schema([_definition()]),
        );
        final catalog = await PreparedPluginCatalog.discover(root.path);
        expect(catalog.issues, isEmpty);
        expect(catalog.installations, hasLength(2));
        expect(
          catalog.installations.every(
            (item) =>
                item.backendArtifactUri != null &&
                item.frontend != null &&
                item.settingsSchema != null,
          ),
          isTrue,
        );
        for (var attempt = 0; attempt < 2; attempt++) {
          expect(
            () => catalog.settings,
            throwsA(
              isA<DuplicateSettingId>()
                  .having(
                    (error) => error.id,
                    'id',
                    SettingId('org.example.plugin.enabled'),
                  )
                  .having(
                    (error) => [error.firstOwner, error.secondOwner],
                    'owners',
                    unorderedEquals([
                      SettingOwnerId('org.example'),
                      SettingOwnerId('org.example.plugin'),
                    ]),
                  ),
            ),
          );
        }
      },
    );
  }

  test(
    'duplicate installations contribute no definitions and retain conflict issues',
    () async {
      await install('a', schema: _schema([_definition()]));
      await install(
        'z',
        schema: {'schemaVersion': 2, 'definitions': <Object?>[]},
      );
      await install(
        'healthy',
        id: 'org.example.other',
        schema: _schema([_definition(id: 'org.example.other.value')]),
      );
      final catalog = await PreparedPluginCatalog.discover(root.path);
      expect(
        catalog.installations.single.metadata.id,
        PluginId('org.example.other'),
      );
      expect(
        catalog.settings.definitions.single.id,
        SettingId('org.example.other.value'),
      );
      expect(
        catalog.issues.where((issue) => issue.isSettingsSchemaIssue),
        hasLength(1),
      );
      final conflicts = catalog.issues.where(
        (issue) => issue.message.contains('Duplicate PluginId'),
      );
      expect(conflicts, hasLength(2));
      expect(conflicts.every((issue) => !issue.isSettingsSchemaIssue), isTrue);
    },
  );

  test(
    'invalid executable components do not discard a healthy schema',
    () async {
      await install(
        'broken-code',
        components: {
          'backend': {'artifact': 'absent.aot'},
          'frontend': {'artifact': 'frontend.evc', 'presentations': false},
        },
        schema: _schema([_definition()]),
      );
      final catalog = await PreparedPluginCatalog.discover(root.path);
      final installation = catalog.installations.single;
      expect(installation.backendArtifactUri, isNull);
      expect(installation.frontend, isNull);
      expect(installation.settingsSchema, isNotNull);
      expect(catalog.settings.definitions, hasLength(1));
      expect(catalog.issues.map((issue) => issue.component), [
        PreparedPluginComponent.backend,
        PreparedPluginComponent.frontend,
      ]);
      expect(
        catalog.issues.every((issue) => !issue.isSettingsSchemaIssue),
        isTrue,
      );
    },
  );

  test('a malformed metadata-only schema preserves the installation', () async {
    await install('metadata-only', schema: false);
    expectRejected(
      await PreparedPluginCatalog.discover(root.path),
      components: false,
    );
  });

  final badSchemas = <String, Object?>{
    'not an object': [],
    'null document': null,
    'missing version': {'definitions': <Object?>[]},
    'missing definitions': {'schemaVersion': 1},
    'unknown envelope field': {..._schema([]), 'owner': 'org.other.plugin'},
    for (final version in <Object?>[null, false, '1', 1.0, 0, -1, 2])
      'version ${jsonEncode(version)}': {
        'schemaVersion': version,
        'definitions': <Object?>[],
      },
    for (final definitions in <Object?>[null, true, 'value', 1, {}])
      'definitions ${jsonEncode(definitions)}': {
        'schemaVersion': 1,
        'definitions': definitions,
      },
  };
  for (final entry in badSchemas.entries) {
    test('rejects schema ${entry.key}', () async {
      await install('invalid', components: _components, schema: entry.value);
      expectRejected(await PreparedPluginCatalog.discover(root.path));
    });
  }

  final badDefinitions = <String, Object?>{
    'not an object': [],
    'null definition': null,
    for (final field in _definition().keys)
      'missing $field': _definition()..remove(field),
    for (final field in [
      'owner',
      'pluginId',
      'nullable',
      'scopes',
      'validate',
      'secret',
      'unknown',
    ])
      'unsupported $field': {..._definition(), field: 'ignored?'},
    for (final id in [
      'org.example.plugin',
      'org.example.plugin-other.value',
      'org.example.plugin2.value',
      'org.other.plugin.value',
      'Enabled',
      'org.example..value',
    ])
      'invalid namespace or ID $id': _definition(id: id),
    for (final type in <Object?>[
      null,
      false,
      'number',
      'array',
      'object',
      'Boolean',
    ])
      'unsupported type ${jsonEncode(type)}': {..._definition(), 'type': type},
    for (final value in <Object?>[null, 'true', 1, 1.0, [], {}])
      'boolean default ${jsonEncode(value)}': _definition(defaultValue: value),
    for (final value in <Object?>[null, '1', true, 1.0, 1.5, [], {}])
      'integer default ${jsonEncode(value)}': _definition(
        type: 'integer',
        defaultValue: value,
      ),
    for (final value in <Object?>[null, true, 1, [], {}])
      'string default ${jsonEncode(value)}': _definition(
        type: 'string',
        defaultValue: value,
      ),
    for (final bound in ['minimum', 'maximum'])
      for (final value in <Object?>[null, true, '1', 1.0, [], {}])
        '$bound ${jsonEncode(value)}': {
          ..._definition(type: 'integer', defaultValue: 1),
          bound: value,
        },
    'inverted bounds': {
      ..._definition(type: 'integer', defaultValue: 2),
      'minimum': 3,
      'maximum': 1,
    },
    'below bound': {
      ..._definition(type: 'integer', defaultValue: 0),
      'minimum': 1,
    },
    'above bound': {
      ..._definition(type: 'integer', defaultValue: 2),
      'maximum': 1,
    },
    'boolean bound': {..._definition(), 'minimum': 0},
    'string options': {
      ..._definition(type: 'string', defaultValue: ''),
      'options': <Object?>[],
    },
    'enum bound': {..._enumDefinition(), 'maximum': 10},
    'enum missing options': _enumDefinition()..remove('options'),
    for (final options in <Object?>[
      null,
      {},
      true,
      [],
      [null],
      ['first'],
      [<String, Object?>{}],
      [
        {'value': 'first', 'unknown': true},
      ],
      [
        {'value': 'first', 'label': null},
      ],
      [
        {'value': ''},
      ],
      [
        {'value': ' first'},
      ],
      [
        {'value': 'first '},
      ],
      [
        {'value': 'first\nsecond'},
      ],
      [
        {'value': 'first', 'label': ''},
      ],
      [
        {'value': 'first', 'label': 'bad\u0000label'},
      ],
      [
        {'value': 'first', 'label': 'One'},
        {'value': 'first', 'label': 'Two'},
      ],
    ])
      'enum options ${jsonEncode(options)}': {
        ..._enumDefinition(),
        'options': options,
      },
    for (final value in <Object?>[
      null,
      true,
      1,
      'First',
      'unknown',
      ' First label ',
    ])
      'enum default ${jsonEncode(value)}': {
        ..._enumDefinition(),
        'default': value,
      },
    for (final field in ['label', 'category', 'section'])
      for (final value in <Object?>[
        null,
        1,
        '',
        ' ',
        'two\nlines',
        'bad\u0000value',
        'bad\u2028value',
      ])
        '$field ${jsonEncode(value)}': {..._definition(), field: value},
    for (final value in <Object?>[null, false, [], {}])
      'description ${jsonEncode(value)}': {
        ..._definition(),
        'description': value,
      },
  };
  for (final entry in badDefinitions.entries) {
    test('rejects whole schema for ${entry.key}', () async {
      await install(
        'invalid',
        components: _components,
        schema: _schema([
          _definition(id: 'org.example.plugin.valid'),
          entry.value,
        ]),
      );
      expectRejected(await PreparedPluginCatalog.discover(root.path));
    });
  }

  for (final invalidJson in [
    '{',
    '',
    'null',
    '\ufeff{}',
    for (final value in ['9223372036854775808', '-9223372036854775809', '1e0'])
      jsonEncode(
        _schema([_definition(type: 'integer', defaultValue: 'OVERFLOW')]),
      ).replaceFirst('"OVERFLOW"', value),
  ]) {
    test(
      'malformed JSON or non-native integer ${jsonEncode(invalidJson)}',
      () async {
        final directory = await install('invalid', components: _components);
        await File.fromUri(
          directory.uri.resolve('settings.schema.json'),
        ).writeAsString(invalidJson);
        expectRejected(await PreparedPluginCatalog.discover(root.path));
      },
    );
  }

  test('invalid UTF-8 rejects only the schema', () async {
    final directory = await install('invalid', components: _components);
    await File.fromUri(
      directory.uri.resolve('settings.schema.json'),
    ).writeAsBytes([0xff]);
    expectRejected(await PreparedPluginCatalog.discover(root.path));
  });

  for (final count in [
    PreparedSettingsSchema.maxDefinitions,
    PreparedSettingsSchema.maxDefinitions + 1,
  ]) {
    test('definition count $count is bounded', () async {
      await install(
        'bounded',
        components: _components,
        schema: _schema([
          for (var index = 0; index < count; index++)
            _definition(id: 'org.example.plugin.value-$index'),
        ]),
      );
      final catalog = await PreparedPluginCatalog.discover(root.path);
      if (count > PreparedSettingsSchema.maxDefinitions) {
        expectRejected(catalog);
      } else {
        expect(catalog.issues, isEmpty);
        expect(catalog.settings.definitions, hasLength(count));
      }
    });
  }

  for (final count in [
    PreparedSettingsSchema.maxEnumOptions,
    PreparedSettingsSchema.maxEnumOptions + 1,
  ]) {
    test('enum option count $count is bounded', () async {
      await install(
        'bounded',
        components: _components,
        schema: _schema([
          {
            ..._enumDefinition(),
            'default': 'value-0',
            'options': [
              for (var index = 0; index < count; index++)
                {'value': 'value-$index'},
            ],
          },
        ]),
      );
      final catalog = await PreparedPluginCatalog.discover(root.path);
      if (count > PreparedSettingsSchema.maxEnumOptions) {
        expectRejected(catalog);
      } else {
        expect(catalog.issues, isEmpty);
        expect(
          (catalog.settings.definitions.single.type as EnumSettingType).options,
          hasLength(count),
        );
      }
    });
  }

  for (final extra in [0, 1]) {
    for (final field in [
      'id',
      'label',
      'category',
      'section',
      'description',
      'enum value',
      'enum label',
    ]) {
      test('$field metadata bound plus $extra', () async {
        final length =
            switch (field) {
              'id' => PreparedSettingsSchema.maxIdLength,
              'description' => PreparedSettingsSchema.maxDescriptionLength,
              _ => PreparedSettingsSchema.maxLabelLength,
            } +
            extra;
        final text = 'x' * length;
        final Map<String, Object?> definition;
        if (field == 'enum value' || field == 'enum label') {
          definition = {
            ..._enumDefinition(),
            'default': field == 'enum value' ? text : 'first',
            'options': [
              {
                'value': field == 'enum value' ? text : 'first',
                if (field == 'enum label') 'label': text,
              },
            ],
          };
        } else {
          definition = {
            ..._definition(),
            field: field == 'id'
                ? 'org.example.plugin.${'x' * (length - 'org.example.plugin.'.length)}'
                : text,
          };
        }
        await install(
          'bounded',
          components: _components,
          schema: _schema([definition]),
        );
        final catalog = await PreparedPluginCatalog.discover(root.path);
        if (extra > 0) {
          expectRejected(catalog);
        } else {
          expect(catalog.issues, isEmpty);
          expect(catalog.settings.definitions, hasLength(1));
        }
      });
    }
  }

  for (final extra in [0, 1]) {
    test('schema byte bound plus $extra limits the read', () async {
      final directory = await install('bounded', components: _components);
      final document = jsonEncode(_schema([]));
      await File.fromUri(
        directory.uri.resolve('settings.schema.json'),
      ).writeAsString(
        '$document${' ' * (PreparedSettingsSchema.maxBytes - document.length + extra)}',
      );
      final catalog = await PreparedPluginCatalog.discover(root.path);
      if (extra > 0) {
        expectRejected(catalog);
        expect(catalog.issues.single.message, contains('bytes'));
      } else {
        expect(catalog.issues, isEmpty);
        expect(catalog.installations.single.settingsSchema, isNotNull);
      }
    });
  }

  test('schema byte bound measures UTF-8 bytes, not text length', () async {
    await install(
      'bounded',
      components: _components,
      schema: _schema([
        _definition(
          type: 'string',
          defaultValue: '\u00e9' * (PreparedSettingsSchema.maxBytes ~/ 2),
        ),
      ]),
    );
    final catalog = await PreparedPluginCatalog.discover(root.path);
    expectRejected(catalog);
    expect(catalog.issues.single.message, contains('bytes'));
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
    '/tmp/settings.json',
    '../settings.json',
    'nested/../../settings.json',
    './settings.json',
    'nested/../settings.json',
    'nested//settings.json',
    'nested/./settings.json',
    'nested/',
    r'C:\settings.json',
    'C:/settings.json',
    r'nested\settings.json',
    '//server/settings.json',
    'file:settings.json',
    'file:///tmp/settings.json',
    'https://example.com/settings.json',
    'settings.json?query',
    'settings.json#fragment',
    '%2e%2e/settings.json',
    'settings.json\u0000',
    'bad|name.json',
    'bad*.json',
  ]) {
    test('schema asset rejects path ${jsonEncode(reference)}', () async {
      await install('invalid', components: _components, reference: reference);
      expectRejected(await PreparedPluginCatalog.discover(root.path));
    });
  }

  test('missing schema file preserves healthy components', () async {
    await install(
      'missing',
      components: _components,
      reference: 'missing.json',
    );
    expectRejected(await PreparedPluginCatalog.discover(root.path));
  });

  test('unreadable schema reports its I/O failure without fallback', () async {
    final directory = await install('unreadable', components: _components);
    final catalog = await IOOverrides.runWithIOOverrides(
      () => PreparedPluginCatalog.discover(root.path),
      _UnreadableSchema(
        directory.uri.resolve('settings.schema.json').toFilePath(),
      ),
    );
    expectRejected(catalog);
    expect(
      catalog.issues.single.message,
      contains('Unable to read settings schema'),
    );
    expect(catalog.issues.single.message, contains('Injected read failure'));
  });

  test('non-regular schema files are rejected before reading', () async {
    final directory = await install(
      'directory',
      components: _components,
      reference: 'folder',
    );
    await Directory.fromUri(directory.uri.resolve('folder/')).create();
    final catalog = await PreparedPluginCatalog.discover(root.path);
    expectRejected(catalog);
    expect(catalog.issues.single.message, contains('regular file'));
  });

  test('FIFO schema is rejected without blocking on read', () async {
    final directory = await install(
      'pipe',
      components: _components,
      reference: 'pipe',
    );
    expect(
      (await Process.run('mkfifo', ['${directory.path}/pipe'])).exitCode,
      0,
    );
    final catalog = await PreparedPluginCatalog.discover(root.path);
    expectRejected(catalog);
    expect(catalog.issues.single.message, contains('regular file'));
  }, skip: !Platform.isLinux);

  test('nested relative schema paths allow spaces', () async {
    final directory = await install(
      'nested',
      reference: 'metadata/schema file.json',
    );
    await Directory.fromUri(directory.uri.resolve('metadata/')).create();
    await File.fromUri(
      directory.uri.resolve('settings.schema.json'),
    ).rename(directory.uri.resolve('metadata/schema%20file.json').toFilePath());
    final catalog = await PreparedPluginCatalog.discover(root.path);
    expect(catalog.issues, isEmpty);
    expect(
      catalog.installations.single.settingsSchema!.artifactUri,
      directory.uri.resolve('metadata/schema%20file.json'),
    );
  });

  group(
    'schema symlinks',
    () {
      for (final ancestor in [false, true]) {
        test('rejects outside installation with ancestor=$ancestor', () async {
          final directory = await install(
            'plugin',
            components: _components,
            reference: ancestor ? 'linked/schema.json' : 'linked.json',
          );
          final outside = await Directory.fromUri(
            temporary.uri.resolve('installations/plugin-outside/'),
          ).create();
          // A valid sibling isolates the schema escape from envelope failures.
          await File.fromUri(
            outside.uri.resolve('adele_plugin.installation.json'),
          ).writeAsString(
            jsonEncode({
              'manifestVersion': 1,
              'metadata': {
                'id': 'org.example.outside',
                'version': '1',
                'displayName': 'Outside',
              },
              'components': <String, Object?>{},
            }),
          );
          final asset = await File.fromUri(
            outside.uri.resolve('schema.json'),
          ).writeAsString(jsonEncode(_schema([])));
          await Link.fromUri(
            directory.uri.resolve(ancestor ? 'linked' : 'linked.json'),
          ).create(ancestor ? outside.path : asset.path);
          final catalog = await PreparedPluginCatalog.discover(root.path);
          expect(catalog.installations, hasLength(2));
          final plugin = catalog.installations.first;
          expect(plugin.settingsSchema, isNull);
          expect(plugin.backendArtifactUri, isNotNull);
          expect(plugin.frontend, isNotNull);
          expect(catalog.issues.single.isSettingsSchemaIssue, isTrue);
          expect(
            catalog.issues.single.message,
            contains('outside the installation'),
          );
        });
      }

      test(
        'accepts confined schema link and symlinked root with canonical asset URI',
        () async {
          final directory = await install(
            'plugin',
            reference: 'linked.json',
            schema: _schema([_definition()]),
          );
          await Link.fromUri(
            directory.uri.resolve('linked.json'),
          ).create('settings.schema.json');
          final linkedRoot = await Link.fromUri(
            temporary.uri.resolve('root-link'),
          ).create(root.path);
          final catalog = await PreparedPluginCatalog.discover(linkedRoot.path);
          expect(catalog.issues, isEmpty);
          expect(
            catalog.installations.single.settingsSchema!.artifactUri,
            directory.uri.resolve('settings.schema.json'),
          );
          expect(catalog.settings.definitions, hasLength(1));
        },
      );

      test('rejects dangling schema links', () async {
        final directory = await install(
          'plugin',
          components: _components,
          reference: 'linked.json',
        );
        await Link.fromUri(
          directory.uri.resolve('linked.json'),
        ).create('absent.json');
        expectRejected(await PreparedPluginCatalog.discover(root.path));
      });
    },
    skip: Platform.isWindows ? 'Symlink creation requires privileges.' : false,
  );
}

const _components = <String, Object?>{
  'backend': {'artifact': 'backend.aot'},
  'frontend': {'artifact': 'frontend.evc', 'presentations': <Object?>[]},
};

Map<String, Object?> _schema(List<Object?> definitions) => {
  'schemaVersion': 1,
  'definitions': definitions,
};

Map<String, Object?> _definition({
  String id = 'org.example.plugin.enabled',
  String type = 'boolean',
  Object? defaultValue = true,
}) => {
  'id': id,
  'type': type,
  'default': defaultValue,
  'label': 'Enabled',
  'category': 'General',
  'section': 'Output',
};

Map<String, Object?> _enumDefinition() => {
  ..._definition(type: 'enum', defaultValue: 'first'),
  'options': [
    {'value': 'first', 'label': 'First label'},
  ],
};

final class _UnreadableSchema extends IOOverrides {
  _UnreadableSchema(this.path);
  final String path;
  final Zone _zone = Zone.current;

  // The pinned SDK's default override omits the native path terminator.
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
