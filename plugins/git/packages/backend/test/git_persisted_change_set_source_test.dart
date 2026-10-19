@TestOn('linux')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:adele_environment/adele_environment.dart';
import 'package:adele_project_storage/adele_project_storage.dart';
import 'package:diff_viewer_contract/diff_viewer_contract.dart';
import 'package:git_backend/git_backend.dart'
    show
        GitPersistedChangeSetSourceService,
        GitPortableUnstagedLimits,
        GitTaskAnchorStore;
import 'package:test/test.dart';

final _identity = AuthorizedEnvironmentIdentity(
  sessionId: 'nonprimary-session',
  environmentId: 'additional-environment',
);
final _processSentinel = StateError('Reached the process boundary.');
const _baseline = '1111111111111111111111111111111111111111';

void main() {
  late _Storage storage;
  late _Processes processes;

  ChangeSetSourceService source({GitPortableUnstagedLimits? limits}) =>
      GitPersistedChangeSetSourceService(
        processes: processes,
        anchors: GitTaskAnchorStore(storage),
        limits: limits ?? const GitPortableUnstagedLimits(),
      );

  setUp(() {
    storage = _Storage([_row()]);
    processes = _Processes();
  });

  test(
    'zero-argument Task uses only captured Session and Environment',
    () async {
      await expectLater(
        source().snapshotTaskChanges(),
        throwsA(same(_processSentinel)),
      );
      expect(processes.identityCalls, 1);
      expect(processes.requests, hasLength(1));
      expect(storage.calls, ['schema', 'query']);
      expect(storage.sessions, [_identity.sessionId, _identity.sessionId]);
      expect(storage.parameters, [
        {':session': _identity.sessionId},
      ]);
    },
  );

  for (final (name, overrides, code)
      in <(String, Map<String, Object?>, String)>[
        (
          'missing anchor',
          {
            'anchor_environment_id': null,
            'baseline_commit': null,
            'expected_branch_ref': null,
          },
          'baseline_unavailable',
        ),
        ('malformed commit', {'baseline_commit': 'HEAD'}, 'baseline_corrupt'),
        ('wrong column type', {'baseline_commit': 1}, 'baseline_corrupt'),
        (
          'malformed branch',
          {'expected_branch_ref': 'main'},
          'baseline_corrupt',
        ),
        (
          'another Session',
          {'session_id': 'primary-session'},
          'baseline_association_mismatch',
        ),
        (
          'primary Environment instead of captured additional Environment',
          {
            'selected_environment_id': 'primary-environment',
            'environment_id': 'primary-environment',
            'anchor_environment_id': 'primary-environment',
          },
          'baseline_association_mismatch',
        ),
        (
          'another Task',
          {'environment_task_id': 'another-task'},
          'baseline_association_mismatch',
        ),
      ]) {
    test('$name fails before any subprocess', () async {
      storage.rows = [_row(overrides: overrides)];
      await expectLater(source().snapshotTaskChanges(), throwsA(_code(code)));
      expect(processes.identityCalls, 1);
      expect(processes.requests, isEmpty);
      expect(storage.calls, ['schema', 'query']);
    });
  }

  test('missing stored Session fails before any subprocess', () async {
    storage.rows = [];
    await expectLater(
      source().snapshotTaskChanges(),
      throwsA(_code('baseline_association_mismatch')),
    );
    expect(processes.requests, isEmpty);
  });

  for (final phase in ['schema', 'query']) {
    test('$phase failure is explicit and cannot fall back to Git', () async {
      if (phase == 'schema') {
        storage.onSchema = () async => throw StateError('Private SQL error.');
      } else {
        storage.onQuery = () async => throw StateError('Private SQL error.');
      }
      await expectLater(
        source().snapshotTaskChanges(),
        throwsA(
          _code(
            'baseline_storage_failed',
          ).having((failure) => failure.details, 'details', isEmpty),
        ),
      );
      expect(
        storage.calls,
        phase == 'schema' ? ['schema'] : ['schema', 'query'],
      );
      expect(processes.requests, isEmpty);
    });
  }

  test(
    'revoked identity fails before storage or process preparation',
    () async {
      processes.onIdentity = () async => throw _revoked();
      await expectLater(
        source().snapshotTaskChanges(),
        throwsA(_environmentRevoked()),
      );
      expect(processes.identityCalls, 1);
      expect(storage.calls, isEmpty);
      expect(processes.requests, isEmpty);
    },
  );

  for (final unstaged in [true, false]) {
    test(
      '${unstaged ? 'Unstaged' : 'Uncommitted'} skips identity and storage',
      () async {
        processes.onIdentity = () async =>
            throw StateError('Identity is forbidden.');
        storage.onSchema = () async =>
            throw StateError('Storage is forbidden.');
        final service = source();
        await expectLater(
          unstaged ? service.snapshotUnstaged() : service.snapshotUncommitted(),
          throwsA(same(_processSentinel)),
        );
        expect(processes.identityCalls, 0);
        expect(storage.calls, isEmpty);
        expect(processes.requests, hasLength(1));
      },
    );
  }

  for (final phase in ['identity', 'schema', 'query', 'process']) {
    test(
      'deadline includes held $phase and fences late continuation',
      () async {
        final gate = _Gate();
        addTearDown(gate.open);
        switch (phase) {
          case 'identity':
            processes.onIdentity = () async {
              await gate.hold();
              return _identity;
            };
          case 'schema':
            storage.onSchema = gate.hold;
          case 'query':
            storage.onQuery = () async {
              await gate.hold();
              return storage.rows;
            };
          case 'process':
            processes.run = (request) async {
              await gate.hold();
              return EnvironmentBufferedProcessResult(
                exitCode: 0,
                stdoutBase64: '',
                stderrBase64: '',
              );
            };
        }
        final operation = source(
          limits: const GitPortableUnstagedLimits(
            operationTimeout: Duration(milliseconds: 100),
          ),
        ).snapshotTaskChanges();
        final failed = expectLater(
          operation,
          throwsA(_code('operation_timeout')),
        );
        await gate.entered.future;
        await failed;
        expect(processes.requests, hasLength(phase == 'process' ? 1 : 0));
        final stoppedCalls = List<String>.of(storage.calls);
        gate.open();
        // Drain the released continuation, not a guessed wall-clock delay.
        await Future<void>(() {});
        expect(processes.requests, hasLength(phase == 'process' ? 1 : 0));
        expect(processes.identityCalls, 1);
        expect(storage.calls, stoppedCalls);
      },
    );
  }

  group('publication after real Git comparison', () {
    late Directory container;
    late Directory repository;
    late String head;

    setUp(() async {
      container = await Directory.systemTemp.createTemp('adele-persisted-git-');
      addTearDown(() => container.delete(recursive: true));
      repository = await Directory('${container.path}/repository').create();
      await _git(repository, ['init', '--initial-branch=main']);
      await _git(repository, ['config', 'user.name', 'ADELE Test']);
      await _git(repository, ['config', 'user.email', 'adele@example.invalid']);
      final tracked = File('${repository.path}/tracked');
      await tracked.writeAsString('baseline\n');
      await _git(repository, ['add', '--', 'tracked']);
      await _git(repository, ['commit', '-m', 'Baseline fixture']);
      final baseline = (await _git(repository, ['rev-parse', 'HEAD'])).trim();
      await tracked.writeAsString('committed\n');
      await _git(repository, ['commit', '-am', 'Changed fixture']);
      head = (await _git(repository, ['rev-parse', 'HEAD'])).trim();
      storage.rows = [_row(baseline: baseline)];
      processes.run = (request) => _run(repository, request);
    });

    test(
      'stable final record and identity publish the compared result',
      () async {
        final result = await source().snapshotTaskChanges();
        expect(result.committed.files.map((file) => file.relativePath), [
          'tracked',
        ]);
        expect(result.uncommitted.staged.files, isEmpty);
        expect(result.uncommitted.unstaged.files, isEmpty);
        expect(result.uncommitted.conflicts, isEmpty);
        expect(processes.requests, isNotEmpty);
        expect(processes.identityCalls, 2);
        expect(storage.calls, ['schema', 'query', 'schema', 'query']);
        expect(storage.sessions, everyElement(_identity.sessionId));
        expect(
          storage.parameters,
          everyElement({':session': _identity.sessionId}),
        );
      },
    );

    for (final phase in ['schema', 'query', 'identity']) {
      test('deadline fences held final $phase and its late response', () async {
        final exchanges =
            <
              ({
                EnvironmentBufferedProcessRequest request,
                EnvironmentBufferedProcessResult result,
              })
            >[];
        processes.run = (request) async {
          final result = await _run(repository, request);
          exchanges.add((request: request, result: result));
          return result;
        };
        final captured = await source().snapshotTaskChanges();
        expect(captured.committed.files.map((file) => file.relativePath), [
          'tracked',
        ]);
        expect(exchanges, isNotEmpty);

        // Capture under normal limits; the deadline below includes no OS startup.
        storage = _Storage(storage.rows);
        processes = _Processes();
        var replayed = 0;
        processes.run = (request) async {
          expect(replayed, lessThan(exchanges.length));
          final exchange = exchanges[replayed++];
          expect(request.program, exchange.request.program);
          expect(request.arguments, exchange.request.arguments);
          expect(
            request.relativeWorkingDirectory,
            exchange.request.relativeWorkingDirectory,
          );
          expect(request.stdinBase64, exchange.request.stdinBase64);
          // A reduced operation budget legitimately reduces the process timeout.
          expect(
            request.timeoutSeconds,
            inInclusiveRange(1, exchange.request.timeoutSeconds),
          );
          return exchange.result;
        };
        final gate = _Gate();
        addTearDown(gate.open);
        switch (phase) {
          case 'schema':
            storage.onSchema = () async {
              if (storage.calls.length == 3) await gate.hold();
            };
          case 'query':
            storage.onQuery = () async {
              if (storage.parameters.length == 2) await gate.hold();
              return storage.rows;
            };
          case 'identity':
            processes.onIdentity = () async {
              if (processes.identityCalls == 2) await gate.hold();
              return _identity;
            };
        }
        var published = false;
        final operation =
            source(
              limits: const GitPortableUnstagedLimits(
                operationTimeout: Duration(milliseconds: 250),
              ),
            ).snapshotTaskChanges().then((result) {
              published = true;
              return result;
            });
        final failed = expectLater(
          operation,
          throwsA(_code('operation_timeout')),
        );
        await Future.any<void>([gate.entered.future, failed]);
        expect(gate.entered.isCompleted, isTrue);
        expect(replayed, exchanges.length);
        expect(storage.calls, [
          'schema',
          'query',
          'schema',
          if (phase != 'schema') 'query',
        ]);
        expect(processes.identityCalls, phase == 'identity' ? 2 : 1);
        await failed;
        expect(published, isFalse);
        final stoppedCalls = List<String>.of(storage.calls);
        final stoppedIdentityCalls = processes.identityCalls;
        final stoppedProcessCalls = processes.requests.length;
        gate.open();
        await Future<void>(() {});
        expect(storage.calls, stoppedCalls);
        expect(processes.identityCalls, stoppedIdentityCalls);
        expect(processes.requests, hasLength(stoppedProcessCalls));
        expect(replayed, exchanges.length);
        expect(published, isFalse);
      });
    }

    for (final (change, code) in [
      ('commit', 'baseline_changed'),
      ('branch', 'baseline_changed'),
      ('removed anchor', 'baseline_unavailable'),
      ('changed association', 'baseline_association_mismatch'),
      ('storage failure', 'baseline_storage_failed'),
    ]) {
      test('final $change prevents successful publication', () async {
        final gate = _Gate();
        addTearDown(gate.open);
        storage.onQuery = () async {
          if (storage.parameters.length == 2) {
            await gate.hold();
            if (change == 'storage failure') {
              throw StateError('Storage closed.');
            }
          }
          return storage.rows;
        };
        final operation = source().snapshotTaskChanges();
        final failed = expectLater(operation, throwsA(_code(code)));
        await gate.entered.future;
        final commandCount = processes.requests.length;
        expect(commandCount, greaterThan(0));
        expect(processes.identityCalls, 1);
        storage.rows = [
          RelationalRow(
            values: {
              ...storage.rows.single.values,
              ...switch (change) {
                'commit' => {'baseline_commit': head},
                'branch' => {'expected_branch_ref': 'refs/heads/other'},
                'removed anchor' => {'anchor_environment_id': null},
                'changed association' => {
                  'selected_environment_id': 'primary-environment',
                },
                _ => <String, Object?>{},
              },
            },
          ),
        ];
        gate.open();
        await failed;
        expect(processes.requests, hasLength(commandCount));
        expect(processes.identityCalls, 1);
        expect(storage.calls, ['schema', 'query', 'schema', 'query']);
      });
    }

    for (final change in ['Session', 'Environment', 'revocation']) {
      test('final identity $change prevents successful publication', () async {
        final gate = _Gate();
        addTearDown(gate.open);
        processes.onIdentity = () async {
          if (processes.identityCalls == 1) return _identity;
          await gate.hold();
          if (change == 'revocation') throw _revoked();
          return AuthorizedEnvironmentIdentity(
            sessionId: change == 'Session'
                ? 'another-session'
                : _identity.sessionId,
            environmentId: change == 'Environment'
                ? 'primary-environment'
                : _identity.environmentId,
          );
        };
        final operation = source().snapshotTaskChanges();
        final failed = expectLater(
          operation,
          throwsA(
            change == 'revocation'
                ? _environmentRevoked()
                : _code('baseline_association_mismatch'),
          ),
        );
        await gate.entered.future;
        final commandCount = processes.requests.length;
        expect(commandCount, greaterThan(0));
        expect(storage.calls, ['schema', 'query', 'schema', 'query']);
        gate.open();
        await failed;
        expect(processes.requests, hasLength(commandCount));
        expect(processes.identityCalls, 2);
      });
    }
  });
}

