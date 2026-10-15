import 'dart:convert';
import 'dart:io';

import 'package:adele_contract/adele_contract.dart';
import 'package:contract_codegen/contract_codegen.dart';
import 'package:dart_eval/dart_eval.dart';
import 'package:dart_eval/dart_eval_bridge.dart';
import 'package:dart_eval/src/eval/runtime/class.dart' show $InstanceImpl;
import 'package:diff_viewer_contract/diff_viewer_contract.dart';
import 'package:test/test.dart';

void main() {
  late _Service service;
  late ChangeSetSourceServiceDispatcher dispatcher;
  late _Channel channel;
  late ChangeSetSourceServiceClient client;
  setUp(() {
    service = _Service();
    dispatcher = ChangeSetSourceServiceDispatcher(service);
    channel = _Channel(dispatcher);
    client = ChangeSetSourceServiceClient(channel);
  });
  tearDown(() => dispatcher.close());

  test(
    'review contract roundtrips exact selections and declared failures',
    () async {
      final service = _ReviewService();
      final dispatcher = ReviewApprovalServiceDispatcher(service);
      addTearDown(dispatcher.close);
      final channel = _Channel(dispatcher);
      final client = ReviewApprovalServiceClient(channel);
      expect(reviewApprovalCapability.id.value, 'adele.diff.review-approval');
      expect(reviewApprovalCapability.majorVersion, 1);
      expect(reviewApprovalServiceId, 'diff.reviewApproval');
      for (final status in ['applied', 'stale', 'ineligible']) {
        service.status = status;
        for (final selection in _reviewSelections) {
          for (final approve in [true, false]) {
            final result = await (approve ? client.approve : client.unapprove)(
              selection,
            );
            expect(result.status, status);
            expect(
              channel.method,
              'diff.reviewApproval.${approve ? 'approve' : 'unapprove'}',
            );
            expect(channel.payload, {
              'selection': {
                'expectedRevision': selection.expectedRevision,
                'granularity': selection.granularity,
                'relativePath': selection.relativePath,
                'hunkIndex': selection.hunkIndex,
              },
            });
            expect(
              service.selection!.expectedRevision,
              selection.expectedRevision,
            );
            expect(service.selection!.granularity, selection.granularity);
            expect(service.selection!.relativePath, selection.relativePath);
            expect(service.selection!.hunkIndex, selection.hunkIndex);
          }
        }
      }
      service.failure = const ReviewApprovalFailure(
        code: 'busy',
        message: 'Review is busy.',
      );
      for (final invoke in [client.approve, client.unapprove]) {
        await expectLater(
          invoke(_reviewSelections.first),
          throwsA(
            isA<ReviewApprovalFailure>()
                .having((failure) => failure.code, 'code', 'busy')
                .having((failure) => failure.details, 'details', isEmpty),
          ),
        );
      }
    },
  );

  test(
    'review dispatch rejects malformed selections before service admission',
    () async {
      final service = _ReviewService();
      final dispatcher = ReviewApprovalServiceDispatcher(service);
      addTearDown(dispatcher.close);
      for (final method in [
        reviewApprovalServiceApproveId,
        reviewApprovalServiceUnapproveId,
      ]) {
        for (final payload in <Object?>[
          null,
          <String, Object?>{},
          {'selection': _selectionWire, 'hostInvocationContext': 'forged'},
          for (final selection in _invalidSelectionWires)
            {'selection': selection},
        ]) {
          final response = await dispatcher.dispatch({
            'kind': 'request',
            'requestId': 1,
            'method': method,
            'payload': payload,
          });
          expect(response['ok'], isFalse, reason: '$payload');
          expect((response['error']! as Map)['code'], 'invalid_request');
        }
      }
      expect(service.selection, isNull);
    },
  );

  test(
    'native review result decoder rejects incomplete and incorrect fields',
    () async {
      for (final wire in _invalidResultWires) {
        final client = ReviewApprovalServiceClient(_Response(wire));
        for (final invoke in [client.approve, client.unapprove]) {
          await expectLater(
            invoke(_reviewSelections.first),
            throwsA(isA<AdeleProtocolException>()),
          );
        }
      }
    },
  );

  test(
    'native snapshot review fields are required and strictly typed',
    () async {
      await client.snapshotUnstaged();
      final snapshot = channel.response! as Map<String, dynamic>;
      final file = (snapshot['files'] as List).single as Map<String, dynamic>;
      for (final wire in <Object?>[
        {...snapshot}..remove('reviewRevision'),
        for (final value in <Object?>[true, 1, [], {}])
          {...snapshot, 'reviewRevision': value},
        for (final invalidFile in [
          {...file}..remove('reviewEligible'),
          for (final value in <Object?>[null, 'true', 1, [], {}])
            {...file, 'reviewEligible': value},
        ])
          {
            ...snapshot,
            'files': [invalidFile],
          },
      ]) {
        await expectLater(
          ChangeSetSourceServiceClient(_Response(wire)).snapshotUnstaged(),
          throwsA(isA<AdeleProtocolException>()),
        );
      }
    },
  );

  test(
    'real eval codecs strictly decode review DTOs and snapshot opt-ins',
    () async {
      final generated = await const ContractGenerator().generateEvalClient(
        File('lib/diff_viewer_contract.dart'),
      );
      await client.snapshotUnstaged();
      final snapshot = channel.response! as Map<String, dynamic>;
      final file = (snapshot['files'] as List).single as Map<String, dynamic>;
      final cases = <(String, Object?, bool)>[
        ('ReviewSelection', _selectionWire, true),
        (
          'ReviewSelection',
          {
            ..._selectionWire,
            'granularity': 'layer',
            'relativePath': null,
            'hunkIndex': null,
          },
          true,
        ),
        for (final wire in _invalidSelectionWires)
          ('ReviewSelection', wire, false),
        for (final status in ['applied', 'stale', 'ineligible'])
          ('ReviewApprovalResult', {'status': status}, true),
        for (final wire in _invalidResultWires)
          ('ReviewApprovalResult', wire, false),
        ('ChangeSetSnapshot', snapshot, true),
        ('ChangeSetSnapshot', {...snapshot, 'reviewRevision': null}, true),
        ('ChangeSetSnapshot', {...snapshot}..remove('reviewRevision'), false),
        ('ChangeSetSnapshot', {...snapshot, 'reviewRevision': false}, false),
        ('ChangedFile', file, true),
        ('ChangedFile', {...file, 'reviewEligible': false}, true),
        ('ChangedFile', {...file}..remove('reviewEligible'), false),
        ('ChangedFile', {...file, 'reviewEligible': null}, false),
        ('ChangedFile', {...file, 'reviewEligible': 'true'}, false),
      ];
      // Exercise the actual emitted decoders synchronously, including parameter
      // DTOs that a client normally only encodes. No native semantic adapter.
      final probes = StringBuffer();
      for (var i = 0; i < cases.length; i++) {
        final (type, wire, _) = cases[i];
        final decoder = RegExp(
          '$type (_wire[0-9]+Decode)\\(',
        ).firstMatch(generated)!.group(1)!;
        probes.writeln(
          'String probe$i() { try { $decoder(jsonDecode(${jsonEncode(jsonEncode(wire))})); return "accepted"; } catch (error) { return "rejected"; } }',
        );
      }
      const library = 'package:diff_viewer_contract/diff_viewer_contract.dart';
      final program =
          (Compiler()
                ..entrypoints.addAll([
                  'package:adele_contract/adele_contract.dart',
                  library,
                ]))
              .compile({
                'adele_contract': {
                  'adele_contract.dart': evalContractSupportSource,
                },
                'diff_viewer_contract': {
                  'diff_viewer_contract.dart':
                      "import 'dart:convert';\n$generated\n$probes",
                },
              });
      final bytes = program.write().buffer.asByteData();
      for (var i = 0; i < cases.length; i++) {
        final result = Runtime(bytes).executeLib(library, 'probe$i') as $Value;
        expect(
          result.$reified,
          cases[i].$3 ? 'accepted' : 'rejected',
          reason: '${cases[i]}',
        );
      }
    },
  );

  test('generated transport roundtrips the complete nested snapshot', () async {
    final snapshot = await client.snapshotUnstaged();
    expect(snapshot.reviewRevision, 'revision');
    expect(changeSetSourceCapability.id.value, 'adele.diff.change-set-source');
    expect(changeSetSourceCapability.majorVersion, 1);
    expect(channel.method, 'diff.changeSetSource.snapshotUnstaged');
    expect(channel.payload, isEmpty);
    final file = snapshot.files.single;
    expect(file.relativePath, 'dir/two words\t\u03bb.txt');
    expect(file.changeKind, 'modified');
    expect(file.contentStatus, 'text');
    expect(file.detail, isNull);
    expect(file.reviewEligible, isTrue);
    final hunk = file.hunks.single;
    expect(
      [hunk.oldStart, hunk.oldCount, hunk.newStart, hunk.newCount],
      [2, 2, 2, 2],
    );
    expect(hunk.lines.map((line) => (line.kind, line.text, line.noNewline)), [
      ('context', 'same', false),
      ('deletion', 'before', true),
      ('addition', 'after\u{1f600}', true),
    ]);
    expect(() => snapshot.files.clear(), throwsUnsupportedError);
    expect(() => file.hunks.clear(), throwsUnsupportedError);
    expect(() => hunk.lines.clear(), throwsUnsupportedError);
  });

  test('all list constructors detach immutable snapshots from callers', () {
    final lines = <DiffLine>[
      const DiffLine(kind: 'addition', text: 'new', noNewline: false),
    ];
    final hunk = DiffHunk(
      oldStart: 0,
      oldCount: 0,
      newStart: 1,
      newCount: 1,
      lines: lines,
    );
    final hunks = [hunk];
    final file = ChangedFile(
      relativePath: 'new.txt',
      changeKind: 'added',
      contentStatus: 'text',
      detail: null,
      reviewEligible: false,
      hunks: hunks,
    );
    final files = [file];
    final snapshot = ChangeSetSnapshot(files: files, reviewRevision: null);
    final conflicts = [file];
    final uncommitted = UncommittedChangeSetSnapshot(
      staged: snapshot,
      unstaged: ChangeSetSnapshot(files: files, reviewRevision: null),
      conflicts: conflicts,
    );
    final task = TaskChangeSetSnapshot(
      committed: ChangeSetSnapshot(files: files, reviewRevision: null),
      uncommitted: uncommitted,
    );
    lines.clear();
    hunks.clear();
    files.clear();
    conflicts.clear();
    expect(snapshot.files.single.hunks.single.lines.single.text, 'new');
    expect(() => snapshot.files.clear(), throwsUnsupportedError);
    expect(() => file.hunks.clear(), throwsUnsupportedError);
    expect(() => hunk.lines.clear(), throwsUnsupportedError);
    for (final layer in [
      task.committed,
      task.uncommitted.staged,
      task.uncommitted.unstaged,
    ]) {
      expect(layer.files.single.hunks.single.lines.single.text, 'new');
      expect(() => layer.files.clear(), throwsUnsupportedError);
      expect(() => layer.files.single.hunks.clear(), throwsUnsupportedError);
      expect(
        () => layer.files.single.hunks.single.lines.clear(),
        throwsUnsupportedError,
      );
    }
    expect(uncommitted.conflicts.single.relativePath, 'new.txt');
    expect(() => uncommitted.conflicts.clear(), throwsUnsupportedError);
    expect(
      () => uncommitted.conflicts.single.hunks.single.lines.clear(),
      throwsUnsupportedError,
    );
  });

  test(
    'generated uncommitted transport preserves both layers and conflicts',
    () async {
      final snapshot = await client.snapshotUncommitted();
      expect(channel.method, 'diff.changeSetSource.snapshotUncommitted');
      expect(channel.payload, isEmpty);
      expect(service.calls, 1);
      for (final layer in [snapshot.staged, snapshot.unstaged]) {
        final file = layer.files.single;
        expect(file.relativePath, 'dir/two words\t\u03bb.txt');
        expect(file.changeKind, 'modified');
        expect(file.contentStatus, 'text');
        expect(file.detail, isNull);
        final hunk = file.hunks.single;
        expect(
          [hunk.oldStart, hunk.oldCount, hunk.newStart, hunk.newCount],
          [2, 2, 2, 2],
        );
        expect(
          hunk.lines.map((line) => (line.kind, line.text, line.noNewline)),
          [
            ('context', 'same', false),
            ('deletion', 'before', true),
            ('addition', 'after\u{1f600}', true),
          ],
        );
        expect(() => layer.files.clear(), throwsUnsupportedError);
        expect(() => file.hunks.clear(), throwsUnsupportedError);
        expect(() => hunk.lines.clear(), throwsUnsupportedError);
      }
      expect(identical(snapshot.staged, snapshot.unstaged), isFalse);
      final conflict = snapshot.conflicts.single;
      expect(conflict.relativePath, 'conflict.txt');
      expect(conflict.changeKind, 'conflicted');
      expect(conflict.contentStatus, 'conflicted');
      expect(conflict.detail, 'Unmerged index entries.');
      expect(conflict.hunks, isEmpty);
      expect(() => snapshot.conflicts.clear(), throwsUnsupportedError);
      expect(() => conflict.hunks.clear(), throwsUnsupportedError);
    },
  );

  test(
    'generated Task transport composes all layers in one empty request',
    () async {
      final snapshot = await client.snapshotTaskChanges();
      expect(channel.method, 'diff.changeSetSource.snapshotTaskChanges');
      expect(channel.payload, isEmpty);
      expect(service.calls, 1);
      for (final layer in [
        snapshot.committed,
        snapshot.uncommitted.staged,
        snapshot.uncommitted.unstaged,
      ]) {
        final file = layer.files.single;
        expect(file.relativePath, 'dir/two words\t\u03bb.txt');
        expect(file.changeKind, 'modified');
        expect(file.contentStatus, 'text');
        expect(file.detail, isNull);
        final hunk = file.hunks.single;
        expect(
          [hunk.oldStart, hunk.oldCount, hunk.newStart, hunk.newCount],
          [2, 2, 2, 2],
        );
        expect(
          hunk.lines.map((line) => (line.kind, line.text, line.noNewline)),
          [
            ('context', 'same', false),
            ('deletion', 'before', true),
            ('addition', 'after\u{1f600}', true),
          ],
        );
        expect(() => layer.files.clear(), throwsUnsupportedError);
        expect(() => file.hunks.clear(), throwsUnsupportedError);
        expect(() => hunk.lines.clear(), throwsUnsupportedError);
      }
      final conflict = snapshot.uncommitted.conflicts.single;
      expect(conflict.relativePath, 'conflict.txt');
      expect(conflict.changeKind, 'conflicted');
      expect(conflict.contentStatus, 'conflicted');
      expect(conflict.detail, 'Unmerged index entries.');
      expect(conflict.hunks, isEmpty);
      expect(
        () => snapshot.uncommitted.conflicts.clear(),
        throwsUnsupportedError,
      );
      expect(() => conflict.hunks.clear(), throwsUnsupportedError);
    },
  );

  test('declared failures reconstruct without inventing a snapshot', () async {
    service.failure = const ChangeSetFailure(
      code: 'snapshot_too_large',
      message: 'Changes exceed the snapshot bound.',
    );
    for (final invoke in [
      client.snapshotUnstaged,
      client.snapshotUncommitted,
      client.snapshotTaskChanges,
    ]) {
      await expectLater(
        invoke(),
        throwsA(
          isA<ChangeSetFailure>()
              .having((failure) => failure.code, 'code', 'snapshot_too_large')
              .having(
                (failure) => failure.message,
                'message',
                'Changes exceed the snapshot bound.',
              )
              .having((failure) => failure.details, 'details', isEmpty),
        ),
      );
    }
  });

  test('unexpected failures stay opaque for all methods', () async {
    service.failure = StateError('private provider diagnostics');
    for (final invoke in [
      client.snapshotUnstaged,
      client.snapshotUncommitted,
      client.snapshotTaskChanges,
    ]) {
      await expectLater(
        invoke(),
        throwsA(
          isA<AdeleRemoteFailure>()
              .having((error) => error.code, 'code', 'internal_error')
              .having(
                (error) => error.message,
                'message',
                isNot(contains('private')),
              ),
        ),
      );
    }
  });

  test(
    'zero-argument service rejects injected authority and unknown fields',
    () async {
      for (final method in [
        changeSetSourceServiceSnapshotUnstagedId,
        changeSetSourceServiceSnapshotUncommittedId,
        changeSetSourceServiceSnapshotTaskChangesId,
      ]) {
        for (final field in [
          'sessionId',
          'environmentId',
          'root',
          'path',
          'scope',
          'configurationContext',
          'hostInvocationContext',
        ]) {
          final response = await dispatcher.dispatch({
            'kind': 'request',
            'requestId': 1,
            'method': method,
            'payload': {field: 'forged'},
          });
          expect(response['ok'], isFalse);
        }
      }
      expect(service.calls, 0);
    },
  );

  test(
    'strict generated decoder rejects missing nullable and malformed nested fields',
    () async {
      await client.snapshotUnstaged();
      final snapshot = channel.response! as Map<String, dynamic>;
      final file = (snapshot['files'] as List).single as Map<String, dynamic>;
      final hunk = (file['hunks'] as List).single as Map<String, dynamic>;
      final line = (hunk['lines'] as List).first as Map<String, dynamic>;
      for (final invalid in <Object?>[
        <String, Object?>{},
        {...snapshot, 'extra': true},
        {
          ...snapshot,
          'files': [
            {...file}..remove('detail'),
          ],
        },
        {
          ...snapshot,
          'files': [
            {...file, 'hunks': 'patch'},
          ],
        },
        {
          ...snapshot,
          'files': [
            {
              ...file,
              'hunks': [
                {...hunk, 'oldCount': 1.5},
              ],
            },
          ],
        },
        {
          ...snapshot,
          'files': [
            {
              ...file,
              'hunks': [
                {
                  ...hunk,
                  'lines': [
                    {...line, 'noNewline': 'false'},
                  ],
                },
              ],
            },
          ],
        },
      ]) {
        await expectLater(
          ChangeSetSourceServiceClient(_Response(invalid)).snapshotUnstaged(),
          throwsA(isA<AdeleProtocolException>()),
        );
      }
    },
  );

  test(
    'strict uncommitted decoding rejects partial layers and malformed conflicts',
    () async {
      await client.snapshotUncommitted();
      final wire = channel.response! as Map<String, dynamic>;
      final staged = wire['staged'] as Map<String, dynamic>;
      final file = (staged['files'] as List).single as Map<String, dynamic>;
      final hunk = (file['hunks'] as List).single as Map<String, dynamic>;
      final line = (hunk['lines'] as List).first as Map<String, dynamic>;
      for (final invalid in <Object?>[
        null,
        <String, Object?>{},
        {...wire, 'extra': true},
        for (final field in ['staged', 'unstaged', 'conflicts']) ...[
          {...wire}..remove(field),
          {...wire, field: null},
          {...wire, field: 'invalid'},
        ],
        for (final layer in ['staged', 'unstaged']) ...[
          {...wire, layer: <String, Object?>{}},
          {
            ...wire,
            layer: {...staged, 'extra': true},
          },
          {
            ...wire,
            layer: {
              ...staged,
              'files': [
                {...file}..remove('detail'),
              ],
            },
          },
          {
            ...wire,
            layer: {
              ...staged,
              'files': [
                {
                  ...file,
                  'hunks': [
                    {...hunk, 'oldCount': 1.5},
                  ],
                },
              ],
            },
          },
          {
            ...wire,
            layer: {
              ...staged,
              'files': [
                {
                  ...file,
                  'hunks': [
                    {
                      ...hunk,
                      'lines': [
                        {...line, 'noNewline': 'false'},
                      ],
                    },
                  ],
                },
              ],
            },
          },
        ],
        {
          ...wire,
          'conflicts': [null],
        },
        {
          ...wire,
          'conflicts': [
            {...file}..remove('relativePath'),
          ],
        },
        {
          ...wire,
          'conflicts': [
            {...file, 'extra': true},
          ],
        },
        {
          ...wire,
          'conflicts': [
            {
              ...file,
              'hunks': [
                {
                  ...hunk,
                  'lines': [
                    {...line, 'text': false},
                  ],
                },
              ],
            },
          ],
        },
      ]) {
        await expectLater(
          ChangeSetSourceServiceClient(
            _Response(invalid),
          ).snapshotUncommitted(),
          throwsA(isA<AdeleProtocolException>()),
        );
      }
    },
  );

  test(
    'strict Task decoder rejects missing components and malformed deep layers',
    () async {
      await client.snapshotTaskChanges();
      final wire = channel.response! as Map<String, dynamic>;
      for (final invalid in _invalidTaskWires(wire)) {
        await expectLater(
          ChangeSetSourceServiceClient(
            _Response(invalid),
          ).snapshotTaskChanges(),
          throwsA(isA<AdeleProtocolException>()),
        );
      }
    },
  );

  test(
    'real eval client decodes native layers into nested immutable values',
    () async {
      await client.snapshotUnstaged();
      final unstagedWire = jsonEncode(channel.response);
      await client.snapshotUncommitted();
      final uncommittedWire = jsonEncode(channel.response);
      await client.snapshotTaskChanges();
      final taskWire = jsonEncode(channel.response);
      final generated = await const ContractGenerator().generateEvalClient(
        File('lib/diff_viewer_contract.dart'),
      );
      final compiler = Compiler()
        ..entrypoints.addAll([
          'package:adele_contract/adele_contract.dart',
          'package:diff_viewer_contract/diff_viewer_contract.dart',
          'package:runner/main.dart',
        ]);
      final program = compiler.compile({
        'adele_contract': {'adele_contract.dart': evalContractSupportSource},
        'diff_viewer_contract': {'diff_viewer_contract.dart': generated},
        'runner': {
          'main.dart':
              '''
import 'dart:convert';
import 'package:adele_contract/adele_contract.dart';
import 'package:diff_viewer_contract/diff_viewer_contract.dart';

class Channel implements AdeleRequestChannel {
  Future<Object?> request(String method, Map<String, Object?> payload) async {
    if (method == '$reviewApprovalServiceApproveId' || method == '$reviewApprovalServiceUnapproveId') {
      final selection = payload['selection'] as Map<String, Object?>;
      if (selection['expectedRevision'] != 'revision' ||
          !selection.containsKey('relativePath') || !selection.containsKey('hunkIndex')) {
        throw StateError('Invalid review wire');
      }
      return <String, Object?>{'status': 'applied'};
    }
    if (payload.isNotEmpty) throw StateError('Authority in request');
    if (method == '$changeSetSourceServiceSnapshotUnstagedId') {
      return jsonDecode(${jsonEncode(unstagedWire)});
    }
    if (method == '$changeSetSourceServiceSnapshotUncommittedId') {
      return jsonDecode(${jsonEncode(uncommittedWire)});
    }
    if (method == '$changeSetSourceServiceSnapshotTaskChangesId') {
      return jsonDecode(${jsonEncode(taskWire)});
    }
    throw StateError('Wrong method');
  }
}

String layer(ChangeSetSnapshot snapshot) {
  final file = snapshot.files[0];
  final hunk = file.hunks[0];
  final line = hunk.lines[2];
  return '\${file.relativePath}|\${file.changeKind}|\${file.contentStatus}|\${file.detail ?? 'none'}|\${hunk.oldStart},\${hunk.oldCount},\${hunk.newStart},\${hunk.newCount}|\${line.kind}|\${line.text}|\${line.noNewline}';
}

Future<String> run() async {
  final ChangeSetSourceServiceClient client = ChangeSetSourceServiceClient(Channel());
  final old = await client.snapshotUnstaged();
  if (old.reviewRevision != 'revision' || !old.files[0].reviewEligible) {
    throw StateError('Review evidence lost');
  }
  final ReviewApprovalServiceClient review = ReviewApprovalServiceClient(Channel());
  final approved = await review.approve(ReviewSelection(expectedRevision: old.reviewRevision!, granularity: 'hunk', relativePath: old.files[0].relativePath, hunkIndex: 0));
  final unapproved = await review.unapprove(ReviewSelection(expectedRevision: old.reviewRevision!, granularity: 'layer', relativePath: null, hunkIndex: null));
  if (approved.status != 'applied' || unapproved.status != 'applied') throw StateError('Review result lost');
  final snapshot = await client.snapshotUncommitted();
  final task = await client.snapshotTaskChanges();
  final conflict = snapshot.conflicts[0];
  final lines = <DiffLine>[DiffLine(kind: 'addition', text: 'detached', noNewline: false)];
  final hunks = <DiffHunk>[DiffHunk(oldStart: 0, oldCount: 0, newStart: 1, newCount: 1, lines: lines)];
  final files = <ChangedFile>[ChangedFile(relativePath: 'copy.txt', changeKind: 'added', contentStatus: 'text', detail: null, hunks: hunks, reviewEligible: false)];
  final copy = UncommittedChangeSetSnapshot(staged: ChangeSetSnapshot(files: files, reviewRevision: null), unstaged: ChangeSetSnapshot(files: files, reviewRevision: null), conflicts: files);
  final taskCopy = TaskChangeSetSnapshot(committed: ChangeSetSnapshot(files: files, reviewRevision: null), uncommitted: copy);
  lines[0] = DiffLine(kind: 'addition', text: 'changed', noNewline: false);
  hunks[0] = DiffHunk(oldStart: 0, oldCount: 0, newStart: 0, newCount: 0, lines: <DiffLine>[]);
  files[0] = ChangedFile(relativePath: 'changed.txt', changeKind: 'added', contentStatus: 'text', detail: null, hunks: <DiffHunk>[], reviewEligible: false);
  if (copy.staged.files[0].hunks[0].lines[0].text != 'detached' ||
      copy.unstaged.files[0].relativePath != 'copy.txt' || copy.conflicts[0].relativePath != 'copy.txt' ||
      taskCopy.committed.files[0].hunks[0].lines[0].text != 'detached') {
    throw StateError('Mutable constructor inputs');
  }
  final collected = <ChangedFile>[];
  collected.addAll(task.committed.files);
  collected.addAll(task.uncommitted.staged.files);
  collected.addAll(task.uncommitted.unstaged.files);
  collected.addAll(task.uncommitted.conflicts);
  collected.addAll(ChangeSetSnapshot(files: <ChangedFile>[], reviewRevision: null).files);
  final collectedHunks = <DiffHunk>[];
  collectedHunks.addAll(collected[0].hunks);
  collectedHunks.addAll(collected[3].hunks);
  final collectedLines = <DiffLine>[];
  collectedLines.addAll(collectedHunks[0].lines);
  if (collected.length != 4 || collectedHunks.length != 1 || collectedLines.length != 3) {
    throw StateError('Typed getter copies cannot be consumed');
  }
  task.committed.files.clear();
  task.uncommitted.staged.files[0].hunks.clear();
  task.uncommitted.unstaged.files[0].hunks[0].lines.clear();
  task.uncommitted.conflicts.clear();
  return '\${layer(old)};\${layer(snapshot.staged)};\${layer(snapshot.unstaged)};\${layer(task.committed)};\${layer(task.uncommitted.staged)};\${layer(task.uncommitted.unstaged)};\${task.uncommitted.conflicts[0].relativePath};\${conflict.relativePath}|\${conflict.changeKind}|\${conflict.contentStatus}|\${conflict.detail}';
}
Future<TaskChangeSetSnapshot> read() {
  final ChangeSetSourceServiceClient client = ChangeSetSourceServiceClient(Channel());
  return client.snapshotTaskChanges();
}
''',
        },
      });
      final runtime = Runtime(program.write().buffer.asByteData());
      final result = await runtime.executeLib(
        'package:runner/main.dart',
        'run',
      );
      const layer =
          'dir/two words\t\u03bb.txt|modified|text|none|2,2,2,2|addition|after\u{1f600}|true';
      expect(
        (result as $Value).$reified,
        '$layer;$layer;$layer;$layer;$layer;$layer;conflict.txt;conflict.txt|conflicted|conflicted|Unmerged index entries.',
      );
      final decoded = await runtime.executeLib(
        'package:runner/main.dart',
        'read',
      );
      var lists = 0;
      void verify(Object? value) {
        if (value is $InstanceImpl) {
          for (final field in value.values) {
            verify(field);
          }
        } else if (value is List) {
          lists++;
          expect(() => value.clear(), throwsUnsupportedError);
          for (final item in value) {
            verify(item);
          }
        } else if (value is $Value && value.$value is List) {
          verify(value.$value);
        }
      }

      // Inspect stored values: the pin's public getter boxes lists into copies.
      verify(decoded);
      expect(lists, 11);
    },
  );
}

