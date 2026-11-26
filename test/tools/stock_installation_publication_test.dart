import 'dart:convert';
import 'dart:io';

// Match the package types returned by runtime discovery in this workspace test.
// ignore: depend_on_referenced_packages
import 'package:adele_settings/adele_settings.dart';
import 'package:test/test.dart';

// ignore: avoid_relative_lib_imports
import '../../packages/plugin_runtime/lib/plugin_runtime.dart';
import '../../tools/backend_artifacts.dart';
import '../../tools/stock_frontend_descriptors.dart';
import 'support/desktop_launcher_fixture.dart';
import 'support/desktop_launcher_inputs.dart';

const _openaiApplyHandler = {
  'recordType': 'dev.adele.openai.api-key',
  'serviceId': 'dev.adele.openai.configuration',
  'method': 'refreshConfiguredProvider',
};
const _modelConfigurationId = 'dev.adele.plugin.model-configuration';
const _modelPreferenceExtension = '$_modelConfigurationId.run-model-preference';
const _modelReferenceEditor = '$_modelConfigurationId.model-reference';

void main() {
  late DesktopLauncherFixture fixture;
  setUp(() async {
    fixture = await DesktopLauncherFixture.create();
  });

  void expectNonBlankControlFree(RecordFieldDefinition<Object> field) {
    for (final invalid in ['', '  ', 'a\nb', 'a\u007fb']) {
      expect(field.valueError(invalid), isNotNull, reason: field.id.value);
    }
    expect(field.snapshotValue('  exact text  '), '  exact text  ');
  }

  test(
    'stock OpenAI records are discoverable without executable components or auth',
    () async {
      final installations = Directory('${fixture.root.path}/published');
      final directory = Directory.fromUri(installations.uri.resolve('openai/'));
      await publishStockPluginInstallation(
        repositoryRoot: fixture.root,
        installationDirectory: directory,
        pluginId: 'dev.adele.openai',
        displayName: 'OpenAI',
      );
      expect(fixture.commands.existsSync(), isFalse);
      expect(directory.listSync(), hasLength(2));
      expect(
        jsonDecode(
          File.fromUri(
            directory.uri.resolve('adele_plugin.installation.json'),
          ).readAsStringSync(),
        ),
        {
          'manifestVersion': 1,
          'metadata': {
            'id': 'dev.adele.openai',
            'version': '0.1.0',
            'displayName': 'OpenAI',
          },
          'recordsSchema': 'records.schema.json',
          'components': <String, Object?>{},
        },
      );
      final schemaFile = File.fromUri(
        directory.uri.resolve('records.schema.json'),
      );
      expect(
        schemaFile.readAsBytesSync(),
        File('plugins/openai/records.schema.json').readAsBytesSync(),
      );
      const endpointHint =
          'Default when not set: https://api.openai.com/v1/responses';
      expect(jsonDecode(schemaFile.readAsStringSync()), {
        'schemaVersion': 1,
        'recordTypes': [
          {
            'id': 'dev.adele.openai.api-key',
            'collection': 'providers',
            'collectionLabel': 'Providers',
            'label': 'OpenAI API',
            'description': 'An OpenAI API-key provider configuration.',
            'displayField': 'display-name',
            'filenameField': 'display-name',
            'credentialSlots': [
              {'id': 'api-key', 'label': 'API key', 'kind': 'secret-text'},
            ],
            'fields': [
              {
                'id': 'display-name',
                'label': 'Name',
                'type': 'string',
                'nonBlank': true,
                'rejectAsciiControls': true,
                'required': true,
              },
              {
                'id': 'endpoint',
                'label': 'API endpoint',
                'description': endpointHint,
                'type': 'string',
                'nonBlank': true,
                'rejectAsciiControls': true,
                'required': false,
              },
            ],
          },
        ],
      });

      final catalog = await PreparedPluginCatalog.discover(installations.path);
      expect(catalog.issues, isEmpty);
      final installation = catalog.installations.single;
      expect(installation.backendArtifactUri, isNull);
      expect(installation.backendConsumedRecordTypes, isEmpty);
      expect(installation.backendConsumedCredentialSlots, isEmpty);
      expect(installation.frontend, isNull);
      expect(installation.settingsSchema, isNull);
      expect(catalog.settings.definitions, isEmpty);
      final schema = installation.recordsSchema!;
      expect(schema.artifactUri, schemaFile.uri);
      final type = schema.definitions.single;
      expect(catalog.records.definitions, [type]);
      expect(type.id.value, 'dev.adele.openai.api-key');
      expect(type.owner.value, installation.metadata.id.value);
      expect(type.collection.value, 'providers');
      expect(type.collectionLabel, 'Providers');
      expect(type.label, 'OpenAI API');
      expect(type.description, 'An OpenAI API-key provider configuration.');
      expect(type.displayField?.value, 'display-name');
      expect(type.filenameField?.value, 'display-name');
      expect(type.credentialSlots.single.id.value, 'api-key');
      expect(type.credentialSlots.single.label, 'API key');
      expect(type.credentialSlots.single.kind.name, 'secretText');
      expect(type.fields.map((field) => field.id.value), [
        'display-name',
        'endpoint',
      ]);
      expect(type.fields.map((field) => field.label), ['Name', 'API endpoint']);
      expect(type.fields.map((field) => field.required), [true, false]);
      expect(type.fields.map((field) => field.description), [
        null,
        endpointHint,
      ]);
      expectNonBlankControlFree(type.fields.first);
      expectNonBlankControlFree(type.fields.last);
      const withoutEndpoint = {'display-name': 'Work'};
      expect(
        type.validate(ConfigurationRecordId('work'), withoutEndpoint),
        withoutEndpoint,
      );
      expect(fixture.commands.existsSync(), isFalse);
    },
  );

  test('schema-only Agent fixture needs no executable components', () async {
    final installations = Directory('${fixture.root.path}/published');
    final directory = Directory.fromUri(
      installations.uri.resolve('agent-configuration/'),
    );
    await publishStockPluginInstallation(
      repositoryRoot: fixture.root,
      installationDirectory: directory,
      pluginId: 'dev.adele.plugin.agent-configuration',
      displayName: 'Agent Configuration',
    );
    expect(fixture.commands.existsSync(), isFalse);
    expect(
      directory.listSync().map((file) => file.uri.pathSegments.last),
      unorderedEquals([
        'adele_plugin.installation.json',
        'records.schema.json',
      ]),
    );
    expect(
      jsonDecode(
        File.fromUri(
          directory.uri.resolve('adele_plugin.installation.json'),
        ).readAsStringSync(),
      ),
      {
        'manifestVersion': 1,
        'metadata': {
          'id': 'dev.adele.plugin.agent-configuration',
          'version': '0.1.0',
          'displayName': 'Agent Configuration',
        },
        'recordsSchema': 'records.schema.json',
        'components': <String, Object?>{},
      },
    );
    final schemaFile = File.fromUri(
      directory.uri.resolve('records.schema.json'),
    );
    expect(
      schemaFile.readAsBytesSync(),
      File('plugins/agent_configuration/records.schema.json').readAsBytesSync(),
    );
    final source = jsonDecode(schemaFile.readAsStringSync()) as Map;
    expect(source['schemaVersion'], 1);
    final declared = (source['recordTypes'] as List).single as Map;
    final fields = (declared['fields'] as List).cast<Map<String, dynamic>>();
    expect(fields.map((field) => field['type']), [
      'string',
      'string',
      'string',
      'string',
    ]);
    expect(
      {
        for (final field in fields)
          if (field.containsKey('editor')) field['id']: field['editor'],
      },
      {'instructions': 'markdown'},
    );

    final catalog = await PreparedPluginCatalog.discover(installations.path);
    expect(catalog.issues, isEmpty);
    final installation = catalog.installations.single;
    expect(installation.backendArtifactUri, isNull);
    expect(installation.frontend, isNull);
    expect(installation.backendConsumedCapabilities, isEmpty);
    expect(installation.backendConsumedRecordTypes, isEmpty);
    expect(installation.backendConsumedCredentialSlots, isEmpty);
    expect(installation.settingsSchema, isNull);
    expect(catalog.settings.definitions, isEmpty);
    final schema = installation.recordsSchema!;
    expect(schema.artifactUri, schemaFile.uri);
    final type = schema.definitions.single;
    expect(catalog.records.definitions, [type]);
    expect(type.id.value, 'dev.adele.plugin.agent-configuration.agent');
    expect(type.owner.value, 'dev.adele.plugin.agent-configuration');
    expect(type.collection.value, 'agents');
    expect(catalog.records.collections, [type.collection]);
    expect(catalog.records.collectionLabel(type.collection), 'Agents');
    expect(type.label, 'Agent');
    expect(type.displayField?.value, 'name');
    expect(type.filenameField?.value, 'name');
    expect(type.credentialSlots, isEmpty);
    expect(type.fields.map((field) => field.id.value), [
      'name',
      'description',
      'when-to-use',
      'instructions',
    ]);
    expect(type.fields.map((field) => field.label), [
      'Name',
      'Description',
      'When to Use',
      'Instructions',
    ]);
    expect(type.fields.map((field) => field.required), [
      true,
      false,
      false,
      true,
    ]);
    expectNonBlankControlFree(type.fields.first);
    const agent = {
      'name': 'Reviewer',
      'description': 'Two\nlines',
      'when-to-use': '',
      'instructions': '',
    };
    expect(type.validate(ConfigurationRecordId('reviewer'), agent), agent);
    expect(fixture.commands.existsSync(), isFalse);
  });

  test(
    'Model Presets are discoverable and valid without any provider',
    () async {
      final installations = Directory('${fixture.root.path}/published');
      final directory = Directory.fromUri(
        installations.uri.resolve('model-configuration/'),
      );
      await publishStockPluginInstallation(
        repositoryRoot: fixture.root,
        installationDirectory: directory,
        pluginId: _modelConfigurationId,
        displayName: 'Model Configuration',
        backend: true,
      );
      final artifact = File.fromUri(directory.uri.resolve('backend.aot'));
      await artifact.writeAsString('Discovery does not execute this artifact.');

      final catalog = await PreparedPluginCatalog.discover(installations.path);
      expect(catalog.issues, isEmpty);
      final installation = catalog.installations.single;
      expect(installation.metadata.id.value, _modelConfigurationId);
      expect(installation.backendArtifactUri, artifact.uri);
      expect(
        installation.runModelPreferenceSource?.value,
        _modelPreferenceExtension,
      );
      expect(installation.backendConsumedRecordTypesToJson(), [
        '$_modelConfigurationId.preset',
      ]);
      expect(installation.backendConsumedCredentialSlots, isEmpty);
      expect(installation.backendConsumedCapabilities, isEmpty);
      expect(installation.backendRecordApplyHandlers, isEmpty);
      expect(installation.frontend, isNull);
      expect(installation.settingsSchema, isNull);
      final schema = installation.recordsSchema!;
      expect(schema.artifactUri, directory.uri.resolve('records.schema.json'));
      expect(
        File.fromUri(schema.artifactUri).readAsBytesSync(),
        File(modelPresetSchema).readAsBytesSync(),
      );
      final preset = schema.definitions.single;
      expect(catalog.records.definitions, [preset]);
      expect(preset.id.value, '$_modelConfigurationId.preset');
      expect(preset.owner.value, _modelConfigurationId);
      expect(preset.collection.value, 'model-presets');
      expect(
        catalog.records.collectionLabel(preset.collection),
        'Model Presets',
      );
      expect(preset.label, 'Model Preset');
      expect(preset.displayField?.value, 'name');
      expect(preset.filenameField?.value, 'name');
      expect(preset.formBehavior?.value, '$_modelConfigurationId.preset-form');
      expect(preset.credentialSlots, isEmpty);
      final model = preset.fields.singleWhere((field) => field.editor != null);
      expect(model.id.value, 'model');
      expect(
        (model.editor as ContributedRecordFieldEditor).extensionId.value,
        _modelReferenceEditor,
      );
      final properties = (model.type as StructuredRecordFieldType).properties;
      expect(properties.keys.map((id) => id.value), [
        'provider-id',
        'model-id',
      ]);
      expect(properties.values, everyElement(isA<StringSettingType>()));
      expect(
        preset.fields.map(
          (field) => (field.id.value, field.label, field.required),
        ),
        [
          ('name', 'Name', true),
          ('description', 'Description', false),
          ('model', 'Model', true),
          ('reasoning-effort', 'Reasoning Effort', false),
        ],
      );
      expect(
        preset.fields.take(2).map((field) => field.type),
        everyElement(isA<StringSettingType>()),
      );
      final effort = preset.fields.last.type as EnumSettingType;
      expect(preset.fields.last.unsetLabel, 'Provider default');
      expect(effort.options.map((option) => (option.value, option.label)), [
        ('none', 'None'),
        ('minimal', 'Minimal'),
        ('low', 'Low'),
        ('medium', 'Medium'),
        ('high', 'High'),
        ('xhigh', 'Extra High'),
        ('max', 'Max'),
      ]);

      final recordId = ConfigurationRecordId('work');
      expectNonBlankControlFree(preset.fields.first);
      const reference = {
        'provider-id': 'org.example.work-provider',
        'model-id': '  Local/Model:v2  ',
      };
      const requiredValues = {'name': 'Work model', 'model': reference};
      expect(preset.validate(recordId, requiredValues), requiredValues);
      final boundary = {
        'provider-id': 'a.${'b' * 1022}',
        'model-id': '\u{1F600}' * 512,
      };
      expect(model.snapshotValue(boundary), boundary);
      for (final (property, invalid) in [
        ('model-id', {'provider-id': 'org.example.work-provider'}),
        ('model-id', {...reference, 'model-id': 3}),
        ('provider-id', {...reference, 'provider-id': 'work-provider'}),
        (
          'provider-id',
          {...boundary, 'provider-id': '${boundary['provider-id']}x'},
        ),
        for (final invalidId in [
          '',
          '  ',
          'model\u0000a',
          '${boundary['model-id']}x',
        ])
          ('model-id', {...reference, 'model-id': invalidId}),
      ]) {
        expect(
          () =>
              preset.validate(recordId, {...requiredValues, 'model': invalid}),
          throwsA(
            isA<InvalidRecordValue>()
                .having((e) => e.fieldId?.value, 'field', 'model')
                .having(
                  (e) => e.message,
                  'property diagnostic',
                  contains(property),
                ),
          ),
        );
      }
      for (final option in effort.options) {
        final values = {...requiredValues, 'reasoning-effort': option.value};
        expect(preset.validate(recordId, values), values);
      }
      expect(
        () => preset.validate(recordId, {
          ...requiredValues,
          'reasoning-effort': 'Extra High',
        }),
        throwsA(
          isA<InvalidRecordValue>().having(
            (e) => e.fieldId?.value,
            'field',
            'reasoning-effort',
          ),
        ),
      );
      expect(
        directory.listSync().map((entry) => entry.uri.pathSegments.last),
        unorderedEquals([
          'adele_plugin.installation.json',
          'records.schema.json',
          'backend.aot',
        ]),
      );
      await artifact.delete();
      final missing = await PreparedPluginCatalog.discover(installations.path);
      expect(missing.issues.single.component, PreparedPluginComponent.backend);
      expect(missing.issues.single.isRunModelPreferenceSourceIssue, isTrue);
      expect(
        missing.installations.single.runModelPreferenceSource?.value,
        _modelPreferenceExtension,
      );
      expect(missing.installations.single.backendArtifactUri, isNull);
      expect(missing.installations.single.backendConsumedRecordTypes, isEmpty);
      expect(missing.records.definitions.single.id, preset.id);
      expect(fixture.commands.existsSync(), isFalse);
    },
  );

  test(
    'invalid preset schema leaves Agent and OpenAI declarations healthy',
    () async {
      final installations = Directory('${fixture.root.path}/published');
      for (final (directory, id, name) in [
        ('model-configuration', _modelConfigurationId, 'Model Configuration'),
        (
          'agent-configuration',
          'dev.adele.plugin.agent-configuration',
          'Agent Configuration',
        ),
        ('openai', 'dev.adele.openai', 'OpenAI'),
      ]) {
        await publishStockPluginInstallation(
          repositoryRoot: fixture.root,
          installationDirectory: Directory.fromUri(
            installations.uri.resolve('$directory/'),
          ),
          pluginId: id,
          displayName: name,
        );
      }
      File.fromUri(
        installations.uri.resolve('model-configuration/records.schema.json'),
      ).writeAsStringSync('{invalid');

      final catalog = await PreparedPluginCatalog.discover(installations.path);
      expect(catalog.issues.map((i) => i.pluginId?.value), [
        _modelConfigurationId,
        _modelConfigurationId,
      ]);
      expect(catalog.issues.where((i) => i.isRecordsSchemaIssue), hasLength(1));
      expect(
        catalog.issues.where((i) => i.isRunModelPreferenceSourceIssue),
        hasLength(1),
      );
      expect(
        catalog.records.definitions.map(
          (type) => (type.collection.value, type.id.value),
        ),
        [
          ('providers', 'dev.adele.openai.api-key'),
          ('agents', 'dev.adele.plugin.agent-configuration.agent'),
        ],
      );
      expect(fixture.commands.existsSync(), isFalse);
    },
  );

  test('missing Agent backend leaves its record schema discoverable', () async {
    final installations = Directory('${fixture.root.path}/published');
    final directory = Directory.fromUri(
      installations.uri.resolve('agent-configuration/'),
    );
    await publishStockPluginInstallation(
      repositoryRoot: fixture.root,
      installationDirectory: directory,
      pluginId: 'dev.adele.plugin.agent-configuration',
      displayName: 'Agent Configuration',
      backend: true,
    );
    final artifact = File.fromUri(directory.uri.resolve('backend.aot'));
    await artifact.writeAsString('Discovery must not execute this file.');
    final available = await PreparedPluginCatalog.discover(installations.path);
    expect(available.issues, isEmpty);
    final backend = available.installations.single;
    expect(backend.backendArtifactUri, artifact.uri);
    expect(backend.backendConsumedRecordTypesToJson(), [
      'dev.adele.plugin.agent-configuration.agent',
    ]);
    expect(backend.backendConsumedCredentialSlots, isEmpty);
    expect(backend.backendConsumedCapabilities, isEmpty);
    expect(backend.frontend, isNull);

    await artifact.delete();
    final catalog = await PreparedPluginCatalog.discover(installations.path);
    final installation = catalog.installations.single;
    expect(catalog.issues.single.component, PreparedPluginComponent.backend);
    expect(installation.backendArtifactUri, isNull);
    expect(installation.backendConsumedRecordTypes, isEmpty);
    expect(
      catalog.records.definitions.single.id.value,
      'dev.adele.plugin.agent-configuration.agent',
    );
    expect(fixture.commands.existsSync(), isFalse);
  });

  test(
    'omitting record and policy plugins keeps settings but adds no declarations for them',
    () async {
      final installations = Directory('${fixture.root.path}/published');
      for (final plugin in [
        (
          directory: 'source-editor',
          id: 'dev.adele.source-editor',
          name: 'Source',
        ),
        (
          directory: 'session-evaluator',
          id: 'dev.adele.plugin.session-evaluator',
          name: 'Session Evaluator',
        ),
      ]) {
        final directory = Directory.fromUri(
          installations.uri.resolve('${plugin.directory}/'),
        );
        await publishStockPluginInstallation(
          repositoryRoot: fixture.root,
          installationDirectory: directory,
          pluginId: plugin.id,
          displayName: plugin.name,
        );
        final manifest =
            jsonDecode(
                  File.fromUri(
                    directory.uri.resolve('adele_plugin.installation.json'),
                  ).readAsStringSync(),
                )
                as Map<String, dynamic>;
        expect(manifest.containsKey('recordsSchema'), isFalse);
        expect(manifest.containsKey('authorizationPolicies'), isFalse);
        expect(
          File.fromUri(
            directory.uri.resolve('records.schema.json'),
          ).existsSync(),
          isFalse,
        );
      }
      final catalog = await PreparedPluginCatalog.discover(installations.path);
      expect(catalog.issues, isEmpty);
      expect(catalog.installations, hasLength(2));
      expect(
        catalog.installations.expand((item) => item.authorizationPolicies),
        isEmpty,
      );
      expect(catalog.records.definitions, isEmpty);
      expect(catalog.installations.map((item) => item.recordsSchema), [
        null,
        null,
      ]);
      final setting = catalog.settings.definitions.single;
      expect(setting.id.value, 'dev.adele.source-editor.enable-folding');
      expect(catalog.settings.resolve(setting.id).value, isFalse);
      expect(fixture.commands.existsSync(), isFalse);
    },
  );

  for (final backend in [false, true]) {
    for (final frontend in [false, true]) {
      test(
        'stock OpenAI record, credential and apply opt-in backend=$backend frontend=$frontend',
        () async {
          final installations = Directory('${fixture.root.path}/published');
          final directory = Directory.fromUri(
            installations.uri.resolve('openai/'),
          );
          await publishStockPluginInstallation(
            repositoryRoot: fixture.root,
            installationDirectory: directory,
            pluginId: 'dev.adele.openai',
            displayName: 'OpenAI',
            backend: backend,
            frontend: frontend,
          );
          for (final artifact in [
            if (backend) 'backend.aot',
            if (frontend) 'frontend.evc',
          ]) {
            await File.fromUri(
              directory.uri.resolve(artifact),
            ).writeAsString('Not executable; discovery must not activate it.');
          }
          final manifest =
              jsonDecode(
                    await File.fromUri(
                      directory.uri.resolve('adele_plugin.installation.json'),
                    ).readAsString(),
                  )
                  as Map<String, Object?>;
          final components = manifest['components']! as Map<String, Object?>;
          expect(components.containsKey('backend'), backend);
          if (backend) {
            expect(components['backend'], {
              'artifact': 'backend.aot',
              'consumesRecordTypes': ['dev.adele.openai.api-key'],
              'appliesRecordTypes': [_openaiApplyHandler],
              'consumesCredentialSlots': [
                {
                  'recordType': 'dev.adele.openai.api-key',
                  'slots': ['api-key'],
                },
              ],
            });
          }
          final catalog = await PreparedPluginCatalog.discover(
            installations.path,
          );
          expect(catalog.issues, isEmpty);
          final installation = catalog.installations.single;
          expect(installation.backendArtifactUri, backend ? isNotNull : isNull);
          expect(installation.frontend, frontend ? isNotNull : isNull);
          expect(installation.backendConsumedRecordTypesToJson(), [
            if (backend) 'dev.adele.openai.api-key',
          ]);
          expect(
            installation.backendRecordApplyHandlers.map(
              (handler) => {
                'recordType': handler.recordType.value,
                'serviceId': handler.serviceId,
                'method': handler.method,
              },
            ),
            [if (backend) _openaiApplyHandler],
          );
          expect(installation.backendConsumedCredentialSlotsToJson(), [
            if (backend)
              {
                'recordType': 'dev.adele.openai.api-key',
                'slots': ['api-key'],
              },
          ]);
          expect(
            catalog.records.definitions.single.id.value,
            'dev.adele.openai.api-key',
          );
          expect(
            await File.fromUri(
              installation.recordsSchema!.artifactUri,
            ).readAsBytes(),
            await File('plugins/openai/records.schema.json').readAsBytes(),
          );
          expect(fixture.commands.existsSync(), isFalse);
        },
      );
    }
  }

  for (final backend in ['available', 'absent', 'missing', 'invalid']) {
    test(
      'stock Conservative authorization expectation with $backend backend',
      () async {
        final installations = Directory('${fixture.root.path}/published');
        final directory = Directory.fromUri(
          installations.uri.resolve('conservative-tool-policy/'),
        );
        await publishStockPluginInstallation(
          repositoryRoot: fixture.root,
          installationDirectory: directory,
          pluginId: 'dev.adele.plugin.conservative-tool-policy',
          displayName: 'Conservative Tool Policy',
          backend: backend != 'absent',
        );
        final manifestFile = File.fromUri(
          directory.uri.resolve('adele_plugin.installation.json'),
        );
        final manifest =
            jsonDecode(await manifestFile.readAsString())
                as Map<String, Object?>;
        expect(manifest, {
          'manifestVersion': 1,
          'metadata': {
            'id': 'dev.adele.plugin.conservative-tool-policy',
            'version': '0.1.0',
            'displayName': 'Conservative Tool Policy',
          },
          'settingsSchema': 'settings.schema.json',
          'authorizationPolicies': [
            {
              'extensionId':
                  'dev.adele.plugin.conservative-tool-policy.authorization',
              'enabledSettingId':
                  'dev.adele.plugin.conservative-tool-policy.enabled',
            },
          ],
          'components': {
            if (backend != 'absent') 'backend': {'artifact': 'backend.aot'},
          },
        });
        final artifact = File.fromUri(directory.uri.resolve('backend.aot'));
        if (backend == 'available' || backend == 'invalid') {
          await artifact.writeAsString(
            'Not executable; discovery must not activate it.',
          );
        }
        if (backend == 'invalid') {
          manifest['components'] = {
            'backend': {'artifact': '../backend.aot'},
          };
          await manifestFile.writeAsString(jsonEncode(manifest));
        }

        final catalog = await PreparedPluginCatalog.discover(
          installations.path,
        );
        final installation = catalog.installations.single;
        expect(
          installation.metadata.id.value,
          'dev.adele.plugin.conservative-tool-policy',
        );
        expect(installation.authorizationPolicies.map((id) => id.value), [
          'dev.adele.plugin.conservative-tool-policy.authorization',
        ]);
        final schema = installation.settingsSchema!;
        expect(
          schema.artifactUri,
          directory.uri.resolve('settings.schema.json'),
        );
        expect(
          await File.fromUri(schema.artifactUri).readAsBytes(),
          await File(
            'plugins/conservative_tool_policy/settings.schema.json',
          ).readAsBytes(),
        );
        final setting = schema.definitions.single;
        expect(installation.authorizationPolicyEnabledSettings, {
          installation.authorizationPolicies.single: setting.id,
        });
        expect(
          setting.id.value,
          'dev.adele.plugin.conservative-tool-policy.enabled',
        );
        expect(setting.owner.value, installation.metadata.id.value);
        expect(setting.label, 'Enable Conservative Tool Authorization');
        expect(setting.category, 'Agents');
        expect(setting.section, 'Tool Authorization');
        expect(catalog.settings.resolve<bool>(setting.id).value, isTrue);
        expect(setting.validate(false), isFalse);
        expect(() => setting.validate('false'), throwsException);
        expect(
          installation.backendArtifactUri,
          backend == 'available' ? artifact.uri : isNull,
        );
        expect(installation.frontend, isNull);
        if (backend != 'available') {
          final issue = catalog.issues.single;
          expect(issue.pluginId, installation.metadata.id);
          expect(issue.installationDirectory.uri, directory.uri);
          expect(issue.isAuthorizationPolicyIssue, backend == 'absent');
          expect(
            issue.component,
            backend == 'absent' ? isNull : PreparedPluginComponent.backend,
          );
          expect(
            issue.message,
            contains(switch (backend) {
              'absent' => 'authorizationPolicies',
              'invalid' => 'backend.artifact',
              _ => 'backend.aot',
            }),
          );
        } else {
          expect(catalog.issues, isEmpty);
        }
        expect(fixture.commands.existsSync(), isFalse);
      },
    );
  }

  test(
    'Linux development launcher prepares evaluator and existing stock catalog without opt-in',
    () async {
      for (final path in [
        conservativeToolPolicyEntrypoint,
        'plugins/conservative_tool_policy/packages/backend/lib/conservative_tool_policy_backend.dart',
        'plugins/conservative_tool_policy/packages/backend/pubspec.yaml',
        'plugins/agent_configuration/packages/frontend/lib/agent_configuration_frontend.dart',
        'app/$agentConfigurationFrontendHarness',
        'app/tool/agent_configuration_frontend_compiler.dart',
        'plugins/model_configuration/packages/frontend/lib/model_configuration_frontend.dart',
        'plugins/model_configuration/packages/frontend/lib/model_reference_editor.dart',
        'plugins/model_configuration/packages/frontend/lib/model_browser.dart',
        'plugins/model_configuration/packages/frontend/lib/preset_form.dart',
        'app/$modelConfigurationFrontendHarness',
        'app/tool/model_configuration_frontend_compiler.dart',
        sessionEvaluatorEntrypoint,
        'plugins/session_evaluator/packages/frontend/lib/session_evaluator_frontend.dart',
        'plugins/session_evaluator/packages/frontend/lib/src/read_prepared_handoff.dart',
        'app/$sessionEvaluatorFrontendHarness',
        'app/tool/session_evaluator_frontend_compiler.dart',
        diffViewerEntrypoint,
        localDirectoryProjectEntrypoint,
        'plugins/local_directory_project/packages/backend/lib/local_directory_project_backend.dart',
        'plugins/local_directory_project/packages/frontend/lib/local_directory_project_frontend.dart',
        'app/$localDirectoryProjectFrontendHarness',
        'app/tool/local_directory_project_frontend_compiler.dart',
        'app/$taskBrowserFrontendHarness',
        'app/tool/task_browser_frontend_compiler.dart',
        'plugins/task_browser/packages/frontend/lib/task_browser_frontend.dart',
        'app/$terminalFrontendHarness',
        'app/tool/terminal_frontend_compiler.dart',
        'plugins/terminal/packages/frontend/lib/terminal_frontend.dart',
        'app/$sourceEditorFrontendHarness',
        'app/tool/source_editor_frontend_compiler.dart',
        'plugins/source_editor/packages/frontend/lib/main.dart',
        'app/$diffViewerFrontendHarness',
        'app/tool/diff_viewer_frontend_compiler.dart',
        'plugins/diff_viewer/packages/frontend/lib/main.dart',
      ]) {
        expect(File(path).existsSync(), isTrue, reason: path);
      }
      final Set<String> outputDirectories = <String>{};
      final Map<String, String> retainedArtifacts = <String, String>{};
      Map<String, String>? firstDefines;
      final configHome = Directory('${fixture.root.path}/xdg-config');
      fixture.environment['XDG_CONFIG_HOME'] = configHome.path;
      final presetRecords = Directory.fromUri(
        configHome.uri.resolve('adele/config/model-presets/'),
      )..createSync(recursive: true);
      // Preparation must replace inherited inputs with this checkout's paths.
      fixture.environment['ADELE_REPOSITORY_ROOT'] = '/wrong-repository';
      fixture.environment['ADELE_CHAT_FRONTEND_OUTPUT'] = '/wrong-output';
      fixture.environment['ADELE_AGENT_CONFIGURATION_FRONTEND_OUTPUT'] =
          '/wrong-agent';
      fixture.environment['ADELE_MODEL_CONFIGURATION_FRONTEND_OUTPUT'] =
          '/wrong-model';
      fixture.environment['ADELE_TASK_BROWSER_FRONTEND_OUTPUT'] =
          '/wrong-task-browser';
      fixture.environment['ADELE_TERMINAL_FRONTEND_OUTPUT'] = '/wrong-terminal';
      fixture.environment['ADELE_SOURCE_EDITOR_FRONTEND_OUTPUT'] =
          '/wrong-source-editor';
      fixture.environment['ADELE_DIFF_VIEWER_FRONTEND_OUTPUT'] =
          '/wrong-diff-viewer';
      fixture.environment['ADELE_TOOL_INSPECTION_FRONTEND_OUTPUT'] =
          '/wrong-tool-output';
      fixture.environment['ADELE_TOOL_INSPECTION_FRONTEND'] = 'wrong-tool';
      fixture.environment['ADELE_OPENAI_ACTIVITY_FRONTEND_OUTPUT'] =
          '/wrong-openai';
      fixture.environment['ADELE_SESSION_EVALUATOR_FRONTEND_OUTPUT'] =
          '/wrong-evaluator';
      fixture.environment['ADELE_LOCAL_DIRECTORY_PROJECT_FRONTEND_OUTPUT'] =
          '/wrong-local-directory-project';
      for (final List<String> arguments in <List<String>>[
        <String>['run', 'linux'],
        <String>['build', 'linux'],
        <String>['build', 'linux', '--profile'],
      ]) {
        final cold = outputDirectories.isEmpty;
        final ProcessResult result = await fixture.invoke(arguments);
        expect(result.exitCode, 0, reason: result.stderr.toString());
        expect(fixture.commands.readAsLinesSync(), <String>[
          'inspect-sdk',
          if (cold) ...toolCompilationEvents,
          'generate|aot|--incremental',
          if (cold) ...[
            for (final entrypoint in backendEntrypoints) ...[
              'compile|$entrypoint',
              'compiled|$entrypoint',
            ],
            'compile|git-pty-helper',
            'compile|$frontendHarness',
            'compiled|$frontendHarness',
            'compile|$toolFrontendHarness|filesystem',
            'compiled|$toolFrontendHarness|filesystem',
            'compile|$toolFrontendHarness|command',
            'compiled|$toolFrontendHarness|command',
            'compile|$openaiFrontendHarness',
            'compiled|$openaiFrontendHarness',
            'compile|$agentConfigurationFrontendHarness',
            'compiled|$agentConfigurationFrontendHarness',
            'compile|$modelConfigurationFrontendHarness',
            'compiled|$modelConfigurationFrontendHarness',
            'compile|$sessionEvaluatorFrontendHarness',
            'compiled|$sessionEvaluatorFrontendHarness',
            'compile|$localDirectoryProjectFrontendHarness',
            'compiled|$localDirectoryProjectFrontendHarness',
            'compile|$taskBrowserFrontendHarness',
            'compiled|$taskBrowserFrontendHarness',
            'compile|$terminalFrontendHarness',
            'compiled|$terminalFrontendHarness',
            'compile|$sourceEditorFrontendHarness',
            'compiled|$sourceEditorFrontendHarness',
            'compile|$diffViewerFrontendHarness',
            'compiled|$diffViewerFrontendHarness',
          ],
          'flutter-launch',
        ]);
        if (cold) expect(result.stdout, contains('frontend compiler output'));
        fixture.expectGenerationArguments(['--incremental'], true);
        expect(fixture.frontendArguments.readAsLinesSync(), <String>[
          'test',
          '--no-pub',
          '--concurrency',
          '1',
          frontendHarness,
        ]);
        final List<String> launched = fixture.launchArguments.readAsLinesSync();
        final bool run = arguments.first == 'run';
        expect(launched.take(run ? 5 : 4), <String>[
          arguments.first,
          if (run) '-d',
          'linux',
          arguments.length == 3 ? arguments.last : '--debug',
          '--target=lib/main.dart',
        ]);
        final Map<String, String> defines = <String, String>{};
        for (final String argument in launched.skip(run ? 5 : 4)) {
          expect(argument, startsWith('--dart-define='));
          final String define = argument.substring('--dart-define='.length);
          final int separator = define.indexOf('=');
          defines[define.substring(0, separator)] = define.substring(
            separator + 1,
          );
        }
        expect(launched, hasLength(run ? 9 : 8));
        if (firstDefines == null) {
          firstDefines = defines;
        } else {
          expect(defines, firstDefines);
        }
        expect(
          defines.keys,
          unorderedEquals(<String>[
            'ADELE_DARTAOTRUNTIME_EXECUTABLE',
            'ADELE_BACKEND_HOST_ARTIFACT',
            'ADELE_PLUGIN_INSTALLATION_ROOT',
            'ADELE_PLUGIN_STARTUP_ARGUMENTS_FILE',
          ]),
        );
        expect(
          defines['ADELE_DARTAOTRUNTIME_EXECUTABLE'],
          '${fixture.sdkBin.path}/dartaotruntime',
        );
        final File host = File(defines['ADELE_BACKEND_HOST_ARTIFACT']!);
        final Directory installations = Directory(
          defines['ADELE_PLUGIN_INSTALLATION_ROOT']!,
        );
        final File startupArguments = File(
          defines['ADELE_PLUGIN_STARTUP_ARGUMENTS_FILE']!,
        );
        final File git = File.fromUri(
          installations.uri.resolve('git/backend.aot'),
        );
        final File openai = File.fromUri(
          installations.uri.resolve('openai/backend.aot'),
        );
        final File agentsMd = File.fromUri(
          installations.uri.resolve('agents-md/backend.aot'),
        );
        final File conservativeToolPolicy = File.fromUri(
          installations.uri.resolve('conservative-tool-policy/backend.aot'),
        );
        final File searchTools = File.fromUri(
          installations.uri.resolve('search-tools/backend.aot'),
        );
        final File filesystemTools = File.fromUri(
          installations.uri.resolve('filesystem-tools/backend.aot'),
        );
        final File commandTools = File.fromUri(
          installations.uri.resolve('command-tools/backend.aot'),
        );
        final File frontend = File.fromUri(
          installations.uri.resolve('chat-strategy/frontend.evc'),
        );
        final File chat = File.fromUri(
          installations.uri.resolve('chat-strategy/backend.aot'),
        );
        final File localDirectoryProject = File.fromUri(
          installations.uri.resolve('local-directory-project/backend.aot'),
        );
        expect(host.uri.isAbsolute, isTrue);
        expect(git.uri.isAbsolute, isTrue);
        expect(openai.uri.isAbsolute, isTrue);
        expect(agentsMd.uri.isAbsolute, isTrue);
        expect(conservativeToolPolicy.uri.isAbsolute, isTrue);
        expect(searchTools.uri.isAbsolute, isTrue);
        expect(filesystemTools.uri.isAbsolute, isTrue);
        expect(commandTools.uri.isAbsolute, isTrue);
        expect(frontend.uri.isAbsolute, isTrue);
        expect(host.path, endsWith('/host.aot'));
        expect(git.path, endsWith('/git/backend.aot'));
        expect(openai.path, endsWith('/openai/backend.aot'));
        expect(agentsMd.path, endsWith('/agents-md/backend.aot'));
        expect(
          conservativeToolPolicy.path,
          endsWith('/conservative-tool-policy/backend.aot'),
        );
        expect(searchTools.path, endsWith('/search-tools/backend.aot'));
        expect(filesystemTools.path, endsWith('/filesystem-tools/backend.aot'));
        expect(commandTools.path, endsWith('/command-tools/backend.aot'));
        expect(frontend.path, endsWith('/chat-strategy/frontend.evc'));
        final compileEnvironment = fixture.frontendEnvironment
            .readAsLinesSync();
        expect(compileEnvironment.first, fixture.root.path);
        expect(compileEnvironment.last, contains('/.staging/'));
        expect(compileEnvironment.last, isNot(frontend.path));
        expect(File(compileEnvironment.last).existsSync(), isFalse);
        expect(installations.uri.isAbsolute, isTrue);
        expect(installations.path, contains('/installations/'));
        expect(startupArguments.uri.isAbsolute, isTrue);
        expect(startupArguments.path, contains('/startup/'));
        expect(startupArguments.parent.path, isNot(host.parent.path));
        expect(jsonDecode(startupArguments.readAsStringSync()), {
          'dev.adele.openai': ['--chatgpt-only'],
          'dev.adele.plugin.git': fixture.gitStartupArguments(),
        });
        expect(
          installations.listSync().whereType<Directory>().map(
            (entry) =>
                entry.uri.pathSegments.where((part) => part.isNotEmpty).last,
          ),
          unorderedEquals(stockInstallationDirectories),
        );
        final installedIds = <String>{};
        for (final plugin in [
          (
            directory: 'agent-configuration',
            id: 'dev.adele.plugin.agent-configuration',
            name: 'Agent Configuration',
            backend: true,
          ),
          (
            directory: 'model-configuration',
            id: _modelConfigurationId,
            name: 'Model Configuration',
            backend: true,
          ),
          (
            directory: 'git',
            id: 'dev.adele.plugin.git',
            name: 'Git',
            backend: true,
          ),
          (
            directory: 'openai',
            id: 'dev.adele.openai',
            name: 'OpenAI',
            backend: true,
          ),
          (
            directory: 'agents-md',
            id: 'dev.adele.plugin.agents-md',
            name: 'AGENTS.md',
            backend: true,
          ),
          (
            directory: 'conservative-tool-policy',
            id: 'dev.adele.plugin.conservative-tool-policy',
            name: 'Conservative Tool Policy',
            backend: true,
          ),
          (
            directory: 'search-tools',
            id: 'dev.adele.plugin.search-tools',
            name: 'Search Tools',
            backend: true,
          ),
          (
            directory: 'chat-strategy',
            id: 'dev.adele.plugin.chat-strategy',
            name: 'Chat',
            backend: true,
          ),
          (
            directory: 'filesystem-tools',
            id: 'dev.adele.plugin.filesystem-tools',
            name: 'Filesystem Tools',
            backend: true,
          ),
          (
            directory: 'command-tools',
            id: 'dev.adele.plugin.command-tools',
            name: 'Command Tools',
            backend: true,
          ),
          (
            directory: 'local-directory-project',
            id: 'dev.adele.plugin.local-directory-project',
            name: 'Local Directory Project',
            backend: true,
          ),
          (
            directory: 'task-browser',
            id: 'dev.adele.plugin.task-browser',
            name: 'Task Browser',
            backend: false,
          ),
          (
            directory: 'terminal',
            id: 'dev.adele.plugin.terminal',
            name: 'Terminal',
            backend: false,
          ),
          (
            directory: 'source-editor',
            id: 'dev.adele.source-editor',
            name: 'Source',
            backend: false,
          ),
          (
            directory: 'diff-viewer',
            id: 'dev.adele.diff-viewer',
            name: 'Diff',
            backend: true,
          ),
          (
            directory: 'session-evaluator',
            id: 'dev.adele.plugin.session-evaluator',
            name: 'Session Evaluator',
            backend: true,
          ),
        ]) {
          final directory = Directory.fromUri(
            installations.uri.resolve('${plugin.directory}/'),
          );
          final presentations = stockFrontendDescriptors[plugin.id];
          final extensions = stockFrontendExtensionDescriptors[plugin.id];
          final hasFrontend = presentations != null || extensions != null;
          final hasRecordsSchema = const {
            'openai',
            'agent-configuration',
            'model-configuration',
          }.contains(plugin.directory);
          final manifest = File.fromUri(
            directory.uri.resolve('adele_plugin.installation.json'),
          );
          final decoded =
              jsonDecode(manifest.readAsStringSync()) as Map<String, dynamic>;
          expect(
            installedIds.add(
              (decoded['metadata'] as Map<String, dynamic>)['id'] as String,
            ),
            isTrue,
          );
          expect(decoded, {
            'manifestVersion': 1,
            'metadata': {
              'id': plugin.id,
              'version': '0.1.0',
              'displayName': plugin.name,
            },
            if (plugin.directory == 'source-editor' ||
                plugin.directory == 'chat-strategy' ||
                plugin.directory == 'conservative-tool-policy')
              'settingsSchema': 'settings.schema.json',
            if (hasRecordsSchema) 'recordsSchema': 'records.schema.json',
            if (plugin.directory == 'model-configuration')
              'runModelPreferenceSource': {
                'extensionId': _modelPreferenceExtension,
              },
            if (plugin.directory == 'conservative-tool-policy')
              'authorizationPolicies': [
                {
                  'extensionId':
                      'dev.adele.plugin.conservative-tool-policy.authorization',
                  'enabledSettingId':
                      'dev.adele.plugin.conservative-tool-policy.enabled',
                },
              ],
            'components': {
              if (plugin.backend)
                'backend': {
                  'artifact': 'backend.aot',
                  if (plugin.directory == 'openai')
                    'consumesRecordTypes': ['dev.adele.openai.api-key'],
                  if (plugin.directory == 'agent-configuration')
                    'consumesRecordTypes': [
                      'dev.adele.plugin.agent-configuration.agent',
                    ],
                  if (plugin.directory == 'openai')
                    'appliesRecordTypes': [_openaiApplyHandler],
                  if (plugin.directory == 'model-configuration')
                    'consumesRecordTypes': ['$_modelConfigurationId.preset'],
                  if (plugin.directory == 'openai')
                    'consumesCredentialSlots': [
                      {
                        'recordType': 'dev.adele.openai.api-key',
                        'slots': ['api-key'],
                      },
                    ],
                },
              if (hasFrontend)
                'frontend': {
                  'artifact': 'frontend.evc',
                  'presentations': presentations ?? [],
                  'extensions': ?extensions,
                },
            },
          });
          expect(
            directory.listSync(),
            hasLength(
              1 +
                  (plugin.backend ? 1 : 0) +
                  (hasFrontend ? 1 : 0) +
                  (plugin.directory == 'source-editor' ? 1 : 0) +
                  (plugin.directory == 'chat-strategy' ? 1 : 0) +
                  (plugin.directory == 'conservative-tool-policy' ? 1 : 0) +
                  (hasRecordsSchema ? 1 : 0) +
                  (plugin.directory == 'git' ? 1 : 0),
            ),
          );
          if (hasFrontend) {
            final artifact = File.fromUri(
              directory.uri.resolve('frontend.evc'),
            );
            expect(artifact.readAsStringSync(), 'frontend bytecode\n');
          }
          for (final file in directory.listSync().cast<File>()) {
            retainedArtifacts[file.path] = file.readAsStringSync();
          }
        }
        expect(installedIds, hasLength(stockInstallationDirectories.length));
        final catalog = await PreparedPluginCatalog.discover(
          installations.path,
        );
        expect(catalog.issues, isEmpty);
        expect(
          catalog.installations.map(
            (installation) => installation.metadata.id.value,
          ),
          unorderedEquals(installedIds),
        );
        expect(
          catalog.installations.where(
            (installation) => installation.backendArtifactUri != null,
          ),
          hasLength(backendEntrypoints.length - 1), // Excludes shared host.
        );
        expect(
          catalog.installations.where(
            (installation) => installation.frontend != null,
          ),
          hasLength(frontendCompilations.length),
        );
        final conservative = catalog.installations.singleWhere(
          (installation) =>
              installation.metadata.id.value ==
              'dev.adele.plugin.conservative-tool-policy',
        );
        expect(conservative.backendArtifactUri, conservativeToolPolicy.uri);
        expect(conservative.frontend, isNull);
        final policySetting = conservative.settingsSchema!.definitions.single;
        expect(conservative.authorizationPolicyEnabledSettings, {
          conservative.authorizationPolicies.single: policySetting.id,
        });
        expect(conservative.recordsSchema, isNull);
        expect(conservative.backendConsumedCapabilities, isEmpty);
        expect(conservative.backendConsumedRecordTypes, isEmpty);
        expect(conservative.backendConsumedCredentialSlots, isEmpty);
        expect(conservative.authorizationPolicies.map((id) => id.value), [
          'dev.adele.plugin.conservative-tool-policy.authorization',
        ]);
        expect(
          catalog.installations.where(
            (installation) => installation.authorizationPolicies.isNotEmpty,
          ),
          [conservative],
        );
        final recordsInstallation = catalog.installations.singleWhere(
          (installation) =>
              installation.metadata.id.value == 'dev.adele.openai',
        );
        expect(recordsInstallation.metadata.id.value, 'dev.adele.openai');
        expect(
          catalog.installations.where(
            (installation) =>
                installation.backendRecordApplyHandlers.isNotEmpty,
          ),
          [recordsInstallation],
        );
        expect(recordsInstallation.backendConsumedRecordTypesToJson(), [
          'dev.adele.openai.api-key',
        ]);
        expect(recordsInstallation.backendConsumedCredentialSlotsToJson(), [
          {
            'recordType': 'dev.adele.openai.api-key',
            'slots': ['api-key'],
          },
        ]);
        expect(
          catalog.installations.where(
            (installation) =>
                installation.backendConsumedCredentialSlots.isNotEmpty,
          ),
          [recordsInstallation],
        );
        final recordsSchema = recordsInstallation.recordsSchema!;
        expect(
          recordsSchema.artifactUri,
          installations.uri.resolve('openai/records.schema.json'),
        );
        expect(
          File.fromUri(recordsSchema.artifactUri).readAsBytesSync(),
          File('plugins/openai/records.schema.json').readAsBytesSync(),
        );
        final agents = catalog.installations.singleWhere(
          (installation) =>
              installation.metadata.id.value ==
              'dev.adele.plugin.agent-configuration',
        );
        expect(
          agents.backendArtifactUri,
          installations.uri.resolve('agent-configuration/backend.aot'),
        );
        expect(
          File.fromUri(agents.backendArtifactUri!).readAsStringSync(),
          'snapshot $agentConfigurationEntrypoint\n',
        );
        final agentFrontend = agents.frontend!;
        expect(
          agentFrontend.artifactUri,
          installations.uri.resolve('agent-configuration/frontend.evc'),
        );
        expect(agentFrontend.extensions, isEmpty);
        final selector =
            agentFrontend.presentations.single
                as PreparedSessionAccessoryPresentation;
        expect(selector.toJson(), {
          'role': 'sessionAccessory',
          'extensionId': 'dev.adele.plugin.agent-configuration.selector',
          'library':
              'package:agent_configuration_frontend/agent_configuration_frontend.dart',
          'entrypoint': 'buildAgentSelector',
          'location': 'execution-configuration',
          'order': 100,
          'backendServices': ['agentCatalog', 'agentSelection'],
        });
        expect(agents.settingsSchema, isNull);
        expect(agents.backendConsumedCapabilities, isEmpty);
        expect(agents.backendConsumedRecordTypesToJson(), [
          'dev.adele.plugin.agent-configuration.agent',
        ]);
        expect(agents.backendConsumedCredentialSlots, isEmpty);
        expect(
          agents.recordsSchema!.artifactUri,
          installations.uri.resolve('agent-configuration/records.schema.json'),
        );
        expect(
          File.fromUri(agents.recordsSchema!.artifactUri).readAsBytesSync(),
          File(
            'plugins/agent_configuration/records.schema.json',
          ).readAsBytesSync(),
        );
        final presets = catalog.installations.singleWhere(
          (installation) =>
              installation.metadata.id.value == _modelConfigurationId,
        );
        expect(
          catalog.installations.where(
            (installation) =>
                installation.backendConsumedRecordTypes.isNotEmpty,
          ),
          unorderedEquals([agents, presets, recordsInstallation]),
        );
        expect(
          presets.backendArtifactUri,
          installations.uri.resolve('model-configuration/backend.aot'),
        );
        expect(
          File.fromUri(presets.backendArtifactUri!).readAsStringSync(),
          'snapshot $modelConfigurationEntrypoint\n',
        );
        final presetFrontend = presets.frontend!;
        expect(
          presetFrontend.artifactUri,
          installations.uri.resolve('model-configuration/frontend.evc'),
        );
        expect(presetFrontend.extensions.single.toJson(), {
          'kind': 'settingsFormBehavior',
          'extensionId': '$_modelConfigurationId.preset-form',
          'library': 'package:model_configuration_frontend/preset_form.dart',
          'entrypoint': 'configurePresetForm',
        });
        final presetSelector = presetFrontend.presentations
            .whereType<PreparedSessionAccessoryPresentation>()
            .single;
        expect(presetSelector.toJson(), {
          'role': 'sessionAccessory',
          'extensionId': '$_modelConfigurationId.selector',
          'library':
              'package:model_configuration_frontend/model_configuration_frontend.dart',
          'entrypoint': 'buildModelPresetSelector',
          'location': 'execution-configuration',
          'order': 200,
          'backendServices': ['modelPresetCatalog', 'modelPresetSelection'],
        });
        expect(
          presetFrontend.presentations
              .whereType<PreparedSettingsFieldEditorPresentation>()
              .single
              .toJson(),
          {
            'role': 'settingsFieldEditor',
            'extensionId': _modelReferenceEditor,
            'library':
                'package:model_configuration_frontend/model_reference_editor.dart',
            'entrypoint': 'buildModelReferenceEditor',
            'associatedAccess': [
              {
                'observe': {
                  'id': 'dev.adele.model.provider',
                  'majorVersion': 1,
                  'serviceId': 'modelProvider',
                },
                'invokeAssociated': {
                  'id': 'dev.adele.model.catalog',
                  'majorVersion': 1,
                  'serviceId': 'modelCatalog',
                },
              },
            ],
          },
        );
        expect(
          presets.runModelPreferenceSource?.value,
          _modelPreferenceExtension,
        );
        expect(catalog.records.definitions, [
          recordsSchema.definitions.single,
          agents.recordsSchema!.definitions.single,
          presets.recordsSchema!.definitions.single,
        ]);
        expect(catalog.records.definitions.map((type) => type.id.value), [
          'dev.adele.openai.api-key',
          'dev.adele.plugin.agent-configuration.agent',
          '$_modelConfigurationId.preset',
        ]);
        expect(
          catalog.records.collections.map((collection) => collection.value),
          ['agents', 'model-presets', 'providers'],
        );
        expect(
          presetRecords.listSync(recursive: true).whereType<File>(),
          isEmpty,
          reason:
              'Publishing declarations must not seed configuration records.',
        );
        final evaluator = catalog.installations.singleWhere(
          (installation) =>
              installation.metadata.id.value ==
              'dev.adele.plugin.session-evaluator',
        );
        expect(
          evaluator.frontend!.artifactUri,
          installations.uri.resolve('session-evaluator/frontend.evc'),
        );
        expect(evaluator.frontend!.presentations, isEmpty);
        expect(evaluator.frontend!.extensions.single.toJson(), {
          'kind': 'sessionCommand',
          'extensionId':
              'dev.adele.plugin.session-evaluator.command.prepare-handoff',
          'commandId': 'dev.adele.session-evaluator.export-session-evidence',
          'label': 'Prepare Evaluation Handoff...',
          'library':
              'package:session_evaluator_frontend/session_evaluator_frontend.dart',
          'entrypoint': 'prepareEvaluationHandoff',
          'backendServices': ['dev.adele.session-evaluation-handoff'],
          'clipboardWrite': true,
          'feedback': true,
        });
        expect(evaluator.settingsSchema, isNull);
        expect(evaluator.backendConsumedCapabilities, isEmpty);
        expect(
          evaluator.backendArtifactUri,
          installations.uri.resolve('session-evaluator/backend.aot'),
        );
        expect(
          File.fromUri(evaluator.backendArtifactUri!).readAsStringSync(),
          'snapshot $sessionEvaluatorEntrypoint\n',
        );
        final diff = catalog.installations.singleWhere(
          (installation) =>
              installation.metadata.id.value == 'dev.adele.diff-viewer',
        );
        expect(
          diff.backendArtifactUri,
          installations.uri.resolve('diff-viewer/backend.aot'),
        );
        expect(
          File.fromUri(diff.backendArtifactUri!).readAsStringSync(),
          'snapshot $diffViewerEntrypoint\n',
        );
        expect(diff.backendConsumedCapabilities, isEmpty);
        expect(diff.frontend!.extensions, isEmpty);
        expect(
          diff.frontend!.artifactUri,
          installations.uri.resolve('diff-viewer/frontend.evc'),
        );
        final diffDescriptor =
            diff.frontend!.presentations.single
                as PreparedMainContentPresentation;
        expect(diffDescriptor.canRequestSourceDisplay, isTrue);
        expect(diffDescriptor.sessionFeedback, isTrue);
        expect(diffDescriptor.backendServices, isEmpty);
        expect(diffDescriptor.optionalBackendServices, ['diff.reviewDraft']);
        expect(
          catalog.installations
              .where(
                (installation) =>
                    installation.frontend?.presentations
                        .whereType<PreparedMainContentPresentation>()
                        .any(
                          (descriptor) => descriptor.canRequestSourceDisplay,
                        ) ??
                    false,
              )
              .map((installation) => installation.metadata.id.value),
          ['dev.adele.diff-viewer'],
        );
        expect(diffDescriptor.toJson(), {
          ...stockFrontendDescriptors['dev.adele.diff-viewer']!.single,
          'sessionExecution': false,
          'canInspectSessionContent': false,
          'backendServices': <String>[],
          'capabilities': <Object?>[],
          'environmentReadCapabilities': <Object?>[],
          'strategyAffinity': 'independent',
          'actions': <Object?>[],
          'operations': <String, Object?>{},
          'retainedData': false,
          'nativeCodeEditor': false,
          'richDocumentEditor': false,
          'environmentTextFiles': false,
        });
        expect(
          catalog.installations
              .where(
                (installation) =>
                    installation.frontend?.presentations
                        .whereType<PreparedMainContentPresentation>()
                        .any((descriptor) => descriptor.richDocumentEditor) ??
                    false,
              )
              .map((installation) => installation.metadata.id.value),
          ['dev.adele.plugin.chat-strategy'],
        );
        final source = catalog.installations.singleWhere(
          (installation) =>
              installation.metadata.id.value == 'dev.adele.source-editor',
        );
        expect(source.backendArtifactUri, isNull);
        final schema = source.settingsSchema!;
        expect(
          schema.artifactUri,
          installations.uri.resolve('source-editor/settings.schema.json'),
        );
        expect(
          File.fromUri(schema.artifactUri).readAsBytesSync(),
          File('plugins/source_editor/settings.schema.json').readAsBytesSync(),
        );
        expect(
          jsonDecode(File.fromUri(schema.artifactUri).readAsStringSync()),
          {
            'schemaVersion': 1,
            'definitions': [
              {
                'id': 'dev.adele.source-editor.enable-folding',
                'type': 'boolean',
                'default': false,
                'label': 'Enable Code Folding',
                'category': 'Editor',
                'section': 'Display',
              },
            ],
          },
        );
        final setting = schema.definitions.single;
        expect(setting.id.value, 'dev.adele.source-editor.enable-folding');
        expect(setting.owner.value, source.metadata.id.value);
        expect(setting.defaultValue, isFalse);
        expect(setting.label, 'Enable Code Folding');
        expect(setting.category, 'Editor');
        expect(setting.section, 'Display');
        expect(setting.description, isNull);
        expect(setting.validate(true), isTrue);
        expect(() => setting.validate('true'), throwsException);
        expect(() => setting.validate(1), throwsException);
        final chatSettings = catalog.installations
            .singleWhere(
              (entry) =>
                  entry.metadata.id.value == 'dev.adele.plugin.chat-strategy',
            )
            .settingsSchema!;
        final budget = chatSettings.definitions.single;
        expect(
          File.fromUri(chatSettings.artifactUri).readAsBytesSync(),
          File('plugins/chat_strategy/settings.schema.json').readAsBytesSync(),
        );
        expect(
          budget.id.value,
          'dev.adele.plugin.chat-strategy.max-model-invocations',
        );
        expect(budget.defaultValue, 40);
        expect(budget.category, 'Agents');
        expect(budget.section, 'Execution');
        expect(budget.label, 'Maximum Model Invocations per Run');
        expect(budget.validate(1), 1);
        expect(budget.validate(80), 80);
        expect(budget.validate(9223372036854775807), 9223372036854775807);
        expect(() => budget.validate(0), throwsException);
        expect(catalog.settings.definitions, [budget, policySetting, setting]);
        expect(catalog.settings.resolve(setting.id).value, isFalse);
        final sourceCommand =
            source.frontend!.extensions.single
                as PreparedMainContentActionCommandExtension;
        expect(sourceCommand.toJson(), {
          'kind': 'mainContentActionCommand',
          'extensionId': 'dev.adele.source-editor.command.open-source',
          'commandId': 'dev.adele.source-editor.open-source',
          'mainContentExtensionId': 'dev.adele.source-editor.main-content',
          'actionId': 'open',
        });
        expect(
          source.frontend!.artifactUri,
          installations.uri.resolve('source-editor/frontend.evc'),
        );
        final sourceDescriptor =
            source.frontend!.presentations.single
                as PreparedMainContentPresentation;
        expect(
          sourceDescriptor.extensionId.value,
          'dev.adele.source-editor.main-content',
        );
        expect(
          sourceDescriptor.library,
          'package:source_editor_frontend/main.dart',
        );
        expect(sourceDescriptor.initialize, 'initializeSource');
        expect(sourceDescriptor.entrypoint, 'sourcePane');
        expect(sourceDescriptor.order, 300);
        expect(sourceDescriptor.actions.single.id, 'open');
        expect(sourceDescriptor.actions.single.label, 'Open Source...');
        expect(sourceDescriptor.actions.single.entrypoint, 'openSourceInput');
        expect(
          sourceCommand.mainContentExtensionId,
          sourceDescriptor.extensionId,
        );
        expect(sourceCommand.actionId, sourceDescriptor.actions.single.id);
        expect(sourceDescriptor.operations, {
          'display': 'displaySource',
          'save': 'saveSource',
          'close': 'closeSource',
          'exit': 'closeSources',
        });
        expect(sourceDescriptor.closeOperation, 'close');
        expect(sourceDescriptor.exitOperation, 'exit');
        expect(sourceDescriptor.displaySourceFileOperation, 'display');
        expect(sourceDescriptor.retainedData, isTrue);
        expect(sourceDescriptor.nativeCodeEditor, isTrue);
        expect(sourceDescriptor.environmentTextFiles, isTrue);
        expect(sourceDescriptor.backendServices, isEmpty);
        expect(sourceDescriptor.optionalBackendServices, isEmpty);
        expect(sourceDescriptor.sessionExecution, isFalse);
        expect(
          sourceDescriptor.strategyAffinity,
          PreparedStrategyAffinity.independent,
        );
        final terminal = catalog.installations.singleWhere(
          (installation) =>
              installation.metadata.id.value == 'dev.adele.plugin.terminal',
        );
        expect(terminal.backendArtifactUri, isNull);
        final terminalCommand =
            terminal.frontend!.extensions.single
                as PreparedConsoleActionCommandExtension;
        expect(
          terminalCommand.extensionId.value,
          'dev.adele.plugin.terminal.command.new-terminal',
        );
        expect(
          terminalCommand.commandId.value,
          'dev.adele.plugin.terminal.new-terminal',
        );
        expect(terminalCommand.toJson(), {
          'kind': 'consoleActionCommand',
          'extensionId': 'dev.adele.plugin.terminal.command.new-terminal',
          'commandId': 'dev.adele.plugin.terminal.new-terminal',
          'consoleExtensionId': 'dev.adele.plugin.terminal.console',
          'actionId': 'new-terminal',
        });
        expect(
          terminal.frontend!.artifactUri,
          installations.uri.resolve('terminal/frontend.evc'),
        );
        final console =
            terminal.frontend!.presentations.single
                as PreparedConsolePresentation;
        expect(console.extensionId.value, 'dev.adele.plugin.terminal.console');
        expect(
          console.library,
          'package:terminal_frontend/terminal_frontend.dart',
        );
        expect(console.entrypoint, 'buildTerminal');
        expect(console.keepAlive, isFalse);
        expect(console.actions.single.id, 'new-terminal');
        expect(console.actions.single.label, 'New Terminal');
        expect(console.actions.single.entrypoint, 'newTerminal');
        expect(terminalCommand.consoleExtensionId, console.extensionId);
        expect(terminalCommand.actionId, console.actions.single.id);
        final commandOutput = catalog.installations
            .singleWhere(
              (installation) =>
                  installation.metadata.id.value ==
                  'dev.adele.plugin.command-tools',
            )
            .frontend!
            .presentations
            .whereType<PreparedConsolePresentation>()
            .single;
        expect(commandOutput.keepAlive, isTrue);
        expect(commandOutput.readOnly, isTrue);
        expect(commandOutput.backendServices, ['command.output']);
        final localDirectoryProjectInstallation = catalog.installations
            .singleWhere(
              (installation) =>
                  installation.metadata.id.value ==
                  'dev.adele.plugin.local-directory-project',
            );
        expect(
          localDirectoryProjectInstallation.backendArtifactUri,
          localDirectoryProject.uri,
        );
        expect(
          localDirectoryProjectInstallation.frontend!.artifactUri,
          installations.uri.resolve('local-directory-project/frontend.evc'),
        );
        expect(
          localDirectoryProjectInstallation.frontend!.extensions.single
              .toJson(),
          {
            'kind': 'projectSelector',
            'extensionId':
                'dev.adele.plugin.local-directory-project.project-selector',
            'projectProviderId': 'dev.adele.project.local-directory',
            'displayName': 'Open Local Directory...',
            'library':
                'package:local_directory_project_frontend/local_directory_project_frontend.dart',
            'entrypoint': 'selectProject',
          },
        );
        for (final installation in catalog.installations) {
          final descriptors =
              stockFrontendDescriptors[installation.metadata.id.value];
          expect(
            installation.frontend?.presentations.length,
            installation.frontend == null ? null : descriptors?.length ?? 0,
          );
          expect(
            installation.frontend?.extensions.map(
              (extension) => extension.toJson(),
            ),
            installation.frontend == null
                ? null
                : stockFrontendExtensionDescriptors[installation
                          .metadata
                          .id
                          .value] ??
                      [],
          );
        }
        retainedArtifacts[startupArguments.path] = startupArguments
            .readAsStringSync();
        expect(
          host.parent.path,
          startsWith(
            '${fixture.root.path}/.dart_tool/adele/desktop-plugins/snapshots/',
          ),
        );
        expect(outputDirectories.add(host.parent.path), cold);
        expect(
          host.parent.listSync().map(
            (entry) =>
                entry.uri.pathSegments.where((part) => part.isNotEmpty).last,
          ),
          unorderedEquals(['host.aot', 'installations', 'receipt.json']),
        );
        expect(host.readAsStringSync(), 'snapshot $hostEntrypoint\n');
        expect(git.readAsStringSync(), 'snapshot $gitEntrypoint\n');
        expect(openai.readAsStringSync(), 'snapshot $openaiEntrypoint\n');
        expect(agentsMd.readAsStringSync(), 'snapshot $agentsMdEntrypoint\n');
        expect(
          conservativeToolPolicy.readAsStringSync(),
          'snapshot $conservativeToolPolicyEntrypoint\n',
        );
        expect(
          searchTools.readAsStringSync(),
          'snapshot $searchToolsEntrypoint\n',
        );
        expect(
          filesystemTools.readAsStringSync(),
          'snapshot $filesystemToolsEntrypoint\n',
        );
        expect(
          commandTools.readAsStringSync(),
          'snapshot $commandToolsEntrypoint\n',
        );
        expect(frontend.readAsStringSync(), 'frontend bytecode\n');
        expect(chat.readAsStringSync(), 'snapshot $chatEntrypoint\n');
        expect(
          localDirectoryProject.readAsStringSync(),
          'snapshot $localDirectoryProjectEntrypoint\n',
        );
        retainedArtifacts[host.path] = host.readAsStringSync();
        for (final MapEntry<String, String> artifact
            in retainedArtifacts.entries) {
          expect(File(artifact.key).readAsStringSync(), artifact.value);
        }
        fixture.commands.deleteSync();
      }
    },
  );

  for (final missing in PreparedPluginComponent.values) {
    test(
      'Command missing ${missing.name} retains its installed sibling',
      () async {
        final result = await fixture.invoke(['run', 'linux']);
        expect(result.exitCode, 0, reason: result.stderr.toString());
        const prefix = '--dart-define=ADELE_PLUGIN_INSTALLATION_ROOT=';
        final rootPath = fixture.launchArguments
            .readAsLinesSync()
            .singleWhere((argument) => argument.startsWith(prefix))
            .substring(prefix.length);
        await File(
          '$rootPath/command-tools/${missing == PreparedPluginComponent.backend ? 'backend.aot' : 'frontend.evc'}',
        ).delete();

        final catalog = await PreparedPluginCatalog.discover(rootPath);
        expect(
          catalog.installations,
          hasLength(stockInstallationDirectories.length),
        );
        expect(catalog.issues.single.component, missing);
        final command = catalog.installations.singleWhere(
          (installation) =>
              installation.metadata.id.value ==
              'dev.adele.plugin.command-tools',
        );
        expect(
          command.backendArtifactUri,
          missing == PreparedPluginComponent.backend ? isNull : isNotNull,
        );
        expect(
          command.frontend,
          missing == PreparedPluginComponent.frontend ? isNull : isNotNull,
        );
        expect(
          catalog.installations.where(
            (installation) => installation.backendArtifactUri != null,
          ),
          hasLength(
            backendEntrypoints.length -
                1 - // Shared host is not a plugin installation.
                (missing == PreparedPluginComponent.backend ? 1 : 0),
          ),
        );
        expect(
          catalog.installations.where(
            (installation) => installation.frontend != null,
          ),
          hasLength(
            frontendCompilations.length -
                (missing == PreparedPluginComponent.frontend ? 1 : 0),
          ),
        );
      },
    );
  }

  test('missing selector EVC retains its owning backend', () async {
    final result = await fixture.invoke(['run', 'linux']);
    expect(result.exitCode, 0, reason: result.stderr.toString());
    const prefix = '--dart-define=ADELE_PLUGIN_INSTALLATION_ROOT=';
    final rootPath = fixture.launchArguments
        .readAsLinesSync()
        .singleWhere((argument) => argument.startsWith(prefix))
        .substring(prefix.length);
    await File('$rootPath/local-directory-project/frontend.evc').delete();

    final catalog = await PreparedPluginCatalog.discover(rootPath);
    expect(
      catalog.installations,
      hasLength(stockInstallationDirectories.length),
    );
    expect(catalog.issues.single.component, PreparedPluginComponent.frontend);
    final localDirectoryProject = catalog.installations.singleWhere(
      (installation) =>
          installation.metadata.id.value ==
          'dev.adele.plugin.local-directory-project',
    );
    expect(localDirectoryProject.backendArtifactUri, isNotNull);
    expect(localDirectoryProject.frontend, isNull);
    expect(
      catalog.installations.where(
        (installation) => installation.frontend != null,
      ),
      hasLength(frontendCompilations.length - 1),
    );
  });

  for (final explicitClient in [false, true]) {
    test(
      'writes only public OpenAI startup config, explicit client=$explicitClient',
      () async {
        final credentials = File('${fixture.root.path}/credentials.json')
          ..writeAsStringSync(
            jsonEncode({
              'accessToken': 'secret-access-token',
              'refreshToken': 'secret-refresh-token',
            }),
          );
        fixture.environment.addAll({
          'ADELE_OPENAI_CHATGPT_CREDENTIAL_FILE': credentials.path,
          'ADELE_OPENAI_CHATGPT_CLIENT_ID': explicitClient
              ? 'public-client'
              : '  ',
          'ADELE_OPENAI_CHATGPT_INSTANCE_ID': 'work-instance',
          'ADELE_OPENAI_CHATGPT_OAUTH_ISSUER': 'https://issuer.example.com',
          'ADELE_OPENAI_CHATGPT_REDIRECT_URI': 'http://localhost:1455/callback',
          'ADELE_OPENAI_CHATGPT_ENDPOINT':
              'https://model.example.com/responses',
          'ADELE_OPENAI_CHATGPT_MODEL': 'app-model-not-backend-config',
          'ADELE_OPENAI_CHATGPT_ACCESS_TOKEN': 'secret-env-access-token',
          'ADELE_OPENAI_CHATGPT_REFRESH_TOKEN': 'secret-env-refresh-token',
          'OPENAI_API_KEY': 'secret-api-key',
        });
        final result = await fixture.invoke(['run', 'linux']);
        expect(result.exitCode, 0, reason: result.stderr.toString());
        final serialized = fixture.readStartupArguments();
        final arguments = jsonDecode(serialized) as Map<String, Object?>;
        expect(arguments.keys, ['dev.adele.openai', 'dev.adele.plugin.git']);
        expect(
          arguments['dev.adele.plugin.git'],
          fixture.gitStartupArguments(),
        );
        final openai = (arguments['dev.adele.openai']! as List<Object?>)
            .cast<String>();
        expect(openai, hasLength(2));
        expect(openai.first, '--chatgpt-only');
        expect(jsonDecode(openai.last), {
          'credentialFile': credentials.path,
          if (explicitClient)
            'clientId': 'public-client'
          else
            'experimentalCodexClient': true,
          'instanceId': 'work-instance',
          'issuer': 'https://issuer.example.com',
          'redirectUri': 'http://localhost:1455/callback',
          'endpoint': 'https://model.example.com/responses',
        });
        for (final forbidden in ['secret-', 'app-model-not-backend-config']) {
          expect(serialized, isNot(contains(forbidden)));
          expect(
            fixture.launchArguments.readAsStringSync(),
            isNot(contains(forbidden)),
          );
        }
        final output = Directory(
          '${fixture.root.path}/.dart_tool/adele/desktop-plugins',
        );
        final manifests = output
            .listSync(recursive: true)
            .whereType<File>()
            .where(
              (file) => file.path.endsWith('adele_plugin.installation.json'),
            );
        expect(manifests, hasLength(stockInstallationDirectories.length));
        for (final manifest in manifests) {
          for (final forbidden in [
            'secret-',
            credentials.path,
            'public-client',
            'work-instance',
            'issuer.example.com',
            'localhost:1455',
            'model.example.com',
            'app-model-not-backend-config',
            '--chatgpt-only',
          ]) {
            expect(manifest.readAsStringSync(), isNot(contains(forbidden)));
            expect(result.stdout, isNot(contains(forbidden)));
            expect(result.stderr, isNot(contains(forbidden)));
            expect(
              fixture.launchArguments.readAsStringSync(),
              isNot(contains(forbidden)),
            );
          }
        }
      },
    );
  }

  test(
    'credential references need not exist and blank public overrides are omitted',
    () async {
      final credentialPath = '${fixture.root.path}/not-created.json';
      fixture.environment['ADELE_OPENAI_CHATGPT_CREDENTIAL_FILE'] =
          credentialPath;
      fixture.environment['ADELE_OPENAI_CHATGPT_INSTANCE_ID'] = '  ';
      fixture.environment['ADELE_OPENAI_CHATGPT_OAUTH_ISSUER'] = '  ';
      final result = await fixture.invoke(['build', 'linux']);
      expect(result.exitCode, 0, reason: result.stderr.toString());
      final serialized = fixture.readStartupArguments();
      expect(jsonDecode(serialized), {
        'dev.adele.plugin.git': fixture.gitStartupArguments(),
        'dev.adele.openai': [
          '--chatgpt-only',
          jsonEncode({
            'credentialFile': credentialPath,
            'experimentalCodexClient': true,
          }),
        ],
      });
      expect(File(credentialPath).existsSync(), isFalse);
    },
  );

  test(
    'without credentials OpenAI stays chatgpt-only and ignores other config',
    () async {
      fixture.environment.addAll({
        'ADELE_OPENAI_CHATGPT_CREDENTIAL_FILE': '  ',
        'ADELE_OPENAI_CHATGPT_CLIENT_ID': 'unused-client',
        'ADELE_OPENAI_CHATGPT_OAUTH_ISSUER': 'https://[invalid',
        'OPENAI_API_KEY': 'must-not-enable-api-key-context',
      });
      final result = await fixture.invoke(['run', 'linux']);
      expect(result.exitCode, 0, reason: result.stderr.toString());
      final serialized = fixture.readStartupArguments();
      expect(jsonDecode(serialized), {
        'dev.adele.openai': ['--chatgpt-only'],
        'dev.adele.plugin.git': fixture.gitStartupArguments(),
      });
    },
  );

  test(
    'invalid public URI is forwarded for backend-local validation',
    () async {
      fixture.environment.addAll({
        'ADELE_OPENAI_CHATGPT_CREDENTIAL_FILE': '/not-read.json',
        'ADELE_OPENAI_CHATGPT_OAUTH_ISSUER': 'https://[invalid-private-value',
      });
      final result = await fixture.invoke(['run', 'linux']);
      expect(result.exitCode, 0, reason: result.stderr.toString());
      final arguments =
          jsonDecode(fixture.readStartupArguments()) as Map<String, dynamic>;
      final openai = arguments['dev.adele.openai'] as List<dynamic>;
      expect(jsonDecode(openai[1] as String), {
        'credentialFile': '/not-read.json',
        'experimentalCodexClient': true,
        'issuer': 'https://[invalid-private-value',
      });
      expect(result.stderr, isNot(contains('invalid-private-value')));
      expect(fixture.launchArguments.existsSync(), isTrue);
    },
  );

  for (final declaration in [
    (kind: 'settings', source: 'chat_strategy', installation: 'chat-strategy'),
    (
      kind: 'settings',
      source: 'conservative_tool_policy',
      installation: 'conservative-tool-policy',
    ),
    (kind: 'settings', source: 'source_editor', installation: 'source-editor'),
    (kind: 'records', source: 'openai', installation: 'openai'),
    (
      kind: 'records',
      source: 'agent_configuration',
      installation: 'agent-configuration',
    ),
    (
      kind: 'records',
      source: 'model_configuration',
      installation: 'model-configuration',
    ),
  ]) {
    for (final failure in ['missing', 'empty', 'directory']) {
      test(
        'stock ${declaration.kind} schema $failure prevents ${declaration.installation} publication and launch',
        () async {
          final filename = '${declaration.kind}.schema.json';
          final schema = File(
            '${fixture.root.path}/plugins/${declaration.source}/$filename',
          );
          if (failure == 'empty') {
            schema.writeAsBytesSync([]);
          } else {
            schema.deleteSync();
            if (failure == 'directory') Directory(schema.path).createSync();
          }
          final result = await fixture.invoke(['run', 'linux']);
          expect(result.exitCode, 1);
          expect(result.stderr, contains('${declaration.kind} schema'));
          expect(result.stderr, contains(filename));
          expect(fixture.launchArguments.existsSync(), isFalse);
          expect(
            fixture.commands.readAsLinesSync(),
            isNot(contains('flutter-launch')),
          );
          fixture.expectNoPublishedInstallations();
        },
      );
    }
  }
}
