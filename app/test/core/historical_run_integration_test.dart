@Timeout(Duration(minutes: 3))
library;

import 'dart:convert';
import 'dart:io';

import 'package:adele_capabilities/adele_capabilities.dart';
import 'package:adele_contract/adele_contract.dart';
import 'package:adele_core_extensions/adele_core_extensions.dart';
import 'package:adele_desktop/core/adele_runtime.dart';
import 'package:adele_desktop/core/application_plugin_bootstrap.dart';
import 'package:adele_desktop/core/orchestration_host.dart';
import 'package:adele_desktop/core/product_lifecycle.dart';
import 'package:adele_environment/adele_environment.dart';
import 'package:adele_orchestration/adele_orchestration.dart';
import 'package:adele_orchestration/remote_orchestration.dart';
import 'package:adele_product/adele_product.dart';
import 'package:agent_kernel/agent_kernel.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plugin_builder/plugin_builder.dart';
import 'package:plugin_runtime/plugin_runtime.dart';
import 'package:sqlite3/sqlite3.dart' hide Session;

const _pluginId = 'test.historical';
const _bound = Duration(seconds: 15);
final _strategyId = OrchestrationStrategyId('test.historical.strategy');
final _projectProvider = ProviderId('test.historical.project');
final _environmentProvider = ProviderId('test.historical.environment');
const _reads = [
  'seed-completed',
  'seed-failed',
  'rich',
  'empty',
  'unknown',
  'foreign-session',
  'foreign-task',
  'foreign-project',
  'missing-activity',
  'reader',
  'oversize-bytes',
  'oversize-nodes',
  'oversize-depth',
  'empty',
];