Iterable<Object?> _invalidTaskWires(Map<String, dynamic> wire) sync* {
  yield null;
  yield <String, Object?>{};
  yield {...wire, 'extra': true};
  for (final field in ['committed', 'uncommitted']) {
    yield {...wire}..remove(field);
    yield {...wire, field: null};
    yield {...wire, field: 'invalid'};
    yield {...wire, field: <String, Object?>{}};
  }
  final uncommitted = wire['uncommitted'] as Map<String, dynamic>;
  yield {
    ...wire,
    'uncommitted': {...uncommitted, 'extra': true},
  };
  for (final field in ['staged', 'unstaged', 'conflicts']) {
    yield {
      ...wire,
      'uncommitted': {...uncommitted}..remove(field),
    };
    yield {
      ...wire,
      'uncommitted': {...uncommitted, field: null},
    };
    yield {
      ...wire,
      'uncommitted': {...uncommitted, field: 'invalid'},
    };
  }
  final committed = wire['committed'] as Map<String, dynamic>;
  final file = (committed['files'] as List).single as Map<String, dynamic>;
  final hunk = (file['hunks'] as List).single as Map<String, dynamic>;
  final line = (hunk['lines'] as List).first as Map<String, dynamic>;
  for (final layer in ['committed', 'staged', 'unstaged', 'conflicts']) {
    for (final invalidFile in [
      null,
      {...file}..remove('detail'),
      {...file, 'extra': true},
      {...file, 'hunks': 'patch'},
      {
        ...file,
        'hunks': [
          {...hunk, 'oldStart': 1.5},
        ],
      },
      {
        ...file,
        'hunks': [
          {
            ...hunk,
            'lines': [
              {...line, 'noNewline': 'false'},
            ],
          },
        ],
      },
    ]) {
      final bad = layer == 'conflicts'
          ? [invalidFile]
          : {
              ...committed,
              'files': [invalidFile],
            };
      yield layer == 'committed'
          ? {...wire, layer: bad}
          : {
              ...wire,
              'uncommitted': {...uncommitted, layer: bad},
            };
    }
  }
}

