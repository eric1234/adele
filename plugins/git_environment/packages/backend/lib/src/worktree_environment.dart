import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:adele_environment/adele_environment.dart';
import 'package:crypto/crypto.dart';

const int maximumEnvironmentFileBytes = 1024 * 1024;
const int maximumEnvironmentDirectoryEntries = 2048;
const int _maximumInitialReadBufferBytes = 64 * 1024;

final class WorktreeEnvironment {
  WorktreeEnvironment(Directory root) : root = _canonicalRoot(root);

  final Directory root;
  Future<void> _pendingMutation = Future<void>.value();

  Future<EnvironmentTextFile> readFile(String relativePath) async {
    final String normalized = _normalizeRelativePath(relativePath);
    try {
      final File file = await _resolveRegularFile(normalized);
      final Uint8List bytes = await _readBounded(file, normalized);
      await _verifyStillDirectRegularFile(file, normalized);
      final String text;
      try {
        text = utf8.decode(bytes, allowMalformed: false);
      } on FormatException {
        throw _failure(
          'invalid_utf8',
          'The requested file is not valid UTF-8 text.',
          relativePath: normalized,
        );
      }
      return EnvironmentTextFile(
        relativePath: normalized,
        text: text,
        sizeBytes: bytes.length,
        revision: _revision(bytes),
      );
    } on EnvironmentFailure {
      rethrow;
    } on FileSystemException {
      throw _failure(
        'unreadable',
        'The requested file could not be read.',
        relativePath: normalized,
      );
    }
  }

  Future<EnvironmentTextFileCreation> createTextFile(
    String relativePath,
    String text,
  ) async {
    final String normalized = _normalizeRelativePath(relativePath);
    final List<int> encoded = utf8.encode(text);
    if (encoded.length > maximumEnvironmentFileBytes) {
      throw _failure(
        'file_too_large',
        'The new file text exceeds the supported size.',
        relativePath: normalized,
        limit: maximumEnvironmentFileBytes,
      );
    }
    return await _coordinateMutation(
      () => _createTextFile(normalized, Uint8List.fromList(encoded)),
    );
  }

  Future<EnvironmentTextFileCreation> _createTextFile(
    String relativePath,
    Uint8List bytes,
  ) async {
    Directory? stagingDirectory;
    try {
      final File target = await _resolveAbsentCreationTarget(relativePath);
      stagingDirectory = await target.parent.createTemp(
        '.adele-creation-$pid-',
      );
      final File staged = File(
        '${stagingDirectory.path}${Platform.pathSeparator}creation',
      );
      await staged.writeAsBytes(bytes, flush: true);

      // Revalidate direct parent identity and absence immediately before the
      // platform's strongest available no-clobber publication sequence.
      final File currentTarget = await _resolveAbsentCreationTarget(
        relativePath,
      );
      if (!Platform.isWindows) {
        // POSIX rename replaces a destination, so reserve absence atomically
        // before promoting over that provider-owned empty file.
        await currentTarget.create(exclusive: true);
        await _verifyEmptyReservation(currentTarget, relativePath);
      }
      // Windows rename already fails when the destination exists, so creating
      // a reservation there would make every promotion fail.
      final File promoted = await staged.rename(currentTarget.path);
      final Uint8List written = await _readBounded(promoted, relativePath);
      await _verifyStillDirectRegularFile(promoted, relativePath);
      return EnvironmentTextFileCreation(revision: _revision(written));
    } on PathExistsException {
      throw _failure(
        environmentFileAlreadyExistsCode,
        'The requested file already exists.',
        relativePath: relativePath,
      );
    } on EnvironmentFailure {
      rethrow;
    } on FileSystemException {
      throw _failure(
        'unwritable',
        'The requested file could not be created.',
        relativePath: relativePath,
      );
    } finally {
      // Do not delete a failed POSIX reservation by pathname: Dart cannot prove
      // that an external process has not replaced it in the meantime.
      if (stagingDirectory case final Directory directory) {
        await _deleteBestEffort(directory);
      }
    }
  }

