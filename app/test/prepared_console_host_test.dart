import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:adele_capabilities/adele_capabilities.dart';
import 'package:adele_desktop/core/application_plugin_bootstrap.dart';
import 'package:adele_desktop/core/product_lifecycle.dart';
import 'package:adele_desktop/frontend/application_frontend_bootstrap.dart';
import 'package:adele_desktop/frontend/console_bridge.dart';
import 'package:adele_desktop/frontend/prepared_console_host.dart';
import 'package:adele_desktop/frontend/prepared_frontend.dart';
import 'package:adele_desktop/frontend/structured_bridge_data.dart';
import 'package:adele_desktop/terminal/environment_terminal_owner.dart';
import 'package:adele_desktop/ui/console/console_controller.dart';
import 'package:adele_desktop/ui/console/workbench_console.dart';
import 'package:adele_environment/adele_environment.dart';
import 'package:adele_plugin_api/adele_plugin_api.dart';
import 'package:adele_product/adele_product.dart';
import 'package:adele_ui/adele_ui.dart';
import 'package:dart_eval/dart_eval.dart';
import 'package:flutter/material.dart';
import 'package:flutter_eval/flutter_eval.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plugin_runtime/plugin_runtime.dart';
import 'package:xterm2/xterm.dart';

import '../../tools/stock_frontend_descriptors.dart';
import '../tool/terminal_frontend_compiler.dart';
import '../tool/tool_inspection_frontend_compiler.dart';

const _plugin = 'dev.adele.plugin.terminal';
const _contentLibrary = 'package:console_content_probe/main.dart';
final _providerId = ProviderId('test.console-environment');

