@Timeout(Duration(minutes: 3))
library;

import 'dart:io';

import 'package:adele_capabilities/adele_capabilities.dart';
import 'package:adele_contract/adele_contract.dart';
import 'package:adele_desktop/core/adele_runtime.dart';
import 'package:adele_desktop/core/application_plugin_bootstrap.dart';
import 'package:adele_desktop/core/backend_configuration_host.dart';
import 'package:adele_desktop/core/global_settings_service.dart';
import 'package:adele_desktop/core/prepared_settings.dart';
import 'package:adele_desktop/core/product_lifecycle.dart';
import 'package:adele_desktop/core/project_storage_host.dart';
import 'package:adele_desktop/core/remote_inference_context_host.dart';
import 'package:adele_desktop/frontend/application_frontend_bootstrap.dart';
import 'package:adele_desktop/ui/main_content/main_content_host.dart';
import 'package:adele_environment/adele_environment.dart';
import 'package:adele_orchestration/adele_orchestration.dart';
import 'package:adele_orchestration/remote_inference_context.dart';
import 'package:adele_platform_storage/adele_platform_storage.dart';
import 'package:adele_plugin_api/adele_plugin_api.dart';
import 'package:adele_plugin_backend_support/adele_backend_configuration.dart';
import 'package:adele_product/adele_product.dart';
import 'package:adele_project_storage/adele_project_storage.dart';
import 'package:adele_settings/adele_settings.dart';
import 'package:adele_ui/adele_ui.dart';
import 'package:agent_configuration_contract/agent_configuration_contract.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plugin_builder/plugin_builder.dart';
import 'package:plugin_runtime/plugin_runtime.dart';
import 'package:sqlite3/sqlite3.dart' hide Session;

import '../../../tools/backend_artifacts.dart';
import '../support/agent_selector_installation.dart';
import '../support/gated_project_storage.dart';
import '../support/selection_sessions.dart';

const _plugin = agentConfigurationPluginId;
const _instructionsSource = '$_plugin.instructions';
const _projectPlugin = 'dev.adele.plugin.local-directory-project';
const _bound = Duration(seconds: 15);
final _type = RecordTypeId('$_plugin.agent');
final _projectProvider = ProviderId('dev.adele.project.local-directory');
final _strategy = OrchestrationStrategyId('test.agent-selection.strategy');

