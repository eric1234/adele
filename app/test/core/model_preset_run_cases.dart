part of 'model_preset_integration_test.dart';

const _models = 'test.preset.models';
const _strategyPlugin = 'test.preset.orchestration';
const _direct = 'test.preset.direct';
const _first = 'test.preset.first';
const _second = 'test.preset.second';
const _directModel = 'launch-default';
const _sharedModel = ' Vendor/MiX:v1.2+custom ';
const _bound = Duration(seconds: 10);
const _firstValues = {
  'name': 'Review',
  'model': {'provider-id': _first, 'model-id': _sharedModel},
  'reasoning-effort': 'none',
};
const _secondValues = {
  'name': 'Review',
  'model': {'provider-id': _second, 'model-id': _sharedModel},
};
final _runArguments = {
  _strategyPlugin: [
    '$_strategyPlugin.registration',
    jsonEncode({'strategyId': _strategy.value}),
  ],
  _models: [
    jsonEncode({
      'providers': [_direct, _first, _second],
      'toolProvider': _first,
    }),
  ],
};

enum _StockArtifact { healthy, corrupt, missing }

Future<void> _prepareRunInstallations(
  Directory root,
  Directory published,
  _StockArtifact stock,
) async {
  final directory = await Directory(
    '${root.path}/model-configuration',
  ).create();
  for (final name in [
    'adele_plugin.installation.json',
    'records.schema.json',
    if (stock == _StockArtifact.healthy) 'backend.aot',
  ]) {
    await File(
      '${published.path}/model-configuration/$name',
    ).copy('${directory.path}/$name');
  }
  if (stock == _StockArtifact.corrupt) {
    await File(
      '${directory.path}/backend.aot',
    ).writeAsString('not an AOT artifact');
  }
  // The two probes remain real, separately routed participants even when the
  // published stock manifest points at an unusable or entirely absent artifact.
  for (final (id, name) in [
    (_models, 'models'),
    (_strategyPlugin, 'strategy'),
  ]) {
    final probe = await Directory('${root.path}/$name').create();
    await File(
      '${published.parent.path}/$name.aot',
    ).copy('${probe.path}/backend.aot');
    await File('${probe.path}/adele_plugin.installation.json').writeAsString(
      jsonEncode({
        'manifestVersion': 1,
        'metadata': {'id': id, 'version': '1', 'displayName': name},
        'components': {
          'backend': {'artifact': 'backend.aot'},
        },
      }),
    );
  }
}

const _directRequest = {
  'providerId': _direct,
  'modelId': _directModel,
  'reasoningEffort': null,
};
const _firstRequest = {
  'providerId': _first,
  'modelId': _sharedModel,
  'reasoningEffort': 'none',
  'toolOutcomes': <String>[],
};
final _continuedRequest = {
  ..._firstRequest,
  'toolOutcomes': ['success'],
};
const _secondRequest = {
  'providerId': _second,
  'modelId': _sharedModel,
  'reasoningEffort': null,
};

