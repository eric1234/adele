import 'dart:convert';

import 'package:adele_environment/adele_environment.dart';
import 'package:adele_model_tool/adele_model_tool.dart';
import 'package:adele_product/adele_product.dart';
import 'package:command_tools_contract/command_tools_contract.dart';
import 'package:command_tools_plugin/command_tools_plugin.dart';
import 'package:test/test.dart';

import 'support/command_storage.dart';

void main() {
  late CommandTestStorage storage;
  late CommandTranscriptStore store;
  late CommandOutputSearch search;

  setUp(() {
    storage = CommandTestStorage();
    store = CommandTranscriptStore(storage);
    search = CommandOutputSearch(store);
  });
  tearDown(() async {
    await store.close();
    storage.close();
  });

  test('finds retained text outside the 8192-unit head/tail preview', () async {
    final text = '${'x' * 9000}NEEDLE${'y' * 5000}';
    await _capture(store, text);
    expect(
      '${text.substring(0, 4096)}${text.substring(text.length - 4096)}',
      isNot(contains('NEEDLE')),
    );

    final result = await search.search(_request(pattern: 'NEEDLE'));
    final line = result.lines.single;
    expect(
      (line.stream, line.lineNumber, line.chunk, line.offset),
      ('stdout', 1, 1, 0),
    );
    expect((line.matchStart, line.matchEnd, line.length), (9000, 9006, 14006));
    expect(line.text, contains('NEEDLE'));
    expect(line.terminated, isFalse);
    expect(result.exhaustive, isTrue);
    expect(result.cursor, isNull);
  });

  test(
    'regex spans stored chunks and an entire multi-chunk logical line',
    () async {
      final first = '${'x' * 4094}TOKEN123${'y' * 4500}';
      await _capture(store, '$first\nlast\n');
      final result = await search.search(
        _request(pattern: r'x{4}TOKEN\d+y{4}', after: 1),
      );
      expect(result.matchCount, 1);
      expect(
        (result.lines.first.matchStart, result.lines.first.matchEnd),
        (4090, 4106),
      );
      expect(result.lines.first.length, first.length);
      expect(result.lines.first.terminated, isTrue);
      final context = result.lines.last;
      expect(
        (context.text, context.lineNumber, context.chunk, context.offset),
        ('last', 2, 3, first.length + 1 - 8192),
      );
      expect(context.isMatch, isFalse);
      expect(result.exhaustive, isTrue);
    },
  );

  test(
    'overlapping context is deduplicated without demoting admitted hits',
    () async {
      await _capture(
        store,
        'one\ntwo\nhit three\nfour\nhit five\nsix\nseven\neight\n',
      );
      final result = await search.search(_request(before: 2, after: 2));
      expect(result.lines.map((line) => line.lineNumber), [
        1,
        2,
        3,
        4,
        5,
        6,
        7,
      ]);
      expect(_hits(result), [('stdout', 3), ('stdout', 5)]);
      expect(
        result.lines.map((line) => (line.stream, line.lineNumber)).toSet(),
        hasLength(result.lines.length),
      );
      expect(result.contextIncomplete, isFalse);
      expect(result.exhaustive, isTrue);
      expect(() => result.lines.clear(), throwsUnsupportedError);
    },
  );

  test('default context is three before and five after', () async {
    await _capture(
      store,
      List.generate(13, (i) => i == 4 ? 'hit\n' : 'line ${i + 1}\n').join(),
    );
    final result = await search.search(
      const CommandOutputSearchRequest(
        sessionId: 'session',
        runId: 'run',
        toolInvocationId: 'invocation',
        pattern: 'hit',
      ),
    );
    expect(result.lines.map((line) => line.lineNumber), [
      2,
      3,
      4,
      5,
      6,
      7,
      8,
      9,
      10,
    ]);
    expect(_hits(result), [('stdout', 5)]);
  });

  test(
    'interleaved pipes have independent lines, context, and locators',
    () async {
      final writer = await _begin(store);
      await writer.append(_output('out-'));
      await writer.append(_output('err-', stderr: true));
      await writer.append(_output('hit\nout tail\n'));
      await writer.append(_output('hit\nerr tail', stderr: true));
      await writer.seal(_completed());

      final result = await search.search(
        _request(pattern: r'^(out|err)-hit$', before: 1, after: 1),
      );
      expect(
        result.lines.map(
          (line) => (
            line.stream,
            line.lineNumber,
            line.chunk,
            line.offset,
            line.text,
            line.terminated,
            line.isMatch,
          ),
        ),
        [
          ('stdout', 1, 1, 0, 'out-hit', true, true),
          ('stdout', 2, 3, 4, 'out tail', true, false),
          ('stderr', 1, 2, 0, 'err-hit', true, true),
          ('stderr', 2, 4, 4, 'err tail', false, false),
        ],
      );
      expect(result.exhaustive, isTrue);
      expect(
        (await search.search(_request(pattern: 'out-err-'))).matchCount,
        0,
      );
    },
  );

  test(
    'only LF splits lines; CR, ANSI, NUL, Unicode and final text stay raw',
    () async {
      final expected = [
        'crlf\r',
        'bare\ronly',
        '\x1b[31mred\x1b[0m\u0000',
        '\u{1f600}e\u0301\u2028\u2029',
        '',
        'tail\r',
      ];
      await _capture(store, expected.join('\n'));
      final result = await search.search(_request(pattern: '^'));
      expect(result.lines.map((line) => line.text), expected);
      expect(
        result.lines.map((line) => line.length),
        expected.map((s) => s.length),
      );
      expect(result.lines.map((line) => line.lineNumber), [1, 2, 3, 4, 5, 6]);
      expect(result.lines.map((line) => line.terminated), [
        true,
        true,
        true,
        true,
        true,
        false,
      ]);
      expect(
        result.lines.every(
          (line) => line.matchStart == 0 && line.matchEnd == 0,
        ),
        isTrue,
      );
      expect(result.matchCount, 6);
      expect(result.exhaustive, isTrue);

      final escaped = await search.search(_request(pattern: r'bare\ronly'));
      expect(escaped.lines.single.text, 'bare\ronly');
      final nul = await search.search(_request(pattern: r'\x00'));
      expect(nul.lines.single.text, expected[2]);
    },
  );

  for (final example in <(String, List<(int, int, int)>)>[
    ('hit', [(1, 0, 3), (3, 7, 10)]),
    (r'^hit', [(1, 0, 3)]),
    (r'^hit$', []),
    (r'^a.b$', []),
    (r'^b$', []),
    (r'^.$', []),
    (r'\uDE00', [(5, 1, 2)]),
    (r'(?=hit)', [(1, 0, 0), (3, 7, 7)]),
  ]) {
    test('firstMatch uses default Dart flags for ${example.$1}', () async {
      await _capture(
        store,
        'hit hit\nHIT\nbefore\rhit\na\u2028b\n\u{1f600}\n\n',
      );
      final result = await search.search(_request(pattern: example.$1));
      expect(
        result.lines.map(
          (line) => (line.lineNumber, line.matchStart, line.matchEnd),
        ),
        example.$2,
      );
      expect(result.matchCount, example.$2.length);
      expect(result.exhaustive, isTrue);
      for (final line in result.lines) {
        expect(utf8.decode(utf8.encode(line.text)), line.text);
      }
    });
  }

  test(
    'CRLF and final empty lines remain exact across stored events',
    () async {
      final writer = await _begin(store);
      await writer.append(_output('before\r'));
      await writer.append(_output('\n'));
      await writer.append(_output('\nlast\r'));
      await writer.append(_output('\n'));
      await writer.seal(_completed());
      final result = await search.search(_request(pattern: '^'));
      expect(result.lines.map((line) => line.text), ['before\r', '', 'last\r']);
      expect(result.lines.map((line) => (line.chunk, line.offset)), [
        (1, 0),
        (3, 0),
        (3, 1),
      ]);
      expect(result.lines.every((line) => line.terminated), isTrue);
      expect(result.exhaustive, isTrue);
    },
  );

  test(
    'each 512-unit excerpt is independent and surrogate-safe around its hit',
    () async {
      final middle =
          '${'x' * 599}\u{1f600}${'a' * 127}hit'
          '${'b' * 379}\u{1f642}${'z' * 500}';
      await _capture(store, '${'c' * 700}\n$middle\n${'d' * 900}\n');
      final result = await search.search(_request(before: 1, after: 1));
      expect(result.lines, hasLength(3));
      expect(result.lines.first.text, 'c' * 512);
      expect(result.lines.last.text, 'd' * 512);
      expect(result.lines.first.excerptOffset, 0);
      expect(result.lines.last.excerptOffset, 0);
      final hit = result.lines[1];
      expect(
        (hit.matchStart, hit.matchEnd, hit.excerptOffset),
        (728, 731, 599),
      );
      expect(hit.text, '\u{1f600}${'a' * 127}hit${'b' * 379}');
      expect(hit.length, middle.length);
      expect(hit.truncatedBefore, isTrue);
      expect(hit.truncatedAfter, isTrue);
      for (final line in result.lines) {
        expect(line.text.length, lessThanOrEqualTo(512));
        expect(utf8.decode(utf8.encode(line.text)), line.text);
        expect(
          line.text,
          ['c' * 700, middle, 'd' * 900][line.lineNumber - 1].substring(
            line.excerptOffset,
            line.excerptOffset + line.text.length,
          ),
        );
      }
    },
  );

  test(
    'maxMatches continuation replays context without duplicate or lost hits',
    () async {
      await _capture(store, List.generate(5, (i) => 'hit ${i + 1}\n').join());
      final pages = <CommandOutputSearchResult>[];
      String? cursor;
      do {
        final page = await search.search(
          _request(before: 1, after: 2, maxMatches: 2, cursor: cursor),
        );
        pages.add(page);
        expect(page.matchCount, lessThanOrEqualTo(2));
        expect(
          page.lines.map((line) => (line.stream, line.lineNumber)).toSet(),
          hasLength(page.lines.length),
        );
        cursor = page.cursor;
        expect(pages.length, lessThan(6));
      } while (cursor != null);
      expect(pages.first.stop, CommandOutputSearchStop.matchLimit);
      expect(pages.first.lines.map((line) => line.lineNumber), [1, 2, 3, 4]);
      expect(pages.first.lines[2].isMatch, isFalse);
      expect(pages[1].lines.first.lineNumber, 2);
      expect(pages[1].lines.first.isMatch, isFalse);
      expect(pages.expand(_hits), List.generate(5, (i) => ('stdout', i + 1)));
      expect(pages.last.exhaustive, isTrue);
      expect(pages.every((page) => !page.contextIncomplete), isTrue);
    },
  );

  test('default match limit admits ten hits per request', () async {
    await _capture(store, 'hit\n' * 11);
    final result = await search.search(_request());
    expect(result.matchCount, 10);
    expect(result.stop, CommandOutputSearchStop.matchLimit);
    expect(result.cursor, isNotNull);
    final next = await search.search(_request(cursor: result.cursor));
    expect(_hits(next), [('stdout', 11)]);
    expect(next.exhaustive, isTrue);
  });

  test(
    '16384-unit text budget preserves outstanding context across continuation',
    () async {
      await _capture(
        store,
        List.generate(50, (i) {
          final prefix = i == 10 || i == 31 ? 'hit' : 'row';
          return '$prefix${'x' * 597}\n';
        }).join(),
      );
      final first = await search.search(_request(before: 10, after: 10));
      expect(first.stop, CommandOutputSearchStop.textLimit);
      expect(
        first.lines.fold<int>(0, (sum, line) => sum + line.text.length),
        16384,
      );
      expect(_hits(first), [('stdout', 11), ('stdout', 32)]);
      expect(first.contextIncomplete, isTrue);
      expect(first.cursor, isNotNull);

      final next = await search.search(
        _request(before: 10, after: 10, cursor: first.cursor),
      );
      expect(
        next.matchCount,
        0,
        reason: 'Earlier admitted hits must not be repeated.',
      );
      expect(next.exhaustive, isTrue);
      final allLines = [
        ...first.lines,
        ...next.lines,
      ].map((line) => line.lineNumber).toSet().toList()..sort();
      expect(
        allLines,
        List.generate(42, (i) => i + 1),
        reason: 'The second hit still owns its ten trailing context lines.',
      );
      expect(
        next.lines.fold<int>(0, (sum, line) => sum + line.text.length),
        lessThanOrEqualTo(16384),
      );
    },
  );

  test(
    '2 Mi scanned units count both stream passes and reset per request',
    () async {
      final text = '${'x' * 8191}\n' * 130;
      await _capture(store, text);
      final first = await search.search(_request(pattern: 'absent'));
      expect(first.stop, CommandOutputSearchStop.scanLimit);
      expect(first.scannedCodeUnits, 2 * 1024 * 1024);
      expect(first.storagePages, lessThanOrEqualTo(128));
      expect(first.unsearchedLongLines, 0);
      expect(first.exhaustive, isFalse);
      expect(first.cursor, isNotNull);
      final next = await search.search(
        _request(pattern: 'absent', cursor: first.cursor),
      );
      expect(next.scannedCodeUnits, 2 * text.length - first.scannedCodeUnits);
      expect(next.exhaustive, isTrue);
      expect(next.lines, isEmpty);
    },
  );

  test(
    '128-page budget counts both stream passes over tiny stored chunks',
    () async {
      final writer = await _begin(store);
      for (var i = 0; i < 1040; i++) {
        await writer.append(_output('x'));
      }
      await writer.seal(_completed());
      final first = await search.search(_request(pattern: 'absent'));
      expect(first.stop, CommandOutputSearchStop.pageLimit);
      expect(first.storagePages, 128);
      expect(first.scannedCodeUnits, 2048);
      expect(first.cursor, isNotNull);
      final next = await search.search(
        _request(pattern: 'absent', cursor: first.cursor),
      );
      expect(next.storagePages, 2);
      expect(next.scannedCodeUnits, 32);
      expect(next.exhaustive, isTrue);
    },
  );

  test(
    'partial lines and escaped context survive a scan limit inside the other pipe',
    () async {
      final writer = await _begin(store);
      for (var i = 0; i < 10; i++) {
        await writer.append(_output('${'\u0000' * 512}\n'));
      }
      await writer.append(_output('${'\u0000' * 16378}tar'));
      final filler = '${'x' * 8191}\n' * 2;
      for (var i = 0; i < 129; i++) {
        await writer.append(_output(filler, stderr: true));
      }
      await writer.append(_output('get\n'));
      await writer.seal(_completed());

      final pages = <CommandOutputSearchResult>[];
      String? cursor;
      do {
        final page = await search.search(
          _request(pattern: r'^\x00*target$', before: 10, cursor: cursor),
        );
        pages.add(page);
        expect(page.unsearchedLongLines, 0);
        expect(page.scannedCodeUnits, lessThanOrEqualTo(2 * 1024 * 1024));
        cursor = page.cursor;
        if (cursor != null) {
          expect(cursor.length, lessThanOrEqualTo(192 * 1024));
        }
        expect(pages.length, lessThan(5));
      } while (cursor != null);
      expect(pages.first.stop, CommandOutputSearchStop.scanLimit);
      expect(pages.first.lines, isEmpty);
      expect(pages.expand(_hits), [('stdout', 11)]);
      final hitPage = pages.singleWhere((page) => page.matchCount != 0);
      expect(
        hitPage.lines.map((line) => line.lineNumber),
        List.generate(11, (i) => i + 1),
      );
      expect(hitPage.lines.last.length, 16384);
      expect(hitPage.lines.last.matchEnd, 16384);
      expect(pages.last.exhaustive, isTrue);
    },
  );

  test(
    'scan-limit continuation retains a previous hit trailing context',
    () async {
      final writer = await _begin(store);
      await writer.append(_output('before\nhit\n'));
      final filler = '${'x' * 8191}\n' * 2;
      for (var i = 0; i < 128; i++) {
        await writer.append(_output(filler, stderr: true));
      }
      await writer.append(_output('after\n'));
      await writer.seal(_completed());
      final pages = <CommandOutputSearchResult>[];
      String? cursor;
      do {
        final page = await search.search(
          _request(before: 1, after: 1, cursor: cursor),
        );
        pages.add(page);
        cursor = page.cursor;
        expect(pages.length, lessThan(5));
      } while (cursor != null);
      expect(pages.first.stop, CommandOutputSearchStop.scanLimit);
      expect(pages.first.contextIncomplete, isTrue);
      expect(pages.expand(_hits), [('stdout', 2)]);
      expect(
        pages.expand((page) => page.lines).map((line) => line.text).toSet(),
        {'before', 'hit', 'after'},
      );
      expect(pages.last.exhaustive, isTrue);
    },
  );

  test(
    '16384-unit lines are searched but longer lines are explicitly skipped',
    () async {
      await _capture(store, 'hit${'x' * 16381}\nhit${'x' * 16382}\nhit\n');
      final result = await search.search(_request());
      expect(_hits(result), [('stdout', 1), ('stdout', 3)]);
      expect(result.lines.first.length, 16384);
      expect(result.unsearchedLongLines, 1);
      expect(result.reachedEnd, isTrue);
      expect(result.exhaustive, isFalse);
    },
  );

  test(
    'long-line omissions remain cumulative while draining across cursors',
    () async {
      await _capture(store, 'hit${'x' * (2 * 1024 * 1024 + 1024)}\nhit\n');
      final pages = <CommandOutputSearchResult>[];
      String? cursor;
      do {
        final page = await search.search(_request(cursor: cursor));
        pages.add(page);
        expect(page.unsearchedLongLines, 1);
        expect(page.exhaustive, isFalse);
        expect(page.scannedCodeUnits, lessThanOrEqualTo(2 * 1024 * 1024));
        expect(page.storagePages, lessThanOrEqualTo(128));
        cursor = page.cursor;
        if (cursor != null) {
          expect(cursor.length, lessThanOrEqualTo(192 * 1024));
        }
        expect(pages.length, lessThan(5));
      } while (cursor != null);
      expect(pages.first.stop, CommandOutputSearchStop.scanLimit);
      expect(pages.first.lines, isEmpty);
      expect(pages.expand(_hits), [('stdout', 2)]);
      expect(pages.last.reachedEnd, isTrue);
    },
  );

  test('invalid requests reject before schema or any storage read', () async {
    final invalid = [
      _request(session: ''),
      _request(run: ''),
      _request(id: ''),
      _request(session: 's' * 1025),
      _request(run: 'r' * 1025),
      _request(id: 'i' * 1025),
      for (final pattern in [
        '',
        'x' * 257,
        '[',
        'a\u0000b',
        'a\rb',
        'a\nb',
        'a\u2028b',
        'a\u2029b',
      ])
        _request(pattern: pattern),
      _request(before: -1),
      _request(before: 11),
      _request(after: -1),
      _request(after: 11),
      _request(maxMatches: 0),
      _request(maxMatches: 11),
    ];
    for (final request in invalid) {
      await expectLater(
        search.search(request),
        throwsA(_failure('invalid_search')),
      );
    }
    expect(storage.schemaChecks, 0);
    expect(storage.queries, 0);
    expect(storage.transactions, 0);
  });

  test(
    'malformed, oversized, tampered and foreign-engine cursors reject before reads',
    () async {
      await _capture(store, 'hit one\nhit two\n');
      final first = await search.search(_request(maxMatches: 1));
      final token = first.cursor!;
      final parts = token.split('.');
      final changedPayload =
          '${base64Url.encode(utf8.encode('[]'))}.${parts[1]}';
      final signature = base64Url.decode(parts[1]);
      signature[0] ^= 1;
      final changedSignature = '${parts[0]}.${base64Url.encode(signature)}';
      final queries = storage.queries;
      for (final cursor in [
        '',
        'not-a-cursor',
        '.',
        'a.b.c',
        '%%.%%',
        'x' * (192 * 1024 + 1),
        changedPayload,
        changedSignature,
      ]) {
        await expectLater(
          search.search(_request(maxMatches: 1, cursor: cursor)),
          throwsA(_failure('invalid_search_cursor')),
        );
      }
      await expectLater(
        CommandOutputSearch(
          store,
        ).search(_request(maxMatches: 1, cursor: token)),
        throwsA(_failure('invalid_search_cursor')),
      );
      expect(storage.queries, queries);
      final next = await search.search(_request(maxMatches: 1, cursor: token));
      expect(_hits(next), [('stdout', 2)]);
    },
  );

  test(
    'authenticated cursors bind every identity and query option before reads',
    () async {
      await _capture(store, 'hit one\nhit two\n');
      final first = await search.search(_request(maxMatches: 1));
      final token = first.cursor!;
      final queries = storage.queries;
      for (final request in [
        _request(session: 'other', maxMatches: 1, cursor: token),
        _request(run: 'other-run', maxMatches: 1, cursor: token),
        _request(id: 'other-id', maxMatches: 1, cursor: token),
        _request(pattern: 'different', maxMatches: 1, cursor: token),
        _request(before: 1, maxMatches: 1, cursor: token),
        _request(after: 1, maxMatches: 1, cursor: token),
        _request(maxMatches: 2, cursor: token),
      ]) {
        await expectLater(
          search.search(request),
          throwsA(_failure('invalid_search_cursor')),
        );
      }
      expect(storage.queries, queries);
    },
  );

  for (final change in [
    'version=version+1',
    "state='failed',failure='changed'",
  ]) {
    test('cursor rejects changed capture snapshot: $change', () async {
      await _capture(store, 'hit one\nhit two\n');
      final first = await search.search(_request(maxMatches: 1));
      storage.database.execute('UPDATE adele_command_captures SET $change');
      final queries = storage.queries;
      await expectLater(
        search.search(_request(maxMatches: 1, cursor: first.cursor)),
        throwsA(_failure('stale_search_cursor')),
      );
      expect(storage.queries, queries + 1);
    });
  }

  test(
    'snapshot changes between header and output page reject the search',
    () async {
      await _capture(store, 'hit\n');
      var changed = false;
      storage.afterQuery = (sql, rows) {
        if (!changed && sql.contains('SELECT * FROM adele_command_captures')) {
          changed = true;
          storage.database.execute(
            'UPDATE adele_command_captures SET version=version+1',
          );
        }
      };
      await expectLater(
        search.search(_request()),
        throwsA(_failure('stale_search_cursor')),
      );
    },
  );

  test('absent, capturing, and complete-empty captures are distinct', () async {
    final absent = await search.search(_request());
    expect(absent.captureState, 'absent');
    expect(absent.stop, CommandOutputSearchStop.absent);
    expect(absent.lines, isEmpty);
    expect(absent.cursor, isNull);
    expect(absent.exhaustive, isFalse);
    expect(absent.storagePages, 0);
    expect(storage.transactions, 0);

    final writer = await _begin(store);
    await writer.append(_output('hit\n'));
    final capturing = await search.search(_request());
    expect(capturing.captureState, 'capturing');
    expect(capturing.stop, CommandOutputSearchStop.capturing);
    expect(capturing.lines, isEmpty);
    expect(capturing.cursor, isNull);
    expect(capturing.storagePages, 0);
    expect(capturing.scannedCodeUnits, 0);
    expect(capturing.committedOutputOnly, isTrue);
    expect(capturing.exhaustive, isFalse);
    await writer.seal(_completed());
    expect((await search.search(_request())).matchCount, 1);

    final empty = await _begin(store, id: 'empty');
    await empty.seal(_completed());
    final complete = await search.search(_request(id: 'empty'));
    expect(complete.captureState, 'complete');
    expect(complete.stop, CommandOutputSearchStop.end);
    expect(complete.exhaustive, isTrue);
    expect(complete.committedOutputOnly, isFalse);
    expect(complete.lines, isEmpty);
    expect(complete.storagePages, 0);
  });

  for (final state in ['complete', 'failed', 'interrupted']) {
    test(
      'fresh reader searches $state committed output without a live writer',
      () async {
        final writer = await _begin(store);
        await writer.append(_output('hit retained\n'));
        if (state == 'complete') await writer.seal(_completed(exitCode: 17));
        if (state == 'failed') await writer.fail('capture failed');
        await store.close();
        final fresh = CommandTranscriptStore(storage);
        addTearDown(fresh.close);
        final transactions = storage.transactions;
        final result = await CommandOutputSearch(fresh).search(_request());
        expect(result.captureState, state);
        expect(result.committedOutputOnly, state != 'complete');
        expect(result.exhaustive, isTrue);
        expect(result.lines.single.text, 'hit retained');
        expect(fresh.activeCaptureCount, 0);
        expect(fresh.observerCount, 0);
        expect(storage.transactions, transactions);
        expect(result.exitCode, state == 'complete' ? 17 : null);
        expect(result.termination, state == 'complete' ? 'exited' : null);
      },
    );
  }

  test(
    'Run-local invocation reuse does not cross Session or Run associations',
    () async {
      await _capture(store, 'hit first\n');
      final second = await _begin(store, run: 'second-run');
      await second.append(_output('hit second\n', stderr: true));
      await second.seal(_completed());
      final other = await _begin(store, session: 'other', run: 'other-run');
      await other.append(_output('hit other\n'));
      await other.seal(_completed());

      expect((await search.search(_request())).lines.single.text, 'hit first');
      final result = await search.search(_request(run: 'second-run'));
      expect(
        (result.lines.single.stream, result.lines.single.text),
        ('stderr', 'hit second'),
      );
      expect(
        (await search.search(
          _request(session: 'other', run: 'other-run'),
        )).lines.single.text,
        'hit other',
      );
      await expectLater(
        search.search(_request(session: 'other')),
        throwsA(_failure('association_mismatch')),
      );
      expect(
        (await search.search(_request(run: 'missing-run'))).captureState,
        'absent',
      );
    },
  );

  test(
    'storage failures propagate rather than becoming empty search results',
    () async {
      await _capture(store, 'hit\n');
      final error = StateError('storage read failed');
      storage.afterQuery = (sql, rows) => throw error;
      await expectLater(search.search(_request()), throwsA(same(error)));
    },
  );

  test('unavailable backing does not become an absent capture', () async {
    final error = StateError('backing unavailable');
    storage.beforeSchema = () => throw error;
    await expectLater(search.search(_request()), throwsA(same(error)));
    expect(storage.queries, 0);
    expect(storage.transactions, 0);
  });

  for (final mutation in [
    'DELETE FROM adele_command_chunks WHERE position=1',
    "UPDATE adele_command_chunks SET stream='unknown' WHERE position=1",
    "UPDATE adele_command_chunks SET text='' WHERE position=1",
    'UPDATE adele_command_captures SET total_code_units=total_code_units+1',
  ]) {
    test('corrupt retained rows fail explicitly: $mutation', () async {
      await _capture(store, 'hit one\nhit two\n');
      expect((await search.search(_request())).matchCount, 2);
      // Deliberately bypass SQL checks to exercise the retained-row decoder.
      storage.database.execute('PRAGMA ignore_check_constraints = ON');
      storage.database.execute(mutation);
      await expectLater(
        search.search(_request()),
        throwsA(_failure('corrupt_capture')),
      );
    });
  }

  test(
    'search and cursor replay never mutate capture rows or register observers',
    () async {
      await _capture(store, 'hit one\nhit two\n');
      List<Map<String, Object?>> rows(String table) => storage.database
          .select('SELECT * FROM $table ORDER BY rowid')
          .map((row) => Map<String, Object?>.from(row))
          .toList();
      final captures = rows('adele_command_captures');
      final chunks = rows('adele_command_chunks');
      final transactions = storage.transactions;
      storage.beforeTransaction = (_) => fail('Search must not write.');
      final first = await search.search(_request(maxMatches: 1));
      final second = await search.search(
        _request(maxMatches: 1, cursor: first.cursor),
      );
      final replay = await search.search(
        _request(maxMatches: 1, cursor: first.cursor),
      );
      expect(_hits(second), _hits(replay));
      expect(second.lines.single.text, replay.lines.single.text);
      expect(rows('adele_command_captures'), captures);
      expect(rows('adele_command_chunks'), chunks);
      expect(storage.transactions, transactions);
      expect(store.observerCount, 0);
      expect(store.activeCaptureCount, 0);
      expect(store.pendingBatchChunks, 0);
    },
  );

  test(
    'catastrophic regex is bounded and later requests remain usable',
    () async {
      await _capture(store, '${'a' * 10000}!\na\n');
      final first = await search.search(_request(pattern: r'^(a+)+$'));
      expect(first.stop, CommandOutputSearchStop.regexLimit);
      expect(first.regexTimeouts, 1);
      expect(first.exhaustive, isFalse);
      expect(first.cursor, isNotNull);
      final next = await search.search(
        _request(pattern: r'^(a+)+$', cursor: first.cursor),
      );
      expect(_hits(next), [('stdout', 2)]);
      expect(next.regexTimeouts, 1);
      expect(next.reachedEnd, isTrue);
      expect(next.exhaustive, isFalse);
      final independent = await search.search(_request(pattern: r'^a$'));
      expect(_hits(independent), [('stdout', 2)]);
      expect(independent.regexTimeouts, 0);
      expect(independent.exhaustive, isTrue);
    },
    timeout: const Timeout(Duration(seconds: 15)),
  );
}

