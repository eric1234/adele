@Timeout(Duration(minutes: 2))
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' show AppExitResponse;

import 'package:adele_core_extensions/adele_core_extensions.dart';
import 'package:adele_desktop/application.dart';
import 'package:adele_desktop/core/adele_runtime.dart';
import 'package:adele_desktop/core/application_plugin_bootstrap.dart';
import 'package:adele_desktop/core/product_lifecycle.dart';
import 'package:adele_desktop/core/run_id_source.dart';
import 'package:adele_desktop/frontend/application_frontend_bootstrap.dart';
import 'package:adele_desktop/plugins/stock_chat_execution_status.dart';
import 'package:adele_desktop/plugins/stock_chat_frontend.dart';
import 'package:adele_desktop/plugins/temporary_chatgpt_selection.dart';
import 'package:adele_desktop/ui/activity/model_native_activity_compact_host.dart';
import 'package:adele_desktop/ui/activity/tool_activity_compact_host.dart';
import 'package:adele_desktop/ui/chat/chat_controller.dart';
import 'package:adele_desktop/ui/execution/pending_tool_approval.dart';
import 'package:adele_desktop/ui/inspection/activity_inspection_selection.dart';
import 'package:adele_desktop/ui/inspection/inspection_host.dart';
import 'package:adele_desktop/ui/inspection/model_native_activity_inspection_host.dart';
import 'package:adele_desktop/ui/inspection/tool_activity_inspection_host.dart';
import 'package:adele_desktop/ui/session/session_presentation_host.dart';
import 'package:adele_desktop/ui/shell/adele_shell.dart';
import 'package:adele_environment/adele_environment.dart';
import 'package:adele_model_provider/adele_model_provider.dart';
import 'package:adele_orchestration/adele_orchestration.dart';
import 'package:adele_plugin_api/adele_plugin_api.dart';
import 'package:adele_product/adele_product.dart';
import 'package:adele_ui/adele_ui.dart';
import 'package:agent_kernel/agent_kernel.dart';
import 'package:chat_strategy_plugin/chat_strategy_plugin.dart';
import 'package:flutter/material.dart';
import 'package:flutter_eval/widgets.dart' show $StatefulWidget$bridge;
import 'package:flutter_test/flutter_test.dart';
import 'package:openai_contract/openai_contract.dart';
import 'package:plugin_builder/plugin_builder.dart';
import 'package:plugin_runtime/plugin_runtime.dart';

import '../../../tools/stock_frontend_descriptors.dart';
import '../../tool/chat_frontend_compiler.dart';
import '../../tool/openai_activity_frontend_compiler.dart';
import '../../tool/tool_inspection_frontend_compiler.dart';

const String _sourcePath = 'lib/task_answer.dart';
const String _gitPluginId = 'dev.adele.plugin.git-environment';
const String _agentsMdPluginId = 'dev.adele.plugin.agents-md';
const String _openAiPluginId = 'dev.adele.openai';
const String _chatPluginId = 'dev.adele.plugin.chat-strategy';
const String _filesystemPluginId = 'dev.adele.plugin.filesystem-tools';
const String _commandPluginId = 'dev.adele.plugin.command-tools';
const String _searchPluginId = 'dev.adele.plugin.search-tools';
const String _taskText = 'const taskAnswer = "task-worktree-only";\n';
const String _patchedText = 'const taskAnswer = "approved-task-value";\n';
const String _agentsText =
    'C2 Task guidance: inspect source before proposing an edit and validation.\n';
const String _baselineAgentsText = 'Committed guidance must be reread.\n';
const String _projectText = 'const projectAnswer = "project-source-only"; \t\n';
const String _projectAgentsText = 'Project-only guidance must not be used.\n';
const String _prompt =
    'Read lib/task_answer.dart, change taskAnswer to "approved-task-value", '
    'and validate with git diff --check after each operation is approved.';
const String _answer =
    'Patched lib/task_answer.dart to declare taskAnswer as "approved-task-value". '
    'The separately approved git diff --check exited with code 0 in the Task. '
    'E4 real-EVC canonical final reply.';
const String _narration = 'Updating the test file and validating the change.';
const String _reasoningA = 'Checking the exact file revision before the patch.';
const String _reasoningB = 'Checking the validation command after the patch.';
const String _initialPrompt = 'Explain the approval workflow without tools.';
const String _initialSummary = 'Reviewing the approval workflow without tools.';
const String _initialAnswer =
    'Source edits and validation commands require separate approvals. No tools ran.';
const String _encryptedA = 'e4-encrypted-replay-A-never-present';
const String _encryptedB = 'e4-encrypted-replay-B-never-present';
const String _encryptedInitial = 'e4-encrypted-initial-never-present';
const String _privateReasoning = 'e4-private-reasoning-content-never-present';
const String _providerExtra = 'e4-provider-extra-field-never-present';
const List<String> _presentationSecrets = [
  _encryptedA,
  _encryptedB,
  _encryptedInitial,
  _privateReasoning,
  _providerExtra,
  'encrypted_content',
  'reasoning_text',
  'provider_extra',
  'compatibility',
];
const Map<String, Object?> _commandArguments = {
  'program': 'git',
  'arguments': ['diff', '--check'],
  'workingDirectory': '',
  'timeoutSeconds': 5,
};