void _registerRunCases(
  Future<_StockRuns> Function({
    _StockArtifact stock,
    SessionId? restore,
    bool selector,
  })
  start,
) {
  testWidgets(
    'interpreted stock selection fixes the actual model route across tool approval; later Runs recapture or use direct on clear',
    (tester) => tester.runAsync(() async {
      final runs = await start(selector: true);
      final f = runs.fixture;
      final id = runs.owner.session.id.value;
      final frontends = await _startFrontends(f);
      expect(
        frontends.generations.single.installation.metadata.id.value,
        _plugin,
      );
      final pane = _SelectorPane(f);
      await pane.present(tester, runs.owner.session);
      await _waitForText(tester, _noPreset);
      const emptyMessage =
          'No Model Presets configured. Create Model Presets in Global Settings.';
      expect(find.text(emptyMessage), findsOneWidget);
      final empty = await f.catalog.readPresets();
      expect(empty.isComplete, isTrue);
      expect(empty.presets, isEmpty);
      expect(_selection(await f.selections.readSessionSelection(id)), (
        id,
        null,
        0,
      ));

      final beforeDirect = f.reads;
      await runs.advance(RunState.completed);
      expect(await runs.requests(), [_directRequest, _directRequest]);
      expect(
        f.reads,
        beforeDirect,
        reason: 'Untouched selection does not consult the catalog.',
      );

      await f.create('review', _firstValues);
      final initial = await f.create('later', {
        ..._secondValues,
        'name': 'Later review',
        'model': {'provider-id': _second, 'model-id': 'Before-edit'},
        'reasoning-effort': 'high',
      });
      final later = await f.settings.updateRecord(initial, {
        ...initial.values,
        'name': 'Review',
      });
      // The same mounted selector must observe the newly authored records.
      await _tapText(tester, 'Refresh');
      await _until(
        tester,
        () =>
            find.text(emptyMessage).evaluate().isEmpty &&
            find.text('Refresh').evaluate().isNotEmpty,
        'refreshed Model Preset catalog',
      );
      expect(find.text(_noPreset), findsOneWidget);
      await _choose(
        tester,
        _noPreset,
        'Review (review)',
        'Model Preset: Review (review)',
      );
      expect(_selection(await f.selections.readSessionSelection(id)), (
        id,
        'review',
        1,
      ));
      final beforeA = f.reads;
      final runA = await runs.advance(RunState.waiting);
      expect(await runs.requests(), [
        _directRequest,
        _directRequest,
        _firstRequest,
      ]);
      expect(f.reads, beforeA + 1);
      expect(runs.tool.executedSessions, isEmpty);

      await _choose(
        tester,
        'Model Preset: Review (review)',
        'Review (later)',
        'Model Preset: Review (later)',
      );
      expect(_selection(await f.selections.readSessionSelection(id)), (
        id,
        'later',
        2,
      ));
      // Capturing values at selection time would use Before-edit/high for B.
      await f.settings.updateRecord(later, _secondValues);
      final afterChanges = f.reads;
      await runs.approve();
      expect(runs.owner.failure, isNull);
      expect(runs.owner.stateForRun(runA), RunState.completed);
      expect(runs.tool.executedSessions, [id]);
      expect(await runs.requests(), [
        _directRequest,
        _directRequest,
        _firstRequest,
        _continuedRequest,
      ]);
      expect(
        f.reads,
        afterChanges,
        reason: 'Approval resume must not poll the catalog.',
      );

      final runB = await runs.advance(RunState.completed);
      expect(runB, isNot(runA));
      expect(f.reads, afterChanges + 1);
      await _tapText(tester, 'Model Preset: Review (later)');
      await _waitForText(tester, 'No Model Preset');
      final beforeClear = f.reads;
      await _tapText(tester, 'No Model Preset');
      await _waitForText(tester, _noPreset);
      expect(_selection(await f.selections.readSessionSelection(id)), (
        id,
        null,
        3,
      ));
      await runs.advance(RunState.completed);
      expect(
        f.reads,
        beforeClear,
        reason:
            'Neither clear nor the next direct Run needs another catalog read.',
      );
      expect(await runs.requests(), [
        _directRequest,
        _directRequest,
        _firstRequest,
        _continuedRequest,
        _secondRequest,
        _secondRequest,
        _directRequest,
        _directRequest,
      ]);
    }),
  );

  testWidgets(
    'editing only the provider of the selected preset redirects the next Run, not approval resume',
    (tester) => tester.runAsync(() async {
      final runs = await start(selector: true);
      final f = runs.fixture;
      final frontends = await _startFrontends(f);
      await f.create('review', _firstValues);
      await _SelectorPane(f).present(tester, runs.owner.session);
      await _choose(tester, _noPreset, 'Review', 'Model Preset: Review');

      final waiting = await runs.advance(RunState.waiting);
      expect(await runs.requests(), [_firstRequest]);

      // Change the saved target through the compiled field editor. Neither
      // the Session selection nor the provider-local model ID changes.
      await _showPresetSettings(tester, f, frontends);
      await _waitForText(tester, 'Review');
      await _press(tester, find.text('Review'));
      await tester.pumpAndSettle();
      const form = 'model-presets-review';
      await _press(tester, _key('record-edit-$form'));
      await _authorReference(tester, _second, _sharedModel);
      await _press(tester, _key('record-save-$form'));
      await _until(
        tester,
        () => _key('record-edit-$form').evaluate().isNotEmpty,
        'acknowledged provider edit',
      );
      final current = (await f.catalog.readPresets()).presets.single;
      expect(
        (current.model.providerId, current.model.modelId),
        (_second, _sharedModel),
      );
      final sessionId = runs.owner.session.id.value;
      expect(_selection(await f.selections.readSessionSelection(sessionId)), (
        sessionId,
        'review',
        1,
      ));

      final beforeResume = f.reads;
      await runs.approve();
      expect(runs.owner.stateForRun(waiting), RunState.completed);
      expect(f.reads, beforeResume);
      expect(await runs.requests(), [_firstRequest, _continuedRequest]);
      await runs.advance(RunState.completed);
      expect(f.reads, beforeResume + 1);
      final retargeted = {..._secondRequest, 'reasoningEffort': 'none'};
      expect(await runs.requests(), [
        _firstRequest,
        _continuedRequest,
        retargeted,
        retargeted,
      ]);
      expect(tester.takeException(), isNull);
    }),
  );

  test(
    'a deleted selected definition in a complete or incomplete catalog never invokes a provider',
    () async {
      final runs = await start();
      final f = runs.fixture;
      final record = await f.create('saved', _secondValues);
      await runs.select('saved', 0);
      await f.settings.deleteRecord(record);
      expect((await f.catalog.readPresets()).isComplete, isTrue);
      await runs.expectPreparationFailure(isA<RunModelPreferenceFailure>());

      await File(
        '${f.roots.configurationRoot}/model-presets/broken.toml',
      ).writeAsString('invalid = [');
      final partial = await f.catalog.readPresets();
      expect(partial.isComplete, isFalse);
      expect(partial.presets, isEmpty);
      await runs.expectPreparationFailure(isA<RunModelPreferenceFailure>());
      final id = runs.owner.session.id.value;
      expect(_selection(await f.selections.readSessionSelection(id)), (
        id,
        'saved',
        1,
      ));
      // Recreating the stored ID supplies positive evidence without clearing
      // the malformed sibling or writing a new Session selection.
      await f.create('saved', {
        ..._secondValues,
        'model': {'provider-id': _second, 'model-id': 'Recreated/Model'},
        'reasoning-effort': 'high',
      });
      await runs.advance(RunState.completed);
      const recreated = {
        'providerId': _second,
        'modelId': 'Recreated/Model',
        'reasoningEffort': 'high',
      };
      expect(await runs.requests(), [recreated, recreated]);
    },
  );

  test(
    'a failed live catalog read or selection storage read never invokes a provider',
    () async {
      final runs = await start();
      final f = runs.fixture;
      await f.create('saved', _secondValues);
      await runs.select('saved', 0);
      final records = Directory('${f.roots.configurationRoot}/model-presets');
      final saved = await records.rename('${records.path}-saved');
      await File(records.path).writeAsString('not a directory');
      final reads = f.reads;
      await runs.expectPreparationFailure(isA<RunModelPreferenceFailure>());
      expect(f.reads, reads + 1);

      await File(records.path).delete();
      await saved.rename(records.path);
      expect((await f.catalog.readPresets()).presets.single.presetId, 'saved');
      final beforeStorageFailure = f.reads;

      // Revoke the actual backend's infrastructure grant, not its preference
      // registration. It must fail reading storage before asking for records.
      f.connection.revokeInfrastructureContext();
      final selection = f.selections.readSessionSelection(
        runs.owner.session.id.value,
      );
      await expectLater(selection, _failure('storage_unavailable'));
      await runs.expectPreparationFailure(isA<RunModelPreferenceFailure>());
      expect(f.reads, beforeStorageFailure);
    },
  );

  testWidgets(
    'malformed persisted provider blocks capture; valid unregistered ID fails exact binding resolution',
    (tester) => tester.runAsync(() async {
      final runs = await start(selector: true);
      final f = runs.fixture;
      final record = await f.create('saved', _secondValues);
      await _startFrontends(f);
      await _SelectorPane(f).present(tester, runs.owner.session);
      await _choose(tester, _noPreset, 'Review', 'Model Preset: Review');
      // An external edit can invalidate a selected preset, but must not change
      // the selection, invoke a fallback provider or repair the file.
      final file = File(
        '${f.roots.configurationRoot}/model-presets/review.toml',
      );
      final original = await file.readAsString();
      expect(original, contains('recordId = "saved"'));
      final malformed = original.replaceFirst(_second, 'not a provider');
      await file.writeAsString(malformed);
      await runs.expectPreparationFailure(isA<RunModelPreferenceFailure>());
      expect(await file.readAsString(), malformed);

      const absent = 'test.preset.unregistered';
      await file.writeAsString(original);
      await f.settings.updateRecord(record, {
        ..._secondValues,
        'model': {'provider-id': absent, 'model-id': _sharedModel},
      });
      await runs.expectPreparationFailure(
        isA<ProviderUnavailable>().having(
          (e) => e.providerId,
          'providerId',
          ProviderId(absent),
        ),
      );
      final sessionId = runs.owner.session.id.value;
      expect(_selection(await f.selections.readSessionSelection(sessionId)), (
        sessionId,
        'saved',
        1,
      ));
    }),
  );

  testWidgets(
    'retiring the captured provider while waiting cannot switch the continuation to direct',
    (tester) => tester.runAsync(() async {
      final runs = await start(selector: true);
      final f = runs.fixture;
      await f.create('review', _firstValues);
      await _startFrontends(f);
      await _SelectorPane(f).present(tester, runs.owner.session);
      await _choose(tester, _noPreset, 'Review', 'Model Preset: Review');
      final runA = await runs.advance(RunState.waiting);
      final binding = f.runtime.registry.resolveExact(
        modelProviderCapability,
        ProviderId(_first),
      );
      await f.runtime.plugins
          .backendForProvider(binding)!
          .retireProvider(binding);
      await runs.approve();
      expect(runs.owner.failure, isNotNull);
      expect(runs.owner.stateForRun(runA), RunState.failed);
      await runs.advance(RunState.failed);
      expect(
        runs.owner.failure,
        isA<ProviderUnavailable>().having(
          (e) => e.providerId,
          'providerId',
          ProviderId(_first),
        ),
      );
      expect(await runs.requests(), [_firstRequest]);
    }),
  );

  for (final stock in [_StockArtifact.corrupt, _StockArtifact.missing]) {
    test(
      'a ${stock.name} stock artifact blocks Runs for a restored Session but not Settings CRUD',
      () async {
        final healthy = await start();
        await healthy.fixture.create('persisted', _secondValues);
        await healthy.select('persisted', 0);
        final session = healthy.owner.session.id;
        await healthy.owner.close();
        await healthy.fixture.close();

        final runs = await start(stock: stock, restore: session);
        final f = runs.fixture;
        final published = f.bootstrap.catalog!.installations.singleWhere(
          (i) => i.metadata.id.value == _plugin,
        );
        expect(published.runModelPreferenceSource?.value, _extensionId);
        expect(f.runtime.plugins.backendForInstallation(published), isNull);
        expect(
          f.runtime.extensions.discover(runModelPreferencesExtensionPoint),
          isEmpty,
        );
        if (stock == _StockArtifact.missing) {
          expect(published.backendArtifactUri, isNull);
          expect(
            f.bootstrap.catalog!.issues.any(
              (i) => i.isRunModelPreferenceSourceIssue,
            ),
            isTrue,
          );
        } else {
          expect(
            f.bootstrap.backends
                .singleWhere((b) => identical(b.installation, published))
                .state,
            InstalledBackendState.failed,
          );
        }
        await runs.expectPreparationFailure(
          isA<RunModelPreferenceFailure>().having(
            (e) => e.kind,
            'kind',
            RunModelPreferenceFailureKind.unavailable,
          ),
        );

        final collection = RecordCollectionId('model-presets');
        expect(
          (await f.settings.loadRecords(collection)).records.single.id.value,
          'persisted',
        );
        final created = await f.create('editable');
        final edited = await f.settings.updateRecord(created, {
          ..._values,
          'name': 'Edited offline',
        });
        final reloaded = (await f.settings.loadRecords(
          collection,
        )).records.singleWhere((r) => r.id == edited.id);
        expect(reloaded.values['name'], 'Edited offline');
        await f.settings.deleteRecord(reloaded);
        expect(
          (await f.settings.loadRecords(collection)).records.single.id.value,
          'persisted',
        );
      },
    );
  }
}