void main() {
  late Directory installations;
  late File host;
  late String aotRuntime;

  setUpAll(() async {
    final artifacts = await _temporary('agent-selection-aot-');
    installations = Directory('${artifacts.path}/installations');
    host = File('${artifacts.path}/host.aot');
    final repository = Directory.current.parent;
    final dart =
        '${Platform.environment['FLUTTER_ROOT']!}/bin/cache/dart-sdk/bin/dart';
    aotRuntime = File(dart).parent.uri.resolve('dartaotruntime').toFilePath();
    await compileAotSnapshot(
      dartExecutable: dart,
      workingDirectory: repository,
      entrypoint: 'packages/plugin_backend_host/bin/adele_backend_host.dart',
      artifact: host,
      stage: 'agent-selection-host',
    );
    for (final (id, entrypoint) in const [
      (
        _plugin,
        'plugins/agent_configuration/packages/backend/bin/agent_configuration_backend.dart',
      ),
      (
        _projectPlugin,
        'plugins/local_directory_project/packages/backend/bin/local_directory_project_backend.dart',
      ),
    ]) {
      final directory = Directory('${installations.path}/$id');
      await compileAotSnapshot(
        dartExecutable: dart,
        workingDirectory: repository,
        entrypoint: entrypoint,
        artifact: File('${directory.path}/backend.aot'),
        stage: 'agent-selection-$id',
      );
      await publishStockPluginInstallation(
        repositoryRoot: repository,
        installationDirectory: directory,
        pluginId: id,
        displayName: id,
        backend: true,
      );
    }
  });

  Future<_Fixture> start({
    ProductIdSource? ids,
    PlatformStorageRoots? roots,
    Directory? selectorInstallations,
  }) async {
    if (roots == null) {
      final temporary = await _temporary('agent-selection-settings-');
      roots = PlatformStorageRoots(
        operatingSystem: Platform.operatingSystem,
        configurationRoot: '${temporary.path}/config',
        localStateRoot: '${temporary.path}/state',
        localDataRoot: '${temporary.path}/data',
        cacheRoot: '${temporary.path}/cache',
      );
    }
    final fixture = _Fixture(roots, ids: ids);
    addTearDown(fixture.close);
    await fixture.bootstrap.start(
      installationRoot: (selectorInstallations ?? installations).path,
      dartaotruntimeExecutable: aotRuntime,
      hostArtifactPath: host.path,
      startupArguments: const {},
    );
    expect(fixture.bootstrap.state, ApplicationPluginState.ready);
    expect(fixture.bootstrap.failure, isNull);
    expect(fixture.bootstrap.catalog!.issues, isEmpty);
    expect(fixture.bootstrap.backends, hasLength(2));
    for (final backend in fixture.bootstrap.backends) {
      expect(
        backend.state,
        InstalledBackendState.active,
        reason: '${backend.failure}',
      );
    }
    final backend = fixture.bootstrap.backends.singleWhere(
      (backend) => backend.installation.metadata.id.value == _plugin,
    );
    expect(
      backend.installation.frontend,
      selectorInstallations == null ? isNull : isNotNull,
    );
    expect(backend.installation.backendConsumedRecordTypes, [_type]);
    expect(backend.installation.backendConsumedCredentialSlots, isEmpty);
    expect(backend.installation.backendConsumedCapabilities, isEmpty);
    fixture.agent = backend.connection!;
    _expectSourceExposure(fixture.agent);
    final binding = fixture.runtime.extensions
        .discover(inferenceContextSources)
        .single;
    expect(binding.id.value, _instructionsSource);
    expect(binding.value.failureMode, InferenceContextFailureMode.required);
    expect(binding.value.captureRun, isNotNull);
    expect(backend.extensionOrigin(binding)!.connection, same(fixture.agent));
    expect(fixture.recordReads, 0);
    return fixture;
  }

  test('durable selections survive replacement and reopen without a Run', () async {
    final source = await _temporary('agent-selection-project-');
    final fixture = await start();
    final graph = await fixture.createGraph(source);
    final session = graph.session.id.value;
    final other = graph.otherSession.id.value;
    final core = _inspect(source, _coreRows);
    final reviewer = await fixture.createAgent('reviewer');
    await fixture.createAgent('writer');
    final client = fixture.client;
    expect(_fields(await client.readSessionSelection(session)), (
      session,
      null,
      0,
    ));
    expect(_fields(await client.readSessionSelection(other)), (other, null, 0));
    expect(_inspect(source, _selectionRows), isEmpty);
    expect(
      fixture.recordReads,
      0,
      reason: 'Reading selection does not read Agents.',
    );

    final selected = await client.updateSessionSelection(
      session,
      'reviewer',
      0,
    );
    expect(_fields(selected), (session, 'reviewer', 1));
    expect(_fields(await client.readSessionSelection(other)), (other, null, 0));
    final sibling = await client.updateSessionSelection(other, 'writer', 0);
    expect(_fields(sibling), (other, 'writer', 1));
    await fixture.settings.updateRecord(reviewer, {
      'name': 'Renamed reviewer',
      'instructions': 'Changed instructions do not replace a Session strategy.',
    });
    expect(
      _fields(await client.readSessionSelection(session)),
      _fields(selected),
    );
    final rows = _inspect(source, _selectionRows);
    expect(rows, hasLength(2));
    await expectLater(
      client.updateSessionSelection(session, 'writer', 0),
      _failure('stale_revision'),
    );
    expect(_inspect(source, _selectionRows), rows);
    expect(_inspect(source, _coreRows), core);
    _expectNoExecution(fixture.runtime, graph);
    expect(
      _inspect(
        source,
        (db) => _rows(
          db,
          "SELECT owner_id, version FROM adele_schema_versions WHERE owner_id = '$_plugin'",
        ),
      ),
      [
        {'owner_id': _plugin, 'version': 1},
      ],
    );
    final foreignKey = _inspect(
      source,
      (db) => _rows(db, 'PRAGMA foreign_key_list(adele_agent_selections)'),
    ).single;
    expect(foreignKey['table'], 'adele_product_sessions');
    expect(foreignKey['from'], 'session_id');
    expect(foreignKey['to'], 'id');

    final oldConnection = fixture.agent;
    await fixture.replaceAgent();
    expect(oldConnection.isClosed, isTrue);
    expect(fixture.bootstrap.host!.isClosed, isFalse);
    await expectLater(
      client.readSessionSelection(session),
      throwsA(isA<PluginConnectionClosed>()),
    );
    expect(
      _fields(await fixture.client.readSessionSelection(session)),
      _fields(selected),
    );
    expect(
      _fields(await fixture.client.readSessionSelection(other)),
      _fields(sibling),
    );
    expect(_inspect(source, _selectionRows), rows);
    await fixture.close();

    final ids = _NoAllocationIds();
    final fresh = await start(ids: ids, roots: fixture.roots);
    // A durable row is not sufficient authority before its Project is published.
    await expectLater(
      fresh.client.readSessionSelection(session),
      _failure('storage_unavailable'),
    );
    final reopened = await fresh.openProject(source);
    expect(reopened.id, graph.project.id);
    expect(reopened, isNot(same(graph.project)));
    expect(
      fresh.runtime.store.session(graph.session.id),
      isNot(same(graph.session)),
    );
    expect(
      _fields(await fresh.client.readSessionSelection(session)),
      _fields(selected),
    );
    expect(
      _fields(await fresh.client.readSessionSelection(other)),
      _fields(sibling),
    );
    expect(ids.calls, 0);
    expect(
      fresh.runtime.lifecycle.environmentRuntime.currentMaterialization(
        graph.environment.id,
      ),
      isNull,
    );
    expect(_inspect(source, _coreRows), core);
    expect(_inspect(source, _selectionRows), rows);
    _expectNoExecution(fresh.runtime, graph);
  });

  test(
    'volatile selections use real SQL for only the Project lifetime',
    () async {
      final source = await _temporary('agent-selection-volatile-');
      final fixture = await start(
        ids: MonotonicProductIdSource(seed: 'volatile-agent'),
      );
      final graph = await fixture.createGraph(source, volatile: true);
      expect(
        fixture.runtime.lifecycle.existingDatabaseForProject(graph.project),
        isNull,
      );
      await fixture.createAgent('reviewer');
      final selected = await fixture.client.updateSessionSelection(
        graph.session.id.value,
        'reviewer',
        0,
      );
      final database = fixture.runtime.lifecycle.existingDatabaseForProject(
        graph.project,
      )!;
      final path = File(database.path);
      expect(path.existsSync(), isTrue);
      expect(path.path, isNot(startsWith(source.path)));
      expect(
        fixture.runtime.lifecycle.databaseForSession(graph.session.id),
        isNull,
      );
      expect(
        database
            .queryPluginRows('SELECT * FROM adele_agent_selections', {})
            .single
            .values,
        {
          'session_id': graph.session.id.value,
          'selected_agent_id': 'reviewer',
          'revision': 1,
        },
      );
      await fixture.replaceAgent();
      expect(
        _fields(
          await fixture.client.readSessionSelection(graph.session.id.value),
        ),
        _fields(selected),
      );
      expect(
        fixture.runtime.lifecycle.existingDatabaseForProject(graph.project),
        same(database),
      );
      _expectNoExecution(fixture.runtime, graph);
      await fixture.close();
      expect(path.existsSync(), isFalse);
      expect(path.parent.existsSync(), isFalse);
      expect(File('${source.path}/.adele/data.db').existsSync(), isFalse);

      final fresh = await start(
        ids: MonotonicProductIdSource(seed: 'volatile-agent'),
      );
      final recreated = await fresh.createGraph(source, volatile: true);
      expect(recreated.project.id, graph.project.id);
      expect(recreated.session.id, graph.session.id);
      expect(
        _fields(
          await fresh.client.readSessionSelection(recreated.session.id.value),
        ),
        (graph.session.id.value, null, 0),
      );
      expect(
        fresh.runtime.lifecycle
            .existingDatabaseForProject(recreated.project)!
            .path,
        isNot(path.path),
      );
      _expectNoExecution(fresh.runtime, recreated);
    },
  );

  test(
    'Settings deletion preserves selection; read and clear need no catalog',
    () async {
      final source = await _temporary('agent-selection-catalog-');
      final fixture = await start();
      final graph = await fixture.createGraph(source);
      final session = graph.session.id.value;
      final record = await fixture.createAgent('reviewer');
      final catalog = fixture.catalog;
      expect((await catalog.readAgents()).agents.single.id, 'reviewer');
      await fixture.client.updateSessionSelection(session, 'reviewer', 0);
      await fixture.settings.deleteRecord(record);
      expect((await catalog.readAgents()).agents, isEmpty);
      expect(_fields(await fixture.client.readSessionSelection(session)), (
        session,
        'reviewer',
        1,
      ));
      final before = _inspect(source, _selectionRows);
      await expectLater(
        fixture.client.updateSessionSelection(session, 'reviewer', 1),
        _failure('agent_not_found'),
      );
      expect(_inspect(source, _selectionRows), before);

      final agents = Directory('${fixture.roots.configurationRoot}/agents');
      final broken = File('${agents.path}/broken.toml');
      const invalid = 'invalid = [ # private diagnostic';
      await broken.writeAsString(invalid);
      await expectLater(
        fixture.client.updateSessionSelection(session, 'missing', 1),
        _failure('catalog_incomplete'),
      );
      expect(_inspect(source, _selectionRows), before);
      expect(await broken.readAsString(), invalid);
      await fixture.createAgent('writer');
      // A valid observed definition remains selectable in a partial catalog.
      expect(
        _fields(
          await fixture.client.updateSessionSelection(session, 'writer', 1),
        ),
        (session, 'writer', 2),
      );
      final partialRows = _inspect(source, _selectionRows);

      await agents.rename('${agents.path}-saved');
      final obstruction = await File(
        agents.path,
      ).writeAsString('private obstruction');
      await expectLater(
        fixture.client.updateSessionSelection(session, 'writer', 2),
        _failure('catalog_unavailable'),
      );
      expect(_inspect(source, _selectionRows), partialRows);
      final reads = fixture.recordReads;
      expect(_fields(await fixture.client.readSessionSelection(session)), (
        session,
        'writer',
        2,
      ));
      expect(
        _fields(await fixture.client.updateSessionSelection(session, null, 2)),
        (session, null, 3),
      );
      await expectLater(
        fixture.client.updateSessionSelection(session, null, 2),
        _failure('stale_revision'),
      );
      expect(_fields(await fixture.client.readSessionSelection(session)), (
        session,
        null,
        3,
      ));
      expect(fixture.recordReads, reads);
      expect(await obstruction.readAsString(), 'private obstruction');
      await fixture.replaceAgent();
      expect(_fields(await fixture.client.readSessionSelection(session)), (
        session,
        null,
        3,
      ));
      expect(_inspect(source, _selectionRows).single, {
        'session_id': session,
        'selected_agent_id': null,
        'revision': 3,
      });
      _expectNoExecution(fixture.runtime, graph);
    },
  );

  test(
    'host rejects unknown, unpublished, foreign and unavailable Sessions',
    () async {
      final source = await _temporary('agent-selection-authority-');
      final fixture = await start(
        ids: MonotonicProductIdSource(seed: 'local-agent'),
      );
      final graph = await fixture.createGraph(source);
      final foreignSource = await _temporary('agent-selection-foreign-');
      final foreign = await start(
        ids: MonotonicProductIdSource(seed: 'foreign-agent'),
      );
      final foreignGraph = await foreign.createGraph(foreignSource);
      final unpublished = Session(
        id: SessionId('unpublished-agent-session'),
        taskId: graph.session.taskId,
        strategyId: _strategy,
      );
      final schema = _inspect(
        source,
        (db) => _rows(db, 'SELECT name, sql FROM sqlite_master ORDER BY name'),
      );
      final core = _inspect(source, _coreRows);
      for (final id in [
        'unknown-agent-session',
        unpublished.id.value,
        foreignGraph.session.id.value,
      ]) {
        expect(fixture.runtime.store.session(SessionId(id)), isNull);
        await expectLater(
          fixture.client.readSessionSelection(id),
          _failure('storage_unavailable'),
        );
        await expectLater(
          fixture.client.updateSessionSelection(id, null, 0),
          _failure('storage_unavailable'),
        );
      }
      expect(
        _inspect(
          source,
          (db) =>
              _rows(db, 'SELECT name, sql FROM sqlite_master ORDER BY name'),
        ),
        schema,
      );
      expect(_inspect(source, _coreRows), core);
      expect(fixture.recordReads, 0);
      expect(
        fixture.probe.calls,
        everyElement(projectStorageServiceEnsureSchemaForSessionId),
      );
      await fixture.runtime.lifecycle.close();
      await expectLater(
        fixture.client.readSessionSelection(graph.session.id.value),
        _failure('storage_unavailable'),
      );
      await expectLater(
        fixture.client.updateSessionSelection(graph.session.id.value, null, 0),
        _failure('storage_unavailable'),
      );
      expect(_inspect(source, _coreRows), core);
    },
  );

  test(
    'closed durable storage does not fall back to temporary or cached state',
    () async {
      final source = await _temporary('agent-selection-unavailable-');
      final fixture = await start();
      final graph = await fixture.createGraph(source);
      final session = graph.session.id.value;
      await fixture.createAgent('reviewer');
      await fixture.client.updateSessionSelection(session, 'reviewer', 0);
      final before = _inspect(source, _selectionRows);
      final database = fixture.runtime.lifecycle.databaseForSession(
        graph.session.id,
      )!;
      database.close();
      await expectLater(
        fixture.client.readSessionSelection(session),
        _failure('storage_unavailable'),
      );
      await expectLater(
        fixture.client.updateSessionSelection(session, null, 1),
        _failure('storage_unavailable'),
      );
      expect(
        fixture.runtime.lifecycle.existingDatabaseForProject(graph.project),
        same(database),
      );
      expect(_inspect(source, _selectionRows), before);
    },
  );

  for (final (column, value) in <(String, Object)>[
    ('selected_agent_id', '../private-agent'),
    ('revision', 0),
    ('revision', 2147483648),
    ('revision', 'invalid'),
  ]) {
    test('corrupt SQL $column=$value is rejected without repair', () async {
      final source = await _temporary('agent-selection-corrupt-');
      final fixture = await start();
      final graph = await fixture.createGraph(source);
      final session = graph.session.id.value;
      await fixture.createAgent('reviewer');
      await fixture.client.updateSessionSelection(session, 'reviewer', 0);
      _inspect(source, (db) {
        db.execute('PRAGMA ignore_check_constraints = ON');
        db.execute(
          'UPDATE adele_agent_selections SET $column = ? WHERE session_id = ?',
          [value, session],
        );
      });
      final corrupt = _inspect(source, _selectionRows);
      final core = _inspect(source, _coreRows);
      final before = fixture.probe.calls.length;
      for (var generation = 0; generation < 2; generation++) {
        await expectLater(
          fixture.client.readSessionSelection(session),
          _failure('corrupt_state'),
        );
        await expectLater(
          fixture.client.updateSessionSelection(session, null, 1),
          _failure('corrupt_state'),
        );
        expect(_inspect(source, _selectionRows), corrupt);
        expect(_inspect(source, _coreRows), core);
        if (generation == 0) {
          expect(
            fixture.probe.calls.skip(before),
            isNot(contains(projectStorageServiceTransactionForSessionId)),
          );
          await fixture.replaceAgent();
        }
      }
    });
  }

  for (final expectedRevision in [0, 1]) {
    test(
      'actual transaction CAS at revision $expectedRevision cannot overwrite a later commit',
      () async {
        final source = await _temporary('agent-selection-cas-');
        final fixture = await start();
        final graph = await fixture.createGraph(source);
        final session = graph.session.id.value;
        await fixture.createAgent('reviewer');
        await fixture.createAgent('writer');
        await fixture.client.readSessionSelection(session);
        if (expectedRevision == 1) {
          await fixture.client.updateSessionSelection(session, 'reviewer', 0);
        }
        final before = fixture.probe.calls.length;
        final gate = fixture.probe.holdTransaction();
        addTearDown(gate.release);
        final failed = expectLater(
          fixture.client.updateSessionSelection(
            session,
            'writer',
            expectedRevision,
          ),
          _failure('outcome_uncertain'),
        );
        await gate.entered.future.timeout(_bound);
        // Another authoritative writer wins after the backend's preflight read.
        await ProjectStorageHost(
          lifecycle: fixture.runtime.lifecycle,
          owner: PluginId(_plugin),
          validateAccess: fixture.agent.validateInfrastructureContext,
        ).transactionForSession(session, [
          RelationalStatement(
            sql: expectedRevision == 0
                ? 'INSERT INTO adele_agent_selections (session_id, selected_agent_id, revision) VALUES (:session, NULL, :next)'
                : 'UPDATE adele_agent_selections SET selected_agent_id = NULL, revision = :next WHERE session_id = :session',
            parameters: {':session': session, ':next': expectedRevision + 1},
            expectedRows: 1,
          ),
        ], ProjectStorageAccessMode.durableOrTemporary);
        final committed = _inspect(source, _selectionRows);
        gate.release();
        await gate.settled.future.timeout(_bound);
        await failed.timeout(_bound);
        expect(
          fixture.probe.calls
              .skip(before)
              .where(
                (call) => call == projectStorageServiceTransactionForSessionId,
              ),
          hasLength(1),
        );
        expect(_inspect(source, _selectionRows), committed);
        expect(
          fixture.runtime.lifecycle
              .databaseForSession(graph.session.id)!
              .autocommit,
          isTrue,
        );
        expect(_fields(await fixture.client.readSessionSelection(session)), (
          session,
          null,
          expectedRevision + 1,
        ));
        await expectLater(
          fixture.client.updateSessionSelection(
            session,
            'writer',
            expectedRevision,
          ),
          _failure('stale_revision'),
        );
        expect(
          _fields(
            await fixture.client.updateSessionSelection(
              session,
              'writer',
              expectedRevision + 1,
            ),
          ),
          (session, 'writer', expectedRevision + 2),
        );
      },
    );
  }

  for (final afterCommit in [false, true]) {
    test(
      '${afterCommit ? 'lost commit acknowledgement' : 'retirement before SQL'} never retries and fresh reads reconcile',
      () async {
        final source = await _temporary('agent-selection-ack-');
        final fixture = await start();
        final graph = await fixture.createGraph(source);
        final session = graph.session.id.value;
        await fixture.createAgent('reviewer');
        await fixture.client.readSessionSelection(session);
        final core = _inspect(source, _coreRows);
        final probe = fixture.probe;
        final before = probe.calls.length;
        final gate = probe.holdTransaction(afterCommit: afterCommit);
        addTearDown(gate.release);
        final client = fixture.client;
        final failed = expectLater(
          client.updateSessionSelection(session, 'reviewer', 0),
          _failure('outcome_uncertain'),
        );
        await gate.entered.future.timeout(_bound);
        final durable = _inspect(source, _selectionRows);
        expect(durable, hasLength(afterCommit ? 1 : 0));
        fixture.agent.revokeInfrastructureContext();
        await failed.timeout(_bound);
        gate.release();
        await gate.settled.future.timeout(_bound);
        expect(
          probe.calls
              .skip(before)
              .where(
                (call) => call == projectStorageServiceTransactionForSessionId,
              ),
          hasLength(1),
        );
        await expectLater(
          client.readSessionSelection(session),
          _failure('storage_unavailable'),
        );
        expect(_inspect(source, _selectionRows), durable);
        await fixture.replaceAgent();
        await expectLater(
          client.readSessionSelection(session),
          throwsA(isA<PluginConnectionClosed>()),
        );
        final recovered = await fixture.client.readSessionSelection(session);
        expect(_fields(recovered), (
          session,
          afterCommit ? 'reviewer' : null,
          afterCommit ? 1 : 0,
        ));
        expect(_inspect(source, _selectionRows), durable);
        await fixture.close();
        final fresh = await start(
          ids: _NoAllocationIds(),
          roots: fixture.roots,
        );
        await fresh.openProject(source);
        expect(
          _fields(await fresh.client.readSessionSelection(session)),
          _fields(recovered),
        );
        expect(_inspect(source, _selectionRows), durable);
        expect(_inspect(source, _coreRows), core);
        _expectNoExecution(fresh.runtime, graph);
      },
    );
  }

  group('compiled Agent inference source', () {
    late Directory source;
    late _Fixture fixture;
    late Session session;
    late RunId runId;
    late InferenceContextComposer composer;

    setUp(() async {
      fixture = await start();
      source = await _temporary('agent-inference-project-');
      session = (await fixture.createGraph(source)).session;
      composer = InferenceContextComposer(fixture.runtime.extensions);
      runId = RunId('agent-run');
    });

    Future<InferenceContextRunBindings> capture() =>
        composer.captureRun(session, runId).timeout(_bound);

    Future<InferenceContextSnapshot> compose(
      InferenceContextRunBindings bindings,
    ) async {
      final context = _NoHostServices(session, runId);
      try {
        return await composer
            .compose(
              strategyMaterial: StrategyInferenceMaterial(input: const []),
              sourceContext: context,
              runBindings: bindings,
            )
            .timeout(_bound);
      } finally {
        expect(
          context.requests,
          isEmpty,
          reason:
              'Agent instructions require no Environment read or other host invocation service.',
        );
      }
    }

    Matcher requiredFailure(Matcher cause) => throwsA(
      isA<InferenceContextSourceFailed>()
          .having((e) => e.sourceId.value, 'source', _instructionsSource)
          .having((e) => e.cause, 'cause', cause),
    );

    test(
      'Run captures the Project selection and rereads its instructions after a Settings edit',
      () async {
        const firstText = '\n# Review\n\n```dart\nreturn true;\n```\n';
        const secondText = '  Revised reviewer instructions.\n';
        final reviewer = await fixture.createAgent(
          'reviewer',
          instructions: firstText,
        );
        await fixture.createAgent('writer');
        await fixture.client.updateSessionSelection(
          session.id.value,
          'reviewer',
          0,
        );
        expect(_inspect(source, _selectionRows).single, {
          'session_id': session.id.value,
          'selected_agent_id': 'reviewer',
          'revision': 1,
        });

        final reads = fixture.recordReads;
        final before = fixture.probe.calls.length;
        final bindings = await capture();
        expect(
          fixture.probe.calls
              .skip(before)
              .where(
                (method) => method == projectStorageServiceQueryForSessionId,
              ),
          hasLength(1),
        );
        expect(
          fixture.recordReads,
          reads,
          reason: 'Capture reads identity, not instructions.',
        );
        final first = await compose(bindings);
        expect(fixture.recordReads, reads + 1);
        final result = first.sourceResults.single;
        expect(result.sourceId.value, _instructionsSource);
        expect(result.status, InferenceContextSourceStatus.contributed);
        expect(result.materials.single.key, 'instructions');
        expect(result.materials.single.revision, isNull);
        expect(renderInferenceInstructions(first), firstText);

        await fixture.client.updateSessionSelection(
          session.id.value,
          'writer',
          1,
        );
        await fixture.settings.updateRecord(reviewer, {
          'name': 'Renamed reviewer',
          'instructions': secondText,
        });
        final afterSelection = fixture.probe.calls.length;
        final beforeSnapshot = fixture.recordReads;
        expect(
          renderInferenceInstructions(await compose(bindings)),
          secondText,
        );
        expect(fixture.recordReads, beforeSnapshot + 1);
        expect(
          fixture.probe.calls,
          hasLength(afterSelection),
          reason: 'Snapshot must not reread selection.',
        );
        expect(renderInferenceInstructions(first), firstText);
      },
    );

    test(
      'partial catalog uses the captured record; partial and complete absence fail without clearing selection',
      () async {
        final reviewer = await fixture.createAgent(
          'reviewer',
          instructions: 'Original reviewer.',
        );
        await fixture.createAgent('writer');
        await fixture.client.updateSessionSelection(
          session.id.value,
          'reviewer',
          0,
        );
        final bindings = await capture();
        final selected = _inspect(source, _selectionRows);
        final broken = await File(
          '${fixture.roots.configurationRoot}/agents/broken.toml',
        ).writeAsString('invalid = [');
        final catalog = fixture.catalog;
        expect((await catalog.readAgents()).isComplete, isFalse);
        expect(
          renderInferenceInstructions(await compose(bindings)),
          'Original reviewer.',
        );

        await fixture.settings.deleteRecord(reviewer);
        for (final complete in [false, true]) {
          if (complete) await broken.delete();
          final observed = await catalog.readAgents();
          expect(observed.isComplete, complete);
          expect(observed.agents.map((a) => a.id), ['writer']);
          await expectLater(
            compose(bindings),
            requiredFailure(isA<PluginRemoteFailure>()),
          );
          expect(_inspect(source, _selectionRows), selected);
        }
        await fixture.createAgent(
          'reviewer',
          instructions: 'Re-created reviewer.',
        );
        expect(
          renderInferenceInstructions(await compose(bindings)),
          'Re-created reviewer.',
        );
      },
    );

    test(
      'retirement fences the old Run; a new Run captures the same-ID replacement',
      () async {
        await fixture.createAgent(
          'first',
          instructions: 'First generation selection.',
        );
        await fixture.createAgent(
          'next',
          instructions: 'Replacement selection.',
        );
        await fixture.client.updateSessionSelection(
          session.id.value,
          'first',
          0,
        );
        final original = fixture.runtime.extensions
            .discover(inferenceContextSources)
            .single;
        final bindings = await capture();
        final first = await compose(bindings);
        final stale = requiredFailure(isA<StaleExtensionBinding>());

        await fixture.agent.close();
        await fixture.agent.terminated.timeout(_bound);
        expect(
          fixture.runtime.extensions.discover(inferenceContextSources),
          isEmpty,
        );
        await expectLater(compose(bindings), stale);
        await fixture.replaceAgent();
        final replacement = fixture.runtime.extensions
            .discover(inferenceContextSources)
            .single;
        expect(replacement.id, original.id);
        expect(
          replacement.registrationIdentity,
          isNot(same(original.registrationIdentity)),
        );
        expect(original.validate, throwsA(isA<StaleExtensionBinding>()));
        final reads = fixture.recordReads;
        await expectLater(compose(bindings), stale);
        expect(
          fixture.probe.calls,
          isEmpty,
          reason: 'The old Run never recaptured selection on the replacement.',
        );
        expect(
          fixture.recordReads,
          reads,
          reason: 'The old Run never called the replacement catalog.',
        );
        expect(
          renderInferenceInstructions(first),
          'First generation selection.',
        );

        await fixture.client.updateSessionSelection(
          session.id.value,
          'next',
          1,
        );
        runId = RunId('agent-replacement-run');
        expect(
          renderInferenceInstructions(await compose(await capture())),
          'Replacement selection.',
        );
      },
    );
  });

  group('compiled Agent selector', () {
    const location = SessionAccessoryLocation.executionConfiguration;
    late Directory withSelector;
    late _Fixture fixture;
    late SelectionGraph graph;
    late ApplicationFrontendBootstrap frontends;
    late Session current;

    setUpAll(() async {
      withSelector = await _temporary('agent-selector-installations-');
      for (final id in [_plugin, _projectPlugin]) {
        final directory = await Directory('${withSelector.path}/$id').create();
        await File(
          '${installations.path}/$id/backend.aot',
        ).copy('${directory.path}/backend.aot');
        if (id == _plugin) {
          await publishAgentSelector(directory);
        } else {
          const manifest = 'adele_plugin.installation.json';
          await File(
            '${installations.path}/$id/$manifest',
          ).copy('${directory.path}/$manifest');
        }
      }
    });

    setUp(() async {
      fixture = await start(selectorInstallations: withSelector);
      graph = await fixture.createGraph(
        await _temporary('agent-selector-project-'),
      );
      current = graph.session;
      frontends = ApplicationFrontendBootstrap(
        extensions: fixture.runtime.extensions,
        backends: fixture.bootstrap,
        loadSettings: (catalog) async =>
            PreparedSettingsSnapshot.resolve(catalog),
      );
      addTearDown(frontends.close);
      await frontends.start(fixture.bootstrap.catalog!);
      expect(
        frontends.generations.single.state,
        InstalledFrontendState.active,
        reason: '${frontends.generations.single.failure}',
      );
      final selector = fixture.runtime.extensions
          .discover(sessionAccessoryContributions)
          .single;
      expect(selector.id.value, '$_plugin.selector');
      expect(selector.value.location, location);
    });

    void registerPane({bool placeLocation = true}) {
      final pane = fixture.runtime.extensions.register(
        point: mainContentContributions,
        id: ExtensionId('test.non-chat.pane'),
        value: MainContentContribution(
          order: 0,
          attach: (access) {
            if (access.session.strategyId != _strategy) return;
            access.open(
              MainContentPane(
                id: 'main',
                title: 'Non-Chat strategy',
                createPresentation: () => placeLocation
                    ? access.buildSessionAccessoryLocation(location)
                    : const Text('Plain strategy pane'),
              ),
            );
          },
        ),
      );
      addTearDown(pane.close);
    }

    Future<void> present(WidgetTester tester, Session session) async {
      current = session;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: MainContentHost(
              extensions: fixture.runtime.extensions,
              session: session,
              isCurrent: () => identical(current, session),
            ),
          ),
        ),
      );
    }

    Future<void> until(
      WidgetTester tester,
      bool Function() ready,
      String reason,
    ) async {
      // Real AOT replies and widget-zone continuations both need to advance.
      final deadline = DateTime.now().add(_bound);
      while (!ready() && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(Duration.zero);
        await tester.pump();
      }
      expect(ready(), isTrue, reason: reason);
    }

    Future<void> waitForText(WidgetTester tester, String label) => until(
      tester,
      () => find.text(label).evaluate().isNotEmpty,
      'Waiting for "$label".',
    );

    Future<StorageTransactionGate> selectAndHold(WidgetTester tester) async {
      await fixture.createAgent('reviewer');
      await waitForText(tester, 'Agent: No Agent');
      await tester.tap(find.text('Agent: No Agent'));
      await waitForText(tester, 'reviewer');
      final gate = fixture.probe.holdTransaction(afterCommit: true);
      addTearDown(gate.release);
      await tester.tap(find.text('reviewer'));
      await until(
        tester,
        () => gate.entered.isCompleted,
        'Waiting for the committed selection.',
      );
      return gate;
    }

    testWidgets(
      'a strategy without the location never reads or shows the selector',
      (tester) async {
        registerPane(placeLocation: false);
        await present(tester, graph.session);
        await tester.pumpAndSettle();
        expect(find.text('Plain strategy pane'), findsOneWidget);
        expect(find.textContaining('Agent'), findsNothing);
        expect(fixture.recordReads, 0);
        expect(fixture.probe.calls, isEmpty);
      },
    );

    testWidgets(
      'a late update belongs to A after navigation to B',
      (tester) => tester.runAsync(() async {
        registerPane();
        final b = graph.otherSession.id.value;
        await fixture.createAgent('writer');
        await fixture.client.updateSessionSelection(b, 'writer', 0);
        await present(tester, graph.session);
        final gate = await selectAndHold(tester);
        await present(tester, graph.otherSession);
        // B's read can queue behind A's held acknowledgement, but not inherit it.
        await waitForText(tester, 'Loading Agents...');
        gate.release();
        await waitForText(tester, 'Agent: writer');
        expect(_fields(await fixture.client.readSessionSelection(b)), (
          b,
          'writer',
          1,
        ));
        expect(find.text('Agent: reviewer'), findsNothing);
        await present(tester, graph.session);
        await waitForText(tester, 'Agent: reviewer');
        _expectNoExecution(fixture.runtime, graph);
        expect(tester.takeException(), isNull);
      }),
    );

    for (final backendReplacement in [false, true]) {
      testWidgets(
        backendReplacement
            ? 'a mounted selector cannot refresh against a replacement backend'
            : 'retiring the selector during an update leaves its sibling interactive',
        (tester) => tester.runAsync(() async {
          registerPane();
          Session? invoked;
          final sibling = fixture.runtime.extensions.register(
            point: sessionAccessoryContributions,
            id: ExtensionId('test.independent.control'),
            value: SessionAccessoryContribution(
              location: location,
              order: 0,
              createPresentation: (access) => TextButton(
                onPressed: () => invoked = access.session,
                child: const Text('Sibling control'),
              ),
            ),
          );
          addTearDown(sibling.close);
          await present(tester, graph.session);
          final gate = await selectAndHold(tester);
          if (backendReplacement) {
            await fixture.replaceAgent();
          } else {
            await frontends.generations.single.close();
          }
          gate.release();
          await gate.settled.future.timeout(_bound);
          if (backendReplacement) {
            await waitForText(
              tester,
              'Change not confirmed. Refresh to check the current selection.',
            );
            final reads = fixture.recordReads;
            await tester.tap(find.text('Refresh'));
            await waitForText(tester, 'Agent selection is unavailable.');
            expect(fixture.recordReads, reads);
            expect(
              fixture.probe.calls,
              isEmpty,
              reason: 'The replacement was never called.',
            );
          } else {
            await tester.pumpAndSettle();
            expect(find.text('Refresh'), findsNothing);
            expect(find.textContaining('Agent:'), findsNothing);
          }
          await tester.tap(find.text('Sibling control'));
          expect(invoked, same(graph.session));
          final a = graph.session.id.value;
          expect(_fields(await fixture.client.readSessionSelection(a)), (
            a,
            'reviewer',
            1,
          ));
          expect(tester.takeException(), isNull);
        }),
      );
    }
  });
}

