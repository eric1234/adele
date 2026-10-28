import 'dart:convert';
import 'dart:io';

const _metadataPath = 'third_party/appflowy_editor/preparation.json';
const _sourcePath = '.adele/dependencies/appflowy_editor';
const _stateName = '.adele-preparation.json';
final _activeLocks = <String>{};

/// Prepares source without pub or Flutter. Existing source is only verified
/// unless [reprepare] explicitly requests replacement after stopping consumers.
Future<Directory> prepareRichEditorSource(
  Directory repository, {
  File? archive,
  bool reprepare = false,
}) => _locked(
  repository,
  (root) => _prepare(root, archive: archive, reprepare: reprepare),
);

/// Holds the exclusive source lease throughout [consume]. Reentrancy is refused.
/// Unleased IDE/direct Flutter consumers must be stopped before replacement.
Future<T> withRichEditorSource<T>(
  Directory repository,
  Future<T> Function(Directory source) consume, {
  File? archive,
}) => _locked(repository, (root) async {
  return consume(await _prepare(root, archive: archive));
});

Future<Directory> _prepare(
  Directory root, {
  File? archive,
  bool reprepare = false,
}) async {
  await _requireFile(root, _metadataPath);
  final metadata = File('${root.path}/$_metadataPath');
  final text = await metadata.readAsString();
  final config = jsonDecode(text) as Map<String, dynamic>;
  if (config['schema'] != 1 || config['package'] != 'appflowy_editor') {
    throw StateError('Unsupported AppFlowy preparation manifest.');
  }
  final patches = (config['patches'] as List).cast<String>();
  for (final patch in patches) {
    _validatePath(patch);
  }
  final inputs = <String>[
    _metadataPath,
    'tools/rich_editor_dependency.dart',
    for (final patch in patches) 'third_party/appflowy_editor/$patch',
  ];
  final inputHashes = await _hashFiles(root, inputs);
  if (await metadata.readAsString() != text) {
    throw StateError('AppFlowy preparation manifest changed. Retry.');
  }
  final identity = await _hashText(jsonEncode(inputHashes));
  final source = Directory('${root.path}/$_sourcePath');
  if (!reprepare &&
      await FileSystemEntity.type(source.path, followLinks: false) !=
          FileSystemEntityType.notFound) {
    try {
      if (await FileSystemEntity.type(source.path, followLinks: false) !=
          FileSystemEntityType.directory) {
        throw StateError('Source is not a directory.');
      }
      await _requireFile(source, _stateName);
      final state =
          jsonDecode(await File('${source.path}/$_stateName').readAsString())
              as Map;
      if (state['identity'] != identity) {
        throw StateError('Preparation inputs changed.');
      }
      final expected = (state['files'] as Map).cast<String, String>();
      // Authenticate the local inventory before using its build-output exclusions.
      // A writable ledger never authorizes a different immutable tree.
      await _verifyTree(expected, config['preparedTreeSha256'] as String);
      final actual = await _manifest(source, expected: expected.keys.toSet());
      if (jsonEncode(actual) != jsonEncode(expected)) {
        throw StateError('Immutable source content changed.');
      }
      await _checkInputs(root, inputs, inputHashes);
      return source;
    } catch (error) {
      throw StateError(
        'Stale or altered AppFlowy checkout: $error Stop all consumers, then '
        'run dart tools/adele.dart prepare-rich-editor --reprepare. '
        'No fallback was used.',
      );
    }
  }
  final stage = await source.parent.createTemp('.appflowy_editor-stage-');
  try {
    final stagedArchive = File('${stage.path}/archive.tar.gz');
    if (archive != null) {
      if (await FileSystemEntity.type(archive.path, followLinks: false) !=
          FileSystemEntityType.file) {
        throw StateError('AppFlowy archive must be a regular file.');
      }
      await archive.copy(stagedArchive.path);
    } else {
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
        stagedArchive.path,
        config['archiveUrl'] as String,
      ]);
    }
    if (await _hashFile(stagedArchive) != config['archiveSha256']) {
      throw StateError('AppFlowy archive checksum mismatch.');
    }
    final listing = await _run('tar', ['-tzf', stagedArchive.path]);
    for (var path in const LineSplitter().convert(listing.stdout as String)) {
      if (path.startsWith('./')) path = path.substring(2);
      if (path.endsWith('/')) path = path.substring(0, path.length - 1);
      if (path.isNotEmpty) _validatePath(path);
    }
    final types = await _run('tar', ['-tvzf', stagedArchive.path]);
    if (const LineSplitter()
        .convert(types.stdout as String)
        .any((line) => !line.startsWith('-') && !line.startsWith('d'))) {
      throw StateError('AppFlowy archive contains links or special entries.');
    }
    final unpacked = Directory('${stage.path}/source')..createSync();
    await _run('tar', [
      '--same-permissions',
      '-xzf',
      stagedArchive.path,
      '-C',
      unpacked.path,
    ]);
    for (final patch in patches) {
      await _run('git', [
        'apply',
        '--whitespace=nowarn',
        '${root.path}/third_party/appflowy_editor/$patch',
      ], cwd: unpacked.path);
    }
    final files = await _manifest(unpacked);
    await _verifyTree(files, config['preparedTreeSha256'] as String);
    final pubspec = await File('${unpacked.path}/pubspec.yaml').readAsString();
    if (!RegExp(
      '^version: ${RegExp.escape(config['version'] as String)}\$',
      multiLine: true,
    ).hasMatch(pubspec)) {
      throw StateError('AppFlowy package version does not match the manifest.');
    }
    await _checkInputs(root, inputs, inputHashes);
    await File('${unpacked.path}/$_stateName').writeAsString(
      jsonEncode({'identity': identity, 'files': files}),
      flush: true,
    );
    final type = await FileSystemEntity.type(source.path, followLinks: false);
    if (type == FileSystemEntityType.notFound) {
      await unpacked.rename(source.path);
    } else {
      if (!reprepare) throw StateError('AppFlowy checkout appeared. Retry.');
      final existing = switch (type) {
        FileSystemEntityType.directory => source,
        FileSystemEntityType.file => File(source.path),
        FileSystemEntityType.link => Link(source.path),
        _ => throw StateError('Invalid AppFlowy checkout: ${source.path}'),
      };
      final backup = await source.parent.createTemp('.appflowy_editor-backup-');
      var retainBackup = false;
      try {
        final previous = await existing.rename('${backup.path}/source');
        try {
          await unpacked.rename(source.path);
        } catch (publishError) {
          try {
            await previous.rename(source.path);
          } catch (rollbackError) {
            retainBackup = true;
            throw StateError(
              'AppFlowy publication failed: $publishError; rollback failed: '
              '$rollbackError. Previous source retained at ${previous.path}. '
              'No fallback was used.',
            );
          }
          rethrow;
        }
      } finally {
        if (!retainBackup) await backup.delete(recursive: true);
      }
    }
    stdout.writeln('Prepared AppFlowy ${config['version']}: ${source.path}');
    return source;
  } finally {
    await stage.delete(recursive: true);
  }
}

