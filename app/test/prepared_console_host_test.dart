import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:adele_capabilities/adele_capabilities.dart';
import 'package:adele_desktop/core/product_lifecycle.dart';
import 'package:adele_desktop/frontend/application_frontend_bootstrap.dart';
import 'package:adele_desktop/frontend/prepared_console_host.dart';
import 'package:adele_desktop/terminal/environment_terminal_owner.dart';
import 'package:adele_desktop/ui/console/console_controller.dart';
import 'package:adele_desktop/ui/console/workbench_console.dart';
import 'package:adele_environment/adele_environment.dart';
import 'package:adele_plugin_api/adele_plugin_api.dart';
import 'package:adele_product/adele_product.dart';
import 'package:adele_ui/adele_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plugin_runtime/plugin_runtime.dart';

import '../../tools/stock_frontend_descriptors.dart';
import '../tool/terminal_frontend_compiler.dart';

const _plugin = 'dev.adele.plugin.terminal';
final _providerId = ProviderId('test.console-environment');

void main() {
  late Directory temporary;
  late PreparedPluginCatalog catalog;

  setUpAll(() async {
    temporary = await Directory.systemTemp.createTemp('prepared-console-');
    final installation = await Directory('${temporary.path}/terminal').create();
    await File('${installation.path}/frontend.evc').writeAsBytes(
      await compileTerminalFrontend(repositoryRoot: Directory.current.parent),
    );
    await File(
      '${installation.path}/adele_plugin.installation.json',
    ).writeAsString(
      jsonEncode({
        'manifestVersion': 1,
        'metadata': {
          'id': _plugin,
          'version': '1.0.0',
          'displayName': 'Terminal',
        },
        'components': {
          'frontend': {
            'artifact': 'frontend.evc',
            'presentations': stockFrontendDescriptors[_plugin],
          },
        },
      }),
    );
    catalog = await PreparedPluginCatalog.discover(temporary.path);
    expect(catalog.issues, isEmpty);
  });
  tearDownAll(() => temporary.delete(recursive: true));

  late _Fixture fixture;
  setUp(() async {
    fixture = _Fixture();
    await fixture.frontends.start(catalog);
    await _turn();
  });
  tearDown(() => fixture.close());

  test(
    'corrupt stock artifact exposes no action or native replacement',
    () async {
      final damaged = await Directory.systemTemp.createTemp('damaged-console-');
      addTearDown(() => damaged.delete(recursive: true));
      final installation = await Directory('${damaged.path}/terminal').create();
      await File(
        '${temporary.path}/terminal/adele_plugin.installation.json',
      ).copy('${installation.path}/adele_plugin.installation.json');
      await File(
        '${installation.path}/frontend.evc',
      ).writeAsBytes([0, 1, 2, 3]);
      final isolated = _Fixture();
      addTearDown(isolated.close);
      await isolated.frontends.start(
        await PreparedPluginCatalog.discover(damaged.path),
      );
      isolated.controller.setSession(isolated.sessionA);
      expect(
        isolated.frontends.generations.single.state,
        InstalledFrontendState.failed,
      );
      expect(isolated.controller.actions, isEmpty);
      expect(isolated.controller.eligibleTabs, isEmpty);
      expect(isolated.provider.requests, isEmpty);
      expect(isolated.provider.restores, 0);
      expect(
        isolated.store.session(isolated.sessionA.id),
        same(isolated.sessionA),
      );
    },
  );

  test(
    'passive context uses exact Session authority, never Task primary',
    () async {
      expect(
        fixture.frontends.generations.single.state,
        InstalledFrontendState.active,
      );
      expect(
        fixture.host.environmentForSession(fixture.sessionA),
        fixture.additional,
      );
      expect(
        fixture.store.primaryEnvironmentFor(fixture.task.id),
        fixture.primary,
      );
      expect(fixture.controller.actions, isEmpty);
      fixture.controller.setSession(fixture.sessionA);
      expect(fixture.controller.actions.single.label, 'New Terminal');
      expect(fixture.provider.requests, isEmpty);
      expect(fixture.provider.restores, 0);
      expect(fixture.controller.eligibleTabs, isEmpty);
      await fixture.create();
      expect(fixture.provider.requests.single.$1, fixture.additional.id);
      expect(
        fixture.provider.requests.single.$2.launchKind,
        EnvironmentTerminalLaunchKind.defaultShell,
      );
      expect(fixture.terminals.forEnvironment(fixture.primary.id), isEmpty);
      final owner = fixture.owners.single;
      expect(owner.state, EnvironmentTerminalState.running);
      fixture.controller.setSession(null);
      expect(fixture.controller.actions, isEmpty);
      expect(fixture.controller.eligibleTabs, isEmpty);
      fixture.controller.setSession(fixture.sessionB);
      expect(fixture.controller.eligibleTabs, hasLength(1));
      expect(fixture.owners.single, same(owner));
      fixture.controller.setSession(fixture.sessionPrimary);
      expect(fixture.controller.eligibleTabs, isEmpty);
      expect(fixture.provider.closes, isEmpty);
      expect(fixture.provider.requests, hasLength(1));
      final fabricated = Session(
        id: fixture.sessionA.id,
        taskId: fixture.task.id,
        strategyId: fixture.sessionA.strategyId,
      );
      expect(fixture.host.environmentForSession(fabricated), isNull);
      fixture.controller.setSession(fabricated);
      await fixture.controller.invoke(fixture.controller.actions.single);
      expect(fixture.provider.requests, hasLength(1));
      expect(fixture.controller.warning, isNotNull);
    },
  );

  testWidgets(
    'Terminal and read-only contribution coexist and own only their tabs',
    (tester) => tester.runAsync(() async {
      var evidence = 'running';
      var released = 0;
      late ConsoleTabRegistration readOnly;
      fixture.extensions.register(
        point: consoleContributions,
        id: ExtensionId('test.read-only'),
        value: ConsoleContribution(
          actions: [
            ConsoleCreationAction(
              id: 'output',
              label: 'Open output',
              create: (access) async {
                readOnly = access.open(
                  ConsoleContent(
                    metadata: ConsoleMetadata(title: 'Command output'),
                    isEligible: (_) => true,
                    createPresentation: (_) => const Text('Evidence'),
                    closeAdvice: () =>
                        const ConsoleCloseAdvice.noConfirmation(),
                    release: () async {
                      released++;
                      return ConsoleCleanupResult();
                    },
                  ),
                );
              },
            ),
          ],
        ),
      );
      await _turn();
      await fixture.create();
      final terminal = fixture.controller.selectedTab!;
      await fixture.controller.invoke(
        fixture.controller.actions.singleWhere(
          (action) => action.id == 'output',
        ),
      );
      final output = fixture.controller.selectedTab!;
      evidence = 'completed evidence';
      readOnly.updateMetadata(
        ConsoleMetadata(title: evidence, status: ConsoleStatus.completed),
      );
      expect(fixture.controller.eligibleTabs, [terminal, output]);
      expect(terminal.metadata.title, 'Terminal 1');
      expect(output.metadata.status, ConsoleStatus.completed);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: WorkbenchConsole(controller: fixture.controller),
          ),
        ),
      );
      await tester.pump();
      expect(find.widgetWithText(TextButton, 'Terminal 1'), findsOneWidget);
      expect(find.widgetWithText(TextButton, evidence), findsOneWidget);
      expect(find.byType(WorkbenchConsole), findsOneWidget);
      expect(find.byType(TabBar), findsNothing);
      expect(find.text('Evidence'), findsOneWidget);
      await readOnly.requestRemoval();
      expect(evidence, 'completed evidence');
      expect(released, 1);
      expect(fixture.provider.closes, isEmpty);
      expect(fixture.controller.eligibleTabs, [terminal]);
      await tester.pump();
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    }),
  );

  test(
    'live close cancellation preserves authority; accepted close releases once',
    () async {
      await fixture.create();
      final tab = fixture.controller.selectedTab!;
      final owner = fixture.owners.single;
      var prompts = 0;
      await fixture.controller.closeTab(tab, (message) async {
        prompts++;
        expect(message.message, contains('may have running work'));
        return false;
      });
      expect(fixture.provider.closes, isEmpty);
      expect(owner.write('still live', isActive: () => true), isTrue);
      await _turn();
      expect(fixture.provider.writes, [('resource-1', 'still live')]);
      final confirmation = Completer<bool>();
      final closing = fixture.controller.closeTab(tab, (_) {
        prompts++;
        return confirmation.future;
      });
      expect(
        fixture.controller.closeTab(
          tab,
          (_) async => throw StateError('duplicate'),
        ),
        same(closing),
      );
      fixture.provider.output('resource-1', '\x1b]2;renamed\x07');
      await _turn();
      expect(tab.metadata.title, 'renamed');
      confirmation.complete(true);
      await closing;
      expect(prompts, 2);
      expect(fixture.provider.closes, ['resource-1']);
      expect(fixture.controller.eligibleTabs, isEmpty);
      expect(fixture.owners, isEmpty);
      expect(owner.surface.isDisposed, isTrue);
    },
  );

  test(
    'hidden title/exit waits for successful cleanup and removes once',
    () async {
      await fixture.create();
      final tab = fixture.controller.selectedTab!;
      final owner = fixture.owners.single;
      fixture.controller.setSession(null);
      fixture.provider.output('resource-1', '\x1b]2;hidden');
      fixture.provider.output('resource-1', ' title\x1b\\');
      await _turn();
      expect(tab.metadata.title, 'hidden title');
      fixture.provider.cleanup = Completer<void>();
      fixture.provider.complete('resource-1', exitCode: 9);
      await _turn();
      expect(owner.shellCompleted, isTrue);
      expect(owner.cleanupPending, isTrue);
      expect(tab.isActive, isTrue);
      fixture.provider.cleanup!.complete();
      await _turn();
      expect(tab.isActive, isFalse);
      expect(fixture.owners, isEmpty);
      expect(owner.surface.isDisposed, isTrue);
      fixture.controller.setSession(fixture.sessionA);
      expect(fixture.controller.eligibleTabs, isEmpty);
      expect(fixture.provider.closes, ['resource-1']);
      expect(fixture.controller.warning, isNull);
    },
  );

  test(
    'completion cleanup failure remains visible and dismissal retains warning',
    () async {
      await fixture.create();
      final tab = fixture.controller.selectedTab!;
      fixture.provider.cleanup = Completer<void>();
      fixture.provider.complete('resource-1');
      await _turn();
      fixture.provider.cleanup!.completeError(StateError('PRIVATE_CLEANUP'));
      await _turn();
      expect(tab.isActive, isTrue);
      expect(tab.metadata.status, ConsoleStatus.failed);
      expect(tab.metadata.description, isNot(contains('PRIVATE_CLEANUP')));
      await fixture.controller.closeTab(tab, (message) async {
        expect(message.message, contains('unconfirmed'));
        return true;
      });
      expect(fixture.controller.eligibleTabs, isEmpty);
      expect(fixture.controller.warning, contains('could not be confirmed'));
      expect(fixture.provider.closes, ['resource-1']);
    },
  );

  test(
    'exit during confirmation and late acceptance do not release replacement',
    () async {
      await fixture.create();
      final old = fixture.controller.selectedTab!;
      final answer = Completer<bool>();
      final closing = fixture.controller.closeTab(old, (_) => answer.future);
      fixture.provider.complete('resource-1');
      await _turn();
      await fixture.create();
      final replacement = fixture.controller.selectedTab!;
      answer.complete(true);
      await closing;
      expect(fixture.controller.eligibleTabs, [replacement]);
      expect(fixture.provider.closes, ['resource-1']);
      expect(fixture.owners.single.state, EnvironmentTerminalState.running);
    },
  );

  test(
    'admitted creation finishes in original Environment after navigation',
    () async {
      fixture.provider.openGate = Completer<void>();
      fixture.controller.setSession(fixture.sessionA);
      final opening = fixture.controller.invoke(
        fixture.controller.actions.single,
      );
      await _turn();
      expect(fixture.provider.requests, hasLength(1));
      fixture.controller.setSession(fixture.sessionPrimary);
      fixture.provider.openGate!.complete();
      await opening;
      expect(fixture.controller.selectedTab, isNull);
      expect(fixture.controller.eligibleTabs, isEmpty);
      expect(fixture.owners, hasLength(1));
      fixture.controller.setSession(fixture.sessionB);
      expect(fixture.controller.eligibleTabs, hasLength(1));
      expect(fixture.provider.requests.single.$1, fixture.additional.id);
    },
  );

  test('forced shutdown during opening fences late native owner', () async {
    fixture.provider.openGate = Completer<void>();
    fixture.controller.setSession(fixture.sessionA);
    final opening = fixture.controller.invoke(
      fixture.controller.actions.single,
    );
    await _turn();
    final owner = fixture.owners.single;
    final closing = fixture.controller.close();
    fixture.provider.openGate!.complete();
    await opening;
    await closing;
    expect(owner.surface.isDisposed, isTrue);
    expect(fixture.controller.eligibleTabs, isEmpty);
    expect(fixture.owners, isEmpty);
  });

  test(
    'frontend retirement cleans its exact content without confirmation',
    () async {
      await fixture.create();
      final activation = fixture.frontends.generations.single;
      await activation.retire(
        consoleContributions,
        ExtensionId('dev.adele.plugin.terminal.console'),
      );
      await _turn();
      expect(fixture.controller.actions, isEmpty);
      expect(fixture.owners, isEmpty);
      expect(fixture.provider.closes, ['resource-1']);
    },
  );
}

