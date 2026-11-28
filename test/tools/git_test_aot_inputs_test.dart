import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import '../../tools/git_test_aot_inputs.dart';

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
