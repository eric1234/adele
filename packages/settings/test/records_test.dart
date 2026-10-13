import 'package:adele_plugin_api/adele_plugin_api.dart';
import 'package:adele_settings/adele_settings.dart';
import 'package:test/test.dart';

void main() {
  test('record identities have value equality and distinct semantic types', () {
    final collection = RecordCollectionId('providers');
    final record = ConfigurationRecordId('providers');
    final field = RecordFieldId('providers');
    final type = RecordTypeId('org.example.api');
    expect(collection, RecordCollectionId('providers'));
    expect(record, ConfigurationRecordId('providers'));
    expect(field, RecordFieldId('providers'));
    expect(type, RecordTypeId('org.example.api'));
    expect(collection, isNot(record));
    expect(record, isNot(field));
    expect(field, isNot(collection));
    expect(type, isNot(PluginId(type.value)));
    expect(type, isNot(SettingId(type.value)));
    for (final pair in <(Object, Object)>[
      (collection, RecordCollectionId('providers')),
      (record, ConfigurationRecordId('providers')),
      (field, RecordFieldId('providers')),
      (type, RecordTypeId(type.value)),
    ]) {
      expect(pair.$1.hashCode, pair.$2.hashCode);
      expect({pair.$1, pair.$2}, hasLength(1));
    }
    expect(collection.toString(), collection.value);
    expect(record.toString(), record.value);
    expect(field.toString(), field.value);
    expect(type.toString(), type.value);
  });

  test('local identities use bounded, exact lowercase ASCII grammar', () {
    for (final value in ['a', 'a1', 'a-1-b2', 'x' * 64, 'com0', 'lpt10']) {
      expect(RecordCollectionId(value).value, value);
      expect(ConfigurationRecordId(value).value, value);
      expect(RecordFieldId(value).value, value);
    }
    for (final value in [
      '',
      'x' * 65,
      'A',
      '1a',
      '-a',
      'a-',
      'a--b',
      'a_b',
      'a.b',
      ' a',
      'a ',
      'a\n',
      'a\r',
      'a\u0000',
      'caf\u00e9',
      '../a',
      'a/b',
      r'a\b',
      'a:b',
      'a%2fb',
    ]) {
      expect(
        () => RecordCollectionId(value),
        throwsFormatException,
        reason: value,
      );
      expect(
        () => ConfigurationRecordId(value),
        throwsFormatException,
        reason: value,
      );
      expect(() => RecordFieldId(value), throwsFormatException, reason: value);
    }
  });

  test('portable identities reject devices and their reserved aliases', () {
    for (final value in [
      'con',
      'prn',
      'aux',
      'nul',
      for (var number = 1; number <= 9; number++) ...[
        'com$number',
        'lpt$number',
      ],
      'CON',
      'Con',
      'nul.',
      'aux ',
      'con.txt',
      r'clock$',
      r'conin$',
      r'conout$',
      'com\u00b9',
      'lpt\u00b2',
      'com\u00b3',
    ]) {
      expect(
        () => RecordCollectionId(value),
        throwsFormatException,
        reason: value,
      );
      expect(
        () => ConfigurationRecordId(value),
        throwsFormatException,
        reason: value,
      );
    }
    expect(RecordFieldId('con').value, 'con');
  });

  test('type identity uses public grammar and owner dot namespace', () {
    for (final id in ['', 'local', 'Org.example.api', 'org..example.api']) {
      expect(() => RecordTypeId(id), throwsFormatException);
    }
    for (final id in [
      'org.example',
      'org.example-other.api',
      'org.example2.api',
      'org.other.api',
    ]) {
      expect(() => _type(id: id), throwsArgumentError);
    }
    expect(_type(id: 'org.example.nested.api').owner, PluginId('org.example'));
  });

  test(
    'declarations copy ordered fields and preserve presentation metadata',
    () {
      final z = _field('z', const StringSettingType(), required: true);
      final a = _field('a', const BooleanSettingType());
      final input = <RecordFieldDefinition<Object>>[z, a];
      final type = _type(fields: input);
      input.clear();
      expect(type.fields, [z, a]);
      expect(() => type.fields.clear(), throwsUnsupportedError);
      expect(() => type.fields[0] = a, throwsUnsupportedError);
      expect(type.collection, RecordCollectionId('providers'));
      expect(type.collectionLabel, 'Providers');
      expect(type.label, '  API  ');
      expect(type.description, 'Type\nexplanation');
      expect(z.label, '  Field  ');
      expect(z.description, 'Field\nexplanation');
      expect(z.required, isTrue);
      expect(a.required, isFalse);
      expect(() => _type(fields: [z, z]), throwsArgumentError);
      expect(_type().fields, isEmpty);
    },
  );

  test(
    'labels reuse presentation rules; description remains optional prose',
    () {
      for (final label in ['', ' ', 'a\nb', 'a\u0000b', 'a\u2028b']) {
        expect(() => _type(label: label), throwsArgumentError);
        expect(() => _type(collectionLabel: label), throwsArgumentError);
        expect(
          () => RecordFieldDefinition(
            id: RecordFieldId('x'),
            label: label,
            type: const StringSettingType(),
            required: false,
          ),
          throwsArgumentError,
        );
      }
      final field = RecordFieldDefinition(
        id: RecordFieldId('x'),
        label: 'X',
        type: const StringSettingType(),
        required: false,
      );
      expect(field.description, isNull);
    },
  );

  test(
    'known-field validation has no defaults, mutation, or unknown inspection',
    () {
      final type = _type(
        fields: [
          _field('z', const StringSettingType(), required: true),
          _field('a', const BooleanSettingType()),
          _field('absent', IntegerSettingType()),
        ],
      );
      final unknown = Object();
      final values = <String, Object?>{'unknown': unknown, 'a': false, 'z': ''};
      final validated = type.validate(_record, values);
      expect(validated, {'z': '', 'a': false});
      expect(validated.keys, ['z', 'a']);
      expect(values['unknown'], same(unknown));
      expect(values, hasLength(3));
      values['a'] = true;
      expect(validated['a'], isFalse);
      expect(() => validated.clear(), throwsUnsupportedError);
      expect(type.validate(_record, {'z': ' \n\u0000'})['z'], ' \n\u0000');
      expect(
        () => type.validate(_record, {}),
        throwsA(_invalid('z', 'Required field is missing.')),
      );
      expect(
        () => type.validate(_record, {'z': '', 'a': null}),
        throwsA(_invalid('a', 'Expected a boolean.')),
      );
    },
  );

  test('record scalars exactly reuse setting validation and messages', () {
    for (final (scalar, valid, failures)
        in <(SettingType<Object>, Object, Map<Object?, String>)>[
          (
            const BooleanSettingType(),
            false,
            {
              null: 'Expected a boolean.',
              'true': 'Expected a boolean.',
              1: 'Expected a boolean.',
            },
          ),
          (
            IntegerSettingType(minimum: 1, maximum: 3),
            2,
            {
              null: 'Expected a native Dart int.',
              2.0: 'Expected a native Dart int.',
              BigInt.one: 'Expected a native Dart int.',
              0: 'Must be at least 1.',
              4: 'Must be at most 3.',
            },
          ),
          (
            const StringSettingType(),
            '',
            {null: 'Expected a string.', true: 'Expected a string.'},
          ),
          (
            EnumSettingType([SettingEnumOption('stable', label: 'Display')]),
            'stable',
            {
              null: 'Expected a declared enum string.',
              'Display': 'Expected a declared enum string.',
              'other': 'Expected a declared enum string.',
            },
          ),
        ]) {
      final type = _type(fields: [_field('value', scalar, required: true)]);
      final setting = SettingDefinition(
        id: SettingId('org.example.value'),
        owner: SettingOwnerId('org.example'),
        label: 'Value',
        category: 'General',
        section: 'Values',
        type: scalar,
        defaultValue: valid,
      );
      expect(type.validate(_record, {'value': valid}), {'value': valid});
      for (final failure in failures.entries) {
        expect(
          () => type.validate(_record, {'value': failure.key}),
          throwsA(_invalid('value', failure.value)),
        );
        expect(
          () => setting.validate(failure.key),
          throwsA(
            isA<InvalidSettingValue>()
                .having((error) => error.id, 'id', setting.id)
                .having((error) => error.message, 'message', failure.value)
                .having(
                  (error) => error.toString(),
                  'diagnostic',
                  'InvalidSettingValue: ${setting.id}: ${failure.value}',
                ),
          ),
        );
      }
    }
    final integer = _type(fields: [_field('value', IntegerSettingType())]);
    for (final value in [-9223372036854775808, 9223372036854775807]) {
      expect(integer.validate(_record, {'value': value}), {'value': value});
    }
  });

  test(
    'catalog copies and sorts types and collections, not fields or labels',
    () {
      final z = _type(
        id: 'org.example.z',
        collection: 'accounts',
        collectionLabel: 'Accounts',
      );
      final a = _type(id: 'org.example.a');
      final input = [z, a];
      final catalog = RecordCatalog(input);
      input.clear();
      expect(catalog.definitions, [a, z]);
      expect(catalog.collections.map((id) => id.value), [
        'accounts',
        'providers',
      ]);
      expect(catalog.collectionLabel(a.collection), 'Providers');
      expect(catalog.definition(z.id), same(z));
      expect(() => catalog.definitions.clear(), throwsUnsupportedError);
      expect(() => catalog.collections.clear(), throwsUnsupportedError);
      expect(
        () => catalog.definition(RecordTypeId('org.example.unknown')),
        throwsA(isA<RecordTypeNotFound>()),
      );
      expect(
        () => catalog.collectionLabel(RecordCollectionId('unknown')),
        throwsArgumentError,
      );
      expect(RecordCatalog([]).definitions, isEmpty);
      expect(RecordCatalog([]).collections, isEmpty);
    },
  );

  test(
    'aggregation rejects duplicate types and conflicting collection labels',
    () {
      final type = _type(id: 'org.example.nested.api');
      final nested = _type(id: type.id.value, owner: 'org.example.nested');
      for (final definitions in [
        [type, type],
        [type, nested],
        [nested, type],
      ]) {
        expect(
          () => RecordCatalog(definitions),
          throwsA(
            isA<DuplicateRecordTypeId>()
                .having((error) => error.id, 'id', type.id)
                .having((error) => error.firstOwner, 'firstOwner', type.owner),
          ),
        );
      }
      final other = _type(
        id: 'org.example.other',
        collectionLabel: 'Different',
      );
      for (final definitions in [
        [type, other],
        [other, type],
      ]) {
        expect(
          () => RecordCatalog(definitions),
          throwsA(
            isA<ConflictingRecordCollectionLabel>()
                .having(
                  (error) => error.collection,
                  'collection',
                  type.collection,
                )
                .having((error) => error.first, 'first', 'Providers')
                .having((error) => error.second, 'second', 'Different'),
          ),
        );
      }
      expect(
        RecordCatalog([type, _type(id: 'org.example.other')]).collections,
        [type.collection],
      );
    },
  );

  test('record-wide failures do not pretend to identify a field', () {
    final error = InvalidRecordValue(
      RecordCollectionId('providers'),
      _record,
      null,
      'Bad header.',
    );
    expect(error.fieldId, isNull);
    expect(error.toString(), 'InvalidRecordValue: providers/work: Bad header.');
  });
}

