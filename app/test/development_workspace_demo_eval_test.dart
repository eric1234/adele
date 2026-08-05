import 'dart:async';
import 'dart:io';

import 'package:adele_desktop/development/workspace_demo/workspace_demo_eval_bridge.dart';
import 'package:adele_plugin_api/adele_plugin_api.dart';
import 'package:dart_eval/dart_eval.dart';
import 'package:dart_eval/dart_eval_bridge.dart';
import 'package:flutter/material.dart';
import 'package:flutter_eval/flutter_eval.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plugin_runtime/plugin_runtime.dart';
import 'package:workspace_demo_contract/workspace_demo_contract.dart';

void main() {
  testWidgets('interpreted frontend calls typed service and renders text', (
    WidgetTester tester,
  ) async {
    final WorkspaceDemoEvalBridge bridge = WorkspaceDemoEvalBridge(
      service: _FakeWorkspaceDemoService(),
      developmentRoot: ResourceRef(uri: Uri.parse('file:///demo/')),
    );
    await tester.pumpWidget(MaterialApp(home: await _createWidget(bridge)));
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
    await tester.pumpWidget(MaterialApp(home: await _createWidget(bridge)));
    await tester.tap(find.text('notes.txt'));
    await tester.pumpWidget(const SizedBox.shrink());
    service.completeDelayed();
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  testWidgets('returns cancellation when invalidated before a request', (
    WidgetTester tester,
  ) async {
    final WorkspaceDemoEvalBridge bridge = WorkspaceDemoEvalBridge(
      service: _FakeWorkspaceDemoService(),
      developmentRoot: ResourceRef(uri: Uri.parse('file:///demo/')),
    )..invalidate();
    await tester.pumpWidget(MaterialApp(home: await _createWidget(bridge)));
    expect(find.byType(SizedBox), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('ignores completion after invalidation while pending', (
    WidgetTester tester,
  ) async {
    final _DelayedWorkspaceDemoService service = _DelayedWorkspaceDemoService();
    final WorkspaceDemoEvalBridge bridge = WorkspaceDemoEvalBridge(
      service: service,
      developmentRoot: ResourceRef(uri: Uri.parse('file:///demo/')),
    );
    await tester.pumpWidget(MaterialApp(home: await _createWidget(bridge)));
    await tester.tap(find.text('notes.txt'));
    bridge.invalidate();
    service.completeDelayed();
    await tester.pump();
    expect(find.text('late text'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('ignores failure after invalidation while pending', (
    WidgetTester tester,
  ) async {
    final _DelayedWorkspaceDemoService service = _DelayedWorkspaceDemoService();
    final WorkspaceDemoEvalBridge bridge = WorkspaceDemoEvalBridge(
      service: service,
      developmentRoot: ResourceRef(uri: Uri.parse('file:///demo/')),
    );
    await tester.pumpWidget(MaterialApp(home: await _createWidget(bridge)));
    await tester.tap(find.text('notes.txt'));
    bridge.invalidate();
    service.completeError(
      const PluginConnectionClosed('Plugin stopped during reload.'),
    );
    await tester.pump();
    expect(find.text('Selected: notes.txt'), findsNothing);
    expect(find.text('Plugin stopped during reload.'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  test('propagates backend failure while bridge is active', () async {
    final WorkspaceDemoEvalBridge bridge = WorkspaceDemoEvalBridge(
      service: _FailingWorkspaceDemoService(),
      developmentRoot: ResourceRef(uri: Uri.parse('file:///demo/')),
    );
    await expectLater(_callText(bridge), throwsA(isA<WorkspaceDemoFailure>()));
  });
}

Future<Object?> _callText(WorkspaceDemoEvalBridge bridge) async {
  final Compiler compiler = Compiler()
    ..addPlugin(bridge)
    ..entrypoints.add('package:probe/main.dart');
  final Program program = compiler.compile(<String, Map<String, String>>{
    'probe': <String, String>{
      'main.dart': '''
import 'package:workspace_demo_frontend/src/adele_eval_bridge.dart';
Future<WorkspaceDemoTextData> callText() => loadWorkspaceDemoText('file:///demo/notes.txt');
''',
    },
    'workspace_demo_frontend': <String, String>{
      'src/adele_eval_bridge.dart': _bridgeSource,
    },
  });
  final Runtime runtime = Runtime.ofProgram(program)..addPlugin(bridge);
  final Object? result = runtime.executeLib(
    'package:probe/main.dart',
    'callText',
  );
  return await (result! as Future<Object?>);
}

Future<Widget> _createWidget(WorkspaceDemoEvalBridge bridge) async {
  final Compiler compiler = Compiler()
    ..addPlugin(flutterEvalPlugin)
    ..addPlugin(bridge)
    ..entrypoints.add(
      'package:workspace_demo_frontend/workspace_demo_frontend.dart',
    );
  final String repository = Directory.current.parent.path;
  final Program program = compiler.compile(<String, Map<String, String>>{
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
  return (value is $Value ? value.$reified : value)! as Widget;
}

const String _bridgeSource = '''
final class WorkspaceDemoViewData {
  const WorkspaceDemoViewData({required this.names, required this.uris, required this.cancelled});
  final List<String> names;
  final List<String> uris;
  final bool cancelled;
}

final class WorkspaceDemoTextData {
  const WorkspaceDemoTextData(this.value, {this.cancelled = false});
  final String value;
  final bool cancelled;
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

  void completeError(Object error, [StackTrace? stackTrace]) {
    _delayed.completeError(error, stackTrace);
  }
}

final class _FailingWorkspaceDemoService extends _FakeWorkspaceDemoService {
  @override
  Future<TextFileContents> readTextFile(ResourceRef file) {
    throw const WorkspaceDemoFailure(
      code: 'unreadable',
      message: 'Backend read failed.',
      details: {},
    );
  }
}
