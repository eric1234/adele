import 'dart:convert';

import 'package:adele_contract/adele_contract.dart';
import 'package:adele_orchestration/adele_orchestration.dart';
import 'package:test/test.dart';

void main() {
  test('canonical JSON includes every field in a fixed order', () {
    final submission = _submission();
    const expected =
        '{"submissionId":"submission","kind":"codeReview","comments":['
        '{"id":"comment","anchor":{"environmentId":"environment",'
        '"relativePath":"lib/file.dart","layer":"unstaged","side":"newSide",'
        '"startLine":2,"endLine":3,"comparisonIdentity":"comparison",'
        '"sourceExcerpt":"old\\r\\nnew","hunkIndex":0,"lineIndex":1},'
        '"text":"  review\\r\\ntext  ","version":1,"sequence":1}]}';
    expect(encodeSessionFeedbackSubmission(submission), expected);
    final restored = decodeSessionFeedbackSubmission(expected);
    expect(encodeSessionFeedbackSubmission(restored), expected);
    expect(restored, isNot(same(submission)));
    expect(restored.comments.single.anchor.sourceExcerpt, 'old\r\nnew');
    expect(restored.comments.single.text, '  review\r\ntext  ');
    expect(() => restored.comments.clear(), throwsUnsupportedError);
  });

  test(
    'comments are copied and retain same-line identity and creation gaps',
    () {
      final first = _comment();
      final second = _comment(id: 'second', sequence: 9, version: 2);
      final comments = [first, second];
      final submission = _submission(comments: comments);
      comments.clear();
      expect(submission.comments, [first, second]);
      expect(() => submission.comments.add(first), throwsUnsupportedError);
      expect(() => submission.comments[0] = second, throwsUnsupportedError);
      for (final invalid in <List<SessionFeedbackComment>>[
        [],
        [first, _comment(sequence: 2)],
        [first, _comment(id: 'second')],
        [second, first],
        List.generate(129, (i) => _comment(id: 'c$i', sequence: i + 1)),
      ]) {
        expect(() => _submission(comments: invalid), _fails());
      }
      expect(
        _submission(
          comments: List.generate(
            128,
            (i) => _comment(id: 'c$i', sequence: i + 1),
          ),
        ).comments,
        hasLength(128),
      );
    },
  );

  test('all identities share exact bounded Unicode validation', () {
    for (final value in [
      '',
      ' ',
      ' secret',
      'secret ',
      'secret\u0000',
      'secret\n',
      'secret\u007f',
      'secret\u0085',
      'secret\u009f',
      'x' * 257,
      '\ud800',
      '\udfff',
    ]) {
      for (final create in <Object? Function()>[
        () => validateSessionFeedbackIdentity(value),
        () => _submission(submissionId: value),
        () => _comment(id: value),
        () => _anchor(environmentId: value),
        () => _receipt(submissionId: value),
        () => _receipt(sessionId: value),
        () => _receipt(occurrenceId: value),
      ]) {
        expect(create, _fails());
      }
    }
    for (final value in ['x' * 256, '\u{1f680}' * 128, 'e\u0301', '\u00e9']) {
      expect(_submission(submissionId: value).submissionId, value);
      expect(_receipt(occurrenceId: value).occurrenceId, value);
    }
  });

  test('paths retain G7a1 confinement and exact characters', () {
    for (final path in [
      '',
      '/absolute',
      'a//b',
      'a/',
      '.',
      '..',
      './a',
      'a/../b',
      'a/./b',
      '.git',
      'a/.git/config',
      'a\\b',
      'C:file',
      'C:/file',
      'a\u0000b',
      'x' * 4097,
      '\ud800',
    ]) {
      expect(() => _anchor(relativePath: path), _fails());
    }
    for (final path in [
      'x' * 4096,
      'lib/\u4e2d\u{1f680}.dart',
      ' space/quotes"\t\n ',
      'a/.gitignore',
    ]) {
      expect(_anchor(relativePath: path).relativePath, path);
    }
  });

  test('comparison identity is nonblank bounded printable ASCII', () {
    for (final value in ['', ' ', 'x' * 257, 'a\n', '\u007f', '\u00e9']) {
      expect(() => _anchor(comparisonIdentity: value), _fails());
    }
    for (final value in ['x' * 256, ' comparison with spaces ', '~!"\\']) {
      expect(_anchor(comparisonIdentity: value).comparisonIdentity, value);
    }
  });

  test(
    'text and excerpts preserve Unicode, CRLF and missing final newline',
    () {
      for (final text in [
        'x' * 8192,
        '\u{1f680}' * 4096,
        ' \r\n\u4e2d\u00e9\u{1f680}\u0000\t ',
        'no final newline',
      ]) {
        expect(_comment(text: text).text, text);
      }
      for (final text in ['', ' \r\n\t', 'x' * 8193, '\ud800', '\udfff']) {
        expect(() => _comment(text: text), _fails());
      }
      for (final excerpt in [
        '',
        'x' * 4096,
        '\u{1f680}' * 2048,
        'a\r\nb',
        'a\r\nb\r\n',
        '\u0000\u4e2d\t',
      ]) {
        expect(_anchor(sourceExcerpt: excerpt).sourceExcerpt, excerpt);
      }
      for (final excerpt in ['x' * 4097, '\ud800', '\udfff']) {
        expect(() => _anchor(sourceExcerpt: excerpt), _fails());
      }
    },
  );

  test(
    'line ranges, display coordinates, versions and sequences are bounded',
    () {
      for (final range in [(0, 1), (2, 1), (1, 1001), (1, 2147483648)]) {
        expect(() => _anchor(startLine: range.$1, endLine: range.$2), _fails());
      }
      for (final range in [(1, 1), (1, 1000), (2147483647, 2147483647)]) {
        final anchor = _anchor(startLine: range.$1, endLine: range.$2);
        expect((anchor.startLine, anchor.endLine), range);
      }
      for (final index in [-1, 8192]) {
        expect(() => _anchor(hunkIndex: index), _fails());
      }
      for (final index in [-1, 65536]) {
        expect(() => _anchor(lineIndex: index), _fails());
      }
      expect(_anchor(hunkIndex: 8191, lineIndex: 65535).lineIndex, 65535);
      for (final value in [-1, 0, 2147483648]) {
        expect(() => _comment(version: value), _fails());
        expect(() => _comment(sequence: value), _fails());
      }
      final comment = _comment(version: 2147483647, sequence: 2147483647);
      expect(_submission(comments: [comment]).comments.single, same(comment));
    },
  );

  test('receipts and records validate exact submission identity', () {
    final submission = _submission();
    final receipt = _receipt();
    final record = SessionFeedbackRecord(
      receipt: receipt,
      submission: submission,
    );
    expect(record.receipt, same(receipt));
    expect(record.submission, same(submission));
    expect(
      () => SessionFeedbackRecord(
        receipt: _receipt(submissionId: 'other'),
        submission: submission,
      ),
      _fails(),
    );
  });

  test('canonical equality distinguishes every exact payload field', () {
    final canonical = encodeSessionFeedbackSubmission(_submission());
    final changes = <void Function(Map<String, dynamic>)>[
      (data) => data['submissionId'] = 'other',
      (data) => _commentData(data)['id'] = 'other',
      (data) => _commentData(data)['text'] = 'review\r\ntext',
      (data) => _commentData(data)['text'] = '  review\ntext  ',
      (data) => _commentData(data)['version'] = 2,
      (data) => _commentData(data)['sequence'] = 2,
      (data) => _anchorData(data)['environmentId'] = 'other',
      (data) => _anchorData(data)['relativePath'] = 'lib/other.dart',
      (data) => _anchorData(data)['layer'] = 'staged',
      (data) => _anchorData(data)['side'] = 'oldSide',
      (data) => _anchorData(data)['startLine'] = 1,
      (data) => _anchorData(data)['endLine'] = 4,
      (data) => _anchorData(data)['comparisonIdentity'] = 'other',
      (data) => _anchorData(data)['sourceExcerpt'] = 'old\nnew',
      (data) => _anchorData(data)['sourceExcerpt'] = 'old\r\nnew\r\n',
      (data) => _anchorData(data)['hunkIndex'] = 1,
      (data) => _anchorData(data)['lineIndex'] = 0,
    ];
    final encodings = <String>{canonical};
    for (final change in changes) {
      final data = _data();
      change(data);
      final changed = decodeSessionFeedbackSubmission(jsonEncode(data));
      expect(encodings.add(encodeSessionFeedbackSubmission(changed)), isTrue);
    }
    final first = _submission(
      comments: [
        _comment(),
        _comment(id: 'second', sequence: 2),
      ],
    );
    final reversed = _submission(
      comments: [
        _comment(id: 'second'),
        _comment(sequence: 2),
      ],
    );
    expect(
      encodeSessionFeedbackSubmission(first),
      isNot(encodeSessionFeedbackSubmission(reversed)),
    );
    expect(
      encodeSessionFeedbackSubmission(_submission(submissionId: '\u00e9')),
      isNot(
        encodeSessionFeedbackSubmission(_submission(submissionId: 'e\u0301')),
      ),
    );
  });

  test('reload rejects malformed JSON, schema, enums and value invariants', () {
    for (final encoded in [
      '',
      '{',
      '{"private-content":',
      '${encodeSessionFeedbackSubmission(_submission())} trailing',
      '\ud800',
      ..._invalidPayloads().map(jsonEncode),
    ]) {
      expect(() => decodeSessionFeedbackSubmission(encoded), _fails());
    }
    expect(
      () => decodeSessionFeedbackSubmission(' ' * (128 * 1024 + 1)),
      _fails('submission_too_large'),
    );
    final data = _data();
    final reordered = Map<String, dynamic>.fromEntries(
      data.entries.toList().reversed,
    );
    expect(
      encodeSessionFeedbackSubmission(
        decodeSessionFeedbackSubmission(' \n${jsonEncode(reordered)}\n'),
      ),
      encodeSessionFeedbackSubmission(_submission()),
    );
  });

  test('canonical UTF8 limit is inclusive and counts JSON escaping', () {
    expect(SessionFeedbackLimits.maxSubmissionBytes, 128 * 1024);
    expect(SessionFeedbackLimits.maxModelContentBytes, 144 * 1024);
    for (final unit in ['a', '\\', '"', '\u0001', '\u4e2d', '\u{1f680}']) {
      final submission = _atByteLimit(unit);
      final encoded = encodeSessionFeedbackSubmission(submission);
      expect(utf8.encode(encoded), hasLength(128 * 1024));
      expect(
        encodeSessionFeedbackSubmission(
          decodeSessionFeedbackSubmission(encoded),
        ),
        encoded,
      );
      expect(
        () => _atByteLimit(unit, extraBytes: 1),
        _fails('submission_too_large'),
      );

      final modelContent = 'Code review feedback\n$encoded';
      expect(
        utf8.encode(modelContent).length,
        lessThan(SessionFeedbackLimits.maxModelContentBytes),
      );
      final response = {
        'kind': 'response',
        'requestId': 1,
        'ok': true,
        'payload': {
          'rows': [
            {
              'values': [
                'session',
                'submission',
                'occurrence',
                encoded,
                modelContent,
              ],
            },
          ],
        },
      };
      expect(utf8.encode(jsonEncode(response)).length, lessThan(1024 * 1024));
      expect(
        utf8.encode(jsonEncode(jsonEncode(response))).length,
        lessThan(1024 * 1024),
      );
    }
  });

  test(
    'native generated transport preserves all layers, sides and exact data',
    () async {
      final service = _Service();
      final dispatcher = RemoteSessionFeedbackServiceDispatcher(service);
      addTearDown(dispatcher.close);
      final channel = _Channel(dispatcher);
      final client = RemoteSessionFeedbackServiceClient(channel);
      final comments = <SessionFeedbackComment>[];
      for (final layer in SessionFeedbackComparisonLayer.values) {
        for (final side in SessionFeedbackComparisonSide.values) {
          comments.add(
            _comment(
              id: 'c${comments.length}',
              sequence: comments.length * 3 + 1,
              version: comments.length + 1,
              text: ' \u4e2d\u{1f680}\r\nreview\t ',
              anchor: _anchor(
                relativePath: 'lib/\u4e2d.dart',
                layer: layer,
                side: side,
                startLine: 1,
                endLine: 1000,
                sourceExcerpt: '\t\u00e9\r\nno final newline',
                hunkIndex: 8191,
                lineIndex: 65535,
              ),
            ),
          );
        }
      }
      final submission = _submission(comments: comments);
      final receipt = await client.accept('route', 'session', submission);
      expect(remoteSessionFeedbackServiceId, 'dev.adele.session.feedback');
      expect(channel.method, 'dev.adele.session.feedback.accept');
      expect(channel.payload, {
        'routeId': 'route',
        'sessionId': 'session',
        'submission': jsonDecode(encodeSessionFeedbackSubmission(submission)),
      });
      expect(service.invocation, ('route', 'session', 'submission'));
      expect(service.record!.submission, isNot(same(submission)));
      expect(
        service.record!.submission.comments.first,
        isNot(same(comments.first)),
      );
      expect(
        () => service.record!.submission.comments.clear(),
        throwsUnsupportedError,
      );
      expect(receipt.submissionId, 'submission');
      expect(receipt.sessionId, 'session');
      expect(receipt.occurrenceId, 'occurrence');

      final record = (await client.lookup('route', 'session', 'submission'))!;
      expect(channel.method, 'dev.adele.session.feedback.lookup');
      expect(channel.payload, {
        'routeId': 'route',
        'sessionId': 'session',
        'submissionId': 'submission',
      });
      expect(record.receipt.occurrenceId, receipt.occurrenceId);
      expect(
        encodeSessionFeedbackSubmission(record.submission),
        encodeSessionFeedbackSubmission(submission),
      );
      expect(record.receipt, isNot(same(service.record!.receipt)));
      expect(await client.lookup('route', 'session', 'absent'), isNull);
    },
  );

  test(
    'maximum canonical submission crosses native client and dispatcher',
    () async {
      final service = _Service();
      final dispatcher = RemoteSessionFeedbackServiceDispatcher(service);
      addTearDown(dispatcher.close);
      final channel = _Channel(dispatcher);
      final client = RemoteSessionFeedbackServiceClient(channel);
      final submission = _atByteLimit('"');
      await client.accept('route', 'session', submission);
      final record = (await client.lookup('route', 'session', 'submission'))!;
      expect(
        encodeSessionFeedbackSubmission(record.submission),
        encodeSessionFeedbackSubmission(submission),
      );
      expect(
        utf8.encode(jsonEncode(jsonEncode(channel.response))).length,
        lessThan(1024 * 1024),
      );
    },
  );

  test(
    'generated decoder rejects malformed submissions before invocation',
    () async {
      final service = _Service();
      final dispatcher = RemoteSessionFeedbackServiceDispatcher(service);
      addTearDown(dispatcher.close);
      final oversized = _data();
      oversized['comments'] = List.generate(32, (index) {
        final comment = _commentData(_data());
        comment['id'] = 'c$index';
        comment['sequence'] = index + 1;
        comment['text'] = 'x' * 8192;
        return comment;
      });
      for (final payload in [..._invalidPayloads(), oversized]) {
        final response = await dispatcher.dispatch({
          'kind': 'request',
          'requestId': 1,
          'method': remoteSessionFeedbackServiceAcceptId,
          'payload': {
            'routeId': 'route',
            'sessionId': 'session',
            'submission': payload,
          },
        });
        final error = response['error']! as Map;
        expect(error['code'], 'invalid_request');
        expect(error['message'], isNot(contains('private-content')));
      }
      expect(service.invocation, isNull);
      expect(service.record, isNull);
    },
  );

  test(
    'generated response decoder rejects corrupt receipts and records',
    () async {
      for (final receipt in [
        {
          'submissionId': '',
          'sessionId': 'session',
          'occurrenceId': 'occurrence',
        },
        {
          'submissionId': 'submission',
          'sessionId': 'session',
          'occurrenceId': 1,
        },
        {'submissionId': 'submission', 'sessionId': 'session'},
        {
          'submissionId': 'submission',
          'sessionId': 'session',
          'occurrenceId': 'occurrence',
          'accepted': true,
        },
      ]) {
        final client = RemoteSessionFeedbackServiceClient(
          _ResponseChannel(receipt),
        );
        await expectLater(
          client.accept('route', 'session', _submission()),
          throwsA(isA<AdeleProtocolException>()),
        );
      }
      final client = RemoteSessionFeedbackServiceClient(
        _ResponseChannel({
          'receipt': {
            'submissionId': 'other',
            'sessionId': 'session',
            'occurrenceId': 'occurrence',
          },
          'submission': _data(),
        }),
      );
      await expectLater(
        client.lookup('route', 'session', 'submission'),
        throwsA(isA<AdeleProtocolException>()),
      );
    },
  );

  test(
    'typed target failures roundtrip without becoming success or absence',
    () async {
      final service = _Service();
      final dispatcher = RemoteSessionFeedbackServiceDispatcher(service);
      addTearDown(dispatcher.close);
      final client = RemoteSessionFeedbackServiceClient(_Channel(dispatcher));
      for (final code in [
        'invalid_submission',
        'submission_too_large',
        'submission_conflict',
        'session_busy',
        'stale_target',
        'storage_failure',
        'outcome_uncertain',
      ]) {
        service.failure = SessionFeedbackFailure(
          code: code,
          message: 'Feedback is unavailable.',
          details: const {'retryable': false},
        );
        final matcher = throwsA(
          isA<SessionFeedbackFailure>()
              .having((error) => error.code, 'code', code)
              .having(
                (error) => error.message,
                'message',
                'Feedback is unavailable.',
              )
              .having((error) => error.details, 'details', {
                'retryable': false,
              }),
        );
        await expectLater(
          client.accept('route', 'session', _submission()),
          matcher,
        );
        await expectLater(
          client.lookup('route', 'session', 'submission'),
          matcher,
        );
      }
      service.failure = StateError('private-content');
      await expectLater(
        client.accept('route', 'session', _submission()),
        throwsA(
          isA<AdeleRemoteFailure>()
              .having((error) => error.code, 'code', 'internal_error')
              .having(
                (error) => error.message,
                'message',
                isNot(contains('private-content')),
              ),
        ),
      );
    },
  );
}

