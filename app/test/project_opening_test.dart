import 'dart:async';
import 'dart:ui' show AppExitResponse;

import 'package:adele_core_extensions/adele_core_extensions.dart';
import 'package:adele_desktop/application.dart';
import 'package:adele_desktop/core/adele_runtime.dart';
import 'package:adele_desktop/core/product_lifecycle.dart';
import 'package:adele_desktop/ui/shell/adele_shell.dart';
import 'package:adele_environment/adele_environment.dart';
import 'package:adele_model_provider/adele_model_provider.dart';
import 'package:adele_plugin_api/adele_plugin_api.dart';
import 'package:adele_product/adele_product.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late AdeleRuntime runtime;
  late _RecordingIds ids;

  setUp(() {
    ids = _RecordingIds();
    runtime = AdeleRuntime(ids: ids);
  });

  ExtensionRegistration registerSelector(Future<Uri?> Function() select) {
    final ExtensionRegistration registration = runtime.extensions.register(
      point: projectSelectorContributions,
      id: ExtensionId('dev.adele.test.project-selector'),
      value: ProjectSelectorContribution(
        displayName: 'Open Test Source...',
        selectProject: select,
      ),
    );
    // This test owns its additional contribution, not the stock runtime.
    addTearDown(registration.close);
    return registration;
  }

  void expectNoProject(WidgetTester tester) {
    expect(runtime.store.project(ProjectId('selected-1')), isNull);
    expect(tester.widget<AdeleShell>(find.byType(AdeleShell)).project, isNull);
    expect(find.text('No Project is open'), findsOneWidget);
    expect(find.text('Project is open'), findsNothing);
    expect(tester.takeException(), isNull);
  }

  for (final String source in <String>[
    'file:///source/Project%20Name/',
    'catalog://team/Project%20Name?revision=stable#details',
  ]) {
    testWidgets('opens one canonical Project and retains it: $source', (
      WidgetTester tester,
    ) async {
      int selections = 0;
      int runtimeCreations = 0;
      final Uri uri = Uri.parse(source);
      registerSelector(() async {
        selections++;
        return uri;
      });
      AdeleRuntime createRuntime() {
        runtimeCreations++;
        return runtime;
      }

      await tester.pumpWidget(AdeleApplication(createRuntime: createRuntime));
      expect(ids.calls, isEmpty);
      expect(find.text('Open Local Directory...'), findsOneWidget);
      expect(find.text('Open Test Source...'), findsOneWidget);
      expect(
        tester.getTopLeft(find.text('Open Local Directory...')).dy,
        lessThan(tester.getTopLeft(find.text('Open Test Source...')).dy),
      );

      await tester.tap(find.text('Open Test Source...'));
      await tester.pumpAndSettle();

      final Project project = tester
          .widget<AdeleShell>(find.byType(AdeleShell))
          .project!;
      expect(project.id, ProjectId('selected-1'));
      expect(project.sourceLocation, uri);
      expect(runtime.store.project(project.id), same(project));
      expect(ids.calls, <String>['project']);
      expect(selections, 1);
      expect(find.text('No Project is open'), findsNothing);
      expect(find.text('Open Test Source...'), findsNothing);
      expect(find.text('Project Name'), findsOneWidget);
      expect(find.text(uri.toString()), findsOneWidget);
      expect(find.text('Project is open'), findsOneWidget);
      expect(find.text('No Tasks yet'), findsOneWidget);
      expect(runtime.store.tasksFor(project.id), isEmpty);
      expect(
        runtime.registry.providersFor(environmentProviderCapability),
        isEmpty,
      );
      expect(runtime.registry.providersFor(modelProviderCapability), isEmpty);

      await tester.pumpWidget(AdeleApplication(createRuntime: createRuntime));
      expect(runtimeCreations, 1);
      expect(
        tester.widget<AdeleShell>(find.byType(AdeleShell)).project,
        same(project),
      );
      expect(ids.calls, <String>['project']);
      await tester.binding.setSurfaceSize(const Size(360, 640));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pump();
      expect(find.text('No Tasks yet'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    });
  }

  testWidgets('no selectors renders an unavailable state', (tester) async {
    // Retire stock contributions before mounting; no activation settings API.
    await runtime.close();
    await tester.pumpWidget(AdeleApplication(createRuntime: () => runtime));

    expectNoProject(tester);
    expect(find.text('No Project selectors are available.'), findsOneWidget);
    expect(find.byType(FilledButton), findsNothing);
    expect(ids.calls, isEmpty);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('cancellation is a no-op and permits another invocation', (
    tester,
  ) async {
    int selections = 0;
    registerSelector(() async {
      selections++;
      return null;
    });
    await tester.pumpWidget(AdeleApplication(createRuntime: () => runtime));

    for (int invocation = 0; invocation < 2; invocation++) {
      await tester.tap(find.text('Open Test Source...'));
      await tester.pumpAndSettle();
      expectNoProject(tester);
      expect(ids.calls, isEmpty);
      expect(find.textContaining('Could not open Project'), findsNothing);
      expect(find.text('Selecting Project...'), findsNothing);
    }
    expect(selections, 2);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'selector error does not create a Project or substitute a selector',
    (tester) async {
      registerSelector(() async => throw StateError('picker failed'));
      await tester.pumpWidget(AdeleApplication(createRuntime: () => runtime));
      await tester.tap(find.text('Open Test Source...'));
      await tester.pumpAndSettle();

      expectNoProject(tester);
      expect(ids.calls, isEmpty);
      expect(
        find.textContaining('Could not open Project: Bad state: picker failed'),
        findsOneWidget,
      );
      expect(find.text('Open Test Source...'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('lifecycle failure preserves the pre-Project state', (
    tester,
  ) async {
    ids.failProject = true;
    registerSelector(() async => Uri.parse('file:///source/'));
    await tester.pumpWidget(AdeleApplication(createRuntime: () => runtime));
    await tester.tap(find.text('Open Test Source...'));
    await tester.pumpAndSettle();

    expectNoProject(tester);
    expect(ids.calls, <String>['project']);
    expect(find.textContaining('Project creation failed'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'pending selection disables actions and rejects duplicate invocation',
    (tester) async {
      final Completer<Uri?> selection = Completer<Uri?>();
      int selections = 0;
      registerSelector(() {
        selections++;
        return selection.future;
      });
      await tester.pumpWidget(AdeleApplication(createRuntime: () => runtime));
      await tester.tap(find.text('Open Test Source...'));
      await tester.tap(find.text('Open Test Source...'));
      await tester.pump();

      expect(selections, 1);
      expect(ids.calls, isEmpty);
      expect(find.text('Selecting Project...'), findsOneWidget);
      for (final FilledButton button in tester.widgetList<FilledButton>(
        find.byType(FilledButton),
      )) {
        expect(button.onPressed, isNull);
      }
      selection.complete(Uri.parse('file:///source/'));
      await tester.pumpAndSettle();
      expect(ids.calls, <String>['project']);
      expect(find.text('No Tasks yet'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('retired selector cannot publish an in-flight result', (
    tester,
  ) async {
    final Completer<Uri?> selection = Completer<Uri?>();
    final ExtensionRegistration registration = registerSelector(
      () => selection.future,
    );
    await tester.pumpWidget(AdeleApplication(createRuntime: () => runtime));
    await tester.tap(find.text('Open Test Source...'));
    await tester.pump();
    await registration.close();
    selection.complete(Uri.parse('file:///source/'));
    await tester.pumpAndSettle();

    expectNoProject(tester);
    expect(ids.calls, isEmpty);
    expect(find.textContaining('StaleExtensionBinding'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  for (final bool exit in <bool>[false, true]) {
    testWidgets(
      'late selection after ${exit ? 'exit' : 'disposal'} is ignored',
      (tester) async {
        final Completer<Uri?> selection = Completer<Uri?>();
        registerSelector(() => selection.future);
        await tester.pumpWidget(AdeleApplication(createRuntime: () => runtime));
        final ExtensionBinding<ProjectSelectorContribution> stockSelector =
            runtime.extensions.discover(projectSelectorContributions).first;
        await tester.tap(find.text('Open Test Source...'));
        await tester.pump();

        if (exit) {
          expect(
            await tester.binding.handleRequestAppExit(),
            AppExitResponse.exit,
          );
        } else {
          await tester.pumpWidget(const SizedBox.shrink());
        }
        selection.complete(Uri.parse('file:///source/'));
        await tester.pumpAndSettle();

        expect(ids.calls, isEmpty);
        expect(runtime.store.project(ProjectId('selected-1')), isNull);
        expect(stockSelector.validate, throwsA(isA<StaleExtensionBinding>()));
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }
}

final class _RecordingIds implements ProductIdSource {
  final List<String> calls = <String>[];
  bool failProject = false;

  @override
  ProjectId nextProjectId() {
    calls.add('project');
    if (failProject) throw StateError('Project creation failed');
    return ProjectId('selected-${calls.length}');
  }

  @override
  TaskId nextTaskId() => throw StateError('Must not create a Task');

  @override
  EnvironmentId nextEnvironmentId() =>
      throw StateError('Must not create an Environment');

  @override
  SessionId nextSessionId() => throw StateError('Must not create a Session');
}