CommandOutputSearchRequest _request({
  String session = 'session',
  String run = 'run',
  String id = 'invocation',
  String pattern = 'hit',
  int before = 0,
  int after = 0,
  int maxMatches = 10,
  String? cursor,
}) => CommandOutputSearchRequest(
  sessionId: session,
  runId: run,
  toolInvocationId: id,
  pattern: pattern,
  before: before,
  after: after,
  maxMatches: maxMatches,
  cursor: cursor,
);

Future<void> _capture(CommandTranscriptStore store, String text) async {
  final writer = await _begin(store);
  for (var offset = 0; offset < text.length;) {
    var end = offset + 16384;
    if (end > text.length) end = text.length;
    if (end < text.length &&
        text.codeUnitAt(end - 1) >= 0xd800 &&
        text.codeUnitAt(end - 1) <= 0xdbff) {
      end--;
    }
    await writer.append(_output(text.substring(offset, end)));
    offset = end;
  }
  await writer.seal(_completed());
}

Future<CommandCaptureWriter> _begin(
  CommandTranscriptStore store, {
  String session = 'session',
  String run = 'run',
  String id = 'invocation',
}) => store.begin(
  context: ToolExecutionContext(
    sessionId: SessionId(session),
    runId: RunId(run),
    toolInvocationId: id,
  ),
  environmentId: 'environment',
  request: EnvironmentForegroundProcessRequest(
    program: 'fixture',
    arguments: [],
    relativeWorkingDirectory: '',
    timeoutSeconds: 30,
  ),
);

EnvironmentProcessOutput _output(String text, {bool stderr = false}) =>
    EnvironmentProcessOutput(
      stream: stderr
          ? EnvironmentProcessOutputStream.stderr
          : EnvironmentProcessOutputStream.stdout,
      text: text,
    );

EnvironmentProcessCompleted _completed({int exitCode = 0}) =>
    EnvironmentProcessCompleted(
      termination: EnvironmentProcessTermination.exited,
      exitCode: exitCode,
      stdoutTruncated: false,
      stderrTruncated: false,
    );

List<(String, int)> _hits(CommandOutputSearchResult result) => result.lines
    .where((line) => line.isMatch)
    .map((line) => (line.stream, line.lineNumber))
    .toList();

Matcher _failure(String code) =>
    isA<CommandOutputFailure>().having((error) => error.code, 'code', code);