void main() {
  late Directory artifacts;
  late Directory installation;
  late File hostArtifact;
  late String aotRuntime;

  setUpAll(() async {
    artifacts = await Directory.systemTemp.createTemp('adele-history-aot-');
    final dart =
        '${Platform.environment['FLUTTER_ROOT']!}/bin/cache/dart-sdk/bin/dart';
    aotRuntime = File(dart).parent.uri.resolve('dartaotruntime').toFilePath();
    hostArtifact = File('${artifacts.path}/host.aot');
    installation = await Directory('${artifacts.path}/installed').create();
    final plugin = await Directory('${installation.path}/history').create();
    final probeArtifact = File('${plugin.path}/backend.aot');
    for (final target in [
      (
        entrypoint: 'packages/plugin_backend_host/bin/adele_backend_host.dart',
        artifact: hostArtifact,
      ),
      (
        entrypoint: 'app/test/core/fixtures/historical_run_probe.dart',
        artifact: probeArtifact,
      ),
    ]) {
      await compileAotSnapshot(
        dartExecutable: dart,
        workingDirectory: Directory.current.parent,
        entrypoint: target.entrypoint,
        artifact: target.artifact,
        stage: 'historical-run-integration',
      );
    }
    await File('${plugin.path}/adele_plugin.installation.json').writeAsString(
      jsonEncode({
        'manifestVersion': 1,
        'metadata': {
          'id': _pluginId,
          'version': '1',
          'displayName': 'Historical Run probe',
        },
        'components': {
          'backend': {'artifact': 'backend.aot'},
        },
      }),
    );
  });
  tearDownAll(() => artifacts.delete(recursive: true));

  Future<void> startInstalled(AdeleRuntime runtime) async {
    await runtime.plugins
        .start(
          installationRoot: installation.path,
          dartaotruntimeExecutable: aotRuntime,
          hostArtifactPath: hostArtifact.path,
          startupArguments: {
            _pluginId: [jsonEncode(_reads)],
          },
        )
        .timeout(_bound);
    expect(runtime.plugins.state, ApplicationPluginState.ready);
    expect(runtime.plugins.failure, isNull);
    expect(runtime.plugins.catalog!.issues, isEmpty);
    expect(runtime.plugins.catalog!.installations, hasLength(1));
    final backend = runtime.plugins.backends.single;
    expect(backend.installation.metadata.id.value, _pluginId);
    expect(
      backend.state,
      InstalledBackendState.active,
      reason: '${backend.failure}',
    );
    expect(
      backend.connection!.extensionExposures.single.serviceId,
      remoteOrchestrationServiceId,
    );
    expect(
      runtime.extensions.discover(orchestrationStrategyContributions),
      hasLength(1),
    );
  }

  test('AOT probe depends only on public plugin APIs', () async {
    final source = await File(
      'test/core/fixtures/historical_run_probe.dart',
    ).readAsString();
    expect(
      RegExp(
        r"import '([^']+)';",
      ).allMatches(source).map((match) => match[1]).toSet(),
      {
        'dart:async',
        'dart:convert',
        'dart:isolate',
        'package:adele_contract/adele_contract.dart',
        'package:adele_orchestration/adele_orchestration.dart',
        'package:adele_orchestration/remote_orchestration.dart',
        'package:adele_orchestration/remote_orchestration_backend.dart',
        'package:adele_plugin_backend_support/adele_plugin_backend_support.dart',
      },
    );
  });

  test(
    'installed AOT strategy consumes durable reopened terminal history via '
    'generated host transport with scope, sanitization and recoverable bounds',
    () async {
      final source = await Directory.systemTemp.createTemp(
        'adele-history-project-',
      );
      addTearDown(() => source.delete(recursive: true));
      final original = AdeleRuntime(
        ids: MonotonicProductIdSource(seed: 'history'),
      );
      addTearDown(original.close);
      final originalProvider = _ProviderChannel();
      _registerProviders(original, originalProvider, environment: true);
      await startInstalled(original);
      final project = await original.lifecycle.openProject(
        sourceLocation: source.uri,
        provider: original.lifecycle.resolveProjectProvider(_projectProvider),
      );
      Future<Session> createSession(ProjectId projectId) async {
        final task = await original.lifecycle.createTask(
          projectId: projectId,
          title: 'Historical evidence',
          providerId: _environmentProvider,
        );
        return original.lifecycle.createSession(
          taskId: task.task.id,
          strategyId: _strategyId,
        );
      }

      final session = await createSession(project.id);
      final model = _Model();
      final previous = <SessionOrchestrationRun>[];
      for (final failed in [false, true]) {
        model.fail = failed;
        final run = await _createRun(
          original,
          session.id,
          failed ? 'seed-failed' : 'seed-completed',
          model,
        );
        await run.start().timeout(_bound);
        expect(run.run.state, failed ? RunState.failed : RunState.completed);
        expect(
          original.store.runRecord(run.run.id)!.state,
          failed ? RunTerminalState.failed : RunTerminalState.completed,
        );
        previous.add(run);
        await run.close();
      }
      expect(model.requests, hasLength(2));
      final rich = _richActivity(session.id);
      _retain(original, rich);
      _retain(original, _empty('empty', session.id));
      final sibling = original.lifecycle.createSession(
        taskId: session.taskId,
        strategyId: _strategyId,
      );
      _retain(original, _empty('foreign-session', sibling.id));
      final foreignTask = await createSession(project.id);
      _retain(original, _empty('foreign-task', foreignTask.id));
      final otherSource = await Directory(
        '${source.path}/other-project',
      ).create();
      final otherProject = await original.lifecycle.openProject(
        sourceLocation: otherSource.uri,
        provider: original.lifecycle.resolveProjectProvider(_projectProvider),
      );
      final foreignProject = await createSession(otherProject.id);
      _retain(original, _empty('foreign-project', foreignProject.id));
      for (final dimension in ['bytes', 'nodes', 'depth']) {
        _retain(original, _oversize(session.id, dimension));
      }
      final inspection = sqlite3.open('${source.path}/.adele/data.db');
      addTearDown(inspection.close);
      final rows = inspection
          .select(
            'SELECT id, session_id, terminal_state FROM adele_product_runs ORDER BY id',
          )
          .map((row) => Map<String, Object?>.from(row))
          .toList();
      expect(rows, hasLength(9));
      expect(
        inspection.select('SELECT * FROM adele_execution_run_activity'),
        hasLength(rows.length),
      );
      await original.close();

      // Reopening publishes new objects from SQLite with no strategy or Environment.
      final fresh = AdeleRuntime(ids: MonotonicProductIdSource(seed: 'fresh'));
      addTearDown(fresh.close);
      final provider = _ProviderChannel();
      _registerProviders(fresh, provider);
      expect(fresh.store.runRecord(RunId('seed-completed')), isNull);
      for (final directory in [source, otherSource]) {
        await fresh.lifecycle.openProject(
          sourceLocation: directory.uri,
          provider: fresh.lifecycle.resolveProjectProvider(_projectProvider),
        );
      }
      expect(fresh.plugins.host, isNull);
      expect(fresh.store.session(session.id), isNot(same(session)));
      expect(fresh.lifecycle.runActivity(RunId('rich')), isNot(same(rich)));
      expect(
        fresh.registry.providersFor(environmentProviderCapability),
        isEmpty,
      );
      final environment = fresh.store
          .requireSessionAuthority(session.id)
          .environmentId;
      expect(
        fresh.lifecycle.environmentRuntime.currentMaterialization(environment),
        isNull,
      );
      expect(
        inspection
            .select(
              'SELECT id, session_id, terminal_state FROM adele_product_runs ORDER BY id',
            )
            .map((row) => Map<String, Object?>.from(row)),
        rows,
      );
      expect(provider.environmentCalls, 0);
      // An absent source snapshot is not a successful empty history. Deliberately
      // publish only the product record in memory, without corrupting durable SQL.
      fresh.store.publishTerminalRun(
        RunRecord(
          id: RunId('missing-activity'),
          sessionId: session.id,
          state: RunTerminalState.completed,
        ),
      );
      await startInstalled(fresh);
      final consumed = _Model();
      final reader = await _createRun(fresh, session.id, 'reader', consumed);
      final connection = fresh.plugins.backends.single.connection!;
      expect(await _control(connection, 'lateRead'), {'denied': true});
      await reader.start().timeout(_bound);
      expect(reader.run.state, RunState.completed);
      expect(reader.run.failure, isNull);
      expect(reader.run.interruptions, isEmpty);
      expect(consumed.requests, hasLength(1));
      final content =
          (consumed.requests.single.context.input.single
                  as SemanticMessageInput)
              .content;
      final results = (jsonDecode(content) as List)
          .map((value) => Map<String, Object?>.from(value as Map))
          .toList();
      expect(results.map((result) => result['id']), _reads);
      expect(content, isNot(contains('SECRET')));
      expect(content, isNot(contains('hostData')));
      expect(content, isNot(contains('providerDetails')));
      expect(content, isNot(contains('nativeMetadata')));
      HistoricalRunEvidence evidence(String id) {
        final result = results.firstWhere((value) => value['id'] == id);
        expect(result['sanitized'], isTrue);
        final value = HistoricalRunEvidence.fromJson(
          Map<String, Object?>.from(result['evidence'] as Map),
        );
        expect(value.record.id, RunId(id));
        expect(value.record.sessionId, session.id);
        expect(result['state'], value.record.state.name);
        return value;
      }

      for (final run in previous) {
        final value = evidence(run.run.id.value);
        expect(value.record.state.name, run.run.state.name);
        expect(value.activity.sequence, run.activity.snapshot.sequence);
        expect(
          value.activity.models.single.outputs.single.sequence,
          run.activity.snapshot.models.single.outputs.single.sequence,
        );
        expect(
          (value.activity.models.single.outputs.single.item as ModelTextOutput)
              .content,
          'Actual previous output',
        );
      }
      expect(
        evidence('seed-completed').record.state,
        RunTerminalState.completed,
      );
      final failed = evidence('seed-failed');
      expect(failed.record.state, RunTerminalState.failed);
      expect(
        failed.activity.models.single.failure!.message,
        contains('Seed failure'),
      );
      expect(
        failed.activity.models.single.failure!.providerCode,
        'seed_failure',
      );
      expect(failed.activity.failure, isNotNull);
      _expectRich(evidence('rich').activity);
      final empty = evidence('empty');
      expect(empty.record.state, RunTerminalState.completed);
      expect(empty.activity.models, isEmpty);
      expect(empty.activity.tools, isEmpty);
      expect(empty.activity.rejectedProposals, isEmpty);
      for (final id in [
        'unknown',
        'foreign-session',
        'foreign-task',
        'foreign-project',
        'missing-activity',
      ]) {
        expect(results.singleWhere((value) => value['id'] == id), {
          'id': id,
          'failure': 'unavailable',
        });
      }
      expect(results.singleWhere((value) => value['id'] == 'reader'), {
        'id': 'reader',
        'failure': 'current_run',
      });
      for (final dimension in ['bytes', 'nodes', 'depth']) {
        final id = 'oversize-$dimension';
        expect(results.singleWhere((value) => value['id'] == id), {
          'id': id,
          'failure': 'result_too_large',
        });
      }
      // Exact equality proves a healthy read after every failure, not a partial
      // oversize success or a poisoned operation masked by an empty result.
      expect(results.last, results[3]);
      expect(
        fresh.store.runRecord(reader.run.id)!.state,
        RunTerminalState.completed,
      );
      expect(provider.environmentCalls, 0);
      expect(
        fresh.lifecycle.environmentRuntime.currentMaterialization(environment),
        isNull,
      );
      final snapshot = await _control(connection, 'snapshot') as Map;
      expect(snapshot['executionCount'], 0);
      expect(snapshot['phases'], [
        {'phase': 'materialize', 'runId': 'reader', 'denied': true},
        {'phase': 'close', 'runId': 'reader', 'denied': true},
      ]);
      final historyCalls = (snapshot['requests'] as List)
          .cast<Map<Object?, Object?>>()
          .where(
            (call) =>
                call['method'] ==
                remoteOrchestrationHostServiceReadHistoricalRunId,
          )
          .toList();
      expect(historyCalls.map((call) => call['payload']), [
        for (final id in _reads) {'runId': id},
      ]);
      expect(await _control(connection, 'lateRead'), {'denied': true});
      expect(connection.isClosed, isFalse);
      await reader.close();
    },
  );
}

