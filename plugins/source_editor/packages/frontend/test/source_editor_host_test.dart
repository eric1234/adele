import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:adele_capabilities/adele_capabilities.dart';
import 'package:adele_core_extensions/adele_core_extensions.dart';
import 'package:adele_desktop/core/product_lifecycle.dart';
import 'package:adele_desktop/frontend/application_frontend_bootstrap.dart';
import 'package:adele_desktop/frontend/contribution_bridge.dart';
import 'package:adele_desktop/frontend/prepared_main_content_host.dart';
import 'package:adele_desktop/ui/main_content/main_content_host.dart';
import 'package:adele_environment/adele_environment.dart';
import 'package:adele_plugin_api/adele_plugin_api.dart';
import 'package:adele_product/adele_product.dart';
import 'package:adele_ui/adele_ui.dart';
import 'package:code_forge/code_forge.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_eval/widgets.dart' show $StatefulWidget$bridge;
import 'package:flutter_test/flutter_test.dart';
import 'package:plugin_runtime/plugin_runtime.dart';

import '../../../../../app/tool/source_editor_frontend_compiler.dart';
import '../../../../../tools/stock_frontend_descriptors.dart';

const _path = 'lib/source.dart';
const _original = 'original source\n';
const _otherText = 'other Environment source\n';
const _readRevision = 'opaque:initial';
const _writeRevision = 'opaque:acknowledged';

