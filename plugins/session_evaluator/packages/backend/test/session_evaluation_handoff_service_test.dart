import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:adele_contract/adele_contract.dart';
import 'package:adele_project_storage/adele_project_storage.dart';
import 'package:session_evaluator_backend/session_evaluator_backend.dart';
import 'package:session_evaluator_backend/src/evidence_tables.dart';
import 'package:session_evaluator_contract/session_evaluator_contract.dart';
import 'package:test/test.dart';

void main() {
  late Directory directory;
  late Directory output;
  late _Storage storage;
  late SessionEvaluationHandoffServiceImpl service;
  var rootCalls = 0;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('adele-handoff-service-');
    output = Directory('${directory.path}/state/evaluations');
    storage = _Storage(Directory('${directory.path}/source').uri.toString());
    rootCalls = 0;
    service = SessionEvaluationHandoffServiceImpl(
      storage,
      outputRoot: () async {
        rootCalls++;
        return output;
      },
    );
  });
  tearDown(() async {
    await service.close();
    await directory.delete(recursive: true);
  });

  Future<String> prepare() async {
    final iterator = StreamIterator(service.prepareSession('session'));
    try {
      return await readSessionEvaluationHandoff(iterator);
    } finally {
      await iterator.cancel();
    }
  }

  void expectNoHandoff() {
    if (output.existsSync()) expect(output.listSync(), isEmpty);
  }

  test('unlistened preparation is inert, including after close', () async {
    final stream = service.prepareSession('session');
    await Future<void>.delayed(Duration.zero);
    expect(storage.queries, isEmpty);
    expect(rootCalls, 0);
    await service.close();
    await expectLater(stream.toList(), throwsA(_safeFailure));
    expect(storage.queries, isEmpty);
    expect(output.existsSync(), isFalse);
  });

  test('normal EOF retains exact evidence bytes and all three files', () async {
    final document = await readSessionEvidence(
      SessionEvidenceCollector(storage),
      'session',
    );
    final path = await prepare();
    final destination = File(path).parent;
    expect(File(path).isAbsolute, isTrue);
    expect(File(path).uri.pathSegments.last, 'README.md');
    expect(destination.parent.path, output.path);
    expect(
      destination.listSync().map((file) => file.uri.pathSegments.last).toSet(),
      {'README.md', 'summary.json', 'evidence.json'},
    );
    expect(
      await File('${destination.path}/evidence.json').readAsBytes(),
      utf8.encode(jsonEncode(document)),
    );
    expect(
      await File('${destination.path}/summary.json').readAsBytes(),
      utf8.encode(jsonEncode(summarizeSessionEvidence(document))),
    );
    expect(
      await File(path).readAsString(),
      contains('unsupported Environment'),
    );
    await service.close();
    expect(destination.existsSync(), isTrue);
    expect(rootCalls, 1);
  });

  test('generation admission rejects duplicates without extra reads', () async {
    final gate = _Gate();
    storage.beforeQuery = (_) => gate.wait();
    final first = StreamIterator(service.prepareSession('session'));
    final pending = first.moveNext();
    await gate.entered.future;
    for (final session in ['session', 'different-session']) {
      await expectLater(
        service.prepareSession(session).toList(),
        throwsA(_safeFailure),
      );
    }
    expect(storage.queries, hasLength(1));
    storage.beforeQuery = null;
    final cancelled = first.cancel();
    gate.release.complete();
    await cancelled;
    expect(await pending, isFalse);
    expect(storage.queries, hasLength(1));
    expect(rootCalls, 0);
    expectNoHandoff();
    expect(await prepare(), endsWith('README.md'));
  });

  for (final phase in ['collection', 'provenance']) {
    test(
      'cancel during $phase query fences subsequent reads and joins it',
      () async {
        final gate = _Gate();
        var identityReads = 0;
        storage.beforeQuery = (sql) async {
          if (sql.contains('SELECT s.id AS session_id')) {
            identityReads++;
            if (identityReads == (phase == 'collection' ? 1 : 2)) {
              await gate.wait();
            }
          }
        };
        final iterator = StreamIterator(service.prepareSession('session'));
        final pending = iterator.moveNext();
        await gate.entered.future;
        var settled = false;
        final cancelled = iterator.cancel().then((_) => settled = true);
        await Future<void>.delayed(Duration.zero);
        expect(settled, isFalse);
        final count = storage.queries.length;
        gate.release.complete();
        await cancelled;
        expect(await pending, isFalse);
        expect(storage.queries, hasLength(count));
        expect(rootCalls, 0);
        expectNoHandoff();
      },
    );
  }

  test('close fences synchronously and drains a blocked query', () async {
    final gate = _Gate();
    storage.beforeQuery = (_) => gate.wait();
    final result = service.prepareSession('session').toList();
    await gate.entered.future;
    var settled = false;
    final closing = service.close().then((_) => settled = true);
    await expectLater(prepare(), throwsA(_safeFailure));
    await Future<void>.delayed(Duration.zero);
    expect(settled, isFalse);
    gate.release.complete();
    await closing;
    expect(await result, isEmpty);
    expect(storage.queries, hasLength(1));
    expect(rootCalls, 0);
  });

  test(
    'optional provider-state cancellation cannot become a handoff',
    () async {
      storage.identity['environment_provider_id'] =
          'dev.adele.environment.git-worktree';
      final gate = _Gate();
      storage.beforeQuery = (sql) async {
        if (sql.startsWith('SELECT e.provider_state_json ')) {
          await gate.wait();
        }
      };
      final iterator = StreamIterator(service.prepareSession('session'));
      final pending = iterator.moveNext();
      await gate.entered.future;
      final count = storage.queries.length;
      final cancelled = iterator.cancel();
      gate.release.complete();
      await cancelled;
      expect(await pending, isFalse);
      expect(storage.queries, hasLength(count));
      expect(rootCalls, 0);
      expect(output.existsSync(), isFalse);
    },
  );

  test(
    'changed canonical graph fails before root resolution or allocation',
    () async {
      var identities = 0;
      storage.beforeQuery = (sql) async {
        if (sql.contains('SELECT s.id AS session_id') && ++identities == 2) {
          storage.identity['task_title'] = 'changed';
        }
      };
      await expectLater(prepare(), throwsA(_safeFailure));
      expect(rootCalls, 0);
      expect(output.existsSync(), isFalse);
    },
  );

  test('cancellation while resolving root creates no directories', () async {
    final gate = _Gate();
    await service.close();
    service = SessionEvaluationHandoffServiceImpl(
      storage,
      outputRoot: () async {
        await gate.wait();
        return output;
      },
    );
    final iterator = StreamIterator(service.prepareSession('session'));
    final pending = iterator.moveNext();
    await gate.entered.future;
    final cancelled = iterator.cancel();
    gate.release.complete();
    await cancelled;
    expect(await pending, isFalse);
    expect(output.existsSync(), isFalse);
  });

  test(
    'cancellation during allocation joins removal before any file write',
    () async {
      final gate = _Gate();
      final overrides = _WriteOverrides(filename: '', allocationGate: gate);
      late StreamIterator<String> iterator;
      final pending = IOOverrides.runWithIOOverrides(() {
        iterator = StreamIterator(service.prepareSession('session'));
        return iterator.moveNext();
      }, overrides);
      await gate.entered.future;
      expect(output.listSync(), hasLength(1));
      final cancelled = iterator.cancel();
      gate.release.complete();
      await cancelled;
      expect(await pending, isFalse);
      expect(overrides.writes, isEmpty);
      expectNoHandoff();
    },
  );

  for (final filename in ['evidence.json', 'summary.json', 'README.md']) {
    for (final close in [false, true]) {
      test(
        '${close ? 'close' : 'cancel'} during $filename joins cleanup',
        () async {
          final gate = _Gate();
          final overrides = _WriteOverrides(filename: filename, gate: gate);
          late StreamIterator<String> iterator;
          final pending = IOOverrides.runWithIOOverrides(() {
            iterator = StreamIterator(service.prepareSession('session'));
            return iterator.moveNext();
          }, overrides);
          await gate.entered.future;
          expect(output.listSync(), hasLength(1));
          var settled = false;
          final cancelled = (close ? service.close() : iterator.cancel()).then(
            (_) => settled = true,
          );
          await Future<void>.delayed(Duration.zero);
          expect(settled, isFalse);
          gate.release.complete();
          await cancelled;
          expect(await pending, isFalse);
          await iterator.cancel();
          expectNoHandoff();
          expect(overrides.writes.last, filename);
        },
      );
    }

    test(
      '$filename failure is sanitized and preserves previous output',
      () async {
        final previous = await prepare();
        final retained = await File(previous).readAsBytes();
        await expectLater(
          IOOverrides.runWithIOOverrides(
            prepare,
            _WriteOverrides(filename: filename, fail: true),
          ),
          throwsA(_safeFailure),
        );
        expect(output.listSync().map((entry) => entry.path), [
          File(previous).parent.path,
        ]);
        expect(await File(previous).readAsBytes(), retained);
        expect(await prepare(), isNot(previous));
      },
    );
  }

  test(
    'cancellation after writer validation but before publication deletes output',
    () async {
      late StreamIterator<String> iterator;
      Future<void>? cancelled;
      final overrides = _WriteOverrides(
        filename: 'README.md',
        beforePublication: () => cancelled = iterator.cancel(),
      );
      final pending = IOOverrides.runWithIOOverrides(() {
        iterator = StreamIterator(service.prepareSession('session'));
        return iterator.moveNext();
      }, overrides);
      expect(await pending, isFalse);
      await cancelled;
      expect(overrides.scheduledLateCancellation, isTrue);
      expect(overrides.writes, ['evidence.json', 'summary.json', 'README.md']);
      expectNoHandoff();
    },
  );

  test('all storage failures are sanitized and no root is resolved', () async {
    for (final error in [
      StateError('private SQL /secret/source token=secret'),
      const SessionEvidenceFailure(
        code: 'private',
        message: 'secret',
        details: {'secret': 'token'},
      ),
    ]) {
      storage.beforeQuery = (_) => Future<void>.error(error);
      await expectLater(prepare(), throwsA(_safeFailure));
    }
    expect(rootCalls, 0);
    expect(output.existsSync(), isFalse);
  });

  test(
    'invalid Session identities fail before storage or allocation',
    () async {
      for (final id in ['', ' session', 'session\n']) {
        await expectLater(
          service.prepareSession(id).toList(),
          throwsA(_safeFailure),
        );
      }
      expect(storage.queries, isEmpty);
      expect(rootCalls, 0);
    },
  );

  test(
    'generated transport cancel acknowledges only after worker cleanup',
    () async {
      final gate = _Gate();
      storage.beforeQuery = (_) => gate.wait();
      final router = AdeleConfigurationContextRouter.single(
        configurationContext: 'context',
        serviceId: sessionEvaluationHandoffServiceId,
        dispatcher: SessionEvaluationHandoffServiceDispatcher(service),
      );
      addTearDown(router.close);
      final frames = <Map<String, Object?>>[];
      await router.handle({
        'kind': 'streamOpen',
        'requestId': 1,
        'configurationContext': 'context',
        'serviceId': sessionEvaluationHandoffServiceId,
        'method': sessionEvaluationHandoffServicePrepareSessionId,
        'payload': {'sessionId': 'session'},
      }, frames.add);
      final pumping = router.handle({
        'kind': 'streamCredit',
        'requestId': 1,
        'credit': 1,
      }, frames.add);
      await gate.entered.future;
      final cancellation = router.handle({
        'kind': 'streamCancel',
        'requestId': 1,
      }, frames.add);
      await Future<void>.delayed(Duration.zero);
      expect(frames, isEmpty);
      gate.release.complete();
      await cancellation;
      await pumping;
      expect(frames, [
        {'kind': 'streamCancelled', 'requestId': 1},
      ]);
      expect(storage.queries, hasLength(1));
      expectNoHandoff();
    },
  );
}