final class _Fixture {
  _Fixture(this.roots, {ProductIdSource? ids})
    : runtime = AdeleRuntime(ids: ids) {
    bootstrap = ApplicationPluginBootstrap(
      runtime.registry,
      runtime.extensions,
      createInfrastructureServices: _services,
      loadSettings: (catalog) async =>
          PreparedSettingsSnapshot.resolve(catalog),
      loadRecords: (catalog, installation) {
        _settings ??= GlobalSettingsService(
          catalog: catalog.settings,
          records: catalog.records,
          roots: roots,
        );
        return settings.loadStartupRecords(catalog, installation);
      },
      loadCurrentRecords: _loadCurrentRecords,
    );
  }

  final PlatformStorageRoots roots;
  final AdeleRuntime runtime;
  late final ApplicationPluginBootstrap bootstrap;
  late PluginBackendConnection agent;
  GlobalSettingsService? _settings;
  final _probes = <PluginBackendConnection, GatedProjectStorage>{};
  final _configurationHosts = <BackendConfigurationHost>[];
  int recordReads = 0;
  Future<void>? _closing;

  GlobalSettingsService get settings => _settings!;
  GatedProjectStorage get probe => _probes[agent]!;
  AgentCatalogServiceClient get catalog => AgentCatalogServiceClient(
    agent.channelFor(agent.defaultConfigurationContext, agentCatalogServiceId),
  );
  AgentSelectionServiceClient get client => AgentSelectionServiceClient(
    agent.channelFor(
      agent.defaultConfigurationContext,
      agentSelectionServiceId,
    ),
  );

