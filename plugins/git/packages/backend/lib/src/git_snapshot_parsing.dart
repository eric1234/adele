import 'package:diff_viewer_contract/diff_viewer_contract.dart';

typedef GitIndexEntry = ({
  String oldMode,
  String newMode,
  String oid,
  String kind,
});

/// Parses public ls-files --cached --stage --debug -z output. Paths end at NUL;
/// fixed metadata follows each path. Unknown metadata formats fail closed.
Map<String, GitIndexEntry> parseGitIndex(
  String raw, {
  int maximumEntries = 4096,
  bool windowsPaths = false,
}) {
  final changes = <String, GitIndexEntry>{};
  final header = RegExp(r'^([0-7]{6}) ([0-9a-f]{40}|[0-9a-f]{64}) ([0-3])$');
  final metadata = RegExp(
    r'  ctime: \d+:\d+\n  mtime: \d+:\d+\n  dev: \d+\tino: \d+\n  uid: \d+\tgid: \d+\n  size: \d+\tflags: ([0-9a-f]+)\n',
  );
  var offset = 0;
  var entries = 0;
  while (offset < raw.length) {
    if (++entries > maximumEntries) {
      throw _failure(
        'inventory_too_large',
        'The index inventory exceeds the supported entry count.',
      );
    }
    final nul = raw.indexOf('\u0000', offset);
    final tab = raw.indexOf('\t', offset);
    if (nul < 0 || tab < offset || tab > nul) throw _malformed();
    final match = header.firstMatch(raw.substring(offset, tab));
    if (match == null) throw _malformed();
    final path = raw.substring(tab + 1, nul);
    validateGitSnapshotPath(path, windowsPaths: windowsPaths);
    final stat = metadata.matchAsPrefix(raw, nul + 1);
    if (stat == null) throw _malformed();
    offset = stat.end;
    final flags = int.tryParse(stat[1]!, radix: 16);
    if (flags == null) throw _malformed();
    final oldMode = match[1]!;
    final intentToAdd = (flags & 0x20000000) != 0;
    final kind = match[3] != '0'
        ? 'conflicted'
        : (flags & 0x40008000) != 0 || oldMode == '160000'
        ? 'unsupported'
        : intentToAdd
        ? 'added'
        : 'modified';
    if (changes[path]?.kind == 'conflicted') continue;
    if (changes.containsKey(path) && kind != 'conflicted') throw _malformed();
    changes[path] = (
      oldMode: intentToAdd ? '000000' : oldMode,
      newMode: oldMode,
      oid: intentToAdd ? '' : match[2]!,
      kind: kind,
    );
  }
  return changes;
}

/// Adds ls-files --others -z records without collecting an unbounded record list.
/// Only this untracked output permits a nested repository's trailing slash.
void addGitUntrackedEntries(
  String raw,
  Map<String, GitIndexEntry> changes, {
  int maximumEntries = 4096,
  bool windowsPaths = false,
}) {
  var offset = 0;
  while (offset < raw.length) {
    final nul = raw.indexOf('\u0000', offset);
    if (nul < 0) throw _malformed();
    final record = raw.substring(offset, nul);
    offset = nul + 1;
    final directory = record.endsWith('/');
    final path = directory ? record.substring(0, record.length - 1) : record;
    validateGitSnapshotPath(path, windowsPaths: windowsPaths);
    if (changes.containsKey(path)) {
      throw _failure(
        'snapshot_changed',
        'A path changed index membership during enumeration.',
      );
    }
    if (changes.length >= maximumEntries) {
      throw _failure(
        'inventory_too_large',
        'The tracked and untracked inventory exceeds the supported entry count.',
      );
    }
    changes[path] = (
      oldMode: '000000',
      newMode: directory ? '040000' : '100644',
      oid: '',
      kind: directory ? 'untrackedRepository' : 'added',
    );
  }
}