final class _StockRuns {
  _StockRuns(this.fixture, Session session)
    : owner = SessionExecutionController(
        runtime: fixture.runtime,
        session: session,
        providerId: ProviderId(_direct),
        model: _directModel,
      ) {
    expect(fixture.runtime.plugins.state, ApplicationPluginState.ready);
    for (final id in [_direct, _first, _second]) {
      fixture.runtime.registry
          .resolveExact(modelProviderCapability, ProviderId(id))
          .streamChannel;
    }
    final extensions = fixture.runtime.extensions;
    final toolRegistration = extensions.register(
      point: modelToolContributions,
      id: ExtensionId('test.preset.tool'),
      value: tool,
    );
    addTearDown(toolRegistration.close);
    final policy = extensions.register(
      point: toolAuthorizationPolicies,
      id: ExtensionId('test.preset.ask'),
      value: ToolAuthorizationPolicyContribution(
        evaluate: (request) => request.toolId == ReviewExecutionFixture.toolId
            ? ToolAuthorizationDecision.ask
            : ToolAuthorizationDecision.abstain,
      ),
    );
    addTearDown(policy.close);
    addTearDown(owner.close);
  }

  final _Fixture fixture;
  final SessionExecutionController owner;
  final tool = ReviewExecutionFixture();

  Future<void> select(String? preset, int expectedRevision) async {
    final id = owner.session.id.value;
    expect(
      _selection(
        await fixture.selections.updateSessionSelection(
          id,
          preset,
          expectedRevision,
        ),
      ),
      (id, preset, expectedRevision + 1),
    );
  }

