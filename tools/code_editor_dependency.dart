import 'dart:convert';
import 'dart:ffi' show Abi;
import 'dart:io';

const _metadataPath = 'third_party/code_forge/preparation.json';
const _sourcePath = '.adele/dependencies/code_forge';
const _stateName = '.adele-preparation.json';
final _activeLocks = <String>{};

/// Prepares source only: no pub resolution, Flutter, Rust, or Cargo invocation.
/// Existing checkouts are only verified unless [reprepare] is explicitly set.
/// Use [withCodeEditorSource] to keep the lease while consuming the source.
Future<Directory> prepareCodeEditorSource(
  Directory repository, {
  File? archive,
  bool reprepare = false,
}) => _locked(
  repository,
  'source',
  () => _prepareCodeEditorSource(
    repository,
    archive: archive,
    reprepare: reprepare,
  ),
);

/// Holds the preparation lease through [consume], preventing replacement.
/// Nested preparation or consumption refuses admission rather than reentering.
Future<T> withCodeEditorSource<T>(
  Directory repository,
  Future<T> Function(Directory source) consume, {
  File? archive,
}) => _locked(repository, 'source', () async {
  final source = await _prepareCodeEditorSource(repository, archive: archive);
  return consume(source);
});

Future<Directory> _prepareCodeEditorSource(
  Directory repository, {
  File? archive,
  bool reprepare = false,
  bool verifyOnly = false,
}) async {
  repository = repository.absolute;
  final metadata = File('${repository.path}/$_metadataPath');
  final metadataText = await metadata.readAsString();
  final config = jsonDecode(metadataText) as Map<String, dynamic>;
  if (config['schema'] != 1 || config['package'] != 'code_forge') {
    throw StateError('Unsupported CodeForge preparation manifest.');
  }
  final patches = (config['patches'] as List).cast<String>();
  final assets = (config['materializedAssets'] as List? ?? const [])
      .map((value) => Map<String, dynamic>.from(value as Map))
      .toList();
  for (final asset in assets) {
    _validateRelativePath(asset['target'] as String);
    if (!(asset['target'] as String).startsWith('assets/adele/')) {
      throw StateError(
        'CodeForge notice assets must stay under assets/adele/.',
      );
    }
  }
  final inputs = <String>[
    _metadataPath,
    'tools/code_editor_dependency.dart',
    'third_party/code_forge/${config['runnerLock']}',
    for (final path in patches) 'third_party/code_forge/$path',
    for (final asset in assets) asset['source'] as String,
  ];
  for (final path in inputs) {
    _validateRelativePath(path);
  }
  final source = Directory('${repository.path}/$_sourcePath');
  final inputHashes = await _hashFiles(repository, inputs);
  final runnerTemplate = await File(
    '${repository.path}/third_party/code_forge/${config['runnerLock']}',
  ).readAsString();
  if (await metadata.readAsString() != metadataText) {
    throw StateError('CodeForge preparation manifest changed. Retry.');
  }
  final identity = await _hashBytes(
    utf8.encode(
      jsonEncode({
        'inputs': inputHashes,
        // The runner's enforced path dependency is specific to this checkout.
        'source': source.path,
      }),
    ),
  );
  if (verifyOnly ||
      (!reprepare &&
          await FileSystemEntity.type(source.path, followLinks: false) !=
              FileSystemEntityType.notFound)) {
    await _verifySource(
      source,
      identity,
      treeHash: config['preparedTreeSha256'] as String,
      runnerTemplate: runnerTemplate,
    );
    return source;
  }
  // A killed process can leave a stage, but never a partially published tree.
  for (final entry in source.parent.listSync(followLinks: false)) {
    if (entry is Directory &&
        entry.uri.pathSegments
            .where((s) => s.isNotEmpty)
            .last
            .startsWith('.code_forge-stage-')) {
      await entry.delete(recursive: true);
    }
  }
  final stage = await source.parent.createTemp('.code_forge-stage-');
  try {
    final inputArchive =
        archive?.absolute ?? File('${stage.path}/archive.tar.gz');
    if (archive == null) {
      await _run('curl', [
        '--fail',
        '--location',
        '--retry',
        '2',
        '--connect-timeout',
        '30',
        '--max-time',
        '300',
        '--output',
        inputArchive.path,
        config['archiveUrl'] as String,
      ]);
    }
    if (await _hashFile(inputArchive) != config['archiveSha256']) {
      throw StateError('CodeForge archive checksum mismatch.');
    }
    final listing = await _run('tar', ['-tzf', inputArchive.path]);
    for (final path in const LineSplitter().convert(listing.stdout as String)) {
      final normalized = path.startsWith('./') ? path.substring(2) : path;
      if (normalized.isNotEmpty) _validateRelativePath(normalized);
    }
    final unpacked = Directory('${stage.path}/source')..createSync();
    await _run('tar', [
      '--same-permissions',
      '-xzf',
      inputArchive.path,
      '-C',
      unpacked.path,
    ]);
    // Reject source symlinks, including ones pointing outside the checkout.
    await _sourceManifest(unpacked);
    for (final patch in patches) {
      await _run(
        'git',
        [
          'apply',
          '--recount',
          '--whitespace=nowarn',
          '${repository.path}/third_party/code_forge/$patch',
        ],
        cwd: unpacked.path,
        // Parent-worktree discovery makes git apply silently skip paths in
        // the ignored dependency tree. Apply as a standalone source tree.
        environment: {
          for (final entry in Platform.environment.entries)
            if (!entry.key.startsWith('GIT_')) entry.key: entry.value,
          'GIT_CEILING_DIRECTORIES': unpacked.parent.path,
        },
        includeParentEnvironment: false,
      );
    }
    for (final asset in assets) {
      final target = File('${unpacked.path}/${asset['target']}');
      if (await target.exists()) {
        throw StateError(
          'Notice materialization would overwrite upstream source.',
        );
      }
      await target.parent.create(recursive: true);
      await File('${repository.path}/${asset['source']}').copy(target.path);
    }
    final runner = File('${unpacked.path}/cargokit/build_tool/runner.lock');
    runner.parent.createSync(recursive: true);
    await runner.writeAsString(
      runnerTemplate.replaceAll(
        '"@CODEFORGE_BUILD_TOOL@"',
        jsonEncode('${source.path}/cargokit/build_tool'),
      ),
    );
    final pubspec = await File('${unpacked.path}/pubspec.yaml').readAsString();
    final dartBindings = await File(
      '${unpacked.path}/lib/src/rust/frb_generated.dart',
    ).readAsString();
    final rustBindings = await File(
      '${unpacked.path}/rust/src/frb_generated.rs',
    ).readAsString();
    final bridge = config['flutterRustBridge'] as String;
    final bindingHash = config['generatedBindingHash'] as int;
    if (!RegExp(
          '^version: ${RegExp.escape(config['version'] as String)}\$',
          multiLine: true,
        ).hasMatch(pubspec) ||
        !RegExp(
          '^  flutter_rust_bridge: ${RegExp.escape(bridge)}\$',
          multiLine: true,
        ).hasMatch(pubspec) ||
        !dartBindings.contains("String get codegenVersion => '$bridge';") ||
        !dartBindings.contains('int get rustContentHash => $bindingHash;') ||
        !rustBindings.contains(
          'FLUTTER_RUST_BRIDGE_CODEGEN_VERSION: &str = "$bridge";',
        ) ||
        !rustBindings.contains(
          'FLUTTER_RUST_BRIDGE_CODEGEN_CONTENT_HASH: i32 = $bindingHash;',
        )) {
      throw StateError(
        'Prepared CodeForge version or FRB binding identity does not match the manifest.',
      );
    }
    final files = await _sourceManifest(unpacked);
    await _verifyTree(
      unpacked,
      source,
      files,
      treeHash: config['preparedTreeSha256'] as String,
      runnerTemplate: runnerTemplate,
    );
    if (jsonEncode(await _hashFiles(repository, inputs)) !=
        jsonEncode(inputHashes)) {
      throw StateError(
        'CodeForge preparation inputs changed during preparation. Retry.',
      );
    }
    await File('${unpacked.path}/$_stateName').writeAsString(
      jsonEncode({'identity': identity, 'files': files}),
      flush: true,
    );
    // Nothing in the existing checkout is touched until every fresh input and
    // the tracked expected tree have been verified under the source lease.
    final existingType = await FileSystemEntity.type(
      source.path,
      followLinks: false,
    );
    if (existingType == FileSystemEntityType.notFound) {
      await unpacked.rename(source.path);
    } else {
      if (!reprepare) {
        throw StateError(
          'CodeForge checkout appeared during preparation. '
          'Refusing to replace it without --reprepare.',
        );
      }
      final existing = switch (existingType) {
        FileSystemEntityType.directory => source,
        FileSystemEntityType.file => File(source.path),
        FileSystemEntityType.link => Link(source.path),
        _ => throw StateError('Invalid CodeForge checkout: ${source.path}'),
      };
      final backup = await source.parent.createTemp('.code_forge-backup-');
      var retainBackup = false;
      try {
        final previous = await existing.rename('${backup.path}/source');
        try {
          await unpacked.rename(source.path);
        } catch (publishError) {
          try {
            await previous.rename(source.path);
          } catch (rollbackError) {
            // Keep this outside disposable staging, including on later runs.
            retainBackup = true;
            throw StateError(
              'CodeForge publication failed: $publishError; '
              'rollback failed: $rollbackError. Previous checkout retained at '
              '${previous.path}. No fallback was used.',
            );
          }
          rethrow;
        }
      } finally {
        if (!retainBackup) await backup.delete(recursive: true);
      }
    }
    stdout.writeln('Prepared CodeForge ${config['version']}: ${source.path}');
    return source;
  } finally {
    if (await stage.exists()) await stage.delete(recursive: true);
  }
}

