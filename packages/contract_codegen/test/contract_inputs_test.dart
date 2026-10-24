import 'dart:convert';
import 'dart:io' as io;
import 'dart:typed_data';

import 'package:analyzer/dart/analysis/analysis_context_collection.dart';
import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer/file_system/file_system.dart';
import 'package:analyzer/file_system/overlay_file_system.dart';
import 'package:contract_codegen/src/contract_inputs.dart';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'support/contract_generator_support.dart' show repositoryRoot;

void main() {
  late io.Directory directory;
  late io.File source;
  late String output;

  setUp(() {
    directory = io.Directory.systemTemp.createTempSync('contract_inputs.');
    source = _write(directory, 'source.dart', 'library;');
    output = p.setExtension(source.path, '.g.dart');
  });
  tearDown(() => directory.deleteSync(recursive: true));

  test('hashes exact bytes and wraps every resource navigation route', () {
    final bytes = [0xef, 0xbb, 0xbf, ...utf8.encode('library;\r\n')];
    source.writeAsBytesSync(bytes);
    final inputs = ContractInputs(excludedOutput: output);
    final file = inputs.resources.getFile(source.path);
    expect(file.readAsStringSync(), 'library;\r\n');
    expect(file.readAsBytesSync(), bytes);
    expect(file.lengthSync, bytes.length);
    expect(
      file.modificationStamp,
      source.lastModifiedSync().millisecondsSinceEpoch,
    );
    expect(file.exists, isTrue);
    expect(inputs.resources.getFolder(source.path).exists, isFalse);
    expect(inputs.resources.getResource(source.path), isA<File>());
    expect(inputs.resources.getResource(directory.path), isA<Folder>());
    expect(file.provider, same(inputs.resources));
    expect(file.parent.provider, same(inputs.resources));
    expect(file.resolveSymbolicLinksSync().provider, same(inputs.resources));
    expect(
      file.parent.resolveSymbolicLinksSync().provider,
      same(inputs.resources),
    );
    expect(
      file.parent.getChild('source.dart').provider,
      same(inputs.resources),
    );
    expect(
      file.parent.getChildAssumingFile('source.dart').provider,
      same(inputs.resources),
    );
    expect(
      file.parent.getChildAssumingFolder('sub').provider,
      same(inputs.resources),
    );
    expect(
      file.parent.getChildren().map((child) => child.provider),
      everyElement(same(inputs.resources)),
    );
    expect(
      inputs.observations[jsonEncode(['read', source.path])],
      sha256.convert(bytes).toString(),
    );
    _validate(inputs);
  });

  test(
    'excludes only its exact output from probes and directory inventories',
    () {
      final inputs = ContractInputs(excludedOutput: output);
      final folder = inputs.resources.getFolder(directory.path);
      folder.exists;
      folder.getChildren();
      final listingKey = jsonEncode(['directory', directory.path, output]);
      final listing = inputs.observations[listingKey];
      io.File(output).writeAsStringSync('generated');
      expect(inputs.resources.getFile(output).readAsStringSync(), 'generated');
      expect(folder.getChildren().map((child) => child.path), contains(output));
      expect(inputs.observations[listingKey], listing);
      expect(inputs.observations.keys.map(_path), isNot(contains(output)));
      _validate(inputs);
      _write(directory, 'other.g.dart', 'other generated part');
      expect(ContractInputs.observe(listingKey), isNot(listing));
      expect(inputs.validate, throwsStateError);
    },
  );

  test(
    'records missing files, failed reads and failed canonical resolution',
    () {
      final inputs = ContractInputs(excludedOutput: output);
      final path = p.join(directory.path, 'absent.dart');
      final file = inputs.resources.getFile(path);
      expect(file.exists, isFalse);
      expect(() => file.lengthSync, throwsA(isA<FileSystemException>()));
      expect(() => file.modificationStamp, throwsA(isA<FileSystemException>()));
      expect(file.readAsBytesSync, throwsA(isA<FileSystemException>()));
      expect(file.readAsStringSync, throwsA(isA<FileSystemException>()));
      expect(
        file.resolveSymbolicLinksSync,
        throwsA(isA<FileSystemException>()),
      );
      expect(
        inputs.resources.getFolder(path).getChildren,
        throwsA(isA<FileSystemException>()),
      );
      _validate(inputs);
      io.File(path).writeAsStringSync('new input');
      expect(inputs.validate, throwsStateError);
      expect(inputs.cacheable, isFalse);
    },
  );

  test('resource type changes invalidate even without reading contents', () {
    final inputs = ContractInputs(excludedOutput: output);
    expect(inputs.resources.getResource(source.path), isA<File>());
    source.deleteSync();
    io.Directory(source.path).createSync();
    expect(inputs.validate, throwsStateError);
  });

  test('directory existence probes ignore unrelated child creation', () {
    final nested = io.Directory(p.join(directory.path, 'nested'))..createSync();
    final inputs = ContractInputs(excludedOutput: output);
    expect(inputs.resources.getFolder(nested.path).exists, isTrue);
    inputs.resources.getResource(nested.path);
    _write(nested, 'unrelated.dart', 'library;');
    _validate(inputs);
  });

  test(
    'symlink targets and aliases of the excluded output remain inputs',
    () {
      final first = _write(directory, 'first.dart', 'identical');
      final second = _write(directory, 'second.dart', 'identical');
      final link = io.Link(p.join(directory.path, 'alias.dart'))
        ..createSync(first.path);
      final inputs = ContractInputs(excludedOutput: output);
      inputs.resources.getFile(link.path).readAsStringSync();
      _validate(inputs);
      link.updateSync(second.path);
      expect(inputs.validate, throwsStateError);

      io.File(output).writeAsStringSync('generated');
      link.updateSync(output);
      final aliases = ContractInputs(excludedOutput: output);
      aliases.resources.getFile(link.path).readAsStringSync();
      _validate(aliases);
      io.File(output).writeAsStringSync('changed');
      expect(
        () => aliases.validate(writtenOutputs: {output}),
        throwsStateError,
      );
    },
    skip: io.Platform.isWindows
        ? 'Symlink creation requires host privileges.'
        : false,
  );

  test(
    'detects edit and restore even with restored contents and mtime',
    () {
      final inputs = ContractInputs(excludedOutput: output);
      inputs.resources.getFile(source.path).readAsStringSync();
      final modified = source.lastModifiedSync();
      io.sleep(const Duration(milliseconds: 20));
      source.writeAsStringSync('changed!');
      source.writeAsStringSync('library;');
      source.setLastModifiedSync(modified);
      expect(inputs.validate, throwsStateError);
    },
    skip: io.Platform.isWindows
        ? 'Windows changed time is creation time, not POSIX ctime.'
        : false,
  );

  test('mid-read mutation fails closed and remains sticky', () {
    final inputs = ContractInputs(excludedOutput: output);
    final proxy = _MutatingFile(source, () {
      source.writeAsStringSync('changed content during read');
    });
    expect(
      () => io.IOOverrides.runZoned(
        () => inputs.resources.getFile(source.path).readAsStringSync(),
        createFile: (path) {
          expect(path, source.path);
          return proxy;
        },
      ),
      throwsStateError,
    );
    expect(inputs.cacheable, isFalse);
    expect(inputs.validate, throwsStateError);
  });

  test('binds returned text to raw bytes despite identical stat evidence', () {
    final inputs = ContractInputs(excludedOutput: output);
    final originalStat = source.statSync();
    final proxy = _MutatingFile(source, () {
      source.writeAsStringSync('changed;');
    });
    expect(
      () => io.IOOverrides.runZoned(
        () => inputs.resources.getFile(source.path).readAsStringSync(),
        createFile: (_) => proxy,
        statSync: (_) => originalStat,
      ),
      throwsStateError,
    );
    expect(inputs.cacheable, isFalse);
    expect(inputs.validate, throwsStateError);
  });

  test('owned writes stay observed and exempt only exact validation paths', () {
    final other = _write(directory, 'other/owned.g.dart', 'old generated part');
    final inputs = ContractInputs(excludedOutput: output);
    inputs.resources.getFile(other.path).readAsStringSync();
    inputs.resources.getFolder(other.parent.path).exists;
    _validate(inputs);
    other.writeAsStringSync('new generated part');
    inputs.validate(writtenOutputs: {other.path});
    expect(
      inputs.observations[jsonEncode(['read', other.path])],
      sha256.convert(utf8.encode('old generated part')).toString(),
    );
    expect(inputs.validate, throwsStateError);
  });

  test('unsupported operations delegate but decline certification', () {
    final links = ContractInputs(excludedOutput: output);
    links.resources.getLink(source.path);
    expect(links.cacheable, isFalse);
    final writes = ContractInputs(excludedOutput: output);
    writes.resources.getFile(source.path).writeAsStringSync('new contents');
    expect(source.readAsStringSync(), 'new contents');
    expect(writes.cacheable, isFalse);
    writes.validate();
  });

  test('warm validation rejects unknown or malformed observation keys', () {
    for (final key in [
      'not JSON',
      '[]',
      '["read", "relative"]',
      jsonEncode(['unknown', source.path]),
      jsonEncode(['read', source.path, 'extra']),
      jsonEncode(['directory', directory.path]),
    ]) {
      expect(() => ContractInputs.observe(key), throwsFormatException);
      expect(() => ContractInputs.stamp(key), throwsFormatException);
      expect(() => ContractInputs.validateKey(key), throwsFormatException);
    }
  });

  test(
    'discovers transitive directive alternatives and actual context metadata',
    () async {
      for (final name in ['a', 'b', 'c', 'd', 'doc', 'transitive']) {
        _write(
          directory,
          'lib/$name.dart',
          name == 'b' ? "export 'transitive.dart';" : 'library;',
        );
      }
      final root = _write(directory, 'lib/root.dart', '''
/// @docImport 'doc.dart';
library;
import 'a.dart' if (dart.library.io) 'b.dart' if (test.absent) 'missing.dart';
export 'c.dart' if (test.export) 'd.dart';
part 'other.g.dart';
part 'root.g.dart';
''');
      _write(directory, 'lib/other.g.dart', "part of 'root.dart';");
      final config = _write(
        directory,
        '.dart_tool/package_config.json',
        jsonEncode({
          'configVersion': 2,
          'packages': [
            {
              'name': 'fixture',
              'rootUri': '../',
              'packageUri': 'lib/',
              'languageVersion': '3.10',
            },
          ],
        }),
      );
      final options = _write(
        directory,
        'analysis_options.yaml',
        'include: config/base.yaml\n',
      );
      final included = _write(
        directory,
        'config/base.yaml',
        'include: nested.yaml\n',
      );
      final nested = _write(
        directory,
        'config/nested.yaml',
        'analyzer:\n  errors:\n    unused_import: ignore\n',
      );
      final excluded = p.setExtension(root.path, '.g.dart');
      final inputs = ContractInputs(excludedOutput: excluded);
      final overlay = OverlayResourceProvider(inputs.resources)
        ..setOverlay(
          excluded,
          content: "part of 'root.dart';",
          modificationStamp: 0,
        );
      final collection = AnalysisContextCollection(
        includedPaths: [root.path],
        resourceProvider: overlay,
      );
      addTearDown(collection.dispose);
      final context = collection.contextFor(root.path);
      inputs.discover(context, root.path);
      expect(
        await context.currentSession.getResolvedUnit(root.path),
        isA<ResolvedUnitResult>(),
      );
      _validate(inputs);
      final reads = inputs.observations.keys
          .where((key) => (jsonDecode(key) as List<Object?>)[0] == 'read')
          .map(_path)
          .toSet();
      expect(
        reads,
        containsAll([
          root.path,
          config.path,
          options.path,
          included.path,
          nested.path,
          for (final name in [
            'a',
            'b',
            'c',
            'd',
            'doc',
            'transitive',
            'other.g',
          ])
            p.join(directory.path, 'lib/$name.dart'),
        ]),
      );
      expect(
        reads.any((path) => path.endsWith(p.join('core', 'bool.dart'))),
        isTrue,
      );
      expect(
        reads.any((path) => path.endsWith(p.join('async', 'future.dart'))),
        isTrue,
      );
      expect(reads.any((path) => p.basename(path) == 'libraries.dart'), isTrue);
      expect(reads, isNot(contains(excluded)));
      final missingKey = jsonEncode([
        'file',
        p.join(directory.path, 'lib/missing.dart'),
      ]);
      expect(inputs.observations[missingKey], 'false');
      nested.writeAsStringSync(
        'analyzer:\n  errors:\n    unused_import: error\n',
      );
      expect(inputs.validate, throwsStateError);
    },
  );

  test(
    'canonicalizes inactive file imports before generated package fallback',
    () {
      final workspace = io.Directory(p.join(directory.path, 'workspace'))
        ..createSync();
      final external = io.Directory(p.join(directory.path, 'external'))
        ..createSync();
      final alternative = _write(external, 'lib/a.dart', "import 'b.dart';");
      final root = _write(
        workspace,
        'lib/root.dart',
        "import 'a.dart' if (test.alternative) '${alternative.uri}';",
      );
      _write(workspace, 'lib/a.dart', 'library;');
      final generated = _write(
        workspace,
        '.dart_tool/build/generated/external/lib/b.dart',
        "export 'c.dart';",
      );
      final transitive = _write(
        workspace,
        '.dart_tool/build/generated/external/lib/c.dart',
        'library;',
      );
      _write(
        workspace,
        '.dart_tool/package_config.json',
        jsonEncode({
          'configVersion': 2,
          'packages': [
            {
              'name': 'fixture',
              'rootUri': '../',
              'packageUri': 'lib/',
              'languageVersion': '3.10',
            },
            {
              'name': 'external',
              'rootUri': external.uri.toString(),
              'packageUri': 'lib/',
              'languageVersion': '3.10',
            },
          ],
        }),
      );
      final inputs = ContractInputs(
        excludedOutput: p.setExtension(root.path, '.g.dart'),
      );
      final collection = AnalysisContextCollection(
        includedPaths: [root.path],
        resourceProvider: inputs.resources,
      );
      addTearDown(collection.dispose);
      inputs.discover(collection.contextFor(root.path), root.path);
      _validate(inputs);
      for (final path in [alternative.path, generated.path, transitive.path]) {
        expect(inputs.observations, contains(jsonEncode(['read', path])));
      }
      expect(
        inputs.observations[jsonEncode([
          'file',
          p.join(external.path, 'lib/b.dart'),
        ])],
        'false',
      );
    },
  );

  test(
    'records actual Flutter embedder metadata and canonical SDK parts',
    () async {
      final root = p.join(
        repositoryRoot().path,
        'packages/core_extensions/lib/project_provider.dart',
      );
      final excluded = p.setExtension(root, '.g.dart');
      final inputs = ContractInputs(excludedOutput: excluded);
      final overlay = OverlayResourceProvider(inputs.resources)
        ..setOverlay(
          excluded,
          content: "part of 'project_provider.dart';",
          modificationStamp: 0,
        );
      final collection = AnalysisContextCollection(
        includedPaths: [root],
        resourceProvider: overlay,
      );
      addTearDown(collection.dispose);
      final context = collection.contextFor(root);
      inputs.discover(context, root);
      expect(context.sdkRoot, isNull);
      expect(
        await context.currentSession.getResolvedUnit(root),
        isA<ResolvedUnitResult>(),
      );
      _validate(inputs);
      final reads = inputs.observations.keys
          .where((key) => (jsonDecode(key) as List<Object?>)[0] == 'read')
          .map(_path);
      expect(
        reads.any(
          (path) =>
              path.endsWith(p.join('sky_engine', 'lib', '_embedder.yaml')),
        ),
        isTrue,
      );
      expect(
        reads.any(
          (path) =>
              path.endsWith(p.join('sky_engine', 'lib', 'core', 'bool.dart')),
        ),
        isTrue,
      );
      expect(
        reads.any(
          (path) => path.endsWith(
            p.join('sky_engine', 'lib', 'async', 'future.dart'),
          ),
        ),
        isTrue,
      );
    },
  );

  test(
    'parse uncertainty declines caching without replacing analyzer diagnostics',
    () async {
      source.writeAsStringSync('library; void broken( {');
      final inputs = ContractInputs(excludedOutput: output);
      final collection = AnalysisContextCollection(
        includedPaths: [source.path],
        resourceProvider: inputs.resources,
      );
      addTearDown(collection.dispose);
      final context = collection.contextFor(source.path);
      inputs.discover(context, source.path);
      expect(inputs.cacheable, isFalse);
      final result = await context.currentSession.getResolvedUnit(source.path);
      expect(result, isA<ResolvedUnitResult>());
      expect((result as ResolvedUnitResult).diagnostics, isNotEmpty);
    },
  );
}

