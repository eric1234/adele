part of 'openai_record_startup_integration_test.dart';

const _modelConfiguration = 'dev.adele.plugin.model-configuration';
const _browserStrategy = 'test.browser.orchestration';
const _sharedModel = 'Vendor/MiX:v2+preview';
const _review = 'model-presets-review';

Future<void> _publishBrowserInstallations(
  _ProviderFixture f,
  Directory repository,
) async {
  final root = f.installationRoot;
  final model = Directory('$root/model-configuration');
  final strategy = Directory('$root/strategy');
  for (final (entrypoint, directory) in [
    (
      'plugins/model_configuration/packages/backend/bin/model_configuration_backend.dart',
      model,
    ),
    ('app/test/core/fixtures/remote_orchestration_probe.dart', strategy),
  ]) {
    await compileAotSnapshot(
      dartExecutable: File(f.runtime).parent.uri.resolve('dart').toFilePath(),
      workingDirectory: repository,
      entrypoint: entrypoint,
      artifact: File('${directory.path}/backend.aot'),
      stage: 'openai-model-browser',
    );
  }
  await File('${model.path}/frontend.evc').writeAsBytes(
    await Isolate.run(
      () => compileModelConfigurationFrontend(repositoryRoot: repository),
    ),
  );
  await publishStockPluginInstallation(
    repositoryRoot: repository,
    installationDirectory: model,
    pluginId: _modelConfiguration,
    displayName: 'Model Configuration',
    backend: true,
    frontend: true,
  );
  await File('${strategy.path}/adele_plugin.installation.json').writeAsString(
    jsonEncode({
      'manifestVersion': 1,
      'metadata': {
        'id': _browserStrategy,
        'version': '1',
        'displayName': 'Test orchestration',
      },
      'components': {
        'backend': {'artifact': 'backend.aot'},
      },
    }),
  );
  f.startupArguments[_browserStrategy] = [
    '$_browserStrategy.registration',
    jsonEncode({'strategyId': _browserStrategy}),
  ];
}

