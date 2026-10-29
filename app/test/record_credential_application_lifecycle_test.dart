import 'dart:async';
import 'dart:io';
import 'dart:ui' show AppExitResponse, IsolateNameServer;

import 'package:adele_desktop/application.dart';
import 'package:adele_desktop/core/application_plugin_bootstrap.dart';
import 'package:adele_desktop/core/credential_service.dart';
import 'package:adele_desktop/core/global_settings_service.dart';
import 'package:adele_desktop/frontend/contribution_bridge.dart';
import 'package:adele_desktop/frontend/prepared_frontend.dart';
import 'package:adele_desktop/frontend/prepared_main_content_host.dart';
import 'package:adele_desktop/terminal/native_adele_runtime.dart';
import 'package:adele_desktop/ui/settings/global_settings_dialog.dart';
import 'package:adele_platform_storage/adele_platform_storage.dart';
import 'package:adele_plugin_api/adele_plugin_api.dart';
import 'package:adele_settings/adele_settings.dart';
import 'package:dart_eval/dart_eval.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plugin_runtime/plugin_runtime.dart';

import '../../tools/backend_artifacts.dart';

final _slot = RecordCredentialSlotId('api-key');
const _workerName = 'dev.adele.global-settings-owner';

void main() {
  for (final exiting in [false, true]) {
    testWidgets(
      '${exiting ? 'accepted exit' : 'Settings dismissal'} retains an admitted credential UI write until it settles',
      (tester) => tester.runAsync(() async {
        await tester.binding.setSurfaceSize(const Size(1100, 1000));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        final fixture = await _ApplicationFixture.create();
        try {
          await fixture.mount(tester);
          final record = await fixture.createRecord();
          await fixture.openRecord(tester);
          expect(find.text('Credential status not checked'), findsOneWidget);
          expect(fixture.storage.calls, isEmpty);
          await _credentialAction(tester, 'check');
          await _until(
            tester,
            () => find.text('No credential configured').evaluate().isNotEmpty,
          );
          await _credentialAction(tester, 'set');
          final input = find.byKey(
            const ValueKey('credential-input-providers-work-openai-api-key'),
          );
          final controller = tester.widget<TextField>(input).controller!;
          await tester.enterText(input, 'ui-write-during-departure');
          await _credentialAction(tester, 'submit');
          await fixture.storage.writeEntered.future;
          await tester.pump();
          expect(controller.text, isEmpty);
          expect(input, findsNothing);
          expect(fixture.storage.calls, ['contains', 'write']);
          final worker = IsolateNameServer.lookupPortByName(_workerName);
          final originalDialog = tester.element(
            find.byType(GlobalSettingsDialog),
          );
          var exited = false;
          Future<AppExitResponse>? exit;
          if (exiting) {
            exit = tester.binding.handleRequestAppExit().then((response) {
              exited = true;
              return response;
            });
            await fixture.closeStarted.future;
            await expectLater(fixture.settings.load(), throwsStateError);
            await expectLater(
              fixture.associations.inspect(record, _slot),
              throwsA(
                isA<RecordCredentialFailure>().having(
                  (failure) => failure.kind,
                  'kind',
                  RecordCredentialFailureKind.closed,
                ),
              ),
            );
            expect(originalDialog.mounted, isTrue);
          } else {
            await tester.tap(find.byTooltip('Close Settings'));
            await tester.pumpAndSettle();
            expect(originalDialog.mounted, isFalse);
            expect(find.byType(GlobalSettingsDialog), findsNothing);
            expect(fixture.closeStarted.isCompleted, isFalse);
            // A fresh Settings read queues behind the admitted association,
            // without closing its owner or probing the saved reference.
            await tester.tap(find.byKey(const ValueKey('settings-button')));
            await tester.pump();
            expect(find.byType(GlobalSettingsDialog), findsOneWidget);
          }
          expect(exited, isFalse);
          expect(fixture.storage.values, isEmpty);
          expect(fixture.runtime.plugins.state, ApplicationPluginState.ready);
          expect(IsolateNameServer.lookupPortByName(_workerName), worker);
          expect(fixture.storage.calls, ['contains', 'write']);
          fixture.storage.releaseWrite.complete();
          if (exit != null) {
            expect(await exit, AppExitResponse.exit);
            await tester.pumpAndSettle();
            expect(find.byType(GlobalSettingsDialog), findsNothing);
            expect(IsolateNameServer.lookupPortByName(_workerName), isNull);
            expect(
              fixture.runtime.plugins.state,
              ApplicationPluginState.closed,
            );
            await expectLater(
              fixture.credentials.contains(fixture.storage.reference!),
              throwsA(
                isA<CredentialFailure>().having(
                  (failure) => failure.kind,
                  'kind',
                  CredentialFailureKind.closed,
                ),
              ),
            );
          } else {
            await fixture.openRecord(tester, alreadyOpen: true);
            expect(fixture.credentialConstructions, 1);
            expect(fixture.associationConstructions, 1);
            expect(find.text('Credential status not checked'), findsOneWidget);
            expect(fixture.storage.calls, ['contains', 'write', 'read']);
            await _credentialAction(tester, 'check');
            await _until(
              tester,
              () =>
                  find.text('Credential stored locally').evaluate().isNotEmpty,
            );
            expect(fixture.storage.calls, [
              'contains',
              'write',
              'read',
              'read',
            ]);
          }
          expect(
            await File(
              '${fixture.roots.configurationRoot}/providers/work-openai.toml',
            ).readAsString(),
            contains(fixture.storage.reference!.value),
          );
          expect(fixture.storage.values, hasLength(1));
          expect(tester.takeException(), isNull);
        } finally {
          await fixture.dispose(tester);
        }
      }),
      skip: !Platform.isLinux,
    );
  }

  for (final graceful in [true, false]) {
    for (final failWrite in [false, true]) {
      testWidgets(
        '${graceful ? 'accepted exit' : 'widget disposal'} drains a ${failWrite ? 'failed' : 'successful'} association workflow before closing dependencies',
        (tester) => tester.runAsync(() async {
          final fixture = await _ApplicationFixture.create();
          fixture.storage.failWrite = failWrite;
          try {
            await fixture.mount(tester);
            final record = await fixture.createRecord();
            final worker = IsolateNameServer.lookupPortByName(_workerName);
            expect(worker, isNotNull);
            final admitted = fixture.associations.attach(
              record,
              _slot,
              CredentialSecret('lifecycle-test-secret'),
            );
            await fixture.storage.writeEntered.future;
            final failed = failWrite
                ? expectLater(
                    admitted,
                    throwsA(
                      isA<RecordCredentialFailure>().having(
                        (failure) => failure.kind,
                        'kind',
                        RecordCredentialFailureKind.reconciliationRequired,
                      ),
                    ),
                  )
                : null;
            var exited = false;
            final runtimeClosed = fixture.runtime.plugins.changes.firstWhere(
              (state) => state == ApplicationPluginState.closed,
            );
            Future<AppExitResponse>? exiting;
            if (graceful) {
              exiting = tester.binding.handleRequestAppExit().then((response) {
                exited = true;
                return response;
              });
            } else {
              await tester.pumpWidget(const SizedBox.shrink());
            }
            await fixture.closeStarted.future;
            await expectLater(
              fixture.associations.inspect(record, _slot),
              throwsA(
                isA<RecordCredentialFailure>().having(
                  (failure) => failure.kind,
                  'kind',
                  RecordCredentialFailureKind.closed,
                ),
              ),
            );

            // Public configuration admission closes immediately, but the admitted
            // workflow must retain private worker and credential access.
            await expectLater(fixture.settings.load(), throwsStateError);
            await expectLater(
              fixture.settings.loadRecords(record.collection),
              throwsStateError,
            );
            await expectLater(
              fixture.settings.updateRecord(record, {
                'display-name': 'Too late',
              }),
              throwsStateError,
            );
            await expectLater(
              fixture.settings.deleteRecord(record),
              throwsStateError,
            );
            final credentialsAvailable = fixture.credentials.contains(
              fixture.storage.reference!,
            );
            var drained = false;
            final draining = fixture.associations.close().then(
              (_) => drained = true,
            );
            await tester.pump();
            expect(drained, isFalse);
            expect(exited, isFalse);
            expect(fixture.storage.calls, ['contains', 'write']);
            expect(fixture.runtime.plugins.state, ApplicationPluginState.ready);
            expect(IsolateNameServer.lookupPortByName(_workerName), worker);

            fixture.storage.releaseWrite.complete();
            RecordCredentialResult? result;
            if (failed != null) {
              await failed;
            } else {
              // Attach performs a fresh conditional TOML read after the keyring
              // write and its verification. A partial credential drain is not
              // enough to produce this acknowledged, fresh record view.
              result = await admitted;
              expect(result.status, RecordCredentialStatus.stored);
              expect(result.record, isNot(same(record)));
              expect(result.record.id, record.id);
              expect(result.record.values, record.values);
            }
            expect(await credentialsAvailable, !failWrite);
            await draining;
            if (exiting != null) expect(await exiting, AppExitResponse.exit);
            await runtimeClosed;

            await expectLater(fixture.settings.load(), throwsStateError);
            await expectLater(
              fixture.credentials.contains(fixture.storage.reference!),
              throwsA(
                isA<CredentialFailure>().having(
                  (failure) => failure.kind,
                  'kind',
                  CredentialFailureKind.closed,
                ),
              ),
            );
            expect(IsolateNameServer.lookupPortByName(_workerName), isNull);
            expect(fixture.storage.calls, [
              'contains',
              'write',
              if (!failWrite) 'read',
              'contains',
            ]);

            // Reopen only after application shutdown released the original owner.
            // Its returned view remains display data, not authority on this owner.
            final reopenedSettings = GlobalSettingsService(
              catalog: fixture.settings.catalog,
              records: fixture.settings.records,
              roots: fixture.roots,
            );
            final reopenedCredentials = CredentialService(fixture.storage);
            final reopenedAssociations = RecordCredentialService(
              settings: reopenedSettings,
              credentials: reopenedCredentials,
            );
            try {
              final loaded = await reopenedSettings.loadRecords(
                record.collection,
              );
              expect(loaded.diagnostics, isEmpty);
              final persisted = loaded.records.single;
              expect(persisted.id, (result?.record ?? record).id);
              expect(persisted.type, (result?.record ?? record).type);
              expect(persisted.values, (result?.record ?? record).values);
              expect(
                (await reopenedAssociations.inspect(persisted, _slot)).status,
                failWrite
                    ? RecordCredentialStatus.missingLocal
                    : RecordCredentialStatus.stored,
              );
            } finally {
              await reopenedAssociations.close();
              await reopenedSettings.close();
              await reopenedCredentials.close();
            }
            expect(tester.takeException(), isNull);
          } finally {
            await fixture.dispose(tester);
          }
        }),
        skip: !Platform.isLinux,
      );
    }
  }

  testWidgets(
    'pending and rejected prepared exit retain the Settings credential draft and owner',
    (tester) => tester.runAsync(() async {
      await tester.binding.setSurfaceSize(const Size(1100, 1000));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final fixture = await _ApplicationFixture.create();
      final preflightEntered = Completer<void>();
      final releasePreflight = Completer<bool>();
      final host = PreparedMainContentHost(
        confirm: (_) {
          preflightEntered.complete();
          return releasePreflight.future;
        },
      );
      PreparedFrontend? generation;
      try {
        await fixture.mount(tester, mainContentHost: host);
        const library = 'package:credential_exit/main.dart';
        final program =
            (Compiler()
                  ..addPlugin(const ContributionDeclarations())
                  ..entrypoints.add(library))
                .compile({
                  'credential_exit': {'main.dart': _exitSource},
                  'adele_ui': {
                    'contribution_bridge.dart': await File(
                      '../packages/ui/lib/contribution_bridge.dart',
                    ).readAsString(),
                  },
                });
        final artifact = await File(
          '${fixture.root.path}/exit.evc',
        ).writeAsBytes(program.write());
        final prepared = generation = await PreparedFrontend.load(artifact);
        prepared.validateOperation(library: library, entrypoint: 'prepareExit');
        host.createContribution(
          extensions: fixture.runtime.extensions,
          installation: PreparedPluginInstallation(
            metadata: PluginMetadata(
              id: PluginId('test.credential-exit'),
              version: '1',
              displayName: 'Exit participant',
            ),
            installationDirectory: fixture.root,
            backendArtifactUri: null,
          ),
          generation: prepared,
          descriptor: PreparedMainContentPresentation(
            extensionId: ExtensionId('test.credential-exit.main'),
            order: 100,
            library: library,
            initialize: 'initialize',
            entrypoint: 'build',
            operations: {'exit': 'prepareExit'},
            exitOperation: 'exit',
          ),
          isActive: () => true,
        );
        await fixture.createRecord();
        await fixture.openRecord(tester);
        await _credentialAction(tester, 'check');
        await _until(
          tester,
          () => find.text('No credential configured').evaluate().isNotEmpty,
        );
        await _credentialAction(tester, 'set');
        final input = find.byKey(
          const ValueKey('credential-input-providers-work-openai-api-key'),
        );
        final controller = tester.widget<TextField>(input).controller!;
        await tester.enterText(input, 'after-rejected-exit');
        final dialog = tester.element(find.byType(GlobalSettingsDialog));
        final worker = IsolateNameServer.lookupPortByName(_workerName);
        final exiting = tester.binding.handleRequestAppExit();
        await preflightEntered.future;
        await fixture.settings.load();
        expect(tester.element(find.byType(GlobalSettingsDialog)), same(dialog));
        expect(controller.text, 'after-rejected-exit');
        expect(fixture.closeStarted.isCompleted, isFalse);
        releasePreflight.complete(false);
        expect(await exiting, AppExitResponse.cancel);
        await tester.pumpAndSettle();
        expect(tester.element(find.byType(GlobalSettingsDialog)), same(dialog));
        expect(tester.widget<TextField>(input).controller, same(controller));
        expect(controller.text, 'after-rejected-exit');
        expect(fixture.closeStarted.isCompleted, isFalse);
        expect(fixture.runtime.plugins.state, ApplicationPluginState.ready);
        expect(IsolateNameServer.lookupPortByName(_workerName), worker);
        expect(fixture.storage.calls, isEmpty);

        fixture.storage.releaseWrite.complete();
        await _credentialAction(tester, 'submit');
        await _until(
          tester,
          () => find.text('Credential stored locally').evaluate().isNotEmpty,
        );
        expect(input, findsNothing);
        final records = await fixture.settings.loadRecords(
          RecordCollectionId('providers'),
        );
        final edited = await fixture.settings.updateRecord(
          records.records.single,
          {'display-name': 'Still usable'},
        );
        expect(
          (await fixture.associations.inspect(edited, _slot)).status,
          RecordCredentialStatus.stored,
        );
        expect(tester.takeException(), isNull);
      } finally {
        if (!releasePreflight.isCompleted) releasePreflight.complete(false);
        await fixture.dispose(tester);
        generation?.invalidate();
      }
    }),
    skip: !Platform.isLinux,
  );
}

