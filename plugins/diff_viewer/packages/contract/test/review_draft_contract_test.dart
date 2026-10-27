import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:adele_contract/adele_contract.dart';
import 'package:contract_codegen/contract_codegen.dart';
import 'package:dart_eval/dart_eval.dart';
import 'package:dart_eval/dart_eval_bridge.dart';
import 'package:dart_eval/src/eval/runtime/class.dart' show $InstanceImpl;
import 'package:dart_eval/stdlib/core.dart';
import 'package:diff_viewer_contract/diff_viewer_contract.dart';
import 'package:test/test.dart';

const _anchorWire = <String, Object?>{
  'environmentId': 'environment-\u03bb',
  'relativePath': 'dir/two words\t\u03bb:?#%.txt',
  'layer': 'committed',
  'side': 'oldSide',
  'startLine': 3,
  'endLine': 4,
  'comparisonIdentity': 'captured-source:not-an-approval',
  'sourceExcerpt': ' before\r\n\t\u{1f600}e\u0301 \n',
  'hunkIndex': 2,
  'lineIndex': 7,
};
const _text = '  Comment \u03bb \u{1f600} e\u0301\r\n\tsecond line  ';
const _failureCodes = [
  'invalid_request',
  'stale_comment',
  'limit_exceeded',
  'corrupt_state',
  'storage_unavailable',
  'outcome_uncertain',
  'backend_closed',
];

