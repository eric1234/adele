import 'dart:convert';
import 'dart:io';

import 'package:adele_model_tool/adele_model_tool.dart';
import 'package:adele_plugin_api/adele_plugin_api.dart';
import 'package:adele_product/adele_product.dart';
import 'package:plugin_runtime/plugin_runtime.dart';
import 'package:test/test.dart';

void main() {
  late Directory temporary;
  late Directory root;

  setUp(() async {
    temporary = await Directory.systemTemp.createTemp('prepared catalog ');
    root = await Directory.fromUri(
      temporary.uri.resolve('installations/'),
    ).create();
  });
  tearDown(() => temporary.delete(recursive: true));

  Future<Directory> install(String name, Object? manifest) async {
    final directory = await Directory.fromUri(
      root.uri.resolve('$name/'),
    ).create();
    await File.fromUri(
      directory.uri.resolve('adele_plugin.installation.json'),
    ).writeAsString(jsonEncode(manifest));
    await File.fromUri(
      directory.uri.resolve('backend.aot'),
    ).writeAsString('aot');
    await File.fromUri(
      directory.uri.resolve('frontend.evc'),
    ).writeAsString('not bytecode; decoding belongs to the view');
    return directory;
  }

  test(
    'empty, missing, and empty-directory roots are empty catalogs',
    () async {
      for (final path in ['', '${root.path}/missing', root.path]) {
        final catalog = await PreparedPluginCatalog.discover(path);
        expect(catalog.installations, isEmpty);
        expect(catalog.issues, isEmpty);
      }
    },
  );

  test(
    'existing non-directory roots throw instead of becoming empty',
    () async {
      final file = await File.fromUri(
        root.uri.resolve('not-a-directory'),
      ).writeAsString('file');
      await expectLater(
        PreparedPluginCatalog.discover(file.path),
        throwsA(isA<FileSystemException>()),
      );
    },
  );

  test(
    'genuine root I/O failures propagate',
    () async {
      final loop = Link.fromUri(temporary.uri.resolve('loop'));
      await loop.create(loop.path);
      await expectLater(
        PreparedPluginCatalog.discover(loop.path),
        throwsA(isA<FileSystemException>()),
      );
    },
    skip: Platform.isWindows ? 'Symlink creation requires privileges.' : false,
  );

  test(
    'discovers arbitrary IDs and metadata in sorted directory order',
    () async {
      final z = await install(
        'z-first-created',
        _manifest(id: 'org.example.alpha'),
      );
      final a = await install('a-second-created', {
        'manifestVersion': 1,
        'metadata': {
          'id': 'org.example.zulu',
          'version': 'opaque-version',
          'displayName': 'Metadata Only',
          'description': 'No prepared backend',
        },
        'components': <String, Object?>{},
      });
      await File.fromUri(
        root.uri.resolve('unrelated.txt'),
      ).writeAsString('ignored');
      final catalog = await PreparedPluginCatalog.discover(root.path);
      expect(catalog.issues, isEmpty);
      expect(catalog.installations.map((item) => item.metadata.id), [
        PluginId('org.example.zulu'),
        PluginId('org.example.alpha'),
      ]);
      final metadataOnly = catalog.installations.first;
      expect(metadataOnly.metadata, isA<PluginMetadata>());
      expect(metadataOnly.metadata.version, 'opaque-version');
      expect(metadataOnly.metadata.displayName, 'Metadata Only');
      expect(metadataOnly.metadata.description, 'No prepared backend');
      expect(metadataOnly.installationDirectory.uri, a.uri);
      expect(metadataOnly.backendArtifactUri, isNull);
      final backend = catalog.installations.last;
      expect(backend.metadata.description, isNull);
      expect(backend.installationDirectory.uri, z.uri);
      expect(backend.backendArtifactUri, z.uri.resolve('backend.aot'));
      expect(backend.backendArtifactUri!.scheme, 'file');
      expect(backend.backendArtifactUri!.isAbsolute, isTrue);
      expect(() => catalog.installations.clear(), throwsUnsupportedError);
      expect(() => catalog.issues.clear(), throwsUnsupportedError);
    },
  );

  test(
    'source manifests are never interpreted as installed manifests',
    () async {
      final source = await Directory.fromUri(
        root.uri.resolve('source/'),
      ).create();
      await File.fromUri(
        source.uri.resolve('adele_plugin.yaml'),
      ).writeAsString('id: org.example.source\nbackend: backend.aot\n');
      await install('prepared', _manifest());
      final catalog = await PreparedPluginCatalog.discover(root.path);
      expect(catalog.installations, hasLength(1));
      expect(catalog.issues.single.installationDirectory.uri, source.uri);
    },
  );

  for (final backend in [false, true]) {
    for (final frontend in [false, true]) {
      test('discovers backend=$backend, frontend=$frontend', () async {
        final directory = await install(
          'plugin',
          _manifest(
            components: {
              if (backend) 'backend': {'artifact': 'backend.aot'},
              if (frontend) 'frontend': _frontend(),
            },
          ),
        );
        final catalog = await PreparedPluginCatalog.discover(root.path);
        expect(catalog.issues, isEmpty);
        final installation = catalog.installations.single;
        expect(installation.metadata.id, PluginId('org.example.plugin'));
        expect(installation.installationDirectory.uri, directory.uri);
        expect(
          installation.backendArtifactUri,
          backend ? directory.uri.resolve('backend.aot') : isNull,
        );
        if (frontend) {
          expect(
            installation.frontend!.artifactUri,
            directory.uri.resolve('frontend.evc'),
          );
          expect(installation.frontend!.presentations, isEmpty);
        } else {
          expect(installation.frontend, isNull);
        }
      });
    }
  }

  test(
    'decodes ordered typed descriptors without decoding EVC bytes',
    () async {
      final directory = await install(
        'frontend',
        _manifest(
          components: {
            'frontend': _frontend(
              presentations: [_toolActivity, _session, _modelNativeActivity],
            ),
          },
        ),
      );
      final catalog = await PreparedPluginCatalog.discover(root.path);
      expect(catalog.issues, isEmpty);
      final frontend = catalog.installations.single.frontend!;
      expect(frontend.artifactUri, directory.uri.resolve('frontend.evc'));
      expect(frontend.artifactUri.scheme, 'file');
      expect(frontend.artifactUri.isAbsolute, isTrue);
      expect(frontend.presentations, hasLength(3));
      final tool =
          frontend.presentations[0] as PreparedToolActivityPresentation;
      expect(tool.library, _toolActivity['library']);
      expect(tool.toolId, ToolId(_toolActivity['toolId']!));
      expect(
        tool.inspectionExtensionId,
        ExtensionId(_toolActivity['inspectionExtensionId']!),
      );
      expect(
        tool.compactExtensionId,
        ExtensionId(_toolActivity['compactExtensionId']!),
      );
      expect(tool.inspectionEntrypoint, _toolActivity['inspectionEntrypoint']);
      expect(tool.compactEntrypoint, _toolActivity['compactEntrypoint']);
      final session = frontend.presentations[1] as PreparedSessionPresentation;
      expect(session.library, _session['library']);
      expect(session.extensionId, ExtensionId(_session['extensionId']!));
      expect(
        session.strategyId,
        OrchestrationStrategyId(_session['strategyId']!),
      );
      expect(session.entrypoint, _session['entrypoint']);
      expect(session.hostAdapter, _session['hostAdapter']);
      final native =
          frontend.presentations[2] as PreparedModelNativeActivityPresentation;
      expect(native.library, _modelNativeActivity['library']);
      expect(native.presentationKind, _modelNativeActivity['presentationKind']);
      expect(
        native.inspectionExtensionId,
        ExtensionId(_modelNativeActivity['inspectionExtensionId']!),
      );
      expect(
        native.compactExtensionId,
        ExtensionId(_modelNativeActivity['compactExtensionId']!),
      );
      expect(
        native.inspectionEntrypoint,
        _modelNativeActivity['inspectionEntrypoint'],
      );
      expect(
        native.compactEntrypoint,
        _modelNativeActivity['compactEntrypoint'],
      );
      expect(() => frontend.presentations.clear(), throwsUnsupportedError);

      final descriptors = frontend.presentations.toList();
      final copy = PreparedFrontendComponent(
        artifactUri: frontend.artifactUri,
        presentations: descriptors,
      );
      descriptors.clear();
      expect(copy.presentations, frontend.presentations);
      expect(() => copy.presentations.clear(), throwsUnsupportedError);
    },
  );

  test('OpenAI backend and native frontend are one installation', () async {
    final directory = await install(
      'openai',
      _manifest(
        id: 'dev.adele.openai',
        components: {
          'backend': {'artifact': 'backend.aot'},
          'frontend': _frontend(presentations: [_modelNativeActivity]),
        },
      ),
    );
    final catalog = await PreparedPluginCatalog.discover(root.path);
    expect(catalog.issues, isEmpty);
    final installation = catalog.installations.single;
    expect(installation.metadata.id, PluginId('dev.adele.openai'));
    expect(
      installation.backendArtifactUri,
      directory.uri.resolve('backend.aot'),
    );
    expect(
      installation.frontend!.artifactUri,
      directory.uri.resolve('frontend.evc'),
    );
    expect(
      installation.frontend!.presentations.single,
      isA<PreparedModelNativeActivityPresentation>(),
    );
  });

  for (final component in PreparedPluginComponent.values) {
    final invalidComponents = <String, Object?>{
      'null': null,
      'array': [],
      'string': 'invalid',
      'missing artifact': component == PreparedPluginComponent.backend
          ? <String, Object?>{}
          : {'presentations': <Object?>[]},
      'missing artifact file': component == PreparedPluginComponent.backend
          ? {'artifact': 'missing.aot'}
          : _frontend(artifact: 'missing.evc'),
      'unknown key': component == PreparedPluginComponent.backend
          ? {'artifact': 'backend.aot', 'entrypoint': 'bin/main.dart'}
          : {..._frontend(), 'source': 'lib/frontend.dart'},
      if (component == PreparedPluginComponent.frontend) ...{
        'missing presentations': {'artifact': 'frontend.evc'},
        for (final value in <Object?>[null, 1, false, 'invalid', {}])
          'non-array presentations $value': _frontend(presentations: value),
      },
    };
    for (final entry in invalidComponents.entries) {
      test('${component.name} ${entry.key} retains healthy sibling', () async {
        final directory = await install(
          'plugin',
          _manifest(
            components: {
              'backend': {'artifact': 'backend.aot'},
              'frontend': _frontend(presentations: [_session]),
              component.name: entry.value,
            },
          ),
        );
        final catalog = await PreparedPluginCatalog.discover(root.path);
        final installation = catalog.installations.single;
        final issue = catalog.issues.single;
        expect(issue.component, component);
        expect(issue.pluginId, installation.metadata.id);
        expect(issue.installationDirectory.uri, directory.uri);
        expect(issue.message, isNotEmpty);
        if (component == PreparedPluginComponent.backend) {
          expect(installation.backendArtifactUri, isNull);
          expect(
            installation.frontend!.artifactUri,
            directory.uri.resolve('frontend.evc'),
          );
          expect(
            installation.frontend!.presentations.single,
            isA<PreparedSessionPresentation>(),
          );
        } else {
          expect(installation.frontend, isNull);
          expect(
            installation.backendArtifactUri,
            directory.uri.resolve('backend.aot'),
          );
        }
      });
    }
  }

  test(
    'both invalid components retain identity with deterministic issues',
    () async {
      await install(
        'plugin',
        _manifest(components: {'frontend': null, 'backend': null}),
      );
      final first = await PreparedPluginCatalog.discover(root.path);
      final second = await PreparedPluginCatalog.discover(root.path);
      expect(
        first.installations.single.metadata.id,
        PluginId('org.example.plugin'),
      );
      expect(first.installations.single.backendArtifactUri, isNull);
      expect(first.installations.single.frontend, isNull);
      expect(first.issues.map((issue) => issue.component), [
        PreparedPluginComponent.backend,
        PreparedPluginComponent.frontend,
      ]);
      expect(
        second.issues.map((issue) => (issue.component, issue.message)),
        first.issues.map((issue) => (issue.component, issue.message)),
      );
    },
  );

  for (final descriptor in [_session, _toolActivity, _modelNativeActivity]) {
    for (final field in descriptor.keys) {
      test('${descriptor['role']} requires nonblank string $field', () async {
        final invalidValues = <Object?>[null, 1, false, [], {}, '', '  '];
        for (var index = 0; index <= invalidValues.length; index++) {
          final invalid = <String, Object?>{...descriptor};
          if (index == invalidValues.length) {
            invalid.remove(field);
          } else {
            invalid[field] = invalidValues[index];
          }
          await install(
            'case-$index',
            _manifest(
              id: 'org.example.case-$index',
              components: {
                'backend': {'artifact': 'backend.aot'},
                'frontend': _frontend(
                  presentations: [_session, invalid, _toolActivity],
                ),
              },
            ),
          );
        }
        final catalog = await PreparedPluginCatalog.discover(root.path);
        expect(catalog.installations, hasLength(invalidValues.length + 1));
        expect(
          catalog.installations.map((item) => item.frontend),
          everyElement(isNull),
        );
        expect(
          catalog.installations.map((item) => item.backendArtifactUri),
          everyElement(isNotNull),
        );
        expect(catalog.issues, hasLength(invalidValues.length + 1));
        expect(
          catalog.issues.map((issue) => issue.component),
          everyElement(PreparedPluginComponent.frontend),
        );
        expect(
          catalog.issues.map((issue) => issue.message),
          everyElement(contains('frontend.presentations[1].$field')),
        );
      });
    }
  }

  final invalidDescriptors = <String, Object?>{
    'null descriptor': null,
    'array descriptor': [],
    'string descriptor': 'session',
    'unknown role': {..._session, 'role': 'future'},
    'case-sensitive role': {..._session, 'role': 'Session'},
    'foreign session field': {..._session, 'toolId': 'org.example.tool'},
    'foreign tool field': {..._toolActivity, 'presentationKind': 'kind'},
    'foreign native field': {..._modelNativeActivity, 'hostAdapter': 'adapter'},
    for (final descriptor in [_session, _toolActivity, _modelNativeActivity])
      '${descriptor['role']} unknown key': {...descriptor, 'unknown': true},
    for (final descriptor in [_session, _toolActivity, _modelNativeActivity])
      for (final field in descriptor.keys.where(
        (key) => key.endsWith('ExtensionId') || key == 'extensionId',
      ))
        '${descriptor['role']} invalid $field': {
          ...descriptor,
          field: 'not namespaced',
        },
  };
  for (final entry in invalidDescriptors.entries) {
    test('${entry.key} invalidates entire frontend only', () async {
      await install(
        'plugin',
        _manifest(
          components: {
            'backend': {'artifact': 'backend.aot'},
            'frontend': _frontend(
              presentations: [_session, entry.value, _toolActivity],
            ),
          },
        ),
      );
      final catalog = await PreparedPluginCatalog.discover(root.path);
      expect(catalog.installations.single.backendArtifactUri, isNotNull);
      expect(catalog.installations.single.frontend, isNull);
      expect(catalog.issues.single.component, PreparedPluginComponent.frontend);
    });
  }

  test(
    'missing and malformed manifests are isolated and deterministic',
    () async {
      await Directory.fromUri(root.uri.resolve('a-missing/')).create();
      final broken = await install('b-invalid-json', _manifest());
      await File.fromUri(
        broken.uri.resolve('adele_plugin.installation.json'),
      ).writeAsString('{');
      await install('c-valid', _manifest());
      final catalog = await PreparedPluginCatalog.discover(root.path);
      expect(catalog.installations, hasLength(1));
      expect(catalog.issues.map((issue) => issue.installationDirectory.uri), [
        root.uri.resolve('a-missing/'),
        root.uri.resolve('b-invalid-json/'),
      ]);
      expect(
        catalog.issues.map((issue) => issue.message),
        everyElement(isNotEmpty),
      );
    },
  );

  final invalidDocuments = <String, Object?>{
    'null document': null,
    'array document': [],
    'missing version': {..._manifest()}..remove('manifestVersion'),
    'unknown version': {..._manifest(), 'manifestVersion': 2},
    'double version': {..._manifest(), 'manifestVersion': 1.0},
    'string version': {..._manifest(), 'manifestVersion': '1'},
    'boolean version': {..._manifest(), 'manifestVersion': true},
    'missing metadata': {..._manifest()}..remove('metadata'),
    'array metadata': {..._manifest(), 'metadata': <Object?>[]},
    'missing components': {..._manifest()}..remove('components'),
    'null components': {..._manifest(), 'components': null},
    'array components': {..._manifest(), 'components': <Object?>[]},
    'unknown component': {
      ..._manifest(),
      'components': {
        'backend': {'artifact': 'backend.aot'},
        'frontend': _frontend(),
        'unknown': <String, Object?>{},
      },
    },
    for (final field in [
      'exposures',
      'configuration',
      'state',
      'source',
      'backend',
    ])
      'unsupported $field': {..._manifest(), field: <String, Object?>{}},
  };
  for (final entry in invalidDocuments.entries) {
    test('rejects ${entry.key}', () async {
      await install('bad', entry.value);
      await install('good', _manifest(id: 'org.example.unrelated'));
      final catalog = await PreparedPluginCatalog.discover(root.path);
      expect(
        catalog.installations.single.metadata.id.value,
        'org.example.unrelated',
      );
      expect(catalog.issues, hasLength(1));
      expect(catalog.issues.single.component, isNull);
    });
  }

  for (final field in ['id', 'version', 'displayName', 'description']) {
    for (final value in <Object?>[null, 1, false, [], {}]) {
      test('rejects non-string metadata $field: $value', () async {
        final manifest = _manifest(
          components: {
            'backend': {'artifact': 'backend.aot'},
            'frontend': _frontend(),
          },
        );
        (manifest['metadata']! as Map<String, Object?>)[field] = value;
        await install('bad', manifest);
        final catalog = await PreparedPluginCatalog.discover(root.path);
        expect(catalog.installations, isEmpty);
        expect(catalog.issues, hasLength(1));
        expect(catalog.issues.single.component, isNull);
      });
    }
    if (field == 'description') continue;
    for (final value in ['', '  ', null]) {
      test('rejects missing or blank metadata $field: $value', () async {
        final manifest = _manifest();
        final metadata = manifest['metadata']! as Map<String, Object?>;
        if (value == null) {
          metadata.remove(field);
        } else {
          metadata[field] = value;
        }
        await install('bad', manifest);
        final catalog = await PreparedPluginCatalog.discover(root.path);
        expect(catalog.installations, isEmpty);
        expect(catalog.issues, hasLength(1));
      });
    }
  }

  test('rejects invalid PluginId and unknown metadata fields', () async {
    await install('invalid-id', _manifest(id: 'not namespaced'));
    final manifest = _manifest();
    (manifest['metadata']! as Map<String, Object?>)['source'] = 'plugin.dart';
    await install('unknown-field', manifest);
    final catalog = await PreparedPluginCatalog.discover(root.path);
    expect(catalog.installations, isEmpty);
    expect(catalog.issues, hasLength(2));
  });

  for (final artifact in <Object?>[
    null,
    1,
    false,
    [],
    {},
    '',
    ' ',
    '/',
    '/tmp/backend.aot',
    '../backend.aot',
    'lib/../../backend.aot',
    'lib/../backend.aot',
    './backend.aot',
    'lib/./backend.aot',
    'lib//backend.aot',
    'lib/',
    r'C:\backend.aot',
    'C:/backend.aot',
    r'lib\backend.aot',
    r'\\server\backend.aot',
    '//server/backend.aot',
    'file:backend.aot',
    'file:///tmp/backend.aot',
    'https://example.com/aot',
    'backend.aot?query',
    'backend.aot#fragment',
    'bad|name.aot',
    'bad*.aot',
    'bad<name.aot',
    'bad>name.aot',
    'bad"name.aot',
    '%2e%2e/backend.aot',
    'backend.aot\u0000',
  ]) {
    test('rejects invalid artifact path: ${jsonEncode(artifact)}', () async {
      final directory = await install(
        'bad',
        _manifest(
          components: {
            'backend': {'artifact': artifact},
            'frontend': _frontend(artifact: artifact),
          },
        ),
      );
      final catalog = await PreparedPluginCatalog.discover(root.path);
      final installation = catalog.installations.single;
      expect(installation.installationDirectory.uri, directory.uri);
      expect(installation.backendArtifactUri, isNull);
      expect(installation.frontend, isNull);
      expect(catalog.issues.map((issue) => issue.component), [
        PreparedPluginComponent.backend,
        PreparedPluginComponent.frontend,
      ]);
    });
  }

  test(
    'requires existing regular artifacts but allows nested relative files',
    () async {
      await install(
        'missing',
        _manifest(id: 'org.example.missing', artifact: 'absent.aot'),
      );
      final folder = await install(
        'directory',
        _manifest(id: 'org.example.directory'),
      );
      await File.fromUri(folder.uri.resolve('backend.aot')).delete();
      await Directory.fromUri(folder.uri.resolve('backend.aot/')).create();
      final nested = await install(
        'nested',
        _manifest(artifact: 'lib/backend file.aot'),
      );
      await Directory.fromUri(nested.uri.resolve('lib/')).create();
      await File.fromUri(
        nested.uri.resolve('lib/backend%20file.aot'),
      ).writeAsString('aot');
      final catalog = await PreparedPluginCatalog.discover(root.path);
      expect(
        catalog.installations.last.backendArtifactUri,
        nested.uri.resolve('lib/backend%20file.aot'),
      );
      expect(catalog.installations, hasLength(3));
      expect(
        catalog.installations.take(2).map((item) => item.backendArtifactUri),
        everyElement(isNull),
      );
      expect(catalog.issues, hasLength(2));
      expect(
        catalog.issues.map((issue) => issue.component),
        everyElement(PreparedPluginComponent.backend),
      );
    },
  );

  test(
    'frontend requires regular files and allows nested relative paths',
    () async {
      final folder = await install(
        'directory',
        _manifest(
          id: 'org.example.directory',
          components: {
            'backend': {'artifact': 'backend.aot'},
            'frontend': _frontend(),
          },
        ),
      );
      await File.fromUri(folder.uri.resolve('frontend.evc')).delete();
      await Directory.fromUri(folder.uri.resolve('frontend.evc/')).create();
      final nested = await install(
        'nested',
        _manifest(
          components: {
            'frontend': _frontend(artifact: 'lib/frontend file.evc'),
          },
        ),
      );
      await Directory.fromUri(nested.uri.resolve('lib/')).create();
      await File.fromUri(
        nested.uri.resolve('lib/frontend%20file.evc'),
      ).writeAsBytes([]);
      final catalog = await PreparedPluginCatalog.discover(root.path);
      expect(catalog.installations, hasLength(2));
      expect(catalog.installations.first.frontend, isNull);
      expect(
        catalog.installations.first.backendArtifactUri,
        folder.uri.resolve('backend.aot'),
      );
      expect(catalog.issues.single.component, PreparedPluginComponent.frontend);
      expect(catalog.issues.single.message, contains('regular file'));
      expect(
        catalog.installations.last.frontend!.artifactUri,
        nested.uri.resolve('lib/frontend%20file.evc'),
      );
    },
  );

  test(
    'rejects non-regular artifacts without trying to read them',
    () async {
      final directory = await install(
        'pipe',
        _manifest(
          components: {
            'backend': {'artifact': 'pipe'},
            'frontend': _frontend(artifact: 'pipe'),
          },
        ),
      );
      final result = await Process.run('mkfifo', ['${directory.path}/pipe']);
      expect(result.exitCode, 0);
      final catalog = await PreparedPluginCatalog.discover(root.path);
      expect(catalog.installations.single.backendArtifactUri, isNull);
      expect(catalog.installations.single.frontend, isNull);
      expect(catalog.issues.map((issue) => issue.component), [
        PreparedPluginComponent.backend,
        PreparedPluginComponent.frontend,
      ]);
      expect(
        catalog.issues.map((issue) => issue.message),
        everyElement(contains('regular file')),
      );
    },
    skip: !Platform.isLinux,
  );

  for (final malformedFirst in [false, true]) {
    test(
      'all duplicate identities excluded, malformed first=$malformedFirst',
      () async {
        await install(
          malformedFirst ? 'a' : 'c',
          _manifest(artifact: 'absent.aot'),
        );
        await install('b', _manifest());
        await install(malformedFirst ? 'c' : 'a', {
          ..._manifest(),
          'components': <String, Object?>{},
        });
        await install('unrelated', _manifest(id: 'org.example.unrelated'));
        final catalog = await PreparedPluginCatalog.discover(root.path);
        expect(
          catalog.installations.single.metadata.id.value,
          'org.example.unrelated',
        );
        final conflicts = catalog.issues.where(
          (issue) => issue.message.contains('Duplicate PluginId'),
        );
        expect(conflicts, hasLength(3));
        expect(
          conflicts.map((issue) => issue.pluginId),
          everyElement(PluginId('org.example.plugin')),
        );
        expect(conflicts.map((issue) => issue.component), everyElement(isNull));
        expect(catalog.issues, hasLength(4));
      },
    );
  }

  test(
    'valid identity in otherwise invalid metadata still conflicts',
    () async {
      final invalid = _manifest();
      (invalid['metadata']! as Map<String, Object?>).remove('version');
      await install('invalid', invalid);
      await install('valid', _manifest());
      final catalog = await PreparedPluginCatalog.discover(root.path);
      expect(catalog.installations, isEmpty);
      expect(
        catalog.issues.where(
          (issue) => issue.message.contains('Duplicate PluginId'),
        ),
        hasLength(2),
      );
    },
  );

  for (final malformedFirst in [false, true]) {
    for (final entry in <String, Map<String, Object?>>{
      'version': {..._manifest(), 'manifestVersion': 2},
      'envelope': {..._manifest(), 'unknown': true},
      'components': _manifest(components: {'unknown': true}),
      'frontend': _manifest(
        components: {
          'frontend': _frontend(
            presentations: [
              {'role': 'unknown'},
            ],
          ),
        },
      ),
    }.entries) {
      test(
        'readable identity conflicts with invalid ${entry.key}, first=$malformedFirst',
        () async {
          await install(malformedFirst ? 'a' : 'z', entry.value);
          await install(
            malformedFirst ? 'z' : 'a',
            _manifest(
              components: {
                'frontend': _frontend(presentations: [_session]),
              },
            ),
          );
          final catalog = await PreparedPluginCatalog.discover(root.path);
          expect(catalog.installations, isEmpty);
          expect(catalog.issues, hasLength(3));
          expect(
            catalog.issues.first.component,
            entry.key == 'frontend' ? PreparedPluginComponent.frontend : isNull,
          );
          final conflicts = catalog.issues.skip(1);
          expect(
            conflicts.map((issue) => issue.component),
            everyElement(isNull),
          );
          expect(
            conflicts.map((issue) => issue.message),
            everyElement(contains('Duplicate PluginId')),
          );
          expect(conflicts.map((issue) => issue.installationDirectory.uri), [
            root.uri.resolve('a/'),
            root.uri.resolve('z/'),
          ]);
        },
      );
    }
  }

  group(
    'symlink confinement',
    () {
      test(
        'rejects artifact and ancestor escapes, even to prefix sibling',
        () async {
          final direct = await install(
            'direct',
            _manifest(
              id: 'org.example.direct',
              components: {
                'backend': {'artifact': 'backend.aot'},
                'frontend': _frontend(artifact: 'backend.aot'),
              },
            ),
          );
          final sibling = await Directory.fromUri(
            root.uri.resolve('direct-outside/'),
          ).create();
          final outside = await File.fromUri(
            sibling.uri.resolve('backend.aot'),
          ).writeAsString('outside');
          await File.fromUri(direct.uri.resolve('backend.aot')).delete();
          await Link.fromUri(
            direct.uri.resolve('backend.aot'),
          ).create(outside.path);
          final ancestor = await install(
            'ancestor',
            _manifest(
              id: 'org.example.ancestor',
              components: {
                'backend': {'artifact': 'linked/backend.aot'},
                'frontend': _frontend(artifact: 'linked/backend.aot'),
              },
            ),
          );
          await Link.fromUri(
            ancestor.uri.resolve('linked'),
          ).create(sibling.path);
          // The sibling is outside the installation, but deliberately shares its prefix.
          final catalog = await PreparedPluginCatalog.discover(root.path);
          expect(catalog.installations, hasLength(2));
          expect(
            catalog.installations.map((item) => item.backendArtifactUri),
            everyElement(isNull),
          );
          expect(
            catalog.installations.map((item) => item.frontend),
            everyElement(isNull),
          );
          expect(catalog.issues.take(4).map((issue) => issue.component), [
            PreparedPluginComponent.backend,
            PreparedPluginComponent.frontend,
            PreparedPluginComponent.backend,
            PreparedPluginComponent.frontend,
          ]);
          expect(
            catalog.issues.where(
              (issue) => issue.message.contains('outside the installation'),
            ),
            hasLength(4),
          );
        },
      );

      test('accepts an artifact link confined to its installation', () async {
        final directory = await install(
          'inside',
          _manifest(
            components: {
              'backend': {'artifact': 'linked.aot'},
              'frontend': _frontend(artifact: 'linked.aot'),
            },
          ),
        );
        await Link.fromUri(
          directory.uri.resolve('linked.aot'),
        ).create('backend.aot');
        final catalog = await PreparedPluginCatalog.discover(root.path);
        expect(catalog.issues, isEmpty);
        expect(
          catalog.installations.single.backendArtifactUri,
          directory.uri.resolve('backend.aot'),
        );
        expect(
          catalog.installations.single.frontend!.artifactUri,
          directory.uri.resolve('backend.aot'),
        );
      });

      test(
        'allows a symlinked root and resolves canonical artifact URIs',
        () async {
          final directory = await install(
            'plugin',
            _manifest(
              components: {
                'backend': {'artifact': 'backend.aot'},
                'frontend': _frontend(),
              },
            ),
          );
          final linkedRoot = await Link.fromUri(
            temporary.uri.resolve('root-link'),
          ).create(root.path);
          final catalog = await PreparedPluginCatalog.discover(linkedRoot.path);
          expect(catalog.issues, isEmpty);
          expect(
            catalog.installations.single.installationDirectory.uri,
            Directory('${linkedRoot.path}/plugin').uri,
          );
          expect(
            catalog.installations.single.backendArtifactUri,
            directory.uri.resolve('backend.aot'),
          );
          expect(
            catalog.installations.single.frontend!.artifactUri,
            directory.uri.resolve('frontend.evc'),
          );
        },
      );

      test('rejects manifest escape and symlinked installation', () async {
        final outside = await File.fromUri(
          temporary.uri.resolve('manifest.json'),
        ).writeAsString(jsonEncode(_manifest()));
        final directory = await install('manifest-link', _manifest());
        final manifestUri = directory.uri.resolve(
          'adele_plugin.installation.json',
        );
        await File.fromUri(manifestUri).delete();
        await Link.fromUri(manifestUri).create(outside.path);
        await Link.fromUri(
          root.uri.resolve('directory-link'),
        ).create(temporary.path);
        final catalog = await PreparedPluginCatalog.discover(root.path);
        expect(catalog.installations, isEmpty);
        expect(catalog.issues, hasLength(2));
      });

      test('rejects dangling artifact link', () async {
        final directory = await install(
          'dangling',
          _manifest(
            components: {
              'backend': {'artifact': 'linked.aot'},
              'frontend': _frontend(artifact: 'linked.aot'),
            },
          ),
        );
        await Link.fromUri(
          directory.uri.resolve('linked.aot'),
        ).create('missing.aot');
        final catalog = await PreparedPluginCatalog.discover(root.path);
        expect(catalog.installations.single.backendArtifactUri, isNull);
        expect(catalog.installations.single.frontend, isNull);
        expect(catalog.issues.map((issue) => issue.component), [
          PreparedPluginComponent.backend,
          PreparedPluginComponent.frontend,
        ]);
      });
    },
    skip: Platform.isWindows ? 'Symlink creation requires privileges.' : false,
  );
}

