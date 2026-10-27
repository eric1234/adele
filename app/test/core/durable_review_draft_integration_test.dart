@Timeout(Duration(minutes: 5))
library;

import 'dart:async';
import 'dart:io';

import 'package:adele_capabilities/adele_capabilities.dart';
import 'package:adele_contract/adele_contract.dart';
import 'package:adele_desktop/core/adele_runtime.dart';
import 'package:adele_desktop/core/application_plugin_bootstrap.dart';
import 'package:adele_desktop/core/product_lifecycle.dart';
import 'package:adele_desktop/core/project_storage_host.dart';
import 'package:adele_environment/adele_environment.dart';
import 'package:adele_orchestration/adele_orchestration.dart';
import 'package:adele_plugin_api/adele_plugin_api.dart';
import 'package:adele_product/adele_product.dart';
import 'package:adele_project_storage/adele_project_storage.dart';
import 'package:diff_viewer_contract/review_draft.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plugin_builder/plugin_builder.dart';
import 'package:plugin_runtime/plugin_runtime.dart';
import 'package:sqlite3/sqlite3.dart' hide Session;

import '../../../tools/backend_artifacts.dart';

const _diffPlugin = 'dev.adele.diff-viewer';
const _projectPlugin = 'dev.adele.plugin.local-directory-project';
const _bound = Duration(seconds: 15);
const _text =
    "  Review '\u03bb'; keep \u6771\u4eac and \u{1f642}\r\n\tsecond line\n  ";
const _editedText = '\tEdited \u00e9 and e\u0301\n\ntrailing spaces  \r\n';
final _projectProvider = ProviderId('dev.adele.project.local-directory');
final _environmentProvider = ProviderId('test.review-draft.environment');
final _strategy = OrchestrationStrategyId('test.review-draft.strategy');

