import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:adele_environment/adele_environment.dart';

const int maximumEnvironmentFileBytes = 1024 * 1024;
const int maximumEnvironmentDirectoryEntries = 2048;
const int _maximumInitialReadBufferBytes = 64 * 1024;

final class WorktreeEnvironment {
  WorktreeEnvironment(Directory root) : root = _canonicalRoot(root);

  final Directory root;

  Future<EnvironmentTextFile> readFile(String relativePath) async {
    final String normalized = _normalizeRelativePath(relativePath);
    final File file = await _resolveRegularFile(normalized);
    try {
      final Uint8List bytes = await _readBounded(file, normalized);
      await _verifyStillConfined(file, normalized, FileSystemEntityType.file);
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

  Future<EnvironmentDirectoryListing> readDirectory(String relativePath) async {
    final String normalized = _normalizeRelativePath(
      relativePath,
      allowRoot: true,
    );
    final Directory directory = await _resolveDirectory(normalized);
    final List<FileSystemEntity> entities = <FileSystemEntity>[];
    try {
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

  Future<File> _resolveRegularFile(String relativePath) async {
    final String candidate = _candidate(relativePath);
    await _requireExisting(candidate, relativePath, 'file');
    final String resolved = await _resolve(candidate, relativePath, 'file');
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
      value.startsWith('\\') ||
      value.contains('\\') ||
      value.contains('\u0000') ||
      RegExp(r'^[A-Za-z]:').hasMatch(value) ||
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