final _safeFailure = isA<SessionEvidenceFailure>()
    .having((error) => error.code, 'code', 'handoff_unavailable')
    .having(
      (error) => error.message,
      'message',
      'Evaluation handoff could not be prepared.',
    )
    .having((error) => error.details, 'details', isEmpty);

final class _Gate {
  final entered = Completer<void>();
  final release = Completer<void>();

  Future<void> wait() {
    entered.complete();
    return release.future;
  }
}

final class _Storage implements ProjectStorageService {
  _Storage(String source)
    : identity = {
        'project_id': 'project',
        'task_id': 'task',
        'task_title': 'Exact task',
        'source_location': source,
        'session_id': 'session',
        'strategy_id': 'dev.adele.strategy.chat',
        'environment_id': 'environment',
        'environment_task_id': 'task',
        'environment_role': 'primary',
        'environment_provider_id': 'dev.adele.environment.fixture',
      };

  final Map<String, Object?> identity;
  final queries = <String>[];
  Future<void> Function(String)? beforeQuery;
  final tables = {
    for (final table in [
      productRuns,
      ...executionTables.values,
      chatSessions,
      chatEntries,
    ])
      table.name: table,
  };
  static const raw = ' \r\n\u001b[31m\u0000\t\u{1f600} exact \\n ';

