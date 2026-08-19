import 'dart:io';

import 'package:development_source_backend/development_source_backend.dart';
import 'package:development_source_contract/development_source_contract.dart';
import 'package:test/test.dart';

void main() {
  late Directory root;
  late LocalDevelopmentSourceService service;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('adele-development-source-');
    await Directory('${root.path}/lib/nested').create(recursive: true);
    await File(
      '${root.path}/lib/main.dart',
    ).writeAsString('void main() {\n  print("needle");\n}\n');
    service = LocalDevelopmentSourceService(root);
  });

  tearDown(() => root.delete(recursive: true));

  test(
    'reads an ordinary nested UTF-8 file with normalized identity',
    () async {
      final DevelopmentSourceTextFile result = await service.readTextFile(
        './lib//main.dart',
      );
      expect(result.relativePath, 'lib/main.dart');
      expect(result.text, contains('needle'));
      expect(result.sizeBytes, greaterThan(0));
    },
  );

  test('rejects traversal and absolute path forms', () async {
    for (final String path in <String>[
      '../outside.txt',
      'lib/../../outside.txt',
      '/etc/passwd',
      r'C:/Windows/system.ini',
      r'C:Windows/system.ini',
      r'lib\main.dart',
      if (Platform.isWindows) 'lib/main.dart:stream',
    ]) {
      await expectLater(
        service.readTextFile(path),
        throwsA(_failureCode('invalid_path')),
        reason: path,
      );
    }
  });

  test('reports missing paths and directories explicitly', () async {
    await expectLater(
      service.readTextFile('missing.dart'),
      throwsA(_failureCode('not_found')),
    );
    await expectLater(
      service.readTextFile('lib'),
      throwsA(_failureCode('not_regular_file')),
    );
  });

  test('rejects invalid UTF-8 and oversized files', () async {
    await File('${root.path}/binary.dart').writeAsBytes(<int>[0xff, 0xfe]);
    await File('${root.path}/large.dart').writeAsBytes(
      List<int>.filled(maximumDevelopmentSourceFileBytes + 1, 0x61),
    );

    await expectLater(
      service.readTextFile('binary.dart'),
      throwsA(_failureCode('invalid_utf8')),
    );
    await expectLater(
      service.readTextFile('large.dart'),
      throwsA(
        isA<DevelopmentSourceFailure>()
            .having(
              (DevelopmentSourceFailure failure) => failure.code,
              'code',
              'file_too_large',
            )
            .having(
              (DevelopmentSourceFailure failure) => failure.details['limit'],
              'limit',
              maximumDevelopmentSourceFileBytes,
            ),
      ),
    );
  });

  test('rejects a file symlink that resolves outside the root', () async {
    if (Platform.isWindows) return;
    final File outside = await File(
      '${root.parent.path}/adele-outside-${root.path.hashCode}.dart',
    ).writeAsString('secret');
    addTearDown(outside.delete);
    await Link('${root.path}/escape.dart').create(outside.path);

    await expectLater(
      service.readTextFile('escape.dart'),
      throwsA(_failureCode('outside_root')),
    );
  });

  test('allows a file symlink that remains inside the root', () async {
    if (Platform.isWindows) return;
    await Link('${root.path}/inside.dart').create('${root.path}/lib/main.dart');

    final DevelopmentSourceTextFile result = await service.readTextFile(
      'inside.dart',
    );
    expect(result.relativePath, 'inside.dart');
    expect(result.text, contains('needle'));
  });

  test('searches literal text across files in deterministic order', () async {
    await File('${root.path}/z.dart').writeAsString('needle z\n');
    await File('${root.path}/a.dart').writeAsString('first\nneedle a\n');
    await File('${root.path}/lib/b.dart').writeAsString('needle b\n');

    final DevelopmentSourceSearchResult result = await service.searchText(
      'needle',
    );

    expect(
      result.matches.map(
        (DevelopmentSourceSearchMatch match) =>
            '${match.relativePath}:${match.lineNumber}',
      ),
      <String>['a.dart:2', 'lib/b.dart:1', 'lib/main.dart:2', 'z.dart:1'],
    );
    expect(result.truncated, isFalse);
  });

  test('bounds match count and reports actual truncation', () async {
    await File('${root.path}/many.txt').writeAsString(
      List<String>.filled(
        maximumDevelopmentSourceSearchMatches + 1,
        'hit',
      ).join('\n'),
    );

    final DevelopmentSourceSearchResult result = await service.searchText(
      'hit',
    );
    expect(result.matches, hasLength(maximumDevelopmentSourceSearchMatches));
    expect(result.truncated, isTrue);
  });

  test('bounds scanned file bytes and reports truncation', () async {
    final List<int> contents = List<int>.filled(
      maximumDevelopmentSourceFileBytes,
      0x78,
    );
    final int filesWithinBudget =
        maximumDevelopmentSourceSearchBytes ~/
        maximumDevelopmentSourceFileBytes;
    for (int index = 0; index <= filesWithinBudget; index++) {
      await File('${root.path}/budget-$index.txt').writeAsBytes(contents);
    }

    final DevelopmentSourceSearchResult result = await service.searchText(
      'absent-budget-match',
    );
    expect(result.matches, isEmpty);
    expect(result.truncated, isTrue);
  });

  test('bounds entries materialized from one directory', () async {
    final Directory crowded = await Directory('${root.path}/crowded').create();
    for (
      int index = 0;
      index <= maximumDevelopmentSourceDirectoryEntries;
      index++
    ) {
      await File('${crowded.path}/entry-$index.txt').writeAsString('hit');
    }

    final DevelopmentSourceSearchResult result = await service.searchText(
      'hit',
    );
    expect(result.matches, isEmpty);
    expect(result.truncated, isTrue);
  });

  test('bounds long snippets while retaining the literal match', () async {
    final String line =
        '${List<String>.filled(600, 'a').join()}long-needle'
        '${List<String>.filled(600, 'z').join()}';
    await File('${root.path}/long.txt').writeAsString(line);

    final DevelopmentSourceSearchMatch match = (await service.searchText(
      'long-needle',
    )).matches.single;
    expect(match.snippet.length, lessThanOrEqualTo(500));
    expect(match.snippet, contains('long-needle'));
  });

  test('skips binary files, links, and fixed generated directories', () async {
    await File('${root.path}/binary.txt').writeAsBytes(<int>[0xff, 0xfe, 0x6e]);
    for (final String name in developmentSourceExcludedDirectoryNames) {
      await Directory('${root.path}/$name').create();
      await File('${root.path}/$name/hidden.txt').writeAsString('hidden-hit');
    }
    if (!Platform.isWindows) {
      await Link(
        '${root.path}/linked.dart',
      ).create('${root.path}/lib/main.dart');
    }

    expect((await service.searchText('hidden-hit')).matches, isEmpty);
    expect((await service.searchText('needle')).matches, hasLength(1));
  });

  test('rejects empty, multiline, and oversized search queries', () async {
    for (final String query in <String>[
      '',
      'two\nlines',
      'x' * (maximumDevelopmentSourceQueryCodeUnits + 1),
    ]) {
      await expectLater(
        service.searchText(query),
        throwsA(_failureCode('invalid_query')),
      );
    }
  });

  test('returns POSIX colon paths that remain readable', () async {
    if (Platform.isWindows) return;
    await File('${root.path}/lib/a:b.dart').writeAsString('colon-hit');

    final DevelopmentSourceSearchMatch match = (await service.searchText(
      'colon-hit',
    )).matches.single;
    expect(match.relativePath, 'lib/a:b.dart');
    expect((await service.readTextFile(match.relativePath)).text, 'colon-hit');
  });
}

Matcher _failureCode(String code) => isA<DevelopmentSourceFailure>().having(
  (DevelopmentSourceFailure failure) => failure.code,
  'code',
  code,
);
