import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

// ignore: avoid_relative_lib_imports
import '../../packages/contract_codegen/lib/src/provenance_files.dart';
import '../../tools/desktop_artifact_cache.dart' show hashBuildFiles;
import '../../tools/git_test_aot_inputs.dart';
import '../../tools/test_contract_provenance.dart';

void main() {
  if (!gitTestAotPlatformEligible) {
    test(
      'unsupported hosts reject inventory before inspecting paths',
      () async {
        await expectLater(
          GitTestAotInputs.capture(
            repositoryRoot: Directory.current,
            recipe: GitTestAot.host,
            dartExecutable: 'unused',
            runtimeExecutable: 'unused',
          ),
          throwsUnsupportedError,
        );
      },
    );
    return;
  }
  late Directory sandbox;
  late Directory root;
  late Directory flutter;
  late String sdk;
  late String external;
  late String git;
  late String host;

  File write(String path, [String text = '// test input\n']) {
    final file = File(path);
    file.parent.createSync(recursive: true);
    return file..writeAsStringSync(text);
  }

  void resolve({
    List<String> rootDeps = const [],
    String? hostRoot,
    String? lib,
  }) {
    write(
      '${root.path}/.dart_tool/package_config.json',
      jsonEncode({
        'configVersion': 2,
        'generator': 'pub',
        'generatorVersion': '3.10.9',
        'flutterVersion': '3.38.10',
        'flutterRoot': flutter.uri.toString(),
        'packages': [
          for (final (name, location, library) in [
            ('adele_workspace', '../', 'lib/'),
            (
              'plugin_backend_host',
              hostRoot ?? '../packages/plugin_backend_host',
              'lib/',
            ),
            ('git_backend', '../plugins/git/packages/backend', 'lib/'),
            ('leaf', Directory(external).uri.toString(), lib ?? 'src/'),
            ('unused', '../unused', 'lib/'),
          ])
            {
              'name': name,
              'rootUri': location,
              'packageUri': library,
              'languageVersion': '3.10',
            },
        ],
      }),
    );
    write(
      '${root.path}/.dart_tool/package_graph.json',
      jsonEncode({
        'packages': [
          for (final (name, deps) in [
            ('adele_workspace', rootDeps),
            ('plugin_backend_host', ['leaf']),
            ('git_backend', ['leaf']),
            ('leaf', <String>[]),
          ])
            {
              'name': name,
              'dependencies': deps,
              'devDependencies': ['unused'],
            },
        ],
      }),
    );
  }

  Future<GitTestAotInputs> observe([
    GitTestAot recipe = GitTestAot.host,
    void Function()? mutation,
  ]) => GitTestAotInputs.capture(
    recipe: recipe,
    repositoryRoot: root,
    dartExecutable: '$sdk/bin/dart',
    runtimeExecutable: '$sdk/bin/dartaotruntime',
    afterInitialStatForTesting: mutation,
  );

  setUp(() {
    sandbox = Directory.systemTemp.createTempSync('git aot inputs ');
    root = Directory('${sandbox.path}/repo');
    flutter = Directory('${sandbox.path}/flutter');
    sdk = '${flutter.path}/bin/cache/dart-sdk';
    external = '${sandbox.path}/pub #leaf';
    git = '${root.path}/plugins/git/packages/backend';
    host = '${root.path}/packages/plugin_backend_host';
    write(
      '${flutter.path}/bin/cache/flutter.version.json',
      jsonEncode({
        'frameworkVersion': '3.38.10',
        'dartSdkVersion': '3.10.9',
        'frameworkRevision': 'c6f67dede3d4aa1aa7a69dd56a3494a5cde6cc80',
        'engineRevision': 'cafcda5721a78a7884db92f13c5e89f7643d52dd',
      }),
    );
    write('$sdk/version', '3.10.9\n');
    for (final path in [
      'revision',
      'bin/dart',
      'bin/dartvm',
      'bin/dartaotruntime',
      'bin/utils/gen_snapshot',
      'bin/snapshots/dartdev_aot.dart.snapshot',
      'bin/snapshots/gen_kernel_aot.dart.snapshot',
      'lib/libraries.json',
      'lib/_internal/vm_platform_product.dill',
      'lib/_internal/vm_platform.dill',
      'lib/_internal/vm_platform_strong.dill',
    ]) {
      write('$sdk/$path');
    }
    for (final path in [
      '.tool-versions',
      'pubspec.lock',
      'tools/adele.dart',
      'tools/desktop_artifact_cache.dart',
      'tools/desktop_tool_artifacts.dart',
      'tools/git_test_aot_inputs.dart',
      'tools/git_test_aot_store.dart',
      'tools/git_test_aot_worker.dart',
      'tools/git_test_aot_client.dart',
      'tools/test_contract_provenance.dart',
      'packages/contract_codegen/lib/src/provenance_files.dart',
      'packages/plugin_builder/lib/src/development_plugin_builder.dart',
      GitTestAot.git.entrypoint,
      GitTestAot.host.entrypoint,
    ]) {
      write('${root.path}/$path');
    }
    write('${root.path}/pubspec.yaml', 'name: adele_workspace\n');
    for (final (path, name) in [
      (host, 'plugin_backend_host'),
      (git, 'git_backend'),
      (external, 'leaf'),
    ]) {
      write('$path/pubspec.yaml', 'name: $name\n');
    }
    write('$host/lib/host.dart');
    write('$git/lib/contract.g.dart');
    write('$external/src/leaf.dart');
    write('$external/lib/not_selected.dart');
    write('${root.path}/unused/lib/not_selected.dart');
    resolve();
  });
  tearDown(() => sandbox.deleteSync(recursive: true));

  test(
    'byte-bounded and desktop batches return the same sorted hashes',
    () async {
      // Cross both the 128-path and 64 KiB limits, including UTF-8 paths.
      final segment = '\u00e9' * 100;
      final files = [
        for (var i = 0; i < 160; i++)
          write('${sandbox.path}/$segment/$segment/input $i', 'file $i').path,
      ]..sort();
      final paths = [...files.reversed, files.first];
      final desktop = await hashBuildFiles(paths);
      final bounded = await hashBuildFiles(paths, batchByArgumentBytes: true);
      expect(bounded.keys, orderedEquals(files));
      expect(bounded, desktop);
      expect(bounded.values.toSet(), hasLength(files.length));
    },
  );

  group('joint compiler and generation read', () {
    late String compilerOnly, generatorOnly, source, output, transitive, probe;
    late ProvenanceFiles generator, proof;
    late Map<String, String> expected;
    final wrong = '0' * 64;

    setUp(() async {
      compilerOnly = '$external/src/leaf.dart';
      generatorOnly = '$external/lib/not_selected.dart';
      source = write('$git/lib/contract.dart').path;
      output = '$git/lib/contract.g.dart';
      transitive = '${root.path}/unused/lib/not_selected.dart';
      probe = '${root.path}/unused/lib/analysis_options.yaml';
      generator = ProvenanceFiles()
        ..watch('$sdk/bin/dart', read: true) // shared with both recipes
        ..watch(generatorOnly, read: true);
      proof = ProvenanceFiles()
        ..watch(source, read: true)
        ..watch(output, read: true)
        ..watch(transitive, read: true)
        ..watch(probe);
      expected = await hashBuildFiles({...generator.reads, ...proof.reads});
    });

    GenerationReadFence begin(Set<String> paths) => beginGenerationReadFence(
      paths,
      generator: generator,
      expectedHashes: expected,
      outputs: {output: proof},
    );

    Future<GitTestAotInputs> capture({
      GitTestAot recipe = GitTestAot.git,
      Future<Map<String, String>> Function(Iterable<String>) hash =
          hashBuildFiles,
      void Function()? afterInitial,
    }) => GitTestAotInputs.capture(
      repositoryRoot: root,
      recipe: recipe,
      dartExecutable: '$sdk/bin/dart',
      runtimeExecutable: '$sdk/bin/dartaotruntime',
      generationReads: begin,
      hashForTesting: hash,
      afterInitialStatForTesting: afterInitial,
    );

    Future<GitTestAotInputs> report(
      GitTestAot recipe,
      String path,
      String? value,
    ) => capture(
      recipe: recipe,
      hash: (paths) async {
        final hashes = await hashBuildFiles(paths);
        if (value == null) {
          hashes.remove(path);
        } else {
          hashes[path] = value;
        }
        return hashes;
      },
    );

    for (final recipe in GitTestAot.values) {
      test('$recipe rereads the exact union once per capture', () async {
        final compiler = await observe(recipe);
        final union = {
          ...compiler.filePaths,
          generatorOnly,
          source,
          output,
          if (recipe == GitTestAot.git) transitive,
        };
        var calls = 0;
        Future<Map<String, String>> hash(Iterable<String> paths) {
          calls++;
          expect(paths, unorderedEquals(union)); // includes multiplicity
          return hashBuildFiles(paths);
        }

        for (var request = 1; request <= 2; request++) {
          final joint = await capture(recipe: recipe, hash: hash);
          expect(calls, request);
          expect(joint.filePaths, unorderedEquals(compiler.filePaths));
          expect(joint.digest, compiler.digest);
        }
      });
    }

    test('either sibling selects the full proof; an unknown part fails', () {
      for (final path in [source, output]) {
        expect(begin({path}).paths, unorderedEquals(expected.keys));
      }
      expect(() => begin({'$host/lib/unknown.g.dart'}), throwsStateError);
    });

    test('deleting both configured siblings fails before hashing', () async {
      await capture(recipe: GitTestAot.host);
      File(source).deleteSync();
      File(output).deleteSync();
      await expectLater(
        capture(
          recipe: GitTestAot.host,
          afterInitial: () => fail('accepted stale initial generation fence'),
          hash: (_) => fail('hashed after stale initial generation fence'),
        ),
        throwsStateError,
      );
    });

    test('requires the expected digest of every selected read', () async {
      for (final path in expected.keys) {
        // Host has neither sibling; only Git requires the transitive read.
        final recipe = path == transitive ? GitTestAot.git : GitTestAot.host;
        for (final value in [null, wrong]) {
          await expectLater(
            report(recipe, path, value),
            throwsStateError,
            reason: '$path reported as $value',
          );
        }
      }
      // Equality of two absent map entries is not evidence of a read.
      expected.remove(transitive);
      expect(() => begin({output}).verify(expected), throwsStateError);
    });

    test('requires and keys a well-formed compiler-only digest', () async {
      for (final invalid in [null, 'a' * 63, 'g' * 64]) {
        await expectLater(
          report(GitTestAot.git, compilerOnly, invalid),
          throwsStateError,
          reason: 'compiler digest: $invalid',
        );
      }
      final actual = await capture();
      final forged = await report(GitTestAot.git, compilerOnly, wrong);
      expect(forged.digest, isNot(actual.digest));
    });

    test('later observation reads the new compiler-only bytes', () async {
      final reads = <String>[];
      Future<Map<String, String>> hash(Iterable<String> paths) async {
        final current = await hashBuildFiles(paths, batchByArgumentBytes: true);
        reads.add(current[compilerOnly]!);
        return current;
      }

      final before = await capture(hash: hash);
      write(compilerOnly, 'new stable bytes');
      final after = await capture(hash: hash);
      expect(reads.toSet(), hasLength(2));
      expect(after.digest, isNot(before.digest));
    });

    test('restored analyzer bytes still fail the generation fence', () async {
      final file = File(transitive);
      final bytes = file.readAsBytesSync();
      final mtime = file.lastModifiedSync();
      await expectLater(
        capture(
          afterInitial: () {
            file
              ..writeAsStringSync('temporary')
              ..writeAsBytesSync(bytes)
              ..setLastModifiedSync(mtime);
          },
        ),
        throwsStateError,
      );
    });

    test('compiler membership cannot change between two byte reads', () async {
      await expectLater(
        capture(
          hash: (paths) async {
            final first = await hashBuildFiles([compilerOnly]);
            write('$external/src/late.dart');
            final rest = await hashBuildFiles(
              paths.where((p) => p != compilerOnly),
            );
            return {...first, ...rest};
          },
        ),
        throwsStateError,
      );
    });

    for (final before in [true, false]) {
      final phase = before ? 'before capture' : 'after byte reads';
      test('known negative probe created and removed $phase', () async {
        await capture();
        if (before) write(probe).deleteSync();
        var calls = 0;
        await expectLater(
          capture(
            hash: (paths) async {
              calls++;
              final hashes = await hashBuildFiles(paths);
              if (!before) write(probe).deleteSync();
              return hashes;
            },
          ),
          throwsStateError,
        );
        expect(calls, before ? 0 : 1);
      });
    }
  });

  test(
    'only stock entrypoints and fixed compile recipe are expressible',
    () async {
      expect(GitTestAot.values.map((recipe) => recipe.entrypoint), [
        'packages/plugin_backend_host/bin/adele_backend_host.dart',
        'plugins/git/packages/backend/bin/git_backend.dart',
      ]);
      final observed = await observe();
      final out = File('${sandbox.path}/stage/snapshot');
      final dep = File('${sandbox.path}/deps');
      expect(observed.arguments(output: out, depfile: dep), [
        'compile',
        'aot-snapshot',
        GitTestAot.host.entrypoint,
        '-o',
        out.path,
        '--depfile',
        dep.path,
        '--packages',
        '${root.path}/.dart_tool/package_config.json',
      ]);
      expect(
        () => observed.arguments(output: dep, depfile: out),
        throwsArgumentError,
      );
      expect(
        observed.environment.keys,
        unorderedEquals(['PATH', 'LC_ALL', 'DART_SUPPRESS_ANALYTICS']),
      );
      expect(await (observe().then((i) => i.digest)), observed.digest);
      expect((await observe(GitTestAot.git)).digest, isNot(observed.digest));
    },
  );

  test(
    'follows only selected resolved libraries, includes generated parts',
    () async {
      final h = await observe();
      final g = await observe(GitTestAot.git);
      expect(h.filePaths, contains('$external/src/leaf.dart'));
      expect(h.filePaths, isNot(contains('$external/lib/not_selected.dart')));
      expect(h.filePaths, isNot(contains('$git/lib/contract.g.dart')));
      expect(g.filePaths, contains('$git/lib/contract.g.dart'));
      final nested = write('${root.path}/plugins/git/pubspec_overrides.yaml');
      final withOverride = await observe(GitTestAot.git);
      expect(withOverride.filePaths, contains(nested.path));
      expect(withOverride.digest, isNot(g.digest));
      write('${root.path}/unused/lib/not_selected.dart', 'irrelevant');
      expect((await observe()).digest, h.digest);
      write('$git/lib/contract.g.dart', 'dirty but stable');
      final changed = await observe(GitTestAot.git);
      expect(changed.digest, isNot(withOverride.digest));
      expect((await observe(GitTestAot.git)).digest, changed.digest);
      expect((await observe()).digest, h.digest);
      File('$git/lib/contract.g.dart').deleteSync();
      expect(
        (await observe(GitTestAot.git)).filePaths,
        isNot(contains('$git/lib/contract.g.dart')),
      );
    },
  );

  test(
    'keys transitive inputs, library membership, overrides, tools and SDK',
    () async {
      var before = await observe();
      for (final path in [
        '$external/src/leaf.dart',
        '$external/src/new.dart',
        '$external/pubspec_overrides.yaml',
        '${root.path}/pubspec.lock',
        '$host/pubspec.yaml',
        '$host/lib/host.dart',
        '${root.path}/tools/git_test_aot_store.dart',
        '$sdk/bin/dart',
        '$sdk/bin/dartaotruntime',
        '$sdk/bin/snapshots/gen_kernel_aot.dart.snapshot',
        '$sdk/bin/utils/gen_snapshot',
        '$sdk/lib/_internal/vm_platform_product.dill',
      ]) {
        write(path, 'changed $path');
        final changed = await observe();
        expect(changed.digest, isNot(before.digest), reason: path);
        expect(changed.filePaths, contains(path));
        before = changed;
      }
      external = '${sandbox.path}/relocated';
      write('$external/pubspec.yaml', 'name: leaf\n');
      write('$external/custom/leaf.dart');
      resolve(lib: 'custom/');
      final moved = await observe();
      expect(moved.filePaths, contains('$external/custom/leaf.dart'));
      expect(
        moved.filePaths,
        isNot(contains('${sandbox.path}/pub #leaf/src/leaf.dart')),
      );
      expect(moved.digest, isNot(before.digest));
    },
  );

  for (final where in [
    'root hook',
    'transitive hook',
    'entry shadow',
    'ancestor shadow',
    'legacy shadow',
  ]) {
    test('refuses $where rather than overriding fresh compilation', () async {
      write(switch (where) {
        'root hook' => '${root.path}/hook/build.dart',
        'transitive hook' => '$external/hook/build.dart',
        'entry shadow' => '$host/bin/.dart_tool/package_config.json',
        'ancestor shadow' =>
          '${root.path}/packages/.dart_tool/package_config.json',
        _ => '$host/.packages',
      });
      await expectLater(observe(), throwsStateError);
    });
  }

  test(
    'refuses ambiguous owners, native-cwd dependencies and mismatched SDK',
    () async {
      resolve(hostRoot: '../wrong');
      await expectLater(observe(), throwsStateError);
      resolve(hostRoot: '../');
      await expectLater(observe(), throwsFormatException);
      resolve(lib: '../outside/');
      await expectLater(observe(), throwsFormatException);
      resolve(rootDeps: ['leaf']);
      await expectLater(observe(), throwsStateError);
      resolve();
      await expectLater(
        GitTestAotInputs.capture(
          repositoryRoot: root,
          recipe: GitTestAot.host,
          dartExecutable: '$sdk/bin/dart',
          runtimeExecutable: '/other/dartaotruntime',
        ),
        throwsStateError,
      );
      write('$sdk/version', '3.12.0');
      await expectLater(observe(), throwsStateError);
    },
  );

  test(
    'rejects linked regular input, linked directory and symlinked checkout',
    () async {
      final source = File('$external/src/leaf.dart');
      source.deleteSync();
      Link(source.path).createSync('$external/lib/not_selected.dart');
      await expectLater(observe(), throwsStateError);
      Link(source.path).deleteSync();
      expect(
        Process.runSync('ln', [
          '$external/lib/not_selected.dart',
          source.path,
        ]).exitCode,
        0,
      );
      await expectLater(observe(), throwsStateError);
      source.deleteSync();
      Directory('$external/src').deleteSync();
      Link('$external/src').createSync('$external/lib');
      await expectLater(observe(), throwsStateError);
      Link('${sandbox.path}/alias').createSync(root.path);
      await expectLater(
        GitTestAotInputs.capture(
          repositoryRoot: Directory('${sandbox.path}/alias'),
          recipe: GitTestAot.host,
          dartExecutable: '$sdk/bin/dart',
          runtimeExecutable: '$sdk/bin/dartaotruntime',
        ),
        throwsStateError,
      );
    },
  );

  test(
    'refuses transient edits, replaced inputs and negative probes inside discovery',
    () async {
      final file = File('$external/src/leaf.dart');
      for (final mutation in <void Function()>[
        () {
          write('$external/src/new.dart');
        },
        () {
          write('$host/pubspec_overrides.yaml').deleteSync();
        },
        () {
          final intermediate = Directory('${flutter.path}/bin/cache');
          intermediate
              .renameSync('${flutter.path}/away')
              .renameSync(intermediate.path);
        },
        () {
          write(
            '$host/bin/.dart_tool/package_config.json',
          ).parent.deleteSync(recursive: true);
        },
        () {
          final bytes = file.readAsBytesSync();
          final mtime = file.lastModifiedSync();
          file.writeAsStringSync('transient');
          file.writeAsBytesSync(bytes);
          file.setLastModifiedSync(mtime);
        },
        () {
          final bytes = file.readAsBytesSync();
          file.deleteSync();
          File(file.path).writeAsBytesSync(bytes);
        },
      ]) {
        final before = await observe();
        await expectLater(observe(GitTestAot.host, mutation), throwsStateError);
        final after = await observe();
        expect(after.digest, isNot(before.digest));
        expect((await observe()).digest, after.digest);
      }
    },
  );
}
