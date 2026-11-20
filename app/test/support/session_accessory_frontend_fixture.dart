import 'dart:io';
import 'dart:isolate';

import 'package:adele_desktop/frontend/main_content_bridge.dart';
import 'package:adele_desktop/frontend/owning_backend_bridge.dart';
import 'package:adele_desktop/frontend/session_accessory_bridge.dart';
import 'package:contract_codegen/contract_codegen.dart';
import 'package:dart_eval/dart_eval.dart';
import 'package:flutter_eval/flutter_eval.dart';

const accessoryProbeLibrary = 'package:accessory_probe/main.dart';

/// The same accessory bytecode runs inside stock Chat and a non-Chat strategy.
Future<File> compileAccessoryProbe(Directory directory) async {
  // The pinned compiler caches type references across compiler instances. Do
  // not inherit the type indices used to compile stock Chat in the same test.
  final bytes = await Isolate.run(_compile);
  return File('${directory.path}/probe.evc').writeAsBytes(bytes);
}

Future<List<int>> _compile() async {
  final compiler = Compiler()
    ..addPlugin(flutterEvalPlugin)
    ..addPlugin(const MainContentDeclarations())
    ..addPlugin(const SessionAccessoryDeclarations())
    ..addPlugin(const OwningBackendDeclarations())
    ..entrypoints.add(accessoryProbeLibrary);
  final program = compiler.compile({
    'accessory_probe': {'main.dart': _source},
    'adele_contract': {'adele_contract.dart': evalContractSupportSource},
    'adele_ui': {
      for (final name in [
        'main_content_bridge',
        'session_accessory_bridge',
        'owning_backend_bridge',
      ])
        '$name.dart': await File(
          '../packages/ui/lib/$name.dart',
        ).readAsString(),
    },
  });
  return program.write();
}

const _source = r'''
import 'package:flutter/material.dart';
import 'package:adele_ui/main_content_bridge.dart';
import 'package:adele_ui/owning_backend_bridge.dart';
import 'package:adele_ui/session_accessory_bridge.dart';

void initialize() { openMainContentPane('strategy', 'Strategy', false); }
Widget buildStrategy() => Column(children: [
  const Text('Non-Chat strategy'),
  buildSessionAccessoryLocation('execution-configuration'),
]);

String currentId() => readSessionAccessorySessionId();
String captured = '';
String label = '';
Widget localAccessory() => capture('Local');
Widget serviceAccessory() => capture('Service');
Widget capture(String name) {
  label = name;
  captured = currentId();
  return Probe();
}
class Probe extends StatelessWidget {
  @override
  Widget build(BuildContext context) => Text(label + ' ' + captured);
}
Future<List<dynamic>> query(String service, String occurrence) =>
  settleOwningBackendOperation(requestOwningBackend(service, 'read',
    <String, dynamic>{'sessionId': captured, 'occurrenceId': occurrence}));
''';
