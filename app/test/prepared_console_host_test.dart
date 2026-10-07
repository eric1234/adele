import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:adele_capabilities/adele_capabilities.dart';
import 'package:adele_core_extensions/adele_core_extensions.dart';
import 'package:adele_desktop/core/application_plugin_bootstrap.dart';
import 'package:adele_desktop/core/product_lifecycle.dart';
import 'package:adele_desktop/frontend/application_frontend_bootstrap.dart';
import 'package:adele_desktop/frontend/console_bridge.dart';
import 'package:adele_desktop/frontend/prepared_console_host.dart';
import 'package:adele_desktop/frontend/prepared_frontend.dart';
import 'package:adele_desktop/frontend/structured_bridge_data.dart';
import 'package:adele_desktop/terminal/environment_terminal_owner.dart';
import 'package:adele_desktop/ui/commands/command_palette.dart';
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
            'extensions': stockFrontendExtensionDescriptors[_plugin],
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

  Future<(PreparedFrontend, ExtensionRegistration, ConsoleBridge)> readOnly({
    bool keepAlive = false,
  }) async {
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
          keepAlive: keepAlive,
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

  for (final departure in ['failure', 'retirement', 'host close', 'dispose']) {
    testWidgets(
      'prepared content detaches resident listeners on $departure',
      (tester) => tester.runAsync(() async {
        final generation = await PreparedFrontend.load(contentArtifact);
        addTearDown(generation.invalidate);
        final contribution = fixture.host.createContribution(
          installation: catalog.installations.single,
          generation: generation,
          descriptor: PreparedConsolePresentation(
            extensionId: ExtensionId('test.listener-cleanup'),
            library: _contentLibrary,
            entrypoint: departure == 'failure' ? 'missing' : 'buildContent',
            actions: [],
            readOnly: true,
            keepAlive: true,
          ),
          isActive: () => true,
        );
        final creation = _CaptureCreation(fixture.sessionA);
        await contribution.openPrepared!(
          creation,
          ConsoleContentDescriptor(
            key: 'listener-cleanup',
            metadata: ConsoleMetadata(title: 'Output'),
            data: {'identity': 'opaque'},
          ),
        );
        expect(creation.content.keepAlive, isTrue);
        final access = _ObservedPresentation();
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(body: creation.content.createPresentation(access)),
          ),
        );
        await tester.pump();
        if (departure == 'failure') {
          expect(find.text('Frontend unavailable.'), findsOneWidget);
        } else {
          expect(access.hasSubscribers, isTrue);
          switch (departure) {
            case 'retirement':
              access.retire();
            case 'host close':
              final closing = fixture.host.close();
              expect(access.hasSubscribers, isFalse);
              await closing;
              await tester.pump();
              expect(find.text('Frontend unavailable.'), findsOneWidget);
            case 'dispose':
              await tester.pumpWidget(const SizedBox.shrink());
          }
        }
        // Failure and resident retirement clean up even before Flutter disposes
        // the prepared subtree. A second disposal must remain harmless.
        expect(access.hasSubscribers, isFalse);
        await tester.pumpWidget(const SizedBox.shrink());
        await creation.content.release();
        access.dispose();
        expect(tester.takeException(), isNull);
      }),
    );
  }

  Future<_CommandHost> commandHost(
    WidgetTester tester, {
    Map<String, _MutableEligibility>? eligibility,
  }) async {
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
    expect(frontends.generations.single.state, InstalledFrontendState.active);
    fixture.controller.setSession(fixture.sessionA);
    var owner = fixture.extensions
        .discover(consoleContributions)
        .singleWhere(
          (binding) =>
              binding.id ==
              ExtensionId('dev.adele.plugin.command-tools.output'),
        );
    if (eligibility != null) {
      final original = owner.value;
      fixture.extensions.register(
        point: consoleContributions,
        id: ExtensionId('test.command-eligibility'),
        value: ConsoleContribution(
          actions: original.actions,
          openPrepared: (access, descriptor) => original.openPrepared!(
            _EligibleCreation(access, eligibility[descriptor.key]!),
            descriptor,
          ),
        ),
      );
      owner = fixture.extensions
          .discover(consoleContributions)
          .singleWhere(
            (binding) => binding.id == ExtensionId('test.command-eligibility'),
          );
    }
    return _CommandHost(
      tester,
      fixture,
      backends,
      backends.backends.single.connection!,
      owner,
    );
  }

  testWidgets(
    'stock Session teardown denies reentrant resident admission and restores fresh history',
    (tester) => tester.runAsync(() async {
      final eligibility = {
        for (final key in ['a', 'b']) key: _MutableEligibility(),
      };
      final host = await commandHost(tester, eligibility: eligibility);
      try {
        await fixture.create();
        final terminalTab = fixture.controller.selectedTab!;
        final terminal = fixture.owners.single;
        await host.control(
          'append',
          text: List.generate(260, (i) => 'checkpoint-$i\r\n').join(),
        );
        final a = await host.open('a');
        await host.mount();
        await host.until(() => host.hasText(a, 'Following output'), 'A ready');
        final b = await host.open('b');
        await host.until(() => host.hasText(b, 'Following output'), 'B ready');
        await tester.tap(find.widgetWithText(TextButton, 'Output a'));
        await tester.pump();
        await tester.pump();
        final residents = fixture.controller.residentPresentations;
        final accessA = residents.singleWhere((r) => r.tab == a).access;
        final accessB = residents.singleWhere((r) => r.tab == b).access;
        final interactionA = accessA.interaction!;
        final engineA = host.view(a).terminal.buffer.terminal as Terminal;
        final engineB = host.view(b).terminal.buffer.terminal as Terminal;
        final frozenA = _terminalText(engineA);
        final frozenB = _terminalText(engineB);
        final workbench = tester.state(find.byType(WorkbenchConsole));
        final navigator = tester.state(find.byType(Navigator));
        final materialApp = tester.state(find.byType(MaterialApp));
        final initialReadsB = host.cursors('b');
        final highWater = host.stats['highWater']! as int;
        final revocations = <ConsolePresentationAccess, int>{
          accessA: 0,
          accessB: 0,
        };
        final attempts =
            <(Widget?, List<ConsoleResidentPresentation>, List<int>)>[];
        for (final access in [accessA, accessB]) {
          access.changes.addListener(() {
            if (!access.isActive) {
              revocations[access] = revocations[access]! + 1;
            }
            // Query from the real synchronous teardown callback, not from an
            // assertion after the admission fence has legitimately reopened.
            attempts.add((
              fixture.controller.selectedPresentation,
              fixture.controller.residentPresentations,
              [for (final value in eligibility.values) value.presentations],
            ));
          });
        }
        await host.control('hold', invocation: 'a');
        await host.control('append', text: 'held-at-departure\r\n');
        await host.until(
          () =>
              host.activeReads('a') == 1 &&
              host.hasText(b, 'Following output (catching up)'),
          'A held with B admitted behind the serial generated dispatcher',
        );
        expect(host.activeReads('b'), 0);
        expect(host.cursors('b'), initialReadsB);
        final readsA = host.cursors('a');
        final queued = host.control('append', text: 'queued-at-departure\r\n');
        final scroll = host.view(a).scrollController!;
        expect(scroll.offset, greaterThan(120));
        scroll.position.pointerScroll(-100);
        final frozenOffset = scroll.offset;
        // No frame/eval turn may save the native checkpoint before departure.
        fixture.controller.setSession(fixture.sessionB);
        expect(attempts, isNotEmpty);
        for (final (selected, admitted, factories) in attempts) {
          expect(selected, isNull);
          expect(admitted, isEmpty);
          expect(factories, [1, 1]);
        }
        expect(revocations.values, [1, 1]);
        expect(accessA.isActive, isFalse);
        expect(accessB.isActive, isFalse);
        expect(interactionA.isActive, isFalse);
        expect(eligibility.values.map((value) => value.releases), [0, 0]);
        expect(fixture.provider.closes, isEmpty);
        await queued;
        await host.control('release', invocation: 'a');
        await host.until(
          () =>
              host.activeReads('a') == 0 &&
              host.activeReads('b') == 0 &&
              host.cursors('b').length == initialReadsB.length + 1 &&
              (host.stats['observers']! as List).isEmpty,
          'both watches detach and admitted held/queued reads settle inertly',
        );
        expect(host.cursors('a'), readsA);
        expect(host.cursors('b'), [...initialReadsB, highWater]);
        final readsB = host.cursors('b');
        expect(_terminalText(engineA), frozenA);
        expect(_terminalText(engineB), frozenB);
        expect([host.watches('a'), host.watches('b')], [1, 1]);
        expect(eligibility.values.map((value) => value.presentations), [1, 1]);
        expect(find.byType(TerminalView, skipOffstage: false), findsOneWidget);
        expect(fixture.controller.selectedTab, same(terminalTab));
        expect(terminal.state, EnvironmentTerminalState.running);
        expect(tester.state(find.byType(WorkbenchConsole)), same(workbench));
        expect(tester.state(find.byType(Navigator)), same(navigator));
        expect(tester.state(find.byType(MaterialApp)), same(materialApp));
        fixture.provider.output('resource-1', 'unrelated-terminal-still-live');
        await host.control('append', text: 'capture-after-departure\r\n');
        await host.until(
          () => _terminalText(
            tester.widget<TerminalView>(find.byType(TerminalView)).terminal,
          ).contains('unrelated-terminal-still-live'),
          'unrelated Terminal remains live while output capture advances',
        );
        expect(host.stats['highWater'], greaterThan(highWater));
        expect(host.stats['observers'], isEmpty);
        expect(host.cursors('a'), readsA);
        expect(host.cursors('b'), readsB);
        expect(_terminalText(engineA), frozenA);
        expect(_terminalText(engineB), frozenB);
        expect(revocations.values, [1, 1]);

        fixture.controller.setSession(fixture.sessionA);
        await tester.pump();
        await host.until(
          () => host.hasText(a, 'Reading history') && host.painted(a),
          'normal return reconstructs the retained same-turn checkpoint',
        );
        final fresh = fixture.controller.residentPresentations.single;
        expect(fresh.tab, same(a));
        expect(fresh.access, isNot(same(accessA)));
        expect(fresh.access.isActive, isTrue);
        expect(fresh.access.interaction!.isActive, isTrue);
        expect(accessA.isActive, isFalse);
        expect(accessB.isActive, isFalse);
        expect(interactionA.isActive, isFalse);
        expect(host.view(a).terminal.buffer.terminal, isNot(same(engineA)));
        expect(_terminalText(host.view(a).terminal), frozenA);
        expect(
          host.view(a).scrollController!.offset,
          closeTo(frozenOffset, .01),
        );
        expect(eligibility.values.map((value) => value.presentations), [2, 1]);
        expect([host.watches('a'), host.watches('b')], [2, 1]);
        expect(host.cursors('a').where((cursor) => cursor == 0), hasLength(2));
        expect(host.cursors('b'), readsB);
        await tester.tap(find.byTooltip('Follow output'));
        await host.until(
          () =>
              host.hasText(a, 'Following output') &&
              _terminalText(
                host.view(a).terminal,
              ).contains('capture-after-departure'),
          'fresh reader follows history captured without a presentation',
        );
        expect(host.stats['observers'], ['a']);
        expect(revocations.values, [1, 1]);
        expect(eligibility.values.map((value) => value.releases), [0, 0]);
        expect(
          eligibility.values.every((value) => value.registration.isActive),
          isTrue,
        );
        expect(fixture.owners.single, same(terminal));
        expect(terminal.state, EnvironmentTerminalState.running);
        expect(fixture.provider.requests, hasLength(1));
        expect(fixture.provider.closes, isEmpty);
        expect(tester.state(find.byType(WorkbenchConsole)), same(workbench));
        expect(tester.state(find.byType(Navigator)), same(navigator));
      } finally {
        await host.control('release', invocation: 'a');
        await host.unmount();
      }
    }),
  );

  testWidgets(
    'generic eligibility prunes false and throwing hidden prepared readers only',
    (tester) => tester.runAsync(() async {
      final eligibility = {
        for (final key in ['a', 'b', 'c']) key: _MutableEligibility(),
      };
      final host = await commandHost(tester, eligibility: eligibility);
      try {
        await host.control('append', text: 'before-loss\r\n');
        final a = await host.open('a');
        await host.mount();
        await host.until(() => host.hasText(a, 'Following output'), 'A ready');
        final accessA = fixture.controller.residentPresentations.single.access;
        final interactionA = accessA.interaction!;
        final engineA = host.view(a).terminal.buffer.terminal as Terminal;
        final b = await host.open('b');
        await host.until(() => host.hasText(b, 'Following output'), 'B ready');
        final accessB = fixture.controller.residentPresentations.last.access;
        final interactionB = accessB.interaction!;
        final engineB = host.view(b).terminal.buffer.terminal as Terminal;
        final c = await host.open('c');
        await host.until(() => host.hasText(c, 'Following output'), 'C ready');
        final residentC = fixture.controller.residentPresentations.last;
        final interactionC = residentC.access.interaction!;
        final engineC = host.view(c).terminal.buffer.terminal as Terminal;
        final stateC = tester.state(host.findView(c));
        final workbench = tester.state(find.byType(WorkbenchConsole));
        var revocationsA = 0;
        var revocationsB = 0;
        accessA.changes.addListener(() {
          if (!accessA.isActive) revocationsA++;
        });
        accessB.changes.addListener(() {
          if (!accessB.isActive) revocationsB++;
        });
        // The fixture's generated dispatcher serializes ordinary requests:
        // holding A queues B/C reads rather than allowing three active reads.
        await host.control('hold', invocation: 'a');
        await host.control('append', text: 'held-before-loss\r\n');
        await host.until(
          () =>
              host.activeReads('a') == 1 &&
              host.hasText(b, 'Following output (catching up)') &&
              host.hasText(c, 'Following output (catching up)'),
          'A read held with B and C reads queued behind it',
        );
        expect(host.activeReads('b'), 0);
        expect(host.activeReads('c'), 0);
        expect(host.cursors('b'), [0]);
        final frozenA = _terminalText(engineA);
        final frozenB = _terminalText(engineB);
        final readsA = host.cursors('a');
        final readsC = host.cursors('c');
        // Queue real backend delivery, then revoke in this same synchronous
        // turn. Its notification and A/B's admitted pages must remain inert.
        final queued = host.control('append', text: 'queued-at-loss\r\n');
        eligibility['a']!.eligible = false;
        eligibility['b']!.throwEligibility = true;
        expect(fixture.controller.residentPresentations, [residentC]);
        expect(fixture.controller.selectedTab, same(c));
        expect(accessA.isActive, isFalse);
        expect(accessB.isActive, isFalse);
        expect(interactionA.isActive, isFalse);
        expect(interactionB.isActive, isFalse);
        expect(residentC.access.interaction, same(interactionC));
        expect(interactionC.isActive, isTrue);
        expect(revocationsA, 1);
        expect(revocationsB, 1);
        expect(
          eligibility.values.every((value) => value.releases == 0),
          isTrue,
        );
        await queued;
        await host.control('release', invocation: 'a');
        await host.until(
          () =>
              host.activeReads('a') == 0 &&
              host.activeReads('b') == 0 &&
              (host.stats['observers']! as List).length == 1 &&
              _terminalText(engineC).contains('queued-at-loss'),
          'revoked watches detach and late pages settle without delivery',
        );
        expect(host.stats['observers'], ['c']);
        expect(_terminalText(engineA), frozenA);
        expect(_terminalText(engineB), frozenB);
        expect(host.cursors('a'), readsA);
        // B's already-admitted queued request may execute after revocation;
        // its reply cannot feed the old projection or admit another read.
        final readsB = host.cursors('b');
        expect(readsB, [0, 1]);
        expect(host.cursors('c').take(readsC.length), readsC);
        expect(host.cursors('c').where((cursor) => cursor == 0), [0]);
        expect(find.byType(TerminalView, skipOffstage: false), findsOneWidget);
        expect(host.view(c).terminal.buffer.terminal, same(engineC));
        expect(tester.state(host.findView(c)), same(stateC));
        expect(tester.state(find.byType(WorkbenchConsole)), same(workbench));
        expect(host.painted(c), isTrue);
        for (var turn = 0; turn < 3; turn++) {
          expect(fixture.controller.eligibleTabs, [c]);
          expect(fixture.controller.residentPresentations, [residentC]);
          eligibility['a']!.registration.updateMetadata(a.metadata);
          await tester.pump();
        }
        await host.control('append', text: 'capture-survives-loss\r\n');
        await host.until(
          () => _terminalText(engineC).contains('capture-survives-loss'),
          'capture and healthy reader remain live after repeated reconciliation',
        );
        expect(host.stats['observers'], ['c']);
        expect(host.cursors('a'), readsA);
        expect(host.cursors('b'), readsB);
        expect(
          [host.watches('a'), host.watches('b'), host.watches('c')],
          [1, 1, 1],
        );
        expect(revocationsA, 1);
        expect(revocationsB, 1);
        eligibility['a']!.eligible = true;
        eligibility['b']!.throwEligibility = false;
        expect(fixture.controller.eligibleTabs, [a, b, c]);
        expect(fixture.controller.residentPresentations, [residentC]);
        expect(accessA.isActive, isFalse);
        expect(accessB.isActive, isFalse);
        expect(
          eligibility.values.every((value) => value.releases == 0),
          isTrue,
        );
        expect(fixture.provider.closes, isEmpty);
      } finally {
        await host.unmount();
      }
    }),
  );

  testWidgets(
    'generic selected eligibility loss retains same-turn checkpoint for cold return',
    (tester) => tester.runAsync(() async {
      final eligibility = {
        for (final key in ['a', 'b']) key: _MutableEligibility(),
      };
      final host = await commandHost(tester, eligibility: eligibility);
      try {
        await host.control(
          'append',
          text: List.generate(260, (i) => 'checkpoint-$i\r\n').join(),
        );
        final a = await host.open('a');
        await host.mount();
        await host.until(() => host.hasText(a, 'Following output'), 'A ready');
        final b = await host.open('b');
        await host.until(() => host.hasText(b, 'Following output'), 'B ready');
        final residentB = fixture.controller.residentPresentations.last;
        final engineB = host.view(b).terminal.buffer.terminal as Terminal;
        final stateB = tester.state(host.findView(b));
        await tester.tap(find.widgetWithText(TextButton, 'Output a'));
        await tester.pump();
        await tester.pump();
        final residentA = fixture.controller.residentPresentations.first;
        final interactionA = residentA.access.interaction!;
        final oldBeginning = tester
            .widget<TextButton>(find.widgetWithText(TextButton, 'Beginning'))
            .onPressed!;
        final oldFollow = tester
            .widget<IconButton>(
              find.widgetWithIcon(IconButton, Icons.arrow_downward),
            )
            .onPressed!;
        final engineA = host.view(a).terminal.buffer.terminal as Terminal;
        final frozen = _terminalText(engineA);
        final scroll = host.view(a).scrollController!;
        expect(scroll.offset, greaterThan(120));
        scroll.position.pointerScroll(-100);
        final frozenOffset = scroll.offset;
        // Do not let eval or a frame save the native freeze before revocation.
        eligibility['a']!.eligible = false;
        expect(fixture.controller.selectedTab, same(b));
        expect(residentA.access.isActive, isFalse);
        expect(interactionA.isActive, isFalse);
        expect(fixture.controller.residentPresentations, [residentB]);
        expect(residentB.access.isActive, isTrue);
        expect(eligibility['a']!.registration.isActive, isTrue);
        expect(eligibility['a']!.releases, 0);
        await tester.pump();
        expect(host.view(b).terminal.buffer.terminal, same(engineB));
        expect(tester.state(host.findView(b)), same(stateB));
        expect(host.painted(b), isTrue);
        await host.until(
          () => !(host.stats['observers']! as List).contains('a'),
          'lost selected watch detached',
        );
        final readsA = host.cursors('a');
        await host.control('append', text: 'while-ineligible\r\n');
        await host.until(
          () => _terminalText(engineB).contains('while-ineligible'),
          'healthy sibling captures output during eligibility loss',
        );
        expect(host.cursors('a'), readsA);
        expect(_terminalText(engineA), frozen);
        eligibility['a']!.eligible = true;
        eligibility['a']!.registration.updateMetadata(a.metadata);
        await tester.pump();
        expect(fixture.controller.selectedTab, same(b));
        expect(fixture.controller.residentPresentations, [residentB]);
        expect(host.watches('a'), 1);
        await tester.tap(find.widgetWithText(TextButton, 'Output a'));
        await tester.pump();
        await host.until(
          () => host.hasText(a, 'Reading history') && host.painted(a),
          'cold selected reader restores the same-turn native checkpoint',
        );
        expect(host.view(a).terminal.buffer.terminal, isNot(same(engineA)));
        expect(_terminalText(host.view(a).terminal), frozen);
        expect(
          host.view(a).scrollController!.offset,
          closeTo(frozenOffset, .01),
        );
        expect(host.watches('a'), 2);
        expect(host.cursors('a').where((cursor) => cursor == 0), hasLength(2));
        expect(host.watches('b'), 1);
        expect(host.view(b).terminal.buffer.terminal, same(engineB));
        expect(tester.state(host.findView(b)), same(stateB));
        expect(residentA.access.isActive, isFalse);
        expect(interactionA.isActive, isFalse);
        final restoredEngine = host.view(a).terminal.buffer.terminal;
        final restoredReads = host.cursors('a');
        oldBeginning();
        oldFollow();
        await host.control('barrier');
        await tester.pump();
        expect(host.view(a).terminal.buffer.terminal, same(restoredEngine));
        expect(host.cursors('a'), restoredReads);
        expect(host.hasText(a, 'Reading history'), isTrue);
        expect(
          eligibility.values.every((value) => value.releases == 0),
          isTrue,
        );
        expect(fixture.provider.closes, isEmpty);
      } finally {
        await host.unmount();
      }
    }),
  );

  testWidgets(
    'stock warm tabs keep native parser, watch and forward cursors while hidden',
    (tester) => tester.runAsync(() async {
      final host = await commandHost(tester);
      final prefix =
          '${List.generate(600, (i) => 'row-${i.toString().padLeft(3, '0')}:'.padRight(78, '.')).join('\r\n')}\r\nprogress\rOK\x1b[K\r\n\x1b[3';
      await host.control('append', text: prefix);
      final a = await host.open('a');
      await host.mount();
      await host.until(
        () => host.hasText(a, 'Following output'),
        'A initial replay',
      );
      final engine = host.view(a).terminal.buffer.terminal as Terminal;
      final element = tester.state(host.findView(a));
      final presentation = fixture.controller.selectedPresentation;
      final reads = host.cursors('a');
      final highWater = host.stats['highWater'];
      expect(reads.length, greaterThan(2));
      expect(_terminalText(engine), contains('row-599'));
      expect(_terminalText(engine), isNot(contains('row-000')));
      expect(engine.buffer.height, lessThanOrEqualTo(200));
      final b = await host.open('b');
      await host.until(
        () => host.hasText(b, 'Following output'),
        'B initial replay',
      );
      expect(find.byType(TerminalView), findsOneWidget);
      expect(find.byType(TerminalView, skipOffstage: false), findsNWidgets(2));
      final suffix =
          '1;1mred\x1b[0m \u03bb\u754c \u{1f600}\r\npartial-\x1b]2;hidden';
      await host.control('append', text: suffix);
      await host.until(
        () =>
            _terminalText(engine).contains('partial-') &&
            host.cursors('a').length == reads.length + 1,
        'hidden A consumes only its new suffix',
      );
      expect(host.cursors('a'), [...reads, highWater]);
      expect(host.watches('a'), 1);
      expect(host.watches('b'), 1);
      final hiddenOffset = host.view(a).scrollController!.offset;
      await tester.tap(find.widgetWithText(TextButton, 'Output a'));
      await tester.pump();
      expect(fixture.controller.selectedPresentation, same(presentation));
      expect(host.view(a).terminal.buffer.terminal, same(engine));
      expect(tester.state(host.findView(a)), same(element));
      expect(host.painted(a), true);
      expect(host.view(a).scrollController!.offset, closeTo(hiddenOffset, .01));
      expect(host.hasText(a, 'Replaying output...'), false);
      await host.control('append', text: ' title\x1b\\-done');
      await host.until(
        () => _terminalText(engine).contains('partial--done'),
        'split OSC resumes across warm selection',
      );
      final reference = Terminal(maxLines: 200)..resize(80, 20);
      reference.write('$prefix$suffix title\x1b\\-done');
      expect(_terminalText(engine), _terminalText(reference));
      final redLine = engine.buffer.lines.length - 2;
      expect(
        engine.buffer.lines[redLine].getForeground(0) & CellColor.valueMask,
        1,
      );
      expect(
        engine.buffer.lines[redLine].getAttributes(0) & CellAttr.bold,
        isNonZero,
      );
      expect(host.cursors('a').where((cursor) => cursor == 0), [0]);
      expect(host.stats['maximumPageChunks'], 4);
      expect(host.stats['maximumPageUnits'], lessThanOrEqualTo(16384));
      expect((host.stats['maximumReads']! as Map)['a'], 1);
      expect(fixture.provider.requests, isEmpty);
      await host.unmount();
    }),
  );

  testWidgets(
    'stock warm switch during held initial replay keeps one finite reveal target',
    (tester) => tester.runAsync(() async {
      final host = await commandHost(tester);
      await host.control(
        'append',
        text: List.generate(260, (i) => 'initial-$i\r\n').join(),
      );
      await host.control('hold', invocation: 'a');
      final a = await host.open('a');
      await host.mount();
      await host.until(() => host.activeReads('a') == 1, 'initial A read held');
      final engine = host.view(a).terminal.buffer.terminal as Terminal;
      final element = tester.state(host.findView(a));
      expect(host.painted(a), false);
      await host.open('b');
      await tester.pump();
      expect(find.text('Output b'), findsOneWidget);
      await host.control('append', text: 'beyond-initial-target\r\n');
      await host.control('releaseAndHoldNext', invocation: 'a');
      await host.until(
        () =>
            host.activeReads('a') == 1 &&
            host.cursors('a').length == 2 &&
            host.painted(a),
        'hidden A reveals its initial prefix before the held live suffix',
      );
      expect(_terminalText(engine), contains('initial-259'));
      expect(_terminalText(engine), isNot(contains('beyond-initial-target')));
      expect(host.hasText(a, 'Following output (catching up)'), true);
      fixture.controller.select(a);
      await tester.pump();
      await tester.pump();
      expect(host.view(a).terminal.buffer.terminal, same(engine));
      expect(tester.state(host.findView(a)), same(element));
      expect(host.painted(a), true);
      expect(host.watches('a'), 1);
      expect(host.cursors('a'), [0, 1]);
      await host.control('release', invocation: 'a');
      await host.until(
        () => _terminalText(engine).contains('beyond-initial-target'),
        'live suffix resumes without resetting initial readiness',
      );
      expect(host.painted(a), true);
      expect(host.cursors('a'), [0, 1]);
      await host.unmount();
    }),
  );

  for (final mode in ['live tail', 'selection', 'explicit history']) {
    testWidgets(
      'stock warm $mode preserves same-turn native freeze and rejects stale controls',
      (tester) => tester.runAsync(() async {
        final host = await commandHost(tester);
        await host.control(
          'append',
          text: List.generate(
            650,
            (i) => 'frozen-$i:'.padRight(78, '.'),
          ).join('\r\n'),
        );
        final a = await host.open('a');
        await host.mount();
        await host.until(
          () => host.hasText(a, 'Following output'),
          'initial A output',
        );
        final b = await host.open('b');
        await host.until(
          () => host.hasText(b, 'Following output'),
          'initial B output',
        );
        fixture.controller.select(a);
        await tester.pump();
        await tester.pump();
        if (mode == 'explicit history') {
          await tester.tap(find.text('Middle'));
          await host.until(
            () => host.hasText(a, 'Reading history'),
            'explicit middle prefix',
          );
        }
        final staleBeginning = tester
            .widget<TextButton>(find.widgetWithText(TextButton, 'Beginning'))
            .onPressed!;
        final staleFollow = tester
            .widget<IconButton>(
              find.byWidgetPredicate(
                (widget) =>
                    widget is IconButton && widget.tooltip == 'Follow output',
              ),
            )
            .onPressed!;
        final engine = host.view(a).terminal.buffer.terminal as Terminal;
        final element = tester.state(host.findView(a));
        final frozen = _terminalText(engine);
        if (mode != 'explicit history') {
          await host.control('hold', invocation: 'a');
          await host.control('append', text: 'held-before-freeze\r\n');
          await host.until(
            () => host.activeReads('a') == 1,
            'A suffix read held',
          );
        }
        final scroll = host.view(a).scrollController!;
        if (mode == 'selection') {
          host
              .view(a)
              .controller!
              .setSelection(
                engine.buffer.createAnchor(0, 0),
                engine.buffer.createAnchor(4, 0),
              );
        } else {
          scroll.position.pointerScroll(mode == 'live tail' ? -100 : 40);
        }
        final offset = scroll.offset;
        // No frame or event turn between the native checkpoint and selection.
        fixture.controller.select(b);
        staleBeginning();
        staleFollow();
        await host.control('release', invocation: 'a');
        await host.until(
          () => host.hasText(b, 'Following output'),
          'B catches up while A is frozen',
        );
        await host.control('append', text: '\r\nhidden-frozen-suffix\r\n');
        await host.until(
          () =>
              host.activeReads('a') == 0 &&
              _terminalText(
                host.view(b).terminal,
              ).contains('hidden-frozen-suffix'),
          'late A settlement and independent B progression',
        );
        final reads = host.cursors('a');
        expect(_terminalText(engine), frozen);
        fixture.controller.select(a);
        await tester.pump();
        await tester.pump();
        staleBeginning();
        staleFollow();
        await host.control('barrier');
        await tester.pump();
        expect(host.cursors('a'), reads);
        expect(host.watches('a'), 1);
        expect(host.hasText(a, 'Reading history'), true);
        expect(host.view(a).terminal.buffer.terminal, same(engine));
        expect(tester.state(host.findView(a)), same(element));
        expect(_terminalText(engine), frozen);
        expect(host.view(a).scrollController!.offset, closeTo(offset, .01));
        if (mode == 'selection') {
          expect(host.view(a).controller!.selection, isNotNull);
        }
        host.view(a).scrollController!.position.pointerScroll(20000);
        if (mode != 'live tail') {
          await tester.pump();
          await host.control('barrier');
          expect(host.cursors('a'), reads);
          expect(_terminalText(engine), frozen);
          await tester.tap(find.byTooltip('Follow output'));
        }
        await host.until(
          () =>
              host.hasText(a, 'Following output') &&
              _terminalText(engine).contains('hidden-frozen-suffix'),
          'fresh selected interaction resumes the exact reader',
        );
        expect(
          _terminalText(engine).split('hidden-frozen-suffix'),
          hasLength(2),
        );
        expect(host.watches('a'), 1);
        expect(
          host.cursors('a').where((cursor) => cursor == 0),
          hasLength(mode == 'explicit history' ? 2 : 1),
        );
        expect((host.stats['maximumReads']! as Map)['a'], 1);
        await host.unmount();
      }),
    );
  }

  testWidgets(
    'stock hidden reader failure stays local to its resident sibling',
    (tester) => tester.runAsync(() async {
      final host = await commandHost(tester);
      await host.control('append', text: 'before-failure\r\n');
      final a = await host.open('a');
      await host.mount();
      await host.until(() => host.hasText(a, 'Following output'), 'A ready');
      final engineA = host.view(a).terminal.buffer.terminal as Terminal;
      final frozen = _terminalText(engineA);
      final b = await host.open('b');
      await host.until(() => host.hasText(b, 'Following output'), 'B ready');
      final engineB = host.view(b).terminal.buffer.terminal as Terminal;
      await host.control('failNextRead', invocation: 'a');
      await host.control('append', text: 'surviving-sibling\r\n');
      await host.until(
        () =>
            host.hasText(
              a,
              'Stored output could not be read. Close and reopen to try fresh access.',
            ) &&
            _terminalText(engineB).contains('surviving-sibling'),
        'hidden A fails without disturbing B',
      );
      await host.until(
        () => !(host.stats['observers']! as List).contains('a'),
        'failed watch detached',
      );
      final reads = host.cursors('a');
      fixture.controller.select(a);
      await tester.pump();
      await tester.pump();
      expect(_terminalText(engineA), frozen);
      expect(find.text('Frontend unavailable.'), findsNothing);
      expect(find.textContaining('SECRET'), findsNothing);
      fixture.controller.select(b);
      await tester.pump();
      await host.control('append', text: 'still-capturing\r\n');
      await host.until(
        () => _terminalText(engineB).contains('still-capturing'),
        'B remains live after failed sibling reselection',
      );
      expect(host.view(b).terminal.buffer.terminal, same(engineB));
      expect(host.cursors('a'), reads);
      expect(host.watches('a'), 1);
      expect(host.watches('b'), 1);
      expect(fixture.provider.requests, isEmpty);
      await host.unmount();
    }),
  );

  testWidgets(
    'stock two-slot LRU retires the evicted reader and reconstructs only on revisit',
    (tester) => tester.runAsync(() async {
      await fixture.close();
      fixture = _Fixture(presentationLimit: 2);
      final host = await commandHost(tester);
      await host.control(
        'append',
        text: List.generate(260, (i) => 'resident-$i\r\n').join(),
      );
      final a = await host.open('a');
      await host.mount();
      await host.until(
        () => host.hasText(a, 'Following output'),
        'A initial reader',
      );
      final engineA = host.view(a).terminal.buffer.terminal as Terminal;
      final b = await host.open('b');
      await host.until(
        () => host.hasText(b, 'Following output'),
        'B initial reader',
      );
      final engineB = host.view(b).terminal.buffer.terminal as Terminal;
      final accessB = fixture.controller.residentPresentations
          .singleWhere((resident) => identical(resident.tab, b))
          .access;
      await tester.tap(find.widgetWithText(TextButton, 'Output a'));
      await tester.pump();
      expect(host.view(a).terminal.buffer.terminal, same(engineA));
      await host.control('hold', invocation: 'b');
      await host.control('append', text: 'pending-at-eviction\r\n');
      await host.until(
        () => host.activeReads('b') == 1,
        'B pending read before eviction',
      );
      final frozenB = _terminalText(engineB);
      final c = await host.open('c');
      await tester.pump();
      expect(accessB.isActive, false);
      expect(fixture.controller.residentPresentations, hasLength(2));
      expect(
        fixture.controller.residentPresentations.map(
          (resident) => resident.tab,
        ),
        [a, c],
      );
      expect(host.view(a).terminal.buffer.terminal, same(engineA));
      await host.control('release', invocation: 'b');
      await host.until(
        () =>
            host.hasText(c, 'Following output') &&
            !(host.stats['observers']! as List).contains('b'),
        'evicted B detaches while surviving readers finish',
      );
      final readsB = host.cursors('b');
      await host.control('append', text: 'capture-after-eviction\r\n');
      await host.until(
        () => _terminalText(engineA).contains('capture-after-eviction'),
        'resident A and capture continue without B',
      );
      expect(_terminalText(engineB), frozenB);
      expect(host.cursors('b'), readsB);
      expect(host.watches('b'), 1);
      await tester.tap(find.widgetWithText(TextButton, 'Output b'));
      await tester.pump();
      await host.until(
        () =>
            host.hasText(b, 'Following output') &&
            _terminalText(
              host.view(b).terminal,
            ).contains('capture-after-eviction'),
        'evicted B rebuilds a fresh prefix only when revisited',
      );
      expect(host.view(b).terminal.buffer.terminal, isNot(same(engineB)));
      expect(host.watches('b'), 2);
      expect(host.cursors('b').where((cursor) => cursor == 0), hasLength(2));
      expect(accessB.isActive, false);
      expect(fixture.controller.residentPresentations, hasLength(2));
      expect(fixture.provider.requests, isEmpty);
      await host.unmount();
    }),
  );

  testWidgets(
    'stock hidden residents retire with their exact backend without closing Terminal',
    (tester) => tester.runAsync(() async {
      final host = await commandHost(tester);
      await host.control('append', text: 'owned-before-retirement\r\n');
      final a = await host.open('a');
      await host.mount();
      await host.until(
        () => host.hasText(a, 'Following output'),
        'A ready before retirement',
      );
      final staleBeginning = tester
          .widget<TextButton>(find.widgetWithText(TextButton, 'Beginning'))
          .onPressed!;
      final b = await host.open('b');
      await host.until(
        () => host.hasText(b, 'Following output'),
        'B ready before retirement',
      );
      await fixture.create();
      await tester.pump();
      await tester.pump();
      final terminal = fixture.owners.single;
      expect(fixture.controller.residentPresentations, hasLength(3));
      await host.backends.close();
      await tester.pump();
      await tester.pump();
      expect(
        find.text('Frontend unavailable.', skipOffstage: false),
        findsNWidgets(2),
      );
      expect(find.byType(TerminalView, skipOffstage: false), findsOneWidget);
      expect(fixture.owners.single, same(terminal));
      expect(terminal.state, EnvironmentTerminalState.running);
      expect(fixture.provider.closes, isEmpty);
      staleBeginning();
      fixture.controller.select(a);
      await tester.pump();
      expect(find.text('Frontend unavailable.'), findsOneWidget);
      expect(find.byType(TerminalView), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 3));
    }),
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
    'Console-action Command uses canonical context and shares Terminal numbering',
    () async {
      final command = CommandResolver(fixture.extensions).discover().single;
      final console = fixture.extensions.discover(consoleContributions).single;
      expect(command.id, CommandId('$_plugin.new-terminal'));
      expect(command.label, console.value.actions.single.label);
      expect(command.availability, CommandAvailability.hidden);
      await expectLater(command.invoke(), throwsA(isA<CommandUnavailable>()));
      fixture.controller.setSession(
        Session(
          id: fixture.sessionA.id,
          taskId: fixture.sessionA.taskId,
          strategyId: fixture.sessionA.strategyId,
        ),
      );
      expect(command.availability, CommandAvailability.hidden);
      await expectLater(command.invoke(), throwsA(isA<CommandUnavailable>()));
      fixture.controller.setSession(fixture.sessionA);
      fixture.controller.setVisible(false);
      fixture.host.environmentAvailable = false;
      expect(command.availability, CommandAvailability.disabled);
      await expectLater(command.invoke(), throwsA(isA<CommandUnavailable>()));
      fixture.host.environmentAvailable = true;
      for (var i = 0; i < 3; i++) {
        expect(command.availability, CommandAvailability.enabled);
        expect(
          command.binding.value.availability(),
          CommandAvailability.enabled,
        );
      }
      expect(fixture.controller.visible, isFalse);
      expect(fixture.provider.restores, 0);
      expect(fixture.provider.requests, isEmpty);
      expect(fixture.owners, isEmpty);

      await command.invoke();
      expect(fixture.controller.visible, isTrue);
      expect(fixture.controller.selectedTab!.metadata.title, 'Terminal 1');
      expect(fixture.provider.requests.single.$1, fixture.additional.id);
      expect(
        fixture.provider.requests.single.$2.launchKind,
        EnvironmentTerminalLaunchKind.defaultShell,
      );
      expect(fixture.terminals.forEnvironment(fixture.primary.id), isEmpty);
      await fixture.create();
      expect(fixture.controller.selectedTab!.metadata.title, 'Terminal 2');
      fixture.controller.setVisible(false);
      await command.invoke();
      expect(fixture.controller.selectedTab!.metadata.title, 'Terminal 3');
      expect(fixture.controller.eligibleTabs, hasLength(3));
      expect(fixture.provider.requests.map((request) => request.$1), [
        fixture.additional.id,
        fixture.additional.id,
        fixture.additional.id,
      ]);
      expect(fixture.provider.restores, 1);
      expect(fixture.controller.warning, isNull);
    },
  );

  testWidgets(
    'Console-action palette reads never execute EVC or provider work',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: CommandPalette(
            extensions: fixture.extensions,
            isInteractive: () => true,
          ),
        ),
      );
      expect(find.text('New Terminal'), findsNothing);
      fixture.controller.setSession(fixture.sessionA);
      fixture.controller.setVisible(false);
      await tester.enterText(find.byType(TextField), 'terminal');
      await tester.pump();
      expect(find.text('New Terminal'), findsOneWidget);
      expect(tester.widget<ListTile>(find.byType(ListTile)).enabled, isTrue);
      fixture.host.environmentAvailable = false;
      await tester.enterText(find.byType(TextField), '$_plugin.new-terminal');
      await tester.pump();
      expect(find.text('New Terminal'), findsOneWidget);
      expect(tester.widget<ListTile>(find.byType(ListTile)).enabled, isFalse);
      expect(find.text('Unavailable'), findsOneWidget);
      expect(fixture.controller.visible, isFalse);
      expect(fixture.controller.eligibleTabs, isEmpty);
      expect(fixture.controller.warning, isNull);
      expect(fixture.provider.restores, 0);
      expect(fixture.provider.requests, isEmpty);
      expect(fixture.owners, isEmpty);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  test(
    'Console-action Command pending survives reveal and Session context changes',
    () async {
      final command = CommandResolver(fixture.extensions).discover().single;
      fixture.provider.openGate = Completer<void>();
      fixture.controller.setSession(fixture.sessionA);
      fixture.controller.setVisible(false);
      final opening = command.invoke();
      try {
        await _turn();
        expect(fixture.controller.visible, isTrue);
        expect(fixture.provider.requests, hasLength(1));
        expect(command.availability, CommandAvailability.disabled);
        fixture.controller.setVisible(false);
        fixture.controller.setSession(fixture.sessionPrimary);
        expect(command.availability, CommandAvailability.disabled);
        await expectLater(command.invoke(), throwsA(isA<CommandUnavailable>()));
        expect(fixture.controller.visible, isFalse);
        fixture.controller.setVisible(true);
        expect(fixture.controller.actions.single.isPending, isTrue);
        final duplicate = fixture.controller.invoke(
          fixture.controller.actions.single,
        );
        expect(fixture.provider.requests, hasLength(1));
        fixture.provider.openGate!.complete();
        await Future.wait([opening, duplicate]);
        expect(fixture.controller.selectedTab, isNull);
        expect(fixture.controller.eligibleTabs, isEmpty);
        expect(fixture.provider.requests.single.$1, fixture.additional.id);
        expect(command.availability, CommandAvailability.enabled);
        fixture.controller.setSession(fixture.sessionB);
        expect(fixture.controller.eligibleTabs, hasLength(1));
        expect(fixture.controller.actions.single.isPending, isFalse);
      } finally {
        if (!fixture.provider.openGate!.isCompleted) {
          fixture.provider.openGate!.complete();
        }
        await opening;
      }
    },
  );

  test(
    'Console-action EVC failure is a safe Console warning before provider work',
    () async {
      final root = await Directory('${temporary.path}/failed-action').create();
      final installation = await Directory('${root.path}/terminal').create();
      await File(
        '${temporary.path}/terminal/frontend.evc',
      ).copy('${installation.path}/frontend.evc');
      final manifest =
          jsonDecode(
                await File(
                  '${temporary.path}/terminal/adele_plugin.installation.json',
                ).readAsString(),
              )
              as Map<String, dynamic>;
      // The real stock view entrypoint requires a surface bridge. It resolves at
      // activation, but invoking it as an action fails before a Terminal request.
      manifest['components']['frontend']['presentations'][0]['actions'][0]['entrypoint'] =
          'buildTerminal';
      await File(
        '${installation.path}/adele_plugin.installation.json',
      ).writeAsString(jsonEncode(manifest));
      final isolated = _Fixture();
      addTearDown(isolated.close);
      await isolated.frontends.start(
        await PreparedPluginCatalog.discover(root.path),
      );
      expect(
        isolated.frontends.generations.single.state,
        InstalledFrontendState.active,
      );
      isolated.controller.setSession(isolated.sessionA);
      isolated.controller.setVisible(false);
      final command = CommandResolver(isolated.extensions).discover().single;
      expect(command.availability, CommandAvailability.enabled);
      expect(isolated.controller.warning, isNull);
      await command.invoke();
      expect(isolated.controller.visible, isTrue);
      expect(isolated.controller.warning, 'The console could not be created.');
      expect(isolated.provider.requests, isEmpty);
      expect(isolated.provider.restores, 0);
      expect(isolated.controller.eligibleTabs, isEmpty);
      expect(command.availability, CommandAvailability.enabled);
      expect(isolated.frontends.generations.single.failure, isNull);
    },
  );

  for (final retirement in ['command', 'console', 'raw console', 'frontend']) {
    test(
      'Console-action $retirement retirement fences callbacks and same-ID replacements',
      () async {
        final commands = CommandResolver(fixture.extensions);
        final captured = commands.discover().single;
        final callback = captured.binding.value.invoke;
        final availability = captured.binding.value.availability;
        final console = fixture.extensions
            .discover(consoleContributions)
            .single;
        final activation = fixture.frontends.generations.single;
        final targetRegistration = activation.registrations.singleWhere(
          (registration) => registration.owns(console),
        );
        await fixture.create();
        final tab = fixture.controller.selectedTab!;
        switch (retirement) {
          case 'command':
            await activation.retire(commandContributions, captured.binding.id);
            expect(console.validate, returnsNormally);
            expect(tab.isActive, isTrue);
            expect(fixture.provider.closes, isEmpty);
            await fixture.create();
            expect(fixture.controller.eligibleTabs, hasLength(2));
          case 'console':
            await activation.retire(consoleContributions, console.id);
          case 'raw console':
            final retiring = targetRegistration.close();
            // Registration closure is synchronous, ahead of registry listeners.
            var replacementCalls = 0;
            final nativeReplacement = fixture.extensions.register(
              point: consoleContributions,
              id: console.id,
              value: ConsoleContribution(
                actions: [
                  ConsoleCreationAction(
                    id: 'new-terminal',
                    label: 'Replacement',
                    create: (_) async => replacementCalls++,
                  ),
                ],
              ),
            );
            expect(availability(), CommandAvailability.hidden);
            await expectLater(
              Future<void>.sync(callback),
              throwsA(isA<CommandUnavailable>()),
            );
            expect(replacementCalls, 0);
            await retiring;
            await _turn();
            expect(commands.discover(), isEmpty);
            await activation.retire(consoleContributions, console.id);
            expect(nativeReplacement.isClosed, isFalse);
            await nativeReplacement.close();
          case 'frontend':
            await activation.close();
        }
        await _turn();
        expect(commands.discover(), isEmpty);
        expect(
          captured.binding.validate,
          throwsA(isA<StaleExtensionBinding>()),
        );
        expect(captured.availability, CommandAvailability.disabled);
        expect(availability(), CommandAvailability.hidden);
        if (retirement != 'command') {
          expect(console.validate, throwsA(isA<StaleExtensionBinding>()));
          expect(tab.isActive, isFalse);
          expect(fixture.controller.eligibleTabs, isEmpty);
          expect(fixture.provider.closes, ['resource-1']);
        } else {
          await activation.retire(consoleContributions, console.id);
        }

        final replacement = ApplicationFrontendBootstrap(
          extensions: fixture.extensions,
          consoleHost: fixture.host,
        );
        // Closing an activation leaves the shared Console host available.
        addTearDown(() async {
          for (final generation in replacement.generations) {
            await generation.close();
          }
        });
        await replacement.start(catalog);
        final fresh = commands.resolve(captured.id);
        expect(fresh.binding.id, captured.binding.id);
        expect(fresh.binding.isSameRegistration(captured.binding), isFalse);
        await activation.close();
        final requests = fixture.provider.requests.length;
        fixture.controller.setVisible(false);
        await expectLater(
          captured.invoke(),
          throwsA(isA<StaleExtensionBinding>()),
        );
        await expectLater(
          Future<void>.sync(callback),
          throwsA(isA<CommandUnavailable>()),
        );
        expect(fixture.controller.visible, isFalse);
        expect(fixture.provider.requests, hasLength(requests));
        expect(fresh.binding.validate, returnsNormally);
        await fresh.invoke();
        expect(fixture.controller.visible, isTrue);
        expect(fixture.provider.requests, hasLength(requests + 1));
        expect(fixture.provider.requests.last.$1, fixture.additional.id);
      },
    );
  }

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

