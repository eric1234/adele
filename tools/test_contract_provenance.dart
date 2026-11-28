import 'dart:convert';
import 'dart:io';

// Keep the launcher loadable before package resolution.
// ignore: avoid_relative_lib_imports
import '../packages/contract_codegen/lib/src/provenance_files.dart';
import 'contract_artifacts.dart';
import 'desktop_artifact_cache.dart' show hashBuildFiles;
import 'desktop_tool_artifacts.dart' show validateToolDepfile;
import 'git_test_aot_inputs.dart' show gitTestAotPlatformEligible;

/// This capability is constructed only from a private successful generation.
/// No checked-in, incremental, or worker-supplied receipt is admission proof.
final class TestContractProvenance {
  TestContractProvenance._(this._generator, this._hashes, this._outputs);

  final ProvenanceFiles _generator;
  final Map<String, String> _hashes;
  final Map<String, ProvenanceFiles> _outputs;

  /// Bind every generated part in the actual requested compiler superset.
  /// Unconfigured, newly introduced or unsupported parts cannot be certified.
  Future<void> verify(Set<String> filePaths) async {
    final files = ProvenanceFiles()..merge(_generator.stamps);
    final reads = {..._generator.reads};
    for (final entry in _outputs.entries) {
      // Deleting both a configured source and its output cannot make the
      // proof disappear by removing them from a later compiler inventory.
      for (final path in [
        entry.key,
        '${entry.key.substring(0, entry.key.length - 7)}.dart',
      ]) {
        files.merge({path: entry.value.stamps[path]!});
        reads.add(path);
      }
    }
    final requiredOutputs = {
      ...filePaths.where((p) => p.endsWith('.g.dart')),
      for (final output in _outputs.keys)
        if (filePaths.contains(
          '${output.substring(0, output.length - 7)}.dart',
        ))
          output,
    };
    for (final path in requiredOutputs) {
      final proof = _outputs[path];
      if (proof == null) {
        throw StateError('Unproven generated test input: $path');
      }
      files.merge(proof.stamps);
      reads.addAll(proof.reads);
    }
    files.verify();
    final current = await hashBuildFiles(reads);
    for (final path in reads) {
      if (current[path] != _hashes[path]) {
        throw StateError(
          'Contract generation input changed; restart maintained preparation: $path',
        );
      }
    }
    files.verify();
  }
}

/// Always runs full configured generation. Only a resolved pinned Linux
/// checkout is eligible for the additional, invocation-local test evidence.
Future<TestContractProvenance?> runTestContractCodegen({
  required Directory repositoryRoot,
}) async {
  final timer = Stopwatch()..start();
  try {
    return await _generate(repositoryRoot);
  } finally {
    stdout.writeln(
      'contract-provenance: full preparation ${timer.elapsedMicroseconds} us',
    );
  }
}

