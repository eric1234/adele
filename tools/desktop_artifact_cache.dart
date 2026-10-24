import 'dart:convert';
import 'dart:io';

// The launcher must also load before workspace bootstrap.
// ignore: avoid_relative_lib_imports
import '../packages/plugin_builder/lib/plugin_builder.dart';
import 'build_timing.dart';

/// Checkout-local, immutable outputs. Callers hold [withDesktopArtifactCache]
/// through generation, input discovery, compilation, validation and publication.
final class DesktopArtifactCache {
  DesktopArtifactCache(this.root);

  final Directory root;
  final Map<String, String> componentIdentities = {};
  final List<({Directory stage, String bucket, String identity})> _pending = [];

  Future<Directory> stage() async {
    final parent = Directory.fromUri(root.uri.resolve('.staging/'));
    await parent.create(recursive: true);
    return parent.createTemp('entry-');
  }

  Future<File> component({
    required String name,
    required String identity,
    required String filename,
    required Future<void> Function(File output) build,
  }) async {
    final timer = Stopwatch()..start();
    var status = 'failed';
    try {
      componentIdentities[name] = identity;
      final bucket = 'components/$name';
      final cached = await _lookup(bucket, identity, artifact: filename);
      if (cached != null &&
          await File.fromUri(cached.uri.resolve(filename)).exists()) {
        status = 'cached';
        return File.fromUri(cached.uri.resolve(filename));
      }
      final output = await stage();
      final artifact = File.fromUri(output.uri.resolve(filename));
      await build(artifact);
      if (!await artifact.exists() || await artifact.length() == 0) {
        throw PluginBuildFailure('$name produced no non-empty artifact.');
      }
      await _seal(output, identity);
      // Do not publish even a component until the caller rechecks the complete
      // input graph. New imports during compilation must not poison this key.
      _pending.add((stage: output, bucket: bucket, identity: identity));
      status = 'rebuilt';
      return artifact;
    } finally {
      reportBuildTiming(name, timer, status);
    }
  }

  Future<void> publishComponents() async {
    for (final entry in _pending) {
      await _publish(entry.stage, entry.bucket, entry.identity);
    }
    _pending.clear();
  }

  /// Assemble in private even on a hit, then compare the exact desired contents.
  /// This keeps manifest/schema ownership with the existing stock publisher.
  Future<Directory> publishSnapshot(Directory stage) async {
    final files = await _inventory(stage);
    final identity = await digestJson({
      'components': componentIdentities,
      'files': files,
    });
    return _reuseOrPublish(stage, 'snapshots', identity, files);
  }

  Future<File> startupArguments(Map<String, List<String>> arguments) async {
    final content = jsonEncode(arguments);
    final identity = await digestJson(arguments);
    final expected = <String, Object>{
      'startup-arguments.json': {'sha256': identity, 'executable': 0},
    };
    final cached = await _lookup('startup', identity, expectedFiles: expected);
    if (cached != null) {
      return File.fromUri(cached.uri.resolve('startup-arguments.json'));
    }
    final output = await stage();
    await File.fromUri(
      output.uri.resolve('startup-arguments.json'),
    ).writeAsString(content, flush: true);
    final published = await _reuseOrPublish(
      output,
      'startup',
      identity,
      expected,
    );
    return File.fromUri(published.uri.resolve('startup-arguments.json'));
  }

  Future<Directory> _reuseOrPublish(
    Directory stage,
    String bucket,
    String identity,
    Map<String, Object> expectedFiles,
  ) async {
    final cached = await _lookup(
      bucket,
      identity,
      expectedFiles: expectedFiles,
    );
    if (cached != null) {
      await stage.delete(recursive: true);
      return cached;
    }
    await _seal(stage, identity, expectedFiles: expectedFiles);
    return _publish(stage, bucket, identity);
  }

  Future<void> _seal(
    Directory stage,
    String identity, {
    Map<String, Object>? expectedFiles,
  }) async {
    final files = await _inventory(stage);
    if (files.isEmpty) {
      throw const PluginBuildFailure('Cannot publish an empty artifact entry.');
    }
    if (expectedFiles != null &&
        jsonEncode(files) != jsonEncode(expectedFiles)) {
      throw const PluginBuildFailure(
        'Prepared outputs changed before publication.',
      );
    }
    await File.fromUri(stage.uri.resolve('receipt.json')).writeAsString(
      jsonEncode({'version': 1, 'identity': identity, 'files': files}),
      flush: true,
    );
  }

  Future<Directory?> _lookup(
    String bucket,
    String identity, {
    Map<String, Object>? expectedFiles,
    String? artifact,
  }) async {
    final parent = Directory.fromUri(root.uri.resolve('$bucket/$identity/'));
    if (!await parent.exists()) return null;
    final entries = await parent.list(followLinks: false).toList();
    entries.sort((a, b) => a.path.compareTo(b.path));
    for (final entry in entries.whereType<Directory>()) {
      try {
        final receipt = jsonDecode(
          await File.fromUri(entry.uri.resolve('receipt.json')).readAsString(),
        );
        if (receipt is! Map ||
            receipt['version'] != 1 ||
            receipt['identity'] != identity ||
            receipt['files'] is! Map ||
            (receipt['files'] as Map).isEmpty) {
          continue;
        }
        final files = receipt['files'] as Map;
        if ((artifact != null &&
                (files.length != 1 || !files.containsKey(artifact))) ||
            (expectedFiles != null &&
                jsonEncode(files) != jsonEncode(expectedFiles))) {
          continue;
        }
        if (jsonEncode(await _inventory(entry)) ==
            jsonEncode(receipt['files'])) {
          return entry;
        }
      } on FileSystemException {
        // A damaged entry is never modified, even when it cannot be reused.
      } on FormatException {
        // Incomplete or corrupt receipts are misses, not older-build fallback.
      } on PluginBuildFailure {
        // Empty, linked or otherwise invalid artifacts are misses too.
      }
    }
    return null;
  }

