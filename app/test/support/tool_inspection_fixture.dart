import 'dart:io';

import 'package:adele_desktop/frontend/application_frontend_bootstrap.dart';
import 'package:adele_desktop/ui/inspection/activity_inspection_selection.dart';
import 'package:adele_orchestration/adele_orchestration.dart';
import 'package:adele_plugin_api/adele_plugin_api.dart';
import 'package:adele_product/adele_product.dart';
import 'package:command_tools_plugin/command_tools_plugin.dart';
import 'package:filesystem_tools_plugin/filesystem_tools_plugin.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plugin_runtime/plugin_runtime.dart';

import '../../tool/tool_inspection_frontend_compiler.dart';
import 'prepared_frontend_installations.dart';

Future<({Directory installations, File filesystemArtifact})>
prepareToolInspectionFrontends(Directory temporary) async {
  final commandArtifact = File('${temporary.path}/command.evc');
  final filesystemArtifact = File('${temporary.path}/filesystem.evc');
  // Compile Command in isolation, without Filesystem's declarations.
  await compileToolInspectionFrontend(
    repositoryRoot: Directory.current.parent,
    artifact: commandArtifact,
    frontend: ToolInspectionFrontend.command,
  );
  await compileToolInspectionFrontend(
    repositoryRoot: Directory.current.parent,
    artifact: filesystemArtifact,
    frontend: ToolInspectionFrontend.filesystem,
  );
  final installations = await prepareFrontendInstallations(
    root: Directory('${temporary.path}/installed'),
    artifacts: {
      'dev.adele.plugin.filesystem-tools': filesystemArtifact,
      'dev.adele.plugin.command-tools': commandArtifact,
    },
  );
  return (installations: installations, filesystemArtifact: filesystemArtifact);
}

Future<ApplicationFrontendBootstrap> startToolInspectionFrontends(
  Directory installations,
  ExtensionRegistry extensions,
) async {
  final catalog = await PreparedPluginCatalog.discover(installations.path);
  expect(catalog.issues, isEmpty);
  final frontends = ApplicationFrontendBootstrap(extensions: extensions);
  addTearDown(frontends.close);
  await frontends.start(catalog);
  expect(frontends.generations, hasLength(2));
  expect(
    frontends.generations.map((generation) => generation.state),
    everyElement(InstalledFrontendState.active),
  );
  return frontends;
}

Widget inspectionHostApp(Widget child) => MaterialApp(
  home: Scaffold(body: SingleChildScrollView(child: child)),
);

InspectionCard inspectionGroupCard(
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

ToolInvocationActivity toolActivity({
  bool patch = true,
  int proposalSequence = 1,
  ToolActivityKind kind = ToolActivityKind.prepared,
  ToolOutcomeDisposition? disposition,
  Map<String, Object?>? arguments,
  Map<String, Object?> data = const {},
}) => ToolInvocationActivity(
  id: ToolInvocationId(patch ? 'patch-1' : 'command-1'),
  preparedSequence: proposalSequence + 10,
  modelInvocationId: ModelInvocationId('model-1'),
  proposalSequence: proposalSequence,
  toolId: patch ? applyPatchToolId : runCommandToolId,
  alias: patch ? 'apply_patch' : 'run_command',
  providerCallId: 'call-1',
  canonicalArguments:
      arguments ??
      (patch
          ? {
              'relativePath': 'lib/main.dart',
              'expectedRevision': 'revision-1',
              'edits': [
                {'search': 'a', 'replace': 'b'},
                {'search': 'c', 'replace': 'd'},
              ],
            }
          : {
              'program': 'dart',
              'arguments': ['test', 'a b; c'],
              'workingDirectory': '',
              'timeoutSeconds': 120,
            }),
  changes: [ToolActivityChange(sequence: proposalSequence + 10, kind: kind)],
  outcome: disposition == null
      ? null
      : ToolOutcomeActivity(
          disposition: disposition,
          failureKind: disposition == ToolOutcomeDisposition.failure
              ? ToolFailureKind.domain
              : null,
          effectCertainty: EffectCertainty.uncertain,
          modelContent: 'Tool outcome.',
          hostData: data,
        ),
);