Future<Object?> _control(PluginBackendConnection connection, String method) =>
    connection
        .channelFor(connection.defaultConfigurationContext, 'probe')
        .request(method, const {})
        .timeout(_bound);

Future<SessionOrchestrationRun> _createRun(
  AdeleRuntime runtime,
  SessionId sessionId,
  String id,
  _Model model,
) async {
  final run = await createSessionOrchestrationRun(
    lifecycle: runtime.lifecycle,
    sessionId: sessionId,
    runId: RunId(id),
    contextComposer: runtime.contextComposer,
    model: model,
    toolCatalog: ToolCatalog(),
    policy: const _NoTools(),
  );
  addTearDown(run.close);
  return run;
}

void _retain(AdeleRuntime runtime, RunActivitySnapshot activity) =>
    runtime.lifecycle.retainTerminalRun(
      RunRecord(
        id: activity.runId,
        sessionId: activity.sessionId,
        state: RunTerminalState.values.byName(activity.state.name),
      ),
      activity,
    );

RunActivitySnapshot _empty(String id, SessionId sessionId) =>
    RunActivitySnapshot(
      runId: RunId(id),
      sessionId: sessionId,
      state: RunState.completed,
      sequence: 0,
      lifecycle: const [
        RunLifecycleActivity(sequence: 0, state: RunState.completed),
      ],
    );

