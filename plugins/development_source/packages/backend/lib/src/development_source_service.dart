import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:development_source_contract/development_source_contract.dart';

const int maximumDevelopmentSourceFileBytes = 1024 * 1024;
const int maximumDevelopmentSourceSearchMatches = 100;
const int maximumDevelopmentSourceSnippetCodeUnits = 500;
const int maximumDevelopmentSourceQueryCodeUnits = 256;
const int maximumDevelopmentSourceSearchEntries = 10000;
const int maximumDevelopmentSourceDirectoryEntries = 2048;
const int maximumDevelopmentSourceSearchBytes = 16 * 1024 * 1024;
const Set<String> developmentSourceExcludedDirectoryNames = <String>{
  '.git',
  '.dart_tool',
  'build',
};

final class LocalDevelopmentSourceService implements DevelopmentSourceService {
  LocalDevelopmentSourceService(Directory sourceRoot)
    : _root = _canonicalRoot(sourceRoot);

  final Directory _root;

  @override
  Future<DevelopmentSourceTextFile> readTextFile(String relativePath) async {
    final String normalized = _normalizeRelativePath(relativePath);
    final File file = await _resolveRegularFile(normalized);
    try {
      final Uint8List bytes = await _readBounded(file, normalized);
      await _verifyStillConfinedRegularFile(file, normalized);
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
      return DevelopmentSourceTextFile(
        relativePath: normalized,
        text: text,
        sizeBytes: bytes.length,
      );
    } on DevelopmentSourceFailure {
      rethrow;
    } on FileSystemException {
      throw _failure(
        'unreadable',
        'The requested file could not be read.',
        relativePath: normalized,
      );
    }
  }

  @override
  Future<DevelopmentSourceSearchResult> searchText(String literalText) async {
    if (literalText.isEmpty ||
        literalText.length > maximumDevelopmentSourceQueryCodeUnits ||
        literalText.contains('\u0000') ||
        literalText.contains('\n') ||
        literalText.contains('\r')) {
      throw _failure(
        'invalid_query',
        'The search text must be one non-empty line within the supported limit.',
        limit: maximumDevelopmentSourceQueryCodeUnits,
      );
    }

    final List<DevelopmentSourceSearchMatch> matches =
        <DevelopmentSourceSearchMatch>[];
    final _SearchBudget budget = _SearchBudget();
    final bool truncated = await _searchDirectory(
      _root,
      '',
      literalText,
      matches,
      budget,
    );
    return DevelopmentSourceSearchResult(
      matches: matches,
      truncated: truncated,
    );
  }

  Future<bool> _searchDirectory(
    Directory directory,
    String relativeDirectory,
    String query,
    List<DevelopmentSourceSearchMatch> matches,
    _SearchBudget budget,
  ) async {
    final List<FileSystemEntity> entries = <FileSystemEntity>[];
    try {
      await for (final FileSystemEntity entry in directory.list(
        followLinks: false,
      )) {
        entries.add(entry);
        if (entries.length > maximumDevelopmentSourceDirectoryEntries) {
          return true;
        }
      }
    } on FileSystemException {
      return false;
    }
    if (!budget.consumeEntries(entries.length)) return true;
    entries.sort((FileSystemEntity left, FileSystemEntity right) {
      return _entityName(left.path).compareTo(_entityName(right.path));
    });

    for (final FileSystemEntity entry in entries) {
      final String name = _entityName(entry.path);
      if (name.contains('\\')) continue;
      final String relativePath = relativeDirectory.isEmpty
          ? name
          : '$relativeDirectory/$name';
      try {
        _normalizeRelativePath(relativePath);
      } on DevelopmentSourceFailure {
        continue;
      }
      final FileSystemEntityType type;
      try {
        type = await FileSystemEntity.type(entry.path, followLinks: false);
      } on FileSystemException {
        continue;
      }
      if (type == FileSystemEntityType.directory) {
        if (developmentSourceExcludedDirectoryNames.contains(name)) continue;
        if (await _searchDirectory(
          Directory(entry.path),
          relativePath,
          query,
          matches,
          budget,
        )) {
          return true;
        }
      } else if (type == FileSystemEntityType.file) {
        if (await _searchFile(relativePath, query, matches, budget)) {
          return true;
        }
      }
    }
    return false;
  }

