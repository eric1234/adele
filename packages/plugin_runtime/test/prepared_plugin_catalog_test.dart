import 'dart:convert';
import 'dart:io';

import 'package:adele_plugin_api/adele_plugin_api.dart';
import 'package:plugin_runtime/plugin_runtime.dart';
import 'package:test/test.dart';

void main() {
  late Directory temporary;
  late Directory root;

  setUp(() async {
    temporary = await Directory.systemTemp.createTemp('prepared catalog ');
    root = await Directory.fromUri(
      temporary.uri.resolve('installations/'),
    ).create();
  });
  tearDown(() => temporary.delete(recursive: true));

  Future<Directory> install(String name, Object? manifest) async {
    final directory = await Directory.fromUri(
      root.uri.resolve('$name/'),
    ).create();
    await File.fromUri(
      directory.uri.resolve('adele_plugin.installation.json'),
    ).writeAsString(jsonEncode(manifest));
    await File.fromUri(
      directory.uri.resolve('backend.aot'),
    ).writeAsString('aot');
    return directory;
  }

  test(
    'empty, missing, and empty-directory roots are empty catalogs',
    () async {
      for (final path in ['', '${root.path}/missing', root.path]) {
        final catalog = await PreparedPluginCatalog.discover(path);
        expect(catalog.installations, isEmpty);
        expect(catalog.issues, isEmpty);
      }
    },
  );

  test(
    'existing non-directory roots throw instead of becoming empty',
    () async {
      final file = await File.fromUri(
        root.uri.resolve('not-a-directory'),
      ).writeAsString('file');
      await expectLater(
        PreparedPluginCatalog.discover(file.path),
        throwsA(isA<FileSystemException>()),
      );
    },
  );

  test(
    'genuine root I/O failures propagate',
    () async {
      final loop = Link.fromUri(temporary.uri.resolve('loop'));
      await loop.create(loop.path);
      await expectLater(
        PreparedPluginCatalog.discover(loop.path),
        throwsA(isA<FileSystemException>()),
      );
    },
    skip: Platform.isWindows ? 'Symlink creation requires privileges.' : false,
  );

  test(
    'discovers arbitrary IDs and metadata in sorted directory order',
    () async {
      final z = await install(
        'z-first-created',
        _manifest(id: 'org.example.alpha'),
      );
      final a = await install('a-second-created', {
        'manifestVersion': 1,
        'metadata': {
          'id': 'org.example.zulu',
          'version': 'opaque-version',
          'displayName': 'Metadata Only',
          'description': 'No prepared backend',
        },
        'components': <String, Object?>{},
      });
      await File.fromUri(
        root.uri.resolve('unrelated.txt'),
      ).writeAsString('ignored');
      final catalog = await PreparedPluginCatalog.discover(root.path);
      expect(catalog.issues, isEmpty);
      expect(catalog.installations.map((item) => item.metadata.id), [
        PluginId('org.example.zulu'),
        PluginId('org.example.alpha'),
      ]);
      final metadataOnly = catalog.installations.first;
      expect(metadataOnly.metadata, isA<PluginMetadata>());
      expect(metadataOnly.metadata.version, 'opaque-version');
      expect(metadataOnly.metadata.displayName, 'Metadata Only');
      expect(metadataOnly.metadata.description, 'No prepared backend');
      expect(metadataOnly.installationDirectory.uri, a.uri);
      expect(metadataOnly.backendArtifactUri, isNull);
      final backend = catalog.installations.last;
      expect(backend.metadata.description, isNull);
      expect(backend.installationDirectory.uri, z.uri);
      expect(backend.backendArtifactUri, z.uri.resolve('backend.aot'));
      expect(backend.backendArtifactUri!.scheme, 'file');
      expect(backend.backendArtifactUri!.isAbsolute, isTrue);
      expect(() => catalog.installations.clear(), throwsUnsupportedError);
      expect(() => catalog.issues.clear(), throwsUnsupportedError);
    },
  );

  test(
    'source manifests are never interpreted as installed manifests',
    () async {
      final source = await Directory.fromUri(
        root.uri.resolve('source/'),
      ).create();
      await File.fromUri(
        source.uri.resolve('adele_plugin.yaml'),
      ).writeAsString('id: org.example.source\nbackend: backend.aot\n');
      await install('prepared', _manifest());
      final catalog = await PreparedPluginCatalog.discover(root.path);
      expect(catalog.installations, hasLength(1));
      expect(catalog.issues.single.installationDirectory.uri, source.uri);
    },
  );

  test(
    'missing and malformed manifests are isolated and deterministic',
    () async {
      await Directory.fromUri(root.uri.resolve('a-missing/')).create();
      final broken = await install('b-invalid-json', _manifest());
      await File.fromUri(
        broken.uri.resolve('adele_plugin.installation.json'),
      ).writeAsString('{');
      await install('c-valid', _manifest());
      final catalog = await PreparedPluginCatalog.discover(root.path);
      expect(catalog.installations, hasLength(1));
      expect(catalog.issues.map((issue) => issue.installationDirectory.uri), [
        root.uri.resolve('a-missing/'),
        root.uri.resolve('b-invalid-json/'),
      ]);
      expect(
        catalog.issues.map((issue) => issue.message),
        everyElement(isNotEmpty),
      );
    },
  );

  final invalidDocuments = <String, Object?>{
    'null document': null,
    'array document': [],
    'missing version': {..._manifest()}..remove('manifestVersion'),
    'unknown version': {..._manifest(), 'manifestVersion': 2},
    'double version': {..._manifest(), 'manifestVersion': 1.0},
    'string version': {..._manifest(), 'manifestVersion': '1'},
    'boolean version': {..._manifest(), 'manifestVersion': true},
    'missing metadata': {..._manifest()}..remove('metadata'),
    'array metadata': {..._manifest(), 'metadata': <Object?>[]},
    'missing components': {..._manifest()}..remove('components'),
    'null components': {..._manifest(), 'components': null},
    'array components': {..._manifest(), 'components': <Object?>[]},
    'unknown component': {
      ..._manifest(),
      'components': {'frontend': <String, Object?>{}},
    },
    'null backend': {
      ..._manifest(),
      'components': {'backend': null},
    },
    'array backend': {
      ..._manifest(),
      'components': {'backend': <Object?>[]},
    },
    'missing artifact': {
      ..._manifest(),
      'components': {'backend': <String, Object?>{}},
    },
    for (final field in [
      'exposures',
      'configuration',
      'state',
      'source',
      'backend',
    ])
      'unsupported $field': {..._manifest(), field: <String, Object?>{}},
    'backend source path': {
      ..._manifest(),
      'components': {
        'backend': {'artifact': 'backend.aot', 'entrypoint': 'bin/main.dart'},
      },
    },
  };
  for (final entry in invalidDocuments.entries) {
    test('rejects ${entry.key}', () async {
      await install('bad', entry.value);
      await install('good', _manifest(id: 'org.example.unrelated'));
      final catalog = await PreparedPluginCatalog.discover(root.path);
      expect(
        catalog.installations.single.metadata.id.value,
        'org.example.unrelated',
      );
      expect(catalog.issues, hasLength(1));
    });
  }

  for (final field in ['id', 'version', 'displayName', 'description']) {
    for (final value in <Object?>[null, 1, false, [], {}]) {
      test('rejects non-string metadata $field: $value', () async {
        final manifest = _manifest();
        (manifest['metadata']! as Map<String, Object?>)[field] = value;
        await install('bad', manifest);
        final catalog = await PreparedPluginCatalog.discover(root.path);
        expect(catalog.installations, isEmpty);
        expect(catalog.issues, hasLength(1));
      });
    }
    if (field == 'description') continue;
    for (final value in ['', '  ', null]) {
      test('rejects missing or blank metadata $field: $value', () async {
        final manifest = _manifest();
        final metadata = manifest['metadata']! as Map<String, Object?>;
        if (value == null) {
          metadata.remove(field);
        } else {
          metadata[field] = value;
        }
        await install('bad', manifest);
        final catalog = await PreparedPluginCatalog.discover(root.path);
        expect(catalog.installations, isEmpty);
        expect(catalog.issues, hasLength(1));
      });
    }
  }

  test('rejects invalid PluginId and unknown metadata fields', () async {
    await install('invalid-id', _manifest(id: 'not namespaced'));
    final manifest = _manifest();
    (manifest['metadata']! as Map<String, Object?>)['source'] = 'plugin.dart';
    await install('unknown-field', manifest);
    final catalog = await PreparedPluginCatalog.discover(root.path);
    expect(catalog.installations, isEmpty);
    expect(catalog.issues, hasLength(2));
  });

  for (final artifact in <Object?>[
    null,
    1,
    false,
    [],
    {},
    '',
    ' ',
    '/',
    '/tmp/backend.aot',
    '../backend.aot',
    'lib/../../backend.aot',
    'lib/../backend.aot',
    './backend.aot',
    'lib/./backend.aot',
    'lib//backend.aot',
    'lib/',
    r'C:\backend.aot',
    'C:/backend.aot',
    r'lib\backend.aot',
    r'\\server\backend.aot',
    '//server/backend.aot',
    'file:backend.aot',
    'file:///tmp/backend.aot',
    'https://example.com/aot',
    'backend.aot?query',
    'backend.aot#fragment',
    'bad|name.aot',
    'bad*.aot',
    'bad<name.aot',
    'bad>name.aot',
    'bad"name.aot',
    '%2e%2e/backend.aot',
    'backend.aot\u0000',
  ]) {
    test('rejects invalid artifact path: ${jsonEncode(artifact)}', () async {
      await install('bad', _manifest(artifact: artifact));
      final catalog = await PreparedPluginCatalog.discover(root.path);
      expect(catalog.installations, isEmpty);
      expect(catalog.issues, hasLength(1));
    });
  }

  test(
    'requires existing regular artifacts but allows nested relative files',
    () async {
      await install(
        'missing',
        _manifest(id: 'org.example.missing', artifact: 'absent.aot'),
      );
      final folder = await install(
        'directory',
        _manifest(id: 'org.example.directory'),
      );
      await File.fromUri(folder.uri.resolve('backend.aot')).delete();
      await Directory.fromUri(folder.uri.resolve('backend.aot/')).create();
      final nested = await install(
        'nested',
        _manifest(artifact: 'lib/backend file.aot'),
      );
      await Directory.fromUri(nested.uri.resolve('lib/')).create();
      await File.fromUri(
        nested.uri.resolve('lib/backend%20file.aot'),
      ).writeAsString('aot');
      final catalog = await PreparedPluginCatalog.discover(root.path);
      expect(
        catalog.installations.single.backendArtifactUri,
        nested.uri.resolve('lib/backend%20file.aot'),
      );
      expect(catalog.issues, hasLength(2));
    },
  );

  test(
    'rejects non-regular artifacts without trying to read them',
    () async {
      final directory = await install('pipe', _manifest(artifact: 'pipe.aot'));
      final result = await Process.run('mkfifo', [
        '${directory.path}/pipe.aot',
      ]);
      expect(result.exitCode, 0);
      final catalog = await PreparedPluginCatalog.discover(root.path);
      expect(catalog.installations, isEmpty);
      expect(catalog.issues.single.message, contains('regular file'));
    },
    skip: !Platform.isLinux,
  );

  for (final malformedFirst in [false, true]) {
    test(
      'all duplicate identities excluded, malformed first=$malformedFirst',
      () async {
        await install(
          malformedFirst ? 'a' : 'c',
          _manifest(artifact: 'absent.aot'),
        );
        await install('b', _manifest());
        await install(malformedFirst ? 'c' : 'a', {
          ..._manifest(),
          'components': <String, Object?>{},
        });
        await install('unrelated', _manifest(id: 'org.example.unrelated'));
        final catalog = await PreparedPluginCatalog.discover(root.path);
        expect(
          catalog.installations.single.metadata.id.value,
          'org.example.unrelated',
        );
        final conflicts = catalog.issues.where(
          (issue) => issue.message.contains('Duplicate PluginId'),
        );
        expect(conflicts, hasLength(3));
        expect(
          conflicts.map((issue) => issue.pluginId),
          everyElement(PluginId('org.example.plugin')),
        );
        expect(catalog.issues, hasLength(4));
      },
    );
  }

  test(
    'valid identity in otherwise invalid metadata still conflicts',
    () async {
      final invalid = _manifest();
      (invalid['metadata']! as Map<String, Object?>).remove('version');
      await install('invalid', invalid);
      await install('valid', _manifest());
      final catalog = await PreparedPluginCatalog.discover(root.path);
      expect(catalog.installations, isEmpty);
      expect(
        catalog.issues.where(
          (issue) => issue.message.contains('Duplicate PluginId'),
        ),
        hasLength(2),
      );
    },
  );

  group(
    'symlink confinement',
    () {
      test(
        'rejects artifact and ancestor escapes, even to prefix sibling',
        () async {
          final direct = await install(
            'direct',
            _manifest(id: 'org.example.direct'),
          );
          final sibling = await Directory.fromUri(
            root.uri.resolve('direct-outside/'),
          ).create();
          final outside = await File.fromUri(
            sibling.uri.resolve('backend.aot'),
          ).writeAsString('outside');
          await File.fromUri(direct.uri.resolve('backend.aot')).delete();
          await Link.fromUri(
            direct.uri.resolve('backend.aot'),
          ).create(outside.path);
          final ancestor = await install(
            'ancestor',
            _manifest(
              id: 'org.example.ancestor',
              artifact: 'linked/backend.aot',
            ),
          );
          await Link.fromUri(
            ancestor.uri.resolve('linked'),
          ).create(sibling.path);
          // The sibling is outside the installation, but deliberately shares its prefix.
          final catalog = await PreparedPluginCatalog.discover(root.path);
          expect(catalog.installations, isEmpty);
          expect(
            catalog.issues.where(
              (issue) => issue.message.contains('outside the installation'),
            ),
            hasLength(2),
          );
        },
      );

      test('accepts an artifact link confined to its installation', () async {
        final directory = await install(
          'inside',
          _manifest(artifact: 'linked.aot'),
        );
        await Link.fromUri(
          directory.uri.resolve('linked.aot'),
        ).create('backend.aot');
        final catalog = await PreparedPluginCatalog.discover(root.path);
        expect(catalog.issues, isEmpty);
        expect(
          catalog.installations.single.backendArtifactUri,
          directory.uri.resolve('backend.aot'),
        );
      });

      test('rejects manifest escape and symlinked installation', () async {
        final outside = await File.fromUri(
          temporary.uri.resolve('manifest.json'),
        ).writeAsString(jsonEncode(_manifest()));
        final directory = await install('manifest-link', _manifest());
        final manifestUri = directory.uri.resolve(
          'adele_plugin.installation.json',
        );
        await File.fromUri(manifestUri).delete();
        await Link.fromUri(manifestUri).create(outside.path);
        await Link.fromUri(
          root.uri.resolve('directory-link'),
        ).create(temporary.path);
        final catalog = await PreparedPluginCatalog.discover(root.path);
        expect(catalog.installations, isEmpty);
        expect(catalog.issues, hasLength(2));
      });

      test('rejects dangling artifact link', () async {
        final directory = await install(
          'dangling',
          _manifest(artifact: 'linked.aot'),
        );
        await Link.fromUri(
          directory.uri.resolve('linked.aot'),
        ).create('missing.aot');
        final catalog = await PreparedPluginCatalog.discover(root.path);
        expect(catalog.installations, isEmpty);
        expect(catalog.issues, hasLength(1));
      });
    },
    skip: Platform.isWindows ? 'Symlink creation requires privileges.' : false,
  );
}

Map<String, Object?> _manifest({
  String id = 'org.example.plugin',
  Object? artifact = 'backend.aot',
}) => {
  'manifestVersion': 1,
  'metadata': <String, Object?>{
    'id': id,
    'version': '0.1.0',
    'displayName': 'Example',
  },
  'components': {
    'backend': {'artifact': artifact},
  },
};