const _reviewSelections = [
  ReviewSelection(
    expectedRevision: 'opaque:revision',
    granularity: 'hunk',
    relativePath: 'dir/two words.txt',
    hunkIndex: 0,
  ),
  ReviewSelection(
    expectedRevision: 'opaque:revision',
    granularity: 'file',
    relativePath: 'dir/two words.txt',
    hunkIndex: null,
  ),
  ReviewSelection(
    expectedRevision: 'opaque:revision',
    granularity: 'layer',
    relativePath: null,
    hunkIndex: null,
  ),
];

const _selectionWire = <String, Object?>{
  'expectedRevision': 'opaque:revision',
  'granularity': 'hunk',
  'relativePath': 'dir/two words.txt',
  'hunkIndex': 0,
};

Iterable<Object?> get _invalidSelectionWires sync* {
  yield null;
  yield 'selection';
  yield <Object?>[];
  yield {..._selectionWire, 'extra': true};
  for (final field in _selectionWire.keys) {
    yield {..._selectionWire}..remove(field);
    for (final value in <Object?>[true, <Object?>[], <String, Object?>{}]) {
      yield {..._selectionWire, field: value};
    }
  }
  for (final field in ['expectedRevision', 'granularity']) {
    yield {..._selectionWire, field: null};
    yield {..._selectionWire, field: 1};
  }
  yield {..._selectionWire, 'relativePath': 1};
  yield {..._selectionWire, 'hunkIndex': '0'};
  yield {..._selectionWire, 'hunkIndex': 0.5};
}