Future<void> _turn() => Future<void>.delayed(Duration.zero);

final class _Fixture {
  _Fixture() {
    task = Task(id: TaskId('task'), projectId: project.id, title: 'Fixture');
    primary = Environment(
      id: EnvironmentId('primary'),
      taskId: task.id,
      role: EnvironmentRole.primary,
      providerId: _providerId,
      providerState: const {},
    );
    additional = Environment(
      id: EnvironmentId('additional'),
      taskId: task.id,
      role: EnvironmentRole.additional,
      providerId: _providerId,
      providerState: const {},
    );
    Session session(String name) => Session(
      id: SessionId(name),
      taskId: task.id,
      strategyId: OrchestrationStrategyId('test.strategy'),
    );
    sessionA = session('a');
    sessionB = session('b');
    sessionPrimary = session('primary-session');
    store.publishRestoredProject(
      project: project,
      tasks: [task],
      environments: [primary, additional],
      sessions: [sessionA, sessionB, sessionPrimary],
      authorities: [
        (sessionA.id, additional.id),
        (sessionB.id, additional.id),
        (sessionPrimary.id, primary.id),
      ],
      runRecords: [],
    );
    capabilities.register(
      provider: ProviderDescriptor(
        id: _providerId,
        pluginId: 'test.provider',
        displayName: 'Fixture',
        capability: environmentProviderCapability,
        serviceId: environmentProviderServiceId,
      ),
      endpoint: provider,
    );
    final environmentRuntime = EnvironmentRuntime(
      store: store,
      registry: capabilities,
      providerForBinding: (binding) => binding.endpointAs<_Provider>(),
      retainEnvironment: store.replaceEnvironment,
    );
    terminals = EnvironmentTerminalCoordinator(
      environmentRuntime: environmentRuntime,
      cleanupTimeout: const Duration(milliseconds: 100),
    );
    host = PreparedConsoleHost(store: store, terminals: terminals);
    controller = ConsoleController(
      extensions,
      cleanupTimeout: const Duration(milliseconds: 200),
    );
    frontends = ApplicationFrontendBootstrap(
      extensions: extensions,
      consoleHost: host,
    );
  }

