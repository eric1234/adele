@Timeout(Duration(minutes: 5))
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:adele_capabilities/adele_capabilities.dart';
import 'package:adele_contract/adele_contract.dart';
import 'package:adele_core_extensions/adele_core_extensions.dart';
import 'package:adele_desktop/core/application_plugin_bootstrap.dart';
import 'package:adele_desktop/core/environment_capability_invocation.dart';
import 'package:adele_desktop/core/environment_capability_selection.dart';
import 'package:adele_desktop/core/product_lifecycle.dart';
import 'package:adele_desktop/core/project_storage_host.dart';
import 'package:adele_desktop/frontend/application_frontend_bootstrap.dart';
import 'package:adele_desktop/frontend/prepared_main_content_host.dart';
import 'package:adele_desktop/frontend/prepared_settings.dart';
import 'package:adele_desktop/ui/main_content/main_content_host.dart';
import 'package:adele_environment/adele_environment.dart';
import 'package:adele_platform_storage/adele_platform_storage.dart';
import 'package:adele_plugin_api/adele_plugin_api.dart';
import 'package:adele_product/adele_product.dart';
import 'package:adele_project_storage/adele_project_storage.dart';
import 'package:adele_ui/adele_ui.dart';
import 'package:code_forge/code_forge.dart';
import 'package:crypto/crypto.dart';
import 'package:diff_viewer_contract/diff_viewer_contract.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plugin_builder/plugin_builder.dart';
import 'package:plugin_runtime/plugin_runtime.dart';

import '../../tools/backend_artifacts.dart';
import '../../tools/stock_frontend_descriptors.dart';
import '../tool/diff_viewer_frontend_compiler.dart';
import '../tool/source_editor_frontend_compiler.dart';
import 'support/project_provider.dart';

const _gitPlugin = 'dev.adele.plugin.git';
const _diffPlugin = 'dev.adele.diff-viewer';
const _sourcePlugin = 'dev.adele.source-editor';
const _punctuatedPath = "b tracked + [file]; 'quoted'\tname.txt";
const _reviewPath = "b review + [file]; 'quoted'.txt";
const _bound = Duration(seconds: 20);
const _scopes = [
  ('Unstaged changes', 'No unstaged changes'),
  ('Uncommitted changes', 'No uncommitted changes'),
  ('Task / Branch', 'No task changes'),
];
final _changes = CapabilityKey(
  id: CapabilityId('adele.diff.change-set-source'),
  majorVersion: 1,
);