Matcher _fails([String code = 'invalid_submission']) => throwsA(
  isA<SessionFeedbackFailure>()
      .having((error) => error.code, 'code', code)
      .having((error) => error.details, 'details', isEmpty)
      .having(
        (error) => error.message,
        'message',
        code == 'submission_too_large'
            ? 'Session feedback exceeds its payload limit.'
            : 'Invalid Session feedback data.',
      ),
);

SessionFeedbackSubmission _submission({
  String submissionId = 'submission',
  List<SessionFeedbackComment>? comments,
}) => SessionFeedbackSubmission(
  submissionId: submissionId,
  kind: SessionFeedbackKind.codeReview,
  comments: comments ?? [_comment()],
);

SessionFeedbackComment _comment({
  String id = 'comment',
  SessionFeedbackAnchor? anchor,
  String text = '  review\r\ntext  ',
  int version = 1,
  int sequence = 1,
}) => SessionFeedbackComment(
  id: id,
  anchor: anchor ?? _anchor(),
  text: text,
  version: version,
  sequence: sequence,
);

SessionFeedbackAnchor _anchor({
  String environmentId = 'environment',
  String relativePath = 'lib/file.dart',
  SessionFeedbackComparisonLayer layer =
      SessionFeedbackComparisonLayer.unstaged,
  SessionFeedbackComparisonSide side = SessionFeedbackComparisonSide.newSide,
  int startLine = 2,
  int endLine = 3,
  String comparisonIdentity = 'comparison',
  String sourceExcerpt = 'old\r\nnew',
  int hunkIndex = 0,
  int lineIndex = 1,
}) => SessionFeedbackAnchor(
  environmentId: environmentId,
  relativePath: relativePath,
  layer: layer,
  side: side,
  startLine: startLine,
  endLine: endLine,
  comparisonIdentity: comparisonIdentity,
  sourceExcerpt: sourceExcerpt,
  hunkIndex: hunkIndex,
  lineIndex: lineIndex,
);

