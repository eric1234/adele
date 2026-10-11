@Timeout(Duration(minutes: 5))
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:adele_capabilities/adele_capabilities.dart';
import 'package:adele_contract/adele_contract.dart';
import 'package:adele_core_extensions/adele_core_extensions.dart';
import 'package:adele_desktop/core/adele_runtime.dart';
import 'package:adele_desktop/core/application_plugin_bootstrap.dart';
import 'package:adele_desktop/core/orchestration_host.dart';
import 'package:adele_desktop/core/product_lifecycle.dart';
import 'package:adele_desktop/core/project_storage_host.dart';
import 'package:adele_desktop/core/window_session_context.dart';
import 'package:adele_desktop/ui/commands/command_palette.dart';
import 'package:adele_environment/adele_environment.dart';
import 'package:adele_orchestration/adele_orchestration.dart';
import 'package:adele_plugin_api/adele_plugin_api.dart';
import 'package:adele_product/adele_product.dart';
import 'package:agent_kernel/agent_kernel.dart';
import 'package:chat_strategy_contract/chat_strategy_contract.dart';
import 'package:file_selector_platform_interface/file_selector_platform_interface.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plugin_builder/plugin_builder.dart';
import 'package:plugin_runtime/plugin_runtime.dart';
import 'package:session_evaluator_contract/session_evaluator_contract.dart';
import 'package:sqlite3/sqlite3.dart' hide Session;

import '../../tool/session_evidence_exporter.dart';
import '../support/project_provider.dart';

const _chatPlugin = 'dev.adele.plugin.chat-strategy';
const _evaluatorPlugin = 'dev.adele.plugin.session-evaluator';
const _instructions = 'Preserve exact evidence; use the deterministic fixture.';
const _opaque = 'opaque-native-payload-must-not-be-exported';
final _environmentProvider = ProviderId('dev.adele.test.evidence-environment');

