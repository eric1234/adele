@Timeout(Duration(minutes: 3))
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:adele_capabilities/adele_capabilities.dart';
import 'package:adele_core_extensions/adele_core_extensions.dart';
import 'package:adele_desktop/core/application_plugin_bootstrap.dart';
import 'package:adele_desktop/core/prepared_settings.dart';
import 'package:adele_desktop/core/window_session_context.dart';
import 'package:adele_desktop/frontend/application_frontend_bootstrap.dart';
import 'package:adele_desktop/frontend/capability_access_bridge.dart';
import 'package:adele_desktop/frontend/directory_picker_bridge.dart';
import 'package:adele_desktop/frontend/environment_access_bridge.dart';
import 'package:adele_desktop/frontend/environment_capability_access_bridge.dart';
import 'package:adele_desktop/frontend/main_content_bridge.dart';
import 'package:adele_desktop/frontend/owning_backend_bridge.dart';
import 'package:adele_desktop/frontend/session_execution_bridge.dart';
import 'package:adele_plugin_api/adele_plugin_api.dart';
import 'package:adele_product/adele_product.dart';
import 'package:adele_ui/adele_ui.dart';
import 'package:contract_codegen/contract_codegen.dart';
import 'package:dart_eval/dart_eval.dart';
import 'package:file_selector_platform_interface/file_selector_platform_interface.dart';
import 'package:flutter_eval/flutter_eval.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plugin_builder/plugin_builder.dart';
import 'package:plugin_runtime/plugin_runtime.dart';

const _library = 'package:session_command_probe/main.dart';
const _service = 'test.capability.probe';
const _plugin = 'test.session.owner';
const _bound = Duration(seconds: 10);

CommandId _id(String name) => CommandId('test.session.$name');

Session _session(String id) => Session(
  id: SessionId('session-$id'),
  taskId: TaskId('task'),
  strategyId: OrchestrationStrategyId('test.uninstalled-strategy'),
);

