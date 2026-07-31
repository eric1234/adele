import 'dart:io';

import 'package:args/args.dart';
import 'package:contract_codegen/contract_codegen.dart';

Future<void> main(List<String> arguments) async {
  final ArgParser parser = ArgParser()..addFlag('check', negatable: false);
  final ArgResults options = parser.parse(arguments);
  final bool check = options.flag('check');
  final bool current = await const WorkspaceDemoContractGenerator().apply(
    Directory.current,
    check: check,
  );
  if (check && !current) {
    stderr.writeln('Generated ADELE contract files are stale.');
    exitCode = 1;
  }
}
