import 'dart:convert';

import 'package:adele_plugin_backend_support/adele_plugin_backend_support.dart';
import 'package:test/test.dart';

Map<String, Object?> _record({
  String collection = 'providers',
  String id = 'work',
  String type = 'dev.adele.fixture.provider',
  Object? values = const <String, Object>{},
}) => {'collection': collection, 'type': type, 'id': id, 'values': values};

void main() {
  test('every entry path captures deeply immutable nonsecret values', () {
    final values = <String, Object>{
      'enabled': false,
      'count': 0,
      'name': '',
      'minimum': -9223372036854775808,
      'maximum': 9223372036854775807,
      'wide-integer': 9007199254740993,
    };
    final record = _record(values: values);
    final source = [record];
    final bootstrap = <String, Object?>{
      'records': source,
      'settings': {'independent': true},
      'unrelated': Object(),
    };
    final expected = jsonDecode(jsonEncode(source));
    final copies = [
      adeleCopyBackendRecords(source),
      AdeleBackendRecords(source).records,
      AdeleBackendRecords.fromBootstrap(bootstrap).records,
    ];
    values.clear();
    record['id'] = 'changed';
    source.clear();
    bootstrap.clear();
    for (final copy in copies) {
      expect(copy, expected);
      expect(copy.clear, throwsUnsupportedError);
      expect(
        () => copy.add(_record().cast<String, Object>()),
        throwsUnsupportedError,
      );
      expect(() => copy.single['id'] = 'changed', throwsUnsupportedError);
      expect(copy.single.clear, throwsUnsupportedError);
      final fields = copy.single['values'] as Map<String, Object>;
      expect(fields.clear, throwsUnsupportedError);
      expect(() => fields['count'] = 9, throwsUnsupportedError);
    }
  });

  test('requires explicit list and preserves explicit empty', () {
    for (final bootstrap in <Object?>[
      null,
      [],
      true,
      {},
      {'records': null},
      {'records': <String, Object>{}},
      {'records': false},
    ]) {
      expect(
        () => AdeleBackendRecords.fromBootstrap(bootstrap),
        throwsFormatException,
      );
    }
    expect(
      AdeleBackendRecords.fromBootstrap({'records': <Object?>[]}).records,
      isEmpty,
    );
    expect(AdeleBackendRecords([]).records, isEmpty);
  });

  test('entries have exactly collection, type, id and values', () {
    for (final entry in <Object?>[
      null,
      false,
      [],
      'private-input',
      for (final key in ['collection', 'type', 'id', 'values'])
        {..._record()}..remove(key),
      for (final key in [
        'unknown',
        'credentials',
        'references',
        'document',
        'root',
        'handle',
        'authorization',
      ])
        {..._record(), key: 'private-input'},
      {..._record(), 1: true},
      _record(values: null),
      _record(values: []),
    ]) {
      expect(() => adeleCopyBackendRecords([entry]), throwsFormatException);
    }
  });

  test(
    'uses exact R1 identities without normalization or portable aliases',
    () {
      for (final id in [
        '',
        'Work',
        ' work',
        'work ',
        'work\n',
        '../work',
        'a.b',
        'a_b',
        '-a',
        'a-',
        'a--b',
        '1a',
        'a' * 65,
        'con',
        'prn',
        'aux',
        'nul',
        'com1',
        'lpt9',
      ]) {
        expect(
          () => adeleCopyBackendRecords([_record(id: id)]),
          throwsFormatException,
        );
        expect(
          () => adeleCopyBackendRecords([_record(collection: id)]),
          throwsFormatException,
        );
      }
      for (final type in [
        '',
        'one',
        'Dev.adele',
        'dev.adele.',
        'dev..adele',
        'dev.adele\n',
        'dev.${'a' * 253}',
      ]) {
        expect(
          () => adeleCopyBackendRecords([_record(type: type)]),
          throwsFormatException,
        );
      }
      for (final key in <Object?>[null, 1, '', 'Bad', 'a.b', 'a' * 65]) {
        expect(
          () => adeleCopyBackendRecords([
            _record(values: {key: true}),
          ]),
          throwsFormatException,
        );
      }
      final valid = _record(
        collection: 'a' * 64,
        id: 'com10',
        type: 'dev.${'a' * 252}',
        values: {'con': '', 'a' * 64: true},
      );
      expect(adeleCopyBackendRecords([valid]), [valid]);
    },
  );

  test(
    'rejects collection/id duplicates across types, not across collections',
    () {
      for (final type in [
        'dev.adele.fixture.provider',
        'dev.adele.other.provider',
      ]) {
        expect(
          () => adeleCopyBackendRecords([_record(), _record(type: type)]),
          throwsFormatException,
        );
      }
      expect(
        adeleCopyBackendRecords([
          _record(),
          _record(collection: 'connections'),
          _record(id: 'personal'),
        ]),
        hasLength(3),
      );
    },
  );

  test('rejects null, double, nested values and objects without coercion', () {
    for (final value in <Object?>[
      null,
      0.0,
      double.nan,
      double.infinity,
      BigInt.one,
      [],
      {},
      Object(),
    ]) {
      final source = [
        _record(values: {'field': value}),
      ];
      expect(() => adeleCopyBackendRecords(source), throwsFormatException);
      expect(() => AdeleBackendRecords(source), throwsFormatException);
      expect(
        () => AdeleBackendRecords.fromBootstrap({'records': source}),
        throwsFormatException,
      );
    }
  });

  test('bounds count, fields and string lengths independently', () {
    final records = [
      for (var i = 0; i < AdeleBackendRecords.maxRecords; i++)
        _record(id: 'record-$i'),
    ];
    expect(
      adeleCopyBackendRecords(records),
      hasLength(AdeleBackendRecords.maxRecords),
    );
    expect(
      () => adeleCopyBackendRecords([...records, _record(id: 'extra')]),
      throwsFormatException,
    );
    final values = <String, Object>{
      for (var i = 0; i < AdeleBackendRecords.maxFields; i++) 'field-$i': false,
    };
    expect(adeleCopyBackendRecords([_record(values: values)]), hasLength(1));
    values['extra'] = true;
    expect(
      () => adeleCopyBackendRecords([_record(values: values)]),
      throwsFormatException,
    );
    final text = 'x' * AdeleBackendRecords.maxStringLength;
    expect(
      adeleCopyBackendRecords([
        _record(values: {'text': text}),
      ]),
      hasLength(1),
    );
    expect(
      () => adeleCopyBackendRecords([
        _record(values: {'text': '${text}x'}),
      ]),
      throwsFormatException,
    );
  });

  test(
    'bounds exact total encoded JSON bytes including escaping and UTF-8',
    () {
      for (final character in ['x', '\u0000', '\u20ac']) {
        final values = <String, Object>{
          for (var i = 0; i < 15; i++)
            'field-$i': character * (AdeleBackendRecords.maxStringLength ~/ 6),
          'padding': '',
        };
        final records = [_record(values: values)];
        // Fill most of the budget, retaining a final bounded padding field.
        while (utf8.encode(jsonEncode(records)).length <
            AdeleBackendRecords.maxJsonBytes -
                AdeleBackendRecords.maxStringLength) {
          values['field-${values.length}'] =
              'x' * (AdeleBackendRecords.maxStringLength ~/ 2);
        }
        values['padding'] =
            'x' *
            (AdeleBackendRecords.maxJsonBytes -
                utf8.encode(jsonEncode(records)).length);
        expect(
          utf8.encode(jsonEncode(records)),
          hasLength(AdeleBackendRecords.maxJsonBytes),
        );
        expect(adeleCopyBackendRecords(records), records);
        values['padding'] = '${values['padding']}x';
        expect(() => adeleCopyBackendRecords(records), throwsFormatException);
      }
    },
  );

  test('failures contain only fixed bounded messages, never input data', () {
    const marker = 'private-input-do-not-echo';
    for (final records in <Object?>[
      marker,
      [
        {..._record(), 'credentials': marker},
      ],
      [_record(id: '$marker/invalid')],
      [
        _record(values: {'$marker/invalid': marker}),
      ],
      [
        _record(
          values: {
            'field': [marker],
          },
        ),
      ],
      [
        _record(values: {'field': marker * 4000}),
      ],
    ]) {
      expect(
        () => adeleCopyBackendRecords(records),
        throwsA(
          isA<FormatException>()
              .having((e) => e.source, 'source', isNull)
              .having((e) => e.toString().length, 'length', lessThan(128))
              .having((e) => e.toString(), 'message', isNot(contains(marker))),
        ),
      );
    }
  });
}