TypeMatcher<ChangeSetFailure> _code(String code) =>
    isA<ChangeSetFailure>().having((failure) => failure.code, 'code', code);

TypeMatcher<ChangeSetFailure> _environmentRevoked() =>
    _code('environment_process_failed').having(
      (failure) => failure.details,
      'details',
      {'environmentCode': 'grant_revoked'},
    );

EnvironmentFailure _revoked() => const EnvironmentFailure(
  code: 'grant_revoked',
  message: 'Captured grant is no longer live.',
  details: {},
);

RelationalRow _row({
  String baseline = _baseline,
  Map<String, Object?> overrides = const {},
}) => RelationalRow(
  values: {
    'session_id': _identity.sessionId,
    'session_task_id': 'task',
    'selected_environment_id': _identity.environmentId,
    'environment_id': _identity.environmentId,
    'environment_task_id': 'task',
    'anchor_environment_id': _identity.environmentId,
    'baseline_commit': baseline,
    'expected_branch_ref': 'refs/heads/main',
    ...overrides,
  },
);

final class _Gate {
  final entered = Completer<void>();
  final _release = Completer<void>();

  Future<void> hold() {
    entered.complete();
    return _release.future;
  }

  void open() {
    if (!_release.isCompleted) _release.complete();
  }
}

