import 'dart:async';
import 'dart:ui' show AppExitResponse;

import 'package:adele_core_extensions/adele_core_extensions.dart';
import 'package:adele_desktop/application.dart';
import 'package:adele_desktop/core/application_plugin_bootstrap.dart';
import 'package:adele_desktop/terminal/native_adele_runtime.dart';
import 'package:adele_desktop/ui/commands/command_palette.dart';
import 'package:adele_plugin_api/adele_plugin_api.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late NativeAdeleRuntime runtime;
  late ExtensionRegistrationGroup registrations;
  late CommandResolver commands;

  setUp(() {
    runtime = NativeAdeleRuntime();
    registrations = ExtensionRegistrationGroup();
    commands = CommandResolver(runtime.extensions);
  });

  tearDown(() async {
    await registrations.close();
    if (runtime.plugins.state != ApplicationPluginState.closed) {
      await runtime.close();
    }
  });

  ExtensionRegistration contribute(
    String id,
    String label, {
    CommandAvailability Function()? availability,
    FutureOr<void> Function()? invoke,
    String? registrationId,
  }) {
    final registration = runtime.extensions.register(
      point: commandContributions,
      id: ExtensionId(registrationId ?? 'test.registration.$id'),
      value: CommandContribution(
        id: CommandId('test.command.$id'),
        label: label,
        availability: availability ?? () => CommandAvailability.enabled,
        invoke: invoke ?? () {},
      ),
    );
    registrations.add(registration);
    return registration;
  }

  Future<void> mount(WidgetTester tester) async {
    await tester.pumpWidget(
      AdeleApplication(
        createRuntime: () => runtime,
        bootstrapPlugins: (_) async {},
        readChatGptConfiguration: () => null,
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> open(WidgetTester tester) async {
    await tester.tap(find.byKey(const ValueKey('command-palette-button')));
    await tester.pumpAndSettle();
    expect(find.byType(CommandPalette), findsOneWidget);
  }

  Future<void> unmount(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    await runtime.close();
    expect(tester.takeException(), isNull);
  }

  final search = find.byKey(const ValueKey('command-palette-search'));

  testWidgets('global pre-Project palette focuses search and Escape closes', (
    tester,
  ) async {
    await mount(tester);
    expect(
      find.descendant(
        of: find.byType(AppBar),
        matching: find.byTooltip('Show Command Palette'),
      ),
      findsOneWidget,
    );
    final show = commands.resolve(showCommandPaletteCommandId);
    expect(show.availability, CommandAvailability.enabled);
    expect(
      commands.resolve(toggleConsoleCommandId).availability,
      CommandAvailability.hidden,
    );
    await open(tester);
    expect(tester.widget<TextField>(search).focusNode!.hasFocus, isTrue);
    expect(find.text('No commands are available.'), findsOneWidget);
    expect(find.text('Toggle Console'), findsNothing);
    expect(show.availability, CommandAvailability.hidden);
    await expectLater(show.invoke(), throwsA(isA<CommandUnavailable>()));
    expect(find.byType(CommandPalette), findsOneWidget);
    await tester.binding.setSurfaceSize(const Size(360, 640));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byType(CommandPalette), findsNothing);
    expect(show.availability, CommandAvailability.enabled);
    await unmount(tester);
  });

  testWidgets('AppBar resolves Show Command Palette rather than bypassing it', (
    tester,
  ) async {
    await mount(tester);
    final button = find.byKey(const ValueKey('command-palette-button'));
    final captured = tester.widget<IconButton>(button).onPressed!;
    var duplicateCalls = 0;
    final duplicate = runtime.extensions.register(
      point: commandContributions,
      id: ExtensionId('test.duplicate-show-palette'),
      value: CommandContribution(
        id: showCommandPaletteCommandId,
        label: 'Conflicting Show',
        availability: () => CommandAvailability.enabled,
        invoke: () => duplicateCalls++,
      ),
    );
    registrations.add(duplicate);
    captured();
    await tester.pumpAndSettle();
    expect(find.byType(CommandPalette), findsNothing);
    expect(duplicateCalls, 0);
    expect(tester.widget<IconButton>(button).onPressed, isNull);
    expect(find.text('The command could not be completed.'), findsOneWidget);
    await duplicate.close();
    await tester.pumpAndSettle();
    await open(tester);
    await unmount(tester);
  });

  testWidgets(
    'search matches label and ID case-insensitively in stable order',
    (tester) async {
      contribute('zebra', 'Zebra');
      contribute('beta', 'alpha');
      contribute('alpha', 'Alpha');
      await mount(tester);
      await open(tester);
      List<String> resultIds() => tester
          .widgetList<ListTile>(find.byType(ListTile))
          .map((tile) => (tile.subtitle! as Text).data!)
          .toList();
      expect(resultIds(), [
        'test.command.alpha',
        'test.command.beta',
        'test.command.zebra',
      ]);
      await tester.enterText(search, 'ALPHA');
      await tester.pump();
      expect(resultIds(), ['test.command.alpha', 'test.command.beta']);
      await tester.enterText(search, 'TEST.COMMAND.BETA');
      await tester.pump();
      expect(resultIds(), ['test.command.beta']);
      await tester.enterText(search, 'no-such-operation');
      await tester.pump();
      expect(find.text('No matching commands.'), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      expect(find.byType(CommandPalette), findsOneWidget);
      await unmount(tester);
    },
  );

  testWidgets('hidden omitted; disabled and failed evaluation cannot invoke', (
    tester,
  ) async {
    var calls = 0;
    contribute(
      'hidden',
      'Hidden operation',
      availability: () => CommandAvailability.hidden,
      invoke: () => calls++,
    );
    contribute(
      'disabled',
      'A disabled operation',
      availability: () => CommandAvailability.disabled,
      invoke: () => calls++,
    );
    contribute(
      'broken',
      'B failed evaluation',
      availability: () => throw StateError('private evaluation failure'),
      invoke: () => calls++,
    );
    contribute('enabled', 'C enabled operation', invoke: () => calls++);
    await mount(tester);
    await open(tester);
    expect(find.text('Hidden operation'), findsNothing);
    for (final label in ['A disabled operation', 'B failed evaluation']) {
      final tile = tester.widget<ListTile>(
        find.widgetWithText(ListTile, label),
      );
      expect(tile.enabled, isFalse);
      expect(tile.onTap, isNull);
    }
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(calls, 0);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(calls, 0);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    expect(
      tester
          .widget<ListTile>(
            find.widgetWithText(ListTile, 'C enabled operation'),
          )
          .selected,
      isTrue,
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pump();
    expect(
      tester
          .widget<ListTile>(
            find.widgetWithText(ListTile, 'B failed evaluation'),
          )
          .selected,
      isTrue,
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(calls, 1);
    expect(find.byType(CommandPalette), findsNothing);
    await unmount(tester);
  });

  testWidgets(
    'registration refresh omits conflicts without an arbitrary winner',
    (tester) async {
      var calls = 0;
      contribute('shared', 'First side', invoke: () => calls++);
      await mount(tester);
      await open(tester);
      final staleTap = tester
          .widget<ListTile>(find.widgetWithText(ListTile, 'First side'))
          .onTap!;
      final duplicate = contribute(
        'shared',
        'Other side',
        registrationId: 'test.other-registration',
        invoke: () => calls++,
      );
      staleTap();
      await tester.pumpAndSettle();
      expect(find.text('First side'), findsNothing);
      expect(find.text('Other side'), findsNothing);
      expect(find.text('No commands are available.'), findsOneWidget);
      expect(calls, 0);
      await duplicate.close();
      await tester.pumpAndSettle();
      expect(find.text('First side'), findsOneWidget);
      await tester.tap(find.text('First side'));
      await tester.pumpAndSettle();
      expect(calls, 1);
      await unmount(tester);
    },
  );

  testWidgets(
    'retirement never retargets a stale callback or selected command',
    (tester) async {
      var oldCalls = 0;
      var newCalls = 0;
      final old = contribute(
        'reused',
        'Old operation',
        invoke: () => oldCalls++,
      );
      await mount(tester);
      await open(tester);
      final staleTap = tester
          .widget<ListTile>(find.widgetWithText(ListTile, 'Old operation'))
          .onTap!;
      await old.close();
      contribute('reused', 'New operation', invoke: () => newCalls++);
      staleTap();
      await tester.pumpAndSettle();
      expect(find.text('Old operation'), findsNothing);
      expect(find.text('New operation'), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(oldCalls, 0);
      expect(newCalls, 0);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(newCalls, 1);
      staleTap();
      await tester.pumpAndSettle();
      expect(oldCalls, 0);
      expect(newCalls, 1);
      await unmount(tester);
    },
  );

  testWidgets('invocation re-evaluates availability without a notification', (
    tester,
  ) async {
    var enabled = true;
    var calls = 0;
    contribute(
      'changing',
      'Changing operation',
      availability: () =>
          enabled ? CommandAvailability.enabled : CommandAvailability.disabled,
      invoke: () => calls++,
    );
    await mount(tester);
    await open(tester);
    enabled = false;
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(calls, 0);
    expect(find.text('Unavailable'), findsOneWidget);
    expect(find.byType(CommandPalette), findsOneWidget);
    await unmount(tester);
  });

  testWidgets('a replacement cannot inherit the retired result row focus', (
    tester,
  ) async {
    var calls = 0;
    final old = contribute('focused', 'Focused operation');
    await mount(tester);
    await open(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    final row = find.widgetWithText(ListTile, 'Focused operation');
    final oldElement = tester.element(row);
    contribute('unrelated', 'Unrelated operation');
    await tester.pumpAndSettle();
    expect(tester.element(row), same(oldElement));
    await old.close();
    contribute('focused', 'Focused operation', invoke: () => calls++);
    await tester.pumpAndSettle();
    expect(tester.element(row), isNot(same(oldElement)));
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(calls, 0);
    await tester.tap(row);
    await tester.pumpAndSettle();
    expect(calls, 1);
    await unmount(tester);
  });

  testWidgets('Enter respects a tab-focused row or Close button', (
    tester,
  ) async {
    final calls = <String>[];
    contribute('first', 'First operation', invoke: () => calls.add('first'));
    contribute('second', 'Second operation', invoke: () => calls.add('second'));
    await mount(tester);
    await open(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(calls, ['second']);
    await open(tester);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(find.byType(CommandPalette), findsNothing);
    expect(calls, ['second']);
    await unmount(tester);
  });

  testWidgets('keyboard reveals results and a changed search returns to top', (
    tester,
  ) async {
    var invoked = -1;
    for (var index = 0; index < 25; index++) {
      contribute(
        'item-$index',
        'Operation ${index.toString().padLeft(2, '0')}',
        invoke: () => invoked = index,
      );
    }
    await mount(tester);
    await open(tester);
    for (var index = 0; index < 20; index++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();
    }
    expect(find.text('Operation 20').hitTestable(), findsOneWidget);
    await tester.enterText(search, 'operation');
    await tester.pumpAndSettle();
    expect(find.text('Operation 00').hitTestable(), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(invoked, 0);
    await unmount(tester);
  });

  for (final asynchronous in [false, true]) {
    testWidgets('command failure is contained (async: $asynchronous)', (
      tester,
    ) async {
      contribute(
        'failure',
        'Fail safely',
        invoke: asynchronous
            ? () async => throw StateError('private async exception')
            : () => throw StateError('private sync exception'),
      );
      await mount(tester);
      await open(tester);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(find.byType(CommandPalette), findsNothing);
      expect(find.text('The command could not be completed.'), findsOneWidget);
      expect(find.textContaining('private'), findsNothing);
      expect(tester.takeException(), isNull);
      await unmount(tester);
    });
  }

  for (final graceful in [false, true]) {
    testWidgets('application Commands retire (graceful: $graceful)', (
      tester,
    ) async {
      await mount(tester);
      final captured = commands.discover();
      expect(captured, hasLength(2));
      await open(tester);
      if (graceful) {
        expect(
          await tester.binding.handleRequestAppExit(),
          AppExitResponse.exit,
        );
        await tester.pumpAndSettle();
        expect(find.byType(CommandPalette), findsNothing);
      }
      await unmount(tester);
      expect(commands.discover(), isEmpty);
      for (final command in captured) {
        expect(command.binding.validate, throwsA(isA<StaleExtensionBinding>()));
        await expectLater(
          command.invoke(),
          throwsA(isA<StaleExtensionBinding>()),
        );
      }
    });
  }
}
