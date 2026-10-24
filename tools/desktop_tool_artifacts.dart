import 'dart:convert';
import 'dart:ffi' show Abi;
import 'dart:io';

// Keep pre-bootstrap command parsing independent of resolved packages.
// ignore: avoid_relative_lib_imports
import '../packages/plugin_builder/lib/plugin_builder.dart';
import 'desktop_artifact_cache.dart';

const _tools = {
  'contract-codegen-compilation': (
    package: 'contract_codegen',
    entrypoint: 'packages/contract_codegen/bin/contract_codegen.dart',
    sources: 'packages/contract_codegen/bin/',
  ),
  'desktop-inputs-compilation': (
    package: 'adele_workspace',
    entrypoint: 'tools/desktop_build_inputs_worker.dart',
    sources: 'tools/',
  ),
};

/// Two build-time tools, never installed plugins. The caller holds the existing
/// preparation lease and publishes only after the final source/input race fence.
final class DesktopToolArtifacts {
  DesktopToolArtifacts._(this.root, this.cache, this.sdkFiles, this._inputs);

  final Directory root;
  final DesktopArtifactCache cache;
  final List<String> sdkFiles;
  final _ToolInputs _inputs;
  final Map<String, File> _artifacts = {};
  final Map<String, String> _artifactHashes = {};
  final Map<String, Object> _artifactStats = {};

  File get generator => _artifacts['contract-codegen-compilation']!;
  File get discovery => _artifacts['desktop-inputs-compilation']!;

  static Future<DesktopToolArtifacts> prepare({
    required Directory repositoryRoot,
    required DesktopArtifactCache cache,
    required String dartExecutable,
    required List<String> sdkFiles,
    required Object sdkVersion,
  }) async {
    final root = repositoryRoot.absolute;
    final inputs = await _ToolInputs.capture(root, sdkFiles);
    final prepared = DesktopToolArtifacts._(
      root,
      // Same cache/lease/publication machinery, separate component identities:
      // developer-tool changes must not churn installation/deployment paths.
      DesktopArtifactCache(cache.root),
      sdkFiles,
      inputs,
    );
    for (final tool in _tools.entries) {
      final options = [
        'compile',
        'aot-snapshot',
        tool.value.entrypoint,
        '-o',
        '<artifact>',
        '--depfile',
        '<depfile>',
        '--packages',
        File.fromUri(root.uri.resolve('.dart_tool/package_config.json')).path,
      ];
      late String verifiedDigest;
      final artifact = await prepared.cache.component(
        name: tool.key,
        identity: await digestJson({
          'version': 1,
          'platform': '${Platform.operatingSystem}/${Abi.current()}',
          'sdk': sdkVersion,
          'options': options,
          'inputs': {
            for (final path in inputs.sources[tool.key]!)
              path: inputs.hashes[path],
          },
        }),
        filename: 'tool.aot',
        onValidated: (digest) => verifiedDigest = digest,
        build: (output) async {
          // A depfile is a cold-build coverage check, not a cached source graph.
          // Keep it outside the sealed, single-artifact component directory.
          final scratch = await prepared.cache.stage();
          final depfile = File.fromUri(scratch.uri.resolve('tool.d'));
          await compileAotSnapshot(
            dartExecutable: dartExecutable,
            workingDirectory: root,
            entrypoint: tool.value.entrypoint,
            artifact: output,
            stage: tool.key,
            depfile: depfile,
            packageConfig: File.fromUri(
              root.uri.resolve('.dart_tool/package_config.json'),
            ),
            onDiagnostic: (diagnostic) {
              stdout.write(diagnostic.stdoutText);
              stderr.write(diagnostic.stderrText);
            },
          );
          validateToolDepfile(
            await depfile.readAsString(),
            output: output,
            root: root,
            inputs: inputs.sources[tool.key]!.toSet(),
          );
        },
      );
      prepared._artifacts[tool.key] = artifact;
      prepared._artifactHashes[artifact.path] = verifiedDigest;
      prepared._artifactStats.addAll(await buildInputStats([artifact.path]));
    }
    await prepared.validate();
    return prepared;
  }