final class _ApplicationFixture {
  _ApplicationFixture(this.root)
    : roots = PlatformStorageRoots(
        operatingSystem: Platform.operatingSystem,
        configurationRoot: '${root.path}/config',
        localStateRoot: '${root.path}/state',
        localDataRoot: '${root.path}/data',
        cacheRoot: '${root.path}/cache',
      );

  final Directory root;
  final PlatformStorageRoots roots;
  final runtime = NativeAdeleRuntime();
  final storage = _GatedWriteStorage();
  late final credentials = CredentialService(storage);
  final start = Completer<void>();
  final associationsCreated = Completer<void>();
  final closeStarted = Completer<void>();
  late GlobalSettingsService settings;
  late RecordCredentialService associations;
  var credentialConstructions = 0;
  var associationConstructions = 0;

  static Future<_ApplicationFixture> create() async {
    final root = await Directory.systemTemp.createTemp(
      'adele-record-credential-lifecycle-',
    );
    for (final id in ['dev.adele.source-editor', 'dev.adele.openai']) {
      await publishStockPluginInstallation(
        repositoryRoot: Directory.current.parent,
        installationDirectory: Directory('${root.path}/installed/$id'),
        pluginId: id,
        displayName: id,
      );
    }
    return _ApplicationFixture(root);
  }

