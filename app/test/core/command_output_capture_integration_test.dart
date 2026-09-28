@Timeout(Duration(minutes: 5))
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:adele_capabilities/adele_capabilities.dart';
import 'package:adele_desktop/core/adele_runtime.dart';
import 'package:adele_desktop/core/model_tool_host.dart';
import 'package:adele_desktop/core/orchestration_host.dart';
import 'package:adele_desktop/core/product_lifecycle.dart';
import 'package:adele_desktop/core/project_storage_host.dart';
import 'package:adele_desktop/core/remote_inference_context_host.dart';
import 'package:adele_desktop/frontend/owning_backend_bridge.dart';
import 'package:adele_desktop/frontend/prepared_frontend.dart';
import 'package:adele_environment/adele_environment.dart';
import 'package:adele_orchestration/adele_orchestration.dart';
import 'package:adele_plugin_api/adele_plugin_api.dart';
import 'package:adele_product/adele_product.dart';
import 'package:agent_kernel/agent_kernel.dart';
import 'package:command_tools_contract/command_tools_contract.dart';
import 'package:command_tools_plugin/command_tools_plugin.dart'
    show maximumRetainedCommandOutputCharacters;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plugin_builder/plugin_builder.dart';
import 'package:plugin_runtime/plugin_runtime.dart';
import 'package:sqlite3/sqlite3.dart' hide Session;

import '../../tool/command_output_frontend_compiler.dart';
import '../fixtures/command_output_process.dart'
    show captureBulk, captureMarker;

const _gitId = 'dev.adele.plugin.git-environment';
const _projectId = 'dev.adele.plugin.local-directory-project';
const _commandId = 'dev.adele.plugin.command-tools';
const _deadline = Duration(seconds: 45);
final _strategyId = OrchestrationStrategyId('dev.adele.test.command-capture');
final _projectProvider = ProviderId('dev.adele.project.local-directory');