  @override
  Future<List<RelationalRow>> queryForSession(
    String sessionId,
    String sql,
    Map<String, Object?> parameters,
    ProjectStorageAccessMode accessMode,
  ) async {
    expect(sessionId, 'session');
    expect(parameters[':session'], 'session');
    expect(accessMode, ProjectStorageAccessMode.durable);
    queries.add(sql);
    await beforeQuery?.call(sql);
    List<Map<String, Object?>> rows;
    if (sql.startsWith('SELECT version ')) {
      rows =
          [
            'dev.adele.product',
            'dev.adele.execution',
            'dev.adele.plugin.chat-strategy',
          ].contains(parameters[':owner'])
          ? [
              {'version': 1},
            ]
          : [];
    } else if (sql.contains('SELECT s.id AS session_id')) {
      rows = [Map.of(identity)];
    } else if (sql.startsWith('SELECT e.provider_state_json ')) {
      rows = [
        {'provider_state_json': null},
      ];
    } else if (sql.contains('FROM sqlite_master ')) {
      rows = tables.containsKey(parameters[':table'])
          ? [
              {'name': parameters[':table']},
            ]
          : [];
    } else if (sql.contains('FROM pragma_table_info(')) {
      final table = tables[parameters[':table']]!;
      rows = [
        for (final name in [...table.columns, ...table.excluded])
          {'name': name},
      ];
    } else if (sql.startsWith('SELECT COUNT(*) AS row_count ')) {
      rows = [
        {'row_count': sql.contains('adele_chat_') ? 1 : 0},
      ];
    } else if (sql.contains('FROM ${chatSessions.name} e ')) {
      rows = parameters[':after'] == null
          ? [
              {'session_id': 'session', 'instructions': raw, 'next_entry': 1},
            ]
          : [];
    } else if (sql.contains('FROM ${chatEntries.name} e ')) {
      rows = parameters[':after'] == null
          ? [
              {
                'session_id': 'session',
                'entry_id': 'entry-0',
                'role': 'user',
                'content': raw,
                'run_id': null,
                'sequence': 0,
              },
            ]
          : [];
    } else if (sql.contains('FROM ${productRuns.name} e ')) {
      rows = [];
    } else {
      fail('Unexpected query: $sql');
    }
    return [for (final row in rows) RelationalRow(values: row)];
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      fail('Unexpected storage mutation or method: ${invocation.memberName}');
}

final class _WriteOverrides extends IOOverrides {
  _WriteOverrides({
    required this.filename,
    this.gate,
    this.allocationGate,
    this.fail = false,
    this.beforePublication,
  });
  final String filename;
  final _Gate? gate;
  final _Gate? allocationGate;
  final bool fail;
  final void Function()? beforePublication;
  final writes = <String>[];
  bool readmeWritten = false;
  bool scheduledLateCancellation = false;