void main() {
  late Directory temporary;
  late File hostArtifact;
  late File backendArtifact;
  late File frontendArtifact;
  late String aotRuntime;
  var sequence = 0;

  setUpAll(() async {
    final parent = await Directory('.dart_tool').create(recursive: true);
    temporary = await parent.createTemp('prepared-session-command-');
    final dart = _dartExecutable();
    final sdk = File(dart).parent.parent.path;
    aotRuntime = File(dart).parent.uri.resolve('dartaotruntime').toFilePath();
    // Reuse the real generated unary/stream service and bounded probe gates.
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
    final generator = ContractGenerator(sdkPath: sdk);
    await generator.apply(contract, check: false);
    final generated = await generator.generateEvalClient(contract);
    final compiler = Compiler()
      ..addPlugin(flutterEvalPlugin)
      ..addPlugin(const OwningBackendDeclarations())
      ..addPlugin(const DirectoryPickerDeclarations())
      ..addPlugin(const MainContentDeclarations())
      ..addPlugin(const CapabilityAccessDeclarations())
      ..addPlugin(const EnvironmentAccessDeclarations())
      ..addPlugin(const EnvironmentCapabilityAccessDeclarations())
      ..addPlugin(const SessionExecutionDeclarations())
      ..entrypoints.addAll([
        _library,
        'package:session_command_probe/contract.dart',
        'package:adele_contract/adele_contract.dart',
      ]);
    final program = compiler.compile({
      'session_command_probe': {
        'main.dart': await File(
          'test/fixtures/prepared_session_command.dart.txt',
        ).readAsString(),
        'contract.dart': generated,
      },
      'adele_contract': {'adele_contract.dart': evalContractSupportSource},
      'adele_ui': {
        for (final name in [
          'owning_backend_bridge',
          'directory_picker_bridge',
          'main_content_bridge',
          'capability_bridge',
          'environment_access_bridge',
          'environment_capability_bridge',
          'session_execution_bridge',
        ])
          '$name.dart': await File(
            '../packages/ui/lib/$name.dart',
          ).readAsString(),
      },
    });
    frontendArtifact = File('${temporary.path}/frontend.evc');
    await frontendArtifact.writeAsBytes(program.write());
    hostArtifact = File('${temporary.path}/host.aot');
    backendArtifact = File('${temporary.path}/backend.aot');
    for (final target in [
      (
        entrypoint:
            '${Directory.current.parent.path}/packages/plugin_backend_host/bin/adele_backend_host.dart',
        artifact: hostArtifact,
      ),
      (
        entrypoint:
            '${temporary.absolute.path}/prepared_capability_backend.dart',
        artifact: backendArtifact,
      ),
    ]) {
      await compileAotSnapshot(
        dartExecutable: dart,
        workingDirectory: Directory.current.parent,
        entrypoint: target.entrypoint,
        artifact: target.artifact.absolute,
        stage: 'prepared-session-command',
      );
    }
  });
  tearDownAll(() => temporary.delete(recursive: true));

  late Directory root;
  late ExtensionRegistry extensions;
  late ApplicationPluginBootstrap backends;
  late ApplicationFrontendBootstrap frontends;
  late WindowSessionContextHost selection;
  late CommandResolver commands;

  setUp(() async {
    root = await Directory('${temporary.path}/case-${sequence++}').create();
    extensions = ExtensionRegistry();
    backends = ApplicationPluginBootstrap(CapabilityRegistry(), extensions);
    selection = WindowSessionContextHost();
    frontends = ApplicationFrontendBootstrap(
      extensions: extensions,
      backends: backends,
      sessionContext: selection.context,
    );
    commands = CommandResolver(extensions);
  });
  tearDown(() async {
    await frontends.close();
    selection.close();
    await backends.close();
  });

  Future<void> install(
    List<Map<String, Object?>> descriptors, {
    String pluginId = _plugin,
    bool backend = false,
    bool brokenBackend = false,
    List<int>? bytes,
    Directory? installationRoot,
  }) async {
    final directory = await Directory(
      '${(installationRoot ?? root).path}/$pluginId',
    ).create();
    if (bytes == null) {
      await frontendArtifact.copy('${directory.path}/frontend.evc');
    } else {
      await File('${directory.path}/frontend.evc').writeAsBytes(bytes);
    }
    if (backend) {
      if (brokenBackend) {
        await File('${directory.path}/backend.aot').writeAsBytes([0]);
      } else {
        await backendArtifact.copy('${directory.path}/backend.aot');
      }
    }
    await File(
      '${directory.path}/adele_plugin.installation.json',
    ).writeAsString(
      jsonEncode({
        'manifestVersion': 1,
        'metadata': {'id': pluginId, 'version': '1', 'displayName': pluginId},
        'components': {
          if (backend) 'backend': {'artifact': 'backend.aot'},
          'frontend': {
            'artifact': 'frontend.evc',
            'presentations': <Object?>[],
            'extensions': descriptors,
          },
        },
      }),
    );
  }

  Future<void> start({bool backend = false, Directory? frontendRoot}) async {
    final PreparedPluginCatalog catalog;
    if (backend) {
      await backends.start(
        installationRoot: root.path,
        dartaotruntimeExecutable: aotRuntime,
        hostArtifactPath: hostArtifact.path,
        startupArguments: {
          _plugin: [_options()],
          'test.session.foreign': [
            _options(identity: 'FOREIGN', foreignService: true),
          ],
        },
      );
      expect(backends.failure, isNull);
      catalog = frontendRoot == null
          ? backends.catalog!
          : await PreparedPluginCatalog.discover(frontendRoot.path);
    } else {
      catalog = await PreparedPluginCatalog.discover(root.path);
    }
    expect(catalog.issues, isEmpty);
    await frontends.start(catalog);
  }

  PluginBackendConnection connection() => backends.backends
      .singleWhere((entry) => entry.installation.metadata.id.value == _plugin)
      .connection!;

  void expectActive() {
    for (final generation in frontends.generations) {
      expect(
        generation.state,
        InstalledFrontendState.active,
        reason: '${generation.failure}',
      );
    }
  }

  test(
    'metadata and selection invalidations are independent of backend and panes',
    () async {
      await install([
        _descriptor('local', 'local'),
        PreparedCommandExtension(
          extensionId: ExtensionId('test.session.independent.registration'),
          commandId: _id('independent'),
          label: 'Independent',
          library: _library,
          entrypoint: 'independent',
        ).toJson(),
      ]);
      await start();
      expectActive();
      expect(
        frontends.catalog!.installations.single.backendArtifactUri,
        isNull,
      );
      expect(extensions.discover(mainContentContributions), isEmpty);
      expect(extensions.discover(consoleContributions), isEmpty);
      expect(extensions.discover(taskBrowserContributions), isEmpty);
      final command = commands.resolve(_id('local'));
      expect(command.label, 'Session local');
      expect(command.binding.id.value, 'test.session.local.registration');
      expect(command.availability, CommandAvailability.hidden);
      expect(
        commands.resolve(_id('independent')).availability,
        CommandAvailability.enabled,
      );
      await expectLater(command.invoke(), throwsA(isA<CommandUnavailable>()));
      var invalidations = 0;
      final subscription = command.binding.value.availabilityChanges!.listen((
        _,
      ) {
        invalidations++;
      });
      addTearDown(subscription.cancel);
      selection.presentSession(_session('a'));
      await Future<void>(() {});
      expect(invalidations, greaterThan(0));
      expect(command.availability, CommandAvailability.enabled);
      await command.invoke();
      await command.invoke();
      final previous = invalidations;
      selection.presentSession(null);
      await Future<void>(() {});
      expect(invalidations, greaterThan(previous));
      expect(command.availability, CommandAvailability.hidden);
      await commands.resolve(_id('independent')).invoke();
      expect(backends.host, isNull);
    },
  );

  test('an absent window context does not infer a Session', () async {
    await frontends.close();
    frontends = ApplicationFrontendBootstrap(extensions: extensions);
    selection.presentSession(_session('a'));
    await install([_descriptor('local', 'local')]);
    await start();
    expectActive();
    final command = commands.resolve(_id('local'));
    expect(command.availability, CommandAvailability.hidden);
    await expectLater(command.invoke(), throwsA(isA<CommandUnavailable>()));
  });

  for (final failure in ['absent', 'failed']) {
    test(
      '$failure backend disables only Commands requiring services',
      () async {
        await install(
          [
            _descriptor('local', 'local'),
            _descriptor('unary', 'unary', services: [_service]),
          ],
          backend: failure == 'failed',
          brokenBackend: failure == 'failed',
        );
        await start(backend: failure == 'failed');
        expectActive();
        if (failure == 'failed') {
          expect(backends.backends.single.state, InstalledBackendState.failed);
        }
        expect(
          commands.resolve(_id('unary')).availability,
          CommandAvailability.hidden,
        );
        selection.presentSession(_session('a'));
        expect(
          commands.resolve(_id('unary')).availability,
          CommandAvailability.disabled,
        );
        await expectLater(
          commands.resolve(_id('unary')).invoke(),
          throwsA(isA<CommandUnavailable>()),
        );
        await commands.resolve(_id('local')).invoke();
      },
    );
  }

  test(
    'backend readiness invalidates availability without delaying frontend activation',
    () async {
      await frontends.close();
      await backends.close();
      final discovered = Completer<PreparedPluginCatalog>();
      final ready = Completer<void>();
      backends = ApplicationPluginBootstrap(
        CapabilityRegistry(),
        extensions,
        loadSettings: (catalog) async {
          discovered.complete(catalog);
          await ready.future;
          return PreparedSettingsSnapshot.resolve(catalog);
        },
      );
      frontends = ApplicationFrontendBootstrap(
        extensions: extensions,
        backends: backends,
        sessionContext: selection.context,
      );
      await install([
        _descriptor('local', 'local'),
        _descriptor('unary', 'unary', services: [_service]),
      ], backend: true);
      final starting = backends.start(
        installationRoot: root.path,
        dartaotruntimeExecutable: aotRuntime,
        hostArtifactPath: hostArtifact.path,
        startupArguments: {
          _plugin: [_options()],
        },
      );
      addTearDown(() {
        if (!ready.isCompleted) ready.complete();
        return starting;
      });
      await frontends.start(await discovered.future.timeout(_bound));
      expectActive();
      selection.presentSession(_session('a'));
      final command = commands.resolve(_id('unary'));
      expect(command.availability, CommandAvailability.disabled);
      await commands.resolve(_id('local')).invoke();
      final enabled = command.binding.value.availabilityChanges!.firstWhere(
        (_) => command.availability == CommandAvailability.enabled,
      );
      ready.complete();
      await starting.timeout(_bound);
      await enabled.timeout(_bound);
      // Readiness and availability observation did not execute plugin services.
      expect((await _snapshot(connection()))['requests'], isEmpty);
      await command.invoke().timeout(_bound);
    },
  );

  test(
    'same plugin ID and service from another installation are not an owner',
    () async {
      await install([], backend: true);
      final otherRoot = await Directory('${root.path}/other-root').create();
      await install([
        _descriptor('local', 'local'),
        _descriptor('unary', 'unary', services: [_service]),
      ], installationRoot: otherRoot);
      await start(backend: true, frontendRoot: otherRoot);
      expectActive();
      selection.presentSession(_session('a'));
      expect(backends.backends.single.state, InstalledBackendState.active);
      expect(connection().capabilityExposures.single.serviceId, _service);
      expect(
        commands.resolve(_id('unary')).availability,
        CommandAvailability.disabled,
      );
      await commands.resolve(_id('local')).invoke();
      expect((await _snapshot(connection()))['requests'], isEmpty);
    },
  );

  test(
    'invocation captures A synchronously, survives navigation, and later captures B',
    () async {
      await install([
        _descriptor('captured', 'captured', services: [_service]),
        _descriptor('unary', 'unary', services: [_service]),
      ], backend: true);
      await start(backend: true);
      expectActive();
      final backend = connection();
      final command = commands.resolve(_id('captured'));
      expect((await _snapshot(backend))['requests'], isEmpty);
      selection.presentSession(_session('a'));
      expect(command.availability, CommandAvailability.enabled);
      final pending = command.invoke();
      // No yield between admission and navigation: capture must be native/synchronous.
      selection.presentSession(_session('b'));
      await _wait(backend, 'read:held');
      await _control(backend, 'release');
      await pending.timeout(_bound);
      await commands.resolve(_id('unary')).invoke().timeout(_bound);
      expect((await _snapshot(backend))['requests'], [
        _request('read', 'held'),
        _request('read', 'session-a'),
        _request('read', 'session-b'),
      ]);
    },
  );

  test(
    'generated unary and bounded server-streaming DTOs cross the real transport',
    () async {
      await install([
        _descriptor('bounded', 'bounded', services: [_service]),
      ], backend: true);
      await start(backend: true);
      selection.presentSession(_session('a'));
      final pending = commands.resolve(_id('bounded')).invoke();
      await _wait(connection(), 'read:held');
      await _wait(connection(), 'read:bounded-done');
      await _control(connection(), 'release');
      await pending.timeout(_bound);
      expect((await _snapshot(connection()))['requests'], [
        _request('watch', 'bounded'),
        _request('read', 'held'),
        _request('read', 'bounded-done'),
        _request('read', 'session-a'),
      ]);
    },
  );

  test(
    'generated subscription pause/resume/cancel retains its captured Session',
    () async {
      await install([
        _descriptor('paused', 'paused', services: [_service]),
      ], backend: true);
      await start(backend: true);
      selection.presentSession(_session('a'));
      final backend = connection();
      final pending = commands.resolve(_id('paused')).invoke();
      await _wait(backend, 'watch:gated');
      await _wait(backend, 'read:held');
      selection.presentSession(_session('b'));
      await _control(backend, 'emit', {'sequence': 1, 'text': 'queued'});
      await _wait(backend, 'pause:gated');
      expect((await _snapshot(backend))['requests'], [
        _request('watch', 'gated'),
        _request('read', 'held'),
      ]);
      await _control(backend, 'release', {'scope': 'held'});
      await _wait(backend, 'read:held-completion');
      await _wait(backend, 'read:delivered');
      await _wait(backend, 'resume:gated');
      await _control(backend, 'release', {'scope': 'held-completion'});
      await pending.timeout(_bound);
      await _wait(backend, 'cancel:gated');
      await _control(backend, 'emit', {'sequence': 2, 'text': 'after-cancel'});
      expect((await _snapshot(backend))['requests'], [
        _request('watch', 'gated'),
        _request('read', 'held'),
        _request('read', 'held-completion'),
        _request('read', 'delivered'),
        _request('read', 'session-a'),
      ]);
    },
  );

  test(
    'undeclared and foreign routes fail without dispatch or ambient authority',
    () async {
      await install([
        _descriptor('no-grant', 'unary'),
        for (final name in [
          'undeclared',
          'foreign',
          'picker',
          'panes',
          'capabilities',
          'environmentRead',
          'environmentWrite',
          'environmentProcess',
          'execution',
          'approval',
        ])
          _descriptor(name.toLowerCase(), name, services: [_service]),
        _descriptor('failure', 'backendFailure', services: [_service]),
        _descriptor('unary', 'unary', services: [_service]),
      ], backend: true);
      await install([], pluginId: 'test.session.foreign', backend: true);
      await start(backend: true);
      selection.presentSession(_session('a'));
      final originalPicker = FileSelectorPlatform.instance;
      final picker = _Picker();
      FileSelectorPlatform.instance = picker;
      addTearDown(() => FileSelectorPlatform.instance = originalPicker);
      for (final name in [
        'no-grant',
        'undeclared',
        'foreign',
        'picker',
        'panes',
        'capabilities',
        'environmentread',
        'environmentwrite',
        'environmentprocess',
        'execution',
        'approval',
      ]) {
        await expectLater(
          commands.resolve(_id(name)).invoke().timeout(_bound),
          throwsA(anything),
        );
      }
      expect(picker.calls, 0);
      for (final backend in backends.backends) {
        expect((await _snapshot(backend.connection!))['requests'], isEmpty);
      }
      await commands.resolve(_id('failure')).invoke().timeout(_bound);
      await commands.resolve(_id('unary')).invoke().timeout(_bound);
      expect((await _snapshot(connection()))['requests'], [
        _request('read', 'fail'),
        _request('read', 'session-a'),
      ]);
      expectActive();
    },
  );

  test(
    'declared service health fails on its owner without routing to a foreign service',
    () async {
      await install([
        _descriptor('missing', 'foreign', services: ['test.foreign.service']),
        _descriptor('unary', 'unary', services: [_service]),
      ], backend: true);
      await install([], pluginId: 'test.session.foreign', backend: true);
      await start(backend: true);
      selection.presentSession(_session('a'));
      final missing = commands.resolve(_id('missing'));
      expect(missing.availability, CommandAvailability.enabled);
      expect((await _snapshot(connection()))['requests'], isEmpty);
      await expectLater(missing.invoke().timeout(_bound), throwsA(anything));
      final foreign = backends.backends.singleWhere(
        (backend) =>
            backend.installation.metadata.id.value == 'test.session.foreign',
      );
      expect((await _snapshot(foreign.connection!))['requests'], isEmpty);
      await commands.resolve(_id('unary')).invoke().timeout(_bound);
      expectActive();
    },
  );

  test(
    'malformed results and operation failures do not retire sibling Commands',
    () async {
      await install([
        for (final name in [
          'local',
          'malformed',
          'malformedAsync',
          'wrongArgument',
          'failure',
        ])
          _descriptor(name.toLowerCase(), name),
      ]);
      await start();
      selection.presentSession(_session('a'));
      for (final name in ['malformed', 'malformedasync']) {
        await expectLater(
          commands.resolve(_id(name)).invoke(),
          throwsFormatException,
        );
      }
      for (final name in ['wrongargument', 'failure']) {
        await expectLater(
          commands.resolve(_id(name)).invoke(),
          throwsA(anything),
        );
      }
      await commands.resolve(_id('local')).invoke();
      expectActive();
    },
  );

  for (final malformed in ['entrypoint', 'bytecode']) {
    test(
      'malformed $malformed rolls back its frontend before publication',
      () async {
        await install([
          _descriptor('local', 'local'),
          _descriptor(
            'invalid',
            malformed == 'entrypoint' ? 'notInArtifact' : 'local',
          ),
        ], bytes: malformed == 'bytecode' ? [1, 2, 3] : null);
        await start();
        expect(
          frontends.generations.single.state,
          InstalledFrontendState.failed,
        );
        expect(frontends.generations.single.registrations, isEmpty);
        expect(commands.discover(), isEmpty);
      },
    );
  }

  test(
    'duplicate semantic identities use ordinary ambiguity regardless of availability',
    () async {
      await install([
        _descriptor('duplicate', 'local'),
        {
          ..._descriptor('other', 'unary', services: [_service]),
          'commandId': _id('duplicate').value,
        },
      ]);
      await start();
      expectActive();
      selection.presentSession(_session('a'));
      expect(extensions.discover(commandContributions), hasLength(2));
      expect(commands.discover(), isEmpty);
      expect(
        () => commands.resolve(_id('duplicate')),
        throwsA(isA<AmbiguousCommand>()),
      );
      await frontends.generations.single.retire(
        commandContributions,
        ExtensionId('test.session.other.registration'),
      );
      await commands.resolve(_id('duplicate')).invoke();
    },
  );

  test(
    'registration-only retirement leaves admitted work on its captured owner',
    () async {
      await install([
        _descriptor('captured', 'captured', services: [_service]),
        _descriptor('local', 'local'),
      ], backend: true);
      await start(backend: true);
      selection.presentSession(_session('a'));
      final captured = commands.resolve(_id('captured'));
      final pending = captured.invoke();
      await _wait(connection(), 'read:held');
      await frontends.generations.single.retire(
        commandContributions,
        captured.binding.id,
      );
      selection.presentSession(_session('b'));
      await _control(connection(), 'release');
      await pending.timeout(_bound);
      expect((await _snapshot(connection()))['requests'], [
        _request('read', 'held'),
        _request('read', 'session-a'),
      ]);
      await expectLater(
        captured.invoke(),
        throwsA(isA<StaleExtensionBinding>()),
      );
      await commands.resolve(_id('local')).invoke();
    },
  );

  test(
    'retired registration and raw callback cannot retarget a same-ID replacement',
    () async {
      await install([_descriptor('local', 'local')]);
      await start();
      selection.presentSession(_session('a'));
      final captured = commands.resolve(_id('local'));
      final callback = captured.binding.value.invoke;
      await frontends.generations.single.retire(
        commandContributions,
        captured.binding.id,
      );
      final replacement = ApplicationFrontendBootstrap(
        extensions: extensions,
        sessionContext: selection.context,
      );
      addTearDown(replacement.close);
      await replacement.start(await PreparedPluginCatalog.discover(root.path));
      final fresh = commands.resolve(captured.id);
      expect(fresh.binding.isSameRegistration(captured.binding), isFalse);
      expect(captured.availability, CommandAvailability.disabled);
      await expectLater(
        captured.invoke(),
        throwsA(isA<StaleExtensionBinding>()),
      );
      await expectLater(Future<void>.sync(callback), throwsStateError);
      await fresh.invoke();
    },
  );

  for (final retirement in ['frontend', 'stopStarting', 'close', 'window']) {
    test(
      '$retirement fences pending unary continuation and stale admission',
      () async {
        await install([
          _descriptor('captured', 'captured', services: [_service]),
          _descriptor('local', 'local'),
        ], backend: true);
        await start(backend: true);
        selection.presentSession(_session('a'));
        final backend = connection();
        final command = commands.resolve(_id('captured'));
        final stale = command.binding.value.invoke;
        final pending = expectLater(command.invoke(), throwsA(anything));
        await _wait(backend, 'read:held');
        switch (retirement) {
          case 'frontend':
            await frontends.generations.single.close();
          case 'stopStarting':
            frontends.stopStarting();
          case 'close':
            await frontends.close();
          case 'window':
            selection.close();
        }
        await _control(backend, 'release');
        await pending.timeout(_bound);
        expect(command.availability, isNot(CommandAvailability.enabled));
        await expectLater(Future<void>.sync(stale), throwsA(anything));
        expect((await _snapshot(backend))['requests'], [
          _request('read', 'held'),
        ]);
        expect(backend.isClosed, isFalse);
      },
    );
  }

  for (final operation in ['observing', 'paused']) {
    for (final retirement in ['frontend', 'stopStarting', 'close', 'window']) {
      test(
        '$retirement cancels $operation generated stream without retiring its backend',
        () async {
          await install([
            _descriptor('observing', operation, services: [_service]),
          ], backend: true);
          await start(backend: true);
          selection.presentSession(_session('a'));
          final backend = connection();
          final pending = expectLater(
            commands.resolve(_id('observing')).invoke(),
            throwsA(anything),
          );
          await _wait(backend, 'watch:gated');
          final gate = operation == 'observing' ? 'held-observation' : 'held';
          await _wait(backend, 'read:$gate');
          switch (retirement) {
            case 'frontend':
              await frontends.generations.single.close();
            case 'stopStarting':
              frontends.stopStarting();
            case 'close':
              await frontends.close();
            case 'window':
              // close deliberately publishes no shutdown event; delivery revalidates.
              selection.close();
              await _control(backend, 'emit', {'sequence': 1, 'text': 'stale'});
              await _control(backend, 'release');
          }
          await pending.timeout(_bound);
          await _wait(backend, 'cancel:gated');
          await _control(backend, 'release');
          expect((await _snapshot(backend))['requests'], [
            _request('watch', 'gated'),
            _request('read', gate),
          ]);
          expect(backend.isClosed, isFalse);
        },
      );
    }
  }

  test(
    'backend retirement fences captured work and cannot retarget a same-ID generation',
    () async {
      await install([
        _descriptor('captured', 'captured', services: [_service]),
        _descriptor('observing', 'observing', services: [_service]),
        _descriptor('local', 'local'),
      ], backend: true);
      await start(backend: true);
      selection.presentSession(_session('a'));
      final old = connection();
      final captured = commands.resolve(_id('captured'));
      final pending = expectLater(captured.invoke(), throwsA(anything));
      final observation = expectLater(
        commands.resolve(_id('observing')).invoke(),
        throwsA(anything),
      );
      await _wait(old, 'read:held');
      await _wait(old, 'watch:gated');
      final retired = backends.changes.firstWhere(
        (_) =>
            backends.backends.single.state == InstalledBackendState.terminated,
      );
      await expectLater(
        _control(old, 'terminate'),
        throwsA(isA<PluginRemoteFailure>()),
      );
      await old.terminated.timeout(_bound);
      await retired.timeout(_bound);
      await pending.timeout(_bound);
      await observation.timeout(_bound);
      final replacement = await backends.host!.startPlugin(
        pluginId: _plugin,
        artifactUri: backendArtifact.absolute.uri,
        arguments: [_options(identity: 'REPLACEMENT')],
      );
      expect(captured.availability, CommandAvailability.disabled);
      await expectLater(captured.invoke(), throwsA(isA<CommandUnavailable>()));
      expect((await _snapshot(replacement))['requests'], isEmpty);
      await commands.resolve(_id('local')).invoke();
    },
  );
}

Map<String, Object?> _descriptor(
  String name,
  String entrypoint, {
  List<String> services = const [],
}) => PreparedSessionCommandExtension(
  extensionId: ExtensionId('test.session.$name.registration'),
  commandId: _id(name),
  label: 'Session $name',
  library: _library,
  entrypoint: entrypoint,
  backendServices: services,
).toJson();

String _options({String identity = 'OWNER', bool foreignService = false}) =>
    jsonEncode({
      'identity': identity,
      'providerId': 'test.provider.${identity.toLowerCase()}',
      'context': 'default',
      'rank': 0,
      'foreignService': foreignService,
    });

Map<String, Object?> _request(String method, String scope) => {
  'configurationContext': 'default',
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

final class _Picker extends FileSelectorPlatform {
  int calls = 0;

  @override
  Future<String?> getDirectoryPathWithOptions(FileDialogOptions options) async {
    calls++;
    return null;
  }
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