void main() {
  late Directory artifacts;
  late String aotRuntime;

  setUpAll(() async {
    artifacts = await Directory.systemTemp.createTemp('adele-command-capture-');
    addTearDown(() => artifacts.delete(recursive: true));
    final dart = _dartExecutable();
    aotRuntime = '${File(dart).parent.path}/dartaotruntime';
    for (final entry in const {
      'host': 'packages/plugin_backend_host/bin/adele_backend_host.dart',
      'child': 'app/test/fixtures/command_output_process.dart',
      _projectId:
          'plugins/local_directory_project/packages/backend/bin/local_directory_project_backend.dart',
      _gitId:
          'plugins/git_environment/packages/backend/bin/git_environment_backend.dart',
      _commandId:
          'plugins/command_tools/packages/backend/bin/command_tools_backend.dart',
    }.entries) {
      await compileAotSnapshot(
        dartExecutable: dart,
        workingDirectory: Directory.current.parent,
        entrypoint: entry.value,
        artifact: File('${artifacts.path}/${entry.key}.aot'),
        stage: 'command-capture-${entry.key}',
      );
    }
  });

  Future<_Backends> start({required bool git}) async {
    final runtime = AdeleRuntime(
      ids: MonotonicProductIdSource(seed: 'capture'),
    );
    final host = await PluginBackendHost.start(
      dartaotruntimeExecutable: aotRuntime,
      hostArtifactPath: '${artifacts.path}/host.aot',
    );
    final backends = _Backends(runtime, host, artifacts);
    addTearDown(backends.close);
    await backends.activate(_projectId);
    if (git) await backends.activate(_gitId);
    return backends;
  }

  testWidgets(
    'T3a full capture crosses real AOT process/storage, EVC observation and fresh Project reopen',
    (tester) => tester.runAsync(() async {
      final source = await Directory.systemTemp.createTemp(
        'adele-capture-project-',
      );
      addTearDown(() => source.delete(recursive: true));
      await File(
        '${source.path}/baseline.txt',
      ).writeAsString('Capture baseline.\n');
      await _git(source, ['init', '--initial-branch=main']);
      await _git(source, ['add', 'baseline.txt']);
      await _git(source, ['commit', '-m', 'Capture fixture']);
      final backends = await start(git: true);
      final command = await backends.activate(_commandId);
      final runtime = backends.runtime;
      late _Execution execution;
      final registration = runtime.extensions.register(
        point: orchestrationStrategyContributions,
        id: ExtensionId(_strategyId.value),
        value: OrchestrationStrategyContribution(
          strategyId: _strategyId,
          materialize: (context) => execution = _Execution(context.host),
        ),
      );
      addTearDown(registration.close);
      final project = await runtime.lifecycle.openProject(
        sourceLocation: source.uri,
        provider: runtime.lifecycle.resolveProjectProvider(_projectProvider),
      );
      final task = await runtime.lifecycle.createTask(
        projectId: project.id,
        title: 'Complete command output',
      );
      final session = runtime.lifecycle.createSession(
        taskId: task.task.id,
        strategyId: _strategyId,
      );
      final environment = task.environment;
      final worktree = Directory.fromUri(
        source.uri.resolve(
          environment.providerState!['worktreeRelativePath']! as String,
        ),
      );
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final connections = StreamIterator(server);
      final children = <_Child>[];
      addTearDown(() async {
        for (final child in children) {
          child.socket.destroy();
          await child.lines.cancel();
        }
        await connections.cancel();
        await server.close();
      });
      final arguments = <String, Object?>{
        'program': aotRuntime,
        'arguments': ['${artifacts.path}/child.aot', '${server.port}'],
        'workingDirectory': '',
        'timeoutSeconds': 600,
      };
      final model = _Model(arguments);
      final catalog = await buildModelToolCatalogForSession(
        sessionId: session.id,
        environmentRuntime: runtime.lifecycle.environmentRuntime,
        extensions: runtime.extensions,
      );
      expect(
        catalog.materialize().tools.single.modelDefinition.alias,
        'run_command',
      );
      expect(
        runtime.lifecycle.environmentRuntime
            .currentMaterialization(environment.id)!
            .provider,
        isA<GeneratedEnvironmentProvider>(),
      );
      final run = await createSessionOrchestrationRun(
        lifecycle: runtime.lifecycle,
        sessionId: session.id,
        runId: RunId('capture-run'),
        contextComposer: runtime.contextComposer,
        model: model,
        toolCatalog: catalog,
        policy: const _AllowCommand(),
      );
      addTearDown(() async {
        execution.release();
        for (final child in children) {
          if (child.active && child.pid != null) {
            Process.killPid(child.pid!, ProcessSignal.sigterm);
          }
          child.socket.destroy();
        }
        await run.close().timeout(_deadline);
      });
      final advancing = run.start();
      // Observe failures without creating an unhandled asynchronous error while
      // an external child handshake is pending.
      advancing.ignore();
      final client = _client(command.connection);
      final captures = <_Capture>[];
      final completeStates = <CommandCaptureState>[];
      final bulk = {
        for (final stream in ['stdout', 'stderr']) stream: captureBulk(stream),
      };
      final bulkUnits = bulk.values.fold(0, (sum, text) => sum + text.length);
      expect(bulkUnits, greaterThan(24 * 1024 * 1024));
      PreparedFrontend? frontend;
      final frontendArtifact = File('${artifacts.path}/command.evc');

      for (var index = 0; index < 2; index++) {
        expect(
          await Future.any([
            connections.moveNext(),
            advancing.then<bool>(
              (_) => throw StateError('Run settled before child connection.'),
            ),
          ]).timeout(_deadline),
          isTrue,
        );
        final child = _Child(connections.current);
        children.add(child);
        await child.expectStage('connected');
        final tool = run.activity.snapshot.tools.last;
        if (index == 0) {
          await compileCommandOutputFrontend(
            repositoryRoot: Directory.current.parent,
            artifact: frontendArtifact,
            sessionId: session.id.value,
            runId: run.run.id.value,
            toolInvocationId: tool.id.value,
          );
          frontend = await PreparedFrontend.load(frontendArtifact);
          addTearDown(frontend.invalidate);
          expect(frontend.failure, isNull);
        }
        child.release('produce');
        await child.expectStage('started');
        if (index == 0) {
          await _mount(tester, frontend!, command.connection);
          await _visible(tester, 'codeUnits:${_markerUnits('START')}');
          await tester.pumpWidget(const SizedBox.shrink());
        }
        child.release('bulk');
        try {
          await Future.any([
            child.expectStage('bulk', timeout: const Duration(minutes: 2)),
            advancing.then<void>(
              (_) => throw StateError('Run settled before bulk output.'),
            ),
          ]);
        } on TimeoutException {
          final state = await client
              .getState(
                session.id.value,
                run.run.id.value,
                run.lastToolInvocation!.id.value,
              )
              .timeout(_deadline);
          fail(
            'Bulk handshake timed out: ${state.state}, '
            '${state.totalCodeUnits}/$bulkUnits code units, '
            'cursor ${state.highWater}, failure ${state.failure}.',
          );
        }
        expect(child.workingDirectory, await worktree.resolveSymbolicLinks());
        expect(await Directory('/proc/${child.pid}').exists(), isTrue);
        final capture = _Capture(
          client,
          session.id.value,
          run.run.id.value,
          tool.id.value,
        );
        captures.add(capture);
        expect(tool.canonicalArguments, arguments);
        expect(
          tool.changes.any(
            (change) => change.kind == ToolActivityKind.executionStarted,
          ),
          isTrue,
        );

        // The child emitted multi-MB output without any mounted consumer. Reads
        // wait on committed extent, not a delay or process completion.
        final live = await capture.waitFor(
          (state) => state.totalCodeUnits == bulkUnits,
        );
        expect(live.state, 'capturing');
        expect(live.environmentId, environment.id.value);
        expect(live.program, aotRuntime);
        expect(jsonDecode(live.argumentsJson!), arguments['arguments']);
        if (index == 0) expect(await _readAll(capture, live), bulk);
        expect(await Directory('/proc/${child.pid}').exists(), isTrue);
        expect(run.run.state, RunState.running);

        if (index == 0) {
          await _mount(tester, frontend!, command.connection);
          await _visible(tester, 'codeUnits:$bulkUnits');
          for (final stream in bulk.keys) {
            expect(find.text('$stream:START=true'), findsOneWidget);
            expect(find.text('$stream:MIDDLE=true'), findsOneWidget);
          }
          expect(find.text('state:capturing'), findsOneWidget);
        }

        child.release('late');
        await child.expectStage('late');
        final lateUnits = bulkUnits + _markerUnits('LATE');
        final late = await capture.waitFor(
          (state) => state.totalCodeUnits == lateUnits,
        );
        expect(late.state, 'capturing');
        final tail = await capture.client
            .readBefore(
              capture.sessionId,
              capture.runId,
              capture.invocationId,
              null,
              commandOutputPageChunks,
              commandOutputPageCodeUnits,
            )
            .timeout(_deadline);
        _expectPage(tail);
        for (final stream in bulk.keys) {
          expect(
            tail.chunks
                .where((chunk) => chunk.stream == stream)
                .map((chunk) => chunk.text)
                .join(),
            contains(captureMarker(stream, 'LATE')),
          );
        }
        if (index == 0) {
          await _visible(tester, 'stdout:LATE=true');
          await _visible(tester, 'stderr:LATE=true');
          await tester.pumpWidget(const SizedBox.shrink());
        }
        expect(await Directory('/proc/${child.pid}').exists(), isTrue);
        // Unmount cancels only observation. More output is captured while hidden.
        child.release('hidden');
        await child.expectStage('hidden');
        final fullUnits = lateUnits + _markerUnits('HIDDEN');
        final hidden = await capture.waitFor(
          (state) => state.totalCodeUnits == fullUnits,
        );
        expect(hidden.state, 'capturing');
        if (index == 0) {
          await _mount(tester, frontend!, command.connection);
          await _visible(tester, 'codeUnits:$fullUnits');
          expect(find.text('stdout:HIDDEN=true'), findsOneWidget);
          expect(find.text('stderr:HIDDEN=true'), findsOneWidget);
          await tester.pumpWidget(const SizedBox.shrink());
        }
        expect(await Directory('/proc/${child.pid}').exists(), isTrue);
        child.release('exit');
        await execution.completed[index].future.timeout(_deadline);
        child.active = false;
        final complete = await capture.waitFor(
          (state) => state.state == 'complete',
        );
        completeStates.add(complete);
        expect(complete.totalCodeUnits, fullUnits);
        expect(complete.termination, 'exited');
        expect(complete.exitCode, 0);
        expect(complete.failure, isNull);
        expect(await Directory('/proc/${child.pid}').exists(), isFalse);
        expect(run.run.state, RunState.running);
        expect(
          runtime.store.runRecord(run.run.id),
          isNull,
          reason:
              'Command history must be readable before terminal Run retention.',
        );
        final expected = {
          for (final stream in bulk.keys)
            stream:
                bulk[stream]! +
                captureMarker(stream, 'LATE') +
                captureMarker(stream, 'HIDDEN'),
        };
        expect(await _readAll(capture, complete), expected);
        expect(await _readBackwards(capture, complete), expected);
        _expectBoundedEvidence(run);
        if (index == 0) execution.nextCommand.complete();
      }

      expect(captures[0].invocationId, isNot(captures[1].invocationId));
      expect(
        run.activity.snapshot.tools.map((tool) => tool.canonicalArguments),
        [arguments, arguments],
      );
      expect(model.calls, 1);
      execution.finish.complete();
      await advancing.timeout(_deadline);
      expect(run.run.state, RunState.completed);
      expect(
        runtime.store.runRecord(run.run.id)!.state,
        RunTerminalState.completed,
      );
      final savedActivity = runtime.lifecycle.runActivity(run.run.id)!;
      final inventory = await _git(source, ['worktree', 'list', '--porcelain']);
      final marker = await File('${worktree.path}/.git').readAsBytes();
      final inspection = sqlite3.open('${source.path}/.adele/data.db');
      try {
        expect(
          inspection
              .select('SELECT owner_id FROM adele_schema_versions')
              .map((row) => row['owner_id']),
          contains(_commandId),
        );
      } finally {
        inspection.close();
      }
      await backends.close();
      expect(command.connection.isClosed, isTrue);

      final fresh = await start(git: false);
      expect(
        fresh.runtime.registry.providersFor(environmentProviderCapability),
        isEmpty,
      );
      expect(
        fresh.runtime.extensions.discover(orchestrationStrategyContributions),
        isEmpty,
      );
      final reopened = await fresh.runtime.lifecycle.openProject(
        sourceLocation: source.uri,
        provider: fresh.runtime.lifecycle.resolveProjectProvider(
          _projectProvider,
        ),
      );
      expect(reopened.id, project.id);
      expect(fresh.runtime.store.session(session.id)!.strategyId, _strategyId);
      await fresh.activations.single.close();
      final replacement = await fresh.activate(_commandId);
      expect(replacement.connection, isNot(same(command.connection)));
      expect(fresh.activations.map((item) => item.connection.pluginId), [
        _projectId,
        _commandId,
      ]);
      expect(
        fresh.activations
            .where((item) => !item.connection.isClosed)
            .map((item) => item.connection.pluginId),
        [_commandId],
      );
      final restoredClient = _client(replacement.connection);
      for (var index = 0; index < captures.length; index++) {
        final original = captures[index];
        final restored = _Capture(
          restoredClient,
          original.sessionId,
          original.runId,
          original.invocationId,
        );
        final state = await restored.state();
        expect(state.state, 'complete');
        expect(state.version, completeStates[index].version);
        expect(state.highWater, completeStates[index].highWater);
        expect(state.totalCodeUnits, completeStates[index].totalCodeUnits);
        expect(await _readAll(restored, state), {
          for (final stream in bulk.keys)
            stream:
                bulk[stream]! +
                captureMarker(stream, 'LATE') +
                captureMarker(stream, 'HIDDEN'),
        });
      }
      final freshFrontend = await PreparedFrontend.load(frontendArtifact);
      addTearDown(freshFrontend.invalidate);
      await _mount(tester, freshFrontend, replacement.connection);
      await _visible(
        tester,
        'codeUnits:${completeStates.first.totalCodeUnits}',
      );
      expect(find.text('state:complete'), findsOneWidget);
      expect(find.text('stdout:HIDDEN=true'), findsOneWidget);
      expect(find.text('stderr:MIDDLE=true'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
      expect(
        fresh.runtime.lifecycle.environmentRuntime.currentMaterialization(
          environment.id,
        ),
        isNull,
      );
      final restoredActivity = fresh.runtime.lifecycle.runActivity(run.run.id)!;
      expect(
        restoredActivity.tools.map((tool) => tool.id),
        savedActivity.tools.map((tool) => tool.id),
      );
      for (var index = 0; index < restoredActivity.tools.length; index++) {
        final restoredTool = restoredActivity.tools[index];
        expect(
          restoredTool.outcome!.hostData,
          savedActivity.tools[index].outcome!.hostData,
        );
        expect(
          restoredTool.outcome!.modelContent,
          savedActivity.tools[index].outcome!.modelContent,
        );
        expect(
          restoredTool.changes.where(
            (change) => change.kind == ToolActivityKind.progress,
          ),
          isEmpty,
        );
      }
      expect(
        await _git(source, ['worktree', 'list', '--porcelain']),
        inventory,
      );
      expect(await File('${worktree.path}/.git').readAsBytes(), marker);
      expect(tester.takeException(), isNull);
      await fresh.close();
    }),
    skip: !Platform.isLinux,
    timeout: const Timeout(Duration(minutes: 6)),
  );
}

final class _Backends {
  _Backends(this.runtime, this.host, this.artifacts);
  final AdeleRuntime runtime;
  final PluginBackendHost host;
  final Directory artifacts;
  final activations = <PluginBackendActivation>[];
  Future<void>? _closing;

  Future<PluginBackendActivation> activate(String pluginId) async {
    final connection = await host.startPlugin(
      pluginId: pluginId,
      artifactUri: File('${artifacts.path}/$pluginId.aot').uri,
      createInfrastructureServices: (connection) =>
          projectStorageServices(runtime.lifecycle, connection),
    );
    final activation = await PluginBackendActivation.registerAdvertised(
      connection: connection,
      capabilities: runtime.registry,
      extensions: runtime.extensions,
      adapters: createRemoteExtensionAdapters(),
    );
    activations.add(activation);
    return activation;
  }

  Future<void> close() => _closing ??= () async {
    try {
      for (final activation in activations.reversed) {
        await activation.close();
      }
    } finally {
      try {
        await host.close();
      } finally {
        await runtime.close();
      }
    }
  }();
}

final class _Execution implements OrchestrationExecution {
  _Execution(this.host);
  final OrchestrationExecutionHost host;
  final completed = [Completer<void>(), Completer<void>()];
  final nextCommand = Completer<void>();
  final finish = Completer<void>();
  bool aborted = false;

  @override
  Future<void> start() async {
    host.start();
    final turn = await host.invokeModel(
      StrategyInferenceMaterial(input: const []),
    );
    final proposals = turn.output.whereType<ModelToolProposalOutput>().toList();
    expect(proposals, hasLength(2));
    for (var index = 0; index < proposals.length; index++) {
      final result = await host.processProposal(
        tools: turn.tools,
        proposal: proposals[index].proposal,
      );
      expect(result, isA<StrategyToolContinuation>());
      final input =
          (result as StrategyToolContinuation).item as SemanticToolOutcomeInput;
      expect(
        input.outcome.disposition,
        ToolOutcomeDisposition.success,
        reason:
            '${input.outcome.modelContent}\n${input.outcome.hostDiagnostic}',
      );
      expect(input.outcome.modelContent.length, lessThan(100000));
      completed[index].complete();
      if (index == 0) await nextCommand.future;
      if (aborted) {
        host.complete();
        return;
      }
    }
    await finish.future;
    host.complete();
  }

  void release() {
    aborted = true;
    if (!nextCommand.isCompleted) nextCommand.complete();
    if (!finish.isCompleted) finish.complete();
  }

  @override
  Future<void> resolveApproval(ToolApprovalResolution resolution) =>
      throw StateError('The local fixture policy allows the exact command.');
  @override
  Future<void> close() async {}
}

final class _Model implements ModelPort {
  _Model(this.arguments);
  final Map<String, Object?> arguments;
  int calls = 0;

  @override
  Stream<ModelEvent> invoke(SemanticModelRequest request) async* {
    expect(++calls, 1);
    for (var index = 0; index < 2; index++) {
      yield ModelOutputItemCompleted(
        invocationId: request.invocationId,
        item: ModelToolProposalOutput(
          ProviderToolProposal(
            providerCallId: 'identical-command-$index',
            alias: 'run_command',
            arguments: arguments,
          ),
        ),
      );
    }
    yield ModelInvocationSettledEvent(invocationId: request.invocationId);
  }
}

final class _AllowCommand implements ToolPolicy {
  const _AllowCommand();
  @override
  ToolPolicyDecision evaluate(ToolPolicyInput input) {
    expect(
      input.invocation.tool.definition.id.value,
      '$_commandId.run-command',
    );
    return ToolPolicyDecision.allow;
  }
}

final class _Child {
  _Child(this.socket)
    : lines = StreamIterator(
        socket
            .cast<List<int>>()
            .transform(utf8.decoder)
            .transform(const LineSplitter()),
      );
  final Socket socket;
  final StreamIterator<String> lines;
  int? pid;
  bool active = true;
  late String workingDirectory;

  Future<void> expectStage(String stage, {Duration timeout = _deadline}) async {
    expect(await lines.moveNext().timeout(timeout), isTrue);
    final parts = lines.current.split(':');
    expect(parts.first, stage);
    pid = int.parse(parts[1]);
    workingDirectory = parts.skip(2).join(':');
  }

  void release(String stage) => socket.writeln(stage);
}

CommandOutputServiceClient _client(PluginBackendConnection connection) =>
    CommandOutputServiceClient(
      connection.channelFor(
        connection.defaultConfigurationContext,
        commandOutputServiceId,
      ),
    );

final class _Capture {
  const _Capture(this.client, this.sessionId, this.runId, this.invocationId);
  final CommandOutputServiceClient client;
  final String sessionId;
  final String runId;
  final String invocationId;
  Future<CommandCaptureState> state() =>
      client.getState(sessionId, runId, invocationId).timeout(_deadline);
  Future<CommandCaptureState> waitFor(
    bool Function(CommandCaptureState) predicate,
  ) => client
      .watch(sessionId, runId, invocationId)
      .firstWhere(predicate)
      .timeout(_deadline);
}

Future<Map<String, String>> _readAll(
  _Capture capture,
  CommandCaptureState state,
) async {
  final text = {'stdout': StringBuffer(), 'stderr': StringBuffer()};
  var cursor = 0;
  while (cursor < state.highWater) {
    final page = await capture.client
        .readAfter(
          capture.sessionId,
          capture.runId,
          capture.invocationId,
          cursor,
          commandOutputPageChunks,
          commandOutputPageCodeUnits,
        )
        .timeout(_deadline);
    _expectPage(page);
    expect(page.chunks, isNotEmpty);
    for (final chunk in page.chunks) {
      expect(chunk.cursor, ++cursor);
      text[chunk.stream]!.write(chunk.text);
    }
  }
  expect(cursor, state.highWater);
  final empty = await capture.client
      .readAfter(
        capture.sessionId,
        capture.runId,
        capture.invocationId,
        cursor,
        commandOutputPageChunks,
        commandOutputPageCodeUnits,
      )
      .timeout(_deadline);
  expect(empty.chunks, isEmpty);
  expect(
    text.values.fold(0, (sum, value) => sum + value.length),
    state.totalCodeUnits,
  );
  return text.map((key, value) => MapEntry(key, value.toString()));
}

Future<Map<String, String>> _readBackwards(
  _Capture capture,
  CommandCaptureState state,
) async {
  final chunks = <CommandOutputChunk>[];
  int? before;
  var expected = state.highWater;
  while (expected > 0) {
    final page = await capture.client
        .readBefore(
          capture.sessionId,
          capture.runId,
          capture.invocationId,
          before,
          commandOutputPageChunks,
          commandOutputPageCodeUnits,
        )
        .timeout(_deadline);
    _expectPage(page);
    expect(page.chunks, isNotEmpty);
    for (final chunk in page.chunks.reversed) {
      expect(chunk.cursor, expected--);
    }
    chunks.addAll(page.chunks.reversed);
    before = page.chunks.first.cursor;
  }
  return {
    for (final stream in ['stdout', 'stderr'])
      stream: chunks.reversed
          .where((chunk) => chunk.stream == stream)
          .map((chunk) => chunk.text)
          .join(),
  };
}

void _expectPage(CommandOutputPage page) {
  expect(page.chunks.length, lessThanOrEqualTo(commandOutputPageChunks));
  expect(
    page.chunks.fold(0, (sum, chunk) => sum + chunk.text.length),
    lessThanOrEqualTo(commandOutputPageCodeUnits),
  );
  for (final chunk in page.chunks) {
    expect(chunk.stream, isIn(['stdout', 'stderr']));
    expect(chunk.text.length, inInclusiveRange(1, commandOutputChunkCodeUnits));
  }
}

void _expectBoundedEvidence(SessionOrchestrationRun run) {
  for (final tool in run.activity.snapshot.tools) {
    final progress = tool.changes.where(
      (change) => change.kind == ToolActivityKind.progress,
    );
    expect(progress, isEmpty, reason: 'Core activity is not the transcript.');
    final outcome = tool.outcome!;
    expect(
      outcome.modelContent.length,
      lessThan(2 * maximumRetainedCommandOutputCharacters + 4096),
    );
    for (final stream in ['stdout', 'stderr']) {
      final preview = outcome.hostData[stream]! as String;
      expect(
        preview.length,
        lessThanOrEqualTo(maximumRetainedCommandOutputCharacters),
      );
      expect(outcome.hostData['${stream}Truncated'], isTrue);
      expect(preview, isNot(contains('$stream:MIDDLE')));
    }
    expect(outcome.hostData['captureState'], 'complete');
    expect(
      jsonEncode(outcome.hostData).length,
      lessThan(2 * maximumRetainedCommandOutputCharacters + 8192),
    );
  }
  final journal = run.run.journal.records
      .map((record) => record.event)
      .whereType<ToolProgressObserved>();
  expect(
    journal,
    isEmpty,
    reason: 'Raw output is not copied into the Run journal.',
  );
}

int _markerUnits(String stage) =>
    captureMarker('stdout', stage).length +
    captureMarker('stderr', stage).length;

Future<void> _mount(
  WidgetTester tester,
  PreparedFrontend frontend,
  PluginBackendConnection connection,
) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: frontend.createPresentation(
          library: commandOutputFrontendLibrary,
          entrypoint: 'buildView',
          createBridge: () => OwningBackendBridge.channel(
            OwningBackendChannel(
              connection: connection,
              configurationContext: connection.defaultConfigurationContext,
              backendServices: [commandOutputServiceId],
              validateOwner: () {
                if (connection.isClosed) throw StateError('Backend retired.');
              },
              validatePresentation: () {},
            ),
            validateBinding: () {},
          ),
        ),
      ),
    ),
  );
}

