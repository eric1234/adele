@Timeout(Duration(minutes: 5))
library;

import 'dart:io';

import 'package:adele_capabilities/adele_capabilities.dart';
import 'package:adele_core_extensions/adele_core_extensions.dart';
import 'package:adele_desktop/core/adele_runtime.dart';
import 'package:adele_desktop/core/orchestration_host.dart';
import 'package:adele_desktop/core/product_lifecycle.dart';
import 'package:adele_desktop/core/project_storage_host.dart';
import 'package:adele_desktop/core/remote_inference_context_host.dart';
import 'package:adele_environment/adele_environment.dart';
import 'package:adele_orchestration/adele_orchestration.dart';
import 'package:adele_plugin_api/adele_plugin_api.dart';
import 'package:adele_product/adele_product.dart';
import 'package:agent_kernel/agent_kernel.dart';
import 'package:chat_strategy_contract/chat_strategy_contract.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plugin_builder/plugin_builder.dart';
import 'package:plugin_runtime/plugin_runtime.dart';
import 'package:sqlite3/sqlite3.dart' hide Session;

const _gitPluginId = 'dev.adele.plugin.git-environment';
const _projectPluginId = 'dev.adele.plugin.local-directory-project';
const _chatPluginId = 'dev.adele.plugin.chat-strategy';
const _instructions = 'Retain the conversation exactly. Answer without tools.';
const _budget = 3;
final _projectProviderId = ProviderId('dev.adele.project.local-directory');
final _gitProviderId = ProviderId('dev.adele.environment.git-worktree');