  Future<StartupRecordsView> _loadCurrentRecords(
    PreparedPluginCatalog catalog,
    PreparedPluginInstallation installation,
  ) {
    recordReads++;
    return settings.loadCurrentRecords(catalog, installation);
  }

  Map<String, AdeleBackendDispatcher> _services(
    PluginBackendConnection connection,
  ) {
    final services = projectStorageServices(runtime.lifecycle, connection);
    final probe = GatedProjectStorage(services[projectStorageServiceId]!);
    _probes[connection] = probe;
    return {projectStorageServiceId: probe};
  }

  Future<RecordView> createAgent(String id, {String? instructions}) =>
      settings.createRecord(_type, ConfigurationRecordId(id), {
        'name': id,
        'instructions': instructions ?? '# $id\n\nReview the changes.',
      });

  Future<void> replaceAgent() async {
    final catalog = bootstrap.catalog!;
    final installation = catalog.installations.singleWhere(
      (entry) => entry.metadata.id.value == _plugin,
    );
    await agent.close();
    agent = await bootstrap.host!.startPlugin(
      pluginId: _plugin,
      artifactUri: installation.backendArtifactUri!,
      createInfrastructureServices: (connection) {
        final configuration = BackendConfigurationHost(
          connection: connection,
          catalog: catalog,
          installation: installation,
          loadRecords: _loadCurrentRecords,
        );
        _configurationHosts.add(configuration);
        return {
          ..._services(connection),
          backendConfigurationServiceId: configuration,
        };
      },
    );
    _expectSourceExposure(agent);
    final activation = await PluginBackendActivation.registerAdvertised(
      connection: agent,
      capabilities: runtime.registry,
      extensions: runtime.extensions,
      adapters: createRemoteExtensionAdapters(),
    );
    addTearDown(activation.close);
  }

