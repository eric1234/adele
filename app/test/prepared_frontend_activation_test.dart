import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:adele_capabilities/adele_capabilities.dart';
import 'package:adele_core_extensions/adele_core_extensions.dart';
import 'package:adele_desktop/core/application_plugin_bootstrap.dart';
import 'package:adele_desktop/core/product_lifecycle.dart';
import 'package:adele_desktop/frontend/application_frontend_bootstrap.dart';
import 'package:adele_desktop/frontend/directory_picker_bridge.dart';
import 'package:adele_desktop/frontend/main_content_bridge.dart';
import 'package:adele_desktop/frontend/model_native_activity_bridge.dart';
import 'package:adele_desktop/frontend/owning_backend_bridge.dart';
import 'package:adele_desktop/frontend/prepared_console_host.dart';
import 'package:adele_desktop/frontend/prepared_session_services.dart';
import 'package:adele_desktop/frontend/tool_activity_inspection_bridge.dart';
import 'package:adele_desktop/terminal/environment_terminal_owner.dart';
import 'package:adele_desktop/ui/console/console_controller.dart';
import 'package:adele_orchestration/adele_orchestration.dart';
import 'package:adele_plugin_api/adele_plugin_api.dart';
import 'package:adele_product/adele_product.dart';
import 'package:adele_ui/adele_ui.dart';
import 'package:contract_codegen/contract_codegen.dart';
import 'package:dart_eval/dart_eval.dart';
import 'package:file_selector_platform_interface/file_selector_platform_interface.dart';
import 'package:flutter/material.dart';
import 'package:flutter_eval/flutter_eval.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plugin_runtime/plugin_runtime.dart';

const _library = 'package:installed_probe/main.dart';
final _toolId = ToolId('dev.example.tool');
final _strategyId = OrchestrationStrategyId('dev.example.strategy');
final _session = Session(
  id: SessionId('session'),
  taskId: TaskId('task'),
  strategyId: _strategyId,
);

