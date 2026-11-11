import 'package:adele_ui/command_bridge.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('native imports grant neither clipboard nor feedback authority', () {
    expect(() => writeCommandClipboard('private'), throwsUnsupportedError);
    expect(() => showCommandFeedback('private'), throwsUnsupportedError);
  });
}
