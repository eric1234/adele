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
      expect(parseGitTree(_treeRecord(path)).keys, [path]);
      final entries = <String, GitIndexEntry>{};
      addGitUntrackedEntries('$path\u0000', entries);
      expect(entries.keys, [path]);
      expect(
        () => parseGitIndex(_indexRecord(path), windowsPaths: true),
        throwsA(_code('invalid_git_output')),
      );
      expect(
        () => parseGitTree(_treeRecord(path), windowsPaths: true),
        throwsA(_code('invalid_git_output')),
      );
      expect(
        () => addGitUntrackedEntries('$path\u0000', {}, windowsPaths: true),
        throwsA(_code('invalid_git_output')),
      );
    }
    for (final windowsPaths in [false, true]) {
      for (final path in [
        '',
        '/absolute',
        '../escape',
        'a/../b',
        'a//b',
        'a/./b',
      ]) {
        expect(
          () => parseGitIndex(_indexRecord(path), windowsPaths: windowsPaths),
          throwsA(_code('invalid_git_output')),
        );
        expect(
          () => parseGitTree(_treeRecord(path), windowsPaths: windowsPaths),
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

  test('tree and index retain exact modes and SHA-1 or SHA-256 identities', () {
    for (final width in [40, 64]) {
      final oid = 'a' * width;
      for (final mode in ['100644', '100755', '120000', '160000']) {
        final tree = parseGitTree(_treeRecord('file', mode: mode, oid: oid));
        expect(tree['file'], (
          oldMode: mode,
          newMode: mode,
          oid: oid,
          kind: 'modified',
        ));
        final index = parseGitIndex(_indexRecord('file', mode: mode, oid: oid));
        expect(index['file'], (
          oldMode: mode,
          newMode: mode,
          oid: oid,
          kind: mode == '160000' ? 'unsupported' : 'modified',
        ));
      }
      for (final flags in [0x20004000, 0x2000c000, 0x60004000]) {
        final entry = parseGitIndex(
          _indexRecord('intent', oid: oid, flags: flags),
        )['intent']!;
        expect(entry, (
          oldMode: '000000',
          newMode: '100644',
          oid: '',
          kind: flags == 0x20004000 ? 'added' : 'unsupported',
        ));
      }
      for (final flags in [0x8000, 0x40004000]) {
        expect(
          parseGitIndex(
            _indexRecord('flagged', oid: oid, flags: flags),
          )['flagged']!.kind,
          'unsupported',
        );
      }
    }
  });

  test('tree and index preserve literal unusual path names', () {
    final paths = [
      ' space ',
      '-option',
      ':(glob)*',
      'dir/tab\tnewline\ncarriage\r',
      '"quoted"',
      r'back\slash',
      'unicode-\u00e9-\u{1f600}',
    ];
    expect(parseGitTree(paths.map(_treeRecord).join()).keys, paths);
    expect(parseGitIndex(paths.map(_indexRecord).join()).keys, paths);
  });

  test('index preserves other exact octal modes for caller classification', () {
    for (final mode in ['000000', '040000', '100600', '100664', '100777']) {
      expect(
        () => parseGitTree(_treeRecord('file', mode: mode)),
        throwsA(_code('invalid_git_output')),
        reason: mode,
      );
      expect(parseGitIndex(_indexRecord('file', mode: mode))['file'], (
        oldMode: mode,
        newMode: mode,
        oid: 'a' * 40,
        kind: 'modified',
      ));
    }
  });

  test('tree and index reject malformed headers modes and OID widths', () {
    for (final mode in ['', '10064', '0100644', '100648', 'abcdef']) {
      expect(
        () => parseGitTree(_treeRecord('file', mode: mode)),
        throwsA(_code('invalid_git_output')),
        reason: mode,
      );
      expect(
        () => parseGitIndex(_indexRecord('file', mode: mode)),
        throwsA(_code('invalid_git_output')),
        reason: mode,
      );
    }
    for (final oid in [
      '',
      'a' * 39,
      'a' * 41,
      'a' * 63,
      'a' * 65,
      'A' * 40,
      'g' * 64,
    ]) {
      expect(
        () => parseGitTree(_treeRecord('file', oid: oid)),
        throwsA(_code('invalid_git_output')),
      );
      expect(
        () => parseGitIndex(_indexRecord('file', oid: oid)),
        throwsA(_code('invalid_git_output')),
      );
    }
    for (final (mode, type) in [
      ('100644', 'commit'),
      ('100755', 'commit'),
      ('120000', 'commit'),
      ('160000', 'blob'),
      ('100644', 'tree'),
      ('100644', 'tag'),
    ]) {
      expect(
        () => parseGitTree(_treeRecord('file', mode: mode, type: type)),
        throwsA(_code('invalid_git_output')),
      );
    }
    for (final (parse, raw) in [
      (parseGitTree, _treeRecord('file')),
      (parseGitIndex, _indexRecord('file')),
    ]) {
      for (final malformed in [
        raw.replaceFirst('\u0000', ''),
        raw.replaceFirst('\t', ' '),
        raw.replaceFirst('\t', '\n\t'),
        raw.replaceFirst(' ', '  '),
        ' $raw',
        '$raw\u0000',
        '$raw\n',
        raw.replaceFirst('file\u0000', 'file/\u0000'),
        raw.replaceFirst('file\u0000', 'fi\u0000le\u0000'),
      ]) {
        expect(
          () => parse(malformed),
          throwsA(_code('invalid_git_output')),
          reason: malformed,
        );
      }
    }
  });

  test('tree rejects contradictory file and descendant paths', () {
    for (final paths in [
      ['parent', 'parent/child'],
      ['parent/child', 'parent'],
      ['parent', 'parent-sibling', 'parent/child'],
    ]) {
      expect(
        () => parseGitTree(paths.map(_treeRecord).join()),
        throwsA(_code('invalid_git_output')),
      );
    }
  });

  test('deep tree paths do not require every growing ancestor prefix', () {
    final path = '${'a/' * 250000}leaf';
    expect(parseGitTree(_treeRecord(path), maximumEntries: 1).keys, [path]);
  });

  test('tree rejects duplicate paths even with different identities', () {
    for (final duplicate in [
      _treeRecord('file'),
      _treeRecord('file', mode: '100755', oid: 'b' * 40),
    ]) {
      expect(
        () => parseGitTree('${_treeRecord('file')}$duplicate'),
        throwsA(_code('invalid_git_output')),
      );
    }
  });

  test('inventories reject mixed hash widths including collapsed stages', () {
    for (final widths in [
      [40, 64],
      [64, 40],
    ]) {
      final first = 'a' * widths.first;
      final second = 'b' * widths.last;
      expect(
        () => parseGitTree(
          _treeRecord('first', oid: first) + _treeRecord('second', oid: second),
        ),
        throwsA(_code('invalid_git_output')),
      );
      for (final raw in [
        _indexRecord('first', oid: first) + _indexRecord('second', oid: second),
        _indexRecord('file', oid: first, stage: 1) +
            _indexRecord('file', oid: second, stage: 2),
        _indexRecord('intent', oid: first, flags: 0x20004000) +
            _indexRecord('file', oid: second),
      ]) {
        expect(() => parseGitIndex(raw), throwsA(_code('invalid_git_output')));
      }
    }
  });

  test('index accepts real unmerged stage subsets as one conflict row', () {
    for (final width in [40, 64]) {
      for (var mask = 1; mask < 8; mask++) {
        final stages = [
          for (var stage = 1; stage <= 3; stage++)
            if ((mask & (1 << (stage - 1))) != 0) stage,
        ];
        for (final order in [stages, stages.reversed.toList()]) {
          final raw = order
              .map(
                (stage) => _indexRecord(
                  'conflict',
                  stage: stage,
                  mode: ['100644', '100755', '120000'][stage - 1],
                  oid: '$stage' * width,
                ),
              )
              .join();
          final entries = parseGitIndex(raw);
          expect(entries, hasLength(1));
          expect(entries['conflict'], (
            oldMode: ['100644', '100755', '120000'][order.first - 1],
            newMode: ['100644', '100755', '120000'][order.first - 1],
            oid: '${order.first}' * width,
            kind: 'conflicted',
          ));
        }
      }
    }
  });

  test(
    'index rejects duplicate stages and stage zero mixed with conflicts',
    () {
      for (var stage = 0; stage <= 3; stage++) {
        final first = _indexRecord('file', stage: stage);
        for (final duplicate in [
          first,
          _indexRecord('file', stage: stage, oid: 'b' * 40, mode: '100755'),
        ]) {
          expect(
            () => parseGitIndex('$first${_indexRecord('other')}$duplicate'),
            throwsA(_code('invalid_git_output')),
          );
        }
        if (stage == 0) continue;
        final resolved = _indexRecord('file');
        for (final raw in ['$first$resolved', '$resolved$first']) {
          expect(
            () => parseGitIndex(raw),
            throwsA(_code('invalid_git_output')),
          );
        }
      }
    },
  );

  test('index rejects contradictory stages and malformed debug metadata', () {
    for (var stage = 0; stage <= 3; stage++) {
      for (var flagStage = 0; flagStage <= 3; flagStage++) {
        if (stage == flagStage) continue;
        expect(
          () => parseGitIndex(
            _indexRecord('file', stage: stage, flags: flagStage << 12),
          ),
          throwsA(_code('invalid_git_output')),
        );
      }
      if (stage == 0) continue;
      expect(
        () => parseGitIndex(
          _indexRecord('file', stage: stage, flags: 0x20004000 | stage << 12),
        ),
        throwsA(_code('invalid_git_output')),
      );
    }
    final raw = _indexRecord('file');
    for (final malformed in [
      _indexRecord('file', stage: 4),
      _indexRecord('file', flags: 0x100000000),
      raw.substring(0, raw.indexOf('\u0000') + 1),
      raw.substring(0, raw.length - 1),
      raw.replaceFirst('ctime: 0:0', 'ctime: -1:0'),
      raw.replaceFirst('  uid: 0\tgid: 0\n', ''),
      raw.replaceFirst('flags: 0', 'flags: nope'),
      raw.replaceFirst('flags: 0', 'flags: fffffffffffffffff'),
      raw.replaceFirst('flags: 0', 'flags: 0 extra'),
    ]) {
      expect(
        () => parseGitIndex(malformed),
        throwsA(_code('invalid_git_output')),
        reason: malformed,
      );
    }
  });

  test(
    'inventory limits count raw index stages before collapsing conflicts',
    () {
      final tree = _treeRecord('first') + _treeRecord('second');
      final index =
          _indexRecord('conflict', stage: 1) +
          _indexRecord('conflict', stage: 2);
      expect(parseGitTree(tree, maximumEntries: 2), hasLength(2));
      expect(parseGitIndex(index, maximumEntries: 2), hasLength(1));
      for (final (parse, raw) in [
        (parseGitTree, tree),
        (parseGitIndex, index),
      ]) {
        expect(parse('', maximumEntries: 0), isEmpty);
        for (final limit in [0, 1]) {
          expect(
            () => parse(raw, maximumEntries: limit),
            throwsA(_code('inventory_too_large')),
          );
        }
        expect(
          () => parse('${raw}malformed', maximumEntries: 2),
          throwsA(_code('inventory_too_large')),
        );
      }
    },
  );

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

String _treeRecord(
  String path, {
  String mode = '100644',
  String? type,
  String? oid,
}) =>
    '$mode ${type ?? (mode == '160000' ? 'commit' : 'blob')} '
    '${oid ?? 'a' * 40}\t$path\u0000';

String _indexRecord(
  String path, {
  String mode = '100644',
  String? oid,
  int stage = 0,
  int? flags,
}) =>
    '$mode ${oid ?? 'a' * 40} $stage\t$path\u0000'
    '  ctime: 0:0\n  mtime: 0:0\n  dev: 0\tino: 0\n'
    '  uid: 0\tgid: 0\n  size: 0\tflags: ${(flags ?? stage << 12).toRadixString(16)}\n';

Matcher _code(String code) =>
    isA<ChangeSetFailure>().having((failure) => failure.code, 'code', code);