/// Builds the exact locked native crate for direct Flutter tests, not packaging.
/// Flutter desktop builds use the prepared package's pinned Cargokit hooks.
Future<Directory> buildNativeCodeEditorForTests(Directory repository) async {
  if (Abi.current() != Abi.linuxX64) {
    throw UnsupportedError(
      'Native CodeForge tests currently support Linux x64 only.',
    );
  }
  const triple = 'x86_64-unknown-linux-gnu';
  return withCodeEditorSource(repository, (source) async {
    final config =
        jsonDecode(
              await File('${repository.path}/$_metadataPath').readAsString(),
            )
            as Map<String, dynamic>;
    final state =
        jsonDecode(await File('${source.path}/$_stateName').readAsString())
            as Map<String, dynamic>;
    final target = Directory(
      '${source.parent.path}/code_forge-native/${state['identity']}',
    );
    return _locked(repository, 'native', () async {
      await _run(
        'rustup',
        [
          'run',
          config['rust'] as String,
          'cargo',
          'build',
          '--locked',
          '--release',
          '--manifest-path',
          '${source.path}/rust/Cargo.toml',
          '--target-dir',
          target.path,
          '--target',
          triple,
        ],
        environment: {'RUST_MIN_STACK': '16777216'},
      );
      final library = File('${target.path}/$triple/release/libcode_forge.so');
      if (!await library.exists() || await library.length() == 0) {
        throw StateError(
          'CodeForge native build produced no library: ${library.path}',
        );
      }
      // Recheck current inputs and source without reentering the held lease or
      // repairing a checkout removed by a nonparticipating consumer.
      await _prepareCodeEditorSource(repository, verifyOnly: true);
      return library.parent;
    });
  });
}

