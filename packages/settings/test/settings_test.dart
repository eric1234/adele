import 'package:adele_plugin_api/adele_plugin_api.dart';
import 'package:adele_settings/adele_settings.dart';
import 'package:test/test.dart';

void main() {
  group('identities', () {
    test('have value equality, hashing, and distinct semantic types', () {
      const value = 'dev.example.settings.value-2';
      final id = SettingId(value);
      final owner = SettingOwnerId(value);
      expect(id.value, value);
      expect(id.toString(), value);
      expect(id, SettingId(value));
      expect(id.hashCode, SettingId(value).hashCode);
      expect(<SettingId>{id, SettingId(value)}, hasLength(1));
      expect(owner.value, value);
      expect(owner.toString(), value);
      expect(owner, SettingOwnerId(value));
      expect(owner.hashCode, SettingOwnerId(value).hashCode);
      expect(<SettingOwnerId>{owner, SettingOwnerId(value)}, hasLength(1));
      expect(id, isNot(SettingId('dev.example.other')));
      expect(owner, isNot(SettingOwnerId('dev.example.other')));
      expect(id, isNot(owner));
      expect(owner, isNot(id));
      expect(owner, isNot(PluginId(value)));
      expect(id, isNot(PluginId(value)));
    });

    test('use the shared public ID grammar', () {
      for (final value in ['dev.example', 'dev.example2.settings-2.value']) {
        expect(SettingId(value).value, value);
        expect(SettingOwnerId(value).value, value);
      }
      for (final value in [
        '',
        'single',
        'dev..example',
        '.dev.example',
        'dev.example.',
        'Dev.example',
        'dev.example_bad',
        'dev.-example',
        'dev.example-',
        'dev.ex--ample',
        'dev.2example',
        'dev.ex\u00e4mple',
        ' dev.example',
        'dev.example ',
        'dev.example\n',
      ]) {
        expect(() => SettingId(value), throwsFormatException, reason: value);
        expect(
          () => SettingOwnerId(value),
          throwsFormatException,
          reason: value,
        );
      }
    });
  });

  group('SettingDefinition', () {
    test('retains typed default and descriptive metadata', () {
      const type = BooleanSettingType();
      final definition = _definition(
        type,
        true,
        label: '  Enabled  ',
        category: 'User preferences',
        section: 'Editing',
        description: 'Optional explanation.\nAnother line.',
      );
      expect(definition.id, SettingId('dev.example.settings.value'));
      expect(definition.owner, SettingOwnerId('dev.example.settings'));
      expect(definition.label, '  Enabled  ');
      expect(definition.category, 'User preferences');
      expect(definition.section, 'Editing');
      expect(definition.description, 'Optional explanation.\nAnother line.');
      expect(definition.type, same(type));
      expect(definition.defaultValue, isTrue);
      expect(_definition(type, false).description, isNull);
    });

    test(
      'enforces owner namespace at a dot boundary without checking trust',
      () {
        for (final id in [
          'dev.example.settings',
          'dev.example.settings-other.value',
          'dev.example.settings2.value',
          'dev.someone.settings.value',
        ]) {
          expect(
            () => _definition(const BooleanSettingType(), true, id: id),
            throwsArgumentError,
          );
        }
        final nested = _definition(
          const BooleanSettingType(),
          true,
          id: 'dev.example.settings.nested.value',
        );
        expect(nested.id.value, 'dev.example.settings.nested.value');
        expect(
          _definition(
            const BooleanSettingType(),
            true,
            owner: 'dev.example',
          ).owner,
          SettingOwnerId('dev.example'),
        );
      },
    );

    test('required presentation metadata is nonblank and single-line', () {
      for (final value in [
        '',
        '   ',
        '\u00a0',
        'before\u2028after',
        'before\u2029after',
        for (var unit = 0; unit <= 0x9f; unit++)
          if (unit < 0x20 || unit >= 0x7f)
            'before${String.fromCharCode(unit)}after',
      ]) {
        expect(
          () => _definition(const BooleanSettingType(), true, label: value),
          throwsArgumentError,
          reason: 'label: ${value.codeUnits}',
        );
        expect(
          () => _definition(const BooleanSettingType(), true, category: value),
          throwsArgumentError,
          reason: 'category: ${value.codeUnits}',
        );
        expect(
          () => _definition(const BooleanSettingType(), true, section: value),
          throwsArgumentError,
          reason: 'section: ${value.codeUnits}',
        );
      }
      final definition = _definition(
        const BooleanSettingType(),
        true,
        label: 'Pr\u00e9f\u00e9rences',
        category: 'x' * 300,
        section: '  Section  ',
      );
      expect(definition.label, 'Pr\u00e9f\u00e9rences');
      expect(definition.category, 'x' * 300);
      expect(definition.section, '  Section  ');
    });

    test(
      'defaults use the same validation and structured errors as values',
      () {
        for (final (type, validDefault, invalidValues)
            in <(SettingType<Object>, Object, List<Object?>)>[
              (const BooleanSettingType(), true, [null, 'true', 1]),
              (
                IntegerSettingType(minimum: 1, maximum: 4),
                2,
                [null, 0, 5, 2.0],
              ),
              (const StringSettingType(), '', [null, 1, false]),
              (
                EnumSettingType([SettingEnumOption('first')]),
                'first',
                [null, 'second', false],
              ),
            ]) {
          final definition = _definition(type, validDefault);
          for (final value in invalidValues) {
            final error = isA<InvalidSettingValue>()
                .having((error) => error.id, 'id', definition.id)
                .having((error) => error.message, 'message', isNotEmpty);
            expect(() => _definition(type, value), throwsA(error));
            expect(() => definition.validate(value), throwsA(error));
          }
        }
      },
    );
  });

  group('scalar types', () {
    test('boolean accepts only bool, without truthiness or conversion', () {
      final definition = _definition(const BooleanSettingType(), true);
      expect(definition.validate(true), isTrue);
      expect(definition.validate(false), isFalse);
      for (final value in <Object?>[null, 0, 1, 'true', 'false', '', [], {}]) {
        expect(
          () => definition.validate(value),
          throwsA(isA<InvalidSettingValue>()),
        );
      }
    });

    test('integer retains the native signed 64-bit extremes exactly', () {
      const minimum = -9223372036854775808;
      const maximum = 9223372036854775807;
      final type = IntegerSettingType();
      expect(type.minimum, isNull);
      expect(type.maximum, isNull);
      for (final value in [
        minimum,
        minimum + 1,
        -1,
        0,
        1,
        maximum - 1,
        maximum,
      ]) {
        final definition = _definition(type, value);
        expect(definition.defaultValue, value);
        expect(definition.validate(value), value);
      }
      final bounded = _definition(
        IntegerSettingType(minimum: minimum, maximum: maximum),
        0,
      );
      expect(bounded.validate(minimum), minimum);
      expect(bounded.validate(maximum), maximum);
    });

    test(
      'integer rejects doubles, BigInts, strings, and other scalar types',
      () {
        final definition = _definition(IntegerSettingType(), 0);
        for (final value in <Object?>[
          null,
          1.0,
          1.5,
          double.infinity,
          double.nan,
          BigInt.zero,
          BigInt.parse('9223372036854775808'),
          BigInt.parse('-9223372036854775809'),
          '1',
          true,
          [],
        ]) {
          expect(
            () => definition.validate(value),
            throwsA(isA<InvalidSettingValue>()),
          );
          expect(
            () => _definition(IntegerSettingType(), value),
            throwsA(isA<InvalidSettingValue>()),
          );
        }
      },
    );

    test('integer bounds are inclusive and may be one-sided or equal', () {
      final type = IntegerSettingType(minimum: -2, maximum: 3);
      expect(type.minimum, -2);
      expect(type.maximum, 3);
      final definition = _definition(type, 0);
      expect(definition.validate(-2), -2);
      expect(definition.validate(3), 3);
      for (final value in [-3, 4]) {
        expect(
          () => definition.validate(value),
          throwsA(isA<InvalidSettingValue>()),
        );
      }
      final lower = _definition(IntegerSettingType(minimum: 0), 1);
      final upper = _definition(IntegerSettingType(maximum: 0), -1);
      expect(lower.validate(9223372036854775807), 9223372036854775807);
      expect(upper.validate(-9223372036854775808), -9223372036854775808);
      expect(() => lower.validate(-1), throwsA(isA<InvalidSettingValue>()));
      expect(() => upper.validate(1), throwsA(isA<InvalidSettingValue>()));
      final exact = _definition(IntegerSettingType(minimum: 2, maximum: 2), 2);
      expect(exact.validate(2), 2);
      expect(() => exact.validate(1), throwsA(isA<InvalidSettingValue>()));
      expect(() => exact.validate(3), throwsA(isA<InvalidSettingValue>()));
      expect(
        () => IntegerSettingType(minimum: 1, maximum: 0),
        throwsArgumentError,
      );
    });

    test('string values are unconstrained text, not presentation metadata', () {
      final definition = _definition(const StringSettingType(), '');
      for (final value in ['', '  ', 'text\nmore', '\u0000', '\u{1f680}']) {
        expect(definition.validate(value), value);
        expect(
          _definition(const StringSettingType(), value).defaultValue,
          value,
        );
      }
      for (final value in <Object?>[null, true, 1, 1.5, BigInt.one, [], {}]) {
        expect(
          () => definition.validate(value),
          throwsA(isA<InvalidSettingValue>()),
        );
      }
    });
  });

  group('enum', () {
    test(
      'matches stable strings exactly, not display labels or other types',
      () {
        final first = SettingEnumOption('first', label: 'First option');
        final second = SettingEnumOption('second');
        final type = EnumSettingType([first, second]);
        expect(first.value, 'first');
        expect(first.label, 'First option');
        expect(second.label, isNull);
        final definition = _definition(type, 'first');
        expect(definition.validate('first'), 'first');
        expect(definition.validate('second'), 'second');
        for (final value in <Object?>[
          null,
          '',
          'First',
          ' first',
          'first ',
          'First option',
          'other',
          1,
          true,
        ]) {
          expect(
            () => definition.validate(value),
            throwsA(isA<InvalidSettingValue>()),
          );
        }
      },
    );

    test('copies options without reordering and exposes an immutable list', () {
      final z = SettingEnumOption('z');
      final a = SettingEnumOption('a');
      final options = [z, a];
      final type = EnumSettingType(options.map((option) => option));
      options.clear();
      expect(type.options, [z, a]);
      expect(() => type.options.clear(), throwsUnsupportedError);
      expect(() => type.options.add(z), throwsUnsupportedError);
      expect(() => type.options[0] = a, throwsUnsupportedError);
      expect(_definition(type, 'a').validate('z'), 'z');
    });

    test('rejects empty options and duplicate values regardless of labels', () {
      expect(() => EnumSettingType([]), throwsArgumentError);
      expect(
        () => EnumSettingType([
          SettingEnumOption('same', label: 'One'),
          SettingEnumOption('same', label: 'Two'),
        ]),
        throwsArgumentError,
      );
      expect(
        EnumSettingType([
          SettingEnumOption('first', label: 'Same label'),
          SettingEnumOption('second', label: 'Same label'),
        ]).options,
        hasLength(2),
      );
    });

    test('rejects blank, control, multiline, and untrimmed enum values', () {
      for (final value in [
        '',
        '   ',
        ' first',
        'first ',
        '\u00a0first',
        'first\u00a0',
        'first\u2028second',
        'first\u2029second',
        for (var unit = 0; unit <= 0x9f; unit++)
          if (unit < 0x20 || unit >= 0x7f)
            'first${String.fromCharCode(unit)}second',
      ]) {
        expect(
          () => SettingEnumOption(value),
          throwsArgumentError,
          reason: value.codeUnits.toString(),
        );
      }
      expect(SettingEnumOption('two words').value, 'two words');
      expect(SettingEnumOption('caf\u00e9').value, 'caf\u00e9');
    });

    test('optional labels follow single-line presentation rules', () {
      for (final label in ['', ' ', 'two\nlines', 'a\u0000b', 'a\u2028b']) {
        expect(
          () => SettingEnumOption('value', label: label),
          throwsArgumentError,
        );
      }
      expect(SettingEnumOption('value', label: '  Label  ').label, '  Label  ');
    });
  });

  group('SettingsCatalog', () {
    test('empty catalogs and missing IDs have explicit outcomes', () {
      final catalog = SettingsCatalog([]);
      final id = SettingId('dev.example.missing');
      expect(catalog.definitions, isEmpty);
      final error = isA<SettingNotFound>().having(
        (error) => error.id,
        'id',
        id,
      );
      expect(() => catalog.definition(id), throwsA(error));
      expect(() => catalog.resolve<bool>(id), throwsA(error));
      expect(
        () => catalog.resolve<bool>(id, globalOverrides: {id: true}),
        throwsA(error),
      );
    });

    test('copies, sorts by ID, and exposes immutable definitions', () {
      final z = _definition(
        const BooleanSettingType(),
        false,
        id: 'dev.example.settings.z',
        label: 'A first label',
      );
      final a = _definition(
        const StringSettingType(),
        '',
        id: 'dev.example.settings.a',
        label: 'Z last label',
      );
      final input = <SettingDefinition<Object>>[z, a];
      final catalog = SettingsCatalog(input.map((definition) => definition));
      expect(input, [z, a]);
      input.clear();
      expect(catalog.definitions, [a, z]);
      expect(catalog.definition(z.id), same(z));
      expect(catalog.definition(a.id), same(a));
      expect(() => catalog.definitions.clear(), throwsUnsupportedError);
      expect(() => catalog.definitions.add(a), throwsUnsupportedError);
      expect(() => catalog.definitions[0] = z, throwsUnsupportedError);
    });

    test('rejects repeated IDs from the same owner, even the same object', () {
      final definition = _definition(const BooleanSettingType(), true);
      final error = isA<DuplicateSettingId>()
          .having((error) => error.id, 'id', definition.id)
          .having((error) => error.firstOwner, 'firstOwner', definition.owner)
          .having(
            (error) => error.secondOwner,
            'secondOwner',
            definition.owner,
          );
      expect(() => SettingsCatalog([definition, definition]), throwsA(error));
      expect(
        () => SettingsCatalog([
          definition,
          _definition(const StringSettingType(), 'different declaration'),
        ]),
        throwsA(error),
      );
    });

    test('nested owners can cross-collide and both owners are reported', () {
      final first = _definition(const BooleanSettingType(), true);
      final second = _definition(
        const StringSettingType(),
        '',
        owner: 'dev.example',
      );
      expect(
        () => SettingsCatalog([first, second]),
        throwsA(
          isA<DuplicateSettingId>()
              .having((error) => error.id, 'id', first.id)
              .having(
                (error) => [error.firstOwner, error.secondOwner],
                'owners',
                unorderedEquals([first.owner, second.owner]),
              )
              .having(
                (error) => error.toString(),
                'diagnostic',
                allOf(
                  contains(first.id.value),
                  contains('by ${first.owner} and ${second.owner}'),
                ),
              ),
        ),
      );
    });

    test(
      'typed resolution fails explicitly rather than with casts or defaults',
      () {
        final integer = _definition(IntegerSettingType(), 2);
        final catalog = SettingsCatalog([integer]);
        expect(catalog.definition(integer.id), same(integer));
        expect(catalog.resolve<int>(integer.id).value, 2);
        expect(catalog.resolve<num>(integer.id).value, 2);
        expect(catalog.resolve<Object>(integer.id).value, 2);
        expect(() => catalog.resolve<bool>(integer.id), throwsArgumentError);
        expect(
          () => catalog.resolve<String>(
            integer.id,
            globalOverrides: {
              integer.id: 'would match the request, not the type',
            },
          ),
          throwsArgumentError,
        );
      },
    );

    test(
      'enum and ordinary string definitions both have String value type',
      () {
        final definition = _definition(
          EnumSettingType([SettingEnumOption('first')]),
          'first',
        );
        final catalog = SettingsCatalog([definition]);
        expect(catalog.definition(definition.id), same(definition));
        expect(catalog.resolve<String>(definition.id).value, 'first');
        expect(() => catalog.resolve<int>(definition.id), throwsArgumentError);
      },
    );
  });

  group('resolution', () {
    test(
      'independent owners share a product section with typed resolution',
      () {
        final enabled = SettingId('dev.example.alpha.enabled');
        final count = SettingId('dev.example.beta.count');
        // Constructor context deliberately widens both definitions to Object.
        final catalog = SettingsCatalog([
          SettingDefinition(
            id: count,
            owner: SettingOwnerId('dev.example.beta'),
            label: 'Count',
            category: 'General',
            section: 'Output',
            type: IntegerSettingType(),
            defaultValue: 10,
          ),
          SettingDefinition(
            id: enabled,
            owner: SettingOwnerId('dev.example.alpha'),
            label: 'Enabled',
            category: 'General',
            section: 'Output',
            type: const BooleanSettingType(),
            defaultValue: false,
          ),
        ]);
        expect(catalog.definitions.map((definition) => definition.id), [
          enabled,
          count,
        ]);
        expect(catalog.resolve<int>(count).value, 10);
        expect(catalog.resolve<bool>(enabled).value, isFalse);
        expect(
          catalog.resolve<int>(count, globalOverrides: {count: 20}).value,
          20,
        );
        expect(
          catalog
              .resolve<bool>(enabled, globalOverrides: {enabled: true})
              .value,
          isTrue,
        );
        expect(() => catalog.resolve<bool>(count), throwsArgumentError);
      },
    );

    test('resolves defaults or explicit scalar overrides with provenance', () {
      for (final definition in <SettingDefinition<Object>>[
        _definition(const BooleanSettingType(), true),
        _definition(IntegerSettingType(minimum: 0), 1),
        _definition(const StringSettingType(), 'default'),
        _definition(
          EnumSettingType([
            SettingEnumOption('first'),
            SettingEnumOption('next'),
          ]),
          'first',
        ),
      ]) {
        final catalog = SettingsCatalog([definition]);
        final inherited = catalog.resolve<Object>(definition.id);
        expect(inherited.id, definition.id);
        expect(inherited.value, definition.defaultValue);
        expect(inherited.source, SettingValueSource.defaultValue);
        expect(inherited.hasGlobalOverride, isFalse);

        final Object value = switch (definition.type) {
          BooleanSettingType() => false,
          IntegerSettingType() => 0,
          StringSettingType() => '',
          EnumSettingType() => 'next',
        };
        final global = catalog.resolve<Object>(
          SettingId(definition.id.value),
          globalOverrides: {definition.id: value},
        );
        expect(global.id, definition.id);
        expect(global.value, value);
        expect(global.source, SettingValueSource.global);
        expect(global.hasGlobalOverride, isTrue);
      }
    });

    test('equal-to-default overrides retain independent explicit presence', () {
      final definition = _definition(const BooleanSettingType(), false);
      final catalog = SettingsCatalog([definition]);
      final overrides = <SettingId, Object?>{definition.id: false};
      final global = catalog.resolve<bool>(
        definition.id,
        globalOverrides: overrides,
      );
      expect(global.value, isFalse);
      expect(global.source, SettingValueSource.global);
      expect(global.hasGlobalOverride, isTrue);
      overrides.remove(definition.id);
      final inherited = catalog.resolve<bool>(
        definition.id,
        globalOverrides: overrides,
      );
      expect(inherited.value, isFalse);
      expect(inherited.source, SettingValueSource.defaultValue);
      expect(inherited.hasGlobalOverride, isFalse);
      expect(global.hasGlobalOverride, isTrue);
      expect(global.source, SettingValueSource.global);
    });

    test('known null or invalid overrides never fall back to defaults', () {
      for (final definition in <SettingDefinition<Object>>[
        _definition(const BooleanSettingType(), false),
        _definition(IntegerSettingType(minimum: 0, maximum: 4), 2),
        _definition(const StringSettingType(), ''),
        _definition(EnumSettingType([SettingEnumOption('first')]), 'first'),
      ]) {
        final catalog = SettingsCatalog([definition]);
        final Object invalid = switch (definition.type) {
          BooleanSettingType() => 'false',
          IntegerSettingType() => 5,
          StringSettingType() => false,
          EnumSettingType() => 'missing',
        };
        for (final value in <Object?>[null, invalid]) {
          late String message;
          try {
            definition.validate(value);
            fail('Expected InvalidSettingValue');
          } on InvalidSettingValue catch (error) {
            message = error.message;
          }
          expect(
            () => catalog.resolve<Object>(
              definition.id,
              globalOverrides: {definition.id: value},
            ),
            throwsA(
              isA<InvalidSettingOverride>()
                  .having((error) => error.id, 'id', definition.id)
                  .having((error) => error.message, 'message', message),
            ),
          );
        }
      }
    });

    test('ignores unknown map entries without inspecting their values', () {
      final definition = _definition(const BooleanSettingType(), false);
      final catalog = SettingsCatalog([definition]);
      final overrides = <SettingId, Object?>{
        SettingId('dev.unknown.null'): null,
        SettingId('dev.unknown.object'): Object(),
        SettingId('dev.unknown.list'): [null, BigInt.one],
      };
      final inherited = catalog.resolve<bool>(
        definition.id,
        globalOverrides: overrides,
      );
      expect(inherited.value, isFalse);
      expect(inherited.hasGlobalOverride, isFalse);
      expect(overrides, hasLength(3));
      overrides[definition.id] = true;
      expect(
        catalog.resolve<bool>(definition.id, globalOverrides: overrides).value,
        isTrue,
      );
    });

    test(
      'does not retain or mutate override maps or earlier resolved values',
      () {
        final definition = _definition(IntegerSettingType(), 2);
        final catalog = SettingsCatalog([definition]);
        final overrides = <SettingId, Object?>{definition.id: 3};
        final before = catalog.resolve<int>(
          definition.id,
          globalOverrides: overrides,
        );
        expect(overrides, {definition.id: 3});
        overrides[definition.id] = 4;
        final after = catalog.resolve<int>(
          definition.id,
          globalOverrides: Map.unmodifiable(overrides),
        );
        expect(before.value, 3);
        expect(after.value, 4);
        expect(catalog.resolve<int>(definition.id).value, 2);
        expect(definition.defaultValue, 2);
      },
    );
  });
}

SettingDefinition<T> _definition<T extends Object>(
  SettingType<T> type,
  Object? defaultValue, {
  String id = 'dev.example.settings.value',
  String owner = 'dev.example.settings',
  String label = 'Setting label',
  String category = 'Category',
  String section = 'Section',
  String? description,
}) => SettingDefinition<T>(
  id: SettingId(id),
  owner: SettingOwnerId(owner),
  label: label,
  category: category,
  section: section,
  description: description,
  type: type,
  defaultValue: defaultValue,
);