  Future<bool> _searchFile(
    String relativePath,
    String query,
    List<DevelopmentSourceSearchMatch> matches,
    _SearchBudget budget,
  ) async {
    try {
      final File file = await _resolveRegularFile(relativePath);
      final int length = await file.length();
      if (length > maximumDevelopmentSourceFileBytes) return false;
      if (!budget.canScanBytes(length)) return true;
      final Uint8List bytes = await _readBounded(file, relativePath);
      if (!budget.consumeBytes(bytes.length)) return true;
      await _verifyStillConfinedRegularFile(file, relativePath);
      final String text = utf8.decode(bytes, allowMalformed: false);
      final List<String> lines = const LineSplitter().convert(text);
      for (int index = 0; index < lines.length; index++) {
        final int matchIndex = lines[index].indexOf(query);
        if (matchIndex < 0) continue;
        if (matches.length == maximumDevelopmentSourceSearchMatches) {
          return true;
        }
        matches.add(
          DevelopmentSourceSearchMatch(
            relativePath: relativePath,
            lineNumber: index + 1,
            snippet: _boundedSnippet(lines[index], matchIndex, query.length),
          ),
        );
      }
    } on DevelopmentSourceFailure {
      // A skipped search file may disappear, change kind, or exceed the bound.
    } on FileSystemException {
      // Unreadable files do not make the whole search fail.
    } on FormatException {
      // Search deliberately skips unusable files instead of failing the query.
    }
    return false;
  }

  Future<File> _resolveRegularFile(String relativePath) async {
    final String candidate = <String>[
      _root.path,
      ...relativePath.split('/'),
    ].join(Platform.pathSeparator);
    final FileSystemEntityType initialType;
    try {
      initialType = await FileSystemEntity.type(candidate, followLinks: false);
    } on FileSystemException {
      throw _failure(
        'unreadable',
        'The requested path could not be inspected.',
        relativePath: relativePath,
      );
    }
    if (initialType == FileSystemEntityType.notFound) {
      throw _failure(
        'not_found',
        'The requested file does not exist.',
        relativePath: relativePath,
      );
    }

    final String resolved;
    try {
      resolved = await File(candidate).resolveSymbolicLinks();
    } on FileSystemException {
      throw _failure(
        'unreadable',
        'The requested path could not be resolved.',
        relativePath: relativePath,
      );
    }
    if (!_isWithinRoot(resolved)) {
      throw _failure(
        'outside_root',
        'The requested file resolves outside the configured source root.',
        relativePath: relativePath,
      );
    }
    final FileSystemEntityType resolvedType;
    try {
      resolvedType = await FileSystemEntity.type(resolved, followLinks: true);
    } on FileSystemException {
      throw _failure(
        'unreadable',
        'The requested path could not be inspected.',
        relativePath: relativePath,
      );
    }
    if (resolvedType != FileSystemEntityType.file) {
      throw _failure(
        'not_regular_file',
        'The requested path is not a regular file.',
        relativePath: relativePath,
      );
    }
    return File(resolved);
  }

  Future<Uint8List> _readBounded(File file, String relativePath) async {
    final RandomAccessFile opened = await file.open();
    try {
      if (await opened.length() > maximumDevelopmentSourceFileBytes) {
        throw _failure(
          'file_too_large',
          'The requested file exceeds the supported size.',
          relativePath: relativePath,
          limit: maximumDevelopmentSourceFileBytes,
        );
      }
      final Uint8List buffer = Uint8List(maximumDevelopmentSourceFileBytes + 1);
      int count = 0;
      while (count < buffer.length) {
        final int read = await opened.readInto(buffer, count, buffer.length);
        if (read == 0) break;
        count += read;
      }
      if (count > maximumDevelopmentSourceFileBytes) {
        throw _failure(
          'file_too_large',
          'The requested file exceeds the supported size.',
          relativePath: relativePath,
          limit: maximumDevelopmentSourceFileBytes,
        );
      }
      return Uint8List.sublistView(buffer, 0, count);
    } finally {
      await opened.close();
    }
  }