RunActivitySnapshot _oversize(SessionId sessionId, String dimension) {
  Object? nested;
  for (var i = 0; i < HistoricalRunEvidenceLimits.maxDepth; i++) {
    nested = {'nested': nested};
  }
  return RunActivitySnapshot(
    runId: RunId('oversize-$dimension'),
    sessionId: sessionId,
    state: RunState.completed,
    sequence: 5,
    lifecycle: const [
      RunLifecycleActivity(sequence: 0, state: RunState.running),
      RunLifecycleActivity(sequence: 5, state: RunState.completed),
    ],
    models: [
      ModelInvocationActivity(
        id: ModelInvocationId('large-model'),
        startSequence: 1,
        terminalSequence: 4,
        settlement: ModelSettlement.completed,
        metadata: ModelTerminalMetadata(),
        outputs: [
          ModelOutputActivity(
            sequence: 2,
            item: dimension == 'bytes'
                ? ModelTextOutput(
                    '\u00e9' * (HistoricalRunEvidenceLimits.maxBytes ~/ 2 + 1),
                  )
                : ModelToolProposalOutput(
                    ProviderToolProposal(
                      providerCallId: 'large-call',
                      alias: 'not-executed',
                      arguments: {
                        'value': dimension == 'nodes'
                            ? List<Object?>.filled(
                                HistoricalRunEvidenceLimits.maxNodes,
                                null,
                              )
                            : nested,
                      },
                    ),
                  ),
          ),
        ],
      ),
    ],
  );
}