  Future<EnvironmentTextFileReplacement> replaceExistingTextFile(
    String relativePath,
    String replacementText,
    String expectedRevision,
  ) async {
    final String normalized = _normalizeRelativePath(relativePath);
    final List<int> replacementBytes = utf8.encode(replacementText);
    if (replacementBytes.length > maximumEnvironmentFileBytes) {
      throw _failure(
        'file_too_large',
        'The replacement text exceeds the supported size.',
        relativePath: normalized,
        limit: maximumEnvironmentFileBytes,
      );
    }
    return await _coordinateMutation(
      () => _replaceExistingTextFile(
        normalized,
        Uint8List.fromList(replacementBytes),
        expectedRevision,
      ),
    );
  }

  Future<EnvironmentTextFileReplacement> _replaceExistingTextFile(
    String relativePath,
    Uint8List replacementBytes,
    String expectedRevision,
  ) async {
    Directory? stagingDirectory;
    try {
      final File file = await _resolveRegularFile(relativePath);
      final Uint8List observed = await _readBounded(file, relativePath);
      await _verifyStillDirectRegularFile(file, relativePath);
      if (_revision(observed) != expectedRevision) {
        throw _failure(
          environmentRevisionConflictCode,
          'The file changed since the expected revision was observed.',
          relativePath: relativePath,
        );
      }
      final FileStat originalStat = await file.stat();
      stagingDirectory = await file.parent.createTemp(
        '.adele-replacement-$pid-',
      );
      final File staged = File(
        '${stagingDirectory.path}${Platform.pathSeparator}replacement',
      );
      await staged.writeAsBytes(replacementBytes, flush: true);
      await _applyPosixPermissions(staged, originalStat.mode & 0x1ff);

      // Re-resolve and re-read immediately before promotion to catch practical
      // out-of-band path, content, or permission changes without overstating
      // filesystem CAS.
      final File currentFile = await _resolveRegularFile(relativePath);
      if (currentFile.path != file.path) {
        throw _failure(
          environmentRevisionConflictCode,
          'The file changed since the expected revision was observed.',
          relativePath: relativePath,
        );
      }
      final Uint8List current = await _readBounded(currentFile, relativePath);
      await _verifyStillDirectRegularFile(currentFile, relativePath);
      if (_revision(current) != expectedRevision) {
        throw _failure(
          environmentRevisionConflictCode,
          'The file changed since the expected revision was observed.',
          relativePath: relativePath,
        );
      }
      final FileStat currentStat = await currentFile.stat();
      if (!Platform.isWindows &&
          (currentStat.mode & 0x1ff) != (originalStat.mode & 0x1ff)) {
        throw _failure(
          environmentRevisionConflictCode,
          'The file changed since the expected revision was observed.',
          relativePath: relativePath,
        );
      }
      final File promoted = await staged.rename(currentFile.path);
      final Uint8List written = await _readBounded(promoted, relativePath);
      await _verifyStillDirectRegularFile(promoted, relativePath);
      return EnvironmentTextFileReplacement(revision: _revision(written));
    } on EnvironmentFailure {
      rethrow;
    } on FileSystemException {
      throw _failure(
        'unwritable',
        'The requested file could not be replaced.',
        relativePath: relativePath,
      );
    } finally {
      if (stagingDirectory case final Directory directory) {
        await _deleteBestEffort(directory);
      }
    }
  }

  Future<void> deleteExistingTextFile(
    String relativePath,
    String expectedRevision,
  ) async {
    final String normalized = _normalizeRelativePath(relativePath);
    await _coordinateMutation(
      () => _deleteExistingTextFile(normalized, expectedRevision),
    );
  }

  Future<void> _deleteExistingTextFile(
    String relativePath,
    String expectedRevision,
  ) async {
    try {
      final File file = await _resolveRegularFile(relativePath);
      final Uint8List observed = await _readBounded(file, relativePath);
      _decodeText(observed, relativePath);
      await _verifyStillDirectRegularFile(file, relativePath);
      if (_revision(observed) != expectedRevision) {
        throw _revisionConflict(relativePath);
      }
      final FileStat originalStat = await file.stat();

      // Re-resolve and re-read immediately before deletion. Dart does not
      // expose a portable atomic compare-and-delete filesystem primitive.
      final File currentFile = await _resolveRegularFile(relativePath);
      if (currentFile.path != file.path) {
        throw _revisionConflict(relativePath);
      }
      final Uint8List current = await _readBounded(currentFile, relativePath);
      _decodeText(current, relativePath);
      await _verifyStillDirectRegularFile(currentFile, relativePath);
      if (_revision(current) != expectedRevision) {
        throw _revisionConflict(relativePath);
      }
      final FileStat currentStat = await currentFile.stat();
      if (!Platform.isWindows &&
          (currentStat.mode & 0x1ff) != (originalStat.mode & 0x1ff)) {
        throw _revisionConflict(relativePath);
      }
      await currentFile.delete();
    } on EnvironmentFailure {
      rethrow;
    } on FileSystemException {
      throw _failure(
        'unwritable',
        'The requested file could not be deleted.',
        relativePath: relativePath,
      );
    }
  }

