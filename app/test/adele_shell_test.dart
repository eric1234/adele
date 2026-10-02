import 'package:adele_desktop/ui/main_content/main_content_host.dart';
import 'package:adele_desktop/ui/shell/adele_shell.dart';
import 'package:adele_plugin_api/adele_plugin_api.dart';
import 'package:adele_product/adele_product.dart';
import 'package:adele_ui/adele_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final project = Project(
    id: ProjectId('project'),
    sourceLocation: Uri.parse('file:///project'),
  );

  Widget shell({
    required bool presented,
    Widget? content,
    Widget? inspection,
    Widget? console,
  }) => MaterialApp(
    home: AdeleShell(
      project: project,
      selectors: const [],
      onSelectProject: (_) {},
      sessionPresented: presented,
      taskBrowser: const Text('Browser work area'),
      sessionContent: content,
      inspection: inspection,
      console: console,
    ),
  );

  testWidgets(
    'Session context does not depend on strategy widget availability',
    (tester) async {
      await tester.pumpWidget(
        shell(presented: true, console: const Text('Session console')),
      );
      expect(find.text('Session presentation is unavailable.'), findsOneWidget);
      expect(find.text('Browser work area'), findsNothing);
      expect(find.text('Session console'), findsOneWidget);

      await tester.pumpWidget(
        shell(
          presented: false,
          content: const Text('Not browser content'),
          console: const Text('Session console'),
        ),
      );
      expect(find.text('Browser work area'), findsOneWidget);
      expect(find.text('Not browser content'), findsNothing);
      expect(find.text('Session console'), findsNothing);
    },
  );

  testWidgets(
    'only Main Content scrolls horizontally, not Inspection or console',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1400, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final extensions = ExtensionRegistry();
      final chatRegistration = extensions.register(
        point: mainContentContributions,
        id: ExtensionId('dev.adele.test.chat'),
        value: MainContentContribution(
          order: 100,
          attach: (access) => access.open(
            MainContentPane(
              id: 'chat',
              title: 'Chat',
              createPresentation: () => const Center(child: Text('Chat body')),
            ),
          ),
        ),
      );
      addTearDown(chatRegistration.close);
      late MainContentAccess access;
      final registration = extensions.register(
        point: mainContentContributions,
        id: ExtensionId('dev.adele.test.editors'),
        value: MainContentContribution(
          order: 300,
          attach: (value) {
            access = value;
            for (final id in ['a', 'b']) {
              access.open(
                MainContentPane(
                  id: id,
                  title: 'Editor $id',
                  createPresentation: () => Center(child: Text('Body $id')),
                ),
              );
            }
          },
        ),
      );
      addTearDown(registration.close);
      await tester.pumpWidget(
        shell(
          presented: true,
          content: MainContentHost(
            session: Session(
              id: SessionId('session'),
              taskId: TaskId('task'),
              strategyId: OrchestrationStrategyId('dev.adele.test.strategy'),
            ),
            extensions: extensions,
          ),
          inspection: const SizedBox(
            key: ValueKey('inspection'),
            height: 200,
            child: Text('Inspection'),
          ),
          console: const SizedBox(
            key: ValueKey('console'),
            height: 120,
            child: Text('Console'),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final inspection = tester.getRect(
        find.byKey(const ValueKey('inspection')),
      );
      final console = tester.getRect(find.byKey(const ValueKey('console')));
      final chatX = tester.getTopLeft(find.text('Chat body')).dx;
      access.focus('b');
      await tester.pumpAndSettle();
      expect(tester.getTopLeft(find.text('Chat body')).dx, lessThan(chatX));
      expect(
        tester.getRect(find.byKey(const ValueKey('inspection'))),
        inspection,
      );
      expect(tester.getRect(find.byKey(const ValueKey('console'))), console);
      expect(
        tester.getRect(find.text('Body b')).right,
        lessThan(inspection.left),
      );
      expect(tester.takeException(), isNull);
    },
  );
}