RunActivitySnapshot _richActivity(SessionId sessionId) {
  final native = ModelNativeEnvelope(
    kind: 'test.native',
    compatibility: {'private': 'SECRET compatibility'},
    // Excluded native data must not count against the sanitized result bound.
    data: {'opaque': 'SECRET ${'x' * HistoricalRunEvidenceLimits.maxBytes}'},
  );
  final failure = ActivityFailure(
    kind: 'transport',
    message: 'Connection lost',
    providerCode: 'lost',
    providerDetails: {'private': 'SECRET provider details'},
  );
  final model = ModelInvocationId('rich-model');
  final proposals = [
    for (var i = 0; i < 6; i++)
      ProviderToolProposal(
        providerCallId: 'call-$i',
        alias: 'tool-$i',
        arguments: {'raw': i},
      ),
  ];
  final effects = EffectDescription(
    effects: [ToolEffect.sourceMutation],
    targets: [EffectTarget(uri: Uri.parse('file:///source/result'))],
    summary: 'Write result',
    uncertainty: EffectUncertainty.uncertain,
  );
  final tools = <ToolInvocationActivity>[];
  for (var i = 0; i < 4; i++) {
    final start = 20 + i * 10;
    final outcome = ToolOutcomeActivity(
      disposition: [
        ToolOutcomeDisposition.success,
        ToolOutcomeDisposition.policyDenied,
        ToolOutcomeDisposition.userRejected,
        ToolOutcomeDisposition.failure,
      ][i],
      failureKind: i == 3 ? ToolFailureKind.infrastructure : null,
      effectCertainty: i == 0
          ? EffectCertainty.knownOccurred
          : i == 3
          ? EffectCertainty.uncertain
          : EffectCertainty.knownNotOccurred,
      modelContent: 'Outcome $i',
      hostData: {'private': 'SECRET host data'},
    );
    final interruption = RunInterruptionId('approval-$i');
    tools.add(
      ToolInvocationActivity(
        id: ToolInvocationId('tool-$i'),
        preparedSequence: start,
        modelInvocationId: model,
        proposalSequence: 6 + i,
        toolId: ToolId('test.tool.$i'),
        alias: proposals[i].alias,
        providerCallId: proposals[i].providerCallId,
        canonicalArguments: {'normalized': i},
        effects: effects,
        outcome: outcome,
        changes: [
          ToolActivityChange(sequence: start, kind: ToolActivityKind.prepared),
          ToolActivityChange(
            sequence: start + 1,
            kind: ToolActivityKind.policyEvaluated,
            effects: effects,
            policyDecision: i == 1
                ? ToolActivityPolicyDecision.deny
                : i == 3
                ? ToolActivityPolicyDecision.allow
                : ToolActivityPolicyDecision.ask,
          ),
          if (i == 0 || i == 2) ...[
            ToolActivityChange(
              sequence: start + 2,
              kind: ToolActivityKind.approvalRequested,
              effects: effects,
              interruptionId: interruption,
            ),
            ToolActivityChange(
              sequence: start + 4,
              kind: ToolActivityKind.approvalResolved,
              interruptionId: interruption,
              approved: i == 0,
            ),
          ],
          if (i == 0 || i == 3) ...[
            ToolActivityChange(
              sequence: start + 6,
              kind: ToolActivityKind.executionStarted,
            ),
            ToolActivityChange(
              sequence: start + 7,
              kind: ToolActivityKind.progress,
              progress: ToolProgress(content: 'Progress $i'),
            ),
          ],
          ToolActivityChange(
            sequence: start + 8,
            kind: ToolActivityKind.completed,
            outcome: outcome,
          ),
        ],
      ),
    );
  }
  return RunActivitySnapshot(
    runId: RunId('rich'),
    sessionId: sessionId,
    state: RunState.failed,
    sequence: 90,
    failure: failure,
    lifecycle: const [
      RunLifecycleActivity(sequence: 0, state: RunState.running),
      RunLifecycleActivity(sequence: 23, state: RunState.waiting),
      RunLifecycleActivity(sequence: 25, state: RunState.running),
      RunLifecycleActivity(sequence: 43, state: RunState.waiting),
      RunLifecycleActivity(sequence: 45, state: RunState.running),
      RunLifecycleActivity(sequence: 90, state: RunState.failed),
    ],
    models: [
      ModelInvocationActivity(
        id: model,
        startSequence: 2,
        terminalSequence: 12,
        settlement: ModelSettlement.completed,
        metadata: ModelTerminalMetadata(
          effectiveModel: 'SECRET model',
          providerNativeState: native,
          usage: ModelUsage(
            inputTokens: 9,
            providerDetails: {'private': 'SECRET usage'},
          ),
        ),
        outputs: [
          ModelOutputActivity(
            sequence: 3,
            item: ModelTextOutput(
              'Retained text',
              providerItemId: 'text-item',
              providerNativeMetadata: native,
            ),
          ),
          ModelOutputActivity(
            sequence: 4,
            item: ModelNativeOutput(
              providerItemId: 'native-item',
              providerNativeMetadata: native,
              presentation: ModelNativePresentation(
                kind: 'test.summary',
                compactText: 'SECRET native-only presentation',
                data: const {'private': 'SECRET presentation data'},
              ),
            ),
          ),
          for (var i = 0; i < proposals.length; i++)
            ModelOutputActivity(
              sequence: 6 + i,
              item: ModelToolProposalOutput(
                proposals[i],
                providerItemId: 'proposal-$i',
                providerNativeMetadata: native,
              ),
            ),
        ],
      ),
      ModelInvocationActivity(
        id: ModelInvocationId('rich-failed-model'),
        startSequence: 70,
        terminalSequence: 75,
        failure: failure,
      ),
    ],
    tools: tools,
    rejectedProposals: [
      RejectedToolProposalActivity(
        sequence: 60,
        modelInvocationId: model,
        proposalSequence: 10,
        proposal: proposals[4],
        kind: ToolProposalFailureKind.unknownAlias,
        message: 'Unavailable alias',
      ),
    ],
  );
}

