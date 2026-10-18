import 'package:diff_viewer_contract/diff_viewer_contract.dart';
import 'package:git_backend/src/git_change_set_source.dart' as legacy;
import 'package:git_backend/src/git_snapshot_parsing.dart';
import 'package:test/test.dart';

void main() {
  test('legacy imports retain the extracted index types and parsers', () {
    final raw = _indexRecord('dir/space tab\tnewline\n');
    final entries = parseGitIndex(raw);
    final Map<String, legacy.GitIndexEntry> legacyEntries = legacy
        .parseGitIndex(raw);
    expect(legacyEntries, entries);
    const untracked = 'new\u0000nested/repository/\u0000';
    addGitUntrackedEntries(untracked, entries);
    legacy.addGitUntrackedEntries(untracked, legacyEntries);
    expect(legacyEntries, entries);
    expect(entries['nested/repository']!.kind, 'untrackedRepository');
    expect(
      () => legacy.parseGitIndex(raw, maximumEntries: 0),
      throwsA(_code('inventory_too_large')),
    );
    expect(
      () => legacy.addGitUntrackedEntries('extra\u0000', {}, maximumEntries: 0),
      throwsA(_code('inventory_too_large')),
    );
  });

  test('inventory path rules are explicit rather than host dependent', () {
    for (final path in [r'dir\file', 'drive:name']) {
      expect(parseGitIndex(_indexRecord(path)).keys, [path]);
      final entries = <String, GitIndexEntry>{};
      addGitUntrackedEntries('$path\u0000', entries);
      expect(entries.keys, [path]);
      expect(
        () => parseGitIndex(_indexRecord(path), windowsPaths: true),
        throwsA(_code('invalid_git_output')),
      );
      expect(
        () => addGitUntrackedEntries('$path\u0000', {}, windowsPaths: true),
        throwsA(_code('invalid_git_output')),
      );
    }
    for (final windowsPaths in [false, true]) {
      for (final path in ['', '/absolute', '../escape', 'a//b', 'a/./b']) {
        expect(
          () => parseGitIndex(_indexRecord(path), windowsPaths: windowsPaths),
          throwsA(_code('invalid_git_output')),
        );
        expect(
          () => addGitUntrackedEntries(
            '$path\u0000',
            {},
            windowsPaths: windowsPaths,
          ),
          throwsA(_code('invalid_git_output')),
        );
      }
    }
  });

  const diff = 'diff --git - ./file\n';
  const paths = '--- -\n+++ ./file\n';
  const content = '@@ -1 +1 @@\n-old\r\n+new\n\\ No newline at end of file\n';
  const noIndex = '$diff$paths$content';

  test('stdin patches opt out of the otherwise required index header', () {
    expect(() => parseGitPatch(noIndex), throwsA(_code('invalid_git_output')));
    expect(
      () => legacy.parseGitPatch(noIndex),
      throwsA(_code('invalid_git_output')),
    );
    final hunk = parseGitPatch(noIndex, requireIndex: false).single;
    expect(
      (hunk.oldStart, hunk.oldCount, hunk.newStart, hunk.newCount),
      (1, 1, 1, 1),
    );
    expect(hunk.lines.map((line) => line.text), ['old\r', 'new']);
    expect(hunk.lines.map((line) => line.noNewline), [false, true]);
    expect(
      legacy.parseGitPatch('${diff}index 123..456 100644\n$paths$content'),
      hasLength(1),
    );
  });

  test('stdin patches accept only paired ordinary mode changes', () {
    for (final (oldMode, newMode) in [
      ('100644', '100755'),
      ('100755', '100644'),
    ]) {
      final modes = 'old mode $oldMode\nnew mode $newMode\n';
      expect(
        () => parseGitPatch('$diff${modes}index 123..456\n$paths$content'),
        throwsA(_code('invalid_git_output')),
      );
      expect(
        parseGitPatch('$diff$modes$paths$content', requireIndex: false),
        hasLength(1),
      );
      expect(parseGitPatch('$diff$modes', requireIndex: false), isEmpty);
    }
    for (final modes in [
      'old mode 100644\n',
      'new mode 100755\n',
      'new mode 100755\nold mode 100644\n',
      'old mode 100644\nnew mode 100644\n',
      'old mode 120000\nnew mode 100644\n',
      'old mode 100644\nnew mode 160000\n',
      'old mode 100644\nnew mode 100755 extra\n',
      'old mode 100644\nnew mode 100755\nold mode 100755\nnew mode 100644\n',
      'new file mode 100644\nold mode 100644\nnew mode 100755\n',
    ]) {
      expect(
        () => parseGitPatch('$diff$modes$paths$content', requireIndex: false),
        throwsA(_code('invalid_git_output')),
        reason: modes,
      );
    }
  });

  test('optional index does not relax other framing or hunk validation', () {
    for (final malformed in [
      '$diff$diff$paths$content',
      '${diff}index invalid\n$paths$content',
      '${diff}index 123..456\nindex 123..456\n$paths$content',
      '${diff}unknown header\n$paths$content',
      '$diff$content',
      '$diff$paths',
      '$diff$paths@@ -1 +1 @@\n-old\n',
      '$diff$paths@@ -0 +1 @@\n-old\n+new\n',
      '$diff$paths$content+extra\n',
      '$diff$paths$content$content',
      '$noIndex\\ No newline at end of file\n',
      noIndex.substring(0, noIndex.length - 1),
    ]) {
      expect(
        () => parseGitPatch(malformed, requireIndex: false),
        throwsA(_code('invalid_git_output')),
        reason: malformed,
      );
    }
    expect(
      () => parseGitPatch(noIndex, requireIndex: false, maximumLines: 1),
      throwsA(_code('snapshot_too_large')),
    );
    expect(parseGitPatch('', requireIndex: false), isEmpty);
  });
}

String _indexRecord(String path) =>
    '100644 ${'a' * 40} 0\t$path\u0000'
    '  ctime: 0:0\n  mtime: 0:0\n  dev: 0\tino: 0\n'
    '  uid: 0\tgid: 0\n  size: 0\tflags: 0\n';

Matcher _code(String code) =>
    isA<ChangeSetFailure>().having((failure) => failure.code, 'code', code);