  Future<void> mount(
    WidgetTester tester, {
    PreparedMainContentHost? mainContentHost,
  }) async {
    late Future<void> starting;
    await tester.pumpWidget(
      AdeleApplication(
        createRuntime: () => runtime,
        createCredentials: () {
          credentialConstructions++;
          return credentials;
        },
        createCredentialAssociations:
            ({required settings, required credentials}) {
              associationConstructions++;
              expect(credentials, same(this.credentials));
              this.settings = settings;
              associations = RecordCredentialService(
                settings: settings,
                credentials: credentials,
              );
              associationsCreated.complete();
              return associations;
            },
        mainContentHost: mainContentHost,
        configurationRoots: roots,
        readChatGptConfiguration: () => null,
        attachSessionContext: (_) => closeStarted.complete,
        bootstrapPlugins: (plugins) => starting = start.future.then(
          (_) => plugins.start(installationRoot: '${root.path}/installed'),
        ),
      ),
    );
    expect(credentialConstructions, 1);
    expect(associationConstructions, 0);
    expect(storage.calls, isEmpty);
    await tester.pumpWidget(
      AdeleApplication(
        createRuntime: () => throw StateError('Runtime must be retained.'),
        createCredentials: () =>
            throw StateError('Credentials must be retained.'),
        createCredentialAssociations:
            ({required settings, required credentials}) =>
                throw StateError('Factory must be selected at mount.'),
        configurationRoots: roots,
        readChatGptConfiguration: () => null,
      ),
    );
    start.complete();
    await starting;
    await associationsCreated.future;
    await settings.load();
    await tester.pumpAndSettle();
    expect(credentialConstructions, 1);
    expect(associationConstructions, 1);
    expect(
      storage.calls,
      isEmpty,
      reason: 'Startup must not access the keyring.',
    );
    expect(await Directory(roots.configurationRoot).exists(), isFalse);
    expect(runtime.plugins.host, isNull);
    expect(runtime.plugins.backends, isEmpty);
  }

