import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

// ignore: avoid_relative_lib_imports
import '../../packages/plugin_runtime/lib/plugin_runtime.dart';
import 'support/desktop_launcher_fixture.dart';
import 'support/desktop_launcher_inputs.dart';

void main() {
  late DesktopLauncherFixture fixture;
  setUp(() async {
    fixture = await DesktopLauncherFixture.create();
  });

  for (final damage in ['missing', 'empty', 'corrupt']) {
    test(
      '$damage cached component is repaired in a new retained entry',
      () async {
        await fixture.prepare();
        final old = fixture.componentArtifact('git-compilation');
        if (damage == 'missing') {
          old.deleteSync();
        } else {
          old.writeAsStringSync(
            damage == 'empty' ? '' : 'corrupt cached bytes',
          );
        }
        final retained = fixture.retainedFiles();
        await fixture.prepare();
        expect(fixture.compilations(), [gitEntrypoint]);
        final replacements = fixture.publishedFiles().where(
          (file) =>
              file.path.contains('/components/git-compilation/') &&
              file.uri.pathSegments.last == 'backend.aot' &&
              file.path != old.path,
        );
        expect(replacements, hasLength(1));
        expect(
          replacements.single.readAsStringSync(),
          'snapshot $gitEntrypoint\n',
        );
        expect(old.existsSync(), damage != 'missing');
        fixture.expectRetained(retained);
        await fixture.prepare();
        expect(fixture.compilations(), isEmpty);
      },
    );
  }

  for (final damage in [
    'missing-receipt',
    'corrupt-receipt',
    'wrong-digest',
    'unlisted-output',
  ]) {
    test('$damage makes a component receipt non-reusable', () async {
      await fixture.prepare();
      final old = fixture.componentArtifact('chat-frontend-compilation');
      final receipt = File('${old.parent.path}/receipt.json');
      switch (damage) {
        case 'missing-receipt':
          receipt.deleteSync();
        case 'corrupt-receipt':
          receipt.writeAsStringSync('{incomplete');
        case 'wrong-digest':
          final data =
              jsonDecode(receipt.readAsStringSync()) as Map<String, dynamic>;
          (data['files'] as Map<String, dynamic>)['frontend.evc'] = {
            'sha256': '0' * 64,
            'executable': 0,
          };
          receipt.writeAsStringSync(jsonEncode(data));
        case 'unlisted-output':
          File(
            '${old.parent.path}/unlisted',
          ).writeAsStringSync('not inventoried');
      }
      final retained = fixture.retainedFiles();
      await fixture.prepare();
      expect(fixture.compilations(), [frontendHarness]);
      fixture.expectRetained(retained);
      expect(
        fixture.publishedFiles().where(
          (file) =>
              file.path.contains('/components/chat-frontend-compilation/') &&
              file.uri.pathSegments.last == 'frontend.evc',
        ),
        hasLength(2),
      );
    });
  }

  for (final output in ['host', 'manifest', 'schema', 'startup']) {
    test(
      'corrupt $output republishes a complete entry without compiling',
      () async {
        final before = await fixture.prepare();
        final old = File(switch (output) {
          'host' => before['ADELE_BACKEND_HOST_ARTIFACT']!,
          'startup' => before['ADELE_PLUGIN_STARTUP_ARGUMENTS_FILE']!,
          'schema' =>
            '${before['ADELE_PLUGIN_INSTALLATION_ROOT']}/openai/records.schema.json',
          _ =>
            '${before['ADELE_PLUGIN_INSTALLATION_ROOT']}/git/adele_plugin.installation.json',
        });
        old.writeAsStringSync('corrupt published output');
        final retained = fixture.retainedFiles();
        final after = await fixture.prepare();
        expect(fixture.compilations(), isEmpty);
        final key = output == 'startup'
            ? 'ADELE_PLUGIN_STARTUP_ARGUMENTS_FILE'
            : 'ADELE_PLUGIN_INSTALLATION_ROOT';
        expect(after[key], isNot(before[key]));
        final catalog = await PreparedPluginCatalog.discover(
          after['ADELE_PLUGIN_INSTALLATION_ROOT']!,
        );
        expect(catalog.issues, isEmpty);
        expect(
          jsonDecode(fixture.readStartupArguments()),
          isA<Map<String, dynamic>>(),
        );
        fixture.expectRetained(retained);
      },
    );
  }

  for (final output in ['snapshot', 'startup']) {
    test(
      'self-consistent incomplete $output receipt is not a cache hit',
      () async {
        final before = await fixture.prepare();
        final key = output == 'snapshot'
            ? 'ADELE_BACKEND_HOST_ARTIFACT'
            : 'ADELE_PLUGIN_STARTUP_ARGUMENTS_FILE';
        final artifact = File(before[key]!);
        final receipt = File('${artifact.parent.path}/receipt.json');
        final data =
            jsonDecode(receipt.readAsStringSync()) as Map<String, dynamic>;
        final files = data['files'] as Map<String, dynamic>;
        final removed = files.remove(artifact.uri.pathSegments.last);
        if (output == 'snapshot') {
          artifact.deleteSync();
        } else {
          artifact.renameSync('${artifact.parent.path}/unexpected.json');
          files['unexpected.json'] = removed;
        }
        receipt.writeAsStringSync(jsonEncode(data));
        final retained = fixture.retainedFiles();
        final after = await fixture.prepare();
        expect(fixture.compilations(), isEmpty);
        expect(after[key], isNot(artifact.path));
        expect(
          File(after['ADELE_BACKEND_HOST_ARTIFACT']!).readAsStringSync(),
          'snapshot $hostEntrypoint\n',
        );
        expect(
          jsonDecode(fixture.readStartupArguments()),
          isA<Map<String, dynamic>>(),
        );
        expect(artifact.existsSync(), isFalse);
        fixture.expectRetained(retained);
      },
    );
  }

  test(
    'native executable mode damage rebuilds without overwriting old entry',
    () async {
      await fixture.prepare();
      final helper = fixture.componentArtifact('git-pty-helper-compilation');
      expect(Process.runSync('chmod', ['-x', helper.path]).exitCode, 0);
      final retained = fixture.retainedFiles();
      await fixture.prepare();
      expect(fixture.compilations(), ['git-pty-helper']);
      expect(helper.statSync().mode & 0x49, 0);
      final replacement = fixture.publishedFiles().singleWhere(
        (file) =>
            file.path.contains('/components/git-pty-helper-compilation/') &&
            file.uri.pathSegments.last == 'pty-helper' &&
            file.path != helper.path,
      );
      expect(replacement.statSync().mode & 0x49, isNot(0));
      fixture.expectRetained(retained);
    },
  );

  test(
    'published receipts inventory every file with its SHA256 digest',
    () async {
      await fixture.prepare();
      final files = fixture.publishedFiles();
      final receipts = files.where(
        (file) => file.uri.pathSegments.last == 'receipt.json',
      );
      // Component receipts, plus the native PTY helper, snapshot and startup.
      expect(
        receipts,
        hasLength(
          toolStages.length +
              backendStages.length +
              frontendCompilations.length +
              3,
        ),
      );
      for (final receipt in receipts) {
        final decoded =
            jsonDecode(receipt.readAsStringSync()) as Map<String, dynamic>;
        expect(decoded['version'], 1);
        expect(
          decoded['identity'],
          receipt.parent.parent.uri.pathSegments.lastWhere(
            (part) => part.isNotEmpty,
          ),
        );
        final inventory = decoded['files'] as Map<String, dynamic>;
        final artifacts = receipt.parent
            .listSync(recursive: true)
            .whereType<File>()
            .where((file) => file.path != receipt.path)
            .toList();
        expect(
          inventory.keys,
          unorderedEquals(
            artifacts.map(
              (file) => file.path.substring(receipt.parent.path.length + 1),
            ),
          ),
        );
        final sums = Process.runSync('sha256sum', [
          '--zero',
          '--',
          ...artifacts.map((file) => file.path),
        ]);
        expect(sums.exitCode, 0, reason: '${sums.stderr}');
        final records = sums.stdout.toString().split('\u0000')..removeLast();
        for (var index = 0; index < artifacts.length; index++) {
          final relative = artifacts[index].path.substring(
            receipt.parent.path.length + 1,
          );
          expect(
            inventory[relative]['sha256'],
            records[index].substring(0, 64),
          );
          expect(artifacts[index].lengthSync(), greaterThan(0));
        }
      }
    },
  );

  test(
    'failed dirty backend rebuild cannot launch or mutate retained outputs',
    () async {
      final before = await fixture.prepare();
      final retained = fixture.retainedFiles();
      fixture.changeSource(gitEntrypoint);
      fixture.environment['ADELE_TEST_FAIL_ENTRYPOINT'] = gitEntrypoint;
      fixture.launchArguments.deleteSync();
      fixture.commands.deleteSync();
      final failed = await fixture.invoke(['run', 'linux']);
      expect(failed.exitCode, 17);
      expect(fixture.compilations(), [gitEntrypoint]);
      expect(fixture.launchArguments.existsSync(), isFalse);
      fixture.expectRetained(retained);
      expect(
        fixture.publishedFiles().map((file) => file.path),
        unorderedEquals(retained.keys),
      );
      fixture.environment.remove('ADELE_TEST_FAIL_ENTRYPOINT');
      final recovered = await fixture.prepare();
      expect(fixture.compilations(), [gitEntrypoint]);
      expect(recovered, isNot(before));
      fixture.expectRetained(retained);
    },
  );

  test('warm cache never masks native toolchain probe failures', () async {
    await fixture.prepare();
    final retained = fixture.retainedFiles();
    fixture.environment['ADELE_TEST_FAIL_NATIVE_INSPECTION'] = '1';
    fixture.launchArguments.deleteSync();
    fixture.commands.deleteSync();
    final failed = await fixture.invoke(['run', 'linux']);
    expect(failed.exitCode, 43);
    expect(failed.stdout, contains('native probe stdout'));
    expect(failed.stderr, contains('native probe stderr'));
    expect(
      failed.stderr,
      contains('toolchain inspection failed with exit code 43'),
    );
    expect(fixture.compilations(), isEmpty);
    expect(fixture.launchArguments.existsSync(), isFalse);
    fixture.expectRetained(retained);
  });

  for (final command in ['run', 'build']) {
    test(
      '$command warm cache never masks incremental generation or discovery failures',
      () async {
        await fixture.prepare();
        final retained = fixture.retainedFiles();
        final discoveries = File('${fixture.root.path}/logs/discovery.txt');
        fixture.frontendArguments.deleteSync();
        for (final failure in ['GENERATION', 'DISCOVERY']) {
          final previousDiscoveries = discoveries.readAsLinesSync();
          fixture.environment['ADELE_TEST_FAIL_$failure'] = '1';
          if (fixture.launchArguments.existsSync()) {
            fixture.launchArguments.deleteSync();
          }
          fixture.commands.deleteSync();
          final result = await fixture.invoke([command, 'linux']);
          expect(result.exitCode, failure == 'GENERATION' ? 29 : 1);
          expect(
            result.stderr,
            contains(
              failure == 'GENERATION'
                  ? 'contract generator failed'
                  : 'discovery worker failed',
            ),
          );
          expect(fixture.compilations(), isEmpty);
          expect(fixture.toolCompilations(), isEmpty);
          expect(fixture.commands.readAsLinesSync(), [
            'inspect-sdk',
            'generate|aot|--incremental',
          ]);
          fixture.expectGenerationArguments(['--incremental'], true);
          expect(discoveries.readAsLinesSync(), [
            ...previousDiscoveries,
            if (failure == 'DISCOVERY') 'discover|aot',
          ]);
          expect(fixture.launchArguments.existsSync(), isFalse);
          expect(fixture.frontendArguments.existsSync(), isFalse);
          fixture.expectRetained(retained);
          expect(
            fixture.publishedFiles().map((file) => file.path),
            unorderedEquals(retained.keys),
          );
          fixture.environment.remove('ADELE_TEST_FAIL_$failure');
        }
        await fixture.prepare([command, 'linux']);
        expect(fixture.compilations(), isEmpty);
        expect(fixture.toolCompilations(), isEmpty);
      },
    );
  }

  test(
    'overlapping preparations serialize or reject without partial publication',
    () async {
      fixture.environment['ADELE_TEST_PAUSE_ENTRYPOINT'] = codegenEntrypoint;
      final first = fixture.invoke(['run', 'linux']);
      final ready = File('${fixture.root.path}/logs/compiler-ready');
      final release = File('${fixture.root.path}/logs/compiler-release');
      try {
        final deadline = DateTime.now().add(const Duration(seconds: 15));
        while (!ready.existsSync() && DateTime.now().isBefore(deadline)) {
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
        expect(
          ready.existsSync(),
          isTrue,
          reason: 'First compiler did not reach barrier.',
        );
        expect(fixture.launchArguments.existsSync(), isFalse);
        expect(fixture.publishedFiles(), isEmpty);
        expect(fixture.toolCompilations(), [codegenEntrypoint]);
        expect(fixture.compilations(), isEmpty);
        fixture.environment.remove('ADELE_TEST_PAUSE_ENTRYPOINT');
        final second = fixture.invoke(['build', 'linux']);
        await Future.any<void>([
          second.then((_) {}),
          Future<void>.delayed(const Duration(seconds: 3)),
        ]);
        expect(fixture.launchArguments.existsSync(), isFalse);
        expect(fixture.publishedFiles(), isEmpty);
        expect(fixture.toolCompilations(), [codegenEntrypoint]);
        release.writeAsStringSync('release');
        final results = await Future.wait([first, second]);
        expect(results.first.exitCode, 0, reason: '${results.first.stderr}');
        if (results.last.exitCode != 0) {
          expect(
            results.last.stderr.toString().toLowerCase(),
            anyOf(
              contains('lease'),
              contains('lock'),
              contains('active'),
              contains('busy'),
            ),
          );
        }
        expect(
          fixture.compilations(),
          hasLength(
            backendEntrypoints.length + frontendCompilations.length + 1,
          ),
        );
        expect(fixture.toolCompilations(), toolStages.values);
        final catalog = await PreparedPluginCatalog.discover(
          fixture.launchDefines()['ADELE_PLUGIN_INSTALLATION_ROOT']!,
        );
        expect(catalog.issues, isEmpty);
        expect(
          catalog.installations,
          hasLength(stockInstallationDirectories.length),
        );
        final stable = fixture.launchDefines();
        expect(await fixture.prepare(), stable);
        expect(fixture.compilations(), isEmpty);
        expect(fixture.toolCompilations(), isEmpty);
      } finally {
        release.writeAsStringSync('release');
        await first;
      }
    },
  );
}