Future<void> _verifySource(
  Directory source,
  String identity, {
  required String treeHash,
  required String runnerTemplate,
}) async {
  const recovery =
      'Stop all consumers, then run dart tools/adele.dart '
      'prepare-code-editor --reprepare. No fallback was used.';
  if (await FileSystemEntity.type(source.path, followLinks: false) !=
      FileSystemEntityType.directory) {
    throw StateError('Invalid CodeForge checkout. $recovery');
  }
  try {
    final state =
        jsonDecode(await File('${source.path}/$_stateName').readAsString())
            as Map<String, dynamic>;
    if (state['identity'] != identity) {
      throw StateError('Preparation inputs changed.');
    }
    final expected = (state['files'] as Map).cast<String, String>();
    final actual = await _sourceManifest(
      source,
      expected: expected.keys.toSet(),
    );
    if (expected.isEmpty || jsonEncode(actual) != jsonEncode(expected)) {
      throw StateError('Immutable source content changed.');
    }
    await _verifyTree(
      source,
      source,
      actual,
      treeHash: treeHash,
      runnerTemplate: runnerTemplate,
    );
  } catch (error) {
    throw StateError('Stale or altered CodeForge checkout: $error $recovery');
  }
}

Future<void> _verifyTree(
  Directory current,
  Directory published,
  Map<String, String> files, {
  required String treeHash,
  required String runnerTemplate,
}) async {
  const runnerPath = 'cargokit/build_tool/runner.lock';
  final expectedRunner = runnerTemplate.replaceAll(
    '"@CODEFORGE_BUILD_TOOL@"',
    jsonEncode('${published.path}/cargokit/build_tool'),
  );
  if (await File('${current.path}/$runnerPath').readAsString() !=
      expectedRunner) {
    throw StateError(
      'CodeForge runner lock does not match the tracked template.',
    );
  }
  // The tracked tree digest, not this writable checkout's ledger, is authority.
  // Normalize only the runner's absolute path so the anchor is checkout-portable.
  final normalized = {...files};
  normalized[runnerPath] =
      '${await _hashBytes(utf8.encode(runnerTemplate))}:${files[runnerPath]!.split(':').last}';
  final canonical = {
    for (final path in normalized.keys.toList()..sort()) path: normalized[path],
  };
  final actual = await _hashBytes(utf8.encode(jsonEncode(canonical)));
  if (actual != treeHash) {
    throw StateError(
      'CodeForge prepared tree checksum mismatch: '
      'expected $treeHash, actual $actual. Review archive and ordered patches; '
      'never update the tracked digest from an unverified cache.',
    );
  }
}

