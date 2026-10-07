@Timeout(Duration(minutes: 2))
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:adele_capabilities/adele_capabilities.dart';
import 'package:adele_core_extensions/adele_core_extensions.dart';
import 'package:adele_core_extensions/remote_command.dart';
import 'package:adele_desktop/application.dart';
import 'package:adele_desktop/core/application_plugin_bootstrap.dart';
import 'package:adele_desktop/core/remote_inference_context_host.dart';
import 'package:adele_desktop/frontend/application_frontend_bootstrap.dart';
import 'package:adele_desktop/terminal/native_adele_runtime.dart';
import 'package:adele_desktop/ui/commands/command_palette.dart';
import 'package:adele_desktop/ui/shell/adele_shell.dart';
import 'package:adele_environment/adele_environment.dart';
import 'package:adele_model_provider/adele_model_provider.dart';
import 'package:adele_model_tool/adele_model_tool.dart';
import 'package:adele_orchestration/adele_orchestration.dart';
import 'package:adele_plugin_api/adele_plugin_api.dart';
import 'package:adele_ui/adele_ui.dart';
import 'package:dart_eval/dart_eval.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plugin_builder/plugin_builder.dart';
import 'package:plugin_runtime/plugin_runtime.dart';

const _pluginId = 'dev.adele.test.remote-command';
const _bound = Duration(seconds: 10);