final _record = ConfigurationRecordId('work');

Matcher _invalid(String field, String message) => isA<InvalidRecordValue>()
    .having(
      (error) => error.collection,
      'collection',
      RecordCollectionId('providers'),
    )
    .having((error) => error.recordId, 'recordId', _record)
    .having((error) => error.fieldId, 'fieldId', RecordFieldId(field))
    .having((error) => error.message, 'message', message)
    .having(
      (error) => error.toString(),
      'diagnostic',
      'InvalidRecordValue: providers/work: $field: $message',
    );

RecordFieldDefinition<T> _field<T extends Object>(
  String id,
  SettingType<T> type, {
  bool required = false,
}) => RecordFieldDefinition(
  id: RecordFieldId(id),
  label: '  Field  ',
  description: 'Field\nexplanation',
  type: type,
  required: required,
);

RecordTypeDefinition _type({
  String id = 'org.example.api',
  String owner = 'org.example',
  String collection = 'providers',
  String collectionLabel = 'Providers',
  String label = '  API  ',
  Iterable<RecordFieldDefinition<Object>> fields = const [],
}) => RecordTypeDefinition(
  id: RecordTypeId(id),
  owner: PluginId(owner),
  collection: RecordCollectionId(collection),
  collectionLabel: collectionLabel,
  label: label,
  description: 'Type\nexplanation',
  fields: fields,
);