Future<Map<String, String>> _sourceManifest(
  Directory source, {
  Set<String>? expected,
}) async {
  final files = <String>[];
  Future<void> visit(Directory directory) async {
    await for (final entry in directory.list(followLinks: false)) {
      final path = entry.path
          .substring(source.path.length + 1)
          .replaceAll('\\', '/');
      _validateRelativePath(path);
      if (path == _stateName) continue;
      if (expected != null &&
          !expected.any((file) => file == path || file.startsWith('$path/')) &&
          _buildGenerated(path)) {
        continue;
      }
      if (entry is Directory) {
        await visit(entry);
      } else if (entry is File) {
        files.add(path);
      } else {
        throw StateError('Unexpected CodeForge source entry: $path');
      }
    }
  }

  await visit(source);
  return _hashFiles(source, files..sort());
}

// Only disposable build outputs may appear after preparation. Files present in
// the archive (including Cargo.lock and build_tool/pubspec.lock) stay immutable.
bool _buildGenerated(String path) =>
    const [
      '.dart_tool',
      'build',
      'rust/target',
      'cargokit/build_tool/.dart_tool',
      'cargokit/build_tool/build',
    ].any((prefix) => path == prefix || path.startsWith('$prefix/')) ||
    const [
      'pubspec.lock',
      '.flutter-plugins',
      '.flutter-plugins-dependencies',
    ].contains(path);