  Future<Project> openProject(Directory source) =>
      runtime.lifecycle.openProject(
        sourceLocation: source.uri,
        provider: runtime.lifecycle.resolveProjectProvider(_projectProvider),
      );

  Future<SelectionGraph> createGraph(
    Directory source, {
    bool volatile = false,
  }) async => createSelectionSessions(
    runtime,
    volatile
        ? runtime.lifecycle.createProject(source.uri)
        : await openProject(source),
    _strategy,
  );

  Future<void> close() => _closing ??= _close();
  Future<void> _close() async {
    try {
      await bootstrap.close();
    } finally {
      try {
        await runtime.close();
      } finally {
        for (final probe in _probes.values) {
          await probe.close();
        }
        for (final configuration in _configurationHosts) {
          await configuration.close();
        }
        await _settings?.close();
      }
    }
  }
}

final class _NoHostServices implements InferenceContextSourceContext {
  _NoHostServices(this.session, this.runId);

  @override
  final Session session;
  @override
  final RunId runId;
  final requests = <Type>[];

  @override
  Future<T> requireHostService<T extends Object>() async {
    requests.add(T);
    throw UnsupportedError('Unexpected Agent inference service: $T');
  }
}

void _expectSourceExposure(PluginBackendConnection agent) {
  expect(agent.capabilityExposures, isEmpty);
  expect(agent.extensionExposures.single.toMap(), {
    'extensionPointId': inferenceContextSources.value,
    'extensionId': _instructionsSource,
    'serviceId': remoteRunBoundInferenceContextSourceServiceId,
    'configurationContext': 'default',
    'metadata': {'failureMode': 'required'},
  });
}

