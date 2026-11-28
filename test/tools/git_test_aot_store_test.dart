import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import '../../tools/git_test_aot_inputs.dart' show gitTestAotPlatformEligible;
import '../../tools/git_test_aot_store.dart';
import 'support/git_test_aot_store_fixture.dart';

void main() {
  late AotStoreFixture fixture;
  late Directory scope;
  late Directory suite;
  late GitTestAotStore store;
  late int serial;
  setUp(() async {
    final root = await Directory.systemTemp.createTemp('adele-aot-store-test-');
    addTearDown(() => root.delete(recursive: true));
    scope = await createPrivateGitTestDirectory(root, 'worker-');
    suite = await root.createTemp('suite-');
    fixture = AotStoreFixture(root);
    await fixture.prepare();
    store = fixture.open(scope);
    serial = 0;
  });
  File next() => File('${suite.path}/${serial++}.aot');
  Future<File> request([GitTestAot recipe = GitTestAot.host]) async {
    final out = next();
    await store.deliver(recipe, out);
    return out;
  }

  Directory ready() => scope.listSync().whereType<Directory>().single;
  group('private AOT publication', () {
    test(
      'concurrent requests launch one compiler and own distinct files',
      () async {
        final outputs = await Future.wait([request(), request(), request()]);
        expect(fixture.compilations, 1);
        final retained = File('${ready().path}/snapshot');
        final identities = <String>{};
        for (final file in [...outputs, retained]) {
          expect(file.readAsStringSync(), 'producer bytes');
          final stat = await Process.run('/usr/bin/stat', [
            '--printf=%d:%i %h',
            file.path,
          ]);
          expect(stat.stdout, endsWith(' 1'));
          identities.add(stat.stdout as String);
        }
        expect(identities, hasLength(4));
        await outputs[0].writeAsString('changed by suite');
        await outputs[1].delete();
        expect((await request()).readAsStringSync(), 'producer bytes');
        expect(fixture.compilations, 1);
        expect(fixture.observations.length, 3 + 2 + 2 + 2);
      },
    );

    test('neither recipe nor a new worker adopts an old publication', () async {
      expect(scope.listSync(), isEmpty);
      expect(fixture.compilations, 0);
      await request();
      await request(GitTestAot.git);
      expect(fixture.compilations, 2);
      // Even mistakenly supplying the same directory to a new store cannot
      // recover authority from disk. The real launcher uses a new scope too.
      store = fixture.open(scope);
      await request();
      expect(fixture.compilations, 3);
    });

    for (final fault in [
      'exit',
      'edit-input',
      'missing',
      'empty',
      'symlink',
      'hardlink',
      'wrong-target',
      'no-entry',
      'no-config',
      'uncovered',
    ]) {
      test(
        '$fault compiler output cannot replace a required compile',
        () async {
          final original = await request();
          fixture.identity = 'changed';
          await fixture.fault.writeAsString(fault);
          final out = next();
          await expectLater(
            store.deliver(GitTestAot.host, out),
            throwsA(
              fault == 'exit'
                  ? isA<ProcessException>()
                        .having((e) => e.errorCode, 'exit', 19)
                        .having(
                          (e) => e.message,
                          'diagnostic',
                          contains('compiler diagnostic'),
                        )
                  : anything,
            ),
          );
          expect(out.existsSync(), isFalse);
          expect(scope.listSync(), isEmpty);
          expect(fixture.compilations, 2);
          expect(original.readAsStringSync(), 'producer bytes');
          await fixture.fault.writeAsString('none');
          await store.deliver(GitTestAot.host, out);
          expect(fixture.compilations, 3);
        },
      );
    }

    for (final damage in [
      'missing',
      '0 bytes',
      'truncated',
      'same size',
      'symlink',
      'hardlink',
      'mode',
      'bad receipt',
      'missing receipt',
      'linked receipt',
      'unexpected file',
      'receipt and payload',
      'replaced directory',
    ]) {
      test('$damage in retained generation forces actual repair', () async {
        final copy = await request();
        final dir = ready();
        final artifact = File('${dir.path}/snapshot');
        final receipt = File('${dir.path}/receipt.json');
        switch (damage) {
          case 'missing':
            await artifact.delete();
          case '0 bytes':
            await artifact.writeAsBytes([]);
          case 'truncated':
            await artifact.writeAsString('half');
          case 'same size':
            await artifact.writeAsString('Producer bytes');
          case 'symlink':
            await artifact.delete();
            await Link(artifact.path).create(copy.path);
          case 'hardlink':
            expect(
              (await Process.run('ln', [
                artifact.path,
                '${suite.path}/hardlink',
              ])).exitCode,
              0,
            );
          case 'mode':
            expect(
              (await Process.run('chmod', ['400', artifact.path])).exitCode,
              0,
            );
          case 'bad receipt':
            await receipt.writeAsString('not JSON');
          case 'missing receipt':
            await receipt.delete();
          case 'linked receipt':
            final external = await receipt.rename('${suite.path}/receipt');
            await Link(receipt.path).create(external.path);
          case 'unexpected file':
            await File('${dir.path}/extra').create();
          case 'receipt and payload':
            await artifact.writeAsString('Producer bytes');
            final digest = await Process.run('sha256sum', [artifact.path]);
            final data =
                jsonDecode(receipt.readAsStringSync()) as Map<String, dynamic>;
            data['sha256'] = (digest.stdout as String).substring(0, 64);
            await receipt.writeAsString(jsonEncode(data));
          case 'replaced directory':
            final moved = await dir.rename('${suite.path}/fake-generation');
            await Link(dir.path).create(moved.path);
        }
        expect((await request()).readAsStringSync(), 'producer bytes');
        expect(fixture.compilations, 2);
        expect(copy.readAsStringSync(), 'producer bytes');
      });
    }

    for (final point in GitTestAotPoint.values) {
      for (final fault in ['inputs', 'provenance', 'artifact', 'interrupted']) {
        test('$fault during ${point.name} fails closed', () async {
          var inject = true;
          store = fixture.open(
            scope,
            checkpoint: (where, file) async {
              if (!inject || where != point) return;
              switch (fault) {
                case 'inputs':
                  fixture.identity = 'different';
                case 'provenance':
                  fixture.provenanceValid = false;
                case 'artifact':
                  await file.writeAsString('Producer bytes');
                case 'interrupted':
                  throw StateError('interrupted');
              }
            },
          );
          final out = next();
          await expectLater(
            store.deliver(GitTestAot.host, out),
            throwsA(anything),
          );
          expect(suite.listSync(), isEmpty);
          if (point == GitTestAotPoint.beforePublication) {
            expect(scope.listSync(), isEmpty);
          }
          expect(fixture.compilations, 1);
          inject = false;
          if (!fixture.provenanceValid) {
            // A retry cannot compile through a broken generation proof.
            await expectLater(
              store.deliver(GitTestAot.host, out),
              throwsStateError,
            );
            expect(fixture.compilations, 1);
            expect(out.existsSync(), isFalse);
          } else {
            await store.deliver(GitTestAot.host, out);
            expect(out.readAsStringSync(), 'producer bytes');
          }
        });
      }
    }

    test('failed lock holder releases queued retry', () async {
      final entered = Completer<void>();
      final unblock = Completer<void>();
      var once = true;
      store = fixture.open(
        scope,
        checkpoint: (p, _) async {
          if (p == GitTestAotPoint.beforePublication && once) {
            once = false;
            entered.complete();
            await unblock.future;
            throw StateError('interruption');
          }
        },
      );
      final failure = expectLater(request(), throwsStateError);
      await entered.future;
      final queued = request();
      unblock.complete();
      await failure;
      expect((await queued).readAsStringSync(), 'producer bytes');
      expect(fixture.compilations, 2);
    });

    test(
      'rejects existing, linked, noncanonical and scope destinations',
      () async {
        final exists = next()..writeAsStringSync('untouched');
        final alias = Link('${fixture.root.path}/alias')
          ..createSync(suite.path);
        final dangling = Link('${suite.path}/link')
          ..createSync('${suite.path}/absent');
        for (final out in [
          exists,
          File('${alias.path}/out'),
          File(dangling.path),
          File('${scope.path}/bad'),
        ]) {
          await expectLater(
            store.deliver(GitTestAot.git, out),
            throwsA(anything),
          );
        }
        expect(exists.readAsStringSync(), 'untouched');
        expect(fixture.compilations, 0);
        expect(scope.listSync(), isEmpty);
      },
    );
    test(
      'propagates genuine pinned compiler diagnostics without publication',
      () async {
        final entry = File(
          '${fixture.root.path}/${GitTestAot.host.entrypoint}',
        );
        await entry.parent.create(recursive: true);
        await entry.writeAsString('void main() => undefinedForThisCompile();');
        final config = File(
          '${fixture.root.path}/.dart_tool/package_config.json',
        );
        await config.parent.create();
        await config.writeAsString('{"configVersion":2,"packages":[]}');
        final bin = File(Platform.resolvedExecutable).parent;
        store = fixture.open(scope, useCompiler: '${bin.path}/dart');
        await expectLater(
          request(),
          throwsA(
            isA<ProcessException>()
                .having((e) => e.errorCode, 'exit code', isNonZero)
                .having(
                  (e) => e.message,
                  'real compiler message',
                  contains('undefinedForThisCompile'),
                ),
          ),
        );
        expect(scope.listSync(), isEmpty);
        expect(suite.listSync(), isEmpty);
      },
    );
  }, skip: !gitTestAotPlatformEligible);
}
