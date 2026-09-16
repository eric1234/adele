import 'dart:io';

import 'package:adele_desktop/frontend/application_frontend_bootstrap.dart';
import 'package:adele_desktop/frontend/model_native_activity_bridge.dart';
import 'package:adele_desktop/frontend/prepared_frontend.dart';
import 'package:adele_desktop/ui/activity/model_native_activity_compact_host.dart';
import 'package:adele_desktop/ui/inspection/activity_inspection_selection.dart';
import 'package:adele_desktop/ui/inspection/inspection_host.dart';
import 'package:adele_orchestration/adele_orchestration.dart';
import 'package:adele_plugin_api/adele_plugin_api.dart';
import 'package:adele_product/adele_product.dart';
import 'package:adele_ui/adele_ui.dart';
import 'package:adele_ui/inspection_display.dart';
import 'package:command_tools_plugin/command_tools_plugin.dart';
import 'package:dart_eval/dart_eval.dart';
import 'package:dart_eval/dart_eval_bridge.dart';
import 'package:filesystem_tools_plugin/filesystem_tools_plugin.dart';
import 'package:flutter/material.dart';
import 'package:flutter_eval/flutter_eval.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openai_contract/openai_contract.dart'
    show openAiReasoningSummaryPresentationKind;
import 'package:plugin_runtime/plugin_runtime.dart';

import '../tool/openai_activity_frontend_compiler.dart';
import '../tool/tool_inspection_frontend_compiler.dart';
import 'support/prepared_frontend_installations.dart';

const String _library = 'package:openai_frontend/openai_frontend.dart';
const String _secret = 'ENCRYPTED-PRIVATE-SECRET';
const String _malformed = 'MALFORMED-SAFE-DATA';