void main() {
  late Directory temporary;
  late PreparedPluginCatalog catalog;

  setUpAll(() async {
    temporary = await Directory.systemTemp.createTemp('adele-source-host-');
    final installed = await Directory('${temporary.path}/source').create();
    await File('${installed.path}/frontend.evc').writeAsBytes(
      await compileSourceEditorFrontend(
        repositoryRoot: Directory.current.parent.parent.parent.parent,
      ),
    );
    await File(
      '${installed.path}/adele_plugin.installation.json',
    ).writeAsString(
      jsonEncode({
        'manifestVersion': 1,
        'metadata': {
          'id': 'dev.adele.source-editor',
          'version': '1',
          'displayName': 'Source Editor',
        },
        'components': {
          'frontend': {
            'artifact': 'frontend.evc',
            'presentations':
                stockFrontendDescriptors['dev.adele.source-editor'],
            'extensions':
                stockFrontendExtensionDescriptors['dev.adele.source-editor'],
          },
        },
      }),
    );
    catalog = await PreparedPluginCatalog.discover(temporary.path);
    expect(catalog.issues, isEmpty);
    expect(catalog.installations.single.backendArtifactUri, isNull);
  });
  tearDownAll(() => temporary.delete(recursive: true));

  Future<_Fixture> start(WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(1200, 800));
    final fixture = _Fixture();
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      await fixture.frontends.close();
      await fixture.registration.close();
      await tester.binding.setSurfaceSize(null);
    });
    await fixture.frontends.start(catalog);
    expect(
      fixture.frontends.generations.single.state,
      InstalledFrontendState.active,
    );
    expect(fixture.extensions.discover(mainContentContributions), hasLength(1));
    expect(
      fixture.extensions.discover(displaySourceFileContributions),
      hasLength(1),
    );
    expect(fixture.openSource.availability, CommandAvailability.hidden);
    await fixture.mount(tester, fixture.session);
    await _until(
      tester,
      () => fixture.openSource.availability == CommandAvailability.enabled,
    );
    expect(find.text('Open Source...'), findsOneWidget);
    expect(find.byType(CodeForge), findsNothing);
    expect(fixture.provider.restored, isEmpty);
    return fixture;
  }

  testWidgets(
    'actual Source Command presents input without reads and retains the normalized native owner',
    (tester) => tester.runAsync(() async {
      final fixture = await start(tester);
      final command = fixture.openSource;
      expect(command.id, CommandId('dev.adele.source-editor.open-source'));
      expect(
        command.binding.id,
        ExtensionId('dev.adele.source-editor.command.open-source'),
      );
      expect(command.label, 'Open Source...');
      expect(fixture.store.session(fixture.session.id), same(fixture.session));
      expect(
        fixture.store.requireSessionAuthority(fixture.session.id).environmentId,
        fixture.additional.id,
      );

      await command.invoke();
      await _until(
        tester,
        () => find.text('Open Source File').evaluate().isNotEmpty,
      );
      expect(find.byType(Dialog), findsOneWidget);
      expect(
        find.text('Existing path relative to the Session Environment'),
        findsOneWidget,
      );
      expect(fixture.provider.restored, isEmpty);
      expect(fixture.provider.reads, isEmpty);
      expect(find.byType(CodeForge), findsNothing);
      await tester.enterText(find.byType(TextField), './lib//source.dart');
      await tester.pump();
      expect(fixture.provider.reads, isEmpty);
      _press(tester, 'Open');
      await _until(
        tester,
        () => find.text('Source Document opened.').evaluate().isNotEmpty,
      );
      expect(fixture.provider.restored, [fixture.additional.id]);
      expect(fixture.provider.reads, [
        (fixture.additional.id, './lib//source.dart'),
      ]);
      await tester.tap(find.byTooltip('Close input'));
      await _until(tester, () => find.byType(Dialog).evaluate().isEmpty);
      final native = _editor(tester);
      final element = tester.element(find.byType(CodeForge));
      expect(native.controller!.text, _original);
      expect(find.text(_path), findsWidgets);
      await _deleteFirst(tester, native);

      await command.invoke();
      await _until(
        tester,
        () => find.text('Open Source File').evaluate().isNotEmpty,
      );
      await tester.enterText(find.byType(TextField), _path);
      await tester.pump();
      _press(tester, 'Open');
      await _until(
        tester,
        () => find.text('Source Document opened.').evaluate().isNotEmpty,
      );
      await tester.tap(find.byTooltip('Close input'));
      await _until(tester, () => find.byType(Dialog).evaluate().isEmpty);
      expect(fixture.provider.reads, hasLength(1));
      expect(find.byType(CodeForge), findsOneWidget);
      expect(tester.element(find.byType(CodeForge)), same(element));
      expect(_editor(tester).controller, same(native.controller));
      expect(_editor(tester).undoController, same(native.undoController));
      expect(native.controller!.text, _original.substring(1));
      native.focusNode!.requestFocus();
      await tester.pump();
      await _key(tester, LogicalKeyboardKey.keyZ, control: true);
      expect(native.controller!.text, _original);
      expect(fixture.provider.replacements, isEmpty);
      expect(fixture.store.runsForSession(fixture.session.id), isEmpty);
      expect(tester.takeException(), isNull);
    }),
  );

  testWidgets(
    'actual Source Command input cannot retarget its captured Environment after navigation',
    (tester) => tester.runAsync(() async {
      final fixture = await start(tester);
      final reading = Completer<EnvironmentTextFile>();
      addTearDown(() {
        if (!reading.isCompleted) reading.complete(_file(_original));
      });
      fixture.provider.reading = reading.future;
      await fixture.openSource.invoke();
      await _until(
        tester,
        () => find.text('Open Source File').evaluate().isNotEmpty,
      );
      await tester.enterText(find.byType(TextField), _path);
      await tester.pump();
      final oldSubmit = tester
          .widget<TextField>(find.byType(TextField))
          .onSubmitted!;
      _press(tester, 'Open');
      await _until(tester, () => fixture.provider.reads.isNotEmpty);
      expect(fixture.provider.reads, [(fixture.additional.id, _path)]);

      await fixture.mount(tester, fixture.otherSession);
      await _until(tester, () => find.byType(Dialog).evaluate().isEmpty);
      oldSubmit(_path);
      reading.complete(_file(_original));
      await fixture.host.drainOperations();
      await tester.pump();
      expect(find.byType(CodeForge), findsNothing);
      expect(fixture.provider.restored, [fixture.additional.id]);
      expect(fixture.provider.reads, [(fixture.additional.id, _path)]);

      fixture.provider.reading = null;
      await fixture.openSource.invoke();
      await _until(
        tester,
        () => find.text('Open Source File').evaluate().isNotEmpty,
      );
      await tester.enterText(find.byType(TextField), _path);
      await tester.pump();
      _press(tester, 'Open');
      await _until(
        tester,
        () => find.text('Source Document opened.').evaluate().isNotEmpty,
      );
      await tester.tap(find.byTooltip('Close input'));
      await _until(tester, () => find.byType(Dialog).evaluate().isEmpty);
      final other = _editor(tester);
      expect(other.controller!.text, _otherText);
      expect(fixture.provider.reads, [
        (fixture.additional.id, _path),
        (fixture.primary.id, _path),
      ]);

      await fixture.mount(tester, fixture.session);
      await _until(tester, () => find.byType(CodeForge).evaluate().length == 1);
      oldSubmit(_path);
      await tester.pump();
      expect(_editor(tester).controller, isNot(same(other.controller)));
      expect(_editor(tester).controller!.text, _original);
      expect(fixture.provider.reads, hasLength(2));
      expect(fixture.provider.replacements, isEmpty);
      expect(fixture.store.runsForSession(fixture.session.id), isEmpty);
      expect(fixture.store.runsForSession(fixture.otherSession.id), isEmpty);
      expect(tester.takeException(), isNull);
    }),
  );

  testWidgets(
    'actual Source EVC deduplicates concurrent normalized opens and preserves native undo',
    (tester) => tester.runAsync(() async {
      final fixture = await start(tester);
      final reading = Completer<EnvironmentTextFile>();
      addTearDown(() {
        if (!reading.isCompleted) reading.complete(_file(_original));
      });
      fixture.provider.reading = reading.future;
      final first = fixture.display('./lib/source.dart');
      final second = fixture.display('lib//source.dart');
      await _until(tester, () => fixture.provider.reads.length == 2);
      expect(find.byType(CodeForge), findsNothing);
      reading.complete(_file(_original));
      final results = await Future.wait([first, second]);
      expect(results.map((result) => result['ok']), everyElement(isTrue));
      expect(results[0]['id'], results[1]['id']);
      await _until(tester, () => find.byType(CodeForge).evaluate().length == 1);
      final native = _editor(tester);
      final element = tester.element(find.byType(CodeForge));
      final evc = tester.widget<$StatefulWidget$bridge>(
        find.byWidgetPredicate((widget) => widget is $StatefulWidget$bridge),
      );
      expect(native.controller!.text, _original);
      expect(fixture.provider.reads, [
        (fixture.additional.id, './lib/source.dart'),
        (fixture.additional.id, 'lib//source.dart'),
      ]);

      await _deleteFirst(tester, native);
      expect(native.controller!.text, _original.substring(1));
      fixture.provider.reading = null;
      final duplicate = await fixture.display(_path);
      await tester.pump();
      expect(duplicate['id'], results.first['id']);
      expect(tester.element(find.byType(CodeForge)), same(element));
      expect(_editor(tester).controller, same(native.controller));
      expect(_editor(tester).undoController, same(native.undoController));
      expect(
        tester
            .widget<$StatefulWidget$bridge>(
              find.byWidgetPredicate(
                (widget) => widget is $StatefulWidget$bridge,
              ),
            )
            .$runtime,
        same(evc.$runtime),
      );
      await _key(tester, LogicalKeyboardKey.keyZ, control: true);
      expect(native.controller!.text, _original);
      expect(fixture.provider.replacements, isEmpty);
      expect(fixture.store.runsForSession(fixture.session.id), isEmpty);
      expect(tester.takeException(), isNull);
    }),
  );

  testWidgets(
    'actual Source EVC reorders two edited documents without replacing native state',
    (tester) => tester.runAsync(() async {
      final fixture = await start(tester);
      expect((await fixture.display(_path))['ok'], isTrue);
      await _until(tester, () => find.byType(CodeForge).evaluate().length == 1);
      final first = _editor(tester);
      const secondPath = 'lib/second.dart';
      const secondText = 'second document\n';
      fixture.provider.reading = Future.value(
        EnvironmentTextFile(
          relativePath: secondPath,
          text: secondText,
          sizeBytes: utf8.encode(secondText).length,
          revision: 'opaque:second',
        ),
      );
      expect((await fixture.display(secondPath))['ok'], isTrue);
      await _until(tester, () => find.byType(CodeForge).evaluate().length == 2);
      final second = tester.widgetList<CodeForge>(find.byType(CodeForge)).last;
      await _deleteFirst(tester, first);
      await _deleteFirst(tester, second);
      await _until(
        tester,
        () =>
            find.text('* $_path').evaluate().isNotEmpty &&
            find.text('* $secondPath').evaluate().isNotEmpty,
      );

      void expectOrder(List<CodeForge> expected) {
        final actual = tester
            .widgetList<CodeForge>(find.byType(CodeForge))
            .toList();
        expect(actual, hasLength(2));
        for (var index = 0; index < expected.length; index++) {
          expect(actual[index].controller, same(expected[index].controller));
          expect(
            actual[index].undoController,
            same(expected[index].undoController),
          );
        }
        expect(first.controller!.text, _original.substring(1));
        expect(second.controller!.text, secondText.substring(1));
        expect(find.text('* $_path'), findsOneWidget);
        expect(find.text('* $secondPath'), findsOneWidget);
        expect(fixture.provider.replacements, isEmpty);
        expect(tester.takeException(), isNull);
      }

      void move(String label, int index) => tester
          .widget<TextButton>(find.widgetWithText(TextButton, label).at(index))
          .onPressed!();

      expectOrder([first, second]);
      move('Move left', 1);
      await tester.pump();
      expectOrder([second, first]);
      move('Move right', 0);
      await tester.pump();
      expectOrder([first, second]);
      move('Move left', 1);
      await tester.pump();
      expectOrder([second, first]);

      await fixture.hide(tester);
      expect(find.byType(CodeForge), findsNothing);
      await fixture.mount(tester, fixture.session);
      await _until(tester, () => find.byType(CodeForge).evaluate().length == 2);
      expectOrder([second, first]);
      expect(fixture.provider.reads, hasLength(2));
      final remounted = tester
          .widgetList<CodeForge>(find.byType(CodeForge))
          .toList();
      remounted[1].focusNode!.requestFocus();
      await tester.pump();
      await _key(tester, LogicalKeyboardKey.keyZ, control: true);
      expect(first.controller!.text, _original);
      expect(second.controller!.text, secondText.substring(1));
      remounted[0].focusNode!.requestFocus();
      await tester.pump();
      await _key(tester, LogicalKeyboardKey.keyZ, control: true);
      expect(second.controller!.text, secondText);
      expect(tester.takeException(), isNull);
    }),
  );

  testWidgets(
    'actual Source EVC retries a failed restore on a new explicit display',
    (tester) => tester.runAsync(() async {
      final fixture = await start(tester);
      final generation = fixture.frontends.generations.single;
      const failure = EnvironmentFailure(
        code: 'restore_failed',
        message: 'The retained provider state cannot be restored.',
        details: {'environment': 'additional'},
      );
      fixture.provider.restoreFailure = failure;
      expect(await fixture.display(_path), {
        'ok': false,
        'failure': {
          'code': failure.code,
          'message': failure.message,
          'details': failure.details,
        },
      });
      await tester.pump();
      expect(fixture.provider.restored, [fixture.additional.id]);
      expect(fixture.provider.reads, isEmpty);
      expect(find.byType(CodeForge), findsNothing);

      fixture.provider.restoreFailure = null;
      final recovered = await fixture.display(_path);
      expect(
        {
          'restores': fixture.provider.restored.length,
          'reads': fixture.provider.reads.length,
        },
        {'restores': 2, 'reads': 1},
        reason: 'A new explicit display must acquire fresh file access.',
      );
      expect(recovered['ok'], isTrue);
      expect(fixture.provider.restored, [
        fixture.additional.id,
        fixture.additional.id,
      ]);
      expect(fixture.provider.reads, [(fixture.additional.id, _path)]);
      expect(fixture.frontends.generations.single, same(generation));
      await _until(tester, () => find.byType(CodeForge).evaluate().length == 1);
      expect(_editor(tester).controller!.text, _original);
      expect(fixture.provider.replacements, isEmpty);
      expect(fixture.store.runsForSession(fixture.session.id), isEmpty);
      expect(tester.takeException(), isNull);
    }),
  );

  testWidgets(
    'actual Source EVC never migrates a pending restore but a new display uses the replacement',
    (tester) => tester.runAsync(() async {
      final fixture = await start(tester);
      final generation = fixture.frontends.generations.single;
      final restoring = Completer<EnvironmentProviderResult>();
      addTearDown(() {
        if (!restoring.isCompleted) {
          restoring.complete(
            EnvironmentProviderResult(providerState: {'ready': true}),
          );
        }
      });
      fixture.provider.restoration = restoring.future;
      final pending = fixture.display(_path);
      await _until(tester, () => fixture.provider.restored.length == 1);
      await fixture.registration.close();
      final replacement = _Provider();
      fixture.registration = fixture.register(replacement);
      restoring.complete(
        EnvironmentProviderResult(providerState: {'ready': true}),
      );
      final retired = await pending;
      expect(retired['ok'], isFalse);
      expect(retired['failure'], containsPair('code', 'binding_stale'));
      expect(fixture.provider.restored, [fixture.additional.id]);
      expect(fixture.provider.reads, isEmpty);
      expect(replacement.restored, isEmpty);
      expect(replacement.reads, isEmpty);
      expect(find.byType(CodeForge), findsNothing);

      expect((await fixture.display(_path))['ok'], isTrue);
      expect(replacement.restored, [fixture.additional.id]);
      expect(replacement.reads, [(fixture.additional.id, _path)]);
      expect(fixture.provider.restored, [fixture.additional.id]);
      expect(fixture.provider.reads, isEmpty);
      expect(fixture.frontends.generations.single, same(generation));
      await _until(tester, () => find.byType(CodeForge).evaluate().length == 1);
      expect(_editor(tester).controller!.text, _original);
      expect(fixture.provider.replacements, isEmpty);
      expect(replacement.replacements, isEmpty);
      expect(tester.takeException(), isNull);
    }),
  );

  testWidgets(
    'actual Source EVC failed and oversized provider reads never create an editor',
    (tester) => tester.runAsync(() async {
      final fixture = await start(tester);
      for (final failure in [
        const EnvironmentFailure(
          code: 'not_found',
          message: 'The file does not exist.',
          details: {'path': 'missing.dart'},
        ),
        const EnvironmentFailure(
          code: 'file_too_large',
          message: 'The requested file exceeds the supported size.',
          details: {'path': 'large.dart', 'limit': 1048576},
        ),
      ]) {
        fixture.provider.readFailure = failure;
        final result = await fixture.display(
          failure.details['path']! as String,
        );
        expect(result, {
          'ok': false,
          'failure': {
            'code': failure.code,
            'message': failure.message,
            'details': failure.details,
          },
        });
        await tester.pump();
        expect(find.byType(CodeForge), findsNothing);
      }
      expect(fixture.provider.replacements, isEmpty);
      expect(await fixture.frontends.prepareToExit(), isTrue);
      expect(fixture.confirmations, isEmpty);
      fixture.provider.readFailure = null;
      expect((await fixture.display(_path))['ok'], isTrue);
      await _until(tester, () => find.byType(CodeForge).evaluate().length == 1);
      expect(_editor(tester).controller!.text, _original);
      expect(tester.takeException(), isNull);
    }),
  );

  for (final sample in [
    'ascii\nsecond\n',
    'a\u{1f600}\r\nsecond\r\n',
    'a\u{1f600}\nno final newline',
  ]) {
    testWidgets(
      'Source native conditional roundtrip ${jsonEncode(sample)}',
      (tester) => tester.runAsync(() async {
        final fixture = await start(tester);
        fixture.provider.reading = Future.value(_file(sample));
        expect((await fixture.display(_path))['ok'], isTrue);
        await _until(
          tester,
          () => find.byType(CodeForge).evaluate().length == 1,
        );
        final native = _editor(tester);
        expect(native.controller!.text, sample);
        await _deleteFirst(tester, native);
        _press(tester, 'Save');
        await _until(tester, () => fixture.provider.replacements.isNotEmpty);
        expect(fixture.provider.replacements.single, (
          fixture.additional.id,
          _path,
          sample.substring(1),
          _readRevision,
        ));
        expect(native.controller!.text, sample.substring(1));
        expect(tester.takeException(), isNull);
      }),
    );
  }

  testWidgets(
    'held Save refuses Close and acknowledges only the original document after navigation',
    (tester) => tester.runAsync(() async {
      final fixture = await start(tester);
      await fixture.display(_path);
      await _until(tester, () => find.byType(CodeForge).evaluate().length == 1);
      final original = _editor(tester);
      await _deleteFirst(tester, original);
      final submitted = _original.substring(1);
      final replacing = Completer<EnvironmentTextFileReplacement>();
      addTearDown(() {
        if (!replacing.isCompleted) {
          replacing.complete(
            const EnvironmentTextFileReplacement(revision: _writeRevision),
          );
        }
      });
      fixture.provider.replacing = replacing.future;
      _press(tester, 'Save');
      await _until(tester, () => fixture.provider.replacements.length == 1);
      expect(fixture.provider.replacements.single, (
        fixture.additional.id,
        _path,
        submitted,
        _readRevision,
      ));
      await _deleteFirst(tester, original);
      final editedDuringSave = _original.substring(2);
      _closeChrome(tester);
      await tester.pump();
      expect(find.byType(CodeForge), findsOneWidget);
      expect(fixture.confirmations, isEmpty);

      await fixture.mount(tester, fixture.otherSession);
      await fixture.display(_path);
      await _until(tester, () => find.byType(CodeForge).evaluate().length == 1);
      final other = _editor(tester);
      expect(other.controller, isNot(same(original.controller)));
      expect(other.controller!.text, _otherText);
      replacing.complete(
        const EnvironmentTextFileReplacement(revision: _writeRevision),
      );
      await fixture.host.drainOperations();
      await tester.pump();
      expect(other.controller!.text, _otherText);
      expect(original.controller!.text, editedDuringSave);
      expect(fixture.provider.replacements, hasLength(1));

      // The acknowledgement advanced A's baseline to the submitted snapshot, not
      // its later text, and did not contaminate B's baseline.
      _press(tester, 'Close');
      await fixture.host.drainOperations();
      await _until(tester, () => find.byType(CodeForge).evaluate().isEmpty);
      expect(fixture.confirmations, isEmpty);
      await fixture.mount(tester, fixture.session);
      await _until(tester, () => find.byType(CodeForge).evaluate().length == 1);
      expect(_editor(tester).controller, same(original.controller));
      expect(_editor(tester).undoController, same(original.undoController));
      _press(tester, 'Close');
      await fixture.host.drainOperations();
      await tester.pump();
      expect(fixture.confirmations, hasLength(1));
      expect(find.byType(CodeForge), findsOneWidget);
      expect(original.controller!.text, editedDuringSave);

      fixture.provider.replacing = null;
      await _until(
        tester,
        () => find.widgetWithText(TextButton, 'Save').evaluate().isNotEmpty,
      );
      _press(tester, 'Save');
      await fixture.host.drainOperations();
      await tester.pump();
      expect(fixture.provider.replacements.last, (
        fixture.additional.id,
        _path,
        editedDuringSave,
        _writeRevision,
      ));
      await _until(
        tester,
        () => find.widgetWithText(TextButton, 'Close').evaluate().isNotEmpty,
      );
      _press(tester, 'Close');
      await fixture.host.drainOperations();
      await _until(tester, () => find.byType(CodeForge).evaluate().isEmpty);
      expect(fixture.confirmations, hasLength(1));
      expect(tester.takeException(), isNull);
    }),
  );

  testWidgets(
    'departed Source view callbacks cannot save or close a reattached native owner',
    (tester) => tester.runAsync(() async {
      final fixture = await start(tester);
      await fixture.display(_path);
      await _until(tester, () => find.byType(CodeForge).evaluate().length == 1);
      final original = _editor(tester);
      await _deleteFirst(tester, original);
      final callbacks = [
        for (final label in ['Save', 'Close', 'Move left', 'Move right'])
          tester
              .widget<TextButton>(find.widgetWithText(TextButton, label))
              .onPressed!,
      ];
      // Logical departure fences callbacks before Flutter disposes the old view.
      fixture.frontends.unbind(fixture.session);
      for (final callback in callbacks) {
        callback();
      }
      await fixture.mount(tester, fixture.otherSession);
      expect(find.byType(CodeForge), findsNothing);
      for (final callback in callbacks) {
        callback();
      }
      await tester.pump();
      await fixture.mount(tester, fixture.session);
      await _until(tester, () => find.byType(CodeForge).evaluate().length == 1);
      for (final callback in callbacks) {
        callback();
      }
      await tester.pump();
      expect(_editor(tester).controller, same(original.controller));
      expect(_editor(tester).undoController, same(original.undoController));
      expect(original.controller!.text, _original.substring(1));
      expect(fixture.provider.replacements, isEmpty);
      expect(fixture.confirmations, isEmpty);
      expect(tester.takeException(), isNull);
    }),
  );

  testWidgets(
    'failed Save and revision conflict retain text and the last acknowledged revision',
    (tester) => tester.runAsync(() async {
      final fixture = await start(tester);
      await fixture.display(_path);
      await _until(tester, () => find.byType(CodeForge).evaluate().length == 1);
      final original = _editor(tester);
      await _deleteFirst(tester, original);
      final changed = _original.substring(1);
      for (final failure in [
        const EnvironmentFailure(
          code: 'write_failed',
          message: 'Replacement was not acknowledged.',
          details: {'providerFact': 'failed'},
        ),
        const EnvironmentFailure(
          code: environmentRevisionConflictCode,
          message: 'The observed revision is stale.',
          details: {'expectedRevision': _readRevision},
        ),
      ]) {
        fixture.provider.replaceFailure = failure;
        await _until(
          tester,
          () => find.widgetWithText(TextButton, 'Save').evaluate().isNotEmpty,
        );
        _press(tester, 'Save');
        await fixture.host.drainOperations();
        await _until(
          tester,
          () => find.textContaining(failure.message).evaluate().isNotEmpty,
        );
        expect(original.controller!.text, changed);
        expect(_editor(tester).controller, same(original.controller));
        expect(_editor(tester).undoController, same(original.undoController));
        expect(fixture.provider.replacements.last, (
          fixture.additional.id,
          _path,
          changed,
          _readRevision,
        ));
      }
      expect(find.text('Save conflict'), findsOneWidget);
      expect(fixture.provider.replacements, hasLength(2));
      _press(tester, 'Close');
      await fixture.host.drainOperations();
      await tester.pump();
      expect(fixture.confirmations, hasLength(1));
      expect(find.byType(CodeForge), findsOneWidget);
      fixture.provider.replaceFailure = null;
      await _until(
        tester,
        () => find.widgetWithText(TextButton, 'Save').evaluate().isNotEmpty,
      );
      _press(tester, 'Save');
      await fixture.host.drainOperations();
      await tester.pump();
      expect(fixture.provider.replacements, hasLength(3));
      expect(fixture.provider.replacements.last.$4, _readRevision);
      expect(original.controller!.text, changed);
      expect(tester.takeException(), isNull);
    }),
  );

  testWidgets(
    'later explicit Source Save uses the last acknowledged revision without migrating or retrying a pending write',
    (tester) => tester.runAsync(() async {
      final fixture = await start(tester);
      final generation = fixture.frontends.generations.single;
      expect((await fixture.display(_path))['ok'], isTrue);
      await _until(tester, () => find.byType(CodeForge).evaluate().length == 1);
      final original = _editor(tester);
      await _deleteFirst(tester, original);
      _press(tester, 'Save');
      await fixture.host.drainOperations();
      await _until(tester, () => find.text('Saved').evaluate().isNotEmpty);
      expect(fixture.provider.replacements.single, (
        fixture.additional.id,
        _path,
        _original.substring(1),
        _readRevision,
      ));

      await _deleteFirst(tester, original);
      final changed = _original.substring(2);
      final replacing = Completer<EnvironmentTextFileReplacement>();
      addTearDown(() {
        if (!replacing.isCompleted) {
          replacing.complete(
            const EnvironmentTextFileReplacement(revision: _writeRevision),
          );
        }
      });
      fixture.provider.replacing = replacing.future;
      _press(tester, 'Save');
      await _until(tester, () => fixture.provider.replacements.length == 2);
      expect(fixture.provider.replacements.last, (
        fixture.additional.id,
        _path,
        changed,
        _writeRevision,
      ));
      await fixture.registration.close();
      final replacement = _Provider();
      fixture.registration = fixture.register(replacement);
      await tester.pump();
      expect(replacement.restored, isEmpty);
      expect(replacement.reads, isEmpty);
      expect(replacement.replacements, isEmpty);
      const failure = EnvironmentFailure(
        code: 'write_unacknowledged',
        message: 'The retired provider did not acknowledge the replacement.',
        details: {'providerFact': 'unacknowledged'},
      );
      replacing.completeError(failure);
      await fixture.host.drainOperations();
      await _until(
        tester,
        () => find.textContaining(failure.message).evaluate().isNotEmpty,
      );
      expect(find.text('Save unconfirmed'), findsOneWidget);
      expect(original.controller!.text, changed);
      expect(_editor(tester).controller, same(original.controller));
      expect(_editor(tester).undoController, same(original.undoController));
      expect(fixture.provider.replacements, hasLength(2));
      expect(replacement.restored, isEmpty);
      expect(replacement.reads, isEmpty);
      expect(replacement.replacements, isEmpty);

      _press(tester, 'Save');
      await fixture.host.drainOperations();
      await _until(tester, () => find.text('Saved').evaluate().isNotEmpty);
      expect(replacement.restored, [fixture.additional.id]);
      expect(replacement.reads, isEmpty);
      expect(replacement.replacements, [
        (fixture.additional.id, _path, changed, _writeRevision),
      ]);
      expect(fixture.provider.restored, [fixture.additional.id]);
      expect(fixture.provider.reads, [(fixture.additional.id, _path)]);
      expect(fixture.provider.replacements, hasLength(2));
      expect(fixture.frontends.generations.single, same(generation));
      expect(original.controller!.text, changed);
      expect(_editor(tester).controller, same(original.controller));
      expect(_editor(tester).undoController, same(original.undoController));
      expect(fixture.store.runsForSession(fixture.session.id), isEmpty);
      expect(tester.takeException(), isNull);
    }),
  );

  testWidgets(
    'hidden exit preflight snapshots actual text despite missed native notifications and Cancel retains it',
    (tester) => tester.runAsync(() async {
      final fixture = await start(tester);
      await fixture.display(_path);
      await _until(tester, () => find.byType(CodeForge).evaluate().length == 1);
      final original = _editor(tester);
      await fixture.hide(tester);
      expect(await fixture.frontends.prepareToExit(), isTrue);
      expect(fixture.confirmations, isEmpty);
      // Invalidate CodeForge's text cache while leaving the text unchanged. No
      // Source view is listening; the following real text change is unnotified.
      original.controller!.text = _original;
      var notifications = 0;
      void changed() => notifications++;
      original.controller!.addListener(changed);
      // Deliberately bypass controller notifications only in this fault-injection
      // test. The retained dirty hint must not replace an exit-time text read.
      original.controller!.rope.insert(0, 'hidden edit ');
      expect(notifications, 0);
      expect(original.controller!.text, 'hidden edit $_original');
      original.controller!.removeListener(changed);
      expect(await fixture.frontends.prepareToExit(), isFalse);
      expect(fixture.confirmations.single, contains(_path));
      expect(
        fixture.confirmations.single,
        contains(fixture.additional.id.value),
      );
      expect(find.byType(CodeForge), findsNothing);
      expect(fixture.provider.replacements, isEmpty);
      await fixture.mount(tester, fixture.session);
      await _until(tester, () => find.byType(CodeForge).evaluate().length == 1);
      expect(_editor(tester).controller, same(original.controller));
      expect(_editor(tester).undoController, same(original.undoController));
      expect(original.controller!.text, 'hidden edit $_original');
      expect(fixture.provider.reads, hasLength(1));

      await fixture.hide(tester);
      fixture.discard = true;
      expect(await fixture.frontends.prepareToExit(), isTrue);
      // Advice to exit is not final disposal: another participant may still veto.
      await fixture.mount(tester, fixture.session);
      await _until(tester, () => find.byType(CodeForge).evaluate().length == 1);
      expect(_editor(tester).controller, same(original.controller));
      expect(original.controller!.text, 'hidden edit $_original');
      expect(tester.takeException(), isNull);
    }),
  );

  testWidgets(
    'owner closure during a pending Source read cannot publish an orphan editor',
    (tester) => tester.runAsync(() async {
      final fixture = await start(tester);
      final reading = Completer<EnvironmentTextFile>();
      addTearDown(() {
        if (!reading.isCompleted) reading.complete(_file(_original));
      });
      fixture.provider.reading = reading.future;
      final pending = expectLater(fixture.display(_path), throwsA(anything));
      await _until(tester, () => fixture.provider.reads.isNotEmpty);
      await fixture.hide(tester);
      await fixture.frontends.close();
      reading.complete(_file(_original));
      await pending;
      await fixture.host.drainOperations();
      await tester.pump();
      expect(fixture.extensions.discover(mainContentContributions), isEmpty);
      expect(
        fixture.extensions.discover(displaySourceFileContributions),
        isEmpty,
      );
      expect(find.byType(CodeForge), findsNothing);
      expect(fixture.provider.replacements, isEmpty);
      expect(fixture.confirmations, isEmpty);
      expect(tester.takeException(), isNull);
    }),
  );

  test(
    'retained owner closes a provisional native editor during initialization',
    () async {
      final owner = RetainedContribution();
      final opening = owner.createEditor('provisional', _original, 'dart');
      final editor = owner.editor('provisional');
      owner.dispose();
      expect(editor.isDisposed, isTrue);
      // Initialization may reject when disposed before readiness, or report that
      // the provisional entry is gone after readiness. Neither outcome publishes it.
      await opening.then<void>(
        (created) => expect(created, isFalse),
        onError: (Object error) => expect(error, isA<StateError>()),
      );
      expect(() => owner.editor('provisional'), throwsStateError);
      expect(await owner.createEditor('late', _original, 'dart'), isFalse);
      expect(owner.keys, isEmpty);
    },
  );
}