void main() {
  test('draft service identity is independent of approval and snapshots', () {
    expect(reviewDraftServiceId, 'diff.reviewDraft');
    expect(reviewDraftServiceSnapshotId, 'diff.reviewDraft.snapshot');
    expect(reviewDraftServiceCreateCommentId, 'diff.reviewDraft.createComment');
    expect(reviewDraftServiceUpdateCommentId, 'diff.reviewDraft.updateComment');
    expect(reviewDraftServiceDeleteCommentId, 'diff.reviewDraft.deleteComment');
    expect(reviewDraftServiceId, isNot(reviewApprovalHandlerServiceId));
    expect(reviewDraftServiceId, isNot(changeSetSourceServiceId));
    // The new validation must not tighten the shipped approval selections.
    expect(ReviewLayerSelection(expectedRevision: ' ').expectedRevision, ' ');
    expect(
      ReviewHunkSelection(
        relativePath: r'C:\literal',
        hunkIndex: 0,
        expectedRevision: ' ',
      ).relativePath,
      r'C:\literal',
    );
  });

  test('immutable snapshots reject duplicate IDs and noncreation ordering', () {
    final first = _comment();
    final second = _comment(id: 'comment-3', sequence: 3);
    final input = [first, second];
    final snapshot = ReviewDraftSnapshot(sessionId: 'session', comments: input);
    input.clear();
    expect(snapshot.comments, [first, second]);
    expect(() => snapshot.comments.clear(), throwsUnsupportedError);
    expect(identical(snapshot.comments.first.anchor, first.anchor), isTrue);
    for (final comments in [
      [first, _comment(sequence: 2)],
      [first, _comment(id: 'different', sequence: 1)],
      [second, first],
    ]) {
      expect(
        () => ReviewDraftSnapshot(sessionId: 'session', comments: comments),
        throwsArgumentError,
      );
    }
    expect(
      ReviewDraftSnapshot(sessionId: 'session', comments: []).comments,
      isEmpty,
    );
  });

  test(
    'anchor enforces canonical identities, paths and all inclusive bounds',
    () {
      for (final wire in _invalidAnchors()) {
        expect(() => _anchor(wire), throwsArgumentError, reason: '$wire');
      }
      for (final wire in [
        {
          'environmentId': '\u{1f600}' * 128,
          'relativePath': '\u{1f600}' * 2048,
          'sourceExcerpt': '\u{1f600}' * 2048,
          'comparisonIdentity': '~' * 256,
          'startLine': ReviewDraftLimits.maxLine - 999,
          'endLine': ReviewDraftLimits.maxLine,
          'hunkIndex': 8191,
          'lineIndex': 65535,
        },
        {
          'relativePath': '.github/.gitignore',
          'sourceExcerpt': '',
          'comparisonIdentity': ' identity with outer spaces ',
          'startLine': 1,
          'endLine': 1000,
          'hunkIndex': 0,
          'lineIndex': 0,
        },
        {
          'relativePath': 'dir/ line\r\nbreak \t:\u03bb?#% ',
          'sourceExcerpt': ' \r\n',
        },
      ]) {
        final anchor = _anchor(wire);
        expect(anchor.relativePath, wire['relativePath']);
        expect(anchor.sourceExcerpt, wire['sourceExcerpt']);
      }
    },
  );

  test(
    'body, IDs and counters reject invalid values without normalization',
    () {
      for (final value in _invalidIdentities()) {
        expect(() => _comment(id: value), throwsArgumentError);
        expect(
          () => ReviewDraftSnapshot(sessionId: value, comments: []),
          throwsArgumentError,
        );
      }
      for (final text in [
        '',
        ' ',
        '\r\n\t\u00a0\u2003',
        'a' * 8193,
        '\u{1f600}' * 4096 + 'x',
        ..._malformedUnicode,
      ]) {
        expect(() => _comment(text: text), throwsArgumentError);
      }
      for (final value in [-1, 0, 2147483648]) {
        expect(() => _comment(version: value), throwsArgumentError);
        expect(() => _comment(sequence: value), throwsArgumentError);
        expect(() => validateReviewCommentVersion(value), throwsArgumentError);
      }
      final comment = _comment(
        id: '\u{1f600}' * 128,
        text: '\u{1f600}' * 4096,
        version: 2147483647,
        sequence: 2147483647,
      );
      expect(comment.text.length, 8192);
      expect(_comment(text: _text).text, _text);
    },
  );

  test('single-line anchors are the one-line case of inclusive ranges', () {
    for (final line in [1, 17, ReviewDraftLimits.maxLine]) {
      final single = _anchor({'startLine': line, 'endLine': line});
      expect(single.startLine, line);
      expect(single.endLine, line);
      expect(single.comparisonIdentity, _anchorWire['comparisonIdentity']);
    }
    final range = _anchor({'startLine': 17, 'endLine': 1016});
    expect(range.endLine - range.startLine + 1, ReviewDraftLimits.maxLineRange);
  });

  test('comment count and combined charge are independent finite limits', () {
    final small = [
      for (var i = 1; i <= 128; i++) _comment(id: 'c$i', sequence: i),
    ];
    expect(
      ReviewDraftSnapshot(sessionId: 's', comments: small).comments,
      small,
    );
    expect(
      () => ReviewDraftSnapshot(
        sessionId: 's',
        comments: [
          ...small,
          _comment(id: 'c129', sequence: 129),
        ],
      ),
      throwsArgumentError,
    );
    final large = [
      for (var i = 1; i <= 10; i++)
        _comment(
          id: 'c$i',
          sequence: i,
          text: 'x' * 8192,
          anchor: _anchor({'sourceExcerpt': 'x' * 4096}),
        ),
    ];
    expect(reviewDraftSnapshotCharge('s', large), greaterThan(512 * 1024));
    expect(
      () => ReviewDraftSnapshot(sessionId: 's', comments: large),
      throwsArgumentError,
    );
    expect(reviewDraftSnapshotCharge('session', []), 256 + 6 * 7);
    final comment = _comment();
    expect(
      reviewCommentCharge(comment),
      512 +
          6 *
              (comment.id.length +
                  comment.text.length +
                  _anchorWire.values.whereType<String>().fold(
                    0,
                    (n, v) => n + v.length,
                  )),
    );
  });

  test('aggregate snapshot charge accepts its exact inclusive boundary', () {
    final comments = [
      for (var i = 1; i <= 8; i++)
        _comment(
          id: 'c$i',
          sequence: i,
          text: 'x' * 8192,
          anchor: _anchor({'sourceExcerpt': ''}),
        ),
    ];
    var remaining =
        (ReviewDraftLimits.maxSnapshotCharge -
            reviewDraftSnapshotCharge('s', comments)) ~/
        6;
    for (var i = 0; i < comments.length; i++) {
      final count = remaining > 4096 ? 4096 : remaining;
      remaining -= count;
      comments[i] = _comment(
        id: 'c${i + 1}',
        sequence: i + 1,
        text: 'x' * 8192,
        anchor: _anchor({'sourceExcerpt': 'x' * count}),
      );
    }
    expect(remaining, 0);
    expect(
      reviewDraftSnapshotCharge('s', comments),
      ReviewDraftLimits.maxSnapshotCharge,
    );
    expect(
      ReviewDraftSnapshot(sessionId: 's', comments: comments).comments,
      comments,
    );
    final last = comments.last;
    comments[7] = _comment(
      id: last.id,
      sequence: last.sequence,
      text: last.text,
      anchor: _anchor({'sourceExcerpt': '${last.anchor.sourceExcerpt}x'}),
    );
    expect(
      () => ReviewDraftSnapshot(sessionId: 's', comments: comments),
      throwsArgumentError,
    );
  });

  for (final eval in [false, true]) {
    group(eval ? 'actual eval transport' : 'native generated transport', () {
      late _Service service;
      late ReviewDraftServiceDispatcher dispatcher;
      late _Channel channel;
      late ReviewDraftServiceClient client;
      late ByteData bytecode;
      if (eval) {
        setUpAll(() async {
          final source = await const ContractGenerator().generateEvalClient(
            File('lib/review_draft.dart'),
          );
          final compiler = Compiler()
            ..entrypoints.addAll([
              'package:adele_contract/adele_contract.dart',
              'package:diff_viewer_contract/review_draft.dart',
              'package:runner/main.dart',
            ]);
          bytecode = compiler
              .compile({
                'adele_contract': {
                  'adele_contract.dart': evalContractSupportSource,
                },
                'diff_viewer_contract': {'review_draft.dart': source},
                'runner': {'main.dart': _evalRunner},
              })
              .write()
              .buffer
              .asByteData();
        });
      }
      setUp(() {
        service = _Service();
        dispatcher = ReviewDraftServiceDispatcher(service);
        channel = _Channel(dispatcher);
        client = ReviewDraftServiceClient(channel);
      });
      tearDown(() => dispatcher.close());

      Future<Object?> runEval(
        String operation,
        Map<String, Object?> data,
      ) async {
        final runtime = Runtime(bytecode);
        final result = await runtime
            .executeLib('package:runner/main.dart', 'run', [
              $Closure((_, _, args) {
                final method = args[0]!.$reified as String;
                final payload = jsonDecode(args[1]!.$reified as String) as Map;
                return $Future.wrap(
                  channel
                      .request(method, Map<String, Object?>.from(payload))
                      .then<$Value>((value) => $String(jsonEncode(value))),
                );
              }),
              $String(operation),
              $String(jsonEncode(data)),
            ]);
        return jsonDecode((result as $Value).$reified as String);
      }

      Future<Object?> invoke(
        String operation,
        Map<String, Object?> data,
      ) async {
        if (eval) return runEval(operation, data);
        final sessionId = data['sessionId']! as String;
        switch (operation) {
          case 'snapshot':
            return client.snapshot(sessionId);
          case 'create':
            return client.createComment(
              sessionId,
              _anchor(data['anchor']! as Map<String, Object?>),
              data['text']! as String,
            );
          case 'update':
            return client.updateComment(
              sessionId,
              data['commentId']! as String,
              data['expectedVersion']! as int,
              data['text']! as String,
            );
          case 'delete':
            await client.deleteComment(
              sessionId,
              data['commentId']! as String,
              data['expectedVersion']! as int,
            );
            return null;
        }
        throw StateError('Unknown test operation.');
      }

      Future<Object?> raw(String method, Map<String, Object?> payload) => eval
          ? runEval('raw', {'method': method, 'payload': payload})
          : channel.request(method, payload);

      test(
        'all methods roundtrip exact text, enums, anchors and counters',
        () async {
          for (final layer in ReviewComparisonLayer.values) {
            for (final side in ReviewComparisonSide.values) {
              final wire = {
                ..._anchorWire,
                'layer': layer.name,
                'side': side.name,
              };
              final createdResult = await invoke('create', {
                'sessionId': 'session-\u03bb',
                'anchor': wire,
                'text': _text,
              });
              expect(channel.method, reviewDraftServiceCreateCommentId);
              expect(channel.payload, {
                'sessionId': 'session-\u03bb',
                'anchor': wire,
                'text': _text,
              });
              final created = Map<String, Object?>.from(
                channel.response! as Map,
              );
              expect(created, {
                'id': 'comment-1',
                'anchor': wire,
                'text': _text,
                'version': 1,
                'sequence': 1,
              });
              if (eval) {
                expect(createdResult, created);
              } else {
                final comment = createdResult! as PendingReviewComment;
                expect(comment.text, _text);
                expect(comment.anchor.layer, layer);
                expect(comment.anchor.side, side);
              }
              expect(service.comments.single.anchor.layer, layer);
              expect(service.comments.single.anchor.side, side);
              expect(
                service.comments.single.anchor.sourceExcerpt,
                _anchorWire['sourceExcerpt'],
              );
              final snapshot = await invoke('snapshot', {
                'sessionId': 'session-\u03bb',
              });
              expect(channel.payload, {'sessionId': 'session-\u03bb'});
              expect(channel.response, {
                'sessionId': 'session-\u03bb',
                'comments': [created],
              });
              if (eval) {
                expect(snapshot, channel.response);
              } else {
                expect(
                  () => (snapshot! as ReviewDraftSnapshot).comments.clear(),
                  throwsUnsupportedError,
                );
              }
              const update = '  revised\r\n\u{1f600}  ';
              final updatedResult = await invoke('update', {
                'sessionId': 'session-\u03bb',
                'commentId': 'comment-1',
                'expectedVersion': 1,
                'text': update,
              });
              expect(channel.method, reviewDraftServiceUpdateCommentId);
              expect(channel.response, {
                ...created,
                'text': update,
                'version': 2,
              });
              if (eval) {
                expect(updatedResult, channel.response);
              } else {
                final comment = updatedResult! as PendingReviewComment;
                expect(comment.text, update);
                expect(comment.version, 2);
                expect(comment.sequence, 1);
              }
              expect(
                service.comments.single.anchor.comparisonIdentity,
                wire['comparisonIdentity'],
              );
              await invoke('delete', {
                'sessionId': 'session-\u03bb',
                'commentId': 'comment-1',
                'expectedVersion': 2,
              });
              expect(channel.method, reviewDraftServiceDeleteCommentId);
              expect(channel.response, isNull);
              await invoke('snapshot', {'sessionId': 'session-\u03bb'});
              expect(channel.response, {
                'sessionId': 'session-\u03bb',
                'comments': <Object?>[],
              });
            }
          }
        },
      );

      test(
        'declared failures preserve code, message, details without success',
        () async {
          for (final code in _failureCodes) {
            for (final details in <Map<String, Object?>>[
              {},
              {'reloadRequired': true, 'version': 2},
            ]) {
              service.failure = ReviewDraftFailure(
                code: code,
                message: 'Draft operation failed.',
                details: details,
              );
              for (final operation in [
                'snapshot',
                'create',
                'update',
                'delete',
              ]) {
                await expectLater(
                  invoke(operation, _request),
                  throwsA(
                    eval
                        ? isA<AdeleRemoteFailure>()
                              .having(
                                (e) => e.declaredFailureType,
                                'type',
                                'diff.reviewDraftFailure',
                              )
                              .having((e) => e.code, 'code', code)
                              .having(
                                (e) => e.message,
                                'message',
                                'Draft operation failed.',
                              )
                              .having((e) => e.details, 'details', details)
                        : isA<ReviewDraftFailure>()
                              .having((e) => e.code, 'code', code)
                              .having(
                                (e) => e.message,
                                'message',
                                'Draft operation failed.',
                              )
                              .having((e) => e.details, 'details', details),
                  ),
                );
              }
            }
          }
        },
      );

      test('invalid native-bound requests never enter service', () async {
        for (final anchor in [
          ..._invalidAnchors(),
          {'layer': 'other'},
          {'side': 'new'},
          {'layer': 0},
          {'side': null},
          {'environmentId': 1},
          {'hunkIndex': 0.5},
          {'expectedRevision': 'approval-revision'},
          {'hostInvocationContext': <String, Object?>{}},
        ]) {
          await expectLater(
            raw(reviewDraftServiceCreateCommentId, {
              'sessionId': 'session',
              'anchor': {..._anchorWire, ...anchor},
              'text': _text,
            }),
            throwsA(
              isA<AdeleRemoteFailure>().having(
                (e) => e.code,
                'code',
                'invalid_request',
              ),
            ),
          );
        }
        for (final field in _anchorWire.keys) {
          await expectLater(
            raw(reviewDraftServiceCreateCommentId, {
              'sessionId': 'session',
              'anchor': {..._anchorWire}..remove(field),
              'text': _text,
            }),
            throwsA(
              isA<AdeleRemoteFailure>().having(
                (e) => e.code,
                'code',
                'invalid_request',
              ),
            ),
          );
        }
        for (final (method, valid) in [
          (
            reviewDraftServiceSnapshotId,
            <String, Object?>{'sessionId': 'session'},
          ),
          (
            reviewDraftServiceCreateCommentId,
            <String, Object?>{
              'sessionId': 'session',
              'anchor': _anchorWire,
              'text': _text,
            },
          ),
          (
            reviewDraftServiceUpdateCommentId,
            <String, Object?>{
              'sessionId': 'session',
              'commentId': 'c',
              'expectedVersion': 1,
              'text': _text,
            },
          ),
          (
            reviewDraftServiceDeleteCommentId,
            <String, Object?>{
              'sessionId': 'session',
              'commentId': 'c',
              'expectedVersion': 1,
            },
          ),
        ]) {
          for (final payload in [
            for (final field in valid.keys) ...[
              {...valid}..remove(field),
              {...valid, field: null},
            ],
            {...valid, 'environmentId': 'forged-authority'},
            {...valid, 'expectedRevision': 'approval'},
            if (method == reviewDraftServiceUpdateCommentId)
              {...valid, 'anchor': _anchorWire},
          ]) {
            await expectLater(
              raw(method, payload),
              throwsA(
                isA<AdeleRemoteFailure>().having(
                  (e) => e.code,
                  'code',
                  'invalid_request',
                ),
              ),
            );
          }
        }
        for (final method in [
          reviewApprovalHandlerServiceApproveHunkId,
          reviewApprovalHandlerServiceUnapproveAllStagedId,
          changeSetSourceServiceSnapshotUnstagedId,
        ]) {
          await expectLater(
            raw(method, {}),
            throwsA(
              isA<AdeleRemoteFailure>().having(
                (e) => e.code,
                'code',
                'unknown_method',
              ),
            ),
          );
        }
        expect(service.calls, 0);
      });

      test(
        'unknown enum responses are rejected by generated decoders',
        () async {
          final comment = <String, Object?>{
            'id': 'c',
            'anchor': {..._anchorWire, 'layer': 'not-a-layer'},
            'text': _text,
            'version': 1,
            'sequence': 1,
          };
          for (final anchor in [
            {..._anchorWire, 'layer': 'not-a-layer'},
            {..._anchorWire, 'side': 1},
          ]) {
            channel.replacement = {
              'sessionId': 'session',
              'comments': [
                {...comment, 'anchor': anchor},
              ],
            };
            await expectLater(
              invoke('snapshot', {'sessionId': 'session'}),
              throwsA(
                eval ? isA<$InstanceImpl>() : isA<AdeleProtocolException>(),
              ),
            );
          }
        },
      );

      if (!eval) {
        test(
          'native snapshot decoder rejects duplicate IDs and invalid values',
          () async {
            service.comments.add(_comment());
            await client.snapshot('session');
            final wire = Map<String, Object?>.from(channel.response! as Map);
            final comment = Map<String, Object?>.from(
              (wire['comments']! as List).single as Map,
            );
            for (final comments in [
              [
                comment,
                {...comment, 'sequence': 2},
              ],
              [
                {...comment, 'version': 0},
              ],
              [
                {...comment, 'text': ' '},
              ],
              [
                {...comment}..remove('sequence'),
              ],
              [
                {...comment, 'extra': true},
              ],
            ]) {
              channel.replacement = {...wire, 'comments': comments};
              await expectLater(
                client.snapshot('session'),
                throwsA(isA<AdeleProtocolException>()),
              );
            }
          },
        );

        test(
          'public charge bounds actual generated escaped JSON snapshot',
          () async {
            for (final content in [
              '\u0000',
              '\\',
              '"',
              '\r\n',
              '\u03bb',
              '\u{1f600}',
            ]) {
              service.comments.clear();
              final anchor = _anchor({'sourceExcerpt': content * 2000});
              for (var i = 1; i <= 128; i++) {
                final comment = _comment(
                  id: 'comment-$i',
                  sequence: i,
                  text: 'x${content * 4000}',
                  anchor: anchor,
                );
                if (reviewDraftSnapshotCharge('session', [
                      ...service.comments,
                      comment,
                    ]) >
                    ReviewDraftLimits.maxSnapshotCharge) {
                  break;
                }
                service.comments.add(comment);
              }
              expect(service.comments, isNotEmpty);
              final snapshot = await client.snapshot('session');
              final actualBytes = utf8
                  .encode(jsonEncode(channel.response))
                  .length;
              final charge = reviewDraftSnapshotCharge(
                'session',
                snapshot.comments,
              );
              expect(actualBytes, lessThanOrEqualTo(charge));
              expect(
                charge,
                lessThanOrEqualTo(ReviewDraftLimits.maxSnapshotCharge),
              );
            }
          },
        );
      }
    });
  }
}

