import 'dart:io';

import 'package:adele_desktop/phase1/eval/workspace_demo_eval_bridge.dart';
import 'package:adele_plugin_api/adele_plugin_api.dart';
import 'package:dart_eval/dart_eval.dart';
import 'package:dart_eval/dart_eval_bridge.dart';
import 'package:flutter/material.dart';
import 'package:flutter_eval/flutter_eval.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:workspace_demo_contract/workspace_demo_contract.dart';

void main() {
  late final Compiler compiler;

  setUpAll(() {
    compiler = Compiler()..addPlugin(flutterEvalPlugin);
  });

  testWidgets('interpreted frontend calls typed service and renders text', (
    WidgetTester tester,
  ) async {
    final WorkspaceDemoEvalBridge bridge = WorkspaceDemoEvalBridge(
      service: _FakeWorkspaceDemoService(),
      developmentRoot: ResourceRef(uri: Uri.parse('file:///demo/')),
    );
    compiler.addPlugin(bridge);
    compiler.entrypoints.add(
      'package:workspace_demo_frontend/workspace_demo_frontend.dart',
    );
    final String repository = Directory.current.parent.path;
    final String frontendSource = File(
      '$repository/plugins/workspace_demo/packages/frontend/lib/workspace_demo_frontend.dart',
    ).readAsStringSync();
    const String contractSource = '''
final class WorkspaceDemoViewData {
  const WorkspaceDemoViewData({required this.names, required this.uris});
  final List<String> names;
  final List<String> uris;
}

final class WorkspaceDemoTextData {
  const WorkspaceDemoTextData(this.value);
  final String value;
}

Future<WorkspaceDemoViewData> loadWorkspaceDemoDirectory() {
  throw UnsupportedError('Bridge function.');
}

Future<WorkspaceDemoTextData> loadWorkspaceDemoText(String uri) {
  throw UnsupportedError('Bridge function.');
}
''';
    final Program program = compiler.compile(<String, Map<String, String>>{
      'workspace_demo_frontend': <String, String>{
        'workspace_demo_frontend.dart': frontendSource,
      },
      'workspace_demo_contract': <String, String>{
        'workspace_demo_contract.dart': contractSource,
      },
    });
    final File artifact = File(
      '${Directory.systemTemp.createTempSync('adele-phase1-full-eval-').path}/frontend.evc',
    );
    addTearDown(() => artifact.parent.deleteSync(recursive: true));
    artifact.writeAsBytesSync(program.write());
    final Runtime runtime =
        Runtime(artifact.readAsBytesSync().buffer.asByteData())
          ..addPlugin(flutterEvalPlugin)
          ..addPlugin(bridge);
    final Object? pendingWidget = runtime.executeLib(
      'package:workspace_demo_frontend/workspace_demo_frontend.dart',
      'buildWorkspaceDemo',
    );
    final Object? widgetValue = await (pendingWidget! as Future<Object?>);
    final Object? widget = widgetValue is $Value
        ? widgetValue.$reified
        : widgetValue;
    await tester.pumpWidget(MaterialApp(home: widget! as Widget));
    expect(find.text('notes.txt'), findsOneWidget);
    expect(find.text('typed backend text'), findsOneWidget);
    bridge.invalidate();
    await tester.pumpWidget(const SizedBox.shrink());
  });
}

final class _FakeWorkspaceDemoService implements WorkspaceDemoService {
  @override
  Future<DirectoryListing> listDirectory(ResourceRef directory) async {
    return DirectoryListing(
      directory: directory,
      entries: <DirectoryEntry>[
        DirectoryEntry(
          resource: ResourceRef(uri: Uri.parse('file:///demo/notes.txt')),
          name: 'notes.txt',
          kind: DirectoryEntryKind.file,
        ),
      ],
    );
  }

  @override
  Future<TextFileContents> readTextFile(ResourceRef file) async {
    return TextFileContents(resource: file, text: 'typed backend text');
  }
}