  Future<T> _coordinateMutation<T>(Future<T> Function() operation) {
    final Future<T> result = _pendingMutation
        .catchError((Object _) {})
        .then((_) => operation());
    _pendingMutation = result.then<void>((_) {}).catchError((Object _) {});
    return result;
  }

  Future<EnvironmentDirectoryListing> readDirectory(String relativePath) async {
    final String normalized = _normalizeRelativePath(
      relativePath,
      allowRoot: true,
    );
    final List<FileSystemEntity> entities = <FileSystemEntity>[];
    try {
      final Directory directory = await _resolveDirectory(normalized);
      await for (final FileSystemEntity entity in directory.list(
        followLinks: false,
      )) {
        entities.add(entity);
        if (entities.length > maximumEnvironmentDirectoryEntries) {
          throw _failure(
            'directory_too_large',
            'The requested directory exceeds the supported entry count.',
            relativePath: normalized,
            limit: maximumEnvironmentDirectoryEntries,
          );
        }
      }
      await _verifyStillConfined(
        directory,
        normalized,
        FileSystemEntityType.directory,
      );
    } on EnvironmentFailure {
      rethrow;
    } on FileSystemException {
      throw _failure(
        'unreadable',
        'The requested directory could not be read.',
        relativePath: normalized,
      );
    }
    entities.sort(
      (FileSystemEntity left, FileSystemEntity right) =>
          _entityName(left.path).compareTo(_entityName(right.path)),
    );
    final List<EnvironmentDirectoryEntry> entries =
        <EnvironmentDirectoryEntry>[];
    for (final FileSystemEntity entity in entities) {
      final String name = _entityName(entity.path);
      final FileSystemEntityType type;
      try {
        type = await FileSystemEntity.type(entity.path, followLinks: false);
      } on FileSystemException {
        throw _failure(
          'unreadable',
          'A directory entry could not be inspected.',
          relativePath: normalized,
        );
      }
      entries.add(
        EnvironmentDirectoryEntry(
          name: name,
          relativePath: normalized.isEmpty ? name : '$normalized/$name',
          kind: switch (type) {
            FileSystemEntityType.file => EnvironmentDirectoryEntryKind.file,
            FileSystemEntityType.directory =>
              EnvironmentDirectoryEntryKind.directory,
            _ => EnvironmentDirectoryEntryKind.other,
          },
        ),
      );
    }
    return EnvironmentDirectoryListing(
      relativePath: normalized,
      entries: entries,
    );
  }

  /// Resolves a process cwd through aliases while keeping it inside [root].
  Future<Directory> resolveProcessWorkingDirectory(String relativePath) async {
    final String normalized = _normalizeRelativePath(
      relativePath,
      allowRoot: true,
    );
    try {
      final Directory directory = await _resolveDirectory(normalized);
      await _verifyStillConfined(
        directory,
        normalized,
        FileSystemEntityType.directory,
      );
      return directory;
    } on EnvironmentFailure {
      rethrow;
    } on FileSystemException {
      throw _failure(
        'unreadable',
        'The process working directory could not be resolved.',
        relativePath: normalized,
      );
    }
  }

  Future<File> _resolveRegularFile(String relativePath) async {
    final String candidate = _candidate(relativePath);
    await _rejectSymbolicLinkComponents(relativePath);
    await _requireExisting(candidate, relativePath, 'file');
    final String resolved = await _resolve(candidate, relativePath, 'file');
    if (resolved != candidate) {
      throw _pathAliasUnsupported(relativePath);
    }
    if (await FileSystemEntity.type(resolved, followLinks: true) !=
        FileSystemEntityType.file) {
      throw _failure(
        'not_regular_file',
        'The requested path is not a regular file.',
        relativePath: relativePath,
      );
    }
    return File(resolved);
  }

