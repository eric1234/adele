import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:adele_environment/adele_environment.dart';
import 'package:crypto/crypto.dart';
import 'package:diff_viewer_contract/diff_viewer_contract.dart';
import 'package:git_backend/git_backend.dart'
    show
        GitPortableReviewApprovalService,
        GitPortableUnstagedLimits,
        GitPortableUnstagedSnapshotService;
import 'package:test/test.dart';

String reviewVerb(bool staged) => staged ? 'unapprove' : 'approve';

ReviewLayerSelection selectLayerFrom(ChangeSetSnapshot layer) {
  expect(
    layer.layerReviewRevision,
    isNotNull,
    reason: 'the entire layer must be actionable',
  );
  return ReviewLayerSelection(expectedRevision: layer.layerReviewRevision!);
}

ReviewLayerSelection untrustedLayerSelection() => ReviewLayerSelection(
  expectedRevision: 'display-only-layer-has-no-review-revision',
);

ReviewFileSelection selectFileFrom(ChangedFile file) {
  expect(
    file.fileReviewRevision,
    isNotNull,
    reason: '${file.relativePath} must be file-actionable',
  );
  return ReviewFileSelection(
    relativePath: file.relativePath,
    expectedRevision: file.fileReviewRevision!,
  );
}

ReviewFileSelection untrustedFileSelection(String path) => ReviewFileSelection(
  relativePath: path,
  expectedRevision: 'display-only-entry-has-no-file-review-revision',
);

String lines([Map<int, String> replacements = const {}]) =>
    '${List.generate(40, (index) => replacements[index] ?? 'line $index').join('\n')}\n';

Matcher hasErrorCode(List<String> codes) => isA<ReviewApprovalFailure>().having(
  (error) => error.code,
  'code',
  isIn(codes),
);

bool isWrite(EnvironmentBufferedProcessRequest request) =>
    request.arguments.contains('apply') &&
    request.arguments.contains('--cached') &&
    !request.arguments.contains('--check');

String checkedApplyPatch(TestRepo fixture, {required bool staged}) {
  final applies = fixture.processes.requests
      .where((request) => request.arguments.contains('apply'))
      .toList();
  expect(applies, hasLength(2));
  expect(applies.first.arguments, contains('--check'));
  expect(applies.last.arguments, isNot(contains('--check')));
  for (final request in applies) {
    expect(request.arguments, contains('--cached'));
    expect(request.arguments.contains('--reverse'), staged);
  }
  expect(applies.first.stdinBase64, applies.last.stdinBase64);
  expect(fixture.processes.writes, hasLength(1));
  expect(
    fixture.processes.requests.any(
      (request) => request.arguments.any(
        ['add', 'rm', 'reset', 'checkout', 'update-index'].contains,
      ),
    ),
    isFalse,
  );
  return utf8.decode(base64Decode(applies.last.stdinBase64));
}

final class TestRepo {
  TestRepo(this.container, this.repository, this.processes, this.format);

  final Directory container;
  final Directory repository;
  final ProcessSpy processes;
  final String format;

  static Future<TestRepo> create({String format = 'sha1'}) async {
    final container = await Directory.systemTemp.createTemp(
      'adele-review-approval-',
    );
    final repository = await Directory('${container.path}/repository').create();
    final fixture = TestRepo(
      container,
      repository,
      ProcessSpy(repository, container),
      format,
    );
    await fixture.git([
      'init',
      '--initial-branch=main',
      '--object-format=$format',
    ]);
    await fixture.git(['config', 'user.name', 'ADELE Test']);
    await fixture.git(['config', 'user.email', 'adele@example.invalid']);
    await fixture.git(['config', 'core.autocrlf', 'false']);
    await fixture.write('tracked.txt', lines());
    await fixture.write('other.txt', 'other original\n');
    await fixture.commit();
    return fixture;
  }

  GitPortableUnstagedSnapshotService get snapshots =>
      snapshotsWith(const GitPortableUnstagedLimits());

  GitPortableUnstagedSnapshotService snapshotsWith(
    GitPortableUnstagedLimits limits,
  ) => GitPortableUnstagedSnapshotService(processes: processes, limits: limits);

  Future<ChangeSetSnapshot> layer({bool staged = false}) async => staged
      ? (await snapshots.snapshotUncommitted()).staged
      : await snapshots.snapshotUnstaged();

  Future<ChangedFile> changed({
    String path = 'tracked.txt',
    bool staged = false,
  }) async => (await layer(
    staged: staged,
  )).files.singleWhere((file) => file.relativePath == path);

  Future<void> mutate(
    ReviewHunkSelection selection, {
    bool staged = false,
    GitPortableUnstagedLimits limits = const GitPortableUnstagedLimits(),
  }) {
    final service = GitPortableReviewApprovalService(
      processes: processes,
      limits: limits,
    );
    return staged
        ? service.unapproveHunk(selection)
        : service.approveHunk(selection);
  }