CodeForge _editor(WidgetTester tester) =>
    tester.widget<CodeForge>(find.byType(CodeForge));

void _press(WidgetTester tester, String label) => tester
    .widget<TextButton>(find.widgetWithText(TextButton, label))
    .onPressed!();

void _closeChrome(WidgetTester tester) => tester
    .widget<IconButton>(
      find.byWidgetPredicate(
        (widget) =>
            widget is IconButton &&
            (widget.tooltip?.startsWith('Close ') ?? false),
      ),
    )
    .onPressed!();

Future<void> _until(WidgetTester tester, bool Function() ready) async {
  final clock = Stopwatch()..start();
  while (!ready()) {
    if (clock.elapsed > const Duration(seconds: 10)) {
      fail('Timed out waiting for the prepared Source Editor.');
    }
    await Future<void>.delayed(const Duration(milliseconds: 1));
    await tester.pump();
  }
  await tester.pump();
}

Future<void> _deleteFirst(WidgetTester tester, CodeForge editor) async {
  editor.focusNode!.requestFocus();
  await tester.pump();
  await _key(tester, LogicalKeyboardKey.home, control: true);
  await _key(tester, LogicalKeyboardKey.delete);
}

Future<void> _key(
  WidgetTester tester,
  LogicalKeyboardKey key, {
  bool control = false,
}) async {
  if (control) await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
  try {
    await tester.sendKeyEvent(key);
  } finally {
    if (control) await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
  }
  await tester.pump();
}