void _expectRich(RunActivitySnapshot activity) {
  expect(activity.state, RunState.failed);
  expect(activity.sequence, 90);
  expect(activity.lifecycle.map((item) => (item.sequence, item.state)), [
    (0, RunState.running),
    (23, RunState.waiting),
    (25, RunState.running),
    (43, RunState.waiting),
    (45, RunState.running),
    (90, RunState.failed),
  ]);
  expect(activity.failure!.kind, 'transport');
  expect(activity.failure!.message, 'Connection lost');
  expect(activity.failure!.providerCode, 'lost');
  expect(activity.models.last.failure!.providerCode, 'lost');
  final model = activity.models.first;
  expect(model.id, ModelInvocationId('rich-model'));
  expect((model.startSequence, model.terminalSequence), (2, 12));
  expect(model.settlement, ModelSettlement.completed);
  expect(model.outputs.map((item) => item.sequence), [3, 6, 7, 8, 9, 10, 11]);
  expect(
    (model.outputs.first.item as ModelTextOutput).content,
    'Retained text',
  );
  expect(
    (model.outputs.first.item as ModelTextOutput).providerItemId,
    'text-item',
  );
  expect(model.metadata, isNull);
  expect(activity.tools, hasLength(4));
  for (var i = 0; i < activity.tools.length; i++) {
    final tool = activity.tools[i];
    final proposal = model.outputs[i + 1].item as ModelToolProposalOutput;
    expect(tool.modelInvocationId, model.id);
    expect(tool.proposalSequence, model.outputs[i + 1].sequence);
    expect(tool.id, ToolInvocationId('tool-$i'));
    expect(tool.toolId, ToolId('test.tool.$i'));
    expect(tool.alias, proposal.proposal.alias);
    expect(tool.providerCallId, proposal.proposal.providerCallId);
    expect(proposal.providerItemId, 'proposal-$i');
    expect(proposal.proposal.arguments, {'raw': i});
    expect(tool.canonicalArguments, {'normalized': i});
    expect(tool.effects!.summary, 'Write result');
    expect(tool.effects!.effects, [ToolEffect.sourceMutation]);
    expect(
      tool.effects!.targets.single.uri,
      Uri.parse('file:///source/result'),
    );
    expect(tool.effects!.uncertainty, EffectUncertainty.uncertain);
    expect(tool.outcome!.modelContent, 'Outcome $i');
    expect(tool.outcome!.hostData, isEmpty);
    expect(tool.changes.first.sequence, tool.preparedSequence);
    final executed = i == 0 || i == 3;
    expect(
      tool.changes.where(
        (item) => item.kind == ToolActivityKind.executionStarted,
      ),
      executed ? hasLength(1) : isEmpty,
    );
    expect(
      tool.changes
          .where((item) => item.kind == ToolActivityKind.progress)
          .map((item) => item.progress!.content),
      executed ? ['Progress $i'] : isEmpty,
    );
    if (i == 0 || i == 2) {
      final approval = tool.changes.singleWhere(
        (item) => item.kind == ToolActivityKind.approvalResolved,
      );
      expect(approval.interruptionId, RunInterruptionId('approval-$i'));
      expect(approval.approved, i == 0);
    }
  }
  expect(activity.tools.map((tool) => tool.outcome!.disposition), [
    ToolOutcomeDisposition.success,
    ToolOutcomeDisposition.policyDenied,
    ToolOutcomeDisposition.userRejected,
    ToolOutcomeDisposition.failure,
  ]);
  expect(activity.tools.map((tool) => tool.outcome!.effectCertainty), [
    EffectCertainty.knownOccurred,
    EffectCertainty.knownNotOccurred,
    EffectCertainty.knownNotOccurred,
    EffectCertainty.uncertain,
  ]);
  expect(
    activity.tools.last.outcome!.failureKind,
    ToolFailureKind.infrastructure,
  );
  expect(
    activity.tools[1].changes[1].policyDecision,
    ToolActivityPolicyDecision.deny,
  );
  final rejected = activity.rejectedProposals.single;
  expect(rejected.modelInvocationId, model.id);
  expect((rejected.sequence, rejected.proposalSequence), (60, 10));
  expect(rejected.kind, ToolProposalFailureKind.unknownAlias);
  expect(rejected.message, 'Unavailable alias');
  expect(rejected.proposal.providerCallId, 'call-4');
  expect(rejected.proposal.arguments, {'raw': 4});
  expect(
    activity.tools.where((tool) => tool.providerCallId == 'call-4'),
    isEmpty,
  );
  final proposedOnly = model.outputs.last.item as ModelToolProposalOutput;
  expect(proposedOnly.proposal.providerCallId, 'call-5');
  expect(proposedOnly.proposal.arguments, {'raw': 5});
  expect(
    activity.tools.where((tool) => tool.providerCallId == 'call-5'),
    isEmpty,
  );
  expect(
    activity.rejectedProposals.where(
      (item) => item.proposal.providerCallId == 'call-5',
    ),
    isEmpty,
  );
}

