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

  test('generated transport roundtrips the complete nested snapshot', () async {
    final snapshot = await client.snapshotUnstaged();
    expect(changeSetSourceCapability.id.value, 'adele.diff.change-set-source');
    expect(changeSetSourceCapability.majorVersion, 1);
    expect(channel.method, 'diff.changeSetSource.snapshotUnstaged');
    expect(channel.payload, isEmpty);
    final file = snapshot.files.single;
    expect(file.relativePath, 'dir/two words\t\u03bb.txt');
    expect(file.changeKind, 'modified');
    expect(file.contentStatus, 'text');
    expect(file.detail, isNull);
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
      hunks: hunks,
    );
    final files = [file];
    final snapshot = ChangeSetSnapshot(files: files);
    final conflicts = [file];
    final uncommitted = UncommittedChangeSetSnapshot(
      staged: snapshot,
      unstaged: ChangeSetSnapshot(files: files),
      conflicts: conflicts,
    );
    lines.clear();
    hunks.clear();
    files.clear();
    conflicts.clear();
    expect(snapshot.files.single.hunks.single.lines.single.text, 'new');
    expect(() => snapshot.files.clear(), throwsUnsupportedError);
    expect(() => file.hunks.clear(), throwsUnsupportedError);
    expect(() => hunk.lines.clear(), throwsUnsupportedError);
    for (final layer in [uncommitted.staged, uncommitted.unstaged]) {
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

  test('declared failures reconstruct without inventing a snapshot', () async {
    service.failure = const ChangeSetFailure(
      code: 'snapshot_too_large',
      message: 'Changes exceed the snapshot bound.',
    );
    for (final invoke in [
      client.snapshotUnstaged,
      client.snapshotUncommitted,
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

  test('unexpected failures stay opaque for both methods', () async {
    service.failure = StateError('private provider diagnostics');
    for (final invoke in [
      client.snapshotUnstaged,
      client.snapshotUncommitted,
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
          'files': [
            {...file}..remove('detail'),
          ],
        },
        {
          'files': [
            {...file, 'hunks': 'patch'},
          ],
        },
        {
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
              'files': [
                {...file}..remove('detail'),
              ],
            },
          },
          {
            ...wire,
            layer: {
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
    'real eval client decodes native layers into nested immutable values',
    () async {
      await client.snapshotUnstaged();
      final unstagedWire = jsonEncode(channel.response);
      await client.snapshotUncommitted();
      final uncommittedWire = jsonEncode(channel.response);
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
    if (payload.isNotEmpty) throw StateError('Authority in request');
    if (method == '$changeSetSourceServiceSnapshotUnstagedId') {
      return jsonDecode(${jsonEncode(unstagedWire)});
    }
    if (method != '$changeSetSourceServiceSnapshotUncommittedId') {
      throw StateError('Wrong method');
    }
    return jsonDecode(${jsonEncode(uncommittedWire)});
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
  final snapshot = await client.snapshotUncommitted();
  final conflict = snapshot.conflicts[0];
  final lines = <DiffLine>[DiffLine(kind: 'addition', text: 'detached', noNewline: false)];
  final hunks = <DiffHunk>[DiffHunk(oldStart: 0, oldCount: 0, newStart: 1, newCount: 1, lines: lines)];
  final files = <ChangedFile>[ChangedFile(relativePath: 'copy.txt', changeKind: 'added', contentStatus: 'text', detail: null, hunks: hunks)];
  final copy = UncommittedChangeSetSnapshot(staged: ChangeSetSnapshot(files: files), unstaged: ChangeSetSnapshot(files: files), conflicts: files);
  lines[0] = DiffLine(kind: 'addition', text: 'changed', noNewline: false);
  hunks[0] = DiffHunk(oldStart: 0, oldCount: 0, newStart: 0, newCount: 0, lines: <DiffLine>[]);
  files[0] = ChangedFile(relativePath: 'changed.txt', changeKind: 'added', contentStatus: 'text', detail: null, hunks: <DiffHunk>[]);
  if (copy.staged.files[0].hunks[0].lines[0].text != 'detached' ||
      copy.unstaged.files[0].relativePath != 'copy.txt' || copy.conflicts[0].relativePath != 'copy.txt') {
    throw StateError('Mutable constructor inputs');
  }
  return '\${layer(old)};\${layer(snapshot.staged)};\${layer(snapshot.unstaged)};\${conflict.relativePath}|\${conflict.changeKind}|\${conflict.contentStatus}|\${conflict.detail}';
}
Future<UncommittedChangeSetSnapshot> read() {
  final ChangeSetSourceServiceClient client = ChangeSetSourceServiceClient(Channel());
  return client.snapshotUncommitted();
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
        '$layer;$layer;$layer;conflict.txt|conflicted|conflicted|Unmerged index entries.',
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
      expect(lists, 8);
    },
  );
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
    return UncommittedChangeSetSnapshot(
      staged: _snapshot(),
      unstaged: _snapshot(),
      conflicts: [
        ChangedFile(
          relativePath: 'conflict.txt',
          changeKind: 'conflicted',
          contentStatus: 'conflicted',
          detail: 'Unmerged index entries.',
          hunks: [],
        ),
      ],
    );
  }

  ChangeSetSnapshot _snapshot() {
    return ChangeSetSnapshot(
      files: [
        ChangedFile(
          relativePath: 'dir/two words\t\u03bb.txt',
          changeKind: 'modified',
          contentStatus: 'text',
          detail: null,
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
  final ChangeSetSourceServiceDispatcher dispatcher;
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
