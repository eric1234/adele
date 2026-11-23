import 'dart:io';
import 'dart:typed_data';

import 'package:adele_desktop/frontend/owning_backend_bridge.dart';
import 'package:adele_desktop/frontend/session_accessory_bridge.dart';
import 'package:contract_codegen/contract_codegen.dart';
import 'package:dart_eval/dart_eval.dart';
import 'package:dart_eval/dart_eval_bridge.dart' show EvalPlugin;
import 'package:flutter_eval/flutter_eval.dart';

/// Compile an owning-backend Session accessory with its own generated clients.
Future<Uint8List> compileSessionAccessoryFrontend({
  required Directory repositoryRoot,
  required String plugin,
  List<String> additionalLibraries = const [],
  List<String> additionalUiSources = const [],
  List<EvalPlugin> additionalDeclarations = const [],
}) async {
  // flutter_test runs inside flutter_tester. Use that toolchain's bundled SDK.
  var directory = File(Platform.resolvedExecutable).parent;
  while (!File('${directory.path}/dart-sdk/lib/core/core.dart').existsSync()) {
    if (directory.parent.path == directory.path) {
      throw StateError('Cannot locate the pinned Dart SDK.');
    }
    directory = directory.parent;
  }
  final packages = repositoryRoot.uri.resolve('plugins/$plugin/packages/');
  final frontendPackage = '${plugin}_frontend';
  final contractPackage = '${plugin}_contract';
  final contract =
      await ContractGenerator(
        sdkPath: '${directory.path}/dart-sdk',
      ).generateEvalClient(
        File.fromUri(packages.resolve('contract/lib/$contractPackage.dart')),
      );
  final libraries = ['$frontendPackage.dart', ...additionalLibraries];
  final compiler = Compiler()
    ..addPlugin(flutterEvalPlugin)
    ..addPlugin(const SessionAccessoryDeclarations())
    ..addPlugin(const OwningBackendDeclarations())
    ..entrypoints.addAll([
      for (final library in libraries) 'package:$frontendPackage/$library',
      'package:$contractPackage/$contractPackage.dart',
      'package:adele_contract/adele_contract.dart',
    ]);
  for (final declaration in additionalDeclarations) {
    compiler.addPlugin(declaration);
  }
  final program = compiler.compile({
    frontendPackage: {
      for (final library in libraries)
        library: await File.fromUri(
          packages.resolve('frontend/lib/$library'),
        ).readAsString(),
    },
    contractPackage: {'$contractPackage.dart': contract},
    'adele_contract': {'adele_contract.dart': evalContractSupportSource},
    'adele_ui': {
      for (final source in [
        'session_accessory_bridge.dart',
        'owning_backend_bridge.dart',
        'inspection_display.dart',
        ...additionalUiSources,
      ])
        source: await File.fromUri(
          repositoryRoot.uri.resolve('packages/ui/lib/$source'),
        ).readAsString(),
    },
  });
  return program.write();
}