void main() {
  late Directory artifacts;
  late File hostArtifact;
  late File probeArtifact;
  late String aotRuntime;

  setUpAll(() async {
    artifacts = await Directory.systemTemp.createTemp('adele-remote-command-');
    addTearDown(() => artifacts.delete(recursive: true));
    final dart = _dartExecutable();
    aotRuntime = File.fromUri(
      File(dart).parent.uri.resolve(
        Platform.isWindows ? 'dartaotruntime.exe' : 'dartaotruntime',
      ),
    ).path;
    hostArtifact = File.fromUri(artifacts.uri.resolve('host.aot'));
    probeArtifact = File.fromUri(artifacts.uri.resolve('probe.aot'));
    for (final target in [
      (
        entrypoint: 'packages/plugin_backend_host/bin/adele_backend_host.dart',
        artifact: hostArtifact,
      ),
      (
        entrypoint: 'app/test/core/fixtures/remote_command_probe.dart',
        artifact: probeArtifact,
      ),
    ]) {
      await compileAotSnapshot(
        dartExecutable: dart,
        workingDirectory: Directory.current.parent,
        entrypoint: target.entrypoint,
        artifact: target.artifact,
        stage: 'remote-command-integration',
      );
    }
  });

  group('remote adapter', () {
    late PluginBackendHost host;
    late CapabilityRegistry capabilities;
    late ExtensionRegistry extensions;
    late CommandResolver commands;

    setUp(() async {
      host = await PluginBackendHost.start(
        dartaotruntimeExecutable: aotRuntime,
        hostArtifactPath: hostArtifact.path,
      );
      addTearDown(host.close);
      capabilities = CapabilityRegistry();
      extensions = ExtensionRegistry();
      commands = CommandResolver(extensions);
    });

    Future<PluginBackendConnection> connect({
      String pluginId = _pluginId,
      List<Map<String, Object?>>? exposures,
    }) async {
      final connection = await host.startPlugin(
        pluginId: pluginId,
        artifactUri: probeArtifact.uri,
        arguments: [
          jsonEncode({'exposures': exposures ?? _exposures()}),
        ],
      );
      addTearDown(connection.close);
      return connection;
    }

    Future<PluginBackendActivation> activate(
      PluginBackendConnection connection,
    ) async {
      final activation = await PluginBackendActivation.registerAdvertised(
        connection: connection,
        capabilities: capabilities,
        extensions: extensions,
        adapters: createRemoteExtensionAdapters(),
      );
      addTearDown(activation.close);
      return activation;
    }

    Future<PluginBackendActivation> start({
      String pluginId = _pluginId,
      List<Map<String, Object?>>? exposures,
    }) async =>
        activate(await connect(pluginId: pluginId, exposures: exposures));

    test(
      'local reads make no requests; routes and configurations coexist',
      () async {
        final maxRoute = 'A${'x' * 251}._:-';
        expect(maxRoute.length, 256);
        final exposures = [
          _exposure('success'),
          _exposure('second', routeId: 'second.route-2:ok'),
          _exposure(
            'configured',
            routeId: 'success',
            configuration: 'alternate',
          ),
          _exposure('maximum', routeId: maxRoute),
        ];
        final probe = await start(exposures: exposures);
        expect(probe.connection.capabilityExposures, isEmpty);
        expect(
          probe.connection.extensionExposures.map((e) => e.toMap()),
          exposures,
        );
        expect(extensions.discover(commandContributions), hasLength(4));
        for (var read = 0; read < 3; read++) {
          expect(commands.discover(), hasLength(4));
          for (final command in commands.discover()) {
            expect(command.availability, CommandAvailability.enabled);
            expect(
              command.binding.value.availability(),
              CommandAvailability.enabled,
            );
            expect(
              commands
                  .resolve(command.id)
                  .binding
                  .isSameRegistration(command.binding),
              isTrue,
            );
          }
        }
        expect(await _snapshot(probe.connection), {
          'requests': <Object?>[],
          'invocations': <Object?>[],
        });
        for (final name in ['second', 'configured', 'maximum', 'success']) {
          await commands.resolve(_commandId(name)).invoke().timeout(_bound);
        }
        final snapshot = await _snapshot(probe.connection);
        final routes = ['second.route-2:ok', 'success', maxRoute, 'success'];
        final contexts = ['default', 'alternate', 'default', 'default'];
        expect(snapshot['requests'], [
          for (var index = 0; index < routes.length; index++)
            _request(routes[index], configuration: contexts[index]),
        ]);
        expect(snapshot['invocations'], [
          for (var index = 0; index < routes.length; index++)
            _invocation(routes[index], configuration: contexts[index]),
        ]);
      },
    );

    test(
      'native, real remote and prepared frontend Commands compose in one registry',
      () async {
        final probe = await start(exposures: [_exposure('success')]);
        var nativeCalls = 0;
        final nativeId = _commandId('native');
        final native = extensions.register(
          point: commandContributions,
          id: ExtensionId('$_pluginId.native'),
          value: CommandContribution(
            id: nativeId,
            label: 'Native Command',
            availability: () => CommandAvailability.enabled,
            invoke: () => nativeCalls++,
          ),
        );
        addTearDown(native.close);
        final directory = await Directory.systemTemp.createTemp(
          'adele-command-coexistence-',
        );
        addTearDown(() => directory.delete(recursive: true));
        final installation = await Directory(
          '${directory.path}/frontend',
        ).create();
        const library = 'package:command_coexistence/main.dart';
        final compiler = Compiler()..entrypoints.add(library);
        final program = compiler.compile({
          'command_coexistence': {
            'main.dart': "void invoke() { print('prepared command invoked'); }",
          },
        });
        await File(
          '${installation.path}/frontend.evc',
        ).writeAsBytes(program.write());
        final preparedId = _commandId('prepared');
        await File(
          '${installation.path}/adele_plugin.installation.json',
        ).writeAsString(
          jsonEncode({
            'manifestVersion': 1,
            'metadata': {
              'id': '$_pluginId.frontend',
              'version': '0.1.0',
              'displayName': 'Prepared Command probe',
            },
            'components': {
              'frontend': {
                'artifact': 'frontend.evc',
                'presentations': <Object?>[],
                'extensions': [
                  PreparedCommandExtension(
                    extensionId: ExtensionId('$_pluginId.prepared'),
                    commandId: preparedId,
                    label: 'Prepared Command',
                    library: library,
                    entrypoint: 'invoke',
                  ).toJson(),
                ],
              },
            },
          }),
        );
        final frontends = ApplicationFrontendBootstrap(extensions: extensions);
        addTearDown(frontends.close);
        final catalog = await PreparedPluginCatalog.discover(directory.path);
        expect(catalog.issues, isEmpty);
        expect(catalog.installations.single.backendArtifactUri, isNull);
        await frontends.start(catalog);
        expect(
          frontends.generations.single.state,
          InstalledFrontendState.active,
        );
        expect(extensions.discover(commandContributions), hasLength(3));
        expect(commands.discover().map((command) => command.id), [
          nativeId,
          preparedId,
          _commandId('success'),
        ]);
        for (final command in commands.discover()) {
          expect(command.availability, CommandAvailability.enabled);
        }
        expect(await _snapshot(probe.connection), {
          'requests': <Object?>[],
          'invocations': <Object?>[],
        });
        final prepared = commands.resolve(preparedId);
        final output = <String>[];
        await runZoned(
          () async {
            await commands.resolve(nativeId).invoke();
            await prepared.invoke();
            await commands
                .resolve(_commandId('success'))
                .invoke()
                .timeout(_bound);
          },
          zoneSpecification: ZoneSpecification(
            print: (_, _, _, line) => output.add(line),
          ),
        );
        expect(nativeCalls, 1);
        expect(output, ['prepared command invoked']);
        expect(await _snapshot(probe.connection), {
          'requests': [_request('success')],
          'invocations': [_invocation('success')],
        });
        final conflict = extensions.register(
          point: commandContributions,
          id: ExtensionId('$_pluginId.prepared-conflict'),
          value: CommandContribution(
            id: preparedId,
            label: 'Native conflict',
            availability: () => CommandAvailability.enabled,
            invoke: () => nativeCalls++,
          ),
        );
        addTearDown(conflict.close);
        expect(
          () => commands.resolve(preparedId),
          throwsA(isA<AmbiguousCommand>()),
        );
        expect(commands.discover().map((command) => command.id), [
          nativeId,
          _commandId('success'),
        ]);
        expect(prepared.availability, CommandAvailability.disabled);
        await expectLater(prepared.invoke(), throwsA(isA<AmbiguousCommand>()));
        expect(nativeCalls, 1);
        await conflict.close();
        expect(
          commands
              .resolve(preparedId)
              .binding
              .isSameRegistration(prepared.binding),
          isTrue,
        );
        expect(prepared.availability, CommandAvailability.enabled);
      },
    );

    test(
      'native and remote semantic identity conflicts use ordinary resolution',
      () async {
        final probe = await start();
        final captured = commands.resolve(_commandId('success'));
        var nativeCalls = 0;
        final native = extensions.register(
          point: commandContributions,
          id: ExtensionId('$_pluginId.native'),
          value: CommandContribution(
            id: captured.id,
            label: 'Native conflict',
            availability: () => CommandAvailability.enabled,
            invoke: () => nativeCalls++,
          ),
        );
        addTearDown(native.close);
        expect(
          () => commands.resolve(captured.id),
          throwsA(isA<AmbiguousCommand>()),
        );
        expect(
          commands.discover().map((c) => c.id),
          isNot(contains(captured.id)),
        );
        expect(captured.availability, CommandAvailability.disabled);
        await expectLater(captured.invoke(), throwsA(isA<AmbiguousCommand>()));
        expect(await _snapshot(probe.connection), {
          'requests': <Object?>[],
          'invocations': <Object?>[],
        });
        expect(nativeCalls, 0);
        await native.close();
        await commands.resolve(captured.id).invoke().timeout(_bound);
        expect((await _snapshot(probe.connection))['invocations'], [
          _invocation('success'),
        ]);
      },
    );

    test(
      'retirement and same-ID replacement never retarget captured bindings or callbacks',
      () async {
        final old = await start();
        final captured = commands.resolve(_commandId('success'));
        final callback = captured.binding.value.invoke;
        final availability = captured.binding.value.availability;
        final sibling = await start(
          pluginId: '$_pluginId.sibling',
          exposures: [_exposure('sibling', routeId: 'success')],
        );
        await old.retire().timeout(_bound);
        expect(old.connection.isClosed, isFalse);
        expect(commands.discover().map((c) => c.id), [_commandId('sibling')]);
        expect(
          captured.binding.validate,
          throwsA(isA<StaleExtensionBinding>()),
        );
        expect(availability, throwsA(isA<StaleExtensionBinding>()));
        expect(captured.availability, CommandAvailability.disabled);
        await expectLater(
          captured.invoke(),
          throwsA(isA<StaleExtensionBinding>()),
        );
        await expectLater(
          Future<void>.sync(callback),
          throwsA(isA<StaleExtensionBinding>()),
        );
        expect(await _snapshot(old.connection), {
          'requests': <Object?>[],
          'invocations': <Object?>[],
        });
        await old.close();
        final replacement = await start();
        await old.close();
        await old.retire();
        expect(commands.discover(), hasLength(4));
        await expectLater(
          captured.invoke(),
          throwsA(isA<StaleExtensionBinding>()),
        );
        await expectLater(
          Future<void>.sync(callback),
          throwsA(isA<StaleExtensionBinding>()),
        );
        expect(await _snapshot(replacement.connection), {
          'requests': <Object?>[],
          'invocations': <Object?>[],
        });
        final fresh = commands.resolve(captured.id);
        expect(fresh.binding.isSameRegistration(captured.binding), isFalse);
        await fresh.invoke().timeout(_bound);
        await commands.resolve(_commandId('sibling')).invoke().timeout(_bound);
        expect((await _snapshot(replacement.connection))['invocations'], [
          _invocation('success'),
        ]);
        expect((await _snapshot(sibling.connection))['invocations'], [
          _invocation('success'),
        ]);
        expect(sibling.connection.isClosed, isFalse);
        expect(host.isClosed, isFalse);
      },
    );

    test(
      'an admitted held invocation completes after registration retirement',
      () async {
        final probe = await start();
        final captured = commands.resolve(_commandId('held'));
        var settled = false;
        final invocation = captured.invoke().then((_) => settled = true);
        final completed = expectLater(invocation, completes);
        await _control(probe.connection, 'ready', {'count': 1});
        expect((await _snapshot(probe.connection))['invocations'], [
          _invocation('held', state: 'held'),
        ]);
        await probe.retire().timeout(_bound);
        expect(commands.discover(), isEmpty);
        expect(captured.availability, CommandAvailability.disabled);
        expect(probe.connection.isClosed, isFalse);
        expect(settled, isFalse);
        await _control(probe.connection, 'release');
        await completed.timeout(_bound);
        expect(settled, isTrue);
        expect((await _snapshot(probe.connection))['invocations'], [
          _invocation('held'),
        ]);
        expect(probe.connection.isClosed, isFalse);
      },
    );

    test(
      'termination fails a pending request and retires only its connection',
      () async {
        final probe = await start();
        final captured = commands.resolve(_commandId('held'));
        final failed = expectLater(
          captured.invoke(),
          throwsA(isA<PluginRemoteFailure>()),
        );
        await _control(probe.connection, 'ready', {'count': 1});
        final sibling = await start(
          pluginId: '$_pluginId.sibling',
          exposures: [_exposure('sibling', routeId: 'success')],
        );
        final terminated = probe.connection.terminated.timeout(_bound);
        await expectLater(
          _control(probe.connection, 'terminate'),
          throwsA(isA<PluginRemoteFailure>()),
        );
        await terminated;
        await failed.timeout(_bound);
        expect(probe.connection.isClosed, isTrue);
        expect(
          captured.binding.validate,
          throwsA(isA<StaleExtensionBinding>()),
        );
        expect(
          () => commands.resolve(captured.id),
          throwsA(isA<CommandNotFound>()),
        );
        expect(commands.discover().map((c) => c.id), [_commandId('sibling')]);
        await commands.resolve(_commandId('sibling')).invoke().timeout(_bound);
        expect((await _snapshot(sibling.connection))['invocations'], [
          _invocation('success'),
        ]);
        expect(host.isClosed, isFalse);
      },
    );

    test(
      'generated remote failure propagates without retiring other routes',
      () async {
        final probe = await start();
        await expectLater(
          commands.resolve(_commandId('fail')).invoke(),
          throwsA(
            isA<PluginRemoteFailure>().having(
              (e) => e.code,
              'code',
              'internal_error',
            ),
          ),
        );
        await commands.resolve(_commandId('success')).invoke().timeout(_bound);
        expect((await _snapshot(probe.connection))['invocations'], [
          _invocation('fail', state: 'failed'),
          _invocation('success'),
        ]);
        expect(probe.connection.isClosed, isFalse);
      },
    );

    final metadata = _metadata('success');
    final invalid = <String, ({Map<String, Object?> exposure, Matcher error})>{
      for (final service in [
        'dev.adele.command.remote.other',
        'DEV.ADELE.COMMAND.REMOTE',
        'other.dev.adele.command.remote',
      ])
        'service $service': (
          exposure: _exposure('success', serviceId: service),
          error: isA<ExtensionContractException>(),
        ),
      for (final key in ['commandId', 'label', 'routeId'])
        'missing $key': (
          exposure: _exposure('success', metadata: {...metadata}..remove(key)),
          error: isA<ExtensionContractException>(),
        ),
      for (final key in ['commandId', 'label', 'routeId'])
        'non-string $key': (
          exposure: _exposure('success', metadata: {...metadata, key: 42}),
          error: isA<ExtensionContractException>(),
        ),
      'extra authority metadata': (
        exposure: _exposure(
          'success',
          metadata: {...metadata, 'hostInvocationContext': 'forged'},
        ),
        error: isA<ExtensionContractException>(),
      ),
      for (final id in ['', 'unqualified', 'dev.adele.Bad'])
        'semantic ID $id': (
          exposure: _exposure(
            'success',
            metadata: {...metadata, 'commandId': id},
          ),
          error: isA<FormatException>(),
        ),
      for (final label in [' ', 'bad\nlabel', 'x' * 161])
        'semantic label ${label.length}': (
          exposure: _exposure(
            'success',
            metadata: {...metadata, 'label': label},
          ),
          error: isA<ArgumentError>(),
        ),
      for (final route in <String, String>{
        'empty': '',
        'blank': ' ',
        'slash': 'route/name',
        'non-ASCII': 'rout\u00e9',
        'control': 'route\n',
        'too long': 'r' * 257,
        'leading punctuation': '.route',
      }.entries)
        '${route.key} route': (
          exposure: _exposure('success', routeId: route.value),
          error: isA<ExtensionContractException>(),
        ),
    };
    for (final entry in invalid.entries) {
      test('invalid ${entry.key} rolls back preceding registrations', () async {
        final native = extensions.register(
          point: commandContributions,
          id: ExtensionId('$_pluginId.unrelated'),
          value: CommandContribution(
            id: _commandId('unrelated'),
            label: 'Unrelated native command',
            availability: () => CommandAvailability.enabled,
            invoke: () {},
          ),
        );
        addTearDown(native.close);
        final retained = commands.resolve(_commandId('unrelated'));
        final connection = await connect(
          exposures: [_exposure('partial'), entry.value.exposure],
        );
        await expectLater(activate(connection), throwsA(entry.value.error));
        expect(connection.isClosed, isTrue);
        expect(commands.discover().map((c) => c.id), [retained.id]);
        expect(retained.binding.validate, returnsNormally);
        expect(host.isClosed, isFalse);
        final healthy = await start(
          exposures: [_exposure('partial'), _exposure('success')],
        );
        expect(commands.discover(), hasLength(3));
        expect(await _snapshot(healthy.connection), {
          'requests': <Object?>[],
          'invocations': <Object?>[],
        });
      });
    }
  });

  testWidgets(
    'backend-only prepared installation participates in the actual pre-Project palette',
    (tester) async {
      final directory = Directory.systemTemp.createTempSync(
        'adele-command-installation-',
      );
      addTearDown(() => directory.deleteSync(recursive: true));
      final installation = Directory('${directory.path}/command')..createSync();
      probeArtifact.copySync('${installation.path}/backend.aot');
      File(
        '${installation.path}/adele_plugin.installation.json',
      ).writeAsStringSync(
        jsonEncode({
          'manifestVersion': 1,
          'metadata': {
            'id': _pluginId,
            'version': '0.1.0',
            'displayName': 'Remote Command probe',
          },
          'components': {
            'backend': {'artifact': 'backend.aot'},
          },
        }),
      );
      final runtime = NativeAdeleRuntime();
      final commands = CommandResolver(runtime.extensions);
      try {
        late Future<void> starting;
        await tester.runAsync(() async {
          await tester.pumpWidget(
            AdeleApplication(
              createRuntime: () => runtime,
              readChatGptConfiguration: () => null,
              bootstrapPlugins: (plugins) => starting = plugins.start(
                installationRoot: directory.path,
                dartaotruntimeExecutable: aotRuntime,
                hostArtifactPath: hostArtifact.path,
                startupArguments: {
                  _pluginId: [
                    jsonEncode({'exposures': _exposures()}),
                  ],
                },
              ),
            ),
          );
          await starting.timeout(_bound);
        });
        await tester.pumpAndSettle();
        expect(runtime.plugins.state, ApplicationPluginState.ready);
        expect(runtime.plugins.failure, isNull);
        expect(runtime.plugins.catalog!.issues, isEmpty);
        final prepared = runtime.plugins.catalog!.installations.single;
        expect(prepared.metadata.id.value, _pluginId);
        expect(prepared.backendArtifactUri, isNotNull);
        expect(prepared.frontend, isNull);
        final backend = runtime.plugins.backends.single;
        expect(backend.state, InstalledBackendState.active);
        expect(backend.validate, returnsNormally);
        final connection = backend.connection!;
        expect(
          connection.extensionExposures.map((e) => e.toMap()),
          _exposures(),
        );
        expect(connection.capabilityExposures, isEmpty);
        expect(
          runtime.registry.providersFor(environmentProviderCapability),
          isEmpty,
        );
        expect(runtime.registry.providersFor(modelProviderCapability), isEmpty);
        expect(
          runtime.extensions.discover(projectSelectorContributions),
          isEmpty,
        );
        expect(runtime.extensions.discover(modelToolContributions), isEmpty);
        expect(runtime.extensions.discover(inferenceContextSources), isEmpty);
        expect(
          runtime.extensions.discover(orchestrationStrategyContributions),
          isEmpty,
        );
        expect(runtime.extensions.discover(mainContentContributions), isEmpty);
        expect(runtime.extensions.discover(consoleContributions), isEmpty);
        expect(runtime.extensions.discover(taskBrowserContributions), isEmpty);
        expect(
          tester.widget<AdeleShell>(find.byType(AdeleShell)).project,
          isNull,
        );
        expect(find.text('No Project is open'), findsOneWidget);
        final captured = commands.resolve(_commandId('success'));
        expect(captured.availability, CommandAvailability.enabled);
        expect(commands.discover(), hasLength(5));
        await _openPalette(tester);
        for (final name in ['success', 'fail', 'held']) {
          expect(
            tester
                .widget<ListTile>(find.widgetWithText(ListTile, _label(name)))
                .enabled,
            isTrue,
          );
        }
        await tester.enterText(
          find.byKey(const ValueKey('command-palette-search')),
          'remote-command.command.success',
        );
        await tester.pumpAndSettle();
        expect(find.text(_label('success')), findsOneWidget);
        expect(find.text(_label('fail')), findsNothing);
        expect(await tester.runAsync(() => _snapshot(connection)), {
          'requests': <Object?>[],
          'invocations': <Object?>[],
        });

        await tester.tap(find.text(_label('success')));
        await tester.pumpAndSettle();
        await tester.runAsync(
          () => _control(connection, 'ready', {'count': 1}),
        );
        await tester.pumpAndSettle();
        expect(find.byType(CommandPalette), findsNothing);
        expect(await tester.runAsync(() => _snapshot(connection)), {
          'requests': [_request('success')],
          'invocations': [_invocation('success')],
        });

        await tester.runAsync(
          () => expectLater(
            commands.resolve(_commandId('fail')).invoke(),
            throwsA(
              isA<PluginRemoteFailure>().having(
                (e) => e.code,
                'code',
                'internal_error',
              ),
            ),
          ),
        );
        await _openPalette(tester);
        await tester.tap(find.text(_label('fail')));
        await tester.pumpAndSettle();
        await tester.runAsync(
          () => _control(connection, 'ready', {'count': 3}),
        );
        await tester.pumpAndSettle();
        expect(find.byType(CommandPalette), findsNothing);
        expect(
          find.text('The command could not be completed.'),
          findsOneWidget,
        );
        expect(
          find.textContaining('private backend command diagnostic'),
          findsNothing,
        );
        expect(find.textContaining('PluginRemoteFailure'), findsNothing);
        expect(
          find.textContaining('The backend request failed unexpectedly.'),
          findsNothing,
        );
        expect(tester.takeException(), isNull);
        expect(await tester.runAsync(() => _snapshot(connection)), {
          'requests': [_request('success'), _request('fail'), _request('fail')],
          'invocations': [
            _invocation('success'),
            _invocation('fail', state: 'failed'),
            _invocation('fail', state: 'failed'),
          ],
        });

        await _openPalette(tester);
        final staleTap = tester
            .widget<ListTile>(find.widgetWithText(ListTile, _label('success')))
            .onTap!;
        await tester.runAsync(() async {
          final retired = runtime.plugins.changes.firstWhere(
            (_) => backend.state == InstalledBackendState.terminated,
          );
          await expectLater(
            _control(connection, 'terminate'),
            throwsA(isA<PluginRemoteFailure>()),
          );
          await connection.terminated.timeout(_bound);
          await retired.timeout(_bound);
        });
        await tester.pumpAndSettle();
        expect(backend.state, InstalledBackendState.terminated);
        expect(runtime.plugins.host!.isClosed, isFalse);
        expect(find.byType(CommandPalette), findsOneWidget);
        for (final name in ['success', 'fail', 'held']) {
          expect(find.text(_label(name)), findsNothing);
        }
        expect(find.text('No commands are available.'), findsOneWidget);
        expect(
          captured.binding.validate,
          throwsA(isA<StaleExtensionBinding>()),
        );
        expect(captured.availability, CommandAvailability.disabled);
        await expectLater(
          captured.invoke(),
          throwsA(isA<StaleExtensionBinding>()),
        );
        staleTap();
        await tester.pumpAndSettle();
        expect(find.byType(CommandPalette), findsOneWidget);
        expect(commands.discover(), hasLength(2));
        expect(
          tester.widget<AdeleShell>(find.byType(AdeleShell)).project,
          isNull,
        );
        expect(tester.takeException(), isNull);
      } finally {
        await tester.runAsync(() async {
          try {
            if (find.byType(AdeleApplication).evaluate().isNotEmpty) {
              await tester.binding.handleRequestAppExit();
            }
          } finally {
            await tester.pumpWidget(const SizedBox.shrink());
            await runtime.close();
          }
        });
        await tester.pumpAndSettle();
      }
    },
  );
}