  Future<void> mutateFile(
    ReviewFileSelection selection, {
    bool staged = false,
    GitPortableUnstagedLimits limits = const GitPortableUnstagedLimits(),
  }) {
    final service = GitPortableReviewApprovalService(
      processes: processes,
      limits: limits,
    );
    return staged
        ? service.unapproveFile(selection)
        : service.approveFile(selection);
  }

  Future<void> mutateLayer(
    ReviewLayerSelection selection, {
    bool staged = false,
    GitPortableUnstagedLimits limits = const GitPortableUnstagedLimits(),
  }) {
    final service = GitPortableReviewApprovalService(
      processes: processes,
      limits: limits,
    );
    return staged
        ? service.unapproveAllStaged(selection)
        : service.approveAllUnstaged(selection);
  }

  Future<({Map<String, String?> head, Map<String, String?> working})>
  layerChanges({bool staged = false, bool mixed = false, int count = 2}) async {
    final paths = [
      'tracked.txt',
      'other.txt',
      for (var i = 2; i < count; i++) 'file-$i.txt',
    ];
    final head = <String, String?>{
      for (var i = 0; i < paths.length; i++) paths[i]: lines({2: 'HEAD $i'}),
      if (mixed) ...{
        'deleted.txt': 'HEAD deleted\n',
        'empty-deleted.txt': '',
        'new.txt': null,
        'empty-new.txt': null,
      },
    };
    final working = <String, String?>{
      for (var i = 0; i < paths.length; i++)
        paths[i]: lines({2: 'working $i', 35: 'last $i'}),
      if (mixed) ...{
        'deleted.txt': null,
        'empty-deleted.txt': null,
        'new.txt': 'new text\n',
        'empty-new.txt': '',
      },
    };
    for (final entry in head.entries) {
      if (entry.value != null) await write(entry.key, entry.value!);
    }
    await commit();
    for (final entry in working.entries) {
      if (entry.value == null) {
        await File('${repository.path}/${entry.key}').delete();
      } else {
        await write(entry.key, entry.value!);
      }
    }
    if (staged) await git(['add', '--all']);
    return (head: head, working: working);
  }

  Future<void> write(String path, String text) async {
    final file = File('${repository.path}/$path');
    await file.parent.create(recursive: true);
    await file.writeAsString(text);
  }

  Future<void> deleteTracked({
    String path = 'tracked.txt',
    String original = 'HEAD A\n',
    String? indexed,
    String mode = '100644',
    bool staged = false,
  }) async {
    await write(path, original);
    await runLocal('/usr/bin/chmod', [
      mode == '100755' ? '755' : '644',
      '${repository.path}/$path',
    ]);
    await commit();
    if (indexed != null && indexed != original) {
      await write(path, indexed);
      await git(['--literal-pathspecs', 'add', '--', path]);
    }
    await File('${repository.path}/$path').delete();
    if (staged) {
      await git([
        '--literal-pathspecs',
        'update-index',
        '--force-remove',
        '--',
        path,
      ]);
    }
  }

  Future<String> git(List<String> arguments, {String input = ''}) async =>
      utf8.decode(await gitBytes(arguments, input: input));

  Future<List<int>> gitBytes(
    List<String> arguments, {
    String input = '',
  }) async {
    final process = await Process.start(
      '/usr/bin/git',
      arguments,
      workingDirectory: repository.path,
      environment: {
        'PATH': '/usr/bin:/bin',
        'HOME': container.path,
        'GIT_CONFIG_NOSYSTEM': '1',
        'GIT_CONFIG_GLOBAL': '/dev/null',
        'GIT_TERMINAL_PROMPT': '0',
        'GIT_OPTIONAL_LOCKS': '0',
        'LC_ALL': 'C',
      },
      includeParentEnvironment: false,
      runInShell: false,
    );
    try {
      final result = await Future.wait<Object?>([
        _capture(process.stdout),
        _capture(process.stderr),
        process.exitCode,
        () async {
          process.stdin.add(utf8.encode(input));
          await process.stdin.close();
        }(),
      ], eagerError: true).timeout(const Duration(seconds: 10));
      expect(
        result[2],
        0,
        reason: 'git $arguments: ${utf8.decode(result[1]! as List<int>)}',
      );
      return result[0]! as List<int>;
    } finally {
      process.kill(ProcessSignal.sigkill);
      await process.exitCode;
    }
  }

  Future<void> commit() async {
    await git(['add', '--all']);
    await git(['commit', '-m', 'Fixture']);
  }