(String, String?, int) _fields(AgentSelectionSnapshot value) =>
    (value.sessionId, value.selectedAgentId, value.revision);

Matcher _failure(String code) => throwsA(
  isA<AgentSelectionFailure>()
      .having((failure) => failure.code, 'code', code)
      .having((failure) => failure.details, 'details', isEmpty),
);

void _expectNoExecution(AdeleRuntime runtime, SelectionGraph graph) {
  for (final original in [graph.session, graph.otherSession]) {
    final session = runtime.store.session(original.id)!;
    expect(session.strategyId, _strategy);
    expect(session.taskId, original.taskId);
    expect(runtime.store.runsForSession(session.id), isEmpty);
    expect(runtime.lifecycle.runActivitiesForSession(session.id), isEmpty);
    expect(
      () => runtime.lifecycle.resolveSessionStrategy(session.id),
      throwsA(isA<OrchestrationStrategyUnavailable>()),
    );
  }
  expect(runtime.registry.providersFor(environmentProviderCapability), isEmpty);
  expect(
    runtime.extensions.discover(orchestrationStrategyContributions),
    isEmpty,
  );
}

T _inspect<T>(Directory source, T Function(Database) inspect) {
  final database = sqlite3.open('${source.path}/.adele/data.db');
  try {
    return inspect(database);
  } finally {
    database.close();
  }
}

List<Map<String, Object?>> _rows(Database database, String sql) => [
  for (final row in database.select(sql)) Map<String, Object?>.from(row),
];

List<Map<String, Object?>> _selectionRows(Database database) =>
    _rows(database, 'SELECT * FROM adele_agent_selections ORDER BY session_id');

Map<String, Object?> _coreRows(Database database) => {
  for (final table in [
    'adele_product_projects',
    'adele_product_tasks',
    'adele_product_environments',
    'adele_product_sessions',
    'adele_product_session_environment_authority',
    'adele_product_runs',
  ])
    table: _rows(database, 'SELECT * FROM $table ORDER BY 1'),
};

final class _NoAllocationIds implements ProductIdSource {
  int calls = 0;
  Never _allocate() {
    calls++;
    throw StateError('Reopening selections must not allocate product IDs.');
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

Future<Directory> _temporary(String prefix) async {
  final directory = await Directory.systemTemp.createTemp(prefix);
  addTearDown(() => directory.delete(recursive: true));
  return directory;
}
