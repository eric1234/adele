import 'dart:async';
import 'dart:convert';
import 'dart:io';

// SDK-only Linux statx, also used by the generation witness.
// ignore: avoid_relative_lib_imports
import '../packages/contract_codegen/lib/src/provenance_files.dart';
import 'desktop_tool_artifacts.dart' show validateToolDepfile;
import 'git_test_aot_inputs.dart';

export 'git_test_aot_inputs.dart' show GitTestAot;

/// Create the directory with private permissions from the first instant. Dart's
/// createTemp permissions can depend on the invoking user's umask.
Future<Directory> createPrivateGitTestDirectory(
  Directory parent,
  String prefix,
) async {
  if (!parent.isAbsolute || !RegExp(r'^[a-zA-Z0-9_.-]+$').hasMatch(prefix)) {
    throw ArgumentError('Expected an absolute parent and local temp prefix');
  }
  _dirId(parent);
  final result = await Process.run('/usr/bin/mktemp', [
    '-d',
    '--',
    '${parent.path}/${prefix}XXXXXXXXXX',
  ]);
  if (result.exitCode != 0) {
    throw FileSystemException(
      'Cannot create private directory: ${result.stderr}',
      parent.path,
    );
  }
  final dir = Directory((result.stdout as String).trimRight());
  try {
    _dirId(dir, private: true);
    return dir;
  } catch (_) {
    await dir.delete(); // Still empty; do not recursively remove anything.
    rethrow;
  }
}

/// Test-only observation points. Neither the worker RPC nor a compiler can
/// supply an input identity, a builder, or a production lifecycle callback.
enum GitTestAotPoint { beforePublication, afterPrivateCopy }

/// Owned by exactly one launcher's isolate for exactly one maintained worker.
/// Independent suite clients reach this object via the worker's private RPC.
/// No on-disk generation is ever discovered or trusted by a new instance.
final class GitTestAotStore {
  GitTestAotStore({
    required Directory scope,
    required Directory repositoryRoot,
    required String dartExecutable,
    required String runtimeExecutable,
    required Future<void> Function(Set<String>) checkProvenance,
  }) : this.forTesting(
         scope: scope,
         capture: (recipe) => GitTestAotInputs.capture(
           repositoryRoot: repositoryRoot,
           recipe: recipe,
           dartExecutable: dartExecutable,
           runtimeExecutable: runtimeExecutable,
         ),
         checkProvenance: checkProvenance,
       );

  GitTestAotStore.forTesting({
    required this.scope,
    required Future<GitTestAotInputs> Function(GitTestAot) capture,
    required Future<void> Function(Set<String>) checkProvenance,
    Future<void> Function(GitTestAotPoint, File)? checkpoint,
  }) : _scopeId = _dirId(scope, private: true),
       _capture = capture,
       _checkProvenance = checkProvenance,
       _checkpoint = checkpoint;

  final Directory scope;
  final Future<GitTestAotInputs> Function(GitTestAot) _capture;
  final Future<void> Function(Set<String>) _checkProvenance;
  final Future<void> Function(GitTestAotPoint, File)? _checkpoint;
  final _pending = <GitTestAot, Future<void>>{};
  final _published = <GitTestAot, _Generation>{};
  final String _scopeId;