SessionFeedbackReceipt _receipt({
  String submissionId = 'submission',
  String sessionId = 'session',
  String occurrenceId = 'occurrence',
}) => SessionFeedbackReceipt(
  submissionId: submissionId,
  sessionId: sessionId,
  occurrenceId: occurrenceId,
);

Map<String, dynamic> _data() =>
    jsonDecode(encodeSessionFeedbackSubmission(_submission()))
        as Map<String, dynamic>;

Map<String, dynamic> _commentData(Map<String, dynamic> data) =>
    (data['comments'] as List).first as Map<String, dynamic>;

Map<String, dynamic> _anchorData(Map<String, dynamic> data) =>
    _commentData(data)['anchor'] as Map<String, dynamic>;

Iterable<Object?> _invalidPayloads() sync* {
  yield null;
  yield [];
  yield 'private-content';
  yield 1;
  final changes = <void Function(Map<String, dynamic>)>[
    (data) => data.remove('submissionId'),
    (data) => data['submissionId'] = null,
    (data) => data['sessionId'] = 'not-a-public-selector',
    (data) => data['kind'] = 'unknown',
    (data) => data['kind'] = 0,
    (data) => data['comments'] = null,
    (data) => data['comments'] = <Object?>[],
    (data) => data['comments'] = [null],
    (data) => _commentData(data).remove('version'),
    (data) => _commentData(data)['unknown'] = true,
    (data) => _commentData(data)['id'] = '',
    (data) => _commentData(data)['text'] = 1,
    (data) => _commentData(data)['text'] = ' ',
    (data) => _commentData(data)['text'] = '\ud800',
    (data) => _commentData(data)['version'] = 1.0,
    (data) => _commentData(data)['version'] = 0,
    (data) => _commentData(data)['sequence'] = true,
    (data) => _commentData(data)['sequence'] = 0,
    (data) => _anchorData(data).remove('sourceExcerpt'),
    (data) => _anchorData(data)['unknown'] = false,
    (data) => _anchorData(data)['layer'] = 'combined',
    (data) => _anchorData(data)['side'] = 'both',
    (data) => _anchorData(data)['startLine'] = '1',
    (data) => _anchorData(data)['endLine'] = 0,
    (data) => _anchorData(data)['relativePath'] = '../private-content',
    (data) => _anchorData(data)['comparisonIdentity'] = '\u4e2d',
    (data) => _anchorData(data)['sourceExcerpt'] = 'x' * 4097,
    (data) => _anchorData(data)['hunkIndex'] = -1,
    (data) => _anchorData(data)['lineIndex'] = 65536,
    (data) => (data['comments'] as List).add(_commentData(_data())),
  ];
  for (final change in changes) {
    final data = _data();
    change(data);
    yield data;
  }
}