Map<String, Object?> _manifest({
  String id = 'org.example.plugin',
  Object? artifact = 'backend.aot',
  Map<String, Object?>? components,
}) => {
  'manifestVersion': 1,
  'metadata': <String, Object?>{
    'id': id,
    'version': '0.1.0',
    'displayName': 'Example',
  },
  'components':
      components ??
      {
        'backend': {'artifact': artifact},
      },
};

Map<String, Object?> _frontend({
  Object? artifact = 'frontend.evc',
  Object? presentations = const [],
}) => {'artifact': artifact, 'presentations': presentations};

const _session = {
  'role': 'session',
  'library': 'package:example_frontend/session.dart',
  'extensionId': 'org.example.session',
  'strategyId': 'org.example.strategy',
  'entrypoint': 'buildSession',
  'hostAdapter': 'example.session.v1',
};

const _toolActivity = {
  'role': 'toolActivity',
  'library': 'package:example_frontend/tool.dart',
  'toolId': 'org.example.tool',
  'inspectionExtensionId': 'org.example.tool.inspection',
  'compactExtensionId': 'org.example.tool.compact',
  'inspectionEntrypoint': 'buildToolInspection',
  'compactEntrypoint': 'buildToolCompact',
};

const _modelNativeActivity = {
  'role': 'modelNativeActivity',
  'library': 'package:openai_frontend/openai_frontend.dart',
  'presentationKind': 'openai.responses.reasoning-summary.v1',
  'inspectionExtensionId': 'dev.adele.openai.reasoning-summary.inspection',
  'compactExtensionId': 'dev.adele.openai.reasoning-summary.compact',
  'inspectionEntrypoint': 'buildOpenAiReasoningInspection',
  'compactEntrypoint': 'buildOpenAiReasoningCompact',
};
