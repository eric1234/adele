import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:adele_desktop/frontend/application_frontend_bootstrap.dart';
import 'package:adele_desktop/frontend/model_native_activity_bridge.dart';
import 'package:adele_desktop/frontend/prepared_frontend.dart';
import 'package:adele_desktop/frontend/prepared_session_adapter.dart';
import 'package:adele_desktop/frontend/tool_activity_inspection_bridge.dart';
import 'package:adele_desktop/plugins/stock_chat_frontend.dart';
import 'package:adele_orchestration/adele_orchestration.dart';
import 'package:adele_plugin_api/adele_plugin_api.dart';
import 'package:adele_product/adele_product.dart';
import 'package:adele_ui/adele_ui.dart';
import 'package:dart_eval/dart_eval.dart';
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
  late _SessionAdapter adapter;
  late ApplicationFrontendBootstrap owner;
  late Uint8List bytes;

  setUpAll(() {
    final compiler = Compiler()
      ..addPlugin(flutterEvalPlugin)
      ..addPlugin(const ToolActivityInspectionDeclarations())
      ..addPlugin(const ModelNativeActivityDeclarations())
      ..entrypoints.add(_library);
    final program = compiler.compile({
      'installed_probe': {
        'main.dart': '''
import 'package:flutter/material.dart';
import 'package:adele_ui/tool_activity_inspection_bridge.dart';
import 'package:adele_ui/model_native_activity_bridge.dart';
Widget toolRich() => Text('rich ' + readToolActivitySnapshot().canonicalArguments['label']);
Widget toolCompact() => Text('compact ' + readToolActivitySnapshot().canonicalArguments['label']);
Widget nativeRich() => Text('rich ' + readModelNativeActivityData()['label']);
Widget nativeCompact() => Text('compact ' + readModelNativeActivityData()['label']);
''',
      },
      'adele_ui': {
        for (final file in [
          'tool_activity_inspection_bridge.dart',
          'model_native_activity_bridge.dart',
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
    adapter = _SessionAdapter();
    owner = ApplicationFrontendBootstrap(
      extensions: extensions,
      sessionAdapters: {'probe': adapter},
    );
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

  test('empty snapshot starts once and closes adapters once', () async {
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
    expect(adapter.closes, 1);
    expect(() => owner.start(catalog), throwsStateError);
  });

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
    'multiple descriptors retain exact metadata and shared generation',
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
        binding.value.createPresentation(_session);
      }
      expect(adapter.generations[0], same(adapter.generations[1]));
      expect(
        adapter.descriptors,
        catalog.installations.single.frontend!.presentations.take(2),
      );
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
    'read and unknown-adapter failures do not stop other installations',
    () async {
      final missing = await install('a-missing', [_toolDescriptor('missing')]);
      await install('b-unknown', [
        {..._sessionDescriptor('unknown'), 'hostAdapter': 'not-registered'},
      ]);
      await install('c-healthy', [_nativeDescriptor('healthy')]);
      final catalog = await discover();
      await missing.delete();
      await owner.start(catalog);
      expect(owner.state, ApplicationFrontendState.ready);
      expect(owner.generations.map((value) => value.state), [
        InstalledFrontendState.failed,
        InstalledFrontendState.failed,
        InstalledFrontendState.active,
      ]);
      expect(owner.generations[0].failure, isA<FileSystemException>());
      expect(owner.generations[1].failure, isA<StateError>());
      expect(extensions.discover(toolActivityInspectionContributions), isEmpty);
      expect(extensions.discover(sessionPresentationContributions), isEmpty);
      expect(
        extensions.discover(modelNativeActivityPresentationContributions),
        hasLength(1),
      );
    },
  );

  test(
    'stock Chat adapter rejects a non-Chat descriptor before registration',
    () async {
      final chat = StockChatFrontend(
        extensions: extensions,
        controllerForSession: (_) =>
            throw StateError('Must not obtain a controller'),
      );
      final chatOwner = ApplicationFrontendBootstrap(
        extensions: extensions,
        sessionAdapters: {'probe': chat},
      );
      addTearDown(chatOwner.close);
      await install('wrong-strategy', [_sessionDescriptor('wrong')]);
      await chatOwner.start(await discover());
      expect(chatOwner.generations.single.state, InstalledFrontendState.failed);
      expect(chatOwner.generations.single.failure, isA<StateError>());
      expect(extensions.discover(sessionPresentationContributions), isEmpty);
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
      factory(_session);
      bindings.last.value.createPresentation(_session);
      await generation.retire(
        sessionPresentationContributions,
        bindings.first.id,
      );
      expect(adapter.liveness.map((active) => active()), [false, true]);
      expect(() => factory(_session), throwsStateError);
      expect(bindings.first.validate, throwsA(isA<StaleExtensionBinding>()));
      bindings.last.validate();
      final replacement = extensions.register(
        point: sessionPresentationContributions,
        id: bindings.first.id,
        value: SessionPresentationContribution(
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
      expect(adapter.liveness.map((active) => active()), [false, false]);
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
      expect(adapter.closes, 1);
      expect(extensions.discover(sessionPresentationContributions), isEmpty);
      expect(extensions.discover(toolActivityInspectionContributions), isEmpty);
    },
  );

  test(
    'close before start owns each adapter once and never opens a snapshot',
    () async {
      final shared = _SessionAdapter();
      final unused = ApplicationFrontendBootstrap(
        extensions: extensions,
        sessionAdapters: {'first': shared, 'second': shared},
      );
      final closing = unused.close();
      expect(unused.close(), same(closing));
      await closing;
      expect(shared.closes, 1);
      expect(unused.catalog, isNull);
      final catalog = await discover();
      expect(() => unused.start(catalog), throwsStateError);
    },
  );

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
      expect(() => binding.value.createPresentation(_session), returnsNormally);
      expect(
        extensions.discover(modelNativeActivityPresentationContributions),
        isEmpty,
      );
      expect(extensions.discover(toolActivityInspectionContributions), isEmpty);
      expect(adapter.closes, 0);
      await owner.close();
      expect(binding.validate, throwsA(isA<StaleExtensionBinding>()));
      expect(
        owner.generations.every(
          (value) => value.state == InstalledFrontendState.closed,
        ),
        isTrue,
      );
      expect(adapter.closes, 1);
    },
  );

  test(
    'adapter cleanup attempts siblings and retains idempotent failure',
    () async {
      final failing = _SessionAdapter()..failClose = true;
      final sibling = _SessionAdapter();
      final closingOwner = ApplicationFrontendBootstrap(
        extensions: extensions,
        sessionAdapters: {'failing': failing, 'sibling': sibling},
      );
      final closing = closingOwner.close();
      await expectLater(closing, throwsStateError);
      expect(closingOwner.state, ApplicationFrontendState.closed);
      expect(closingOwner.close(), same(closing));
      expect(failing.closes, 1);
      expect(sibling.closes, 1);
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
  'hostAdapter': 'probe',
};

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

final class _SessionAdapter implements PreparedSessionAdapter {
  final generations = <PreparedFrontend>[];
  final descriptors = <PreparedSessionPresentation>[];
  final liveness = <bool Function()>[];
  int closes = 0;
  bool failClose = false;

  @override
  void validate(PreparedSessionPresentation descriptor) {}

  @override
  Widget createPresentation({
    required PreparedFrontend generation,
    required PreparedSessionPresentation descriptor,
    required Session session,
    required bool Function() isActive,
  }) {
    generations.add(generation);
    descriptors.add(descriptor);
    liveness.add(isActive);
    return Text(descriptor.entrypoint);
  }

  @override
  Future<void> close() async {
    closes++;
    if (failClose) throw StateError('adapter cleanup failed');
  }
}

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
