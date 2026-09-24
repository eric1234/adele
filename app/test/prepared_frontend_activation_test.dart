import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:adele_capabilities/adele_capabilities.dart';
import 'package:adele_core_extensions/adele_core_extensions.dart';
import 'package:adele_desktop/core/application_plugin_bootstrap.dart';
import 'package:adele_desktop/frontend/application_frontend_bootstrap.dart';
import 'package:adele_desktop/frontend/directory_picker_bridge.dart';
import 'package:adele_desktop/frontend/model_native_activity_bridge.dart';
import 'package:adele_desktop/frontend/prepared_session_host.dart';
import 'package:adele_desktop/frontend/tool_activity_inspection_bridge.dart';
import 'package:adele_orchestration/adele_orchestration.dart';
import 'package:adele_plugin_api/adele_plugin_api.dart';
import 'package:adele_product/adele_product.dart';
import 'package:adele_ui/adele_ui.dart';
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
      ..entrypoints.add(_library);
    final program = compiler.compile({
      'installed_probe': {
        'main.dart': '''
import 'package:flutter/material.dart';
import 'package:adele_ui/tool_activity_inspection_bridge.dart';
import 'package:adele_ui/model_native_activity_bridge.dart';
import 'package:adele_ui/directory_picker_bridge.dart';
Widget toolRich() => Text('rich ' + readToolActivitySnapshot().canonicalArguments['label']);
Widget toolCompact() => Text('compact ' + readToolActivitySnapshot().canonicalArguments['label']);
Widget nativeRich() => Text('rich ' + readModelNativeActivityData()['label']);
Widget nativeCompact() => Text('compact ' + readModelNativeActivityData()['label']);
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
''',
      },
      'adele_ui': {
        for (final file in [
          'tool_activity_inspection_bridge.dart',
          'model_native_activity_bridge.dart',
          'directory_picker_bridge.dart',
        ])
          file: File(
            '${Directory.current.parent.path}/packages/ui/lib/$file',
          ).readAsStringSync(),
      },
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
      'Session $affinity metadata activates independently of its backend',
      () async {
        await owner.close();
        final backends = ApplicationPluginBootstrap(
          CapabilityRegistry(),
          extensions,
        );
        addTearDown(backends.close);
        final host = PreparedSessionHost(
          extensions: extensions,
          backends: backends,
          controllerForSession: (_) =>
              throw StateError('Activation cannot obtain execution.'),
          inspectActivity: (_, _) => false,
        );
        owner = ApplicationFrontendBootstrap(
          extensions: extensions,
          sessionHost: host,
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
          {..._sessionDescriptor('session'), 'strategyAffinity': affinity},
        ]);
        await owner.start(await discover());
        expect(owner.generations.single.state, InstalledFrontendState.active);
        final presentation = extensions
            .discover(sessionPresentationContributions)
            .single;
        if (affinity == 'independent') {
          final choice = host.resolve(presentation);
          expect(choice.pinStrategy, isFalse);
          expect(choice.backend, isNull);
          expect(choice.strategy.strategyId, _strategyId);
        } else {
          expect(() => host.resolve(presentation), throwsStateError);
        }
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
      final sessions = extensions.discover(sessionPresentationContributions);
      expect(sessions.map((binding) => binding.id.value), [
        'dev.example.one.session',
        'dev.example.two.session',
      ]);
      for (final binding in sessions) {
        expect(binding.value.strategyId, _strategyId);
        expect(binding.value.displayName, 'Prepared Session');
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
      expect(
        extensions.discover(sessionPresentationContributions),
        hasLength(1),
      );
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
      expect(
        extensions.discover(sessionPresentationContributions),
        hasLength(1),
      );
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
      expect(extensions.discover(sessionPresentationContributions), isEmpty);
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
        extensions.discover(sessionPresentationContributions).single.id.value,
        'dev.example.healthy.session',
      );
    },
  );

  test(
    'retired Session factories cannot migrate to replacement bindings',
    () async {
      await install('sessions', [
        _sessionDescriptor('one'),
        _sessionDescriptor('two'),
      ]);
      await owner.start(await discover());
      final generation = owner.generations.single;
      final bindings = extensions.discover(sessionPresentationContributions);
      final factory = bindings.first.value.createPresentation;
      await generation.retire(
        sessionPresentationContributions,
        bindings.first.id,
      );
      expect(() => factory(_session), throwsStateError);
      expect(bindings.first.validate, throwsA(isA<StaleExtensionBinding>()));
      bindings.last.validate();
      final replacement = extensions.register(
        point: sessionPresentationContributions,
        id: bindings.first.id,
        value: SessionPresentationContribution(
          displayName: 'Replacement',
          strategyId: _strategyId,
          createPresentation: (_) => const Text('replacement'),
        ),
      );
      addTearDown(replacement.close);
      final closing = generation.close();
      expect(generation.close(), same(closing));
      await closing;
      expect(replacement.isClosed, isFalse);
      expect(() => factory(_session), throwsStateError);
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
      expect(extensions.discover(sessionPresentationContributions), isEmpty);
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
      final binding = extensions
          .discover(sessionPresentationContributions)
          .single;
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
  'role': 'session',
  'library': _library,
  'extensionId': 'dev.example.$name.session',
  'strategyId': _strategyId.value,
  'entrypoint': 'customSession',
  'displayName': 'Prepared Session',
};

Map<String, Object?> _selectorDescriptor(String name, String entrypoint) => {
  'kind': 'projectSelector',
  'library': _library,
  'extensionId': 'dev.example.$name.selector',
  'displayName': 'Open prepared Project...',
  'projectProviderId': 'dev.example.project',
  'entrypoint': entrypoint,
};

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
