import 'dart:convert';
import 'dart:io';

import 'package:session_evaluator_contract/session_evaluator_contract.dart';

/// Write only to a newly allocated private directory, never a previous handoff.
/// Failure cleanup is best effort, not crash recovery or power-loss durability.
Future<Directory> writeSessionEvaluationHandoff(
  Directory outputRoot,
  List<int> bytes, {
  required List<int> summaryBytes,
  required String readme,
  required void Function() validate,
  required Iterable<Directory> excludedDirectories,
}) async {
  if (bytes.length > sessionEvidenceMaxBytes) {
    throw const FormatException('Session evidence exceeds its byte bound.');
  }
  final excluded = excludedDirectories
      .map((directory) => Directory(_resolvedOutputPath(directory)))
      .toList();
  void validateLocation(Directory directory) {
    final path = _resolvedOutputPath(directory);
    // Reject any enclosing checkout, not just a selected nested source scope.
    var ancestor = Directory(path);
    while (true) {
      if (FileSystemEntity.typeSync(
            '${ancestor.path}${Platform.pathSeparator}.git',
            followLinks: false,
          ) !=
          FileSystemEntityType.notFound) {
        throw StateError('Evaluation output must be outside source checkouts.');
      }
      final parent = ancestor.parent;
      if (parent.path == ancestor.path) break;
      ancestor = parent;
    }
    final segments = Directory(path).uri.pathSegments;
    if (excluded.any(
          (root) =>
              path == root.path ||
              path.startsWith(
                root.path.endsWith(Platform.pathSeparator)
                    ? root.path
                    : '${root.path}${Platform.pathSeparator}',
              ),
        ) ||
        List.generate(segments.length - 1, (index) => index).any(
          (index) =>
              segments[index] == '.adele' && segments[index + 1] == 'worktrees',
        )) {
      throw StateError('Evaluation output must be outside source checkouts.');
    }
    validate();
  }

  Directory? destination;
  var complete = false;
  try {
    validateLocation(outputRoot);
    final root = Directory(_resolvedOutputPath(outputRoot));
    await root.create(recursive: true);
    validateLocation(root);
    destination = await root.createTemp('session-');
    validateLocation(destination);
    if (Platform.isLinux || Platform.isMacOS) {
      // Dart's createTemp uses the umask, not necessarily owner-only access.
      final permissions = await Process.run('chmod', ['700', destination.path]);
      if (permissions.exitCode != 0) {
        throw FileSystemException('Could not protect the handoff directory.');
      }
      validateLocation(destination);
    }
    await File(
      '${destination.path}${Platform.pathSeparator}evidence.json',
    ).writeAsBytes(bytes, flush: true);
    validateLocation(destination);
    await File(
      '${destination.path}${Platform.pathSeparator}summary.json',
    ).writeAsBytes(summaryBytes, flush: true);
    validateLocation(destination);
    await File(
      '${destination.path}${Platform.pathSeparator}README.md',
    ).writeAsBytes(utf8.encode(readme), flush: true);
    validateLocation(destination);
    complete = true;
    return destination;
  } finally {
    if (!complete && destination != null) {
      try {
        await destination.delete(recursive: true);
      } on FileSystemException {
        // Never report success for incomplete output, even if cleanup fails.
      }
    }
  }
}

// Resolve existing ancestors before creating anything, including output aliases
// into a checkout. Missing final components are appended without filesystem I/O.
String _resolvedOutputPath(Directory directory) {
  var absolute = Directory.fromUri(directory.absolute.uri.normalizePath());
  // A trailing separator makes lstat follow a directory symlink on POSIX.
  // Inspect the entry itself so a dangling alias is not treated as absent.
  if (absolute.path.endsWith(Platform.pathSeparator) &&
      absolute.parent.path != absolute.path) {
    absolute = Directory(absolute.path.substring(0, absolute.path.length - 1));
  }
  if (FileSystemEntity.typeSync(absolute.path, followLinks: false) !=
      FileSystemEntityType.notFound) {
    return absolute.resolveSymbolicLinksSync();
  }
  final parent = absolute.parent;
  if (parent.path == absolute.path) {
    throw FileSystemException('Missing output filesystem root.');
  }
  final name = absolute.uri.pathSegments.where((part) => part.isNotEmpty).last;
  return Directory.fromUri(
    Directory(
      _resolvedOutputPath(parent),
    ).uri.resolveUri(Uri(pathSegments: [name, ''])),
  ).path;
}
