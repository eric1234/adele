import 'dart:io';

import 'package:adele_configuration_store/adele_configuration_store.dart';
import 'package:adele_platform_storage/adele_platform_storage.dart';
import 'package:adele_settings/adele_settings.dart';
import 'package:adele_settings_host/adele_settings_host.dart';
import 'package:adele_toml_document/adele_toml_document.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  final alpha = SettingOwnerId('dev.adele.alpha');
  final beta = SettingOwnerId('dev.adele.beta');
  final enabled = SettingId('dev.adele.alpha.enabled');
  final limit = SettingId('dev.adele.beta.output-limit');
  final mode = SettingId('dev.adele.alpha.mode');
  final text = SettingId('dev.adele.beta.text');
  final catalog = SettingsCatalog([
    SettingDefinition(
      id: enabled,
      owner: alpha,
      label: 'Enabled',
      category: 'General',
      section: 'Output',
      type: const BooleanSettingType(),
      defaultValue: true,
    ),
    SettingDefinition(
      id: limit,
      owner: beta,
      label: 'Output Limit',
      category: 'General',
      section: 'Output',
      type: IntegerSettingType(minimum: 100, maximum: 10000),
      defaultValue: 1000,
    ),
    SettingDefinition(
      id: mode,
      owner: alpha,
      label: 'Mode',
      category: 'General',
      section: 'Output',
      type: EnumSettingType([
        SettingEnumOption('brief', label: 'Brief'),
        SettingEnumOption('detailed', label: 'Detailed'),
      ]),
      defaultValue: 'brief',
    ),
    SettingDefinition(
      id: text,
      owner: beta,
      label: 'Text',
      category: 'General',
      section: 'Output',
      type: const StringSettingType(),
      defaultValue: '',
    ),
  ]);

  late Directory root;
  late PlatformStorageRoots roots;
  late ConfigurationStore persistence;
  late GlobalSettingsStore host;
  late File file;

  setUp(() {
    root = Directory.systemTemp.createTempSync('adele-settings-');
    roots = PlatformStorageRoots(
      operatingSystem: Platform.operatingSystem,
      configurationRoot: p.join(root.path, 'config'),
      localStateRoot: p.join(root.path, 'state'),
      localDataRoot: p.join(root.path, 'data'),
      cacheRoot: p.join(root.path, 'cache'),
    );
    persistence = ConfigurationStore(roots);
    host = GlobalSettingsStore(store: persistence, catalog: catalog);
    file = File(persistence.filePath);
  });
  tearDown(() => root.deleteSync(recursive: true));

  void seed(String source) {
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(source);
  }

  Matcher invalid(SettingId id) => isA<InvalidSettingOverride>().having(
    (error) => error.id,
    'setting ID',
    id,
  );

  test('absent file resolves two owners without creating any artifacts', () {
    final snapshot = host.load();
    expect(snapshot.exists, isFalse);
    final value = snapshot.resolve<bool>(enabled);
    expect(value.value, isTrue);
    expect(value.source, SettingValueSource.defaultValue);
    expect(value.hasGlobalOverride, isFalse);
    expect(snapshot.resolve<int>(limit).value, 1000);
    expect(snapshot.resetOverride(enabled), same(snapshot));
    expect(host.save(snapshot), same(snapshot));
    expect(root.listSync(), isEmpty);
  });

  test('malformed TOML remains a parse failure without repair', () {
    const source = 'value =\n';
    seed(source);
    expect(
      host.load,
      throwsA(
        isA<TomlException>().having(
          (error) => error.kind,
          'kind',
          TomlFailureKind.parse,
        ),
      ),
    );
    expect(file.readAsStringSync(), source);
    expect(Directory(roots.localStateRoot).existsSync(), isFalse);
  });

  for (final entry in <(SettingId, String)>[
    (enabled, '"true"'),
    (enabled, '1'),
    (limit, '50000'),
    (limit, '1000.0'),
    (limit, '"1000"'),
    (mode, '"unknown"'),
    (text, 'true'),
    (enabled, '[true]'),
    (enabled, '{ value = true }'),
    (enabled, '1979-05-27T07:32:00Z'),
  ]) {
    test(
      'invalid known override ${entry.$1} = ${entry.$2} is not defaulted',
      () {
        final source = '"${entry.$1.value}" = ${entry.$2} # untouched\n';
        seed(source);
        final snapshot = host.load();
        expect(() => snapshot.resolve(entry.$1), throwsA(invalid(entry.$1)));
        // Independent resolution still works; no eager unknown/global scan.
        final other = entry.$1 == text ? mode : text;
        expect(snapshot.resolve(other).source, SettingValueSource.defaultValue);
        expect(file.readAsStringSync(), source);
        expect(Directory(roots.localStateRoot).existsSync(), isFalse);
      },
    );
  }

  test('a table at the literal setting key is invalid, not absent', () {
    seed('["${enabled.value}"]\nvalue = true\n');
    final snapshot = host.load();
    expect(() => snapshot.resolve(enabled), throwsA(invalid(enabled)));
    expect(() => snapshot.resetOverride(enabled), throwsA(invalid(enabled)));
    expect(
      () => snapshot.setOverride(enabled, false),
      throwsA(invalid(enabled)),
    );
  });

  test('dotted TOML is unrelated to one fully qualified literal key', () {
    seed('${enabled.value} = false\n');
    final value = host.load().resolve<bool>(enabled);
    expect(value.value, isTrue);
    expect(value.hasGlobalOverride, isFalse);
  });

  test('missing IDs and invalid pending edits fail without file changes', () {
    final snapshot = host.load();
    final unknown = SettingId('dev.adele.absent.value');
    expect(() => snapshot.resolve(unknown), throwsA(isA<SettingNotFound>()));
    expect(
      () => snapshot.setOverride(unknown, true),
      throwsA(isA<SettingNotFound>()),
    );
    expect(
      () => snapshot.resetOverride(unknown),
      throwsA(isA<SettingNotFound>()),
    );
    for (final value in [null, 'false', 1]) {
      expect(
        () => snapshot.setOverride(enabled, value),
        throwsA(isA<InvalidSettingValue>()),
      );
    }
    expect(
      () => snapshot.setOverride(limit, 50000),
      throwsA(isA<InvalidSettingValue>()),
    );
    expect(
      () => snapshot.setOverride(mode, 'other'),
      throwsA(isA<InvalidSettingValue>()),
    );
    expect(snapshot.document.source, '');
    expect(root.listSync(), isEmpty);
  });

  group('conditional persistence', () {
    test('edit, save, reconstruct, reload and reset use literal root keys', () {
      final original = host.load();
      final edited = original
          .setOverride(enabled, false)
          .setOverride(limit, 5000)
          .setOverride(mode, 'detailed')
          .setOverride(text, 'first line\nsecond line');
      expect(original.resolve<bool>(enabled).value, isTrue);
      expect(file.existsSync(), isFalse);
      var saved = host.save(edited);
      expect(saved.exists, isTrue);
      expect(file.readAsStringSync(), contains('"${enabled.value}" = false'));
      final other = GlobalSettingsStore(
        store: ConfigurationStore(roots),
        catalog: catalog,
      );
      final reloaded = other.load();
      expect(reloaded.resolve<bool>(enabled).value, isFalse);
      expect(reloaded.resolve<int>(limit).value, 5000);
      expect(reloaded.resolve<String>(mode).value, 'detailed');
      expect(reloaded.resolve<String>(text).value, 'first line\nsecond line');
      expect(reloaded.resolve(limit).source, SettingValueSource.global);
      expect(reloaded.resolve(limit).hasGlobalOverride, isTrue);

      // A successful save advances the baseline for the next edit.
      saved = host.save(saved.setOverride(enabled, true));
      expect(saved.resolve(enabled).source, SettingValueSource.global);
      expect(saved.resolve(enabled).hasGlobalOverride, isTrue);
      final reset = host.save(saved.resetOverride(enabled));
      expect(reset.resolve<bool>(enabled).value, isTrue);
      expect(reset.resolve(enabled).source, SettingValueSource.defaultValue);
      expect(reset.resolve(enabled).hasGlobalOverride, isFalse);
      expect(other.load().resolve(enabled).hasGlobalOverride, isFalse);
      expect(file.readAsStringSync(), isNot(contains(enabled.value)));
      expect(reset.resetOverride(enabled), same(reset));
    });

    test(
      'comments, unknown unavailable-owner values and tables survive edits',
      () {
        final source =
            '# shared header\n'
            '"${enabled.value}" = true # keep value comment\n'
            '"dev.unavailable.plugin.value" = [1, 2] # keep unknown\n'
            'unrelated = 0x10\n'
            "[other] # keep table\nname  = 'literal'\n";
        seed(source);
        final loaded = host.load();
        expect(loaded.resolve<int>(limit).value, 1000);
        var saved = host.save(loaded.setOverride(enabled, false));
        expect(
          file.readAsStringSync(),
          source.replaceFirst('= true', '= false'),
        );
        saved = host.save(saved.setOverride(limit, 2000));
        saved = host.save(saved.resetOverride(limit));
        expect(
          file.readAsStringSync(),
          source.replaceFirst('= true', '= false'),
        );
        expect(saved.resolve(enabled).hasGlobalOverride, isTrue);
      },
    );

    test('invalid existing structures/types cannot be replaced implicitly', () {
      for (final value in ['[true]', '1.0', '"true"']) {
        final source = '"${enabled.value}" = $value\n';
        seed(source);
        final snapshot = host.load();
        expect(
          () => snapshot.setOverride(enabled, false),
          throwsA(invalid(enabled)),
        );
        expect(file.readAsStringSync(), source);
      }
    });

    test(
      'explicit reset can remove an invalid supported scalar without coercion',
      () {
        seed('"${limit.value}" = 50000\n');
        final snapshot = host.load();
        expect(() => snapshot.resolve(limit), throwsA(invalid(limit)));
        host.save(snapshot.resetOverride(limit));
        expect(
          host.load().resolve(limit).source,
          SettingValueSource.defaultValue,
        );
        expect(file.readAsStringSync(), isNot(contains(limit.value)));
      },
    );

    test('equal-value writes and absent resets preserve bytes and mtime', () {
      final source = '# keep CRLF\r\n"${limit.value}" = 0x3e8 # keep radix\r\n';
      seed(source);
      final marker = DateTime.utc(2001);
      file.setLastModifiedSync(marker);
      final loaded = host.load();
      expect(loaded.resolve(limit).source, SettingValueSource.global);
      expect(loaded.setOverride(limit, 1000), same(loaded));
      expect(host.save(loaded.resetOverride(enabled)), same(loaded));
      expect(file.readAsStringSync(), source);
      expect(file.lastModifiedSync().toUtc(), marker);
      expect(Directory(roots.localStateRoot).existsSync(), isFalse);
    });

    test('stale snapshots, including no-ops, propagate CFG2 conflicts', () {
      final stale = host.load();
      final winner = host.save(host.load().setOverride(enabled, false));
      expect(
        () => host.save(stale.setOverride(limit, 2000)),
        throwsA(isA<ConfigurationConflictException>()),
      );
      expect(
        () => host.save(stale),
        throwsA(isA<ConfigurationConflictException>()),
      );
      expect(file.readAsStringSync(), winner.document.source);
      // External changes are also whole-document conflicts, not merged edits.
      file.writeAsStringSync('${winner.document.source}external = 1\n');
      expect(
        () => host.save(winner.setOverride(limit, 2000)),
        throwsA(isA<ConfigurationConflictException>()),
      );
      expect(file.readAsStringSync(), contains('external = 1'));
    });

    test('snapshot cannot cross catalog or configuration-file boundaries', () {
      final snapshot = host.load().setOverride(enabled, false);
      final foreignCatalog = GlobalSettingsStore(
        store: persistence,
        catalog: SettingsCatalog(catalog.definitions),
      );
      expect(() => foreignCatalog.save(snapshot), throwsArgumentError);
      final foreignRoots = PlatformStorageRoots(
        operatingSystem: Platform.operatingSystem,
        configurationRoot: p.join(root.path, 'other-config'),
        localStateRoot: roots.localStateRoot,
        localDataRoot: roots.localDataRoot,
        cacheRoot: roots.cacheRoot,
      );
      final foreignFile = GlobalSettingsStore(
        store: ConfigurationStore(foreignRoots),
        catalog: catalog,
      );
      expect(() => foreignFile.save(snapshot), throwsArgumentError);
      expect(root.listSync(), isEmpty);
    });

    test('only config and CFG2 local-state lock are touched', () {
      final project = Directory(p.join(root.path, 'project'))..createSync();
      final sentinel = File(p.join(project.path, 'sentinel'))
        ..writeAsStringSync('unchanged');
      final marker = DateTime.utc(2001);
      sentinel.setLastModifiedSync(marker);
      final saved = host.save(host.load().setOverride(enabled, false));
      host.save(saved.resetOverride(enabled));
      expect(Directory(roots.localDataRoot).existsSync(), isFalse);
      expect(Directory(roots.cacheRoot).existsSync(), isFalse);
      expect(sentinel.readAsStringSync(), 'unchanged');
      expect(sentinel.lastModifiedSync().toUtc(), marker);
      expect(
        root
            .listSync(recursive: true)
            .whereType<File>()
            .map((f) => p.relative(f.path, from: root.path)),
        unorderedEquals([
          'config/settings.toml',
          'state/configuration/settings.lock',
          'project/sentinel',
        ]),
      );
    });
  }, skip: !Platform.isLinux);
}
