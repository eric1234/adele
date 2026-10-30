import 'package:adele_ui/session_feedback_bridge.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('native import grants no Session feedback or execution authority', () {
    final Map<String, Object?> Function() availability =
        readSessionFeedbackAvailability;
    final Future<Map<String, Object?>> Function(String) accept =
        acceptSessionFeedback;
    final Future<Map<String, Object?>> Function(String) lookup =
        lookupSessionFeedback;
    final Future<Map<String, Object?>> Function(String, String, int) start =
        startSessionFeedbackRun;
    final Future<Map<String, Object?>> Function(String, String) lookupRun =
        lookupSessionFeedbackRun;

    expect(availability, throwsUnsupportedError);
    expect(() => accept('canonical-payload'), throwsUnsupportedError);
    expect(() => lookup('canonical-payload'), throwsUnsupportedError);
    expect(
      () => start('canonical-payload', 'occurrence', 1),
      throwsUnsupportedError,
    );
    expect(
      () => lookupRun('canonical-payload', 'occurrence'),
      throwsUnsupportedError,
    );
  });
}