  Future<Directory> _publish(
    Directory stage,
    String bucket,
    String identity,
  ) async {
    final parent = Directory.fromUri(root.uri.resolve('$bucket/$identity/'));
    await parent.create(recursive: true);
    // Unique immutable generations also permit repair without overwriting a
    // damaged path that an earlier application's captured catalog may reference.
    final name = stage.uri.pathSegments.lastWhere((s) => s.isNotEmpty);
    return stage.rename(parent.uri.resolve(name).toFilePath());
  }
}

final _activeRoots = <String>{};

Future<T> withDesktopArtifactCache<T>(
  Directory repository,
  Future<T> Function(DesktopArtifactCache cache) action,
) async {
  final root = Directory.fromUri(
    repository.absolute.uri.resolve('.dart_tool/adele/desktop-plugins/'),
  );
  await root.create(recursive: true);
  final path = await root.resolveSymbolicLinks();
  if (!_activeRoots.add(path)) {
    throw const PluginBuildFailure('Desktop preparation is already active.');
  }
  RandomAccessFile? lock;
  try {
    lock = await File('$path/preparation.lock').open(mode: FileMode.append);
    await lock.lock(FileLock.blockingExclusive);
    return await action(DesktopArtifactCache(Directory(path)));
  } finally {
    await lock?.close();
    _activeRoots.remove(path);
  }
}

/// SHA-256 is supplied by the same Linux prerequisite as CodeForge preparation.
/// Hash paths and bytes, never mtimes; batching keeps large dependency sets cheap.
Future<Map<String, String>> hashBuildFiles(Iterable<String> inputPaths) async {
  final paths = inputPaths.toSet().toList()..sort();
  final hashes = <String, String>{};
  for (var offset = 0; offset < paths.length; offset += 128) {
    final batch = paths.skip(offset).take(128).toList();
    final result = await Process.run('sha256sum', ['--zero', '--', ...batch]);
    if (result.exitCode != 0) {
      throw PluginBuildFailure(
        'Unable to fingerprint build inputs: ${result.stderr}',
      );
    }
    final records = (result.stdout as String).split('\x00')..removeLast();
    if (records.length != batch.length) {
      throw const PluginBuildFailure('Invalid build-input checksum output.');
    }
    for (var index = 0; index < records.length; index++) {
      final record = records[index];
      if (record.length < 67 ||
          !RegExp(r'^[a-f0-9]{64}  ').hasMatch(record) ||
          record.substring(66) != batch[index]) {
        throw const PluginBuildFailure('Invalid build-input checksum record.');
      }
      hashes[batch[index]] = record.substring(0, 64);
    }
  }
  return hashes;
}

Future<String> digestJson(Object? value) async {
  final process = await Process.start('sha256sum', const []);
  final output = process.stdout.transform(utf8.decoder).join();
  final errors = process.stderr.transform(utf8.decoder).join();
  process.stdin.add(utf8.encode(jsonEncode(value)));
  await process.stdin.close();
  if (await process.exitCode != 0) {
    throw PluginBuildFailure(
      'Unable to fingerprint build context: ${await errors}',
    );
  }
  final result = await output;
  if (!RegExp(r'^[a-f0-9]{64}  -\n$').hasMatch(result)) {
    throw const PluginBuildFailure('Invalid build-context checksum output.');
  }
  return result.substring(0, 64);
}

/// These are preparation-race fences, not persistent cache keys. A touch between
/// launches remains a hit, but an edit-and-restore during a compile must fail.
Future<Map<String, Object>> buildInputStats(Iterable<String> inputs) async {
  final paths = <String>{
    ...inputs,
    for (final path in inputs)
      if (path.endsWith('.dart')) File(path).parent.path,
  }.toList()..sort();
  return {
    for (final path in paths)
      path: await (() async {
        final stat = await FileStat.stat(path);
        return [
          stat.type.toString(),
          stat.size,
          stat.modified.microsecondsSinceEpoch,
          stat.changed.microsecondsSinceEpoch,
        ];
      })(),
  };
}

Future<Map<String, Object>> _inventory(Directory root) async {
  final entries = await root.list(recursive: true, followLinks: false).toList();
  final files = <String>[];
  for (final entry in entries) {
    if (entry is Link) {
      throw const PluginBuildFailure('Linked cache outputs are not reusable.');
    }
    if (entry is File && entry.path != '${root.path}/receipt.json') {
      if (await entry.length() == 0) {
        throw const PluginBuildFailure('Empty cache outputs are not reusable.');
      }
      files.add(entry.path);
    }
  }
  final hashes = await hashBuildFiles(files);
  return {
    for (final entry in hashes.entries)
      entry.key.substring(root.path.length + 1): {
        'sha256': entry.value,
        'executable': (await File(entry.key).stat()).mode & 0x49,
      },
  };
}
