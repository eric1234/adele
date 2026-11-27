import 'dart:io';

import 'package:adele_desktop/frontend/application_frontend_bootstrap.dart';
import 'package:adele_desktop/frontend/prepared_frontend.dart';
import 'package:adele_desktop/frontend/tool_activity_inspection_bridge.dart';
import 'package:adele_desktop/ui/activity/tool_activity_compact_host.dart';
import 'package:adele_desktop/ui/inspection/activity_inspection_selection.dart';
import 'package:adele_desktop/ui/inspection/inspection_host.dart';
import 'package:adele_model_tool/adele_model_tool.dart';
import 'package:adele_orchestration/adele_orchestration.dart';
import 'package:adele_plugin_api/adele_plugin_api.dart';
import 'package:adele_ui/adele_ui.dart';
import 'package:command_tools_plugin/command_tools_plugin.dart';
import 'package:filesystem_tools_plugin/filesystem_tools_plugin.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plugin_runtime/plugin_runtime.dart';

import '../../test/support/prepared_frontend_installations.dart';
import '../../test/support/tool_inspection_fixture.dart';

void main() {
  late Directory temporary;
  late File filesystemArtifact;
  late Directory installations;
  late ExtensionRegistry extensions;
  late InstalledFrontendActivation filesystem;
  late List<ExtensionBinding<ToolActivityInspectionContribution>>
  filesystemInspections;

  setUpAll(() async {
    temporary = await Directory.systemTemp.createTemp(
      'adele-inspection-interaction-',
    );
    final prepared = await prepareToolInspectionFrontends(temporary);
    installations = prepared.installations;
    filesystemArtifact = prepared.filesystemArtifact;
  });
  tearDownAll(() => temporary.delete(recursive: true));

  setUp(() async {
    extensions = ExtensionRegistry();
    final frontends = await startToolInspectionFrontends(
      installations,
      extensions,
    );
    filesystem = frontends.generations.singleWhere(
      (generation) =>
          generation.installation.metadata.id.value ==
          'dev.adele.plugin.filesystem-tools',
    );
    filesystemInspections = extensions
        .discover(toolActivityInspectionContributions)
        .where(
          (binding) => filesystem.registrations.any(
            (registration) => registration.owns(binding),
          ),
        )
        .toList();
  });

  Widget presentation(_Source source) => ToolActivityInspectionResolver(
    extensions,
  ).resolve(source.value.toolId).value.createPresentation(source);

  Widget compact(_Source source, {String fallback = 'Factual tool fallback'}) =>
      ToolActivityCompactHost(
        extensions: extensions,
        source: source,
        fallback: Text(fallback),
      );

  void expectFilesystemInspectionsRetired() {
    expect(
      ToolActivityInspectionResolver(extensions).resolve(runCommandToolId).id,
      ExtensionId('dev.adele.plugin.command-tools.inspection'),
    );
    for (final binding in filesystemInspections) {
      expect(binding.validate, throwsA(isA<StaleExtensionBinding>()));
    }
    expect(
      extensions
          .discover(toolActivityInspectionContributions)
          .where(
            (binding) =>
                filesystemInspections.any(
                  (retired) => retired.id == binding.id,
                ) ||
                binding.value.toolId.value ==
                    'dev.adele.plugin.filesystem-tools.read-file' ||
                binding.value.toolId == applyPatchToolId,
          ),
      isEmpty,
    );
  }

  testWidgets(
    'failed compact EVC preserves refreshed facts without retry or sibling failure',
    (tester) async {
      final source = _Source(
        toolActivity(arguments: {'relativePath': 42, 'edits': []}),
      );
      final healthy = _Source(toolActivity(patch: false));
      await tester.pumpWidget(
        inspectionHostApp(
          Column(children: [compact(source), compact(healthy)]),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Factual tool fallback'), findsOneWidget);
      expect(
        find.text('Run Command: "dart" ["test", "a b; c"]'),
        findsOneWidget,
      );
      expect(source.listening, isFalse);
      final reads = source.reads;
      final subscriptions = source.subscriptions;
      source.update(toolActivity());
      await tester.pumpWidget(
        inspectionHostApp(
          Column(
            children: [
              compact(source, fallback: 'Updated facts'),
              compact(healthy),
            ],
          ),
        ),
      );
      expect(find.text('Updated facts'), findsOneWidget);
      // Host resolution reads identity; a failed EVC never subscribes again.
      expect(source.reads, reads + 1);
      expect(source.subscriptions, subscriptions);
      expect(source.listening, isFalse);
      expect(
        find.text('Run Command: "dart" ["test", "a b; c"]'),
        findsOneWidget,
      );
      await tester.pumpWidget(const SizedBox.shrink());
      expect(healthy.listening, isFalse);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'installed activations and simultaneous presenters retire independently',
    (tester) async {
      final backend = const FilesystemToolsPlugin().activate(extensions);
      final commandBackend = const CommandToolsPlugin().activate(extensions);
      addTearDown(backend.close);
      addTearDown(commandBackend.close);
      final _Source first = _Source(toolActivity());
      final _Source second = _Source(
        toolActivity(arguments: {'relativePath': 'second.dart', 'edits': []}),
      );
      final _Source process = _Source(toolActivity(patch: false));
      await tester.pumpWidget(
        inspectionHostApp(
          Column(
            children: [
              presentation(first),
              presentation(second),
              presentation(process),
            ],
          ),
        ),
      );
      expect(find.text('Apply Patch'), findsNWidgets(2));
      expect(find.text('Run Command'), findsOneWidget);
      second.update(
        toolActivity(
          kind: ToolActivityKind.approvalRequested,
          arguments: {'relativePath': 'second.dart', 'edits': []},
        ),
      );
      await tester.pump();
      await tester.pump();
      expect(find.text('Status: Waiting for approval'), findsOneWidget);
      expect(find.text('Status: Prepared'), findsNWidgets(2));
      final retainedBinding = ToolActivityInspectionResolver(
        extensions,
      ).resolve(applyPatchToolId);
      final retainedFactory = retainedBinding.value.createPresentation;
      await tester.runAsync(filesystem.close);
      await tester.pump();
      expect(retainedBinding.validate, throwsA(isA<StaleExtensionBinding>()));
      expect(find.text('Frontend unavailable.'), findsNWidgets(2));
      expect(find.text('Run Command'), findsOneWidget);
      expect(first.listening, isFalse);
      expect(second.listening, isFalse);
      expect(process.listening, isTrue);
      expect(extensions.discover(modelToolContributions), hasLength(2));
      expectFilesystemInspectionsRetired();
      expect(() => retainedFactory(first), throwsStateError);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'actual mixed EVC group follows proposal order and survives partial retirement',
    (tester) async {
      final backend = const FilesystemToolsPlugin().activate(extensions);
      final commandBackend = const CommandToolsPlugin().activate(extensions);
      addTearDown(backend.close);
      addTearDown(commandBackend.close);
      final ToolInvocationActivity patch = toolActivity(
        proposalSequence: 2,
        kind: ToolActivityKind.completed,
        disposition: ToolOutcomeDisposition.success,
        data: {'newRevision': 'mixed-revision-2', 'editCount': 2},
      );
      final ToolInvocationActivity running = toolActivity(
        patch: false,
        proposalSequence: 3,
        kind: ToolActivityKind.executionStarted,
      );
      final ProviderToolProposal rejectedProposal = ProviderToolProposal(
        providerCallId: 'call-1',
        alias: 'unsupported_operation',
        arguments: const {},
      );
      final ModelInvocationActivity model = ModelInvocationActivity(
        id: patch.modelInvocationId,
        startSequence: 1,
        terminalSequence: 5,
        settlement: ModelSettlement.completed,
        outputs: [
          for (final tool in [patch, running])
            ModelOutputActivity(
              sequence: tool.proposalSequence,
              item: ModelToolProposalOutput(
                ProviderToolProposal(
                  providerCallId: tool.providerCallId,
                  alias: tool.alias,
                  arguments: tool.canonicalArguments,
                ),
              ),
            ),
          ModelOutputActivity(
            sequence: 4,
            item: ModelToolProposalOutput(rejectedProposal),
          ),
        ],
      );
      final RejectedToolProposalActivity rejected =
          RejectedToolProposalActivity(
            sequence: 30,
            modelInvocationId: model.id,
            proposalSequence: 4,
            proposal: rejectedProposal,
            kind: ToolProposalFailureKind.unknownAlias,
            message: 'No registered tool matches this proposal.',
          );
      final ActivityGroupInspectionTarget selection =
          ActivityGroupInspectionTarget(
            sessionId: SessionId('mixed-session'),
            runId: RunId('mixed-run'),
            modelInvocationId: model.id,
          );
      RunActivitySnapshot snapshot(
        ToolInvocationActivity process,
      ) => RunActivitySnapshot(
        runId: selection.runId,
        sessionId: selection.sessionId,
        state: process.outcome == null ? RunState.running : RunState.completed,
        sequence: 40,
        models: [model],
        // Deliberately opposite the authoritative model-output proposal order.
        tools: [process, patch],
        rejectedProposals: [rejected],
      );
      final RunActivitySnapshot retained = snapshot(running);
      Widget group(RunActivitySnapshot activity) => inspectionHostApp(
        InspectionHost(
          card: inspectionGroupCard(activity, selection.modelInvocationId),
          activity: activity,
          heading: 'Patch source, then validate it',
          extensions: extensions,
          onCollapse: () {},
          onExpand: () {},
          onDismiss: () {},
          onInspectOutput: (_) {},
        ),
      );

      await tester.pumpWidget(group(retained));
      final Finder patchTitle = find.text(
        'Apply Patch: "lib/main.dart" / 2 edits',
      );
      final Finder commandTitle = find.text(
        'Run Command: "dart" ["test", "a b; c"]',
      );
      final Finder placeholder = find.text('Proposal: unsupported_operation');
      expect(find.byType(ToolActivityCompactHost), findsNWidgets(2));
      expect(patchTitle, findsOneWidget);
      expect(commandTitle, findsOneWidget);
      expect(find.textContaining('Requested edits:'), findsNothing);
      expect(find.text('New revision: mixed-revision-2'), findsNothing);
      expect(find.textContaining('Status:'), findsNothing);
      expect(find.text('Proposal rejected: unknownAlias.'), findsOneWidget);
      expect(
        tester.getTopLeft(patchTitle).dy,
        lessThan(tester.getTopLeft(commandTitle).dy),
      );
      expect(
        tester.getTopLeft(commandTitle).dy,
        lessThan(tester.getTopLeft(placeholder).dy),
      );
      final Element commandElement = tester.element(commandTitle);
      final ToolActivityInspectionSource commandSource = tester
          .widgetList<ToolActivityCompactHost>(
            find.byType(ToolActivityCompactHost),
          )
          .singleWhere((host) => host.source.snapshot.id == running.id)
          .source;
      expect(commandSource.snapshot, same(running));

      await tester.runAsync(filesystem.close);
      await tester.pumpAndSettle();
      expect(patchTitle, findsNothing);
      expect(find.text('Tool: apply_patch'), findsOneWidget);
      expect(tester.element(commandTitle), same(commandElement));
      expect(commandSource.snapshot, same(running));
      expect(
        find.text('Run Command: "dart" ["test", "a b; c"]'),
        findsOneWidget,
      );
      expect(find.text('Proposal rejected: unknownAlias.'), findsOneWidget);
      expect(extensions.discover(modelToolContributions), hasLength(2));
      expectFilesystemInspectionsRetired();
      expect(retained.state, RunState.running);
      expect(retained.tools, orderedEquals([running, patch]));
      expect(
        retained.tools.last.outcome!.hostData['newRevision'],
        'mixed-revision-2',
      );
      expect(retained.rejectedProposals.single, same(rejected));

      final ToolInvocationActivity completed = toolActivity(
        patch: false,
        proposalSequence: 3,
        kind: ToolActivityKind.completed,
        disposition: ToolOutcomeDisposition.success,
        data: {
          'termination': 'exited',
          'exitCode': 0,
          'stdout': 'Validation complete',
          'stderr': '',
          'stdoutTruncated': false,
          'stderrTruncated': false,
        },
      );
      await tester.pumpWidget(group(snapshot(completed)));
      await tester.pumpAndSettle();
      expect(tester.element(commandTitle), same(commandElement));
      expect(commandSource.snapshot, same(completed));
      expect(find.text('stdout preview: Validation complete'), findsNothing);
      expect(find.textContaining('Status:'), findsNothing);
      expect(retained.tools.first.outcome, isNull);
      expect(retained.tools.last, same(patch));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'missing and corrupt EVC are bounded without retiring other plugins',
    (tester) async {
      await tester.runAsync(filesystem.close);
      await tester.runAsync(() async {
        final root = await prepareFrontendInstallations(
          root: Directory('${temporary.path}/missing-installation'),
          artifacts: {'dev.adele.plugin.filesystem-tools': filesystemArtifact},
        );
        final installedArtifact = File(
          '${root.path}/dev.adele.plugin.filesystem-tools/frontend.evc',
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

        await filesystemArtifact.copy(installedArtifact.path);
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
      expectFilesystemInspectionsRetired();
      final _Source process = _Source(toolActivity(patch: false));
      await tester.pumpWidget(inspectionHostApp(presentation(process)));
      expect(find.text('Run Command'), findsOneWidget);
      await tester.runAsync(() async {
        final File corrupt = File('${temporary.path}/corrupt.evc');
        await corrupt.writeAsBytes([1, 2, 3]);
        final root = await prepareFrontendInstallations(
          root: Directory('${temporary.path}/corrupt-installation'),
          artifacts: {'dev.adele.plugin.filesystem-tools': corrupt},
        );
        final catalog = await PreparedPluginCatalog.discover(root.path);
        expect(catalog.issues, isEmpty);
        final bootstrap = ApplicationFrontendBootstrap(extensions: extensions);
        addTearDown(bootstrap.close);
        await bootstrap.start(catalog);
        filesystem = bootstrap.generations.single;
        // Bytes are retained at activation; decoding remains presentation-local.
        expect(filesystem.state, InstalledFrontendState.active);
      });
      final _Source patch = _Source(toolActivity());
      await tester.pumpWidget(
        inspectionHostApp(
          Column(children: [presentation(patch), presentation(process)]),
        ),
      );
      expect(find.text('Frontend unavailable.'), findsOneWidget);
      expect(find.text('Run Command'), findsOneWidget);
      expect(patch.listening, isFalse);
      expect(tester.takeException(), isNull);

      final PreparedFrontend missing = (await tester.runAsync(
        () => PreparedFrontend.load(File('${temporary.path}/missing.evc')),
      ))!;
      await tester.pumpWidget(
        inspectionHostApp(
          missing.createPresentation(
            library:
                'package:filesystem_tools_frontend/filesystem_tools_frontend.dart',
            entrypoint: 'buildApplyPatchInspection',
            createBridge: () => ToolActivityInspectionBridge(
              source: patch,
              isActive: () => true,
            ),
          ),
        ),
      );
      expect(find.text('Frontend unavailable.'), findsOneWidget);
      expect(patch.listening, isFalse);
      expect(tester.takeException(), isNull);
    },
  );
}

class _Source extends ChangeNotifier implements ToolActivityInspectionSource {
  _Source(this.value);

  @override
  final SessionId sessionId = SessionId('session');
  @override
  final RunId runId = RunId('run');
  ToolInvocationActivity value;
  int reads = 0;
  int subscriptions = 0;
  bool get listening => hasListeners;

  void update(ToolInvocationActivity activity) {
    value = activity;
    notifyListeners();
  }

  @override
  ToolInvocationActivity get snapshot {
    reads++;
    return value;
  }

  @override
  void addListener(VoidCallback listener) {
    subscriptions++;
    super.addListener(listener);
  }
}
