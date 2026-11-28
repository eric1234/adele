import 'dart:convert';
import 'dart:ffi' show Abi;
import 'dart:io';

// Keep the launcher independent of resolved packages.
// ignore: avoid_relative_lib_imports
import '../packages/contract_codegen/lib/src/provenance_files.dart'
    show LinuxPathStat, linuxLstat;
import 'desktop_artifact_cache.dart' show digestJson, hashBuildFiles;
import 'git_test_aot_client.dart' show GitTestAot;

export 'git_test_aot_client.dart' show GitTestAot;

const _compilerEnvironment = {
  'PATH': '/usr/bin:/bin',
  'LC_ALL': 'C',
  'DART_SUPPRESS_ANALYTICS': 'true',
};

/// The launcher can leave unsupported processes entirely on the fresh path,
/// before generation or admission to any scope.
bool get gitTestAotPlatformEligible =>
    Abi.current() == Abi.linuxX64 &&
    !Platform.environment.keys.any(
      (key) =>
          key.startsWith('LD_') ||
          key == 'PACKAGE_CONFIG' ||
          key.startsWith('DART_') && key != 'DART_SUPPRESS_ANALYTICS',
    );

/// One point-in-time observation. Nothing here is a persistent cache key or
/// evidence of generation: the launcher separately verifies provenance.
class GitTestAotInputs {
  GitTestAotInputs._(
    this.root,
    this.recipe,
    this.dartExecutable,
    this.runtimeExecutable,
    this.filePaths,
    this.digest,
  );

  final Directory root;
  final GitTestAot recipe;
  final String dartExecutable;
  final String runtimeExecutable;
  final Set<String> filePaths;
  final String digest;

  File get packageConfig => File('${root.path}/.dart_tool/package_config.json');
  Map<String, String> get environment => _compilerEnvironment;

  List<String> arguments({required File output, required File depfile}) {
    if (!output.isAbsolute ||
        !depfile.isAbsolute ||
        output.uri.pathSegments.last != 'snapshot' ||
        output.path == depfile.path) {
      throw ArgumentError('Expected an absolute private snapshot and depfile.');
    }
    return _arguments(recipe, output.path, depfile.path, packageConfig.path);
  }

  static Future<GitTestAotInputs> capture({
    required Directory repositoryRoot,
    required GitTestAot recipe,
    required String dartExecutable,
    required String runtimeExecutable,
    void Function()? afterInitialStatForTesting,
  }) async {
    if (!gitTestAotPlatformEligible) {
      throw UnsupportedError(
        'Ineligible Git test AOT compiler platform or environment.',
      );
    }
    if (!repositoryRoot.isAbsolute ||
        repositoryRoot.path != repositoryRoot.resolveSymbolicLinksSync()) {
      throw StateError(
        'Expected a canonical checkout root: ${repositoryRoot.path}',
      );
    }
    // Each directory is observed *before* probing a child or enumerating it;
    // each file (including the graph/config) before reading it. Don't start a
    // change fence for the first time after an unobserved discovery pass.
    final inventory = _discover(
      repositoryRoot,
      recipe,
      dartExecutable,
      runtimeExecutable,
    );
    final paths = inventory.observed.keys.toList()..sort();
    final before = inventory.stamps(paths, recheck: false);
    afterInitialStatForTesting?.call();
    final hashes = await hashBuildFiles(inventory.files);
    for (final entry in inventory.stamps(paths, recheck: true).entries) {
      if (before[entry.key] != entry.value) {
        throw StateError(
          'Git test AOT input changed while fingerprinting: ${entry.key}. Retry.',
        );
      }
    }
    final digest = await digestJson({
      'abi': Abi.current().toString(),
      'cwd': repositoryRoot.path,
      'compiler': dartExecutable,
      'runtime': runtimeExecutable,
      'environment': _compilerEnvironment,
      'arguments': _arguments(
        recipe,
        '<private>/snapshot',
        '<depfile>',
        '${repositoryRoot.path}/.dart_tool/package_config.json',
      ),
      'stat': before,
      'sha256': hashes,
    });
    return GitTestAotInputs._(
      repositoryRoot,
      recipe,
      dartExecutable,
      runtimeExecutable,
      Set.unmodifiable(inventory.files),
      digest,
    );
  }
}

List<String> _arguments(
  GitTestAot recipe,
  String output,
  String depfile,
  String config,
) => [
  'compile',
  'aot-snapshot',
  recipe.entrypoint,
  '-o',
  output,
  '--depfile',
  depfile,
  '--packages',
  config,
];

