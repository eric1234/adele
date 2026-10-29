import 'dart:convert';
import 'dart:io';

import 'package:adele_capabilities/adele_capabilities.dart';
import 'package:adele_desktop/core/adele_runtime.dart';
import 'package:adele_desktop/core/application_plugin_bootstrap.dart';
import 'package:adele_desktop/editor/native_rich_document_editor.dart';
import 'package:adele_desktop/frontend/main_content_bridge.dart';
import 'package:adele_desktop/frontend/owning_backend_bridge.dart';
import 'package:adele_desktop/frontend/prepared_frontend.dart';
import 'package:adele_desktop/frontend/prepared_main_content_host.dart';
import 'package:adele_desktop/frontend/prepared_session_services.dart';
import 'package:adele_desktop/frontend/rich_document_editor_bridge.dart';
import 'package:adele_desktop/frontend/session_execution_bridge.dart';
import 'package:adele_desktop/frontend/session_presentation_lifecycle_bridge.dart';
import 'package:adele_desktop/frontend/structured_bridge_data.dart';
import 'package:adele_desktop/ui/execution/run_execution_status.dart';
import 'package:adele_desktop/ui/execution/session_execution_controller.dart';
import 'package:adele_desktop/ui/main_content/main_content_host.dart';
import 'package:adele_orchestration/adele_orchestration.dart';
import 'package:adele_plugin_api/adele_plugin_api.dart';
import 'package:adele_product/adele_product.dart';
import 'package:adele_ui/adele_ui.dart';
import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:contract_codegen/contract_codegen.dart';
import 'package:dart_eval/dart_eval.dart';
import 'package:dart_eval/stdlib/core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_eval/flutter_eval.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plugin_runtime/plugin_runtime.dart';

const _library = 'package:session_probe/main.dart';

// Only the transport peer is synthetic; bootstrap, ownership and EVC are real.
const _hostScript = r'''
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
void send(Map<String, Object?> message) {
  final bytes = utf8.encode(jsonEncode({'protocolVersion': 1, ...message}));
  final length = ByteData(4)..setUint32(0, bytes.length);
  stdout.add([...length.buffer.asUint8List(), ...bytes]);
}
void main() {
  send({'kind': 'hostHello'});
  var buffer = <int>[];
  var effects = 0;
  Map<String, Object?>? held;
  stdin.listen((bytes) {
    buffer.addAll(bytes);
    while (buffer.length >= 4) {
      final length = ByteData.sublistView(Uint8List.fromList(buffer), 0, 4).getUint32(0);
      if (buffer.length < length + 4) break;
      final message = jsonDecode(utf8.decode(buffer.sublist(4, 4 + length))) as Map<String, dynamic>;
      buffer = buffer.sublist(4 + length);
      final route = {'requestId': message['requestId'], 'pluginId': message['pluginId'], 'generation': message['generation']};
      switch (message['kind']) {
        case 'startPlugin':
          effects = 0;
          if ((message['arguments'] as List).contains('fail')) {
            send({'kind': 'pluginFailed', ...route, 'error': {'code': 'startup_failed', 'message': 'private startup failure'}});
          } else {
            send({'kind': 'pluginReady', ...route});
          }
        case 'stopPlugin':
          send({'kind': 'pluginStopped', ...route});
        case 'request':
          if (message['serviceId'] != 'fixture.optional' || message['method'] == 'fail') {
            send({'kind': 'response', ...route, 'ok': false, 'error': {'code': 'service_unavailable', 'message': 'private fixture error'}});
          } else if (message['method'] == 'effect') {
            effects++;
            held = route;
          } else {
            if (message['method'] == 'release' && held != null) {
              send({'kind': 'response', ...held!, 'ok': true, 'payload': effects});
              held = null;
            }
            send({'kind': 'response', ...route, 'ok': true, 'payload': {'context': message['configurationContext'], 'effects': effects}});
          }
        case 'shutdownHost':
          send({'kind': 'hostStopped', 'requestId': message['requestId']});
          exit(0);
      }
    }
  });
}
''';

