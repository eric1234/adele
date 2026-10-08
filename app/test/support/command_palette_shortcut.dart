import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

Future<bool> sendPaletteShortcut(
  WidgetTester tester, {
  List<LogicalKeyboardKey> modifiers = const [
    LogicalKeyboardKey.controlLeft,
    LogicalKeyboardKey.shiftLeft,
  ],
}) async {
  for (final modifier in modifiers) {
    await tester.sendKeyDownEvent(modifier);
  }
  try {
    final handled = await tester.sendKeyDownEvent(LogicalKeyboardKey.keyP);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.keyP);
    return handled;
  } finally {
    for (final modifier in modifiers.reversed) {
      await tester.sendKeyUpEvent(modifier);
    }
  }
}