const _request = <String, Object?>{
  'sessionId': 'session',
  'commentId': 'comment-1',
  'expectedVersion': 1,
  'anchor': _anchorWire,
  'text': _text,
};

final _malformedUnicode = [
  String.fromCharCode(0xd800),
  String.fromCharCode(0xdc00),
  String.fromCharCodes([0xd800, 0x61]),
  String.fromCharCodes([0xdc00, 0xd800]),
];

Iterable<String> _invalidIdentities() => [
  '',
  ' ',
  ' outer',
  'outer ',
  '\u00a0outer',
  'outer\n',
  'in\u0000side',
  'in\u007fside',
  'in\u0085side',
  'x' * 257,
  '\u{1f600}' * 129,
  ..._malformedUnicode,
];

Iterable<Map<String, Object?>> _invalidAnchors() sync* {
  for (final value in _invalidIdentities()) {
    yield {'environmentId': value};
  }
  for (final path in [
    '',
    '/',
    '/absolute',
    'dir/',
    'dir//file',
    '.',
    '..',
    '.git',
    './file',
    '../file',
    'dir/./file',
    'dir/../file',
    'dir/.git/file',
    'dir/a\u0000b',
    r'dir\file',
    r'\server\share',
    'C:file',
    'z:/file',
    'x' * 4097,
    '\u{1f600}' * 2048 + 'x',
    ..._malformedUnicode,
  ]) {
    yield {'relativePath': path};
  }
  for (final value in [
    '',
    ' ',
    ' \t',
    '\u001f',
    '\u007f',
    '\u03bb',
    'x' * 257,
  ]) {
    yield {'comparisonIdentity': value};
  }
  for (final value in [
    'x' * 4097,
    '\u{1f600}' * 2048 + 'x',
    ..._malformedUnicode,
  ]) {
    yield {'sourceExcerpt': value};
  }
  yield {'startLine': 0};
  yield {'startLine': -1};
  yield {'startLine': 5, 'endLine': 4};
  yield {'startLine': 1, 'endLine': 1001};
  yield {'startLine': 2147483648, 'endLine': 2147483648};
  yield {'endLine': 2147483648};
  yield {'hunkIndex': -1};
  yield {'hunkIndex': 8192};
  yield {'lineIndex': -1};
  yield {'lineIndex': 65536};
}

