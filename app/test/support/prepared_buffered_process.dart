import 'dart:convert';
import 'dart:io';

import 'package:adele_capabilities/adele_capabilities.dart';
import 'package:adele_contract/adele_contract.dart';
import 'package:adele_desktop/core/application_plugin_bootstrap.dart';
import 'package:adele_desktop/frontend/application_frontend_bootstrap.dart';
import 'package:adele_environment/adele_environment.dart';
import 'package:adele_product/adele_product.dart';
import 'package:contract_codegen/contract_codegen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plugin_builder/plugin_builder.dart';

import '../../tool/prepared_environment_capability_frontend_compiler.dart';
import 'prepared_environment_capability_installation.dart';

const bufferedWait = Duration(seconds: 15);
final bufferedCapability = CapabilityKey(
  id: CapabilityId('test.capability.buffered'),
  majorVersion: 1,
);

/// Each suite builds its own host, independent callable and EVC consumer.
/// The caller supplies the Environment backend for each fresh installation.
final class PreparedBufferedProcess {
  PreparedBufferedProcess(this.repositoryRoot);

  final Directory repositoryRoot;
  late final Directory temporary;
  late final File _host;
  late final File _callable;
  late final File _frontend;
  final _dart = File(
    '${Platform.environment['FLUTTER_ROOT']!}/bin/cache/dart-sdk/bin/dart',
  );

  File fixtureSource(String name) =>
      File('${repositoryRoot.path}/app/test/fixtures/$name.dart.txt');

  Future<File> copyFixture(String name) =>
      fixtureSource(name).copy('${temporary.path}/$name.dart');

  Future<void> prepare() async {
    // Keep generated sources inside the resolved workspace regardless of which
    // Flutter package launched this suite.
    final parent = await Directory(
      '${repositoryRoot.path}/app/.dart_tool',
    ).create(recursive: true);
    temporary = await parent.createTemp('prepared-buffered-process-');
    addTearDown(() => temporary.delete(recursive: true));

    final sdk = _dart.parent.parent.path;
    final contract = await copyFixture('prepared_capability_contract');
    await ContractGenerator(sdkPath: sdk).apply(contract, check: false);
    await copyFixture('prepared_environment_capability_support');
    final callable = await copyFixture(
      'prepared_environment_buffered_process_callable',
    );
    _frontend = File('${temporary.path}/frontend.evc');
    await compilePreparedEnvironmentCapabilityFrontend(
      repositoryRoot: repositoryRoot,
      contract: contract,
      sdkPath: sdk,
      artifact: _frontend,
      frontendFixture:
          'prepared_environment_buffered_process_frontend.dart.txt',
    );
    _host = await compileBackend(
      'packages/plugin_backend_host/bin/adele_backend_host.dart',
      'host',
    );
    _callable = await compileBackend(callable.path, 'callable');
  }

  Future<File> compileBackend(String entrypoint, String name) async {
    final artifact = File('${temporary.path}/$name.aot');
    await compileAotSnapshot(
      dartExecutable: _dart.path,
      workingDirectory: repositoryRoot,
      entrypoint: entrypoint,
      artifact: artifact,
      stage: 'prepared-buffered-process',
    );
    return artifact;
  }

