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
  late File host;
  late String aotRuntime;

  setUpAll(() async {
    artifacts = await Directory.systemTemp.createTemp('adele-diff-artifacts-');
    installations = await Directory('${artifacts.path}/installed').create();
    frontendOnly = await Directory('${artifacts.path}/frontend-only').create();
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

  Future<void> mount(WidgetTester tester, {Directory? catalog}) async {
    tester.view.physicalSize = const Size(1600, 2000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.runAsync(() => fixture.start(catalog ?? installations));
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
    'actual Diff focuses an existing dirty Source document without replacing text or undo',
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
    await _git(repository, ['init', '--initial-branch=main']);
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
  final processArrived = Completer<void>();
  final processRelease = Completer<void>();
  final processes = <Map<String, Object?>>[];

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
      final held = fixture.holdNextProcess;
      fixture.holdNextProcess = false;
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