Future<void> _checkInputs(
  Directory root,
  List<String> inputs,
  Map<String, String> hashes,
) async {
  if (jsonEncode(await _hashFiles(root, inputs)) != jsonEncode(hashes)) {
    throw StateError('AppFlowy preparation inputs changed during preparation.');
  }
}

Future<void> _verifyTree(Map<String, String> files, String expected) async {
  final canonical = {
    for (final path in files.keys.toList()..sort()) path: files[path],
  };
  final actual = await _hashText(jsonEncode(canonical));
  if (actual != expected) {
    throw StateError(
      'AppFlowy prepared tree checksum mismatch: expected $expected, actual '
      '$actual. Review the archive and patches, never trust a local cache.',
    );
  }
}

Future<Map<String, String>> _manifest(
  Directory source, {
  Set<String>? expected,
}) async {
  final entries = <String, String>{};
  final files = <String>[];
  Future<void> visit(Directory directory) async {
    await for (final entry in directory.list(followLinks: false)) {
      final path = entry.path
          .substring(source.path.length + 1)
          .replaceAll('\\', '/');
      _validatePath(path);
      if (path == _stateName && expected != null) continue;
      if (expected != null &&
          !expected.contains(path) &&
          (path == '.dart_tool' ||
              path.startsWith('.dart_tool/') ||
              path == 'build' ||
              path.startsWith('build/') ||
              const [
                'pubspec.lock',
                '.flutter-plugins',
                '.flutter-plugins-dependencies',
              ].contains(path))) {
        continue;
      }
      if (entry is Directory) {
        entries[path] = 'directory';
        await visit(entry);
      } else if (entry is File && path != _stateName) {
        files.add(path);
      } else {
        throw StateError('Unexpected AppFlowy source entry: $path');
      }
    }
  }

  await visit(source);
  entries.addAll(await _hashFiles(source, files..sort()));
  return {
    for (final path in entries.keys.toList()..sort()) path: entries[path]!,
  };
}