  final store = InMemoryProductStore();
  final extensions = ExtensionRegistry();
  final capabilities = CapabilityRegistry();
  final provider = _Provider();
  final project = Project(
    id: ProjectId('project'),
    sourceLocation: Uri.parse('file:///fixture'),
  );
  late final Task task;
  late final Environment primary;
  late final Environment additional;
  late final Session sessionA;
  late final Session sessionB;
  late final Session sessionPrimary;
  late final EnvironmentTerminalCoordinator terminals;
  late final PreparedConsoleHost host;
  late final ConsoleController controller;
  late final ApplicationFrontendBootstrap frontends;

  List<EnvironmentTerminalOwner> get owners =>
      terminals.forEnvironment(additional.id);
  Future<void> create() async {
    controller.setSession(sessionA);
    await controller.invoke(
      controller.actions.singleWhere((action) => action.id == 'new-terminal'),
    );
    await _turn();
  }

  Future<void> close() async {
    await controller.close();
    await frontends.close();
    await terminals.close();
    controller.dispose();
  }
}

final class _Provider
    implements
        EnvironmentProvider,
        EnvironmentTerminalProvider,
        CapabilityEndpoint {
  @override
  ProviderId get providerId => _providerId;
  @override
  String get serviceId => environmentProviderServiceId;
  @override
  bool get isAvailable => true;
  int restores = 0;
  final requests = <(EnvironmentId, EnvironmentTerminalRequest)>[];
  final events = <String, StreamController<EnvironmentTerminalEvent>>{};
  final closes = <String>[];
  final writes = <(String, String)>[];
  Completer<void>? cleanup;
  Completer<void>? openGate;

  @override
  Future<EnvironmentProviderResult> restore(
    LocalEnvironment environment,
  ) async {
    restores++;
    return EnvironmentProviderResult(providerState: const {});
  }

  @override
  Stream<EnvironmentTerminalEvent> openTerminal(
    EnvironmentId id,
    EnvironmentTerminalRequest request,
  ) {
    requests.add((id, request));
    final handle = 'resource-${requests.length}';
    late StreamController<EnvironmentTerminalEvent> stream;
    stream = StreamController(
      sync: true,
      onListen: () async {
        await openGate?.future;
        stream.add(
          EnvironmentTerminalEvent(
            kind: EnvironmentTerminalEventKind.opened,
            opened: EnvironmentTerminalOpened(
              handle: handle,
              dimensions: request.dimensions,
            ),
            output: null,
            completed: null,
          ),
        );
      },
    );
    events[handle] = stream;
    return stream.stream;
  }

  void output(String handle, String text) => events[handle]!.add(
    EnvironmentTerminalEvent(
      kind: EnvironmentTerminalEventKind.output,
      opened: null,
      output: text,
      completed: null,
    ),
  );

  void complete(String handle, {int exitCode = 0}) => events[handle]!.add(
    EnvironmentTerminalEvent(
      kind: EnvironmentTerminalEventKind.completed,
      opened: null,
      output: null,
      completed: EnvironmentTerminalCompleted(
        termination: EnvironmentTerminalTermination.exited,
        exitCode: exitCode,
      ),
    ),
  );

  @override
  Future<void> closeTerminal(EnvironmentId id, String handle) async {
    closes.add(handle);
    await cleanup?.future;
  }

  @override
  Future<void> writeTerminal(
    EnvironmentId id,
    String handle,
    String text,
  ) async => writes.add((handle, text));
  @override
  Future<void> resizeTerminal(
    EnvironmentId id,
    String handle,
    EnvironmentTerminalDimensions dimensions,
  ) async {}
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