void main() {
  late Directory artifacts;
  late Directory installations;
  late Directory frontendOnly;
  late Directory approvalDenied;
  late File host;
  late String aotRuntime;

  setUpAll(() async {
    artifacts = await Directory.systemTemp.createTemp('adele-diff-artifacts-');
    installations = await Directory('${artifacts.path}/installed').create();
    frontendOnly = await Directory('${artifacts.path}/frontend-only').create();
    approvalDenied = await Directory(
      '${artifacts.path}/approval-denied',
    ).create();
    final repository = Directory.current.parent;
    final dart = _dartExecutable();
    aotRuntime = File(dart).parent.uri.resolve('dartaotruntime').toFilePath();
    host = File('${artifacts.path}/host.aot');
    final git = await Directory('${installations.path}/git').create();
    for (final target in [
      (
        entrypoint: 'packages/plugin_backend_host/bin/adele_backend_host.dart',
        artifact: host,
      ),
      (
        entrypoint: 'plugins/git/packages/backend/bin/git_backend.dart',
        artifact: File('${git.path}/backend.aot'),
      ),
    ]) {
      await compileAotSnapshot(
        dartExecutable: dart,
        workingDirectory: repository,
        entrypoint: target.entrypoint,
        artifact: target.artifact,
        stage: 'prepared-diff-git',
      );
    }
    await publishStockPluginInstallation(
      repositoryRoot: repository,
      installationDirectory: git,
      pluginId: _gitPlugin,
      displayName: 'Git',
      backend: true,
    );
    final diff = await Directory('${installations.path}/diff').create();
    await compileDiffViewerFrontend(
      repositoryRoot: repository,
      sdkPath: File(dart).parent.parent.path,
      artifact: File('${diff.path}/frontend.evc'),
    );
    final component = {
      'frontend': {
        'artifact': 'frontend.evc',
        'presentations': stockFrontendDescriptors[_diffPlugin]!,
      },
    };
    await _manifest(diff, _diffPlugin, component);
    final alone = await Directory('${frontendOnly.path}/diff').create();
    await File('${diff.path}/frontend.evc').copy('${alone.path}/frontend.evc');
    await _manifest(alone, _diffPlugin, component);
    final deniedGit = await Directory('${approvalDenied.path}/git').create();
    for (final name in ['backend.aot', 'adele_plugin.installation.json']) {
      await File('${git.path}/$name').copy('${deniedGit.path}/$name');
    }
    final deniedDiff = await Directory('${approvalDenied.path}/diff').create();
    await File(
      '${diff.path}/frontend.evc',
    ).copy('${deniedDiff.path}/frontend.evc');
    await _manifest(deniedDiff, _diffPlugin, {
      'frontend': {
        'artifact': 'frontend.evc',
        'presentations': [
          {
            ...stockFrontendDescriptors[_diffPlugin]!.single,
            'environmentBufferedProcessCapabilities': [
              {'id': _changes.id.value, 'majorVersion': 1},
            ],
          },
        ],
      },
    });
    final source = await Directory('${installations.path}/source').create();
    await File('${source.path}/frontend.evc').writeAsBytes(
      await compileSourceEditorFrontend(repositoryRoot: repository),
    );
    await publishStockPluginInstallation(
      repositoryRoot: repository,
      installationDirectory: source,
      pluginId: _sourcePlugin,
      displayName: 'Source',
      frontend: true,
    );
  });
  tearDownAll(() => artifacts.delete(recursive: true));

  late _Fixture fixture;
  setUp(() async {
    fixture = await _Fixture.create(
      installations: installations,
      host: host,
      aotRuntime: aotRuntime,
    );
  });
  tearDown(() => fixture.close());

  Future<void> mount(
    WidgetTester tester, {
    Directory? catalog,
    bool approvalPresent = true,
  }) async {
    tester.view.physicalSize = const Size(1600, 2000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.runAsync(() => fixture.start(catalog ?? installations));
    if (!approvalPresent) {
      await tester.runAsync(
        () => fixture.backends.backends.single.retireProvider(
          fixture.capabilities.resolve(reviewApprovalCapability),
        ),
      );
    }
    await tester.runAsync(
      () => tester.pumpWidget(fixture.widget(fixture.additionalSession)),
    );
    await _waitFor(
      tester,
      () => find.text('Unstaged changes').evaluate().isNotEmpty,
    );
  }

  testWidgets(
    'stock EVC shows real nonprimary Git hunks, additions, deletion and refresh without mutations',
    (tester) async {
      await tester.runAsync(() async {
        await fixture.write(
          'a modified.txt',
          'context before\nAdditional edit\ncontext after\n',
        );
        await fixture.write('b new + [file].txt', 'A new untracked line\n');
        await fixture.file('c deleted.txt').delete();
        await fixture.write(
          'd staged.txt',
          'Staged only, never in this view\n',
        );
        await _git(fixture.additionalRoot, ['add', 'd staged.txt']);
        // A net HEAD comparison would hide this real unstaged reversal.
        await fixture.write('e reversal.txt', 'Index layer\n');
        await _git(fixture.additionalRoot, ['add', 'e reversal.txt']);
        await fixture.write('e reversal.txt', 'Original layer\n');
        await fixture.write('ignored.tmp', 'Ignored addition\n');
        await fixture.file('f binary.dat').writeAsBytes([0, 1, 2, 255]);
        await File(
          '${fixture.additionalWorktree.path}/outside.txt',
        ).writeAsString('Outside source scope\n');
        await File(
          '${fixture.primaryRoot.path}/a modified.txt',
        ).writeAsString('Primary worktree, not the selected Environment\n');
      });
      final before = (await tester.runAsync(fixture.fingerprint))!;
      await mount(tester);
      await _visible(tester, 'Additional edit');
      for (final text in [
        'a modified.txt',
        'Original text',
        'context before',
        'context after',
        'b new + [file].txt',
        'A new untracked line',
        'c deleted.txt',
        'Deleted baseline',
        'Index layer',
        'Original layer',
        'f binary.dat',
        'binary',
      ]) {
        expect(find.textContaining(text), findsWidgets);
      }
      expect(find.textContaining('@@ -'), findsWidgets);
      for (final absent in [
        'd staged.txt',
        'ignored.tmp',
        'outside.txt',
        'Primary worktree',
      ]) {
        expect(find.textContaining(absent), findsNothing);
      }
      expect(find.text('Diff'), findsOneWidget);
      expect(
        fixture.frontends.generations.map((generation) => generation.state),
        everyElement(InstalledFrontendState.active),
      );
      final diff = fixture.backends.catalog!.installations.singleWhere(
        (entry) => entry.metadata.id.value == _diffPlugin,
      );
      expect(diff.backendArtifactUri, isNull);
      expect(fixture.backends.backendForInstallation(diff), isNull);
      final git = fixture.backends.catalog!.installations.singleWhere(
        (entry) => entry.metadata.id.value == _gitPlugin,
      );
      expect(git.metadata.displayName, 'Git');
      expect(git.backendArtifactUri!.path, endsWith('/git/backend.aot'));
      expect(git.frontend, isNull);
      expect(
        fixture.backends.backendForInstallation(git),
        same(fixture.backends.backends.single),
      );
      final descriptor = stockFrontendDescriptors[_diffPlugin]!.single;
      expect(descriptor['order'], 200);
      expect(descriptor['capabilities'], isNull);
      expect(descriptor['backendServices'], isNull);
      expect(descriptor['canRequestSourceDisplay'], isTrue);
      expect(descriptor['environmentReadCapabilities'], isNull);
      expect(descriptor['environmentBufferedProcessCapabilities'], [
        {'id': _changes.id.value, 'majorVersion': _changes.majorVersion},
        {'id': reviewApprovalCapability.id.value, 'majorVersion': 1},
      ]);
      final changeBinding = fixture.capabilities.resolve(_changes);
      final environmentBinding = fixture.capabilities.resolve(
        environmentProviderCapability,
      );
      expect(
        changeBinding.provider.id.value,
        'dev.adele.git.change-set-source',
      );
      expect(
        environmentBinding.provider.id.value,
        'dev.adele.environment.git-worktree',
      );
      final owner = fixture.backends.backends.single;
      expect(owner.associationFor(changeBinding), isNull);
      expect(owner.isEnvironmentBound(changeBinding), isTrue);
      expect(
        owner.allowsEnvironmentHostService(
          changeBinding,
          AdeleEnvironmentHostService.bufferedProcess,
        ),
        isTrue,
      );
      expect(
        owner.allowsEnvironmentHostService(
          changeBinding,
          AdeleEnvironmentHostService.read,
        ),
        isFalse,
      );
      final approval = fixture.capabilities.resolve(reviewApprovalCapability);
      expect(approval.provider.id.value, 'dev.adele.git.review-approval');
      expect(approval.provider.serviceId, reviewApprovalHandlerServiceId);
      expect(owner.associationFor(approval), isNull);
      expect(owner.isEnvironmentBound(approval), isTrue);
      expect(
        owner.allowsEnvironmentHostService(
          approval,
          AdeleEnvironmentHostService.bufferedProcess,
        ),
        isTrue,
      );
      expect(
        owner.allowsEnvironmentHostService(
          approval,
          AdeleEnvironmentHostService.read,
        ),
        isFalse,
      );
      expect(await tester.runAsync(fixture.fingerprint), before);

      await tester.runAsync(
        () => fixture.write(
          'a modified.txt',
          'context before\nRefreshed real content\ncontext after\n',
        ),
      );
      _refresh(tester);
      await _visible(tester, 'Refreshed real content');
      expect(find.textContaining('Additional edit'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'stock Approve stages only the first nonprimary hunk and Unapprove restores that index portion',
    (tester) async {
      await tester.runAsync(() async {
        await fixture.write(
          _reviewPath,
          _reviewContent(first: true, second: true),
        );
        await File(
          '${fixture.primaryRoot.path}/$_reviewPath',
        ).writeAsString('Primary Environment must remain untouched\n');
      });
      final before = (await tester.runAsync(fixture.reviewState))!;
      await mount(tester);
      await _visible(tester, '+Selected first change');
      await _visible(tester, '+Selected second change');
      await _reviewReady(tester, 'Approve', count: 2);
      expect(find.textContaining('@@ -'), findsNWidgets(2));
      expect(_reviewAction('Unapprove'), findsNothing);
      final stale = tester
          .widget<TextButton>(_reviewAction('Approve').first)
          .onPressed!;
      await tester.runAsync(() => tester.tap(_reviewAction('Approve').first));
      await _waitFor(
        tester,
        () =>
            find.textContaining('+Selected first change').evaluate().isEmpty &&
            _reviewAction('Approve').evaluate().length == 1,
      );
      expect(find.textContaining('+Selected second change'), findsOneWidget);
      await tester.runAsync(
        () => fixture.expectReviewIndex(before, first: true),
      );
      expect(fixture.indexWrites, hasLength(1));
      expect(
        fixture.indexWrites.single['environmentId'],
        fixture.additional.id.value,
      );
      final afterApprove = (await tester.runAsync(fixture.reviewState))!;
      stale();
      await tester.pump();
      expect(await tester.runAsync(fixture.reviewState), afterApprove);
      expect(fixture.indexWrites, hasLength(1));

      await _selectScope(tester, 'Uncommitted changes');
      await _reviewReady(tester, 'Unapprove');
      await _reviewReady(tester, 'Approve');
      final stagedY = tester.getTopLeft(find.text('Staged changes')).dy;
      final unstagedY = tester
          .getTopLeft(find.text('Unstaged changes').last)
          .dy;
      expect(
        tester.getTopLeft(find.textContaining('+Selected first change')).dy,
        greaterThan(stagedY),
      );
      expect(
        tester.getTopLeft(find.textContaining('+Selected first change')).dy,
        lessThan(unstagedY),
      );
      expect(
        tester.getTopLeft(find.textContaining('+Selected second change')).dy,
        greaterThan(unstagedY),
      );
      expect(find.text('$_reviewPath  [modified]'), findsNWidgets(2));
      await tester.runAsync(() => tester.tap(_reviewAction('Unapprove')));
      await _visible(tester, 'No staged changes');
      await _reviewReady(tester, 'Approve', count: 2);
      expect(_reviewAction('Unapprove'), findsNothing);
      expect(find.textContaining('+Selected first change'), findsOneWidget);
      expect(find.textContaining('+Selected second change'), findsOneWidget);
      expect(await tester.runAsync(fixture.reviewState), before);
      await tester.runAsync(() => fixture.expectReviewIndex(before));
      expect(fixture.indexWrites, hasLength(2));
      expect(fixture.reads, isEmpty);
      expect(
        fixture.environmentRuntime.currentMaterialization(fixture.primary.id),
        isNull,
      );
      expect(
        fixture.store.runsForSession(fixture.additionalSession.id),
        isEmpty,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
    skip: !Platform.isLinux,
  );

  testWidgets(
    'stock Uncommitted scope shows staged-only nonprimary changes and confines HEAD inventory',
    (tester) async {
      await tester.runAsync(() async {
        await fixture.write('d staged.txt', 'Staged-only additional content\n');
        await _git(fixture.additionalRoot, ['add', 'd staged.txt']);
        await File(
          '${fixture.additionalWorktree.path}/outside.txt',
        ).writeAsString('Staged outside source scope\n');
        await _git(fixture.additionalWorktree, ['add', 'outside.txt']);
        await File(
          '${fixture.primaryRoot.path}/d staged.txt',
        ).writeAsString('Staged in primary Environment\n');
        await _git(fixture.primaryRoot, ['add', 'd staged.txt']);
      });
      await mount(tester);
      await _visible(tester, 'No unstaged changes');
      expect(find.textContaining('d staged.txt'), findsNothing);

      await _selectScope(tester, 'Uncommitted changes');
      await _visible(tester, 'Staged-only additional content');
      expect(find.text('Staged changes'), findsOneWidget);
      expect(find.text('d staged.txt  [modified]'), findsOneWidget);
      expect(find.textContaining('-Staged baseline'), findsOneWidget);
      expect(
        find.textContaining('+Staged-only additional content'),
        findsOneWidget,
      );
      expect(find.textContaining('@@ -1,1 +1,1 @@'), findsOneWidget);
      expect(find.textContaining('outside.txt'), findsNothing);
      expect(find.textContaining('Staged in primary'), findsNothing);
      expect(_sourceAction(), findsNothing);
      expect(
        fixture.store
            .requireSessionAuthority(fixture.additionalSession.id)
            .environmentId,
        fixture.additional.id,
      );
      expect(
        fixture.environmentRuntime.currentMaterialization(fixture.primary.id),
        isNull,
      );

      await _selectScope(tester, 'Unstaged changes');
      await _visible(tester, 'No unstaged changes');
      expect(find.textContaining('d staged.txt'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'stock Uncommitted scope omits an unchanged 1054288-byte binary image beside a staged text hunk',
    (tester) async {
      const imagePath = 'unchanged.bmp';
      const imageLength = 1054288;
      const pixelOffset = 592;
      // A 24-bit 1024 x 343 BMP, padded before its deterministic pixel data.
      final image = ByteData(imageLength)
        ..setUint16(0, 0x4d42, Endian.little)
        ..setUint32(2, imageLength, Endian.little)
        ..setUint32(10, pixelOffset, Endian.little)
        ..setUint32(14, 40, Endian.little)
        ..setInt32(18, 1024, Endian.little)
        ..setInt32(22, 343, Endian.little)
        ..setUint16(26, 1, Endian.little)
        ..setUint16(28, 24, Endian.little)
        ..setUint32(34, imageLength - pixelOffset, Endian.little);
      final bytes = image.buffer.asUint8List();
      for (var i = pixelOffset; i < bytes.length; i++) {
        bytes[i] = (i * 31 + i ~/ 256) & 255;
      }
      final stagedBefore = await tester.runAsync(() async {
        await fixture.file(imagePath).writeAsBytes(bytes);
        expect(await fixture.file(imagePath).length(), imageLength);
        await _git(fixture.additionalRoot, ['add', imagePath]);
        await _git(fixture.additionalRoot, [
          'commit',
          '-m',
          'Track unchanged large image',
        ]);
        await fixture.write(
          'd staged.txt',
          'Staged text beside unchanged image\n',
        );
        await _git(fixture.additionalRoot, ['add', 'd staged.txt']);
        expect(
          await _git(fixture.additionalRoot, [
            'diff',
            'HEAD',
            '--name-only',
            '--',
            imagePath,
          ]),
          isEmpty,
        );
        return _git(fixture.additionalRoot, ['diff', '--cached', '--binary']);
      });

      await mount(tester);
      await _visible(tester, 'No unstaged changes');
      expect(find.textContaining(imagePath), findsNothing);

      await _selectScope(tester, 'Uncommitted changes');
      await _visible(tester, '+Staged text beside unchanged image');
      expect(find.text('Staged changes'), findsOneWidget);
      expect(find.text('d staged.txt  [modified]'), findsOneWidget);
      expect(find.textContaining('-Staged baseline'), findsOneWidget);
      expect(find.textContaining('@@ -1,1 +1,1 @@'), findsOneWidget);
      expect(find.textContaining('No unstaged changes'), findsOneWidget);
      for (final absent in [
        imagePath,
        'binary',
        'oversized',
        'Unable to load',
      ]) {
        expect(find.textContaining(absent), findsNothing);
      }
      expect(
        fixture.store
            .requireSessionAuthority(fixture.additionalSession.id)
            .environmentId,
        fixture.additional.id,
      );
      expect(fixture.additional.role, EnvironmentRole.additional);
      expect(
        fixture.environmentRuntime.currentMaterialization(fixture.primary.id),
        isNull,
      );
      await tester.runAsync(() async {
        expect(await fixture.file(imagePath).readAsBytes(), bytes);
        expect(
          await _git(fixture.additionalRoot, ['diff', '--cached', '--binary']),
          stagedBefore,
        );
        expect(
          await _git(fixture.additionalRoot, ['diff', '--name-only']),
          isEmpty,
        );
      });
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'stock Uncommitted layers retain partial staging and cancellation and refresh the selected scope',
    (tester) async {
      await tester.runAsync(() async {
        await fixture.write(
          'a modified.txt',
          'context before\nStaged middle\ncontext after\n',
        );
        await fixture.write('e reversal.txt', 'Index layer\n');
        await _git(fixture.additionalRoot, [
          'add',
          'a modified.txt',
          'e reversal.txt',
        ]);
        await fixture.write(
          'a modified.txt',
          'context before\nStaged middle\nUnstaged ending\n',
        );
        await fixture.write('e reversal.txt', 'Original layer\n');
      });
      await mount(tester);
      await _visible(tester, 'Unstaged ending');
      expect(find.text('a modified.txt  [modified]'), findsOneWidget);
      expect(find.textContaining('-Original text'), findsNothing);

      await _selectScope(tester, 'Uncommitted changes');
      await _visible(tester, '-Original text');
      expect(find.text('a modified.txt  [modified]'), findsNWidgets(2));
      expect(find.text('e reversal.txt  [modified]'), findsNWidgets(2));
      expect(find.textContaining('+Staged middle'), findsOneWidget);
      expect(find.textContaining('-context after'), findsOneWidget);
      expect(find.textContaining('+Unstaged ending'), findsOneWidget);
      expect(find.textContaining('-Original layer'), findsOneWidget);
      expect(find.textContaining('+Index layer'), findsOneWidget);
      expect(find.textContaining('-Index layer'), findsOneWidget);
      expect(find.textContaining('+Original layer'), findsOneWidget);
      final stagedY = tester.getTopLeft(find.text('Staged changes')).dy;
      // The first matching label is the scope control, the last is the section.
      final unstagedY = tester
          .getTopLeft(find.text('Unstaged changes').last)
          .dy;
      for (final path in ['a modified.txt', 'e reversal.txt']) {
        final headers = find.text('$path  [modified]');
        expect(tester.getTopLeft(headers.first).dy, greaterThan(stagedY));
        expect(tester.getTopLeft(headers.first).dy, lessThan(unstagedY));
        expect(tester.getTopLeft(headers.last).dy, greaterThan(unstagedY));
      }
      // Only the two current-working-file entries may navigate to Source.
      expect(_sourceAction(), findsNWidgets(2));
      for (final action in _sourceAction().evaluate()) {
        expect(
          tester.getTopLeft(find.byWidget(action.widget)).dy,
          greaterThan(unstagedY),
        );
      }

      await tester.runAsync(
        () => _git(fixture.additionalRoot, [
          'add',
          'a modified.txt',
          'e reversal.txt',
        ]),
      );
      _refresh(tester);
      await _waitFor(
        tester,
        () =>
            find.textContaining('+Unstaged ending').evaluate().isNotEmpty &&
            find.text('a modified.txt  [modified]').evaluate().length == 1,
      );
      expect(find.text('Staged changes'), findsOneWidget);
      expect(find.textContaining('e reversal.txt'), findsNothing);
      expect(_sourceAction(), findsNothing);

      await tester.runAsync(
        () => fixture.write(
          'a modified.txt',
          'context before\nStaged middle\nRefreshed working ending\n',
        ),
      );
      _refresh(tester);
      await _visible(tester, '+Refreshed working ending');
      expect(find.text('a modified.txt  [modified]'), findsNWidgets(2));
      expect(find.textContaining('+Unstaged ending'), findsOneWidget);
      expect(find.textContaining('-Unstaged ending'), findsOneWidget);
      expect(_sourceAction(), findsOneWidget);
      expect(find.textContaining('-Original text'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'stock Task scope shows committed-only managed branch changes and refreshes after a real commit',
    (tester) async {
      await tester.runAsync(() async {
        expect(
          (await _git(fixture.additionalRoot, [
            'branch',
            '--show-current',
          ])).trim(),
          fixture.additional.providerState!['branch'],
        );
        await fixture.write(
          'a modified.txt',
          'context before\nCommitted Task change\ncontext after\n',
        );
        await _git(fixture.additionalRoot, ['add', 'a modified.txt']);
        await _git(fixture.additionalRoot, [
          'commit',
          '-m',
          'First managed branch change',
        ]);
        expect(
          await _git(fixture.additionalRoot, ['status', '--porcelain=v1']),
          isEmpty,
        );
      });
      await mount(tester);
      await _visible(tester, 'No unstaged changes');
      expect(find.textContaining('a modified.txt'), findsNothing);
      await _selectScope(tester, 'Uncommitted changes');
      await _visible(tester, 'No uncommitted changes');
      expect(find.textContaining('a modified.txt'), findsNothing);

      await _selectScope(tester, 'Task / Branch');
      await _visible(tester, '+Committed Task change');
      expect(find.text('Committed changes'), findsOneWidget);
      expect(find.text('a modified.txt  [modified]'), findsOneWidget);
      expect(find.textContaining('-Original text'), findsOneWidget);
      expect(find.textContaining('No staged changes'), findsOneWidget);
      expect(find.textContaining('No unstaged changes'), findsOneWidget);
      expect(find.textContaining('No conflicts'), findsOneWidget);
      expect(find.textContaining('No task changes'), findsNothing);
      expect(_sourceAction(), findsNothing);
      expect(_reviewAction('Approve'), findsNothing);
      expect(_reviewAction('Unapprove'), findsNothing);

      final previousHead = await tester.runAsync(
        () => _git(fixture.additionalRoot, ['rev-parse', 'HEAD']),
      );
      await tester.runAsync(() async {
        await fixture.write(
          'a modified.txt',
          'context before\nRefreshed committed Task change\ncontext after\n',
        );
        await _git(fixture.additionalRoot, ['add', 'a modified.txt']);
        await _git(fixture.additionalRoot, [
          'commit',
          '-m',
          'Second managed branch change',
        ]);
        expect(
          await _git(fixture.additionalRoot, ['rev-parse', 'HEAD']),
          isNot(previousHead),
        );
      });
      _refresh(tester);
      await _visible(tester, '+Refreshed committed Task change');
      expect(find.textContaining('+Committed Task change'), findsNothing);
      // Refresh remains in Task scope and compares against establishment, not
      // the previous observation or the parent of the newest commit.
      expect(find.textContaining('-Original text'), findsOneWidget);
      expect(find.textContaining('-Committed Task change'), findsNothing);
      expect(find.text('a modified.txt  [modified]'), findsOneWidget);
      expect(_sourceAction(), findsNothing);
      for (final (scope, clean) in _scopes.take(2)) {
        await _selectScope(tester, scope);
        await _visible(tester, clean);
        expect(find.textContaining('a modified.txt'), findsNothing);
      }
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'stock Task layers use the selected nonprimary baseline and confine committed staged and unstaged paths',
    (tester) async {
      const path = 'g baseline.txt';
      const working = 'Selected Environment working layer\n';
      final selectedBaseline = fixture.baseline(fixture.additional);
      final primaryBaseline = fixture.baseline(fixture.primary);
      expect(selectedBaseline, isNot(primaryBaseline));
      expect(fixture.additional.role, EnvironmentRole.additional);
      expect(fixture.additionalRoot.path, isNot(fixture.primaryRoot.path));
      expect(
        fixture.additional.providerState!['sourceRelativePath'],
        'nested source',
      );
      await tester.runAsync(() async {
        expect(
          (await _git(fixture.additionalRoot, ['rev-parse', 'HEAD'])).trim(),
          selectedBaseline,
        );
        expect(
          (await _git(fixture.primaryRoot, ['rev-parse', 'HEAD'])).trim(),
          primaryBaseline,
        );
        await fixture.write(path, 'Selected Environment committed layer\n');
        final outside = File('${fixture.additionalWorktree.path}/outside.txt');
        await outside.writeAsString('Committed outside source scope\n');
        await _git(fixture.additionalWorktree, [
          'add',
          'nested source/$path',
          'outside.txt',
        ]);
        await _git(fixture.additionalRoot, [
          'commit',
          '-m',
          'Selected Environment committed work',
        ]);
        await fixture.write(path, 'Selected Environment staged layer\n');
        await outside.writeAsString('Staged outside source scope\n');
        await _git(fixture.additionalWorktree, [
          'add',
          'nested source/$path',
          'outside.txt',
        ]);
        await fixture.write(path, working);
        await outside.writeAsString('Unstaged outside source scope\n');

        final primaryFile = File('${fixture.primaryRoot.path}/$path');
        await primaryFile.writeAsString(
          'Primary Environment committed layer\n',
        );
        await _git(fixture.primaryRoot, ['add', path]);
        await _git(fixture.primaryRoot, [
          'commit',
          '-m',
          'Primary Environment committed work',
        ]);
        await primaryFile.writeAsString('Primary Environment staged layer\n');
        await _git(fixture.primaryRoot, ['add', path]);
        await primaryFile.writeAsString('Primary Environment working layer\n');
        await File(
          '${Directory.fromUri(fixture.project.sourceLocation).path}/$path',
        ).writeAsString('Original Project working layer\n');
      });
      await mount(tester);
      await _visible(tester, '+Selected Environment working layer');
      expect(find.text('$path  [modified]'), findsOneWidget);
      await _selectScope(tester, 'Task / Branch');
      await _visible(tester, '-Additional establishment baseline');
      expect(find.text('$path  [modified]'), findsNWidgets(3));
      for (final line in [
        '-Additional establishment baseline',
        '+Selected Environment committed layer',
        '-Selected Environment committed layer',
        '+Selected Environment staged layer',
        '-Selected Environment staged layer',
        '+Selected Environment working layer',
      ]) {
        expect(find.textContaining(line), findsOneWidget);
      }
      for (final absent in [
        'Primary establishment baseline',
        'Primary Environment',
        'Original Project',
        'outside.txt',
        'outside source scope',
        'nested source/',
      ]) {
        expect(find.textContaining(absent), findsNothing);
      }
      final committedY = tester.getTopLeft(find.text('Committed changes')).dy;
      final stagedY = tester.getTopLeft(find.text('Staged changes')).dy;
      final unstagedY = tester
          .getTopLeft(find.text('Unstaged changes').last)
          .dy;
      final headers = find.text('$path  [modified]');
      expect(tester.getTopLeft(headers.at(0)).dy, greaterThan(committedY));
      expect(tester.getTopLeft(headers.at(0)).dy, lessThan(stagedY));
      expect(tester.getTopLeft(headers.at(1)).dy, greaterThan(stagedY));
      expect(tester.getTopLeft(headers.at(1)).dy, lessThan(unstagedY));
      expect(tester.getTopLeft(headers.at(2)).dy, greaterThan(unstagedY));
      expect(_sourceAction(), findsOneWidget);
      expect(tester.getTopLeft(_sourceAction()).dy, greaterThan(unstagedY));
      await _reviewReady(tester, 'Approve');
      await _reviewReady(tester, 'Unapprove');
      expect(
        tester.getTopLeft(_reviewAction('Unapprove')).dy,
        greaterThan(stagedY),
      );
      expect(
        tester.getTopLeft(_reviewAction('Unapprove')).dy,
        lessThan(unstagedY),
      );
      expect(
        tester.getTopLeft(_reviewAction('Approve')).dy,
        greaterThan(unstagedY),
      );
      expect(
        fixture.store
            .requireSessionAuthority(fixture.additionalSession.id)
            .environmentId,
        fixture.additional.id,
      );
      expect(
        fixture.environmentRuntime.currentMaterialization(fixture.primary.id),
        isNull,
      );
      expect(fixture.reads, isEmpty);

      tester.view.physicalSize = const Size(720, 1200);
      await tester.pump();
      await _openFromDiff(tester);
      expect(_editor(tester).controller!.text, working);
      expect(fixture.reads, [(fixture.additional.id.value, path)]);
      expect(
        fixture.store.runsForSession(fixture.additionalSession.id),
        isEmpty,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'actual Diff opens a tracked punctuated nonprimary path in Source and repeats without another read or pane',
    (tester) async {
      const path = _punctuatedPath;
      const text = 'Additional Environment source content\n';
      await tester.runAsync(() async {
        await fixture.write(path, text);
        await File(
          '${fixture.primaryRoot.path}/$path',
        ).writeAsString('Primary Environment must not be read\n');
        await File(
          '${Directory.fromUri(fixture.project.sourceLocation).path}/$path',
        ).writeAsString('Original Project must not be read\n');
      });
      await mount(tester);
      await _visible(tester, 'Additional Environment source content');
      expect(find.text('$path  [modified]'), findsOneWidget);
      expect(
        fixture.store
            .requireSessionAuthority(fixture.additionalSession.id)
            .environmentId,
        fixture.additional.id,
      );
      expect(fixture.additional.role, EnvironmentRole.additional);
      expect(fixture.additionalRoot.path, isNot(fixture.primaryRoot.path));
      expect(
        fixture.environmentRuntime.currentMaterialization(fixture.primary.id),
        isNull,
      );
      expect(fixture.frontends.generations, hasLength(2));
      expect(
        DisplaySourceFileResolver(fixture.extensions).resolve().id,
        ExtensionId('$_sourcePlugin.main-content'),
      );
      for (final id in [_diffPlugin, _sourcePlugin]) {
        final installation = fixture.backends.catalog!.installations
            .singleWhere((entry) => entry.metadata.id.value == id);
        expect(installation.backendArtifactUri, isNull);
        expect(fixture.backends.backendForInstallation(installation), isNull);
      }
      expect(find.byType(CodeForge), findsNothing);
      expect(fixture.reads, isEmpty);

      // Use ordinary desktop pane widths for Source's existing toolbar. The
      // returned pane must be visible and focused through Main Content.
      tester.view.physicalSize = const Size(720, 1200);
      await tester.pump();
      await _openFromDiff(tester);
      final native = _editor(tester);
      final element = tester.element(find.byType(CodeForge));
      expect(native.controller!.text, text);
      expect(native.readOnly, isFalse);
      expect(fixture.reads, [(fixture.additional.id.value, path)]);
      final bounds = tester.getRect(find.byType(CodeForge));
      final hostBounds = tester.getRect(find.byType(MainContentHost));
      expect(bounds.left, greaterThanOrEqualTo(hostBounds.left));
      expect(bounds.right, lessThanOrEqualTo(hostBounds.right));

      native.focusNode!.unfocus();
      await tester.pump();
      expect(native.focusNode!.hasFocus, isFalse);
      await _openFromDiff(tester);
      expect(find.byType(CodeForge), findsOneWidget);
      expect(tester.element(find.byType(CodeForge)), same(element));
      expect(_editor(tester).controller, same(native.controller));
      expect(_editor(tester).undoController, same(native.undoController));
      expect(native.controller!.text, text);
      expect(fixture.reads, [(fixture.additional.id.value, path)]);
      expect(
        await tester.runAsync(() => fixture.file(path).readAsString()),
        text,
      );
      expect(
        fixture.store.runsForSession(fixture.additionalSession.id),
        isEmpty,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
    skip: !Platform.isLinux,
  );

  testWidgets(
    'actual Diff refuses ambiguous Source providers without reading or choosing one',
    (tester) async {
      const text = 'Actual Source remains explicitly selected\n';
      await tester.runAsync(() => fixture.write('a modified.txt', text));
      await mount(tester);
      await _visible(tester, text.trim());
      final staleOpen = tester.widget<TextButton>(_sourceAction()).onPressed!;
      final competing = fixture.extensions.register(
        point: displaySourceFileContributions,
        id: ExtensionId('test.competing-source'),
        value: DisplaySourceFileContribution(
          display: (_) async =>
              fail('An ambiguous provider must not be invoked.'),
        ),
      );
      addTearDown(competing.close);
      staleOpen();
      await _visible(tester, 'Multiple Source providers are available.');
      expect(_sourceAction(), findsNothing);
      expect(find.byType(CodeForge), findsNothing);
      expect(fixture.reads, isEmpty);
      await competing.close();
      _refresh(tester);
      await _visible(tester, text.trim());
      tester.view.physicalSize = const Size(720, 1200);
      await tester.pump();
      await _openFromDiff(tester);
      expect(_editor(tester).controller!.text, text);
      expect(fixture.reads, [(fixture.additional.id.value, 'a modified.txt')]);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'actual Diff Unapprove preserves and focuses an existing dirty Source document without replacing text or undo',
    (tester) async {
      const path = 'a modified.txt';
      const openedText = 'Source buffer opened before the Diff action\n';
      const changedOnDisk =
          'Newer disk text must not replace the dirty buffer\n';
      await tester.runAsync(() => fixture.write(path, openedText));
      await mount(tester);
      await _visible(tester, 'Source buffer opened before the Diff action');

      // Establish the existing document through Source's normal contributed form,
      // not its implementation or the resolver used by the later Diff action.
      await tester.runAsync(
        () => tester.tap(find.widgetWithText(TextButton, 'Open Source...')),
      );
      await _visible(tester, 'Open Source File');
      await tester.pumpAndSettle();
      expect(fixture.reads, isEmpty);
      await tester.enterText(find.byType(TextField), './$path');
      await tester.pump();
      await tester.tap(find.widgetWithText(TextButton, 'Open'));
      await _visible(tester, 'Source Document opened.');
      await tester.tap(find.byTooltip('Close input'));
      await _waitFor(tester, () => find.byType(Dialog).evaluate().isEmpty);
      final native = _editor(tester);
      final element = tester.element(find.byType(CodeForge));
      expect(native.controller!.text, openedText);
      native.focusNode!.requestFocus();
      await tester.pump();
      await _key(tester, LogicalKeyboardKey.home, control: true);
      await _key(tester, LogicalKeyboardKey.delete);
      expect(native.controller!.text, openedText.substring(1));
      await _visible(tester, 'Possibly modified');

      await tester.runAsync(() => fixture.write(path, changedOnDisk));
      _refresh(tester);
      await _visible(
        tester,
        'Newer disk text must not replace the dirty buffer',
      );
      final unstaged = (await tester.runAsync(fixture.reviewState))!;
      await tester.runAsync(() async {
        await _git(fixture.additionalRoot, ['add', '--', path]);
        expect(
          (await _git(fixture.additionalRoot, [
            'rev-parse',
            ':nested source/$path',
          ])).trim(),
          _blobOid(changedOnDisk),
        );
      });
      await _selectScope(tester, 'Uncommitted changes');
      await _reviewReady(tester, 'Unapprove');
      expect(native.controller!.text, openedText.substring(1));
      expect(_sourceAction(), findsNothing);
      await tester.runAsync(() => tester.tap(_reviewAction('Unapprove')));
      await _visible(tester, 'No staged changes');
      await _reviewReady(tester, 'Approve');
      expect(fixture.indexWrites, hasLength(1));
      expect(await tester.runAsync(fixture.reviewState), unstaged);
      await tester.runAsync(() async {
        final original = await _git(fixture.additionalRoot, [
          'rev-parse',
          'HEAD:nested source/$path',
        ]);
        expect(
          await _git(fixture.additionalRoot, [
            'rev-parse',
            ':nested source/$path',
          ]),
          original,
        );
        expect(
          await _git(fixture.additionalRoot, [
            'cat-file',
            'blob',
            original.trim(),
          ]),
          'context before\nOriginal text\ncontext after\n',
        );
        expect(
          await fixture.file(path).readAsBytes(),
          utf8.encode(changedOnDisk),
        );
      });
      expect(find.byType(CodeForge), findsOneWidget);
      expect(tester.element(find.byType(CodeForge)), same(element));
      expect(_editor(tester).controller, same(native.controller));
      expect(_editor(tester).undoController, same(native.undoController));
      expect(native.controller!.text, openedText.substring(1));
      expect(fixture.reads, [(fixture.additional.id.value, './$path')]);
      native.focusNode!.unfocus();
      await tester.pump();
      await _openFromDiff(tester);
      expect(find.byType(CodeForge), findsOneWidget);
      expect(tester.element(find.byType(CodeForge)), same(element));
      expect(_editor(tester).controller, same(native.controller));
      expect(_editor(tester).undoController, same(native.undoController));
      expect(native.controller!.text, openedText.substring(1));
      expect(fixture.reads, [(fixture.additional.id.value, './$path')]);
      // Diff's ordinary Main Content focus must reach the retained native editor;
      // do not manually focus it before proving that its original undo still works.
      await _key(tester, LogicalKeyboardKey.keyZ, control: true);
      expect(native.controller!.text, openedText);
      expect(
        await tester.runAsync(() => fixture.file(path).readAsString()),
        changedOnDisk,
      );
      expect(
        fixture.store.runsForSession(fixture.additionalSession.id),
        isEmpty,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'navigation during a held actual Source read cannot publish or focus in the new Environment',
    (tester) async {
      const path = 'a modified.txt';
      const additionalText = 'Held additional Environment Source content\n';
      const primaryText = 'New Session primary Environment Source content\n';
      await tester.runAsync(() async {
        await fixture.write(path, additionalText);
        await File(
          '${fixture.primaryRoot.path}/$path',
        ).writeAsString(primaryText);
      });
      await mount(tester);
      await _visible(tester, 'Held additional Environment Source content');
      await _waitFor(tester, () => _sourceAction().evaluate().length == 1);
      fixture.holdNextRead = true;
      final staleOpen = tester.widget<TextButton>(_sourceAction()).onPressed!;
      await tester.tap(_sourceAction());
      await _waitFor(tester, () => fixture.readArrived.isCompleted);
      expect(fixture.reads, [(fixture.additional.id.value, path)]);
      expect(find.byType(CodeForge), findsNothing);

      await fixture.navigate(
        tester,
        fixture.additionalSession,
        fixture.primarySession,
      );
      await _visible(tester, 'New Session primary Environment Source content');
      staleOpen();
      await _openFromDiff(tester);
      final primary = _editor(tester);
      expect(primary.controller!.text, primaryText);
      expect(fixture.reads, [
        (fixture.additional.id.value, path),
        (fixture.primary.id.value, path),
      ]);

      fixture.readRelease.complete();
      await tester.runAsync(fixture.mainContent.drainOperations);
      await tester.pump();
      expect(find.byType(CodeForge), findsOneWidget);
      expect(_editor(tester).controller, same(primary.controller));
      expect(primary.controller!.text, primaryText);
      expect(primary.focusNode!.hasFocus, isTrue);
      expect(find.textContaining('Held additional Environment'), findsNothing);

      await fixture.navigate(
        tester,
        fixture.primarySession,
        fixture.additionalSession,
      );
      await _waitFor(
        tester,
        () => find.byType(CodeForge).evaluate().length == 1,
      );
      expect(_editor(tester).controller, isNot(same(primary.controller)));
      expect(_editor(tester).controller!.text, additionalText);
      expect(fixture.reads, [
        (fixture.additional.id.value, path),
        (fixture.primary.id.value, path),
      ]);
      expect(
        fixture.store.runsForSession(fixture.additionalSession.id),
        isEmpty,
      );
      expect(fixture.store.runsForSession(fixture.primarySession.id), isEmpty);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  for (final absent in [true, false]) {
    testWidgets(
      'stock review ${absent ? 'missing provider' : 'denied frontend grant'} leaves real snapshots readable',
      (tester) async {
        await tester.runAsync(() async {
          await fixture.write(
            'g baseline.txt',
            'Review unavailable committed layer\n',
          );
          await _git(fixture.additionalRoot, ['add', '--', 'g baseline.txt']);
          await _git(fixture.additionalRoot, [
            'commit',
            '-m',
            'Read-only Task layer',
          ]);
          await fixture.write(
            'd staged.txt',
            'Review unavailable staged layer\n',
          );
          await _git(fixture.additionalRoot, ['add', '--', 'd staged.txt']);
          await fixture.write(
            _reviewPath,
            _reviewContent(first: true, second: true),
          );
        });
        final before = (await tester.runAsync(fixture.reviewState))!;
        await mount(
          tester,
          catalog: absent ? installations : approvalDenied,
          approvalPresent: !absent,
        );
        await _visible(tester, '+Selected first change');
        await _visible(tester, 'Review actions unavailable');
        expect(find.textContaining('+Selected second change'), findsOneWidget);
        expect(_reviewAction('Approve'), findsNothing);
        expect(_reviewAction('Unapprove'), findsNothing);
        _refresh(tester);
        await _visible(tester, '+Selected second change');
        await _visible(tester, 'Review actions unavailable');
        for (final scope in ['Uncommitted changes', 'Task / Branch']) {
          await _selectScope(tester, scope);
          await _visible(tester, '+Review unavailable staged layer');
          await _visible(tester, '+Selected first change');
          await _visible(tester, '+Selected second change');
          await _visible(tester, 'Review actions unavailable');
          expect(find.text('Staged changes'), findsOneWidget);
          expect(find.text('Unstaged changes'), findsNWidgets(2));
          expect(find.text('d staged.txt  [modified]'), findsOneWidget);
          expect(find.text('$_reviewPath  [modified]'), findsOneWidget);
          if (scope == 'Task / Branch') {
            await _visible(tester, '+Review unavailable committed layer');
            expect(find.text('Committed changes'), findsOneWidget);
            expect(find.text('g baseline.txt  [modified]'), findsOneWidget);
          } else {
            expect(
              find.textContaining('Review unavailable committed layer'),
              findsNothing,
            );
          }
          expect(_reviewAction('Approve'), findsNothing);
          expect(_reviewAction('Unapprove'), findsNothing);
          expect(fixture.indexWrites, isEmpty);
          expect(await tester.runAsync(fixture.reviewState), before);
        }
        if (absent) {
          tester.view.physicalSize = const Size(720, 1200);
          await tester.pump();
          await _openFromDiff(tester);
          expect(
            _editor(tester).controller!.text,
            _reviewContent(first: true, second: true),
          );
          expect(fixture.reads, [(fixture.additional.id.value, _reviewPath)]);
        }
        expect(fixture.indexWrites, isEmpty);
        expect(await tester.runAsync(fixture.reviewState), before);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
      skip: !Platform.isLinux,
    );
  }

  for (final failure in ['manual staging', 'index lock']) {
    testWidgets(
      'stock $failure rejects stale Approve without retry and requires a truthful refresh',
      (tester) async {
        await tester.runAsync(
          () => fixture.write(
            _reviewPath,
            _reviewContent(first: true, second: true),
          ),
        );
        await mount(tester);
        await _reviewReady(tester, 'Approve', count: 2);
        final stale = tester
            .widget<TextButton>(_reviewAction('Approve').first)
            .onPressed!;
        File? lock;
        await tester.runAsync(() async {
          if (failure == 'manual staging') {
            await _git(fixture.additionalRoot, ['add', '--', _reviewPath]);
          } else {
            final path = (await _git(fixture.additionalRoot, [
              'rev-parse',
              '--path-format=absolute',
              '--git-path',
              'index.lock',
            ])).trim();
            lock = await File(path).create(exclusive: true);
          }
        });
        final before = (await tester.runAsync(fixture.reviewState))!;
        await tester.runAsync(() => tester.tap(_reviewAction('Approve').first));
        await _visible(tester, 'Refresh before trying again');
        expect(_reviewAction('Approve'), findsNothing);
        expect(_reviewAction('Unapprove'), findsNothing);
        expect(find.widgetWithText(TextButton, 'Retry'), findsNothing);
        expect(find.textContaining('index.lock'), findsNothing);
        expect(find.textContaining('stale_selection'), findsNothing);
        expect(find.textContaining(fixture.root.path), findsNothing);
        expect(await tester.runAsync(fixture.reviewState), before);
        final writes = fixture.indexWrites.length;
        final processes = fixture.processes.length;
        expect(writes, failure == 'manual staging' ? 0 : 1);
        stale();
        await tester.pump();
        expect(fixture.processes, hasLength(processes));
        expect(fixture.indexWrites, hasLength(writes));
        expect(await tester.runAsync(fixture.reviewState), before);
        if (lock != null) await tester.runAsync(() => lock!.delete());
        _refresh(tester);
        if (failure == 'manual staging') {
          await _visible(tester, 'No unstaged changes');
          await _selectScope(tester, 'Uncommitted changes');
          await _reviewReady(tester, 'Unapprove', count: 2);
          expect(_reviewAction('Approve'), findsNothing);
        } else {
          await _reviewReady(tester, 'Approve', count: 2);
        }
        expect(
          find.textContaining('Refresh before trying again'),
          findsNothing,
        );
        expect(fixture.indexWrites, hasLength(writes));
        expect(await tester.runAsync(fixture.reviewState), before);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
      skip: !Platform.isLinux,
    );
  }

  testWidgets(
    'stock review retirement before admission fences the captured button without touching the index',
    (tester) async {
      await tester.runAsync(
        () => fixture.write(
          _reviewPath,
          _reviewContent(first: true, second: true),
        ),
      );
      await mount(tester);
      await _reviewReady(tester, 'Approve', count: 2);
      final stale = tester
          .widget<TextButton>(_reviewAction('Approve').first)
          .onPressed!;
      final before = (await tester.runAsync(fixture.reviewState))!;
      final processes = fixture.processes.length;
      await tester.runAsync(
        () => fixture.backends.backends.single.retireProvider(
          fixture.capabilities.resolve(reviewApprovalCapability),
        ),
      );
      stale();
      await _visible(tester, 'Refresh before trying again');
      expect(fixture.processes, hasLength(processes));
      expect(fixture.indexWrites, isEmpty);
      expect(await tester.runAsync(fixture.reviewState), before);
      _refresh(tester);
      await _visible(tester, '+Selected first change');
      await _visible(tester, 'Review actions unavailable');
      expect(_reviewAction('Approve'), findsNothing);
      expect(await tester.runAsync(fixture.reviewState), before);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
    skip: !Platform.isLinux,
  );

  testWidgets(
    'stock review retirement after real index effect suppresses success without rollback or retry',
    (tester) async {
      await tester.runAsync(
        () => fixture.write(
          _reviewPath,
          _reviewContent(first: true, second: true),
        ),
      );
      final before = (await tester.runAsync(fixture.reviewState))!;
      await mount(tester);
      await _reviewReady(tester, 'Approve', count: 2);
      final stale = tester
          .widget<TextButton>(_reviewAction('Approve').first)
          .onPressed!;
      fixture.holdNextIndexWrite = true;
      await tester.runAsync(() => tester.tap(_reviewAction('Approve').first));
      await _waitFor(tester, () => fixture.processArrived.isCompleted);
      await tester.runAsync(
        () => fixture.expectReviewIndex(before, first: true),
      );
      final effected = (await tester.runAsync(fixture.reviewState))!;
      final processes = fixture.processes.length;
      expect(fixture.indexWrites, hasLength(1));
      expect(_reviewAction('Approve'), findsNothing);
      await tester.runAsync(
        () => fixture.backends.backends.single.retireProvider(
          fixture.capabilities.resolve(reviewApprovalCapability),
        ),
      );
      await tester.runAsync(fixture.releaseGate);
      await _visible(tester, 'Refresh before trying again');
      stale();
      await tester.pump();
      expect(fixture.processes, hasLength(processes));
      expect(fixture.indexWrites, hasLength(1));
      expect(await tester.runAsync(fixture.reviewState), effected);
      expect(find.textContaining('Approved'), findsNothing);
      _refresh(tester);
      await _visible(tester, '+Selected second change');
      await _visible(tester, 'Review actions unavailable');
      expect(find.textContaining('+Selected first change'), findsNothing);
      await _selectScope(tester, 'Uncommitted changes');
      await _visible(tester, '+Selected first change');
      await _visible(tester, 'Review actions unavailable');
      expect(find.textContaining('+Selected second change'), findsOneWidget);
      expect(_reviewAction('Unapprove'), findsNothing);
      expect(await tester.runAsync(fixture.reviewState), effected);
      expect(fixture.indexWrites, hasLength(1));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
    skip: !Platform.isLinux,
  );

  testWidgets(
    'stock captured Approve control stays retired while fresh same-ID replacement access works',
    (tester) async {
      await tester.runAsync(
        () => fixture.write(
          _reviewPath,
          _reviewContent(first: true, second: true),
        ),
      );
      await mount(tester);
      await _reviewReady(tester, 'Approve', count: 2);
      final stale = tester
          .widget<TextButton>(_reviewAction('Approve').first)
          .onPressed!;
      final old = fixture.capabilities.resolve(reviewApprovalCapability);
      final before = (await tester.runAsync(fixture.reviewState))!;
      final processes = fixture.processes.length;
      await tester.runAsync(fixture.backends.close);
      final replacement = ApplicationPluginBootstrap(
        fixture.capabilities,
        ExtensionRegistry(),
        createInfrastructureServices: (connection) =>
            projectStorageServices(fixture.lifecycle, connection),
      );
      try {
        await tester.runAsync(
          () => replacement.start(
            installationRoot: installations.path,
            dartaotruntimeExecutable: aotRuntime,
            hostArtifactPath: host.path,
            startupArguments: const {},
          ),
        );
        expect(replacement.backends.single.state, InstalledBackendState.active);
        final current = fixture.capabilities.resolve(reviewApprovalCapability);
        expect(current.provider.id, old.provider.id);
        expect(current.isSameRegistration(old), isFalse);
        expect(() => old.requestChannel, throwsA(isA<ProviderUnavailable>()));
        replacement.backends.single.validateProviderOwnership(current);
        stale();
        await _visible(tester, 'Refresh before trying again');
        stale();
        await tester.pump();
        expect(fixture.processes, hasLength(processes));
        expect(fixture.indexWrites, isEmpty);
        expect(await tester.runAsync(fixture.reviewState), before);
        expect(_reviewAction('Approve'), findsNothing);
        // The old pane retains its closed bootstrap. This is real retirement and
        // fresh-access recovery; the isolated compiled frontend suite separately
        // tests live same-ID handle retargeting with an otherwise usable host.
        await tester.runAsync(() async {
          final captured = CapturedEnvironmentCapabilities(
            environmentRuntime: fixture.environmentRuntime,
            backends: replacement,
            session: fixture.additionalSession,
          );
          final source = await captured.resolve(_changes);
          expect(source.environment.id, fixture.additional.id);
          final snapshot = await invokeEnvironmentCapabilityWithBufferedProcess(
            selection: source,
            backends: replacement,
            serviceId: changeSetSourceServiceId,
            invoke: (channel) =>
                ChangeSetSourceServiceClient(channel).snapshotUnstaged(),
          );
          final file = snapshot.files.singleWhere(
            (file) => file.relativePath == _reviewPath,
          );
          expect(file.hunks, hasLength(2));
          expect(file.reviewRevision, isNotNull);
          final approval = await captured.resolve(reviewApprovalCapability);
          expect(approval.binding.isSameRegistration(current), isTrue);
          expect(approval.environment.id, fixture.additional.id);
          await invokeEnvironmentCapabilityWithBufferedProcess(
            selection: approval,
            backends: replacement,
            serviceId: reviewApprovalHandlerServiceId,
            invoke: (channel) =>
                ReviewApprovalHandlerServiceClient(channel).approveHunk(
                  ReviewHunkSelection(
                    relativePath: _reviewPath,
                    hunkIndex: 0,
                    expectedRevision: file.reviewRevision!,
                  ),
                ),
          );
          await fixture.expectReviewIndex(before, first: true);
          expect(fixture.indexWrites, hasLength(1));
          for (final process in fixture.processes.skip(processes)) {
            expect(process['environmentId'], fixture.additional.id.value);
          }
          expect(
            fixture.environmentRuntime.currentMaterialization(
              fixture.primary.id,
            ),
            isNull,
          );
        });
        final effected = (await tester.runAsync(fixture.reviewState))!;
        final replacementProcesses = fixture.processes.length;
        stale();
        await tester.pump();
        expect(fixture.processes, hasLength(replacementProcesses));
        expect(fixture.indexWrites, hasLength(1));
        expect(await tester.runAsync(fixture.reviewState), effected);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      } finally {
        await tester.runAsync(replacement.close);
      }
    },
    skip: !Platform.isLinux,
  );

  testWidgets(
    'stock generated review client rejects another Session revision on the same Environment',
    (tester) async {
      await tester.runAsync(() async {
        await fixture.write(
          _reviewPath,
          _reviewContent(first: true, second: true),
        );
        await fixture.start(installations);
        final before = await fixture.reviewState();
        final sibling = fixture.store.session(
          SessionId('additional-peer-session'),
        )!;
        Future<EnvironmentCapabilitySelection> select(
          Session session,
          CapabilityKey key,
        ) => CapturedEnvironmentCapabilities(
          environmentRuntime: fixture.environmentRuntime,
          backends: fixture.backends,
          session: session,
        ).resolve(key);
        Future<ChangedFile> snapshot(Session session) async {
          final selection = await select(session, _changes);
          return (await invokeEnvironmentCapabilityWithBufferedProcess(
            selection: selection,
            backends: fixture.backends,
            serviceId: changeSetSourceServiceId,
            invoke: (channel) =>
                ChangeSetSourceServiceClient(channel).snapshotUnstaged(),
          )).files.singleWhere((file) => file.relativePath == _reviewPath);
        }

        final original = await snapshot(fixture.additionalSession);
        final other = await snapshot(sibling);
        expect(original.reviewRevision, isNotNull);
        expect(other.reviewRevision, isNot(original.reviewRevision));
        final approval = await select(sibling, reviewApprovalCapability);
        expect(approval.environment.id, fixture.additional.id);
        await expectLater(
          invokeEnvironmentCapabilityWithBufferedProcess(
            selection: approval,
            backends: fixture.backends,
            serviceId: reviewApprovalHandlerServiceId,
            invoke: (channel) =>
                ReviewApprovalHandlerServiceClient(channel).approveHunk(
                  ReviewHunkSelection(
                    relativePath: _reviewPath,
                    hunkIndex: 0,
                    expectedRevision: original.reviewRevision!,
                  ),
                ),
          ),
          throwsA(
            isA<ReviewApprovalFailure>().having(
              (error) => error.code,
              'code',
              'stale_selection',
            ),
          ),
        );
        expect(fixture.indexWrites, isEmpty);
        expect(await fixture.reviewState(), before);
        await invokeEnvironmentCapabilityWithBufferedProcess(
          selection: approval,
          backends: fixture.backends,
          serviceId: reviewApprovalHandlerServiceId,
          invoke: (channel) =>
              ReviewApprovalHandlerServiceClient(channel).approveHunk(
                ReviewHunkSelection(
                  relativePath: _reviewPath,
                  hunkIndex: 0,
                  expectedRevision: other.reviewRevision!,
                ),
              ),
        );
        await fixture.expectReviewIndex(before, first: true);
        expect(fixture.indexWrites, hasLength(1));
      });
      expect(tester.takeException(), isNull);
    },
    skip: !Platform.isLinux,
  );

  for (final (scope, clean) in _scopes) {
    testWidgets(
      '$scope clean Environment is distinct from unavailable and Git failure',
      (tester) async {
        await mount(tester);
        await _visible(tester, 'No unstaged changes');
        if (scope != 'Unstaged changes') {
          await _selectScope(tester, scope);
        }
        await _visible(tester, clean);
        final marker = File('${fixture.additionalWorktree.path}/.git');
        final markerText = (await tester.runAsync(marker.readAsString))!;
        for (final damage in [
          'corrupt marker',
          'missing marker',
          'foreign marker',
          'nested repository',
        ]) {
          await tester.runAsync(() async {
            switch (damage) {
              case 'corrupt marker':
                await marker.writeAsString('invalid gitfile\n');
              case 'missing marker':
                // The linked checkout is under the original source repository.
                // Its ancestor must not become replacement inspection authority.
                await marker.delete();
              case 'foreign marker':
                await marker.writeAsString(
                  await File(
                    '${fixture.worktree(fixture.primary).path}/.git',
                  ).readAsString(),
                );
              case 'nested repository':
                await _git(fixture.additionalRoot, ['init']);
            }
          });
          _refresh(tester);
          await _visible(tester, 'Unable to load');
          expect(find.textContaining(clean), findsNothing, reason: damage);
          await tester.runAsync(() async {
            if (damage == 'nested repository') {
              await Directory(
                '${fixture.additionalRoot.path}/.git',
              ).delete(recursive: true);
            } else {
              await marker.writeAsString(markerText);
            }
          });
          await tester.runAsync(
            () => tester.tap(find.widgetWithText(TextButton, 'Retry')),
          );
          await _visible(tester, clean);
        }
        await tester.runAsync(
          () => fixture.backends.backends.single.retireProvider(
            fixture.capabilities.resolve(_changes),
          ),
        );
        _refresh(tester);
        await _visible(tester, 'unavailable');
        expect(find.textContaining(clean), findsNothing);
        expect(
          fixture.capabilities.providersFor(environmentProviderCapability),
          hasLength(1),
        );
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
      skip: !Platform.isLinux,
    );
  }

  testWidgets(
    'frontend-only installation retains Diff when change source is absent',
    (tester) async {
      await mount(tester, catalog: frontendOnly);
      await _visible(tester, 'unavailable');
      expect(find.text('Diff'), findsOneWidget);
      expect(find.textContaining('No unstaged changes'), findsNothing);
      expect(fixture.backends.backends, isEmpty);
      _refresh(tester);
      await _visible(tester, 'unavailable');
      expect(fixture.backends.backends, isEmpty);
      for (final (scope, clean) in _scopes.skip(1)) {
        await _selectScope(tester, scope);
        await _visible(tester, 'unavailable');
        expect(find.textContaining(clean), findsNothing);
      }
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  for (final (scope, clean) in _scopes) {
    for (final departure in ['navigation', 'provider retirement']) {
      testWidgets(
        '$departure fences a pending actual Git $scope snapshot',
        (tester) async {
          await mount(tester);
          await _visible(tester, 'No unstaged changes');
          if (scope != 'Unstaged changes') {
            await _selectScope(tester, scope);
            await _visible(tester, clean);
          }
          expect(
            fixture.environmentRuntime.currentMaterialization(
              fixture.additional.id,
            ),
            isNotNull,
          );
          await tester.runAsync(() async {
            await fixture.write(
              'a modified.txt',
              'Old Session pending content\n',
            );
            if (scope == 'Task / Branch') {
              await _git(fixture.additionalRoot, ['add', 'a modified.txt']);
              await _git(fixture.additionalRoot, [
                'commit',
                '-m',
                'Pending Task snapshot commit',
              ]);
            }
            fixture.holdNextProcess = true;
          });
          final staleRefresh = _refreshCallback(tester);
          _refresh(tester);
          // This checkpoint is reached inside Git's actual snapshot operation, after
          // canonical materialization, contextual admission, and authority lookup.
          await _waitFor(tester, () => fixture.processArrived.isCompleted);
          final admitted = fixture.processes
              .where(
                (request) =>
                    request['environmentId'] == fixture.additional.id.value,
              )
              .length;
          if (departure == 'navigation') {
            await fixture.navigate(
              tester,
              fixture.additionalSession,
              fixture.primarySession,
            );
          } else {
            await tester.runAsync(
              () => fixture.backends.backends.single.retireProvider(
                fixture.capabilities.resolve(_changes),
              ),
            );
          }
          await tester.runAsync(fixture.releaseGate);
          if (departure == 'navigation') {
            await _visible(tester, 'No unstaged changes');
            staleRefresh();
          } else {
            await _visible(tester, 'Unable to load');
            _refresh(tester);
            await _visible(tester, 'unavailable');
            final materialized = fixture.environmentRuntime
                .currentMaterialization(fixture.additional.id)!;
            final read = await tester.runAsync(
              () => materialized.provider.readFile(
                fixture.additional.id,
                'a modified.txt',
              ),
            );
            expect(read!.text, 'Old Session pending content\n');
          }
          await tester.pumpAndSettle();
          expect(
            find.textContaining('Old Session pending content'),
            findsNothing,
          );
          expect(
            fixture.processes.where(
              (request) =>
                  request['environmentId'] == fixture.additional.id.value,
            ),
            hasLength(admitted),
            reason:
                'Departure cannot admit another command for the old snapshot.',
          );
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox.shrink());
        },
        skip: !Platform.isLinux,
      );
    }
  }
}

final class _Fixture {
  _Fixture(
    this.root,
    this.launcher,
    this.host,
    this.project,
    this.task,
    this.primary,
    this.additional,
  ) {
    lifecycle = ProductLifecycleCoordinator(
      store: store,
      registry: capabilities,
      extensions: extensions,
      ids: MonotonicProductIdSource(),
      providerForBinding: (binding) => GeneratedEnvironmentProvider(
        providerId: binding.provider.id,
        service: EnvironmentProviderServiceClient(
          _EnvironmentChannel(binding.requestChannel, this),
        ),
      ),
    );
    environmentRuntime = lifecycle.environmentRuntime;
    backends = ApplicationPluginBootstrap(
      capabilities,
      extensions,
      createInfrastructureServices: (connection) =>
          projectStorageServices(lifecycle, connection),
    );
    mainContent = PreparedMainContentHost(
      environmentRuntime: environmentRuntime,
    );
    frontends = ApplicationFrontendBootstrap(
      extensions: extensions,
      backends: backends,
      mainContentHost: mainContent,
      loadSettings: (catalog) => PreparedSettingsSnapshot.load(
        catalog,
        roots: PlatformStorageRoots(
          operatingSystem: Platform.operatingSystem,
          configurationRoot: '${root.path}/config',
          localStateRoot: '${root.path}/state',
          localDataRoot: '${root.path}/data',
          cacheRoot: '${root.path}/cache',
        ),
      ),
    );
  }

  static Future<_Fixture> create({
    required Directory installations,
    required File host,
    required String aotRuntime,
  }) async {
    final root = await Directory.systemTemp.createTemp('adele-diff-case-');
    final repository = await Directory('${root.path}/repository').create();
    final source = await Directory('${repository.path}/nested source').create();
    for (final entry in {
      'a modified.txt': 'context before\nOriginal text\ncontext after\n',
      _reviewPath: _reviewContent(),
      if (Platform.isLinux) _punctuatedPath: 'Tracked source baseline\n',
      'c deleted.txt': 'Deleted baseline\n',
      'd staged.txt': 'Staged baseline\n',
      'e reversal.txt': 'Original layer\n',
      'g baseline.txt': 'Primary establishment baseline\n',
      '.gitignore': '*.tmp\n',
    }.entries) {
      await File('${source.path}/${entry.key}').writeAsString(entry.value);
    }
    await File(
      '${repository.path}/outside.txt',
    ).writeAsString('Outside baseline\n');
    await _git(repository, [
      'init',
      '--object-format=sha1',
      '--initial-branch=main',
    ]);
    await _git(repository, ['add', '.']);
    await _git(repository, ['commit', '-m', 'Diff integration baseline']);
    final capabilities = CapabilityRegistry();
    final extensions = ExtensionRegistry();
    late ApplicationPluginBootstrap backends;
    final lifecycle = ProductLifecycleCoordinator.generated(
      store: InMemoryProductStore(),
      registry: capabilities,
      extensions: extensions,
      captureEstablishmentOwner: (binding) {
        final owner = backends.backendForProvider(binding)!;
        return EnvironmentEstablishmentOwner(
          pluginId: PluginId(owner.connection!.pluginId),
          validate: () => owner.validateProviderOwnership(binding),
        );
      },
    );
    backends = ApplicationPluginBootstrap(
      capabilities,
      extensions,
      createInfrastructureServices: (connection) =>
          projectStorageServices(lifecycle, connection),
    );
    final projectProvider = _projectProvider(capabilities);
    late Project project;
    late TaskCreationResult created;
    late Environment additional;
    try {
      await backends.start(
        installationRoot: installations.path,
        dartaotruntimeExecutable: aotRuntime,
        hostArtifactPath: host.path,
        startupArguments: const {},
      );
      expect(
        backends.backends.single.state,
        InstalledBackendState.active,
        reason: '${backends.backends.single.failure}',
      );
      project = await lifecycle.openProject(
        sourceLocation: source.uri,
        provider: lifecycle.resolveProjectProvider(projectProvider.providerId),
      );
      created = await lifecycle.createTask(
        projectId: project.id,
        title: 'Real Diff Task',
      );
      // Establish the nonprimary Environment from a genuinely newer source
      // commit. Both the lifecycle state and actual returned SQL plan are retained.
      await File(
        '${source.path}/g baseline.txt',
      ).writeAsString('Additional establishment baseline\n');
      await _git(source, ['add', 'g baseline.txt']);
      await _git(source, ['commit', '-m', 'Additional Environment baseline']);
      final binding = capabilities.resolve(environmentProviderCapability);
      final owner = backends.backendForProvider(binding)!;
      owner.validateProviderOwnership(binding);
      final provider = GeneratedEnvironmentProvider(
        providerId: binding.provider.id,
        service: EnvironmentProviderServiceClient(binding.requestChannel),
      );
      final value = Environment(
        id: EnvironmentId('additional-diff'),
        taskId: created.task.id,
        role: EnvironmentRole.additional,
        providerId: binding.provider.id,
        providerState: null,
      );
      final established = await provider.establish(
        LocalEnvironment(project: project, task: created.task, value: value),
      );
      additional = Environment(
        id: value.id,
        taskId: value.taskId,
        role: value.role,
        providerId: value.providerId,
        providerState: established.providerState,
      );
      final database = lifecycle.databaseForEnvironment(
        created.environment.id,
      )!;
      final initial = established.initialState!;
      owner.validateProviderOwnership(binding);
      if (initial.schema case final schema?) {
        database.ensurePluginSchema(owner.connection!.pluginId, [
          schema,
        ], definitionsOnly: true);
      }
      // Additional creation has no public lifecycle API. Trusted fixture setup
      // retains its core row and the provider's required inserts in one commit.
      database.executePluginTransaction([
        RelationalStatement(
          sql:
              'INSERT INTO adele_product_environments '
              '(id, task_id, role, provider_id, provider_state_json) '
              'VALUES (:id, :task, :role, :provider, :state)',
          parameters: {
            ':id': additional.id.value,
            ':task': additional.taskId.value,
            ':role': additional.role.name,
            ':provider': additional.providerId.value,
            ':state': jsonEncode(additional.providerState),
          },
          expectedRows: 1,
        ),
        for (final insert in initial.inserts) insert.toRelationalStatement(),
      ]);
      expect(database.loadProductGraph().sessions, isEmpty);
      expect(
        database.queryPluginRows(
          'SELECT environment_id FROM adele_git_task_anchors',
          const {},
        ),
        hasLength(2),
      );
      for (final (id, environment) in [
        ('additional-session', additional),
        ('additional-peer-session', additional),
        ('primary-session', created.environment),
      ]) {
        expect(environment.providerState!['schemaVersion'], 2);
        expect(environment.providerState, isNot(contains('baselineCommit')));
        database.insertSessionWithAuthority(
          Session(
            id: SessionId(id),
            taskId: created.task.id,
            strategyId: OrchestrationStrategyId('test.uninstalled-strategy'),
          ),
          environment.id,
        );
      }
    } finally {
      await backends.close();
      await lifecycle.close();
      await projectProvider.close();
    }
    final fixture = _Fixture(
      root,
      aotRuntime,
      host,
      project,
      created.task,
      created.environment,
      additional,
    );
    final reopenedProvider = _projectProvider(fixture.capabilities);
    try {
      final reopened = await fixture.lifecycle.openProject(
        sourceLocation: source.uri,
        provider: fixture.lifecycle.resolveProjectProvider(
          reopenedProvider.providerId,
        ),
      );
      expect(reopened.id, project.id);
      fixture.additionalSession = fixture.store.session(
        SessionId('additional-session'),
      )!;
      fixture.primarySession = fixture.store.session(
        SessionId('primary-session'),
      )!;
      expect(
        fixture.baseline(additional),
        isNot(fixture.baseline(created.environment)),
      );
      for (final environment in [created.environment, additional]) {
        expect(
          fixture.environmentRuntime.currentMaterialization(environment.id),
          isNull,
        );
      }
    } finally {
      await reopenedProvider.close();
    }
    return fixture;
  }

  final Directory root;
  final String launcher;
  final File host;
  final Project project;
  final Task task;
  final Environment primary;
  final Environment additional;
  final capabilities = CapabilityRegistry();
  final extensions = ExtensionRegistry();
  final store = InMemoryProductStore();
  late final ProductLifecycleCoordinator lifecycle;
  late final Session additionalSession;
  late final Session primarySession;
  late final EnvironmentRuntime environmentRuntime;
  late final ApplicationPluginBootstrap backends;
  late final PreparedMainContentHost mainContent;
  late final ApplicationFrontendBootstrap frontends;
  final reads = <(String, String)>[];
  bool holdNextRead = false;
  final readArrived = Completer<void>();
  final readRelease = Completer<void>();
  bool holdNextProcess = false;
  bool holdNextIndexWrite = false;
  final processArrived = Completer<void>();
  final processRelease = Completer<void>();
  final processes = <Map<String, Object?>>[];

  List<Map<String, Object?>> get indexWrites =>
      processes.where(_isIndexWrite).toList();

  Future<Map<String, Map<String, Object?>>> reviewState() async {
    final result = <String, Map<String, Object?>>{};
    for (final environment in [additional, primary]) {
      final root = worktree(environment);
      final workingBytes = <String, String>{};
      final workingHashes = <String, String>{};
      await for (final entry in root.list(
        recursive: true,
        followLinks: false,
      )) {
        final path = entry.path.substring(root.path.length + 1);
        if (path == '.git' || path.startsWith('.git/') || entry is! File) {
          continue;
        }
        final bytes = await entry.readAsBytes();
        workingBytes[path] = base64Encode(bytes);
        workingHashes[path] = sha256.convert(bytes).toString();
      }
      result[environment.id.value] = {
        'head': await _git(root, ['rev-parse', 'HEAD']),
        'branch': await _git(root, ['symbolic-ref', 'HEAD']),
        'baseline': baseline(environment),
        'providerState': environment.providerState,
        'index': await _git(root, ['ls-files', '--stage', '-z']),
        'workingBytes': workingBytes,
        'workingHashes': workingHashes,
      };
    }
    return result;
  }

  Future<void> expectReviewIndex(
    Map<String, Map<String, Object?>> before, {
    bool first = false,
  }) async {
    final content = _reviewContent(first: first);
    final original = _blobOid(_reviewContent());
    final expected = _blobOid(content);
    final suffix = ' 0\tnested source/$_reviewPath\u0000';
    final index = before[additional.id.value]!['index']! as String;
    expect(index, contains('$original$suffix'));
    expect(await reviewState(), {
      ...before,
      additional.id.value: {
        ...before[additional.id.value]!,
        'index': index.replaceFirst('$original$suffix', '$expected$suffix'),
      },
    });
    expect(await _git(additionalRoot, ['cat-file', 'blob', expected]), content);
    expect(
      (await _git(additionalRoot, [
        'rev-parse',
        ':nested source/$_reviewPath',
      ])).trim(),
      expected,
    );
  }

  String baseline(Environment environment) =>
      lifecycle
              .databaseForEnvironment(environment.id)!
              .queryPluginRows(
                'SELECT baseline_commit FROM adele_git_task_anchors WHERE environment_id=:id',
                {':id': environment.id.value},
              )
              .single
              .values['baseline_commit']!
          as String;

  Directory worktree(Environment environment) => Directory.fromUri(
    project.sourceLocation.resolve(
      '${environment.providerState!['worktreeRelativePath']}/',
    ),
  );
  Directory sourceRoot(Environment environment) => Directory(
    '${worktree(environment).path}/${environment.providerState!['sourceRelativePath']}',
  );
  Directory get additionalWorktree => worktree(additional);
  Directory get additionalRoot => sourceRoot(additional);
  Directory get primaryRoot => sourceRoot(primary);
  File file(String path) => File('${additionalRoot.path}/$path');
  Future<void> write(String path, String text) async =>
      file(path).writeAsString(text);
  Future<List<String>> fingerprint() async => [
    await _git(additionalWorktree, ['status', '--porcelain=v1', '-z']),
    await _git(additionalWorktree, ['diff', '--cached', '--binary']),
    await _git(additionalWorktree, ['diff', '--binary']),
    await _git(additionalWorktree, ['rev-parse', 'HEAD']),
    await file('b new + [file].txt').readAsString(),
  ];

  Future<void> start(Directory catalog) async {
    await backends.start(
      installationRoot: catalog.path,
      dartaotruntimeExecutable: launcher,
      hostArtifactPath: host.path,
      startupArguments: const {},
    );
    expect(backends.state, ApplicationPluginState.ready);
    expect(backends.failure, isNull);
    expect(backends.catalog!.issues, isEmpty);
    for (final backend in backends.backends) {
      expect(
        backend.state,
        InstalledBackendState.active,
        reason: '${backend.failure}',
      );
    }
    await frontends.start(backends.catalog!);
    for (final generation in frontends.generations) {
      expect(
        generation.state,
        InstalledFrontendState.active,
        reason: '${generation.failure}',
      );
    }
  }

  Widget widget(Session session) => MaterialApp(
    home: Scaffold(
      body: MainContentHost(
        session: session,
        extensions: extensions,
        actionCoordinator: mainContent.actionCoordinator,
      ),
    ),
  );

  Future<void> navigate(
    WidgetTester tester,
    Session previous,
    Session next,
  ) async {
    await tester.runAsync(() => frontends.prepareToDeactivate(previous));
    frontends.unbind(previous);
    await tester.runAsync(() => tester.pumpWidget(widget(next)));
    await tester.pump();
  }

  Future<void> releaseGate() async {
    if (!processRelease.isCompleted) processRelease.complete();
  }

  Future<void> close() async {
    if (!readRelease.isCompleted) readRelease.complete();
    await releaseGate();
    await frontends.close();
    await backends.close();
    await lifecycle.close();
    await root.delete(recursive: true);
  }
}

final class _EnvironmentChannel implements AdeleRequestChannel {
  const _EnvironmentChannel(this.delegate, this.fixture);

  final AdeleRequestChannel delegate;
  final _Fixture fixture;

  @override
  Future<Object?> request(String method, Map<String, Object?> payload) async {
    if (method == environmentProviderServiceRunBufferedProcessId) {
      fixture.processes.add(Map.of(payload));
      final indexWrite = fixture.holdNextIndexWrite && _isIndexWrite(payload);
      final held = fixture.holdNextProcess || indexWrite;
      fixture.holdNextProcess = false;
      if (indexWrite) fixture.holdNextIndexWrite = false;
      final result = await delegate.request(method, payload);
      if (held) {
        // Real stock Git executed the command. Gate only its unchanged response.
        fixture.processArrived.complete();
        await fixture.processRelease.future;
      }
      return result;
    }
    if (method != environmentProviderServiceReadFileId) {
      return delegate.request(method, payload);
    }
    fixture.reads.add((
      payload['environmentId']! as String,
      payload['relativePath']! as String,
    ));
    final held = fixture.holdNextRead;
    fixture.holdNextRead = false;
    final result = await delegate.request(method, payload);
    if (held) {
      // The real Git AOT read has completed. Hold only delivery of its unchanged
      // response to Source, not a fabricated provider result or a timed delay.
      fixture.readArrived.complete();
      await fixture.readRelease.future;
    }
    return result;
  }
}

Future<void> _manifest(
  Directory directory,
  String id,
  Map<String, Object?> components,
) async {
  await File('${directory.path}/adele_plugin.installation.json').writeAsString(
    jsonEncode({
      'manifestVersion': 1,
      'metadata': {'id': id, 'version': '1.0.0', 'displayName': id},
      'components': components,
    }),
  );
}

Future<String> _git(Directory directory, List<String> arguments) async {
  final result = await Process.run(
    'git',
    arguments,
    workingDirectory: directory.path,
    environment: {
      for (final entry in Platform.environment.entries)
        if (!entry.key.toUpperCase().startsWith('GIT_')) entry.key: entry.value,
      'GIT_CONFIG_NOSYSTEM': '1',
      'GIT_CONFIG_GLOBAL': '/dev/null',
      'GIT_AUTHOR_NAME': 'ADELE Test',
      'GIT_AUTHOR_EMAIL': 'test@example.invalid',
      'GIT_COMMITTER_NAME': 'ADELE Test',
      'GIT_COMMITTER_EMAIL': 'test@example.invalid',
      'GIT_TERMINAL_PROMPT': '0',
      'GIT_OPTIONAL_LOCKS': '0',
    },
    includeParentEnvironment: false,
  );
  expect(result.exitCode, 0, reason: '${result.stderr}');
  return result.stdout as String;
}

VoidCallback _refreshCallback(WidgetTester tester) => tester
    .widget<TextButton>(find.widgetWithText(TextButton, 'Refresh'))
    .onPressed!;
void _refresh(WidgetTester tester) => _refreshCallback(tester)();

String _reviewContent({bool first = false, bool second = false}) =>
    '${List.generate(30, (index) {
      if (index == 3 && first) return 'Selected first change';
      if (index == 24 && second) return 'Selected second change';
      return 'Selected line $index';
    }).join('\n')}\n';

String _blobOid(String content) {
  final bytes = utf8.encode(content);
  return sha1.convert([
    ...utf8.encode('blob ${bytes.length}\u0000'),
    ...bytes,
  ]).toString();
}

bool _isIndexWrite(Map<String, Object?> payload) {
  final arguments = (payload['request']! as Map)['arguments']! as List;
  return arguments.contains('apply') &&
      arguments.contains('--cached') &&
      !arguments.contains('--check');
}

Finder _reviewAction(String label) => find.widgetWithText(TextButton, label);

Future<void> _reviewReady(WidgetTester tester, String label, {int count = 1}) =>
    _waitFor(tester, () => _reviewAction(label).evaluate().length == count);

Future<void> _selectScope(WidgetTester tester, String scope) async {
  await tester.runAsync(
    () => tester.tap(find.widgetWithText(TextButton, scope)),
  );
  await tester.pump();
}

Finder _sourceAction() => find.widgetWithText(TextButton, 'Open in Source');

CodeForge _editor(WidgetTester tester) =>
    tester.widget<CodeForge>(find.byType(CodeForge));

Future<void> _openFromDiff(WidgetTester tester) async {
  bool enabled() =>
      _sourceAction().evaluate().length == 1 &&
      tester.widget<TextButton>(_sourceAction()).onPressed != null;
  await _waitFor(tester, enabled);
  await tester.ensureVisible(_sourceAction());
  await tester.pump();
  await tester.runAsync(() => tester.tap(_sourceAction()));
  await _waitFor(
    tester,
    () =>
        find.byType(CodeForge).evaluate().length == 1 &&
        _editor(tester).focusNode!.hasFocus,
  );
  await _waitFor(tester, enabled);
}

Future<void> _key(
  WidgetTester tester,
  LogicalKeyboardKey key, {
  bool control = false,
}) async {
  if (control) await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
  try {
    await tester.sendKeyEvent(key);
  } finally {
    if (control) await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
  }
  await tester.pump();
}

Future<void> _visible(WidgetTester tester, String text) async {
  await _waitFor(tester, () => find.textContaining(text).evaluate().isNotEmpty);
  expect(find.textContaining(text), findsWidgets);
}

Future<void> _waitFor(WidgetTester tester, bool Function() complete) async {
  await tester.runAsync(() async {
    final deadline = DateTime.now().add(_bound);
    while (!complete() && DateTime.now().isBefore(deadline)) {
      await Future<void>(() {});
      await tester.pump();
    }
  });
  expect(
    complete(),
    isTrue,
    reason: 'Timed out waiting for actual AOT/EVC checkpoint.',
  );
}

TestProjectProvider _projectProvider(CapabilityRegistry registry) =>
    TestProjectProvider(
      registry,
      prepare: (source) async => ProjectBacking(
        sourceLocation: source,
        databaseRelativePath: '.adele/data.db',
      ),
    );

String _dartExecutable() {
  var directory = File(Platform.resolvedExecutable).parent;
  while (directory.parent.path != directory.path) {
    final executable = File('${directory.path}/dart-sdk/bin/dart');
    if (executable.existsSync()) return executable.path;
    directory = directory.parent;
  }
  throw StateError('Cannot locate the running Flutter toolchain Dart SDK.');
}