EnvironmentTextFile _file(String text) => EnvironmentTextFile(
  relativePath: _path,
  text: text,
  sizeBytes: utf8.encode(text).length,
  revision: _readRevision,
);

final class _Fixture {
  _Fixture() {
    primary = Environment(
      id: EnvironmentId('primary'),
      taskId: task.id,
      role: EnvironmentRole.primary,
      providerId: provider.providerId,
      providerState: const {'ready': true},
    );
    additional = Environment(
      id: EnvironmentId('additional'),
      taskId: task.id,
      role: EnvironmentRole.additional,
      providerId: provider.providerId,
      providerState: const {'ready': true},
    );
    store.publishRestoredProject(
      project: Project(
        id: task.projectId,
        sourceLocation: Uri.parse('file:///fixture'),
      ),
      tasks: [task],
      environments: [primary, additional],
      sessions: [session, otherSession],
      authorities: [(session.id, additional.id), (otherSession.id, primary.id)],
      runRecords: const [],
    );
    registration = register(provider);
    host = PreparedMainContentHost(
      environmentRuntime: EnvironmentRuntime(
        store: store,
        registry: registry,
        providerForBinding: (binding) =>
            binding.endpointAs<_Endpoint>().provider,
        retainEnvironment: store.replaceEnvironment,
      ),
      confirm: (request) async {
        expect(request['title'], 'Discard unsaved changes?');
        expect(request['acceptLabel'], 'Discard');
        expect(request['cancelLabel'], 'Cancel');
        confirmations.add(request['message']! as String);
        return discard;
      },
    );
    frontends = ApplicationFrontendBootstrap(
      extensions: extensions,
      mainContentHost: host,
    );
  }

