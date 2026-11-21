part of 'model_preset_integration_test.dart';

const _noPreset = 'Model Preset: No Model Preset';
const _noAgent = 'Agent: No Agent';

Future<void> _publishModelSelector(Directory directory, File evc) async {
  await evc.copy('${directory.path}/frontend.evc');
  await publishStockPluginInstallation(
    repositoryRoot: Directory.current.parent,
    installationDirectory: directory,
    pluginId: _plugin,
    displayName: 'Model Configuration',
    backend: true,
    frontend: true,
  );
}

void _registerSelectorCases({
  required Future<void> Function(Directory root) prepare,
  required Future<(_Fixture, SelectionGraph)> Function(Directory root) start,
}) {
  group('compiled Agent and Model Preset selectors', () {
    late Directory root;
    late _Fixture f;
    late SelectionGraph graph;
    late ApplicationFrontendBootstrap frontends;
    setUpAll(() async {
      root = await _temporary('mixed-selector-installations-');
      await prepare(root);
    });
    setUp(() async {
      (f, graph) = await start(root);
      expect(f.bootstrap.catalog!.issues, isEmpty);
      for (final backend in f.bootstrap.backends) {
        expect(
          backend.state,
          InstalledBackendState.active,
          reason: '${backend.failure}',
        );
      }
      frontends = await _startFrontends(f);
      expect(
        f.runtime.extensions
            .discover(sessionAccessoryContributions)
            .map((b) => b.id.value),
        unorderedEquals([
          '$agentConfigurationPluginId.selector',
          '$_plugin.selector',
        ]),
      );
    });

    Future<void> createRecords() async {
      await f.settings.createRecord(
        RecordTypeId('$agentConfigurationPluginId.agent'),
        ConfigurationRecordId('review'),
        {'name': 'Reviewer', 'instructions': 'Review the request.'},
      );
      await f.create('review', {..._values, 'name': 'Review model'});
    }

    testWidgets(
      'a strategy omitting the location shows and queries neither selector',
      (tester) async {
        final pane = _SelectorPane(f, placeLocation: false);
        await pane.present(tester, graph.session);
        await tester.pumpAndSettle();
        expect(find.text('Plain strategy pane'), findsOneWidget);
        expect(find.textContaining('Agent'), findsNothing);
        expect(find.textContaining('Model Preset'), findsNothing);
        expect(f.reads, 0);
        expect(f.storage.calls, isEmpty);
        _expectNoInference(f, graph);
      },
    );

    testWidgets(
      'navigation fences a pending Model acknowledgement and restores each Session independently',
      (tester) => tester.runAsync(() async {
        await createRecords();
        final pane = _SelectorPane(f);
        await pane.present(tester, graph.session);
        await _waitForText(tester, _noAgent);
        await _waitForText(tester, _noPreset);
        expect(
          tester
              .widgetList<Text>(
                find.textContaining(RegExp('^(Agent|Model Preset):')),
              )
              .map((w) => w.data),
          [_noAgent, _noPreset],
          reason: 'Both contributions are mounted in declared order.',
        );
        await _choose(tester, _noAgent, 'Reviewer', 'Agent: Reviewer');
        await _tapText(tester, _noPreset);
        await _waitForText(tester, 'Review model');
        final gate = f.storage.holdTransaction(afterCommit: true);
        addTearDown(gate.release);
        await _tapText(tester, 'Review model');
        await _until(
          tester,
          () => gate.entered.isCompleted,
          'committed Model selection',
        );
        await pane.present(tester, graph.otherSession);
        await _waitForText(tester, 'Loading Model Presets...');
        gate.release();
        await _waitForText(tester, _noAgent);
        await _waitForText(tester, _noPreset);
        expect(find.text('Agent: Reviewer'), findsNothing);
        expect(find.text('Model Preset: Review model'), findsNothing);
        expect(
          _selection(
            await f.selections.readSessionSelection(
              graph.otherSession.id.value,
            ),
          ),
          (graph.otherSession.id.value, null, 0),
        );
        await pane.present(tester, graph.session);
        await _waitForText(tester, 'Agent: Reviewer');
        await _waitForText(tester, 'Model Preset: Review model');
        expect(
          _selection(
            await f.selections.readSessionSelection(graph.session.id.value),
          ),
          (graph.session.id.value, 'review', 1),
        );
        _expectNoInference(f, graph);
        expect(tester.takeException(), isNull);
      }),
    );

    for (final unavailable in [_plugin, agentConfigurationPluginId]) {
      testWidgets(
        'failure then retirement of $unavailable leaves the other control usable',
        (tester) => tester.runAsync(() async {
          await createRecords();
          final modelFailed = unavailable == _plugin;
          final backend = f.bootstrap.backends.singleWhere(
            (b) => b.installation.metadata.id.value == unavailable,
          );
          final generation = frontends.generations.singleWhere(
            (g) => identical(g.installation, backend.installation),
          );
          final connection = backend.connection!;
          await connection.close();
          await connection.terminated.timeout(_bound);
          final pane = _SelectorPane(f);
          await pane.present(tester, graph.session);
          final failure = modelFailed
              ? 'Model Preset selection is unavailable.'
              : 'Agent selection is unavailable.';
          await _waitForText(tester, failure);
          final idle = modelFailed ? _noAgent : _noPreset;
          final choice = modelFailed ? 'Reviewer' : 'Review model';
          final selected = modelFailed
              ? 'Agent: Reviewer'
              : 'Model Preset: Review model';
          await _choose(tester, idle, choice, selected);
          expect(find.text(failure), findsOneWidget);
          await generation.close();
          await _until(
            tester,
            () => find.text(failure).evaluate().isEmpty,
            'retired selector removal',
          );
          expect(find.text(selected), findsOneWidget);
          await _choose(
            tester,
            selected,
            modelFailed ? 'No Agent' : 'No Model Preset',
            idle,
          );
          _expectNoInference(f, graph);
          expect(tester.takeException(), isNull);
        }),
      );
    }

    testWidgets(
      'a mounted Model selector cannot refresh against a live same-ID backend replacement',
      (tester) => tester.runAsync(() async {
        await createRecords();
        final pane = _SelectorPane(f);
        await pane.present(tester, graph.session);
        await _waitForText(tester, _noAgent);
        await _choose(
          tester,
          _noPreset,
          'Review model',
          'Model Preset: Review model',
        );
        final old = f.connection;
        final catalog = f.bootstrap.catalog!;
        final installation = catalog.installations.singleWhere(
          (i) => i.metadata.id.value == _plugin,
        );
        await old.close();
        await old.terminated.timeout(_bound);
        final replacement = await f.bootstrap.host!.startPlugin(
          pluginId: _plugin,
          artifactUri: installation.backendArtifactUri!,
          createInfrastructureServices: (connection) {
            final configuration = BackendConfigurationHost(
              connection: connection,
              catalog: catalog,
              installation: installation,
              loadRecords: f.loadCurrentRecords,
            );
            addTearDown(configuration.close);
            final storage = f.bootstrap.createInfrastructureServices!(
              connection,
            );
            addTearDown(f.storage.close);
            return {...storage, backendConfigurationServiceId: configuration};
          },
        );
        addTearDown(replacement.close);
        final activation = await PluginBackendActivation.registerAdvertised(
          connection: replacement,
          capabilities: f.runtime.registry,
          extensions: f.runtime.extensions,
          adapters: createRemoteExtensionAdapters(),
        );
        addTearDown(activation.close);
        final reads = f.reads;
        final row = tester
            .element(find.text('Model Preset: Review model'))
            .findAncestorWidgetOfExactType<Row>()!;
        await tester.tap(
          find.descendant(
            of: find.byWidget(row),
            matching: find.text('Refresh'),
          ),
        );
        await _waitForText(tester, 'Model Preset selection is unavailable.');
        expect(
          find.text('Model Preset catalog is unavailable.'),
          findsOneWidget,
        );
        expect(f.reads, reads);
        expect(
          f.storage.calls,
          isEmpty,
          reason: 'The old presentation never contacted the replacement.',
        );

        // Both services on the exact replacement really are available.
        final context = replacement.defaultConfigurationContext;
        final selections = ModelPresetSelectionServiceClient(
          replacement.channelFor(context, modelPresetSelectionServiceId),
        );
        final presets = ModelPresetCatalogServiceClient(
          replacement.channelFor(context, modelPresetCatalogServiceId),
        );
        final id = graph.session.id.value;
        expect(_selection(await selections.readSessionSelection(id)), (
          id,
          'review',
          1,
        ));
        expect((await presets.readPresets()).presets.single.presetId, 'review');
        expect(
          f.storage.calls,
          contains(projectStorageServiceQueryForSessionId),
        );
        expect(f.reads, reads + 1);
        await _choose(tester, _noAgent, 'Reviewer', 'Agent: Reviewer');
        expect(tester.takeException(), isNull);
      }),
    );
  });
}