Future<T> _locked<T>(
  Directory root,
  Future<T> Function(Directory) action,
) async {
  root = Directory(await root.resolveSymbolicLinks());
  final lock = File(
    '${root.path}/.adele/dependencies/appflowy_editor-source.lock',
  );
  if (!_activeLocks.add(lock.path)) {
    throw StateError('AppFlowy source preparation is busy; retry after exit.');
  }
  RandomAccessFile? handle;
  try {
    for (final path in ['.adele', '.adele/dependencies']) {
      final directory = Directory('${root.path}/$path');
      final type = await FileSystemEntity.type(
        directory.path,
        followLinks: false,
      );
      if (type == FileSystemEntityType.notFound) await directory.create();
      if (await FileSystemEntity.type(directory.path, followLinks: false) !=
          FileSystemEntityType.directory) {
        throw StateError(
          'AppFlowy preparation directory is not regular: $path',
        );
      }
    }
    final type = await FileSystemEntity.type(lock.path, followLinks: false);
    if (type != FileSystemEntityType.notFound &&
        type != FileSystemEntityType.file) {
      throw StateError('AppFlowy source lock is not a regular file.');
    }
    handle = await lock.open(mode: FileMode.append);
    try {
      await handle.lock(FileLock.exclusive);
    } on FileSystemException {
      throw StateError(
        'AppFlowy source preparation is busy; retry after exit.',
      );
    }
    return await action(root);
  } finally {
    await handle?.close();
    _activeLocks.remove(lock.path);
  }
}

void _validatePath(String path) {
  if (path.isEmpty ||
      path.startsWith('/') ||
      path.contains('\\') ||
      path.contains(':') ||
      path.contains('\n') ||
      path.contains('\r') ||
      path
          .split('/')
          .any((part) => part.isEmpty || part == '.' || part == '..')) {
    throw StateError('Unsafe AppFlowy input path: $path');
  }
}

Future<void> _requireFile(Directory root, String path) async {
  _validatePath(path);
  var current = root.path;
  final parts = path.split('/');
  for (var i = 0; i < parts.length; i++) {
    current = '$current/${parts[i]}';
    final expected = i == parts.length - 1
        ? FileSystemEntityType.file
        : FileSystemEntityType.directory;
    if (await FileSystemEntity.type(current, followLinks: false) != expected) {
      throw StateError('Missing or non-regular AppFlowy input: $path');
    }
  }
}

Future<Map<String, String>> _hashFiles(
  Directory root,
  List<String> paths,
) async {
  final hashes = <String, String>{};
  for (var offset = 0; offset < paths.length; offset += 100) {
    final batch = paths.skip(offset).take(100).toList();
    for (final path in batch) {
      await _requireFile(root, path);
    }
    final result = await _run(Platform.isMacOS ? 'shasum' : 'sha256sum', [
      if (Platform.isMacOS) ...['-a', '256'],
      for (final path in batch) '${root.path}/$path',
    ]);
    final lines = const LineSplitter().convert(result.stdout as String);
    if (lines.length != batch.length) {
      throw StateError('Invalid SHA-256 output.');
    }
    for (var i = 0; i < batch.length; i++) {
      final mode = (await File('${root.path}/${batch[i]}').stat()).mode & 0x49;
      hashes[batch[i]] = '${_digest(lines[i])}:$mode';
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

Future<String> _hashText(String text) async {
  final process = await Process.start(
    Platform.isMacOS ? 'shasum' : 'sha256sum',
    [
      if (Platform.isMacOS) ...['-a', '256'],
    ],
  );
  final output = process.stdout.transform(utf8.decoder).join();
  final errors = process.stderr.transform(utf8.decoder).join();
  process.stdin.add(utf8.encode(text));
  await process.stdin.close();
  if (await process.exitCode != 0) throw StateError(await errors);
  return _digest(await output);
}

String _digest(String output) {
  final match = RegExp(r'^([a-f0-9]{64})\s').firstMatch(output);
  if (match == null) throw StateError('Invalid SHA-256 output: $output');
  return match[1]!;
}

Future<ProcessResult> _run(
  String executable,
  List<String> arguments, {
  String? cwd,
}) async {
  final result = await Process.run(
    executable,
    arguments,
    workingDirectory: cwd,
    // Prevent parent repository discovery from silently skipping ignored patches.
    environment: {
      for (final entry in Platform.environment.entries)
        if (!entry.key.startsWith('GIT_')) entry.key: entry.value,
      if (cwd != null) 'GIT_CEILING_DIRECTORIES': Directory(cwd).parent.path,
    },
    includeParentEnvironment: false,
  );
  if (result.exitCode != 0) {
    throw StateError(
      'AppFlowy $executable failed (${result.exitCode}): '
      '${result.stdout}\n${result.stderr}',
    );
  }
  return result;
}