// This controls adapter boundaries only; real SQL persistence is tested in app.
final class _Storage implements ProjectStorageService {
  _Storage(this.rows);

  List<RelationalRow> rows;
  final calls = <String>[];
  final sessions = <String>[];
  final parameters = <Map<String, Object?>>[];
  Future<void> Function()? onSchema;
  Future<List<RelationalRow>> Function()? onQuery;

  @override
  Future<void> ensureSchemaForSession(
    String sessionId,
    List<String> migrations,
    ProjectStorageAccessMode accessMode,
  ) async {
    calls.add('schema');
    sessions.add(sessionId);
    expect(migrations, hasLength(1));
    expect(migrations.single, contains('CREATE TABLE adele_git_task_anchors'));
    expect(accessMode, ProjectStorageAccessMode.durableOrTemporary);
    await onSchema?.call();
  }

  @override
  Future<List<RelationalRow>> queryForSession(
    String sessionId,
    String sql,
    Map<String, Object?> parameters,
    ProjectStorageAccessMode accessMode,
  ) async {
    calls.add('query');
    sessions.add(sessionId);
    this.parameters.add(Map.of(parameters));
    expect(sql, contains('LEFT JOIN adele_git_task_anchors'));
    expect(accessMode, ProjectStorageAccessMode.durableOrTemporary);
    return onQuery == null ? rows : await onQuery!();
  }

