@Timeout(Duration(minutes: 3))
library;

import 'dart:convert';
import 'dart:io';

import 'package:adele_capabilities/adele_capabilities.dart';
import 'package:adele_desktop/core/application_plugin_bootstrap.dart';
import 'package:adele_desktop/frontend/application_frontend_bootstrap.dart';
import 'package:adele_desktop/ui/main_content/main_content_host.dart';
import 'package:adele_plugin_api/adele_plugin_api.dart';
import 'package:adele_product/adele_product.dart';
import 'package:adele_ui/adele_ui.dart';
import 'package:contract_codegen/contract_codegen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plugin_builder/plugin_builder.dart';
import 'package:plugin_runtime/plugin_runtime.dart';

import '../tool/prepared_capability_frontend_compiler.dart';

const _bound = Duration(seconds: 10);
const _service = 'test.capability.probe';
final _capability = CapabilityKey(
  id: CapabilityId('test.capability.read'),
  majorVersion: 1,
);

void main() {
  late Directory temporary;
  late File hostArtifact;
  late File providerArtifact;
  late File frontendArtifact;
  late String aotRuntime;
  var sequence = 0;

  setUpAll(() async {
    final parent = await Directory('.dart_tool').create(recursive: true);
    temporary = await parent.createTemp('prepared-capability-');
    final dart = _dartExecutable();
    final sdk = File(dart).parent.parent.path;
    aotRuntime = File(dart).parent.uri.resolve('dartaotruntime').toFilePath();
    for (final name in ['contract', 'backend']) {
      await File(
        '${temporary.path}/prepared_capability_$name.dart',
      ).writeAsString(
        await File(
          'test/fixtures/prepared_capability_$name.dart.txt',
        ).readAsString(),
      );
    }
    final contract = File(
      '${temporary.path}/prepared_capability_contract.dart',
    );
    await ContractGenerator(sdkPath: sdk).apply(contract, check: false);
    hostArtifact = File('${temporary.path}/host.aot');
    providerArtifact = File('${temporary.path}/provider.aot');
    frontendArtifact = File('${temporary.path}/frontend.evc');
    await compilePreparedCapabilityFrontend(
      repositoryRoot: Directory.current.parent,
      contract: contract,
      sdkPath: sdk,
      artifact: frontendArtifact,
    );
    for (final target in [
      (
        entrypoint:
            '${Directory.current.parent.path}/packages/plugin_backend_host/bin/adele_backend_host.dart',
        artifact: hostArtifact,
      ),
      (
        entrypoint:
            '${temporary.absolute.path}/prepared_capability_backend.dart',
        artifact: providerArtifact,
      ),
    ]) {
      await compileAotSnapshot(
        dartExecutable: dart,
        workingDirectory: Directory.current.parent,
        entrypoint: target.entrypoint,
        artifact: target.artifact.absolute,
        stage: 'prepared-capability-integration',
      );
    }
  });
  tearDownAll(() => temporary.delete(recursive: true));

  late _Installation fixture;
  setUp(() {
    fixture = _Installation();
    addTearDown(fixture.close);
  });

  Future<void> mount(WidgetTester tester, {bool granted = true}) async {
    tester.view.physicalSize = const Size(1200, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.runAsync(() async {
      final root = await Directory(
        '${temporary.path}/case-${sequence++}',
      ).create();
      for (final id in ['a', 'b']) {
        final directory = await Directory('${root.path}/provider-$id').create();
        await providerArtifact.copy('${directory.path}/backend.aot');
        await _manifest(directory, 'test.backend.$id', {
          'backend': {'artifact': 'backend.aot'},
        });
      }
      final consumer = await Directory('${root.path}/consumer').create();
      await frontendArtifact.copy('${consumer.path}/frontend.evc');
      await _manifest(consumer, 'test.consumer', {
        'frontend': {
          'artifact': 'frontend.evc',
          'presentations': [
            {
              'role': 'mainContent',
              'extensionId': 'test.consumer.pane',
              'order': 100,
              'library': preparedCapabilityFrontendLibrary,
              'initialize': 'initialize',
              'entrypoint': 'buildPane',
              if (granted)
                'capabilities': [
                  {'id': _capability.id.value, 'majorVersion': 1},
                  {'id': _capability.id.value, 'majorVersion': 2},
                  {'id': 'test.capability.missing', 'majorVersion': 1},
                  {'id': 'test.capability.private', 'majorVersion': 1},
                ],
            },
          ],
        },
      });
      await fixture.backends.start(
        installationRoot: root.path,
        dartaotruntimeExecutable: aotRuntime,
        hostArtifactPath: hostArtifact.path,
        startupArguments: {
          for (final id in ['a', 'b']) 'test.backend.$id': [_options(id)],
        },
      );
      expect(fixture.backends.state, ApplicationPluginState.ready);
      expect(fixture.backends.failure, isNull);
      expect(fixture.backends.catalog!.issues, isEmpty);
      for (final backend in fixture.backends.backends) {
        expect(
          backend.state,
          InstalledBackendState.active,
          reason: '${backend.failure}',
        );
        expect(backend.connection!.capabilityExposures, hasLength(1));
      }
      await fixture.frontends.start(fixture.backends.catalog!);
      final frontend = fixture.frontends.generations.single;
      expect(
        frontend.state,
        InstalledFrontendState.active,
        reason: '${frontend.failure}',
      );
    });
    await tester.pumpWidget(fixture.widget());
    await tester.pumpAndSettle();
    expect(find.text('idle'), findsOneWidget);
    expect(find.text('Independent content'), findsOneWidget);
  }

  test(
    'consumer and provider import contracts, never host or peer implementations',
    () async {
      final imports = RegExp(r"import '([^']+)';");
      Future<Set<String>> imported(String name) async => imports
          .allMatches(
            await File(
              'test/fixtures/prepared_capability_$name.dart.txt',
            ).readAsString(),
          )
          .map((match) => match[1]!)
          .toSet();
      expect(await imported('contract'), {
        'package:adele_contract/adele_contract.dart',
      });
      expect(await imported('frontend'), {
        'package:adele_ui/capability_bridge.dart',
        'package:adele_ui/main_content_bridge.dart',
        'package:capability_probe_contract/contract.dart',
        'package:flutter/material.dart',
      });
      expect(await imported('backend'), {
        'dart:async',
        'dart:convert',
        'dart:isolate',
        'package:adele_contract/adele_contract.dart',
        'prepared_capability_contract.dart',
      });
    },
  );

  testWidgets(
    'installed frontend-only EVC discovers and calls independently installed generated AOT providers',
    (tester) async {
      await mount(tester);
      final catalog = fixture.backends.catalog!;
      expect(catalog.installations, hasLength(3));
      final consumer = catalog.installations.singleWhere(
        (entry) => entry.metadata.id.value == 'test.consumer',
      );
      expect(consumer.backendArtifactUri, isNull);
      expect(fixture.backends.backendForInstallation(consumer), isNull);
      expect(
        fixture.extensions.discover(mainContentContributions),
        hasLength(2),
      );
      expect(
        fixture.capabilities.providersFor(_capability).map((p) => p.id.value),
        ['test.provider.b', 'test.provider.a'],
      );
      for (final id in ['a', 'b']) {
        expect(
          (await tester.runAsync(
            () => _snapshot(fixture.connection(id)),
          ))!['requests'],
          isEmpty,
        );
      }

      _press(tester, 'Discover');
      await tester.pump();
      expect(
        find.text(
          'providers|test.provider.b,test.backend.b,Provider B,$_service|test.provider.a,test.backend.a,Provider A,$_service',
        ),
        findsOneWidget,
      );
      _press(tester, 'Default');
      _press(tester, 'Read');
      await _text(tester, 'B:configured-b:0:normal');
      _press(tester, 'Select A');
      _press(tester, 'Read');
      await _text(tester, 'A:configured-a:0:normal');
      _press(tester, 'Select B');
      _press(tester, 'Read');
      await _text(tester, 'B:configured-b:0:normal');
      expect(
        (await tester.runAsync(
          () => _snapshot(fixture.connection('a')),
        ))!['requests'],
        [_request('a', 'read', 'normal')],
      );
      expect(
        (await tester.runAsync(
          () => _snapshot(fixture.connection('b')),
        ))!['requests'],
        [_request('b', 'read', 'normal'), _request('b', 'read', 'normal')],
      );
      await tester.pumpWidget(const SizedBox.shrink());
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'missing, wrong-version, wrong-service, private and undeclared routes send no backend request',
    (tester) async {
      await mount(tester);
      _press(tester, 'Check denials');
      await tester.pump();
      expect(find.text('denials:passed'), findsOneWidget);
      _press(tester, 'Forged handle');
      await _text(tester, 'read:unavailable');
      for (final id in ['a', 'b']) {
        expect(
          (await tester.runAsync(
            () => _snapshot(fixture.connection(id)),
          ))!['requests'],
          isEmpty,
        );
      }
      await tester.pumpWidget(const SizedBox.shrink());
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'ordinary pane without Capability declarations has no ambient access',
    (tester) async {
      await mount(tester, granted: false);
      expect(fixture.capabilities.providersFor(_capability), hasLength(2));
      _press(tester, 'Discover');
      await tester.pump();
      expect(find.text('denied'), findsOneWidget);
      _press(tester, 'Default');
      await tester.pump();
      expect(find.text('selection:unavailable'), findsOneWidget);
      for (final id in ['a', 'b']) {
        expect(
          (await tester.runAsync(
            () => _snapshot(fixture.connection(id)),
          ))!['requests'],
          isEmpty,
        );
      }
      await tester.pumpWidget(const SizedBox.shrink());
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'generated bounded stream completes and gated cancellation reaches the AOT producer',
    (tester) async {
      await mount(tester);
      final connection = fixture.connection('a');
      _press(tester, 'Select A');
      _press(tester, 'Watch bounded');
      await _text(
        tester,
        'stream|A:configured-a:1:first|A:configured-a:2:last:done',
      );
      _press(tester, 'Watch gated');
      await tester.runAsync(() => _wait(connection, 'watch:gated'));
      await tester.runAsync(
        () => _control(connection, 'emit', {'sequence': 3, 'text': 'before'}),
      );
      await _text(tester, 'stream|A:configured-a:3:before');
      _press(tester, 'Cancel');
      await tester.runAsync(() => _wait(connection, 'cancel:gated'));
      await _text(tester, 'stream:cancelled');
      await tester.runAsync(
        () => _control(connection, 'emit', {
          'sequence': 4,
          'text': 'after-cancel',
        }),
      );
      _press(tester, 'Read');
      await _text(tester, 'A:configured-a:0:normal');
      expect(find.textContaining('after-cancel'), findsNothing);
      expect(find.text('stream:cancelled'), findsOneWidget);
      expect(
        (await tester.runAsync(() => _snapshot(connection)))!['requests'],
        [
          _request('a', 'watch', 'bounded'),
          _request('a', 'watch', 'gated'),
          _request('a', 'read', 'normal'),
        ],
      );
      await tester.pumpWidget(const SizedBox.shrink());
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'generated backend failures stay local and released handles cannot invoke',
    (tester) async {
      await mount(tester);
      _press(tester, 'Select A');
      _press(tester, 'Fail');
      await _text(tester, 'read:unavailable');
      _press(tester, 'Watch failure');
      await _text(tester, 'stream:error:Backend stream unavailable.:done');
      _press(tester, 'Read');
      await _text(tester, 'A:configured-a:0:normal');
      _press(tester, 'Override route');
      await _text(tester, 'override:rejected');
      _press(tester, 'Release');
      await tester.pump();
      expect(find.text('released'), findsOneWidget);
      _press(tester, 'Read saved A');
      await _text(tester, 'read:unavailable');
      _press(tester, 'Release');
      await tester.pump();
      expect(find.text('already released'), findsOneWidget);
      _press(tester, 'Select B');
      _press(tester, 'Read');
      await _text(tester, 'B:configured-b:0:normal');
      expect(find.textContaining('SECRET'), findsNothing);
      expect(find.text('Frontend unavailable.'), findsNothing);
      expect(
        (await tester.runAsync(
          () => _snapshot(fixture.connection('a')),
        ))!['requests'],
        [
          _request('a', 'read', 'fail'),
          _request('a', 'watch', 'fail'),
          _request('a', 'read', 'normal'),
          {
            ..._request('a', 'read', 'normal'),
            'payload': {
              'scope': 'normal',
              'serviceId': 'test.capability.private',
              'configurationContext': 'configured-b',
              'hostInvocationContext': 'forged',
            },
          },
        ],
      );
      await tester.pumpWidget(const SizedBox.shrink());
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'terminated pending provider fails locally, sibling survives, and same-ID replacement never revives a captured handle',
    (tester) async {
      await mount(tester);
      final old = fixture.connection('a');
      _press(tester, 'Select B');
      _press(tester, 'Select A');
      _press(tester, 'Held');
      await tester.runAsync(() => _wait(old, 'read:held'));
      await tester.runAsync(() async {
        final retired = fixture.backends.changes.firstWhere(
          (_) =>
              fixture.backends.backends
                  .singleWhere((b) => b.connection == old)
                  .state ==
              InstalledBackendState.terminated,
        );
        await expectLater(
          _control(old, 'terminate'),
          throwsA(isA<PluginRemoteFailure>()),
        );
        await old.terminated.timeout(_bound);
        await retired.timeout(_bound);
      });
      await _text(tester, 'read:unavailable');
      expect(
        fixture.capabilities.providersFor(_capability).map((p) => p.id.value),
        ['test.provider.b'],
      );
      _press(tester, 'Read saved B');
      await _text(tester, 'B:configured-b:0:normal');
      final replacement = (await tester.runAsync(() async {
        final connection = await fixture.backends.host!.startPlugin(
          pluginId: 'test.backend.a',
          artifactUri: providerArtifact.absolute.uri,
          arguments: [_options('a', identity: 'A2')],
        );
        final activation = await PluginCapabilityActivation.registerAdvertised(
          connection: connection,
          registry: fixture.capabilities,
        );
        fixture.replacement = activation;
        return connection;
      }))!;
      _press(tester, 'Read saved A');
      await _text(tester, 'read:unavailable');
      expect(
        (await tester.runAsync(() => _snapshot(replacement)))!['requests'],
        isEmpty,
      );
      _press(tester, 'Select A');
      _press(tester, 'Read');
      await _text(tester, 'A2:configured-a:0:normal');
      _press(tester, 'Read saved B');
      await _text(tester, 'B:configured-b:0:normal');
      expect(
        (await tester.runAsync(() => _snapshot(replacement)))!['requests'],
        [_request('a', 'read', 'normal')],
      );
      expect(fixture.backends.host!.isClosed, isFalse);
      await tester.pumpWidget(const SizedBox.shrink());
      expect(tester.takeException(), isNull);
    },
  );

  for (final departure in ['navigation', 'frontend retirement']) {
    testWidgets(
      '$departure cancels a live stream and fences captured callbacks without affecting providers',
      (tester) async {
        await mount(tester);
        final connection = fixture.connection('a');
        _press(tester, 'Select A');
        _press(tester, 'Watch gated');
        await tester.runAsync(() => _wait(connection, 'watch:gated'));
        await tester.runAsync(
          () =>
              _control(connection, 'emit', {'sequence': 1, 'text': 'visible'}),
        );
        await _text(tester, 'stream|A:configured-a:1:visible');
        _press(tester, 'Held');
        await tester.runAsync(() => _wait(connection, 'read:held'));
        final staleRead = _callback(tester, 'Read');
        final staleResolve = _callback(tester, 'Default');
        if (departure == 'navigation') {
          fixture.frontends.unbind(fixture.session);
          await tester.pumpWidget(const SizedBox.shrink());
        } else {
          await tester.runAsync(fixture.frontends.generations.single.close);
          await tester.pumpAndSettle();
          expect(find.text('Independent content'), findsOneWidget);
        }
        staleRead();
        staleResolve();
        await tester.runAsync(() async {
          await _wait(connection, 'cancel:gated');
          await _control(connection, 'release');
          await _control(connection, 'emit', {
            'sequence': 2,
            'text': 'late-private-result',
          });
        });
        await tester.pumpAndSettle();
        expect(find.textContaining('late-private-result'), findsNothing);
        expect(find.textContaining(':0:held'), findsNothing);
        expect(fixture.capabilities.providersFor(_capability), hasLength(2));
        expect(
          (await tester.runAsync(() => _snapshot(connection)))!['requests'],
          [_request('a', 'watch', 'gated'), _request('a', 'read', 'held')],
        );
        if (departure == 'navigation') {
          await tester.pumpWidget(fixture.widget());
          await tester.pumpAndSettle();
          expect(find.text('idle'), findsOneWidget);
          _press(tester, 'Default');
          _press(tester, 'Read');
          await _text(tester, 'B:configured-b:0:normal');
        }
        await tester.pumpWidget(const SizedBox.shrink());
        expect(tester.takeException(), isNull);
      },
    );
  }
}

final class _Installation {
  _Installation() {
    backends = ApplicationPluginBootstrap(capabilities, extensions);
    frontends = ApplicationFrontendBootstrap(
      extensions: extensions,
      backends: backends,
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

  final capabilities = CapabilityRegistry();
  final extensions = ExtensionRegistry();
  final session = Session(
    id: SessionId('session'),
    taskId: TaskId('task'),
    strategyId: OrchestrationStrategyId('test.uninstalled-strategy'),
  );
  late final ApplicationPluginBootstrap backends;
  late final ApplicationFrontendBootstrap frontends;
  PluginCapabilityActivation? replacement;

  PluginBackendConnection connection(String id) => backends.backends
      .singleWhere(
        (entry) => entry.installation.metadata.id.value == 'test.backend.$id',
      )
      .connection!;

  Widget widget() => MaterialApp(
    home: Scaffold(
      body: MainContentHost(session: session, extensions: extensions),
    ),
  );

  Future<void> close() async {
    await frontends.close();
    await replacement?.close();
    await backends.close();
  }
}

Future<void> _manifest(
  Directory directory,
  String id,
  Map<String, Object?> components,
) => File('${directory.path}/adele_plugin.installation.json').writeAsString(
  jsonEncode({
    'manifestVersion': 1,
    'metadata': {'id': id, 'version': '1', 'displayName': id},
    'components': components,
  }),
);

String _options(String id, {String? identity}) => jsonEncode({
  'identity': identity ?? id.toUpperCase(),
  'providerId': 'test.provider.$id',
  'context': 'configured-$id',
  'rank': id == 'a' ? 10 : 20,
});

Map<String, Object?> _request(String id, String method, String scope) => {
  'configurationContext': 'configured-$id',
  'serviceId': _service,
  'method': '$_service.$method',
  'payload': {'scope': scope},
  'hostInvocationContext': null,
};

Future<Object?> _control(
  PluginBackendConnection connection,
  String method, [
  Map<String, Object?> payload = const {},
]) => connection
    .channelFor(connection.defaultConfigurationContext, 'probe')
    .request(method, payload)
    .timeout(_bound);

Future<void> _wait(PluginBackendConnection connection, String key) async {
  await _control(connection, 'wait', {'key': key, 'count': 1});
}

Future<Map<String, Object?>> _snapshot(
  PluginBackendConnection connection,
) async =>
    Map<String, Object?>.from(await _control(connection, 'snapshot') as Map);

VoidCallback _callback(WidgetTester tester, String label) => tester
    .widget<TextButton>(find.widgetWithText(TextButton, label))
    .onPressed!;

void _press(WidgetTester tester, String label) => _callback(tester, label)();

// Wait for the observable result, yielding the real I/O queue rather than sleeping
// for a guessed backend latency. Producer admission/cancellation use explicit gates.
Future<void> _text(WidgetTester tester, String text) async {
  await tester.runAsync(() async {
    final deadline = DateTime.now().add(_bound);
    while (find.text(text).evaluate().isEmpty &&
        DateTime.now().isBefore(deadline)) {
      await Future<void>(() {});
      await tester.pump();
    }
  });
  expect(find.text(text), findsOneWidget);
}

String _dartExecutable() {
  final root = Platform.environment['FLUTTER_ROOT'];
  if (root != null) {
    final dart = File('$root/bin/cache/dart-sdk/bin/dart');
    if (dart.existsSync()) return dart.path;
  }
  var directory = File(Platform.resolvedExecutable).parent;
  while (!File('${directory.path}/dart-sdk/bin/dart').existsSync()) {
    if (directory.parent.path == directory.path) {
      throw StateError('Pinned Dart SDK not found.');
    }
    directory = directory.parent;
  }
  return '${directory.path}/dart-sdk/bin/dart';
}