Future<TestContractProvenance?> _generate(Directory repositoryRoot) async {
  final root = Directory(repositoryRoot.resolveSymbolicLinksSync());
  Future<TestContractProvenance?> ordinary(String reason) async {
    stdout.writeln(
      'contract-provenance: $reason; using ordinary generation without sharing.',
    );
    await runContractCodegen(repositoryRoot: root);
    return null;
  }

  final config = File('${root.path}/.dart_tool/package_config.json');
  final graph = File('${root.path}/.dart_tool/package_graph.json');
  final tempRoot = Directory.systemTemp.resolveSymbolicLinksSync();
  if (root.path == tempRoot || root.path.startsWith('$tempRoot/')) {
    return ordinary('checkout inside mutable system temp');
  }
  final entry = File(
    '${root.path}/packages/contract_codegen/bin/contract_codegen.dart',
  );
  if (!gitTestAotPlatformEligible ||
      !config.existsSync() ||
      !graph.existsSync() ||
      !entry.existsSync()) {
    return ordinary('no eligible resolved Linux checkout');
  }
  final files = ProvenanceFiles();
  files.watch(config.path, read: true);
  files.watch(graph.path, read: true);
  final resolution = jsonDecode(config.readAsStringSync()) as Map;
  if (resolution['generatorVersion'] != '3.10.9' ||
      resolution['flutterVersion'] != '3.38.10') {
    return ordinary('unexpected workspace SDK');
  }
  final sdk = Directory.fromUri(
    Uri.parse(resolution['flutterRoot'] as String),
  ).uri.resolve('bin/cache/dart-sdk/');
  String sdkPath(String relative) => File.fromUri(sdk.resolve(relative)).path;
  bool matchedVm(Object? exe) =>
      exe == sdkPath('bin/dart') || exe == sdkPath('bin/dartvm');
  if (!matchedVm(Platform.resolvedExecutable)) {
    return ordinary('launcher SDK mismatch');
  }
  // Flutter creates this immediate child on the first native-assets build.
  // Establish the empty parent before taking the generation fence on a cold
  // resolved checkout. No hook runs and no hook outputs are reused here.
  final hooks = Directory('${config.parent.path}/hooks_runner');
  if (FileSystemEntity.typeSync(hooks.path, followLinks: false) ==
      FileSystemEntityType.notFound) {
    if (config.parent.resolveSymbolicLinksSync() != config.parent.path) {
      return ordinary('noncanonical workspace resolution');
    }
    hooks.createSync();
    // Discard the pre-creation observation, including decoded configuration.
    return _generate(root);
  }
  if (hooks.resolveSymbolicLinksSync() != hooks.path) {
    return ordinary('noncanonical Flutter hooks directory');
  }
  final packages = {
    for (final e in resolution['packages'] as List)
      e['name'] as String: e as Map,
  };
  final graphData = jsonDecode(graph.readAsStringSync()) as Map;
  final deps = {
    for (final e in graphData['packages'] as List)
      e['name'] as String: (e['dependencies'] as List).cast<String>(),
  };
  Set<String> closure(List<String> pending) {
    final seen = <String>{};
    while (pending.isNotEmpty) {
      final name = pending.removeLast();
      if (seen.add(name)) pending.addAll(deps[name]!);
    }
    return seen;
  }

  Directory location(String name) => Directory.fromUri(
    config.uri.resolve(packages[name]!['rootUri'] as String),
  );
  Directory library(String name) => Directory.fromUri(
    location(name).uri.resolve(packages[name]!['packageUri'] as String),
  );
  void tree(Directory dir) {
    files.watch(dir.path, listing: true);
    if (!dir.existsSync()) return;
    for (final entity in dir.listSync(followLinks: false)) {
      if (entity is Directory) {
        tree(entity);
      } else if (entity is Link || entity.path.endsWith('.dart')) {
        files.watch(entity.path, read: true);
      }
    }
  }

  void absent(String path) {
    files.watch(path);
    if (files.stamps[path] != 'missing') {
      throw UnsupportedError('shadow resolution or hook at $path');
    }
  }

  final common = <String>{};
  try {
    for (var dir = entry.parent; dir.path != root.path; dir = dir.parent) {
      absent('${dir.path}/.packages');
      absent('${dir.path}/.dart_tool/package_config.json');
    }
    absent('${root.path}/.packages');
    absent('${root.path}/hook');
    if (location('adele_workspace').resolveSymbolicLinksSync() != root.path ||
        deps['adele_workspace']?.isEmpty != true) {
      return ordinary('nonstandard generator cwd');
    }
    for (final path in [
      'pubspec.yaml',
      'pubspec_overrides.yaml',
      'pubspec.lock',
      'contract_codegen.yaml',
      'tools/test_contract_provenance.dart',
      'tools/contract_artifacts.dart',
      'tools/desktop_tool_artifacts.dart',
      'tools/desktop_artifact_cache.dart',
    ]) {
      files.watch('${root.path}/$path', read: true);
    }
    for (final path in [
      'bin/dart',
      'bin/dartvm',
      'bin/dartaotruntime',
      'bin/snapshots/dartdev_aot.dart.snapshot',
      'bin/snapshots/kernel-service.dart.snapshot',
      'lib/_internal/vm_platform_strong.dill',
      'lib/_internal/vm_platform.dill',
      'version',
      'revision',
    ]) {
      files.watch(sdkPath(path), read: true);
    }
    final owners = closure(['contract_codegen']);
    for (final name in owners) {
      absent(Directory.fromUri(location(name).uri.resolve('hook')).path);
      files.watch(
        File.fromUri(location(name).uri.resolve('pubspec.yaml')).path,
        read: true,
      );
    }
    common.addAll(files.reads);
    for (final name in owners) {
      tree(library(name));
    }
    tree(entry.parent);
  } on UnsupportedError catch (error) {
    return ordinary(error.toString());
  }
  final baseline = await hashBuildFiles(files.reads);
  files.verify();

  final temp = await Process.run('/usr/bin/mktemp', [
    '-d',
    '${Directory.systemTemp.path}/adele-gen.XXXXXXXX',
  ]);
  if (temp.exitCode != 0) {
    throw StateError(
      'Cannot create private generation directory: ${temp.stderr}',
    );
  }
  final scratch = Directory((temp.stdout as String).trim());
  try {
    final proof = File('${scratch.path}/proof.json');
    final depfile = File('${scratch.path}/generator.d');
    final libraries = closure([
      'plugin_backend_host',
      'git_backend',
    ]).map((name) => library(name).path).toList();
    File(
      '${scratch.path}/libraries.json',
    ).writeAsStringSync(jsonEncode(libraries));
    await runContractCodegen(
      repositoryRoot: root,
      vmOptions: [
        '--depfile=${depfile.path}',
        '--depfile-output-filename=${proof.path}',
      ],
      options: ['--test-provenance', scratch.path],
    );
    final actual = validateToolDepfile(
      depfile.readAsStringSync(),
      output: proof,
      root: root,
      inputs: files.reads,
      requiredInputs: {entry.path},
    );
    files.verify();
    // Keep the complete pre-observed membership/change fence, but only hash
    // source bytes loaded by this VM, not every unrelated analyzer library.
    files.reads.retainAll({...actual, ...common});
    if (!proof.existsSync()) {
      stdout.writeln(
        'contract-provenance: unsupported analyzer discovery; no sharing.',
      );
      return null;
    }
    final decoded = jsonDecode(proof.readAsStringSync()) as Map;
    if (!matchedVm(decoded['executable']) ||
        decoded['packageConfig'] != config.uri.toString()) {
      stdout.writeln(
        'contract-provenance: generator SDK/config does not match workspace resolution; no sharing.',
      );
      return null;
    }
    final outputs = <String, ProvenanceFiles>{};
    for (final e in (decoded['outputs'] as Map<String, dynamic>).entries) {
      outputs[e.key] = ProvenanceFiles()
        ..merge((e.value['stamps'] as Map).cast<String, String>())
        ..reads.addAll((e.value['reads'] as List).cast<String>());
    }
    final observed = (decoded['hashes'] as Map).cast<String, String>();
    for (final path in observed.keys) {
      if (baseline.containsKey(path) && baseline[path] != observed[path]) {
        throw StateError('Generator and analyzer read different bytes: $path');
      }
    }
    final resultProof = TestContractProvenance._(files, {
      ...baseline,
      ...observed,
    }, outputs);
    await resultProof.verify(outputs.keys.toSet());
    return resultProof;
  } finally {
    await scratch.delete(recursive: true);
  }
}
