import 'dart:async';

import 'package:adele_desktop/frontend/command_bridge.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late List<MethodCall> calls;
  late List<String> messages;
  late bool active;

  CommandBridge bridge({bool clipboardWrite = true, bool feedback = true}) =>
      CommandBridge(
        clipboardWrite: clipboardWrite,
        feedback: feedback,
        validateOperation: () {
          if (!active) throw StateError('Operation retired.');
        },
        showFeedback: messages.add,
      );

  setUp(() {
    calls = [];
    messages = [];
    active = true;
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      calls.add(call);
      return null;
    });
  });
  tearDown(
    () => messenger.setMockMethodCallHandler(SystemChannels.platform, null),
  );

  test('writes only bounded text and never reads the clipboard', () async {
    final owner = bridge();
    final text = 'x' * 16384;
    expect(await owner.writeClipboard(text), isTrue);
    expect(calls.single.method, 'Clipboard.setData');
    expect(calls.single.arguments, {'text': text});
    await expectLater(owner.writeClipboard('$text!'), throwsFormatException);
    expect(calls, hasLength(1));
    owner.showFeedback(text);
    expect(messages, [text]);
    expect(() => owner.showFeedback('$text!'), throwsFormatException);
  });

  test('clipboard and feedback opt-ins are independent', () async {
    final notices = bridge(clipboardWrite: false);
    await expectLater(notices.writeClipboard('secret'), throwsStateError);
    notices.showFeedback('notice');
    final clipboard = bridge(feedback: false);
    expect(await clipboard.writeClipboard('text'), isTrue);
    expect(() => clipboard.showFeedback('notice'), throwsStateError);
    expect(calls, hasLength(1));
    expect(messages, ['notice']);
  });

  test('platform failure is a false outcome without diagnostics', () async {
    messenger.setMockMethodCallHandler(SystemChannels.platform, (_) async {
      throw PlatformException(code: 'private', message: 'sensitive payload');
    });
    expect(await bridge().writeClipboard('secret'), isFalse);
    expect(messages, isEmpty);
  });

  for (final retireOwner in [false, true]) {
    test('retirement fences native calls owner=$retireOwner', () async {
      final owner = bridge();
      if (retireOwner) {
        owner.invalidate();
      } else {
        active = false;
      }
      await expectLater(owner.writeClipboard('late'), throwsStateError);
      expect(() => owner.showFeedback('late'), throwsStateError);
      expect(calls, isEmpty);
      expect(messages, isEmpty);
    });
  }

  test(
    'retirement during OS acknowledgement cannot report copied success',
    () async {
      final submitted = Completer<void>();
      final acknowledgement = Completer<void>();
      messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        calls.add(call);
        submitted.complete();
        await acknowledgement.future;
        return null;
      });
      final owner = bridge();
      final result = expectLater(
        owner.writeClipboard('admitted'),
        throwsStateError,
      );
      await submitted.future;
      owner.invalidate();
      acknowledgement.complete();
      await result;
      expect(calls, hasLength(1));
      expect(messages, isEmpty);
    },
  );
}
