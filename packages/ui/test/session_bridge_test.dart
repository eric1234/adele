import 'package:adele_contract/adele_contract.dart';
import 'package:adele_ui/capability_bridge.dart';
import 'package:adele_ui/environment_capability_bridge.dart';
import 'package:adele_ui/owning_backend_bridge.dart';
import 'package:adele_ui/session_execution_bridge.dart';
import 'package:adele_ui/session_presentation_lifecycle_bridge.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Environment Capability channel is handle-only and request-only', () {
    const AdeleRequestChannel channel = EnvironmentCapabilityRequestChannel(
      'opaque-presentation-handle',
    );
    expect(channel, isNot(isA<AdeleStreamChannel>()));
    expect(
      (channel as EnvironmentCapabilityRequestChannel).handle,
      'opaque-presentation-handle',
    );
    expect(() => channel.request('read', {}), throwsUnsupportedError);
  });

  test('native imports grant no contextual Environment Capability access', () {
    final Future<String?> Function(String, int, String, String?) resolve =
        resolveEnvironmentCapabilityProvider;
    expect(
      () => resolve('dev.example.probe', 1, 'probe', null),
      throwsUnsupportedError,
    );
    expect(
      () => resolve('dev.example.probe', 1, 'probe', 'dev.example.provider'),
      throwsUnsupportedError,
    );
    expect(
      () => requestEnvironmentCapability('invented', 'read', {}),
      throwsUnsupportedError,
    );
    expect(
      () => releaseEnvironmentCapabilityProvider('invented'),
      throwsUnsupportedError,
    );
    expect(
      () => settleEnvironmentCapabilityOperation(Future<dynamic>.value(null)),
      throwsUnsupportedError,
    );
  });

  test('native imports grant no cross-plugin Capability access', () {
    expect(
      () => discoverCapabilityProviders('dev.example.probe', 1),
      throwsUnsupportedError,
    );
    expect(
      () => resolveCapabilityProvider('dev.example.probe', 1, 'probe', null),
      throwsUnsupportedError,
    );
    const channel = CapabilityRequestChannel('invented');
    expect(() => channel.request('read', {}), throwsUnsupportedError);
    expect(() => channel.stream('watch', {}), throwsUnsupportedError);
    expect(() => releaseCapabilityProvider('invented'), throwsUnsupportedError);
    expect(
      () => settleCapabilityOperation(Future<dynamic>.value(null)),
      throwsUnsupportedError,
    );
  });

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
