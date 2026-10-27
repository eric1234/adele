import 'package:adele_plugin_backend_support/adele_plugin_backend_support.dart';
import 'package:test/test.dart';

void main() {
  test('copies scalar values and exposes an immutable snapshot', () {
    final source = <String, Object>{
      'enabled': true,
      'count': 17,
      'label': 'original',
    };
    final settings = AdeleBackendSettings(source);
    source
      ..['enabled'] = false
      ..['count'] = 29
      ..remove('label')
      ..['added'] = 'later';
    expect(settings.read<bool>('enabled'), isTrue);
    expect(settings.read<int>('count'), 17);
    expect(settings.read<String>('label'), 'original');
    expect(settings.values, {
      'enabled': true,
      'count': 17,
      'label': 'original',
    });
    expect(() => settings.values['count'] = 4, throwsUnsupportedError);
    expect(settings.values.clear, throwsUnsupportedError);
  });

  test(
    'bootstrap copies an explicit map without interpreting other fields',
    () {
      final source = <Object?, Object?>{'value': false};
      final bootstrap = <Object?, Object?>{
        'settings': source,
        'unrelated': Object(),
      };
      final settings = AdeleBackendSettings.fromBootstrap(bootstrap);
      source['value'] = true;
      bootstrap['settings'] = {'value': 'replaced'};
      expect(settings.read<bool>('value'), isFalse);
      expect(
        AdeleBackendSettings.fromBootstrap({
          'settings': <String, Object>{},
        }).values,
        isEmpty,
      );
    },
  );

  test('missing and wrongly typed reads fail without fallback or coercion', () {
    final settings = AdeleBackendSettings({'count': 12, 'text': '12'});
    expect(() => settings.read<int>('absent'), throwsStateError);
    expect(() => settings.read<Object?>('absent'), throwsStateError);
    expect(() => settings.read<String>('count'), throwsStateError);
    expect(() => settings.read<double>('count'), throwsStateError);
    expect(() => settings.read<int>('text'), throwsStateError);
    expect(settings.read<Object>('count'), 12);
  });

  test('bootstrap never substitutes absent or malformed settings', () {
    for (final bootstrap in <Object?>[
      null,
      [],
      'settings',
      {},
      {'count': 12},
      {'settings': null},
      {'settings': <Object?>[]},
      {'settings': 'invalid'},
    ]) {
      expect(
        () => AdeleBackendSettings.fromBootstrap(bootstrap),
        throwsFormatException,
      );
    }
  });

  test('all entry paths share strict scalar transport validation', () {
    for (final invalid in <Object?>[
      null,
      1.0,
      double.nan,
      [],
      <String, Object>{},
      Object(),
    ]) {
      final raw = <Object?, Object?>{'value': invalid};
      expect(() => adeleCopyBackendSettings(raw), throwsFormatException);
      expect(
        () => AdeleBackendSettings.fromBootstrap({'settings': raw}),
        throwsFormatException,
      );
      if (invalid != null) {
        expect(
          () => AdeleBackendSettings({'value': invalid}),
          throwsFormatException,
        );
      }
    }
    for (final key in <Object?>[null, 1, true]) {
      expect(
        () => adeleCopyBackendSettings({key: 'value'}),
        throwsFormatException,
      );
    }
  });

  test('transport adds no identity, count, text, or integer policy limits', () {
    final source = <String, Object>{
      '': '',
      'negative': -9223372036854775808,
      'positive': 9223372036854775807,
      'text': 'x' * 10000,
      for (var index = 0; index < 1000; index++) 'key $index': index,
    };
    final copied = adeleCopyBackendSettings(source);
    expect(copied, source);
    expect(() => copied['new'] = true, throwsUnsupportedError);
  });
}
