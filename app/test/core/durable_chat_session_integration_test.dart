@Timeout(Duration(minutes: 5))
library;

import 'dart:convert';
import 'dart:io';

import 'package:adele_capabilities/adele_capabilities.dart';
import 'package:adele_contract/adele_contract.dart';
import 'package:adele_core_extensions/adele_core_extensions.dart';
import 'package:adele_desktop/core/adele_runtime.dart';
import 'package:adele_desktop/core/application_plugin_bootstrap.dart';
import 'package:adele_desktop/core/global_settings_service.dart';
import 'package:adele_desktop/core/orchestration_host.dart';
import 'package:adele_desktop/core/prepared_settings.dart';
import 'package:adele_desktop/core/product_lifecycle.dart';
import 'package:adele_desktop/core/project_storage_host.dart';
import 'package:adele_desktop/core/remote_inference_context_host.dart';
import 'package:adele_desktop/core/session_feedback_host.dart';
import 'package:adele_environment/adele_environment.dart';
import 'package:adele_orchestration/adele_orchestration.dart';
import 'package:adele_orchestration/remote_orchestration.dart';
import 'package:adele_platform_storage/adele_platform_storage.dart';
import 'package:adele_plugin_api/adele_plugin_api.dart';
import 'package:adele_product/adele_product.dart';
import 'package:adele_project_storage/adele_project_storage.dart';
import 'package:adele_settings/adele_settings.dart';
import 'package:agent_kernel/agent_kernel.dart';
import 'package:chat_strategy_contract/chat_strategy_contract.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plugin_builder/plugin_builder.dart';
import 'package:plugin_runtime/plugin_runtime.dart';
import 'package:sqlite3/sqlite3.dart' hide Session;

import '../../../tools/backend_artifacts.dart';

const _gitPluginId = 'dev.adele.plugin.git';
const _projectPluginId = 'dev.adele.plugin.local-directory-project';
const _chatPluginId = 'dev.adele.plugin.chat-strategy';
const _instructions = 'Retain the conversation exactly. Answer without tools.';
const _draftRequest =
    '  Question after restart:\n\tkeep this partial request...\n  ';
final _projectProviderId = ProviderId('dev.adele.project.local-directory');
final _gitProviderId = ProviderId('dev.adele.environment.git-worktree');