final class _CommandHost {
  _CommandHost(
    this.tester,
    this.fixture,
    this.backends,
    this.connection,
    this.owner,
  );

  final WidgetTester tester;
  final _Fixture fixture;
  final ApplicationPluginBootstrap backends;
  final PluginBackendConnection connection;
  final ExtensionBinding<ConsoleContribution> owner;
  Map<Object?, Object?> stats = {};

  Future<void> control(
    String method, {
    String? text,
    String? invocation,
  }) async {
    stats =
        (await connection.request(method, {
              'text': ?text,
              'invocation': ?invocation,
            }))!
            as Map;
  }

  int watches(String invocation) =>
      (stats['watches']! as Map)[invocation] as int? ?? 0;
  int activeReads(String invocation) =>
      (stats['activeReads']! as Map)[invocation] as int? ?? 0;
  List<int> cursors(String invocation) =>
      List<int>.from((stats['cursors']! as Map)[invocation] as List? ?? []);

  Future<ConsoleTab> open(String invocation) async {
    await fixture.controller.openOrFocus(
      owner: owner,
      session: fixture.sessionA,
      descriptor: ConsoleContentDescriptor(
        key: invocation,
        metadata: ConsoleMetadata(title: 'Output $invocation'),
        data: {
          'sessionId': 'a',
          'runId': 'run',
          'toolInvocationId': invocation,
          'title': 'Output $invocation',
        },
      ),
    );
    return fixture.controller.selectedTab!;
  }

