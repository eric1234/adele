import 'dart:io';

import 'package:adele_platform_storage/adele_platform_storage.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  group('Linux', () {
    test('uses standard XDG default bases under injected home', () {
      final roots = PlatformStorageRoots.resolve(
        operatingSystem: 'linux',
        environment: const {'HOME': '/ignored'},
        homeDirectory: '/home/test',
      );

      expect(_roots(roots), [
        '/home/test/.config/adele/config',
        '/home/test/.local/state/adele/state',
        '/home/test/.local/share/adele/data',
        '/home/test/.cache/adele/cache',
      ]);
    });

    test('accepts all absolute XDG overrides without needing home', () {
      final roots = PlatformStorageRoots.resolve(
        operatingSystem: 'linux',
        environment: const {
          'XDG_CONFIG_HOME': '/storage/settings/',
          'XDG_STATE_HOME': '/storage/unused/../state',
          'XDG_DATA_HOME': '/storage/local data',
          'XDG_CACHE_HOME': '/storage/cache',
        },
      );

      expect(_roots(roots), [
        '/storage/settings/adele/config',
        '/storage/state/adele/state',
        '/storage/local data/adele/data',
        '/storage/cache/adele/cache',
      ]);
    });

    test(
      'falls back per domain and uses HOME from the injected environment',
      () {
        final roots = PlatformStorageRoots.resolve(
          operatingSystem: 'linux',
          environment: const {
            'HOME': '/home/test',
            'XDG_CONFIG_HOME': '/custom/settings',
            'XDG_STATE_HOME': '',
            'XDG_DATA_HOME': 'relative/data',
          },
        );

        expect(_roots(roots), [
          '/custom/settings/adele/config',
          '/home/test/.local/state/adele/state',
          '/home/test/.local/share/adele/data',
          '/home/test/.cache/adele/cache',
        ]);
      },
    );

    test('ignores empty and relative overrides for every XDG domain', () {
      for (final invalid in ['', 'relative', '~/storage', r'C:\storage']) {
        final roots = PlatformStorageRoots.resolve(
          operatingSystem: 'linux',
          homeDirectory: '/home/test',
          environment: {for (final key in _xdgKeys) key: invalid},
        );

        expect(_roots(roots), [
          '/home/test/.config/adele/config',
          '/home/test/.local/state/adele/state',
          '/home/test/.local/share/adele/data',
          '/home/test/.cache/adele/cache',
        ], reason: invalid);
      }
    });

    test('equal bases retain four distinct and stable domain roots', () {
      final environment = {for (final key in _xdgKeys) key: '/shared'};
      final roots = PlatformStorageRoots.resolve(
        operatingSystem: 'linux',
        environment: environment,
      );

      expect(_roots(roots), [
        '/shared/adele/config',
        '/shared/adele/state',
        '/shared/adele/data',
        '/shared/adele/cache',
      ]);
      environment['XDG_CACHE_HOME'] = '/other';
      final changed = PlatformStorageRoots.resolve(
        operatingSystem: 'linux',
        environment: environment,
      );
      expect(_roots(changed).take(3), _roots(roots).take(3));
      expect(changed.cacheRoot, '/other/adele/cache');
      expect(roots.cacheRoot, '/shared/adele/cache');
    });

    test('invalid XDG overrides still require a valid home for defaults', () {
      expect(
        () => PlatformStorageRoots.resolve(
          operatingSystem: 'linux',
          environment: {
            for (final key in _xdgKeys) key: '/valid',
            'XDG_CACHE_HOME': 'relative',
          },
        ),
        _invalidInput('HOME'),
      );
    });
  });

  group('macOS', () {
    test('uses separate Application Support domains and Caches', () {
      final roots = PlatformStorageRoots.resolve(
        operatingSystem: 'macos',
        environment: const {
          'HOME': '/Users/test',
          'XDG_CONFIG_HOME': '/ignored',
        },
      );

      expect(_roots(roots), [
        '/Users/test/Library/Application Support/ADELE/config',
        '/Users/test/Library/Application Support/ADELE/state',
        '/Users/test/Library/Application Support/ADELE/data',
        '/Users/test/Library/Caches/ADELE',
      ]);
    });

    test('honors and normalizes explicit home instead of environment HOME', () {
      final roots = PlatformStorageRoots.resolve(
        operatingSystem: 'macos',
        environment: const {'HOME': '/ignored'},
        homeDirectory: '/Users/scratch/../test/',
      );

      expect(
        roots.configurationRoot,
        '/Users/test/Library/Application Support/ADELE/config',
      );
    });
  });

  for (final operatingSystem in ['linux', 'macos']) {
    test('$operatingSystem rejects missing or invalid required home', () {
      for (final home in [null, '', 'relative', '~/home', '/home/\x00test']) {
        expect(
          () => PlatformStorageRoots.resolve(
            operatingSystem: operatingSystem,
            environment: {'HOME': ?home},
          ),
          _invalidInput('HOME'),
          reason: 'HOME: $home',
        );
        if (home != null) {
          expect(
            () => PlatformStorageRoots.resolve(
              operatingSystem: operatingSystem,
              environment: const {'HOME': '/valid'},
              homeDirectory: home,
            ),
            _invalidInput('homeDirectory'),
            reason: 'homeDirectory: $home',
          );
        }
      }
    });
  }

  group('Windows', () {
    test(
      'separates roaming configuration from local state, data, and cache',
      () {
        final roots = PlatformStorageRoots.resolve(
          operatingSystem: 'windows',
          environment: const {
            'APPDATA': r'C:\Users\test\AppData\Roaming',
            'LOCALAPPDATA': 'D:/Local Data/',
          },
        );

        expect(_roots(roots), [
          r'C:\Users\test\AppData\Roaming\ADELE\config',
          r'D:\Local Data\ADELE\state',
          r'D:\Local Data\ADELE\data',
          r'D:\Local Data\ADELE\cache',
        ]);
      },
    );

    test('supports complete UNC shares and both separator styles', () {
      final roots = PlatformStorageRoots.resolve(
        operatingSystem: 'windows',
        environment: const {
          'APPDATA': r'\\server\roaming',
          'LOCALAPPDATA': '//server/local/test',
        },
      );

      expect(_roots(roots), [
        r'\\server\roaming\ADELE\config',
        r'\\server\local\test\ADELE\state',
        r'\\server\local\test\ADELE\data',
        r'\\server\local\test\ADELE\cache',
      ]);
    });

    test(
      'keeps distinct domains with equal bases and does not require home',
      () {
        final roots = PlatformStorageRoots.resolve(
          operatingSystem: 'windows',
          environment: const {
            'APPDATA': r'C:\shared',
            'LOCALAPPDATA': r'C:\shared',
          },
          homeDirectory: 'unused',
        );

        expect(_roots(roots), [
          r'C:\shared\ADELE\config',
          r'C:\shared\ADELE\state',
          r'C:\shared\ADELE\data',
          r'C:\shared\ADELE\cache',
        ]);
      },
    );

    for (final key in ['APPDATA', 'LOCALAPPDATA']) {
      test('rejects missing and non-fully-qualified $key', () {
        for (final invalid in [
          null,
          '',
          'relative',
          'C:',
          r'C:relative',
          r'\rooted',
          '/rooted',
          r'\\server',
          '\\\\server\\',
          r'\\server\\share',
          r'\\.\pipe',
          r'\\?\C:\data',
          'C:\\nul\x00',
        ]) {
          final environment = {
            'APPDATA': r'C:\roaming',
            'LOCALAPPDATA': r'C:\local',
            'USERPROFILE': r'C:\Users\test',
            'HOME': r'C:\Users\test',
          }..remove(key);
          if (invalid != null) environment[key] = invalid;
          expect(
            () => PlatformStorageRoots.resolve(
              operatingSystem: 'windows',
              environment: environment,
              homeDirectory: r'C:\Users\test',
            ),
            _invalidInput(key),
            reason: '$key: $invalid',
          );
        }
      });
    }
  });

  group('explicit roots', () {
    test('normalizes injected roots independently of host path syntax', () {
      final roots = PlatformStorageRoots(
        operatingSystem: 'windows',
        configurationRoot: 'C:/fixture/unused/../config/',
        localStateRoot: r'C:\fixture\state',
        localDataRoot: r'C:\fixture\data',
        cacheRoot: r'C:\fixture\cache',
      );

      expect(_roots(roots), [
        r'C:\fixture\config',
        r'C:\fixture\state',
        r'C:\fixture\data',
        r'C:\fixture\cache',
      ]);
    });

    test('rejects relative roots', () {
      expect(
        () => PlatformStorageRoots(
          operatingSystem: 'linux',
          configurationRoot: '/fixture/config',
          localStateRoot: '/fixture/state',
          localDataRoot: '/fixture/data',
          cacheRoot: 'relative',
        ),
        _invalidInput('cacheRoot'),
      );
    });

    test(
      'rejects normalized aliases, including Windows case and separators',
      () {
        for (final operatingSystem in ['linux', 'windows']) {
          final prefix = operatingSystem == 'windows' ? 'C:' : '';
          expect(
            () => PlatformStorageRoots(
              operatingSystem: operatingSystem,
              configurationRoot: '$prefix/fixture/config/../state',
              localStateRoot: operatingSystem == 'windows'
                  ? r'c:\FIXTURE\state'
                  : '/fixture/state',
              localDataRoot: '$prefix/fixture/data',
              cacheRoot: '$prefix/fixture/cache',
            ),
            throwsA(
              isA<ArgumentError>().having(
                (error) => error.message,
                'message',
                contains('distinct'),
              ),
            ),
          );
        }
      },
    );
  });

  test('unsupported operating systems fail explicitly', () {
    for (final operatingSystem in [
      'android',
      'ios',
      'freebsd',
      'unknown',
      '',
    ]) {
      expect(
        () => PlatformStorageRoots.resolve(
          operatingSystem: operatingSystem,
          environment: const {},
        ),
        throwsA(
          isA<UnsupportedError>().having(
            (error) => error.message,
            'message',
            contains('Unsupported operating system: $operatingSystem'),
          ),
        ),
      );
    }
  });

  test('all platform resolutions work without any filesystem handles', () {
    IOOverrides.runZoned(
      () {
        for (final operatingSystem in ['linux', 'macos', 'windows']) {
          final roots = PlatformStorageRoots.resolve(
            operatingSystem: operatingSystem,
            homeDirectory: '/synthetic/home',
            environment: const {
              'APPDATA': r'C:\roaming',
              'LOCALAPPDATA': r'C:\local',
            },
          );
          expect(_roots(roots).toSet(), hasLength(4));
        }
      },
      createDirectory: (path) =>
          throw StateError('Unexpected directory: $path'),
      createFile: (path) => throw StateError('Unexpected file: $path'),
      createLink: (path) => throw StateError('Unexpected link: $path'),
    );
  });

  test('resolution does not create directories under an isolated fixture', () {
    final fixture = Directory.systemTemp.createTempSync(
      'adele_platform_storage_',
    );
    addTearDown(() => fixture.deleteSync(recursive: true));
    final roots = PlatformStorageRoots.resolve(
      operatingSystem: Platform.operatingSystem,
      homeDirectory: p.join(fixture.path, 'home'),
      environment: {
        'APPDATA': p.join(fixture.path, 'roaming'),
        'LOCALAPPDATA': p.join(fixture.path, 'local'),
      },
    );

    for (final root in _roots(roots)) {
      expect(Directory(root).existsSync(), isFalse);
    }
    expect(fixture.listSync(), isEmpty);
  });
}

const _xdgKeys = [
  'XDG_CONFIG_HOME',
  'XDG_STATE_HOME',
  'XDG_DATA_HOME',
  'XDG_CACHE_HOME',
];

List<String> _roots(PlatformStorageRoots roots) => [
  roots.configurationRoot,
  roots.localStateRoot,
  roots.localDataRoot,
  roots.cacheRoot,
];

Matcher _invalidInput(String name) => throwsA(
  isA<ArgumentError>()
      .having((error) => error.name, 'name', name)
      .having((error) => error.message, 'message', contains('directory path')),
);
