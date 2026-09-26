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
const _draftRequest =
    '  Question after restart:\n\tkeep this partial request...\n  ';
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
    'durable Chat history and draft survive generation replacement and restart, then submit once',
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
      final initial = await chatA.snapshot(session.id.value);
      expect(initial.entries, isEmpty);
      expect(initial.draftRequest, '');
      expect(_inspect(source, _chatRows)['sessions'], [
        {
          'session_id': session.id.value,
          'instructions': initial.instructions,
          'max_model_invocations': initial.maxModelInvocations,
          'next_entry': 0,
          'draft_request': '',
        },
      ]);
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
      expect(first.entries.map((entry) => entry.runId), ['first-run', null]);
      expect(
        runtime.lifecycle.runActivity(firstRun.run.id)!.state,
        RunState.completed,
      );
      await chatA.setDraftRequest(session.id.value, _draftRequest);
      final drafted = await chatA.snapshot(session.id.value);
      expect(_snapshot(drafted), {
        ..._snapshot(first),
        'draftRequest': _draftRequest,
      });
      expect(_inspect(source, _coreRows), coreBefore);
      final firstRows = _inspect(source, _chatRows);
      expect(firstRows['sessions'], [
        {
          'session_id': session.id.value,
          'instructions': _instructions,
          'max_model_invocations': _budget,
          'next_entry': 2,
          'draft_request': _draftRequest,
        },
      ]);
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
        _snapshot(drafted),
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
      expect(saved.draftRequest, _draftRequest);
      _expectHistory(saved, [
        ('user', 'First durable question.'),
        ('assistant', 'First durable answer.'),
        ('user', 'Second durable question.'),
        ('assistant', 'Second durable answer.'),
      ]);
      expect(saved.entries.map((entry) => entry.runId), [
        'first-run',
        null,
        'second-run',
        null,
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
      expect(
        reopenedRuntime.lifecycle
            .runActivitiesForSession(session.id)
            .map(
              (activity) =>
                  (activity.runId.value, activity.sessionId, activity.state),
            ),
        unorderedEquals([
          ('first-run', session.id, RunState.completed),
          ('second-run', session.id, RunState.completed),
        ]),
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
      expect(
        reopenedRuntime.lifecycle.environmentRuntime.currentMaterialization(
          environment.id,
        ),
        isNull,
      );
      // Restoring a draft neither submits it nor starts execution.
      final nextUser = await chat.submitDraftRequest(session.id.value);
      expect(nextUser.id, 'entry-4');
      expect(nextUser.role, 'user');
      expect(nextUser.content, _draftRequest);
      expect(nextUser.runId, isNull);
      final submitted = await chat.snapshot(session.id.value);
      expect(submitted.draftRequest, '');
      _expectHistory(submitted, [
        ('user', 'First durable question.'),
        ('assistant', 'First durable answer.'),
        ('user', 'Second durable question.'),
        ('assistant', 'Second durable answer.'),
        ('user', _draftRequest),
      ]);
      final submittedRows = _inspect(source, _chatRows);
      expect(submittedRows['sessions'], [
        {
          'session_id': session.id.value,
          'instructions': _instructions,
          'max_model_invocations': _budget,
          'next_entry': 5,
          'draft_request': '',
        },
      ]);
      await expectLater(
        chat.submitDraftRequest(session.id.value),
        throwsA(
          isA<ChatSessionFailure>().having(
            (failure) => failure.code,
            'code',
            'invalid_content',
          ),
        ),
      );
      expect(
        _snapshot(await chat.snapshot(session.id.value)),
        _snapshot(submitted),
      );
      expect(_inspect(source, _chatRows), submittedRows);
      final continuedModel = _Model(submitted, 'Answer after restart.');
      final continued = await _createRun(
        reopenedRuntime,
        session.id,
        'fresh-run',
        continuedModel,
      );
      expect(continuedModel.calls, 0);
      expect(continued.run.state, RunState.created);
      expect(continued.run.journal.records, isEmpty);
      expect(continued.run, isNot(same(secondRun.run)));
      await continued.start();
      expect(continued.run.state, RunState.completed);
      expect(continuedModel.calls, 1);
      final finalSnapshot = await chat.snapshot(session.id.value);
      expect(finalSnapshot.draftRequest, '');
      _expectHistory(finalSnapshot, [
        ('user', 'First durable question.'),
        ('assistant', 'First durable answer.'),
        ('user', 'Second durable question.'),
        ('assistant', 'Second durable answer.'),
        ('user', _draftRequest),
        ('assistant', 'Answer after restart.'),
      ]);
      expect(finalSnapshot.entries.map((entry) => entry.runId), [
        'first-run',
        null,
        'second-run',
        null,
        'fresh-run',
        null,
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
      final finalRows = _inspect(source, _chatRows);
      await fresh.close();
      expect(fresh.host.isClosed, isTrue);
      expect(reactivated.connection.isClosed, isTrue);
      final thirdIds = _NoAllocationIds();
      final third = await start(thirdIds);
      await third.runtime.lifecycle.openProject(
        sourceLocation: source.uri,
        provider: third.runtime.lifecycle.resolveProjectProvider(
          _projectProviderId,
        ),
      );
      expect(_inspect(source, _chatRows), finalRows);
      final thirdGeneration = await third.activate(_chatPluginId);
      final restored = await _chatClient(
        thirdGeneration.connection,
      ).snapshot(session.id.value);
      expect(_snapshot(restored), _snapshot(finalSnapshot));
      expect(restored.draftRequest, '');
      expect(
        restored.entries
            .where((entry) => entry.id == nextUser.id)
            .single
            .content,
        _draftRequest,
      );
      expect(thirdIds.calls, 0);
      expect(
        third.runtime.lifecycle.environmentRuntime.currentMaterialization(
          environment.id,
        ),
        isNull,
      );
      expect(_inspect(source, _coreRows), coreBefore);
      expect(_inspect(source, _chatRows), finalRows);
      await third.close();
      _inspect(source, _expectSchema);
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test(
    'real SQLite rollback preserves Chat cache, rows, and IDs without mutating core identities or associations',
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
      await chat.setDraftRequest(sessionId.value, _draftRequest);
      final before = await chat.snapshot(sessionId.value);
      final rowsBefore = _inspect(source, _chatRows);
      expect(rowsBefore['sessions'], [
        {
          'session_id': sessionId.value,
          'instructions': _instructions,
          'max_model_invocations': _budget,
          'next_entry': 1,
          'draft_request': _draftRequest,
        },
      ]);
      expect(rowsBefore['entries'], [
        {
          'session_id': sessionId.value,
          'sequence': 0,
          'entry_id': 'entry-0',
          'role': 'user',
          'content': 'Retained before failure.',
          'run_id': null,
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
        CREATE TRIGGER reject_chat_draft
        BEFORE UPDATE OF draft_request ON adele_chat_sessions
        WHEN NEW.draft_request <> ''
        BEGIN SELECT RAISE(ABORT, 'durable-chat-draft-failure'); END;
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
        chat.setDraftRequest(sessionId.value, 'Must not replace the draft.'),
        storageFailure,
      );
      expect(
        _snapshot(await chat.snapshot(sessionId.value)),
        _snapshot(before),
      );
      expect(_inspect(source, _chatRows), rowsBefore);
      expect(_inspect(source, _coreRows), coreBefore);

      // Clearing is allowed by the draft trigger; the entry failure must roll
      // back the entire submission, including its draft clear and counter.
      await expectLater(
        chat.submitDraftRequest(sessionId.value),
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
      // Association is its own acknowledged write at materialization; failure of
      // the later assistant INSERT must not erase this initiating occurrence.
      final associated = await chat.snapshot(sessionId.value);
      expect(associated.entries.single.id, before.entries.single.id);
      expect(associated.entries.single.runId, failed.run.id.value);
      final associatedRows = _inspect(source, _chatRows);
      await expectLater(failed.start(), storageFailure);
      // Host execution already completed; the remote caller still sees failure.
      expect(failed.run.state, RunState.completed);
      expect(failed.run.journal.records.last.event, isA<RunCompleted>());
      final completedRecord = runtime.store.runRecord(failed.run.id)!;
      expect(completedRecord.id, failed.run.id);
      expect(completedRecord.sessionId, sessionId);
      expect(completedRecord.state, RunTerminalState.completed);
      expect(runtime.store.runsForSession(sessionId), [same(completedRecord)]);
      final completedActivity = runtime.lifecycle.runActivity(failed.run.id)!;
      expect(completedActivity.runId, completedRecord.id);
      expect(completedActivity.sessionId, sessionId);
      expect(completedActivity.state, RunState.completed);
      expect(completedActivity.failure, isNull);
      expect(completedActivity.lifecycle.last.state, RunState.completed);
      expect(
        completedActivity.models.single.settlement,
        ModelSettlement.completed,
      );
      expect(
        (completedActivity.models.single.outputs.single.item as ModelTextOutput)
            .content,
        'Must not enter durable history.',
      );
      expect(
        _inspect(
          source,
          (database) => _rows(
            database,
            'SELECT run_id, latest_sequence FROM adele_execution_run_activity',
          ),
        ),
        [
          {
            'run_id': failed.run.id.value,
            'latest_sequence': completedActivity.sequence,
          },
        ],
      );
      expect(
        _inspect(
          source,
          (database) => _rows(database, 'SELECT * FROM adele_product_runs'),
        ),
        [
          {
            'id': failed.run.id.value,
            'session_id': sessionId.value,
            'terminal_state': 'completed',
          },
        ],
      );
      expect(
        _snapshot(await chat.snapshot(sessionId.value)),
        _snapshot(associated),
      );
      expect(_inspect(source, _chatRows), associatedRows);
      expect(_inspect(source, _coreRows), coreBefore);

      _inspect(
        source,
        (database) => database.execute('''
          DROP TRIGGER reject_chat_entry;
          DROP TRIGGER reject_chat_configuration;
          DROP TRIGGER reject_chat_draft;
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
      expect(
        (await chat.snapshot(sessionId.value)).draftRequest,
        _draftRequest,
      );
      final accepted = await chat.submitDraftRequest(sessionId.value);
      expect(accepted.id, 'entry-2');
      expect(accepted.role, 'user');
      expect(accepted.content, _draftRequest);
      final recovered = await chat.snapshot(sessionId.value);
      expect(recovered.draftRequest, '');
      _expectHistory(recovered, [
        ('user', 'Retained before failure.'),
        ('assistant', 'Committed after retry.'),
        ('user', _draftRequest),
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
      await backends.close();
      final ids = _NoAllocationIds();
      final fresh = await start(ids);
      expect(
        fresh.runtime.extensions.discover(orchestrationStrategyContributions),
        isEmpty,
      );
      await fresh.runtime.lifecycle.openProject(
        sourceLocation: source.uri,
        provider: fresh.runtime.lifecycle.resolveProjectProvider(
          _projectProviderId,
        ),
      );
      final restoredRecord = fresh.runtime.store.runRecord(failed.run.id)!;
      expect(restoredRecord, isNot(same(completedRecord)));
      expect(restoredRecord.id, completedRecord.id);
      expect(restoredRecord.sessionId, sessionId);
      expect(restoredRecord.state, RunTerminalState.completed);
      final restoredActivity = fresh.runtime.lifecycle.runActivity(
        failed.run.id,
      )!;
      expect(restoredActivity, isNot(same(completedActivity)));
      expect(restoredActivity.runId, completedRecord.id);
      expect(restoredActivity.sessionId, sessionId);
      expect(restoredActivity.state, RunState.completed);
      expect(restoredActivity.sequence, completedActivity.sequence);
      expect(restoredActivity.failure, isNull);
      expect(
        restoredActivity.lifecycle.map(
          (change) => (change.sequence, change.state),
        ),
        completedActivity.lifecycle.map(
          (change) => (change.sequence, change.state),
        ),
      );
      final restoredModel = restoredActivity.models.single;
      final completedModel = completedActivity.models.single;
      expect(restoredModel.id, completedModel.id);
      expect(restoredModel.startSequence, completedModel.startSequence);
      expect(restoredModel.terminalSequence, completedModel.terminalSequence);
      expect(restoredModel.settlement, ModelSettlement.completed);
      expect(
        restoredModel.outputs.single.sequence,
        completedModel.outputs.single.sequence,
      );
      expect(
        (restoredModel.outputs.single.item as ModelTextOutput).content,
        'Must not enter durable history.',
      );
      expect(
        fresh.runtime.lifecycle
            .runActivitiesForSession(sessionId)
            .map((activity) => activity.runId),
        unorderedEquals([failed.run.id, retry.run.id]),
      );
      expect(
        fresh.runtime.store
            .runsForSession(sessionId)
            .map((record) => (record.id, record.sessionId, record.state)),
        unorderedEquals([
          (failed.run.id, sessionId, RunTerminalState.completed),
          (retry.run.id, sessionId, RunTerminalState.completed),
        ]),
      );
      expect(ids.calls, 0);
      expect(
        fresh.runtime.lifecycle.environmentRuntime.currentMaterialization(
          product.environment.id,
        ),
        isNull,
      );
      expect(_inspect(source, _chatRows), recoveredRows);
      expect(_inspect(source, _coreRows), coreBefore);
      await fresh.close();
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
  'draftRequest': snapshot.draftRequest,
  'entries': [
    for (final entry in snapshot.entries)
      {
        'id': entry.id,
        'role': entry.role,
        'content': entry.content,
        'runId': entry.runId,
      },
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

// Identity and association invariance is separate from terminal Run retention.
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
    database
        .select('PRAGMA table_info(adele_chat_sessions)')
        .map((row) => (row['name'], row['type'], row['notnull'])),
    [
      ('session_id', 'TEXT', 1),
      ('instructions', 'TEXT', 1),
      ('max_model_invocations', 'INTEGER', 1),
      ('next_entry', 'INTEGER', 1),
      ('draft_request', 'TEXT', 1),
    ],
  );
  expect(
    _rows(database, 'SELECT * FROM adele_schema_versions ORDER BY owner_id'),
    [
      {'owner_id': 'dev.adele.execution', 'version': 1},
      {'owner_id': _chatPluginId, 'version': 1},
      {'owner_id': 'dev.adele.product', 'version': 1},
    ],
  );
  // Data-only terminal evidence is retained separately from canonical Chat.
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
      'adele_product_runs',
      'adele_execution_run_activity',
      'adele_execution_run_lifecycle',
      'adele_execution_model_invocations',
      'adele_execution_model_outputs',
      'adele_execution_tool_invocations',
      'adele_execution_tool_changes',
      'adele_execution_rejected_proposals',
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
