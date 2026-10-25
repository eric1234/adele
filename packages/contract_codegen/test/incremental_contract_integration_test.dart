@Timeout(Duration(minutes: 10))
library;

import 'dart:convert';

import 'package:contract_codegen/src/contract_inputs.dart';
import 'package:contract_codegen/src/incremental_generation.dart';
import 'package:path/path.dart' as p;

import 'support/contract_generator_support.dart';

void main() {
  test(
    'configured contracts reuse receipts and isolate a wire-schema edit',
    () async {
      final fixture = await _cloneConfiguredContracts();
      expect(fixture.sources, hasLength(16));
      final receipt = File(
        p.join(fixture.root.path, '.dart_tool/adele/contracts/freshness.json'),
      );
      expect(receipt.existsSync(), isFalse);
      for (final source in fixture.sources) {
        expect(
          File(p.setExtension(source.path, '.g.dart')).existsSync(),
          isFalse,
        );
      }

      final cold = await generateIncrementally(
        root: fixture.root,
        sources: fixture.sources,
        configuration: fixture.configuration,
        generatorIdentity: 'configured-contract-integration',
      );
      expect(cold, (current: 0, regenerated: 16));

      final bytes = <String, List<int>>{};
      final modified = <String, DateTime>{};
      for (final source in fixture.sources) {
        final output = File(p.setExtension(source.path, '.g.dart'));
        bytes[output.path] = await output.readAsBytes();
        await output.setLastModified(DateTime.utc(2000));
        modified[output.path] = await output.lastModified();
      }

      final warm = await generateIncrementally(
        root: fixture.root,
        sources: fixture.sources,
        configuration: fixture.configuration,
        generatorIdentity: 'configured-contract-integration',
        generate: (File source, {ContractInputs? inputs}) =>
            throw StateError('Warm generation resolved ${source.path}.'),
      );
      expect(warm, (current: 16, regenerated: 0));
      for (final source in fixture.sources) {
        final output = File(p.setExtension(source.path, '.g.dart'));
        expect(
          await output.readAsBytes(),
          bytes[output.path],
          reason: source.path,
        );
        expect(
          await output.lastModified(),
          modified[output.path],
          reason: source.path,
        );

        // Independently resolve every schema after the warm run, without receipts.
        final authoritative = await const ContractGenerator().generate(source);
        expect(authoritative.path, output.path);
        expect(
          await output.readAsBytes(),
          utf8.encode(authoritative.contents),
          reason: source.path,
        );
        expect(
          await output.lastModified(),
          modified[output.path],
          reason: source.path,
        );
      }

      final demo = fixture.sources.singleWhere(
        (source) => p.basename(source.path) == 'workspace_demo_contract.dart',
      );
      final sourceText = await demo.readAsString();
      const originalEnum = 'enum DirectoryEntryKind { directory, file }';
      expect(sourceText, contains(originalEnum));
      await demo.writeAsString(
        sourceText.replaceFirst(
          originalEnum,
          'enum DirectoryEntryKind { directory, file, symbolicLink }',
        ),
      );

      final generatedSources = <String>[];
      final edited = await generateIncrementally(
        root: fixture.root,
        sources: fixture.sources,
        configuration: fixture.configuration,
        generatorIdentity: 'configured-contract-integration',
        generate: (File source, {ContractInputs? inputs}) {
          generatedSources.add(source.path);
          return const ContractGenerator().generate(source, inputs: inputs);
        },
      );
      expect(edited, (current: 15, regenerated: 1));
      expect(generatedSources, [demo.path]);
      final authoritative = await const ContractGenerator().generate(demo);
      final changedOutput = File(authoritative.path);
      expect(authoritative.contents, contains('symbolicLink'));
      expect(
        await changedOutput.readAsBytes(),
        isNot(bytes[changedOutput.path]),
      );
      expect(
        await changedOutput.readAsBytes(),
        utf8.encode(authoritative.contents),
      );
      for (final source in fixture.sources.where(
        (source) => source.path != demo.path,
      )) {
        final output = File(p.setExtension(source.path, '.g.dart'));
        expect(
          await output.readAsBytes(),
          bytes[output.path],
          reason: source.path,
        );
        expect(
          await output.lastModified(),
          modified[output.path],
          reason: source.path,
        );
      }

      expect(
        await generateIncrementally(
          root: fixture.root,
          sources: fixture.sources,
          configuration: fixture.configuration,
          generatorIdentity: 'configured-contract-integration',
          generate: (File source, {ContractInputs? inputs}) => throw StateError(
            'Edited warm generation resolved ${source.path}.',
          ),
        ),
        (current: 16, regenerated: 0),
      );
    },
  );
}