SessionFeedbackSubmission _atByteLimit(String unit, {int extraBytes = 0}) {
  final comments = List.generate(
    32,
    (i) => _comment(id: 'c$i', sequence: i + 1, text: 'a'),
  );
  final base = encodeSessionFeedbackSubmission(_submission(comments: comments));
  var remaining =
      SessionFeedbackLimits.maxSubmissionBytes +
      extraBytes -
      utf8.encode(base).length;
  final unitBytes = utf8.encode(jsonEncode(unit)).length - 2;
  for (var index = 0; index < comments.length; index++) {
    final capacity = (SessionFeedbackLimits.maxTextLength - 1) ~/ unit.length;
    final requested = remaining ~/ unitBytes;
    final count = requested < capacity ? requested : capacity;
    remaining -= count * unitBytes;
    final asciiCapacity =
        SessionFeedbackLimits.maxTextLength - 1 - count * unit.length;
    final asciiCount = remaining < asciiCapacity ? remaining : asciiCapacity;
    remaining -= asciiCount;
    comments[index] = _comment(
      id: 'c$index',
      sequence: index + 1,
      text: 'a${unit * count}${'a' * asciiCount}',
    );
  }
  expect(remaining, 0);
  return _submission(comments: comments);
}

final class _Service implements RemoteSessionFeedbackService {
  SessionFeedbackRecord? record;
  (String, String, String)? invocation;
  Object? failure;