void main() {
  late Directory artifacts;
  late Directory installations;
  late File hostArtifact;
  late String aotRuntime;

  setUpAll(() async {
    artifacts = await Directory.systemTemp.createTemp(
      'adele-review-draft-aot-',
    );
    addTearDown(() => artifacts.delete(recursive: true));
    installations = await Directory('${artifacts.path}/installed').create();
    final repository = Directory.current.parent;
    final dart = _dartExecutable();
    aotRuntime = File(dart).parent.uri.resolve('dartaotruntime').toFilePath();
    hostArtifact = File('${artifacts.path}/host.aot');
    await compileAotSnapshot(
      dartExecutable: dart,
      workingDirectory: repository,
      entrypoint: 'packages/plugin_backend_host/bin/adele_backend_host.dart',
      artifact: hostArtifact,
      stage: 'review-draft-host',
    );
    for (final (id, entrypoint) in const [
      (
        _projectPlugin,
        'plugins/local_directory_project/packages/backend/bin/local_directory_project_backend.dart',
      ),
      (
        _diffPlugin,
        'plugins/diff_viewer/packages/backend/bin/diff_viewer_backend.dart',
      ),
    ]) {
      final directory = await Directory('${installations.path}/$id').create();
      await compileAotSnapshot(
        dartExecutable: dart,
        workingDirectory: repository,
        entrypoint: entrypoint,
        artifact: File('${directory.path}/backend.aot'),
        stage: 'review-draft-$id',
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

  Future<_Fixture> start({ProductIdSource? ids}) async {
    final fixture = _Fixture(ids: ids);
    addTearDown(fixture.close);
    await fixture.bootstrap.start(
      installationRoot: installations.path,
      dartaotruntimeExecutable: aotRuntime,
      hostArtifactPath: hostArtifact.path,
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
    final installed = fixture.bootstrap.catalog!.installations.singleWhere(
      (installation) => installation.metadata.id.value == _diffPlugin,
    );
    expect(installed.frontend, isNull);
    final activation = fixture.bootstrap.backendForInstallation(installed)!;
    fixture.diff = activation.connection!;
    expect(fixture.diff.pluginId, _diffPlugin);
    expect(fixture.diff.capabilityExposures, isEmpty);
    expect(fixture.diff.extensionExposures, isEmpty);
    expect(
      fixture.runtime.registry.providersFor(environmentProviderCapability),
      isEmpty,
    );
    expect(
      fixture.runtime.extensions.discover(orchestrationStrategyContributions),
      isEmpty,
    );
    return fixture;
  }

  test(
    'actual Diff CRUD survives replacement and durable Project reopen',
    () async {
      final source = await _source();
      final fixture = await start(
        ids: MonotonicProductIdSource(seed: 'durable-review'),
      );
      final graph = await fixture.createGraph(source);
      final session = graph.session.id.value;
      final otherSession = graph.otherSession.id.value;
      final coreBefore = _inspect(source, _coreRows);
      final client = fixture.client;
      final initial = await fixture.measure(
        'initial snapshot',
        () => client.snapshot(session),
      );
      expect(initial.sessionId, session);
      expect(initial.comments, isEmpty);
      final anchors = [
        _anchor(graph.environment.id.value),
        _anchor(graph.otherEnvironment.id.value),
        _anchor(
          graph.environment.id.value,
          layer: ReviewComparisonLayer.staged,
        ),
        _anchor(
          graph.environment.id.value,
          layer: ReviewComparisonLayer.committed,
          side: ReviewComparisonSide.oldSide,
        ),
      ];
      final comments = <PendingReviewComment>[];
      for (final anchor in anchors) {
        final comment = await fixture.measure(
          'create ${anchor.environmentId}/${anchor.layer.name}',
          () => client.createComment(session, anchor, _text),
        );
        expect(comment.text, _text);
        expect(_anchorFields(comment.anchor), _anchorFields(anchor));
        comments.add(comment);
      }
      expect(comments.map((comment) => comment.id).toSet(), hasLength(4));
      expect((await client.snapshot(otherSession)).comments, isEmpty);
      final isolated = await client.createComment(
        otherSession,
        anchors.first,
        _text,
      );
      final updated = await fixture.measure(
        'update',
        () => client.updateComment(
          session,
          comments.first.id,
          comments.first.version,
          _editedText,
        ),
      );
      expect(updated.id, comments.first.id);
      expect(updated.sequence, comments.first.sequence);
      expect(updated.version, comments.first.version + 1);
      expect(updated.text, _editedText);
      expect(_anchorFields(updated.anchor), _anchorFields(anchors.first));
      final beforeStale = _inspect(source, _reviewRows);
      await expectLater(
        client.updateComment(
          session,
          comments.first.id,
          comments.first.version,
          'stale',
        ),
        _failure('stale_comment'),
      );
      await expectLater(
        client.deleteComment(
          session,
          comments.first.id,
          comments.first.version,
        ),
        _failure('stale_comment'),
      );
      expect(_inspect(source, _reviewRows), beforeStale);
      await fixture.measure(
        'delete',
        () =>
            client.deleteComment(session, comments[1].id, comments[1].version),
      );
      final recreated = await client.createComment(session, anchors[1], _text);
      expect(recreated.id, isNot(comments[1].id));
      expect(recreated.sequence, greaterThan(comments.last.sequence));
      final saved = await fixture.measure(
        'warm snapshot',
        () => client.snapshot(session),
      );
      expect(saved.comments.map(_commentFields), [
        _commentFields(updated),
        _commentFields(comments[2]),
        _commentFields(comments[3]),
        _commentFields(recreated),
      ]);
      expect(
        (await client.snapshot(otherSession)).comments.map(_commentFields),
        [_commentFields(isolated)],
      );
      final rows = _inspect(source, _reviewRows);
      for (final comment in saved.comments) {
        _expectStoredComment(source, session, comment);
      }
      _expectStoredComment(source, otherSession, isolated);
      expect(_inspect(source, _coreRows), coreBefore);
      _expectOwner(source);
      _expectNoExecution(fixture.runtime, graph);

      final oldConnection = fixture.diff;
      await fixture.replaceDiff();
      expect(oldConnection.isClosed, isTrue);
      expect(fixture.bootstrap.host!.isClosed, isFalse);
      await expectLater(
        client.snapshot(session),
        throwsA(isA<PluginConnectionClosed>()),
      );
      expect(
        _snapshotFields(
          await fixture.measure(
            'replacement snapshot',
            () => fixture.client.snapshot(session),
          ),
        ),
        _snapshotFields(saved),
      );
      expect(_inspect(source, _reviewRows), rows);
      await fixture.close();
      expect(_inspect(source, _reviewRows), rows);

      final ids = _NoAllocationIds();
      final fresh = await start(ids: ids);
      final reopened = await fresh.runtime.lifecycle.openProject(
        sourceLocation: source.uri,
        provider: fresh.runtime.lifecycle.resolveProjectProvider(
          _projectProvider,
        ),
      );
      expect(reopened.id, graph.project.id);
      expect(reopened, isNot(same(graph.project)));
      expect(
        fresh.runtime.store.session(graph.session.id),
        isNot(same(graph.session)),
      );
      expect(
        fresh.runtime.store
            .requireSessionAuthority(graph.session.id)
            .environmentId,
        graph.environment.id,
      );
      for (final environment in [graph.environment, graph.otherEnvironment]) {
        expect(
          fresh.runtime.lifecycle.environmentRuntime.currentMaterialization(
            environment.id,
          ),
          isNull,
        );
      }
      expect(
        _snapshotFields(
          await fresh.measure(
            'durable reopen snapshot',
            () => fresh.client.snapshot(session),
          ),
        ),
        _snapshotFields(saved),
      );
      expect(
        (await fresh.client.snapshot(
          otherSession,
        )).comments.map(_commentFields),
        [_commentFields(isolated)],
      );
      expect(ids.calls, 0);
      expect(_inspect(source, _coreRows), coreBefore);
      expect(_inspect(source, _reviewRows), rows);
      _expectNoExecution(fresh.runtime, graph);
      expect(Directory('${source.path}/.git').existsSync(), isFalse);
    },
  );

  test(
    'volatile Project keeps real SQL across backend replacement, not its lifetime',
    () async {
      final source = await _source();
      final fixture = await start(
        ids: MonotonicProductIdSource(seed: 'volatile-review'),
      );
      final graph = await fixture.createGraph(source, volatile: true);
      expect(
        fixture.runtime.lifecycle.existingDatabaseForProject(graph.project),
        isNull,
      );
      final comment = await fixture.measure(
        'volatile create',
        () => fixture.client.createComment(
          graph.session.id.value,
          _anchor(graph.environment.id.value),
          _text,
        ),
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
        database.queryPluginRows(
          'SELECT * FROM adele_diff_review_comments',
          {},
        ),
        hasLength(1),
      );
      await fixture.replaceDiff();
      expect(
        (await fixture.client.snapshot(
          graph.session.id.value,
        )).comments.map(_commentFields),
        [_commentFields(comment)],
      );
      expect(
        fixture.runtime.lifecycle.existingDatabaseForProject(graph.project),
        same(database),
      );
      await fixture.close();
      expect(path.existsSync(), isFalse);
      expect(path.parent.existsSync(), isFalse);
      expect(File('${source.path}/.adele/data.db').existsSync(), isFalse);

      final fresh = await start(
        ids: MonotonicProductIdSource(seed: 'volatile-review'),
      );
      final recreated = await fresh.createGraph(source, volatile: true);
      expect(recreated.project.id, graph.project.id);
      expect(recreated.session.id, graph.session.id);
      expect(
        (await fresh.measure(
          'new volatile lifetime snapshot',
          () => fresh.client.snapshot(recreated.session.id.value),
        )).comments,
        isEmpty,
      );
      final newDatabase = fresh.runtime.lifecycle.existingDatabaseForProject(
        recreated.project,
      )!;
      expect(newDatabase.path, isNot(path.path));
      _expectNoExecution(fresh.runtime, recreated);
    },
  );

  test(
    'actual SQL failure rolls back comment and counters without fallback',
    () async {
      final source = await _source();
      final fixture = await start();
      final graph = await fixture.createGraph(source);
      final session = graph.session.id.value;
      final anchor = _anchor(graph.environment.id.value);
      final first = await fixture.client.createComment(session, anchor, _text);
      final before = _inspect(source, _reviewRows);
      _inspect(
        source,
        (database) => database.execute('''
      CREATE TRIGGER reject_review_comment BEFORE INSERT ON adele_diff_review_comments
      BEGIN SELECT RAISE(ABORT, 'review-comment-failure'); END;
    '''),
      );
      await expectLater(
        fixture.client.createComment(session, anchor, _editedText),
        _failure('outcome_uncertain'),
      );
      expect(_inspect(source, _reviewRows), before);
      expect(
        (await fixture.client.snapshot(session)).comments.map(_commentFields),
        [_commentFields(first)],
      );
      _inspect(
        source,
        (database) => database.execute('DROP TRIGGER reject_review_comment'),
      );
      final next = await fixture.client.createComment(
        session,
        anchor,
        _editedText,
      );
      expect(next.sequence, first.sequence + 1);
      expect(next.id, 'comment-${next.sequence}');
      _expectStoredComment(source, session, next);
      await fixture.replaceDiff();
      expect(
        (await fixture.client.snapshot(session)).comments.map(_commentFields),
        [_commentFields(first), _commentFields(next)],
      );
    },
  );

  test(
    'lost transaction acknowledgement reports uncertainty and replacement reads the commit once',
    () async {
      final source = await _source();
      final fixture = await start();
      final graph = await fixture.createGraph(source);
      final session = graph.session.id.value;
      await fixture.client.snapshot(session);
      final gate = fixture.probe.holdTransaction(afterCommit: true);
      final failed = expectLater(
        fixture.client.createComment(
          session,
          _anchor(graph.environment.id.value),
          _text,
        ),
        _failure('outcome_uncertain'),
      );
      await gate.entered.future.timeout(_bound);
      final committed = _inspect(source, _reviewRows);
      expect(committed['comments'], hasLength(1));
      // SQL has committed, but its successful reply has not crossed the host grant.
      fixture.diff.revokeInfrastructureContext();
      await failed.timeout(_bound);
      gate.release();
      await gate.settled.future.timeout(_bound);
      await expectLater(
        fixture.client.snapshot(session),
        _failure('storage_unavailable'),
      );
      await fixture.replaceDiff();
      final recovered = await fixture.measure(
        'lost ack replacement snapshot',
        () => fixture.client.snapshot(session),
      );
      expect(recovered.comments, hasLength(1));
      expect(recovered.comments.single.text, _text);
      expect(
        _anchorFields(recovered.comments.single.anchor),
        _anchorFields(_anchor(graph.environment.id.value)),
      );
      expect(_inspect(source, _reviewRows), committed);
      await fixture.close();
      final fresh = await start(ids: _NoAllocationIds());
      await fresh.runtime.lifecycle.openProject(
        sourceLocation: source.uri,
        provider: fresh.runtime.lifecycle.resolveProjectProvider(
          _projectProvider,
        ),
      );
      expect(
        _snapshotFields(await fresh.client.snapshot(session)),
        _snapshotFields(recovered),
      );
      expect(_inspect(source, _reviewRows), committed);
    },
  );

  for (final closeProject in [false, true]) {
    test(
      'queued Diff transaction cannot enter SQL after ${closeProject ? 'Project close' : 'generation retirement'}',
      () async {
        final source = await _source();
        final fixture = await start();
        final graph = await fixture.createGraph(source);
        final session = graph.session.id.value;
        await fixture.client.snapshot(session);
        final before = _inspect(source, _reviewRows);
        final gate = fixture.probe.holdTransaction();
        final failed = expectLater(
          fixture.client.createComment(
            session,
            _anchor(graph.environment.id.value),
            _text,
          ),
          _failure('outcome_uncertain'),
        );
        await gate.entered.future.timeout(_bound);
        if (closeProject) {
          await fixture.runtime.lifecycle.close().timeout(_bound);
        } else {
          fixture.diff.revokeInfrastructureContext();
        }
        gate.release();
        await gate.settled.future.timeout(_bound);
        await failed.timeout(_bound);
        expect(_inspect(source, _reviewRows), before);
        await expectLater(
          fixture.client.snapshot(session),
          _failure('storage_unavailable'),
        );
        await fixture.close();
        final fresh = await start(ids: _NoAllocationIds());
        await fresh.runtime.lifecycle.openProject(
          sourceLocation: source.uri,
          provider: fresh.runtime.lifecycle.resolveProjectProvider(
            _projectProvider,
          ),
        );
        expect((await fresh.client.snapshot(session)).comments, isEmpty);
        expect(_inspect(source, _reviewRows), before);
      },
    );
  }
}

final class _Fixture {
  _Fixture({ProductIdSource? ids}) : runtime = AdeleRuntime(ids: ids) {
    bootstrap = ApplicationPluginBootstrap(
      runtime.registry,
      runtime.extensions,
      createInfrastructureServices: _services,
    );
  }

  final AdeleRuntime runtime;
  late final ApplicationPluginBootstrap bootstrap;
  late PluginBackendConnection diff;
  final probes = <PluginBackendConnection, _StorageProbe>{};
  Future<void>? _closing;

  ReviewDraftServiceClient get client => ReviewDraftServiceClient(
    diff.channelFor(diff.defaultConfigurationContext, reviewDraftServiceId),
  );
  _StorageProbe get probe => probes[diff]!;

  Map<String, AdeleBackendDispatcher> _services(
    PluginBackendConnection connection,
  ) {
    final services = projectStorageServices(runtime.lifecycle, connection);
    expect(services.keys, [projectStorageServiceId]);
    final probe = _StorageProbe(services[projectStorageServiceId]!);
    probes[connection] = probe;
    return {projectStorageServiceId: probe};
  }

  Future<T> measure<T>(String operation, Future<T> Function() call) async {
    final before = probe.calls.length;
    final watch = Stopwatch()..start();
    try {
      return await call();
    } finally {
      watch.stop();
      // Diagnostics, not machine-dependent performance acceptance thresholds.
      print(
        'Diff AOT $operation: ${watch.elapsedMicroseconds} us; '
        '${probe.calls.length - before} host storage calls',
      );
    }
  }

  Future<void> replaceDiff() async {
    final installation = bootstrap.catalog!.installations.singleWhere(
      (entry) => entry.metadata.id.value == _diffPlugin,
    );
    await diff.close();
    diff = await bootstrap.host!.startPlugin(
      pluginId: _diffPlugin,
      artifactUri: installation.backendArtifactUri!,
      createInfrastructureServices: _services,
    );
    expect(diff.capabilityExposures, isEmpty);
    expect(diff.extensionExposures, isEmpty);
  }

  Future<_Graph> createGraph(Directory source, {bool volatile = false}) async {
    final channel = _EstablishmentOnlyChannel();
    final environment = runtime.registry.register(
      provider: ProviderDescriptor(
        id: _environmentProvider,
        capability: environmentProviderCapability,
        pluginId: 'test.review-draft.environment',
        displayName: 'Establishment only',
        serviceId: environmentProviderServiceId,
      ),
      endpoint: AdeleRequestChannelEndpoint(
        channel: channel,
        serviceId: environmentProviderServiceId,
        isAvailable: () => true,
      ),
    );
    final strategy = runtime.extensions.register(
      point: orchestrationStrategyContributions,
      id: ExtensionId(_strategy.value),
      value: OrchestrationStrategyContribution(
        strategyId: _strategy,
        materialize: (_) =>
            throw StateError('Review records must not start execution.'),
      ),
    );
    try {
      final project = volatile
          ? runtime.lifecycle.createProject(source.uri)
          : await runtime.lifecycle.openProject(
              sourceLocation: source.uri,
              provider: runtime.lifecycle.resolveProjectProvider(
                _projectProvider,
              ),
            );
      final task = await runtime.lifecycle.createTask(
        projectId: project.id,
        title: 'Review records',
        providerId: _environmentProvider,
      );
      final other = await runtime.lifecycle.createTask(
        projectId: project.id,
        title: 'Different Environment, same relative path',
        providerId: _environmentProvider,
      );
      final session = runtime.lifecycle.createSession(
        taskId: task.task.id,
        strategyId: _strategy,
      );
      final otherSession = runtime.lifecycle.createSession(
        taskId: task.task.id,
        strategyId: _strategy,
      );
      expect(channel.calls, 2);
      return (
        project: project,
        environment: task.environment,
        otherEnvironment: other.environment,
        session: session,
        otherSession: otherSession,
      );
    } finally {
      await environment.close();
      await strategy.close();
    }
  }

  Future<void> close() => _closing ??= _close();

  Future<void> _close() async {
    try {
      await bootstrap.close();
    } finally {
      try {
        await runtime.close();
      } finally {
        for (final probe in probes.values) {
          await probe.close();
        }
      }
    }
  }
}

typedef _Graph = ({
  Project project,
  Environment environment,
  Environment otherEnvironment,
  Session session,
  Session otherSession,
});

final class _EstablishmentOnlyChannel implements AdeleRequestChannel {
  int calls = 0;
  @override
  Future<Object?> request(String method, Map<String, Object?> payload) async {
    expect(
      method,
      environmentProviderServiceEstablishId,
      reason:
          'Saving comments must not restore, read, or execute in an Environment.',
    );
    calls++;
    return {'providerState': <String, Object?>{}, 'initialState': null};
  }
}

/// Gates actual host dispatch/replies, never substitutes a storage implementation.
final class _StorageProbe implements AdeleBackendDispatcher {
  _StorageProbe(this.delegate);
  final AdeleBackendDispatcher delegate;
  final calls = <String>[];
  _TransactionGate? _next;
  final _gates = <_TransactionGate>[];

  _TransactionGate holdTransaction({bool afterCommit = false}) {
    expect(_next, isNull);
    final gate = _TransactionGate(afterCommit);
    _gates.add(gate);
    _next = gate;
    return gate;
  }

  @override
  Future<Map<String, Object?>> dispatch(Map<Object?, Object?> request) async {
    final method = request['method']! as String;
    calls.add(method);
    final payload = request['payload']! as Map;
    expect(
      payload['accessMode'],
      ProjectStorageAccessMode.durableOrTemporary.name,
    );
    final gate = method == projectStorageServiceTransactionForSessionId
        ? _next
        : null;
    if (gate == null) return delegate.dispatch(request);
    _next = null;
    try {
      if (!gate.afterCommit) {
        gate.entered.complete();
        await gate._release.future;
      }
      final response = await delegate.dispatch(request);
      if (gate.afterCommit) {
        expect(response['ok'], isTrue);
        gate.entered.complete();
        await gate._release.future;
      }
      return response;
    } finally {
      gate.settled.complete();
    }
  }

  @override
  Future<void> handle(
    Map<Object?, Object?> command,
    void Function(Map<String, Object?>) send,
  ) async => send(await dispatch(command));

  @override
  Future<void> close() async {
    for (final gate in _gates) {
      gate.release();
    }
    await delegate.close();
  }
}

final class _TransactionGate {
  _TransactionGate(this.afterCommit);
  final bool afterCommit;
  final entered = Completer<void>();
  final settled = Completer<void>();
  final _release = Completer<void>();
  void release() {
    if (!_release.isCompleted) _release.complete();
  }
}

ReviewCommentAnchor _anchor(
  String environmentId, {
  ReviewComparisonLayer layer = ReviewComparisonLayer.unstaged,
  ReviewComparisonSide side = ReviewComparisonSide.newSide,
}) => ReviewCommentAnchor(
  environmentId: environmentId,
  relativePath: "lib/a + [quoted]; '\u6771\u4eac'.dart",
  layer: layer,
  side: side,
  startLine: 17,
  endLine: 19,
  comparisonIdentity: 'opaque-comparison: independent of approval revision',
  sourceExcerpt: "  old '\u03bb';\r\n\tnew \u{1f642}\n",
  hunkIndex: 3,
  lineIndex: 5,
);

Map<String, Object?> _anchorFields(ReviewCommentAnchor anchor) => {
  'environmentId': anchor.environmentId,
  'relativePath': anchor.relativePath,
  'layer': anchor.layer.name,
  'side': anchor.side.name,
  'startLine': anchor.startLine,
  'endLine': anchor.endLine,
  'comparisonIdentity': anchor.comparisonIdentity,
  'sourceExcerpt': anchor.sourceExcerpt,
  'hunkIndex': anchor.hunkIndex,
  'lineIndex': anchor.lineIndex,
};

Map<String, Object?> _commentFields(PendingReviewComment comment) => {
  'id': comment.id,
  'anchor': _anchorFields(comment.anchor),
  'text': comment.text,
  'version': comment.version,
  'sequence': comment.sequence,
};

Map<String, Object?> _snapshotFields(ReviewDraftSnapshot snapshot) => {
  'sessionId': snapshot.sessionId,
  'comments': snapshot.comments.map(_commentFields).toList(),
};

Matcher _failure(String code) => throwsA(
  isA<ReviewDraftFailure>().having((failure) => failure.code, 'code', code),
);

void _expectNoExecution(AdeleRuntime runtime, _Graph graph) {
  for (final session in [graph.session, graph.otherSession]) {
    expect(runtime.store.runsForSession(session.id), isEmpty);
    expect(runtime.lifecycle.runActivitiesForSession(session.id), isEmpty);
    expect(
      () => runtime.lifecycle.resolveSessionStrategy(session.id),
      throwsA(isA<OrchestrationStrategyUnavailable>()),
    );
  }
  expect(runtime.registry.providersFor(environmentProviderCapability), isEmpty);
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

Map<String, Object?> _reviewRows(Database database) => {
  'sessions': _rows(
    database,
    'SELECT * FROM adele_diff_review_sessions ORDER BY 1',
  ),
  'comments': _rows(
    database,
    'SELECT * FROM adele_diff_review_comments ORDER BY 1, 2',
  ),
};

void _expectStoredComment(
  Directory source,
  String sessionId,
  PendingReviewComment comment,
) {
  expect(
    _inspect(
      source,
      (database) => database
          .select(
            'SELECT * FROM adele_diff_review_comments WHERE session_id = ? AND comment_id = ?',
            [sessionId, comment.id],
          )
          .map((row) => Map<String, Object?>.from(row))
          .toList(),
    ),
    [
      {
        'session_id': sessionId,
        'comment_id': comment.id,
        'sequence': comment.sequence,
        'version': comment.version,
        'environment_id': comment.anchor.environmentId,
        'relative_path': comment.anchor.relativePath,
        'layer': comment.anchor.layer.name,
        'side': comment.anchor.side.name,
        'start_line': comment.anchor.startLine,
        'end_line': comment.anchor.endLine,
        'comparison_identity': comment.anchor.comparisonIdentity,
        'source_excerpt': comment.anchor.sourceExcerpt,
        'hunk_index': comment.anchor.hunkIndex,
        'line_index': comment.anchor.lineIndex,
        'text': comment.text,
        'charge': reviewCommentCharge(comment),
      },
    ],
  );
}

void _expectOwner(Directory source) {
  expect(
    _inspect(
      source,
      (database) => _rows(
        database,
        'SELECT owner_id, version FROM adele_schema_versions ORDER BY owner_id',
      ),
    ),
    [
      {'owner_id': _diffPlugin, 'version': 1},
      {'owner_id': 'dev.adele.execution', 'version': 1},
      {'owner_id': 'dev.adele.product', 'version': 1},
    ],
  );
}

final class _NoAllocationIds implements ProductIdSource {
  int calls = 0;
  Never _allocate() {
    calls++;
    throw StateError('Reopening review records must not allocate product IDs.');
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
  final source = await Directory.systemTemp.createTemp('adele-review-project-');
  addTearDown(() => source.delete(recursive: true));
  return source;
}

String _dartExecutable() {
  final flutterRoot = Platform.environment['FLUTTER_ROOT'];
  if (flutterRoot != null) {
    final executable = File('$flutterRoot/bin/cache/dart-sdk/bin/dart');
    if (executable.existsSync()) return executable.path;
  }
  throw StateError('Set FLUTTER_ROOT to the pinned Flutter SDK for AOT tests.');
}