const _invalidResultWires = <Object?>[
  null,
  'applied',
  <Object?>[],
  <String, Object?>{},
  {'status': null},
  {'status': true},
  {'status': 1},
  {'status': <Object?>[]},
  {'status': 'applied', 'extra': true},
];

class _ReviewService implements ReviewApprovalService {
  ReviewSelection? selection;
  String status = 'applied';
  Object? failure;
  @override
  Future<ReviewApprovalResult> approve(ReviewSelection selection) async {
    this.selection = selection;
    if (failure != null) throw failure!;
    return ReviewApprovalResult(status: status);
  }

  @override
  Future<ReviewApprovalResult> unapprove(ReviewSelection selection) =>
      approve(selection);
}

class _Service implements ChangeSetSourceService {
  int calls = 0;
  Object? failure;
  @override
  Future<ChangeSetSnapshot> snapshotUnstaged() async {
    calls++;
    if (failure != null) throw failure!;
    return _snapshot();
  }

  @override
  Future<UncommittedChangeSetSnapshot> snapshotUncommitted() async {
    calls++;
    if (failure != null) throw failure!;
    return _uncommitted();
  }

  @override
  Future<TaskChangeSetSnapshot> snapshotTaskChanges() async {
    calls++;
    if (failure != null) throw failure!;
    return TaskChangeSetSnapshot(
      committed: _snapshot(),
      uncommitted: _uncommitted(),
    );
  }