Future<T> _locked<T>(
  Directory repository,
  String name,
  Future<T> Function() action,
) async {
  // Canonicalize admission so path aliases cannot reenter a process-owned lock.
  repository = Directory(await repository.resolveSymbolicLinks());
  final lock = File(
    '${repository.absolute.path}/.adele/dependencies/code_forge-$name.lock',
  );
  if (!_activeLocks.add(lock.path)) {
    throw StateError(
      'CodeForge $name preparation is busy; retry after the other operation exits.',
    );
  }
  RandomAccessFile? handle;
  try {
    await lock.parent.create(recursive: true);
    handle = await lock.open(mode: FileMode.append);
    // OS locks are released even on process death. Nonblocking admission also
    // avoids an unbounded wait behind a stalled download or compiler.
    try {
      await handle.lock(FileLock.exclusive);
    } on FileSystemException {
      throw StateError(
        'CodeForge $name preparation is busy; retry after the other process exits.',
      );
    }
    return await action();
  } finally {
    await handle?.close();
    _activeLocks.remove(lock.path);
  }
}

void _validateRelativePath(String path) {
  if (path.isEmpty ||
      path.startsWith('/') ||
      path.contains('\\') ||
      path.contains(':') ||
      path.contains('\n') ||
      path.contains('\r') ||
      path.split('/').contains('..')) {
    throw StateError('Unsafe CodeForge input path: $path');
  }
}

Future<Map<String, String>> _hashFiles(
  Directory root,
  List<String> paths,
) async {
  final hashes = <String, String>{};
  // Batch hashing avoids a subprocess per file without importing package:crypto
  // into the pre-pub launcher graph.
  for (var offset = 0; offset < paths.length; offset += 100) {
    final batch = paths.skip(offset).take(100).toList();
    final result = await _run(Platform.isMacOS ? 'shasum' : 'sha256sum', [
      if (Platform.isMacOS) ...['-a', '256'],
      for (final path in batch) '${root.path}/$path',
    ]);
    final lines = const LineSplitter().convert(result.stdout as String);
    if (lines.length != batch.length) {
      throw StateError('Invalid SHA-256 output.');
    }
    for (var i = 0; i < batch.length; i++) {
      final digest = _digest(lines[i]);
      final mode = (await File('${root.path}/${batch[i]}').stat()).mode & 0x49;
      hashes[batch[i]] = '$digest:$mode';
    }
  }
  return hashes;
}

Future<String> _hashFile(File file) async => _digest(
  (await _run(Platform.isMacOS ? 'shasum' : 'sha256sum', [
        if (Platform.isMacOS) ...['-a', '256'],
        file.path,
      ])).stdout
      as String,
);

Future<String> _hashBytes(List<int> bytes) async {
  final process = await Process.start(
    Platform.isMacOS ? 'shasum' : 'sha256sum',
    [
      if (Platform.isMacOS) ...['-a', '256'],
    ],
  );
  final output = process.stdout.transform(utf8.decoder).join();
  final error = process.stderr.transform(utf8.decoder).join();
  process.stdin.add(bytes);
  await process.stdin.close();
  if (await process.exitCode != 0) throw StateError(await error);
  return _digest(await output);
}

String _digest(String output) {
  final match = RegExp(r'^([a-fA-F0-9]{64})\s').firstMatch(output);
  if (match == null) throw StateError('Invalid SHA-256 output: $output');
  return match[1]!.toLowerCase();
}

Future<ProcessResult> _run(
  String executable,
  List<String> arguments, {
  String? cwd,
  Map<String, String>? environment,
  bool includeParentEnvironment = true,
}) async {
  final result = await Process.run(
    executable,
    arguments,
    workingDirectory: cwd,
    environment: environment,
    includeParentEnvironment: includeParentEnvironment,
  );
  if (result.exitCode != 0) {
    throw StateError(
      'CodeForge $executable failed (${result.exitCode}): '
      '${result.stdout}\n${result.stderr}',
    );
  }
  return result;
}