  final store = InMemoryProductStore();
  final registry = CapabilityRegistry();
  final extensions = ExtensionRegistry();
  final provider = _Provider();
  final confirmations = <String>[];
  final task = Task(
    id: TaskId('task'),
    projectId: ProjectId('project'),
    title: 'Source files',
  );
  final session = Session(
    id: SessionId('source-session'),
    taskId: TaskId('task'),
    strategyId: OrchestrationStrategyId('test.unavailable-strategy'),
  );
  final otherSession = Session(
    id: SessionId('other-session'),
    taskId: TaskId('task'),
    strategyId: OrchestrationStrategyId('test.unavailable-strategy'),
  );
  late final Environment primary;
  late final Environment additional;
  late CapabilityRegistration registration;
  late final PreparedMainContentHost host;
  late final ApplicationFrontendBootstrap frontends;
  bool discard = false;
  Session? current;

  CapabilityRegistration register(_Provider provider) => registry.register(
    provider: ProviderDescriptor(
      id: provider.providerId,
      capability: environmentProviderCapability,
      pluginId: 'test.source-files',
      displayName: 'Source files fixture',
      serviceId: environmentProviderServiceId,
    ),
    endpoint: _Endpoint(provider),
  );

  Future<Map<String, Object?>> display(String path) =>
      DisplaySourceFileResolver(extensions).display(path);

