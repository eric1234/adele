import 'dart:io';

import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:args/args.dart';
import 'package:contract_codegen/contract_codegen.dart';
import 'package:path/path.dart' as p;

Future<void> main(List<String> arguments) async {
  final ArgParser parser = ArgParser()
    ..addFlag('check', negatable: false)
    ..addFlag('clean', negatable: false)
    ..addMultiOption('source', abbr: 's');
  try {
    final ArgResults options = parser.parse(arguments);
    final bool check = options.flag('check');
    final bool clean = options.flag('clean');
    if (options.rest.isNotEmpty ||
        clean && (check || options.wasParsed('source'))) {
      throw const FormatException(
        'Use --clean alone, or generate with [--check] [--source <path>].',
      );
    }
    final configured = options.multiOption('source').isEmpty
        ? await _configuredSources(Directory.current)
        : null;
    if (clean) {
      if (configured == null) {
        throw const FormatException(
          '--clean requires a repository contract_codegen.yaml.',
        );
      }
      await _clean(configured.root, configured.sources);
      return;
    }
    final List<File> sources = options.multiOption('source').isNotEmpty
        ? options.multiOption('source').map(File.new).toList()
        : configured?.sources ?? <File>[];
    if (sources.isEmpty) {
      throw const FormatException(
        'No contract sources found. Pass --source or configure contract_codegen.yaml.',
      );
    }
    final List<ContractGeneratedFile> outputs = <ContractGeneratedFile>[];
    for (final File source in sources) {
      outputs.add(await const ContractGenerator().generate(source));
    }
    final List<ContractGeneratedFile> stale = <ContractGeneratedFile>[];
    for (final ContractGeneratedFile output in outputs) {
      final File destination = File(output.path);
      if (!destination.existsSync() ||
          await destination.readAsString() != output.contents) {
        stale.add(output);
      }
    }
    if (check) {
      for (final ContractGeneratedFile output in stale) {
        stderr.writeln('${output.path}: generated contract is stale.');
      }
      if (stale.isNotEmpty) exitCode = 1;
      return;
    }
    for (final ContractGeneratedFile output in stale) {
      await const ContractGenerator().write(output);
    }
  } on ContractDiagnostic catch (error) {
    stderr.writeln(error);
    exitCode = 1;
  } on FormatException catch (error) {
    stderr.writeln(error.message);
    exitCode = 64;
  } on FileSystemException catch (error) {
    stderr.writeln(error);
    exitCode = 1;
  }
}

Future<({Directory root, List<File> sources})?> _configuredSources(
  Directory start,
) async {
  Directory directory = Directory(p.normalize(start.absolute.path));
  while (true) {
    final File config = File(
      '${directory.path}${Platform.pathSeparator}contract_codegen.yaml',
    );
    if (config.existsSync()) {
      final List<File> sources = <File>[];
      for (final String line in await config.readAsLines()) {
        final String value = line.trim();
        if (value.isEmpty || value.startsWith('#') || value == 'sources:') {
          continue;
        }
        if (!value.startsWith('- ')) {
          throw FormatException('Expected a sources list in ${config.path}.');
        }
        sources.add(File(p.join(directory.path, value.substring(2).trim())));
      }
      return (root: directory, sources: sources);
    }
    final Directory parent = directory.parent;
    if (parent.path == directory.path) return null;
    directory = parent;
  }
}

Future<void> _clean(Directory root, List<File> sources) async {
  final sourcePaths = sources
      .map((source) => p.normalize(source.absolute.path))
      .toSet();
  // Validate the entire configuration before deleting anything. Sources may
  // have been removed, and legacy outputs need not have a valid header or body.
  for (final path in sourcePaths) {
    if (!p.isWithin(root.path, path) || p.extension(path) != '.dart') {
      throw FormatException('Expected an in-repository .dart source: $path');
    }
  }
  final outputs = sourcePaths
      .map((path) => p.setExtension(path, '.g.dart'))
      .toSet();
  final pending = <Directory>[
    Directory(p.join(root.path, 'packages')),
    Directory(p.join(root.path, 'plugins')),
  ];
  while (pending.isNotEmpty) {
    final directory = pending.removeLast();
    if (await FileSystemEntity.type(directory.path, followLinks: false) !=
        FileSystemEntityType.directory) {
      continue;
    }
    await for (final entity in directory.list(followLinks: false)) {
      final name = p.basename(entity.path);
      if (entity is Directory) {
        if (!name.startsWith('.') && name != 'build' && name != 'coverage') {
          pending.add(entity);
        }
      } else if (entity is File &&
          name.endsWith('.g.dart') &&
          !sourcePaths.contains(entity.path)) {
        if (outputs.contains(entity.path)) {
          await entity.delete();
          continue;
        }
        final contents = await entity.readAsString();
        if (!contents.startsWith('${DartContractEmitter.nativeHeader}\n') &&
            !contents.startsWith('${DartContractEmitter.nativeHeader}\r\n')) {
          continue;
        }
        final unit = parseString(
          content: contents,
          throwIfDiagnostics: false,
        ).unit;
        if (unit.directives.length == 1 &&
            unit.directives.single is PartOfDirective) {
          final part = unit.directives.single as PartOfDirective;
          final sourceName = '${name.substring(0, name.length - 7)}.dart';
          if (part.uri?.stringValue == sourceName) await entity.delete();
        }
      }
    }
  }
}