void main() {
  late Directory root;
  late ExtensionRegistry extensions;
  late ApplicationFrontendBootstrap owner;
  late Uint8List bytes;

  setUpAll(() {
    final compiler = Compiler()
      ..addPlugin(flutterEvalPlugin)
      ..addPlugin(const ToolActivityInspectionDeclarations())
      ..addPlugin(const ModelNativeActivityDeclarations())
      ..addPlugin(const DirectoryPickerDeclarations())
      ..addPlugin(const OwningBackendDeclarations())
      ..addPlugin(const MainContentDeclarations())
      ..entrypoints.add(_library);
    final program = compiler.compile({
      'installed_probe': {
        'main.dart': '''
import 'package:flutter/material.dart';
import 'package:adele_ui/tool_activity_inspection_bridge.dart';
import 'package:adele_ui/model_native_activity_bridge.dart';
import 'package:adele_ui/directory_picker_bridge.dart';
import 'package:adele_ui/owning_backend_bridge.dart';
import 'package:adele_ui/main_content_bridge.dart';
void initializePanes() { readMainContentContext(); }
Widget customPane() => Text('Prepared pane');
Widget toolRich() => Text('rich ' + readToolActivitySnapshot().canonicalArguments['label']);
Widget toolCompact() => Text('compact ' + readToolActivitySnapshot().canonicalArguments['label']);
Widget nativeRich() => Text('rich ' + readModelNativeActivityData()['label']);
Widget nativeCompact() => Text('compact ' + readModelNativeActivityData()['label']);
Widget toolBackend() => ToolBackendProbe();
Widget toolCompactBackendProbe() {
  requestOwningBackend('fixture.read', 'read', <String, dynamic>{});
  return Text('compact backend acquired');
}
class ToolBackendProbe extends StatefulWidget {
  @override
  State<ToolBackendProbe> createState() => ToolBackendState();
}
class ToolBackendState extends State<ToolBackendProbe> {
  String status = 'idle';
  bool disposed = false;
  void query() async {
    final result = await settleOwningBackendOperation(
      requestOwningBackend('fixture.read', 'read', <String, dynamic>{}),
    );
    if (disposed) return;
    setState(() { status = result[0] == true ? 'ready' : 'unavailable'; });
  }
  @override
  void dispose() {
    disposed = true;
    super.dispose();
  }
  @override
  Widget build(BuildContext context) {
    final snapshot = readToolActivitySnapshot();
    return Column(children: [
      Text('facts ' + snapshot.sessionId + '/' + snapshot.runId + '/' + snapshot.toolInvocationId),
      Text(status),
      TextButton(onPressed: query, child: Text('Query backend')),
    ]);
  }
}
Future<String?> customSelector() async => 'catalog://example/project';
Future<String?> cancellation() async => null;
Future<String?> badUri() async => 'https://[invalid';
Future<int> badShape() async => 42;
Future<dynamic> recordResult() async => (1, 2);
Future<dynamic> cyclicResult() async {
  final value = <String, dynamic>{};
  value['self'] = value;
  return value;
}
Future<String?> semanticFailure() async { throw StateError('selection failed'); }
Future<String?> nativeSelector() async => await pickDirectory();
int commandCalls = 0;
void voidCommand() {
  commandCalls++;
  if (commandCalls != 1) throw StateError('Command runtime was reused.');
}
dynamic nullCommand() => null;
Future<void> asyncCommand() async {}
Future<void> delayedCommand() async {
  await Future<void>.delayed(Duration(seconds: 1));
}
''',
      },
      'adele_ui': {
        for (final file in [
          'tool_activity_inspection_bridge.dart',
          'model_native_activity_bridge.dart',
          'directory_picker_bridge.dart',
          'owning_backend_bridge.dart',
          'main_content_bridge.dart',
        ])
          file: File(
            '${Directory.current.parent.path}/packages/ui/lib/$file',
          ).readAsStringSync(),
      },
      'adele_contract': {'adele_contract.dart': evalContractSupportSource},
    });
    bytes = program.write();
  });

  setUp(() async {
    root = await Directory.systemTemp.createTemp('adele-installed-frontend-');
    extensions = ExtensionRegistry();
    owner = ApplicationFrontendBootstrap(extensions: extensions);
  });

  tearDown(() async {
    await owner.close();
    await root.delete(recursive: true);
  });

  Future<File> install(
    String name,
    List<Map<String, Object?>>? descriptors, {
    List<int>? artifactBytes,
    bool backend = false,
    List<Map<String, Object?>> extensionDescriptors = const [],
  }) async {
    final directory = await Directory('${root.path}/$name').create();
    final artifact = File('${directory.path}/frontend.evc');
    if (descriptors != null) {
      await artifact.writeAsBytes(artifactBytes ?? bytes);
    }
    if (backend) await File('${directory.path}/backend.aot').writeAsBytes([1]);
    await File(
      '${directory.path}/adele_plugin.installation.json',
    ).writeAsString(
      jsonEncode({
        'manifestVersion': 1,
        'metadata': {
          'id': 'dev.example.$name',
          'version': 'opaque',
          'displayName': name,
        },
        'components': {
          if (backend) 'backend': {'artifact': 'backend.aot'},
          if (descriptors != null)
            'frontend': {
              'artifact': 'frontend.evc',
              'presentations': descriptors,
              'extensions': extensionDescriptors,
            },
        },
      }),
    );
    return artifact;
  }

  Future<PreparedPluginCatalog> discover() async {
    final catalog = await PreparedPluginCatalog.discover(root.path);
    expect(catalog.issues, isEmpty);
    return catalog;
  }

  Future<void> enableConsoleHost() async {
    await owner.close();
    final store = InMemoryProductStore();
    final terminals = EnvironmentTerminalCoordinator(
      environmentRuntime: EnvironmentRuntime(
        store: store,
        registry: CapabilityRegistry(),
        providerForBinding: (_) => throw StateError(
          'Activation cannot acquire an Environment provider.',
        ),
        retainEnvironment: store.replaceEnvironment,
      ),
    );
    final controller = ConsoleController(extensions);
    owner = ApplicationFrontendBootstrap(
      extensions: extensions,
      consoleHost: PreparedConsoleHost(
        store: store,
        terminals: terminals,
        extensions: extensions,
        controller: controller,
      ),
    );
    addTearDown(() async {
      await owner.close();
      await controller.close();
      await terminals.close();
      controller.dispose();
    });
  }

  test('empty snapshot starts and closes once', () async {
    final catalog = await discover();
    await owner.start(catalog);
    expect(owner.state, ApplicationFrontendState.ready);
    expect(owner.catalog, same(catalog));
    expect(owner.generations, isEmpty);
    expect(() => owner.start(catalog), throwsStateError);
    final closing = owner.close();
    expect(owner.close(), same(closing));
    await closing;
    expect(owner.state, ApplicationFrontendState.closed);
    expect(() => owner.start(catalog), throwsStateError);
  });

  for (final affinity in ['independent', 'owningBackend']) {
    test(
      'Main Content $affinity metadata initializes without execution or backend',
      () async {
        await owner.close();
        final backends = ApplicationPluginBootstrap(
          CapabilityRegistry(),
          extensions,
        );
        addTearDown(backends.close);
        final services = PreparedSessionServices(
          extensions: extensions,
          backends: backends,
          controllerForSession: (_, _) =>
              throw StateError('Activation cannot obtain execution.'),
          inspectActivity: (_, _) => false,
          isCurrent: (_) => true,
        );
        owner = ApplicationFrontendBootstrap(
          extensions: extensions,
          sessionServices: services,
        );
        final strategy = extensions.register(
          point: orchestrationStrategyContributions,
          id: ExtensionId('dev.example.strategy'),
          value: OrchestrationStrategyContribution(
            strategyId: _strategyId,
            materialize: (_) =>
                throw StateError('Activation cannot start a Run.'),
          ),
        );
        addTearDown(strategy.close);
        await install('session', [
          {
            ..._sessionDescriptor('session'),
            'strategyAffinity': affinity,
            'sessionExecution': true,
            'backendServices': ['required.backend'],
          },
        ]);
        await owner.start(await discover());
        expect(owner.generations.single.state, InstalledFrontendState.active);
        final presentation = extensions
            .discover(mainContentContributions)
            .single;
        await presentation.value.attach(_Access());
        expect(backends.state, ApplicationPluginState.unconfigured);
        presentation.validate();
      },
    );
  }

  test(
    'absent frontend is ignored; zero descriptors is an active generation',
    () async {
      await install('backend-only', null, backend: true);
      await install('zero', []);
      await owner.start(await discover());
      expect(owner.generations, hasLength(1));
      expect(owner.generations.single.state, InstalledFrontendState.active);
      expect(owner.generations.single.registrations, isEmpty);
      expect(owner.generations.single.failure, isNull);
    },
  );

  testWidgets(
    'rich missing backend preserves facts and compact never acquires it',
    (tester) async {
      await owner.close();
      final backends = ApplicationPluginBootstrap(
        CapabilityRegistry(),
        extensions,
      );
      addTearDown(backends.close);
      owner = ApplicationFrontendBootstrap(
        extensions: extensions,
        backends: backends,
      );
      await tester.runAsync(() async {
        await install('tool-backend', [
          {
            ..._toolDescriptor('tool-backend'),
            'inspectionEntrypoint': 'toolBackend',
            'backendServices': ['fixture.read'],
          },
        ]);
        await owner.start(await discover());
      });
      final source = _ToolSource();
      addTearDown(source.dispose);
      final compact = extensions
          .discover(toolActivityCompactPresentationContributions)
          .single;
      await tester.pumpWidget(
        MaterialApp(home: compact.value.createPresentation(source)),
      );
      expect(find.text('compact tool'), findsOneWidget);
      expect(backends.state, ApplicationPluginState.unconfigured);
      expect(backends.host, isNull);
      final rich = extensions
          .discover(toolActivityInspectionContributions)
          .single;
      await tester.pumpWidget(
        MaterialApp(home: rich.value.createPresentation(source)),
      );
      expect(find.text('facts session/run/tool'), findsOneWidget);
      await tester.tap(find.text('Query backend'));
      await tester.pump();
      expect(find.text('unavailable'), findsOneWidget);
      expect(find.text('facts session/run/tool'), findsOneWidget);
      expect(backends.state, ApplicationPluginState.unconfigured);
      expect(backends.host, isNull);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('compact entrypoint cannot access the rich backend bridge', (
    tester,
  ) async {
    await tester.runAsync(() async {
      await install('compact-backend', [
        {
          ..._toolDescriptor('compact-backend'),
          'compactEntrypoint': 'toolCompactBackendProbe',
          'backendServices': ['fixture.read'],
        },
      ]);
      await owner.start(await discover());
    });
    final source = _ToolSource();
    addTearDown(source.dispose);
    final compact = extensions
        .discover(toolActivityCompactPresentationContributions)
        .single;
    await tester.pumpWidget(
      MaterialApp(home: compact.value.createPresentation(source)),
    );
    await tester.pump();
    expect(find.text('compact backend acquired'), findsNothing);
    expect(find.text('Frontend unavailable.'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  test(
    'multiple descriptors retain exact metadata independently of Session hosting',
    () async {
      await install('multiple', [
        _sessionDescriptor('one'),
        _sessionDescriptor('two'),
        _toolDescriptor('one'),
        _toolDescriptor('two'),
        _nativeDescriptor('one'),
      ]);
      final catalog = await discover();
      await owner.start(catalog);
      final generation = owner.generations.single;
      expect(generation.installation, same(catalog.installations.single));
      expect(generation.registrations, hasLength(8));
      expect(() => owner.generations.clear(), throwsUnsupportedError);
      expect(() => generation.registrations.clear(), throwsUnsupportedError);
      final sessions = extensions.discover(mainContentContributions);
      expect(sessions.map((binding) => binding.id.value), [
        'dev.example.one.session',
        'dev.example.two.session',
      ]);
      for (final binding in sessions) {
        expect(binding.value.order, 100);
      }
      expect(
        extensions.discover(toolActivityInspectionContributions),
        hasLength(2),
      );
      expect(
        extensions.discover(toolActivityCompactPresentationContributions),
        hasLength(2),
      );
      expect(
        extensions
            .discover(modelNativeActivityPresentationContributions)
            .single
            .value
            .presentationKind,
        'example.safe-kind',
      );
      expect(
        () => ToolActivityInspectionResolver(extensions).resolve(_toolId),
        throwsA(isA<AmbiguousToolActivityInspection>()),
      );
    },
  );

  test(
    'read failures do not stop independently activated Session frontends',
    () async {
      final missing = await install('a-missing', [_toolDescriptor('missing')]);
      await install('b-unknown', [_sessionDescriptor('unknown')]);
      await install('c-healthy', [_nativeDescriptor('healthy')]);
      final catalog = await discover();
      await missing.delete();
      await owner.start(catalog);
      expect(owner.state, ApplicationFrontendState.ready);
      expect(owner.generations.map((value) => value.state), [
        InstalledFrontendState.failed,
        InstalledFrontendState.active,
        InstalledFrontendState.active,
      ]);
      expect(owner.generations[0].failure, isA<FileSystemException>());
      expect(owner.generations[1].failure, isNull);
      expect(extensions.discover(toolActivityInspectionContributions), isEmpty);
      expect(extensions.discover(mainContentContributions), hasLength(1));
      expect(
        extensions.discover(modelNativeActivityPresentationContributions),
        hasLength(1),
      );
    },
  );

  test(
    'behavioral descriptors coexist with presentations and retain exact bytes',
    () async {
      final artifact = await install(
        'mixed',
        [_sessionDescriptor('mixed')],
        extensionDescriptors: [
          _selectorDescriptor('selector', 'customSelector'),
        ],
      );
      await owner.start(await discover());
      final binding = extensions.discover(projectSelectorContributions).single;
      expect(binding.id.value, 'dev.example.selector.selector');
      expect(binding.value.displayName, 'Open prepared Project...');
      expect(
        binding.value.projectProviderId,
        ProviderId('dev.example.project'),
      );
      expect(owner.catalog!.installations.single.backendArtifactUri, isNull);
      expect(owner.generations.single.registrations, hasLength(2));
      await artifact.writeAsBytes([0, 1, 2]);
      expect(
        await binding.value.selectProject(),
        Uri.parse('catalog://example/project'),
      );
      expect(
        await binding.value.selectProject(),
        Uri.parse('catalog://example/project'),
      );
      expect(extensions.discover(mainContentContributions), hasLength(1));
    },
  );

  test(
    'selector cancellation, result validation and semantic failure are operation-local',
    () async {
      await install(
        'selectors',
        [],
        extensionDescriptors: [
          for (final name in [
            'cancellation',
            'badUri',
            'badShape',
            'recordResult',
            'cyclicResult',
            'semanticFailure',
            'customSelector',
          ])
            _selectorDescriptor(name.toLowerCase(), name),
        ],
      );
      await owner.start(await discover());
      final bindings = extensions.discover(projectSelectorContributions);
      expect(await bindings.first.value.selectProject(), isNull);
      for (final binding in bindings.skip(1).take(4)) {
        await expectLater(binding.value.selectProject(), throwsFormatException);
      }
      await expectLater(bindings[5].value.selectProject(), throwsA(anything));
      expect(
        await bindings.last.value.selectProject(),
        Uri.parse('catalog://example/project'),
      );
      expect(owner.generations.single.state, InstalledFrontendState.active);
      expect(owner.generations.single.failure, isNull);
      for (final binding in bindings) {
        binding.validate();
      }
    },
  );

  test(
    'corrupt behavioral bytecode and missing entrypoints fail activation without granting a picker',
    () async {
      await install(
        'a-corrupt',
        [_sessionDescriptor('rolled-back')],
        artifactBytes: [1, 2, 3],
        extensionDescriptors: [
          _selectorDescriptor('corrupt', 'customSelector'),
        ],
      );
      await install(
        'b-absent-entrypoint',
        [],
        extensionDescriptors: [_selectorDescriptor('absent', 'notInArtifact')],
      );
      await install('c-healthy', [_nativeDescriptor('healthy')], backend: true);
      await owner.start(await discover());
      expect(owner.generations.map((generation) => generation.state), [
        InstalledFrontendState.failed,
        InstalledFrontendState.failed,
        InstalledFrontendState.active,
      ]);
      expect(extensions.discover(projectSelectorContributions), isEmpty);
      expect(extensions.discover(mainContentContributions), isEmpty);
      expect(
        extensions.discover(modelNativeActivityPresentationContributions),
        hasLength(1),
      );
      expect(owner.catalog!.installations.last.backendArtifactUri, isNotNull);
    },
  );

  test(
    'retired selector rejects late native results and replacement requires fresh discovery',
    () async {
      final original = FileSelectorPlatform.instance;
      final picker = _PendingPicker();
      FileSelectorPlatform.instance = picker;
      addTearDown(() => FileSelectorPlatform.instance = original);
      await install(
        'selector',
        [],
        extensionDescriptors: [
          _selectorDescriptor('selector', 'nativeSelector'),
        ],
      );
      await owner.start(await discover());
      expect(picker.calls, 0);
      final old = extensions.discover(projectSelectorContributions).single;
      final select = old.value.selectProject;
      final pending = select();
      final rejected = expectLater(pending, throwsA(anything));
      expect(picker.calls, 1);
      await owner.generations.single.retire(
        projectSelectorContributions,
        old.id,
      );
      expect(old.validate, throwsA(isA<StaleExtensionBinding>()));
      expect(extensions.discover(projectSelectorContributions), isEmpty);
      await install(
        'selector',
        [],
        extensionDescriptors: [
          _selectorDescriptor('selector', 'customSelector'),
        ],
      );
      final replacement = ApplicationFrontendBootstrap(extensions: extensions);
      addTearDown(replacement.close);
      await replacement.start(await discover());
      picker.pending.complete('catalog://late/selection');
      await rejected;
      await expectLater(select(), throwsStateError);
      await owner.close();
      final fresh = extensions.discover(projectSelectorContributions).single;
      expect(
        await fresh.value.selectProject(),
        Uri.parse('catalog://example/project'),
      );
      expect(picker.calls, 1);
    },
  );

  test(
    'frontend-only Commands invoke void and null in fresh runtimes without presentations',
    () async {
      await install(
        'commands',
        [],
        extensionDescriptors: [
          _commandDescriptor('sync', 'voidCommand'),
          _commandDescriptor('null', 'nullCommand'),
          _commandDescriptor('async', 'asyncCommand'),
          _commandDescriptor('async-null', 'cancellation'),
        ],
      );
      await owner.start(await discover());
      final installation = owner.catalog!.installations.single;
      expect(installation.backendArtifactUri, isNull);
      expect(installation.frontend!.presentations, isEmpty);
      expect(owner.generations.single.state, InstalledFrontendState.active);
      expect(owner.generations.single.registrations, hasLength(4));
      expect(extensions.discover(mainContentContributions), isEmpty);
      expect(extensions.discover(consoleContributions), isEmpty);
      expect(extensions.discover(taskBrowserContributions), isEmpty);
      final commands = CommandResolver(extensions);
      expect(commands.discover(), hasLength(4));
      for (final command in commands.discover()) {
        expect(command.binding.id.value, '${command.id.value}.registration');
        expect(command.label, 'Prepared ${command.id.value.split('.').last}');
        expect(command.availability, CommandAvailability.enabled);
        expect(
          command.binding.value.availability(),
          CommandAvailability.enabled,
        );
        await command.invoke();
        await command.invoke();
      }
    },
  );

  test(
    'Command result, semantic and unavailable native bridge failures stay operation-local',
    () async {
      final original = FileSelectorPlatform.instance;
      final picker = _PendingPicker();
      FileSelectorPlatform.instance = picker;
      addTearDown(() => FileSelectorPlatform.instance = original);
      await install(
        'commands',
        [],
        extensionDescriptors: [
          for (final name in [
            'badShape',
            'recordResult',
            'cyclicResult',
            'semanticFailure',
            'nativeSelector',
            'voidCommand',
          ])
            _commandDescriptor(name.toLowerCase(), name),
        ],
      );
      await owner.start(await discover());
      final commands = CommandResolver(extensions);
      final generation = owner.generations.single;
      expect(generation.state, InstalledFrontendState.active);
      expect(picker.calls, 0);
      for (final name in ['badshape', 'recordresult', 'cyclicresult']) {
        await expectLater(
          commands.resolve(CommandId('dev.example.$name')).invoke(),
          throwsFormatException,
        );
      }
      for (final name in ['semanticfailure', 'nativeselector']) {
        await expectLater(
          commands.resolve(CommandId('dev.example.$name')).invoke(),
          throwsA(anything),
        );
      }
      expect(picker.calls, 0);
      await commands.resolve(CommandId('dev.example.voidcommand')).invoke();
      expect(generation.state, InstalledFrontendState.active);
      expect(generation.failure, isNull);
      for (final command in commands.discover()) {
        expect(command.binding.validate, returnsNormally);
        expect(command.availability, CommandAvailability.enabled);
      }
    },
  );

  test('missing Command entrypoint fails before any registration', () async {
    await install(
      'commands',
      [_sessionDescriptor('not-registered')],
      extensionDescriptors: [
        _commandDescriptor('valid', 'voidCommand'),
        _commandDescriptor('absent', 'notInArtifact'),
      ],
    );
    await owner.start(await discover());
    final generation = owner.generations.single;
    expect(generation.state, InstalledFrontendState.failed);
    expect(generation.failure, isNotNull);
    expect(generation.registrations, isEmpty);
    expect(extensions.discover(commandContributions), isEmpty);
    expect(extensions.discover(mainContentContributions), isEmpty);
  });

  for (final invalid in [
    'missing target',
    'non-Console target',
    'missing action',
    'no-action target',
    'read-only target',
    'ambiguous target',
    'foreign registered target',
  ]) {
    test('Console-action $invalid fails before any publication', () async {
      await enableConsoleHost();
      ExtensionRegistration? foreign;
      if (invalid == 'foreign registered target') {
        foreign = extensions.register(
          point: consoleContributions,
          id: ExtensionId('dev.example.target.console'),
          value: ConsoleContribution(
            actions: [
              ConsoleCreationAction(
                id: 'create',
                label: 'Foreign action',
                create: (_) => fail('Cannot execute a foreign action.'),
              ),
            ],
          ),
        );
        addTearDown(foreign.close);
      }
      final publications = <ExtensionId>[];
      final subscription = extensions.changes.listen((_) {
        publications.addAll([
          ...extensions
              .discover(mainContentContributions)
              .map((entry) => entry.id),
          ...extensions.discover(commandContributions).map((entry) => entry.id),
          ...extensions
              .discover(consoleContributions)
              .where((entry) => !(foreign?.owns(entry) ?? false))
              .map((entry) => entry.id),
        ]);
      });
      addTearDown(subscription.cancel);
      await install(
        'invalid',
        [
          _sessionDescriptor('not-published'),
          if (invalid == 'non-Console target')
            {
              ..._sessionDescriptor('target'),
              'extensionId': 'dev.example.target.console',
            },
          if (invalid == 'missing action' || invalid == 'ambiguous target')
            _consoleDescriptor('target'),
          if (invalid == 'ambiguous target') _consoleDescriptor('target'),
          if (invalid == 'read-only target' || invalid == 'no-action target')
            {
              ..._consoleDescriptor('target'),
              'readOnly': invalid == 'read-only target',
              'actions': <Object?>[],
            },
        ],
        extensionDescriptors: [
          _commandDescriptor('not-published', 'voidCommand'),
          {
            ..._consoleCommandDescriptor('target'),
            if (invalid == 'missing action') 'actionId': 'not-an-action',
          },
        ],
      );
      await owner.start(await discover());
      await Future<void>.delayed(Duration.zero);
      final generation = owner.generations.single;
      expect(generation.state, InstalledFrontendState.failed);
      expect(generation.failure, isA<StateError>());
      expect(generation.registrations, isEmpty);
      expect(publications, isEmpty);
      expect(extensions.discover(commandContributions), isEmpty);
      expect(extensions.discover(mainContentContributions), isEmpty);
      expect(
        extensions.discover(consoleContributions),
        hasLength(foreign == null ? 0 : 1),
      );
      expect(foreign?.isClosed, foreign == null ? isNull : isFalse);
    });
  }

  test(
    'Console-action registration collision rolls back only its acquired generation',
    () async {
      await enableConsoleHost();
      var calls = 0;
      final unrelated = extensions.register(
        point: commandContributions,
        id: ExtensionId('dev.example.conflict.registration'),
        value: CommandContribution(
          id: CommandId('dev.example.unrelated'),
          label: 'Unrelated',
          availability: () => CommandAvailability.enabled,
          invoke: () => calls++,
        ),
      );
      addTearDown(unrelated.close);
      final visibleFailedBindings = <ExtensionId>[];
      final subscription = extensions.changes.listen((_) {
        for (final generation in owner.generations) {
          if (generation.state != InstalledFrontendState.failed) continue;
          for (final binding in <ExtensionBinding<Object>>[
            ...extensions.discover(commandContributions),
            ...extensions.discover(consoleContributions),
            ...extensions.discover(mainContentContributions),
          ]) {
            if (generation.registrations.any((entry) => entry.owns(binding))) {
              visibleFailedBindings.add(binding.id);
            }
          }
        }
      });
      addTearDown(subscription.cancel);
      await install(
        'a-conflict',
        [_sessionDescriptor('rolled-back'), _consoleDescriptor('target')],
        extensionDescriptors: [
          _consoleCommandDescriptor('target'),
          {
            ..._consoleCommandDescriptor('target'),
            'extensionId': 'dev.example.conflict.registration',
            'commandId': 'dev.example.conflict',
          },
        ],
      );
      await install('b-healthy', [_sessionDescriptor('healthy')]);
      await owner.start(await discover());
      await Future<void>.delayed(Duration.zero);
      final failed = owner.generations.first;
      expect(failed.state, InstalledFrontendState.failed);
      expect(failed.failure, isA<ExtensionRegistrationException>());
      expect(failed.registrations, hasLength(3));
      expect(failed.registrations.every((entry) => entry.isClosed), isTrue);
      expect(visibleFailedBindings, isEmpty);
      expect(unrelated.isClosed, isFalse);
      expect(extensions.discover(consoleContributions), isEmpty);
      final retained = CommandResolver(extensions).discover().single;
      expect(unrelated.owns(retained.binding), isTrue);
      await retained.invoke();
      expect(calls, 1);
      expect(
        extensions.discover(mainContentContributions).single.id,
        ExtensionId('dev.example.healthy.session'),
      );
      expect(owner.generations.last.state, InstalledFrontendState.active);
    },
  );

  for (final invalid in [
    'missing target',
    'non-Main-Content target',
    'missing action',
    'no-action target',
    'ambiguous target',
    'foreign registered target',
  ]) {
    test('Main Content action $invalid fails before any publication', () async {
      ExtensionRegistration? foreign;
      if (invalid == 'foreign registered target') {
        foreign = extensions.register(
          point: mainContentContributions,
          id: ExtensionId('dev.example.target.session'),
          value: MainContentContribution(
            order: 100,
            attach: (_) {},
            actions: [
              MainContentAction(
                id: 'open',
                label: 'Foreign input',
                createPresentation: (_) => fail('Cannot open foreign input.'),
              ),
            ],
          ),
        );
        addTearDown(foreign.close);
      }
      final publications = <ExtensionId>[];
      final subscription = extensions.changes.listen((_) {
        publications.addAll([
          ...extensions
              .discover(mainContentContributions)
              .where((entry) => !(foreign?.owns(entry) ?? false))
              .map((entry) => entry.id),
          ...extensions.discover(commandContributions).map((entry) => entry.id),
          ...extensions
              .discover(taskBrowserContributions)
              .map((entry) => entry.id),
        ]);
      });
      addTearDown(subscription.cancel);
      await install(
        'invalid',
        [
          _sessionDescriptor('not-published'),
          if (invalid == 'non-Main-Content target')
            {
              'role': 'taskBrowser',
              'extensionId': 'dev.example.target.session',
              'displayName': 'Not Main Content',
              'library': _library,
              'entrypoint': 'customPane',
            },
          if (invalid == 'missing action' || invalid == 'ambiguous target')
            _mainContentActionDescriptor('target'),
          if (invalid == 'ambiguous target')
            _mainContentActionDescriptor('target'),
          if (invalid == 'no-action target') _sessionDescriptor('target'),
        ],
        extensionDescriptors: [
          _commandDescriptor('not-published', 'voidCommand'),
          {
            ..._mainContentCommandDescriptor('target'),
            if (invalid == 'missing action') 'actionId': 'not-an-action',
          },
        ],
      );
      await owner.start(await discover());
      await Future<void>.delayed(Duration.zero);
      final generation = owner.generations.single;
      expect(generation.state, InstalledFrontendState.failed);
      expect(generation.failure, isA<StateError>());
      expect(generation.registrations, isEmpty);
      expect(publications, isEmpty);
      expect(extensions.discover(commandContributions), isEmpty);
      expect(extensions.discover(taskBrowserContributions), isEmpty);
      expect(
        extensions.discover(mainContentContributions),
        hasLength(foreign == null ? 0 : 1),
      );
      expect(foreign?.isClosed, foreign == null ? isNull : isFalse);
    });
  }

  test(
    'Main Content action cannot bind another installation with the same IDs',
    () async {
      await install('a-owner', [_mainContentActionDescriptor('target')]);
      await install(
        'b-command',
        [_sessionDescriptor('not-published')],
        extensionDescriptors: [
          _commandDescriptor('not-published', 'voidCommand'),
          _mainContentCommandDescriptor('target'),
        ],
      );
      final publications = <ExtensionId>[];
      final subscription = extensions.changes.listen((_) {
        publications.addAll([
          ...extensions.discover(commandContributions).map((entry) => entry.id),
          ...extensions
              .discover(mainContentContributions)
              .where(
                (entry) => !owner.generations.first.registrations.any(
                  (registration) => registration.owns(entry),
                ),
              )
              .map((entry) => entry.id),
        ]);
      });
      addTearDown(subscription.cancel);
      await owner.start(await discover());
      await Future<void>.delayed(Duration.zero);
      expect(owner.generations.first.state, InstalledFrontendState.active);
      expect(owner.generations.last.state, InstalledFrontendState.failed);
      expect(owner.generations.last.failure, isA<StateError>());
      expect(owner.generations.last.registrations, isEmpty);
      expect(publications, isEmpty);
      expect(extensions.discover(commandContributions), isEmpty);
      final retained = extensions.discover(mainContentContributions).single;
      expect(retained.id, ExtensionId('dev.example.target.session'));
      expect(retained.value.actions.single.id, 'open');
      expect(retained.validate, returnsNormally);
      expect(
        owner.generations.first.registrations.single.owns(retained),
        isTrue,
      );
    },
  );

  test(
    'Main Content action collision synchronously rolls back only its generation',
    () async {
      var calls = 0;
      final unrelated = extensions.register(
        point: commandContributions,
        id: ExtensionId('dev.example.conflict.registration'),
        value: CommandContribution(
          id: CommandId('dev.example.unrelated'),
          label: 'Unrelated',
          availability: () => CommandAvailability.enabled,
          invoke: () => calls++,
        ),
      );
      addTearDown(unrelated.close);
      final visibleFailedBindings = <ExtensionId>[];
      final subscription = extensions.changes.listen((_) {
        for (final generation in owner.generations) {
          if (generation.state != InstalledFrontendState.failed) continue;
          for (final binding in <ExtensionBinding<Object>>[
            ...extensions.discover(commandContributions),
            ...extensions.discover(mainContentContributions),
          ]) {
            if (generation.registrations.any((entry) => entry.owns(binding))) {
              visibleFailedBindings.add(binding.id);
            }
          }
        }
      });
      addTearDown(subscription.cancel);
      await install(
        'a-conflict',
        [
          _sessionDescriptor('rolled-back'),
          _mainContentActionDescriptor('target'),
        ],
        extensionDescriptors: [
          _mainContentCommandDescriptor('target'),
          {
            ..._mainContentCommandDescriptor('target'),
            'extensionId': 'dev.example.conflict.registration',
            'commandId': 'dev.example.conflict',
          },
        ],
      );
      await install('b-healthy', [_sessionDescriptor('healthy')]);
      await owner.start(await discover());
      await Future<void>.delayed(Duration.zero);
      final failed = owner.generations.first;
      expect(failed.state, InstalledFrontendState.failed);
      expect(failed.failure, isA<ExtensionRegistrationException>());
      expect(failed.registrations, hasLength(3));
      expect(failed.registrations.every((entry) => entry.isClosed), isTrue);
      expect(visibleFailedBindings, isEmpty);
      expect(unrelated.isClosed, isFalse);
      final retained = CommandResolver(extensions).discover().single;
      expect(unrelated.owns(retained.binding), isTrue);
      await retained.invoke();
      expect(calls, 1);
      expect(
        extensions.discover(mainContentContributions).single.id,
        ExtensionId('dev.example.healthy.session'),
      );
      expect(owner.generations.last.state, InstalledFrontendState.active);
    },
  );

  test('prepared duplicate Command IDs use ordinary ambiguity', () async {
    await install(
      'commands',
      [],
      extensionDescriptors: [
        _commandDescriptor('duplicate', 'voidCommand'),
        {
          ..._commandDescriptor('other', 'asyncCommand'),
          'commandId': 'dev.example.duplicate',
        },
      ],
    );
    await owner.start(await discover());
    final commands = CommandResolver(extensions);
    final id = CommandId('dev.example.duplicate');
    expect(owner.generations.single.state, InstalledFrontendState.active);
    expect(extensions.discover(commandContributions), hasLength(2));
    expect(commands.discover(), isEmpty);
    expect(() => commands.resolve(id), throwsA(isA<AmbiguousCommand>()));
    await owner.generations.single.retire(
      commandContributions,
      ExtensionId('dev.example.duplicate.registration'),
    );
    final remaining = commands.resolve(id);
    expect(remaining.binding.id.value, 'dev.example.other.registration');
    await remaining.invoke();
  });

  test(
    'Command registration collision rolls back its generation, not unrelated contributions',
    () async {
      var nativeCalls = 0;
      final existing = extensions.register(
        point: commandContributions,
        id: ExtensionId('dev.example.conflict.registration'),
        value: CommandContribution(
          id: CommandId('dev.example.native'),
          label: 'Unrelated native Command',
          availability: () => CommandAvailability.enabled,
          invoke: () => nativeCalls++,
        ),
      );
      addTearDown(existing.close);
      await install(
        'a-conflict',
        [_sessionDescriptor('rolled-back')],
        extensionDescriptors: [
          _commandDescriptor('rolled-back', 'voidCommand'),
          _commandDescriptor('conflict', 'asyncCommand'),
        ],
      );
      await install('b-healthy', [_sessionDescriptor('healthy')]);
      await owner.start(await discover());
      final failed = owner.generations.first;
      expect(failed.state, InstalledFrontendState.failed);
      expect(failed.failure, isA<ExtensionRegistrationException>());
      expect(failed.registrations, hasLength(2));
      expect(failed.registrations.every((value) => value.isClosed), isTrue);
      expect(existing.isClosed, isFalse);
      final retained = CommandResolver(extensions).discover().single;
      expect(retained.id, CommandId('dev.example.native'));
      await retained.invoke();
      expect(nativeCalls, 1);
      expect(
        extensions.discover(mainContentContributions).single.id.value,
        'dev.example.healthy.session',
      );
    },
  );

  for (final closeFrontend in [false, true]) {
    final retirement = closeFrontend
        ? 'frontend close'
        : 'individual retirement';
    test(
      'Command $retirement fences captured bindings and raw callbacks',
      () async {
        await install(
          'commands',
          [],
          extensionDescriptors: [
            _commandDescriptor('replace', 'voidCommand'),
            _commandDescriptor('sibling', 'asyncCommand'),
          ],
        );
        await owner.start(await discover());
        final commands = CommandResolver(extensions);
        final captured = commands.resolve(CommandId('dev.example.replace'));
        final callback = captured.binding.value.invoke;
        final availability = captured.binding.value.availability;
        final sibling = commands.resolve(CommandId('dev.example.sibling'));
        if (closeFrontend) {
          await owner.close();
          expect(commands.discover(), isEmpty);
          expect(sibling.availability, CommandAvailability.disabled);
        } else {
          await owner.generations.single.retire(
            commandContributions,
            captured.binding.id,
          );
          expect(commands.discover().map((command) => command.id), [
            sibling.id,
          ]);
          await sibling.invoke();
        }
        expect(
          captured.binding.validate,
          throwsA(isA<StaleExtensionBinding>()),
        );
        expect(captured.availability, CommandAvailability.disabled);
        expect(availability(), CommandAvailability.disabled);
        await expectLater(
          captured.invoke(),
          throwsA(isA<StaleExtensionBinding>()),
        );
        await expectLater(Future<void>.sync(callback), throwsStateError);
        await install(
          'commands',
          [],
          extensionDescriptors: [_commandDescriptor('replace', 'asyncCommand')],
        );
        final replacement = ApplicationFrontendBootstrap(
          extensions: extensions,
        );
        addTearDown(replacement.close);
        await replacement.start(await discover());
        final fresh = commands.resolve(captured.id);
        expect(fresh.binding.id, captured.binding.id);
        expect(fresh.binding.isSameRegistration(captured.binding), isFalse);
        await owner.close();
        expect(fresh.binding.validate, returnsNormally);
        expect(availability(), CommandAvailability.disabled);
        await expectLater(
          captured.invoke(),
          throwsA(isA<StaleExtensionBinding>()),
        );
        await expectLater(Future<void>.sync(callback), throwsStateError);
        await fresh.invoke();
      },
    );

    testWidgets('admitted Command completion follows $retirement semantics', (
      tester,
    ) async {
      await tester.runAsync(() async {
        await install(
          'commands',
          [],
          extensionDescriptors: [
            _commandDescriptor('delayed', 'delayedCommand'),
          ],
        );
        await owner.start(await discover());
      });
      final command = CommandResolver(extensions).discover().single;
      var settled = false;
      final outcome = expectLater(
        command.invoke(),
        closeFrontend ? throwsStateError : completes,
      ).then((_) => settled = true);
      await tester.pump(const Duration(milliseconds: 100));
      expect(settled, isFalse);
      if (closeFrontend) {
        // Closure awaits startup futures created in the real async zone.
        await tester.runAsync(owner.close);
      } else {
        await owner.generations.single.retire(
          commandContributions,
          command.binding.id,
        );
      }
      expect(command.availability, CommandAvailability.disabled);
      expect(settled, isFalse);
      await tester.pump(const Duration(seconds: 1));
      await outcome;
      expect(settled, isTrue);
    });
  }

  test(
    'partial registration failure rolls back the whole generation only',
    () async {
      final existing = extensions.register(
        point: toolActivityCompactPresentationContributions,
        id: ExtensionId('dev.example.conflict.compact'),
        value: ToolActivityCompactPresentationContribution(
          toolId: _toolId,
          createPresentation: (_) => const Text('existing'),
        ),
      );
      addTearDown(existing.close);
      await install('a-conflict', [
        _sessionDescriptor('acquired'),
        _nativeDescriptor('acquired'),
        _toolDescriptor('conflict'),
      ]);
      await install('b-healthy', [_sessionDescriptor('healthy')]);
      await owner.start(await discover());
      final failed = owner.generations.first;
      expect(failed.state, InstalledFrontendState.failed);
      expect(failed.failure, isA<ExtensionRegistrationException>());
      expect(failed.registrations, hasLength(4));
      expect(
        failed.registrations.every((registration) => registration.isClosed),
        isTrue,
      );
      expect(existing.isClosed, isFalse);
      expect(extensions.discover(toolActivityInspectionContributions), isEmpty);
      expect(
        extensions.discover(modelNativeActivityPresentationContributions),
        isEmpty,
      );
      expect(
        extensions.discover(
          modelNativeActivityCompactPresentationContributions,
        ),
        isEmpty,
      );
      expect(
        extensions.discover(mainContentContributions).single.id.value,
        'dev.example.healthy.session',
      );
    },
  );

  test(
    'Main Content operations validate without executing and retire with their owner',
    () async {
      await install('retained', [
        {
          ..._sessionDescriptor('retained'),
          'retainedData': true,
          'actions': [
            {'id': 'open', 'label': 'Open file', 'entrypoint': 'customPane'},
          ],
          // This entrypoint throws if executed. Activation only resolves it.
          'operations': {'display': 'semanticFailure'},
          'displaySourceFileOperation': 'display',
        },
      ]);
      await owner.start(await discover());
      expect(owner.generations.single.state, InstalledFrontendState.active);
      final display = extensions
          .discover(displaySourceFileContributions)
          .single;
      expect(display.validate, returnsNormally);
      await owner.generations.single.retire(
        mainContentContributions,
        ExtensionId('dev.example.retained.session'),
      );
      expect(extensions.discover(mainContentContributions), isEmpty);
      expect(extensions.discover(displaySourceFileContributions), isEmpty);
      expect(display.validate, throwsA(isA<StaleExtensionBinding>()));
    },
  );

  for (final missing in ['action', 'operation']) {
    test('missing Main Content $missing fails before registration', () async {
      await install('missing-$missing', [
        {
          ..._sessionDescriptor('missing'),
          'retainedData': true,
          if (missing == 'action')
            'actions': [
              {
                'id': 'open',
                'label': 'Open file',
                'entrypoint': 'notInArtifact',
              },
            ],
          if (missing == 'operation')
            'operations': {'display': 'notInArtifact'},
        },
      ]);
      await owner.start(await discover());
      expect(owner.generations.single.state, InstalledFrontendState.failed);
      expect(extensions.discover(mainContentContributions), isEmpty);
      expect(extensions.discover(displaySourceFileContributions), isEmpty);
    });
  }

  test(
    'retired Main Content attachments cannot migrate to replacement bindings',
    () async {
      await install('sessions', [
        _sessionDescriptor('one'),
        _sessionDescriptor('two'),
      ]);
      await owner.start(await discover());
      final generation = owner.generations.single;
      final bindings = extensions.discover(mainContentContributions);
      final factory = bindings.first.value.attach;
      await generation.retire(mainContentContributions, bindings.first.id);
      await expectLater(
        Future.sync(() => factory(_Access())),
        throwsStateError,
      );
      expect(bindings.first.validate, throwsA(isA<StaleExtensionBinding>()));
      bindings.last.validate();
      final replacement = extensions.register(
        point: mainContentContributions,
        id: bindings.first.id,
        value: MainContentContribution(order: 100, attach: (_) {}),
      );
      addTearDown(replacement.close);
      final closing = generation.close();
      expect(generation.close(), same(closing));
      await closing;
      expect(replacement.isClosed, isFalse);
      await expectLater(
        Future.sync(() => factory(_Access())),
        throwsStateError,
      );
    },
  );

  test(
    'close during byte loading drains startup without late registrations',
    () async {
      await install('first', [_sessionDescriptor('first')]);
      await install('second', [_toolDescriptor('second')]);
      final catalog = await discover();
      final starting = owner.start(catalog);
      expect(owner.state, ApplicationFrontendState.starting);
      expect(owner.generations.first.state, InstalledFrontendState.starting);
      expect(() => owner.start(catalog), throwsStateError);
      final closing = owner.close();
      expect(owner.close(), same(closing));
      await Future.wait([starting, closing]);
      expect(
        owner.generations.every(
          (generation) => generation.state == InstalledFrontendState.closed,
        ),
        isTrue,
      );
      expect(
        owner.generations.every(
          (generation) => generation.registrations.isEmpty,
        ),
        isTrue,
      );
      expect(extensions.discover(mainContentContributions), isEmpty);
      expect(extensions.discover(toolActivityInspectionContributions), isEmpty);
    },
  );

  test('close before start never opens a snapshot', () async {
    final unused = ApplicationFrontendBootstrap(extensions: extensions);
    final closing = unused.close();
    expect(unused.close(), same(closing));
    await closing;
    expect(unused.catalog, isNull);
    final catalog = await discover();
    expect(() => unused.start(catalog), throwsStateError);
  });

  test(
    'retirement distinguishes equal IDs at sibling extension points',
    () async {
      final id = ExtensionId('dev.example.shared.presentation');
      await install('shared', [
        {
          ..._toolDescriptor('shared'),
          'inspectionExtensionId': id.value,
          'compactExtensionId': id.value,
        },
      ]);
      await owner.start(await discover());
      final rich = extensions
          .discover(toolActivityInspectionContributions)
          .single;
      final compact = extensions
          .discover(toolActivityCompactPresentationContributions)
          .single;
      await owner.generations.single.retire(
        toolActivityInspectionContributions,
        id,
      );
      expect(rich.validate, throwsA(isA<StaleExtensionBinding>()));
      expect(compact.validate, returnsNormally);
      expect(
        extensions.discover(toolActivityCompactPresentationContributions),
        hasLength(1),
      );
      await owner.generations.single.retire(
        toolActivityInspectionContributions,
        id,
      );
      expect(compact.validate, returnsNormally);
    },
  );

  test(
    'stopping startup keeps active views but rejects late generations',
    () async {
      await install('a-active', [_sessionDescriptor('active')]);
      await install('b-pending', [_nativeDescriptor('pending')]);
      await install('c-pending', [_toolDescriptor('pending')]);
      final subscription = owner.changes.listen((_) {
        if (owner.generations.first.state == InstalledFrontendState.active) {
          owner.stopStarting();
        }
      });
      addTearDown(subscription.cancel);
      await owner.start(await discover());
      expect(owner.state, ApplicationFrontendState.closing);
      final binding = extensions.discover(mainContentContributions).single;
      expect(binding.validate, returnsNormally);
      expect(
        extensions.discover(modelNativeActivityPresentationContributions),
        isEmpty,
      );
      expect(extensions.discover(toolActivityInspectionContributions), isEmpty);
      await owner.close();
      expect(binding.validate, throwsA(isA<StaleExtensionBinding>()));
      expect(
        owner.generations.every(
          (value) => value.state == InstalledFrontendState.closed,
        ),
        isTrue,
      );
    },
  );

  testWidgets('descriptor entrypoints share retained bytes across all roles', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final artifact = await install('views', [
        _toolDescriptor('tool'),
        _nativeDescriptor('native'),
      ]);
      await owner.start(await discover());
      // New views still use the one captured artifact, never reread this path.
      await artifact.writeAsBytes([0, 1, 2]);
    });
    final source = _ToolSource();
    addTearDown(source.dispose);
    final native = ModelNativePresentation(
      kind: 'example.safe-kind',
      compactText: 'Native',
      data: const {'label': 'native'},
    );
    final richTool = extensions
        .discover(toolActivityInspectionContributions)
        .single
        .value;
    final compactTool = extensions
        .discover(toolActivityCompactPresentationContributions)
        .single
        .value;
    final richNative = extensions
        .discover(modelNativeActivityPresentationContributions)
        .single
        .value;
    final compactNative = extensions
        .discover(modelNativeActivityCompactPresentationContributions)
        .single
        .value;
    await tester.pumpWidget(
      MaterialApp(
        home: Column(
          children: [
            richTool.createPresentation(source),
            compactTool.createPresentation(source),
            richNative.createInspection(native),
            compactNative.createPresentation(native),
          ],
        ),
      ),
    );
    for (final label in [
      'rich tool',
      'compact tool',
      'rich native',
      'compact native',
    ]) {
      expect(find.text(label), findsOneWidget);
    }
    await owner.generations.single.retire(
      toolActivityCompactPresentationContributions,
      ExtensionId('dev.example.tool.compact'),
    );
    await owner.generations.single.retire(
      modelNativeActivityPresentationContributions,
      ExtensionId('dev.example.native.inspection'),
    );
    expect(() => compactTool.createPresentation(source), throwsStateError);
    expect(() => richNative.createInspection(native), throwsStateError);
    expect(() => richTool.createPresentation(source), returnsNormally);
    expect(() => compactNative.createPresentation(native), returnsNormally);
    await tester.runAsync(owner.close);
    await tester.pump();
    expect(find.text('Frontend unavailable.'), findsNWidgets(4));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'corrupt bytecode fails views, not activation or sibling registrations',
    (tester) async {
      await tester.runAsync(() async {
        await install(
          'corrupt',
          [_nativeDescriptor('native')],
          artifactBytes: [1, 2, 3],
        );
        await owner.start(await discover());
      });
      final generation = owner.generations.single;
      expect(generation.state, InstalledFrontendState.active);
      expect(generation.failure, isNull);
      final native = ModelNativePresentation(
        kind: 'example.safe-kind',
        compactText: 'Safe',
        data: const {},
      );
      final rich = extensions
          .discover(modelNativeActivityPresentationContributions)
          .single;
      final compact = extensions
          .discover(modelNativeActivityCompactPresentationContributions)
          .single;
      await tester.pumpWidget(
        MaterialApp(
          home: Column(
            children: [
              rich.value.createInspection(native),
              compact.value.createPresentation(native),
            ],
          ),
        ),
      );
      await tester.pump();
      expect(find.text('Frontend unavailable.'), findsNWidgets(2));
      rich.validate();
      compact.validate();
      expect(generation.failure, isNull);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}

Map<String, Object?> _sessionDescriptor(String name) => {
  'role': 'mainContent',
  'library': _library,
  'extensionId': 'dev.example.$name.session',
  'order': 100,
  'initialize': 'initializePanes',
  'entrypoint': 'customPane',
};

final class _Access implements MainContentAccess {
  @override
  Session get session => _session;
  @override
  bool get isActive => true;
  @override
  List<MainContentPaneInfo> get panes => const [];
  @override
  void open(MainContentPane pane) =>
      throw StateError('Initializer opens no panes.');
  @override
  void setTitle(String id, String title) => throw StateError('No panes.');
  @override
  void setOrder(List<String> ids) => throw StateError('No panes.');
  @override
  void remove(String id) => throw StateError('No panes.');
  @override
  void focus(String id, {bool keyboardFocus = false}) =>
      throw StateError('No panes.');
}

Map<String, Object?> _selectorDescriptor(String name, String entrypoint) => {
  'kind': 'projectSelector',
  'library': _library,
  'extensionId': 'dev.example.$name.selector',
  'displayName': 'Open prepared Project...',
  'projectProviderId': 'dev.example.project',
  'entrypoint': entrypoint,
};

Map<String, Object?> _commandDescriptor(String name, String entrypoint) =>
    PreparedCommandExtension(
      extensionId: ExtensionId('dev.example.$name.registration'),
      commandId: CommandId('dev.example.$name'),
      label: 'Prepared $name',
      library: _library,
      entrypoint: entrypoint,
    ).toJson();

Map<String, Object?> _consoleDescriptor(String name) => {
  'role': 'console',
  'extensionId': 'dev.example.$name.console',
  'library': _library,
  'entrypoint': 'customPane',
  'actions': [
    {
      'id': 'create',
      'label': 'Create Console',
      'entrypoint': 'semanticFailure',
    },
  ],
};

Map<String, Object?> _consoleCommandDescriptor(String name) =>
    PreparedConsoleActionCommandExtension(
      extensionId: ExtensionId('dev.example.$name.command'),
      commandId: CommandId('dev.example.$name'),
      consoleExtensionId: ExtensionId('dev.example.$name.console'),
      actionId: 'create',
    ).toJson();

Map<String, Object?> _mainContentActionDescriptor(String name) => {
  ..._sessionDescriptor(name),
  'actions': [
    {'id': 'open', 'label': 'Open prepared input', 'entrypoint': 'customPane'},
  ],
};

Map<String, Object?> _mainContentCommandDescriptor(String name) =>
    PreparedMainContentActionCommandExtension(
      extensionId: ExtensionId('dev.example.$name.command'),
      commandId: CommandId('dev.example.$name'),
      mainContentExtensionId: ExtensionId('dev.example.$name.session'),
      actionId: 'open',
    ).toJson();

final class _PendingPicker extends FileSelectorPlatform {
  final pending = Completer<String?>();
  int calls = 0;

  @override
  Future<String?> getDirectoryPathWithOptions(FileDialogOptions options) {
    calls++;
    return pending.future;
  }
}

Map<String, Object?> _toolDescriptor(String name) => {
  'role': 'toolActivity',
  'library': _library,
  'toolId': _toolId.value,
  'inspectionExtensionId': 'dev.example.$name.inspection',
  'compactExtensionId': 'dev.example.$name.compact',
  'inspectionEntrypoint': 'toolRich',
  'compactEntrypoint': 'toolCompact',
};

Map<String, Object?> _nativeDescriptor(String name) => {
  'role': 'modelNativeActivity',
  'library': _library,
  'presentationKind': 'example.safe-kind',
  'inspectionExtensionId': 'dev.example.$name.inspection',
  'compactExtensionId': 'dev.example.$name.compact',
  'inspectionEntrypoint': 'nativeRich',
  'compactEntrypoint': 'nativeCompact',
};

final class _ToolSource extends ChangeNotifier
    implements ToolActivityInspectionSource {
  @override
  final SessionId sessionId = SessionId('session');
  @override
  final RunId runId = RunId('run');
  @override
  final snapshot = ToolInvocationActivity(
    id: ToolInvocationId('tool'),
    preparedSequence: 2,
    modelInvocationId: ModelInvocationId('model'),
    proposalSequence: 1,
    toolId: _toolId,
    alias: 'probe',
    providerCallId: 'call',
    canonicalArguments: const {'label': 'tool'},
    changes: const [],
    outcome: null,
  );
}