  Future<File> _resolveAbsentCreationTarget(String relativePath) async {
    final List<String> segments = relativePath.split('/');
    final String parentRelativePath = segments.length == 1
        ? ''
        : segments.sublist(0, segments.length - 1).join('/');
    final Directory parent = await _resolveDirectDirectory(
      parentRelativePath,
      relativePath,
    );
    final File target = File(
      '${parent.path}${Platform.pathSeparator}${segments.last}',
    );
    final FileSystemEntityType type;
    try {
      type = await FileSystemEntity.type(target.path, followLinks: false);
    } on FileSystemException {
      throw _failure(
        'unreadable',
        'The requested file path could not be inspected.',
        relativePath: relativePath,
      );
    }
    if (type == FileSystemEntityType.link) {
      throw _pathAliasUnsupported(relativePath);
    }
    if (type != FileSystemEntityType.notFound) {
      throw _failure(
        environmentFileAlreadyExistsCode,
        'The requested file already exists.',
        relativePath: relativePath,
      );
    }
    return target;
  }

  Future<Directory> _resolveDirectDirectory(
    String directoryRelativePath,
    String requestedRelativePath,
  ) async {
    String candidate = root.path;
    for (final String segment in directoryRelativePath.split('/')) {
      if (segment.isEmpty) continue;
      candidate = '$candidate${Platform.pathSeparator}$segment';
      final FileSystemEntityType type;
      try {
        type = await FileSystemEntity.type(candidate, followLinks: false);
      } on FileSystemException {
        throw _failure(
          'unreadable',
          'The requested parent directory could not be inspected.',
          relativePath: requestedRelativePath,
        );
      }
      if (type == FileSystemEntityType.link) {
        throw _pathAliasUnsupported(requestedRelativePath);
      }
      if (type == FileSystemEntityType.notFound) {
        throw _failure(
          'not_found',
          'The requested parent directory does not exist.',
          relativePath: requestedRelativePath,
        );
      }
      if (type != FileSystemEntityType.directory) {
        throw _failure(
          'not_directory',
          'The requested parent path is not a directory.',
          relativePath: requestedRelativePath,
        );
      }
    }
    final String resolved = await _resolve(
      candidate,
      requestedRelativePath,
      'parent directory',
    );
    if (resolved != candidate) {
      throw _pathAliasUnsupported(requestedRelativePath);
    }
    if (await FileSystemEntity.type(resolved, followLinks: true) !=
        FileSystemEntityType.directory) {
      throw _failure(
        'not_directory',
        'The requested parent path is not a directory.',
        relativePath: requestedRelativePath,
      );
    }
    return Directory(resolved);
  }

  Future<void> _verifyEmptyReservation(File file, String relativePath) async {
    await _verifyStillDirectRegularFile(file, relativePath);
    final Uint8List bytes = await _readBounded(file, relativePath);
    if (bytes.isNotEmpty) {
      throw _failure(
        'unwritable',
        'The requested file changed after its creation reservation.',
        relativePath: relativePath,
      );
    }
  }

  Future<void> _rejectSymbolicLinkComponents(String relativePath) async {
    String candidate = root.path;
    for (final String segment in relativePath.split('/')) {
      candidate = '$candidate${Platform.pathSeparator}$segment';
      final FileSystemEntityType type;
      try {
        type = await FileSystemEntity.type(candidate, followLinks: false);
      } on FileSystemException {
        throw _failure(
          'unreadable',
          'The requested file path could not be inspected.',
          relativePath: relativePath,
        );
      }
      if (type == FileSystemEntityType.link) {
        throw _pathAliasUnsupported(relativePath);
      }
      if (type == FileSystemEntityType.notFound) return;
    }
  }

  Future<void> _verifyStillDirectRegularFile(
    File file,
    String relativePath,
  ) async {
    await _rejectSymbolicLinkComponents(relativePath);
    final String resolved = await _resolve(file.path, relativePath, 'file');
    if (resolved != file.path) {
      throw _pathAliasUnsupported(relativePath);
    }
    if (await FileSystemEntity.type(resolved, followLinks: true) !=
        FileSystemEntityType.file) {
      throw _failure(
        'not_regular_file',
        'The requested path changed kind while it was being read.',
        relativePath: relativePath,
      );
    }
  }