  /// [destination] must be fresh, in an existing suite-owned directory.
  /// Returns only after renaming a verified private copy into place.
  Future<void> deliver(GitTestAot recipe, File destination) async {
    final total = Stopwatch()..start();
    final inputTime = Stopwatch();
    final provenanceTime = Stopwatch();
    final compileTime = Stopwatch();
    final prior = _pending[recipe];
    final release = Completer<void>();
    // Install the gate before the first await, including for a queued miss.
    _pending[recipe] = release.future;
    if (prior != null) await prior;
    final queueUs = total.elapsedMicroseconds;
    var status = 'failed';
    Future<GitTestAotInputs> observe([String? expected]) async {
      final inputs = await _timed(inputTime, () => _capture(recipe));
      if (expected != null && inputs.digest != expected) {
        throw StateError(
          '${recipe.name} AOT inputs changed during preparation.',
        );
      }
      await _timed(provenanceTime, () => _checkProvenance(inputs.filePaths));
      _checkScope();
      return inputs;
    }

    try {
      // All observations, including eligibility and provenance, are made after
      // acquiring the gate. A queued retry cannot inherit a failed result.
      final parentId = await _destinationParent(destination);
      final inputs = await observe();
      var gen = _published[recipe];
      final hit =
          gen != null && gen.inputs == inputs.digest && await gen.valid();
      if (!hit) {
        // Forget before trying to rebuild. A required compile never falls back
        // to the previous generation, even when the failed output looks valid.
        _published.remove(recipe);
        if (gen != null) await _remove(gen.dir);
        gen = await _build(inputs, () => observe(inputs.digest), compileTime);
        _published[recipe] = gen;
      }
      final parent = destination.parent;
      if (await _destinationParent(destination) != parentId) {
        throw StateError('AOT destination parent changed: ${parent.path}');
      }
      final stage = await createPrivateGitTestDirectory(
        parent,
        '.git-aot-delivery-',
      );
      final stageId = _dirId(stage, private: true);
      try {
        final privateCopy = File('${stage.path}/snapshot');
        await gen.snapshot.copy(privateCopy.path);
        await _checkpoint?.call(GitTestAotPoint.afterPrivateCopy, privateCopy);
        // Re-inventory after the copy (including membership/absence probes).
        // Check the retained receipt and payload, as well as the copied bytes;
        // nothing at the public destination is ever used to establish trust.
        await observe(inputs.digest);
        final copyStamp = _regular(privateCopy);
        if (_dirId(stage, private: true) != stageId ||
            !await gen.valid() ||
            copyStamp.id == gen.payload.id ||
            copyStamp.mode != gen.payload.mode ||
            copyStamp.size != gen.payload.size ||
            await _digest(privateCopy) != gen.sha256 ||
            _regular(privateCopy) != copyStamp ||
            await _destinationParent(destination) != parentId) {
          throw StateError('Invalid ${recipe.name} AOT private delivery.');
        }
        // All clients in this launcher commit synchronously in the same
        // isolate. Never overwrite a path filled by another admitted request.
        if (FileSystemEntity.typeSync(destination.path, followLinks: false) !=
            FileSystemEntityType.notFound) {
          throw StateError(
            'AOT destination already exists: ${destination.path}',
          );
        }
        privateCopy.renameSync(destination.path);
      } finally {
        if (_dirId(parent) == parentId) await _remove(stage);
      }
      status = hit ? 'hit' : 'built';
    } finally {
      release.complete();
      if (identical(_pending[recipe], release.future)) _pending.remove(recipe);
      final inputsUs = inputTime.elapsedMicroseconds;
      final provenanceUs = provenanceTime.elapsedMicroseconds;
      final compileUs = compileTime.elapsedMicroseconds;
      final artifactUs =
          total.elapsedMicroseconds -
          queueUs -
          inputsUs -
          provenanceUs -
          compileUs;
      stdout.writeln(
        '[git-test-aot] recipe=${recipe.name} status=$status '
        'queueUs=$queueUs inputsUs=$inputsUs provenanceUs=$provenanceUs '
        'compileUs=$compileUs artifactUs=$artifactUs',
      );
    }
  }

  Future<String> _destinationParent(File file) async {
    if (!file.isAbsolute ||
        file.path.startsWith('${scope.path}/') ||
        file.path == scope.path ||
        await FileSystemEntity.type(file.path, followLinks: false) !=
            FileSystemEntityType.notFound) {
      throw StateError(
        'Expected a fresh private AOT destination: ${file.path}',
      );
    }
    return _dirId(file.parent);
  }

  void _checkScope() {
    if (_dirId(scope, private: true) != _scopeId) {
      throw StateError('Git AOT scope was replaced.');
    }
  }

