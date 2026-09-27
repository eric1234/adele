import 'package:adele_desktop/ui/task_browser/task_browser_presentation_host.dart';
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
  late ExtensionRegistry extensions;
  setUp(() => extensions = ExtensionRegistry());
  Widget host({Project? value}) => MaterialApp(
    home: Scaffold(
      body: TaskBrowserPresentationHost(
        project: value ?? project,
        extensions: extensions,
      ),
    ),
  );
  ExtensionRegistration register(
    TaskBrowserContribution contribution, [
    String id = 'test.browser',
  ]) => extensions.register(
    point: taskBrowserContributions,
    id: ExtensionId(id),
    value: contribution,
  );

  testWidgets('missing and ambiguous browsers never pick a fallback', (
    tester,
  ) async {
    await tester.pumpWidget(host());
    expect(find.text('Task Browser is unavailable.'), findsOneWidget);
    var calls = 0;
    final contribution = TaskBrowserContribution(
      displayName: 'Browser',
      createPresentation: (_) {
        calls++;
        return const Text('Browser');
      },
    );
    register(contribution);
    final other = register(contribution, 'test.other');
    await tester.pumpAndSettle();
    expect(find.textContaining('Task Browser is ambiguous'), findsOneWidget);
    expect(calls, 0);
    await other.close();
    await tester.pumpAndSettle();
    expect(find.text('Browser'), findsOneWidget);
    expect(calls, 1);
  });

  testWidgets('search state and exact factory widget survive window rebuilds', (
    tester,
  ) async {
    var calls = 0;
    final contribution = TaskBrowserContribution(
      displayName: 'Browser',
      createPresentation: (value) {
        expect(value, same(project));
        calls++;
        return TextField();
      },
    );
    final first = register(contribution);
    await tester.pumpWidget(host());
    final retained = tester.widget(find.byType(TextField));
    await tester.enterText(find.byType(TextField), 'search');
    await tester.pumpWidget(host());
    extensions.register(
      point: ExtensionPoint<String>('test.unrelated'),
      id: ExtensionId('test.unrelated'),
      value: 'value',
    );
    await tester.pumpAndSettle();
    expect(calls, 1);
    expect(tester.widget(find.byType(TextField)), same(retained));
    expect(find.text('search'), findsOneWidget);
    await first.close();
    register(contribution);
    await tester.pumpAndSettle();
    expect(calls, 2);
    expect(find.text('search'), findsNothing);
  });

  testWidgets('failed factories do not retry on unrelated rebuilds', (
    tester,
  ) async {
    var calls = 0;
    register(
      TaskBrowserContribution(
        displayName: 'Broken',
        createPresentation: (_) {
          calls++;
          throw StateError('private diagnostic');
        },
      ),
    );
    await tester.pumpWidget(host());
    await tester.pumpWidget(host());
    expect(
      find.textContaining('the presentation could not be created'),
      findsOneWidget,
    );
    expect(calls, 1);
    final other = Project(
      id: ProjectId('other'),
      sourceLocation: Uri.parse('file:///other'),
    );
    await tester.pumpWidget(host(value: other));
    expect(calls, 2);
  });
}