  @override
  Future<SessionFeedbackReceipt> accept(
    String routeId,
    String sessionId,
    SessionFeedbackSubmission submission,
  ) async {
    if (failure case final error?) throw error;
    invocation = (routeId, sessionId, submission.submissionId);
    final receipt = _receipt(
      submissionId: submission.submissionId,
      sessionId: sessionId,
    );
    record = SessionFeedbackRecord(receipt: receipt, submission: submission);
    return receipt;
  }

  @override
  Future<SessionFeedbackRecord?> lookup(
    String routeId,
    String sessionId,
    String submissionId,
  ) async {
    if (failure case final error?) throw error;
    invocation = (routeId, sessionId, submissionId);
    return record?.submission.submissionId == submissionId ? record : null;
  }
}

final class _Channel implements AdeleRequestChannel {
  _Channel(this.dispatcher);
  final AdeleBackendDispatcher dispatcher;
  String? method;
  Map<String, Object?>? payload;
  Map<String, Object?>? response;

  @override
  Future<Object?> request(String method, Map<String, Object?> payload) async {
    this.method = method;
    this.payload = payload;
    final response = await dispatcher.dispatch({
      'kind': 'request',
      'requestId': 1,
      'method': method,
      'payload': payload,
    });
    this.response = response;
    if (response['ok'] != true) {
      throw _RemoteFailure(response['error']! as Map<Object?, Object?>);
    }
    return response['payload'];
  }
}

final class _ResponseChannel implements AdeleRequestChannel {
  const _ResponseChannel(this.response);
  final Object? response;

  @override
  Future<Object?> request(String method, Map<String, Object?> payload) async =>
      response;
}

final class _RemoteFailure implements AdeleRemoteFailure {
  const _RemoteFailure(this.error);
  final Map<Object?, Object?> error;

  @override
  String? get declaredFailureType => error['declaredFailureType'] as String?;
  @override
  String get code => error['code']! as String;
  @override
  String get message => error['message']! as String;
  @override
  Map<String, Object?> get details =>
      Map<String, Object?>.from(error['details']! as Map);
}