  Future<RunId> advance(RunState expected) async {
    final run = await owner.startRun();
    await owner.activeRunFuture?.timeout(_bound);
    expect(owner.stateForRun(run), expected, reason: '${owner.failure}');
    if (expected != RunState.failed) expect(owner.failure, isNull);
    return run;
  }

  Future<void> approve() async {
    expect(
      owner.resolveApproval(owner.pendingApproval!, approved: true),
      isTrue,
    );
    await owner.activeRunFuture!.timeout(_bound);
  }

  Future<Object?> requests() => _probe(_models, 'requests');

  Future<void> expectPreparationFailure(Matcher failure) async {
    await advance(RunState.failed);
    expect(owner.failure, failure);
    expect(owner.currentRun, isNull);
    expect(
      (await _probe(_strategyPlugin, 'snapshot') as Map)['records'],
      isEmpty,
      reason: 'Preference failure precedes strategy materialization.',
    );
    expect(
      await requests(),
      isEmpty,
      reason: 'Not even the available direct provider may be invoked.',
    );
  }

  Future<Object?> _probe(String plugin, String method) {
    final connection = fixture.bootstrap.backends
        .singleWhere((b) => b.installation.metadata.id.value == plugin)
        .connection!;
    return connection
        .channelFor(connection.defaultConfigurationContext, 'probe')
        .request(method, const {})
        .timeout(_bound);
  }
}
