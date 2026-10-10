import 'dart:async';
import 'dart:io';

import 'package:adele_capabilities/adele_capabilities.dart';
import 'package:adele_desktop/core/adele_runtime.dart';
import 'package:adele_desktop/frontend/contribution_bridge.dart';
import 'package:adele_desktop/frontend/main_content_bridge.dart';
import 'package:adele_desktop/frontend/prepared_frontend.dart';
import 'package:adele_desktop/frontend/prepared_main_content_host.dart';
import 'package:adele_desktop/frontend/structured_bridge_data.dart';
import 'package:adele_desktop/ui/main_content/main_content_host.dart';
import 'package:adele_environment/adele_environment.dart';
import 'package:adele_plugin_api/adele_plugin_api.dart';
import 'package:adele_product/adele_product.dart';
import 'package:adele_ui/adele_ui.dart';
import 'package:adele_ui/main_content_bridge.dart' as public_bridge;
import 'package:dart_eval/dart_eval.dart';
import 'package:dart_eval/dart_eval_bridge.dart';
import 'package:dart_eval/stdlib/core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_eval/flutter_eval.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plugin_runtime/plugin_runtime.dart';

const _library = 'package:source_display_probe/main.dart';
const _rawPath = ' dir/../a [modified];\t\n"quoted" \\ \u00e9.txt ';
final _consumerId = ExtensionId('test.source-consumer');
final _providerId = ExtensionId('test.source-provider');

