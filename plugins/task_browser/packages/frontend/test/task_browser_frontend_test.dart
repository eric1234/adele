import 'dart:async';
import 'dart:io';

import 'package:adele_desktop/frontend/prepared_frontend.dart';
import 'package:adele_desktop/frontend/prepared_task_browser_host.dart';
import 'package:adele_desktop/frontend/task_browser_bridge.dart';
import 'package:adele_desktop/ui/theme/adele_theme.dart';
import 'package:adele_plugin_api/adele_plugin_api.dart';
import 'package:adele_product/adele_product.dart';
import 'package:adele_ui/adele_ui.dart';
import 'package:dart_eval/dart_eval.dart';
import 'package:flutter/material.dart';
import 'package:flutter_eval/flutter_eval.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plugin_runtime/plugin_runtime.dart';

import '../tool/task_browser_frontend_compiler.dart';

void main() {
  late Directory temporary;
  late File artifact;
  late PreparedFrontend generation;
  late PreparedTaskBrowserHost host;
  late _Source source;
  final project = Project(
    id: ProjectId('project'),
    sourceLocation: Uri.parse('file:///example-project'),
  );

  setUpAll(() async {
    temporary = await Directory.systemTemp.createTemp('task-browser-eval-');
    artifact = File('${temporary.path}/frontend.evc');
    // Normal preparation compiles other Flutter frontends before Task Browser.
    // Ensure its LayoutBuilder declaration does not rely on first-compiler state.
    (Compiler()
          ..addPlugin(flutterEvalPlugin)
          ..entrypoints.add('package:layout_warmup/main.dart'))
        .compile({
          'layout_warmup': {
            'main.dart': '''
import 'package:flutter/material.dart';
Widget build() => Text('Another frontend');
''',
          },
        });
    final bytecode = await compileTaskBrowserFrontend(
      repositoryRoot: Directory.current.parent.parent.parent.parent,
    );
    await artifact.writeAsBytes(bytecode);
  });
  tearDownAll(() => temporary.delete(recursive: true));

  setUp(() async {
    source = _Source();
    generation = await PreparedFrontend.load(artifact);
    host = PreparedTaskBrowserHost(sourceForProject: (_) => source);
  });

  tearDown(() async {
    generation.invalidate();
    await host.close();
    if (!source.disposed) source.dispose();
  });

  Future<void> mount(
    WidgetTester tester, {
    double width = 1100,
    double height = 900,
  }) async {
    tester.view.reset();
    tester.view.physicalSize = Size(width, height);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAdeleTheme(),
        home: Scaffold(
          body: host.createPresentation(
            generation: generation,
            contribution: TaskBrowserContribution(
              displayName: 'Task Browser',
              createPresentation: (_) =>
                  throw StateError('Unused fixture factory'),
            ),
            descriptor: PreparedTaskBrowserPresentation(
              extensionId: ExtensionId(
                'dev.adele.plugin.task-browser.task-browser',
              ),
              displayName: 'Task Browser',
              library: taskBrowserFrontendLibrary,
              entrypoint: 'createTaskBrowser',
            ),
            project: project,
            isActive: () => true,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.byType(LayoutBuilder), findsWidgets);
  }

  Finder field(String label) => find.descendant(
    of: find
        .ancestor(of: find.text(label), matching: find.byType(Column))
        .first,
    matching: find.byType(TextField),
  );

  testWidgets('empty Project exposes truthful empty states and creation form', (
    tester,
  ) async {
    source.tasks.clear();
    await mount(tester);
    expect(find.text('Project: Example Project'), findsOneWidget);
    expect(
      find.text('No Tasks yet. Create a Task to get started.'),
      findsOneWidget,
    );
    expect(
      find.text('Select a Task to view its Environment and Sessions.'),
      findsOneWidget,
    );
    expect(source.operations, isEmpty);
    expect(find.widgetWithText(ElevatedButton, 'New Task'), findsOneWidget);
    await tester.tap(find.text('New Task'));
    await tester.pumpAndSettle();
    expect(find.byType(Card), findsNWidgets(2));
    expect(find.text('Task title'), findsOneWidget);
    expect(find.widgetWithText(TextButton, 'Create Task'), findsNothing);
    await tester.enterText(field('Task title'), '   ');
    await tester.pumpAndSettle();
    expect(find.widgetWithText(TextButton, 'Create Task'), findsNothing);
    expect(source.operations, isEmpty);
  });

  testWidgets('title substring search is local and case insensitive', (
    tester,
  ) async {
    await mount(tester);
    await tester.enterText(find.byType(TextField), 'ETA');
    await tester.pumpAndSettle();
    expect(find.text('Beta task'), findsOneWidget);
    expect(find.text('Alpha task'), findsNothing);
    expect(source.operations, isEmpty);
    await tester.enterText(find.byType(TextField), 'not a title');
    await tester.pumpAndSettle();
    expect(find.text('No Tasks match your search.'), findsOneWidget);
    await tester.enterText(find.byType(TextField), '');
    await tester.pumpAndSettle();
    expect(find.text('Alpha task'), findsOneWidget);
    expect(find.text('Beta task'), findsOneWidget);
  });

  testWidgets('row callbacks retain each Task identity after rendering', (
    tester,
  ) async {
    await mount(tester);
    await tester.tap(find.text('Alpha task'));
    await tester.pumpAndSettle();
    expect(source.operations, [('selectTask', 'task-a')]);
    expect(find.text('Environment: environment-task-a'), findsOneWidget);
    expect(find.text('Provider: dev.example.environment'), findsOneWidget);
    expect(find.text('No Sessions in this Task.'), findsOneWidget);
    expect(
      find.text('No Session creation strategy is available.'),
      findsOneWidget,
    );
    await tester.tap(find.text('Beta task'));
    await tester.pumpAndSettle();
    expect(source.operations.last, ('selectTask', 'task-b'));
    expect(find.text('Task: task-b'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('notifications retain search and unsubmitted Task title', (
    tester,
  ) async {
    await mount(tester);
    await tester.enterText(find.byType(TextField), 'alpha');
    await tester.tap(find.text('New Task'));
    await tester.pumpAndSettle();
    await tester.enterText(field('Task title'), '  Keep this draft  ');
    source.tasks.add(_task('task-c', 'Another alpha'));
    source.selectedId = 'task-a';
    source.notifyListeners();
    await tester.pumpAndSettle();
    expect(find.text('Another alpha'), findsOneWidget);
    expect(find.text('Beta task'), findsNothing);
    expect(
      tester.widget<TextField>(field('Task title')).controller!.text,
      '  Keep this draft  ',
    );
    expect(find.text('alpha'), findsOneWidget);
    expect(source.operations, isEmpty);
  });

  testWidgets('generic execution status refreshes without granting actions', (
    tester,
  ) async {
    source.selectedId = 'task-a';
    source.tasks[0] = _task(
      'task-a',
      'Alpha task',
      sessionCount: 7,
      preparing: 1,
      running: 1,
      waiting: 1,
      completed: 1,
      cancelled: 1,
      failed: 1,
    );
    for (final status in [
      'idle',
      'preparing',
      'running',
      'waitingForApproval',
      'completed',
      'cancelled',
      'failed',
    ]) {
      source.sessions.add(
        _session(
          'session-$status',
          '$status Session',
          executionStatus: status,
          available: status != 'waitingForApproval',
        ),
      );
    }
    await mount(tester, height: 1800);
    expect(
      find.text(
        '7 Sessions\n1 preparing | 1 running | 1 waiting | 3 terminal (1 failed)',
      ),
      findsOneWidget,
    );
    for (final label in [
      'Idle',
      'Preparing',
      'Running',
      'Waiting for approval',
      'Completed',
      'Cancelled',
      'Failed',
    ]) {
      expect(find.textContaining('Status: $label'), findsOneWidget);
    }
    expect(find.text('Approve'), findsNothing);
    expect(find.text('Reject'), findsNothing);
    expect(
      tester
          .widget<ListTile>(
            find.widgetWithText(ListTile, 'waitingForApproval Session'),
          )
          .enabled,
      isFalse,
    );
    await tester.tap(find.text('waitingForApproval Session'));
    expect(source.operations, isEmpty);
    final reads = source.reads;
    source.sessions[2]['executionStatus'] = 'completed';
    source.tasks[0] = _task(
      'task-a',
      'Alpha task',
      sessionCount: 7,
      preparing: 1,
      waiting: 1,
      completed: 2,
      cancelled: 1,
      failed: 1,
    );
    for (var i = 0; i < 10; i++) {
      source.notifyListeners();
    }
    await tester.pumpAndSettle();
    expect(source.reads, reads + 1);
    expect(
      find.text(
        '7 Sessions\n1 preparing | 0 running | 1 waiting | 4 terminal (1 failed)',
      ),
      findsOneWidget,
    );
    expect(find.textContaining('Status: Completed'), findsNWidgets(2));
    expect(find.textContaining('Status: Running'), findsNothing);
    expect(source.operations, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'create guards busy state, preserves failure draft, and retries',
    (tester) async {
      source.gate = Completer<void>();
      source.failOperation = true;
      await mount(tester);
      await tester.tap(find.text('New Task'));
      await tester.pumpAndSettle();
      await tester.enterText(field('Task title'), '  New work  ');
      await tester.pumpAndSettle();
      await tester.tap(find.text('Create Task'));
      await tester.pumpAndSettle();
      expect(find.text('Creating Task...'), findsOneWidget);
      expect(tester.widget<TextField>(field('Task title')).enabled, isFalse);
      expect(find.widgetWithText(TextButton, 'Create Task'), findsNothing);
      final tile = tester.widget<ListTile>(
        find.widgetWithText(ListTile, 'Alpha task'),
      );
      expect(tile.enabled, isFalse);
      await tester.tap(find.text('Alpha task'));
      await tester.pumpAndSettle();
      expect(source.operations, [('createTask', 'New work')]);
      source.gate!.complete();
      await tester.pumpAndSettle();
      expect(
        find.text('Task Browser action could not be completed.'),
        findsOneWidget,
      );
      expect(
        tester.widget<TextField>(field('Task title')).controller!.text,
        '  New work  ',
      );
      expect(source.tasks, hasLength(2));
      source.failOperation = false;
      source.gate = null;
      await tester.tap(find.text('Create Task'));
      await tester.pumpAndSettle();
      expect(source.operations, [
        ('createTask', 'New work'),
        ('createTask', 'New work'),
      ]);
      expect(source.tasks, hasLength(3));
      expect(find.text('Task title'), findsNothing);
      expect(find.text('Task: task-new'), findsOneWidget);
      expect(
        find.text('Task Browser action could not be completed.'),
        findsNothing,
      );
      await tester.tap(find.text('New Task'));
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextField>(field('Task title')).controller!.text,
        isEmpty,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'single choice uses its label and opaque handle, not Chat assumptions',
    (tester) async {
      source.selectedId = 'task-a';
      source.options.add({
        'opaqueHandle': 'opaque-not-strategy',
        'displayName': 'Planner',
      });
      await mount(tester);
      expect(find.text('New Chat Session'), findsNothing);
      await tester.tap(find.text('New Planner Session'));
      await tester.pumpAndSettle();
      expect(source.operations, [('createSession', 'opaque-not-strategy')]);
      expect(find.text('opaque-not-strategy'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'zero choices disable creation without hiding existing Sessions',
    (tester) async {
      source.selectedId = 'task-a';
      source.sessions.add(_session('existing-session', 'Existing Session'));
      await mount(tester);
      expect(find.text('New Session'), findsOneWidget);
      expect(find.widgetWithText(TextButton, 'New Session'), findsNothing);
      expect(find.widgetWithText(ElevatedButton, 'New Session'), findsNothing);
      expect(
        tester.widget<Text>(find.text('New Session')).style!.color,
        Colors.grey,
      );
      expect(
        find.text('No Session creation strategy is available.'),
        findsOneWidget,
      );
      expect(find.widgetWithText(ListTile, 'Existing Session'), findsOneWidget);
      await tester.tap(find.text('New Session'));
      await tester.pumpAndSettle();
      expect(source.operations, isEmpty);
      await tester.tap(find.text('Existing Session'));
      await tester.pumpAndSettle();
      expect(source.operations, [('openSession', 'existing-session')]);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('multiple choices retain their distinct handles', (tester) async {
    source.selectedId = 'task-a';
    source.options.addAll([
      {'opaqueHandle': 'choice-first', 'displayName': 'Planner'},
      {'opaqueHandle': 'choice-last', 'displayName': 'Review'},
    ]);
    await mount(tester);
    expect(find.text('New Session: choose a strategy'), findsOneWidget);
    await tester.tap(find.text('Planner'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Review'));
    await tester.pumpAndSettle();
    expect(source.operations, [
      ('createSession', 'choice-first'),
      ('createSession', 'choice-last'),
    ]);
  });

  testWidgets('Session rows open exact IDs and unavailable rows are disabled', (
    tester,
  ) async {
    source.selectedId = 'task-a';
    source.sessions.addAll([
      _session('session-first', 'First session'),
      _session('session-last', 'Other session'),
      _session('session-unavailable', 'Offline session', available: false),
    ]);
    await mount(tester);
    expect(
      find.text(
        'Session: session-first\nStrategy: dev.example.chat\nStatus: Idle',
      ),
      findsOneWidget,
    );
    expect(
      tester
          .widget<ListTile>(find.widgetWithText(ListTile, 'Offline session'))
          .enabled,
      isFalse,
    );
    await tester.tap(find.text('Offline session'));
    await tester.tap(find.text('First session'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Other session'));
    await tester.pumpAndSettle();
    expect(source.operations, [
      ('openSession', 'session-first'),
      ('openSession', 'session-last'),
    ]);
    source.sessions[0]['available'] = false;
    source.notifyListeners();
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<ListTile>(find.widgetWithText(ListTile, 'First session'))
          .enabled,
      isFalse,
    );
  });

  testWidgets('narrow detail navigation and resizing retain local state', (
    tester,
  ) async {
    await mount(tester, width: 360);
    await tester.enterText(find.byType(TextField), 'Alpha');
    await tester.pumpAndSettle();
    await tester.tap(find.text('Alpha task'));
    await tester.pumpAndSettle();
    expect(find.text('Back to Tasks'), findsOneWidget);
    expect(find.text('Search tasks'), findsNothing);
    expect(find.text('Task: task-a'), findsOneWidget);
    await tester.tap(find.text('Back to Tasks'));
    await tester.pumpAndSettle();
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      'Alpha',
    );
    expect(find.text('Beta task'), findsNothing);
    tester.view.physicalSize = const Size(1000, 900);
    await tester.pumpAndSettle();
    expect(find.text('Search tasks'), findsOneWidget);
    expect(find.text('Task: task-a'), findsOneWidget);
    expect(find.text('Back to Tasks'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  for (final failInitialRead in [false, true]) {
    testWidgets(
      'narrow reopen shows selected Task details (retry: $failInitialRead)',
      (tester) async {
        source.selectedId = 'task-a';
        source.failRead = failInitialRead;
        await mount(tester, width: 360);
        if (failInitialRead) {
          source.failRead = false;
          await tester.tap(find.text('Retry'));
          await tester.pumpAndSettle();
        }
        expect(find.text('Task: task-a'), findsOneWidget);
        expect(find.text('Back to Tasks'), findsOneWidget);
        expect(find.text('Search tasks'), findsNothing);
        expect(source.operations, isEmpty);
        await tester.tap(find.text('Back to Tasks'));
        await tester.pumpAndSettle();
        source.notifyListeners();
        await tester.pumpAndSettle();
        expect(find.text('Search tasks'), findsOneWidget);
        expect(find.text('Task: task-a'), findsNothing);
        expect(source.operations, isEmpty);
        expect(tester.takeException(), isNull);
      },
    );
  }

  for (final width in [360.0, 1100.0]) {
    testWidgets(
      'creation shows new details while preserving search at width $width',
      (tester) async {
        await mount(tester, width: width);
        await tester.enterText(find.byType(TextField), 'Alpha');
        await tester.tap(find.text('New Task'));
        await tester.pumpAndSettle();
        await tester.enterText(field('Task title'), 'Unmatched new task');
        await tester.pumpAndSettle();
        await tester.tap(find.text('Create Task'));
        await tester.pumpAndSettle();
        expect(find.text('Task: task-new'), findsOneWidget);
        expect(find.text('Unmatched new task'), findsOneWidget);
        expect(source.operations, [('createTask', 'Unmatched new task')]);
        if (width < 760) {
          await tester.tap(find.text('Back to Tasks'));
          await tester.pumpAndSettle();
        }
        expect(
          tester.widget<TextField>(find.byType(TextField)).controller!.text,
          'Alpha',
        );
        expect(
          find.widgetWithText(ListTile, 'Unmatched new task'),
          findsNothing,
        );
        expect(find.text('Alpha task'), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('Cancel discards the title without clearing local search', (
    tester,
  ) async {
    await mount(tester);
    await tester.enterText(find.byType(TextField), 'Beta');
    await tester.tap(find.text('New Task'));
    await tester.pumpAndSettle();
    await tester.enterText(field('Task title'), 'Discard this title');
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(find.text('Task title'), findsNothing);
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      'Beta',
    );
    await tester.tap(find.text('New Task'));
    await tester.pumpAndSettle();
    expect(
      tester.widget<TextField>(field('Task title')).controller!.text,
      isEmpty,
    );
    expect(source.operations, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'retained local callbacks cannot mutate pending or disposed forms',
    (tester) async {
      source.gate = Completer<void>();
      await mount(tester);
      final open = tester
          .widget<ElevatedButton>(
            find.widgetWithText(ElevatedButton, 'New Task'),
          )
          .onPressed!;
      final searchChanged = tester
          .widget<TextField>(find.byType(TextField))
          .onChanged!;
      open();
      await tester.pumpAndSettle();
      await tester.enterText(field('Task title'), 'Keep this pending title');
      await tester.pumpAndSettle();
      final cancel = tester
          .widget<TextButton>(find.widgetWithText(TextButton, 'Cancel'))
          .onPressed!;
      final submit = tester
          .widget<TextButton>(find.widgetWithText(TextButton, 'Create Task'))
          .onPressed!;
      final titleChanged = tester
          .widget<TextField>(field('Task title'))
          .onChanged!;
      final keyboardSubmit = tester
          .widget<TextField>(field('Task title'))
          .onSubmitted!;
      submit();
      cancel();
      open();
      titleChanged('Retained change');
      keyboardSubmit('Retained keyboard submission');
      await tester.pumpAndSettle();
      expect(find.text('Creating Task...'), findsOneWidget);
      expect(
        tester.widget<TextField>(field('Task title')).controller!.text,
        'Keep this pending title',
      );
      expect(source.operations, [('createTask', 'Keep this pending title')]);
      source.gate!.complete();
      await tester.pumpAndSettle();
      keyboardSubmit('Submission from a closed form');
      await tester.pumpAndSettle();
      expect(find.text('Task title'), findsNothing);
      expect(source.operations, hasLength(1));
      final reads = source.reads;
      await tester.pumpWidget(const SizedBox.shrink());
      cancel();
      open();
      submit();
      titleChanged('After disposal');
      searchChanged('After disposal');
      keyboardSubmit('After disposal');
      await tester.pumpAndSettle();
      expect(source.reads, reads);
      expect(source.operations, hasLength(1));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('cancelled form callbacks cannot target a reopened form', (
    tester,
  ) async {
    await mount(tester);
    await tester.tap(find.text('New Task'));
    await tester.pumpAndSettle();
    await tester.enterText(field('Task title'), 'Discarded title');
    await tester.pumpAndSettle();
    final oldSubmit = tester
        .widget<TextButton>(find.widgetWithText(TextButton, 'Create Task'))
        .onPressed!;
    final oldCancel = tester
        .widget<TextButton>(find.widgetWithText(TextButton, 'Cancel'))
        .onPressed!;
    final oldKeyboardSubmit = tester
        .widget<TextField>(field('Task title'))
        .onSubmitted!;
    final oldChanged = tester.widget<TextField>(field('Task title')).onChanged!;
    oldCancel();
    await tester.pumpAndSettle();
    oldSubmit();
    oldKeyboardSubmit('Stale hidden submission');
    await tester.pumpAndSettle();
    expect(find.text('Task title'), findsNothing);
    expect(source.operations, isEmpty);
    await tester.tap(find.text('New Task'));
    await tester.pumpAndSettle();
    expect(
      tester.widget<TextField>(field('Task title')).controller!.text,
      isEmpty,
    );
    await tester.enterText(field('Task title'), 'Current title');
    await tester.pumpAndSettle();
    oldSubmit();
    oldKeyboardSubmit('Stale reopened submission');
    oldCancel();
    oldChanged('Stale edit');
    await tester.pumpAndSettle();
    expect(
      tester.widget<TextField>(field('Task title')).controller!.text,
      'Current title',
    );
    expect(source.operations, isEmpty);
    await tester.tap(find.text('Create Task'));
    await tester.pumpAndSettle();
    expect(source.operations, [('createTask', 'Current title')]);
    expect(find.text('Task: task-new'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('single populated Task and nested creation maps remain boxed', (
    tester,
  ) async {
    source.tasks.removeLast();
    source.options.add({'opaqueHandle': 'choice', 'displayName': 'Review'});
    await mount(tester, width: 800, height: 600);
    await tester.tap(find.widgetWithText(ListTile, 'Alpha task'));
    await tester.pumpAndSettle();
    expect(find.text('Task: task-a'), findsOneWidget);
    expect(find.text('Environment: environment-task-a'), findsOneWidget);
    await tester.tap(find.text('New Review Session'));
    await tester.pumpAndSettle();
    expect(source.operations, [
      ('selectTask', 'task-a'),
      ('createSession', 'choice'),
    ]);
    expect(tester.takeException(), isNull);
  });

  for (final width in [320.0, 800.0]) {
    testWidgets(
      'inline form scrolls without overflow at $width by 360 pixels',
      (tester) async {
        source.gate = Completer<void>();
        await mount(tester, width: width, height: 360);
        await tester.tap(find.text('New Task'));
        await tester.pumpAndSettle();
        await tester.ensureVisible(field('Task title'));
        await tester.enterText(
          field('Task title'),
          'A long title in a short surface',
        );
        await tester.pumpAndSettle();
        await tester.ensureVisible(find.text('Create Task'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Create Task'));
        await tester.pumpAndSettle();
        expect(find.text('Creating Task...'), findsOneWidget);
        expect(tester.takeException(), isNull);
        source.gate!.complete();
        await tester.pumpAndSettle();
        expect(find.text('Task: task-new'), findsOneWidget);
        expect(source.operations, [
          ('createTask', 'A long title in a short surface'),
        ]);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('unsubscribes and ignores operation settlement after disposal', (
    tester,
  ) async {
    source.gate = Completer<void>();
    await mount(tester);
    expect(source.hasSubscriptions, isTrue);
    await tester.tap(find.text('Alpha task'));
    await tester.pumpAndSettle();
    expect(find.text('Selecting Task...'), findsOneWidget);
    final reads = source.reads;
    await tester.pumpWidget(const SizedBox.shrink());
    expect(source.hasSubscriptions, isFalse);
    source.gate!.complete();
    await tester.pumpAndSettle();
    expect(source.reads, reads);
    expect(source.operations, [('selectTask', 'task-a')]);
    expect(tester.takeException(), isNull);
  });

  testWidgets('exit-retained form ignores settlement and retained controls', (
    tester,
  ) async {
    source.gate = Completer<void>();
    source.failOperation = true;
    await mount(tester);
    final open = tester
        .widget<ElevatedButton>(find.widgetWithText(ElevatedButton, 'New Task'))
        .onPressed!;
    open();
    await tester.pumpAndSettle();
    await tester.enterText(field('Task title'), 'Pending exit');
    await tester.pumpAndSettle();
    final submit = tester
        .widget<TextButton>(find.widgetWithText(TextButton, 'Create Task'))
        .onPressed!;
    final cancel = tester
        .widget<TextButton>(find.widgetWithText(TextButton, 'Cancel'))
        .onPressed!;
    submit();
    await tester.pumpAndSettle();
    generation.retainPresentations();
    source.gate!.complete();
    await tester.pumpAndSettle();
    submit();
    cancel();
    open();
    await tester.pumpAndSettle();
    expect(
      find.text('Task Browser action could not be completed.'),
      findsNothing,
    );
    expect(
      tester.widget<TextField>(field('Task title')).controller!.text,
      'Pending exit',
    );
    expect(source.operations, [('createTask', 'Pending exit')]);
    expect(tester.takeException(), isNull);
    generation.releasePresentations();
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'snapshot failure is explicit, disables actions, and is retryable',
    (tester) async {
      source.failRead = true;
      await mount(tester);
      expect(find.text('Task Browser is unavailable.'), findsOneWidget);
      expect(find.text('Loading Task Browser...'), findsNothing);
      expect(source.operations, isEmpty);
      source.failRead = false;
      await tester.tap(find.text('Retry'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'alpha');
      source.failRead = true;
      source.notifyListeners();
      await tester.pumpAndSettle();
      expect(
        find.text('Task Browser could not refresh. Retry to load tasks.'),
        findsOneWidget,
      );
      expect(
        tester
            .widget<ListTile>(find.widgetWithText(ListTile, 'Alpha task'))
            .enabled,
        isFalse,
      );
      expect(find.widgetWithText(ElevatedButton, 'New Task'), findsNothing);
      source.failRead = false;
      await tester.tap(find.text('Retry'));
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        'alpha',
      );
      expect(find.text('Beta task'), findsNothing);
      expect(find.text('Retry'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'missing Environment is visible without inventing provider identity',
    (tester) async {
      source.selectedId = 'task-a';
      source.hasEnvironment = false;
      await mount(tester);
      expect(find.text('No primary Environment is available.'), findsOneWidget);
      expect(find.text('Provider: dev.example.environment'), findsNothing);
      expect(source.operations, isEmpty);
    },
  );

  for (final width in [320.0, 759.0, 760.0]) {
    testWidgets('long factual identities fit a $width pixel surface', (
      tester,
    ) async {
      const title =
          'Investigate a long descriptive Task title without fabricated status';
      source.tasks[0]['title'] = title;
      source.sessions.add(
        _session(
          'session-b5d48a0c-9a39-480a-aaf5-bfdb40fd4675',
          'A descriptive Chat Session presentation',
          available: false,
          executionStatus: 'waitingForApproval',
        ),
      );
      await mount(tester, width: width);
      await tester.tap(find.text(title));
      await tester.pumpAndSettle();
      expect(find.text('Primary Environment'), findsOneWidget);
      expect(find.text('Unavailable'), findsOneWidget);
      expect(
        find.text('Back to Tasks'),
        width < 760 ? findsOneWidget : findsNothing,
      );
      expect(tester.takeException(), isNull);
    });
  }
}

Map<String, Object?> _session(
  String id,
  String name, {
  bool available = true,
  String executionStatus = 'idle',
}) => {
  'id': id,
  'strategyId': 'dev.example.chat',
  'presentationName': name,
  'available': available,
  'executionStatus': executionStatus,
};

Map<String, Object?> _task(
  String id,
  String title, {
  int sessionCount = 0,
  int preparing = 0,
  int running = 0,
  int waiting = 0,
  int completed = 0,
  int cancelled = 0,
  int failed = 0,
}) => {
  'id': id,
  'title': title,
  'sessionCount': sessionCount,
  'executionCounts': {
    'preparing': preparing,
    'running': running,
    'waiting': waiting,
    'terminal': completed + cancelled + failed,
    'completed': completed,
    'cancelled': cancelled,
    'failed': failed,
  },
};

final class _Source extends ChangeNotifier implements TaskBrowserSource {
  final tasks = <Map<String, Object?>>[
    _task('task-a', 'Alpha task'),
    _task('task-b', 'Beta task'),
  ];
  final sessions = <Map<String, Object?>>[];
  final options = <Map<String, Object?>>[];
  final operations = <(String, String?)>[];
  String? selectedId;
  Completer<void>? gate;
  bool failOperation = false;
  bool failRead = false;
  bool hasEnvironment = true;
  bool disposed = false;
  int reads = 0;

  bool get hasSubscriptions => hasListeners;

  @override
  void notifyListeners() {
    if (!disposed) super.notifyListeners();
  }

  @override
  void dispose() {
    disposed = true;
    super.dispose();
  }

  @override
  Map<String, Object?> read() {
    reads++;
    if (failRead) throw StateError('Private snapshot diagnostic');
    final selected = selectedId == null
        ? null
        : tasks.singleWhere((task) => task['id'] == selectedId);
    return {
      'project': {'id': 'project', 'displayName': 'Example Project'},
      'tasks': tasks,
      'selectedTaskId': selectedId,
      'selectedTask': selected == null
          ? null
          : {
              'id': selectedId,
              'title': selected['title'],
              'primaryEnvironment': !hasEnvironment
                  ? null
                  : {
                      'id': 'environment-$selectedId',
                      'providerId': 'dev.example.environment',
                    },
              'sessions': sessions,
              'sessionCreationOptions': options,
            },
    };
  }

  Future<void> settle(String operation, String? value) async {
    operations.add((operation, value));
    await gate?.future;
    if (failOperation) throw StateError('Private diagnostic must not escape');
  }

  @override
  Future<void> selectTask(String? taskId) async {
    await settle('selectTask', taskId);
    selectedId = taskId;
    notifyListeners();
  }

  @override
  Future<void> createTask(String title) async {
    await settle('createTask', title);
    tasks.add(_task('task-new', title));
    selectedId = 'task-new';
    notifyListeners();
  }

  @override
  Future<void> createSession(String optionHandle) =>
      settle('createSession', optionHandle);

  @override
  Future<void> openSession(String sessionId) =>
      settle('openSession', sessionId);
}