  Future<void> makeConflict({String path = 'tracked.txt'}) async {
    final oid = (await git(['rev-parse', 'HEAD:$path'])).trim();
    await git(
      ['update-index', '--index-info'],
      input:
          '0 ${'0' * oid.length}\t$path\n'
          '100644 $oid 1\t$path\n'
          '100644 $oid 2\t$path\n'
          '100644 $oid 3\t$path\n',
    );
  }

  Future<ReviewState> state() async {
    final indexBytes = await File(
      '${repository.path}/.git/index',
    ).readAsBytes();
    // Evidence collection must not execute the hostile helper under test.
    final listing = await git([
      '-c',
      'core.fsmonitor=false',
      'ls-files',
      '--stage',
      '-z',
    ]);
    final oids = <String, String>{};
    final blobs = <String, List<int>>{};
    for (final record
        in listing.split('\x00').where((record) => record.isNotEmpty)) {
      final match = RegExp(
        r'^([0-9]{6}) ([0-9a-f]+) ([0-3])\t(.*)$',
        dotAll: true,
      ).firstMatch(record)!;
      final key = '${match[3]}:${match[4]}';
      oids[key] = match[2]!;
      blobs[key] = await gitBytes([
        'cat-file',
        match[1] == '160000' ? 'commit' : 'blob',
        match[2]!,
      ]);
    }
    final working = <String, Object>{};
    await for (final entity in repository.list(
      recursive: true,
      followLinks: false,
    )) {
      final path = entity.path.substring(repository.path.length + 1);
      if (path == '.git' || path.startsWith('.git/')) continue;
      if (entity is File) {
        final stat = await entity.stat();
        working[path] = (
          sha256.convert(await entity.readAsBytes()).toString(),
          stat.size,
          stat.mode,
        );
      } else if (entity is Link) {
        working[path] = ('link', await entity.target());
      } else {
        working[path] = 'directory';
      }
    }
    return ReviewState(
      indexBytes,
      listing,
      oids,
      blobs,
      working,
      await git(['rev-parse', 'HEAD']),
      await File('${repository.path}/.git/HEAD').readAsString(),
    );
  }

  Future<void> expectUnchanged(ReviewState before) async {
    final after = await state();
    _expectWorkingAndHead(before, after);
    expect(
      after.indexBytes,
      before.indexBytes,
      reason: 'exact index file bytes',
    );
    expect(
      after.listing,
      before.listing,
      reason: 'all index modes, stages and OIDs',
    );
    expect(after.oids, before.oids);
    expect(after.blobs, before.blobs, reason: 'exact index blob bytes');
  }

  Future<ReviewState> expectIndexChange(
    ReviewState before,
    String path,
    String text,
  ) async {
    final after = await state();
    _expectWorkingAndHead(before, after);
    final bytes = utf8.encode(text);
    final expectedOid = (format == 'sha256' ? sha256 : sha1).convert([
      ...utf8.encode('blob ${bytes.length}\x00'),
      ...bytes,
    ]).toString();
    expect(after.indexBytes, isNot(equals(before.indexBytes)));
    expect(
      after.listing,
      before.listing.replaceFirst(
        '${before.oids['0:$path']} 0\t$path\x00',
        '$expectedOid 0\t$path\x00',
      ),
      reason:
          'only the selected index blob may change, not its mode or other entries',
    );
    expect(after.oids, {...before.oids, '0:$path': expectedOid});
    expect(after.blobs, {...before.blobs, '0:$path': bytes});
    return after;
  }

  Future<ReviewState> expectIndexPresence(
    ReviewState before,
    String path,
    String? text, {
    String mode = '100644',
  }) => expectIndexChanges(before, {path: text}, mode: mode);

  Future<ReviewState> expectIndexChanges(
    ReviewState before,
    Map<String, String?> changes, {
    String mode = '100644',
  }) async {
    final after = await state();
    _expectWorkingAndHead(before, after);
    final records = before.listing.split('\x00')
      ..removeWhere(
        (record) =>
            record.isEmpty ||
            changes.keys.any((path) => record.endsWith('\t$path')),
      );
    final oids = {...before.oids};
    final blobs = {...before.blobs};
    for (final entry in changes.entries) {
      final path = entry.key;
      oids.remove('0:$path');
      blobs.remove('0:$path');
      if (entry.value == null) continue;
      final bytes = utf8.encode(entry.value!);
      final oid = (format == 'sha256' ? sha256 : sha1).convert([
        ...utf8.encode('blob ${bytes.length}\x00'),
        ...bytes,
      ]).toString();
      records.add('$mode $oid 0\t$path');
      oids['0:$path'] = oid;
      blobs['0:$path'] = bytes;
    }
    expect(after.indexBytes, isNot(equals(before.indexBytes)));
    expect(
      after.listing.split('\x00').where((record) => record.isNotEmpty),
      unorderedEquals(records),
      reason: 'only selected stage-0 entries may change membership or content',
    );
    expect(after.oids, oids);
    expect(after.blobs, blobs, reason: 'all exact index blob bytes');
    return after;
  }

