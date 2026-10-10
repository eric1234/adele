import 'dart:convert';

import 'package:adele_contract/adele_contract.dart';
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
    lines.clear();
    hunks.clear();
    files.clear();
    expect(snapshot.files.single.hunks.single.lines.single.text, 'new');
    expect(() => snapshot.files.clear(), throwsUnsupportedError);
    expect(() => file.hunks.clear(), throwsUnsupportedError);
    expect(() => hunk.lines.clear(), throwsUnsupportedError);
  });

  test('declared failures reconstruct without inventing a snapshot', () async {
    service.failure = const ChangeSetFailure(
      code: 'snapshot_too_large',
      message: 'Changes exceed the snapshot bound.',
    );
    await expectLater(
      client.snapshotUnstaged(),
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
  });

  test(
    'zero-argument service rejects injected authority and unknown fields',
    () async {
      for (final field in [
        'sessionId',
        'environmentId',
        'root',
        'hostInvocationContext',
      ]) {
        final response = await dispatcher.dispatch({
          'kind': 'request',
          'requestId': 1,
          'method': changeSetSourceServiceSnapshotUnstagedId,
          'payload': {field: 'forged'},
        });
        expect(response['ok'], isFalse);
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
}

class _Service implements ChangeSetSourceService {
  int calls = 0;
  ChangeSetFailure? failure;
  @override
  Future<ChangeSetSnapshot> snapshotUnstaged() async {
    calls++;
    if (failure != null) throw failure!;
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
