import 'package:plugin_backend_host/plugin_backend_host.dart';
import 'package:test/test.dart';

void main() {
  test(
    'rejects missing or malformed settings before spawning an isolate',
    () async {
      final sent = <Map<String, Object?>>[];
      final host = AdeleBackendHost(
        send: (message) {
          sent.add(message);
          return true;
        },
        diagnostic: (_) {},
      );
      addTearDown(() => host.shutdown(notify: false));
      final start = <String, Object?>{
        'protocolVersion': backendHostProtocolVersion,
        'kind': 'startPlugin',
        'requestId': 1,
        'pluginId': 'invalid-settings',
        'generation': 'generation',
        'hostInfrastructureContext': 'infrastructure',
        'defaultConfigurationContext': 'default',
        'artifactUri': Uri.file('/nonexistent-settings-fixture.aot').toString(),
        'arguments': <String>[],
        'records': <Object?>[],
      };
      for (final fields in <Map<String, Object?>>[
        {},
        {'settings': null},
        {'settings': []},
        {'settings': false},
        {'settings': 'not a map'},
        {
          'settings': {1: true},
        },
        {
          'settings': {'count': null},
        },
        {
          'settings': {'count': 1.0},
        },
        {
          'settings': {'count': <Object?>[]},
        },
        {
          'settings': {'count': <String, Object>{}},
        },
      ]) {
        sent.clear();
        expect(await host.handle({...start, ...fields}), isTrue);
        expect(sent, hasLength(1));
        expect(sent.single['kind'], 'error');
        final error = sent.single['error'] as Map;
        expect(error['code'], 'host_command_failed');
        expect(error['message'], contains('Backend setting'));
      }
    },
  );
}