  @override
  File createFile(String path) => _WritingFile(super.createFile(path), this);

  @override
  Directory createDirectory(String path) =>
      _ResolvingDirectory(super.createDirectory(path), this);
}

final class _WritingFile implements File {
  const _WritingFile(this.file, this.owner);
  final File file;
  final _WriteOverrides owner;

  @override
  String get path => file.path;
  @override
  File get absolute => file.absolute;
  @override
  Uri get uri => file.uri;

  @override
  Future<File> writeAsBytes(
    List<int> bytes, {
    FileMode mode = FileMode.write,
    bool flush = false,
  }) async {
    expect(flush, isTrue);
    final name = file.uri.pathSegments.last;
    owner.writes.add(name);
    await file.writeAsBytes(bytes, mode: mode, flush: flush);
    if (name == owner.filename) {
      if (owner.fail) {
        throw FileSystemException('secret write failure', file.path);
      }
      await owner.gate?.wait();
    }
    if (name == 'README.md') owner.readmeWritten = true;
    return this;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _ResolvingDirectory implements Directory {
  const _ResolvingDirectory(this.directory, this.owner);
  final Directory directory;
  final _WriteOverrides owner;

  @override
  String get path => directory.path;
  @override
  Directory get absolute => directory.absolute;
  @override
  Directory get parent => directory.parent;
  @override
  Uri get uri => directory.uri;
  @override
  Future<Directory> create({bool recursive = false}) =>
      directory.create(recursive: recursive);
  @override
  Future<Directory> createTemp([String? prefix]) async {
    final destination = await directory.createTemp(prefix);
    await owner.allocationGate?.wait();
    return destination;
  }

  @override
  Future<FileSystemEntity> delete({bool recursive = false}) =>
      directory.delete(recursive: recursive);

  @override
  String resolveSymbolicLinksSync() {
    final path = directory.resolveSymbolicLinksSync();
    if (owner.readmeWritten &&
        owner.beforePublication != null &&
        !owner.scheduledLateCancellation) {
      owner.scheduledLateCancellation = true;
      // Writer's final synchronous validation still succeeds, but cancellation
      // runs before its Future resumes the service's publication continuation.
      scheduleMicrotask(owner.beforePublication!);
    }
    return path;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