  Future<_Generation> _build(
    GitTestAotInputs inputs,
    Future<void> Function() fence,
    Stopwatch compileTime,
  ) async {
    final stage = await createPrivateGitTestDirectory(
      scope,
      '${inputs.recipe.name}-stage-',
    );
    final stageId = _dirId(stage, private: true);
    final output = File('${stage.path}/snapshot'); // Stable ELF debug basename.
    final depfile = File('${stage.path}/compile.d');
    final receipt = File('${stage.path}/receipt.json');
    try {
      final arguments = inputs.arguments(output: output, depfile: depfile);
      final result = await _timed(
        compileTime,
        () => Process.run(
          inputs.dartExecutable,
          arguments,
          workingDirectory: inputs.root.path,
          environment: inputs.environment,
          includeParentEnvironment: false,
        ),
      );
      if (result.exitCode != 0) {
        throw ProcessException(
          inputs.dartExecutable,
          arguments,
          'AOT compilation in ${inputs.root.path} failed.\n'
          '${result.stdout}\n${result.stderr}',
          result.exitCode,
        );
      }
      if (_dirId(stage, private: true) != stageId) {
        throw StateError('AOT compiler staging directory was replaced.');
      }
      final payload = _regular(output);
      final sha256 = await _digest(output);
      final dependencies = _regular(depfile);
      validateToolDepfile(
        await depfile.readAsString(),
        output: output,
        root: inputs.root,
        inputs: inputs.filePaths,
        requiredInputs: {
          File.fromUri(inputs.root.uri.resolve(inputs.recipe.entrypoint)).path,
          inputs.packageConfig.path,
        },
      );
      if (_regular(depfile) != dependencies) {
        throw StateError('AOT compiler depfile changed during validation.');
      }
      await depfile.delete();
      final text = jsonEncode({
        'schema': 1,
        'recipe': inputs.recipe.name,
        'inputs': inputs.digest,
        'sha256': sha256,
        'size': payload.size,
        'mode': payload.mode,
      });
      await receipt.create(exclusive: true);
      await receipt.writeAsString(text, flush: true);
      final staged = _Generation(
        stage,
        stageId,
        inputs.digest,
        payload,
        sha256,
        _regular(receipt),
        text,
      );
      await _checkpoint?.call(GitTestAotPoint.beforePublication, output);
      await fence();
      if (!await staged.valid()) {
        throw StateError('Invalid staged AOT generation.');
      }
      // Same private filesystem. Only the successfully renamed, completely
      // validated generation gets an entry in the trusted in-memory index.
      final ready = await stage.rename('${stage.path}.ready');
      return _Generation(
        ready,
        staged.id,
        inputs.digest,
        payload,
        sha256,
        staged.receipt,
        text,
      );
    } finally {
      _checkScope();
      await _remove(stage);
    }
  }
}

final class _Generation {
  _Generation(
    this.dir,
    this.id,
    this.inputs,
    this.payload,
    this.sha256,
    this.receipt,
    this.text,
  );
  final Directory dir;
  final String id, inputs, sha256, text;
  final LinuxPathStat payload, receipt;
  File get snapshot => File('${dir.path}/snapshot');

  Future<bool> valid() async {
    try {
      if (_dirId(dir, private: true) != id) return false;
      final listing = linuxLstat(dir.path);
      final names = await dir
          .list(followLinks: false)
          .map((e) => e.path)
          .toSet();
      final record = File('${dir.path}/receipt.json');
      if (names.length != 2 ||
          !names.containsAll({record.path, snapshot.path})) {
        return false;
      }
      return _regular(record) == receipt &&
          await record.readAsString() == text &&
          _regular(snapshot) == payload &&
          await _digest(snapshot) == sha256 &&
          _regular(record) == receipt &&
          _regular(snapshot) == payload &&
          linuxLstat(dir.path) == listing;
    } on FileSystemException {
      return false;
    } on FormatException {
      return false;
    }
  }
}

extension on LinuxPathStat {
  String get id => '$deviceMajor:$deviceMinor:$inode';
}

LinuxPathStat _regular(File file) {
  final stamp = linuxLstat(file.path);
  if (stamp == null ||
      stamp.mode & 0xf000 != 0x8000 ||
      stamp.mode & 0xe00 != 0 ||
      stamp.mode & 0x100 == 0 ||
      stamp.nlink != 1 ||
      stamp.size <= 0) {
    throw FileSystemException(
      'Expected a singly linked, regular nonempty AOT file',
      file.path,
    );
  }
  return stamp;
}

String _dirId(Directory dir, {bool private = false}) {
  if (!dir.isAbsolute || dir.resolveSymbolicLinksSync() != dir.path) {
    throw FileSystemException('Expected canonical AOT directory', dir.path);
  }
  final stamp = linuxLstat(dir.path);
  if (stamp == null ||
      stamp.mode & 0xf000 != 0x4000 ||
      (private && stamp.mode & 0xfff != 0x1c0)) {
    throw FileSystemException(
      'Invalid AOT directory type or permissions',
      dir.path,
    );
  }
  return stamp.id;
}

Future<String> _digest(File file) async {
  final result = await Process.run('/usr/bin/sha256sum', [
    '--zero',
    '--',
    file.path,
  ]);
  final hash = RegExp(r'^[0-9a-f]{64}  ').firstMatch(result.stdout as String);
  if (result.exitCode != 0 || hash == null) {
    throw FileSystemException('Cannot hash AOT: ${result.stderr}', file.path);
  }
  return hash[0]!.trim();
}

Future<void> _remove(Directory dir) async {
  // Recursive delete unlinks symlinks instead of traversing them. It is also
  // defined for a file/link replacing the original private directory.
  if (await FileSystemEntity.type(dir.path, followLinks: false) !=
      FileSystemEntityType.notFound) {
    await dir.delete(recursive: true);
  }
}

Future<T> _timed<T>(Stopwatch time, Future<T> Function() f) async {
  time.start();
  try {
    return await f();
  } finally {
    time.stop();
  }
}
