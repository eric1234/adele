import 'package:adele_orchestration/adele_orchestration.dart';
import 'package:openai_native_activity/openai_native_activity.dart';
import 'package:test/test.dart';

void main() {
  test('exports the existing native item wire identity', () {
    expect(openAiResponsesItemKind, 'openai.responses.item.v1');
    expect(openAiResponsesItemVersion, 1);
  });

  test(
    'projects ordered nonblank parts without changing Unicode or markup',
    () {
      final OpenAiReasoningSummaryProjection projection =
          projectOpenAiReasoningSummary(
            _envelope(
              summary: <Object?>[
                _part(' \n\t '),
                _part('  Caf\u00e9 \u{1f680} e\u0301 <tag>\nsecond line.  '),
                _part('Later \u65e5\u672c\u8a9e & details.'),
              ],
            ),
          )!;

      expect(
        projection.compactText,
        'Caf\u00e9 \u{1f680} e\u0301 <tag>\nsecond line.',
      );
      expect(projection.data, <String, Object?>{
        'summaryParts': <String>[
          'Caf\u00e9 \u{1f680} e\u0301 <tag>\nsecond line.',
          'Later \u65e5\u672c\u8a9e & details.',
        ],
        'truncated': false,
      });
      expect(projection.summaryParts, same(projection.data['summaryParts']));
      expect(projection.truncated, isFalse);
    },
  );

  for (final (String label, Object? summary) in <(String, Object?)>[
    ('missing', null),
    ('not a list', 'hidden-summary'),
    ('map', <String, Object?>{'text': 'hidden-summary'}),
    ('empty', <Object?>[]),
    ('blank', <Object?>[_part(''), _part(' \n\t ')]),
    ('null part', <Object?>[null]),
    ('non-map part', <Object?>['hidden-summary']),
    (
      'missing type',
      <Object?>[
        <String, Object?>{'text': 'hidden-summary'},
      ],
    ),
    (
      'unknown type',
      <Object?>[
        <String, Object?>{'type': 'text', 'text': 'hidden-summary'},
      ],
    ),
    (
      'missing text',
      <Object?>[
        <String, Object?>{'type': 'summary_text'},
      ],
    ),
    (
      'non-string text',
      <Object?>[
        <String, Object?>{'type': 'summary_text', 'text': 42},
      ],
    ),
    (
      'nested text',
      <Object?>[
        <String, Object?>{
          'type': 'summary_text',
          'text': <String, Object?>{'text': 'hidden-summary'},
        },
      ],
    ),
    ('mixed valid and malformed', <Object?>[_part('Visible.'), _part(null)]),
  ]) {
    test('$label summary fails closed without throwing', () {
      expect(
        projectOpenAiReasoningSummary(_envelope(summary: summary)),
        isNull,
      );
    });
  }

  test(
    'rejects foreign kind, missing or unsupported version and item shape',
    () {
      final Map<String, Object?> reasoning = <String, Object?>{
        'type': 'reasoning',
        'summary': <Object?>[_part('Visible.')],
      };
      for (final ModelNativeEnvelope envelope in <ModelNativeEnvelope>[
        _envelope(kind: 'foreign.native', summary: reasoning['summary']),
        for (final Object? version in <Object?>[null, '1', 1.0, 0, 2])
          _envelope(version: version, summary: reasoning['summary']),
        ModelNativeEnvelope(
          kind: openAiResponsesItemKind,
          compatibility: const <String, Object?>{'version': 1},
          data: const <String, Object?>{},
        ),
        for (final Object? item in <Object?>[
          null,
          'reasoning',
          <Object?>[],
          <String, Object?>{},
        ])
          ModelNativeEnvelope(
            kind: openAiResponsesItemKind,
            compatibility: const <String, Object?>{'version': 1},
            data: <String, Object?>{'item': item},
          ),
        for (final String type in <String>['compaction', 'message', 'unknown'])
          _envelope(type: type, summary: reasoning['summary']),
      ]) {
        expect(projectOpenAiReasoningSummary(envelope), isNull);
      }
    },
  );

  test('hidden text and encrypted state cannot replace a missing summary', () {
    final ModelNativeEnvelope envelope = _envelope(
      summary: <Object?>[],
      extra: <String, Object?>{
        'text': 'HIDDEN-TEXT',
        'content': <Object?>[_part('HIDDEN-CONTENT')],
        'encrypted_content': 'ENCRYPTED-SECRET',
      },
    );
    expect(projectOpenAiReasoningSummary(envelope), isNull);
  });

  test('recursively excludes every unknown key and secret value', () {
    const Set<String> forbiddenKeys = <String>{
      'id',
      'item',
      'type',
      'version',
      'compatibility',
      'encrypted_content',
      'text',
      'content',
      'unknown',
      'account',
    };
    const Set<String> forbiddenValues = <String>{
      'ITEM-SECRET',
      'ENCRYPTED-SECRET',
      'COMPATIBILITY-SECRET',
      'HIDDEN-TEXT',
      'HIDDEN-CONTENT',
      'UNKNOWN-SECRET',
      'ACCOUNT-SECRET',
    };
    final ModelNativeEnvelope envelope = ModelNativeEnvelope(
      kind: openAiResponsesItemKind,
      compatibility: const <String, Object?>{
        'version': 1,
        'unknown': 'COMPATIBILITY-SECRET',
      },
      data: <String, Object?>{
        'account': 'ACCOUNT-SECRET',
        'item': <String, Object?>{
          'type': 'reasoning',
          'id': 'ITEM-SECRET',
          'encrypted_content': 'ENCRYPTED-SECRET',
          'text': 'HIDDEN-TEXT',
          'content': <Object?>[_part('HIDDEN-CONTENT')],
          'summary': <Object?>[
            <String, Object?>{
              ..._part('Safe summary.'),
              'unknown': <String, Object?>{
                'encrypted_content': <String>['UNKNOWN-SECRET'],
              },
            },
          ],
        },
      },
    );
    final OpenAiReasoningSummaryProjection projection =
        projectOpenAiReasoningSummary(envelope)!;

    void check(Object? value) {
      if (value is Map<String, Object?>) {
        for (final MapEntry<String, Object?> entry in value.entries) {
          expect(forbiddenKeys, isNot(contains(entry.key)));
          check(entry.key);
          check(entry.value);
        }
      } else if (value is List<Object?>) {
        for (final Object? item in value) {
          check(item);
        }
      } else if (value is String) {
        for (final String secret in forbiddenValues) {
          expect(value, isNot(contains(secret)));
        }
      } else {
        expect(value, isA<bool>());
      }
    }

    check(projection.data);
    check(projection.compactText);
    expect(
      projection.data.keys,
      unorderedEquals(<String>['summaryParts', 'truncated']),
    );
    expect(projection.summaryParts, <String>['Safe summary.']);
    expect(
      (envelope.data['item']! as Map<String, Object?>)['encrypted_content'],
      'ENCRYPTED-SECRET',
    );
  });

  test('projection data is a detached recursively immutable snapshot', () {
    final Map<String, Object?> part = _part('Original.');
    final List<Object?> summary = <Object?>[part];
    final OpenAiReasoningSummaryProjection projection =
        projectOpenAiReasoningSummary(_envelope(summary: summary))!;
    part['text'] = 'Changed.';
    summary.clear();

    expect(projection.summaryParts, <String>['Original.']);
    expect(() => projection.data['truncated'] = true, throwsUnsupportedError);
    expect(() => projection.data.clear(), throwsUnsupportedError);
    expect(
      () => projection.summaryParts.add('Changed.'),
      throwsUnsupportedError,
    );
    expect(
      () => projection.summaryParts[0] = 'Changed.',
      throwsUnsupportedError,
    );
  });

  for (final int length in <int>[159, 160, 161]) {
    test(
      'compact bound counts $length Unicode code points, not UTF-16 units',
      () {
        final String text = List<String>.filled(length, '\u{1f680}').join();
        final OpenAiReasoningSummaryProjection projection =
            projectOpenAiReasoningSummary(
              _envelope(summary: <Object?>[_part(text)]),
            )!;
        expect(projection.summaryParts, <String>[text]);
        expect(projection.truncated, isFalse);
        expect(
          projection.compactText,
          length <= 160
              ? text
              : '${List<String>.filled(159, '\u{1f680}').join()}\u2026',
        );
        expect(projection.compactText.runes.length, lessThanOrEqualTo(160));
      },
    );
  }

  test(
    'full character bound retains prefix and visible truncation indication',
    () {
      final String text = List<String>.filled(32769, '\u{1f680}').join();
      final OpenAiReasoningSummaryProjection projection =
          projectOpenAiReasoningSummary(
            _envelope(summary: <Object?>[_part(text)]),
          )!;
      expect(projection.summaryParts.single.runes.length, 32768);
      expect(
        projection.summaryParts.single,
        List<String>.filled(32768, '\u{1f680}').join(),
      );
      expect(projection.truncated, isTrue);
      expect(projection.compactText.endsWith('\u2026'), isTrue);
    },
  );

  test('full bound is aggregate and exact-bound content is not truncated', () {
    final String rest = List<String>.filled(32763, 'a').join();
    for (final bool overflow in <bool>[false, true]) {
      final OpenAiReasoningSummaryProjection projection =
          projectOpenAiReasoningSummary(
            _envelope(
              summary: <Object?>[
                _part('First'),
                _part(rest),
                if (overflow) _part('Lost'),
                _part('  '),
              ],
            ),
          )!;
      expect(projection.summaryParts, <String>['First', rest]);
      expect(projection.truncated, overflow);
      expect(projection.compactText, overflow ? 'First\u2026' : 'First');
    }
  });

  test('part bound marks truncation even when compact first part is short', () {
    final List<Object?> summary = <Object?>[
      for (int index = 0; index < 129; index++) _part('Part $index'),
    ];
    final OpenAiReasoningSummaryProjection projection =
        projectOpenAiReasoningSummary(_envelope(summary: summary))!;
    expect(projection.summaryParts, <String>[
      for (int index = 0; index < 128; index++) 'Part $index',
    ]);
    expect(projection.truncated, isTrue);
    expect(projection.compactText, 'Part 0\u2026');
    expect(
      projectOpenAiReasoningSummary(
        _envelope(summary: summary.take(128).toList()),
      )!.truncated,
      isFalse,
    );
  });

  test('malformed suffix fails closed even beyond either full bound', () {
    for (final List<Object?> summary in <List<Object?>>[
      <Object?>[_part(List<String>.filled(32769, 'x').join()), _part(42)],
      <Object?>[
        for (int index = 0; index < 129; index++) _part('Part $index'),
        null,
      ],
    ]) {
      expect(
        projectOpenAiReasoningSummary(_envelope(summary: summary)),
        isNull,
      );
    }
  });

  test('leading whitespace cannot exhaust the visible summary budget', () {
    final OpenAiReasoningSummaryProjection projection =
        projectOpenAiReasoningSummary(
          _envelope(
            summary: <Object?>[
              _part('${List<String>.filled(32769, ' ').join()}Visible.'),
            ],
          ),
        )!;
    expect(projection.summaryParts, <String>['Visible.']);
    expect(projection.compactText, 'Visible.');
    expect(projection.truncated, isFalse);
  });

  for (final String label in <String>[
    'input part count',
    'oversized whitespace suffix',
    'aggregate string size',
    'UTF-16 rather than code point count',
  ]) {
    test('$label over budget declines without throwing or mutation', () {
      final List<Object?> summary = switch (label) {
        'input part count' => <Object?>[
          _part('Visible.'),
          for (int index = 0; index < 1024; index++) _part(''),
        ],
        'oversized whitespace suffix' => <Object?>[
          _part('Visible.'),
          _part(List<String>.filled(262145, ' ').join()),
        ],
        'aggregate string size' => <Object?>[
          _part('Visible.'),
          for (int index = 0; index < 4; index++)
            _part(List<String>.filled(65536, ' ').join()),
        ],
        _ => <Object?>[_part(List<String>.filled(131073, '\u{1f680}').join())],
      };
      final ModelNativeEnvelope envelope = _envelope(
        summary: summary,
        extra: const <String, Object?>{
          'encrypted_content': 'UNCHANGED-ENCRYPTED-STATE',
        },
      );
      final Map<String, Object?> originalData = envelope.data;
      final Map<String, Object?> originalCompatibility = envelope.compatibility;
      OpenAiReasoningSummaryProjection? result;

      expect(
        () => result = projectOpenAiReasoningSummary(envelope),
        returnsNormally,
      );
      expect(result, isNull);
      expect(envelope.data, same(originalData));
      expect(envelope.compatibility, same(originalCompatibility));
      expect(envelope.kind, openAiResponsesItemKind);
      expect(envelope.data, <String, Object?>{
        'item': <String, Object?>{
          'type': 'reasoning',
          'summary': summary,
          'encrypted_content': 'UNCHANGED-ENCRYPTED-STATE',
        },
      });
    });
  }

  test(
    'exact input part limit remains eligible with unchanged display caps',
    () {
      final OpenAiReasoningSummaryProjection projection =
          projectOpenAiReasoningSummary(
            _envelope(
              summary: <Object?>[
                for (int index = 0; index < 1024; index++) _part('Part $index'),
              ],
            ),
          )!;
      expect(projection.summaryParts, <String>[
        for (int index = 0; index < 128; index++) 'Part $index',
      ]);
      expect(projection.truncated, isTrue);
      expect(projection.compactText, 'Part 0\u2026');
    },
  );

  test('exact aggregate input size remains eligible including whitespace', () {
    const String visible = 'Visible.';
    final OpenAiReasoningSummaryProjection projection =
        projectOpenAiReasoningSummary(
          _envelope(
            summary: <Object?>[
              _part(visible),
              _part(List<String>.filled(131072, ' ').join()),
              _part(List<String>.filled(131072 - visible.length, ' ').join()),
            ],
          ),
        )!;
    expect(projection.summaryParts, <String>[visible]);
    expect(projection.compactText, visible);
    expect(projection.truncated, isFalse);
  });

  test('exact UTF-16 input limit retains unchanged full code point cap', () {
    final OpenAiReasoningSummaryProjection projection =
        projectOpenAiReasoningSummary(
          _envelope(
            summary: <Object?>[
              _part(List<String>.filled(131072, '\u{1f680}').join()),
            ],
          ),
        )!;
    expect(projection.summaryParts.single.runes.length, 32768);
    expect(projection.compactText.runes.length, 160);
    expect(projection.compactText.endsWith('\u2026'), isTrue);
    expect(projection.truncated, isTrue);
  });

  test(
    'validates the final input part within budget after display truncation',
    () {
      expect(
        projectOpenAiReasoningSummary(
          _envelope(
            summary: <Object?>[
              for (int index = 0; index < 1023; index++) _part('Part $index'),
              _part(42),
            ],
          ),
        ),
        isNull,
      );
    },
  );
}

Map<String, Object?> _part(Object? text) => <String, Object?>{
  'type': 'summary_text',
  'text': text,
};

ModelNativeEnvelope _envelope({
  required Object? summary,
  String kind = openAiResponsesItemKind,
  Object? version = openAiResponsesItemVersion,
  String type = 'reasoning',
  Map<String, Object?> extra = const <String, Object?>{},
}) => ModelNativeEnvelope(
  kind: kind,
  compatibility: <String, Object?>{'version': version},
  data: <String, Object?>{
    'item': <String, Object?>{'type': type, 'summary': summary, ...extra},
  },
);