  @override
  Future<bool> isDurableSession(String sessionId) async {
    calls.add('durability');
    throw StateError('Snapshot must not probe durability.');
  }

  @override
  Future<void> transactionForSession(
    String sessionId,
    List<RelationalStatement> statements,
    ProjectStorageAccessMode accessMode,
  ) async {
    calls.add('transaction');
    throw StateError('Snapshot must not enroll or replace an anchor.');
  }
}

final class _Processes implements AuthorizedEnvironmentBufferedProcessService {
  int identityCalls = 0;
  final requests = <EnvironmentBufferedProcessRequest>[];
  Future<AuthorizedEnvironmentIdentity> Function()? onIdentity;
  Future<EnvironmentBufferedProcessResult> Function(
    EnvironmentBufferedProcessRequest,
  )?
  run;

  @override
  Future<AuthorizedEnvironmentIdentity> capturedIdentity() async {
    identityCalls++;
    return onIdentity == null ? _identity : await onIdentity!();
  }

  @override
  Future<EnvironmentBufferedProcessResult> runBufferedProcess(
    EnvironmentBufferedProcessRequest request,
  ) async {
    requests.add(request);
    if (run == null) throw _processSentinel;
    return run!(request);
  }
}

// Independent of the Worktree provider, host storage and process supervisor.
Future<EnvironmentBufferedProcessResult> _run(
  Directory repository,
  EnvironmentBufferedProcessRequest request,
) async {
  expect(request.relativeWorkingDirectory, isEmpty);
  final process = await Process.start(
    request.program,
    request.arguments,
    workingDirectory: repository.path,
    environment: _environment(repository),
    includeParentEnvironment: false,
  );
  try {
    final completed = await Future.wait<Object?>([
      _capture(process.stdout, environmentBufferedProcessStdoutLimit),
      _capture(process.stderr, environmentBufferedProcessStderrLimit),
      process.exitCode,
      () async {
        process.stdin.add(
          decodeEnvironmentProcessBytes(
            request.stdinBase64,
            maximumBytes: environmentBufferedProcessStdinLimit,
          ),
        );
        await process.stdin.close();
      }(),
    ], eagerError: true).timeout(Duration(seconds: request.timeoutSeconds));
    return EnvironmentBufferedProcessResult(
      exitCode: completed[2]! as int,
      stdoutBase64: base64Encode(completed[0]! as List<int>),
      stderrBase64: base64Encode(completed[1]! as List<int>),
    );
  } finally {
    process.kill(ProcessSignal.sigkill);
    await process.exitCode;
  }
}

Future<List<int>> _capture(Stream<List<int>> stream, int limit) async {
  final bytes = BytesBuilder(copy: false);
  await for (final chunk in stream) {
    if (bytes.length + chunk.length > limit) {
      throw StateError('Fixture output exceeded the transport bound.');
    }
    bytes.add(chunk);
  }
  return bytes.takeBytes();
}

Map<String, String> _environment(Directory repository) => {
  'PATH': '/usr/bin:/bin',
  'HOME': repository.parent.path,
  'XDG_CONFIG_HOME': '${repository.parent.path}/config',
  'GIT_CONFIG_NOSYSTEM': '1',
  'GIT_CONFIG_GLOBAL': '/dev/null',
  'GIT_TERMINAL_PROMPT': '0',
  'LC_ALL': 'C',
};

Future<String> _git(Directory repository, List<String> arguments) async {
  final result = await Process.run(
    '/usr/bin/git',
    arguments,
    workingDirectory: repository.path,
    environment: _environment(repository),
    includeParentEnvironment: false,
  );
  expect(result.exitCode, 0, reason: 'git $arguments: ${result.stderr}');
  return result.stdout as String;
}