ReviewCommentAnchor _anchor([Map<String, Object?> overrides = const {}]) {
  final value = {..._anchorWire, ...overrides};
  return ReviewCommentAnchor(
    environmentId: value['environmentId']! as String,
    relativePath: value['relativePath']! as String,
    layer: ReviewComparisonLayer.values.byName(value['layer']! as String),
    side: ReviewComparisonSide.values.byName(value['side']! as String),
    startLine: value['startLine']! as int,
    endLine: value['endLine']! as int,
    comparisonIdentity: value['comparisonIdentity']! as String,
    sourceExcerpt: value['sourceExcerpt']! as String,
    hunkIndex: value['hunkIndex']! as int,
    lineIndex: value['lineIndex']! as int,
  );
}

PendingReviewComment _comment({
  String id = 'comment-1',
  ReviewCommentAnchor? anchor,
  String text = _text,
  int version = 1,
  int sequence = 1,
}) => PendingReviewComment(
  id: id,
  anchor: anchor ?? _anchor(),
  text: text,
  version: version,
  sequence: sequence,
);

class _Service implements ReviewDraftService {
  final comments = <PendingReviewComment>[];
  Object? failure;
  int calls = 0;

  void _enter() {
    calls++;
    if (failure != null) throw failure!;
  }

  @override
  Future<ReviewDraftSnapshot> snapshot(String sessionId) async {
    _enter();
    return ReviewDraftSnapshot(sessionId: sessionId, comments: comments);
  }