Future<ApplicationFrontendBootstrap> _startFrontends(_Fixture f) async {
  final frontends = ApplicationFrontendBootstrap(
    extensions: f.runtime.extensions,
    backends: f.bootstrap,
    loadSettings: (catalog) async => PreparedSettingsSnapshot.resolve(catalog),
  );
  addTearDown(frontends.close);
  await frontends.start(f.bootstrap.catalog!);
  for (final g in frontends.generations) {
    expect(g.state, InstalledFrontendState.active, reason: '${g.failure}');
  }
  return frontends;
}

/// The strategy pane chooses placement; the controls and their channels come
/// exclusively from the prepared stock registrations.
final class _SelectorPane {
  _SelectorPane(this.fixture, {bool placeLocation = true}) {
    final registration = fixture.runtime.extensions.register(
      point: mainContentContributions,
      id: ExtensionId('test.model-preset.strategy-pane'),
      value: MainContentContribution(
        order: 0,
        attach: (access) {
          if (access.session.strategyId != _strategy) return;
          access.open(
            MainContentPane(
              id: 'main',
              title: 'Non-Chat strategy',
              createPresentation: () => placeLocation
                  ? access.buildSessionAccessoryLocation(
                      SessionAccessoryLocation.executionConfiguration,
                    )
                  : const Text('Plain strategy pane'),
            ),
          );
        },
      ),
    );
    addTearDown(registration.close);
  }
  final _Fixture fixture;
  Session? current;

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
}

Future<void> _until(
  WidgetTester tester,
  bool Function() ready,
  String reason,
) async {
  // Pump both the widget tree and the real backend process' event loop.
  final deadline = DateTime.now().add(_bound);
  while (!ready() && DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(Duration.zero);
    await tester.pump();
  }
  expect(ready(), isTrue, reason: 'Waiting for $reason.');
}

Future<void> _waitForText(WidgetTester tester, String text) =>
    _until(tester, () => find.text(text).evaluate().isNotEmpty, '"$text"');

Future<void> _tapText(WidgetTester tester, String text) async {
  await _waitForText(tester, text);
  await tester.tap(find.text(text));
}

Future<void> _choose(
  WidgetTester tester,
  String header,
  String choice,
  String selected,
) async {
  await _tapText(tester, header);
  await _tapText(tester, choice);
  await _waitForText(tester, selected);
}