  Future<void> _verifyStillConfinedRegularFile(
    File file,
    String relativePath,
  ) async {
    final String resolved;
    try {
      resolved = await file.resolveSymbolicLinks();
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
        'The requested file resolves outside the configured source root.',
        relativePath: relativePath,
      );
    }
    if (await FileSystemEntity.type(resolved, followLinks: true) !=
        FileSystemEntityType.file) {
      throw _failure(
        'not_regular_file',
        'The requested path is not a regular file.',
        relativePath: relativePath,
      );
    }
  }

  bool _isWithinRoot(String path) {
    final String root = Platform.isWindows
        ? _root.path.toLowerCase()
        : _root.path;
    final String candidate = Platform.isWindows ? path.toLowerCase() : path;
    final String rootPrefix = root.endsWith(Platform.pathSeparator)
        ? root
        : '$root${Platform.pathSeparator}';
    return candidate == root || candidate.startsWith(rootPrefix);
  }
}

Directory _canonicalRoot(Directory sourceRoot) {
  final String path;
  try {
    path = sourceRoot.absolute.resolveSymbolicLinksSync();
  } on FileSystemException {
    throw ArgumentError.value(sourceRoot.path, 'sourceRoot', 'Must exist.');
  }
  if (FileSystemEntity.typeSync(path, followLinks: true) !=
      FileSystemEntityType.directory) {
    throw ArgumentError.value(
      sourceRoot.path,
      'sourceRoot',
      'Must be a directory.',
    );
  }
  return Directory(path);
}

String _normalizeRelativePath(String value) {
  if (value.isEmpty ||
      value.startsWith('/') ||
      value.startsWith('\\') ||
      value.contains('\\') ||
      value.contains('\u0000') ||
      RegExp(r'^[A-Za-z]:').hasMatch(value) ||
      (Platform.isWindows &&
          (value.contains(':') ||
              value.split('/').any(_isUnsupportedWindowsPathSegment)))) {
    throw _failure(
      'invalid_path',
      'A root-relative path using forward slashes is required.',
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
  if (segments.isEmpty) {
    throw _failure(
      'invalid_path',
      'The path must identify a file beneath the configured source root.',
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

String _boundedSnippet(String line, int matchStart, int matchLength) {
  if (line.length <= maximumDevelopmentSourceSnippetCodeUnits) return line;
  final int context =
      (maximumDevelopmentSourceSnippetCodeUnits - matchLength) ~/ 2;
  int start = math.max(0, matchStart - context);
  int end = math.min(
    line.length,
    start + maximumDevelopmentSourceSnippetCodeUnits,
  );
  start = math.max(0, end - maximumDevelopmentSourceSnippetCodeUnits);
  if (start > 0 && _isLowSurrogate(line.codeUnitAt(start))) start++;
  if (end < line.length && _isHighSurrogate(line.codeUnitAt(end - 1))) end--;
  return line.substring(start, end);
}

bool _isHighSurrogate(int codeUnit) => codeUnit >= 0xd800 && codeUnit <= 0xdbff;
bool _isLowSurrogate(int codeUnit) => codeUnit >= 0xdc00 && codeUnit <= 0xdfff;

final class _SearchBudget {
  int _remainingEntries = maximumDevelopmentSourceSearchEntries;
  int _remainingBytes = maximumDevelopmentSourceSearchBytes;

  bool consumeEntries(int count) {
    if (count > _remainingEntries) return false;
    _remainingEntries -= count;
    return true;
  }

  bool canScanBytes(int count) => count <= _remainingBytes;

  bool consumeBytes(int count) {
    if (count > _remainingBytes) return false;
    _remainingBytes -= count;
    return true;
  }
}

DevelopmentSourceFailure _failure(
  String code,
  String message, {
  String? relativePath,
  int? limit,
}) => DevelopmentSourceFailure(
  code: code,
  message: message,
  details: <String, Object?>{'relativePath': ?relativePath, 'limit': ?limit},
);