  ResolvedCommand get openSource => CommandResolver(
    extensions,
  ).resolve(CommandId('dev.adele.source-editor.open-source'));

  Future<void> mount(WidgetTester tester, Session selected) async {
    if (current case final previous?) {
      await frontends.prepareToDeactivate(previous);
      frontends.unbind(previous);
    }
    current = selected;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MainContentHost(
            session: selected,
            extensions: extensions,
            actionCoordinator: host.actionCoordinator,
          ),
        ),
      ),
    );
    await tester.pump();
  }

  Future<void> hide(WidgetTester tester) async {
    if (current case final previous?) {
      await frontends.prepareToDeactivate(previous);
      frontends.unbind(previous);
    }
    current = null;
    await tester.pumpWidget(const SizedBox.shrink());
  }
}

final class _Endpoint implements CapabilityEndpoint {
  const _Endpoint(this.provider);
  final _Provider provider;
  @override
  bool get isAvailable => true;
  @override
  String get serviceId => environmentProviderServiceId;
}

final class _Provider implements EnvironmentProvider {
  @override
  final providerId = ProviderId('test.source-files');
  final restored = <EnvironmentId>[];
  final reads = <(EnvironmentId, String)>[];
  final replacements = <(EnvironmentId, String, String, String)>[];
  Future<EnvironmentProviderResult>? restoration;
  Future<EnvironmentTextFile>? reading;
  Future<EnvironmentTextFileReplacement>? replacing;
  EnvironmentFailure? restoreFailure;
  EnvironmentFailure? readFailure;
  EnvironmentFailure? replaceFailure;

  @override
  Future<EnvironmentProviderResult> restore(
    LocalEnvironment environment,
  ) async {
    restored.add(environment.id);
    if (restoreFailure case final failure?) throw failure;
    return restoration ??
        EnvironmentProviderResult(providerState: environment.providerState!);
  }

  @override
  Future<EnvironmentTextFile> readFile(
    EnvironmentId environmentId,
    String relativePath,
  ) async {
    reads.add((environmentId, relativePath));
    if (readFailure case final failure?) throw failure;
    return reading ??
        _file(environmentId.value == 'primary' ? _otherText : _original);
  }

  @override
  Future<EnvironmentTextFileReplacement> replaceExistingTextFile(
    EnvironmentId environmentId,
    String relativePath,
    String replacementText,
    String expectedRevision,
  ) async {
    replacements.add((
      environmentId,
      relativePath,
      replacementText,
      expectedRevision,
    ));
    if (replaceFailure case final failure?) throw failure;
    return replacing ??
        const EnvironmentTextFileReplacement(revision: _writeRevision);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