  @override
  Future<PendingReviewComment> createComment(
    String sessionId,
    ReviewCommentAnchor anchor,
    String text,
  ) async {
    _enter();
    final comment = _comment(anchor: anchor, text: text);
    comments.add(comment);
    return comment;
  }

  @override
  Future<PendingReviewComment> updateComment(
    String sessionId,
    String commentId,
    int expectedVersion,
    String text,
  ) async {
    _enter();
    final comment = _comment(
      anchor: comments.single.anchor,
      text: text,
      version: expectedVersion + 1,
    );
    comments[0] = comment;
    return comment;
  }

  @override
  Future<void> deleteComment(
    String sessionId,
    String commentId,
    int expectedVersion,
  ) async {
    _enter();
    comments.clear();
  }
}

class _Channel implements AdeleRequestChannel {
  _Channel(this.dispatcher);
  final ReviewDraftServiceDispatcher dispatcher;
  String? method;
  Map<String, Object?>? payload;
  Object? response;
  Object? replacement;

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
    return response = replacement ?? jsonDecode(jsonEncode(result['payload']));
  }
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

const _evalRunner = r'''
import 'dart:convert';
import 'package:adele_contract/adele_contract.dart';
import 'package:diff_viewer_contract/review_draft.dart';

class Channel implements AdeleRequestChannel {
  Channel(this.send);
  final Function send;
  Future<Object?> request(String method, Map<String, Object?> payload) {
    final callback = send;
    final Future<String> response = callback(method, jsonEncode(payload));
    return response.then((String wire) => jsonDecode(wire));
  }
}

Map<String, Object?> describe(PendingReviewComment comment) {
  final anchor = comment.anchor;
  var layer = 'unstaged';
  if (anchor.layer == ReviewComparisonLayer.staged) layer = 'staged';
  if (anchor.layer == ReviewComparisonLayer.committed) layer = 'committed';
  final side = anchor.side == ReviewComparisonSide.oldSide ? 'oldSide' : 'newSide';
  return {
    'id': comment.id, 'text': comment.text, 'version': comment.version,
    'sequence': comment.sequence,
    'anchor': {
      'environmentId': anchor.environmentId, 'relativePath': anchor.relativePath,
      'layer': layer, 'side': side,
      'startLine': anchor.startLine, 'endLine': anchor.endLine,
      'comparisonIdentity': anchor.comparisonIdentity, 'sourceExcerpt': anchor.sourceExcerpt,
      'hunkIndex': anchor.hunkIndex, 'lineIndex': anchor.lineIndex,
    },
  };
}

Future<String> run(Function send, String operation, String wire) async {
  final data = jsonDecode(wire);
  final ReviewDraftServiceClient client = ReviewDraftServiceClient(Channel(send));
  if (operation == 'raw') {
    return jsonEncode(await Channel(send).request(data['method'], data['payload']));
  }
  if (operation == 'snapshot') {
    final snapshot = await client.snapshot(data['sessionId']);
    final items = <PendingReviewComment>[];
    items.addAll(snapshot.comments);
    final copy = ReviewDraftSnapshot(sessionId: snapshot.sessionId, comments: items);
    items.clear();
    snapshot.comments.clear();
    copy.comments.clear();
    final descriptions = <Object?>[];
    for (final comment in copy.comments) {
      descriptions.add(describe(comment));
    }
    return jsonEncode({'sessionId': snapshot.sessionId, 'comments': descriptions});
  }
  if (operation == 'create') {
    final value = data['anchor'];
    var layer = ReviewComparisonLayer.unstaged;
    if (value['layer'] == 'staged') layer = ReviewComparisonLayer.staged;
    if (value['layer'] == 'committed') layer = ReviewComparisonLayer.committed;
    var side = ReviewComparisonSide.oldSide;
    if (value['side'] == 'newSide') side = ReviewComparisonSide.newSide;
    final anchor = ReviewCommentAnchor(
      environmentId: value['environmentId'], relativePath: value['relativePath'],
      layer: layer, side: side, startLine: value['startLine'], endLine: value['endLine'],
      comparisonIdentity: value['comparisonIdentity'], sourceExcerpt: value['sourceExcerpt'],
      hunkIndex: value['hunkIndex'], lineIndex: value['lineIndex'],
    );
    return jsonEncode(describe(await client.createComment(data['sessionId'], anchor, data['text'])));
  }
  if (operation == 'update') {
    return jsonEncode(describe(await client.updateComment(data['sessionId'], data['commentId'], data['expectedVersion'], data['text'])));
  }
  await client.deleteComment(data['sessionId'], data['commentId'], data['expectedVersion']);
  return 'null';
}
''';
