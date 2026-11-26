part of 'openai_record_startup_integration_test.dart';

const _modelConfiguration = 'dev.adele.plugin.model-configuration';
const _browserStrategy = 'test.browser.orchestration';
const _sharedModel = 'gpt-5.4';
const _highOnly = 'gpt-5-pro';
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
      'app/test/core/fixtures/openai_model_browser_loopback.dart',
      Directory('$root/openai'),
    ),
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
    'prepared Model Browser carries effort choices through Save, restart and Run approval',
    (tester) => tester.runAsync(() async {
      final f = await prepare();
      final collection = RecordCollectionId('model-presets');
      Map<String, String> model(String id, String name) => {
        'provider-id': '$_recordType.$id-openai',
        'model-id': name,
      };
      // An authored, schema-valid preference can predate better catalog data.
      final original = model('work', _highOnly);
      final work = model('work', _sharedModel);
      final personal = model('personal', _sharedModel);
      Map<String, Object> values(Map<String, String> target, String? effort) =>
          {'name': 'Code review', 'model': target, 'reasoning-effort': ?effort};
      await f.settings.createRecord(
        RecordTypeId('$_modelConfiguration.preset'),
        ConfigurationRecordId('review'),
        values(original, 'low'),
      );
      final toml = File(
        '${f.roots.configurationRoot}/model-presets/code-review.toml',
      );
      final originalBytes = await toml.readAsBytes();
      expect(utf8.decode(originalBytes), contains('recordId = "review"'));
      const retiring = 'gpt-6-astra';
      f.catalogModels['/work/models'] = [_sharedModel, _highOnly, retiring];
      f.catalogModels['/personal/models'] = [_sharedModel];
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
      final effort = find.byKey(
        const ValueKey('record-input-$_review-reasoning-effort'),
        skipOffstage: false,
      );
      const all = ['none', 'minimal', 'low', 'medium', 'high', 'xhigh', 'max'];
      const known = ['none', 'low', 'medium', 'high', 'xhigh'];
      void expectEffort(String? selected, List<String> choices) {
        final menu = tester.widget<DropdownButton<String>>(effort);
        expect(menu.onChanged, isNotNull);
        expect(menu.value, selected);
        expect(
          menu.items!.where((item) => item.enabled).map((item) => item.value),
          [null, ...choices],
        );
        expect((menu.items!.first.child as Text).data, 'Provider default');
        expect(
          find.byKey(
            const ValueKey('record-presence-$_review-reasoning-effort'),
            skipOffstage: false,
          ),
          findsNothing,
        );
      }

      var catalogRounds = 0;
      var posts = 0;
      void expectTraffic() {
        expect(
          f.requests.where((r) => r['method'] == 'GET'),
          hasLength(catalogRounds * 2),
        );
        expect(f.requests, hasLength(catalogRounds * 2 + posts));
        expect(f.storage.calls, List.filled(catalogRounds * 2 + posts, 'read'));
      }

      String authority(String account) => account == 'work'
          ? Uri.parse(f.origin).authority
          : Uri.parse(
              f.records[account]!.values['endpoint']! as String,
            ).authority;
      Future<void> edit(_ProviderSettings ui) async {
        await ui.section('Model Presets');
        await ui.until(
          () => ui.key('record-$_review').evaluate().isNotEmpty,
          'saved review',
        );
        await ui._tap(find.text('Code review'));
        await ui.press('record-edit-$_review');
        await ui.until(
          () => find.text('Browse models...').evaluate().isNotEmpty,
          'prepared field editor',
        );
      }

      Future<void> save(_ProviderSettings ui) async {
        await ui.press('record-save-$_review');
        await ui.until(
          () => ui._enabled('record-edit-$_review'),
          'Save acknowledgement',
        );
        expectTraffic();
      }

      Finder chip(String text) => find.widgetWithText(ChoiceChip, text);
      Future<void> browse(
        _ProviderSettings ui, {
        bool refresh = false,
        bool unavailable = false,
      }) async {
        // Never start aggregate discovery against an ambient account.
        expect(
          f.registry
              .providersFor(modelProviderCapability)
              .map((p) => p.id.value),
          unorderedEquals([work['provider-id'], personal['provider-id']]),
        );
        _expectCatalogAssociations(f.bootstrap, f.registry);
        expectTraffic();
        final before = f.requests.length;
        final reads = f.storage.readReferences.length;
        await ui._tap(find.text(refresh ? 'Refresh' : 'Browse models...'));
        await ui._tap(chip('All'));
        final rows = find.descendant(
          of: find.byType(Dialog).last,
          matching: find.text(_sharedModel),
        );
        if (unavailable) {
          await ui._tap(find.text('Provider status'));
          await ui.until(
            () =>
                find
                    .textContaining('Catalog request failed.')
                    .evaluate()
                    .length ==
                2,
            'both explicit catalog requests failed',
          );
          expect(rows, findsNothing);
        } else {
          await ui.until(
            () => rows.evaluate().length == 2,
            'shared model on two configured accounts',
          );
        }
        expect(
          f.requests.skip(before),
          unorderedEquals([
            for (final id in ['work', 'personal'])
              {
                'method': 'GET',
                'authority': authority(id),
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
        catalogRounds++;
        expectTraffic();
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
        expectTraffic();
      }

      Future<void> cancelBrowser(_ProviderSettings ui) => ui._tap(
        find.descendant(
          of: find.byType(Dialog).last,
          matching: find.text('Cancel'),
        ),
      );

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
        expectEffort('low', all);
        expectTraffic();
        await browse(ui);
        await select(ui, 'OpenAI Work', _sharedModel);
        await cancelBrowser(ui);
        expect(draft(), original);
        expectEffort('low', all);
        await browse(ui);
        await select(ui, 'OpenAI Work', retiring);
        expect(draft(), original);
        // The already-highlighted row loses its exact registration, even though
        // both stable IDs and the owning OpenAI backend remain available.
        final old = f.capture('work');
        f.catalogModels['/work/models'] = [_sharedModel, _highOnly];
        expect(await f.refresh(), _refreshResult('applied', 'replaced'));
        old.expectReplacement(f.capture('work'));
        await ui._tap(find.text('Use model'));
        expect(find.text('Model Browser'), findsOneWidget);
        expect(
          find.text('Catalog changed; refresh to browse again.'),
          findsOneWidget,
        );
        expect(draft(), original);
        expectEffort('low', all);
        await browse(ui, refresh: true);
        await select(ui, 'OpenAI Work', _highOnly);
        await use(ui);
        expect(draft(), original);
        expectEffort('low', ['high']); // New evidence, not a change of model.
        expect(
          find.textContaining('not reported as supported'),
          findsOneWidget,
        );
        await ui._tap(effort);
        await ui._tap(find.text('High').last);
        expectEffort('high', ['high']);

        // An invalid manual proposal from another account cannot replace the
        // accepted Work pair or its known effort choices, even transiently.
        await browse(ui);
        await ui._tap(find.text('Enter manually'));
        await ui._tap(chip('OpenAI Personal'));
        final manualModel = find.descendant(
          of: find.byType(Dialog).last,
          matching: find.byType(TextField),
        );
        const invalid = 'model\u007fid';
        await tester.enterText(manualModel, invalid);
        await tester.pump();
        await ui._tap(find.text('Use reference'));
        expect(find.textContaining('Property model-id:'), findsOneWidget);
        expect(tester.widget<TextField>(manualModel).controller!.text, invalid);
        expect(
          tester.widget<ChoiceChip>(chip('OpenAI Personal')).selected,
          isTrue,
        );
        expect(draft(), original);
        expectEffort('high', ['high']);
        await cancelBrowser(ui);
        expect(draft(), original);
        expectEffort('high', ['high']);
        expect(await toml.readAsBytes(), originalBytes);
        expectTraffic();

        await browse(ui);
        await select(ui, 'OpenAI Work', _sharedModel);
        await use(ui);
        expect(draft(), work);
        expectEffort('high', known); // A supported explicit choice survives.
        await ui._tap(effort);
        await ui._tap(find.text('None').last);
        expectEffort('none', known);
        expect(await saved(), values(original, 'low'));
        expect(await toml.readAsBytes(), originalBytes);
        await save(ui);
        expect(await saved(), values(work, 'none'));
        expect(
          (await selections().updateSessionSelection(
            id.value,
            'review',
            0,
          )).revision,
          1,
        );
        await ui.dismiss();
        expectTraffic();
      });

      // New app, Settings worker, frontend and AOT generations; no catalog
      // observation is required to restore either the preset or Session choice.
      final savedWork = await toml.readAsBytes();
      expect(
        utf8.decode(savedWork),
        utf8
            .decode(originalBytes)
            .replaceFirst('"$_highOnly"', '"$_sharedModel"')
            .replaceFirst('"low"', '"none"'),
        reason: 'Only authored model and effort changed, not catalog evidence.',
      );
      final (second, restored) = await openProject();
      expect(restored.id, project.id);
      await f.withApplication(tester, second, (ui, _) async {
        await edit(ui);
        final selection = await selections().readSessionSelection(id.value);
        expect((selection.selectedPresetId, selection.revision), ('review', 1));
        expect(draft(), work);
        expectEffort('none', all); // Catalog hints were never persisted.
        expect(await saved(), values(work, 'none'));
        expectTraffic();
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

        void expectInvocations(List<(String, String, String?)> expected) {
          posts = expected.length;
          expectTraffic();
          final requests = f.requests.where((r) => r['method'] == 'POST');
          expect(
            requests.map((r) {
              final body = r['body']! as Map;
              final reasoning = body['reasoning'] as Map?;
              return (
                r['authority'],
                r['path'],
                r['authorization'],
                body['model'],
                reasoning?.containsKey('effort') ?? false,
                reasoning?['effort'],
              );
            }),
            [
              for (final (account, model, effort) in expected)
                (
                  authority(account),
                  '/$account/responses',
                  'Bearer test-$account-key',
                  model,
                  effort != null,
                  effort,
                ),
            ],
          );
        }

        try {
          f.proposeReviewTool = true;
          final waiting = await advance(RunState.waiting);
          expectInvocations([('work', _sharedModel, 'none')]);
          expect(tool.executedSessions, isEmpty);
          // Failed discovery does not reinterpret the saved preference or retry.
          f.catalogStatus = HttpStatus.serviceUnavailable;
          await browse(ui, unavailable: true);
          expect(find.text('Use model'), findsNothing);
          await cancelBrowser(ui);
          expectEffort('none', all);
          expect(draft(), work);
          f.catalogStatus = HttpStatus.ok;

          await browse(ui);
          await select(ui, 'OpenAI Work', _highOnly);
          await use(ui);
          expectEffort(null, ['high']); // None is not supported by this model.
          expect(
            find.textContaining('Reset to Provider default'),
            findsOneWidget,
          );
          expect(draft(), model('work', _highOnly));
          expect(await toml.readAsBytes(), savedWork);
          await ui.press('record-cancel-$_review');
          await ui.press('record-edit-$_review');
          expect(draft(), work);
          expectEffort('none', all);

          await browse(ui);
          await select(ui, 'OpenAI Work', _highOnly);
          await use(ui);
          const description = 'Review a proposed change';
          expect(ui.key('record-presence-$_review-description'), findsNothing);
          await ui._enter('record-input-$_review-name', 'Personal review');
          await ui._enter('record-input-$_review-description', description);
          // Leave the text input before opening a dialog that restores focus.
          await tester.sendKeyEvent(LogicalKeyboardKey.tab);
          await tester.pumpAndSettle();
          expect(draft(), model('work', _highOnly));
          expectEffort(null, ['high']);
          expectTraffic();
          await browse(ui);
          await select(ui, 'OpenAI Personal', _sharedModel);
          await use(ui);
          expect(
            draft(),
            personal,
            reason: 'The same model is a distinct reference on Personal.',
          );
          expectEffort(null, all); // Custom endpoint, even for the same ID.
          expect(await saved(), values(work, 'none'));
          expect(await toml.readAsBytes(), savedWork);
          await save(ui);
          expect(await saved(), {
            ...values(personal, null),
            'name': 'Personal review',
            'description': description,
          });
          final edited = await toml.readAsString();
          expect(edited, contains('recordId = "review"'));
          expect(edited, contains('name = "Personal review"'));
          expect(edited, isNot(contains('reasoning-effort')));
          expect(
            await File('${toml.parent.path}/personal-review.toml').exists(),
            isFalse,
          );
          final selected = await selections().readSessionSelection(id.value);
          expect((selected.selectedPresetId, selected.revision), ('review', 1));

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
          expectInvocations([
            ('work', _sharedModel, 'none'),
            ('work', _sharedModel, 'none'),
          ]);
          expect(await advance(RunState.completed), isNot(waiting));
          expectInvocations([
            ('work', _sharedModel, 'none'),
            ('work', _sharedModel, 'none'),
            ('personal', _sharedModel, null),
            ('personal', _sharedModel, null),
          ]);
        } finally {
          await owner.close();
          await policy.close();
          await tools.close();
        }
        await ui.dismiss();
        expectTraffic();
      });
    }),
  );
}