void main() {
  group('native source-display bridge', () {
    late ExtensionRegistry extensions;
    late MainContentBridge bridge;

    setUp(() {
      extensions = ExtensionRegistry();
      bridge = MainContentBridge(
        context: const {'sessionId': 'captured'},
        isActive: () => true,
        resolveSourceDisplay: DisplaySourceFileResolver(extensions).resolve,
      );
    });

    test('public stubs and an undeclared bridge grant no access', () async {
      expect(public_bridge.sourceDisplayAvailability, throwsUnsupportedError);
      expect(
        () => public_bridge.displaySourceFile(_rawPath),
        throwsUnsupportedError,
      );
      final denied = MainContentBridge(
        context: const {'sessionId': 'not-authority'},
        isActive: () => true,
      );
      expect(denied.sourceDisplayAvailability(), 'denied');
      expect(await denied.displaySourceFile(_rawPath), {'status': 'denied'});
    });

    test(
      'zero and many providers do not invoke or select a fallback',
      () async {
        expect(bridge.sourceDisplayAvailability(), 'unavailable');
        expect(await bridge.displaySourceFile(_rawPath), {
          'status': 'unavailable',
        });
        var calls = 0;
        for (final id in ['test.first', 'test.second']) {
          extensions.register(
            point: displaySourceFileContributions,
            id: ExtensionId(id),
            value: DisplaySourceFileContribution(
              display: (_) async {
                calls++;
                return const {'ok': true};
              },
            ),
          );
        }
        expect(bridge.sourceDisplayAvailability(), 'ambiguous');
        expect(await bridge.displaySourceFile(_rawPath), {
          'status': 'ambiguous',
        });
        expect(calls, 0);
      },
    );

    test(
      'discovery is passive and raw paths and provider data stay separate',
      () async {
        final paths = <String>[];
        extensions.register(
          point: displaySourceFileContributions,
          id: _providerId,
          value: DisplaySourceFileContribution(
            display: (path) async {
              paths.add(path);
              return const {
                'ok': true,
                'path': 'provider-normalized.txt',
                'private': 'not for the consumer',
              };
            },
          ),
        );
        for (var i = 0; i < 3; i++) {
          expect(bridge.sourceDisplayAvailability(), 'available');
        }
        expect(paths, isEmpty);
        for (final path in [
          _rawPath,
          '',
          '../outside',
          '/absolute',
          'a\u0000b',
        ]) {
          expect(await bridge.displaySourceFile(path), {'status': 'success'});
        }
        expect(paths, [_rawPath, '', '../outside', '/absolute', 'a\u0000b']);
      },
    );

    for (final throws in [false, true]) {
      test(
        'provider ${throws ? 'exception' : 'rejection'} is safe and not retried',
        () async {
          var calls = 0;
          extensions.register(
            point: displaySourceFileContributions,
            id: _providerId,
            value: DisplaySourceFileContribution(
              display: (_) async {
                calls++;
                if (throws) throw StateError('private /host/path diagnostic');
                return const {
                  'ok': false,
                  'failure': {'message': 'private /host/path diagnostic'},
                };
              },
            ),
          );
          expect(bridge.sourceDisplayAvailability(), 'available');
          expect(await bridge.displaySourceFile(_rawPath), {
            'status': 'failed',
          });
          expect(calls, 1);
        },
      );
    }

    test(
      'an admitted exact binding retires without cancellation or replacement dispatch',
      () async {
        final entered = Completer<void>();
        final release = Completer<void>();
        var completed = 0;
        var replacements = 0;
        final original = extensions.register(
          point: displaySourceFileContributions,
          id: _providerId,
          value: DisplaySourceFileContribution(
            display: (_) async {
              entered.complete();
              await release.future;
              completed++;
              return const {'ok': true};
            },
          ),
        );
        final pending = bridge.displaySourceFile(_rawPath);
        await entered.future;
        await original.close();
        extensions.register(
          point: displaySourceFileContributions,
          id: _providerId,
          value: DisplaySourceFileContribution(
            display: (_) async {
              replacements++;
              return const {'ok': true};
            },
          ),
        );
        release.complete();
        expect(await pending, {'status': 'retired'});
        expect(completed, 1);
        expect(replacements, 0);
        expect(await bridge.displaySourceFile(_rawPath), {'status': 'success'});
        expect(replacements, 1);
      },
    );

    test(
      'observed origin departure permanently fences a captured bridge',
      () async {
        var active = true;
        var calls = 0;
        final entered = Completer<void>();
        final release = Completer<Map<String, Object?>>();
        extensions.register(
          point: displaySourceFileContributions,
          id: _providerId,
          value: DisplaySourceFileContribution(
            display: (_) {
              calls++;
              entered.complete();
              return release.future;
            },
          ),
        );
        bridge = MainContentBridge(
          context: const {},
          isActive: () => active,
          resolveSourceDisplay: DisplaySourceFileResolver(extensions).resolve,
        );
        final pending = bridge.displaySourceFile(_rawPath);
        await entered.future;
        active = false;
        expect(bridge.sourceDisplayAvailability(), 'retired');
        active = true;
        expect(await bridge.displaySourceFile('later'), {'status': 'retired'});
        release.complete(const {'ok': true});
        expect(await pending, {'status': 'retired'});
        expect(calls, 1);
      },
    );
  });

  group('compiled source-display authority', () {
    late Directory temporary;
    late File artifact;

    setUpAll(() async {
      temporary = await Directory.systemTemp.createTemp(
        'source-display-probe-',
      );
      final program =
          (Compiler()
                ..addPlugin(flutterEvalPlugin)
                ..addPlugin(const MainContentDeclarations())
                ..addPlugin(const ContributionDeclarations())
                ..entrypoints.add(_library))
              .compile({
                'source_display_probe': {'main.dart': _source},
                'adele_ui': {
                  for (final library in [
                    'main_content_bridge',
                    'contribution_bridge',
                  ])
                    '$library.dart': await File(
                      '../packages/ui/lib/$library.dart',
                    ).readAsString(),
                },
              });
      artifact = await File(
        '${temporary.path}/probe.evc',
      ).writeAsBytes(program.write());
    });
    tearDownAll(() => temporary.delete(recursive: true));

    Future<_Fixture> fixture(
      WidgetTester tester, {
      bool canonicalRuntime = true,
    }) async {
      final generation = (await tester.runAsync(
        () => PreparedFrontend.load(artifact),
      ))!;
      final result = _Fixture(
        generation,
        temporary,
        canonicalRuntime: canonicalRuntime,
      );
      addTearDown(result.close);
      return result;
    }

    testWidgets(
      'declared canonical pane uses passive zero/one/many resolution and safe results',
      (tester) async {
        final f = await fixture(tester);
        f.consumer();
        await tester.pumpWidget(f.widget());
        await tester.pumpAndSettle();
        final eval = f.pane(_consumerId).runtime;
        expect(find.text('Init denied/denied'), findsOneWidget);
        expect(_availability(eval), 'unavailable');
        expect(await _request(eval, _rawPath), {'status': 'unavailable'});
        final paths = <String>[];
        var reject = false;
        f.nativeProvider((path) async {
          paths.add(path);
          if (reject) throw StateError('private provider details');
          return const {'ok': true, 'private': 'not exposed'};
        });
        expect(_availability(eval), 'available');
        expect(_availability(eval), 'available');
        expect(paths, isEmpty);
        expect(await _request(eval, _rawPath), {'status': 'success'});
        expect(paths, [_rawPath]);
        final other = f.nativeProvider((_) async {
          fail('Ambiguous resolution invoked another provider.');
        }, id: ExtensionId('test.other-source'));
        expect(_availability(eval), 'ambiguous');
        expect(await _request(eval, _rawPath), {'status': 'ambiguous'});
        expect(paths, [_rawPath]);
        await other.close();
        reject = true;
        expect(await _request(eval, _rawPath), {'status': 'failed'});
        expect(paths, [_rawPath, _rawPath]);
        f.expectNoEnvironmentWork();
        await tester.pumpWidget(const SizedBox.shrink());
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets('undeclared pane cannot borrow a discovered provider', (
      tester,
    ) async {
      final f = await fixture(tester);
      f.consumer(allowed: false);
      var calls = 0;
      f.nativeProvider((_) async {
        calls++;
        return const {'ok': true};
      });
      await tester.pumpWidget(f.widget());
      await tester.pumpAndSettle();
      final eval = f.pane(_consumerId).runtime;
      expect(_availability(eval), 'denied');
      expect(await _request(eval, _rawPath), {'status': 'denied'});
      expect(calls, 0);
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets(
      'initializer, action and finite operation do not inherit pane permission',
      (tester) async {
        final f = await fixture(tester);
        f.consumer();
        var calls = 0;
        f.nativeProvider((_) async {
          calls++;
          return const {'ok': true};
        });
        await tester.pumpWidget(f.widget());
        await tester.pumpAndSettle();
        final eval = f.pane(_consumerId).runtime;
        expect(find.text('Init denied/denied'), findsOneWidget);
        expect(_availability(eval), 'available');
        expect(await _invoke(eval, 'probeOperation'), {
          'availability': 'denied',
          'status': 'denied',
        });
        await tester.pumpAndSettle();
        await tester.tap(find.text('Probe input'));
        await tester.pumpAndSettle();
        expect(find.text('Action denied'), findsOneWidget);
        await tester.tap(find.text('Action denied'));
        await tester.pumpAndSettle();
        expect(_read(eval, 'actionResult'), {
          'availability': 'denied',
          'status': 'denied',
        });
        expect(calls, 0);
        await tester.pumpWidget(const SizedBox.shrink());
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets('a host without canonical runtime cannot grant source access', (
      tester,
    ) async {
      final f = await fixture(tester, canonicalRuntime: false);
      f.consumer();
      var calls = 0;
      f.nativeProvider((_) async {
        calls++;
        return const {'ok': true};
      });
      await tester.pumpWidget(f.widget());
      await tester.pumpAndSettle();
      final eval = f.pane(_consumerId).runtime;
      expect(_availability(eval), 'unavailable');
      expect(await _request(eval, _rawPath), {'status': 'unavailable'});
      expect(calls, 0);
      await tester.pumpWidget(const SizedBox.shrink());
    });

    for (final foreign in [false, true]) {
      testWidgets(
        '${foreign ? 'foreign canonical' : 'equal noncanonical'} Session cannot initialize a consumer',
        (tester) async {
          final f = await fixture(tester);
          f.consumer();
          var calls = 0;
          f.nativeProvider((_) async {
            calls++;
            return const {'ok': true};
          });
          final other = _session(f.session.id.value);
          if (foreign) {
            final otherRuntime = AdeleRuntime();
            addTearDown(otherRuntime.close);
            _publish(otherRuntime, [other]);
            expect(otherRuntime.store.session(other.id), same(other));
          }
          await tester.pumpWidget(f.widget(session: other));
          await tester.pumpAndSettle();
          expect(f.panes, isEmpty);
          expect(find.text('Consumer body'), findsNothing);
          expect(calls, 0);
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox.shrink());
        },
      );
    }

    for (final departure in [
      'unmount',
      'Session departure',
      'pane removal',
      'registration retirement',
    ]) {
      testWidgets(
        '$departure fences old EVC without redirecting an admitted request',
        (tester) async {
          final f = await fixture(tester);
          final consumer = f.consumer();
          final entered = Completer<void>();
          final release = Completer<void>();
          var calls = 0;
          var completed = 0;
          f.nativeProvider((_) async {
            calls++;
            entered.complete();
            await release.future;
            completed++;
            return const {'ok': true};
          });
          await tester.pumpWidget(f.widget());
          await tester.pumpAndSettle();
          final eval = f.pane(_consumerId).runtime;
          final pending = _request(eval, _rawPath);
          await entered.future;
          switch (departure) {
            case 'unmount':
              await tester.pumpWidget(const SizedBox.shrink());
              await tester.pumpWidget(f.widget());
            case 'Session departure':
              await tester.pumpWidget(f.widget(session: f.other));
            case 'pane removal':
              expect(_read(eval, 'removePane'), isTrue);
            case 'registration retirement':
              await consumer.close();
              f.consumer();
          }
          await tester.pumpAndSettle();
          expect(_availability(eval), 'retired');
          expect(await _request(eval, 'do-not-redirect'), {
            'status': 'retired',
          });
          release.complete();
          expect(await pending, {'status': 'retired'});
          expect(calls, 1);
          expect(completed, 1);
          await tester.pumpWidget(const SizedBox.shrink());
          expect(tester.takeException(), isNull);
        },
      );
    }

    testWidgets(
      'prepared provider attached to another canonical Session is unavailable',
      (tester) async {
        final f = await fixture(tester);
        f.consumer();
        final providerViews = ExtensionRegistry();
        f.preparedProvider(registry: providerViews);
        var operations = 0;
        f.confirm = (_) async {
          operations++;
          return true;
        };
        Widget page(Session target) => MaterialApp(
          home: Scaffold(
            body: Column(
              children: [
                Expanded(
                  child: MainContentHost(
                    session: target,
                    extensions: providerViews,
                  ),
                ),
                Expanded(
                  child: MainContentHost(
                    session: f.session,
                    extensions: f.extensions,
                  ),
                ),
              ],
            ),
          ),
        );
        await tester.pumpWidget(page(f.other));
        await tester.pumpAndSettle();
        final eval = f.pane(_consumerId).runtime;
        expect(_availability(eval), 'unavailable');
        expect(await _request(eval, _rawPath), {'status': 'unavailable'});
        expect(operations, 0);
        await tester.pumpWidget(page(f.session));
        await tester.pumpAndSettle();
        expect(_availability(eval), 'available');
        expect(await _request(eval, _rawPath), {'status': 'success'});
        expect(operations, 1);
        expect(_read(f.pane(_providerId).runtime, 'completed'), {
          'path': _rawPath,
          'session': f.session.id.value,
        });
        await tester.pumpWidget(const SizedBox.shrink());
        expect(tester.takeException(), isNull);
      },
    );

    for (final retirement in ['display registration', 'target attachment']) {
      testWidgets(
        'retired $retirement preserves admitted effects but cannot refresh or focus replacements',
        (tester) async {
          final f = await fixture(tester);
          f.consumer();
          final display = f.preparedProvider();
          final entered = Completer<void>();
          final release = Completer<bool>();
          f.confirm = (_) {
            entered.complete();
            return release.future;
          };
          await tester.pumpWidget(f.widget());
          await tester.pumpAndSettle();
          final eval = f.pane(_consumerId).runtime;
          final pending = _request(eval, _rawPath);
          await entered.future;
          var replacements = 0;
          if (retirement == 'display registration') {
            await display.close();
            f.nativeProvider((_) async {
              replacements++;
              return const {'ok': true};
            });
          } else {
            await tester.pumpWidget(f.widget(session: f.other));
            await tester.pumpAndSettle();
          }
          final target = f.pane(_providerId);
          final initializations = _read(target.runtime, 'initializations');
          expect(target.focuses, 0);
          release.complete(true);
          expect(await pending, {'status': 'retired'});
          await f.host.drainOperations();
          await tester.pumpAndSettle();
          expect(_read(target.runtime, 'completed'), {
            'path': _rawPath,
            'session': f.session.id.value,
          });
          expect(_read(target.runtime, 'initializations'), initializations);
          expect(target.focuses, 0);
          expect(replacements, 0);
          expect(find.text('Source idle'), findsOneWidget);
          f.confirm = (_) async => true;
          expect(await _request(f.pane(_consumerId).runtime, 'fresh.txt'), {
            'status': 'success',
          });
          await tester.pumpAndSettle();
          if (retirement == 'display registration') {
            expect(replacements, 1);
          } else {
            expect(_read(target.runtime, 'completed'), {
              'path': 'fresh.txt',
              'session': f.other.id.value,
            });
            expect(target.focuses, 1);
            expect(find.text('Source fresh.txt'), findsOneWidget);
          }
          await tester.pumpWidget(const SizedBox.shrink());
          expect(tester.takeException(), isNull);
        },
      );
    }
  });
}

String _availability(Runtime runtime) =>
    _read(runtime, 'availability') as String;

Object? _read(Runtime runtime, String entrypoint) =>
    copyStructuredBridgeData(runtime.executeLib(_library, entrypoint));

Future<Map<String, Object?>> _invoke(
  Runtime runtime,
  String entrypoint, [
  List<$Value> arguments = const [],
]) async =>
    copyStructuredBridgeData(
          await runtime.executeLib(_library, entrypoint, arguments),
        )
        as Map<String, Object?>;

Future<Map<String, Object?>> _request(Runtime runtime, String path) =>
    _invoke(runtime, 'request', [$String(path)]);

Session _session(String id) => Session(
  id: SessionId(id),
  taskId: TaskId('task'),
  strategyId: OrchestrationStrategyId('test.strategy'),
);

void _publish(AdeleRuntime runtime, List<Session> sessions) {
  final project = Project(
    id: ProjectId('project'),
    sourceLocation: Uri.parse('file:///source-display'),
  );
  final task = Task(id: TaskId('task'), projectId: project.id, title: 'Task');
  final environments = [
    for (final role in EnvironmentRole.values)
      Environment(
        id: EnvironmentId(role.name),
        taskId: task.id,
        role: role,
        providerId: ProviderId('test.unavailable'),
        providerState: const {},
      ),
  ];
  runtime.store.publishRestoredProject(
    project: project,
    tasks: [task],
    environments: environments,
    sessions: sessions,
    authorities: [
      for (final session in sessions) (session.id, EnvironmentId('additional')),
    ],
    runRecords: [],
  );
}

final class _Fixture {
  _Fixture(
    this.generation,
    Directory directory, {
    required bool canonicalRuntime,
  }) {
    _publish(runtime, [session, other]);
    host = PreparedMainContentHost(
      environmentRuntime: canonicalRuntime
          ? runtime.lifecycle.environmentRuntime
          : null,
      confirm: (request) => confirm(request),
      createBinding:
          ({
            required installation,
            required descriptor,
            required session,
            required paneId,
          }) {
            final pane = _Pane(descriptor.extensionId, session);
            panes.add(pane);
            return PreparedMainContentPaneBinding(
              createBridge: (_) =>
                  _RecordingBridge((runtime) => pane.runtime = runtime),
              requestFocus: () => pane.focuses++,
            );
          },
    );
    installation = PreparedPluginInstallation(
      metadata: PluginMetadata(
        id: PluginId('test.source-display'),
        version: '1',
        displayName: 'Source display probe',
      ),
      installationDirectory: directory,
      backendArtifactUri: null,
    );
  }

  final PreparedFrontend generation;
  final runtime = AdeleRuntime();
  final extensions = ExtensionRegistry();
  final session = _session('session');
  final other = _session('other');
  final panes = <_Pane>[];
  final _registrations = <Future<void> Function()>[];
  late final PreparedMainContentHost host;
  late final PreparedPluginInstallation installation;
  Future<bool> Function(Map<String, Object?>) confirm = (_) async => true;

  _Pane pane(ExtensionId id) => panes.lastWhere((pane) => pane.id == id);

  ExtensionRegistration consumer({bool allowed = true}) => _contribute(
    PreparedMainContentPresentation(
      extensionId: _consumerId,
      order: 100,
      library: _library,
      initialize: 'initializeConsumer',
      entrypoint: 'buildConsumer',
      canRequestSourceDisplay: allowed,
      retainedData: true,
      operations: const {'probe': 'operation'},
      actions: [
        PreparedMainContentAction(
          id: 'probe',
          label: 'Probe input',
          entrypoint: 'buildAction',
        ),
      ],
    ),
  );

  ExtensionRegistration _contribute(
    PreparedMainContentPresentation descriptor, {
    ExtensionRegistry? registry,
  }) {
    final registration = (registry ?? extensions).register(
      point: mainContentContributions,
      id: descriptor.extensionId,
      value: host.createContribution(
        extensions: extensions,
        installation: installation,
        generation: generation,
        descriptor: descriptor,
        isActive: () => true,
      ),
    );
    _registrations.add(registration.close);
    return registration;
  }

  ExtensionRegistration nativeProvider(
    Future<Map<String, Object?>> Function(String) display, {
    ExtensionId? id,
  }) {
    final registration = extensions.register(
      point: displaySourceFileContributions,
      id: id ?? _providerId,
      value: DisplaySourceFileContribution(display: display),
    );
    _registrations.add(registration.close);
    return registration;
  }

  ExtensionRegistration preparedProvider({ExtensionRegistry? registry}) {
    final descriptor = PreparedMainContentPresentation(
      extensionId: _providerId,
      order: 200,
      library: _library,
      initialize: 'initializeSource',
      entrypoint: 'buildSource',
      retainedData: true,
      operations: const {'display': 'display'},
      displaySourceFileOperation: 'display',
    );
    _contribute(descriptor, registry: registry);
    late final ExtensionRegistration registration;
    registration = extensions.register(
      point: displaySourceFileContributions,
      id: _providerId,
      value: host.createSourceDisplayContribution(
        descriptor,
        () => !registration.isClosed,
      ),
    );
    _registrations.add(registration.close);
    return registration;
  }

  Widget widget({Session? session}) => MaterialApp(
    home: Scaffold(
      body: MainContentHost(
        session: session ?? this.session,
        extensions: extensions,
        actionCoordinator: host.actionCoordinator,
      ),
    ),
  );

  void expectNoEnvironmentWork() {
    expect(
      runtime.registry.providersFor(environmentProviderCapability),
      isEmpty,
    );
    for (final id in ['primary', 'additional']) {
      expect(
        runtime.lifecycle.environmentRuntime.currentMaterialization(
          EnvironmentId(id),
        ),
        isNull,
      );
    }
    expect(runtime.store.runsForSession(session.id), isEmpty);
  }

  Future<void> close() async {
    for (final close in _registrations.reversed) {
      await close();
    }
    await host.close();
    generation.invalidate();
    await runtime.close();
  }
}

final class _Pane {
  _Pane(this.id, this.session);
  final ExtensionId id;
  final Session session;
  late Runtime runtime;
  var focuses = 0;
}

final class _RecordingBridge implements PreparedFrontendBridge {
  _RecordingBridge(this.record);
  final void Function(Runtime) record;
  @override
  String get identifier => 'test.source-display-recording';
  @override
  void configureForCompile(BridgeDeclarationRegistry registry) {}
  @override
  void configureForRuntime(Runtime runtime) => record(runtime);
  @override
  void invalidate() {}
}

const _source = r'''
import 'package:flutter/material.dart';
import 'package:adele_ui/main_content_bridge.dart';
import 'package:adele_ui/contribution_bridge.dart';

String availability() => sourceDisplayAvailability();
Future<Map<String, dynamic>> request(String path) async => await displaySourceFile(path);
bool removePane() => removeMainContentPane('consumer');

Future<void> initializeConsumer() async {
  final available = sourceDisplayAvailability();
  final result = await displaySourceFile('initializer');
  if (readMainContentPanes().isEmpty) {
    openMainContentPane('consumer', 'Init ' + available + '/' + result['status'], true);
  }
}
Widget buildConsumer() => Text('Consumer body');

Future<Map<String, dynamic>> operation() async {
  final available = sourceDisplayAvailability();
  final result = await displaySourceFile('operation');
  return <String, dynamic>{'availability': available, 'status': result['status']};
}
Future<Map<String, dynamic>> probeOperation() async =>
    await invokeContributionOperation('probe', <String, dynamic>{});
Map<String, dynamic> actionResult() => readContributionData('action-result');
Widget buildAction() => TextButton(
  onPressed: () async {
    final available = sourceDisplayAvailability();
    final result = await displaySourceFile('action');
    writeContributionData('action-result', <String, dynamic>{'availability': available, 'status': result['status']});
  },
  child: Text('Action ' + sourceDisplayAvailability()),
);

void initializeSource() {
  final previous = readContributionData('initializations');
  int count = previous['count'] ?? 0;
  writeContributionData('initializations', <String, dynamic>{'count': count + 1});
  final data = readContributionData('completed');
  String path = data['path'] ?? 'idle';
  if (readMainContentPanes().isEmpty) {
    openMainContentPane('source', 'Source ' + path, false);
  } else {
    setMainContentPaneTitle('source', 'Source ' + path);
  }
}
Widget buildSource() => Text('Source body ' + readMainContentContext()['sessionId']);
Map<String, dynamic> completed() => readContributionData('completed');
Map<String, dynamic> initializations() => readContributionData('initializations');
Future<Map<String, dynamic>> display() async {
  final context = readMainContentContext();
  final arguments = readContributionArguments()!;
  await confirmContribution(<String, dynamic>{
    'title': 'Gate', 'message': 'Admitted', 'acceptLabel': 'Continue', 'cancelLabel': 'Cancel',
  });
  writeContributionData('completed', <String, dynamic>{'path': arguments['path'], 'session': context['sessionId']});
  return <String, dynamic>{'ok': true, 'focus': 'source'};
}
''';
