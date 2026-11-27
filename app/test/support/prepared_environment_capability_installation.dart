import 'dart:io';

import 'package:adele_capabilities/adele_capabilities.dart';
import 'package:adele_desktop/core/application_plugin_bootstrap.dart';
import 'package:adele_desktop/core/product_lifecycle.dart';
import 'package:adele_desktop/core/project_storage_host.dart';
import 'package:adele_desktop/frontend/application_frontend_bootstrap.dart';
import 'package:adele_desktop/frontend/prepared_main_content_host.dart';
import 'package:adele_desktop/ui/main_content/main_content_host.dart';
import 'package:adele_environment/adele_environment.dart';
import 'package:adele_plugin_api/adele_plugin_api.dart';
import 'package:adele_product/adele_product.dart';
import 'package:adele_ui/adele_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plugin_runtime/plugin_runtime.dart';

const probeTimeout = Duration(seconds: 10);
const siblingPluginId = 'test.environment.capability.backend';
const environmentPluginId = 'test.environment.only';
const callablePluginId = 'test.capability.only';
const probeServiceId = 'test.capability.probe';

/// Prepared Session and Environment host for the capability and portable Git suites.
final class PreparedEnvironmentCapabilityInstallation {
  PreparedEnvironmentCapabilityInstallation({
    CapabilityRegistry? capabilities,
    required Directory files,
    required this.independent,
    this.environmentPlugin = environmentPluginId,
    this.callablePlugin = callablePluginId,
    ProductLifecycleCoordinator? lifecycle,
    Uri? sourceLocation,
    List<Environment>? environments,
  }) : capabilities = capabilities ?? CapabilityRegistry() {
    if (lifecycle != null) {
      // The caller owns durable storage and may reuse it across backend generations.
      if (capabilities == null) {
        throw ArgumentError(
          'An external lifecycle requires its capability registry.',
        );
      }
      sessionA = lifecycle.store.session(SessionId('nonprimary-session'))!;
      sessionB = lifecycle.store.session(SessionId('primary-session'))!;
      environmentRuntime = lifecycle.environmentRuntime;
    } else {
      final task = Task(
        id: TaskId('task'),
        projectId: ProjectId('project'),
        title: 'C2c',
      );
      final strategy = OrchestrationStrategyId('test.uninstalled-strategy');
      sessionA = Session(
        id: SessionId('nonprimary-session'),
        taskId: task.id,
        strategyId: strategy,
      );
      sessionB = Session(
        id: SessionId('primary-session'),
        taskId: task.id,
        strategyId: strategy,
      );
      final store = InMemoryProductStore();
      store.publishRestoredProject(
        project: Project(
          id: task.projectId,
          sourceLocation: sourceLocation ?? Uri.parse('test:/project'),
        ),
        tasks: [task],
        environments:
            environments ??
            [
              Environment(
                id: EnvironmentId('additional'),
                taskId: task.id,
                role: EnvironmentRole.additional,
                providerId: ProviderId('test.environment.a'),
                providerState: {'root': '${files.absolute.path}/a'},
              ),
              Environment(
                id: EnvironmentId('primary'),
                taskId: task.id,
                role: EnvironmentRole.primary,
                providerId: ProviderId('test.environment.b'),
                providerState: {'root': '${files.absolute.path}/b'},
              ),
            ],
        sessions: [sessionA, sessionB],
        authorities: [
          (sessionA.id, EnvironmentId('additional')),
          (sessionB.id, EnvironmentId('primary')),
        ],
        runRecords: const [],
      );
      environmentRuntime = EnvironmentRuntime(
        store: store,
        registry: this.capabilities,
        providerForBinding: (binding) => GeneratedEnvironmentProvider(
          providerId: binding.provider.id,
          service: EnvironmentProviderServiceClient(binding.requestChannel),
        ),
        retainEnvironment: store.replaceEnvironment,
      );
    }
    backends = ApplicationPluginBootstrap(
      this.capabilities,
      extensions,
      createInfrastructureServices: lifecycle == null
          ? null
          : (connection) => projectStorageServices(lifecycle, connection),
    );
    frontends = ApplicationFrontendBootstrap(
      extensions: extensions,
      backends: backends,
      mainContentHost: PreparedMainContentHost(
        environmentRuntime: environmentRuntime,
      ),
    );
    extensions.register(
      point: mainContentContributions,
      id: ExtensionId('test.independent'),
      value: MainContentContribution(
        order: 200,
        attach: (access) => access.open(
          MainContentPane(
            id: 'independent',
            title: 'Independent',
            createPresentation: () => const Text('Independent content'),
          ),
        ),
      ),
    );
  }

