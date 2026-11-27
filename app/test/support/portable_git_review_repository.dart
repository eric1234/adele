import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

const selectedBranch = 'selected-task';
const selectedBranchRef = 'refs/heads/$selectedBranch';
const newFileReviewPath = "new review + [file]; 'quoted'.txt";
const deletedFileReviewPath = "deleted review + [file]; 'quoted'.txt";

Future<String> runGit(
  Directory root,
  List<String> arguments, {
  int exitCode = 0,
  bool trim = true,
}) async {
  final result = await Process.run(
    '/usr/bin/git',
    arguments,
    workingDirectory: root.path,
  );
  expect(
    result.exitCode,
    exitCode,
    reason: '${result.stdout}\n${result.stderr}',
  );
  final output = result.stdout as String;
  return trim ? output.trim() : output;
}

String reviewContent(String id, {bool first = false, bool second = false}) =>
    '${List.generate(30, (index) {
      if (index == 3 && first) return '$id first change';
      if (index == 24 && second) return '$id second change';
      return '$id line $index';
    }).join('\n')}\n';

String fileReviewContent(
  String id, {
  bool staged = false,
  bool changed = false,
}) => [
  for (var index = 0; index < 90; index++) ...[
    if (index == 32 && changed) ...[
      '$id inserted first',
      '$id inserted second',
    ],
    if (!changed || (index != 54 && index != 55))
      if (index == 16 && staged)
        '$id staged change'
      else if (index == 76 && changed)
        '$id final replacement'
      else
        '$id line $index',
  ],
  '',
].join('\n');

String reviewBlobOid(String content) {
  final bytes = utf8.encode(content);
  return sha1.convert([
    ...utf8.encode('blob ${bytes.length}\u0000'),
    ...bytes,
  ]).toString();
}

Map<String, String> layerReviewContents(String id, {required bool approved}) =>
    {
      if (!approved) deletedFileReviewPath: '$id deleted layer\n',
      if (approved) newFileReviewPath: '$id added layer\n',
      'review.txt': fileReviewContent(id, staged: approved, changed: approved),
      'untouched.txt': approved ? '$id staged sentinel\n' : '$id sentinel\n',
      'z-other.txt': approved ? '$id other working\n' : '$id other baseline\n',
    };

void expectLayerReviewIndex(
  Map<String, Map<String, Object>> actual,
  Map<String, Map<String, Object>> before, {
  required bool approved,
}) {
  final contents = layerReviewContents('additional', approved: approved);
  final paths = contents.keys.toList()..sort();
  expect(actual, {
    ...before,
    'additional': {
      ...before['additional']!,
      'index': paths
          .map(
            (path) => '100644 ${reviewBlobOid(contents[path]!)} 0\t$path\u0000',
          )
          .join(),
    },
  });
}

Future<Map<String, Map<String, Object>>> reviewStates(
  Map<String, String> roots,
) async {
  final result = <String, Map<String, Object>>{};
  for (final entry in roots.entries) {
    final root = Directory(entry.value);
    final hashes = <String, String>{};
    final workingBytes = <String, String>{};
    final workingModes = <String, int>{};
    await for (final entity in root.list(recursive: true, followLinks: false)) {
      final path = entity.path.substring(root.path.length + 1);
      if (path == '.git' || path.startsWith('.git/')) continue;
      expect(entity, isA<File>(), reason: 'Unexpected worktree entry: $path');
      final bytes = await File(entity.path).readAsBytes();
      hashes[path] = sha256.convert(bytes).toString();
      workingBytes[path] = base64Encode(bytes);
      workingModes[path] = (await entity.stat()).mode;
    }
    result[entry.key] = {
      'head': await runGit(root, ['rev-parse', 'HEAD']),
      'branch': await runGit(root, ['symbolic-ref', 'HEAD']),
      'refs': await runGit(root, ['show-ref']),
      'index': await runGit(root, ['ls-files', '--stage', '-z']),
      'workingHashes': hashes,
      'workingBytes': workingBytes,
      'workingModes': workingModes,
    };
  }
  return result;
}

void expectReviewIndex(
  Map<String, Map<String, Object>> actual,
  Map<String, Map<String, Object>> before,
  String environment,
  String expectedContent, {
  String? originalContent,
}) {
  final oldOid = reviewBlobOid(originalContent ?? reviewContent(environment));
  final newOid = reviewBlobOid(expectedContent);
  expect(newOid, matches(RegExp(r'^[0-9a-f]{40}$')));
  expect(newOid, isNot(oldOid));
  expect(
    before[environment]!['index'],
    contains('$oldOid 0\treview.txt\u0000'),
  );
  expect(actual, {
    ...before,
    environment: {
      ...before[environment]!,
      'index': (before[environment]!['index']! as String).replaceFirst(
        '$oldOid 0\treview.txt\u0000',
        '$newOid 0\treview.txt\u0000',
      ),
    },
  });
}

List<Map<Object?, Object?>> reviewWrites(Map<Object?, Object?> evidence) =>
    (evidence['processes'] as List).cast<Map<Object?, Object?>>().where((
      process,
    ) {
      final arguments = process['arguments'] as List;
      return arguments.contains('apply') &&
          arguments.contains('--cached') &&
          !arguments.contains('--check');
    }).toList();