void main() {
  late Directory temporary;
  late PreparedPluginCatalog catalog;
  late File contentArtifact;
  late Directory commandInstallation;

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
    final program =
        (Compiler()
              ..addPlugin(flutterEvalPlugin)
              ..addPlugin(const ConsoleDeclarations())
              ..entrypoints.add(_contentLibrary))
            .compile({
              'console_content_probe': {
                'main.dart': await File(
                  'test/fixtures/console_content_frontend.dart',
                ).readAsString(),
              },
              'adele_ui': {
                'console_bridge.dart': await File(
                  '../packages/ui/lib/console_bridge.dart',
                ).readAsString(),
              },
            });
    contentArtifact = await File(
      '${temporary.path}/content.evc',
    ).writeAsBytes(program.write());
    commandInstallation = await Directory(
      '${temporary.path}/command-installation',
    ).create();
    final command = await Directory(
      '${commandInstallation.path}/command',
    ).create();
    await compileToolInspectionFrontend(
      repositoryRoot: Directory.current.parent,
      artifact: File('${command.path}/frontend.evc'),
      frontend: ToolInspectionFrontend.command,
    );
    await File('${command.path}/backend.aot').writeAsString('fixture');
    await File('${command.path}/adele_plugin.installation.json').writeAsString(
      jsonEncode({
        'manifestVersion': 1,
        'metadata': {
          'id': 'dev.adele.plugin.command-tools',
          'version': 'test',
          'displayName': 'Command Tools',
        },
        'components': {
          'backend': {'artifact': 'backend.aot'},
          'frontend': {
            'artifact': 'frontend.evc',
            'presentations':
                stockFrontendDescriptors['dev.adele.plugin.command-tools'],
          },
        },
      }),
    );
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
    'missing optional read-only host preserves factual frontend roles',
    () async {
      final root = await Directory(
        '${temporary.path}/optional-console',
      ).create();
      final installation = await Directory('${root.path}/owner').create();
      await contentArtifact.copy('${installation.path}/frontend.evc');
      await File(
        '${installation.path}/adele_plugin.installation.json',
      ).writeAsString(
        jsonEncode({
          'manifestVersion': 1,
          'metadata': {
            'id': 'test.optional-console',
            'version': '1',
            'displayName': 'Optional',
          },
          'components': {
            'frontend': {
              'artifact': 'frontend.evc',
              'presentations': [
                {
                  'role': 'console',
                  'extensionId': 'test.read-only',
                  'library': _contentLibrary,
                  'entrypoint': 'buildContent',
                  'actions': <Object?>[],
                  'readOnly': true,
                },
                {
                  'role': 'toolActivity',
                  'toolId': 'test.tool',
                  'library': _contentLibrary,
                  'inspectionExtensionId': 'test.inspection',
                  'compactExtensionId': 'test.compact',
                  'inspectionEntrypoint': 'buildContent',
                  'compactEntrypoint': 'buildContent',
                  'consoleExtensions': ['test.read-only'],
                },
              ],
            },
          },
        }),
      );
      final extensions = ExtensionRegistry();
      final frontends = ApplicationFrontendBootstrap(extensions: extensions);
      addTearDown(frontends.close);
      await frontends.start(await PreparedPluginCatalog.discover(root.path));
      expect(frontends.generations.single.state, InstalledFrontendState.active);
      expect(extensions.discover(consoleContributions), isEmpty);
      expect(
        extensions.discover(toolActivityInspectionContributions),
        hasLength(1),
      );
      expect(
        extensions.discover(toolActivityCompactPresentationContributions),
        hasLength(1),
      );
    },
  );

  Future<(PreparedFrontend, ExtensionRegistration, ConsoleBridge)>
  readOnly() async {
    final generation = await PreparedFrontend.load(contentArtifact);
    addTearDown(generation.invalidate);
    late ExtensionRegistration registration;
    registration = fixture.extensions.register(
      point: consoleContributions,
      id: ExtensionId('test.read-only'),
      value: fixture.host.createContribution(
        installation: catalog.installations.single,
        generation: generation,
        descriptor: PreparedConsolePresentation(
          extensionId: ExtensionId('test.read-only'),
          library: _contentLibrary,
          entrypoint: 'buildContent',
          actions: [],
          readOnly: true,
        ),
        isActive: () => !registration.isClosed,
      ),
    );
    final bridge =
        fixture.host.createOpeningBridge(
              installation: catalog.installations.single,
              generation: generation,
              sessionId: fixture.sessionA.id,
              consoleExtensions: [ExtensionId('test.read-only')],
              isActive: () => true,
            )
            as ConsoleBridge;
    fixture.controller.setSession(fixture.sessionA);
    return (generation, registration, bridge);
  }

  testWidgets(
    'prepared read-only content outlives opener and retains only logical state',
    (tester) => tester.runAsync(() async {
      final (generation, registration, bridge) = await readOnly();
      final result = await generation.invoke<Object?>(
        library: _contentLibrary,
        entrypoint: 'open',
        createBridge: () => bridge,
        decodeResult: copyStructuredBridgeData,
      );
      expect(result, [true, null]);
      expect(bridge.isActive, isFalse);
      final tab = fixture.controller.selectedTab!;
      expect(fixture.provider.requests, isEmpty);
      expect(fixture.provider.restores, 0);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: WorkbenchConsole(controller: fixture.controller),
          ),
        ),
      );
      await tester.pump();
      expect(find.text('Identity: opaque; history: 0'), findsOneWidget);
      final oldButton = tester.widget<TextButton>(
        find.widgetWithText(TextButton, 'Identity: opaque; history: 0'),
      );
      oldButton.onPressed!();
      fixture.controller.setVisible(false);
      await tester.pump();
      fixture.controller.setVisible(true);
      await tester.pump();
      await tester.pump();
      expect(find.text('Identity: opaque; history: 1'), findsOneWidget);
      await tester.tap(find.text('Identity: opaque; history: 1'));
      fixture.controller.setVisible(false);
      await tester.pump();
      oldButton.onPressed!();
      fixture.controller.setVisible(true);
      await tester.pump();
      await tester.pump();
      expect(find.text('Identity: opaque; history: 2'), findsOneWidget);
      fixture.controller.setSession(fixture.sessionB);
      expect(fixture.controller.eligibleTabs, isEmpty);
      fixture.controller.setSession(fixture.sessionA);
      expect(fixture.controller.selectedTab, same(tab));
      await fixture.controller.closeTab(
        tab,
        (_) async => fail('Read-only content never confirms.'),
      );
      expect(fixture.controller.eligibleTabs, isEmpty);
      expect(fixture.provider.closes, isEmpty);
      await registration.close();
      await tester.pumpWidget(const SizedBox.shrink());
      expect(tester.takeException(), isNull);
    }),
  );

  test(
    'opening requires exact declared installation generation and owner',
    () async {
      final (generation, registration, bridge) = await readOnly();
      final descriptor = ConsoleContentDescriptor(
        key: 'same',
        metadata: ConsoleMetadata(title: 'Output'),
        data: const {},
      );
      expect(await bridge.open('test.unlisted', descriptor), [
        false,
        'Console content is unavailable.',
      ]);
      final otherGeneration = await PreparedFrontend.load(contentArtifact);
      addTearDown(otherGeneration.invalidate);
      final foreign =
          fixture.host.createOpeningBridge(
                installation: catalog.installations.single,
                generation: otherGeneration,
                sessionId: fixture.sessionA.id,
                consoleExtensions: [ExtensionId('test.read-only')],
                isActive: () => true,
              )
              as ConsoleBridge;
      expect(await foreign.open('test.read-only', descriptor), [
        false,
        'Console content is unavailable.',
      ]);
      expect(await bridge.open('test.read-only', descriptor), [true, null]);
      final tab = fixture.controller.selectedTab;
      expect(await bridge.open('test.read-only', descriptor), [true, null]);
      expect(fixture.controller.eligibleTabs, [tab]);
      final value = fixture.extensions
          .discover(consoleContributions)
          .singleWhere((entry) => entry.id == ExtensionId('test.read-only'))
          .value;
      await registration.close();
      fixture.extensions.register(
        point: consoleContributions,
        id: ExtensionId('test.read-only'),
        value: value,
      );
      expect(await bridge.open('test.read-only', descriptor), [
        false,
        'Console content is unavailable.',
      ]);
      await _turn();
      expect(fixture.controller.eligibleTabs, isEmpty);
      expect(fixture.provider.requests, isEmpty);
    },
  );

  for (final departure in ['hide', 'switch tab', 'leave Session']) {
    testWidgets(
      'stock Command retains immediate native scroll before $departure',
      (tester) => tester.runAsync(() async {
        final backends = ApplicationPluginBootstrap(
          fixture.capabilities,
          fixture.extensions,
        );
        final host = PreparedConsoleHost(
          store: fixture.store,
          terminals: fixture.terminals,
          extensions: fixture.extensions,
          controller: fixture.controller,
          backends: backends,
        );
        final frontends = ApplicationFrontendBootstrap(
          extensions: fixture.extensions,
          consoleHost: host,
          backends: backends,
        );
        addTearDown(() async {
          await tester.pumpWidget(const SizedBox.shrink());
          await frontends.close();
          await host.close();
          await backends.close();
        });
        await backends.start(
          installationRoot: commandInstallation.path,
          dartaotruntimeExecutable:
              '${Platform.environment['FLUTTER_ROOT']}/bin/cache/dart-sdk/bin/${Platform.isWindows ? 'dart.exe' : 'dart'}',
          hostArtifactPath: File(
            'test/fixtures/command_output_host.dart',
          ).absolute.path,
        );
        await frontends.start(backends.catalog!);
        expect(
          frontends.generations.single.state,
          InstalledFrontendState.active,
        );
        final connection = backends.backends.single.connection!;
        Future<Object?> control(String method, [String? text]) =>
            connection.request(method, {'text': ?text});
        Map<Object?, Object?> backendState = {};
        Future<void> until(bool Function() ready, String reason) async {
          for (var turn = 0; turn < 200; turn++) {
            // A backend acknowledgement advances real I/O without sleeps.
            backendState = (await control('barrier'))! as Map;
            await tester.pump();
            expect(tester.takeException(), isNull, reason: reason);
            if (ready()) return;
          }
          fail(
            'Did not reach $reason; visible text: '
            '${tester.widgetList<Text>(find.byType(Text)).map((text) => text.data).join(' | ')}',
          );
        }

        await control(
          'append',
          List.generate(260, (i) => 'original-$i\r\n').join(),
        );
        fixture.controller.setSession(fixture.sessionA);
        final owner = fixture.extensions
            .discover(consoleContributions)
            .singleWhere(
              (binding) =>
                  binding.id ==
                  ExtensionId('dev.adele.plugin.command-tools.output'),
            );
        Future<void> open(String key) => fixture.controller.openOrFocus(
          owner: owner,
          session: fixture.sessionA,
          descriptor: ConsoleContentDescriptor(
            key: key,
            metadata: ConsoleMetadata(title: key),
            data: const {
              'sessionId': 'a',
              'runId': 'run',
              'toolInvocationId': 'invocation',
              'title': 'Command output',
            },
          ),
        );
        await open('other output');
        final other = fixture.controller.selectedTab!;
        await open('reading output');
        final tab = fixture.controller.selectedTab!;
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: WorkbenchConsole(controller: fixture.controller),
            ),
          ),
        );
        TerminalView view() =>
            tester.widget<TerminalView>(find.byType(TerminalView));
        await until(
          () =>
              find.text('Following output').evaluate().isNotEmpty &&
              find.byType(TerminalView).evaluate().isNotEmpty &&
              _terminalText(view().terminal).contains('original-259'),
          'initial stock reader catch-up',
        );
        await tester.pump();
        final previous = view();
        final frozen = _terminalText(previous.terminal);
        final oldPresentation = fixture.controller.selectedPresentation;
        final scroll = previous.scrollController!;
        final liveOffset = scroll.offset;
        expect(liveOffset, greaterThan(120));

        // This is the actual native wheel path, not jumpTo or a plugin callback.
        // Revoke in the same synchronous turn: no await, microtask, or frame may
        // let the stock reader save the newly frozen mode/offset before departure.
        scroll.position.pointerScroll(-100);
        final frozenOffset = scroll.offset;
        expect(frozenOffset, closeTo(liveOffset - 100, 0.01));
        expect(find.text('Following output'), findsOneWidget);
        switch (departure) {
          case 'hide':
            fixture.controller.setVisible(false);
          case 'switch tab':
            fixture.controller.select(other);
          case 'leave Session':
            fixture.controller.setSession(fixture.sessionB);
        }
        await tester.pumpWidget(const SizedBox.shrink());
        await control('append', 'while-away\r\n');
        fixture.controller.setSession(fixture.sessionA);
        fixture.controller.setVisible(true);
        fixture.controller.select(tab);
        expect(fixture.controller.selectedTab, same(tab));
        expect(
          fixture.controller.selectedPresentation,
          isNot(same(oldPresentation)),
        );
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: WorkbenchConsole(controller: fixture.controller),
            ),
          ),
        );
        await until(
          () => find.text('Reading history').evaluate().isNotEmpty,
          'frozen mode after immediate $departure',
        );
        await tester.pump();
        expect(view().terminal, isNot(same(previous.terminal)));
        expect(_terminalText(view().terminal), frozen);
        expect(view().terminal.buffer.height, lessThanOrEqualTo(200));
        expect(view().scrollController!.offset, closeTo(frozenOffset, 0.01));
        await control('append', 'after-remount\r\n');
        await until(
          () => backendState['deliveredVersion'] == 3,
          'post-remount append delivered through generated watch',
        );
        expect(find.text('Reading history'), findsOneWidget);
        expect(_terminalText(view().terminal), frozen);
        expect(view().scrollController!.offset, closeTo(frozenOffset, 0.01));
        view().scrollController!.position.pointerScroll(20000);
        await until(
          () =>
              find.text('Following output').evaluate().isNotEmpty &&
              _terminalText(view().terminal).contains('after-remount'),
          'retained live-tail policy resumes on real user return',
        );
        expect(fixture.provider.requests, isEmpty);
        await tester.pumpWidget(const SizedBox.shrink());
      }),
    );
  }

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

String _terminalText(Terminal terminal) => [
  for (var i = 0; i < terminal.buffer.lines.length; i++)
    terminal.buffer.lines[i].getText().trimRight(),
].join('\n');

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
    controller = ConsoleController(
      extensions,
      cleanupTimeout: const Duration(milliseconds: 200),
    );
    host = PreparedConsoleHost(
      store: store,
      terminals: terminals,
      extensions: extensions,
      controller: controller,
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