CommandId _commandId(String name) => CommandId('$_pluginId.command.$name');

String _label(String name) => 'Remote $name';

Map<String, Object?> _metadata(String name, {String? routeId}) => {
  'commandId': _commandId(name).value,
  'label': _label(name),
  'routeId': routeId ?? name,
};

Map<String, Object?> _exposure(
  String name, {
  String? routeId,
  String configuration = 'default',
  String serviceId = remoteCommandServiceId,
  Map<String, Object?>? metadata,
}) => {
  'extensionPointId': commandContributions.value,
  'extensionId': '$_pluginId.registration.$name',
  'serviceId': serviceId,
  'configurationContext': configuration,
  'metadata': metadata ?? _metadata(name, routeId: routeId),
};

List<Map<String, Object?>> _exposures() => [
  for (final name in ['success', 'fail', 'held']) _exposure(name),
];

Map<String, Object?> _request(
  String route, {
  String configuration = 'default',
}) => {
  'configurationContext': configuration,
  'serviceId': remoteCommandServiceId,
  'method': remoteCommandServiceInvokeId,
  'payload': {'routeId': route},
};

Map<String, Object?> _invocation(
  String route, {
  String configuration = 'default',
  String state = 'completed',
}) => {'configurationContext': configuration, 'routeId': route, 'state': state};

