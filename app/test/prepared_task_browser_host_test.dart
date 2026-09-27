import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:adele_desktop/frontend/application_frontend_bootstrap.dart';
import 'package:adele_desktop/frontend/layout_builder_bridge.dart';
import 'package:adele_desktop/frontend/prepared_task_browser_host.dart';
import 'package:adele_desktop/frontend/task_browser_bridge.dart';
import 'package:adele_desktop/ui/task_browser/task_browser_presentation_host.dart';
import 'package:adele_plugin_api/adele_plugin_api.dart';
import 'package:adele_product/adele_product.dart';
import 'package:adele_ui/adele_ui.dart';
import 'package:dart_eval/dart_eval.dart';
import 'package:flutter/material.dart';
import 'package:flutter_eval/flutter_eval.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plugin_runtime/plugin_runtime.dart';

const _library = 'package:browser_probe/main.dart';

void main() {
  final project = Project(
    id: ProjectId('project'),
    sourceLocation: Uri.parse('file:///project'),
  );
  final extensionId = ExtensionId('test.browser');
  late Directory root;
  late ExtensionRegistry extensions;
  late PreparedTaskBrowserHost host;
  late ApplicationFrontendBootstrap owner;
  late Uint8List bytes;
  late List<_Source> sources;

  setUpAll(() {
    final compiler = Compiler()
      ..addPlugin(flutterEvalPlugin)
      ..addPlugin(const LayoutBuilderBridge())
      ..addPlugin(const TaskBrowserDeclarations())
      ..entrypoints.add(_library);
    bytes = compiler.compile({
      'browser_probe': {
        'main.dart': '''
import 'package:flutter/material.dart';
import 'package:adele_ui/task_browser_bridge.dart';
Widget createBrowser() => LayoutBuilder(builder: (context, constraints) =>
  Text(readTaskBrowser()['title']));
''',
      },
      'adele_ui': {
        'task_browser_bridge.dart': File(
          '${Directory.current.parent.path}/packages/ui/lib/task_browser_bridge.dart',
        ).readAsStringSync(),
      },
    }).write();
  });

  setUp(() async {
    root = await Directory.systemTemp.createTemp('prepared-browser-');
    extensions = ExtensionRegistry();
    sources = [];
    host = PreparedTaskBrowserHost(
      sourceForProject: (value) {
        expect(value, same(project));
        final source = _Source();
        sources.add(source);
        return source;
      },
    );
    owner = ApplicationFrontendBootstrap(
      extensions: extensions,
      taskBrowserHost: host,
    );
  });
  tearDown(() async {
    await owner.close();
    await root.delete(recursive: true);
  });

  Future<void> start({
    List<int>? artifactBytes,
    String entrypoint = 'createBrowser',
  }) async {
    final directory = await Directory('${root.path}/browser').create();
    await File(
      '${directory.path}/frontend.evc',
    ).writeAsBytes(artifactBytes ?? bytes);
    await File(
      '${directory.path}/adele_plugin.installation.json',
    ).writeAsString(
      jsonEncode({
        'manifestVersion': 1,
        'metadata': {
          'id': 'test.browser',
          'version': 'test',
          'displayName': 'Browser',
        },
        'components': {
          'frontend': {
            'artifact': 'frontend.evc',
            'presentations': [
              {
                'role': 'taskBrowser',
                'extensionId': extensionId.value,
                'displayName': 'Browser',
                'library': _library,
                'entrypoint': entrypoint,
              },
            ],
          },
        },
      }),
    );
    final catalog = await PreparedPluginCatalog.discover(root.path);
    expect(catalog.issues, isEmpty);
    expect(catalog.installations.single.backendArtifactUri, isNull);
    await owner.start(catalog);
    expect(owner.generations.single.state, InstalledFrontendState.active);
  }

  Widget view() => MaterialApp(
    home: Scaffold(
      body: TaskBrowserPresentationHost(
        project: project,
        extensions: extensions,
      ),
    ),
  );

  testWidgets(
    'frontend-only activation is lazy and host disposes each view source',
    (tester) async {
      await tester.runAsync(start);
      expect(sources, isEmpty);
      await tester.pumpWidget(view());
      await tester.pumpAndSettle();
      expect(find.text('Browser data'), findsOneWidget);
      expect(sources, hasLength(1));
      await tester.pumpWidget(view());
      expect(sources, hasLength(1));
      await tester.pumpWidget(const SizedBox.shrink());
      expect(sources.single.disposals, 1);
      await tester.pumpWidget(view());
      await tester.pumpAndSettle();
      expect(sources, hasLength(2));
      await tester.runAsync(owner.close);
      expect(sources.last.disposals, 1);
      await tester.pumpWidget(const SizedBox.shrink());
      expect(sources.map((source) => source.disposals), [1, 1]);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'exact retirement revokes factory and disposes source without replacing it',
    (tester) async {
      await tester.runAsync(start);
      final binding = TaskBrowserResolver(extensions).resolve();
      final factory = binding.value.createPresentation;
      await tester.pumpWidget(view());
      await tester.pumpAndSettle();
      await owner.generations.single.retire(
        taskBrowserContributions,
        extensionId,
      );
      expect(binding.validate, throwsA(isA<StaleExtensionBinding>()));
      expect(() => factory(project), throwsStateError);
      await tester.pumpAndSettle();
      expect(sources.single.disposals, 1);
      expect(find.text('Task Browser is unavailable.'), findsOneWidget);
    },
  );

  for (final corrupt in [true, false]) {
    testWidgets(
      '${corrupt ? 'corrupt bytecode' : 'missing entrypoint'} fails only the presentation and releases its source',
      (tester) async {
        await tester.runAsync(
          () => start(
            artifactBytes: corrupt ? [0, 1, 2] : null,
            entrypoint: corrupt ? 'createBrowser' : 'missing',
          ),
        );
        await tester.pumpWidget(view());
        await tester.pumpAndSettle();
        expect(find.text('Frontend unavailable.'), findsOneWidget);
        expect(owner.generations.single.state, InstalledFrontendState.active);
        expect(sources.single.disposals, 1);
        await tester.pumpWidget(view());
        expect(sources, hasLength(1));
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'a missing optional host does not prevent contribution activation',
    (tester) async {
      await owner.close();
      owner = ApplicationFrontendBootstrap(extensions: extensions);
      await tester.runAsync(start);
      await tester.pumpWidget(view());
      expect(
        find.textContaining('the presentation could not be created'),
        findsOneWidget,
      );
      expect(sources, isEmpty);
    },
  );
}

class _Source extends ChangeNotifier implements TaskBrowserSource {
  int disposals = 0;
  @override
  Map<String, Object?> read() => {'title': 'Browser data'};
  @override
  Future<void> selectTask(String? taskId) async {}
  @override
  Future<void> createTask(String title) async {}
  @override
  Future<void> createSession(String optionHandle) async {}
  @override
  Future<void> openSession(String sessionId) async {}
  @override
  void dispose() {
    disposals++;
    super.dispose();
  }
}