  Future<void> validate() async {
    await validateArtifacts();
    final current = await _ToolInputs.capture(root, sdkFiles);
    if (jsonEncode(_inputs.sources) != jsonEncode(current.sources) ||
        jsonEncode(_inputs.hashes) != jsonEncode(current.hashes) ||
        jsonEncode(_inputs.stats) != jsonEncode(current.stats)) {
      final changed = {..._inputs.stats.keys, ...current.stats.keys}.where(
        (path) =>
            jsonEncode(_inputs.stats[path]) != jsonEncode(current.stats[path]),
      );
      throw PluginBuildFailure(
        'Build tool inputs or artifacts changed during desktop preparation. Retry.'
        '${changed.isEmpty ? '' : ' Changed inputs: ${changed.take(3).join(', ')}'}',
      );
    }
  }

  Future<void> validateArtifacts() async {
    final hashes = await hashBuildFiles(_artifactHashes.keys);
    final stats = await buildInputStats(_artifactHashes.keys);
    if (_artifactHashes.entries.any(
          (entry) => hashes[entry.key] != entry.value,
        ) ||
        _artifactStats.entries.any(
          (entry) => jsonEncode(stats[entry.key]) != jsonEncode(entry.value),
        )) {
      throw const PluginBuildFailure(
        'Build tool inputs or artifacts changed during desktop preparation. Retry.',
      );
    }
  }
}

final class _ToolInputs {
  _ToolInputs(this.sources, this.hashes, this.stats);

  final Map<String, List<String>> sources;
  final Map<String, String> hashes;
  final Map<String, Object> stats;