  Future<void> mount() => tester.pumpWidget(
    MaterialApp(
      home: Scaffold(body: WorkbenchConsole(controller: fixture.controller)),
    ),
  );

  Future<void> unmount() async {
    await tester.pumpWidget(const SizedBox.shrink());
    await until(
      () => (stats['observers']! as List).isEmpty,
      'all resident watches detached',
    );
    await tester.pump(const Duration(seconds: 3));
    expect(tester.takeException(), isNull);
  }

  Finder presentation(ConsoleTab tab) => find.byWidget(
    fixture.controller.residentPresentations
        .singleWhere((resident) => identical(resident.tab, tab))
        .widget,
    skipOffstage: false,
  );

  Finder findView(ConsoleTab tab) => find.descendant(
    of: presentation(tab),
    matching: find.byType(TerminalView, skipOffstage: false),
    skipOffstage: false,
  );

  TerminalView view(ConsoleTab tab) =>
      tester.widget<TerminalView>(findView(tab));

  bool hasText(ConsoleTab tab, String value) => find
      .descendant(
        of: presentation(tab),
        matching: find.text(value, skipOffstage: false),
        skipOffstage: false,
      )
      .evaluate()
      .isNotEmpty;

  bool painted(ConsoleTab tab) =>
      tester
          .widget<Opacity>(
            find.ancestor(
              of: findView(tab),
              matching: find.byType(Opacity, skipOffstage: false),
            ),
          )
          .opacity ==
      1;