void main() {
  late Directory temporary;
  late File artifact;
  late PreparedFrontend generation;
  late Program program;
  setUpAll(() async {
    final compiler = Compiler()
      ..addPlugin(flutterEvalPlugin)
      ..addPlugin(const MainContentDeclarations())
      ..addPlugin(const OwningBackendDeclarations())
      ..addPlugin(const SessionExecutionDeclarations())
      ..addPlugin(const SessionPresentationLifecycleDeclarations())
      ..addPlugin(const RichDocumentEditorDeclarations())
      ..entrypoints.add(_library);
    program = compiler.compile({
      'session_probe': {
        'main.dart': '''
import 'package:flutter/material.dart';
import 'package:adele_ui/main_content_bridge.dart';
import 'package:adele_ui/owning_backend_bridge.dart';
import 'package:adele_ui/session_execution_bridge.dart';
import 'package:adele_ui/session_presentation_lifecycle_bridge.dart';
import 'package:adele_ui/rich_document_editor_bridge.dart';
bool ready = false;
void initialize() {
  openMainContentPane('a', 'A', true);
  openMainContentPane('b', 'B', true);
}
Future<bool> prepare() async {
  await Future.delayed(Duration(milliseconds: 10));
  return ready;
}
Widget buildView() {
  registerSessionPrepareToDeactivate(prepare);
  return TextButton(onPressed: () {
    currentSessionId();
    ready = true;
  }, child: Text('Acknowledge ' + readMainContentPaneId()));
}
Widget withoutHook() => Column(children: [
  Text('No pending state ' + readMainContentPaneId()),
  TextButton(onPressed: () { openSessionRunActivity('missing'); },
    child: Text('Open activity')),
  buildSessionExecutionStatus(),
]);
Widget richEditor() {
  subscribeSessionExecution(() {});
  final handle = createRichDocumentEditor('Draft ' + readMainContentPaneId(), false);
  return SizedBox(height: 240, child: buildRichDocumentEditor(handle));
}
Widget lifecycleOnly() {
  registerSessionPrepareToDeactivate(prepare);
  return TextButton(onPressed: () { ready = true; },
    child: Text('Acknowledge ' + readMainContentPaneId()));
}
Future<List<dynamic>> query(String service, String method) =>
  settleOwningBackendOperation(requestOwningBackend(service, method, <String, dynamic>{}));
Widget optionalBackend() => OptionalBackendProbe();
class OptionalBackendProbe extends StatefulWidget {
  @override
  State<OptionalBackendProbe> createState() => OptionalBackendState();
}
class OptionalBackendState extends State<OptionalBackendProbe> {
  String status = 'idle';
  bool disposed = false;
  void read() async {
    final result = await query('fixture.optional', 'read');
    if (disposed) return;
    setState(() { status = result[0] == true ? 'available' : 'unavailable'; });
  }
  @override
  void dispose() { disposed = true; super.dispose(); }
  @override
  Widget build(BuildContext context) => Column(children: [
    Text('Optional ' + readMainContentPaneId() + ' ' + status),
    TextButton(onPressed: read, child: Text('Read optional ' + readMainContentPaneId())),
  ]);
}
''',
      },
      'adele_ui': {
        for (final name in [
          'main_content_bridge.dart',
          'owning_backend_bridge.dart',
          'session_execution_bridge.dart',
          'session_presentation_lifecycle_bridge.dart',
          'rich_document_editor_bridge.dart',
        ])
          name: File('../packages/ui/lib/$name').readAsStringSync(),
      },
      'adele_contract': {'adele_contract.dart': evalContractSupportSource},
    });
    temporary = await Directory.systemTemp.createTemp(
      'adele-session-services-',
    );
    artifact = await File(
      '${temporary.path}/probe.evc',
    ).writeAsBytes(program.write());
  });
  tearDownAll(() => temporary.delete(recursive: true));
  setUp(() async {
    generation = await PreparedFrontend.load(artifact);
    addTearDown(generation.invalidate);
  });

  var backendSequence = 0;
  Future<PreparedPluginInstallation> startBackend(
    AdeleRuntime runtime, {
    bool fail = false,
  }) async {
    final root = await Directory(
      '${temporary.path}/backend-${backendSequence++}',
    ).create();
    final directory = await Directory('${root.path}/plugin').create();
    await File('${directory.path}/backend.aot').writeAsString('fixture');
    final script = await File(
      '${root.path}/host.dart',
    ).writeAsString(_hostScript);
    await File(
      '${directory.path}/adele_plugin.installation.json',
    ).writeAsString(
      jsonEncode({
        'manifestVersion': 1,
        'metadata': {
          'id': 'dev.example.optional',
          'version': 'test',
          'displayName': 'Optional services',
        },
        'components': {
          'backend': {'artifact': 'backend.aot'},
        },
      }),
    );
    await runtime.plugins.start(
      installationRoot: root.path,
      dartaotruntimeExecutable:
          '${Platform.environment['FLUTTER_ROOT']}/bin/cache/dart-sdk/bin/dart',
      hostArtifactPath: script.path,
      startupArguments: {
        'dev.example.optional': [if (fail) 'fail'],
      },
    );
    return runtime.plugins.catalog!.installations.single;
  }

  for (final mode in ['no binder', 'missing', 'failed']) {
    testWidgets('optional backend $mode keeps the pane available', (
      tester,
    ) async {
      final runtime = AdeleRuntime();
      addTearDown(() => tester.runAsync(runtime.close));
      final session = Session(
        id: SessionId('optional'),
        taskId: TaskId('task'),
        strategyId: OrchestrationStrategyId('dev.missing.strategy'),
      );
      final installation = mode == 'failed'
          ? (await tester.runAsync(() => startBackend(runtime, fail: true)))!
          : PreparedPluginInstallation(
              metadata: PluginMetadata(
                id: PluginId('dev.example.optional'),
                version: 'test',
                displayName: 'Optional services',
              ),
              installationDirectory: temporary,
              backendArtifactUri: null,
            );
      if (mode == 'failed') {
        expect(runtime.plugins.state, ApplicationPluginState.ready);
        expect(
          runtime.plugins.backends.single.state,
          InstalledBackendState.failed,
        );
      }
      final services = PreparedSessionServices(
        extensions: runtime.extensions,
        backends: runtime.plugins,
        controllerForSession: (_, _) => throw StateError('No execution grant.'),
        inspectActivity: (_, _) => false,
        isCurrent: (value) => identical(value, session),
      );
      final host = PreparedMainContentHost();
      addTearDown(host.close);
      final descriptor = PreparedMainContentPresentation(
        extensionId: ExtensionId('dev.example.optional-pane'),
        order: 100,
        library: _library,
        initialize: 'initialize',
        entrypoint: 'optionalBackend',
        optionalBackendServices: ['fixture.optional'],
      );
      final contribution = host.createContribution(
        extensions: runtime.extensions,
        installation: installation,
        generation: generation,
        descriptor: descriptor,
        services: mode == 'no binder' ? null : services,
        isActive: () => true,
      );
      final registration = runtime.extensions.register(
        point: mainContentContributions,
        id: descriptor.extensionId,
        value: contribution,
      );
      addTearDown(registration.close);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: MainContentHost(
              session: session,
              extensions: runtime.extensions,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Optional a idle'), findsOneWidget);
      await tester.tap(find.text('Read optional a'));
      await tester.pumpAndSettle();
      expect(find.text('Optional a unavailable'), findsOneWidget);
      expect(find.text('Frontend unavailable.'), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
      expect(tester.takeException(), isNull);

      // The additive optional declaration must not weaken the existing grant.
      services.registerMetadata(
        contribution,
        installation,
        PreparedMainContentPresentation(
          extensionId: descriptor.extensionId,
          order: 100,
          library: _library,
          initialize: 'initialize',
          entrypoint: 'optionalBackend',
          backendServices: ['fixture.required'],
          optionalBackendServices: ['fixture.optional'],
        ),
      );
      expect(
        () => services.bind(
          runtime.extensions.discover(mainContentContributions).single,
          session: session,
          isActive: () => true,
        ),
        throwsStateError,
      );
    });
  }

  test(
    'optional services capture exact installation, context and generation',
    () async {
      final runtime = AdeleRuntime();
      addTearDown(runtime.close);
      final installation = await startBackend(runtime);
      final backend = runtime.plugins.backendForInstallation(installation)!;
      final session = Session(
        id: SessionId('optional'),
        taskId: TaskId('task'),
        strategyId: OrchestrationStrategyId('dev.missing.strategy'),
      );
      var live = true;
      final services = PreparedSessionServices(
        extensions: runtime.extensions,
        backends: runtime.plugins,
        controllerForSession: (_, _) => throw StateError('No execution grant.'),
        inspectActivity: (_, _) => false,
        isCurrent: (value) => identical(value, session),
      );
      final bridges = <PreparedFrontendBridge>[];
      Runtime bind(PreparedPluginInstallation owner) {
        final descriptor = PreparedMainContentPresentation(
          extensionId: ExtensionId(
            'dev.example.optional-pane.p${backendSequence++}',
          ),
          order: 100,
          library: _library,
          initialize: 'initialize',
          entrypoint: 'optionalBackend',
          optionalBackendServices: ['fixture.optional', 'fixture.missing'],
        );
        final contribution = MainContentContribution(
          order: 100,
          attach: (_) {},
        );
        final registration = runtime.extensions.register(
          point: mainContentContributions,
          id: descriptor.extensionId,
          value: contribution,
        );
        addTearDown(registration.close);
        services.registerMetadata(contribution, owner, descriptor);
        final bridge = services.bind(
          runtime.extensions
              .discover(mainContentContributions)
              .singleWhere((view) => view.id == descriptor.extensionId),
          session: session,
          isActive: () => live,
        );
        addTearDown(bridge.invalidate);
        bridges.add(bridge);
        return Runtime.ofProgram(program)..addPlugin(bridge);
      }

      Future<Object?> query(
        Runtime eval,
        String method, {
        String service = 'fixture.optional',
      }) async => copyStructuredBridgeData(
        await (eval.executeLib(_library, 'query', [
                  $String(service),
                  $String(method),
                ])
                as $Future)
            .$value,
      );

      final eval = bind(installation);
      expect(await query(eval, 'read'), [
        true,
        {'context': 'default', 'effects': 0},
      ]);
      expect(await query(eval, 'read', service: 'fixture.undeclared'), [
        false,
        null,
      ]);
      expect(await query(eval, 'read', service: 'fixture.missing'), [
        false,
        null,
      ]);
      expect(await query(eval, 'fail'), [false, null]);
      final foreign = bind(
        PreparedPluginInstallation(
          metadata: installation.metadata,
          installationDirectory: installation.installationDirectory,
          backendArtifactUri: installation.backendArtifactUri,
        ),
      );
      expect(await query(foreign, 'read'), [false, null]);
      expect(await query(eval, 'read'), [
        true,
        {'context': 'default', 'effects': 0},
      ]);

      final pending = query(eval, 'effect');
      final control = backend.connection!.channelFor(
        backend.connection!.defaultConfigurationContext,
        'fixture.optional',
      );
      expect((await control.request('read', {}))! as Map, {
        'context': 'default',
        'effects': 1,
      });
      live = false;
      bridges.first.invalidate();
      await control.request('release', {});
      expect(await pending, [false, null]);
      expect(await query(eval, 'effect'), [false, null]);
      expect(
        (await control.request('read', {}))! as Map,
        {'context': 'default', 'effects': 1},
        reason:
            'Retirement fences publication and new calls, not admitted effects.',
      );
      live = true;
      expect(await query(eval, 'read'), [false, null]);
      final fresh = bind(installation);
      expect(await query(fresh, 'read'), [
        true,
        {'context': 'default', 'effects': 1},
      ]);

      final interrupted = query(fresh, 'effect');
      expect(await control.request('read', {}), {
        'context': 'default',
        'effects': 2,
      });
      await backend.connection!.close();
      expect(await interrupted, [false, null]);
      expect(await query(fresh, 'read'), [false, null]);
      final replacement = await runtime.plugins.host!.startPlugin(
        pluginId: installation.metadata.id.value,
        artifactUri: installation.backendArtifactUri!,
      );
      addTearDown(replacement.close);
      final replacementChannel = replacement.channelFor(
        replacement.defaultConfigurationContext,
        'fixture.optional',
      );
      expect(await query(eval, 'effect'), [false, null]);
      expect(await query(fresh, 'effect'), [false, null]);
      expect(await query(foreign, 'effect'), [false, null]);
      expect(await replacementChannel.request('read', {}), {
        'context': 'default',
        'effects': 0,
      });
    },
  );

  for (final mode in ['without hook', 'hook', 'rich editor retirement']) {
    final hook = mode == 'hook';
    final rich = mode == 'rich editor retirement';
    testWidgets(
      'per-pane services revoke exact views, not execution; mode=$mode',
      (tester) async {
        final runtime = AdeleRuntime();
        addTearDown(runtime.close);
        final strategyId = OrchestrationStrategyId('dev.example.strategy');
        final strategy = runtime.extensions.register(
          point: orchestrationStrategyContributions,
          id: ExtensionId('dev.example.strategy'),
          value: OrchestrationStrategyContribution(
            strategyId: strategyId,
            materialize: (_) => throw StateError('No Run should start.'),
          ),
        );
        addTearDown(strategy.close);
        final project = runtime.lifecycle.createProject(
          Uri.parse('file:///fixture/'),
        );
        final task = Task(
          id: TaskId('task'),
          projectId: project.id,
          title: 'Fixture',
        );
        runtime.store.publishTaskWithPrimaryEnvironment(
          task,
          Environment(
            id: EnvironmentId('environment'),
            taskId: task.id,
            role: EnvironmentRole.primary,
            providerId: ProviderId('dev.example.environment'),
            providerState: const {},
          ),
        );
        final session = runtime.lifecycle.createSession(
          taskId: task.id,
          strategyId: strategyId,
        );
        SessionExecutionController? controller;
        var allocations = 0;
        final services = PreparedSessionServices(
          extensions: runtime.extensions,
          backends: runtime.plugins,
          controllerForSession: (canonical, pin) {
            allocations++;
            expect(canonical, same(session));
            expect(
              pin,
              isNull,
              reason: 'Independent services do not impose a pin.',
            );
            return controller = SessionExecutionController(
              runtime: runtime,
              session: canonical,
              providerId: ProviderId('dev.example.model'),
              model: null,
              // Model a core owner already pinned independently of its frontend.
              strategy: OrchestrationStrategyResolver(
                runtime.extensions,
              ).resolve(strategyId),
            );
          },
          lookupControllerForSession: (_) => controller,
          inspectActivity: (_, _) => false,
          isCurrent: (_) => true,
        );
        addTearDown(() async => controller?.close());
        final host = PreparedMainContentHost();
        addTearDown(host.close);
        final descriptor = PreparedMainContentPresentation(
          extensionId: ExtensionId('dev.example.presentation'),
          order: 100,
          library: _library,
          initialize: 'initialize',
          entrypoint: rich
              ? 'richEditor'
              : hook
              ? 'buildView'
              : 'withoutHook',
          sessionExecution: true,
          richDocumentEditor: rich,
        );
        final installation = PreparedPluginInstallation(
          metadata: PluginMetadata(
            id: PluginId('dev.example.plugin'),
            version: '1',
            displayName: 'Fixture',
          ),
          installationDirectory: temporary,
          backendArtifactUri: null,
        );
        final contribution = host.createContribution(
          extensions: runtime.extensions,
          installation: installation,
          generation: generation,
          descriptor: descriptor,
          services: services,
          isActive: () => true,
        );
        final registration = runtime.extensions.register(
          point: mainContentContributions,
          id: descriptor.extensionId,
          value: contribution,
        );
        addTearDown(registration.close);
        Widget mount() => MaterialApp(
          home: Scaffold(
            body: MainContentHost(
              key: UniqueKey(),
              session: session,
              extensions: runtime.extensions,
            ),
          ),
        );
        await host.prepareToDeactivate(session);
        expect(allocations, 0);
        await tester.pumpWidget(mount());
        await tester.pumpAndSettle();
        expect(allocations, 1);
        if (!hook && !rich) {
          expect(find.byType(RunExecutionStatus), findsNWidgets(2));
          expect(
            tester
                .widgetList<RunExecutionStatus>(find.byType(RunExecutionStatus))
                .every((status) => !status.enabled),
            isTrue,
          );
        }
        final execution = controller!;
        if (rich) {
          final owners = tester
              .widgetList<NativeRichDocumentEditorView>(
                find.byType(NativeRichDocumentEditorView),
              )
              .map((view) => view.editor)
              .toList();
          expect(owners, hasLength(2));
          await tester.tapAt(
            tester.getCenter(find.text('Draft a', findRichText: true)),
          );
          await tester.pumpAndSettle();
          final state = tester
              .widget<AppFlowyEditor>(find.byType(AppFlowyEditor).first)
              .editorState;
          state.selection = Selection.single(path: [0], startOffset: 7);
          await tester.pumpAndSettle();
          expect(tester.testTextInput.hasAnyClients, isTrue);
          expect(owners.every((owner) => owner.editingEnabled), isTrue);

          // Match the application's extension-change execution refresh. Neither
          // the frontend nor its Main Content registration is being retired.
          await strategy.close();
          execution.refresh();
          expect(
            runtime.extensions.discover(mainContentContributions).single.value,
            same(contribution),
          );
          expect(owners.every((owner) => owner.isDisposed), isTrue);
          expect(tester.testTextInput.hasAnyClients, isFalse);
          await tester.pumpAndSettle();
          expect(state.isDisposed, isTrue);
          expect(find.text('Frontend unavailable.'), findsNWidgets(2));
          expect(execution.isClosed, isFalse);

          final replacement = runtime.extensions.register(
            point: orchestrationStrategyContributions,
            id: ExtensionId('dev.example.strategy'),
            value: OrchestrationStrategyContribution(
              strategyId: strategyId,
              materialize: (_) => throw StateError('Must not retarget.'),
            ),
          );
          addTearDown(replacement.close);
          execution.refresh();
          await tester.pumpAndSettle();
          expect(find.byType(NativeRichDocumentEditorView), findsNothing);
          expect(find.text('Frontend unavailable.'), findsNWidgets(2));
          expect(tester.testTextInput.hasAnyClients, isFalse);
          await tester.pumpWidget(const SizedBox.shrink());
          expect(tester.takeException(), isNull);
          return;
        }
        final view = runtime.extensions
            .discover(mainContentContributions)
            .single;
        expect(
          () => services.bind(
            view,
            session: Session(
              id: session.id,
              taskId: session.taskId,
              strategyId: session.strategyId,
            ),
            isActive: () => true,
          ),
          throwsStateError,
        );
        final foreign = ExtensionRegistry()
          ..register(
            point: mainContentContributions,
            id: view.id,
            value: view.value,
          );
        expect(
          () => services.bind(
            foreign.discover(mainContentContributions).single,
            session: session,
            isActive: () => true,
          ),
          throwsStateError,
        );

        VoidCallback? oldAction;
        Future<void>? interrupted;
        if (hook) {
          Future<void> settle({bool rejected = false}) async {
            final pending = host.prepareToDeactivate(session);
            final checked = rejected
                ? expectLater(pending, throwsStateError)
                : pending;
            await tester.pump(const Duration(milliseconds: 10));
            await tester.pump(const Duration(milliseconds: 10));
            await checked;
          }

          await settle(rejected: true);
          oldAction = tester
              .widget<TextButton>(
                find.widgetWithText(TextButton, 'Acknowledge a'),
              )
              .onPressed!;
          oldAction();
          // A's accepted hook cannot hide B's still-pending state.
          await settle(rejected: true);
          await tester.tap(find.text('Acknowledge b'));
          await settle();
          final changed = expectLater(
            host.prepareToDeactivate(session),
            throwsStateError,
          );
          final addedDescriptor = PreparedMainContentPresentation(
            extensionId: ExtensionId('dev.example.later'),
            order: 200,
            library: _library,
            initialize: 'initialize',
            entrypoint: 'lifecycleOnly',
          );
          final added = runtime.extensions.register(
            point: mainContentContributions,
            id: addedDescriptor.extensionId,
            value: host.createContribution(
              extensions: runtime.extensions,
              installation: installation,
              generation: generation,
              descriptor: addedDescriptor,
              isActive: () => true,
            ),
          );
          // New actual presentations must not evade an in-flight departure.
          await tester.pump();
          await tester.pump();
          expect(find.text('Acknowledge a'), findsNWidgets(2));
          await tester.pumpAndSettle();
          await changed;
          await added.close();
          await tester.pumpAndSettle();
          await settle();
          interrupted = expectLater(
            host.prepareToDeactivate(session),
            throwsStateError,
          );
        } else {
          await host.prepareToDeactivate(session);
        }
        host.unbind(session);
        expect(execution.isClosed, isFalse);
        if (oldAction != null) expect(oldAction, throwsA(anything));
        await tester.pumpWidget(mount());
        await tester.pumpAndSettle();
        if (interrupted != null) await interrupted;
        expect(controller, same(execution));
        expect(allocations, 1);
        if (hook) {
          final rejected = expectLater(
            host.prepareToDeactivate(session),
            throwsStateError,
          );
          await tester.pump(const Duration(milliseconds: 10));
          await rejected;
          await tester.tap(find.text('Acknowledge a'));
          await tester.tap(find.text('Acknowledge b'));
          final accepted = host.prepareToDeactivate(session);
          await tester.pump(const Duration(milliseconds: 10));
          await tester.pump(const Duration(milliseconds: 10));
          await accepted;
        } else {
          final openActivity = tester
              .widget<TextButton>(
                find.widgetWithText(TextButton, 'Open activity').first,
              )
              .onPressed!;
          final display = tester.element(find.text('No pending state a'));
          expect(generation.retainPresentations, returnsNormally);
          expect(openActivity, throwsA(anything));
          await tester.runAsync(() async {
            await execution.close();
            await host.close();
          });
          await tester.pump();
          expect(
            tester.element(find.text('No pending state a')),
            same(display),
          );
          expect(find.byType(RunExecutionStatus), findsNWidgets(2));
          expect(find.text('Frontend unavailable.'), findsNothing);
          await tester.pumpWidget(const SizedBox.shrink());
          expect(tester.takeException(), isNull);
          return;
        }
        await tester.pumpWidget(const SizedBox.shrink());
        await host.prepareToDeactivate(session);
        await registration.close();
        expect(
          () => services.bind(view, session: session, isActive: () => true),
          throwsA(isA<StaleExtensionBinding>()),
        );
        expect(execution.capturedStrategy!.validateBinding, returnsNormally);
        final freshRegistration = runtime.extensions.register(
          point: mainContentContributions,
          id: descriptor.extensionId,
          value: contribution,
        );
        addTearDown(freshRegistration.close);
        final fresh = runtime.extensions
            .discover(mainContentContributions)
            .single;
        services
            .bind(fresh, session: session, isActive: () => true)
            .invalidate();
        await strategy.close();
        final replacement = runtime.extensions.register(
          point: orchestrationStrategyContributions,
          id: ExtensionId('dev.example.strategy'),
          value: OrchestrationStrategyContribution(
            strategyId: strategyId,
            materialize: (_) =>
                throw StateError('Must not substitute a new backend.'),
          ),
        );
        addTearDown(replacement.close);
        expect(
          () => services.bind(fresh, session: session, isActive: () => true),
          throwsA(isA<StaleExtensionBinding>()),
        );
        expect(execution.isClosed, isFalse);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'lifecycle hooks require neither execution services nor a strategy',
    (tester) async {
      final extensions = ExtensionRegistry();
      final session = Session(
        id: SessionId('offline'),
        taskId: TaskId('task'),
        strategyId: OrchestrationStrategyId('dev.missing.strategy'),
      );
      final host = PreparedMainContentHost();
      addTearDown(host.close);
      final descriptor = PreparedMainContentPresentation(
        extensionId: ExtensionId('dev.example.lifecycle'),
        order: 100,
        library: _library,
        initialize: 'initialize',
        entrypoint: 'lifecycleOnly',
      );
      final registration = extensions.register(
        point: mainContentContributions,
        id: descriptor.extensionId,
        value: host.createContribution(
          extensions: extensions,
          installation: PreparedPluginInstallation(
            metadata: PluginMetadata(
              id: PluginId('dev.example.plugin'),
              version: '1',
              displayName: 'Fixture',
            ),
            installationDirectory: temporary,
            backendArtifactUri: null,
          ),
          generation: generation,
          descriptor: descriptor,
          isActive: () => true,
        ),
      );
      addTearDown(registration.close);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: MainContentHost(session: session, extensions: extensions),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final rejected = expectLater(
        host.prepareToDeactivate(session),
        throwsStateError,
      );
      await tester.pump(const Duration(milliseconds: 10));
      await rejected;
      await tester.tap(find.text('Acknowledge a'));
      await tester.tap(find.byTooltip('Close B'));
      // Closing the unsettled pane removes its hook before a rebuild.
      final accepted = host.prepareToDeactivate(session);
      await tester.pump(const Duration(milliseconds: 10));
      await tester.pump(const Duration(milliseconds: 10));
      await accepted;
      await tester.pumpWidget(const SizedBox.shrink());
      await host.prepareToDeactivate(session);
      expect(tester.takeException(), isNull);
    },
  );
}
