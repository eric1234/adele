import 'dart:io';

import 'package:args/args.dart';
import 'package:contract_codegen/contract_codegen.dart';

Future<void> main(List<String> arguments) async {
  final ArgParser parser = ArgParser()
    ..addFlag('check', negatable: false)
    ..addMultiOption('source', abbr: 's');
  final ArgResults options = parser.parse(arguments);
  final bool check = options.flag('check');
  final List<File> sources = options.multiOption('source').isNotEmpty
      ? options.multiOption('source').map(File.new).toList()
      : await _configuredSources(Directory.current);
  if (sources.isEmpty) {
    stderr.writeln(
      'No contract sources found. Pass --source or configure contract_codegen.yaml.',
    );
    exitCode = 64;
    return;
  }
  try {
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
  }
}

Future<List<File>> _configuredSources(Directory start) async {
  Directory directory = start.absolute;
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
        sources.add(
          File(
            '${directory.path}${Platform.pathSeparator}${value.substring(2).trim()}',
          ),
        );
      }
      return sources;
    }
    final Directory parent = directory.parent;
    if (parent.path == directory.path) return <File>[];
    directory = parent;
  }
}