void main() {
  late Directory artifacts;
  late Directory installationRoot;
  late String dartaotruntime;
  late File hostArtifact;
  late File gitArtifact;
  late File agentsMdArtifact;
  late File searchArtifact;
  late File filesystemArtifact;
  late File openAiArtifact;
  late File evc;
  late File filesystemEvc;
  late File commandEvc;
  late File openAiEvc;

  setUpAll(() async {
    final Directory repository = Directory.current.parent;
    artifacts = await Directory.systemTemp.createTemp(
      'adele-normal-chatgpt-aot-',
    );
    addTearDown(() => artifacts.delete(recursive: true));
    final String dart = _dartExecutable();
    dartaotruntime = File.fromUri(
      File(dart).parent.uri.resolve(
        Platform.isWindows ? 'dartaotruntime.exe' : 'dartaotruntime',
      ),
    ).path;
    installationRoot = await Directory('${artifacts.path}/installed').create();
    for (final String pluginId in [
      _gitPluginId,
      _agentsMdPluginId,
      _searchPluginId,
      _openAiPluginId,
      _chatPluginId,
      _filesystemPluginId,
      _commandPluginId,
    ]) {
      final String directoryName = pluginId == _agentsMdPluginId
          ? 'agents-md'
          : pluginId;
      final Directory installed = await Directory(
        '${installationRoot.path}/$directoryName',
      ).create();
      await File(
        '${installed.path}/adele_plugin.installation.json',
      ).writeAsString(
        jsonEncode({
          'manifestVersion': 1,
          'metadata': {
            'id': pluginId,
            'version': '1.0.0',
            'displayName': pluginId,
          },
          'components': {
            if (pluginId == _gitPluginId ||
                pluginId == _agentsMdPluginId ||
                pluginId == _searchPluginId ||
                pluginId == _filesystemPluginId ||
                pluginId == _openAiPluginId)
              'backend': {'artifact': 'backend.aot'},
            if (stockFrontendDescriptors[pluginId] case final descriptors?)
              'frontend': {
                'artifact': 'frontend.evc',
                'presentations': descriptors,
              },
          },
        }),
      );
    }
    hostArtifact = File('${artifacts.path}/host.aot');
    gitArtifact = File('${installationRoot.path}/$_gitPluginId/backend.aot');
    agentsMdArtifact = File('${installationRoot.path}/agents-md/backend.aot');
    searchArtifact = File(
      '${installationRoot.path}/$_searchPluginId/backend.aot',
    );
    filesystemArtifact = File(
      '${installationRoot.path}/$_filesystemPluginId/backend.aot',
    );
    openAiArtifact = File(
      '${installationRoot.path}/$_openAiPluginId/backend.aot',
    );
    evc = File('${installationRoot.path}/$_chatPluginId/frontend.evc');
    filesystemEvc = File(
      '${installationRoot.path}/$_filesystemPluginId/frontend.evc',
    );
    commandEvc = File(
      '${installationRoot.path}/$_commandPluginId/frontend.evc',
    );
    openAiEvc = File('${installationRoot.path}/$_openAiPluginId/frontend.evc');
    await compileChatFrontend(repositoryRoot: repository, artifact: evc);
    await openAiEvc.writeAsBytes(
      await compileOpenAiActivityFrontend(repositoryRoot: repository),
    );
    for (final target in [
      (frontend: ToolInspectionFrontend.filesystem, artifact: filesystemEvc),
      (frontend: ToolInspectionFrontend.command, artifact: commandEvc),
    ]) {
      await compileToolInspectionFrontend(
        repositoryRoot: repository,
        artifact: target.artifact,
        frontend: target.frontend,
      );
    }
    // Use the normal artifact boundary, compiling each real backend just once.
    for (final target in [
      (
        entrypoint: 'packages/plugin_backend_host/bin/adele_backend_host.dart',
        artifact: hostArtifact,
        stage: 'normal-chatgpt-host',
      ),
      (
        entrypoint:
            'plugins/git_environment/packages/backend/bin/git_environment_backend.dart',
        artifact: gitArtifact,
        stage: 'normal-chatgpt-git',
      ),
      (
        entrypoint:
            'plugins/agents_md/packages/backend/bin/agents_md_backend.dart',
        artifact: agentsMdArtifact,
        stage: 'normal-chatgpt-agents-md',
      ),
      (
        entrypoint:
            'plugins/search_tools/packages/backend/bin/search_tools_backend.dart',
        artifact: searchArtifact,
        stage: 'normal-chatgpt-search',
      ),
      (
        entrypoint:
            'plugins/filesystem_tools/packages/backend/bin/filesystem_tools_backend.dart',
        artifact: filesystemArtifact,
        stage: 'normal-chatgpt-filesystem',
      ),
      (
        entrypoint:
            'plugins/openai/packages/backend/bin/openai_model_provider_backend.dart',
        artifact: openAiArtifact,
        stage: 'normal-chatgpt-openai',
      ),
    ]) {
      await compileAotSnapshot(
        dartExecutable: dart,
        workingDirectory: repository,
        entrypoint: target.entrypoint,
        artifact: target.artifact,
        stage: target.stage,
      );
    }
  });

  for (final failedComponent in ['none', 'backend', 'frontend']) {
    test(
      'F3c installed Filesystem components stay independent: $failedComponent failure',
      () async {
        final root = await Directory.systemTemp.createTemp(
          'adele-filesystem-only-',
        );
        addTearDown(() => root.delete(recursive: true));
        final installed = await Directory(
          '${root.path}/filesystem-tools',
        ).create();
        await File(
          '${installationRoot.path}/$_filesystemPluginId/adele_plugin.installation.json',
        ).copy('${installed.path}/adele_plugin.installation.json');
        if (failedComponent == 'backend') {
          await File('${installed.path}/backend.aot').writeAsBytes([0]);
        } else {
          await filesystemArtifact.copy('${installed.path}/backend.aot');
        }
        if (failedComponent != 'frontend') {
          await filesystemEvc.copy('${installed.path}/frontend.evc');
        }
        final runtime = AdeleRuntime();
        addTearDown(runtime.close);
        expect(
          runtime.extensions
              .discover(modelToolContributions)
              .map((b) => b.id.value),
          ['$_commandPluginId.model-tools'],
        );
        await runtime.plugins.start(
          installationRoot: root.path,
          dartaotruntimeExecutable: dartaotruntime,
          hostArtifactPath: hostArtifact.path,
        );
        expect(runtime.plugins.state, ApplicationPluginState.ready);
        expect(runtime.plugins.failure, isNull);
        final backend = runtime.plugins.backends.single;
        expect(backend.installation.metadata.id.value, _filesystemPluginId);
        expect(
          backend.state,
          failedComponent == 'backend'
              ? InstalledBackendState.failed
              : InstalledBackendState.active,
        );
        expect(
          backend.failure,
          failedComponent == 'backend' ? isNotNull : isNull,
        );
        expect(
          runtime.plugins.catalog!.issues,
          hasLength(failedComponent == 'frontend' ? 1 : 0),
        );
        final frontends = ApplicationFrontendBootstrap(
          extensions: runtime.extensions,
        );
        addTearDown(frontends.close);
        await frontends.start(runtime.plugins.catalog!);
        expect(
          runtime.extensions.discover(toolActivityInspectionContributions),
          hasLength(failedComponent == 'frontend' ? 0 : 1),
        );
        expect(
          runtime.extensions
              .discover(modelToolContributions)
              .map((b) => b.id.value),
          unorderedEquals([
            '$_commandPluginId.model-tools',
            if (failedComponent != 'backend')
              '$_filesystemPluginId.model-tools',
          ]),
        );
        expect(
          runtime.registry.providersFor(environmentProviderCapability),
          isEmpty,
        );
        expect(runtime.registry.providersFor(modelProviderCapability), isEmpty);
        expect(runtime.extensions.discover(inferenceContextSources), isEmpty);
        await runtime.plugins.close();
        expect(
          runtime.extensions
              .discover(modelToolContributions)
              .map((b) => b.id.value),
          ['$_commandPluginId.model-tools'],
          reason:
              'Retirement cannot activate an in-process filesystem fallback.',
        );
        expect(
          runtime.extensions.discover(toolActivityInspectionContributions),
          hasLength(failedComponent == 'frontend' ? 0 : 1),
          reason:
              'Backend close does not retire independently owned presentation.',
        );
      },
    );
  }

  test('F3b installed Search starts without Git, AGENTS or OpenAI', () async {
    final container = await Directory.systemTemp.createTemp(
      'adele-search-only-',
    );
    addTearDown(() => container.delete(recursive: true));
    final installed = await Directory(
      '${container.path}/search-tools',
    ).create();
    await searchArtifact.copy('${installed.path}/backend.aot');
    await File(
      '${installationRoot.path}/$_searchPluginId/adele_plugin.installation.json',
    ).copy('${installed.path}/adele_plugin.installation.json');
    final runtime = AdeleRuntime();
    addTearDown(runtime.close);
    await runtime.plugins.start(
      installationRoot: container.path,
      dartaotruntimeExecutable: dartaotruntime,
      hostArtifactPath: hostArtifact.path,
    );
    expect(runtime.plugins.state, ApplicationPluginState.ready);
    expect(runtime.plugins.failure, isNull);
    expect(runtime.plugins.catalog!.issues, isEmpty);
    final backend = runtime.plugins.backends.single;
    expect(backend.installation.metadata.id.value, _searchPluginId);
    expect(backend.state, InstalledBackendState.active);
    expect(backend.failure, isNull);
    expect(
      runtime.extensions
          .discover(modelToolContributions)
          .map((binding) => binding.id.value),
      unorderedEquals([
        '$_commandPluginId.model-tools',
        '$_searchPluginId.model-tools',
      ]),
    );
    expect(runtime.extensions.discover(inferenceContextSources), isEmpty);
    expect(
      runtime.registry.providersFor(environmentProviderCapability),
      isEmpty,
    );
    expect(runtime.registry.providersFor(modelProviderCapability), isEmpty);
  });

  for (final failedPluginId in [_searchPluginId, _filesystemPluginId]) {
    test(
      '$failedPluginId startup failure preserves sibling backends and Task creation',
      () async {
        final container = await Directory.systemTemp.createTemp(
          'adele-tools-startup-failure-',
        );
        addTearDown(() => container.delete(recursive: true));
        final runtime = AdeleRuntime(
          ids: MonotonicProductIdSource(seed: 'tools-startup-failure'),
        );
        addTearDown(runtime.close);
        final staticTools = runtime.extensions.discover(modelToolContributions);
        expect(
          staticTools.map((binding) => binding.id.value),
          unorderedEquals(['$_commandPluginId.model-tools']),
        );
        await runtime.plugins.start(
          installationRoot: installationRoot.path,
          dartaotruntimeExecutable: dartaotruntime,
          hostArtifactPath: hostArtifact.path,
          // Both real tool entrypoints reject argv before advertising extensions.
          startupArguments: {
            failedPluginId: ['unexpected-test-argument'],
          },
        );
        expect(runtime.plugins.state, ApplicationPluginState.ready);
        expect(runtime.plugins.failure, isNull);
        expect(runtime.plugins.host!.isClosed, isFalse);
        expect(runtime.plugins.catalog!.issues, isEmpty);
        expect(runtime.plugins.backends, hasLength(5));
        final failed = runtime.plugins.backends.singleWhere(
          (entry) => entry.installation.metadata.id.value == failedPluginId,
        );
        expect(
          failed.installation.backendArtifactUri,
          failedPluginId == _searchPluginId
              ? searchArtifact.uri
              : filesystemArtifact.uri,
        );
        expect(failed.state, InstalledBackendState.failed);
        expect(failed.failure, isNotNull);
        expect(failed.connection, isNull);
        for (final id in [
          _gitPluginId,
          _agentsMdPluginId,
          _openAiPluginId,
          if (failedPluginId != _searchPluginId) _searchPluginId,
          if (failedPluginId != _filesystemPluginId) _filesystemPluginId,
        ]) {
          final backend = runtime.plugins.backends.singleWhere(
            (entry) => entry.installation.metadata.id.value == id,
          );
          expect(backend.state, InstalledBackendState.active);
          expect(backend.failure, isNull);
          expect(backend.connection!.isClosed, isFalse);
          if (id == _openAiPluginId) {
            expect(backend.connection!.capabilityExposures, isEmpty);
          }
        }
        expect(
          runtime.extensions
              .discover(modelToolContributions)
              .map((binding) => binding.id.value),
          unorderedEquals([
            ...staticTools.map((binding) => binding.id.value),
            if (failedPluginId != _searchPluginId)
              '$_searchPluginId.model-tools',
            if (failedPluginId != _filesystemPluginId)
              '$_filesystemPluginId.model-tools',
          ]),
        );
        for (final binding in staticTools) {
          expect(binding.validate, returnsNormally);
        }
        final agents = runtime.extensions
            .discover(inferenceContextSources)
            .single;
        expect(agents.id.value, '$_agentsMdPluginId.instructions');
        expect(agents.validate, returnsNormally);
        expect(runtime.registry.providersFor(modelProviderCapability), isEmpty);
        expect(
          runtime.registry
              .providersFor(environmentProviderCapability)
              .single
              .id
              .value,
          'dev.adele.environment.git-worktree',
        );

        final source = Directory('${container.path}/project');
        await Directory('${source.path}/lib').create(recursive: true);
        await File('${source.path}/$_sourcePath').writeAsString(_taskText);
        await _git(source, ['init', '--initial-branch=main']);
        await _git(source, ['add', '.']);
        await _git(source, ['commit', '-m', 'Fixture baseline']);
        final project = runtime.lifecycle.createProject(source.uri);
        final created = await runtime.lifecycle.createTask(
          projectId: project.id,
          title: 'Task after $failedPluginId startup failure',
        );
        final session = runtime.lifecycle.createSession(
          taskId: created.task.id,
          strategyId: chatStrategyId,
        );
        expect(runtime.store.project(project.id), same(project));
        expect(runtime.store.task(created.task.id), same(created.task));
        expect(runtime.store.session(session.id), same(session));
        expect(session.taskId, created.task.id);
        expect(
          runtime.store.requireSessionAuthority(session.id).environmentId,
          created.environment.id,
        );
        final materialization = await runtime.lifecycle.environmentRuntime
            .materialize(created.environment.id);
        expect(materialization.validateBinding, returnsNormally);
        final read = await materialization.provider.readFile(
          created.environment.id,
          _sourcePath,
        );
        expect(read.text, _taskText);
        expect(read.revision, isNotEmpty);
        expect(runtime.plugins.host!.isClosed, isFalse);
      },
    );
  }

  testWidgets(
    'F3b installed remote Search runs in the authorized Task and retires independently',
    (tester) => tester.runAsync(() async {
      final Directory container = await Directory.systemTemp.createTemp(
        'adele-normal-search-run-',
      );
      addTearDown(() => container.delete(recursive: true));
      final Directory source = Directory('${container.path}/project');
      await Directory('${source.path}/lib').create(recursive: true);
      await File('${source.path}/$_sourcePath').writeAsString(_taskText);
      await File('${source.path}/AGENTS.md').writeAsString(_baselineAgentsText);
      await _git(source, ['init', '--initial-branch=main']);
      await _git(source, ['add', '.']);
      await _git(source, ['commit', '-m', 'Fixture baseline']);

      // Private fake credentials and a loopback endpoint keep this deterministic.
      final File credentials = File('${container.path}/credentials.json');
      await credentials.writeAsString(
        jsonEncode({
          'version': 1,
          'instances': {
            'fixture': {
              'revision': 1,
              'credential': {
                'idToken': _idToken('f3b-search-account'),
                'accessToken': 'f3b-fake-access-token',
                'refreshToken': 'f3b-fake-refresh-never-used',
                'accountId': 'f3b-search-account',
                'fedRamp': false,
              },
            },
          },
        }),
      );
      const String query = 'f3b-search-needle';
      const String taskText = 'const taskAnswer = "$query-task-only";\n';
      const String projectText =
          'const projectAnswer = "$query-project-only";\n';
      const String prompt = 'Search the Task for $query.';
      const String answer = 'Search found $query-task-only in $_sourcePath.';
      const String followUp = 'Read the Task source after Search stops.';
      const String followUpAnswer = 'The same Task source is still readable.';
      const String laterGuidance =
          'AGENTS remains active after Search stops.\n';
      final Map<String, Object?> match = {
        'relativePath': _sourcePath,
        'lineNumber': 1,
        'snippet': taskText.trimRight(),
      };
      final outbound = <Map<String, Object?>>[];
      final endpointFailures = <(Object, StackTrace)>[];
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final subscription = server.listen((request) async {
        try {
          expect(request.method, 'POST');
          expect(request.uri.path, '/backend-api/codex/responses');
          expect(
            request.headers.value(HttpHeaders.authorizationHeader),
            'Bearer f3b-fake-access-token',
          );
          expect(
            request.headers.value('ChatGPT-Account-ID'),
            'f3b-search-account',
          );
          final body =
              jsonDecode(await utf8.decoder.bind(request).join())
                  as Map<String, Object?>;
          outbound.add(body);
          expect(body['model'], 'gpt-6-astra');
          expect(body['instructions'], contains(_agentsText));
          expect(body['instructions'], isNot(contains(_baselineAgentsText)));
          expect(body['instructions'], isNot(contains(_projectAgentsText)));
          final tools = (body['tools']! as List<Object?>)
              .cast<Map<String, Object?>>();
          expect(
            tools.map((tool) => tool['name']),
            unorderedEquals([
              if (outbound.length <= 2) 'search',
              'read_file',
              'apply_patch',
              'create_file',
              'delete_file',
              'run_command',
            ]),
          );
          for (final forbidden in [
            'environmentId',
            'taskId',
            'providerId',
            'worktreePath',
          ]) {
            expect(jsonEncode(tools), isNot(contains(forbidden)));
          }
          request.response.headers.contentType = ContentType(
            'text',
            'event-stream',
            charset: 'utf-8',
          );
          switch (outbound.length) {
            case 1:
              _output(
                request.response,
                _call('search-task', 'search', {'query': query}),
              );
            case 2:
              final output = _toolOutput(body, 'search-task');
              expect(output, 'Search results:\n${jsonEncode(match)}');
              expect(output, isNot(contains('project-only')));
              _output(request.response, _message('search-final', answer));
            case 3:
              expect(body['instructions'], contains(laterGuidance));
              expect(jsonEncode(body['input']), contains(answer));
              expect(
                (body['input']! as List<Object?>)
                    .cast<Map<String, Object?>>()
                    .where((item) => item['type'] == 'function_call_output'),
                isEmpty,
              );
              _output(
                request.response,
                _call('after-search-read', 'read_file', {
                  'relativePath': _sourcePath,
                }),
              );
            case 4:
              expect(body['instructions'], contains(laterGuidance));
              final output = _toolOutput(body, 'after-search-read');
              expect(output, contains(taskText));
              expect(output, isNot(contains('project-only')));
              expect(_revision(output), isNotEmpty);
              _output(request.response, _message('read-final', followUpAnswer));
            default:
              fail(
                'Unexpected Search Responses invocation ${outbound.length}.',
              );
          }
          _sse(request.response, {
            'type': 'response.completed',
            'response': {
              'id': 'search-${outbound.length}',
              'model': 'gpt-6-astra',
            },
          });
        } on Object catch (error, stack) {
          endpointFailures.add((error, stack));
        } finally {
          await request.response.close();
        }
      });
      addTearDown(() async {
        await subscription.cancel();
        await server.close(force: true);
      });

      final runtime = AdeleRuntime(
        ids: MonotonicProductIdSource(seed: 'f3b-search'),
      );
      addTearDown(runtime.close);
      final staticTools = runtime.extensions.discover(modelToolContributions);
      expect(
        staticTools.map((binding) => binding.id.value),
        unorderedEquals(['$_commandPluginId.model-tools']),
      );
      expect(runtime.extensions.discover(inferenceContextSources), isEmpty);
      expect(
        runtime.registry.providersFor(environmentProviderCapability),
        isEmpty,
      );
      expect(runtime.registry.providersFor(modelProviderCapability), isEmpty);
      await runtime.plugins.start(
        installationRoot: installationRoot.path,
        dartaotruntimeExecutable: dartaotruntime,
        hostArtifactPath: hostArtifact.path,
        startupArguments: {
          _openAiPluginId: [
            '--chatgpt-only',
            jsonEncode({
              'credentialFile': credentials.path,
              'clientId': 'fixture',
              'instanceId': 'fixture',
              'issuer': 'http://${server.address.address}:${server.port}',
              'endpoint':
                  'http://${server.address.address}:${server.port}/backend-api/codex/responses',
            }),
          ],
        },
      );
      expect(runtime.plugins.state, ApplicationPluginState.ready);
      expect(runtime.plugins.failure, isNull);
      expect(runtime.plugins.catalog!.issues, isEmpty);
      expect(runtime.plugins.backends, hasLength(5));
      for (final backend in runtime.plugins.backends) {
        expect(
          backend.failure,
          isNull,
          reason: 'Backend ${backend.installation.metadata.id} must start.',
        );
        expect(backend.state, InstalledBackendState.active);
      }
      final searchBackend = runtime.plugins.backends.singleWhere(
        (entry) => entry.installation.metadata.id.value == _searchPluginId,
      );
      expect(searchBackend.installation.backendArtifactUri, searchArtifact.uri);
      expect(searchBackend.installation.frontend, isNull);
      expect(searchBackend.connection!.pluginId, _searchPluginId);
      expect(searchBackend.connection!.capabilityExposures, isEmpty);
      final exposure = searchBackend.connection!.extensionExposures.single;
      expect(exposure.extensionPointId, 'dev.adele.extension.model-tools');
      expect(exposure.extensionId, '$_searchPluginId.model-tools');
      final tools = runtime.extensions.discover(modelToolContributions);
      expect(
        tools.map((binding) => binding.id.value),
        unorderedEquals([
          '$_filesystemPluginId.model-tools',
          '$_commandPluginId.model-tools',
          '$_searchPluginId.model-tools',
        ]),
      );
      final searchBinding = tools.singleWhere(
        (binding) => binding.id.value == exposure.extensionId,
      );
      expect(searchBinding.validate, returnsNormally);
      final agentsBinding = runtime.extensions
          .discover(inferenceContextSources)
          .single;
      final gitBinding = runtime.registry.resolve(
        environmentProviderCapability,
      );
      final modelBinding = runtime.registry.resolve(
        modelProviderCapability,
        providerId: stockChatGptProviderId,
      );
      expect(outbound, isEmpty);

      final project = runtime.lifecycle.createProject(source.uri);
      final created = await runtime.lifecycle.createTask(
        projectId: project.id,
        title: 'Search the installed product Task',
      );
      final session = runtime.lifecycle.createSession(
        taskId: created.task.id,
        strategyId: chatStrategyId,
      );
      final authority = runtime.store.requireSessionAuthority(session.id);
      expect(authority.taskId, created.task.id);
      expect(authority.environmentId, created.environment.id);
      // Only fixture corroboration uses the path; the tool receives Session authority.
      final worktree = Directory(
        created.environment.providerState!['worktreePath']! as String,
      );
      expect(worktree.path, isNot(source.path));
      expect(await File('${worktree.path}/.git').exists(), isTrue);
      await File('${worktree.path}/$_sourcePath').writeAsString(taskText);
      await File('${source.path}/$_sourcePath').writeAsString(projectText);
      await File('${worktree.path}/AGENTS.md').writeAsString(_agentsText);
      await File('${source.path}/AGENTS.md').writeAsString(_projectAgentsText);
      final projectBefore = await _sourceSnapshot(source);
      final taskBefore = await _sourceSnapshot(worktree);
      final controller = ChatController(
        runtime: runtime,
        session: session,
        providerId: stockChatGptProviderId,
        model: 'gpt-6-astra',
        runIds: MonotonicRunIdSource(seed: 'f3b-search'),
      );
      addTearDown(controller.close);
      expect(controller.submit(prompt), isTrue);
      await controller.activeRunFuture!;
      await tester.pumpAndSettle();
      if (endpointFailures.isNotEmpty) {
        final (error, stack) = endpointFailures.first;
        Error.throwWithStackTrace(error, stack);
      }
      expect(outbound, hasLength(2));
      expect(controller.failure, isNull);
      expect(controller.pendingApproval, isNull);
      final run = controller.currentRun!.run;
      expect(run.sessionId, session.id);
      expect(run.state, RunState.completed);
      expect(run.failure, isNull);
      expect(run.interruptions, isEmpty);
      expect(controller.snapshot.entries.map((entry) => entry.content), [
        prompt,
        answer,
      ]);
      final events = run.journal.records.map((record) => record.event).toList();
      expect(events.whereType<ModelInvocationStarted>(), hasLength(2));
      for (final settlement in events.whereType<ModelInvocationSettled>()) {
        expect(settlement.settlement, ModelSettlement.completed);
        expect(settlement.metadata.effectiveModel, 'gpt-6-astra');
      }
      final invocation = events
          .whereType<ToolInvocationPrepared>()
          .single
          .invocation;
      expect(invocation.tool.definition.id.value, '$_searchPluginId.search');
      expect(invocation.tool.modelDefinition.alias, 'search');
      expect(invocation.canonicalArguments, {'query': query, 'path': ''});
      final policy = events.whereType<ToolPolicyEvaluated>().single;
      expect(policy.invocationId, invocation.id);
      expect(policy.decision, ToolPolicyDecision.allow);
      expect(policy.effects.effects, {ToolEffect.sourceRead});
      expect(policy.effects.uncertainty, EffectUncertainty.none);
      expect(policy.effects.targets.map((target) => target.uri.toString()), [
        'adele-environment:/${authority.environmentId.value}/',
      ]);
      expect(
        events.whereType<ToolExecutionStarted>().single.invocationId,
        invocation.id,
      );
      final completed = events.whereType<ToolExecutionCompleted>().single;
      expect(completed.invocationId, invocation.id);
      expect(completed.outcome.disposition, ToolOutcomeDisposition.success);
      expect(completed.outcome.effectCertainty, EffectCertainty.knownOccurred);
      expect(
        completed.outcome.hostData['environmentId'],
        authority.environmentId.value,
      );
      expect(completed.outcome.hostData['matches'], [match]);
      expect(completed.outcome.hostData['truncated'], isFalse);
      expect(completed.outcome.hostData['incomplete'], isFalse);
      expect(
        completed.outcome.modelContent,
        _toolOutput(outbound.last, 'search-task'),
      );
      expect(
        events.indexOf(completed),
        lessThan(
          events.lastIndexWhere((event) => event is ModelInvocationStarted),
        ),
      );
      expect(await _sourceSnapshot(source), projectBefore);
      expect(await _sourceSnapshot(worktree), taskBefore);

      final retired = runtime.plugins.changes
          .firstWhere(
            (_) => searchBackend.state == InstalledBackendState.terminated,
          )
          .timeout(const Duration(seconds: 10));
      await runtime.plugins.host!.stopPlugin(_searchPluginId);
      await retired;
      expect(searchBackend.connection!.isClosed, isTrue);
      expect(searchBinding.validate, throwsA(isA<StaleExtensionBinding>()));
      expect(
        invocation.tool.executable.validateBinding,
        throwsA(isA<StaleToolBindingException>()),
      );
      expect(
        runtime.extensions
            .discover(modelToolContributions)
            .map((binding) => binding.id.value),
        unorderedEquals([
          ...staticTools.map((binding) => binding.id.value),
          '$_filesystemPluginId.model-tools',
        ]),
      );
      for (final binding in [...staticTools, agentsBinding]) {
        expect(binding.validate, returnsNormally);
      }
      expect(runtime.plugins.host!.isClosed, isFalse);
      expect(runtime.plugins.state, ApplicationPluginState.ready);
      expect(runtime.plugins.failure, isNull);
      for (final backend in runtime.plugins.backends.where(
        (entry) => entry != searchBackend,
      )) {
        expect(backend.state, InstalledBackendState.active);
        expect(backend.connection!.isClosed, isFalse);
      }
      expect(
        runtime.registry.resolve(environmentProviderCapability).provider,
        same(gitBinding.provider),
      );
      expect(
        runtime.registry.resolve(modelProviderCapability).provider,
        same(modelBinding.provider),
      );
      expect(
        runtime.store.requireSessionAuthority(session.id),
        same(authority),
      );

      // Fresh normal Chat composition omits Search, while AGENTS, Git reads and
      // OpenAI continuation remain usable through their original generations.
      await File(
        '${worktree.path}/AGENTS.md',
      ).writeAsString('$_agentsText$laterGuidance');
      final taskAfterGuidance = await _sourceSnapshot(worktree);
      expect(controller.submit(followUp), isTrue);
      await controller.activeRunFuture!;
      await tester.pumpAndSettle();
      if (endpointFailures.isNotEmpty) {
        final (error, stack) = endpointFailures.first;
        Error.throwWithStackTrace(error, stack);
      }
      expect(outbound, hasLength(4));
      expect(controller.failure, isNull);
      expect(controller.pendingApproval, isNull);
      expect(controller.currentRun!.run.id, isNot(run.id));
      expect(controller.currentRun!.run.state, RunState.completed);
      expect(controller.snapshot.entries.map((entry) => entry.content), [
        prompt,
        answer,
        followUp,
        followUpAnswer,
      ]);
      final read = controller
          .activityForRun(controller.currentRun!.run.id)!
          .tools
          .single;
      expect(read.outcome!.disposition, ToolOutcomeDisposition.success);
      expect(
        read.outcome!.hostData['environmentId'],
        authority.environmentId.value,
      );
      expect(read.outcome!.hostData['text'], taskText);
      expect(await _sourceSnapshot(source), projectBefore);
      expect(await _sourceSnapshot(worktree), taskAfterGuidance);
      expect(tester.takeException(), isNull);
    }),
    timeout: const Timeout(Duration(seconds: 45)),
  );

  testWidgets(
    'F3c installed Filesystem mutation requires approval and retains real Inspection cards',
    (tester) => tester.runAsync(() async {
      await tester.binding.setSurfaceSize(const Size(1400, 1100));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final Directory container = await Directory.systemTemp.createTemp(
        'adele-normal-chatgpt-run-',
      );
      addTearDown(() => container.delete(recursive: true));
      final Directory source = Directory('${container.path}/project');
      await Directory('${source.path}/lib').create(recursive: true);
      final File sourceFile = File('${source.path}/$_sourcePath');
      await sourceFile.writeAsString(_taskText);
      await File('${source.path}/AGENTS.md').writeAsString(_baselineAgentsText);
      await _git(source, ['init', '--initial-branch=main']);
      await _git(source, ['add', '.']);
      await _git(source, ['commit', '-m', 'Fixture baseline']);

      // This is a private, non-expiring fake credential, never a user credential.
      final File credentials = File('${container.path}/credentials.json');
      final String credentialText = jsonEncode({
        'version': 1,
        'instances': {
          'fixture': {
            'revision': 1,
            'credential': {
              'idToken': _idToken('c2-fixture-account'),
              'accessToken': 'c2-fixture-chatgpt-access-token',
              'refreshToken': 'c2-fixture-refresh-never-used',
              'accountId': 'c2-fixture-account',
              'fedRamp': false,
            },
          },
        },
      });
      await credentials.writeAsString(credentialText, flush: true);

      final List<Map<String, Object?>> outbound = [];
      final List<(Object, StackTrace)> endpointFailures = [];
      final Completer<void> continuationArrived = Completer<void>();
      final Completer<void> releaseFinal = Completer<void>();
      addTearDown(() {
        if (!releaseFinal.isCompleted) releaseFinal.complete();
      });
      String? observedPath;
      String? observedRevision;
      String? patchedRevision;
      late final Map<String, Object?> patchArguments;
      final HttpServer responses = await HttpServer.bind(
        InternetAddress.loopbackIPv4,
        0,
      );
      final StreamSubscription<HttpRequest> subscription = responses.listen((
        HttpRequest request,
      ) {
        unawaited(() async {
          try {
            expect(request.method, 'POST');
            expect(request.uri.path, '/backend-api/codex/responses');
            expect(
              request.headers.value(HttpHeaders.authorizationHeader),
              'Bearer c2-fixture-chatgpt-access-token',
            );
            expect(
              request.headers.value('ChatGPT-Account-ID'),
              'c2-fixture-account',
            );
            expect(request.headers.value('X-OpenAI-Fedramp'), isNull);
            expect(
              request.headers.value(HttpHeaders.acceptHeader),
              'text/event-stream',
            );
            final Map<String, Object?> body =
                jsonDecode(await utf8.decoder.bind(request).join())
                    as Map<String, Object?>;
            outbound.add(body);
            expect(body['model'], 'gpt-6-astra');
            expect(body['store'], isFalse);
            expect(body['stream'], isTrue);
            expect(body['parallel_tool_calls'], isTrue);
            expect(body['reasoning'], {'summary': 'auto'});
            expect(body['include'], ['reasoning.encrypted_content']);
            expect(body, isNot(contains('max_output_tokens')));
            expect(body, isNot(contains('previous_response_id')));
            expect(body['instructions'], contains(_agentsText));
            expect(body['instructions'], isNot(contains(_baselineAgentsText)));
            expect(body['instructions'], contains(chatToolNarrationGuidance));
            expect(body['instructions'], isNot(contains(_projectAgentsText)));
            // Raw supplied summaries replay normally; their separate safe
            // presentation DTO must never become model input.
            final String replay = jsonEncode(body['input']);
            for (final String presentationOnly in [
              openAiReasoningSummaryPresentationKind,
              '"nativePresentation"',
              '"presentation"',
              '"compactText"',
              '"summaryParts"',
              '"truncated"',
            ]) {
              expect(replay, isNot(contains(presentationOnly)));
            }
            final List<Map<String, Object?>> tools =
                (body['tools']! as List<Object?>).cast<Map<String, Object?>>();
            expect(
              tools.map((tool) => tool['name']),
              unorderedEquals([
                'search',
                'read_file',
                'apply_patch',
                'create_file',
                'delete_file',
                'run_command',
              ]),
            );
            for (final String forbidden in [
              'environmentId',
              'taskId',
              'providerId',
              'worktreePath',
            ]) {
              expect(jsonEncode(tools), isNot(contains(forbidden)));
            }
            request.response.headers.contentType = ContentType(
              'text',
              'event-stream',
              charset: 'utf-8',
            );
            switch (outbound.length) {
              case 1:
                expect(body['input'], [
                  {
                    'type': 'message',
                    'role': 'user',
                    'content': [
                      {'type': 'input_text', 'text': _initialPrompt},
                    ],
                  },
                ]);
                _output(
                  request.response,
                  _reasoning(
                    'reasoning-initial',
                    _initialSummary,
                    _encryptedInitial,
                  ),
                );
                _output(
                  request.response,
                  _message('message-initial-final', _initialAnswer),
                );
              case 2:
                // The later Run reuses canonical history, never prior native
                // output, its encrypted replay, or presentation metadata.
                expect(body['input'], [
                  ...(outbound.first['input']! as List<Object?>),
                  {
                    'type': 'message',
                    'role': 'assistant',
                    'content': [
                      {
                        'type': 'output_text',
                        'text': _initialAnswer,
                        'annotations': <Object?>[],
                      },
                    ],
                    'status': 'completed',
                  },
                  {
                    'type': 'message',
                    'role': 'user',
                    'content': [
                      {'type': 'input_text', 'text': _prompt},
                    ],
                  },
                ]);
                _output(
                  request.response,
                  _call('read', 'read_file', {'relativePath': _sourcePath}),
                );
              case 3:
                final String readOutput = _toolOutput(body, 'read');
                expect(
                  readOutput,
                  startsWith('File: ${jsonEncode(_sourcePath)}'),
                );
                observedPath =
                    jsonDecode(
                          readOutput
                              .split('\n')
                              .first
                              .substring('File: '.length),
                        )
                        as String;
                expect(readOutput, contains(_taskText));
                expect(readOutput, isNot(contains('project-source-only')));
                observedRevision = _revision(readOutput);
                expect(observedRevision, isNotEmpty);
                final String observedLine = readOutput
                    .split('\n')
                    .singleWhere(
                      (line) => line.startsWith('const taskAnswer = '),
                    );
                patchArguments = {
                  'relativePath': observedPath,
                  'expectedRevision': observedRevision,
                  'edits': [
                    {
                      'search': observedLine,
                      'replace': observedLine.replaceFirst(
                        'task-worktree-only',
                        'approved-task-value',
                      ),
                    },
                  ],
                };
                // One completed model turn proposes both operations. Each must
                // wait for its own approval before the next inference occurs.
                _output(
                  request.response,
                  _reasoning('reasoning-a', _reasoningA, _encryptedA),
                );
                _output(
                  request.response,
                  _message('batch-purpose', _narration),
                );
                _output(
                  request.response,
                  _call('patch', 'apply_patch', patchArguments),
                );
                _output(
                  request.response,
                  _reasoning('reasoning-b', _reasoningB, _encryptedB),
                );
                _output(
                  request.response,
                  _call('command', 'run_command', _commandArguments),
                );
              case 4:
                final String patchOutput = _toolOutput(body, 'patch');
                patchedRevision = _revision(patchOutput);
                expect(patchedRevision, isNotEmpty);
                expect(patchedRevision, isNot(observedRevision));
                expect(
                  patchOutput,
                  'Patched: ${jsonEncode(observedPath)}\n'
                  'Edits applied: 1\n'
                  'Revision: ${jsonEncode(patchedRevision)}',
                );
                final String commandOutput = _toolOutput(body, 'command');
                expect(
                  commandOutput,
                  allOf(
                    contains('Program: "git"'),
                    contains('Arguments: ["diff","--check"]'),
                    contains('Termination: exited'),
                    contains('Exit code: 0'),
                  ),
                );
                expect(
                  (body['input']! as List<Object?>)
                      .cast<Map<String, Object?>>()
                      .where((item) => item['type'] == 'function_call_output')
                      .map((item) => item['call_id']),
                  ['read', 'patch', 'command'],
                );
                // Native items retain exact ciphertext and opaque fields in
                // replay, in output order, not in a separate native-first group.
                expect(body['input'], [
                  ...(outbound[2]['input']! as List<Object?>),
                  _reasoning('reasoning-a', _reasoningA, _encryptedA),
                  _message('batch-purpose', _narration),
                  _call('patch', 'apply_patch', patchArguments),
                  _reasoning('reasoning-b', _reasoningB, _encryptedB),
                  _call('command', 'run_command', _commandArguments),
                  {
                    'type': 'function_call_output',
                    'call_id': 'patch',
                    'output': patchOutput,
                  },
                  {
                    'type': 'function_call_output',
                    'call_id': 'command',
                    'output': commandOutput,
                  },
                ]);
                continuationArrived.complete();
                await releaseFinal.future;
                _output(request.response, _message('message-final', _answer));
              default:
                fail('Unexpected Responses invocation ${outbound.length}.');
            }
            _sse(request.response, {
              'type': 'response.completed',
              'response': {
                'id': 'response-${outbound.length}',
                'model': 'gpt-6-astra',
              },
            });
          } on Object catch (error, stack) {
            endpointFailures.add((error, stack));
            if (!continuationArrived.isCompleted && outbound.length == 4) {
              continuationArrived.complete();
            }
          } finally {
            await request.response.close();
          }
        }());
      });
      addTearDown(() async {
        await subscription.cancel();
        await responses.close(force: true);
      });

      final AdeleRuntime runtime = AdeleRuntime(
        ids: MonotonicProductIdSource(seed: 'c2-fixture'),
      );
      addTearDown(runtime.close);
      expect(runtime.extensions.discover(inferenceContextSources), isEmpty);
      expect(
        runtime.extensions
            .discover(modelToolContributions)
            .map((b) => b.id.value),
        ['$_commandPluginId.model-tools'],
        reason: 'Filesystem tools must be absent before installed bootstrap.',
      );
      await runtime.plugins.start(
        installationRoot: installationRoot.path,
        dartaotruntimeExecutable: dartaotruntime,
        hostArtifactPath: hostArtifact.path,
        startupArguments: {
          _openAiPluginId: [
            '--chatgpt-only',
            jsonEncode({
              'credentialFile': credentials.path,
              'clientId': 'fixture',
              'instanceId': 'fixture',
              'issuer': 'http://${responses.address.address}:${responses.port}',
              'endpoint':
                  'http://${responses.address.address}:${responses.port}/backend-api/codex/responses',
            }),
          ],
        },
      );
      expect(runtime.plugins.state, ApplicationPluginState.ready);
      expect(runtime.plugins.failure, isNull);
      expect(runtime.plugins.registry, same(runtime.registry));
      expect(runtime.plugins.backends, hasLength(5));
      for (final backend in runtime.plugins.backends) {
        expect(
          backend.failure,
          isNull,
          reason: 'Backend ${backend.installation.metadata.id} must start.',
        );
        expect(backend.state, InstalledBackendState.active);
      }
      final agentsMdBackend = runtime.plugins.backends.singleWhere(
        (entry) => entry.installation.metadata.id.value == _agentsMdPluginId,
      );
      final filesystemBackend = runtime.plugins.backends.singleWhere(
        (entry) => entry.installation.metadata.id.value == _filesystemPluginId,
      );
      expect(
        filesystemBackend.installation.backendArtifactUri,
        filesystemArtifact.uri,
      );
      expect(
        filesystemBackend.installation.frontend!.artifactUri,
        filesystemEvc.uri,
      );
      expect(filesystemBackend.connection!.capabilityExposures, isEmpty);
      expect(
        filesystemBackend.connection!.extensionExposures.single.extensionId,
        '$_filesystemPluginId.model-tools',
      );
      expect(
        agentsMdBackend.installation.backendArtifactUri,
        agentsMdArtifact.uri,
      );
      expect(agentsMdBackend.installation.frontend, isNull);
      final agentsMdBinding = runtime.extensions
          .discover(inferenceContextSources)
          .single;
      expect(agentsMdBinding.id.value, '$_agentsMdPluginId.instructions');
      expect(agentsMdBinding.validate, returnsNormally);
      expect(
        agentsMdBinding.value.failureMode,
        InferenceContextFailureMode.required,
      );
      expect(
        runtime.registry.providersFor(modelProviderCapability).single.id,
        stockChatGptProviderId,
      );
      expect(
        runtime.registry
            .providersFor(environmentProviderCapability)
            .single
            .id
            .value,
        'dev.adele.environment.git-worktree',
      );
      expect(outbound, isEmpty);
      final Project project = runtime.lifecycle.createProject(source.uri);
      final TaskCreationResult created = await runtime.lifecycle.createTask(
        projectId: project.id,
        title: 'Approve a Task source edit and validation',
      );
      expect(runtime.store.project(project.id), same(project));
      expect(runtime.store.task(created.task.id), same(created.task));
      expect(created.task.projectId, project.id);
      expect(
        runtime.store.primaryEnvironmentFor(created.task.id),
        same(created.environment),
      );
      final Session session = runtime.lifecycle.createSession(
        taskId: created.task.id,
        strategyId: chatStrategyId,
      );
      expect(runtime.store.session(session.id), same(session));
      expect(session.taskId, created.task.id);
      expect(session.strategyId, chatStrategyId);
      final SessionEnvironmentAuthority authority = runtime.store
          .requireSessionAuthority(session.id);
      expect(authority.taskId, created.task.id);
      expect(authority.environmentId, created.environment.id);

      // Only fixture corroboration inspects stock-owned provider state. The
      // controller and tools receive the canonical Session, never this path.
      final Directory worktree = Directory(
        created.environment.providerState!['worktreePath']! as String,
      );
      expect(await File('${worktree.path}/.git').exists(), isTrue);
      expect(worktree.path, isNot(source.path));
      expect(
        await File('${worktree.path}/$_sourcePath').readAsString(),
        _taskText,
      );
      // Establish distinct staged, unstaged, and untracked Project data after
      // Task creation, plus a dirty Task fixture that must also survive the Run.
      await sourceFile.writeAsString('const projectStaged = 1;\n');
      await _git(source, ['add', _sourcePath]);
      await sourceFile.writeAsString(_projectText);
      await File('${source.path}/AGENTS.md').writeAsString(_projectAgentsText);
      await File('${worktree.path}/AGENTS.md').writeAsString(_agentsText);
      await File(
        '${source.path}/scratch.txt',
      ).writeAsString('Project scratch.\n');
      await File(
        '${worktree.path}/scratch.txt',
      ).writeAsString('Task scratch.\n');
      final Map<String, Object?> projectBefore = await _sourceSnapshot(source);
      final Map<String, Object?> taskBefore = await _sourceSnapshot(worktree);
      expect(projectBefore['status'], isNotEmpty);
      expect(projectBefore['staged'], isNotEmpty);
      expect(taskBefore['status'], isNotEmpty);
      // A successful check cannot come from accidentally validating the Project:
      // its deliberately dirty source contains a whitespace error absent in Task.
      final ProcessResult projectCheck = await Process.run('git', [
        'diff',
        '--check',
      ], workingDirectory: source.path);
      expect(projectCheck.exitCode, isNot(0));
      expect(projectCheck.stdout, contains(_sourcePath));

      late final VoidCallback refreshFrontend;
      StateSetter? updatePresentation;
      bool presentationScheduled = false;
      void refreshPresentation() {
        if (updatePresentation == null || presentationScheduled) return;
        presentationScheduled = true;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          presentationScheduled = false;
          updatePresentation?.call(() {});
        });
        WidgetsBinding.instance.ensureVisualUpdate();
      }

      final WindowInspection inspection = WindowInspection()
        ..presentSession(session)
        ..addListener(refreshPresentation);
      addTearDown(() {
        inspection.removeListener(refreshPresentation);
        inspection.dispose();
      });
      final ChatController controller = ChatController(
        runtime: runtime,
        session: session,
        providerId: stockChatGptProviderId,
        model: 'gpt-6-astra',
        runIds: MonotonicRunIdSource(seed: 'c2-fixture'),
        onChanged: () {
          refreshFrontend();
          refreshPresentation();
        },
        onActivityChanged: () {
          if (inspection.cards.isNotEmpty) refreshPresentation();
        },
      );
      addTearDown(controller.close);
      final frontend = StockChatFrontend(
        extensions: runtime.extensions,
        controllerForSession: (presentedSession) {
          expect(presentedSession, same(session));
          return controller;
        },
        inspectActivity: (presentedSession, runId, modelInvocationId) {
          final ChatActivitySummary? summary = controller.activitySummary(
            runId,
            modelInvocationId,
          );
          if (!identical(presentedSession, session) ||
              controller.isClosed ||
              summary == null) {
            return false;
          }
          final RunActivitySnapshot? activity = controller.activityForRun(
            runId,
          );
          if (activity == null) return false;
          if (summary.outputSequence case final int sequence) {
            return inspection.inspectOutput(
              session: presentedSession,
              activity: activity,
              modelInvocationId: modelInvocationId,
              outputSequence: sequence,
            );
          }
          return inspection.inspectActivity(
            session: presentedSession,
            activity: activity,
            modelInvocationId: modelInvocationId,
          );
        },
      );
      refreshFrontend = frontend.refresh;
      final frontends = ApplicationFrontendBootstrap(
        extensions: runtime.extensions,
        sessionAdapters: {'stock-chat-controller-v1': frontend},
      );
      addTearDown(frontends.close);
      final PreparedPluginCatalog catalog = runtime.plugins.catalog!;
      await frontends.start(catalog);
      expect(frontends.catalog, same(catalog));
      expect(catalog.issues, isEmpty);
      expect(catalog.installations, hasLength(7));
      expect(
        catalog.installations.where(
          (entry) => entry.backendArtifactUri != null,
        ),
        hasLength(5),
      );
      expect(
        catalog.installations.where((entry) => entry.frontend != null),
        hasLength(4),
      );
      expect(frontends.generations, hasLength(4));
      for (final generation in frontends.generations) {
        expect(generation.state, InstalledFrontendState.active);
        expect(generation.failure, isNull);
        expect(catalog.installations, contains(same(generation.installation)));
        expect(
          generation.installation.installationDirectory.path,
          startsWith(installationRoot.path),
        );
      }
      final openAiFrontend = frontends.generations.singleWhere(
        (entry) => entry.installation.metadata.id.value == _openAiPluginId,
      );
      expect(
        openAiFrontend.installation,
        same(
          runtime.plugins.backends
              .singleWhere(
                (entry) =>
                    entry.installation.metadata.id.value == _openAiPluginId,
              )
              .installation,
        ),
      );
      addTearDown(() async {
        updatePresentation = null;
        if (!releaseFinal.isCompleted) releaseFinal.complete();
        await controller.close();
        await tester.pumpWidget(const SizedBox.shrink());
      });
      await tester.pumpWidget(
        MaterialApp(
          home: StatefulBuilder(
            builder: (context, setState) {
              updatePresentation = setState;
              return AdeleShell(
                project: project,
                task: created.task,
                environment: created.environment,
                environmentReady:
                    runtime.lifecycle.environmentRuntime.currentMaterialization(
                      created.environment.id,
                    ) !=
                    null,
                selectors: const [],
                onSelectProject: (_) =>
                    fail('Project selection is not part of this Run.'),
                sessionControls: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    SessionPresentationHost(
                      session: session,
                      extensions: runtime.extensions,
                    ),
                    StockChatExecutionStatus(controller: controller),
                  ],
                ),
                inspection: inspection.cards.isEmpty
                    ? null
                    : InspectionStackHost(
                        key: const ValueKey('inspection-stack'),
                        cards: inspection.cards,
                        cardBuilder: (context, card) => InspectionHost(
                          card: card,
                          activity: controller.activityForRun(
                            card.target.runId,
                          ),
                          heading: controller
                              .activitySummary(
                                card.target.runId,
                                card.target.modelInvocationId,
                              )!
                              .content,
                          extensions: runtime.extensions,
                          onCollapse: () => inspection.collapse(card.id),
                          onExpand: () => inspection.expand(card.id),
                          onDismiss: () => inspection.dismiss(card.id),
                          onInspectOutput: (target) {
                            final activity = controller.activityForRun(
                              target.runId,
                            );
                            if (activity == null) return;
                            inspection.inspectOutput(
                              session: session,
                              activity: activity,
                              modelInvocationId: target.modelInvocationId,
                              outputSequence: target.outputSequence,
                              originCardId: card.id,
                            );
                          },
                        ),
                      ),
              );
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      final Finder sessionHost = find.byType(SessionPresentationHost);
      final Finder inspectionHost = find.byKey(
        const ValueKey('inspection-stack'),
      );
      final Finder narratedActivity = find.descendant(
        of: sessionHost,
        matching: find.textContaining(_narration),
      );
      final Finder fallbackActivity = find.descendant(
        of: sessionHost,
        matching: find.text('Tool: read_file'),
      );
      final Finder promptField = find.descendant(
        of: sessionHost,
        matching: find.byType(TextField),
      );
      final Finder send = find.descendant(
        of: sessionHost,
        matching: find.text('Send'),
      );
      final Finder allowOnce = find.descendant(
        of: find.byType(StockChatExecutionStatus),
        matching: find.widgetWithText(FilledButton, 'Allow once'),
      );
      expect(sessionHost, findsOneWidget);
      expect(
        tester.widget<AdeleShell>(find.byType(AdeleShell)).project,
        same(project),
      );
      expect(
        tester.widget<AdeleShell>(find.byType(AdeleShell)).task,
        same(created.task),
      );
      expect(
        tester.widget<AdeleShell>(find.byType(AdeleShell)).environment,
        same(created.environment),
      );
      expect(inspection.cards, isEmpty);
      expect(inspectionHost, findsNothing);
      expect(promptField, findsOneWidget);
      expect(send, findsOneWidget);
      expect(allowOnce, findsNothing);
      expect(tester.widget<TextField>(promptField).controller!.text, isEmpty);
      expect(tester.widget<TextField>(promptField).enabled, isTrue);
      final Finder chatPresentation = find.descendant(
        of: sessionHost,
        matching: find.byWidgetPredicate(
          (widget) => widget is $StatefulWidget$bridge,
        ),
      );
      final chatWidget = tester.widget<$StatefulWidget$bridge>(
        chatPresentation,
      );
      final chatState = tester.state(chatPresentation);
      final chatRuntime = chatWidget.$runtime;
      expect(outbound, isEmpty);
      expect(controller.snapshot.entries, isEmpty);
      expect(controller.currentRun, isNull);
      expect(controller.activeRunFuture, isNull);
      expect(controller.pendingApproval, isNull);
      Finder nativeHost(ModelNativePresentation presentation) =>
          find.descendant(
            of: inspectionHost,
            matching: find.byWidgetPredicate(
              (widget) =>
                  widget is ModelNativeActivityInspectionHost &&
                  identical(widget.presentation, presentation),
            ),
          );

      // A single safe native output opens an individual card directly from Chat.
      // Final assistant text is canonical history, not a second activity.
      await tester.enterText(promptField, _initialPrompt);
      await tester.ensureVisible(send);
      await tester.tap(send);
      final Future<void>? starting = controller.activeRunFuture;
      expect(starting, isNotNull);
      await starting!;
      await tester.pumpAndSettle();
      expect(endpointFailures, isEmpty);
      final initialExecution = controller.currentRun!;
      final AgentRun initialRun = initialExecution.run;
      expect(initialRun.id, RunId('run-c2-fixture-1'));
      expect(initialRun.sessionId, session.id);
      expect(initialRun.state, RunState.completed);
      expect(initialRun.failure, isNull);
      expect(initialRun.interruptions, isEmpty);
      expect(controller.failure, isNull);
      expect(controller.isRunning, isFalse);
      expect(controller.isAdvancing, isFalse);
      expect(controller.activeRunFuture, isNull);
      expect(controller.pendingApproval, isNull);
      expect(allowOnce, findsNothing);
      expect(tester.widget<TextField>(promptField).enabled, isTrue);
      expect(tester.widget<TextField>(promptField).controller!.text, isEmpty);
      expect(outbound, hasLength(1));
      final RunActivitySnapshot initialActivity = controller.activityForRun(
        initialRun.id,
      )!;
      expect(controller.activitySnapshots, [initialActivity]);
      expect(initialActivity.models, hasLength(1));
      expect(initialActivity.tools, isEmpty);
      expect(initialActivity.rejectedProposals, isEmpty);
      final ModelInvocationActivity initialModel =
          initialActivity.models.single;
      expect(initialModel.settlement, ModelSettlement.completed);
      expect(initialModel.failure, isNull);
      expect(initialModel.outputs.map((output) => output.item), [
        isA<ModelNativeOutput>(),
        isA<ModelTextOutput>(),
      ]);
      final ModelNativeOutput initialNative =
          initialModel.outputs.first.item as ModelNativeOutput;
      _expectSafePresentation(
        initialNative,
        id: 'reasoning-initial',
        summary: _initialSummary,
        encrypted: _encryptedInitial,
      );
      final ChatActivitySummary initialSummary = controller.timeline
          .whereType<ChatActivitySummary>()
          .single;
      expect(initialSummary.invocationId, initialModel.id);
      expect(initialSummary.content, _initialSummary);
      expect(initialSummary.activityCount, 1);
      expect(initialSummary.isGroup, isFalse);
      expect(
        initialSummary.outputSequence,
        initialModel.outputs.first.sequence,
      );
      expect(controller.timeline.map((entry) => entry.content), [
        _initialPrompt,
        _initialSummary,
        _initialAnswer,
      ]);
      expect(controller.snapshot.entries.map((entry) => entry.content), [
        _initialPrompt,
        _initialAnswer,
      ]);
      final initialEvents = initialRun.journal.records
          .map((record) => record.event)
          .toList();
      expect(initialEvents.whereType<ModelInvocationStarted>(), hasLength(1));
      final initialSettlement = initialEvents
          .whereType<ModelInvocationSettled>()
          .single;
      expect(initialSettlement.settlement, ModelSettlement.completed);
      expect(initialSettlement.metadata.effectiveModel, 'gpt-6-astra');
      expect(initialEvents.whereType<ToolInvocationPrepared>(), isEmpty);
      expect(initialEvents.whereType<ToolPolicyEvaluated>(), isEmpty);
      expect(initialEvents.whereType<ToolExecutionStarted>(), isEmpty);
      expect(initialEvents.whereType<RunInterrupted>(), isEmpty);
      final Finder initialActivityLink = find.descendant(
        of: sessionHost,
        matching: find.textContaining(_initialSummary),
      );
      _expectVerticalOrder(tester, [
        find.descendant(of: sessionHost, matching: find.text(_initialPrompt)),
        initialActivityLink,
        find.descendant(of: sessionHost, matching: find.text(_initialAnswer)),
      ]);

      // Both components of the one OpenAI installation came from the same
      // startup snapshot. No stock-specific delayed activation is involved.
      final nativeResolver = ModelNativeActivityPresentationResolver(
        runtime.extensions,
      );
      expect(
        nativeResolver
            .resolve(initialNative.presentation!.kind)
            .value
            .presentationKind,
        openAiReasoningSummaryPresentationKind,
      );
      await tester.pumpAndSettle();
      await tester.ensureVisible(initialActivityLink);
      await tester.tap(
        find.ancestor(
          of: initialActivityLink,
          matching: find.byType(TextButton),
        ),
      );
      await tester.pumpAndSettle();
      final InspectionCard cardA = inspection.cards.single;
      final ModelOutputInspectionTarget targetA =
          cardA.target as ModelOutputInspectionTarget;
      expect(targetA.sessionId, session.id);
      expect(targetA.runId, initialRun.id);
      expect(targetA.modelInvocationId, initialModel.id);
      expect(targetA.outputSequence, initialModel.outputs.first.sequence);
      expect(cardA.isCollapsed, isFalse);
      final Finder initialNativeHost = nativeHost(initialNative.presentation!);
      final initialNativeState = tester.state(initialNativeHost);
      expect(find.byType(ModelNativeActivityInspectionHost), findsOneWidget);
      expect(find.byType(ToolActivityInspectionHost), findsNothing);
      expect(
        find.descendant(
          of: inspectionHost,
          matching: find.byType(ModelNativeActivityCompactHost),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: sessionHost,
          matching: find.byType(ModelNativeActivityCompactHost),
        ),
        findsOneWidget,
      );
      expect(find.byType(ToolActivityCompactHost), findsNothing);
      for (final String label in ['Reasoning summary', _initialSummary]) {
        expect(
          find.descendant(of: initialNativeHost, matching: find.text(label)),
          findsOneWidget,
        );
      }
      expect(
        initialRun.journal.records.map((record) => record.event),
        initialEvents,
      );
      expect(outbound, hasLength(1));
      expect(await _sourceSnapshot(source), projectBefore);
      expect(await _sourceSnapshot(worktree), taskBefore);
      _expectNoPresentationSecrets(tester, controller);
      expect(tester.takeException(), isNull);

      // Process/socket work, including interpreted submission, uses real async.
      await tester.enterText(promptField, _prompt);
      await tester.ensureVisible(send);
      await tester.tap(send);
      final Future<void>? running = controller.activeRunFuture;
      expect(running, isNotNull);
      expect(controller.isAdvancing, isTrue);
      expect(controller.submit('Duplicate must not enter history.'), isFalse);
      await running!;
      await tester.pumpAndSettle();
      expect(
        find.descendant(of: sessionHost, matching: find.text(_prompt)),
        findsOneWidget,
      );
      expect(tester.widget<TextField>(promptField).controller!.text, isEmpty);
      expect(tester.widget<TextField>(promptField).enabled, isFalse);
      expect(find.text('Tool: apply_patch'), findsOneWidget);
      expect(allowOnce, findsOneWidget);

      expect(narratedActivity, findsOneWidget);
      expect(fallbackActivity, findsOneWidget);
      expect(
        find.descendant(of: sessionHost, matching: find.text('Allow once')),
        findsNothing,
      );

      expect(endpointFailures, isEmpty);
      expect(controller.failure, isNull);
      expect(controller.activeRunFuture, isNull);
      expect(controller.isAdvancing, isFalse);
      expect(controller.isRunning, isTrue);
      final execution = controller.currentRun!;
      final AgentRun run = execution.run;
      expect(execution, isNot(same(initialExecution)));
      expect(run.id, RunId('run-c2-fixture-2'));
      expect(run.sessionId, session.id);
      expect(run.state, RunState.waiting);
      expect(outbound, hasLength(3));
      expect(controller.snapshot.entries.map((entry) => entry.content), [
        _initialPrompt,
        _initialAnswer,
        _prompt,
      ]);
      final ChatActivitySummary batch = controller.timeline
          .whereType<ChatActivitySummary>()
          .last;
      expect(batch.content, _narration);
      expect(batch.activityCount, 4);
      expect(batch.isGroup, isTrue);
      expect(batch.outputSequence, isNull);
      expect(
        controller.timeline.whereType<ChatActivitySummary>(),
        hasLength(3),
      );
      final ChatActivitySummary readSummary = controller.timeline
          .whereType<ChatActivitySummary>()
          .where((entry) => entry.runId == run.id)
          .first;
      expect(readSummary.activityCount, 1);
      expect(readSummary.isGroup, isFalse);
      expect(
        readSummary.outputSequence,
        execution.activity.snapshot.models.first.outputs.single.sequence,
      );
      final RunActivitySnapshot waitingEvidence = execution.activity.snapshot;
      expect(waitingEvidence.models.last.outputs.map((output) => output.item), [
        isA<ModelNativeOutput>(),
        isA<ModelTextOutput>(),
        isA<ModelToolProposalOutput>(),
        isA<ModelNativeOutput>(),
        isA<ModelToolProposalOutput>(),
      ]);
      final ModelNativeOutput nativeA =
          waitingEvidence.models.last.outputs[0].item as ModelNativeOutput;
      final ModelNativeOutput nativeB =
          waitingEvidence.models.last.outputs[3].item as ModelNativeOutput;
      _expectSafePresentation(
        nativeA,
        id: 'reasoning-a',
        summary: _reasoningA,
        encrypted: _encryptedA,
      );
      _expectSafePresentation(
        nativeB,
        id: 'reasoning-b',
        summary: _reasoningB,
        encrypted: _encryptedB,
      );
      _expectNoPresentationSecrets(tester, controller);
      final PendingToolApproval patchApproval = controller.pendingApproval!;
      final ToolApprovalInterruption patchInterruption =
          run.interruptions.values.single as ToolApprovalInterruption;
      expect(patchApproval.toolAlias, 'apply_patch');
      expect(patchApproval.effects, {ToolEffect.sourceMutation});
      expect(patchApproval.uncertainty, EffectUncertainty.none);
      expect(patchApproval.targets, [
        'adele-environment:/${authority.environmentId.value}/$_sourcePath',
      ]);
      expect(jsonDecode(patchApproval.canonicalArgumentsJson), patchArguments);
      expect(
        patchInterruption.toolInvocationId,
        ToolInvocationId('${run.id.value}-tool-2'),
      );
      expect(patchInterruption.invocation.proposal.providerCallId, 'patch');
      final beforePatch = run.journal.records
          .map((record) => record.event)
          .toList();
      final readInvocation = beforePatch
          .whereType<ToolInvocationPrepared>()
          .first
          .invocation;
      expect(readInvocation.id, ToolInvocationId('${run.id.value}-tool-1'));
      expect(beforePatch.whereType<ToolInvocationPrepared>(), hasLength(2));
      expect(
        beforePatch.whereType<ToolInvocationPrepared>().last.invocation,
        same(patchInterruption.invocation),
      );
      expect(
        beforePatch.whereType<ToolExecutionStarted>().map(
          (event) => event.invocationId,
        ),
        [readInvocation.id],
      );
      expect(
        beforePatch.whereType<ToolExecutionCompleted>().map(
          (event) => event.invocationId,
        ),
        [readInvocation.id],
      );
      expect(beforePatch.whereType<RunInterruptionResolved>(), isEmpty);
      expect(await _sourceSnapshot(source), projectBefore);
      expect(await _sourceSnapshot(worktree), taskBefore);

      // B is one compact group above the retained individual card A. Narration
      // is its heading, not an activity row or an extra counted output.
      expect(inspection.cards, [cardA]);
      await tester.ensureVisible(narratedActivity);
      await tester.tap(narratedActivity);
      await tester.pumpAndSettle();
      final InspectionCard cardB = inspection.cards.first;
      final ActivityGroupInspectionTarget targetB =
          cardB.target as ActivityGroupInspectionTarget;
      expect(targetB.sessionId, session.id);
      expect(targetB.runId, run.id);
      expect(targetB.modelInvocationId, batch.invocationId);
      expect(inspection.cards, [cardB, cardA]);
      Finder cardHost(InspectionCard card) => find.byWidgetPredicate(
        (widget) =>
            widget is InspectionHost && identical(widget.card.id, card.id),
      );
      final Finder groupCard = cardHost(cardB);
      expect(inspectionHost, findsOneWidget);
      expect(
        tester.getTopLeft(inspectionHost).dx,
        greaterThan(tester.getBottomRight(sessionHost).dx),
      );
      expect(narratedActivity, findsOneWidget);
      expect(
        find.descendant(of: groupCard, matching: find.text(_narration)),
        findsOneWidget,
      );
      _expectVerticalOrder(tester, [groupCard, cardHost(cardA)]);
      expect(tester.state(initialNativeHost), same(initialNativeState));
      expect(
        find.descendant(
          of: groupCard,
          matching: find.byType(ToolActivityInspectionHost),
        ),
        findsNothing,
      );
      expect(
        find.descendant(
          of: groupCard,
          matching: find.byType(ModelNativeActivityInspectionHost),
        ),
        findsNothing,
      );

      Finder toolHost(ToolInvocationId id) => find.descendant(
        of: inspectionHost,
        matching: find.byWidgetPredicate(
          (widget) =>
              widget is ToolActivityInspectionHost &&
              widget.source.snapshot.id == id,
        ),
      );
      Finder nativeCompactHost(ModelNativePresentation presentation) =>
          find.descendant(
            of: groupCard,
            matching: find.byWidgetPredicate(
              (widget) =>
                  widget is ModelNativeActivityCompactHost &&
                  identical(widget.presentation, presentation),
            ),
          );
      Finder toolCompactHost(ToolInvocationId id) => find.descendant(
        of: groupCard,
        matching: find.byWidgetPredicate(
          (widget) =>
              widget is ToolActivityCompactHost &&
              widget.source.snapshot.id == id,
        ),
      );
      final Finder reasoningAHost = nativeCompactHost(nativeA.presentation!);
      final Finder reasoningBHost = nativeCompactHost(nativeB.presentation!);
      final reasoningAState = tester.state(reasoningAHost);
      final reasoningBState = tester.state(reasoningBHost);
      final Finder patchCompactHost = toolCompactHost(
        patchInterruption.toolInvocationId,
      );
      for (final (host, summary) in [
        (reasoningAHost, _reasoningA),
        (reasoningBHost, _reasoningB),
      ]) {
        expect(host, findsOneWidget);
        expect(
          find.descendant(of: host, matching: find.text('Reasoning: $summary')),
          findsOneWidget,
        );
      }
      expect(
        find.descendant(
          of: groupCard,
          matching: find.byType(ModelNativeActivityCompactHost),
        ),
        findsNWidgets(2),
      );
      expect(
        find.descendant(
          of: groupCard,
          matching: find.byType(ToolActivityCompactHost),
        ),
        findsOneWidget,
      );
      expect(find.byType(ModelNativeActivityInspectionHost), findsOneWidget);
      expect(find.byType(ToolActivityInspectionHost), findsNothing);
      final Finder unresolvedCommand = find.descendant(
        of: groupCard,
        matching: find.text('Proposal: run_command'),
      );
      expect(unresolvedCommand, findsOneWidget);
      final groupRows = tester.widgetList<TextButton>(
        find.descendant(of: groupCard, matching: find.byType(TextButton)),
      );
      expect(groupRows.map((row) => row.key), [
        for (final index in [0, 2, 3, 4])
          ValueKey((
            session.id,
            run.id,
            batch.invocationId,
            waitingEvidence.models.last.outputs[index].sequence,
          )),
      ]);
      expect(
        find.descendant(
          of: patchCompactHost,
          matching: find.text('Apply Patch: "$_sourcePath" / 1 edit'),
        ),
        findsOneWidget,
      );
      _expectVerticalOrder(tester, [
        reasoningAHost,
        patchCompactHost,
        reasoningBHost,
        unresolvedCommand,
      ]);
      expect(
        tester
            .widget<ToolActivityCompactHost>(patchCompactHost)
            .source
            .snapshot
            .proposalSequence,
        waitingEvidence.models.last.outputs[2].sequence,
      );
      expect(
        find.descendant(
          of: groupCard,
          matching: find.text('Waiting to be processed.'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: groupCard,
          matching: find.text('Relative path: "$_sourcePath"'),
        ),
        findsNothing,
      );

      // Clicking the prepared patch row opens C above B/A without replacing B.
      await tester.ensureVisible(patchCompactHost);
      await tester.tap(
        find.ancestor(of: patchCompactHost, matching: find.byType(TextButton)),
      );
      await tester.pumpAndSettle();
      final InspectionCard cardC = inspection.cards.first;
      final ModelOutputInspectionTarget targetC =
          cardC.target as ModelOutputInspectionTarget;
      expect(targetC.sessionId, session.id);
      expect(targetC.runId, run.id);
      expect(targetC.modelInvocationId, batch.invocationId);
      expect(
        targetC.outputSequence,
        waitingEvidence.models.last.outputs[2].sequence,
      );
      expect({cardA.id, cardB.id, cardC.id}, hasLength(3));
      expect(inspection.cards, [cardC, cardB, cardA]);
      _expectVerticalOrder(tester, [
        cardHost(cardC),
        groupCard,
        cardHost(cardA),
      ]);
      Finder toolPresentation(ToolInvocationId id) => find.descendant(
        of: toolHost(id),
        matching: find.byWidgetPredicate(
          (widget) => widget is $StatefulWidget$bridge,
        ),
      );
      final Finder patchPresentation = toolPresentation(
        patchInterruption.toolInvocationId,
      );
      final patchWidget = tester.widget<$StatefulWidget$bridge>(
        patchPresentation,
      );
      final patchState = tester.state(patchPresentation);
      final patchRuntime = patchWidget.$runtime;
      final patchSource = tester
          .widget<ToolActivityInspectionHost>(
            toolHost(patchInterruption.toolInvocationId),
          )
          .source;
      final ToolInvocationActivity waitingPatch = patchSource.snapshot;
      expect(waitingPatch.id, patchInterruption.toolInvocationId);
      expect(waitingPatch.toolId, patchInterruption.toolId);
      expect(waitingPatch.modelInvocationId, batch.invocationId);
      expect(
        waitingPatch.proposalSequence,
        waitingEvidence.models.last.outputs[2].sequence,
      );
      expect(
        waitingPatch.changes.last.kind,
        ToolActivityKind.approvalRequested,
      );
      expect(waitingPatch.outcome, isNull);
      expect(patchRuntime, isNot(same(chatRuntime)));
      for (final String label in [
        'Apply Patch',
        'Relative path: "$_sourcePath"',
        'Edit count: 1',
        'Status: Waiting for approval',
        'Tool delivery: Pending',
      ]) {
        expect(
          find.descendant(of: patchPresentation, matching: find.text(label)),
          findsOneWidget,
        );
      }
      expect(find.byType(ToolActivityInspectionHost), findsOneWidget);
      final Finder collapseGroup = find.descendant(
        of: groupCard,
        matching: find.byTooltip('Collapse Inspection'),
      );
      await tester.ensureVisible(collapseGroup);
      await tester.tap(collapseGroup);
      await tester.pumpAndSettle();
      expect(inspection.cards.map((card) => card.id), [
        cardC.id,
        cardB.id,
        cardA.id,
      ]);
      expect(inspection.cards[1].isCollapsed, isTrue);
      expect(reasoningAHost, findsNothing);
      expect(reasoningBHost, findsNothing);
      expect(patchCompactHost, findsNothing);
      expect(unresolvedCommand, findsNothing);
      expect(tester.state(patchPresentation), same(patchState));
      expect(tester.state(initialNativeHost), same(initialNativeState));
      _expectVerticalOrder(tester, [
        cardHost(cardC),
        groupCard,
        cardHost(cardA),
      ]);
      _expectNoPresentationSecrets(tester, controller);
      expect(
        find.descendant(of: inspectionHost, matching: find.text('Allow once')),
        findsNothing,
      );
      expect(
        find.descendant(
          of: inspectionHost,
          matching: find.text('Program: "git"'),
        ),
        findsNothing,
      );
      expect(controller.currentRun, same(execution));
      expect(controller.pendingApproval, same(patchApproval));
      expect(controller.snapshot.entries.last.content, _prompt);
      expect(run.journal.records.map((record) => record.event), beforePatch);
      expect(outbound, hasLength(3));
      expect(tester.takeException(), isNull);

      await tester.ensureVisible(allowOnce);
      await tester.tap(allowOnce);
      final Future<void>? patching = controller.activeRunFuture;
      expect(patching, isNotNull);
      expect(controller.isAdvancing, isTrue);
      await patching!;
      await tester.pumpAndSettle();
      expect(find.text('Tool: apply_patch'), findsNothing);
      expect(find.text('Tool: run_command'), findsOneWidget);
      expect(
        find.text('Effects may extend beyond the listed target.'),
        findsOneWidget,
      );
      expect(allowOnce, findsOneWidget);
      expect(tester.widget<TextField>(promptField).enabled, isFalse);
      expect(narratedActivity, findsOneWidget);

      expect(endpointFailures, isEmpty);
      expect(controller.failure, isNull);
      expect(controller.currentRun, same(execution));
      expect(controller.activeRunFuture, isNull);
      expect(controller.isAdvancing, isFalse);
      expect(controller.isRunning, isTrue);
      expect(run.state, RunState.waiting);
      expect(outbound, hasLength(3));
      expect(controller.snapshot.entries.last.content, _prompt);
      final PendingToolApproval commandApproval = controller.pendingApproval!;
      final ToolApprovalInterruption commandInterruption =
          run.interruptions.values.single as ToolApprovalInterruption;
      expect(commandApproval, isNot(same(patchApproval)));
      expect(commandApproval.toolAlias, 'run_command');
      expect(commandApproval.effects, {ToolEffect.processExecution});
      expect(commandApproval.uncertainty, EffectUncertainty.uncertain);
      expect(commandApproval.targets, [
        'adele-environment:/${authority.environmentId.value}/',
      ]);
      expect(
        jsonDecode(commandApproval.canonicalArgumentsJson),
        _commandArguments,
      );
      expect(
        commandInterruption.toolInvocationId,
        ToolInvocationId('${run.id.value}-tool-3'),
      );
      expect(commandInterruption.invocation.proposal.providerCallId, 'command');
      expect(commandInterruption.id, isNot(patchInterruption.id));
      final List<ToolInvocationActivity> batchTools = execution
          .activity
          .snapshot
          .tools
          .where((tool) => tool.modelInvocationId == batch.invocationId)
          .toList();
      expect(batchTools.map((tool) => tool.id), [
        patchInterruption.toolInvocationId,
        commandInterruption.toolInvocationId,
      ]);
      expect(
        batchTools.first.outcome!.disposition,
        ToolOutcomeDisposition.success,
      );
      expect(batchTools.last.outcome, isNull);
      expect(
        batchTools.last.changes.last.kind,
        ToolActivityKind.approvalRequested,
      );
      expect(inspection.cards.first, same(cardC));
      expect(inspection.cards[1].id, cardB.id);
      expect(inspection.cards[1].isCollapsed, isTrue);
      expect(inspection.cards.last, same(cardA));
      expect(
        tester.widget<$StatefulWidget$bridge>(patchPresentation),
        same(patchWidget),
      );
      expect(tester.state(patchPresentation), same(patchState));
      expect(
        tester.widget<$StatefulWidget$bridge>(patchPresentation).$runtime,
        same(patchRuntime),
      );
      expect(
        tester
            .widget<ToolActivityInspectionHost>(
              toolHost(patchInterruption.toolInvocationId),
            )
            .source,
        same(patchSource),
      );
      expect(patchSource.snapshot.id, waitingPatch.id);
      expect(patchSource.snapshot.toolId, waitingPatch.toolId);
      expect(
        patchSource.snapshot.proposalSequence,
        waitingPatch.proposalSequence,
      );
      expect(
        patchSource.snapshot.outcome!.disposition,
        ToolOutcomeDisposition.success,
      );
      final String inspectionRevision =
          patchSource.snapshot.outcome!.hostData['newRevision']! as String;
      expect(inspectionRevision, isNotEmpty);
      expect(inspectionRevision, isNot(observedRevision));
      expect(waitingPatch.outcome, isNull);
      for (final String label in [
        'Status: Succeeded',
        'Tool delivery: success',
        'New revision: $inspectionRevision',
      ]) {
        expect(
          find.descendant(of: patchPresentation, matching: find.text(label)),
          findsOneWidget,
        );
      }
      // The collapsed group keeps receiving evidence. Expanding upgrades only
      // its original command occurrence from placeholder to compact tool view.
      final Finder expandGroup = find.descendant(
        of: groupCard,
        matching: find.byTooltip('Expand Inspection'),
      );
      await tester.ensureVisible(expandGroup);
      await tester.tap(expandGroup);
      await tester.pumpAndSettle();
      expect(inspection.cards.map((card) => card.id), [
        cardC.id,
        cardB.id,
        cardA.id,
      ]);
      expect(inspection.cards[1].isCollapsed, isFalse);
      expect(unresolvedCommand, findsNothing);
      expect(find.byType(ToolActivityInspectionHost), findsOneWidget);
      expect(
        find.descendant(
          of: groupCard,
          matching: find.byType(ToolActivityCompactHost),
        ),
        findsNWidgets(2),
      );
      expect(
        find.descendant(
          of: groupCard,
          matching: find.byType(ToolActivityInspectionHost),
        ),
        findsNothing,
      );
      final Finder commandCompactHost = toolCompactHost(
        commandInterruption.toolInvocationId,
      );
      final Finder commandPresentation = find.descendant(
        of: commandCompactHost,
        matching: find.byWidgetPredicate(
          (widget) => widget is $StatefulWidget$bridge,
        ),
      );
      final commandWidget = tester.widget<$StatefulWidget$bridge>(
        commandPresentation,
      );
      final commandState = tester.state(commandPresentation);
      final commandRuntime = commandWidget.$runtime;
      final commandSource = tester
          .widget<ToolActivityCompactHost>(commandCompactHost)
          .source;
      expect(commandSource.snapshot.id, commandInterruption.toolInvocationId);
      expect(commandSource.snapshot.modelInvocationId, batch.invocationId);
      expect(
        commandSource.snapshot.proposalSequence,
        waitingEvidence.models.last.outputs[4].sequence,
      );
      expect(
        commandSource.snapshot.changes.last.kind,
        ToolActivityKind.approvalRequested,
      );
      expect(commandSource.snapshot.outcome, isNull);
      expect(commandRuntime, isNot(same(patchRuntime)));
      expect(commandRuntime, isNot(same(chatRuntime)));
      expect(tester.state(reasoningAHost), same(reasoningAState));
      expect(tester.state(reasoningBHost), same(reasoningBState));
      _expectVerticalOrder(tester, [
        reasoningAHost,
        patchCompactHost,
        reasoningBHost,
        commandCompactHost,
      ]);
      _expectNoPresentationSecrets(tester, controller);
      expect(
        find.descendant(
          of: commandPresentation,
          matching: find.text('Run Command: "git" ["diff", "--check"]'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(of: groupCard, matching: find.text('Program: "git"')),
        findsNothing,
      );
      expect(
        find.descendant(of: inspectionHost, matching: find.text('Allow once')),
        findsNothing,
      );
      expect(tester.takeException(), isNull);
      expect(
        controller.timeline.whereType<ChatActivitySummary>().last.invocationId,
        batch.invocationId,
      );
      final beforeCommand = run.journal.records
          .map((record) => record.event)
          .toList();
      expect(beforeCommand.whereType<ModelInvocationStarted>(), hasLength(2));
      expect(beforeCommand.whereType<ToolInvocationPrepared>(), hasLength(3));
      expect(
        beforeCommand.whereType<ToolInvocationPrepared>().last.invocation,
        same(commandInterruption.invocation),
      );
      expect(
        beforeCommand.whereType<ToolExecutionStarted>().map(
          (event) => event.invocationId,
        ),
        [readInvocation.id, patchInterruption.toolInvocationId],
      );
      expect(
        beforeCommand.whereType<ToolExecutionCompleted>().map(
          (event) => event.invocationId,
        ),
        [readInvocation.id, patchInterruption.toolInvocationId],
      );
      expect(
        beforeCommand.whereType<RunInterruptionResolved>().single.interruption,
        same(patchInterruption),
      );
      for (final (approval, interruption) in [
        (patchApproval, patchInterruption),
        (commandApproval, commandInterruption),
      ]) {
        expect(approval.toolId, interruption.toolId.value);
        expect(approval.hasUnsafeAuthorityText, isFalse);
        expect(approval.summary, interruption.effects.summary);
        expect(approval.summary, isNotEmpty);
        expect(approval.effects, interruption.effects.effects);
        expect(approval.uncertainty, interruption.effects.uncertainty);
        expect(
          approval.targets,
          interruption.effects.targets.map((target) => target.uri.toString()),
        );
        expect(
          jsonDecode(approval.canonicalArgumentsJson),
          interruption.canonicalArguments,
        );
      }
      final Map<String, Object?> taskAfterPatch = await _sourceSnapshot(
        worktree,
      );
      expect(taskAfterPatch['files'], {
        ...taskBefore['files']! as Map<String, Object?>,
        _sourcePath: utf8.encode(_patchedText),
      });
      for (final String key in ['head', 'branch', 'staged']) {
        expect(taskAfterPatch[key], taskBefore[key], reason: key);
      }
      expect(
        await _git(worktree, ['diff', '--name-only']),
        'AGENTS.md\n$_sourcePath\n',
      );
      expect(await _sourceSnapshot(source), projectBefore);

      await tester.ensureVisible(allowOnce);
      await tester.tap(allowOnce);
      final Future<void>? validating = controller.activeRunFuture;
      expect(validating, isNotNull);
      expect(controller.isAdvancing, isTrue);
      await continuationArrived.future;
      if (endpointFailures.isNotEmpty) {
        final (error, stack) = endpointFailures.first;
        Error.throwWithStackTrace(error, stack);
      }
      await tester.pumpAndSettle();
      expect(controller.isAdvancing, isTrue);
      expect(controller.activeRunFuture, same(validating));
      expect(narratedActivity, findsOneWidget);
      expect(fallbackActivity, findsOneWidget);
      expect(find.text(_answer), findsNothing);
      expect(controller.snapshot.entries, hasLength(3));
      expect(inspection.cards.map((card) => card.id), [
        cardC.id,
        cardB.id,
        cardA.id,
      ]);
      expect(inspectionHost, findsOneWidget);
      expect(patchedRevision, inspectionRevision);
      expect(
        commandSource.snapshot.outcome!.disposition,
        ToolOutcomeDisposition.success,
      );
      expect(commandSource.snapshot.outcome!.hostData['exitCode'], 0);
      expect(
        tester.widget<$StatefulWidget$bridge>(commandPresentation),
        same(commandWidget),
      );
      expect(tester.state(commandPresentation), same(commandState));
      expect(
        tester.widget<$StatefulWidget$bridge>(commandPresentation).$runtime,
        same(commandRuntime),
      );
      expect(
        find.descendant(
          of: commandPresentation,
          matching: find.text('Run Command: "git" ["diff", "--check"]'),
        ),
        findsOneWidget,
      );
      releaseFinal.complete();
      await validating!;
      await tester.pumpAndSettle();
      if (endpointFailures.isNotEmpty) {
        final (error, stack) = endpointFailures.first;
        Error.throwWithStackTrace(error, stack);
      }
      expect(
        find.descendant(of: sessionHost, matching: find.text(_answer)),
        findsOneWidget,
      );
      expect(
        find.descendant(of: sessionHost, matching: find.text(_prompt)),
        findsOneWidget,
      );
      expect(tester.widget<TextField>(promptField).controller!.text, isEmpty);
      expect(tester.widget<TextField>(promptField).enabled, isTrue);
      expect(allowOnce, findsNothing);
      expect(find.text('Approval required'), findsNothing);
      expect(tester.takeException(), isNull);
      expect(narratedActivity, findsOneWidget);
      expect(fallbackActivity, findsOneWidget);
      expect(
        tester.getTopLeft(find.text(_prompt)).dy,
        lessThan(tester.getTopLeft(fallbackActivity).dy),
      );
      expect(
        tester.getTopLeft(fallbackActivity).dy,
        lessThan(tester.getTopLeft(narratedActivity).dy),
      );
      expect(
        tester.getTopLeft(narratedActivity).dy,
        lessThan(tester.getTopLeft(find.text(_answer)).dy),
      );

      expect(controller.failure, isNull);
      expect(controller.currentRun, same(execution));
      expect(controller.activeRunFuture, isNull);
      expect(controller.pendingApproval, isNull);
      expect(controller.isAdvancing, isFalse);
      expect(controller.isRunning, isFalse);
      expect(run.state, RunState.completed);
      expect(run.failure, isNull);
      expect(run.interruptions, isEmpty);
      expect(outbound, hasLength(4));
      final RunActivitySnapshot activity = controller.activityForRun(run.id)!;
      expect(controller.activitySnapshots, [initialActivity, activity]);
      expect(activity.state, RunState.completed);
      expect(activity.models, hasLength(3));
      expect(activity.tools, hasLength(3));
      expect(
        activity.tools.where(
          (tool) => tool.modelInvocationId == batch.invocationId,
        ),
        hasLength(2),
      );
      expect(
        controller.timeline.whereType<ChatActivitySummary>(),
        hasLength(3),
      );
      expect(controller.timeline.map((entry) => entry.content), [
        _initialPrompt,
        _initialSummary,
        _initialAnswer,
        _prompt,
        'read_file',
        _narration,
        _answer,
      ]);
      final ChatSessionSnapshot snapshot = controller.snapshot;
      expect(snapshot.id, session.id);
      expect(snapshot.entries, [
        isA<ChatUserMessage>(),
        isA<ChatAssistantMessage>(),
        isA<ChatUserMessage>(),
        isA<ChatAssistantMessage>(),
      ]);
      expect(snapshot.entries.map((entry) => entry.content), [
        _initialPrompt,
        _initialAnswer,
        _prompt,
        _answer,
      ]);
      expect(
        runtime.chat.sessions.obtain(session.id).snapshot().entries,
        snapshot.entries,
      );
      final events = run.journal.records.map((record) => record.event).toList();
      expect(events.whereType<ModelInvocationStarted>(), hasLength(3));
      final settlements = events.whereType<ModelInvocationSettled>().toList();
      expect(settlements, hasLength(3));
      for (final settlement in settlements) {
        expect(settlement.settlement, ModelSettlement.completed);
        expect(settlement.metadata.effectiveModel, 'gpt-6-astra');
      }
      final prepared = events.whereType<ToolInvocationPrepared>().toList();
      expect(
        prepared.map((event) => event.invocation.tool.modelDefinition.alias),
        ['read_file', 'apply_patch', 'run_command'],
      );
      expect(
        prepared.first.invocation.canonicalArguments['relativePath'],
        observedPath,
      );
      expect(prepared[1].invocation.canonicalArguments, patchArguments);
      expect(prepared.last.invocation.canonicalArguments, _commandArguments);
      final proposals = events
          .whereType<ModelOutputObserved>()
          .where((event) => event.item is ModelToolProposalOutput)
          .toList();
      expect(proposals, hasLength(3));
      expect(proposals[1].invocationId, proposals[2].invocationId);
      expect(proposals[1].invocationId, settlements[1].invocationId);
      expect(
        proposals.map(
          (event) =>
              (event.item as ModelToolProposalOutput).proposal.providerCallId,
        ),
        ['read', 'patch', 'command'],
      );
      final policies = events.whereType<ToolPolicyEvaluated>().toList();
      expect(
        policies.map((event) => event.invocationId),
        prepared.map((event) => event.invocation.id),
      );
      expect(policies.map((event) => event.decision), [
        ToolPolicyDecision.allow,
        ToolPolicyDecision.ask,
        ToolPolicyDecision.ask,
      ]);
      final completed = events.whereType<ToolExecutionCompleted>().toList();
      expect(
        completed.map((event) => event.invocationId),
        prepared.map((event) => event.invocation.id),
      );
      expect(
        events.whereType<ToolExecutionStarted>().map(
          (event) => event.invocationId,
        ),
        prepared.map((event) => event.invocation.id),
      );
      for (final completion in completed) {
        expect(completion.outcome.disposition, ToolOutcomeDisposition.success);
        expect(
          completion.outcome.hostData['environmentId'],
          authority.environmentId.value,
        );
      }
      expect(completed.first.outcome.hostData['relativePath'], _sourcePath);
      expect(completed.first.outcome.hostData['text'], _taskText);
      expect(completed.first.outcome.hostData['revision'], observedRevision);
      expect(completed[1].outcome.hostData, {
        'environmentId': authority.environmentId.value,
        'relativePath': _sourcePath,
        'editCount': 1,
        'newRevision': patchedRevision,
      });
      expect(
        completed[1].outcome.effectCertainty,
        EffectCertainty.knownOccurred,
      );
      final ToolOutcome commandOutcome = completed.last.outcome;
      expect(commandOutcome.effectCertainty, EffectCertainty.knownOccurred);
      expect(commandOutcome.hostData, {
        'environmentId': authority.environmentId.value,
        ..._commandArguments,
        'termination': 'exited',
        'exitCode': 0,
        'stdout': '',
        'stderr': '',
        'stdoutTruncated': false,
        'stderrTruncated': false,
      });
      expect(
        commandOutcome.modelContent,
        _toolOutput(outbound.last, 'command'),
      );
      expect(
        completed[1].outcome.modelContent,
        _toolOutput(outbound.last, 'patch'),
      );
      expect(events.whereType<ToolInvocationCompleted>(), isEmpty);
      expect(
        events.whereType<RunInterrupted>().map((event) => event.interruption),
        [patchInterruption, commandInterruption],
      );
      final resolutions = events.whereType<RunInterruptionResolved>().toList();
      expect(resolutions.map((event) => event.interruption), [
        patchInterruption,
        commandInterruption,
      ]);
      for (final resolved in resolutions) {
        final ToolApprovalInterruption interruption =
            resolved.interruption as ToolApprovalInterruption;
        final ToolApprovalResolution resolution =
            resolved.resolution as ToolApprovalResolution;
        expect(resolution.interruptionId, interruption.id);
        expect(resolution.toolInvocationId, interruption.toolInvocationId);
        expect(resolution.approved, isTrue);
        final int resolvedIndex = events.indexOf(resolved);
        final int startedIndex = events.indexWhere(
          (event) =>
              event is ToolExecutionStarted &&
              event.invocationId == interruption.toolInvocationId,
        );
        final int completedIndex = events.indexWhere(
          (event) =>
              event is ToolExecutionCompleted &&
              event.invocationId == interruption.toolInvocationId,
        );
        expect(resolvedIndex, lessThan(startedIndex));
        expect(startedIndex, lessThan(completedIndex));
        expect(
          completedIndex,
          lessThan(
            events.lastIndexWhere((event) => event is ModelInvocationStarted),
          ),
        );
      }
      final EnvironmentTextFile resultingFile = await runtime
          .lifecycle
          .environmentRuntime
          .currentMaterialization(authority.environmentId)!
          .provider
          .readFile(authority.environmentId, _sourcePath);
      expect(resultingFile.text, _patchedText);
      expect(resultingFile.revision, patchedRevision);

      await tester.ensureVisible(
        find.descendant(of: sessionHost, matching: find.text(_answer)),
      );
      expect(inspection.cards.first, same(cardC));
      expect(inspection.cards.map((card) => card.id), [
        cardC.id,
        cardB.id,
        cardA.id,
      ]);
      expect(inspectionHost, findsOneWidget);
      expect(
        tester.widget<InspectionHost>(cardHost(cardC)).activity,
        same(activity),
      );
      expect(
        tester.widget<$StatefulWidget$bridge>(patchPresentation),
        same(patchWidget),
      );
      expect(tester.state(patchPresentation), same(patchState));
      expect(
        tester.widget<$StatefulWidget$bridge>(patchPresentation).$runtime,
        same(patchRuntime),
      );
      expect(
        tester
            .widget<ToolActivityInspectionHost>(
              toolHost(patchInterruption.toolInvocationId),
            )
            .source,
        same(patchSource),
      );
      expect(
        tester.widget<$StatefulWidget$bridge>(commandPresentation),
        same(commandWidget),
      );
      expect(tester.state(commandPresentation), same(commandState));
      expect(
        tester.widget<$StatefulWidget$bridge>(commandPresentation).$runtime,
        same(commandRuntime),
      );
      expect(
        tester.widget<ToolActivityCompactHost>(commandCompactHost).source,
        same(commandSource),
      );
      expect(
        patchSource.snapshot.outcome!.hostData['newRevision'],
        patchedRevision,
      );
      expect(commandSource.snapshot.outcome!.hostData, commandOutcome.hostData);
      _expectVerticalOrder(tester, [
        reasoningAHost,
        patchCompactHost,
        reasoningBHost,
        commandCompactHost,
      ]);
      _expectNoPresentationSecrets(tester, controller);
      expect(
        tester.widget<$StatefulWidget$bridge>(chatPresentation),
        same(chatWidget),
      );
      expect(tester.state(chatPresentation), same(chatState));
      expect(
        tester.widget<$StatefulWidget$bridge>(chatPresentation).$runtime,
        same(chatRuntime),
      );

      // Dismissing C leaves B and A, including their live presentation resources.
      final Finder closeInspection = find.descendant(
        of: cardHost(cardC),
        matching: find.byTooltip('Dismiss Inspection'),
      );
      await tester.ensureVisible(closeInspection);
      await tester.tap(closeInspection);
      await tester.pumpAndSettle();
      expect(inspection.cards.map((card) => card.id), [cardB.id, cardA.id]);
      expect(cardHost(cardC), findsNothing);
      expect(inspectionHost, findsOneWidget);
      expect(find.byType(ToolActivityInspectionHost), findsNothing);
      expect(find.byType(ModelNativeActivityInspectionHost), findsOneWidget);
      expect(patchState.mounted, isFalse);
      expect(tester.state(commandPresentation), same(commandState));
      expect(tester.state(reasoningAHost), same(reasoningAState));
      expect(tester.state(reasoningBHost), same(reasoningBState));
      expect(tester.state(initialNativeHost), same(initialNativeState));
      _expectVerticalOrder(tester, [groupCard, cardHost(cardA)]);
      expect(tester.state(chatPresentation), same(chatState));
      expect(
        tester.widget<$StatefulWidget$bridge>(chatPresentation).$runtime,
        same(chatRuntime),
      );
      expect(controller.currentRun, same(execution));
      expect(run.state, RunState.completed);
      expect(run.journal.records.map((record) => record.event), events);
      expect(controller.snapshot, same(snapshot));
      expect(controller.activityForRun(run.id), same(activity));
      expect(
        controller.activitySummary(run.id, batch.invocationId)!.content,
        _narration,
      );
      expect(controller.activitySnapshots, [initialActivity, activity]);
      expect(
        runtime.chat.sessions.obtain(session.id).snapshot().entries,
        snapshot.entries,
      );
      expect(narratedActivity, findsOneWidget);
      expect(fallbackActivity, findsOneWidget);
      expect(
        find.descendant(of: sessionHost, matching: find.text(_answer)),
        findsOneWidget,
      );
      expect(controller.pendingApproval, isNull);
      expect(controller.activeRunFuture, isNull);
      expect(outbound, hasLength(4));
      expect(tester.takeException(), isNull);

      // The same installed Command artifact supplies a separate rich role, not
      // merely its compact row in the retained group.
      await tester.ensureVisible(commandCompactHost);
      await tester.tap(
        find.ancestor(
          of: commandCompactHost,
          matching: find.byType(TextButton),
        ),
      );
      await tester.pumpAndSettle();
      final InspectionCard commandCard = inspection.cards.first;
      expect(inspection.cards.map((card) => card.id), [
        commandCard.id,
        cardB.id,
        cardA.id,
      ]);
      final commandTarget = commandCard.target as ModelOutputInspectionTarget;
      expect(commandTarget.runId, run.id);
      expect(commandTarget.modelInvocationId, batch.invocationId);
      expect(
        commandTarget.outputSequence,
        commandSource.snapshot.proposalSequence,
      );
      final Finder commandInspection = toolPresentation(
        commandInterruption.toolInvocationId,
      );
      expect(commandInspection, findsOneWidget);
      expect(
        tester.widget<$StatefulWidget$bridge>(commandInspection).$runtime,
        isNot(same(commandRuntime)),
      );
      for (final label in [
        'Run Command',
        'Program: "git"',
        '[0]: "diff"',
        '[1]: "--check"',
        'Status: Completed',
        'Tool delivery: success',
        'Process termination: exited',
        'Exit code: 0',
      ]) {
        expect(
          find.descendant(of: commandInspection, matching: find.text(label)),
          findsOneWidget,
        );
      }
      expect(
        tester
            .widget<ToolActivityInspectionHost>(
              toolHost(commandInterruption.toolInvocationId),
            )
            .source
            .snapshot
            .outcome!
            .hostData,
        commandOutcome.hostData,
      );
      _expectNoPresentationSecrets(tester, controller);
      final Finder dismissCommand = find.descendant(
        of: cardHost(commandCard),
        matching: find.byTooltip('Dismiss Inspection'),
      );
      await tester.ensureVisible(dismissCommand);
      await tester.tap(dismissCommand);
      await tester.pumpAndSettle();
      expect(inspection.cards.map((card) => card.id), [cardB.id, cardA.id]);
      expect(tester.state(commandPresentation), same(commandState));

      expect(initialActivityLink, findsOneWidget);
      expect(controller.activityForRun(initialRun.id), same(initialActivity));
      expect(
        initialRun.journal.records.map((record) => record.event),
        initialEvents,
      );
      expect(run.journal.records.map((record) => record.event), events);
      expect(outbound, hasLength(4));
      expect(await _sourceSnapshot(source), projectBefore);
      expect(await _sourceSnapshot(worktree), taskAfterPatch);
      expect(tester.state(chatPresentation), same(chatState));
      _expectNoPresentationSecrets(tester, controller);
      expect(tester.takeException(), isNull);

      // Frontend absence does not remove backend-supplied safe activity or raw
      // replay. Retire through the generic installed generation, without rescans.
      final nativeBinding = nativeResolver.resolve(
        openAiReasoningSummaryPresentationKind,
      );
      final compactBinding = ModelNativeActivityCompactPresentationResolver(
        runtime.extensions,
      ).resolve(openAiReasoningSummaryPresentationKind);
      await openAiFrontend.retire(
        modelNativeActivityPresentationContributions,
        nativeBinding.id,
      );
      await tester.pumpAndSettle();
      expect(nativeBinding.validate, throwsA(isA<StaleExtensionBinding>()));
      expect(compactBinding.validate, returnsNormally);
      expect(
        () => nativeResolver.resolve(openAiReasoningSummaryPresentationKind),
        throwsA(isA<ModelNativeActivityPresentationUnavailable>()),
      );
      expect(
        find.text('Model native activity rich inspection is unavailable.'),
        findsOneWidget,
      );
      expect(initialActivityLink, findsOneWidget);
      await openAiFrontend.close();
      await tester.pumpAndSettle();
      expect(compactBinding.validate, throwsA(isA<StaleExtensionBinding>()));
      expect(initialActivityLink, findsOneWidget);
      expect(narratedActivity, findsOneWidget);
      expect(controller.activitySnapshots, [initialActivity, activity]);
      expect(controller.snapshot, same(snapshot));
      expect(run.journal.records.map((record) => record.event), events);
      expect(
        initialRun.journal.records.map((record) => record.event),
        initialEvents,
      );
      expect(
        runtime.registry.providersFor(modelProviderCapability),
        hasLength(1),
      );
      expect(runtime.plugins.catalog, same(catalog));
      expect(outbound, hasLength(4));
      _expectNoPresentationSecrets(tester, controller);
      expect(tester.takeException(), isNull);

      // Stop only the installed AGENTS generation while the host remains live.
      // A retained binding must fail rather than use an in-process fallback.
      await agentsMdBackend.connection!.close();
      await agentsMdBackend.connection!.terminated;
      expect(agentsMdBackend.state, InstalledBackendState.terminated);
      expect(agentsMdBinding.validate, throwsA(isA<StaleExtensionBinding>()));
      expect(
        () => agentsMdBinding.value,
        throwsA(isA<StaleExtensionBinding>()),
      );
      expect(runtime.extensions.discover(inferenceContextSources), isEmpty);
      expect(runtime.plugins.host!.isClosed, isFalse);
      expect(runtime.plugins.state, ApplicationPluginState.ready);
      expect(
        runtime.plugins.backends
            .where((entry) => entry != agentsMdBackend)
            .map((entry) => entry.state),
        everyElement(InstalledBackendState.active),
      );

      await controller.close();
      updatePresentation = null;
      await tester.pumpWidget(const SizedBox.shrink());
      await frontends.close();
      await runtime.close();
      expect(runtime.plugins.state, ApplicationPluginState.closed);
      expect(agentsMdBinding.validate, throwsA(isA<StaleExtensionBinding>()));
      expect(runtime.extensions.discover(inferenceContextSources), isEmpty);
      expect(runtime.registry.providersFor(modelProviderCapability), isEmpty);
      expect(
        runtime.registry.providersFor(environmentProviderCapability),
        isEmpty,
      );
      expect(await _sourceSnapshot(source), projectBefore);
      expect(await _sourceSnapshot(worktree), taskAfterPatch);
      expect(await credentials.readAsString(), credentialText);
      expect(
        runtime.store.requireSessionAuthority(session.id),
        same(authority),
      );
    }),
    timeout: const Timeout(Duration(seconds: 90)),
  );

  testWidgets(
    'F3a normal AdeleApplication opens a real Task with installed AGENTS, Chat and OpenAI EVCs',
    (tester) => tester.runAsync(() async {
      await tester.binding.setSurfaceSize(const Size(1400, 1100));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final Directory container = await Directory.systemTemp.createTemp(
        'adele-f2-product-',
      );
      addTearDown(() => container.delete(recursive: true));
      final Directory source = Directory('${container.path}/project');
      await Directory('${source.path}/lib').create(recursive: true);
      await File('${source.path}/$_sourcePath').writeAsString(_taskText);
      await File('${source.path}/AGENTS.md').writeAsString(_agentsText);
      await _git(source, ['init', '--initial-branch=main']);
      await _git(source, ['add', '.']);
      await _git(source, ['commit', '-m', 'Fixture baseline']);
      final File credentials = File('${container.path}/credentials.json');
      await credentials.writeAsString(
        jsonEncode({
          'version': 1,
          'instances': {
            'fixture': {
              'revision': 1,
              'credential': {
                'idToken': _idToken('f2-product-account'),
                'accessToken': 'f2-fake-access-token',
                'refreshToken': 'f2-fake-refresh-never-used',
                'accountId': 'f2-product-account',
                'fedRamp': false,
              },
            },
          },
        }),
      );
      const prompt = 'Read the Task source without changing it.';
      const summary = 'Checking the observed Task source.';
      const answer = 'Read lib/task_answer.dart from the Task Environment.';
      final outbound = <Map<String, Object?>>[];
      final endpointFailures = <(Object, StackTrace)>[];
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final subscription = server.listen((request) async {
        try {
          expect(request.method, 'POST');
          expect(request.uri.path, '/backend-api/codex/responses');
          expect(
            request.headers.value(HttpHeaders.authorizationHeader),
            'Bearer f2-fake-access-token',
          );
          final body =
              jsonDecode(await utf8.decoder.bind(request).join())
                  as Map<String, Object?>;
          outbound.add(body);
          expect(body['model'], 'gpt-6-astra');
          expect(body['instructions'], contains(_agentsText));
          request.response.headers.contentType = ContentType(
            'text',
            'event-stream',
            charset: 'utf-8',
          );
          switch (outbound.length) {
            case 1:
              _output(
                request.response,
                _call('product-read', 'read_file', {
                  'relativePath': _sourcePath,
                }),
              );
            case 2:
              expect(_toolOutput(body, 'product-read'), contains(_taskText));
              expect(_revision(_toolOutput(body, 'product-read')), isNotEmpty);
              _output(
                request.response,
                _reasoning('product-reasoning', summary, _encryptedInitial),
              );
              _output(request.response, _message('product-final', answer));
            default:
              fail(
                'Unexpected product Responses invocation ${outbound.length}.',
              );
          }
          _sse(request.response, {
            'type': 'response.completed',
            'response': {
              'id': 'product-${outbound.length}',
              'model': 'gpt-6-astra',
            },
          });
        } on Object catch (error, stack) {
          endpointFailures.add((error, stack));
        } finally {
          await request.response.close();
        }
      });
      addTearDown(() async {
        await subscription.cancel();
        await server.close(force: true);
      });
      final runtime = AdeleRuntime(
        ids: MonotonicProductIdSource(seed: 'f2-product'),
      );
      addTearDown(runtime.close);
      expect(runtime.extensions.discover(inferenceContextSources), isEmpty);
      final selector = runtime.extensions.register(
        point: projectSelectorContributions,
        id: ExtensionId('dev.adele.test.f2-project-selector'),
        value: ProjectSelectorContribution(
          displayName: 'Open F2 Project',
          selectProject: () async => source.uri,
        ),
      );
      addTearDown(selector.close);
      late Future<void> starting;
      await tester.pumpWidget(
        AdeleApplication(
          createRuntime: () => runtime,
          readChatGptConfiguration: () =>
              const StockChatGptConfiguration(model: 'gpt-6-astra'),
          runIds: MonotonicRunIdSource(seed: 'f2-product'),
          bootstrapPlugins: (plugins) => starting = plugins.start(
            installationRoot: installationRoot.path,
            dartaotruntimeExecutable: dartaotruntime,
            hostArtifactPath: hostArtifact.path,
            startupArguments: {
              _openAiPluginId: [
                '--chatgpt-only',
                jsonEncode({
                  'credentialFile': credentials.path,
                  'clientId': 'fixture',
                  'instanceId': 'fixture',
                  'issuer': 'http://${server.address.address}:${server.port}',
                  'endpoint':
                      'http://${server.address.address}:${server.port}/backend-api/codex/responses',
                }),
              ],
            },
          ),
        ),
      );
      addTearDown(() async {
        await tester.binding.handleRequestAppExit();
        await tester.pumpWidget(const SizedBox.shrink());
      });
      await starting;
      bool allFrontendsRegistered() =>
          runtime.extensions
                  .discover(sessionPresentationContributions)
                  .length ==
              1 &&
          runtime.extensions
                  .discover(toolActivityInspectionContributions)
                  .length ==
              2 &&
          runtime.extensions
                  .discover(toolActivityCompactPresentationContributions)
                  .length ==
              2 &&
          runtime.extensions
                  .discover(modelNativeActivityPresentationContributions)
                  .length ==
              1 &&
          runtime.extensions
                  .discover(modelNativeActivityCompactPresentationContributions)
                  .length ==
              1;
      if (!allFrontendsRegistered()) {
        await runtime.extensions.changes
            .firstWhere((_) => allFrontendsRegistered())
            .timeout(const Duration(seconds: 10));
      }
      await tester.pumpAndSettle();
      final catalog = runtime.plugins.catalog!;
      expect(catalog.issues, isEmpty);
      expect(catalog.installations, hasLength(7));
      expect(runtime.plugins.backends, hasLength(5));
      expect(
        catalog.installations.where((entry) => entry.frontend != null),
        hasLength(4),
      );
      for (final backend in runtime.plugins.backends) {
        expect(
          backend.failure,
          isNull,
          reason: 'Backend ${backend.installation.metadata.id} must start.',
        );
        expect(backend.state, InstalledBackendState.active);
      }
      final agentsMdBinding = runtime.extensions
          .discover(inferenceContextSources)
          .single;
      expect(agentsMdBinding.id.value, '$_agentsMdPluginId.instructions');
      expect(agentsMdBinding.validate, returnsNormally);
      expect(outbound, isEmpty);
      expect(find.text('No Project is open'), findsOneWidget);
      await tester.tap(find.text('Open F2 Project'));
      await tester.pumpAndSettle();
      AdeleShell shell() => tester.widget<AdeleShell>(find.byType(AdeleShell));
      final project = shell().project!;
      expect(runtime.store.project(project.id), same(project));
      expect(runtime.store.tasksFor(project.id), isEmpty);
      await tester.tap(find.text('New Task'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byType(TextField),
        'Read the installed product Task',
      );
      await tester.tap(find.text('Create Task'));
      final deadline = DateTime.now().add(const Duration(seconds: 10));
      while (shell().task == null && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
        await tester.pump();
      }
      await tester.pumpAndSettle();
      expect(shell().task, isNotNull);
      expect(shell().environmentReady, isTrue);
      final environment = shell().environment!;
      expect(
        runtime.store.primaryEnvironmentFor(shell().task!.id),
        same(environment),
      );
      expect(outbound, isEmpty);
      await tester.tap(find.text('New Session'));
      await tester.pumpAndSettle();
      final sessionHost = find.byType(SessionPresentationHost);
      final session = tester
          .widget<SessionPresentationHost>(sessionHost)
          .session;
      expect(runtime.store.session(session.id), same(session));
      expect(session.taskId, shell().task!.id);
      final controller = tester
          .widget<StockChatExecutionStatus>(
            find.byType(StockChatExecutionStatus),
          )
          .controller;
      final promptField = find.descendant(
        of: sessionHost,
        matching: find.byType(TextField),
      );
      expect(promptField, findsOneWidget);
      expect(
        find.descendant(
          of: sessionHost,
          matching: find.byWidgetPredicate(
            (widget) => widget is $StatefulWidget$bridge,
          ),
        ),
        findsOneWidget,
      );
      await tester.enterText(promptField, prompt);
      await tester.ensureVisible(find.text('Send'));
      await tester.tap(find.text('Send'));
      final running = controller.activeRunFuture;
      expect(running, isNotNull);
      await running!;
      await tester.pumpAndSettle();
      if (endpointFailures.isNotEmpty) {
        final (error, stack) = endpointFailures.first;
        Error.throwWithStackTrace(error, stack);
      }
      expect(outbound, hasLength(2));
      expect(controller.currentRun!.run.state, RunState.completed);
      expect(controller.failure, isNull);
      expect(controller.pendingApproval, isNull);
      expect(controller.snapshot.entries.map((entry) => entry.content), [
        prompt,
        answer,
      ]);
      final activity = controller.activitySnapshots.single;
      expect(activity.tools.single.outcome!.hostData['text'], _taskText);
      expect(
        activity.tools.single.outcome!.hostData['environmentId'],
        environment.id.value,
      );
      final native = activity.models.last.outputs
          .map((output) => output.item)
          .whereType<ModelNativeOutput>()
          .single;
      _expectSafePresentation(
        native,
        id: 'product-reasoning',
        summary: summary,
        encrypted: _encryptedInitial,
      );
      final summaryLink = find.descendant(
        of: sessionHost,
        matching: find.text('Reasoning: $summary'),
      );
      await tester.ensureVisible(summaryLink);
      await tester.tap(
        find.ancestor(of: summaryLink, matching: find.byType(TextButton)),
      );
      await tester.pumpAndSettle();
      expect(find.byType(InspectionHost), findsOneWidget);
      expect(find.text('Reasoning summary'), findsOneWidget);
      expect(
        find.descendant(
          of: find.byType(ModelNativeActivityInspectionHost),
          matching: find.text(summary),
        ),
        findsOneWidget,
      );
      _expectNoPresentationSecrets(tester, controller);
      expect(runtime.plugins.catalog, same(catalog));
      expect(
        await File('${source.path}/$_sourcePath').readAsString(),
        _taskText,
      );
      expect(await _git(source, ['status', '--porcelain=v1']), isEmpty);
      final sessionBinding = runtime.extensions
          .discover(sessionPresentationContributions)
          .single;
      expect(await tester.binding.handleRequestAppExit(), AppExitResponse.exit);
      expect(runtime.plugins.state, ApplicationPluginState.closed);
      expect(sessionBinding.validate, throwsA(isA<StaleExtensionBinding>()));
      expect(agentsMdBinding.validate, throwsA(isA<StaleExtensionBinding>()));
      expect(runtime.extensions.discover(inferenceContextSources), isEmpty);
      expect(
        runtime.extensions.discover(toolActivityInspectionContributions),
        isEmpty,
      );
      expect(
        runtime.extensions.discover(
          toolActivityCompactPresentationContributions,
        ),
        isEmpty,
      );
      expect(
        runtime.extensions.discover(
          modelNativeActivityPresentationContributions,
        ),
        isEmpty,
      );
      expect(
        runtime.extensions.discover(
          modelNativeActivityCompactPresentationContributions,
        ),
        isEmpty,
      );
      expect(runtime.store.session(session.id), same(session));
      expect(outbound, hasLength(2));
      await tester.pumpWidget(const SizedBox.shrink());
      expect(tester.takeException(), isNull);
    }),
    timeout: const Timeout(Duration(seconds: 45)),
  );

  for (final failure in ['frontend load', 'frontend bytecode', 'backend']) {
    testWidgets(
      'F2 real OpenAI installation isolates $failure failure from its sibling',
      (tester) => tester.runAsync(() async {
        final Directory container = await Directory.systemTemp.createTemp(
          'adele-component-failure-',
        );
        addTearDown(() => container.delete(recursive: true));
        final Directory root = await Directory(
          '${container.path}/installed',
        ).create();
        for (final id in [_gitPluginId, _openAiPluginId]) {
          final Directory installed = await Directory(
            '${root.path}/$id',
          ).create();
          await for (final file in Directory(
            '${installationRoot.path}/$id',
          ).list()) {
            await (file as File).copy(
              '${installed.path}/${file.uri.pathSegments.last}',
            );
          }
        }
        int requests = 0;
        final HttpServer server = await HttpServer.bind(
          InternetAddress.loopbackIPv4,
          0,
        );
        server.listen((request) async {
          requests++;
          request.response.statusCode = HttpStatus.internalServerError;
          await request.response.close();
        });
        addTearDown(() async {
          await server.close(force: true);
          expect(
            requests,
            0,
            reason: 'Activation must not make model or OAuth calls.',
          );
        });
        final File credentials = File(
          '${container.path}/never-created-credentials.json',
        );
        final AdeleRuntime runtime = AdeleRuntime();
        addTearDown(runtime.close);
        expect(runtime.extensions.discover(inferenceContextSources), isEmpty);
        await runtime.plugins.start(
          installationRoot: root.path,
          dartaotruntimeExecutable: dartaotruntime,
          hostArtifactPath: hostArtifact.path,
          startupArguments: {
            _openAiPluginId: [
              '--chatgpt-only',
              jsonEncode({
                'credentialFile': credentials.path,
                'clientId': 'fixture',
                'endpoint': failure == 'backend'
                    ? 'relative'
                    : 'http://${server.address.address}:${server.port}/responses',
              }),
            ],
          },
        );
        final catalog = runtime.plugins.catalog!;
        expect(catalog.issues, isEmpty);
        // This root omits AGENTS, Search and Filesystem; no static substitutes.
        expect(runtime.extensions.discover(inferenceContextSources), isEmpty);
        expect(
          runtime.extensions
              .discover(modelToolContributions)
              .map((binding) => binding.id.value),
          unorderedEquals(['$_commandPluginId.model-tools']),
        );
        final backend = runtime.plugins.backends.singleWhere(
          (entry) => entry.installation.metadata.id.value == _openAiPluginId,
        );
        expect(
          backend.state,
          failure == 'backend'
              ? InstalledBackendState.failed
              : InstalledBackendState.active,
        );
        expect(backend.failure, failure == 'backend' ? isNotNull : isNull);
        final providers = runtime.registry
            .providersFor(modelProviderCapability)
            .toList();
        expect(providers, hasLength(failure == 'backend' ? 0 : 1));
        expect(
          runtime.registry.providersFor(environmentProviderCapability),
          hasLength(1),
        );

        final File frontendArtifact = File(
          '${root.path}/$_openAiPluginId/frontend.evc',
        );
        if (failure == 'frontend load') {
          await frontendArtifact.delete();
        } else if (failure == 'frontend bytecode') {
          await frontendArtifact.writeAsBytes([1, 2, 3]);
        }
        // A fresh discovery would exclude this installation. Frontend startup
        // must consume the backend's retained catalog, not reread its manifest.
        await File(
          '${root.path}/$_openAiPluginId/adele_plugin.installation.json',
        ).writeAsString('{');
        final frontends = ApplicationFrontendBootstrap(
          extensions: runtime.extensions,
        );
        addTearDown(frontends.close);
        await frontends.start(catalog);
        expect(frontends.catalog, same(catalog));
        expect(frontends.state, ApplicationFrontendState.ready);
        final frontend = frontends.generations.single;
        expect(frontend.installation, same(backend.installation));
        expect(
          frontend.state,
          failure == 'frontend load'
              ? InstalledFrontendState.failed
              : InstalledFrontendState.active,
        );
        expect(
          frontend.failure,
          failure == 'frontend load' ? isNotNull : isNull,
        );
        final presentation = ModelNativePresentation(
          kind: openAiReasoningSummaryPresentationKind,
          compactText: _initialSummary,
          data: {
            'summaryParts': [_initialSummary],
            'truncated': false,
          },
        );
        await tester.pumpWidget(
          MaterialApp(
            home: Column(
              children: [
                ModelNativeActivityCompactHost(
                  extensions: runtime.extensions,
                  presentation: presentation,
                  fallback: Text(presentation.compactText),
                ),
                ModelNativeActivityInspectionHost(
                  extensions: runtime.extensions,
                  presentation: presentation,
                ),
              ],
            ),
          ),
        );
        await tester.pumpAndSettle();
        if (failure == 'backend') {
          expect(find.text('Reasoning summary'), findsOneWidget);
          expect(find.text(_initialSummary), findsOneWidget);
          expect(find.text('Reasoning: $_initialSummary'), findsOneWidget);
          expect(find.text('Frontend unavailable.'), findsNothing);
        } else {
          expect(find.text('Reasoning summary'), findsNothing);
          expect(find.textContaining(_initialSummary), findsOneWidget);
          expect(
            find.text(
              failure == 'frontend load'
                  ? 'Model native activity rich inspection is unavailable.'
                  : 'Frontend unavailable.',
            ),
            findsOneWidget,
          );
        }
        expect(tester.takeException(), isNull);
        expect(runtime.plugins.state, ApplicationPluginState.ready);
        expect(runtime.plugins.failure, isNull);
        expect(runtime.plugins.catalog, same(catalog));
        expect(
          runtime.registry.providersFor(modelProviderCapability),
          providers,
        );
        expect(
          runtime.registry.providersFor(environmentProviderCapability),
          hasLength(1),
        );
        expect(credentials.existsSync(), isFalse);
        await tester.pumpWidget(const SizedBox.shrink());
        await frontends.close();
        expect(
          runtime.registry.providersFor(modelProviderCapability),
          providers,
        );
        await runtime.close();
      }),
      timeout: const Timeout(Duration(seconds: 30)),
    );
  }
}

void _expectSafePresentation(
  ModelNativeOutput output, {
  required String id,
  required String summary,
  required String encrypted,
}) {
  expect(output.providerItemId, id);
  expect(output.providerNativeMetadata.kind, openAiResponsesItemKind);
  expect(output.providerNativeMetadata.compatibility, {
    'version': openAiResponsesItemVersion,
  });
  expect(output.providerNativeMetadata.data, {
    'item': _reasoning(id, summary, encrypted),
  });
  final ModelNativePresentation? presentation = output.presentation;
  expect(presentation, isNotNull);
  expect(presentation!.kind, openAiReasoningSummaryPresentationKind);
  expect(presentation.compactText, summary);
  // Exact recursive allowlist at the provider-to-host boundary, not merely that
  // an encrypted sentinel happens not to be rendered by this particular widget.
  expect(presentation.data, {
    'summaryParts': [summary],
    'truncated': false,
  });
  final String encoded = jsonEncode({
    'kind': presentation.kind,
    'compactText': presentation.compactText,
    'data': presentation.data,
  });
  for (final String secret in _presentationSecrets) {
    expect(encoded, isNot(contains(secret)));
  }
  expect(presentation.data.clear, throwsUnsupportedError);
  expect(
    (presentation.data['summaryParts']! as List<Object?>).clear,
    throwsUnsupportedError,
  );
}

void _expectNoPresentationSecrets(
  WidgetTester tester,
  ChatController controller,
) {
  final String timeline = controller.timeline
      .map((entry) => entry.content)
      .join('\n');
  final String rendered = tester
      .widgetList<Text>(find.byType(Text, skipOffstage: false))
      .map((widget) => widget.data ?? widget.textSpan?.toPlainText() ?? '')
      .join('\n');
  // Check the inputs to both rich and compact frontend bridges, including
  // retained collapsed bodies, not just the text those frontends choose to show.
  final List<Object?> bridgeInputs = [];
  for (final Widget widget in tester.allWidgets) {
    final ModelNativePresentation? presentation = switch (widget) {
      ModelNativeActivityCompactHost(:final presentation) => presentation,
      ModelNativeActivityInspectionHost(:final presentation) => presentation,
      _ => null,
    };
    if (presentation != null) {
      bridgeInputs.add({
        'kind': presentation.kind,
        'compactText': presentation.compactText,
        'data': presentation.data,
      });
    }
    final ToolActivityInspectionSource? source = switch (widget) {
      ToolActivityCompactHost(:final source) => source,
      ToolActivityInspectionHost(:final source) => source,
      _ => null,
    };
    if (source != null) {
      bridgeInputs.add({
        'canonicalArguments': source.snapshot.canonicalArguments,
        'hostData': source.snapshot.outcome?.hostData,
        'modelContent': source.snapshot.outcome?.modelContent,
      });
    }
  }
  final String bridgeData = jsonEncode(bridgeInputs);
  for (final String secret in _presentationSecrets) {
    expect(timeline, isNot(contains(secret)));
    expect(rendered, isNot(contains(secret)));
    expect(bridgeData, isNot(contains(secret)));
  }
  expect(find.text('Frontend unavailable.'), findsNothing);
  expect(find.text('Reasoning summary unavailable.'), findsNothing);
}

void _expectVerticalOrder(WidgetTester tester, List<Finder> items) {
  for (final item in items) {
    expect(item, findsOneWidget);
  }
  for (int index = 1; index < items.length; index++) {
    expect(
      tester.getBottomLeft(items[index - 1]).dy,
      lessThanOrEqualTo(tester.getTopLeft(items[index]).dy),
      reason: 'Inspection/timeline item $index must follow item ${index - 1}.',
    );
  }
}

String _revision(String output) =>
    jsonDecode(
          output
              .split('\n')
              .singleWhere((line) => line.startsWith('Revision: '))
              .substring('Revision: '.length),
        )
        as String;

String _toolOutput(Map<String, Object?> body, String callId) =>
    (body['input']! as List<Object?>).cast<Map<String, Object?>>().singleWhere(
          (item) =>
              item['type'] == 'function_call_output' &&
              item['call_id'] == callId,
        )['output']!
        as String;

Map<String, Object?> _call(
  String callId,
  String name,
  Map<String, Object?> arguments,
) => {
  'type': 'function_call',
  'id': 'fc_$callId',
  'call_id': callId,
  'name': name,
  'arguments': jsonEncode(arguments),
  'status': 'completed',
};

Map<String, Object?> _message(String id, String text) => {
  'type': 'message',
  'id': id,
  'role': 'assistant',
  'status': 'completed',
  'content': [
    {'type': 'output_text', 'text': text, 'annotations': <Object?>[]},
  ],
};

Map<String, Object?> _reasoning(String id, String summary, String encrypted) =>
    {
      'type': 'reasoning',
      'id': id,
      'status': 'completed',
      'summary': [
        {'type': 'summary_text', 'text': summary},
      ],
      'encrypted_content': encrypted,
      'content': [
        {'type': 'reasoning_text', 'text': _privateReasoning},
      ],
      'provider_extra': {'text': _providerExtra},
    };

void _output(HttpResponse response, Map<String, Object?> item) =>
    _sse(response, {'type': 'response.output_item.done', 'item': item});

void _sse(HttpResponse response, Map<String, Object?> event) {
  response.write('data: ${jsonEncode(event)}\n\n');
}

String _idToken(String accountId) {
  String encode(Object value) =>
      base64Url.encode(utf8.encode(jsonEncode(value))).replaceAll('=', '');
  return '${encode({'alg': 'none'})}.${encode({
    'https://api.openai.com/auth': {'chatgpt_account_id': accountId},
  })}.';
}

Future<Map<String, Object?>> _sourceSnapshot(Directory repository) async {
  final Map<String, Object?> files = {};
  Future<void> visit(Directory directory) async {
    await for (final entity in directory.list(followLinks: false)) {
      if (entity.path == '${repository.path}/.git') continue;
      if (entity is Directory) {
        await visit(entity);
      } else if (entity is File) {
        files[entity.path.substring(repository.path.length + 1)] = await entity
            .readAsBytes();
      } else {
        throw StateError('Unexpected source fixture entity ${entity.path}.');
      }
    }
  }

  await visit(repository);
  return {
    'files': files,
    'head': await _git(repository, ['rev-parse', 'HEAD']),
    'branch': await _git(repository, ['branch', '--show-current']),
    'status': await _git(repository, ['status', '--porcelain=v1', '-z']),
    'diff': await _git(repository, ['diff', '--binary', 'HEAD']),
    'staged': await _git(repository, ['diff', '--cached', '--binary']),
  };
}

Future<String> _git(Directory directory, List<String> arguments) async {
  final ProcessResult result = await Process.run('git', [
    '-c',
    'user.name=ADELE Test',
    '-c',
    'user.email=adele-test@example.invalid',
    '-c',
    'commit.gpgsign=false',
    ...arguments,
  ], workingDirectory: directory.path);
  if (result.exitCode != 0) {
    throw StateError('git ${arguments.join(' ')} failed: ${result.stderr}');
  }
  return result.stdout.toString();
}

String _dartExecutable() {
  final String? flutterRoot = Platform.environment['FLUTTER_ROOT'];
  if (flutterRoot != null) {
    final File executable = File.fromUri(
      Directory(flutterRoot).uri.resolve(
        'bin/cache/dart-sdk/bin/${Platform.isWindows ? 'dart.exe' : 'dart'}',
      ),
    );
    if (executable.existsSync()) return executable.path;
  }
  final File executable = File(Platform.resolvedExecutable);
  if (executable.parent.path.endsWith(
    '${Platform.pathSeparator}dart-sdk${Platform.pathSeparator}bin',
  )) {
    return executable.path;
  }
  throw StateError('Unable to locate the Dart SDK executable for AOT tests.');
}
