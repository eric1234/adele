import 'package:adele_ui/owning_backend_bridge.dart';
import 'package:adele_ui/session_execution_bridge.dart';
import 'package:adele_ui/session_presentation_lifecycle_bridge.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('native imports grant neither backend nor Session execution access', () {
    expect(
      () => const OwningBackendRequestChannel('example').request('read', {}),
      throwsUnsupportedError,
    );
    expect(currentSessionId, throwsUnsupportedError);
    expect(readSessionExecution, throwsUnsupportedError);
    expect(startSessionRun, throwsUnsupportedError);
    expect(() => openSessionRunActivity('invented'), throwsUnsupportedError);
    expect(() => readSessionRunActivity('invented'), throwsUnsupportedError);
    expect(() => inspectSessionActivity('invented'), throwsUnsupportedError);
    expect(() => buildSessionActivity('invented'), throwsUnsupportedError);
    expect(buildSessionExecutionStatus, throwsUnsupportedError);
  });

  test('native imports grant no presentation lifecycle access', () {
    Future<bool> prepareToDeactivate() async => true;
    expect(
      () => registerSessionPrepareToDeactivate(prepareToDeactivate),
      throwsUnsupportedError,
    );
    expect(
      () => unregisterSessionPrepareToDeactivate(prepareToDeactivate),
      throwsUnsupportedError,
    );
  });
}
