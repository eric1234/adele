import 'dart:async';
import 'dart:convert';

import 'package:adele_environment/adele_environment.dart';
import 'package:adele_model_tool/adele_model_tool.dart';
import 'package:adele_product/adele_product.dart';
import 'package:adele_project_storage/adele_project_storage.dart';
import 'package:command_tools_contract/command_tools_contract.dart';
import 'package:command_tools_plugin/command_tools_plugin.dart';
import 'package:test/test.dart';

import 'support/command_storage.dart';

void main() {
  late CommandTestStorage storage;
  late CommandTranscriptStore store;
  setUp(() {
    storage = CommandTestStorage();
    store = CommandTranscriptStore(storage);
  });
  tearDown(() async {
    await store.close();
    storage.close();
  });

  test(
    'absence is distinct from capturing and complete empty output',
    () async {
      final absent = await _state(store);
      expect(
        (absent.state, absent.version, absent.highWater),
        ('absent', 0, 0),
      );
      expect(absent.program, isNull);
      expect((await _after(store)).chunks, isEmpty);
      final writer = await _begin(store);
      final capturing = await _state(store);
      expect(
        (capturing.state, capturing.version, capturing.highWater),
        ('capturing', 1, 0),
      );
      expect(capturing.program, 'fixture');
      expect(capturing.argumentsJson, '["two words","","literal | argument"]');
      expect(capturing.workingDirectory, 'src');
      expect(capturing.environmentId, 'environment');
      expect(capturing.timeoutSeconds, 30);
      await writer.seal(_completed());
      final complete = await _state(store);
      expect(
        (complete.state, complete.version, complete.highWater),
        ('complete', 2, 0),
      );
      expect(complete.totalCodeUnits, 0);
      expect(complete.exitCode, 0);
      expect((await _after(store)).chunks, isEmpty);
      expect(store.activeCaptureCount, 0);
    },
  );

  test(
    'every tiny output is committed immediately before terminal settlement',
    () async {
      final writer = await _begin(store);
      await writer.append(_output('waiting...\r'));
      final page = await _after(store);
      expect(page.state.state, 'capturing');
      expect(page.state.highWater, 1);
      expect(page.state.totalCodeUnits, 11);
      expect(page.chunks.single.text, 'waiting...\r');
      expect(store.pendingBatchChunks, 0);
      expect(store.activeCaptureCount, 1);
      expect(storage.transactionKinds, ['setup', 'append']);
      await writer.seal(_completed());
    },
  );

  test(
    '12 Mi UTF16 survives many bounded writes with no retained pending chunks',
    () async {
      final writer = await _begin(store);
      final admitted = Completer<void>();
      final release = Completer<void>();
      var batches = 0;
      var maximumChunks = 0;
      var maximumUnits = 0;
      storage.beforeTransaction = (statements) async {
        if (CommandTestStorage.kindOf(statements) != 'append') return;
        final chunks = statements.skip(1);
        final units = chunks.fold<int>(
          0,
          (sum, statement) =>
              sum + (statement.parameters[':text']! as String).length,
        );
        maximumChunks = maximumChunks < chunks.length
            ? chunks.length
            : maximumChunks;
        maximumUnits = maximumUnits < units ? units : maximumUnits;
        expect(chunks.length, lessThanOrEqualTo(4));
        expect(units, lessThanOrEqualTo(16384));
        expect(
          statements.every((statement) => statement.expectedRows == 1),
          isTrue,
        );
        expect(store.pendingBatchChunks, chunks.length);
        if (++batches == 1) {
          admitted.complete();
          await release.future;
        }
      };
      final block = 'x' * 16384;
      final first = writer.append(_output(block));
      await admitted.future;
      expect(store.pendingBatchChunks, 4);
      expect((await _state(store)).highWater, 0);
      expect((await _after(store)).chunks, isEmpty);
      release.complete();
      await first;
      for (var i = 1; i < 768; i++) {
        await writer.append(_output(block, stderr: i.isOdd));
        expect(store.pendingBatchChunks, 0);
      }
      await writer.seal(_completed());
      expect((maximumChunks, maximumUnits, batches), (4, 16384, 768));
      expect(store.pendingBatchChunks, 0);
      expect(store.activeCaptureCount, 0);
      expect(store.observerCount, 0);
      var cursor = 0;
      var readUnits = 0;
      while (true) {
        final page = await _after(store, cursor: cursor);
        expect(page.state.highWater, 3072);
        expect(page.state.totalCodeUnits, 12 * 1024 * 1024);
        if (page.chunks.isEmpty) break;
        expect(page.chunks.length, lessThanOrEqualTo(16));
        for (final chunk in page.chunks) {
          expect(chunk.cursor, ++cursor);
          expect(chunk.text, 'x' * 4096);
          expect(chunk.stream, ((cursor - 1) ~/ 4).isOdd ? 'stderr' : 'stdout');
          readUnits += chunk.text.length;
        }
      }
      expect(readUnits, 12 * 1024 * 1024);
      // Page objects are reader-owned, not retained/reused by a transcript cache.
      final one = await _after(store);
      final two = await _after(store);
      expect(identical(one.chunks.first, two.chunks.first), isFalse);
      final fresh = CommandTranscriptStore(storage);
      addTearDown(fresh.close);
      expect(
        (await fresh.readBefore(
          'session',
          'run',
          'invocation',
          null,
          16,
          65536,
        )).chunks.last.cursor,
        3072,
      );
      expect((await _state(fresh)).state, 'complete');
    },
  );

  test(
    'forward backward and tail pages preserve exact Unicode controls and pipe order',
    () async {
      final writer = await _begin(store);
      final outputs = <EnvironmentProcessOutput>[
        _output('${'a' * 4095}\u{1f600}\r\x1b[31mred\x1b[0m\n\u0000'),
        _output('\t\u{1f642}e\u0301 stderr\r\n', stderr: true),
        _output('middle ${'b' * 9000} late\n'),
        _output('final\r\u0000', stderr: true),
      ];
      for (final output in outputs) {
        await writer.append(output);
      }
      await writer.seal(_completed(exitCode: 17));
      final forward = <CommandOutputChunk>[];
      while (true) {
        final page = await _after(
          store,
          cursor: forward.lastOrNull?.cursor ?? 0,
          chunks: 2,
          units: 8192,
        );
        if (page.chunks.isEmpty) break;
        forward.addAll(page.chunks);
      }
      expect(
        forward.map((chunk) => chunk.text).join(),
        outputs.map((output) => output.text).join(),
      );
      expect(
        forward.map((chunk) => chunk.cursor),
        List.generate(forward.length, (i) => i + 1),
      );
      for (final stream in ['stdout', 'stderr']) {
        expect(
          forward
              .where((chunk) => chunk.stream == stream)
              .map((chunk) => chunk.text)
              .join(),
          outputs
              .where((output) => output.stream.name == stream)
              .map((output) => output.text)
              .join(),
        );
      }
      for (final chunk in forward) {
        expect(chunk.text.length, lessThanOrEqualTo(4096));
        expect(utf8.decode(utf8.encode(chunk.text)), chunk.text);
      }
      expect(forward.first.text.length, 4095);
      final backward = <CommandOutputChunk>[];
      int? before;
      while (true) {
        final page = await store.readBefore(
          'session',
          'run',
          'invocation',
          before,
          2,
          8192,
        );
        if (page.chunks.isEmpty) break;
        expect(
          page.chunks.map((chunk) => chunk.cursor).toList(),
          orderedEquals(
            page.chunks.map((chunk) => chunk.cursor).toList()..sort(),
          ),
        );
        backward.insertAll(0, page.chunks);
        before = page.chunks.first.cursor;
      }
      expect(_values(backward), _values(forward));
      final tail = await store.readBefore(
        'session',
        'run',
        'invocation',
        null,
        16,
        4096,
      );
      expect(
        _values(tail.chunks),
        _values(forward.sublist(forward.length - 1)),
      );
      expect((await _after(store, cursor: 10000)).chunks, isEmpty);
      expect(
        (await store.readBefore(
          'session',
          'run',
          'invocation',
          0,
          1,
          4096,
        )).chunks,
        isEmpty,
      );
    },
  );

  test(
    'invalid page bounds and mismatched associations reject reads and watch',
    () async {
      final writer = await _begin(store);
      await writer.seal(_completed());
      for (final bounds in [
        (-1, 1, 4096),
        (0, 0, 4096),
        (0, 17, 4096),
        (0, 1, 4095),
        (0, 1, 65537),
      ]) {
        await expectLater(
          _after(store, cursor: bounds.$1, chunks: bounds.$2, units: bounds.$3),
          throwsA(_failure('invalid_page')),
        );
      }
      for (final association in [('other', 'run'), ('session', 'other-run')]) {
        await expectLater(
          store.getState(association.$1, association.$2, 'invocation'),
          throwsA(_failure('association_mismatch')),
        );
        await expectLater(
          store.readAfter(
            association.$1,
            association.$2,
            'invocation',
            0,
            16,
            65536,
          ),
          throwsA(_failure('association_mismatch')),
        );
        await expectLater(
          store.watch(association.$1, association.$2, 'invocation'),
          emitsInOrder([
            emitsError(_failure('association_mismatch')),
            emitsDone,
          ]),
        );
      }
      expect(store.observerCount, 0);
      await expectLater(
        store.getState('', 'run', 'invocation'),
        throwsA(_failure('invalid_identity')),
      );
    },
  );

  test(
    'SQLite chunk failure rolls back header highwater and all batch rows',
    () async {
      final writer = await _begin(store);
      storage.database.execute(
        '''CREATE TRIGGER reject_second BEFORE INSERT ON adele_command_chunks
      WHEN NEW.position=2 BEGIN SELECT RAISE(IGNORE); END''',
      );
      await expectLater(writer.append(_output('z' * 8192)), throwsStateError);
      expect(storage.rollbacks, 1);
      expect(
        storage.database.select('SELECT * FROM adele_command_chunks'),
        isEmpty,
      );
      final header = await _state(store);
      expect(
        (header.highWater, header.totalCodeUnits, header.version),
        (0, 0, 1),
      );
      expect(store.pendingBatchChunks, 0);
      await writer.fail('append rejected');
      expect((await _state(store)).state, 'failed');
    },
  );

  test(
    'stale expectedRows compare-and-set rejects before any chunk is inserted',
    () async {
      final writer = await _begin(store);
      storage.database.execute(
        'UPDATE adele_command_captures SET version=version+1',
      );
      await expectLater(
        writer.append(_output('never committed')),
        throwsStateError,
      );
      expect(storage.rollbacks, 1);
      expect((await _after(store)).chunks, isEmpty);
      await writer.fail('stale extent');
      final fresh = CommandTranscriptStore(storage);
      addTearDown(fresh.close);
      expect((await _state(fresh)).state, 'interrupted');
    },
  );

  test(
    'subscription registered before initial read cannot lose a racing append or seal',
    () async {
      final writer = await _begin(store);
      final reading = Completer<void>();
      final release = Completer<void>();
      var gate = true;
      storage.afterQuery = (sql, rows) async {
        if (gate && sql.contains('SELECT * FROM adele_command_captures')) {
          gate = false;
          reading.complete();
          await release.future;
        }
      };
      final observed = <CommandCaptureState>[];
      final complete = Completer<void>();
      final subscription = store.watch('session', 'run', 'invocation').listen((
        state,
      ) {
        observed.add(state);
        if (state.state == 'complete') complete.complete();
      });
      addTearDown(subscription.cancel);
      await reading.future;
      expect(store.observerCount, 1);
      await writer.append(_output('raced'));
      await writer.seal(_completed());
      release.complete();
      await complete.future.timeout(const Duration(seconds: 2));
      expect(observed.first.highWater, 0);
      expect(observed.first.state, 'capturing');
      expect(observed.last.highWater, 1);
      expect(observed.last.version, 3);
      expect((await _after(store)).chunks.single.text, 'raced');
    },
  );

  test(
    'paused observer coalesces state while independent readers and capture advance',
    () async {
      final writer = await _begin(store);
      final initial = Completer<void>();
      final complete = Completer<void>();
      final observed = <CommandCaptureState>[];
      final subscription = store.watch('session', 'run', 'invocation').listen((
        state,
      ) {
        observed.add(state);
        if (!initial.isCompleted) initial.complete();
        if (state.state == 'complete') complete.complete();
      });
      addTearDown(subscription.cancel);
      await initial.future;
      subscription.pause();
      final pausedQueries = storage.queries;
      for (var i = 0; i < 64; i++) {
        await writer.append(_output('$i\n'));
      }
      await writer.seal(_completed());
      expect(storage.queries, pausedQueries);
      expect(observed, hasLength(1));
      expect(store.observerCount, 1);
      final firstReader = await _after(store, chunks: 1);
      final otherReader = await _after(store, cursor: 40, chunks: 2);
      expect(firstReader.chunks.single.text, '0\n');
      expect(otherReader.chunks.map((chunk) => chunk.text), ['40\n', '41\n']);
      subscription.resume();
      await complete.future.timeout(const Duration(seconds: 2));
      expect(observed, hasLength(2));
      expect(observed.last.highWater, 64);
      expect(observed.last.state, 'complete');
      var cursor = firstReader.chunks.last.cursor;
      final catchup = StringBuffer(firstReader.chunks.single.text);
      while (cursor < observed.last.highWater) {
        final page = await _after(store, cursor: cursor);
        catchup.writeAll(page.chunks.map((chunk) => chunk.text));
        cursor = page.chunks.last.cursor;
      }
      expect(catchup.toString(), List.generate(64, (i) => '$i\n').join());
      await subscription.cancel();
      expect(store.observerCount, 0);
    },
  );

  test(
    'state-only completion and observer cancellation do not cancel capture',
    () async {
      final writer = await _begin(store);
      var producerCancelled = false;
      writer.cancelProducer = () async => producerCancelled = true;
      final first = StreamIterator(store.watch('session', 'run', 'invocation'));
      final second = StreamIterator(
        store.watch('session', 'run', 'invocation'),
      );
      addTearDown(first.cancel);
      addTearDown(second.cancel);
      expect(await first.moveNext(), isTrue);
      expect(await second.moveNext(), isTrue);
      await first.cancel();
      expect(store.observerCount, 1);
      expect(producerCancelled, isFalse);
      await writer.seal(_completed());
      expect(await second.moveNext(), isTrue);
      expect((second.current.state, second.current.highWater), ('complete', 0));
      expect(producerCancelled, isFalse);
      expect(store.activeCaptureCount, 0);
    },
  );

  test(
    'unique admission rejects concurrent setup and completed duplicate without poisoning history',
    () async {
      final entered = Completer<void>();
      final release = Completer<void>();
      storage.beforeSchema = () async {
        entered.complete();
        await release.future;
      };
      final beginning = _begin(store);
      await entered.future;
      await expectLater(_begin(store), throwsStateError);
      expect(store.activeCaptureCount, 1);
      release.complete();
      final writer = await beginning;
      await writer.append(_output('original'));
      await writer.seal(_completed());
      final before = await _state(store);
      await expectLater(_begin(store), throwsA(isA<Object>()));
      final after = await _state(store);
      expect(after.state, 'complete');
      expect(after.version, before.version);
      expect((await _after(store)).chunks.single.text, 'original');
    },
  );

  test(
    'same opaque invocation ID in separate Runs has independent capture and observers',
    () async {
      final first = await _begin(store);
      final second = await _begin(store, run: 'other-run');
      expect(store.activeCaptureCount, 2);
      final firstObserver = StreamIterator(
        store.watch('session', 'run', 'invocation'),
      );
      final secondObserver = StreamIterator(
        store.watch('session', 'other-run', 'invocation'),
      );
      addTearDown(firstObserver.cancel);
      addTearDown(secondObserver.cancel);
      expect(await firstObserver.moveNext(), isTrue);
      expect(await secondObserver.moveNext(), isTrue);
      expect(store.observerCount, 2);
      await first.append(_output('first run output'));
      expect(
        (await store.getState('session', 'other-run', 'invocation')).highWater,
        0,
      );
      await second.append(_output('second run stderr', stderr: true));
      await first.fail('only first failed');
      await second.seal(_completed(exitCode: 23));
      expect(await firstObserver.moveNext(), isTrue);
      expect(await secondObserver.moveNext(), isTrue);
      expect(
        (
          firstObserver.current.runId,
          firstObserver.current.state,
          firstObserver.current.failure,
        ),
        ('run', 'failed', 'only first failed'),
      );
      expect(
        (
          secondObserver.current.runId,
          secondObserver.current.state,
          secondObserver.current.exitCode,
          secondObserver.current.failure,
        ),
        ('other-run', 'complete', 23, null),
      );
      expect((await _after(store)).chunks.single.text, 'first run output');
      final otherPage = await store.readAfter(
        'session',
        'other-run',
        'invocation',
        0,
        16,
        65536,
      );
      expect(
        (
          otherPage.chunks.single.cursor,
          otherPage.chunks.single.stream,
          otherPage.chunks.single.text,
        ),
        (1, 'stderr', 'second run stderr'),
      );
      await expectLater(
        store.getState('other', 'run', 'invocation'),
        throwsA(_failure('association_mismatch')),
      );
      await expectLater(
        store.getState('session', 'missing-run', 'invocation'),
        throwsA(_failure('association_mismatch')),
      );
      final fresh = CommandTranscriptStore(storage);
      addTearDown(fresh.close);
      expect((await _state(fresh)).state, 'failed');
      expect(
        (await fresh.getState('session', 'other-run', 'invocation')).state,
        'complete',
      );
      await firstObserver.cancel();
      expect(store.observerCount, 1);
      await secondObserver.cancel();
      expect(store.observerCount, 0);
      expect(store.activeCaptureCount, 0);
    },
  );

  test(
    'read page is fenced to its header extent during a concurrent commit',
    () async {
      final writer = await _begin(store);
      await writer.append(_output('first'));
      final reading = Completer<void>();
      final release = Completer<void>();
      var gated = false;
      storage.afterQuery = (sql, rows) async {
        if (!gated && sql.contains('SELECT * FROM adele_command_captures')) {
          gated = true;
          reading.complete();
          await release.future;
        }
      };
      final pending = _after(store);
      await reading.future;
      await writer.append(_output('second', stderr: true));
      await writer.seal(_completed());
      release.complete();
      final snapshot = await pending;
      expect(snapshot.state.highWater, 1);
      expect(snapshot.state.state, 'capturing');
      expect(snapshot.chunks.map((chunk) => chunk.text), ['first']);
      final catchup = await _after(store, cursor: snapshot.chunks.last.cursor);
      expect(catchup.state.state, 'complete');
      expect(catchup.chunks.map((chunk) => chunk.text), ['second']);
    },
  );

  test(
    'pausing an in-flight observation retains only the latest resumed state',
    () async {
      final writer = await _begin(store);
      final reading = Completer<void>();
      final release = Completer<void>();
      var gated = false;
      storage.afterQuery = (sql, rows) async {
        if (!gated) {
          gated = true;
          reading.complete();
          await release.future;
        }
      };
      final observed = <CommandCaptureState>[];
      final terminal = Completer<void>();
      final subscription = store.watch('session', 'run', 'invocation').listen((
        state,
      ) {
        observed.add(state);
        if (state.state == 'failed') terminal.complete();
      });
      addTearDown(subscription.cancel);
      await reading.future;
      subscription.pause();
      for (var i = 0; i < 20; i++) {
        await writer.append(_output('$i'));
      }
      await writer.fail('x' * 2048);
      release.complete();
      // Allow the held storage read to settle while its subscriber is paused.
      await Future<void>.delayed(Duration.zero);
      expect(observed, isEmpty);
      subscription.resume();
      await terminal.future.timeout(const Duration(seconds: 2));
      expect(observed, hasLength(1));
      expect(observed.single.highWater, 20);
      expect(observed.single.failure!.length, 1024);
    },
  );

  for (final missing in [1, 2, 3]) {
    test(
      'missing committed chunk $missing rejects the page without poisoning unrelated history',
      () async {
        final writer = await _begin(store);
        for (var i = 1; i <= 3; i++) {
          await writer.append(_output('$i'));
        }
        await writer.seal(_completed());
        final unrelated = await _begin(store, id: 'unrelated');
        await unrelated.append(_output('intact'));
        await unrelated.seal(_completed());
        // Read once before mutation to also prove the next read does not use a
        // permanent cached collection of output objects.
        expect((await _after(store)).chunks, hasLength(3));
        storage.database.execute(
          'DELETE FROM adele_command_chunks WHERE invocation_id=? AND position=?',
          ['invocation', missing],
        );
        await expectLater(_after(store), throwsA(_failure('corrupt_capture')));
        await expectLater(
          store.readBefore('session', 'run', 'invocation', null, 16, 65536),
          throwsA(_failure('corrupt_capture')),
        );
        expect(
          (await store.readAfter(
            'session',
            'run',
            'unrelated',
            0,
            16,
            65536,
          )).chunks.single.text,
          'intact',
        );
      },
    );
  }

  for (final invalid in <(String, String)>[
    ('extent exceeds chunk capacity', 'total_code_units=4097'),
    ('capturing termination', "termination='timedOut'"),
    ('capturing exit outcome', "termination='exited',exit_code=23"),
    ('capturing failure', "failure='unexpected terminal field'"),
    ('failed without failure', "state='failed'"),
    ('failed with empty failure', "state='failed',failure=''"),
  ]) {
    test('rejects stored header with ${invalid.$1}', () async {
      final writer = await _begin(store);
      await writer.append(_output('x' * 4096));
      final valid = await _state(store);
      expect((valid.highWater, valid.totalCodeUnits), (1, 4096));
      storage.database.execute(
        'UPDATE adele_command_captures SET ${invalid.$2} WHERE invocation_id=? AND run_id=?',
        ['invocation', 'run'],
      );
      await expectLater(_state(store), throwsA(_failure('corrupt_capture')));
      await expectLater(_after(store), throwsA(_failure('corrupt_capture')));
      final fresh = CommandTranscriptStore(storage);
      addTearDown(fresh.close);
      await expectLater(_state(fresh), throwsA(_failure('corrupt_capture')));
    });
  }

  test(
    'stored working directory must be canonical and Environment-relative',
    () async {
      final writer = await _begin(store);
      await writer.seal(_completed());
      for (final directory in [
        '/',
        '/absolute',
        'src/',
        'src//nested',
        '.',
        './src',
        'src/./nested',
        '..',
        '../src',
        'src/../nested',
      ]) {
        storage.database.execute(
          'UPDATE adele_command_captures SET working_directory=? WHERE invocation_id=? AND run_id=?',
          [directory, 'invocation', 'run'],
        );
        await expectLater(
          _state(store),
          throwsA(_failure('corrupt_capture')),
          reason: directory,
        );
      }
      for (final directory in ['', 'src', 'src/nested', 'two words/.hidden']) {
        storage.database.execute(
          'UPDATE adele_command_captures SET working_directory=? WHERE invocation_id=? AND run_id=?',
          [directory, 'invocation', 'run'],
        );
        expect((await _state(store)).workingDirectory, directory);
      }
    },
  );

  test(
    'many acknowledged failures retain SQL history but no uncertain overlays',
    () async {
      expect(store.uncertainCaptureCount, 0);
      for (var i = 0; i < 128; i++) {
        final writer = await _begin(store, id: 'failure-$i');
        await writer.append(_output('output-$i'));
        await writer.fail('failure-$i ${'x' * 2048}');
        expect(store.uncertainCaptureCount, 0);
        expect(store.activeCaptureCount, 0);
        expect(store.pendingBatchChunks, 0);
        final state = await store.getState('session', 'run', 'failure-$i');
        expect(state.state, 'failed');
        expect(state.failure, startsWith('failure-$i '));
        expect(state.failure!.length, 1024);
      }
      expect(
        storage.database
            .select(
              "SELECT COUNT(*) AS count FROM adele_command_captures WHERE state='failed'",
            )
            .single['count'],
        128,
      );
      final fresh = CommandTranscriptStore(storage);
      addTearDown(fresh.close);
      for (final id in ['failure-0', 'failure-127']) {
        expect((await fresh.getState('session', 'run', id)).state, 'failed');
        expect(
          (await fresh.readAfter('session', 'run', id, 0, 16, 65536)).chunks,
          hasLength(1),
        );
      }
      expect(fresh.uncertainCaptureCount, 0);
    },
  );

  for (final lostAck in [false, true]) {
    test(
      'uncertain ${lostAck ? 'lost marker acknowledgement' : 'failed marker'} overlay is bounded and cleared on close',
      () async {
        final writer = await _begin(store);
        await writer.append(_output('retained output'));
        var attempts = 0;
        void rejectMarker(List<RelationalStatement> statements) {
          if (CommandTestStorage.kindOf(statements) == 'failed') {
            attempts++;
            throw StateError('marker unavailable');
          }
        }

        if (lostAck) {
          storage.afterCommit = rejectMarker;
        } else {
          storage.beforeTransaction = rejectMarker;
        }
        await writer.fail('x' * 2048, termination: 'exited', exitCode: 23);
        expect(attempts, 1);
        expect(store.uncertainCaptureCount, 1);
        expect(store.activeCaptureCount, 0);
        final state = await _state(store);
        expect(
          (state.state, state.termination, state.exitCode),
          ('failed', 'exited', 23),
        );
        expect(state.failure!.length, 1024);
        expect((await _after(store)).chunks.single.text, 'retained output');
        await writer.fail('must not retry or replace the uncertainty');
        expect(attempts, 1);
        expect(store.uncertainCaptureCount, 1);
        storage.beforeTransaction = null;
        storage.afterCommit = null;

        final otherRun = await _begin(store, run: 'other-run');
        await otherRun.fail('acknowledged independent failure');
        expect(store.uncertainCaptureCount, 1);
        expect(
          (await store.getState('session', 'other-run', 'invocation')).failure,
          'acknowledged independent failure',
        );

        final closing = await _begin(store, id: 'closing');
        var cancellations = 0;
        closing.cancelProducer = () async {
          cancellations++;
          expect(store.activeCaptureCount, 0);
          expect(store.uncertainCaptureCount, 0);
          await closing.fail('cleanup after store close');
          expect(store.uncertainCaptureCount, 0);
        };
        final transactions = storage.transactions;
        await store.close();
        expect(cancellations, 1);
        expect(store.uncertainCaptureCount, 0);
        expect(store.activeCaptureCount, 0);
        expect(storage.transactions, transactions);
        await closing.fail('late repeated cleanup');
        expect(store.uncertainCaptureCount, 0);

        final fresh = CommandTranscriptStore(storage);
        addTearDown(fresh.close);
        expect((await _state(fresh)).state, lostAck ? 'failed' : 'interrupted');
        expect((await _after(fresh)).chunks.single.text, 'retained output');
        expect(fresh.uncertainCaptureCount, 0);
        expect(
          (await fresh.getState('session', 'run', 'closing')).state,
          'interrupted',
        );
      },
    );
  }

  for (final phase in ['setup', 'append', 'complete']) {
    for (final lostAck in [false, true]) {
      test(
        '$phase ${lostAck ? 'lost acknowledgement' : 'failure'} is not retried and committed extent survives fresh store',
        () async {
          final history = await _begin(store, id: 'history');
          await history.append(_output('unrelated retained'));
          await history.seal(_completed());
          var injections = 0;
          void inject(List<RelationalStatement> statements) {
            if (CommandTestStorage.kindOf(statements) == phase &&
                injections++ == 0) {
              throw StateError(
                'injected $phase ${lostAck ? 'lost ack' : 'failure'}',
              );
            }
          }

          if (lostAck) {
            storage.afterCommit = inject;
          } else {
            storage.beforeTransaction = inject;
          }
          if (phase == 'setup') {
            await expectLater(_begin(store), throwsStateError);
          } else {
            final writer = await _begin(store);
            if (phase == 'append') {
              await expectLater(
                writer.append(_output('committed iff ack lost')),
                throwsStateError,
              );
            } else {
              await writer.append(_output('committed iff ack lost'));
              await expectLater(
                writer.seal(_completed(exitCode: 23)),
                throwsStateError,
              );
            }
            await writer.fail(
              'capture failed',
              termination: phase == 'complete' ? 'exited' : null,
              exitCode: phase == 'complete' ? 23 : null,
            );
          }
          expect(injections, 1);
          expect(store.pendingBatchChunks, 0);
          expect(store.activeCaptureCount, 0);
          final live = await _state(store);
          expect(
            live.state,
            phase == 'setup' ? (lostAck ? 'interrupted' : 'absent') : 'failed',
          );
          final fresh = CommandTranscriptStore(storage);
          addTearDown(fresh.close);
          final state = await _state(fresh);
          final expected = switch ((phase, lostAck)) {
            ('setup', false) => 'absent',
            ('setup', true) || ('append', true) => 'interrupted',
            ('complete', true) => 'complete',
            _ => 'failed',
          };
          expect(state.state, expected);
          final shouldHaveOutput =
              phase == 'complete' || (phase == 'append' && lostAck);
          expect(state.highWater, shouldHaveOutput ? 1 : 0);
          expect(
            (await _after(fresh)).chunks.map((chunk) => chunk.text),
            shouldHaveOutput ? ['committed iff ack lost'] : isEmpty,
          );
          if (phase == 'complete') expect(state.exitCode, 23);
          expect(
            (await fresh.readAfter(
              'session',
              'run',
              'history',
              0,
              16,
              65536,
            )).chunks.single.text,
            'unrelated retained',
          );
          final distinct = await _begin(store, id: 'distinct');
          await distinct.seal(_completed());
        },
      );
    }
  }

  test(
    'schema failure prevents capture without substituting memory storage',
    () async {
      storage.beforeSchema = () => throw StateError('unavailable storage');
      await expectLater(_begin(store), throwsStateError);
      expect(storage.transactions, 0);
      expect(store.activeCaptureCount, 0);
      expect(store.pendingBatchChunks, 0);
      await expectLater(_begin(store), throwsStateError);
      expect(storage.schemaChecks, 1);
    },
  );

  test(
    'close cancels producer and never waits for a paused observer',
    () async {
      final writer = await _begin(store);
      final cancelled = Completer<void>();
      writer.cancelProducer = () async {
        cancelled.complete();
        await writer.fail('backend closed');
      };
      final observer = StreamIterator(
        store.watch('session', 'run', 'invocation'),
      );
      expect(await observer.moveNext(), isTrue);
      expect(store.observerCount, 1);
      await store.close().timeout(const Duration(seconds: 2));
      await cancelled.future;
      expect(store.observerCount, 0);
      expect(store.activeCaptureCount, 0);
      expect(store.pendingBatchChunks, 0);
      expect(
        await observer.moveNext().timeout(const Duration(seconds: 2)),
        isFalse,
      );
      await observer.cancel();
      await store.close();
      await expectLater(_state(store), throwsStateError);
      await expectLater(
        store.watch('session', 'run', 'invocation'),
        emitsInOrder([emitsError(isStateError), emitsDone]),
      );
      final fresh = CommandTranscriptStore(storage);
      addTearDown(fresh.close);
      expect((await _state(fresh)).state, 'interrupted');
    },
  );
}

Future<CommandCaptureWriter> _begin(
  CommandTranscriptStore store, {
  String id = 'invocation',
  String run = 'run',
}) => store.begin(
  context: ToolExecutionContext(
    sessionId: SessionId('session'),
    runId: RunId(run),
    toolInvocationId: id,
  ),
  environmentId: 'environment',
  request: EnvironmentForegroundProcessRequest(
    program: 'fixture',
    arguments: ['two words', '', 'literal | argument'],
    relativeWorkingDirectory: 'src',
    timeoutSeconds: 30,
  ),
);

Future<CommandCaptureState> _state(CommandTranscriptStore store) =>
    store.getState('session', 'run', 'invocation');

Future<CommandOutputPage> _after(
  CommandTranscriptStore store, {
  int cursor = 0,
  int chunks = 16,
  int units = 65536,
}) => store.readAfter('session', 'run', 'invocation', cursor, chunks, units);

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

List<(int, String, String)> _values(Iterable<CommandOutputChunk> chunks) =>
    chunks.map((chunk) => (chunk.cursor, chunk.stream, chunk.text)).toList();

Matcher _failure(String code) =>
    isA<CommandOutputFailure>().having((error) => error.code, 'code', code);