Future<void> _visible(WidgetTester tester, String text) async {
  final deadline = DateTime.now().add(_deadline);
  while (find.text(text).evaluate().isEmpty) {
    if (DateTime.now().isAfter(deadline)) fail('EVC did not display $text.');
    await tester.pump();
    await Future<void>.delayed(Duration.zero);
    expect(tester.takeException(), isNull);
    expect(find.text('Frontend unavailable.'), findsNothing);
    for (final widget in tester.widgetList<Text>(find.byType(Text))) {
      final value = widget.data;
      if (value != null &&
          value.startsWith('failure:') &&
          value != 'failure:') {
        fail('Command output EVC $value');
      }
    }
  }
  expect(find.text('failure:'), findsOneWidget);
}

Future<String> _git(Directory directory, List<String> arguments) async {
  final result = await Process.run('git', [
    '-c',
    'user.name=ADELE Test',
    '-c',
    'user.email=adele-test@example.invalid',
    '-c',
    'commit.gpgsign=false',
    ...arguments,
  ], workingDirectory: directory.path).timeout(_deadline);
  if (result.exitCode != 0) {
    throw StateError('git $arguments: ${result.stderr}');
  }
  return result.stdout.toString();
}

String _dartExecutable() {
  final flutterRoot = Platform.environment['FLUTTER_ROOT'];
  if (flutterRoot != null) {
    final executable = File('$flutterRoot/bin/cache/dart-sdk/bin/dart');
    if (executable.existsSync()) return executable.path;
  }
  var directory = File(Platform.resolvedExecutable).parent;
  while (directory.parent.path != directory.path) {
    final executable = File('${directory.path}/dart-sdk/bin/dart');
    if (executable.existsSync()) return executable.path;
    directory = directory.parent;
  }
  throw StateError('Cannot locate the running Flutter toolchain Dart SDK.');
}