final class _Inventory {
  final files = <String>{};
  final listings = <String>{};
  final observed = <String, LinuxPathStat>{};

  void directory(String path) {
    if (!observed.containsKey(path)) {
      final parent = Directory(path).parent.path;
      if (parent != path) directory(parent);
      final st = linuxLstat(path);
      if (st == null || st.mode & 0xf000 != 0x4000) {
        throw StateError('Missing or linked Git test AOT directory: $path');
      }
      observed[path] = st;
    } else if (files.contains(path)) {
      throw StateError('Ambiguous Git test AOT directory: $path');
    }
  }

  File file(String path, {bool optional = false}) {
    final f = File(path);
    // The parent also fences a transient optional file or replacement.
    directory(f.parent.path);
    if (optional) listings.add(f.parent.path);
    final st = observed[path] ?? linuxLstat(path);
    if (st == null && optional) return f;
    if (st == null || st.mode & 0xf000 != 0x8000 || st.nlink != 1) {
      throw StateError('Missing or linked Git test AOT file: $path');
    }
    observed[path] = st;
    files.add(path);
    return f;
  }

  void absent(String path) {
    directory(File(path).parent.path);
    listings.add(File(path).parent.path);
    if (linuxLstat(path) != null) {
      throw StateError(
        'Unsupported Git test AOT hook or shadow resolution: $path',
      );
    }
  }

  void tree(String path) {
    directory(path);
    listings.add(path);
    for (final entity in Directory(path).listSync(followLinks: false)) {
      if (entity is Directory) {
        tree(entity.path);
      } else {
        file(entity.path);
      }
    }
  }

  void manifest(String path) {
    file('$path/pubspec.yaml');
    file('$path/pubspec_overrides.yaml', optional: true);
    file('$path/pubspec.lock', optional: true);
    absent('$path/hook');
  }

  Map<String, String> stamps(List<String> paths, {required bool recheck}) {
    final result = <String, String>{};
    final anchoredChildren = <String>{};
    for (final path in paths) {
      // Sorted parent first.
      final st = recheck ? linuxLstat(path) : observed[path];
      if (st == null) throw StateError('Git test AOT input disappeared: $path');
      final identity =
          '${st.deviceMajor}:${st.deviceMinor}:${st.inode}:${st.mode}:${st.uid}';
      final isDir = st.mode & 0xf000 == 0x4000;
      // A root-owned directory with no non-root write bits is a trusted system
      // anchor. Don't watch unrelated membership of e.g. /tmp or $HOME unless
      // we list it. User-swappable ancestors do need ctime: renaming a whole
      // subtree away and back need not touch the identity of any descendant.
      if (isDir && st.uid == 0 && st.mode & 0x12 == 0) {
        anchoredChildren.add(path);
      }
      final anchored =
          path == '/' || anchoredChildren.contains(Directory(path).parent.path);
      result[path] = !isDir || !anchored || listings.contains(path)
          ? '$identity:${st.nlink}:${st.size}:${st.ctimeNs}:${st.mtimeNs}'
          : identity;
    }
    return result;
  }
}

Map<String, dynamic> _json(File file) =>
    jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;