  Future<PreparedEnvironmentCapabilityInstallation> mount(
    WidgetTester tester, {
    required File environmentArtifact,
    required String environmentPlugin,
    List<String> environmentArguments = const [],
    Uri? sourceLocation,
    List<Environment>? environments,
    bool processGrant = true,
    bool readGrant = false,
    bool concurrent = false,
    bool present = true,
    int providers = 1,
    List<AdeleEnvironmentHostService>? secondPermissions,
    List<AdeleEnvironmentHostService> permissions = const [
      AdeleEnvironmentHostService.bufferedProcess,
    ],
    CapabilityRegistry? registry,
  }) async {
    tester.view.physicalSize = const Size(1600, 3200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final fixture = PreparedEnvironmentCapabilityInstallation(
      capabilities: registry,
      files: temporary,
      independent: true,
      environmentPlugin: environmentPlugin,
      sourceLocation: sourceLocation,
      environments: environments,
    );
    addTearDown(fixture.close);
    await tester.runAsync(() async {
      final root = await temporary.createTemp('case-');
      for (final (id, artifact) in [
        (environmentPlugin, environmentArtifact),
        (callablePluginId, _callable),
      ]) {
        final installation = await Directory('${root.path}/$id').create();
        await artifact.copy('${installation.path}/backend.aot');
        await _manifest(installation, id, {
          'backend': {'artifact': 'backend.aot'},
        });
      }
      final consumer = await Directory('${root.path}/consumer').create();
      await _frontend.copy('${consumer.path}/frontend.evc');
      await _manifest(consumer, 'test.buffered.consumer', {
        'frontend': {
          'artifact': 'frontend.evc',
          'presentations': [
            {
              'role': 'mainContent',
              'extensionId': 'test.buffered.pane',
              'order': 100,
              'library': preparedEnvironmentCapabilityFrontendLibrary,
              'initialize': 'initialize',
              'entrypoint': 'buildPane',
              'capabilities': [
                {'id': bufferedCapability.id.value, 'majorVersion': 1},
              ],
              if (processGrant)
                'environmentBufferedProcessCapabilities': [
                  {'id': bufferedCapability.id.value, 'majorVersion': 1},
                ],
              if (readGrant)
                'environmentReadCapabilities': [
                  {'id': bufferedCapability.id.value, 'majorVersion': 1},
                ],
            },
          ],
        },
      });
      await fixture.backends.start(
        installationRoot: root.path,
        dartaotruntimeExecutable: _dart.parent.uri
            .resolve('dartaotruntime')
            .toFilePath(),
        hostArtifactPath: _host.path,
        startupArguments: {
          if (environmentArguments.isNotEmpty)
            environmentPlugin: environmentArguments,
          callablePluginId: [
            jsonEncode({
              'exposures': _callableExposures(
                providers,
                permissions,
                secondPermissions,
              ),
            }),
          ],
        },
      );
      expect(fixture.backends.state, ApplicationPluginState.ready);
      expect(fixture.backends.failure, isNull);
      expect(fixture.backends.catalog!.issues, isEmpty);
      expect(fixture.backends.catalog!.installations, hasLength(3));
      expect(fixture.backends.backends, hasLength(2));
      for (final backend in fixture.backends.backends) {
        expect(
          backend.state,
          InstalledBackendState.active,
          reason: '${backend.failure}',
        );
        expect(backend.installation.frontend, isNull);
      }
      await fixture.frontends.start(fixture.backends.catalog!);
      final frontend = fixture.frontends.generations.single;
      expect(
        frontend.state,
        InstalledFrontendState.active,
        reason: '${frontend.failure}',
      );
      expect(frontend.installation.backendArtifactUri, isNull);
      expect(
        fixture.backends.backendForInstallation(frontend.installation),
        isNull,
      );
    });
    if (present) {
      await tester.pumpWidget(fixture.widget(concurrent: concurrent));
      await tester.pumpAndSettle();
      expect(
        find.text('idle'),
        findsNWidgets(concurrent ? 2 : 1),
        reason: tester
            .widgetList<Text>(find.byType(Text))
            .map((text) => text.data)
            .join(' | '),
      );
    }
    return fixture;
  }
}

List<Map<String, Object?>> _callableExposures(
  int count,
  List<AdeleEnvironmentHostService> permissions,
  List<AdeleEnvironmentHostService>? secondPermissions,
) => [
  for (final id in [
    ...['a', 'b'].take(count),
    'context-free',
  ])
    AdeleCapabilityExposure(
      providerId: 'test.callable.$id',
      capabilityId: bufferedCapability.id.value,
      capabilityMajorVersion: 1,
      serviceId: probeServiceId,
      displayName: id,
      configurationContext: id == 'context-free' ? id : 'callable-shared',
      rank: id == 'a' ? 1 : 100,
      environmentBound: id != 'context-free',
      environmentHostServices: id == 'context-free'
          ? const []
          : id == 'b'
          ? secondPermissions ?? permissions
          : permissions,
    ).toMap(),
];

Future<void> _manifest(
  Directory root,
  String id,
  Map<String, Object?> components,
) => File('${root.path}/adele_plugin.installation.json').writeAsString(
  jsonEncode({
    'manifestVersion': 1,
    'metadata': {'id': id, 'version': '1', 'displayName': id},
    'components': components,
  }),
);

Finder _pane(String pane, Finder matching) =>
    find.descendant(of: find.byKey(ValueKey(pane)), matching: matching);
VoidCallback buttonCallback(
  WidgetTester tester,
  String label, {
  String pane = 'a',
}) => tester
    .widget<TextButton>(_pane(pane, find.widgetWithText(TextButton, label)))
    .onPressed!;
void press(WidgetTester tester, String label, {String pane = 'a'}) =>
    buttonCallback(tester, label, pane: pane)();

Future<void> waitForText(
  WidgetTester tester,
  String text, {
  String pane = 'a',
}) async {
  await tester.pump();
  final finder = _pane(pane, find.text(text));
  await tester.runAsync(() async {
    final deadline = DateTime.now().add(bufferedWait);
    while (finder.evaluate().isEmpty && DateTime.now().isBefore(deadline)) {
      await Future<void>(() {});
      await tester.pump();
    }
  });
  expect(finder, findsOneWidget);
}

Future<void> select(
  WidgetTester tester, {
  String pane = 'a',
  String button = 'Default',
}) async {
  press(tester, button, pane: pane);
  await waitForText(tester, 'selected', pane: pane);
}

String bufferedResult(
  List<int> stdout, {
  int exitCode = 0,
  List<int> stderr = const [],
}) => 'buffered|${base64Encode(stdout)}|$exitCode|${base64Encode(stderr)}';

Future<Map<Object?, Object?>> callableSnapshot(
  PreparedEnvironmentCapabilityInstallation h,
) async => (await h.control('snapshot'))! as Map<Object?, Object?>;

Future<void> expectDenied(
  PreparedEnvironmentCapabilityInstallation h,
  String token, {
  String? service,
  String? method,
  Map<String, Object?>? arguments,
}) async {
  expect(
    await h.control('attackBuffered', {
      'token': token,
      'service': ?service,
      'method': ?method,
      'arguments': ?arguments,
    }),
    {'ok': false},
  );
  if (service == null && method == null && arguments == null) {
    expect(
      await h.control('attackBuffered', {
        'token': token,
        'method': authorizedEnvironmentBufferedProcessServiceCapturedIdentityId,
        'arguments': <String, Object?>{},
      }),
      {'ok': false},
    );
  }
}