  UncommittedChangeSetSnapshot _uncommitted() => UncommittedChangeSetSnapshot(
    staged: _snapshot(),
    unstaged: _snapshot(),
    conflicts: [
      ChangedFile(
        relativePath: 'conflict.txt',
        changeKind: 'conflicted',
        contentStatus: 'conflicted',
        detail: 'Unmerged index entries.',
        reviewEligible: false,
        hunks: [],
      ),
    ],
  );

  ChangeSetSnapshot _snapshot() {
    return ChangeSetSnapshot(
      reviewRevision: 'revision',
      files: [
        ChangedFile(
          relativePath: 'dir/two words\t\u03bb.txt',
          changeKind: 'modified',
          contentStatus: 'text',
          detail: null,
          reviewEligible: true,
          hunks: [
            DiffHunk(
              oldStart: 2,
              oldCount: 2,
              newStart: 2,
              newCount: 2,
              lines: const [
                DiffLine(kind: 'context', text: 'same', noNewline: false),
                DiffLine(kind: 'deletion', text: 'before', noNewline: true),
                DiffLine(
                  kind: 'addition',
                  text: 'after\u{1f600}',
                  noNewline: true,
                ),
              ],
            ),
          ],
        ),
      ],
    );
  }
}

class _Channel implements AdeleRequestChannel {
  _Channel(this.dispatcher);
  final AdeleBackendDispatcher dispatcher;
  String? method;
  Map<String, Object?>? payload;
  Object? response;
  @override
  Future<Object?> request(String method, Map<String, Object?> payload) async {
    this.method = method;
    this.payload = payload;
    final result = await dispatcher.dispatch({
      'kind': 'request',
      'requestId': 1,
      'method': method,
      'payload': jsonDecode(jsonEncode(payload)),
    });
    if (result['ok'] != true) throw _Failure(result['error']! as Map);
    return response = jsonDecode(jsonEncode(result['payload']));
  }
}

class _Response implements AdeleRequestChannel {
  _Response(this.value);
  final Object? value;
  @override
  Future<Object?> request(String method, Map<String, Object?> payload) async =>
      value;
}

class _Failure implements AdeleRemoteFailure {
  _Failure(this.error);
  final Map<Object?, Object?> error;
  @override
  String? get declaredFailureType => error['declaredFailureType'] as String?;
  @override
  String get code => error['code'] as String;
  @override
  String get message => error['message'] as String;
  @override
  Map<String, Object?> get details =>
      Map<String, Object?>.from(error['details'] as Map);
}