  Future<Directory> _resolveDirectory(String relativePath) async {
    final String candidate = _candidate(relativePath);
    await _requireExisting(candidate, relativePath, 'directory');
    final String resolved = await _resolve(
      candidate,
      relativePath,
      'directory',
    );
    if (await FileSystemEntity.type(resolved, followLinks: true) !=
        FileSystemEntityType.directory) {
      throw _failure(
        'not_directory',
        'The requested path is not a directory.',
        relativePath: relativePath,
      );
    }
    return Directory(resolved);
  }

  Future<void> _requireExisting(
    String candidate,
    String relativePath,
    String kind,
  ) async {
    final FileSystemEntityType initialType;
    try {
      initialType = await FileSystemEntity.type(candidate, followLinks: false);
    } on FileSystemException {
      throw _failure(
        'unreadable',
        'The requested $kind could not be inspected.',
        relativePath: relativePath,
      );
    }
    if (initialType == FileSystemEntityType.notFound) {
      throw _failure(
        'not_found',
        'The requested $kind does not exist.',
        relativePath: relativePath,
      );
    }
  }

  Future<String> _resolve(
    String candidate,
    String relativePath,
    String kind,
  ) async {
    final String resolved;
    try {
      resolved = await File(candidate).resolveSymbolicLinks();
    } on FileSystemException {
      throw _failure(
        'unreadable',
        'The requested $kind could not be resolved.',
        relativePath: relativePath,
      );
    }
    if (!_isWithinRoot(resolved)) {
      throw _failure(
        'outside_root',
        'The requested path resolves outside the Environment root.',
        relativePath: relativePath,
      );
    }
    return resolved;
  }

  Future<Uint8List> _readBounded(File file, String relativePath) async {
    final RandomAccessFile opened = await file.open();
    try {
      final int initialLength = await opened.length();
      if (initialLength > maximumEnvironmentFileBytes) {
        throw _failure(
          'file_too_large',
          'The requested file exceeds the supported size.',
          relativePath: relativePath,
          limit: maximumEnvironmentFileBytes,
        );
      }
      Uint8List buffer = Uint8List(
        math.max(
          1,
          math.min(
            maximumEnvironmentFileBytes + 1,
            math.min(initialLength + 1, _maximumInitialReadBufferBytes),
          ),
        ),
      );
      int count = 0;
      while (true) {
        if (count == buffer.length) {
          final int nextLength = math.min(
            maximumEnvironmentFileBytes + 1,
            buffer.length * 2,
          );
          final Uint8List grown = Uint8List(nextLength)
            ..setRange(0, count, buffer);
          buffer = grown;
        }
        final int read = await opened.readInto(buffer, count, buffer.length);
        if (read == 0) break;
        count += read;
        if (count > maximumEnvironmentFileBytes) {
          throw _failure(
            'file_too_large',
            'The requested file exceeds the supported size.',
            relativePath: relativePath,
            limit: maximumEnvironmentFileBytes,
          );
        }
      }
      return Uint8List.sublistView(buffer, 0, count);
    } finally {
      await opened.close();
    }
  }

  Future<void> _verifyStillConfined(
    FileSystemEntity entity,
    String relativePath,
    FileSystemEntityType expectedType,
  ) async {
    final String resolved;
    try {
      resolved = await entity.resolveSymbolicLinks();
    } on FileSystemException {
      throw _failure(
        'unreadable',
        'The requested path changed while it was being read.',
        relativePath: relativePath,
      );
    }
    if (!_isWithinRoot(resolved)) {
      throw _failure(
        'outside_root',
        'The requested path resolves outside the Environment root.',
        relativePath: relativePath,
      );
    }
    if (await FileSystemEntity.type(resolved, followLinks: true) !=
        expectedType) {
      throw _failure(
        expectedType == FileSystemEntityType.file
            ? 'not_regular_file'
            : 'not_directory',
        'The requested path changed kind while it was being read.',
        relativePath: relativePath,
      );
    }
  }

  String _candidate(String relativePath) => relativePath.isEmpty
      ? root.path
      : <String>[
          root.path,
          ...relativePath.split('/'),
        ].join(Platform.pathSeparator);