void _registerProviders(
  AdeleRuntime runtime,
  _ProviderChannel channel, {
  bool environment = false,
}) {
  for (final descriptor in [
    ProviderDescriptor(
      id: _projectProvider,
      capability: projectProviderCapability,
      pluginId: 'test.provider',
      displayName: 'Project',
      serviceId: projectProviderServiceId,
    ),
    if (environment)
      ProviderDescriptor(
        id: _environmentProvider,
        capability: environmentProviderCapability,
        pluginId: 'test.provider',
        displayName: 'Environment',
        serviceId: environmentProviderServiceId,
      ),
  ]) {
    final registration = runtime.registry.register(
      provider: descriptor,
      endpoint: AdeleRequestChannelEndpoint(
        channel: channel,
        serviceId: descriptor.serviceId,
        isAvailable: () => true,
      ),
    );
    addTearDown(registration.close);
  }
}

final class _ProviderChannel implements AdeleRequestChannel {
  int environmentCalls = 0;
  @override
  Future<Object?> request(String method, Map<String, Object?> payload) async {
    if (method == projectProviderServicePrepareSourceId) {
      return {
        'sourceLocation': payload['sourceLocation'],
        'databaseRelativePath': '.adele/data.db',
      };
    }
    expect(method, environmentProviderServiceEstablishId);
    environmentCalls++;
    return {'providerState': <String, Object?>{}, 'initialState': null};
  }
}

final class _Model implements ModelPort {
  bool fail = false;
  final requests = <SemanticModelRequest>[];
  @override
  Stream<ModelEvent> invoke(SemanticModelRequest request) async* {
    requests.add(request);
    yield ModelOutputItemCompleted(
      invocationId: request.invocationId,
      item: ModelTextOutput(
        'Actual previous output',
        providerItemId: 'actual-text',
      ),
    );
    if (fail) {
      yield ModelInvocationFailedEvent(
        invocationId: request.invocationId,
        error: ModelFailure(
          kind: ModelFailureKind.providerFailure,
          providerCode: 'seed_failure',
          providerMessage: 'Seed failure',
          providerDetails: const {'private': 'SECRET actual provider details'},
        ),
      );
    } else {
      yield ModelInvocationSettledEvent(invocationId: request.invocationId);
    }
  }
}

final class _NoTools implements ToolPolicy {
  const _NoTools();
  @override
  ToolPolicyDecision evaluate(ToolPolicyInput input) =>
      throw StateError('Reading history must not execute tools or policy.');
}