void main() {
  late Directory temporary;
  late File artifact;
  late File commandArtifact;
  late File filesystemArtifact;
  late File failingArtifact;
  late Program probe;
  late Directory installations;
  late ExtensionRegistry extensions;
  late ApplicationFrontendBootstrap frontends;
  late InstalledFrontendActivation openai;

  setUpAll(() async {
    temporary = await Directory.systemTemp.createTemp('adele-openai-activity-');
    final root = Directory.current.parent;
    artifact = File('${temporary.path}/openai.evc');
    await artifact.writeAsBytes(
      await compileOpenAiActivityFrontend(repositoryRoot: root),
    );
    commandArtifact = File('${temporary.path}/command.evc');
    await compileToolInspectionFrontend(
      repositoryRoot: root,
      artifact: commandArtifact,
      frontend: ToolInspectionFrontend.command,
    );
    filesystemArtifact = File('${temporary.path}/filesystem.evc');
    await compileToolInspectionFrontend(
      repositoryRoot: root,
      artifact: filesystemArtifact,
      frontend: ToolInspectionFrontend.filesystem,
    );
    failingArtifact = File('${temporary.path}/failing.evc');
    final failing =
        (Compiler()
              ..addPlugin(flutterEvalPlugin)
              ..addPlugin(const ModelNativeActivityDeclarations())
              ..entrypoints.add(_library))
            .compile({
              'openai_frontend': {'openai_frontend.dart': _failingFrontend},
            });
    await failingArtifact.writeAsBytes(failing.write());
    probe =
        (Compiler()
              ..addPlugin(const ModelNativeActivityDeclarations())
              ..entrypoints.add('package:probe/main.dart'))
            .compile({
              'probe': {
                'main.dart': '''
import 'package:adele_ui/model_native_activity_bridge.dart';
Map<String, dynamic> inspect() => readModelNativeActivityData();
''',
              },
            });
    installations = await prepareFrontendInstallations(
      root: Directory('${temporary.path}/installed'),
      artifacts: {
        'dev.adele.openai': artifact,
        'dev.adele.plugin.command-tools': commandArtifact,
        'dev.adele.plugin.filesystem-tools': filesystemArtifact,
      },
    );
  });
  tearDownAll(() => temporary.delete(recursive: true));

  setUp(() async {
    extensions = ExtensionRegistry();
    final catalog = await PreparedPluginCatalog.discover(installations.path);
    expect(catalog.issues, isEmpty);
    frontends = ApplicationFrontendBootstrap(extensions: extensions);
    await frontends.start(catalog);
    expect(frontends.generations, hasLength(3));
    expect(
      frontends.generations.map((generation) => generation.state),
      everyElement(InstalledFrontendState.active),
    );
    openai = frontends.generations.singleWhere(
      (generation) =>
          generation.installation.metadata.id.value == 'dev.adele.openai',
    );
  });
  tearDown(() => frontends.close());

  ModelNativeActivityPresentationContribution contribution() => extensions
      .discover(modelNativeActivityPresentationContributions)
      .single
      .value;

  Widget compact(
    ModelNativePresentation presentation, {
    String fallback = 'Factual safe summary',
  }) => ModelNativeActivityCompactHost(
    extensions: extensions,
    presentation: presentation,
    fallback: Text(fallback),
  );

  testWidgets(
    'same OpenAI EVC mounts separate compact and rich views from safe data',
    (tester) async {
      final presentation = _presentation([
        'First approved summary',
        'Full detail only',
      ], truncated: true);
      await tester.pumpWidget(
        _host([
          compact(presentation),
          contribution().createInspection(presentation),
        ]),
      );
      expect(find.text('Reasoning: First approved summary'), findsOneWidget);
      final compactText = find.descendant(
        of: find.byType(ModelNativeActivityCompactHost),
        matching: find.byType(Text),
      );
      expect(compactText, findsOneWidget);
      expect(find.text('2 summary parts'), findsNothing);
      expect(find.text('Supplied summary truncated.'), findsNothing);
      expect(find.text('Reasoning summary'), findsOneWidget);
      expect(find.text('Full detail only'), findsOneWidget);
      expect(find.text('Reasoning summary truncated.'), findsOneWidget);
      expect(find.byType(TextButton), findsNothing);
      expect(find.byType(TextField), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('compact OpenAI text has bounded escaping without raw metadata', (
    tester,
  ) async {
    final presentation = _presentation([
      '\u202E\u{1F600}${'x' * 10000}',
      'Second part',
    ]);
    final raw = _output(presentation);
    await tester.binding.setSurfaceSize(const Size(360, 640));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(_host([compact(presentation)]));
    expect(find.byType(Text), findsOneWidget);
    final text = tester.widget<Text>(find.textContaining('Reasoning:')).data!;
    expect(text.runes.length, lessThanOrEqualTo(171));
    expect(text, endsWith('...'));
    expect(text, contains(r'\u202E'));
    expect(text, isNot(contains('\u202E')));
    expect(text, contains('\u{1F600}'));
    expect(find.text('Second part'), findsNothing);
    expect(find.textContaining(_secret), findsNothing);
    expect(raw.providerNativeMetadata.data.toString(), contains(_secret));
    expect(tester.takeException(), isNull);
  });

  for (final retireCompact in [true, false]) {
    testWidgets(
      'retiring OpenAI ${retireCompact ? 'compact' : 'rich'} role preserves sibling generation',
      (tester) async {
        final presentation = _presentation(['Approved summary']);
        final compactBinding = ModelNativeActivityCompactPresentationResolver(
          extensions,
        ).resolve(presentation.kind);
        final richBinding = ModelNativeActivityPresentationResolver(
          extensions,
        ).resolve(presentation.kind);
        final compactFactory = compactBinding.value.createPresentation;
        final richFactory = richBinding.value.createInspection;
        await tester.pumpWidget(
          _host([compact(presentation), richFactory(presentation)]),
        );
        await openai.retire(
          retireCompact
              ? modelNativeActivityCompactPresentationContributions
              : modelNativeActivityPresentationContributions,
          retireCompact ? compactBinding.id : richBinding.id,
        );
        await tester.pumpAndSettle();
        if (retireCompact) {
          expect(
            compactBinding.validate,
            throwsA(isA<StaleExtensionBinding>()),
          );
          expect(() => compactFactory(presentation), throwsStateError);
          richBinding.validate();
          expect(find.text('Factual safe summary'), findsOneWidget);
          expect(find.text('Reasoning summary'), findsOneWidget);
        } else {
          expect(richBinding.validate, throwsA(isA<StaleExtensionBinding>()));
          expect(() => richFactory(presentation), throwsStateError);
          compactBinding.validate();
          expect(find.text('Reasoning: Approved summary'), findsOneWidget);
        }
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'compact malformed suffix is rejected before displaying any part',
    (tester) async {
      for (final data in <Map<String, Object?>>[
        {
          'summaryParts': ['MUST-NOT-DISPLAY', 42],
          'truncated': false,
        },
        {
          'summaryParts': ['MUST-NOT-DISPLAY', '  '],
          'truncated': false,
        },
        {
          'summaryParts': ['MUST-NOT-DISPLAY'],
          'truncated': false,
          'extra': 'private',
        },
        {
          'summaryParts': List.filled(129, 'MUST-NOT-DISPLAY'),
          'truncated': false,
        },
        {
          'summaryParts': ['MUST-NOT-DISPLAY', 'x' * 65536],
          'truncated': false,
        },
      ]) {
        final presentation = ModelNativePresentation(
          kind: openAiReasoningSummaryPresentationKind,
          compactText: 'Safe factual fallback',
          data: data,
        );
        await tester.pumpWidget(_host([compact(presentation)]));
        await tester.pumpAndSettle();
        expect(find.text('Factual safe summary'), findsOneWidget);
        expect(find.textContaining('MUST-NOT-DISPLAY'), findsNothing);
        expect(find.text('Frontend unavailable.'), findsNothing);
        expect(tester.takeException(), isNull);
      }
    },
  );

  testWidgets(
    'missing compact entrypoint and corrupt EVC preserve host fallback',
    (tester) async {
      await tester.runAsync(openai.close);
      final corrupt = File('${temporary.path}/compact-corrupt.evc');
      await tester.runAsync(() => corrupt.writeAsBytes([1, 2, 3]));
      // failingArtifact deliberately exports only the rich entrypoint.
      for (final file in [failingArtifact, corrupt]) {
        await tester.runAsync(() async {
          final root = await prepareFrontendInstallations(
            root: Directory(
              '${temporary.path}/compact-${file.uri.pathSegments.last}',
            ),
            artifacts: {'dev.adele.openai': file},
          );
          final catalog = await PreparedPluginCatalog.discover(root.path);
          expect(catalog.issues, isEmpty);
          final bootstrap = ApplicationFrontendBootstrap(
            extensions: extensions,
          );
          addTearDown(bootstrap.close);
          await bootstrap.start(catalog);
          openai = bootstrap.generations.single;
          expect(openai.state, InstalledFrontendState.active);
        });
        final presentation = _presentation(['Healthy OpenAI sibling']);
        await tester.pumpWidget(_host([compact(presentation)]));
        await tester.pumpAndSettle();
        expect(find.text('Factual safe summary'), findsOneWidget);
        await tester.pumpWidget(
          _host([compact(presentation, fallback: 'Updated facts')]),
        );
        expect(find.text('Updated facts'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.runAsync(openai.close);
      }
    },
  );

  test(
    'OpenAI compact registration collision rolls back acquired rich role',
    () async {
      final registry = ExtensionRegistry();
      final blocker = registry.register(
        point: modelNativeActivityCompactPresentationContributions,
        id: extensions
            .discover(modelNativeActivityCompactPresentationContributions)
            .single
            .id,
        value: ModelNativeActivityCompactPresentationContribution(
          presentationKind: openAiReasoningSummaryPresentationKind,
          createPresentation: (_) => const SizedBox.shrink(),
        ),
      );
      final root = await prepareFrontendInstallations(
        root: Directory('${temporary.path}/collision'),
        artifacts: {'dev.adele.openai': artifact},
      );
      final catalog = await PreparedPluginCatalog.discover(root.path);
      expect(catalog.issues, isEmpty);
      final bootstrap = ApplicationFrontendBootstrap(extensions: registry);
      addTearDown(bootstrap.close);
      await bootstrap.start(catalog);
      expect(bootstrap.generations.single.state, InstalledFrontendState.failed);
      expect(
        bootstrap.generations.single.failure,
        isA<ExtensionRegistrationException>(),
      );
      expect(
        registry.discover(modelNativeActivityPresentationContributions),
        isEmpty,
      );
      expect(blocker.isClosed, isFalse);
      await blocker.close();
    },
  );

  for (final compactionOnly in [false, true]) {
    testWidgets(
      compactionOnly
          ? 'common Inspection omits compaction beside an interpreted tool'
          : 'common Inspection orders real OpenAI, Filesystem, OpenAI, Command EVCs',
      (tester) async {
        final modelId = ModelInvocationId('ordered-model');
        final patch = ToolInvocationActivity(
          id: ToolInvocationId('patch'),
          preparedSequence: 10,
          modelInvocationId: modelId,
          proposalSequence: 3,
          toolId: applyPatchToolId,
          alias: 'apply_patch',
          providerCallId: 'shared-provider-call',
          canonicalArguments: const {
            'relativePath': 'example.txt',
            'expectedRevision': 'revision',
            'edits': [
              {'search': 'before', 'replace': 'after'},
            ],
          },
          changes: const [],
        );
        final process = ToolInvocationActivity(
          id: ToolInvocationId('command'),
          preparedSequence: 11,
          modelInvocationId: modelId,
          proposalSequence: 5,
          toolId: runCommandToolId,
          alias: 'run_command',
          providerCallId: 'shared-provider-call',
          canonicalArguments: const {
            'program': 'dart',
            'arguments': ['test'],
            'workingDirectory': '',
            'timeoutSeconds': 30,
          },
          changes: const [],
        );
        final tools = [if (!compactionOnly) process, patch];
        final outputs = [
          ModelOutputActivity(
            sequence: 2,
            item: _output(
              compactionOnly ? null : _presentation(['Reasoning A']),
              type: compactionOnly ? 'compaction' : 'reasoning',
            ),
          ),
          if (!compactionOnly)
            ModelOutputActivity(
              sequence: 4,
              item: _output(_presentation(['Reasoning B'])),
            ),
          for (final tool in tools)
            ModelOutputActivity(
              sequence: tool.proposalSequence,
              item: ModelToolProposalOutput(
                ProviderToolProposal(
                  providerCallId: 'shared-provider-call',
                  alias: tool.alias,
                  arguments: tool.canonicalArguments,
                ),
              ),
            ),
        ];
        final activity = RunActivitySnapshot(
          runId: RunId('ordered-run'),
          sessionId: SessionId('ordered-session'),
          state: RunState.waiting,
          sequence: 11,
          models: [
            ModelInvocationActivity(
              id: modelId,
              startSequence: 1,
              settlement: ModelSettlement.completed,
              terminalSequence: 6,
              // Sequence, not input-list order or repeated provider IDs, is authoritative.
              outputs: outputs,
            ),
          ],
          tools: tools,
          rejectedProposals: const [],
        );
        await tester.pumpWidget(
          _host([
            InspectionHost(
              card: _groupCard(activity, modelId),
              activity: activity,
              heading: 'Direct ordered activity',
              extensions: extensions,
              onCollapse: () {},
              onExpand: () {},
              onDismiss: () {},
              onInspectOutput: (_) {},
            ),
          ]),
        );
        final labels = compactionOnly
            ? ['Apply Patch: "example.txt" / 1 edit']
            : [
                'Reasoning: Reasoning A',
                'Apply Patch: "example.txt" / 1 edit',
                'Reasoning: Reasoning B',
                'Run Command: "dart" ["test"]',
              ];
        double previous = -1;
        for (final label in labels) {
          final finder = find.text(label);
          expect(finder, findsOneWidget);
          final y = tester.getTopLeft(finder).dy;
          expect(y, greaterThan(previous));
          previous = y;
        }
        expect(find.text('Reasoning summary'), findsNothing);
        expect(find.text('Never present compaction'), findsNothing);
        expect(find.textContaining('Model native activity'), findsNothing);
        expect(find.textContaining(_secret), findsNothing);
        for (final output in outputs) {
          if (output.item case final ModelNativeOutput native) {
            expect(
              native.providerNativeMetadata.data.toString(),
              contains(_secret),
            );
            if (compactionOnly) {
              expect(native.presentation, isNull);
            } else {
              expect(
                native.presentation!.kind,
                openAiReasoningSummaryPresentationKind,
              );
              expect(
                native.presentation!.data.toString(),
                isNot(contains(_secret)),
              );
            }
          }
        }
        // Navigation belongs to common group rows, not the interpreted widgets.
        expect(find.byType(TextButton), findsNWidgets(compactionOnly ? 1 : 4));
        expect(tester.takeException(), isNull);
      },
    );
  }

  for (final parts in <List<String>>[
    ['One approved summary'],
    [
      'First: \u00E9 e\u0301 \u{1F600}',
      'Second\n\r\t\u001b[31m\u202E\u200B\\n',
      'Third\u200D\u{E007F}',
    ],
  ]) {
    testWidgets(
      'actual EVC renders ${parts.length} parts in order and escapes controls',
      (tester) async {
        await tester.binding.setSurfaceSize(const Size(360, 640));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        final presentation = _presentation(parts);
        final output = _output(presentation);
        final presenter = contribution();
        expect(
          presenter.presentationKind,
          openAiReasoningSummaryPresentationKind,
        );
        expect(presentation.data, {'summaryParts': parts, 'truncated': false});
        final bridge = ModelNativeActivityBridge(
          presentation: presentation,
          isActive: () => true,
        );
        addTearDown(bridge.invalidate);
        final runtime = Runtime(probe.write().buffer.asByteData())
          ..addPlugin(bridge);
        final transported =
            runtime.executeLib('package:probe/main.dart', 'inspect') as $Value;
        expect(transported.$reified, presentation.data);
        expect(transported.$reified.toString(), isNot(contains(_secret)));
        expect((transported.$reified as Map).keys, [
          'summaryParts',
          'truncated',
        ]);

        await tester.pumpWidget(
          _host([presenter.createInspection(presentation)]),
        );
        expect(find.text('Reasoning summary'), findsOneWidget);
        double previous = -1;
        for (final part in parts) {
          final finder = find.text(inspectionDisplayText(part));
          expect(finder, findsOneWidget);
          final y = tester.getTopLeft(finder).dy;
          expect(y, greaterThan(previous));
          previous = y;
        }
        expect(find.text('Reasoning summary truncated.'), findsNothing);
        expect(find.byType(TextButton), findsNothing);
        expect(find.byType(TextField), findsNothing);
        for (final text in tester.widgetList<Text>(find.byType(Text))) {
          expect(text.data, isNot(contains(_secret)));
          expect(text.data, isNot(contains('\u202E')));
          expect(text.data, isNot(contains('\n')));
        }
        expect(
          output.providerNativeMetadata.data.toString(),
          contains(_secret),
        );
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('safe presentation truncation stays visible in actual EVC', (
    tester,
  ) async {
    final presentation = _presentation(
      List.filled(128, 'Part'),
      truncated: true,
    );
    await tester.pumpWidget(
      _host([contribution().createInspection(presentation)]),
    );
    expect(find.text('Part'), findsNWidgets(128));
    expect(find.text('Reasoning summary truncated.'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'actual EVC rejects malformed safe maps without echoing any part',
    (tester) async {
      for (final data in <Map<String, Object?>>[
        {},
        {'summaryParts': _malformed, 'truncated': false},
        {'summaryParts': <String>[], 'truncated': false},
        {
          'summaryParts': [_malformed],
          'truncated': 'false',
        },
        {
          'summaryParts': [_malformed, 7],
          'truncated': false,
        },
        {
          'summaryParts': [_malformed, '  '],
          'truncated': false,
        },
        {
          'summaryParts': [_malformed],
          'truncated': false,
          'unexpected': _malformed,
        },
        {'summaryParts': List.filled(129, _malformed), 'truncated': false},
        {
          'summaryParts': ['${'x' * 65537}$_malformed'],
          'truncated': false,
        },
      ]) {
        final presentation = ModelNativePresentation(
          kind: openAiReasoningSummaryPresentationKind,
          compactText: _malformed,
          data: data,
        );
        await tester.pumpWidget(
          _host([contribution().createInspection(presentation)]),
        );
        expect(find.text('Reasoning summary unavailable.'), findsOneWidget);
        expect(find.text('Reasoning summary'), findsNothing);
        expect(find.textContaining(_secret), findsNothing);
        expect(find.textContaining(_malformed), findsNothing);
        expect(
          tester.widgetList<Text>(find.byType(Text)).map((text) => text.data),
          ['Reasoning summary unavailable.'],
        );
        expect(tester.takeException(), isNull);
      }
    },
  );

  testWidgets(
    'retired OpenAI views never migrate and tool presentation stays live',
    (tester) async {
      final binding = extensions
          .discover(modelNativeActivityPresentationContributions)
          .single;
      final retained = binding.value;
      final first = _presentation(['First view']);
      final second = _presentation(['Second view']);
      final source = _CommandSource();
      addTearDown(source.dispose);
      final toolView = ToolActivityInspectionResolver(
        extensions,
      ).resolve(runCommandToolId).value.createPresentation(source);
      final views = [
        retained.createInspection(first),
        retained.createInspection(second),
        toolView,
      ];
      await tester.pumpWidget(_host(views));
      final toolElement = tester.element(find.text('Run Command'));
      expect(find.text('Reasoning summary'), findsNWidgets(2));
      await tester.runAsync(() async {
        final closing = openai.close();
        expect(openai.close(), same(closing));
        await closing;
      });
      await tester.pump();
      expect(binding.validate, throwsA(isA<StaleExtensionBinding>()));
      expect(() => retained.createInspection(first), throwsStateError);
      expect(find.text('Frontend unavailable.'), findsNWidgets(2));
      expect(tester.element(find.text('Run Command')), same(toolElement));
      expect(source.listening, isTrue);
      await tester.runAsync(() async {
        final root = await prepareFrontendInstallations(
          root: Directory('${temporary.path}/replacement'),
          artifacts: {'dev.adele.openai': artifact},
        );
        final catalog = await PreparedPluginCatalog.discover(root.path);
        expect(catalog.issues, isEmpty);
        final bootstrap = ApplicationFrontendBootstrap(extensions: extensions);
        addTearDown(bootstrap.close);
        await bootstrap.start(catalog);
        openai = bootstrap.generations.single;
        expect(openai.state, InstalledFrontendState.active);
      });
      final fresh = _presentation(['Fresh generation']);
      await tester.pumpWidget(
        _host([...views, contribution().createInspection(fresh)]),
      );
      expect(find.text('Frontend unavailable.'), findsNWidgets(2));
      expect(find.text('Fresh generation'), findsOneWidget);
      expect(tester.element(find.text('Run Command')), same(toolElement));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'missing, corrupt and failed OpenAI EVC leave tool presenter independent',
    (tester) async {
      final source = _CommandSource();
      addTearDown(source.dispose);
      final toolView = ToolActivityInspectionResolver(
        extensions,
      ).resolve(runCommandToolId).value.createPresentation(source);
      await tester.pumpWidget(_host([const SizedBox.shrink(), toolView]));
      final toolElement = tester.element(find.text('Run Command'));
      await tester.runAsync(openai.close);
      await tester.runAsync(() async {
        final root = await prepareFrontendInstallations(
          root: Directory('${temporary.path}/missing-installation'),
          artifacts: {'dev.adele.openai': artifact},
        );
        final installedArtifact = File(
          '${root.path}/dev.adele.openai/frontend.evc',
        );
        await installedArtifact.delete();
        final catalog = await PreparedPluginCatalog.discover(root.path);
        expect(catalog.issues, hasLength(1));
        expect(
          catalog.issues.single.component,
          PreparedPluginComponent.frontend,
        );
        expect(catalog.installations.single.frontend, isNull);
        final bootstrap = ApplicationFrontendBootstrap(extensions: extensions);
        addTearDown(bootstrap.close);
        await bootstrap.start(catalog);
        expect(bootstrap.generations, isEmpty);

        await artifact.copy(installedArtifact.path);
        final discovered = await PreparedPluginCatalog.discover(root.path);
        expect(discovered.issues, isEmpty);
        await installedArtifact.delete();
        final vanished = ApplicationFrontendBootstrap(extensions: extensions);
        addTearDown(vanished.close);
        await vanished.start(discovered);
        expect(
          vanished.generations.single.state,
          InstalledFrontendState.failed,
        );
        expect(vanished.generations.single.failure, isA<FileSystemException>());
      });
      expect(
        extensions.discover(modelNativeActivityPresentationContributions),
        isEmpty,
      );
      final missing = (await tester.runAsync(
        () => PreparedFrontend.load(File('${temporary.path}/missing.evc')),
      ))!;
      addTearDown(missing.invalidate);
      await tester.pumpWidget(
        _host([
          missing.createPresentation(
            library: _library,
            entrypoint: 'buildOpenAiReasoningInspection',
            createBridge: () =>
                throw StateError('Must not create a missing bridge'),
          ),
          toolView,
        ]),
      );
      expect(find.text('Frontend unavailable.'), findsOneWidget);

      final corrupt = File('${temporary.path}/corrupt.evc');
      await tester.runAsync(() => corrupt.writeAsBytes([1, 2, 3]));
      for (final file in [corrupt, failingArtifact]) {
        await tester.runAsync(() async {
          final root = await prepareFrontendInstallations(
            root: Directory(
              '${temporary.path}/failed-${file.uri.pathSegments.last}',
            ),
            artifacts: {'dev.adele.openai': file},
          );
          final catalog = await PreparedPluginCatalog.discover(root.path);
          expect(catalog.issues, isEmpty);
          final bootstrap = ApplicationFrontendBootstrap(
            extensions: extensions,
          );
          addTearDown(bootstrap.close);
          await bootstrap.start(catalog);
          openai = bootstrap.generations.single;
          expect(openai.state, InstalledFrontendState.active);
        });
        final presentation = _presentation(['Not a native fallback']);
        await tester.pumpWidget(
          _host([contribution().createInspection(presentation), toolView]),
        );
        await tester.pump();
        expect(find.text('Frontend unavailable.'), findsOneWidget);
        expect(find.text('Not a native fallback'), findsNothing);
        expect(find.textContaining('PRIVATE-BUILD-ERROR'), findsNothing);
        expect(tester.element(find.text('Run Command')), same(toolElement));
        expect(source.listening, isTrue);
        if (file == failingArtifact) {
          final sibling = _presentation(['Healthy OpenAI sibling']);
          await tester.pumpWidget(
            _host([
              contribution().createInspection(presentation),
              toolView,
              contribution().createInspection(sibling),
            ]),
          );
          expect(find.text('Frontend unavailable.'), findsOneWidget);
          expect(find.text('Healthy OpenAI sibling'), findsOneWidget);
          expect(tester.element(find.text('Run Command')), same(toolElement));
        }
        source.notifyListeners();
        await tester.pumpAndSettle();
        expect(find.text('Program: "dart"'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.runAsync(openai.close);
      }
    },
  );
}

Widget _host(List<Widget> children) => MaterialApp(
  home: Scaffold(
    body: SingleChildScrollView(child: Column(children: children)),
  ),
);

InspectionCard _groupCard(
  RunActivitySnapshot activity,
  ModelInvocationId model,
) {
  final session = Session(
    id: activity.sessionId,
    taskId: TaskId('task'),
    strategyId: OrchestrationStrategyId('dev.example.chat'),
  );
  final window = WindowInspection()..presentSession(session);
  window.inspectActivity(
    session: session,
    activity: activity,
    modelInvocationId: model,
  );
  final card = window.cards.single;
  window.dispose();
  return card;
}

ModelNativePresentation _presentation(
  List<String> parts, {
  bool truncated = false,
}) => ModelNativePresentation(
  kind: openAiReasoningSummaryPresentationKind,
  compactText: parts.first,
  data: {'summaryParts': parts, 'truncated': truncated},
);

ModelNativeOutput _output(
  ModelNativePresentation? presentation, {
  String type = 'reasoning',
}) => ModelNativeOutput(
  providerItemId: 'private-item-id',
  presentation: presentation,
  providerNativeMetadata: ModelNativeEnvelope(
    kind: 'openai.responses.item.v1',
    compatibility: {'version': 1, 'private': _secret},
    data: {
      'item': {
        'type': type,
        'id': 'private-item-id',
        'summary': [
          {
            'type': 'summary_text',
            'text': 'Never parse raw summary',
            'private': _secret,
          },
        ],
        'encrypted_content': _secret,
        'content': _secret,
        'unknown': _secret,
      },
      'private': _secret,
    },
  ),
);

class _CommandSource extends ChangeNotifier
    implements ToolActivityInspectionSource {
  bool get listening => hasListeners;

  @override
  final ToolInvocationActivity snapshot = ToolInvocationActivity(
    id: ToolInvocationId('command-1'),
    preparedSequence: 3,
    modelInvocationId: ModelInvocationId('model-1'),
    proposalSequence: 2,
    toolId: runCommandToolId,
    alias: 'run_command',
    providerCallId: 'call-1',
    canonicalArguments: const {
      'program': 'dart',
      'arguments': ['test'],
      'workingDirectory': '',
      'timeoutSeconds': 30,
    },
    changes: const [],
  );
}

const String _failingFrontend = '''
import 'package:adele_ui/model_native_activity_bridge.dart';
import 'package:flutter/material.dart';
Widget buildOpenAiReasoningInspection() => BrokenInspection();
class BrokenInspection extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final String text = readModelNativeActivityData()['summaryParts'][0];
    if (text == 'Not a native fallback') throw StateError('PRIVATE-BUILD-ERROR');
    return Text(text);
  }
}
''';