  static Future<_ToolInputs> capture(
    Directory root,
    List<String> sdkFiles,
  ) async {
    final watched = <String>{};
    final common = <String>{...sdkFiles};
    void file(Uri uri, Set<String> files, {bool optional = false}) {
      final path = File.fromUri(uri.normalizePath()).absolute.path;
      watched.add(path);
      if (optional &&
          FileSystemEntity.typeSync(path) == FileSystemEntityType.notFound) {
        return;
      }
      if (!File(path).existsSync()) {
        throw PluginBuildFailure(
          'Missing build tool input: $path. Run bootstrap.',
        );
      }
      files.add(path);
    }

    void configuration(Directory directory, Set<String> files) {
      watched.add(directory.path);
      file(directory.uri.resolve('pubspec.yaml'), files);
      for (final name in ['pubspec_overrides.yaml', 'pubspec.lock']) {
        file(directory.uri.resolve(name), files, optional: true);
      }
    }

    void tree(
      Directory directory,
      Set<String> files, [
      Set<String> ancestors = const {},
    ]) {
      watched.add(directory.path);
      // Some pure metadata packages (for example lints) have no library tree.
      if (FileSystemEntity.typeSync(directory.path) ==
          FileSystemEntityType.notFound) {
        return;
      }
      final real = directory.resolveSymbolicLinksSync();
      watched.add(real);
      if (ancestors.contains(real)) {
        throw PluginBuildFailure('Cyclic build tool input: ${directory.path}');
      }
      for (final entry in directory.listSync(followLinks: false)) {
        final type = FileSystemEntity.typeSync(entry.path);
        if (type == FileSystemEntityType.directory) {
          tree(Directory(entry.path), files, {...ancestors, real});
        } else if (type == FileSystemEntityType.file) {
          file(entry.uri, files);
        } else {
          throw PluginBuildFailure(
            'Unreadable build tool input: ${entry.path}',
          );
        }
      }
    }

    configuration(root, common);
    for (final path in [
      '.dart_tool/package_config.json',
      '.dart_tool/package_graph.json',
      'tools/desktop_tool_artifacts.dart',
      'tools/desktop_artifact_cache.dart',
      'packages/plugin_builder/lib/src/development_plugin_builder.dart',
    ]) {
      file(root.uri.resolve(path), common);
    }
    final configFile = File.fromUri(
      root.uri.resolve('.dart_tool/package_config.json'),
    );
    // Flutter may create unrelated caches here during frontend compilation.
    // The required resolution files themselves are content/stat checked.
    final config =
        jsonDecode(configFile.readAsStringSync()) as Map<String, dynamic>;
    final graph =
        jsonDecode(
              File.fromUri(
                root.uri.resolve('.dart_tool/package_graph.json'),
              ).readAsStringSync(),
            )
            as Map<String, dynamic>;
    if (config['configVersion'] != 2) {
      throw const FormatException('Invalid tool package configuration.');
    }
    final locations = <String, ({Directory root, Directory library})>{};
    for (final entry in config['packages'] as List) {
      final packageRoot = Directory.fromUri(
        configFile.uri.resolve(entry['rootUri'] as String),
      );
      final library = packageRoot.uri.resolve(
        entry['packageUri'] as String? ?? '',
      );
      final name = entry['name'] as String;
      if (name.isEmpty ||
          locations.containsKey(name) ||
          library.scheme != 'file' ||
          library.hasQuery ||
          library.hasFragment) {
        throw const FormatException('Invalid tool package location.');
      }
      locations[name] = (
        root: packageRoot,
        library: Directory.fromUri(library),
      );
    }
    final dependencies = <String, Map<String, dynamic>>{};
    for (final entry in graph['packages'] as List) {
      final name = entry['name'] as String;
      if (dependencies.containsKey(name)) {
        throw const FormatException('Duplicate tool package.');
      }
      dependencies[name] = entry as Map<String, dynamic>;
    }
    final sources = <String, List<String>>{};
    for (final tool in _tools.entries) {
      final files = {...common};
      final pending = [tool.value.package];
      final seen = <String>{};
      while (pending.isNotEmpty) {
        final name = pending.removeLast();
        if (!seen.add(name)) continue;
        final location = locations[name];
        final dependency = dependencies[name];
        if (location == null || dependency == null) {
          throw PluginBuildFailure(
            'Missing tool package $name. Run bootstrap.',
          );
        }
        configuration(location.root, files);
        tree(location.library, files);
        pending.addAll((dependency['dependencies'] as List).cast<String>());
        if (name == 'adele_workspace') {
          pending.addAll(
            (dependency['devDependencies'] as List).cast<String>(),
          );
        }
      }
      tree(Directory.fromUri(root.uri.resolve(tool.value.sources)), files);
      file(root.uri.resolve(tool.value.entrypoint), files);
      sources[tool.key] = files.toList()..sort();
    }
    final files = sources.values.expand((paths) => paths).toSet();
    final stats = await buildInputStats({...watched, ...files});
    final hashes = await hashBuildFiles(files);
    // Do not capture a hybrid package/source tree if it changed while reading.
    if (jsonEncode(stats) !=
        jsonEncode(await buildInputStats({...watched, ...files}))) {
      throw const PluginBuildFailure(
        'Build tool inputs changed while fingerprinting. Retry.',
      );
    }
    return _ToolInputs(sources, hashes, stats);
  }
}

/// The pinned Dart compiler emits one Make-style rule with backslash-escaped
/// paths. Reject uncovered imports rather than publishing a partially keyed tool.
void validateToolDepfile(
  String content, {
  required File output,
  required Directory root,
  required Set<String> inputs,
}) {
  final tokens = <String>[];
  var token = StringBuffer();
  var escaped = false;
  for (final code in content.codeUnits) {
    if (escaped) {
      if (code != 10) token.writeCharCode(code);
      escaped = false;
    } else if (code == 92) {
      escaped = true;
    } else if (code == 32 || code == 10 || code == 13 || code == 9) {
      if (token.isNotEmpty) tokens.add(token.toString());
      token = StringBuffer();
    } else {
      token.writeCharCode(code);
    }
  }
  if (token.isNotEmpty) tokens.add(token.toString());
  if (escaped ||
      tokens.length < 2 ||
      tokens.first != '${output.absolute.path}:') {
    throw const PluginBuildFailure('Invalid build tool compiler depfile.');
  }
  for (final path in tokens.skip(1)) {
    final absolute = File.fromUri(
      root.uri.resolveUri(Uri.file(path)).normalizePath(),
    ).path;
    if (!inputs.contains(absolute)) {
      throw PluginBuildFailure(
        'Uncovered build tool compiler input: $absolute. '
        'Run bootstrap after dependency changes; tool imports must stay within '
        'their resolved package library and tooling source trees.',
      );
    }
  }
}