Future<({Directory root, List<File> sources, String configuration})>
_cloneConfiguredContracts() async {
  final original = repositoryRoot();
  final root = await Directory.systemTemp.createTemp(
    'adele_contract_inventory.',
  );
  addTearDown(() => root.delete(recursive: true));
  final configuration = await File(
    p.join(original.path, 'contract_codegen.yaml'),
  ).readAsString();
  final paths = <String>[];
  for (final line in const LineSplitter().convert(configuration)) {
    final value = line.trim();
    if (value.isEmpty || value.startsWith('#') || value == 'sources:') continue;
    expect(value, startsWith('- '));
    final path = value.substring(2).trim();
    expect(p.isWithin(original.path, p.join(original.path, path)), isTrue);
    paths.add(path);
  }

  final owners = <String, Directory>{};
  final generatedPaths = {
    for (final path in paths)
      p.setExtension(p.join(original.path, path), '.g.dart'),
  };
  for (final path in paths) {
    var owner = File(p.join(original.path, path)).parent;
    while (!File(p.join(owner.path, 'pubspec.yaml')).existsSync()) {
      expect(p.isWithin(original.path, owner.path), isTrue, reason: path);
      owner = owner.parent;
    }
    owners[owner.path] = Directory(
      p.join(root.path, p.relative(owner.path, from: original.path)),
    );
  }
  for (final entry in owners.entries) {
    final library = Directory(p.join(entry.key, 'lib'));
    final destination = Directory(p.join(entry.value.path, 'lib'));
    await destination.create(recursive: true);
    await for (final entity in library.list(
      recursive: true,
      followLinks: false,
    )) {
      final path = p.join(
        destination.path,
        p.relative(entity.path, from: library.path),
      );
      if (entity is Directory) {
        await Directory(path).create(recursive: true);
      } else if (entity is File) {
        if (generatedPaths.contains(entity.path)) continue;
        await File(path).parent.create(recursive: true);
        await entity.copy(path);
      } else {
        fail(
          'Contract fixture must not retain a source symlink: ${entity.path}',
        );
      }
    }
    await File(
      p.join(entry.key, 'pubspec.yaml'),
    ).copy(p.join(entry.value.path, 'pubspec.yaml'));
    for (final name in ['analysis_options.yaml', 'pubspec_overrides.yaml']) {
      final file = File(p.join(entry.key, name));
      if (file.existsSync()) await file.copy(p.join(entry.value.path, name));
    }
  }
  for (final path in [
    'contract_codegen.yaml',
    'analysis_options.yaml',
    'pubspec.yaml',
    'pubspec_overrides.yaml',
    'pubspec.lock',
    '.dart_tool/package_graph.json',
  ]) {
    final file = File(p.join(original.path, path));
    if (!file.existsSync()) continue;
    final destination = File(p.join(root.path, path));
    await destination.parent.create(recursive: true);
    await file.copy(destination.path);
  }

  final packageConfig = File(
    p.join(original.path, '.dart_tool/package_config.json'),
  );
  final config =
      jsonDecode(await packageConfig.readAsString()) as Map<String, dynamic>;
  final redirected = <String>{};
  for (final package
      in (config['packages'] as List<dynamic>).cast<Map<String, dynamic>>()) {
    // Relative URIs belong to the original config, not the temporary checkout.
    final uri = packageConfig.uri.resolve(package['rootUri'] as String);
    final owner = p.normalize(uri.toFilePath());
    final cloned = owners[owner];
    package['rootUri'] = (cloned?.uri ?? uri).toString();
    if (cloned != null) redirected.add(owner);
  }
  expect(redirected, unorderedEquals(owners.keys));
  final destination = File(p.join(root.path, '.dart_tool/package_config.json'));
  await destination.parent.create(recursive: true);
  await destination.writeAsString(jsonEncode(config));
  return (
    root: root,
    sources: [for (final path in paths) File(p.join(root.path, path))],
    configuration: configuration,
  );
}