  final CapabilityRegistry capabilities;
  final bool independent;
  final String environmentPlugin;
  final String callablePlugin;
  final extensions = ExtensionRegistry();
  late final Session sessionA;
  late final Session sessionB;
  late final EnvironmentRuntime environmentRuntime;
  late final ApplicationPluginBootstrap backends;
  late final ApplicationFrontendBootstrap frontends;
  InstalledBackendActivation get callableOwner => backends.backends.singleWhere(
    (backend) =>
        backend.installation.metadata.id.value ==
        (independent ? callablePlugin : siblingPluginId),
  );
  InstalledBackendActivation get environmentOwner =>
      backends.backends.singleWhere(
        (backend) =>
            backend.installation.metadata.id.value ==
            (independent ? environmentPlugin : siblingPluginId),
      );
  PluginBackendConnection get connection => callableOwner.connection!;
  PluginBackendConnection get environmentConnection =>
      environmentOwner.connection!;

  Future<Object?> control(
    String method, [
    Map<String, Object?> payload = const {},
  ]) {
    final key = payload['key'] as String?;
    return controlOn(
      key != null &&
              (key.startsWith('read:') ||
                  key.startsWith('process:') ||
                  key.startsWith('restore:'))
          ? environmentConnection
          : connection,
      method,
      payload,
    );
  }

  Future<Object?> controlOn(
    PluginBackendConnection target,
    String method, [
    Map<String, Object?> payload = const {},
  ]) => target
      .channelFor(target.defaultConfigurationContext, 'probe')
      .request(method, payload)
      .timeout(probeTimeout);
  Future<void> wait(WidgetTester tester, String key) async {
    var completed = false;
    Object? failure;
    StackTrace? trace;
    final pending = control('wait', {'key': key}).then<void>(
      (_) => completed = true,
      onError: (Object error, StackTrace stack) {
        failure = error;
        trace = stack;
        completed = true;
      },
    );
    // Reverse dispatch is hosted in the widget's fake-async zone. Pump it while
    // waiting for the explicit AOT checkpoint, rather than inferring progress.
    while (!completed) {
      await Future<void>(() {});
      await tester.pump();
    }
    await pending;
    if (failure != null) Error.throwWithStackTrace(failure!, trace!);
  }

  Future<Map<Object?, Object?>> snapshot() async {
    final callable = (await control('snapshot'))! as Map<Object?, Object?>;
    if (!independent) return callable;
    final environment =
        (await controlOn(environmentConnection, 'snapshot'))! as Map;
    return {
      'requests': [
        ...environment['requests'] as List,
        ...callable['requests'] as List,
      ],
      'reads': environment['reads'],
      if (environment.containsKey('processes'))
        'processes': environment['processes'],
    };
  }

  List<Map<Object?, Object?>> calls(Map<Object?, Object?> snapshot) =>
      (snapshot['requests'] as List)
          .cast<Map<Object?, Object?>>()
          .where((r) => r['serviceId'] == probeServiceId)
          .toList();
  Future<void> denied(
    String token, {
    String? service,
    Map<String, Object?>? arguments,
  }) async {
    expect(
      await control('attack', {
        'token': token,
        'service': ?service,
        'arguments': ?arguments,
      }),
      {'ok': false},
    );
  }

  Widget widget({bool concurrent = false, Session? session}) => MaterialApp(
    home: Scaffold(
      body: Column(
        children: [
          Expanded(
            child: MainContentHost(
              key: const ValueKey('a'),
              session: session ?? sessionA,
              extensions: extensions,
            ),
          ),
          if (concurrent)
            Expanded(
              child: MainContentHost(
                key: const ValueKey('b'),
                session: sessionB,
                extensions: extensions,
              ),
            ),
        ],
      ),
    ),
  );

  Future<void> close() async {
    await frontends.close();
    await backends.close();
  }
}