  Future<RecordView> createRecord() => settings.createRecord(
    RecordTypeId('dev.adele.openai.api-key'),
    ConfigurationRecordId('work-openai'),
    {'display-name': 'Work'},
  );

  Future<void> openRecord(
    WidgetTester tester, {
    bool alreadyOpen = false,
  }) async {
    if (!alreadyOpen) {
      await tester.tap(find.byKey(const ValueKey('settings-button')));
    }
    await _until(
      tester,
      () => find.text('Enable Code Folding').evaluate().isNotEmpty,
    );
    final dialog = tester.widget<GlobalSettingsDialog>(
      find.byType(GlobalSettingsDialog),
    );
    expect(await dialog.service(), same(settings));
    expect(dialog.credentialAssociations!(), same(associations));
    await tester.tap(find.byKey(const ValueKey('settings-section')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Providers').last);
    await _until(tester, () => find.text('Work').evaluate().isNotEmpty);
    await tester.tap(find.text('Work'));
    await tester.pumpAndSettle();
  }

  Future<void> dispose(WidgetTester tester) async {
    if (!start.isCompleted) start.complete();
    if (!storage.releaseWrite.isCompleted) storage.releaseWrite.complete();
    await tester.pumpWidget(const SizedBox.shrink());
    if (associationsCreated.isCompleted) {
      await associations.close();
      await settings.close();
    }
    await credentials.close();
    await runtime.close();
    await root.delete(recursive: true);
  }
}

Future<void> _credentialAction(WidgetTester tester, String action) async {
  final control = find.byKey(
    ValueKey('credential-$action-providers-work-openai-api-key'),
  );
  await tester.ensureVisible(control);
  await tester.tap(control);
  await tester.pump();
}

Future<void> _until(WidgetTester tester, bool Function() ready) async {
  final clock = Stopwatch()..start();
  await tester.pump();
  while (!ready() ||
      find.byType(LinearProgressIndicator).evaluate().isNotEmpty) {
    if (clock.elapsed >= const Duration(seconds: 10)) {
      fail('Timed out waiting for credential Settings.');
    }
    await Future<void>.delayed(Duration.zero);
    await tester.pump();
  }
  await tester.pumpAndSettle();
}

final class _GatedWriteStorage implements CredentialStorageAdapter {
  final writeEntered = Completer<void>();
  final releaseWrite = Completer<void>();
  final calls = <String>[];
  final values = <CredentialReference, String>{};
  CredentialReference? reference;
  var failWrite = false;

  @override
  Future<bool> contains(CredentialReference reference) async {
    calls.add('contains');
    return values.containsKey(reference);
  }

  @override
  Future<String?> read(CredentialReference reference) async {
    calls.add('read');
    return values[reference];
  }

  @override
  Future<void> write(
    CredentialReference reference,
    CredentialSecret secret,
  ) async {
    calls.add('write');
    this.reference = reference;
    writeEntered.complete();
    await releaseWrite.future;
    if (failWrite) throw const CredentialFailure(CredentialFailureKind.failed);
    values[reference] = secret.reveal();
  }

  @override
  Future<void> delete(CredentialReference reference) =>
      throw UnimplementedError();
}

const _exitSource = '''
import 'package:adele_ui/contribution_bridge.dart';

void initialize() {}
dynamic build() => null;

Future<Map<String, dynamic>> prepareExit() async {
  final accepted = await confirmContribution(<String, dynamic>{
    'title': 'Exit?',
    'message': 'Leave this workspace?',
    'acceptLabel': 'Leave',
    'cancelLabel': 'Stay',
  });
  return <String, dynamic>{'accepted': accepted};
}
''';
