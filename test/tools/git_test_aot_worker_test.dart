@TestOn('linux')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import '../../tools/git_test_aot_client.dart';
import '../../tools/git_test_aot_inputs.dart' show gitTestAotPlatformEligible;
import '../../tools/git_test_aot_worker.dart';
import 'support/git_test_aot_peer.dart' as fixture;
import 'support/git_test_aot_store_fixture.dart';

final _peer = File('test/tools/support/git_test_aot_peer.dart').absolute.path;

Future<int> _worker(
  Directory root,
  String mode,
  GitTestDelivery Function(Directory scope) open,
) => fixture.runFixtureWorker(File(_peer), root, mode, open);

void main() {
  if (!gitTestAotPlatformEligible) return;
  late Directory root;
  setUp(() => root = Directory.systemTemp.createTempSync('git-worker-test-'));
  tearDown(() => root.deleteSync(recursive: true));

  test(
    'no requests, isolated invocations and ordinary child environment',
    () async {
      final scopes = <String>{};
      final roots = [
        for (final n in [1, 2]) Directory('${root.path}/$n')..createSync(),
      ];
      expect(
        await Future.wait([
          for (final repo in roots)
            _worker(repo, 'empty', (scope) {
              expect(scope.statSync().mode & 0x1ff, 0x1c0); // 0700
              scopes.add(scope.path);
              return (_, _) => throw StateError('Eager artifact preparation');
            }),
        ]),
        [0, 0],
      );
      expect(scopes, hasLength(2));
      for (final repo in roots) {
        final socket = File('${repo.path}/locator').readAsStringSync();
        expect(scopes, contains(File(socket).parent.path));
        expect(File(socket).parent.existsSync(), isFalse);
        final abandoned = await Process.run(
          Platform.resolvedExecutable,
          [_peer, 'peer', repo.path],
          environment: {gitTestAotLocator: socket},
        );
        expect(abandoned.exitCode, isNot(0));
        final direct = await Process.run(
          Platform.resolvedExecutable,
          [_peer, 'direct', repo.path],
          environment: testWorkerEnvironment({gitTestAotLocator: socket}),
          includeParentEnvironment: false,
        );
        expect(direct.exitCode, 0, reason: '${direct.stderr}');
      }
    },
  );

  test(
    'isolates and an independent suite process reach the same owner',
    () async {
      final admitted = <File>[];
      final concurrent = Completer<void>();
      final publisher = AotStoreFixture(root);
      await publisher.prepare();
      expect(
        await _worker(root, 'concurrent', (scope) {
          final store = publisher.open(scope);
          return (recipe, destination) async {
            expect(recipe, GitTestAot.host);
            admitted.add(destination);
            if (admitted.length == 3) concurrent.complete();
            await concurrent.future.timeout(const Duration(seconds: 8));
            await store.deliver(recipe, destination);
          };
        }),
        0,
      );
      expect(publisher.compilations, 1);
      expect(
        admitted.map((f) => f.path),
        unorderedEquals([
          for (final n in ['peer', 'first', 'second']) '${root.path}/$n.aot',
        ]),
      );
    },
  );

  test(
    'same checkout has independent host-only and Git worker stores',
    () async {
      final scopes = <Directory>[];
      final publisher = AotStoreFixture(root);
      await publisher.prepare();
      expect(
        await Future.wait([
          for (final (name, recipes) in [
            ('desktop', {GitTestAot.host}),
            ('git', {GitTestAot.host, GitTestAot.git}),
          ])
            fixture.runFixtureWorker(File(_peer), root, name, (scope) {
              scopes.add(scope);
              return publisher.open(scope).deliver;
            }, allowedRecipes: recipes),
        ]),
        [0, 0],
      );
      expect(scopes.map((s) => s.path).toSet(), hasLength(2));
      expect(scopes.any((s) => s.existsSync()), isFalse);
      expect(
        publisher.compilations,
        3,
      ); // One host per worker; Git only in Git.
      expect(File('${root.path}/desktop-git.aot').existsSync(), isFalse);
      for (final name in ['desktop-host', 'git-host', 'git-git']) {
        expect(
          File('${root.path}/$name.aot').readAsStringSync(),
          'producer bytes',
        );
      }
    },
  );

  test(
    'wrong SDK is ineligible; wrong checkout fails the worker and cleans up',
    () async {
      late Directory scope;
      expect(
        await _worker(root, 'reject', (dir) {
          scope = dir;
          return (_, _) => throw StateError('Unexpected admission');
        }),
        37,
      );
      expect(scope.existsSync(), isFalse);
      expect(File('${root.path}/wrong-checkout.aot').existsSync(), isFalse);
    },
  );

  for (final signal in [ProcessSignal.sigterm, ProcessSignal.sigkill]) {
    test('owner $signal during admitted work', () async {
      final owner = await Process.start(Platform.resolvedExecutable, [
        _peer,
        'owner',
        root.path,
      ]);
      addTearDown(() => owner.kill(ProcessSignal.sigkill));
      final errors = owner.stderr.transform(utf8.decoder).join();
      final line = await owner.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .firstWhere((s) => s.startsWith('ADMITTED '));
      final scope = Directory(line.substring('ADMITTED '.length));
      addTearDown(() {
        if (scope.existsSync()) scope.deleteSync(recursive: true);
      });
      expect(owner.kill(signal), isTrue);
      if (signal == ProcessSignal.sigterm) {
        owner.stdin.writeln('release');
        await owner.stdin.flush();
      }
      expect(await owner.exitCode, -signal.signalNumber, reason: await errors);
      if (signal == ProcessSignal.sigterm) {
        expect(File('${root.path}/drained').readAsStringSync(), scope.path);
        expect(scope.existsSync(), isFalse);
      } else {
        expect(scope.existsSync(), isTrue);
        expect(
          await _worker(root, 'empty', (fresh) {
            expect(fresh.path, isNot(scope.path));
            return (_, _) => throw StateError('Reused abandoned input');
          }),
          0,
        );
        expect(scope.existsSync(), isTrue);
      }
    });
  }
}