/// Strict unified-hunk parser. Header path strings never establish path identity.
/// With [requireIndex] false, accepts stdin no-index patches without an index
/// header and ordinary old/new mode pairs; callers classify mode changes.
List<DiffHunk> parseGitPatch(
  String patch, {
  int maximumLines = 8192,
  bool requireIndex = true,
}) {
  if (patch.isEmpty) return [];
  if (!patch.endsWith('\n')) throw _malformed();
  final records = patch.substring(0, patch.length - 1).split('\n');
  final hunks = <DiffHunk>[];
  final header = RegExp(
    r'^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@(?: .*)?$',
  );
  var index = 0;
  var sawDiff = false;
  var sawOld = false;
  var sawNew = false;
  var sawMode = false;
  var sawIndex = false;
  while (index < records.length && !records[index].startsWith('@@')) {
    final line = records[index++];
    if (line.startsWith('diff --git ')) {
      if (sawDiff) throw _malformed();
      sawDiff = true;
    } else if (line.startsWith('index ')) {
      if (sawIndex ||
          !RegExp(
            r'^index [0-9a-f]+\.\.[0-9a-f]+(?: [0-7]{6})?$',
          ).hasMatch(line)) {
        throw _malformed();
      }
      sawIndex = true;
    } else if (line.startsWith('--- ')) {
      if (sawOld) throw _malformed();
      sawOld = true;
    } else if (line.startsWith('+++ ')) {
      if (sawNew) throw _malformed();
      sawNew = true;
    } else if (RegExp(r'^(?:new|deleted) file mode [0-7]{6}$').hasMatch(line)) {
      if (sawMode) throw _malformed();
      sawMode = true;
    } else if (!requireIndex &&
        RegExp(r'^old mode 100(?:644|755)$').hasMatch(line)) {
      if (sawMode || index == records.length) throw _malformed();
      final newMode = records[index++];
      if (!RegExp(r'^new mode 100(?:644|755)$').hasMatch(newMode) ||
          newMode.substring(9) == line.substring(9)) {
        throw _malformed();
      }
      sawMode = true;
    } else {
      throw _malformed();
    }
  }
  if (!sawDiff ||
      (requireIndex && !sawIndex) ||
      (index < records.length ? !(sawOld && sawNew) : !sawMode)) {
    throw _malformed();
  }
  var previousOldEnd = 0;
  var previousNewEnd = 0;
  var lineCount = 0;
  while (index < records.length) {
    final match = header.firstMatch(records[index++]);
    if (match == null) throw _malformed();
    final oldStart = int.tryParse(match[1]!);
    final newStart = int.tryParse(match[3]!);
    final oldCount = int.tryParse(match[2] ?? '1');
    final newCount = int.tryParse(match[4] ?? '1');
    if (oldStart == null ||
        newStart == null ||
        oldCount == null ||
        newCount == null ||
        oldStart < previousOldEnd ||
        newStart < previousNewEnd ||
        (oldCount > 0 && oldStart == 0) ||
        (newCount > 0 && newStart == 0)) {
      throw _malformed();
    }
    var oldSeen = 0;
    var newSeen = 0;
    final lines = <DiffLine>[];
    while (index < records.length && !records[index].startsWith('@@')) {
      final line = records[index++];
      if (line == r'\ No newline at end of file') {
        if (lines.isEmpty || lines.last.noNewline) throw _malformed();
        final previous = lines.removeLast();
        lines.add(
          DiffLine(kind: previous.kind, text: previous.text, noNewline: true),
        );
        continue;
      }
      if (line.isEmpty) throw _malformed();
      if (++lineCount > maximumLines) {
        throw _failure(
          'snapshot_too_large',
          'The change snapshot exceeds its line limit.',
        );
      }
      final kind = switch (line[0]) {
        ' ' => 'context',
        '+' => 'addition',
        '-' => 'deletion',
        _ => throw _malformed(),
      };
      if (kind != 'addition') oldSeen++;
      if (kind != 'deletion') newSeen++;
      if (oldSeen > oldCount || newSeen > newCount) throw _malformed();
      lines.add(
        DiffLine(kind: kind, text: line.substring(1), noNewline: false),
      );
    }
    if (oldSeen != oldCount || newSeen != newCount || lines.isEmpty) {
      throw _malformed();
    }
    hunks.add(
      DiffHunk(
        oldStart: oldStart,
        oldCount: oldCount,
        newStart: newStart,
        newCount: newCount,
        lines: lines,
      ),
    );
    previousOldEnd = oldStart + oldCount;
    previousNewEnd = newStart + newCount;
  }
  return hunks;
}

/// Validates an inventory path using the inspected Environment's path rules.
void validateGitSnapshotPath(String path, {bool windowsPaths = false}) {
  if (path.isEmpty ||
      path.startsWith('/') ||
      path.contains('\u0000') ||
      path
          .split('/')
          .any((part) => part.isEmpty || part == '.' || part == '..') ||
      (windowsPaths && (path.contains('\\') || path.contains(':')))) {
    throw _malformed();
  }
}

ChangeSetFailure _failure(String code, String message) =>
    ChangeSetFailure(code: code, message: message);
ChangeSetFailure _malformed() => _failure(
  'invalid_git_output',
  'Git returned an unsupported or malformed change description.',
);
