import 'dart:convert';
import 'dart:io';

import 'package:adele_capabilities/adele_capabilities.dart';
import 'package:adele_core_extensions/commands.dart';
import 'package:adele_model_tool/adele_model_tool.dart';
import 'package:adele_plugin_api/adele_plugin_api.dart';
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
          expect(installation.frontend!.extensions, isEmpty);
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
      expect(frontend.extensions, isEmpty);
      expect(() => frontend.extensions.clear(), throwsUnsupportedError);
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
      expect(tool.backendServices, isEmpty);
      expect(tool.consoleExtensions, isEmpty);
      final session =
          frontend.presentations[1] as PreparedMainContentPresentation;
      expect(session.library, _session['library']);
      expect(
        session.extensionId,
        ExtensionId(_session['extensionId']! as String),
      );
      expect(session.entrypoint, _session['entrypoint']);
      expect(session.initialize, _session['initialize']);
      expect(session.sessionExecution, isFalse);
      expect(session.backendServices, isEmpty);
      expect(session.capabilities, isEmpty);
      expect(session.strategyAffinity, PreparedStrategyAffinity.independent);
      expect(() => session.backendServices.clear(), throwsUnsupportedError);
      expect(() => session.capabilities.clear(), throwsUnsupportedError);
      expect(session.actions, isEmpty);
      expect(session.operations, isEmpty);
      expect(session.closeOperation, isNull);
      expect(session.exitOperation, isNull);
      expect(session.displaySourceFileOperation, isNull);
      expect(session.retainedData, isFalse);
      expect(session.nativeCodeEditor, isFalse);
      expect(session.environmentTextFiles, isFalse);
      expect(() => session.actions.clear(), throwsUnsupportedError);
      expect(() => session.operations.clear(), throwsUnsupportedError);
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
      expect(copy.extensions, isEmpty);
      expect(() => copy.extensions.clear(), throwsUnsupportedError);
    },
  );

  test(
    'Tool Inspection allowlists are optional, explicit and immutable',
    () async {
      await install(
        'inspection',
        _manifest(
          components: {
            'frontend': _frontend(
              presentations: [
                {
                  ..._toolActivity,
                  'backendServices': ['example.read'],
                  'consoleExtensions': ['org.example.output'],
                },
              ],
            ),
          },
        ),
      );
      final catalog = await PreparedPluginCatalog.discover(root.path);
      expect(catalog.issues, isEmpty);
      final descriptor =
          catalog.installations.single.frontend!.presentations.single
              as PreparedToolActivityPresentation;
      expect(descriptor.backendServices, ['example.read']);
      expect(descriptor.consoleExtensions, [ExtensionId('org.example.output')]);
      expect(() => descriptor.backendServices.clear(), throwsUnsupportedError);
      expect(
        () => descriptor.consoleExtensions.clear(),
        throwsUnsupportedError,
      );
    },
  );

  for (final entry in <String, Object?>{
    'non-list services': 'example.read',
    'non-string service': [1],
    'blank service': [''],
    'duplicate services': ['example.read', 'example.read'],
  }.entries) {
    test('Tool Inspection rejects ${entry.key}', () async {
      await install(
        'inspection',
        _manifest(
          components: {
            'frontend': _frontend(
              presentations: [
                {..._toolActivity, 'backendServices': entry.value},
              ],
            ),
          },
        ),
      );
      final catalog = await PreparedPluginCatalog.discover(root.path);
      expect(catalog.installations.single.frontend, isNull);
      expect(catalog.issues.single.component, PreparedPluginComponent.frontend);
    });
  }

  for (final targets in <Object?>[
    'org.example.output',
    [1],
    ['not-an-extension-id'],
    ['org.example.output', 'org.example.output'],
  ]) {
    test('Tool Inspection rejects invalid console targets $targets', () async {
      await install(
        'inspection',
        _manifest(
          components: {
            'frontend': _frontend(
              presentations: [
                {..._toolActivity, 'consoleExtensions': targets},
              ],
            ),
          },
        ),
      );
      final catalog = await PreparedPluginCatalog.discover(root.path);
      expect(catalog.installations.single.frontend, isNull);
      expect(catalog.issues.single.component, PreparedPluginComponent.frontend);
    });
  }

  test('Main Content is data-only, ordered and frontend-only', () async {
    await install(
      'panes',
      _manifest(
        components: {
          'frontend': _frontend(presentations: [_mainContent]),
        },
      ),
    );
    final catalog = await PreparedPluginCatalog.discover(root.path);
    expect(catalog.issues, isEmpty);
    final installation = catalog.installations.single;
    expect(installation.backendArtifactUri, isNull);
    final descriptor =
        installation.frontend!.presentations.single
            as PreparedMainContentPresentation;
    expect(descriptor.extensionId, ExtensionId('org.example.main-content'));
    expect(descriptor.order, 200);
    expect(descriptor.library, 'package:example_frontend/main_content.dart');
    expect(descriptor.initialize, 'initializePanes');
    expect(descriptor.entrypoint, 'buildPane');
    for (final order in [-200, 0, 100, 200]) {
      expect(
        PreparedMainContentPresentation(
          extensionId: descriptor.extensionId,
          order: order,
          library: descriptor.library,
          initialize: descriptor.initialize,
          entrypoint: descriptor.entrypoint,
        ).order,
        order,
      );
    }
  });

  test(
    'Main Content constructor validates both callable names and library',
    () {
      for (final (library, initialize, entrypoint) in [
        ('pane.dart', 'initializePanes', 'buildPane'),
        ('package:example/../pane.dart', 'initializePanes', 'buildPane'),
        ('package:example/pane.dart', 'Pane.initialize', 'buildPane'),
        ('package:example/pane.dart', 'initializePanes', 'buildPane()'),
      ]) {
        expect(
          () => PreparedMainContentPresentation(
            extensionId: ExtensionId('org.example.main-content'),
            order: 200,
            library: library,
            initialize: initialize,
            entrypoint: entrypoint,
          ),
          throwsFormatException,
        );
      }
    },
  );

  const mainContentAction = {
    'id': 'open',
    'label': 'Open Source...',
    'entrypoint': 'openSourceInput',
  };
  const mainContentOperations = {
    'display': 'displaySource',
    'save': 'saveSource',
    'close': 'closeSource',
    'exit': 'closeSources',
  };
  const mainContentCapability = {'id': 'org.example.read', 'majorVersion': 1};

  for (final capabilities in [
    <Map<String, Object?>>[],
    [
      mainContentCapability,
      {'id': 'org.example.read', 'majorVersion': 2},
      {'id': 'org.example.write', 'majorVersion': 1},
    ],
  ]) {
    test(
      'Main Content accepts ${capabilities.length} Capability keys without backend or providers',
      () async {
        await install(
          'capability-consumer',
          _manifest(
            components: {
              'frontend': _frontend(
                presentations: [
                  {..._mainContent, 'capabilities': capabilities},
                ],
              ),
            },
          ),
        );
        final catalog = await PreparedPluginCatalog.discover(root.path);
        expect(catalog.issues, isEmpty);
        final installation = catalog.installations.single;
        expect(installation.backendArtifactUri, isNull);
        final descriptor =
            installation.frontend!.presentations.single
                as PreparedMainContentPresentation;
        expect(descriptor.capabilities, [
          for (final capability in capabilities)
            CapabilityKey(
              id: CapabilityId(capability['id']! as String),
              majorVersion: capability['majorVersion']! as int,
            ),
        ]);
        expect(() => descriptor.capabilities.clear(), throwsUnsupportedError);
        expect(descriptor.sessionExecution, isFalse);
        expect(descriptor.backendServices, isEmpty);
        expect(
          descriptor.strategyAffinity,
          PreparedStrategyAffinity.independent,
        );
      },
    );
  }

  test(
    'Main Content decodes explicit actions, operations and permissions',
    () async {
      await install(
        'source',
        _manifest(
          components: {
            'frontend': _frontend(
              presentations: [
                {
                  ..._mainContent,
                  'actions': [mainContentAction],
                  'operations': mainContentOperations,
                  'closeOperation': 'close',
                  'exitOperation': 'exit',
                  'displaySourceFileOperation': 'display',
                  'retainedData': true,
                  'nativeCodeEditor': true,
                  'environmentTextFiles': true,
                },
              ],
            ),
          },
        ),
      );
      final catalog = await PreparedPluginCatalog.discover(root.path);
      expect(catalog.issues, isEmpty);
      final installation = catalog.installations.single;
      expect(installation.backendArtifactUri, isNull);
      final descriptor =
          installation.frontend!.presentations.single
              as PreparedMainContentPresentation;
      expect(descriptor.actions.single.id, 'open');
      expect(descriptor.actions.single.label, 'Open Source...');
      expect(descriptor.actions.single.entrypoint, 'openSourceInput');
      expect(descriptor.operations, mainContentOperations);
      expect(descriptor.closeOperation, 'close');
      expect(descriptor.exitOperation, 'exit');
      expect(descriptor.displaySourceFileOperation, 'display');
      expect(descriptor.retainedData, isTrue);
      expect(descriptor.nativeCodeEditor, isTrue);
      expect(descriptor.environmentTextFiles, isTrue);
      expect(descriptor.sessionExecution, isFalse);
      expect(descriptor.backendServices, isEmpty);
      expect(descriptor.strategyAffinity, PreparedStrategyAffinity.independent);
      expect(() => descriptor.actions.clear(), throwsUnsupportedError);
      expect(() => descriptor.operations.clear(), throwsUnsupportedError);
    },
  );

  PreparedMainContentPresentation mainContent({
    Iterable<CapabilityKey> capabilities = const [],
    List<PreparedMainContentAction> actions = const [],
    Map<String, String> operations = const {},
    String? closeOperation,
    String? exitOperation,
    String? displaySourceFileOperation,
    bool retainedData = false,
    bool nativeCodeEditor = false,
    bool environmentTextFiles = false,
  }) => PreparedMainContentPresentation(
    extensionId: ExtensionId('org.example.main-content'),
    order: 200,
    library: 'package:example_frontend/main_content.dart',
    initialize: 'initializePanes',
    entrypoint: 'buildPane',
    capabilities: capabilities,
    actions: actions,
    operations: operations,
    closeOperation: closeOperation,
    exitOperation: exitOperation,
    displaySourceFileOperation: displaySourceFileOperation,
    retainedData: retainedData,
    nativeCodeEditor: nativeCodeEditor,
    environmentTextFiles: environmentTextFiles,
  );

  test('Main Content constructor snapshots distinct Capability keys', () {
    final empty = mainContent();
    expect(empty.capabilities, isEmpty);
    expect(() => empty.capabilities.clear(), throwsUnsupportedError);
    final keys = [
      CapabilityKey(id: CapabilityId('org.example.read'), majorVersion: 1),
      CapabilityKey(id: CapabilityId('org.example.read'), majorVersion: 2),
      CapabilityKey(id: CapabilityId('org.example.write'), majorVersion: 1),
    ];
    final descriptor = mainContent(capabilities: keys);
    expect(descriptor.capabilities, keys);
    keys.clear();
    expect(descriptor.capabilities, hasLength(3));
    expect(() => descriptor.capabilities.clear(), throwsUnsupportedError);
    expect(
      () => descriptor.capabilities[0] = descriptor.capabilities[1],
      throwsUnsupportedError,
    );
    expect(descriptor.sessionExecution, isFalse);
    expect(descriptor.backendServices, isEmpty);
    expect(descriptor.strategyAffinity, PreparedStrategyAffinity.independent);
    expect(
      () => mainContent(
        capabilities: [
          CapabilityKey(id: CapabilityId('org.example.read'), majorVersion: 1),
          CapabilityKey(id: CapabilityId('org.example.read'), majorVersion: 1),
        ],
      ),
      throwsFormatException,
    );
  });

  test(
    'Main Content snapshots actions and operations without implicit grants',
    () {
      final actions = [
        PreparedMainContentAction(
          id: 'open',
          label: 'L' * 128,
          entrypoint: 'openInput',
        ),
        PreparedMainContentAction(
          id: 'another',
          label: 'Another',
          entrypoint: r'_input$2',
        ),
      ];
      final operations = {'open': 'openSource'};
      final descriptor = mainContent(actions: actions, operations: operations);
      actions.clear();
      operations.clear();
      expect(descriptor.actions.map((action) => action.id), [
        'open',
        'another',
      ]);
      expect(descriptor.actions.last.entrypoint, r'_input$2');
      expect(descriptor.operations, {'open': 'openSource'});
      expect(descriptor.retainedData, isFalse);
      expect(descriptor.nativeCodeEditor, isFalse);
      expect(descriptor.environmentTextFiles, isFalse);
      expect(mainContent(retainedData: true).operations, isEmpty);
      expect(
        mainContent(
          operations: {'read': 'readSource'},
          environmentTextFiles: true,
        ).retainedData,
        isFalse,
      );
    },
  );

  test('Main Content constructors enforce action and operation invariants', () {
    for (final create in <Object Function()>[
      () =>
          PreparedMainContentAction(id: ' ', label: 'Open', entrypoint: 'open'),
      () =>
          PreparedMainContentAction(id: 'open', label: ' ', entrypoint: 'open'),
      () => PreparedMainContentAction(
        id: 'open',
        label: 'L' * 129,
        entrypoint: 'open',
      ),
      () => PreparedMainContentAction(
        id: 'open',
        label: 'Open',
        entrypoint: 'open()',
      ),
      () => mainContent(
        actions: [
          PreparedMainContentAction(
            id: 'open',
            label: 'Open',
            entrypoint: 'open',
          ),
          PreparedMainContentAction(
            id: 'open',
            label: 'Other',
            entrypoint: 'other',
          ),
        ],
      ),
      () => mainContent(operations: {' ': 'openSource'}),
      () => mainContent(operations: {'open': 'Source.open'}),
      () => mainContent(closeOperation: 'close'),
      () => mainContent(exitOperation: 'exit'),
      () => mainContent(displaySourceFileOperation: 'display'),
      () => mainContent(
        operations: {'close': 'closeSource'},
        closeOperation: 'closeSource',
      ),
      () => mainContent(nativeCodeEditor: true),
      () => mainContent(environmentTextFiles: true),
    ]) {
      expect(create, throwsFormatException);
    }
  });

  final invalidMainContent = <String, Object?>{
    for (final field in _mainContent.keys)
      'missing $field': {..._mainContent}..remove(field),
    for (final field in ['extensionId', 'library', 'initialize', 'entrypoint'])
      for (final value in <Object?>[null, 1, false, [], {}, '', '  '])
        'invalid $field ${jsonEncode(value)}': {..._mainContent, field: value},
    for (final value in <Object?>[null, false, '200', 200.0, [], {}])
      'invalid order ${jsonEncode(value)}': {..._mainContent, 'order': value},
    for (final field in [
      'hostAdapter',
      'strategyId',
      'panes',
      'displayName',
      'unknown',
    ])
      'unsupported $field': {..._mainContent, field: 'unsupported'},
    'invalid extension ID': {..._mainContent, 'extensionId': 'not namespaced'},
    for (final library in [
      'main_content.dart',
      'file:///pane.dart',
      'package:example/../pane.dart',
      'package:example//pane.dart',
      'package:example/pane.dart?query',
    ])
      'invalid library $library': {..._mainContent, 'library': library},
    for (final field in ['initialize', 'entrypoint'])
      for (final name in [
        'Pane.build',
        'build()',
        '1build',
        'build pane',
        'build\n',
      ])
        'invalid $field ${jsonEncode(name)}': {..._mainContent, field: name},
    for (final field in [
      'retainedData',
      'nativeCodeEditor',
      'environmentTextFiles',
    ])
      for (final value in <Object?>[null, 'true', 1, [], {}])
        'invalid $field ${jsonEncode(value)}': {..._mainContent, field: value},
    'native editor without retention': {
      ..._mainContent,
      'nativeCodeEditor': true,
    },
    'environment access without operations': {
      ..._mainContent,
      'environmentTextFiles': true,
    },
    for (final value in <Object?>[null, false, '', 1, {}])
      'invalid capabilities ${jsonEncode(value)}': {
        ..._mainContent,
        'capabilities': value,
      },
    for (final value in <Object?>[
      null,
      false,
      '',
      1,
      [],
      {},
      for (final field in mainContentCapability.keys)
        {...mainContentCapability}..remove(field),
      for (final id in <Object?>[
        null,
        1,
        false,
        [],
        {},
        '',
        '  ',
        'read',
        'Org.example.read',
        'org.example.read ',
        'org.example..read',
        'org.example.r\u00e9ad',
      ])
        {...mainContentCapability, 'id': id},
      for (final version in <Object?>[null, false, '1', 1.0, [], {}, 0, -1])
        {...mainContentCapability, 'majorVersion': version},
      for (final field in ['unknown', 'providerId', 'serviceId'])
        {...mainContentCapability, field: 'org.example.provider'},
    ])
      'invalid capability ${jsonEncode(value)}': {
        ..._mainContent,
        'capabilities': [value],
      },
    'duplicate Capability keys': {
      ..._mainContent,
      'capabilities': [
        mainContentCapability,
        {...mainContentCapability},
      ],
    },
    for (final value in <Object?>[null, false, '', 1, {}])
      'invalid actions ${jsonEncode(value)}': {
        ..._mainContent,
        'actions': value,
      },
    for (final value in <Object?>[
      null,
      false,
      '',
      1,
      [],
      {},
      for (final field in mainContentAction.keys)
        {...mainContentAction}..remove(field),
      for (final field in mainContentAction.keys)
        for (final value in <Object?>[null, 1, false, [], {}, '', '  '])
          {...mainContentAction, field: value},
      {...mainContentAction, 'label': 'L' * 129},
      {...mainContentAction, 'entrypoint': 'Source.open'},
      {...mainContentAction, 'unknown': true},
    ])
      'invalid action ${jsonEncode(value)}': {
        ..._mainContent,
        'actions': [value],
      },
    'duplicate action IDs': {
      ..._mainContent,
      'actions': [mainContentAction, mainContentAction],
    },
    for (final value in <Object?>[
      null,
      false,
      '',
      1,
      [],
      {'': 'displaySource'},
      {'  ': 'displaySource'},
      for (final entrypoint in <Object?>[
        null,
        1,
        false,
        [],
        {},
        '',
        '  ',
        'Source.display',
        'display()',
        '1display',
        'display\n',
      ])
        {'display': entrypoint},
    ])
      'invalid operations ${jsonEncode(value)}': {
        ..._mainContent,
        'operations': value,
      },
    for (final field in [
      'closeOperation',
      'exitOperation',
      'displaySourceFileOperation',
    ])
      for (final value in <Object?>[
        null,
        1,
        false,
        [],
        {},
        '',
        '  ',
        'unknown',
        'displaySource',
      ])
        'invalid $field ${jsonEncode(value)}': {
          ..._mainContent,
          'operations': mainContentOperations,
          field: value,
        },
  };
  for (final entry in invalidMainContent.entries) {
    test('Main Content ${entry.key} invalidates only frontend', () async {
      await install(
        'invalid-panes',
        _manifest(
          components: {
            'backend': {'artifact': 'backend.aot'},
            'frontend': _frontend(presentations: [_session, entry.value]),
          },
        ),
      );
      final catalog = await PreparedPluginCatalog.discover(root.path);
      expect(catalog.installations.single.frontend, isNull);
      expect(catalog.installations.single.backendArtifactUri, isNotNull);
      expect(catalog.issues.single.component, PreparedPluginComponent.frontend);
    });
  }

  final invalidConsoleActionIds = [
    '',
    '  ',
    'new console',
    ' new-console',
    'new-console ',
    'new-console\n',
    'new\u0000console',
    'n\u00e9w-console',
    '_new-console',
    '.new-console',
    '-new-console',
    'a' * 129,
  ];

  test('Console is frontend-only with ordered immutable actions', () async {
    await install(
      'console',
      _manifest(
        components: {
          'frontend': _frontend(
            presentations: [
              {
                ..._console,
                'actions': [
                  _consoleAction,
                  {
                    'id': 'another-action',
                    'label': 'L' * 128,
                    'entrypoint': r'_anotherAction$2',
                  },
                ],
              },
              {
                ..._console,
                'extensionId': 'org.example.another-console',
                'library': 'package:example_frontend/src/console.g.dart',
                'actions': <Object?>[],
              },
            ],
          ),
        },
      ),
    );
    final catalog = await PreparedPluginCatalog.discover(root.path);
    expect(catalog.issues, isEmpty);
    final installation = catalog.installations.single;
    expect(installation.backendArtifactUri, isNull);
    final descriptors = installation.frontend!.presentations
        .cast<PreparedConsolePresentation>();
    final console = descriptors.first;
    expect(console.extensionId, ExtensionId('org.example.console'));
    expect(console.library, 'package:example_frontend/console.dart');
    expect(console.entrypoint, 'buildConsole');
    expect(console.keepAlive, isFalse);
    expect(console.actions.map((action) => action.id), [
      'new-console',
      'another-action',
    ]);
    expect(console.actions.first.label, 'New Console');
    expect(console.actions.first.entrypoint, 'newConsole');
    expect(console.actions.last.label, 'L' * 128);
    expect(console.actions.last.entrypoint, r'_anotherAction$2');
    expect(() => console.actions.clear(), throwsUnsupportedError);
    expect(descriptors.last.actions, isEmpty);
    expect(() => descriptors.last.actions.clear(), throwsUnsupportedError);
  });

  test('Console constructors snapshot actions and validate their ABI', () {
    PreparedConsolePresentation descriptor({
      required List<PreparedConsoleAction> actions,
      String library = 'package:example/console.dart',
      String entrypoint = 'buildConsole',
      bool keepAlive = false,
      bool readOnly = false,
    }) => PreparedConsolePresentation(
      extensionId: ExtensionId('org.example.console'),
      library: library,
      entrypoint: entrypoint,
      actions: actions,
      keepAlive: keepAlive,
      readOnly: readOnly,
    );
    final action = PreparedConsoleAction(
      id: 'new-console',
      label: 'New Console',
      entrypoint: 'newConsole',
    );
    final actions = [action];
    final console = descriptor(actions: actions);
    expect(console.keepAlive, isFalse);
    expect(
      () => descriptor(actions: [], keepAlive: true),
      throwsFormatException,
    );
    expect(
      descriptor(actions: [], readOnly: true, keepAlive: true).keepAlive,
      isTrue,
    );
    actions.clear();
    expect(console.actions, [action]);
    expect(() => console.actions.add(action), throwsUnsupportedError);
    expect(() => descriptor(actions: [action, action]), throwsFormatException);
    expect(
      () => descriptor(actions: [], library: 'package:example/../console.dart'),
      throwsFormatException,
    );
    expect(
      () => descriptor(actions: [], entrypoint: 'Console.build'),
      throwsFormatException,
    );
    for (final (id, label, entrypoint) in [
      ('', 'New Console', 'newConsole'),
      ('  ', 'New Console', 'newConsole'),
      ('new', '', 'newConsole'),
      ('new', '  ', 'newConsole'),
      ('new', 'L' * 129, 'newConsole'),
      ('new', 'New Console', 'Console.new'),
    ]) {
      expect(
        () =>
            PreparedConsoleAction(id: id, label: label, entrypoint: entrypoint),
        throwsFormatException,
      );
    }
  });

  test(
    'read-only console descriptors declare immutable backend services',
    () async {
      await install(
        'read-only',
        _manifest(
          components: {
            'frontend': _frontend(
              presentations: [
                {
                  ..._console,
                  'readOnly': true,
                  'actions': <Object?>[],
                  'backendServices': ['example.read'],
                },
              ],
            ),
          },
        ),
      );
      final catalog = await PreparedPluginCatalog.discover(root.path);
      expect(catalog.issues, isEmpty);
      final descriptor =
          catalog.installations.single.frontend!.presentations.single
              as PreparedConsolePresentation;
      expect(descriptor.readOnly, isTrue);
      expect(descriptor.keepAlive, isFalse);
      expect(descriptor.actions, isEmpty);
      expect(descriptor.backendServices, ['example.read']);
      expect(() => descriptor.backendServices.clear(), throwsUnsupportedError);
    },
  );

  test('read-only console may opt into keepAlive explicitly', () async {
    await install(
      'resident-console',
      _manifest(
        components: {
          'frontend': _frontend(
            presentations: [
              {
                ..._console,
                'readOnly': true,
                'keepAlive': true,
                'actions': <Object?>[],
              },
            ],
          ),
        },
      ),
    );
    final catalog = await PreparedPluginCatalog.discover(root.path);
    expect(catalog.issues, isEmpty);
    final descriptor =
        catalog.installations.single.frontend!.presentations.single
            as PreparedConsolePresentation;
    expect(descriptor.keepAlive, isTrue);
    expect(descriptor.readOnly, isTrue);
    expect(descriptor.backendServices, isEmpty);
  });

  for (final fields in <Map<String, Object?>>[
    {'readOnly': true},
    {'readOnly': null},
    {'readOnly': 'true'},
    {'keepAlive': true},
    {'keepAlive': true, 'actions': []},
    for (final value in <Object?>[null, 1, 'true', [], {}])
      {'readOnly': true, 'actions': [], 'keepAlive': value},
    {
      'backendServices': ['example.read'],
    },
    {'readOnly': true, 'actions': [], 'backendServices': null},
    {
      'readOnly': true,
      'actions': [],
      'backendServices': [''],
    },
    {
      'readOnly': true,
      'actions': [],
      'backendServices': ['example.read', 'example.read'],
    },
  ]) {
    test('rejects incompatible read-only console metadata $fields', () async {
      await install(
        'invalid-read-only',
        _manifest(
          components: {
            'frontend': _frontend(
              presentations: [
                {..._console, ...fields},
              ],
            ),
          },
        ),
      );
      final catalog = await PreparedPluginCatalog.discover(root.path);
      expect(catalog.installations.single.frontend, isNull);
      expect(catalog.issues.single.component, PreparedPluginComponent.frontend);
    });
  }

  final invalidConsoles = <String, Object?>{
    for (final id in invalidConsoleActionIds)
      'invalid action ID ${jsonEncode(id)}': {
        ..._console,
        'actions': [
          {..._consoleAction, 'id': id},
        ],
      },
    for (final field in ['extensionId', 'library', 'entrypoint', 'actions'])
      'missing $field': {..._console}..remove(field),
    for (final field in ['extensionId', 'library', 'entrypoint', 'actions'])
      for (final value in <Object?>[null, 1, false, {}, '', '  '])
        'invalid $field ${jsonEncode(value)}': {..._console, field: value},
    'invalid extension ID': {..._console, 'extensionId': 'not namespaced'},
    for (final field in [
      'displayName',
      'strategyId',
      'strategyAffinity',
      'backendServices',
      'hostAdapter',
      'unknown',
    ])
      'unsupported $field': {..._console, field: 'unsupported'},
    for (final library in [
      'console.dart',
      'file:///console.dart',
      'package://example/console.dart',
      'package:BadPackage/console.dart',
      'package:bad-package/console.dart',
      'package:example/console',
      'package:example/console.txt',
      'package:example/./console.dart',
      'package:example/../console.dart',
      'package:example//console.dart',
      'package:example/%63onsole.dart',
      'package:example/console.dart?query',
      'package:example/console.dart#fragment',
      r'package:example/src\console.dart',
      'package:example/console.dart\n',
    ])
      'invalid library ${jsonEncode(library)}': {
        ..._console,
        'library': library,
      },
    for (final entrypoint in [
      'Console.build',
      'buildConsole()',
      'build-console',
      '1buildConsole',
      'build Console',
      ' buildConsole',
      'buildConsole\n',
    ]) ...{
      'invalid entrypoint ${jsonEncode(entrypoint)}': {
        ..._console,
        'entrypoint': entrypoint,
      },
      'invalid action entrypoint ${jsonEncode(entrypoint)}': {
        ..._console,
        'actions': [
          {..._consoleAction, 'entrypoint': entrypoint},
        ],
      },
    },
    'duplicate action IDs': {
      ..._console,
      'actions': [
        _consoleAction,
        {..._consoleAction, 'label': 'Other', 'entrypoint': 'other'},
      ],
    },
    for (final entry in <String, Object?>{
      for (final field in ['id', 'label', 'entrypoint'])
        'missing $field': {..._consoleAction}..remove(field),
      for (final field in ['id', 'label', 'entrypoint'])
        for (final value in <Object?>[null, 1, false, [], {}, '', ' \t\n'])
          'invalid $field ${jsonEncode(value)}': {
            ..._consoleAction,
            field: value,
          },
      'long label': {..._consoleAction, 'label': 'L' * 129},
      'own library': {
        ..._consoleAction,
        'library': 'package:other/action.dart',
      },
      'unknown field': {..._consoleAction, 'unknown': true},
      'null': null,
      'array': [],
      'string': 'newConsole',
    }.entries)
      'action ${entry.key}': {
        ..._console,
        'actions': [entry.value],
      },
  };
  for (final entry in invalidConsoles.entries) {
    test('Console ${entry.key} invalidates only the frontend', () async {
      await install(
        'console',
        _manifest(
          components: {
            'backend': {'artifact': 'backend.aot'},
            'frontend': _frontend(presentations: [_session, entry.value]),
          },
        ),
      );
      final catalog = await PreparedPluginCatalog.discover(root.path);
      expect(catalog.installations.single.frontend, isNull);
      expect(catalog.installations.single.backendArtifactUri, isNotNull);
      expect(catalog.issues.single.component, PreparedPluginComponent.frontend);
      expect(catalog.issues.single.message, isNotEmpty);
    });
  }

  for (final sameInstallation in [false, true]) {
    test(
      'Console duplicate registration is registry-owned, same installation=$sameInstallation',
      () async {
        await install(
          'first',
          _manifest(
            components: {
              'frontend': _frontend(
                presentations: [_console, if (sameInstallation) _console],
              ),
            },
          ),
        );
        if (!sameInstallation) {
          await install(
            'second',
            _manifest(
              id: 'org.example.second',
              components: {
                'frontend': _frontend(presentations: [_console]),
              },
            ),
          );
        }
        final catalog = await PreparedPluginCatalog.discover(root.path);
        expect(catalog.issues, isEmpty);
        final descriptors = catalog.installations
            .expand((installation) => installation.frontend!.presentations)
            .cast<PreparedConsolePresentation>()
            .toList();
        expect(descriptors, hasLength(2));
        final registry = ExtensionRegistry();
        final point = ExtensionPoint<PreparedConsolePresentation>(
          'org.example.console-presentations',
        );
        final registration = registry.register(
          point: point,
          id: descriptors.first.extensionId,
          value: descriptors.first,
        );
        addTearDown(registration.close);
        expect(
          () => registry.register(
            point: point,
            id: descriptors.last.extensionId,
            value: descriptors.last,
          ),
          throwsA(isA<ExtensionRegistrationException>()),
        );
        expect(registry.discover(point).single.value, same(descriptors.first));
      },
    );
  }

  const browser = <String, Object?>{
    'role': 'taskBrowser',
    'extensionId': 'test.task-browser',
    'displayName': 'Task Browser',
    'library': 'package:example/browser.dart',
    'entrypoint': 'createTaskBrowser',
  };

  for (final descriptor in [
    _console,
    browser,
    _toolActivity,
    _modelNativeActivity,
  ]) {
    test('${descriptor['role']} rejects Capability grants', () async {
      await install(
        'invalid-role-grant',
        _manifest(
          components: {
            'backend': {'artifact': 'backend.aot'},
            'frontend': _frontend(
              presentations: [
                {...descriptor, 'capabilities': <Object?>[]},
              ],
            ),
          },
        ),
      );
      final catalog = await PreparedPluginCatalog.discover(root.path);
      expect(catalog.installations.single.frontend, isNull);
      expect(catalog.installations.single.backendArtifactUri, isNotNull);
      expect(catalog.issues.single.component, PreparedPluginComponent.frontend);
    });
  }

  test('Task Browser is frontend-only and has no backend metadata', () async {
    await install(
      'browser',
      _manifest(
        components: {
          'frontend': _frontend(presentations: [browser]),
        },
      ),
    );
    final catalog = await PreparedPluginCatalog.discover(root.path);
    expect(catalog.issues, isEmpty);
    final installation = catalog.installations.single;
    expect(installation.backendArtifactUri, isNull);
    final descriptor =
        installation.frontend!.presentations.single
            as PreparedTaskBrowserPresentation;
    expect(descriptor.extensionId, ExtensionId('test.task-browser'));
    expect(descriptor.displayName, 'Task Browser');
    expect(descriptor.library, 'package:example/browser.dart');
    expect(descriptor.entrypoint, 'createTaskBrowser');
  });

  for (final field in [
    'backendServices',
    'strategyAffinity',
    'strategyId',
    'hostAdapter',
  ]) {
    test(
      'Task Browser rejects $field without retiring healthy backend',
      () async {
        await install(
          'browser',
          _manifest(
            components: {
              'backend': {'artifact': 'backend.aot'},
              'frontend': _frontend(
                presentations: [
                  {...browser, field: 'invalid'},
                ],
              ),
            },
          ),
        );
        final catalog = await PreparedPluginCatalog.discover(root.path);
        expect(
          catalog.issues.single.component,
          PreparedPluginComponent.frontend,
        );
        expect(catalog.installations.single.frontend, isNull);
        expect(catalog.installations.single.backendArtifactUri, isNotNull);
      },
    );
  }

  for (final field in ['extensionId', 'displayName', 'library', 'entrypoint']) {
    for (final invalid in [null, '', 7]) {
      test('Task Browser rejects $field=$invalid', () async {
        await install(
          'browser',
          _manifest(
            components: {
              'frontend': _frontend(
                presentations: [
                  {...browser, field: invalid},
                ],
              ),
            },
          ),
        );
        final catalog = await PreparedPluginCatalog.discover(root.path);
        expect(
          catalog.issues.single.component,
          PreparedPluginComponent.frontend,
        );
        expect(catalog.installations.single.frontend, isNull);
      });
    }
  }

  for (final presentations in [
    <Object?>[],
    [_toolActivity, _session, _modelNativeActivity],
  ]) {
    test(
      'round-trips frontend-only selectors with ${presentations.length} presentations',
      () async {
        final PreparedFrontendExtension selector =
            PreparedProjectSelectorExtension(
              extensionId: ExtensionId(_projectSelector['extensionId']!),
              projectProviderId: ProviderId(
                _projectSelector['projectProviderId']!,
              ),
              displayName: _projectSelector['displayName']!,
              library: _projectSelector['library']!,
              entrypoint: _projectSelector['entrypoint']!,
            );
        final secondSelector = PreparedProjectSelectorExtension(
          extensionId: ExtensionId('org.example.another-selector'),
          projectProviderId: ProviderId('org.example.another-provider'),
          displayName: ' Another Project... ',
          library: 'package:example_frontend/src/another_selector.g.dart',
          entrypoint: '_selectAnotherProject2',
        );
        expect(selector.toJson(), _projectSelector);
        final serialized = [selector.toJson(), secondSelector.toJson()];
        final directory = await install(
          'frontend',
          _manifest(
            components: {
              'frontend': {
                ..._frontend(presentations: presentations),
                'extensions': [selector, secondSelector],
              },
            },
          ),
        );
        final catalog = await PreparedPluginCatalog.discover(root.path);
        expect(catalog.issues, isEmpty);
        final installation = catalog.installations.single;
        expect(installation.backendArtifactUri, isNull);
        final frontend = installation.frontend!;
        expect(frontend.artifactUri, directory.uri.resolve('frontend.evc'));
        expect(frontend.presentations, hasLength(presentations.length));
        expect(frontend.extensions, hasLength(2));
        final decoded =
            frontend.extensions.first as PreparedProjectSelectorExtension;
        expect(
          decoded.extensionId,
          ExtensionId(_projectSelector['extensionId']!),
        );
        expect(decoded.displayName, _projectSelector['displayName']);
        expect(
          decoded.projectProviderId,
          ProviderId(_projectSelector['projectProviderId']!),
        );
        expect(decoded.library, _projectSelector['library']);
        expect(decoded.entrypoint, _projectSelector['entrypoint']);
        expect(
          frontend.extensions.map((extension) => extension.toJson()),
          serialized,
        );
        expect(() => frontend.extensions.clear(), throwsUnsupportedError);

        final extensions = frontend.extensions.toList();
        final copy = PreparedFrontendComponent(
          artifactUri: frontend.artifactUri,
          presentations: frontend.presentations,
          extensions: extensions,
        );
        extensions.clear();
        expect(copy.extensions, frontend.extensions);
        expect(() => copy.extensions.clear(), throwsUnsupportedError);
      },
    );
  }

  PreparedCommandExtension command({
    String label = 'Run Command',
    String library = 'package:example_frontend/command.dart',
    String entrypoint = 'runCommand',
  }) => PreparedCommandExtension(
    extensionId: ExtensionId(_command['extensionId']!),
    commandId: CommandId(_command['commandId']!),
    label: label,
    library: library,
    entrypoint: entrypoint,
  );

  test('round-trips frontend-only commands with zero presentations', () async {
    final PreparedFrontendExtension descriptor = command();
    expect(descriptor.toJson(), _command);
    final commands = [
      descriptor,
      for (final label in [
        '  Command with spaces  ',
        'Ouvrir le projet \u00e9tendu',
        'L' * 160,
        '\u{1f680}' * 80,
      ])
        command(
          label: label,
          library: 'package:example_frontend/src/another_command.g.dart',
          entrypoint: r'_runCommand$2',
        ),
    ];
    final directory = await install(
      'commands',
      _manifest(
        components: {
          'frontend': {..._frontend(), 'extensions': commands},
        },
      ),
    );
    final catalog = await PreparedPluginCatalog.discover(root.path);
    expect(catalog.issues, isEmpty);
    final installation = catalog.installations.single;
    expect(installation.backendArtifactUri, isNull);
    final frontend = installation.frontend!;
    expect(frontend.artifactUri, directory.uri.resolve('frontend.evc'));
    expect(frontend.presentations, isEmpty);
    expect(frontend.extensions, everyElement(isA<PreparedCommandExtension>()));
    final decoded = frontend.extensions.first as PreparedCommandExtension;
    expect(decoded.extensionId, ExtensionId(_command['extensionId']!));
    expect(decoded.commandId, CommandId(_command['commandId']!));
    expect(decoded.label, _command['label']);
    expect(decoded.library, _command['library']);
    expect(decoded.entrypoint, _command['entrypoint']);
    expect(
      frontend.extensions.map((extension) => extension.toJson()),
      commands.map((extension) => extension.toJson()),
    );
    expect(() => frontend.extensions.clear(), throwsUnsupportedError);
  });

  PreparedConsoleActionCommandExtension consoleActionCommand({
    String actionId = 'new-console',
  }) => PreparedConsoleActionCommandExtension(
    extensionId: ExtensionId(_consoleActionCommand['extensionId']!),
    commandId: CommandId(_consoleActionCommand['commandId']!),
    consoleExtensionId: ExtensionId(
      _consoleActionCommand['consoleExtensionId']!,
    ),
    actionId: actionId,
  );

  test(
    'round-trips Console action Commands without resolving targets',
    () async {
      final PreparedFrontendExtension descriptor = consoleActionCommand();
      expect(descriptor.toJson(), _consoleActionCommand);
      final directory = await install(
        'console-command',
        _manifest(
          components: {
            'frontend': {
              ..._frontend(),
              'extensions': [descriptor],
            },
          },
        ),
      );
      final catalog = await PreparedPluginCatalog.discover(root.path);
      expect(catalog.issues, isEmpty);
      final installation = catalog.installations.single;
      expect(installation.backendArtifactUri, isNull);
      final frontend = installation.frontend!;
      expect(frontend.artifactUri, directory.uri.resolve('frontend.evc'));
      expect(frontend.presentations, isEmpty);
      final decoded =
          frontend.extensions.single as PreparedConsoleActionCommandExtension;
      expect(
        decoded.extensionId,
        ExtensionId(_consoleActionCommand['extensionId']!),
      );
      expect(decoded.commandId, CommandId(_consoleActionCommand['commandId']!));
      expect(decoded.consoleExtensionId, ExtensionId('org.example.console'));
      expect(decoded.actionId, 'new-console');
      expect(decoded.toJson(), _consoleActionCommand);
      expect(() => frontend.extensions.clear(), throwsUnsupportedError);
    },
  );

  test('Console actions and Command references share bounded ASCII IDs', () {
    for (final id in ['a', '0', 'A0._-', 'a' * 128]) {
      expect(consoleActionCommand(actionId: id).actionId, id);
      expect(
        PreparedConsoleAction(
          id: id,
          label: 'New Console',
          entrypoint: 'newConsole',
        ).id,
        id,
      );
    }
    for (final id in invalidConsoleActionIds) {
      expect(() => consoleActionCommand(actionId: id), throwsFormatException);
      expect(
        () => PreparedConsoleAction(
          id: id,
          label: 'New Console',
          entrypoint: 'newConsole',
        ),
        throwsFormatException,
      );
    }
  });

  test('commands coexist with selectors and presentations in order', () async {
    await install(
      'mixed',
      _manifest(
        components: {
          'frontend': {
            ..._frontend(
              presentations: [
                _session,
                _console,
                {
                  ..._mainContent,
                  'actions': [_mainContentAction],
                },
              ],
            ),
            'extensions': [
              _command,
              _consoleActionCommand,
              _mainContentActionCommand,
              _projectSelector,
              _command,
            ],
          },
        },
      ),
    );
    final catalog = await PreparedPluginCatalog.discover(root.path);
    expect(catalog.issues, isEmpty);
    final frontend = catalog.installations.single.frontend!;
    expect(
      frontend.presentations.first,
      isA<PreparedMainContentPresentation>(),
    );
    expect(frontend.presentations[1], isA<PreparedConsolePresentation>());
    expect(
      (frontend.presentations.last as PreparedMainContentPresentation)
          .actions
          .single
          .id,
      _mainContentActionCommand['actionId'],
    );
    expect(frontend.extensions.map((extension) => extension.toJson()), [
      _command,
      _consoleActionCommand,
      _mainContentActionCommand,
      _projectSelector,
      _command,
    ]);
  });

  test(
    'Console action Command target semantics remain activation-owned',
    () async {
      for (final (index, console) in [
        {..._console, 'extensionId': 'org.example.other-console'},
        {..._console, 'actions': <Object?>[]},
        {..._console, 'actions': <Object?>[], 'readOnly': true},
      ].indexed) {
        await install(
          'unresolved-$index',
          _manifest(
            id: 'org.example.unresolved-$index',
            components: {
              'frontend': {
                ..._frontend(presentations: [console]),
                'extensions': [_consoleActionCommand],
              },
            },
          ),
        );
      }
      final catalog = await PreparedPluginCatalog.discover(root.path);
      expect(catalog.issues, isEmpty);
      expect(catalog.installations, hasLength(3));
      expect(
        catalog.installations.map((item) => item.frontend!.extensions.single),
        everyElement(isA<PreparedConsoleActionCommandExtension>()),
      );
    },
  );

  final invalidConsoleActionCommands = <String, Object?>{
    'case-sensitive kind': {
      ..._consoleActionCommand,
      'kind': 'ConsoleActionCommand',
    },
    for (final field in [
      'unknown',
      'role',
      'library',
      'entrypoint',
      'label',
      'displayName',
      'projectProviderId',
      'backendServices',
      'strategyAffinity',
      'sessionExecution',
      'hostAdapter',
      'configuration',
      'availability',
      'arguments',
      'sessionId',
      'environmentId',
      'authority',
    ])
      'unsupported $field': {..._consoleActionCommand, field: 'unsupported'},
    for (final field in ['extensionId', 'commandId', 'consoleExtensionId'])
      for (final id in [
        'console',
        'not namespaced',
        'org.Example.console',
        'org.example..console',
        'org.example.console-',
        'org.example.-console',
        'org.example_console',
        'org.ex\u00e4mple.console',
        ' org.example.console',
        'org.example.console ',
        'org.example.console\n',
      ])
        'invalid $field ${jsonEncode(id)}': {
          ..._consoleActionCommand,
          field: id,
        },
    for (final id in invalidConsoleActionIds)
      'invalid actionId ${jsonEncode(id)}': {
        ..._consoleActionCommand,
        'actionId': id,
      },
  };
  for (final entry in invalidConsoleActionCommands.entries) {
    test(
      'Console action Command ${entry.key} invalidates only frontend',
      () async {
        final directory = await install(
          'console-commands',
          _manifest(
            components: {
              'backend': {'artifact': 'backend.aot'},
              'frontend': {
                ..._frontend(presentations: [_console]),
                'extensions': [_command, entry.value, _projectSelector],
              },
            },
          ),
        );
        final catalog = await PreparedPluginCatalog.discover(root.path);
        final installation = catalog.installations.single;
        expect(installation.frontend, isNull);
        expect(
          installation.backendArtifactUri,
          directory.uri.resolve('backend.aot'),
        );
        final issue = catalog.issues.single;
        expect(issue.component, PreparedPluginComponent.frontend);
        expect(issue.pluginId, installation.metadata.id);
        expect(issue.installationDirectory.uri, directory.uri);
        expect(issue.message, isNotEmpty);
        if (entry.key.startsWith('invalid actionId')) {
          expect(issue.message, contains('frontend.extensions[1].actionId'));
        }
      },
    );
  }

  PreparedMainContentActionCommandExtension mainContentActionCommand({
    String actionId = 'open',
  }) => PreparedMainContentActionCommandExtension(
    extensionId: ExtensionId(_mainContentActionCommand['extensionId']!),
    commandId: CommandId(_mainContentActionCommand['commandId']!),
    mainContentExtensionId: ExtensionId(
      _mainContentActionCommand['mainContentExtensionId']!,
    ),
    actionId: actionId,
  );

  test(
    'round-trips Main Content action Commands without resolving targets',
    () async {
      final PreparedFrontendExtension descriptor = mainContentActionCommand();
      expect(descriptor.toJson(), _mainContentActionCommand);
      final directory = await install(
        'main-content-command',
        _manifest(
          components: {
            'frontend': {
              ..._frontend(),
              'extensions': [descriptor],
            },
          },
        ),
      );
      final catalog = await PreparedPluginCatalog.discover(root.path);
      expect(catalog.issues, isEmpty);
      final installation = catalog.installations.single;
      expect(installation.backendArtifactUri, isNull);
      final frontend = installation.frontend!;
      expect(frontend.artifactUri, directory.uri.resolve('frontend.evc'));
      expect(frontend.presentations, isEmpty);
      final decoded =
          frontend.extensions.single
              as PreparedMainContentActionCommandExtension;
      expect(
        decoded.extensionId,
        ExtensionId(_mainContentActionCommand['extensionId']!),
      );
      expect(
        decoded.commandId,
        CommandId(_mainContentActionCommand['commandId']!),
      );
      expect(
        decoded.mainContentExtensionId,
        ExtensionId('org.example.main-content'),
      );
      expect(decoded.actionId, 'open');
      expect(decoded.toJson(), _mainContentActionCommand);
      expect(() => frontend.extensions.clear(), throwsUnsupportedError);
    },
  );

  test(
    'Main Content action Command IDs retain owning action semantics',
    () async {
      final ids = [
        'open',
        ' open source ',
        '_open/source:1',
        'open\nsource',
        '\u00e9',
        '\u0000',
        'a' * 129,
      ];
      final descriptors = [
        for (final id in ids) mainContentActionCommand(actionId: id),
      ];
      for (final id in ids) {
        expect(
          PreparedMainContentAction(
            id: id,
            label: 'Open',
            entrypoint: 'openInput',
          ).id,
          id,
        );
      }
      for (final id in ['', ' ', '\t\n', '\u00a0']) {
        expect(
          () => mainContentActionCommand(actionId: id),
          throwsFormatException,
        );
        expect(
          () => PreparedMainContentAction(
            id: id,
            label: 'Open',
            entrypoint: 'openInput',
          ),
          throwsFormatException,
        );
      }
      await install(
        'main-content-action-ids',
        _manifest(
          components: {
            'frontend': {..._frontend(), 'extensions': descriptors},
          },
        ),
      );
      final catalog = await PreparedPluginCatalog.discover(root.path);
      expect(catalog.issues, isEmpty);
      expect(
        catalog.installations.single.frontend!.extensions
            .cast<PreparedMainContentActionCommandExtension>()
            .map((descriptor) => descriptor.actionId),
        ids,
      );
    },
  );

  test(
    'Main Content action Command target semantics remain activation-owned',
    () async {
      final target = {
        ..._mainContent,
        'actions': [_mainContentAction],
      };
      final cases = [
        [
          {...target, 'extensionId': 'org.example.other-main-content'},
        ],
        [_mainContent],
        [target, target],
        [
          {..._console, 'extensionId': _mainContent['extensionId']},
        ],
      ];
      for (final (index, presentations) in cases.indexed) {
        await install(
          'unresolved-$index',
          _manifest(
            id: 'org.example.unresolved-$index',
            components: {
              'frontend': {
                ..._frontend(presentations: presentations),
                'extensions': [_mainContentActionCommand],
              },
            },
          ),
        );
      }
      final catalog = await PreparedPluginCatalog.discover(root.path);
      expect(catalog.issues, isEmpty);
      expect(catalog.installations, hasLength(cases.length));
      expect(
        catalog.installations.map((item) => item.frontend!.extensions.single),
        everyElement(isA<PreparedMainContentActionCommandExtension>()),
      );
    },
  );

  final invalidMainContentActionCommands = <String, Object?>{
    'case-sensitive kind': {
      ..._mainContentActionCommand,
      'kind': 'MainContentActionCommand',
    },
    for (final field in [
      'unknown',
      'role',
      'library',
      'entrypoint',
      'initialize',
      'label',
      'displayName',
      'consoleExtensionId',
      'projectProviderId',
      'backendServices',
      'strategyAffinity',
      'sessionExecution',
      'retainedData',
      'nativeCodeEditor',
      'environmentTextFiles',
      'operations',
      'hostAdapter',
      'configuration',
      'availability',
      'arguments',
      'context',
      'projectId',
      'taskId',
      'sessionId',
      'environmentId',
      'environmentKey',
      'authority',
      'hostServices',
      'hostContext',
      'hostInvocationContext',
      'hostInfrastructureContext',
    ])
      'unsupported $field': {
        ..._mainContentActionCommand,
        field: 'unsupported',
      },
    for (final field in ['extensionId', 'commandId', 'mainContentExtensionId'])
      for (final id in [
        'main-content',
        'not namespaced',
        'org.Example.main-content',
        'org.example..main-content',
        'org.example.main-content-',
        'org.example.-main-content',
        'org.example_main-content',
        'org.ex\u00e4mple.main-content',
        ' org.example.main-content',
        'org.example.main-content ',
        'org.example.main-content\n',
      ])
        'invalid $field ${jsonEncode(id)}': {
          ..._mainContentActionCommand,
          field: id,
        },
  };
  for (final entry in invalidMainContentActionCommands.entries) {
    test(
      'Main Content action Command ${entry.key} invalidates only frontend',
      () async {
        final directory = await install(
          'main-content-commands',
          _manifest(
            components: {
              'backend': {'artifact': 'backend.aot'},
              'frontend': {
                ..._frontend(presentations: [_mainContent]),
                'extensions': [_command, entry.value, _projectSelector],
              },
            },
          ),
        );
        final catalog = await PreparedPluginCatalog.discover(root.path);
        final installation = catalog.installations.single;
        expect(installation.frontend, isNull);
        expect(
          installation.backendArtifactUri,
          directory.uri.resolve('backend.aot'),
        );
        final issue = catalog.issues.single;
        expect(issue.component, PreparedPluginComponent.frontend);
        expect(issue.pluginId, installation.metadata.id);
        expect(issue.installationDirectory.uri, directory.uri);
        expect(issue.message, isNotEmpty);
      },
    );
  }

  final invalidCommandLabels = [
    '',
    '   ',
    '\u00a0',
    'L' * 161,
    '\u{1f680}' * 81,
    'before\u2028after',
    'before\u2029after',
    for (var unit = 0; unit <= 0x9f; unit++)
      if (unit < 0x20 || unit >= 0x7f)
        'before${String.fromCharCode(unit)}after',
  ];
  final invalidCommandOperations = {
    'library': [
      '',
      ' ',
      'lib/command.dart',
      'file:///command.dart',
      'package://example/command.dart',
      'package:bad-package/command.dart',
      'package:BadPackage/command.dart',
      'package:1example/command.dart',
      'package:example/',
      'package:example/command',
      'package:example/command.txt',
      'package:example/command.dart/',
      'package:example//command.dart',
      'package:example/./command.dart',
      'package:example/nested/../command.dart',
      'package:example/../../command.dart',
      r'package:example/src\command.dart',
      'package:example/%63ommand.dart',
      'package:example/%2e%2e/command.dart',
      'package:example/command.dart?query',
      'package:example/command.dart#fragment',
      'package:example/my command.dart',
      ' package:example/command.dart',
      'package:example/command.dart\n',
    ],
    'entrypoint': [
      '',
      ' ',
      'Command.run',
      'runCommand()',
      'run-command',
      '1runCommand',
      'run Command',
      ' runCommand',
      'runCommand ',
      'runCommand\n',
      r'run\u0043ommand',
    ],
  };

  test('Command constructor validates labels and canonical operations', () {
    for (final label in invalidCommandLabels) {
      expect(() => command(label: label), throwsArgumentError);
    }
    for (final library in invalidCommandOperations['library']!) {
      expect(() => command(library: library), throwsFormatException);
    }
    for (final entrypoint in invalidCommandOperations['entrypoint']!) {
      expect(() => command(entrypoint: entrypoint), throwsFormatException);
    }
  });

  final invalidCommands = <String, Object?>{
    'case-sensitive kind': {..._command, 'kind': 'Command'},
    for (final field in [
      'unknown',
      'role',
      'displayName',
      'projectProviderId',
      'backendServices',
      'strategyAffinity',
      'sessionExecution',
      'hostAdapter',
      'configuration',
      'availability',
      'arguments',
    ])
      'unsupported $field': {..._command, field: 'unsupported'},
    for (final field in ['extensionId', 'commandId'])
      for (final id in [
        'command',
        'not namespaced',
        'org.Example.command',
        'org.example..command',
        'org.example.command-',
        'org.example.-command',
        'org.example_command',
        'org.ex\u00e4mple.command',
        ' org.example.command',
        'org.example.command ',
        'org.example.command\n',
      ])
        'invalid $field ${jsonEncode(id)}': {..._command, field: id},
    for (final label in invalidCommandLabels)
      'invalid label ${jsonEncode(label)}': {..._command, 'label': label},
    for (final field in invalidCommandOperations.entries)
      for (final value in field.value)
        'invalid ${field.key} ${jsonEncode(value)}': {
          ..._command,
          field.key: value,
        },
  };
  for (final entry in invalidCommands.entries) {
    test('Command ${entry.key} invalidates only frontend', () async {
      final directory = await install(
        'commands',
        _manifest(
          components: {
            'backend': {'artifact': 'backend.aot'},
            'frontend': {
              ..._frontend(presentations: [_session]),
              'extensions': [_projectSelector, entry.value, _command],
            },
          },
        ),
      );
      final catalog = await PreparedPluginCatalog.discover(root.path);
      final installation = catalog.installations.single;
      expect(installation.frontend, isNull);
      expect(
        installation.backendArtifactUri,
        directory.uri.resolve('backend.aot'),
      );
      final issue = catalog.issues.single;
      expect(issue.component, PreparedPluginComponent.frontend);
      expect(issue.pluginId, installation.metadata.id);
      expect(issue.installationDirectory.uri, directory.uri);
      expect(issue.message, isNotEmpty);
      if (entry.key.startsWith('invalid label')) {
        expect(issue.message, contains('frontend.extensions[1].label'));
      }
    });
  }

  test('explicit empty extensions coexist with presentations', () async {
    await install(
      'frontend',
      _manifest(
        components: {
          'frontend': {
            ..._frontend(presentations: [_session]),
            'extensions': <Object?>[],
          },
        },
      ),
    );
    final catalog = await PreparedPluginCatalog.discover(root.path);
    expect(catalog.issues, isEmpty);
    final frontend = catalog.installations.single.frontend!;
    expect(
      frontend.presentations.single,
      isA<PreparedMainContentPresentation>(),
    );
    expect(frontend.extensions, isEmpty);
    expect(() => frontend.extensions.clear(), throwsUnsupportedError);
  });

  for (final affinity in PreparedStrategyAffinity.values) {
    test(
      'Main Content metadata decodes ${affinity.name} and opt-in services',
      () async {
        await install(
          'session',
          _manifest(
            components: {
              'frontend': _frontend(
                presentations: [
                  {
                    ..._session,
                    'strategyAffinity': affinity.name,
                    'sessionExecution': true,
                    'backendServices': ['history.v1', 'testService'],
                  },
                ],
              ),
            },
          ),
        );
        final catalog = await PreparedPluginCatalog.discover(root.path);
        expect(catalog.issues, isEmpty);
        final descriptor =
            catalog.installations.single.frontend!.presentations.single
                as PreparedMainContentPresentation;
        expect(descriptor.sessionExecution, isTrue);
        expect(descriptor.strategyAffinity, affinity);
        expect(descriptor.backendServices, ['history.v1', 'testService']);
      },
    );
  }

  test(
    'Main Content constructor snapshots and validates the service allowlist',
    () {
      PreparedMainContentPresentation descriptor(List<String> services) =>
          PreparedMainContentPresentation(
            extensionId: ExtensionId(_session['extensionId']! as String),
            order: 100,
            initialize: _session['initialize']! as String,
            library: _session['library']! as String,
            entrypoint: _session['entrypoint']! as String,
            backendServices: services,
          );
      final services = ['history.v1'];
      final prepared = descriptor(services);
      services.clear();
      expect(prepared.backendServices, ['history.v1']);
      expect(
        () => prepared.backendServices.add('other'),
        throwsUnsupportedError,
      );
      expect(() => descriptor(['a', 'a']), throwsFormatException);
      expect(() => descriptor(['not a service']), throwsFormatException);
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
        for (final value in <Object?>[null, 1, false, 'invalid', {}])
          'non-array extensions $value': {
            ..._frontend(presentations: [_session]),
            'extensions': value,
          },
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
            isA<PreparedMainContentPresentation>(),
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

  for (final descriptor in [
    _session,
    _toolActivity,
    _modelNativeActivity,
    _projectSelector,
    _command,
    _consoleActionCommand,
    _mainContentActionCommand,
  ]) {
    final list = descriptor.containsKey('kind')
        ? 'extensions'
        : 'presentations';
    for (final field in descriptor.keys.where((key) => key != 'order')) {
      test(
        '${descriptor['role'] ?? descriptor['kind']} requires nonblank string $field',
        () async {
          final invalidValues = <Object?>[
            null,
            1,
            false,
            [],
            {},
            '',
            '  ',
            '\t\n',
          ];
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
                  'frontend': {
                    ..._frontend(presentations: [_session]),
                    'extensions': [_projectSelector],
                    list: [descriptor, invalid, descriptor],
                  },
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
            everyElement(contains('frontend.$list[1].$field')),
          );
        },
      );
    }
  }

  final invalidDescriptors = <String, Object?>{
    'null descriptor': null,
    'array descriptor': [],
    'string descriptor': 'session',
    'behavioral extension in presentations': _projectSelector,
    'command extension in presentations': _command,
    'console action command extension in presentations': _consoleActionCommand,
    'console action command presentation role': {
      ..._consoleActionCommand,
      'role': 'consoleActionCommand',
    }..remove('kind'),
    'main content action command extension in presentations':
        _mainContentActionCommand,
    'main content action command presentation role': {
      ..._mainContentActionCommand,
      'role': 'mainContentActionCommand',
    }..remove('kind'),
    'command presentation role': {..._command, 'role': 'command'}
      ..remove('kind'),
    'project selector presentation role': {
      ..._projectSelector,
      'role': 'projectSelector',
    }..remove('kind'),
    'unknown role': {..._session, 'role': 'future'},
    'removed session role': {..._session, 'role': 'session'},
    'case-sensitive role': {..._session, 'role': 'Session'},
    'foreign session field': {..._session, 'toolId': 'org.example.tool'},
    'removed hostAdapter': {..._session, 'hostAdapter': 'example.session.v1'},
    for (final value in <Object?>[null, 'true', 1, [], {}])
      'invalid sessionExecution $value': {
        ..._session,
        'sessionExecution': value,
      },
    for (final value in <Object?>[
      null,
      true,
      1,
      [],
      {},
      '',
      'owning-backend',
      'OwningBackend',
    ])
      'invalid strategyAffinity $value': {
        ..._session,
        'strategyAffinity': value,
      },
    for (final value in <Object?>[
      null,
      true,
      1,
      '',
      {},
      ['a', 'a'],
      [1],
      [null],
      [''],
      [' spaced'],
      ['path/service'],
      ['a..b'],
    ])
      'invalid backendServices $value': {..._session, 'backendServices': value},
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

  final invalidExtensions = <String, Object?>{
    'null': null,
    'array': [],
    'string': 'projectSelector',
    'number': 1,
    'boolean': false,
    'unknown kind': {..._projectSelector, 'kind': 'future'},
    'case-sensitive kind': {..._projectSelector, 'kind': 'ProjectSelector'},
    'presentation in extensions': _session,
    for (final field in ['unknown', 'role', 'hostAdapter', 'configuration'])
      'unsupported $field': {..._projectSelector, field: 'unsupported'},
    for (final id in [
      'selector',
      'not namespaced',
      'org.Example.selector',
      'org.example..selector',
      'org.example.selector-',
      ' org.example.selector',
      'org.example.selector ',
    ])
      'invalid ExtensionId $id': {..._projectSelector, 'extensionId': id},
    for (final id in [
      'provider',
      'not namespaced',
      'org.Example.provider',
      'org.example.provider-',
      ' org.example.provider',
      'org.example.provider ',
    ])
      'invalid ProviderId $id': {..._projectSelector, 'projectProviderId': id},
    for (final library in [
      'lib/selector.dart',
      'file:///selector.dart',
      'package://example/selector.dart',
      'package:bad-package/selector.dart',
      'package:BadPackage/selector.dart',
      'package:1example/selector.dart',
      'package:example/',
      'package:example/selector',
      'package:example/selector.txt',
      'package:example/selector.dart/',
      'package:example//selector.dart',
      'package:example/./selector.dart',
      'package:example/nested/../selector.dart',
      'package:example/../../selector.dart',
      r'package:example/src\selector.dart',
      'package:example/%73elector.dart',
      'package:example/%2e%2e/selector.dart',
      'package:example/selector.dart?query',
      'package:example/selector.dart#fragment',
      'package:example/my selector.dart',
      ' package:example/selector.dart',
      'package:example/selector.dart\n',
    ])
      'invalid library ${jsonEncode(library)}': {
        ..._projectSelector,
        'library': library,
      },
    for (final entrypoint in [
      'Selector.selectProject',
      'selectProject()',
      'select-project',
      '1selectProject',
      'select Project',
      ' selectProject',
      'selectProject ',
      'selectProject\n',
      r'select\u0050roject',
    ])
      'invalid entrypoint ${jsonEncode(entrypoint)}': {
        ..._projectSelector,
        'entrypoint': entrypoint,
      },
  };
  for (final entry in invalidExtensions.entries) {
    test('extension ${entry.key} invalidates entire frontend only', () async {
      final directory = await install(
        'plugin',
        _manifest(
          components: {
            'backend': {'artifact': 'backend.aot'},
            'frontend': {
              ..._frontend(presentations: [_session]),
              'extensions': [_projectSelector, entry.value],
            },
          },
        ),
      );
      final catalog = await PreparedPluginCatalog.discover(root.path);
      final installation = catalog.installations.single;
      expect(
        installation.backendArtifactUri,
        directory.uri.resolve('backend.aot'),
      );
      expect(installation.frontend, isNull);
      final issue = catalog.issues.single;
      expect(issue.component, PreparedPluginComponent.frontend);
      expect(issue.pluginId, installation.metadata.id);
      expect(issue.installationDirectory.uri, directory.uri);
      expect(
        issue.message,
        contains(
          entry.key.startsWith('invalid ExtensionId')
              ? 'extension ID'
              : 'frontend.extensions[1]',
        ),
      );
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
  'role': 'mainContent',
  'library': 'package:example_frontend/session.dart',
  'extensionId': 'org.example.session',
  'order': 100,
  'initialize': 'initializeSession',
  'entrypoint': 'buildSession',
};

const _consoleAction = {
  'id': 'new-console',
  'label': 'New Console',
  'entrypoint': 'newConsole',
};

const _mainContent = <String, Object?>{
  'role': 'mainContent',
  'extensionId': 'org.example.main-content',
  'order': 200,
  'library': 'package:example_frontend/main_content.dart',
  'initialize': 'initializePanes',
  'entrypoint': 'buildPane',
};

const _mainContentAction = {
  'id': 'open',
  'label': 'Open',
  'entrypoint': 'openInput',
};

const _console = {
  'role': 'console',
  'extensionId': 'org.example.console',
  'library': 'package:example_frontend/console.dart',
  'entrypoint': 'buildConsole',
  'actions': [_consoleAction],
};

const _projectSelector = {
  'kind': 'projectSelector',
  'extensionId': 'org.example.project-selector',
  'projectProviderId': 'org.example.project-provider',
  'displayName': 'Open Project...',
  'library': 'package:example_frontend/project_selector.dart',
  'entrypoint': 'selectProject',
};

const _command = {
  'kind': 'command',
  'extensionId': 'org.example.command-extension',
  'commandId': 'org.example.command',
  'label': 'Run Command',
  'library': 'package:example_frontend/command.dart',
  'entrypoint': 'runCommand',
};

const _consoleActionCommand = {
  'kind': 'consoleActionCommand',
  'extensionId': 'org.example.console-command-extension',
  'commandId': 'org.example.new-console',
  'consoleExtensionId': 'org.example.console',
  'actionId': 'new-console',
};

const _mainContentActionCommand = {
  'kind': 'mainContentActionCommand',
  'extensionId': 'org.example.main-content-command-extension',
  'commandId': 'org.example.open',
  'mainContentExtensionId': 'org.example.main-content',
  'actionId': 'open',
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