void main() {
  late Directory artifacts;
  late Directory installations;
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
      _gitPluginId: 'plugins/git/packages/backend/bin/git_backend.dart',
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
    installations = await Directory('${artifacts.path}/installed').create();
    for (final id in [_projectPluginId, _gitPluginId, _chatPluginId]) {
      final installation = Directory('${installations.path}/$id');
      await publishStockPluginInstallation(
        repositoryRoot: Directory.current.parent,
        installationDirectory: installation,
        pluginId: id,
        displayName: id,
        backend: true,
      );
      await File(
        '${artifacts.path}/$id.aot',
      ).copy('${installation.path}/backend.aot');
    }
  });

  Future<AdeleRuntime> startPrepared({
    Map<SettingId, Object?> globalOverrides = const {},
    PlatformStorageRoots? roots,
  }) async {
    final runtime = AdeleRuntime(
      ids: MonotonicProductIdSource(seed: 'global-chat-budget'),
    );
    addTearDown(runtime.close);
    runtime.plugins.configureSettingsLoader(
      (catalog) async => roots == null
          ? PreparedSettingsSnapshot.resolve(
              catalog,
              globalOverrides: globalOverrides,
            )
          : PreparedSettingsSnapshot.load(catalog, roots: roots),
    );
    await runtime.plugins.start(
      installationRoot: installations.path,
      dartaotruntimeExecutable: aotRuntime,
      hostArtifactPath: hostArtifact.path,
      startupArguments: const {},
    );
    expect(runtime.plugins.state, ApplicationPluginState.ready);
    expect(runtime.plugins.catalog!.issues, isEmpty);
    expect(runtime.plugins.backends, hasLength(3));
    for (final backend in runtime.plugins.backends) {
      expect(backend.installation.frontend, isNull);
      expect(
        backend.state,
        InstalledBackendState.active,
        reason: '${backend.failure}',
      );
    }
    return runtime;
  }

  Future<_RuntimeBackends> start(ProductIdSource ids) async {
    late final PluginBackendActivation git;
    final runtime = AdeleRuntime(
      ids: ids,
      captureEstablishmentOwner: (binding) {
        if (!git.ownsProvider(binding)) return null;
        return EnvironmentEstablishmentOwner(
          pluginId: PluginId(git.connection.pluginId),
          validate: () {
            if (!git.ownsProvider(binding)) {
              throw StateError('Environment owner retired.');
            }
          },
        );
      },
    );
    addTearDown(runtime.close);
    final host = await PluginBackendHost.start(
      dartaotruntimeExecutable: aotRuntime,
      hostArtifactPath: hostArtifact.path,
    );
    final backends = _RuntimeBackends(runtime, host, artifacts);
    addTearDown(backends.close);
    await backends.activate(_projectPluginId);
    git = await backends.activate(_gitPluginId);
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
    'host-mediated review acceptance survives replacement and reopen without starting a Run',
    () async {
      final source = await _source();
      final original = await start(MonotonicProductIdSource(seed: 'feedback'));
      final generationA = await original.activate(_chatPluginId);
      final runtime = original.runtime;
      final product = await _createSession(runtime, source);
      final session = product.session;
      final other = runtime.lifecycle.createSession(
        taskId: product.task.id,
        strategyId: chatStrategyId,
      );
      final chatA = _chatClient(generationA.connection);
      await chatA.setDraftRequest(session.id.value, _draftRequest);
      final submission = _feedback(product.environment.id.value, 'review-1');
      final target = CapturedSessionFeedbackTarget.capture(
        lifecycle: runtime.lifecycle,
        session: session,
      );
      final otherTarget = CapturedSessionFeedbackTarget.capture(
        lifecycle: runtime.lifecycle,
        session: other,
      );
      final coreBefore = _inspect(source, _coreRows);
      final worktree = Directory.fromUri(
        source.uri.resolve(
          product.environment.providerState!['worktreeRelativePath']! as String,
        ),
      );
      final indexBefore = await _git(worktree, ['ls-files', '--stage']);
      final diffBefore = await _git(worktree, ['diff', '--binary', 'HEAD']);
      final fileBefore = await File(
        '${worktree.path}/baseline.txt',
      ).readAsBytes();
      expect(await target.lookup(submission.submissionId), isNull);

      final receipts = await Future.wait([
        target.accept(submission),
        target.accept(submission),
      ]);
      final receipt = receipts.first;
      expect(receipts.map((value) => value.occurrenceId), [
        'entry-0',
        'entry-0',
      ]);
      expect(receipt.sessionId, session.id.value);
      expect(receipt.submissionId, submission.submissionId);
      final record = (await target.lookup(submission.submissionId))!;
      expect(record.receipt.occurrenceId, receipt.occurrenceId);
      expect(
        encodeSessionFeedbackSubmission(record.submission),
        encodeSessionFeedbackSubmission(submission),
      );
      final accepted = await chatA.snapshot(session.id.value);
      expect(accepted.entries, hasLength(1));
      expect(accepted.entries.single.id, receipt.occurrenceId);
      expect(accepted.entries.single.role, 'user');
      expect(accepted.entries.single.runId, isNull);
      expect(accepted.draftRequest, _draftRequest);
      for (final comment in submission.comments) {
        expect(
          accepted.entries.single.content,
          contains(jsonEncode(comment.text)),
        );
        expect(
          accepted.entries.single.content,
          contains(jsonEncode(comment.anchor.sourceExcerpt)),
        );
      }
      final stored = _inspect(source, _feedbackRows).single;
      expect(stored['session_id'], session.id.value);
      expect(stored['submission_id'], submission.submissionId);
      expect(stored['entry_id'], receipt.occurrenceId);
      expect(
        stored['canonical_payload'],
        encodeSessionFeedbackSubmission(submission),
      );
      expect(await otherTarget.lookup(submission.submissionId), isNull);
      expect((await chatA.snapshot(other.id.value)).entries, isEmpty);
      expect(runtime.store.runsForSession(session.id), isEmpty);
      expect(runtime.lifecycle.runActivitiesForSession(session.id), isEmpty);
      expect(_inspect(source, _coreRows), coreBefore);
      expect(await _git(worktree, ['ls-files', '--stage']), indexBefore);
      expect(await _git(worktree, ['diff', '--binary', 'HEAD']), diffBefore);
      expect(
        await File('${worktree.path}/baseline.txt').readAsBytes(),
        fileBefore,
      );
      await expectLater(
        target.accept(
          _feedback(product.environment.id.value, 'review-1', changed: true),
        ),
        _feedbackFailure('submission_conflict'),
      );
      expect(
        _snapshot(await chatA.snapshot(session.id.value)),
        _snapshot(accepted),
      );

      await generationA.close();
      final generationB = await original.activate(_chatPluginId);
      await expectLater(
        target.accept(submission),
        _feedbackFailure('stale_target'),
      );
      final replacement = CapturedSessionFeedbackTarget.capture(
        lifecycle: runtime.lifecycle,
        session: session,
      );
      expect(
        (await replacement.lookup('review-1'))!.receipt.occurrenceId,
        receipt.occurrenceId,
      );
      expect(
        (await replacement.accept(submission)).occurrenceId,
        receipt.occurrenceId,
      );
      expect(
        _snapshot(
          await _chatClient(generationB.connection).snapshot(session.id.value),
        ),
        _snapshot(accepted),
      );
      await original.close();

      final ids = _NoAllocationIds();
      final fresh = await start(ids);
      await fresh.runtime.lifecycle.openProject(
        sourceLocation: source.uri,
        provider: fresh.runtime.lifecycle.resolveProjectProvider(
          _projectProviderId,
        ),
      );
      final restoredSession = fresh.runtime.store.session(session.id)!;
      final generationC = await fresh.activate(_chatPluginId);
      final reopened = CapturedSessionFeedbackTarget.capture(
        lifecycle: fresh.runtime.lifecycle,
        session: restoredSession,
      );
      final restored = (await reopened.lookup('review-1'))!;
      expect(restored.receipt.occurrenceId, receipt.occurrenceId);
      expect(
        encodeSessionFeedbackSubmission(restored.submission),
        encodeSessionFeedbackSubmission(submission),
      );
      expect(fresh.runtime.store.runsForSession(session.id), isEmpty);
      expect(ids.calls, 0);
      expect(
        fresh.runtime.lifecycle.environmentRuntime.currentMaterialization(
          product.environment.id,
        ),
        isNull,
      );
      expect(_inspect(source, _feedbackRows), [stored]);
      final chatC = _chatClient(generationC.connection);
      final model = _Model(
        await chatC.snapshot(session.id.value),
        'Addressed captured review.',
      );
      final run = await _createRun(
        fresh.runtime,
        session.id,
        'review-run',
        model,
      );
      expect(model.calls, 0);
      expect(run.run.state, RunState.created);
      // Materialization uses the existing claim and associates the same occurrence.
      expect(
        (await chatC.snapshot(session.id.value)).entries.single.runId,
        'review-run',
      );
      await expectLater(
        reopened.accept(
          _feedback(product.environment.id.value, 'new-while-busy'),
        ),
        _feedbackFailure('session_busy'),
      );
      expect(
        (await reopened.lookup('review-1'))!.receipt.occurrenceId,
        receipt.occurrenceId,
      );
      expect(
        (await reopened.accept(submission)).occurrenceId,
        receipt.occurrenceId,
      );
      await run.start();
      expect(run.run.state, RunState.completed);
      expect(model.calls, 1);
      final afterRun = await chatC.snapshot(session.id.value);
      expect(afterRun.entries.map((entry) => entry.role), [
        'user',
        'assistant',
      ]);
      expect(afterRun.entries.first.id, receipt.occurrenceId);
      expect(afterRun.entries.first.runId, 'review-run');
      expect(afterRun.draftRequest, _draftRequest);
      expect(_inspect(source, _feedbackRows), [stored]);
      expect(await _git(worktree, ['ls-files', '--stage']), indexBefore);
      expect(await _git(worktree, ['diff', '--binary', 'HEAD']), diffBefore);
      expect(
        await File('${worktree.path}/baseline.txt').readAsBytes(),
        fileBefore,
      );
      await fresh.close();
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test(
    'retired waiting Run still fences new feedback on a fresh backend',
    () async {
      final source = await _source();
      final backends = await start(
        MonotonicProductIdSource(seed: 'feedback-busy'),
      );
      final generationA = await backends.activate(_chatPluginId);
      final product = await _createSession(backends.runtime, source);
      final submission = _feedback(product.environment.id.value, 'before-run');
      final first = CapturedSessionFeedbackTarget.capture(
        lifecycle: backends.runtime.lifecycle,
        session: product.session,
      );
      final receipt = await first.accept(submission);
      final run = await createSessionOrchestrationRun(
        lifecycle: backends.runtime.lifecycle,
        sessionId: product.session.id,
        runId: RunId('retired-waiting'),
        contextComposer: backends.runtime.contextComposer,
        model: _ReviewWaitingModel(),
        toolCatalog: ToolCatalog()
          ..register(
            ToolRegistration(
              definition: ToolDefinition(
                id: ToolId('test.feedback'),
                description: 'Must not execute',
              ),
              modelDefinition: ModelToolDefinition(
                alias: 'wait',
                description: 'Wait for approval',
                argumentsSchema: const {},
              ),
              executable: _NeverExecutedTool(),
            ),
          ),
        policy: const _Ask(),
      );
      addTearDown(run.close);
      await run.start();
      expect(run.run.state, RunState.waiting);
      await generationA.close();
      await backends.activate(_chatPluginId);
      final replacement = CapturedSessionFeedbackTarget.capture(
        lifecycle: backends.runtime.lifecycle,
        session: product.session,
      );
      expect(run.run.state, RunState.waiting);
      expect(
        backends.runtime.lifecycle.hasSessionExecution(product.session),
        isTrue,
      );
      expect(
        (await replacement.lookup(
          submission.submissionId,
        ))!.receipt.occurrenceId,
        receipt.occurrenceId,
      );
      expect(
        (await replacement.accept(submission)).occurrenceId,
        receipt.occurrenceId,
      );
      await expectLater(
        replacement.accept(
          _feedback(product.environment.id.value, 'before-run', changed: true),
        ),
        _feedbackFailure('submission_conflict'),
      );
      final next = _feedback(product.environment.id.value, 'after-run');
      await expectLater(
        replacement.accept(next),
        _feedbackFailure('session_busy'),
      );
      expect(await replacement.lookup(next.submissionId), isNull);
      expect(_inspect(source, _feedbackRows), hasLength(1));
      await run.close();
      expect(
        backends.runtime.lifecycle.hasSessionExecution(product.session),
        isFalse,
      );
      expect((await replacement.accept(next)).occurrenceId, 'entry-1');
      expect(
        backends.runtime.store.runsForSession(product.session.id),
        isEmpty,
      );
      await backends.close();
    },
  );

  test(
    'lost acceptance acknowledgement reconciles actual committed SQL without replay',
    () async {
      final source = await _source();
      final backends = await start(
        MonotonicProductIdSource(seed: 'feedback-ack'),
      );
      late _LostFeedbackAcknowledgement fault;
      final generation = await backends.activate(
        _chatPluginId,
        interceptStorage: (dispatcher) =>
            fault = _LostFeedbackAcknowledgement(dispatcher),
      );
      final product = await _createSession(backends.runtime, source);
      final chat = _chatClient(generation.connection);
      await chat.setDraftRequest(product.session.id.value, _draftRequest);
      final target = CapturedSessionFeedbackTarget.capture(
        lifecycle: backends.runtime.lifecycle,
        session: product.session,
      );
      final submission = _feedback(product.environment.id.value, 'lost-ack');
      await expectLater(
        target.accept(submission),
        _feedbackFailure('outcome_uncertain'),
      );
      expect(fault.commits, 1);
      expect(_inspect(source, _feedbackRows), hasLength(1));
      final record = (await target.lookup(submission.submissionId))!;
      expect(record.receipt.occurrenceId, 'entry-0');
      expect(
        encodeSessionFeedbackSubmission(record.submission),
        encodeSessionFeedbackSubmission(submission),
      );
      expect(fault.commits, 1);
      await generation.close();
      final replacement = await backends.activate(_chatPluginId);
      final fresh = CapturedSessionFeedbackTarget.capture(
        lifecycle: backends.runtime.lifecycle,
        session: product.session,
      );
      expect(
        (await fresh.lookup(submission.submissionId))!.receipt.occurrenceId,
        record.receipt.occurrenceId,
      );
      final snapshot = await _chatClient(
        replacement.connection,
      ).snapshot(product.session.id.value);
      expect(snapshot.entries, hasLength(1));
      expect(snapshot.entries.single.id, record.receipt.occurrenceId);
      expect(snapshot.draftRequest, _draftRequest);
      expect(
        backends.runtime.store.runsForSession(product.session.id),
        isEmpty,
      );
      // Failure after the candidate entry INSERT rolls back the entire batch.
      final rowsBefore = _inspect(source, _chatRows);
      final receiptsBefore = _inspect(source, _feedbackRows);
      _inspect(
        source,
        (database) => database.execute('''
        CREATE TRIGGER reject_feedback BEFORE INSERT ON adele_chat_feedback_submissions
        BEGIN SELECT RAISE(ABORT, 'private-feedback-storage-failure'); END;
      '''),
      );
      final rejected = _feedback(product.environment.id.value, 'rollback');
      await expectLater(
        fresh.accept(rejected),
        _feedbackFailure('outcome_uncertain'),
      );
      expect(await fresh.lookup(rejected.submissionId), isNull);
      expect(_inspect(source, _chatRows), rowsBefore);
      expect(_inspect(source, _feedbackRows), receiptsBefore);
      _inspect(
        source,
        (database) => database.execute('DROP TRIGGER reject_feedback'),
      );
      // New explicit acceptance after authoritative reconciliation, not replay
      // performed automatically by the target.
      expect((await fresh.accept(rejected)).occurrenceId, 'entry-1');
      await backends.close();
    },
  );

  test(
    'backend-only prepared Chat enforces default 40 then global 80 on the same durable Session',
    () async {
      final source = await _source();
      final global = await Directory.systemTemp.createTemp(
        'chat-global-settings-',
      );
      addTearDown(() => global.delete(recursive: true));
      final roots = PlatformStorageRoots(
        operatingSystem: Platform.operatingSystem,
        configurationRoot: '${global.path}/config',
        localStateRoot: '${global.path}/state',
        localDataRoot: '${global.path}/data',
        cacheRoot: '${global.path}/cache',
      );
      SessionId? sessionId;
      Map<String, Object?>? retained;
      Map<String, Object?>? coreRows;
      for (final limit in [40, 80]) {
        final runtime = await startPrepared(roots: roots);
        final backend = runtime.plugins.backends.singleWhere(
          (backend) => backend.installation.metadata.id.value == _chatPluginId,
        );
        final settings = await runtime.plugins.settingsForCatalog(
          runtime.plugins.catalog!,
        );
        expect(settings.valuesForInstallation(backend.installation), {
          chatMaxModelInvocationsSettingId: limit,
        });
        final chat = _chatClient(backend.connection!);
        if (sessionId == null) {
          sessionId = (await _createSession(runtime, source)).session.id;
          await chat.configureSession(sessionId.value, _instructions);
          await chat.setDraftRequest(sessionId.value, _draftRequest);
          coreRows = _inspect(source, _coreRows);
        } else {
          await runtime.lifecycle.openProject(
            sourceLocation: source.uri,
            provider: runtime.lifecycle.resolveProjectProvider(
              _projectProviderId,
            ),
          );
          expect(runtime.store.session(sessionId)!.id, sessionId);
          expect(_snapshot(await chat.snapshot(sessionId.value)), retained);
          expect(_inspect(source, _coreRows), coreRows);
        }
        await chat.appendUserMessage(
          sessionId.value,
          'Loop with limit $limit.',
        );
        final model = _LoopModel();
        final tool = _LoopTool();
        final policy = _LoopPolicy();
        final run = await _createRun(
          runtime,
          sessionId,
          'global-limit-$limit',
          model,
          toolCatalog: _loopCatalog(tool),
          policy: policy,
        );
        final before = _snapshot(await chat.snapshot(sessionId.value));
        await run.start();
        expect(run.run.state, RunState.failed);
        expect(
          run.run.failure,
          isA<RemoteStrategyFailure>()
              .having(
                (failure) => failure.code,
                'code',
                'ModelInvocationLimitExceeded',
              )
              .having(
                (failure) => failure.message,
                'message',
                contains('$limit model invocations'),
              ),
        );
        expect(model.calls, limit);
        expect(tool.calls, limit - 1);
        expect(policy.calls, limit - 1);
        expect(run.run.interruptions, isEmpty);
        final activity = runtime.lifecycle.runActivity(run.run.id)!;
        expect(activity.state, RunState.failed);
        expect(activity.models, hasLength(limit));
        expect(activity.tools, hasLength(limit - 1));
        expect(
          runtime.store.runRecord(run.run.id)!.state,
          RunTerminalState.failed,
        );
        expect(_snapshot(await chat.snapshot(sessionId.value)), before);
        await run.close();

        if (limit == 80) {
          // A fresh Run gets all 80 slots, including a final non-tool answer.
          final completingModel = _LoopModel(completeAt: limit);
          final completingTool = _LoopTool();
          final completing = await _createRun(
            runtime,
            sessionId,
            'global-limit-final-answer',
            completingModel,
            toolCatalog: _loopCatalog(completingTool),
            policy: _LoopPolicy(),
          );
          await completing.start();
          expect(completing.run.state, RunState.completed);
          expect(completingModel.calls, limit);
          expect(completingTool.calls, limit - 1);
          expect(
            (await chat.snapshot(sessionId.value)).entries.last.content,
            'Completed in the final permitted slot.',
          );
          await completing.close();
        }
        retained = _snapshot(await chat.snapshot(sessionId.value));
        expect(retained['instructions'], _instructions);
        expect(retained['draftRequest'], _draftRequest);
        expect(_inspect(source, _coreRows), coreRows);
        _inspect(source, _expectSchema);
        if (limit == 40) {
          final service = GlobalSettingsService(
            catalog: runtime.plugins.catalog!.settings,
            roots: roots,
          );
          try {
            final saved = await service.save(
              await service.load(),
              SettingId(chatMaxModelInvocationsSettingId),
              80,
            );
            expect(
              saved.values[SettingId(chatMaxModelInvocationsSettingId)]!.source,
              SettingValueSource.global,
            );
            expect(settings.valuesForInstallation(backend.installation), {
              chatMaxModelInvocationsSettingId: 40,
            });
          } finally {
            await service.close();
          }
        }
        await runtime.close();
      }
    },
    skip: !Platform.isLinux,
  );

  test(
    'backend-only prepared Chat keeps its startup budget across approval waits',
    () async {
      final source = await _source();
      final overrides = <SettingId, Object?>{};
      final runtime = await startPrepared(globalOverrides: overrides);
      final session = (await _createSession(runtime, source)).session;
      final backend = runtime.plugins.backends.singleWhere(
        (backend) => backend.installation.metadata.id.value == _chatPluginId,
      );
      final settings = await runtime.plugins.settingsForCatalog(
        runtime.plugins.catalog!,
      );
      final chat = _chatClient(backend.connection!);
      await chat.appendUserMessage(session.id.value, 'Loop through approvals.');
      final model = _LoopModel();
      final tool = _LoopTool();
      final policy = _LoopPolicy(askAt: {1, 39});
      final run = await _createRun(
        runtime,
        session.id,
        'global-limit-approval',
        model,
        toolCatalog: _loopCatalog(tool),
        policy: policy,
      );
      await run.start();
      expect(run.run.state, RunState.waiting);
      expect(model.calls, 1);
      expect(tool.calls, 0);
      overrides[SettingId(chatMaxModelInvocationsSettingId)] = 80;
      expect(
        settings
            .read(backend.installation, chatMaxModelInvocationsSettingId)
            .value,
        40,
      );
      expect(
        () => settings.valuesForInstallation(
          backend.installation,
        )[chatMaxModelInvocationsSettingId] = 80,
        throwsUnsupportedError,
      );
      await _approve(run);
      expect(run.run.state, RunState.waiting);
      expect(model.calls, 39);
      expect(tool.calls, 38);
      await _approve(run);
      expect(run.run.state, RunState.failed);
      expect(model.calls, 40);
      expect(tool.calls, 39);
      expect(policy.calls, 39);
      expect(run.run.interruptions, isEmpty);
      expect(
        run.run.failure,
        isA<RemoteStrategyFailure>().having(
          (failure) => failure.code,
          'code',
          'ModelInvocationLimitExceeded',
        ),
      );
      expect(
        run.run.journal.records.where(
          (record) => record.event is RunInterrupted,
        ),
        hasLength(2),
      );
      expect((await chat.snapshot(session.id.value)).entries, hasLength(1));
    },
  );

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
          'next_entry': 0,
          'draft_request': '',
        },
      ]);
      await chatA.configureSession(session.id.value, _instructions);
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
      await chat.configureSession(sessionId.value, _instructions);
      await chat.appendUserMessage(sessionId.value, 'Retained before failure.');
      await chat.setDraftRequest(sessionId.value, _draftRequest);
      final before = await chat.snapshot(sessionId.value);
      final rowsBefore = _inspect(source, _chatRows);
      expect(rowsBefore['sessions'], [
        {
          'session_id': sessionId.value,
          'instructions': _instructions,
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
        BEFORE UPDATE OF instructions ON adele_chat_sessions
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

  Future<PluginBackendActivation> activate(
    String pluginId, {
    AdeleBackendDispatcher Function(AdeleBackendDispatcher)? interceptStorage,
  }) async {
    final connection = await host.startPlugin(
      pluginId: pluginId,
      artifactUri: File('${artifacts.path}/$pluginId.aot').uri,
      settings: {
        if (pluginId == _chatPluginId) chatMaxModelInvocationsSettingId: 8,
      },
      createInfrastructureServices: (connection) {
        final services = projectStorageServices(runtime.lifecycle, connection);
        if (interceptStorage != null) {
          services[projectStorageServiceId] = interceptStorage(
            services[projectStorageServiceId]!,
          );
        }
        return services;
      },
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
  ModelPort model, {
  ToolCatalog? toolCatalog,
  ToolPolicy policy = const _NoTools(),
}) async {
  final run = await createSessionOrchestrationRun(
    lifecycle: runtime.lifecycle,
    sessionId: sessionId,
    runId: RunId(runId),
    contextComposer: runtime.contextComposer,
    model: model,
    toolCatalog: toolCatalog ?? ToolCatalog(),
    policy: policy,
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

final class _ReviewWaitingModel implements ModelPort {
  @override
  Stream<ModelEvent> invoke(SemanticModelRequest request) async* {
    yield ModelOutputItemCompleted(
      invocationId: request.invocationId,
      item: ModelToolProposalOutput(
        ProviderToolProposal(
          providerCallId: 'wait-1',
          alias: 'wait',
          arguments: const {},
        ),
      ),
    );
    yield ModelInvocationSettledEvent(invocationId: request.invocationId);
  }
}

final class _NeverExecutedTool implements ToolExecutable {
  @override
  void validateBinding() {}
  @override
  CanonicalToolArguments validateAndNormalize(Map<String, Object?> arguments) =>
      CanonicalToolArguments(arguments);
  @override
  Future<EffectDescription> describe(
    CanonicalToolArguments arguments,
    ToolExecutionContext context,
  ) async => EffectDescription(
    effects: const [ToolEffect.sourceMutation],
    targets: const [],
    summary: 'Approval fixture',
  );
  @override
  Stream<ToolExecutionEvent> execute(
    CanonicalToolArguments arguments,
    ToolExecutionContext context,
  ) =>
      throw StateError('Feedback acceptance cannot approve or execute a tool.');
}

final class _Ask implements ToolPolicy {
  const _Ask();
  @override
  ToolPolicyDecision evaluate(ToolPolicyInput input) => ToolPolicyDecision.ask;
}

Future<void> _approve(SessionOrchestrationRun run) {
  final pending =
      run.run.interruptions.values.single as ToolApprovalInterruption;
  return run.resolveApproval(
    ToolApprovalResolution(
      interruptionId: pending.id,
      toolInvocationId: pending.toolInvocationId,
      approved: true,
    ),
  );
}

final class _LoopModel implements ModelPort {
  _LoopModel({this.completeAt});
  final int? completeAt;
  int calls = 0;

  @override
  Stream<ModelEvent> invoke(SemanticModelRequest request) async* {
    calls++;
    // Bound even a regressed implementation without a timing-based test oracle.
    expect(calls, lessThanOrEqualTo(100));
    expect(request.tools.byAlias('continue_loop'), isNotNull);
    expect(
      request.input.whereType<SemanticToolOutcomeInput>(),
      hasLength(calls - 1),
    );
    yield ModelOutputItemCompleted(
      invocationId: request.invocationId,
      item: calls == completeAt
          ? ModelTextOutput('Completed in the final permitted slot.')
          : ModelToolProposalOutput(
              ProviderToolProposal(
                providerCallId: 'loop-$calls',
                alias: 'continue_loop',
                arguments: const {},
              ),
            ),
    );
    yield ModelInvocationSettledEvent(
      invocationId: request.invocationId,
      settlement: ModelSettlement.completed,
      metadata: ModelTerminalMetadata(
        effectiveModel: 'global-budget-deterministic',
      ),
    );
  }
}

ToolCatalog _loopCatalog(_LoopTool tool) => ToolCatalog()
  ..register(
    ToolRegistration(
      definition: ToolDefinition(
        id: ToolId('dev.adele.test.continue-loop'),
        description: 'Continue the deterministic loop.',
      ),
      modelDefinition: ModelToolDefinition(
        alias: 'continue_loop',
        description: 'Continue the deterministic loop.',
        argumentsSchema: const {},
      ),
      executable: tool,
    ),
  );

final class _LoopTool implements ToolExecutable {
  int calls = 0;

  @override
  void validateBinding() {}

  @override
  CanonicalToolArguments validateAndNormalize(Map<String, Object?> arguments) {
    expect(arguments, isEmpty);
    return CanonicalToolArguments(arguments);
  }

  @override
  Future<EffectDescription> describe(
    CanonicalToolArguments arguments,
    ToolExecutionContext context,
  ) async => EffectDescription(
    effects: const [ToolEffect.resourceInspection],
    targets: const [],
    summary: 'Continue the deterministic loop.',
  );

  @override
  Stream<ToolExecutionEvent> execute(
    CanonicalToolArguments arguments,
    ToolExecutionContext context,
  ) async* {
    calls++;
    yield ToolExecutionTerminal(
      ToolOutcome(
        disposition: ToolOutcomeDisposition.success,
        effectCertainty: EffectCertainty.knownOccurred,
        modelContent: 'Continue.',
      ),
    );
  }
}

final class _LoopPolicy implements ToolPolicy {
  _LoopPolicy({this.askAt = const {}});
  final Set<int> askAt;
  int calls = 0;

  @override
  ToolPolicyDecision evaluate(ToolPolicyInput input) => askAt.contains(++calls)
      ? ToolPolicyDecision.ask
      : ToolPolicyDecision.allow;
}

Map<String, Object?> _snapshot(ChatSessionSnapshot snapshot) => {
  'instructions': snapshot.instructions,
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

List<Map<String, Object?>> _feedbackRows(Database database) => _rows(
  database,
  'SELECT * FROM adele_chat_feedback_submissions ORDER BY session_id, submission_id',
);

void _expectSchema(Database database) {
  expect(
    database
        .select('PRAGMA table_info(adele_chat_sessions)')
        .map((row) => (row['name'], row['type'], row['notnull'])),
    [
      ('session_id', 'TEXT', 1),
      ('instructions', 'TEXT', 1),
      ('next_entry', 'INTEGER', 1),
      ('draft_request', 'TEXT', 1),
    ],
  );
  expect(
    _rows(database, 'SELECT * FROM adele_schema_versions ORDER BY owner_id'),
    [
      {'owner_id': 'dev.adele.execution', 'version': 1},
      {'owner_id': _chatPluginId, 'version': 1},
      {'owner_id': _gitPluginId, 'version': 1},
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
      'adele_chat_feedback_submissions',
      'adele_git_task_anchors',
    ]),
  );
}

Matcher _feedbackFailure(String code) => throwsA(
  isA<SessionFeedbackFailure>().having((failure) => failure.code, 'code', code),
);

SessionFeedbackSubmission _feedback(
  String environmentId,
  String id, {
  bool changed = false,
}) => SessionFeedbackSubmission(
  submissionId: id,
  kind: SessionFeedbackKind.codeReview,
  comments: [
    for (var index = 0; index < 3; index++)
      SessionFeedbackComment(
        id: 'comment-$index',
        version: index + 1,
        sequence: index * 2 + 1,
        text: index == 0 && changed
            ? 'Changed feedback.'
            : 'Feedback $index: preserve \u03bb and \u{1f680}.\r\nExact body.',
        anchor: SessionFeedbackAnchor(
          environmentId: environmentId,
          relativePath: 'baseline.txt',
          layer: SessionFeedbackComparisonLayer.values[index],
          side: index == 1
              ? SessionFeedbackComparisonSide.oldSide
              : SessionFeedbackComparisonSide.newSide,
          startLine: 1,
          endLine: index == 2 ? 3 : 1,
          comparisonIdentity: 'captured-comparison-$index',
          sourceExcerpt: index == 0
              ? 'captured\r\nsource\r\n'
              : 'captured \u03bb without newline',
          hunkIndex: index,
          lineIndex: 0,
        ),
      ),
  ],
);

/// Drops only the first successful submission transaction acknowledgement,
/// after the real generation-scoped host dispatcher has committed SQLite.
final class _LostFeedbackAcknowledgement implements AdeleBackendDispatcher {
  _LostFeedbackAcknowledgement(this.delegate);
  final AdeleBackendDispatcher delegate;
  int commits = 0;

  Map<String, Object?> _response(
    Map<Object?, Object?> request,
    Map<String, Object?> response,
  ) {
    if (response['ok'] == true &&
        request['method'] == projectStorageServiceTransactionForSessionId &&
        jsonEncode(request).contains('adele_chat_feedback_submissions')) {
      commits++;
      if (commits == 1) {
        return {
          ...response,
          'ok': false,
          'error': {
            'code': 'acknowledgement_lost',
            'message': 'Injected lost acknowledgement.',
          },
        };
      }
    }
    return response;
  }

  @override
  Future<Map<String, Object?>> dispatch(Map<Object?, Object?> request) async =>
      _response(request, await delegate.dispatch(request));

  @override
  Future<void> handle(
    Map<Object?, Object?> command,
    void Function(Map<String, Object?>) send,
  ) => delegate.handle(command, (event) => send(_response(command, event)));

  @override
  Future<void> close() => delegate.close();
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