  bool _isWithinRoot(String path) {
    final String rootPrefix = root.path.endsWith(Platform.pathSeparator)
        ? root.path
        : '${root.path}${Platform.pathSeparator}';
    return path == root.path || path.startsWith(rootPrefix);
  }
}

EnvironmentFailure _pathAliasUnsupported(String relativePath) => _failure(
  'path_alias_unsupported',
  'Symbolic-link aliases are not supported for direct file access.',
  relativePath: relativePath,
);

EnvironmentFailure _revisionConflict(String relativePath) => _failure(
  environmentRevisionConflictCode,
  'The file changed since the expected revision was observed.',
  relativePath: relativePath,
);

String _decodeText(List<int> bytes, String relativePath) {
  try {
    return utf8.decode(bytes, allowMalformed: false);
  } on FormatException {
    throw _failure(
      'invalid_utf8',
      'The requested file is not valid UTF-8 text.',
      relativePath: relativePath,
    );
  }
}

String _revision(List<int> bytes) => sha256.convert(bytes).toString();

Future<void> _applyPosixPermissions(File file, int permissions) async {
  if (Platform.isWindows) return;
  final ProcessResult result;
  try {
    result = await Process.run('chmod', <String>[
      permissions.toRadixString(8),
      file.path,
    ]);
  } on ProcessException catch (error) {
    throw FileSystemException(
      'Could not preserve replacement file permissions: ${error.message}',
      file.path,
    );
  }
  if (result.exitCode != 0) {
    throw FileSystemException(
      'Could not preserve replacement file permissions.',
      file.path,
    );
  }
}

Future<void> _deleteBestEffort(Directory directory) async {
  try {
    if (await directory.exists()) await directory.delete(recursive: true);
  } on FileSystemException {
    // Staging cleanup must not replace the mutation's result or failure.
  }
}

Directory _canonicalRoot(Directory sourceRoot) {
  final String path;
  try {
    path = sourceRoot.absolute.resolveSymbolicLinksSync();
  } on FileSystemException {
    throw ArgumentError.value(sourceRoot.path, 'root', 'Must exist.');
  }
  if (FileSystemEntity.typeSync(path, followLinks: true) !=
      FileSystemEntityType.directory) {
    throw ArgumentError.value(sourceRoot.path, 'root', 'Must be a directory.');
  }
  return Directory(path);
}

String _normalizeRelativePath(String value, {bool allowRoot = false}) {
  if (value.startsWith('/') ||
      (Platform.isWindows &&
          (value.startsWith('\\') || value.contains('\\'))) ||
      value.contains('\u0000') ||
      (Platform.isWindows && RegExp(r'^[A-Za-z]:').hasMatch(value)) ||
      (Platform.isWindows &&
          (value.contains(':') ||
              value.split('/').any(_isUnsupportedWindowsPathSegment)))) {
    throw _failure(
      'invalid_path',
      'An Environment-relative path using forward slashes is required.',
      relativePath: value,
    );
  }
  final List<String> segments = <String>[];
  for (final String segment in value.split('/')) {
    if (segment.isEmpty || segment == '.') continue;
    if (segment == '..') {
      throw _failure(
        'invalid_path',
        'Parent traversal is not allowed.',
        relativePath: value,
      );
    }
    segments.add(segment);
  }
  if (segments.isEmpty && !allowRoot) {
    throw _failure(
      'invalid_path',
      'The path must identify a file beneath the Environment root.',
      relativePath: value,
    );
  }
  return segments.join('/');
}

bool _isUnsupportedWindowsPathSegment(String segment) {
  if (segment.endsWith('.') || segment.endsWith(' ')) return true;
  final String base = segment.split('.').first.toUpperCase();
  return const <String>{'CON', 'PRN', 'AUX', 'NUL'}.contains(base) ||
      RegExp(r'^(COM|LPT)[1-9]$').hasMatch(base);
}

String _entityName(String path) {
  final List<String> parts = path.split(Platform.pathSeparator);
  return parts.lastWhere((String part) => part.isNotEmpty);
}

EnvironmentFailure _failure(
  String code,
  String message, {
  required String relativePath,
  int? limit,
}) => EnvironmentFailure(
  code: code,
  message: message,
  details: <String, Object?>{'relativePath': relativePath, 'limit': ?limit},
);