void main() {
  late Directory artifacts;
  late File hostArtifact;
  late String aotRuntime;

  setUpAll(() async {
    artifacts = await Directory.systemTemp.createTemp(
      'adele-durable-chat-aot-',
    );
    addTearDown(() => artifacts.delete(recursive: true));
    final dart = _dartExecutable();
    aotRuntime = File.fromUri(
      File(dart).parent.uri.resolve(
        Platform.isWindows ? 'dartaotruntime.exe' : 'dartaotruntime',
      ),
    ).path;
    hostArtifact = File('${artifacts.path}/host.aot');
    // Compile once; every runtime and Chat generation starts fresh AOT isolates.
    for (final entry in const {
      'host': 'packages/plugin_backend_host/bin/adele_backend_host.dart',
      _projectPluginId:
          'plugins/local_directory_project/packages/backend/bin/local_directory_project_backend.dart',
      _gitPluginId:
          'plugins/git_environment/packages/backend/bin/git_environment_backend.dart',
      _chatPluginId:
          'plugins/chat_strategy/packages/backend/bin/chat_strategy_backend.dart',
    }.entries) {
      await compileAotSnapshot(
        dartExecutable: dart,
        workingDirectory: Directory.current.parent,
        entrypoint: entry.value,
        artifact: File('${artifacts.path}/${entry.key}.aot'),
        stage: 'durable-chat-${entry.key}',
      );
    }
  });

  Future<_RuntimeBackends> start(ProductIdSource ids) async {
    final runtime = AdeleRuntime(ids: ids);
    addTearDown(runtime.close);
    final host = await PluginBackendHost.start(
      dartaotruntimeExecutable: aotRuntime,
      hostArtifactPath: hostArtifact.path,
    );
    final backends = _RuntimeBackends(runtime, host, artifacts);
    addTearDown(backends.close);
    await backends.activate(_projectPluginId);
    await backends.activate(_gitPluginId);
    expect(
      runtime.registry.providersFor(projectProviderCapability).single.id,
      _projectProviderId,
    );
    expect(
      runtime.registry.providersFor(environmentProviderCapability).single.id,
      _gitProviderId,
    );
    return backends;
  }

  test(
    'durable Session and Chat survive generation replacement, absent plugin, and fresh reactivation',
    () async {
      final source = await _source();
      final original = await start(
        MonotonicProductIdSource(seed: 'durable-chat'),
      );
      final generationA = await original.activate(_chatPluginId);
      final runtime = original.runtime;
      final product = await _createSession(runtime, source);
      final session = product.session;
      final authority = runtime.store.requireSessionAuthority(session.id);
      expect(authority.sessionId, session.id);
      expect(authority.taskId, product.task.id);
      expect(authority.environmentId, product.environment.id);
      final coreBefore = _inspect(source, _coreRows);
      final chatA = _chatClient(generationA.connection);
      await chatA.configureSession(session.id.value, _instructions, _budget);
      final firstUser = await chatA.appendUserMessage(
        session.id.value,
        'First durable question.',
      );
      final firstInput = await chatA.snapshot(session.id.value);
      final firstRun = await _createRun(
        runtime,
        session.id,
        'first-run',
        _Model(firstInput, 'First durable answer.'),
      );
      await firstRun.start();
      expect(firstRun.run.state, RunState.completed);
      expect(firstRun.run.journal.records.last.event, isA<RunCompleted>());
      final first = await chatA.snapshot(session.id.value);
      _expectHistory(first, [
        ('user', 'First durable question.'),
        ('assistant', 'First durable answer.'),
      ]);
      expect(first.entries.first.id, firstUser.id);
      expect(_inspect(source, _coreRows), coreBefore);
      final firstRows = _inspect(source, _chatRows);
      final retained = runtime.lifecycle.resolveSessionStrategy(session.id);
      expect(
        generationA.extensionOrigin(retained.binding)!.connection,
        same(generationA.connection),
      );

      await generationA.close();
      expect(generationA.connection.isClosed, isTrue);
      expect(original.host.isClosed, isFalse);
      expect(retained.validateBinding, throwsA(isA<StaleExtensionBinding>()));
      expect(
        () => runtime.lifecycle.resolveSessionStrategy(session.id),
        throwsA(isA<OrchestrationStrategyUnavailable>()),
      );
      await expectLater(
        chatA.snapshot(session.id.value),
        throwsA(isA<PluginConnectionClosed>()),
      );
      expect(runtime.store.session(session.id), same(session));
      expect(
        runtime.store.requireSessionAuthority(session.id),
        same(authority),
      );
      expect(_inspect(source, _chatRows), firstRows);

      final generationB = await original.activate(_chatPluginId);
      final chatB = _chatClient(generationB.connection);
      expect(generationB.connection, isNot(same(generationA.connection)));
      final replacement = runtime.lifecycle.resolveSessionStrategy(session.id);
      expect(replacement.binding, isNot(same(retained.binding)));
      expect(
        generationB.extensionOrigin(replacement.binding)!.connection,
        same(generationB.connection),
      );
      expect(retained.validateBinding, throwsA(isA<StaleExtensionBinding>()));
      expect(
        _snapshot(await chatB.snapshot(session.id.value)),
        _snapshot(first),
      );
      expect(_inspect(source, _chatRows), firstRows);
      await chatB.appendUserMessage(
        session.id.value,
        'Second durable question.',
      );
      final secondRun = await _createRun(
        runtime,
        session.id,
        'second-run',
        _Model(
          await chatB.snapshot(session.id.value),
          'Second durable answer.',
        ),
      );
      await secondRun.start();
      expect(secondRun.run.state, RunState.completed);
      final saved = await chatB.snapshot(session.id.value);
      _expectHistory(saved, [
        ('user', 'First durable question.'),
        ('assistant', 'First durable answer.'),
        ('user', 'Second durable question.'),
        ('assistant', 'Second durable answer.'),
      ]);
      expect(
        saved.entries.take(2).map((e) => e.id),
        first.entries.map((e) => e.id),
      );
      expect(_inspect(source, _coreRows), coreBefore);
      final savedRows = _inspect(source, _chatRows);
      final inventory = await _git(source, ['worktree', 'list', '--porcelain']);
      final worktree = Directory.fromUri(
        source.uri.resolve(
          product.environment.providerState!['worktreeRelativePath']! as String,
        ),
      );
      final marker = await File('${worktree.path}/.git').readAsBytes();

      await original.close();
      expect(original.host.isClosed, isTrue);
      for (final activation in original.activations) {
        expect(activation.connection.isClosed, isTrue);
      }
      expect(_inspect(source, _chatRows), savedRows);

      final ids = _NoAllocationIds();
      final fresh = await start(ids);
      final reopenedRuntime = fresh.runtime;
      expect(reopenedRuntime.store, isNot(same(runtime.store)));
      expect(fresh.host, isNot(same(original.host)));
      expect(reopenedRuntime.store.session(session.id), isNull);
      expect(reopenedRuntime.store.sessionAuthority(session.id), isNull);
      expect(
        reopenedRuntime.extensions.discover(orchestrationStrategyContributions),
        isEmpty,
      );
      final reopened = await reopenedRuntime.lifecycle.openProject(
        sourceLocation: source.uri,
        provider: reopenedRuntime.lifecycle.resolveProjectProvider(
          _projectProviderId,
        ),
      );
      expect(reopened.id, product.project.id);
      expect(reopened.sourceLocation, source.uri);
      expect(reopened, isNot(same(product.project)));
      final task = reopenedRuntime.store.tasksFor(reopened.id).single;
      expect(task.id, product.task.id);
      expect(task.projectId, reopened.id);
      expect(task.title, product.task.title);
      final environment = reopenedRuntime.store.primaryEnvironmentFor(task.id)!;
      expect(environment.id, product.environment.id);
      expect(environment.taskId, task.id);
      expect(environment.role, EnvironmentRole.primary);
      expect(environment.providerId, _gitProviderId);
      expect(environment.providerState, product.environment.providerState);
      final restoredSession = reopenedRuntime.store.session(session.id)!;
      expect(restoredSession, isNot(same(session)));
      expect(restoredSession.id, session.id);
      expect(restoredSession.taskId, task.id);
      expect(restoredSession.strategyId, chatStrategyId);
      final restoredAuthority = reopenedRuntime.store.requireSessionAuthority(
        session.id,
      );
      expect(restoredAuthority, isNot(same(authority)));
      expect(restoredAuthority.sessionId, restoredSession.id);
      expect(restoredAuthority.taskId, task.id);
      expect(restoredAuthority.environmentId, environment.id);
      expect(
        reopenedRuntime.lifecycle.environmentRuntime.currentMaterialization(
          environment.id,
        ),
        isNull,
      );
      expect(ids.calls, 0);
      expect(
        () => reopenedRuntime.lifecycle.resolveSessionStrategy(session.id),
        throwsA(isA<OrchestrationStrategyUnavailable>()),
      );
      // Core loading must not initialize, adopt, reset, or migrate absent Chat.
      expect(_inspect(source, _coreRows), coreBefore);
      expect(_inspect(source, _chatRows), savedRows);
      expect(
        await _git(source, ['worktree', 'list', '--porcelain']),
        inventory,
      );
      expect(await File('${worktree.path}/.git').readAsBytes(), marker);

      final reactivated = await fresh.activate(_chatPluginId);
      final chat = _chatClient(reactivated.connection);
      expect(reactivated.connection, isNot(same(generationB.connection)));
      expect(
        _snapshot(await chat.snapshot(session.id.value)),
        _snapshot(saved),
      );
      expect(_inspect(source, _chatRows), savedRows);
      final nextUser = await chat.appendUserMessage(
        session.id.value,
        'Question after restart.',
      );
      expect(nextUser.id, 'entry-4');
      final continued = await _createRun(
        reopenedRuntime,
        session.id,
        'fresh-run',
        _Model(await chat.snapshot(session.id.value), 'Answer after restart.'),
      );
      expect(continued.run.state, RunState.created);
      expect(continued.run.journal.records, isEmpty);
      expect(continued.run, isNot(same(secondRun.run)));
      await continued.start();
      expect(continued.run.state, RunState.completed);
      final finalSnapshot = await chat.snapshot(session.id.value);
      _expectHistory(finalSnapshot, [
        ('user', 'First durable question.'),
        ('assistant', 'First durable answer.'),
        ('user', 'Second durable question.'),
        ('assistant', 'Second durable answer.'),
        ('user', 'Question after restart.'),
        ('assistant', 'Answer after restart.'),
      ]);
      expect(
        finalSnapshot.entries.take(4).map((e) => e.id),
        saved.entries.map((e) => e.id),
      );
      expect(ids.calls, 0);
      expect(
        reopenedRuntime.lifecycle.environmentRuntime.currentMaterialization(
          environment.id,
        ),
        isNull,
      );
      expect(_inspect(source, _coreRows), coreBefore);
      await fresh.close();
      _inspect(source, _expectSchema);
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test(
    'real SQLite rollback preserves Chat cache, rows, and IDs without mutating core product rows',
    () async {
      final source = await _source();
      final backends = await start(
        MonotonicProductIdSource(seed: 'chat-rollback'),
      );
      final generation = await backends.activate(_chatPluginId);
      final runtime = backends.runtime;
      final product = await _createSession(runtime, source);
      final sessionId = product.session.id;
      final coreBefore = _inspect(source, _coreRows);
      final chat = _chatClient(generation.connection);
      await chat.configureSession(sessionId.value, _instructions, _budget);
      await chat.appendUserMessage(sessionId.value, 'Retained before failure.');
      final before = await chat.snapshot(sessionId.value);
      final rowsBefore = _inspect(source, _chatRows);
      expect(rowsBefore['sessions'], [
        {
          'session_id': sessionId.value,
          'instructions': _instructions,
          'max_model_invocations': _budget,
          'next_entry': 1,
        },
      ]);
      expect(rowsBefore['entries'], [
        {
          'session_id': sessionId.value,
          'sequence': 0,
          'entry_id': 'entry-0',
          'role': 'user',
          'content': 'Retained before failure.',
        },
      ]);
      _inspect(source, _expectSchema);
      expect(_inspect(source, _coreRows), coreBefore);
      // Undeclared SQL errors are deliberately sanitized by generated transport.
      final storageFailure = throwsA(
        isA<PluginRemoteFailure>().having(
          (failure) => failure.code,
          'code',
          'internal_error',
        ),
      );

      // Fail inside the host's actual SQLite transaction, not a mock transport.
      _inspect(
        source,
        (database) => database.execute('''
        CREATE TRIGGER reject_chat_entry BEFORE INSERT ON adele_chat_entries
        BEGIN SELECT RAISE(ABORT, 'durable-chat-entry-failure'); END;
        CREATE TRIGGER reject_chat_configuration
        BEFORE UPDATE OF instructions, max_model_invocations ON adele_chat_sessions
        BEGIN SELECT RAISE(ABORT, 'durable-chat-configuration-failure'); END;
      '''),
      );
      await expectLater(
        chat.appendUserMessage(sessionId.value, 'Must not be published.'),
        storageFailure,
      );
      expect(
        _snapshot(await chat.snapshot(sessionId.value)),
        _snapshot(before),
      );
      expect(_inspect(source, _chatRows), rowsBefore);
      expect(_inspect(source, _coreRows), coreBefore);

      await expectLater(
        chat.configureSession(
          sessionId.value,
          'Must not replace instructions.',
          11,
        ),
        storageFailure,
      );
      expect(
        _snapshot(await chat.snapshot(sessionId.value)),
        _snapshot(before),
      );
      expect(_inspect(source, _chatRows), rowsBefore);
      expect(_inspect(source, _coreRows), coreBefore);

      final failed = await _createRun(
        runtime,
        sessionId,
        'assistant-persistence-fails',
        _Model(before, 'Must not enter durable history.'),
      );
      await expectLater(failed.start(), storageFailure);
      // Host execution already completed; the remote caller still sees failure.
      expect(failed.run.state, RunState.completed);
      expect(failed.run.journal.records.last.event, isA<RunCompleted>());
      expect(
        _snapshot(await chat.snapshot(sessionId.value)),
        _snapshot(before),
      );
      expect(_inspect(source, _chatRows), rowsBefore);
      expect(_inspect(source, _coreRows), coreBefore);

      _inspect(
        source,
        (database) => database.execute('''
          DROP TRIGGER reject_chat_entry;
          DROP TRIGGER reject_chat_configuration;
        '''),
      );
      final retry = await _createRun(
        runtime,
        sessionId,
        'assistant-persistence-retry',
        _Model(before, 'Committed after retry.'),
      );
      await retry.start();
      expect(retry.run.state, RunState.completed);
      final recovered = await chat.snapshot(sessionId.value);
      _expectHistory(recovered, [
        ('user', 'Retained before failure.'),
        ('assistant', 'Committed after retry.'),
      ]);
      expect(recovered.entries.first.id, before.entries.single.id);
      expect(_inspect(source, _coreRows), coreBefore);
      final recoveredRows = _inspect(source, _chatRows);
      await generation.close();
      final replacement = await backends.activate(_chatPluginId);
      expect(
        _snapshot(
          await _chatClient(replacement.connection).snapshot(sessionId.value),
        ),
        _snapshot(recovered),
      );
      expect(_inspect(source, _chatRows), recoveredRows);
      expect(_inspect(source, _coreRows), coreBefore);
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
}

final class _RuntimeBackends {
  _RuntimeBackends(this.runtime, this.host, this.artifacts);
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
    expect(connection.isClosed, isFalse);
    return activation;
  }

  Future<void> close() => _closing ??= _close();

  Future<void> _close() async {
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
  }
}

Future<({Project project, Task task, Environment environment, Session session})>
_createSession(AdeleRuntime runtime, Directory source) async {
  final project = await runtime.lifecycle.openProject(
    sourceLocation: source.uri,
    provider: runtime.lifecycle.resolveProjectProvider(_projectProviderId),
  );
  final created = await runtime.lifecycle.createTask(
    projectId: project.id,
    title: 'Durable Chat Task',
  );
  final session = runtime.lifecycle.createSession(
    taskId: created.task.id,
    strategyId: chatStrategyId,
  );
  return (
    project: project,
    task: created.task,
    environment: created.environment,
    session: session,
  );
}

ChatSessionServiceClient _chatClient(PluginBackendConnection connection) =>
    ChatSessionServiceClient(
      connection.channelFor(
        connection.defaultConfigurationContext,
        chatSessionServiceId,
      ),
    );

Future<SessionOrchestrationRun> _createRun(
  AdeleRuntime runtime,
  SessionId sessionId,
  String runId,
  _Model model,
) async {
  final run = await createSessionOrchestrationRun(
    lifecycle: runtime.lifecycle,
    sessionId: sessionId,
    runId: RunId(runId),
    contextComposer: runtime.contextComposer,
    model: model,
    toolCatalog: ToolCatalog(),
    policy: const _NoTools(),
  );
  addTearDown(run.close);
  return run;
}

/// Only the model is native. Chat sequencing, history, and storage cross AOT RPC.
final class _Model implements ModelPort {
  _Model(this.expected, this.answer);
  final ChatSessionSnapshot expected;
  final String answer;
  int calls = 0;

  @override
  Stream<ModelEvent> invoke(SemanticModelRequest request) async* {
    expect(++calls, 1);
    expect(
      renderInferenceInstructions(request.context),
      contains(expected.instructions),
    );
    expect(request.context.input, everyElement(isA<SemanticMessageInput>()));
    expect(
      request.context.input.cast<SemanticMessageInput>().map(
        (item) => (item.role.name, item.content),
      ),
      expected.entries.map((entry) => (entry.role, entry.content)),
    );
    yield ModelOutputItemCompleted(
      invocationId: request.invocationId,
      item: ModelTextOutput(answer),
    );
    yield ModelInvocationSettledEvent(
      invocationId: request.invocationId,
      settlement: ModelSettlement.completed,
      metadata: ModelTerminalMetadata(
        effectiveModel: 'durable-chat-deterministic',
      ),
    );
  }
}

final class _NoTools implements ToolPolicy {
  const _NoTools();
  @override
  ToolPolicyDecision evaluate(ToolPolicyInput input) => throw StateError(
    'This deterministic conversation must not invoke tools.',
  );
}

Map<String, Object?> _snapshot(ChatSessionSnapshot snapshot) => {
  'instructions': snapshot.instructions,
  'maxModelInvocations': snapshot.maxModelInvocations,
  'entries': [
    for (final entry in snapshot.entries)
      {'id': entry.id, 'role': entry.role, 'content': entry.content},
  ],
};

void _expectHistory(
  ChatSessionSnapshot snapshot,
  List<(String, String)> entries,
) {
  expect(snapshot.instructions, _instructions);
  expect(snapshot.maxModelInvocations, _budget);
  expect(snapshot.entries.map((entry) => (entry.role, entry.content)), entries);
  expect(snapshot.entries.map((entry) => entry.id), [
    for (var index = 0; index < entries.length; index++) 'entry-$index',
  ]);
}

T _inspect<T>(Directory source, T Function(Database) read) {
  final database = sqlite3.open('${source.path}/.adele/data.db');
  try {
    return read(database);
  } finally {
    database.close();
  }
}

List<Map<String, Object?>> _rows(Database database, String sql) => [
  for (final row in database.select(sql)) Map<String, Object?>.from(row),
];

Map<String, Object?> _coreRows(Database database) => {
  for (final table in [
    'adele_product_projects',
    'adele_product_tasks',
    'adele_product_environments',
    'adele_product_sessions',
    'adele_product_session_environment_authority',
  ])
    table: _rows(database, 'SELECT * FROM $table ORDER BY 1'),
  'version': _rows(
    database,
    "SELECT * FROM adele_schema_versions WHERE owner_id = 'dev.adele.product'",
  ),
};

Map<String, Object?> _chatRows(Database database) => {
  'sessions': _rows(database, 'SELECT * FROM adele_chat_sessions ORDER BY 1'),
  'entries': _rows(database, 'SELECT * FROM adele_chat_entries ORDER BY 1, 2'),
  'versions': _rows(
    database,
    'SELECT * FROM adele_schema_versions ORDER BY owner_id',
  ),
};

void _expectSchema(Database database) {
  expect(
    _rows(database, 'SELECT * FROM adele_schema_versions ORDER BY owner_id'),
    [
      {'owner_id': _chatPluginId, 'version': 1},
      {'owner_id': 'dev.adele.product', 'version': 1},
    ],
  );
  // Runs and execution objects are deliberately not part of durable restoration.
  expect(
    database
        .select("SELECT name FROM sqlite_master WHERE type = 'table'")
        .map((row) => row['name']),
    unorderedEquals([
      'adele_schema_versions',
      'adele_product_projects',
      'adele_product_tasks',
      'adele_product_environments',
      'adele_product_sessions',
      'adele_product_session_environment_authority',
      'adele_chat_sessions',
      'adele_chat_entries',
    ]),
  );
}

final class _NoAllocationIds implements ProductIdSource {
  int calls = 0;
  Never _allocate() {
    calls++;
    throw StateError(
      'Restoring durable Session work must not allocate product IDs.',
    );
  }

  @override
  ProjectId nextProjectId() => _allocate();
  @override
  TaskId nextTaskId() => _allocate();
  @override
  EnvironmentId nextEnvironmentId() => _allocate();
  @override
  SessionId nextSessionId() => _allocate();
}

Future<Directory> _source() async {
  final source = await Directory.systemTemp.createTemp(
    'adele-durable-chat-project-',
  );
  addTearDown(() => source.delete(recursive: true));
  await File(
    '${source.path}/baseline.txt',
  ).writeAsString('Durable Chat fixture.\n');
  await _git(source, ['init', '--initial-branch=main']);
  await _git(source, ['add', 'baseline.txt']);
  await _git(source, ['commit', '-m', 'Fixture baseline']);
  return source;
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
  ], workingDirectory: directory.path);
  if (result.exitCode != 0) {
    throw StateError('git ${arguments.join(' ')} failed: ${result.stderr}');
  }
  return result.stdout.toString();
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