  Future<void> close() async {
    await processes.close();
    await container.delete(recursive: true);
  }
}

void _expectWorkingAndHead(ReviewState before, ReviewState after) {
  expect(
    after.working,
    before.working,
    reason: 'all working SHA256, sizes and modes are unchanged',
  );
  expect(after.head, before.head, reason: 'HEAD commit is unchanged');
  expect(
    after.reference,
    before.reference,
    reason: 'HEAD reference is unchanged',
  );
}

final class ReviewState {
  const ReviewState(
    this.indexBytes,
    this.listing,
    this.oids,
    this.blobs,
    this.working,
    this.head,
    this.reference,
  );

  final List<int> indexBytes;
  final String listing;
  final Map<String, String> oids;
  final Map<String, List<int>> blobs;
  final Map<String, Object> working;
  final String head;
  final String reference;
}

typedef ProcessRun =
    Future<EnvironmentBufferedProcessResult> Function(
      EnvironmentBufferedProcessRequest,
    );
typedef ProcessIntercept =
    Future<EnvironmentBufferedProcessResult> Function(
      EnvironmentBufferedProcessRequest,
      ProcessRun,
    );

// Independent of the stock Worktree provider: all production I/O crosses this grant.
final class ProcessSpy implements AuthorizedEnvironmentBufferedProcessService {
  ProcessSpy(this.root, this.home);

  Directory root;
  final Directory home;
  String sessionId = 'review-session';
  String environmentId = 'selected-review-environment';
  int identityCalls = 0;
  final requests = <EnvironmentBufferedProcessRequest>[];
  final _active = <Process>{};
  ProcessIntercept? intercept;

  Iterable<EnvironmentBufferedProcessRequest> get writes =>
      requests.where(isWrite);

  @override
  Future<AuthorizedEnvironmentIdentity> capturedIdentity() async {
    identityCalls++;
    return AuthorizedEnvironmentIdentity(
      sessionId: sessionId,
      environmentId: environmentId,
    );
  }

  @override
  Future<EnvironmentBufferedProcessResult> runBufferedProcess(
    EnvironmentBufferedProcessRequest request,
  ) {
    requests.add(request);
    expect(request.program, '/bin/sh');
    expect(request.relativeWorkingDirectory, isEmpty);
    expect(request.timeoutSeconds, inInclusiveRange(1, 10));
    return intercept?.call(request, _run) ?? _run(request);
  }

  Future<EnvironmentBufferedProcessResult> _run(
    EnvironmentBufferedProcessRequest request,
  ) async {
    final process = await Process.start(
      request.program,
      request.arguments,
      workingDirectory: root.path,
      environment: {
        'PATH': '/usr/bin:/bin',
        'HOME': home.path,
        'XDG_CONFIG_HOME': '${home.path}/config',
        'LC_ALL': 'C',
      },
      includeParentEnvironment: false,
      runInShell: false,
    );
    _active.add(process);
    try {
      final result = await Future.wait<Object?>([
        _capture(process.stdout, limit: environmentBufferedProcessStdoutLimit),
        _capture(process.stderr, limit: environmentBufferedProcessStderrLimit),
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
        exitCode: result[2]! as int,
        stdoutBase64: base64Encode(result[0]! as List<int>),
        stderrBase64: base64Encode(result[1]! as List<int>),
      );
    } on TimeoutException {
      throw const EnvironmentFailure(
        code: 'process_timeout',
        message: 'Fixture deadline expired.',
        details: {},
      );
    } finally {
      process.kill(ProcessSignal.sigkill);
      await process.exitCode;
      _active.remove(process);
    }
  }

  Future<void> close() async {
    for (final process in _active.toList()) {
      process.kill(ProcessSignal.sigkill);
      await process.exitCode;
    }
  }
}

Future<List<int>> _capture(
  Stream<List<int>> stream, {
  int limit = 2 * 1024 * 1024,
}) async {
  final bytes = BytesBuilder(copy: false);
  await for (final chunk in stream) {
    if (bytes.length + chunk.length > limit) {
      throw const EnvironmentFailure(
        code: 'process_output_overflow',
        message: 'Fixture output bound exceeded.',
        details: {},
      );
    }
    bytes.add(chunk);
  }
  return bytes.takeBytes();
}

Future<void> runLocal(String program, List<String> arguments) async {
  final result = await Process.run(program, arguments);
  expect(result.exitCode, 0, reason: '$program $arguments: ${result.stderr}');
}
