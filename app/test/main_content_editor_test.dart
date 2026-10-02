import 'dart:io';

import 'package:adele_desktop/frontend/application_frontend_bootstrap.dart';
import 'package:adele_desktop/ui/main_content/main_content_host.dart';
import 'package:adele_plugin_api/adele_plugin_api.dart';
import 'package:adele_product/adele_product.dart';
import 'package:adele_ui/adele_ui.dart';
import 'package:code_forge/code_forge.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_eval/widgets.dart' show $StatefulWidget$bridge;
import 'package:flutter_test/flutter_test.dart';
import 'package:plugin_runtime/plugin_runtime.dart';

import '../tool/main_content_fixture.dart';
import '../tool/main_content_frontend_compiler.dart';

void main() {
  late Directory temporary;
  late Directory installed;

  setUpAll(() async {
    temporary = await Directory.systemTemp.createTemp('adele-main-editors-');
    installed = await Directory('${temporary.path}/installed').create();
    final artifact = File('${temporary.path}/fixture.evc');
    await prepareMainContentFixture(
      repositoryRoot: Directory.current.parent,
      artifact: artifact,
    );
    await installMainContentFixture(
      installationRoot: installed,
      artifact: artifact,
    );
  });
  tearDownAll(() => temporary.delete(recursive: true));

  testWidgets(
    'catalog EVC editors retain exact views, runtimes, native text and undo across order changes',
    (tester) => tester.runAsync(() async {
      await tester.binding.setSurfaceSize(const Size(1300, 700));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final resources = MainContentFixtureResources();
      addTearDown(resources.dispose);
      final extensions = ExtensionRegistry();
      final frontends = ApplicationFrontendBootstrap(
        extensions: extensions,
        mainContentHost: resources.host,
      );
      addTearDown(frontends.close);
      final catalog = await PreparedPluginCatalog.discover(installed.path);
      expect(catalog.issues, isEmpty);
      expect(catalog.installations.single.backendArtifactUri, isNull);
      await frontends.start(catalog);
      expect(frontends.generations.single.state, InstalledFrontendState.active);
      expect(extensions.discover(mainContentContributions), hasLength(1));
      expect(resources.editors, isEmpty);
      final chat = extensions.register(
        point: mainContentContributions,
        id: ExtensionId('test.main-content.chat'),
        value: MainContentContribution(
          order: 100,
          attach: (access) => access.open(
            MainContentPane(
              id: 'chat',
              title: 'Chat',
              createPresentation: () => const Text('Unchanged Chat fixture'),
            ),
          ),
        ),
      );
      addTearDown(chat.close);
      final session = Session(
        id: SessionId('main-content-session'),
        taskId: TaskId('task'),
        strategyId: OrchestrationStrategyId('test.strategy'),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: MainContentHost(session: session, extensions: extensions),
          ),
        ),
      );
      Future<void> until(bool Function() ready) async {
        final clock = Stopwatch()..start();
        while (!ready()) {
          if (clock.elapsed > const Duration(seconds: 10)) {
            fail('Timed out waiting for prepared native editor.');
          }
          await Future<void>.delayed(Duration.zero);
          await tester.pump();
        }
        await tester.pump();
      }

      Future<void> action(String label) async {
        final target = find.widgetWithText(TextButton, label);
        await tester.ensureVisible(target);
        await tester.tap(target);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 350));
      }

      Future<void> key(LogicalKeyboardKey key, {bool control = false}) async {
        if (control) {
          await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
        }
        try {
          await tester.sendKeyEvent(key);
        } finally {
          if (control) {
            await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
          }
        }
        await tester.pump();
      }

      final editors = find.byType(CodeForge);
      await until(() => editors.evaluate().length == 1);
      await action('Open B');
      await until(() => editors.evaluate().length == 2);
      expect(extensions.discover(mainContentContributions), hasLength(2));
      final chatElement = tester.element(find.text('Unchanged Chat fixture'));
      final a = resources.editor(session.id, 'editor-a')!;
      final b = resources.editor(session.id, 'editor-b')!;
      final elements = editors.evaluate().toList();
      final native = tester.widgetList<CodeForge>(editors).toList();
      final views = find.byWidgetPredicate(
        (widget) => widget is $StatefulWidget$bridge,
      );
      final evcElements = views.evaluate().toList();
      final evc = tester.widgetList<$StatefulWidget$bridge>(views).toList();
      final runtimes = evc.map((widget) => widget.$runtime).toList();
      expect(runtimes, hasLength(2));
      expect(runtimes[0], isNot(same(runtimes[1])));
      await action('Focus A');
      await key(LogicalKeyboardKey.home, control: true);
      await key(LogicalKeyboardKey.delete);
      expect(a.snapshot()['text'], mainContentFixtureTextA.substring(1));
      expect(b.snapshot()['text'], mainContentFixtureTextB);
      await action('Focus B');
      await key(LogicalKeyboardKey.home, control: true);
      await key(LogicalKeyboardKey.delete);
      expect(b.snapshot()['text'], mainContentFixtureTextB.substring(1));
      expect(a.snapshot()['text'], mainContentFixtureTextA.substring(1));
      await action('Rename B');
      await action('Reverse editors');
      expect(
        tester.element(find.text('Unchanged Chat fixture')),
        same(chatElement),
      );
      expect(editors.evaluate().toList(), [
        same(elements[1]),
        same(elements[0]),
      ]);
      expect(views.evaluate().toList(), [
        same(evcElements[1]),
        same(evcElements[0]),
      ]);
      final reordered = tester.widgetList<CodeForge>(editors).toList();
      expect(reordered[0].controller, same(native[1].controller));
      expect(reordered[0].undoController, same(native[1].undoController));
      expect(reordered[1].controller, same(native[0].controller));
      expect(reordered[1].undoController, same(native[0].undoController));
      expect(
        tester
            .widgetList<$StatefulWidget$bridge>(views)
            .map((widget) => widget.$runtime),
        [same(runtimes[1]), same(runtimes[0])],
      );
      await action('Open B');
      expect(resources.editor(session.id, 'editor-b'), same(b));
      expect(find.text('Renamed B'), findsOneWidget);
      await action('Focus A');
      await key(LogicalKeyboardKey.keyZ, control: true);
      expect(a.snapshot()['text'], mainContentFixtureTextA);
      expect(b.snapshot()['text'], mainContentFixtureTextB.substring(1));
      await key(LogicalKeyboardKey.keyY, control: true);
      expect(a.snapshot()['text'], mainContentFixtureTextA.substring(1));
      await action('Remove B');
      expect(b.isDisposed, isTrue);
      expect(a.isDisposed, isFalse);
      expect(
        tester.element(find.text('Unchanged Chat fixture')),
        same(chatElement),
      );
      expect(editors.evaluate().single, same(elements[0]));
      await tester.pumpWidget(const SizedBox.shrink());
      expect(a.isDisposed, isTrue);
      expect(resources.editors, isEmpty);
      expect(tester.takeException(), isNull);
    }),
  );
}
