@Timeout(Duration(minutes: 4))
library;

import 'dart:convert';
import 'dart:io';

import 'package:adele_capabilities/adele_capabilities.dart';
import 'package:adele_desktop/core/environment_capability_selection.dart';
import 'package:adele_environment/adele_environment.dart';
import 'package:adele_product/adele_product.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../../../app/test/support/prepared_buffered_process.dart';

const _stockPlugin = 'dev.adele.plugin.git';
const _stockProvider = 'dev.adele.environment.git-worktree';
const _binaryInput = [0, 255, 195, 40, 128, 97, 0];

void main() {
  final suite = PreparedBufferedProcess(
    Directory.current.parent.parent.parent.parent,
  );
  late File stockArtifact;
  late Directory repository;
  late List<Environment> stockEnvironments;

  setUpAll(() async {
    await suite.prepare();
    stockArtifact = await suite.compileBackend(
      'plugins/git/packages/backend/bin/git_backend.dart',
      'stock',
    );
    repository = await Directory('${suite.temporary.path}/repository').create();
    await _git(repository, ['init', '--initial-branch=main']);
    await File('${repository.path}/seed.txt').writeAsString('baseline\n');
    await _git(repository, ['add', '--', 'seed.txt']);
    await _git(repository, [
      '-c',
      'user.name=Fixture',
      '-c',
      'user.email=fixture@example.invalid',
      'commit',
      '-m',
      'baseline',
    ]);
    stockEnvironments = [];
    for (final id in ['additional', 'primary']) {
      final relative = '.adele/worktrees/$id';
      await _git(repository, ['worktree', 'add', '-b', 'adele-$id', relative]);
      final checkout = Directory('${repository.path}/$relative');
      final names = id == 'additional'
          ? ['file with spaces.txt', 'line\nname.txt', 'overflow.bin']
          : ['primary-only.txt'];
      for (final name in names) {
        if (name == 'overflow.bin') {
          await File('${checkout.path}/$name').writeAsBytes(
            List<int>.filled(environmentBufferedProcessStdoutLimit + 1, 255),
          );
        } else {
          await File('${checkout.path}/$name').writeAsString('$id\n');
        }
      }
      await _git(checkout, ['add', '--', ...names]);
      stockEnvironments.add(
        Environment(
          id: EnvironmentId(id),
          taskId: TaskId('task'),
          role: id == 'additional'
              ? EnvironmentRole.additional
              : EnvironmentRole.primary,
          providerId: ProviderId(_stockProvider),
          providerState: {
            'schemaVersion': 2,
            'environmentId': id,
            'sourceRelativePath': '',
            'worktreeRelativePath': relative,
            'branch': 'adele-$id',
          },
        ),
      );
    }
  });

  testWidgets(
    'stock AOT A hashes binary stdin and returns NUL-delimited nonprimary paths through independent B and EVC C',
    (tester) async {
      final fixture = await suite.mount(
        tester,
        environmentPlugin: _stockPlugin,
        environmentArtifact: stockArtifact,
        sourceLocation: repository.uri,
        environments: stockEnvironments,
        concurrent: true,
      );
      expect(
        fixture.environmentOwner.installation.metadata.id.value,
        _stockPlugin,
      );
      expect(fixture.connection, isNot(same(fixture.environmentConnection)));
      expect(
        fixture.callableOwner.installation.backendArtifactUri,
        isNot(fixture.environmentOwner.installation.backendArtifactUri),
      );
      expect(
        fixture.connection.capabilityExposures.every(
          (exposure) =>
              exposure.capabilityId != environmentProviderCapability.id.value,
        ),
        isTrue,
      );
      final selected = await tester.runAsync(
        () => CapturedEnvironmentCapabilities(
          environmentRuntime: fixture.environmentRuntime,
          backends: fixture.backends,
          session: fixture.sessionA,
        ).resolve(bufferedCapability),
      );
      expect(selected!.environment.id.value, 'additional');
      expect(selected.environment.role, EnvironmentRole.additional);
      expect(
        selected.materialization.binding.provider.id.value,
        _stockProvider,
      );
      expect(selected.binding.provider.id.value, 'test.callable.a');
      expect(fixture.callableOwner.associationFor(selected.binding), isNull);
      fixture.environmentOwner.validateProviderOwnership(
        selected.materialization.binding,
      );
      fixture.callableOwner.validateProviderOwnership(selected.binding);
      expect(
        () => fixture.environmentOwner.validateProviderOwnership(
          selected.binding,
        ),
        throwsStateError,
      );
      await select(tester);
      await select(tester, pane: 'b');

      press(tester, 'hash');
      // Git blob identity is independently computed, not compared to another Git invocation.
      final digest = sha1.convert([
        ...utf8.encode('blob ${_binaryInput.length}\x00'),
        ..._binaryInput,
      ]);
      await waitForText(tester, bufferedResult(utf8.encode('$digest\n')));
      press(tester, 'files');
      await waitForText(
        tester,
        bufferedResult(
          utf8.encode(
            'file with spaces.txt\x00line\nname.txt\x00overflow.bin\x00seed.txt\x00',
          ),
        ),
      );
      press(tester, 'files', pane: 'b');
      await waitForText(
        tester,
        bufferedResult(utf8.encode('primary-only.txt\x00seed.txt\x00')),
        pane: 'b',
      );
      press(tester, 'empty');
      await waitForText(tester, bufferedResult([]));
      press(tester, 'stdin-bound');
      final fullInput = List<int>.filled(
        environmentBufferedProcessStdinLimit,
        255,
      );
      final fullDigest = sha1.convert([
        ...utf8.encode('blob ${fullInput.length}\x00'),
        ...fullInput,
      ]);
      await waitForText(tester, bufferedResult(utf8.encode('$fullDigest\n')));
      press(tester, 'nonzero');
      await waitForText(
        tester,
        bufferedResult(
          [],
          exitCode: 128,
          stderr: utf8.encode('fatal: Needed a single revision\n'),
        ),
      );
      for (final (action, code) in [
        ('timeout', 'process_timed_out'),
        ('stdout-overflow', 'process_output_overflow'),
      ]) {
        press(tester, action);
        await tester.runAsync(() => fixture.wait(tester, 'settled:$action'));
        await waitForText(tester, 'process:unavailable');
        expect(
          ((await tester.runAsync(() => callableSnapshot(fixture)))!['failures']
                  as List)
              .last,
          code,
        );
      }
      final requests = fixture.calls(
        (await tester.runAsync(() => callableSnapshot(fixture)))!,
      );
      expect(requests, hasLength(8));
      expect(
        requests.map((r) => r['hostInvocationContext']).toSet(),
        hasLength(8),
      );
      expect(
        requests.every((r) => r['configurationContext'] == 'callable-shared'),
        isTrue,
      );
      for (final request in requests) {
        expect((request['payload'] as Map).keys, ['scope']);
        await tester.runAsync(
          () =>
              expectDenied(fixture, request['hostInvocationContext'] as String),
        );
      }
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}

Future<String> _git(Directory directory, List<String> arguments) async {
  final result = await Process.run(
    'git',
    arguments,
    workingDirectory: directory.path,
  );
  expect(result.exitCode, 0, reason: '${result.stderr}');
  return result.stdout as String;
}