void _registerModelBrowserCases(Future<_ProviderFixture> Function() prepare) {
  testWidgets(
    'prepared Model Browser keeps OpenAI accounts distinct through Save, restart and Run approval',
    (tester) => tester.runAsync(() async {
      final f = await prepare();
      final collection = RecordCollectionId('model-presets');
      Map<String, String> model(String id, String name) => {
        'provider-id': '$_recordType.$id-openai',
        'model-id': name,
      };
      final original = model('personal', 'old-unlisted');
      final work = model('work', _sharedModel);
      final personal = model('personal', _sharedModel);
      final next = model('personal', 'personal-only');
      Map<String, Object> values(Map<String, String> target) => {
        'name': 'Review',
        'model': target,
        'reasoning-effort': 'high',
      };
      await f.settings.createRecord(
        RecordTypeId('$_modelConfiguration.preset'),
        ConfigurationRecordId('review'),
        values(original),
      );
      f.catalogModels['/work/models'] = [_sharedModel, 'retiring'];
      f.catalogModels['/personal/models'] = [_sharedModel, 'personal-only'];
      Future<Map<String, Object>> saved() async {
        // This independent Settings owner cannot invalidate the form's baseline.
        final record = (await f.settings.loadRecords(
          collection,
        )).records.single;
        expect(record.id.value, 'review');
        return record.values;
      }

      Object? draft() => tester
          .widget<RecordFieldEditorHost>(
            find.byType(RecordFieldEditorHost, skipOffstage: false),
          )
          .readValue();
      Future<void> edit(_ProviderSettings ui) async {
        await ui.section('Model Presets');
        await ui.until(
          () => ui.key('record-$_review').evaluate().isNotEmpty,
          'saved review',
        );
        await ui._tap(find.text('Review'));
        await ui.press('record-edit-$_review');
        await ui.until(
          () => find.text('Browse models...').evaluate().isNotEmpty,
          'prepared field editor',
        );
      }

      Future<void> save(_ProviderSettings ui) async {
        final count = f.requests.length;
        await ui.press('record-save-$_review');
        await ui.until(
          () => ui._enabled('record-edit-$_review'),
          'Save acknowledgement',
        );
        expect(f.requests, hasLength(count));
        expect(f.storage.calls, hasLength(count));
      }

      Finder chip(String text) => find.widgetWithText(ChoiceChip, text);
      Future<void> browse(_ProviderSettings ui, {bool refresh = false}) async {
        // Never start aggregate discovery against an ambient account.
        expect(
          f.registry
              .providersFor(modelProviderCapability)
              .map((p) => p.id.value),
          unorderedEquals([work['provider-id'], personal['provider-id']]),
        );
        _expectCatalogAssociations(f.bootstrap, f.registry);
        final before = f.requests.length;
        final reads = f.storage.readReferences.length;
        await ui._tap(find.text(refresh ? 'Refresh' : 'Browse models...'));
        await ui._tap(chip('All'));
        final rows = find.descendant(
          of: find.byType(Dialog).last,
          matching: find.text(_sharedModel),
        );
        await ui.until(
          () => rows.evaluate().length == 2,
          'shared model on two configured accounts',
        );
        expect(
          f.requests.skip(before),
          unorderedEquals([
            for (final id in ['work', 'personal'])
              {
                'method': 'GET',
                'authority': Uri.parse(
                  f.records[id]!.values['endpoint']! as String,
                ).authority,
                'path': '/$id/models',
                'query': '',
                'authorization': 'Bearer test-$id-key',
                'account': null,
                'accept': 'application/json',
                'body': '',
              },
          ]),
        );
        expect(
          f.storage.readReferences.skip(reads),
          unorderedEquals([f.reference('work'), f.reference('personal')]),
        );
      }

      Future<void> select(
        _ProviderSettings ui,
        String account,
        String model,
      ) async {
        await ui._tap(chip(account));
        await ui._tap(
          find.descendant(
            of: find.byType(Dialog).last,
            matching: find.text(model),
          ),
        );
      }

      Future<void> use(_ProviderSettings ui) async {
        await ui._tap(find.text('Use model'));
        await ui.until(
          () => find.text('Model Browser').evaluate().isEmpty,
          'confirmed model',
        );
      }

      ModelPresetSelectionServiceClient selections() {
        final c = f.bootstrap.backends
            .singleWhere(
              (b) => b.installation.metadata.id.value == _modelConfiguration,
            )
            .connection!;
        return ModelPresetSelectionServiceClient(
          c.channelFor(
            c.defaultConfigurationContext,
            modelPresetSelectionServiceId,
          ),
        );
      }

      Future<(NativeAdeleRuntime, Project)> openProject() async {
        final app = NativeAdeleRuntime(
          localStateRoot: () => f.roots.localStateRoot,
        );
        final provider = TestProjectProvider(app.registry);
        addTearDown(provider.close);
        final project = await app.lifecycle.openProject(
          sourceLocation: f.directory.uri,
          provider: app.lifecycle.resolveProjectProvider(provider.providerId),
        );
        return (app, project);
      }

      final (first, project) = await openProject();
      final graph = await createSelectionSessions(
        first,
        project,
        OrchestrationStrategyId(_browserStrategy),
      );
      final id = graph.session.id;
      await f.withApplication(tester, first, (ui, _) async {
        await edit(ui);
        expect(draft(), original);
        expect(f.requests, isEmpty);
        expect(f.storage.calls, isEmpty);
        await browse(ui);
        await select(ui, 'Work OpenAI', 'retiring');
        expect(draft(), original);
        // The already-highlighted row loses its exact registration, even though
        // both stable IDs and the owning OpenAI backend remain available.
        final old = f.capture('work');
        f.catalogModels['/work/models'] = [_sharedModel];
        expect(await f.refresh(), _refreshResult('applied', 'replaced'));
        old.expectReplacement(f.capture('work'));
        await ui._tap(find.text('Use model'));
        expect(find.text('Model Browser'), findsOneWidget);
        expect(
          find.text('Catalog changed; refresh to browse again.'),
          findsOneWidget,
        );
        expect(draft(), original);
        await browse(ui, refresh: true);
        await select(ui, 'Work OpenAI', _sharedModel);
        await use(ui);
        expect(draft(), work);
        expect(await saved(), values(original));
        await save(ui);
        expect(await saved(), values(work));
        expect(
          (await selections().updateSessionSelection(
            id.value,
            'review',
            0,
          )).revision,
          1,
        );
        await ui.dismiss();
      });

      // New app, Settings worker, frontend and AOT generations; no catalog
      // observation is required to restore either the preset or Session choice.
      final countBeforeRestart = f.requests.length;
      final (second, restored) = await openProject();
      expect(restored.id, project.id);
      await f.withApplication(tester, second, (ui, _) async {
        await edit(ui);
        final selection = await selections().readSessionSelection(id.value);
        expect((selection.selectedPresetId, selection.revision), ('review', 1));
        expect(draft(), work);
        expect(f.requests, hasLength(countBeforeRestart));
        expect(f.storage.calls, hasLength(countBeforeRestart));
        final tool = ReviewExecutionFixture();
        final tools = second.extensions.register(
          point: modelToolContributions,
          id: ExtensionId('test.browser.tool'),
          value: tool,
        );
        final policy = second.extensions.register(
          point: toolAuthorizationPolicies,
          id: ExtensionId('test.browser.ask'),
          value: ToolAuthorizationPolicyContribution(
            evaluate: (_) => ToolAuthorizationDecision.ask,
          ),
        );
        final owner = SessionExecutionController(
          runtime: second,
          session: second.store.session(id)!,
          providerId: ProviderId('test.browser.no-fallback'),
          model: 'not-selected',
        );
        Future<RunId> advance(RunState expected) async {
          final run = await owner.startRun();
          await owner.activeRunFuture?.timeout(const Duration(seconds: 10));
          expect(owner.stateForRun(run), expected, reason: '${owner.failure}');
          return run;
        }

        void expectInvocations(List<(String, String)> expected) {
          final posts = f.requests.where((r) => r['method'] == 'POST');
          expect(
            posts.map((r) {
              final body = r['body']! as Map;
              return (
                r['authority'],
                r['path'],
                r['authorization'],
                body['model'],
                (body['reasoning'] as Map)['effort'],
              );
            }),
            [
              for (final (account, model) in expected)
                (
                  Uri.parse(
                    f.records[account]!.values['endpoint']! as String,
                  ).authority,
                  '/$account/responses',
                  'Bearer test-$account-key',
                  model,
                  'high',
                ),
            ],
          );
          expect(f.storage.calls, List.filled(f.requests.length, 'read'));
        }

        try {
          f.proposeReviewTool = true;
          final waiting = await advance(RunState.waiting);
          expectInvocations([('work', _sharedModel)]);
          expect(tool.executedSessions, isEmpty);
          await browse(ui);
          await select(ui, 'Personal OpenAI', _sharedModel);
          await use(ui);
          expect(
            draft(),
            personal,
            reason: 'The same model is a distinct reference on Personal.',
          );
          expect(await saved(), values(work));
          await browse(ui);
          await select(ui, 'Personal OpenAI', 'personal-only');
          await use(ui);
          expect(draft(), next);
          await save(ui);
          expect(await saved(), values(next));

          expect(
            owner.resolveApproval(owner.pendingApproval!, approved: true),
            isTrue,
          );
          await owner.activeRunFuture!.timeout(const Duration(seconds: 10));
          expect(
            owner.stateForRun(waiting),
            RunState.completed,
            reason: '${owner.failure}',
          );
          expect(tool.executedSessions, [id.value]);
          expectInvocations([('work', _sharedModel), ('work', _sharedModel)]);
          expect(await advance(RunState.completed), isNot(waiting));
          expectInvocations([
            ('work', _sharedModel),
            ('work', _sharedModel),
            ('personal', 'personal-only'),
            ('personal', 'personal-only'),
          ]);
        } finally {
          await owner.close();
          await policy.close();
          await tools.close();
        }
        await ui.dismiss();
      });
    }),
  );
}
