import 'dart:async';
import 'dart:io';

import 'package:adele_desktop/development/workspace_demo/workspace_demo_eval_bridge.dart';
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
    final Program program = compiler.compile(<String, Map<String, String>>{
      'workspace_demo_frontend': <String, String>{
        'workspace_demo_frontend.dart': frontendSource,
        'src/adele_eval_bridge.dart': _bridgeSource,
      },
    });
    final File artifact = File(
      '${Directory.systemTemp.createTempSync('adele-workspace-eval-').path}/frontend.evc',
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
    expect(find.text('first.txt'), findsOneWidget);
    expect(find.text('notes.txt'), findsOneWidget);
    await tester.tap(find.text('notes.txt'));
    await tester.pump();
    await tester.pump();
    expect(find.text('Selected: notes.txt'), findsOneWidget);
    expect(find.text('typed backend text'), findsOneWidget);
    bridge.invalidate();
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('ignores a delayed response after interpreted disposal', (
    WidgetTester tester,
  ) async {
    final _DelayedWorkspaceDemoService service = _DelayedWorkspaceDemoService();
    final WorkspaceDemoEvalBridge bridge = WorkspaceDemoEvalBridge(
      service: service,
      developmentRoot: ResourceRef(uri: Uri.parse('file:///demo/')),
    );
    final Compiler delayedCompiler = Compiler()
      ..addPlugin(flutterEvalPlugin)
      ..addPlugin(bridge)
      ..entrypoints.add(
        'package:workspace_demo_frontend/workspace_demo_frontend.dart',
      );
    final String repository = Directory.current.parent.path;
    final Program
    program = delayedCompiler.compile(<String, Map<String, String>>{
      'workspace_demo_frontend': <String, String>{
        'workspace_demo_frontend.dart': File(
          '$repository/plugins/workspace_demo/packages/frontend/lib/workspace_demo_frontend.dart',
        ).readAsStringSync(),
        'src/adele_eval_bridge.dart': _bridgeSource,
      },
    });
    final Runtime runtime = Runtime(program.write().buffer.asByteData())
      ..addPlugin(flutterEvalPlugin)
      ..addPlugin(bridge);
    final Object? pending = runtime.executeLib(
      'package:workspace_demo_frontend/workspace_demo_frontend.dart',
      'buildWorkspaceDemo',
    );
    final Object? value = await (pending! as Future<Object?>);
    final Widget widget = (value is $Value ? value.$reified : value)! as Widget;
    await tester.pumpWidget(MaterialApp(home: widget));
    await tester.tap(find.text('notes.txt'));
    await tester.pumpWidget(const SizedBox.shrink());
    service.completeDelayed();
    await tester.pump();
    expect(tester.takeException(), isNull);
    bridge.invalidate();
  });
}

const String _bridgeSource = '''
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

class _FakeWorkspaceDemoService implements WorkspaceDemoService {
  @override
  Future<DirectoryListing> listDirectory(ResourceRef directory) async {
    return DirectoryListing(
      directory: directory,
      entries: <DirectoryEntry>[
        DirectoryEntry(
          resource: ResourceRef(uri: Uri.parse('file:///demo/first.txt')),
          name: 'first.txt',
          kind: DirectoryEntryKind.file,
        ),
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
    return TextFileContents(
      resource: file,
      text: file.uri.path.endsWith('notes.txt')
          ? 'typed backend text'
          : 'first text',
    );
  }
}

final class _DelayedWorkspaceDemoService extends _FakeWorkspaceDemoService {
  final Completer<TextFileContents> _delayed = Completer<TextFileContents>();

  @override
  Future<TextFileContents> readTextFile(ResourceRef file) => _delayed.future;

  void completeDelayed() {
    _delayed.complete(
      TextFileContents(
        resource: ResourceRef(uri: Uri.parse('file:///demo/notes.txt')),
        text: 'late text',
      ),
    );
  }
}