io.File _write(io.Directory root, String relative, String content) {
  final file = io.File(p.join(root.path, relative));
  file.parent.createSync(recursive: true);
  return file..writeAsStringSync(content);
}

String _path(String key) => (jsonDecode(key) as List<Object?>)[1] as String;

void _validate(ContractInputs inputs) {
  expect(inputs.cacheable, isTrue);
  inputs.validate();
  for (final entry in inputs.observations.entries) {
    final before = ContractInputs.stamp(entry.key);
    expect(ContractInputs.capture(entry.key), (
      value: entry.value,
      stamp: before,
    ));
    expect(ContractInputs.observe(entry.key), entry.value, reason: entry.key);
    expect(ContractInputs.stamp(entry.key), before);
  }
}

final class _MutatingFile implements io.File {
  _MutatingFile(this.base, this.mutate);

  final io.File base;
  void Function()? mutate;

  @override
  String get path => base.path;

  @override
  String resolveSymbolicLinksSync() => base.resolveSymbolicLinksSync();

  @override
  String readAsStringSync({Encoding encoding = utf8}) {
    final value = base.readAsStringSync(encoding: encoding);
    mutate?.call();
    mutate = null;
    return value;
  }

  @override
  Uint8List readAsBytesSync() => base.readAsBytesSync();

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('Unexpected filesystem operation: $invocation');
}