void main() {
  late Directory artifacts;
  late String aotRuntime;
  late File hostArtifact;
  late Directory installations;
  late Directory evaluatorOnly;
  late Directory source;
  late AdeleRuntime runtime;
  late Project project;
  late TaskCreationResult task;
  late Session session;
  late ChatSessionServiceClient chat;
  late SessionEvaluatorServiceClient evaluator;

  setUpAll(() async {
    artifacts = await Directory.systemTemp.createTemp('adele-evidence-aot-');
    addTearDown(() => artifacts.delete(recursive: true));
    final dart =
        '${Platform.environment['FLUTTER_ROOT']!}/bin/cache/dart-sdk/bin/dart';
    aotRuntime = File(dart).parent.uri.resolve('dartaotruntime').toFilePath();
    hostArtifact = File('${artifacts.path}/host.aot');
    for (final entry in const {
      'host': 'packages/plugin_backend_host/bin/adele_backend_host.dart',
      _chatPlugin:
          'plugins/chat_strategy/packages/backend/bin/chat_strategy_backend.dart',
      _evaluatorPlugin:
          'plugins/session_evaluator/packages/backend/bin/session_evaluator_backend.dart',
    }.entries) {
      await compileAotSnapshot(
        dartExecutable: dart,
        workingDirectory: Directory.current.parent,
        entrypoint: entry.value,
        artifact: File('${artifacts.path}/${entry.key}.aot'),
        stage: 'session-evaluator-${entry.key}',
      );
    }
    // Explicit test installations, independent of stock preparation/startup.
    installations = await _install(artifacts, 'initial', [
      _chatPlugin,
      _evaluatorPlugin,
    ]);
    evaluatorOnly = await _install(artifacts, 'replacement', [
      _evaluatorPlugin,
    ]);
  });

  Future<void> start(
    ApplicationPluginBootstrap bootstrap,
    Directory root,
  ) async {
    await bootstrap.start(
      installationRoot: root.path,
      dartaotruntimeExecutable: aotRuntime,
      hostArtifactPath: hostArtifact.path,
    );
    expect(bootstrap.state, ApplicationPluginState.ready);
    expect(bootstrap.failure, isNull);
    expect(bootstrap.catalog!.issues, isEmpty);
    for (final backend in bootstrap.backends) {
      expect(
        backend.state,
        InstalledBackendState.active,
        reason: '${backend.failure}',
      );
    }
  }

  setUp(() async {
    source = await Directory.systemTemp.createTemp('adele-evidence-project-');
    addTearDown(() => source.delete(recursive: true));
    runtime = AdeleRuntime(ids: MonotonicProductIdSource(seed: 'evidence'));
    addTearDown(runtime.close);
    final provider = TestProjectProvider(runtime.registry);
    addTearDown(provider.close);
    final environment = runtime.registry.register(
      provider: ProviderDescriptor(
        id: _environmentProvider,
        capability: environmentProviderCapability,
        pluginId: 'dev.adele.test.environment',
        displayName: 'Deterministic Environment',
        serviceId: environmentProviderServiceId,
      ),
      endpoint: AdeleRequestChannelEndpoint(
        channel: _EnvironmentChannel(),
        serviceId: environmentProviderServiceId,
        isAvailable: () => true,
      ),
    );
    addTearDown(environment.close);
    await start(runtime.plugins, installations);
    final connection = _connection(runtime.plugins, _evaluatorPlugin);
    expect(connection.capabilityExposures, isEmpty);
    expect(connection.extensionExposures, isEmpty);
    evaluator = _client(connection);
    chat = ChatSessionServiceClient(
      _connection(runtime.plugins, _chatPlugin).channelFor(
        _connection(runtime.plugins, _chatPlugin).defaultConfigurationContext,
        chatSessionServiceId,
      ),
    );
    project = await runtime.lifecycle.openProject(
      sourceLocation: source.uri,
      provider: runtime.lifecycle.resolveProjectProvider(testProjectProviderId),
    );
    task = await runtime.lifecycle.createTask(
      projectId: project.id,
      title: 'Session evidence fixture',
      providerId: _environmentProvider,
    );
    session = runtime.lifecycle.createSession(
      taskId: task.task.id,
      strategyId: chatStrategyId,
    );
  });

  Session otherSession() => runtime.lifecycle.createSession(
    taskId: task.task.id,
    strategyId: chatStrategyId,
  );

  Future<SessionOrchestrationRun> createRun(
    Session owner,
    String id,
    _Model model, {
    ToolPolicyDecision decision = ToolPolicyDecision.allow,
    ToolId? toolId,
    _Tool? tool,
  }) async {
    final run = await createSessionOrchestrationRun(
      lifecycle: runtime.lifecycle,
      sessionId: owner.id,
      runId: RunId(id),
      contextComposer: runtime.contextComposer,
      model: model,
      toolCatalog: ToolCatalog()
        ..register(
          ToolRegistration(
            definition: ToolDefinition(
              id: toolId ?? ToolId('dev.adele.test.evidence-tool'),
              description: 'Deterministic evidence tool',
            ),
            modelDefinition: ModelToolDefinition(
              alias: 'evidence_tool',
              description: 'Deterministic evidence tool',
              argumentsSchema: const {},
            ),
            executable: tool ?? _Tool(),
          ),
        ),
      policy: _Policy(decision),
    );
    addTearDown(run.close);
    return run;
  }

  Future<Map<String, Object?>> collect(Session owner) =>
      readSessionEvidence(evaluator, owner.id.value);

  test(
    'invalid Session IDs retain their declared failure across AOT transport',
    () async {
      final before = _inspect(source, _snapshot);
      final canonicalId = session.id.value;
      for (final sessionId in [
        '',
        ' \t\n',
        ' $canonicalId',
        '$canonicalId ',
        '\t$canonicalId',
        '$canonicalId\t',
        '\n$canonicalId',
        '$canonicalId\n',
      ]) {
        await expectLater(
          readSessionEvidence(evaluator, sessionId),
          throwsA(
            isA<SessionEvidenceFailure>().having(
              (failure) => failure.code,
              'code',
              'invalid_session',
            ),
          ),
        );
      }
      final document = await collect(session);
      expect(_map(document['identity'])['session_id'], canonicalId);
      expect(_inspect(source, _snapshot), before);
    },
  );

  test('exports source-valid padded ToolId and deep tool values from a '
      'normally retained failed Chat Run without writes', () async {
    Map<String, Object?> nested = {'value': 7};
    for (var depth = 0; depth < 80; depth++) {
      nested = {'nested': nested};
    }
    final toolId = ToolId(' \tdev.adele.test.evidence-tool\n ');
    final canonicalArguments = CanonicalToolArguments({'normalized': nested});
    final hostData = {'result': nested};
    await chat.appendUserMessage(session.id.value, 'Retain deep tool values.');
    final model = _Model(
      'Not reached after transport failure.',
      withTools: true,
    );
    final run = await createRun(
      session,
      'deep-tool-run',
      model,
      toolId: toolId,
      tool: _Tool(canonicalArguments: canonicalArguments, hostData: hostData),
    );
    // Chat's reverse transport has a separate depth bound. The successful tool
    // outcome is journaled before that transport fails and the Run is retained.
    await expectLater(
      run.start(),
      throwsA(
        isA<PluginRemoteFailure>().having(
          (failure) => failure.code,
          'code',
          'internal_error',
        ),
      ),
    );
    expect(run.run.state, RunState.failed);
    expect(model.calls, 1);
    expect(runtime.store.runRecord(run.run.id)!.state, RunTerminalState.failed);
    final before = _inspect(source, _snapshot);
    final document = await collect(session);
    expect(document['identity'], {
      'session_id': session.id.value,
      'task_id': task.task.id.value,
      'project_id': project.id.value,
      'source_location': project.sourceLocation.toString(),
      'task_title': task.task.title,
      'strategy_id': chatStrategyId.value,
      'environment_id': task.environment.id.value,
      'environment_task_id': task.task.id.value,
      'environment_role': 'primary',
      'environment_provider_id': _environmentProvider.value,
    });
    final retained = _maps(document['runs']).single;
    expect(retained['id'], run.run.id.value);
    expect(retained['session_id'], session.id.value);
    expect(retained['terminal_state'], 'failed');
    final evidence = _map(retained['evidence']);
    expect(
      evidence,
      _inspect(source, (database) => _evidence(database, run.run.id.value)),
    );
    final tool = _maps(evidence['tool_invocations']).single;
    expect(tool['tool_id'], toolId.value);
    expect(
      tool['canonical_arguments_json'],
      jsonEncode(canonicalArguments.snapshot),
    );
    final outcome = _maps(evidence['tool_changes']).last;
    expect(outcome['tool_invocation_id'], tool['invocation_id']);
    expect(outcome['outcome_disposition'], 'success');
    expect(outcome['host_data_json'], jsonEncode(hostData));
    // Deep canonical arguments come from normalization, not the bounded proposal.
    expect(
      _maps(evidence['model_outputs']).singleWhere(
        (row) => row['sequence'] == tool['proposal_sequence'],
      )['arguments_json'],
      jsonEncode({'value': 7}),
    );
    expect(_map(document['coverage'])['status'], 'complete_retained_evidence');
    expect(_inspect(source, _snapshot), before);
  });

  test('exports exact retained Chat and Run evidence, isolates Sessions, and '
      'does not retarget a retired generated route', () async {
    await chat.configureSession(session.id.value, _instructions, 4);
    await chat.appendUserMessage(session.id.value, '  First question.\n');
    final first = await createRun(
      session,
      'z-first-run',
      _Model('First answer.', withTools: true),
    );
    await first.start();
    expect(first.run.state, RunState.completed);
    await chat.appendUserMessage(session.id.value, 'Second question.');
    final second = await createRun(
      session,
      'a-second-run',
      _Model('Second answer.'),
    );
    await second.start();
    expect(second.run.state, RunState.completed);
    await chat.setDraftRequest(
      session.id.value,
      'Unsubmitted draft is not Chat.',
    );

    final other = otherSession();
    await chat.appendUserMessage(other.id.value, 'OTHER-SESSION-QUESTION');
    final otherRun = await createRun(
      other,
      'other-run',
      _Model('OTHER-SESSION-ANSWER'),
    );
    await otherRun.start();
    final before = _inspect(source, _snapshot);
    final document = await collect(session);
    expect(document['schema'], 'dev.adele.session-evidence.v1');
    expect(document['identity'], {
      'session_id': session.id.value,
      'task_id': task.task.id.value,
      'project_id': project.id.value,
      'source_location': project.sourceLocation.toString(),
      'task_title': task.task.title,
      'strategy_id': chatStrategyId.value,
      'environment_id': task.environment.id.value,
      'environment_task_id': task.task.id.value,
      'environment_role': 'primary',
      'environment_provider_id': _environmentProvider.value,
    });
    final conversation = _map(document['conversation']);
    expect(conversation['status'], 'available');
    expect(conversation['configuration'], {
      'instructions': _instructions,
      'max_model_invocations': 4,
      'next_entry': 4,
    });
    expect(
      conversation['entries'],
      _inspect(
        source,
        (database) => _rows(
          database,
          'SELECT * FROM adele_chat_entries WHERE session_id = ? ORDER BY sequence',
          [session.id.value],
        ),
      ),
    );
    final entries = _maps(conversation['entries']);
    expect(entries.map((row) => (row['role'], row['content'], row['run_id'])), [
      ('user', '  First question.\n', first.run.id.value),
      ('assistant', 'First answer.', null),
      ('user', 'Second question.', second.run.id.value),
      ('assistant', 'Second answer.', null),
    ]);
    final runs = _maps(document['runs']);
    expect(runs.map((row) => row['id']), ['a-second-run', 'z-first-run']);
    for (final run in runs) {
      expect(run['session_id'], session.id.value);
      expect(run['terminal_state'], 'completed');
      expect(
        run['evidence'],
        _inspect(
          source,
          (database) => _evidence(database, run['id']! as String),
        ),
      );
    }
    final evidence = _map(runs.last['evidence']);
    final models = _maps(evidence['model_invocations']);
    expect(models, hasLength(2));
    expect(models.first['usage_present'], 1);
    expect(models.first['input_tokens'], 0);
    expect(models.first['output_tokens'], isNull);
    expect(models.first['cache_read_tokens'], 0);
    expect(models.first['cache_write_tokens'], isNull);
    expect(models.last['usage_present'], 0);
    expect(models.last['input_tokens'], isNull);
    final tools = _maps(evidence['tool_invocations']);
    expect(tools, hasLength(1));
    final outputs = _maps(evidence['model_outputs']);
    final proposal = outputs.singleWhere(
      (row) => row['sequence'] == tools.single['proposal_sequence'],
    );
    expect(proposal['kind'], 'toolProposal');
    expect(
      proposal['model_invocation_id'],
      tools.single['model_invocation_id'],
    );
    expect(proposal['provider_call_id'], tools.single['provider_call_id']);
    expect(jsonDecode(tools.single['canonical_arguments_json']! as String), {
      'value': 7,
    });
    expect(
      _maps(evidence['tool_changes']).last['outcome_disposition'],
      'success',
    );
    expect(_maps(evidence['rejected_proposals']), hasLength(1));
    expect(
      outputs.singleWhere(
        (row) => row['kind'] == 'native',
      )['presentation_compact_text'],
      'Safe native summary',
    );
    final coverage = _map(document['coverage']);
    expect(coverage['status'], 'complete_retained_evidence');
    expect(coverage['associated_runs_without_terminal_evidence'], isEmpty);
    expect(coverage['consistency'], 'independent_reads_not_atomic_snapshot');
    expect(coverage['run_order'], 'lexical_id_not_chronology');
    expect(coverage['exclusions'], isNotEmpty);
    expect(coverage['limitations'], isNotEmpty);

    final encoded = jsonEncode(document);
    expect(encoded, isNot(contains(_opaque)));
    expect(encoded, isNot(contains('OTHER-SESSION')));
    expect(encoded, isNot(contains('Unsubmitted draft')));
    // The caller owns the export file; the production collector only streams.
    final export = File('${source.path}/caller-evidence.json');
    await export.writeAsString(encoded);
    expect(jsonDecode(await export.readAsString()), document);
    final isolated = await collect(other);
    expect(_maps(isolated['runs']).single['id'], 'other-run');
    expect(_maps(_map(isolated['conversation'])['entries']), hasLength(2));
    expect(_inspect(source, _snapshot), before);

    final oldConnection = _connection(runtime.plugins, _evaluatorPlugin);
    await runtime.plugins.close();
    expect(oldConnection.isClosed, isTrue);
    await expectLater(collect(session), throwsA(isA<PluginConnectionClosed>()));
    final replacement = ApplicationPluginBootstrap(
      runtime.registry,
      runtime.extensions,
      createInfrastructureServices: (connection) =>
          projectStorageServices(runtime.lifecycle, connection),
    );
    addTearDown(replacement.close);
    await start(replacement, evaluatorOnly);
    final newConnection = _connection(replacement, _evaluatorPlugin);
    expect(newConnection, isNot(same(oldConnection)));
    expect(
      await readSessionEvidence(_client(newConnection), session.id.value),
      document,
    );
    await expectLater(collect(session), throwsA(isA<PluginConnectionClosed>()));
    expect(_inspect(source, _snapshot), before);
  });

  test('distinguishes absent schema, uninitialized Chat, and valid empty Chat '
      'without initializing or mutating storage', () async {
    final absent = _inspect(source, _snapshot);
    final unavailable = await collect(session);
    expect(unavailable['conversation'], {
      'status': 'unavailable',
      'configuration': null,
      'entries': <Object?>[],
    });
    expect(unavailable['runs'], isEmpty);
    expect(_inspect(source, _snapshot), absent);

    final other = otherSession();
    await chat.snapshot(other.id.value);
    final uninitialized = _inspect(source, _snapshot);
    expect((await collect(session))['conversation'], {
      'status': 'uninitialized',
      'configuration': null,
      'entries': <Object?>[],
    });
    expect(_inspect(source, _snapshot), uninitialized);

    final empty = await chat.snapshot(session.id.value);
    final initialized = _inspect(source, _snapshot);
    expect((await collect(session))['conversation'], {
      'status': 'available',
      'configuration': {
        'instructions': empty.instructions,
        'max_model_invocations': empty.maxModelInvocations,
        'next_entry': 0,
      },
      'entries': <Object?>[],
    });
    expect(_inspect(source, _snapshot), initialized);
  });

  for (final waiting in [false, true]) {
    test('${waiting ? 'waiting' : 'unstarted'} Chat association is partial '
        'evidence, not a fabricated terminal Run', () async {
      await chat.appendUserMessage(session.id.value, 'Pending question.');
      final model = _Model('Not yet answered.', withTools: true);
      final run = await createRun(
        session,
        'pending-run',
        model,
        decision: ToolPolicyDecision.ask,
      );
      if (waiting) await run.start();
      expect(run.run.state, waiting ? RunState.waiting : RunState.created);
      expect(model.calls, waiting ? 1 : 0);
      expect(runtime.store.runRecord(run.run.id), isNull);
      final before = _inspect(source, _snapshot);
      final document = await collect(session);
      expect(document['runs'], isEmpty);
      expect(
        _maps(_map(document['conversation'])['entries']).single['run_id'],
        'pending-run',
      );
      final coverage = _map(document['coverage']);
      expect(coverage['status'], 'partial');
      expect(coverage['associated_runs_without_terminal_evidence'], [
        'pending-run',
      ]);
      expect(_inspect(source, _snapshot), before);
      await run.close();
      expect(await collect(session), document);
      expect(_inspect(source, _snapshot), before);
    });
  }

  test('keyset pagination retains over 1000 canonical messages and bounded '
      'stream chunks without truncation', () async {
    // These remain normal Chat writes, not synthetic successful evidence rows.
    final padding = 'x' * 1100;
    for (var index = 0; index < 1005; index++) {
      await chat.appendUserMessage(session.id.value, 'message-$index $padding');
    }
    final before = _inspect(source, _snapshot);
    final chunks = await evaluator.collectSession(session.id.value).toList();
    expect(chunks.length, greaterThan(1));
    expect(
      chunks,
      everyElement(
        predicate<String>(
          (chunk) => chunk.isNotEmpty && chunk.length <= 16 * 1024,
        ),
      ),
    );
    final document = await collect(session);
    expect(jsonDecode(chunks.join()), document);
    expect(utf8.encode(chunks.join()).length, greaterThan(1024 * 1024));
    final entries = _maps(_map(document['conversation'])['entries']);
    expect(entries, hasLength(1005));
    expect(
      entries.map((row) => row['sequence']),
      List.generate(1005, (i) => i),
    );
    expect(entries.last['content'], 'message-1004 $padding');
    expect(_inspect(source, _snapshot), before);
  });

  test('real SQL corruption and query bounds cross generated transport as '
      'declared failures without partial exports or writes', () async {
    await chat.appendUserMessage(
      session.id.value,
      'Persist before corruption.',
    );
    final run = await createRun(session, 'corruption-run', _Model('Retained.'));
    await run.start();

    Future<void> failure(String code) async {
      final before = _inspect(source, _snapshot);
      final emitted = <String>[];
      await expectLater(
        evaluator.collectSession(session.id.value).forEach(emitted.add),
        throwsA(
          isA<SessionEvidenceFailure>().having(
            (failure) => failure.code,
            'code',
            code,
          ),
        ),
      );
      expect(emitted, isEmpty);
      expect(_inspect(source, _snapshot), before);
    }

    final original = _inspect(source, _snapshot);
    final validDocument = await collect(session);
    for (final (sql, invalidValue, originalValue, id) in [
      (
        'UPDATE adele_product_sessions SET strategy_id = ? WHERE id = ?',
        ' ${chatStrategyId.value} ',
        chatStrategyId.value,
        session.id.value,
      ),
      (
        'UPDATE adele_product_environments SET provider_id = ? WHERE id = ?',
        'invalid provider id',
        _environmentProvider.value,
        task.environment.id.value,
      ),
    ]) {
      _inspect(
        source,
        (database) => database.execute(sql, [invalidValue, id]),
        write: true,
      );
      await failure('malformed_data');
      _inspect(
        source,
        (database) => database.execute(sql, [originalValue, id]),
        write: true,
      );
      expect(await collect(session), validDocument);
      expect(_inspect(source, _snapshot), original);
    }

    _inspect(
      source,
      (database) => database.execute(
        "UPDATE adele_schema_versions SET version = 99 WHERE owner_id = ?",
        [_chatPlugin],
      ),
      write: true,
    );
    await failure('incompatible_schema');
    _inspect(
      source,
      (database) => database.execute(
        'UPDATE adele_schema_versions SET version = 1 WHERE owner_id = ?',
        [_chatPlugin],
      ),
      write: true,
    );

    _inspect(
      source,
      (database) => database.execute(
        'UPDATE adele_execution_model_invocations '
        "SET usage_provider_details_json = 'not-json' WHERE run_id = ?",
        [run.run.id.value],
      ),
      write: true,
    );
    await failure('malformed_data');
    _inspect(
      source,
      (database) => database.execute(
        'UPDATE adele_execution_model_invocations '
        'SET usage_provider_details_json = NULL WHERE run_id = ?',
        [run.run.id.value],
      ),
      write: true,
    );

    _inspect(
      source,
      (database) => database.execute(
        'UPDATE adele_chat_entries SET content = ? WHERE session_id = ? AND sequence = 0',
        ['x' * (1024 * 1024 + 1), session.id.value],
      ),
      write: true,
    );
    await failure('storage_query_failed');
    _inspect(
      source,
      (database) => database.execute(
        'UPDATE adele_chat_entries SET content = ? WHERE session_id = ? AND sequence = 0',
        ['Persist before corruption.', session.id.value],
      ),
      write: true,
    );

    _inspect(
      source,
      (database) => database.execute(
        'DELETE FROM adele_execution_run_activity WHERE run_id = ?',
        [run.run.id.value],
      ),
      write: true,
    );
    await failure('malformed_data');
    await expectLater(
      readSessionEvidence(evaluator, 'unknown-session'),
      throwsA(
        isA<SessionEvidenceFailure>().having(
          (failure) => failure.code,
          'code',
          'storage_query_failed',
        ),
      ),
    );
  });

  group('native evidence export', () {
    late WindowSessionContextHost window;
    late GlobalKey<NavigatorState> navigatorKey;
    late SessionEvidenceExporter exporter;
    late CommandResolver commands;
    late AdeleRuntime mountedRuntime;
    late _SavePicker picker;
    late Future<void> exporting;
    late Future<ResolvedCommand?> paletteSelection;

    setUp(() {
      window = WindowSessionContextHost();
      addTearDown(window.close);
      navigatorKey = GlobalKey<NavigatorState>();
      final original = FileSelectorPlatform.instance;
      FileSelectorPlatform.instance = picker = _SavePicker();
      addTearDown(() => FileSelectorPlatform.instance = original);
    });

    Future<void> mount(WidgetTester tester, {AdeleRuntime? owner}) async {
      final host = mountedRuntime = owner ?? runtime;
      exporter = SessionEvidenceExporter(
        runtime: host,
        context: window.context,
        navigatorKey: navigatorKey,
      );
      commands = CommandResolver(host.extensions);
      addTearDown(exporter.close);
      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: navigatorKey,
          home: const Scaffold(body: SizedBox.shrink()),
        ),
      );
    }

    Future<AdeleRuntime> reopenRuntime(WidgetTester tester) async {
      final fresh = AdeleRuntime();
      addTearDown(fresh.close);
      final provider = TestProjectProvider(fresh.registry);
      addTearDown(provider.close);
      await tester.runAsync(() async {
        await fresh.lifecycle.openProject(
          sourceLocation: source.uri,
          provider: fresh.lifecycle.resolveProjectProvider(
            testProjectProviderId,
          ),
        );
      });
      window.presentSession(fresh.store.session(session.id)!);
      return fresh;
    }

    Future<void> openPalette(WidgetTester tester) async {
      await tester.runAsync(() async {
        paletteSelection = showDialog<ResolvedCommand>(
          context: navigatorKey.currentContext!,
          builder: (_) => CommandPalette(
            extensions: mountedRuntime.extensions,
            isInteractive: () => true,
          ),
        );
      });
      await tester.pumpAndSettle();
    }

    Future<void> invoke(WidgetTester tester) async {
      // AOT I/O and its continuations use real async; only UI animation is fake.
      await tester.runAsync(() async {
        exporting = commands.resolve(exportSessionEvidenceCommandId).invoke();
      });
      await tester.pumpAndSettle();
      expect(find.text('Export Session Evidence'), findsOneWidget);
    }

    Future<void> continueExport(WidgetTester tester) async {
      await tester.tap(find.text('Continue'));
      await tester.pumpAndSettle();
      await tester.runAsync(
        () => picker.opened.future.timeout(const Duration(seconds: 10)),
      );
    }

    Future<void> finish(WidgetTester tester) async {
      await tester.runAsync(
        () => exporting.timeout(const Duration(seconds: 20)),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    }

    void expectNoFeedback() {
      expect(find.text('Session evidence exported.'), findsNothing);
      expect(
        find.text('Session evidence could not be exported.'),
        findsNothing,
      );
    }

    void expectNoStaging() {
      expect(
        source.listSync().where(
          (entry) => entry.uri.pathSegments.any(
            (segment) => segment.startsWith('.adele-session-evidence-'),
          ),
        ),
        isEmpty,
      );
    }

    testWidgets('palette exports the exact E1 document from retained Chat/Run '
        'without collecting a draft or changing storage', (tester) async {
      final model = _Model('Exact retained answer.', withTools: true);
      late Map<String, Object?> expected;
      await tester.runAsync(() async {
        await chat.configureSession(session.id.value, _instructions, 4);
        await chat.appendUserMessage(session.id.value, '  Exact question.\n');
        final run = await createRun(session, 'native-export-run', model);
        await run.start();
        expect(run.run.state, RunState.completed);
        await chat.setDraftRequest(
          session.id.value,
          'Unsubmitted private draft',
        );
        final other = otherSession();
        await chat.appendUserMessage(other.id.value, 'OTHER-SESSION');
        expected = await collect(session);
      });
      final before = _inspect(source, _snapshot);
      final destination = File('${source.path}/chosen-evidence.json')
        ..writeAsStringSync('previous destination');
      picker.pick = () async => FileSaveLocation(destination.path);
      window.presentSession(session);
      await mount(tester);
      await openPalette(tester);
      expect(find.text('Export Session Evidence...'), findsOneWidget);
      await tester.tap(find.text('Export Session Evidence...'));
      await tester.pumpAndSettle();
      await tester.runAsync(() async {
        final command = await paletteSelection;
        expect(command!.id, exportSessionEvidenceCommandId);
        exporting = command.invoke();
      });
      await tester.pumpAndSettle();
      expect(find.byType(CommandPalette), findsNothing);
      expect(find.text('Export Session Evidence'), findsOneWidget);
      expect(find.textContaining('potentially sensitive'), findsOneWidget);
      expect(picker.calls, 0);
      expect(destination.readAsStringSync(), 'previous destination');

      await continueExport(tester);
      await finish(tester);
      expect(picker.calls, 1);
      expect(picker.options!.suggestedName, 'session-evidence.json');
      expect(picker.typeGroups!.single.extensions, ['json']);
      expect(destination.readAsStringSync(), jsonEncode(expected));
      expect(expected['schema'], 'dev.adele.session-evidence.v1');
      expect(
        _map(expected['coverage'])['status'],
        'complete_retained_evidence',
      );
      final encoded = destination.readAsStringSync();
      expect(encoded, isNot(contains(_opaque)));
      expect(encoded, isNot(contains('OTHER-SESSION')));
      expect(encoded, isNot(contains('Unsubmitted private draft')));
      expect(model.calls, 2);
      expect(_inspect(source, _snapshot), before);
      expectNoStaging();
      expect(find.text('Session evidence exported.'), findsOneWidget);
      expect(
        find.text('Session evidence could not be exported.'),
        findsNothing,
      );
    });

    testWidgets('no Session is hidden; confirmation and save cancellation are '
        'silent and reject duplicate pending admission', (tester) async {
      final before = _inspect(source, _snapshot);
      await mount(tester);
      final command = commands.resolve(exportSessionEvidenceCommandId);
      expect(command.availability, CommandAvailability.hidden);
      await expectLater(command.invoke(), throwsA(isA<CommandUnavailable>()));
      await openPalette(tester);
      expect(find.text('Export Session Evidence...'), findsNothing);
      navigatorKey.currentState!.pop();
      await tester.pumpAndSettle();

      window.presentSession(session);
      await invoke(tester);
      expect(command.availability, CommandAvailability.disabled);
      await expectLater(command.invoke(), throwsA(isA<CommandUnavailable>()));
      expect(find.byType(AlertDialog), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await finish(tester);
      expect(picker.calls, 0);
      expect(command.availability, CommandAvailability.enabled);
      expectNoFeedback();

      final selection = Completer<FileSaveLocation?>();
      picker.pick = () => selection.future;
      await invoke(tester);
      await continueExport(tester);
      expect(command.availability, CommandAvailability.disabled);
      await expectLater(command.invoke(), throwsA(isA<CommandUnavailable>()));
      expect(picker.calls, 1);
      selection.complete(null);
      await finish(tester);
      expect(command.availability, CommandAvailability.enabled);
      expectNoFeedback();
      expect(_inspect(source, _snapshot), before);
      expectNoStaging();
    });

    testWidgets('captures A before confirmation and picker; B and A reentry '
        'never redirect the export, and a fresh command captures B', (
      tester,
    ) async {
      final other = otherSession();
      late Map<String, Object?> expectedA;
      late Map<String, Object?> expectedB;
      await tester.runAsync(() async {
        await chat.appendUserMessage(session.id.value, 'ONLY-A');
        await chat.appendUserMessage(other.id.value, 'ONLY-B');
        expectedA = await collect(session);
        expectedB = await collect(other);
      });
      final before = _inspect(source, _snapshot);
      final first = File('${source.path}/a.json');
      final second = File('${source.path}/b.json');
      final selection = Completer<FileSaveLocation?>();
      picker.pick = () => selection.future;
      window.presentSession(session);
      final firstRevision = window.context.snapshot.revision;
      await mount(tester);
      await invoke(tester);
      window.presentSession(other);
      await continueExport(tester);
      expect(first.existsSync(), isFalse);
      expect(
        commands.resolve(exportSessionEvidenceCommandId).availability,
        CommandAvailability.disabled,
      );
      window.presentSession(session);
      expect(window.context.snapshot.revision, firstRevision + 2);
      selection.complete(FileSaveLocation(first.path));
      await finish(tester);
      expect(jsonDecode(first.readAsStringSync()), expectedA);

      window.presentSession(other);
      picker.pick = () async => FileSaveLocation(second.path);
      await invoke(tester);
      await continueExport(tester);
      await finish(tester);
      expect(jsonDecode(second.readAsStringSync()), expectedB);
      expect(picker.calls, 2);
      expect(_inspect(source, _snapshot), before);
      expectNoStaging();
    });

    testWidgets('exports partial evidence without completing a waiting Run', (
      tester,
    ) async {
      final model = _Model('Not yet answered.', withTools: true);
      late SessionOrchestrationRun run;
      late Map<String, Object?> expected;
      await tester.runAsync(() async {
        await chat.appendUserMessage(session.id.value, 'Pending question.');
        run = await createRun(
          session,
          'native-pending-run',
          model,
          decision: ToolPolicyDecision.ask,
        );
        await run.start();
        expected = await collect(session);
      });
      final before = _inspect(source, _snapshot);
      final destination = File('${source.path}/partial.json');
      picker.pick = () async => FileSaveLocation(destination.path);
      window.presentSession(session);
      await mount(tester);
      await invoke(tester);
      await continueExport(tester);
      await finish(tester);
      final document = _map(jsonDecode(destination.readAsStringSync()));
      expect(document, expected);
      expect(document['runs'], isEmpty);
      expect(_map(document['coverage'])['status'], 'partial');
      expect(
        _map(document['coverage'])['associated_runs_without_terminal_evidence'],
        ['native-pending-run'],
      );
      expect(run.run.state, RunState.waiting);
      expect(runtime.store.runRecord(run.run.id), isNull);
      expect(model.calls, 1);
      expect(_inspect(source, _snapshot), before);
      expect(find.text('Session evidence exported.'), findsOneWidget);
      expectNoStaging();
    });

    testWidgets('collection failure keeps an existing destination intact and '
        'shows only safe feedback', (tester) async {
      await tester.runAsync(() async {
        await chat.appendUserMessage(
          session.id.value,
          'Retained before damage.',
        );
        final run = await createRun(
          session,
          'native-failure-run',
          _Model('Answer'),
        );
        await run.start();
      });
      _inspect(
        source,
        (database) => database.execute(
          "UPDATE adele_execution_model_invocations "
          "SET usage_provider_details_json = 'private-invalid-json'",
        ),
        write: true,
      );
      final before = _inspect(source, _snapshot);
      final destination = File('${source.path}/existing.json')
        ..writeAsStringSync('existing destination must survive');
      picker.pick = () async => FileSaveLocation(destination.path);
      window.presentSession(session);
      await mount(tester);
      await invoke(tester);
      await continueExport(tester);
      await finish(tester);
      expect(
        destination.readAsStringSync(),
        'existing destination must survive',
      );
      expect(_inspect(source, _snapshot), before);
      expectNoStaging();
      expect(
        find.text('Session evidence could not be exported.'),
        findsOneWidget,
      );
      expect(find.text('Session evidence exported.'), findsNothing);
      expect(find.textContaining('private-invalid-json'), findsNothing);
      expect(find.textContaining('SessionEvidenceFailure'), findsNothing);
      expect(
        commands.resolve(exportSessionEvidenceCommandId).availability,
        CommandAvailability.enabled,
      );
    });

    testWidgets('write failure preserves a nonempty destination directory and '
        'reports failure without exposing its path', (tester) async {
      await tester.runAsync(() async {
        await chat.appendUserMessage(
          session.id.value,
          'Valid retained evidence.',
        );
        expect(
          _map((await collect(session))['coverage'])['status'],
          'complete_retained_evidence',
        );
      });
      final before = _inspect(source, _snapshot);
      final destination = Directory('${source.path}/private-save-target')
        ..createSync();
      final existing = File('${destination.path}/keep.txt')
        ..writeAsStringSync('existing directory contents');
      picker.pick = () async => FileSaveLocation(destination.path);
      window.presentSession(session);
      await mount(tester);
      await invoke(tester);
      await continueExport(tester);
      await finish(tester);
      expect(destination.existsSync(), isTrue);
      expect(existing.readAsStringSync(), 'existing directory contents');
      expect(destination.listSync(), hasLength(1));
      expect(_inspect(source, _snapshot), before);
      expectNoStaging();
      expect(
        find.text('Session evidence could not be exported.'),
        findsOneWidget,
      );
      expect(find.text('Session evidence exported.'), findsNothing);
      expect(find.textContaining('private-save-target'), findsNothing);
      expect(find.textContaining('FileSystemException'), findsNothing);
      expect(
        commands.resolve(exportSessionEvidenceCommandId).availability,
        CommandAvailability.enabled,
      );
    });

    for (final closeExporter in [false, true]) {
      testWidgets('${closeExporter ? 'closing exporter' : 'retiring backend'} '
          'while the native picker is pending fences publication', (
        tester,
      ) async {
        final before = _inspect(source, _snapshot);
        final destination = File('${source.path}/pending.json')
          ..writeAsStringSync('untouched destination');
        final selection = Completer<FileSaveLocation?>();
        picker.pick = () => selection.future;
        window.presentSession(session);
        await mount(tester);
        final command = commands.resolve(exportSessionEvidenceCommandId);
        await invoke(tester);
        await continueExport(tester);
        await tester.runAsync(() async {
          await (closeExporter ? exporter.close() : runtime.plugins.close())
              .timeout(const Duration(seconds: 10));
        });
        expect(selection.isCompleted, isFalse);
        expect(
          () => commands.resolve(exportSessionEvidenceCommandId),
          throwsA(isA<CommandNotFound>()),
        );
        await expectLater(
          command.invoke(),
          throwsA(isA<StaleExtensionBinding>()),
        );
        selection.complete(FileSaveLocation(destination.path));
        await finish(tester);
        expect(destination.readAsStringSync(), 'untouched destination');
        expect(_inspect(source, _snapshot), before);
        expect(picker.calls, 1);
        expectNoStaging();
        if (closeExporter) {
          expectNoFeedback();
          // The cached close Future belongs to the real-async zone too.
          await tester.runAsync(
            () => exporter.close().timeout(const Duration(seconds: 10)),
          );
        } else {
          expect(
            find.text('Session evidence could not be exported.'),
            findsOneWidget,
          );
        }
      });
    }

    testWidgets('close dismisses its confirmation without opening the picker', (
      tester,
    ) async {
      window.presentSession(session);
      await mount(tester);
      await invoke(tester);
      await tester.runAsync(exporter.close);
      await finish(tester);
      expect(find.byType(AlertDialog), findsNothing);
      expect(picker.calls, 0);
      expectNoFeedback();
      expect(commands.discover(), isEmpty);
    });

    for (final failed in [false, true]) {
      testWidgets('${failed ? 'failed' : 'absent'} evaluator startup leaves '
          'no export Command even with a canonical Session', (tester) async {
        final fresh = await reopenRuntime(tester);
        await mount(tester, owner: fresh);
        await openPalette(tester);
        expect(commands.discover(), isEmpty);
        await tester.runAsync(() async {
          if (failed) {
            final broken = await _install(artifacts, 'failed-evaluator', [
              _chatPlugin,
              _evaluatorPlugin,
            ]);
            await File(
              '${broken.path}/$_evaluatorPlugin/backend.aot',
            ).writeAsString('invalid evaluator artifact');
            await fresh.plugins.start(
              installationRoot: broken.path,
              dartaotruntimeExecutable: aotRuntime,
              hostArtifactPath: hostArtifact.path,
            );
            expect(fresh.plugins.state, ApplicationPluginState.ready);
            expect(
              fresh.plugins.backends
                  .singleWhere(
                    (backend) =>
                        backend.installation.metadata.id.value ==
                        _evaluatorPlugin,
                  )
                  .state,
              InstalledBackendState.failed,
            );
            expect(_connection(fresh.plugins, _chatPlugin).isClosed, isFalse);
          } else {
            await fresh.plugins.start(installationRoot: '');
            expect(fresh.plugins.state, ApplicationPluginState.ready);
            expect(fresh.plugins.backends, isEmpty);
          }
        });
        await tester.pumpAndSettle();
        expect(fresh.extensions.discover(commandContributions), isEmpty);
        expect(
          () => commands.resolve(exportSessionEvidenceCommandId),
          throwsA(isA<CommandNotFound>()),
        );
        expect(find.byType(CommandPalette), findsOneWidget);
        expect(find.text('Export Session Evidence...'), findsNothing);
        expect(picker.calls, 0);
        expectNoFeedback();
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('startup and retirement refresh the open palette without '
        'duplicating or retargeting a Command', (tester) async {
      final fresh = await reopenRuntime(tester);
      await mount(tester, owner: fresh);
      expect(commands.discover(), isEmpty);
      await openPalette(tester);
      expect(find.text('Export Session Evidence...'), findsNothing);
      await tester.runAsync(() => start(fresh.plugins, installations));
      await tester.pumpAndSettle();
      final command = commands.resolve(exportSessionEvidenceCommandId);
      expect(command.availability, CommandAvailability.enabled);
      expect(fresh.extensions.discover(commandContributions), hasLength(1));
      expect(find.text('Export Session Evidence...'), findsOneWidget);

      await tester.runAsync(() async {
        final retired = fresh.plugins.changes.firstWhere(
          (_) =>
              fresh.plugins.backends
                  .singleWhere(
                    (item) =>
                        item.installation.metadata.id.value == _chatPlugin,
                  )
                  .state ==
              InstalledBackendState.terminated,
        );
        await _connection(fresh.plugins, _chatPlugin).close();
        await retired.timeout(const Duration(seconds: 10));
      });
      await tester.pumpAndSettle();
      expect(fresh.extensions.discover(commandContributions), hasLength(1));
      expect(
        commands
            .resolve(exportSessionEvidenceCommandId)
            .binding
            .isSameRegistration(command.binding),
        isTrue,
      );
      expect(find.text('Export Session Evidence...'), findsOneWidget);
      await tester.runAsync(fresh.plugins.close);
      await tester.pumpAndSettle();
      expect(find.byType(CommandPalette), findsOneWidget);
      expect(find.text('Export Session Evidence...'), findsNothing);
      expect(fresh.extensions.discover(commandContributions), isEmpty);
      await expectLater(
        command.invoke(),
        throwsA(isA<StaleExtensionBinding>()),
      );
      expect(tester.takeException(), isNull);
    });
  });
}

final class _SavePicker extends FileSelectorPlatform {
  int calls = 0;
  final opened = Completer<void>();
  SaveDialogOptions? options;
  List<XTypeGroup>? typeGroups;
  Future<FileSaveLocation?> Function() pick = () async => null;

  @override
  Future<FileSaveLocation?> getSaveLocation({
    List<XTypeGroup>? acceptedTypeGroups,
    SaveDialogOptions options = const SaveDialogOptions(),
  }) {
    calls++;
    this.options = options;
    typeGroups = acceptedTypeGroups;
    if (!opened.isCompleted) opened.complete();
    return pick();
  }
}

Future<Directory> _install(
  Directory artifacts,
  String name,
  List<String> plugins,
) async {
  final root = await Directory('${artifacts.path}/$name').create();
  for (final plugin in plugins) {
    final directory = await Directory('${root.path}/$plugin').create();
    await File(
      '${artifacts.path}/$plugin.aot',
    ).copy('${directory.path}/backend.aot');
    await File(
      '${directory.path}/adele_plugin.installation.json',
    ).writeAsString(
      jsonEncode({
        'manifestVersion': 1,
        'metadata': {'id': plugin, 'version': '1', 'displayName': plugin},
        'components': {
          'backend': {'artifact': 'backend.aot'},
        },
      }),
    );
  }
  return root;
}

PluginBackendConnection _connection(
  ApplicationPluginBootstrap bootstrap,
  String id,
) => bootstrap.backends
    .singleWhere((backend) => backend.installation.metadata.id.value == id)
    .connection!;

SessionEvaluatorServiceClient _client(PluginBackendConnection connection) =>
    SessionEvaluatorServiceClient(
      connection.channelFor(
        connection.defaultConfigurationContext,
        sessionEvaluatorServiceId,
      ),
    );

Map<String, Object?> _map(Object? value) =>
    Map<String, Object?>.from(value! as Map);
List<Map<String, Object?>> _maps(Object? value) =>
    (value! as List).map(_map).toList();

T _inspect<T>(
  Directory source,
  T Function(Database) inspect, {
  bool write = false,
}) {
  final database = sqlite3.open(
    '${source.path}/${TestProjectProvider.databaseRelativePath}',
    mode: write ? OpenMode.readWrite : OpenMode.readOnly,
  );
  try {
    return inspect(database);
  } finally {
    database.close();
  }
}

List<Map<String, Object?>> _rows(
  Database database,
  String sql, [
  List<Object?> parameters = const [],
]) => [
  for (final row in database.select(sql, parameters))
    Map<String, Object?>.from(row),
];

Map<String, Object?> _snapshot(Database database) => {
  'schema': _rows(database, 'SELECT * FROM sqlite_master ORDER BY name'),
  for (final row in database.select(
    "SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name",
  ))
    row['name']! as String: _rows(
      database,
      'SELECT * FROM ${row['name']} ORDER BY 1, 2',
    ),
};

Map<String, Object?> _evidence(Database database, String runId) {
  List<Map<String, Object?>> rows(String table, String order) => [
    for (final row in _rows(
      database,
      'SELECT * FROM adele_execution_$table WHERE run_id = ? ORDER BY $order',
      [runId],
    ))
      Map.of(row)
        ..remove('native_state_compatibility_json')
        ..remove('native_state_data_json')
        ..remove('native_metadata_compatibility_json')
        ..remove('native_metadata_data_json'),
  ];
  return {
    'root': rows('run_activity', 'run_id').single,
    'lifecycle': rows('run_lifecycle', 'sequence'),
    'model_invocations': rows('model_invocations', 'start_sequence'),
    'model_outputs': rows('model_outputs', 'sequence'),
    'tool_invocations': rows('tool_invocations', 'prepared_sequence'),
    'tool_changes': rows('tool_changes', 'sequence'),
    'rejected_proposals': rows('rejected_proposals', 'sequence'),
  };
}

final class _EnvironmentChannel implements AdeleRequestChannel {
  @override
  Future<Object?> request(String method, Map<String, Object?> payload) async {
    expect(method, environmentProviderServiceEstablishId);
    return {'providerState': <String, Object?>{}};
  }
}

final class _Policy implements ToolPolicy {
  const _Policy(this.decision);
  final ToolPolicyDecision decision;
  @override
  ToolPolicyDecision evaluate(ToolPolicyInput input) => decision;
}

final class _Model implements ModelPort {
  _Model(this.answer, {this.withTools = false});
  final String answer;
  final bool withTools;
  int calls = 0;

  @override
  Stream<ModelEvent> invoke(SemanticModelRequest request) async* {
    final propose = withTools && ++calls == 1;
    if (!withTools) calls++;
    if (propose) {
      yield ModelObservationEvent(
        invocationId: request.invocationId,
        observation: ModelTextDeltaObservation('not retained as an output'),
      );
      yield ModelOutputItemCompleted(
        invocationId: request.invocationId,
        item: ModelNativeOutput(
          providerNativeMetadata: ModelNativeEnvelope(
            kind: 'fixture.native',
            compatibility: {'secret': _opaque},
            data: {'opaque': _opaque},
          ),
          presentation: ModelNativePresentation(
            kind: 'fixture.summary',
            compactText: 'Safe native summary',
            data: {'summary': 'Retained presentation'},
          ),
        ),
      );
      for (final alias in ['evidence_tool', 'unknown_tool']) {
        yield ModelOutputItemCompleted(
          invocationId: request.invocationId,
          item: ModelToolProposalOutput(
            ProviderToolProposal(
              providerCallId: 'call-$alias',
              alias: alias,
              arguments: const {'value': 7},
            ),
          ),
        );
      }
    } else {
      yield ModelOutputItemCompleted(
        invocationId: request.invocationId,
        item: ModelTextOutput(answer),
      );
    }
    yield ModelInvocationSettledEvent(
      invocationId: request.invocationId,
      settlement: ModelSettlement.completed,
      metadata: ModelTerminalMetadata(
        effectiveModel: 'deterministic-session-evidence',
        providerResponseId: 'response-$calls',
        usage: propose
            ? ModelUsage(
                inputTokens: 0,
                cacheReadTokens: 0,
                providerDetails: {'knownZero': true},
              )
            : null,
        providerNativeState: propose
            ? ModelNativeEnvelope(
                kind: 'fixture.state',
                compatibility: {'secret': _opaque},
                data: {'opaque': _opaque},
              )
            : null,
      ),
    );
  }
}

final class _Tool implements ToolExecutable {
  _Tool({this.canonicalArguments, this.hostData = const {'value': 7}});

  final CanonicalToolArguments? canonicalArguments;
  final Map<String, Object?> hostData;

  @override
  void validateBinding() {}
  @override
  CanonicalToolArguments validateAndNormalize(Map<String, Object?> arguments) =>
      canonicalArguments ?? CanonicalToolArguments(arguments);
  @override
  Future<EffectDescription> describe(
    CanonicalToolArguments arguments,
    ToolExecutionContext context,
  ) async => EffectDescription(
    effects: const [ToolEffect.resourceInspection],
    targets: const [],
    summary: 'Deterministic read-only fixture',
  );
  @override
  Stream<ToolExecutionEvent> execute(
    CanonicalToolArguments arguments,
    ToolExecutionContext context,
  ) async* {
    yield ToolExecutionProgress(ToolProgress(content: 'Fixture progress'));
    yield ToolExecutionTerminal(
      ToolOutcome(
        disposition: ToolOutcomeDisposition.success,
        effectCertainty: EffectCertainty.knownOccurred,
        modelContent: 'Tool result.',
        hostData: hostData,
      ),
    );
  }
}