  Future<void> until(bool Function() ready, String reason) async {
    for (var turn = 0; turn < 1000; turn++) {
      // Advance real backend I/O and one bounded frame without a sleep or a
      // pumpAndSettle loop over native cursor animation.
      await control('barrier');
      await tester.pump();
      expect(tester.takeException(), isNull, reason: reason);
      expect(find.text('Frontend unavailable.'), findsNothing, reason: reason);
      if (ready()) return;
    }
    fail(
      'Did not reach $reason; stats: $stats; text: ${tester.widgetList<Text>(find.byType(Text, skipOffstage: false)).map((text) => text.data).join(' | ')}',
    );
  }
}

final class _Fixture {
  _Fixture({int presentationLimit = 4}) {
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
      presentationLimit: presentationLimit,
    );
    host = _ConsoleHost(
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
  late final _ConsoleHost host;
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

final class _ConsoleHost extends PreparedConsoleHost {
  _ConsoleHost({
    required super.store,
    required super.terminals,
    required super.extensions,
    required super.controller,
  });

  bool environmentAvailable = true;

  @override
  Environment? environmentForSession(Session session) =>
      environmentAvailable ? super.environmentForSession(session) : null;
}

final class _ObservedPresentation extends ChangeNotifier
    implements ConsolePresentationAccess {
  @override
  bool isActive = true;
  @override
  Listenable get changes => this;
  @override
  ConsoleInteractionAccess? get interaction => null;
  bool get hasSubscribers => hasListeners;

  void retire() {
    isActive = false;
    notifyListeners();
  }
}

final class _MutableEligibility {
  bool eligible = true;
  bool throwEligibility = false;
  int presentations = 0;
  int releases = 0;
  late ConsoleTabRegistration registration;
}

final class _EligibleCreation implements ConsoleCreationAccess {
  _EligibleCreation(this.original, this.eligibility);

  final ConsoleCreationAccess original;
  final _MutableEligibility eligibility;

  @override
  Session get session => original.session;
  @override
  bool get isActive => original.isActive;

  @override
  ConsoleTabRegistration open(ConsoleContent content) {
    return eligibility.registration = original.open(
      ConsoleContent(
        metadata: content.metadata,
        isEligible: (session) {
          if (eligibility.throwEligibility) {
            throw StateError('Eligibility unavailable.');
          }
          return eligibility.eligible && content.isEligible(session);
        },
        keepAlive: content.keepAlive,
        createPresentation: (access) {
          eligibility.presentations++;
          return content.createPresentation(access);
        },
        closeAdvice: content.closeAdvice,
        release: () {
          eligibility.releases++;
          return content.release();
        },
      ),
    );
  }
}

final class _CaptureCreation implements ConsoleCreationAccess {
  _CaptureCreation(this.session);
  @override
  final Session session;
  @override
  bool get isActive => true;
  late ConsoleContent content;

  @override
  ConsoleTabRegistration open(ConsoleContent content) {
    this.content = content;
    return _CapturedRegistration();
  }
}

final class _CapturedRegistration implements ConsoleTabRegistration {
  @override
  bool get isActive => true;
  @override
  void updateMetadata(ConsoleMetadata metadata) {}
  @override
  Future<void> requestRemoval() async {}
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