_Inventory _discover(
  Directory root,
  GitTestAot recipe,
  String compiler,
  String runtime,
) {
  final inv = _Inventory();
  final configFile = inv.file('${root.path}/.dart_tool/package_config.json');
  final config = _json(configFile);
  if (config['configVersion'] != 2 ||
      config['generator'] != 'pub' ||
      config['generatorVersion'] != '3.10.9' ||
      config['flutterVersion'] != '3.38.10') {
    throw StateError(
      'Git test AOT requires resolution by the pinned Flutter/Dart SDK.',
    );
  }
  final flutter = _directoryUri(Uri.parse(config['flutterRoot'] as String));
  final sdk = '$flutter/bin/cache/dart-sdk';
  if (compiler != '$sdk/bin/dart' || runtime != '$sdk/bin/dartaotruntime') {
    throw StateError(
      'Mismatched Git test AOT compiler/runtime and package resolution.',
    );
  }
  final version = _json(inv.file('$flutter/bin/cache/flutter.version.json'));
  if (version['frameworkVersion'] != '3.38.10' ||
      version['frameworkRevision'] !=
          'c6f67dede3d4aa1aa7a69dd56a3494a5cde6cc80' ||
      version['engineRevision'] != 'cafcda5721a78a7884db92f13c5e89f7643d52dd' ||
      version['dartSdkVersion'] != '3.10.9' ||
      inv.file('$sdk/version').readAsStringSync().trim() != '3.10.9') {
    throw StateError(
      'Unexpected Flutter/Dart compiler version for Git test AOT.',
    );
  }
  for (final name in const [
    'revision',
    'bin/dart',
    'bin/dartaotruntime',
    'bin/dartvm',
    'bin/snapshots/dartdev_aot.dart.snapshot',
    'bin/snapshots/gen_kernel_aot.dart.snapshot',
    'bin/utils/gen_snapshot',
    'lib/libraries.json',
    'lib/_internal/vm_platform.dill',
    'lib/_internal/vm_platform_product.dill',
    'lib/_internal/vm_platform_strong.dill',
  ]) {
    inv.file('$sdk/$name');
  }
  for (final name in const [
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
  ]) {
    inv.file('${root.path}/$name');
  }
  final locations = <String, ({String root, String lib})>{};
  final roots = <String>{};
  for (final p in config['packages'] as List) {
    final name = p['name'] as String;
    final location = _directoryUri(
      configFile.uri.resolve(p['rootUri'] as String),
    );
    final lib = _directoryUri(
      Directory(location).uri.resolve(p['packageUri'] as String),
    );
    if (locations.containsKey(name) ||
        !roots.add(location) ||
        !lib.startsWith('$location/') ||
        p['languageVersion'] is! String) {
      throw FormatException(
        'Ambiguous package location/language version: $name',
      );
    }
    locations[name] = (root: location, lib: lib);
  }
  final graph = _json(inv.file('${root.path}/.dart_tool/package_graph.json'));
  final dependencies = <String, List<String>>{};
  for (final p in graph['packages'] as List) {
    final name = p['name'] as String;
    if (dependencies.containsKey(name)) {
      throw FormatException('Duplicate package in graph: $name');
    }
    dependencies[name] = (p['dependencies'] as List).cast<String>();
  }
  // dartdev on this pin checks hooks from the cwd/root package (NOT the
  // explicit --packages entrypoint). Only our dependency-free cwd qualifies.
  const workspace = 'adele_workspace';
  inv.manifest(root.path);
  if (locations[workspace]?.root != root.path ||
      dependencies[workspace]?.isEmpty != true ||
      !File(
        '${root.path}/pubspec.yaml',
      ).readAsStringSync().startsWith('name: $workspace\n')) {
    throw StateError(
      'Expected the dependency-free workspace package as compiler cwd.',
    );
  }

  final entry = inv.file('${root.path}/${recipe.entrypoint}');
  final owner = recipe.package;
  if (locations[owner]?.root != entry.parent.parent.path) {
    throw StateError('Stock entrypoint does not match resolved owner $owner.');
  }
  // Refuse to override the implicit search made by the ordinary compiler.
  for (var dir = entry.parent; dir.path != root.path; dir = dir.parent) {
    inv.absent('${dir.path}/.packages');
    final dotTool = '${dir.path}/.dart_tool';
    if (linuxLstat(dotTool) != null) {
      inv.absent('$dotTool/package_config.json');
    }
  }
  inv.tree(entry.parent.path);
  final pending = [owner];
  final visited = <String>{};
  final workspaceAncestors = <String>{};
  while (pending.isNotEmpty) {
    final name = pending.removeLast();
    if (!visited.add(name)) continue;
    final p = locations[name];
    final deps = dependencies[name];
    if (p == null || deps == null) {
      throw StateError('Missing resolved Git test package: $name');
    }
    inv.manifest(p.root);
    // Nested workspace membership/overrides (e.g. plugins/git -> backend)
    // are resolution inputs too. Do not walk sibling packages or the host's
    // arbitrary parents above an external package-cache location.
    if (p.root.startsWith('${root.path}/')) {
      for (
        var dir = Directory(p.root).parent;
        dir.path != root.path && workspaceAncestors.add(dir.path);
        dir = dir.parent
      ) {
        for (final name in const [
          'pubspec.yaml',
          'pubspec_overrides.yaml',
          'pubspec.lock',
        ]) {
          inv.file('${dir.path}/$name', optional: true);
        }
      }
    }
    inv.tree(p.lib);
    pending.addAll(deps);
  }
  return inv;
}

String _directoryUri(Uri uri) {
  if (uri.scheme != 'file' ||
      uri.authority.isNotEmpty ||
      uri.hasQuery ||
      uri.hasFragment) {
    throw FormatException('Expected a local Git test AOT input: $uri');
  }
  final path = uri.normalizePath().toFilePath();
  if (path == '/') throw FormatException('Invalid package or SDK root: $uri');
  return path.endsWith('/') ? path.substring(0, path.length - 1) : path;
}