Future<Object?> _control(
  PluginBackendConnection connection,
  String method, [
  Map<String, Object?> payload = const {},
]) => connection
    .channelFor(connection.defaultConfigurationContext, 'probe')
    .request(method, payload)
    .timeout(_bound);

Future<Map<String, Object?>> _snapshot(
  PluginBackendConnection connection,
) async =>
    Map<String, Object?>.from(await _control(connection, 'snapshot') as Map);

Future<void> _openPalette(WidgetTester tester) async {
  await tester.tap(find.byKey(const ValueKey('command-palette-button')));
  await tester.pumpAndSettle();
  expect(find.byType(CommandPalette), findsOneWidget);
}

String _dartExecutable() {
  final flutterRoot = Platform.environment['FLUTTER_ROOT'];
  if (flutterRoot != null) {
    final executable = File.fromUri(
      Directory(flutterRoot).uri.resolve(
        'bin/cache/dart-sdk/bin/${Platform.isWindows ? 'dart.exe' : 'dart'}',
      ),
    );
    if (executable.existsSync()) return executable.path;
  }
  final executable = File(Platform.resolvedExecutable);
  if (executable.parent.path.endsWith(
    '${Platform.pathSeparator}dart-sdk${Platform.pathSeparator}bin',
  )) {
    return executable.path;
  }
  throw StateError('Unable to locate the Dart SDK executable for AOT tests.');
}
