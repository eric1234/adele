@Timeout(Duration(minutes: 3))
library;

import 'dart:convert';
import 'dart:io';

import 'package:adele_capabilities/adele_capabilities.dart';
import 'package:adele_desktop/core/application_plugin_bootstrap.dart';
import 'package:adele_desktop/frontend/application_frontend_bootstrap.dart';
import 'package:adele_desktop/frontend/prepared_session_services.dart';
import 'package:adele_desktop/frontend/structured_bridge_data.dart';
import 'package:adele_desktop/ui/main_content/main_content_host.dart';
import 'package:adele_orchestration/adele_orchestration.dart';
import 'package:adele_orchestration/remote_orchestration.dart';
import 'package:adele_plugin_api/adele_plugin_api.dart';
import 'package:adele_product/adele_product.dart';
import 'package:dart_eval/dart_eval.dart';
import 'package:dart_eval/stdlib/core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_eval/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plugin_runtime/plugin_runtime.dart';

import 'support/session_accessory_frontend_fixture.dart';
import 'support/session_content_backend_fixture.dart';

const _library = accessoryProbeLibrary;
const _strategy = 'test.not-chat';
const _owner = 'test.accessory';
const _local = 'test.frontend-only';
const _service = 'fixture.content';

void main() {
  late Directory temporary;
  late ContentBackendArtifacts compiled;
  late File evc;
  setUpAll(() async {
    temporary = await Directory.systemTemp.createTemp('accessory-probe-');
    addTearDown(() => temporary.delete(recursive: true));
    compiled = await compileContentBackend(temporary);
    evc = await compileAccessoryProbe(temporary);
  });

  late ExtensionRegistry extensions;
  late ApplicationPluginBootstrap backends;
  late ApplicationFrontendBootstrap frontends;
  late Session current;
  Session session(String id) => Session(
    id: SessionId(id),
    taskId: TaskId('task'),
    strategyId: OrchestrationStrategyId(_strategy),
  );
  setUp(() {
    current = session('session');
    extensions = ExtensionRegistry();
    backends = ApplicationPluginBootstrap(CapabilityRegistry(), extensions);
    frontends = ApplicationFrontendBootstrap(
      extensions: extensions,
      backends: backends,
      sessionServices: PreparedSessionServices(
        extensions: extensions,
        backends: backends,
        controllerForSession: (_, _) => fail('No execution grant.'),
        inspectActivity: (_, _) => fail('No Inspection grant.'),
        isCurrent: (session) => identical(current, session),
      ),
    );
  });

  Widget host(Session presented) => MaterialApp(
    home: Scaffold(
      body: MainContentHost(
        session: presented,
        extensions: extensions,
        isCurrent: () => identical(current, presented),
      ),
    ),
  );
  Future<void> mount(
    WidgetTester tester, {
    bool owning = true,
    bool localRequestsBackend = false,
  }) async {
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(() async {
        try {
          await frontends.close();
        } finally {
          await backends.close();
        }
      });
    });
    await tester.runAsync(() async {
      final root = await temporary.createTemp('installations-');
      for (final id in [_strategy, _owner, _local]) {
        final directory = await Directory('${root.path}/$id').create();
        if (id != _local) {
          await compiled.backend.copy('${directory.path}/backend.aot');
        }
        await evc.copy('${directory.path}/frontend.evc');
        await File(
          '${directory.path}/adele_plugin.installation.json',
        ).writeAsString(
          jsonEncode({
            'manifestVersion': 1,
            'metadata': {'id': id, 'version': '1', 'displayName': id},
            'components': {
              if (id != _local) 'backend': {'artifact': 'backend.aot'},
              'frontend': {
                'artifact': 'frontend.evc',
                'presentations': [
                  {
                    'extensionId': '$id.view',
                    'order': 10,
                    'library': _library,
                    if (id == _strategy) ...{
                      'role': 'mainContent',
                      'initialize': 'initialize',
                      'entrypoint': 'buildStrategy',
                      'strategyAffinity': owning
                          ? 'owningBackend'
                          : 'independent',
                    } else ...{
                      'role': 'sessionAccessory',
                      'location': 'execution-configuration',
                      'entrypoint': id == _local
                          ? 'localAccessory'
                          : 'serviceAccessory',
                      if (id == _owner || localRequestsBackend)
                        'backendServices': [_service],
                    },
                  },
                ],
              },
            },
          }),
        );
      }
      await backends.start(
        installationRoot: root.path,
        dartaotruntimeExecutable: compiled.runtime,
        hostArtifactPath: compiled.host.path,
        startupArguments: {
          _owner: ['owner'],
          _strategy: [
            'strategy',
            jsonEncode({
              'extensionPointId': orchestrationStrategyContributions.value,
              'extensionId': '$_strategy.registration',
              'serviceId': remoteOrchestrationServiceId,
              'configurationContext': 'strategy-context',
              'metadata': {'strategyId': _strategy, 'routeId': 'strategy'},
            }),
          ],
        },
      );
      final catalog = backends.catalog!;
      expect(catalog.issues, isEmpty);
      expect(backends.backends, hasLength(2));
      for (final backend in backends.backends) {
        expect(
          backend.state,
          InstalledBackendState.active,
          reason: '${backend.failure}',
        );
      }
      await frontends.start(catalog);
      expect(frontends.generations, hasLength(3));
      for (final frontend in frontends.generations) {
        expect(
          frontend.state,
          InstalledFrontendState.active,
          reason: '${frontend.failure}',
        );
      }
    });
    await tester.pumpWidget(host(current));
    await tester.pumpAndSettle();
    expect(find.text('Non-Chat strategy'), findsOneWidget);
  }

  PluginBackendConnection connection(String id) => backends.backends
      .singleWhere((entry) => entry.installation.metadata.id.value == id)
      .connection!;

  testWidgets('independent compiled pane cannot place Session accessories', (
    tester,
  ) async {
    await mount(tester, owning: false);
    expect(find.text('Local session'), findsNothing);
    expect(find.text('Service session'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'compiled accessories receive Session identity and only declared owning-backend service',
    (tester) async {
      await mount(tester, localRequestsBackend: true);
      expect(find.text('Local session'), findsOneWidget);
      expect(find.text('Service session'), findsOneWidget);
      final runtime = _runtime(tester, 'Service session');
      final local = _runtime(tester, 'Local session');
      await _withBackend(tester, () async {
        expectSync(await _query(local, 'first'), [false, null]);
        expectSync(await _query(runtime, 'first'), [
          true,
          'owner|session/first|first content',
        ]);
        expectSync(await _query(runtime, 'first', service: 'fixture.private'), [
          false,
          null,
        ]);
        // Both backends really serve the same route. The accessory must not inherit
        // the strategy's channel/context or dispatch an undeclared request.
        final foreign = connection(_strategy);
        expectSync(await contentBackendControl(foreign, 'snapshot'), isEmpty);
        expectSync(
          await foreign
              .channelFor(foreign.defaultConfigurationContext, _service)
              .request('read', {
                'sessionId': 'session',
                'occurrenceId': 'first',
              }),
          'strategy|session/first|first content',
        );
        expectSync(
          await contentBackendControl(connection(_owner), 'snapshot'),
          [
            {
              'configurationContext': 'default',
              'serviceId': _service,
              'method': 'read',
              'payload': {'sessionId': 'session', 'occurrenceId': 'first'},
              'hostInvocationContext': null,
            },
          ],
        );
      });
      expect(tester.takeException(), isNull);
    },
  );

  for (final departure in [
    'Session switch',
    'accessory retirement',
    'backend replacement',
  ]) {
    testWidgets(
      '$departure fences pending and subsequent compiled accessory reads',
      (tester) async {
        await mount(tester);
        final old = _runtime(tester, 'Service session');
        final owner = connection(_owner);
        final key = {'key': 'session/held-navigation'};
        await _withBackend(tester, () async {
          final pending = _query(old, 'held-navigation');
          await contentBackendControl(owner, 'wait', key);
          switch (departure) {
            case 'Session switch':
              // The previous Session's subtree has not been replaced yet.
              current = session('other');
            case 'accessory retirement':
              await frontends.generations
                  .singleWhere(
                    (g) => g.installation.metadata.id.value == _owner,
                  )
                  .registrations
                  .single
                  .close();
            case 'backend replacement':
              await owner.close();
          }
          if (!owner.isClosed) {
            await contentBackendControl(owner, 'release', key);
          }
          expectSync(await pending, [false, null]);
          if (departure == 'backend replacement') {
            final replacement = await backends.host!.startPlugin(
              pluginId: _owner,
              artifactUri: compiled.backend.uri,
              arguments: ['replacement'],
            );
            expectSync(await _query(old, 'first'), [false, null]);
            expectSync(
              await contentBackendControl(replacement, 'snapshot'),
              isEmpty,
            );
          } else {
            expectSync(
              () => old.executeLib(_library, 'currentId'),
              throwsA(anything),
            );
            expectSync(await _query(old, 'first'), [false, null]);
            expectSync(
              await contentBackendControl(owner, 'snapshot'),
              hasLength(1),
            );
          }
          expectSync(
            await contentBackendControl(connection(_strategy), 'snapshot'),
            isEmpty,
          );
        });
        if (departure == 'Session switch') {
          await tester.pumpWidget(host(current));
          await tester.pumpAndSettle();
          expect(find.text('Local other'), findsOneWidget);
          expect(find.text('Service other'), findsOneWidget);
          final fresh = _runtime(tester, 'Service other');
          expect(fresh, isNot(same(old)));
          await _withBackend(tester, () async {
            expectSync(await _query(fresh, 'first'), [
              true,
              'owner|other/first|other content',
            ]);
            expectSync(await _query(old, 'first'), [false, null]);
          });
        }
        expect(tester.takeException(), isNull);
      },
    );
  }
}

Runtime _runtime(WidgetTester tester, String text) => tester
    .widget<$StatelessWidget$bridge>(
      find.ancestor(
        of: find.text(text),
        matching: find.byWidgetPredicate(
          (widget) => widget is $StatelessWidget$bridge,
        ),
      ),
    )
    .$runtime;

// AOT replies arrive on the I/O queue; the mounted bridge settles futures in
// the widget's test zone. Drive both, bounded by the same fixture deadline.
Future<void> _withBackend(
  WidgetTester tester,
  Future<void> Function() work,
) async {
  await tester.runAsync(() async {
    var done = false;
    final result = work()
        .timeout(const Duration(seconds: 10))
        .whenComplete(() => done = true);
    result.ignore();
    while (!done) {
      await Future<void>(() {});
      await tester.pump();
    }
    await result;
  });
}

Future<Object?> _query(
  Runtime runtime,
  String occurrence, {
  String service = _service,
}) async {
  final operation =
      runtime.executeLib(_library, 'query', [
            $String(service),
            $String(occurrence),
          ])
          as $Future;
  return copyStructuredBridgeData(
    await operation.$value.timeout(const Duration(seconds: 10)),
  );
}
