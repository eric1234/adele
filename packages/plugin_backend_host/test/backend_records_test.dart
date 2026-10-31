import 'package:adele_plugin_backend_support/adele_backend_records.dart';
import 'package:plugin_backend_host/plugin_backend_host.dart';
import 'package:test/test.dart';

void main() {
  test(
    'malformed raw record frames fail before isolate spawn without data leaks',
    () async {
      final sent = <Map<String, Object?>>[];
      final diagnostics = <String>[];
      final host = AdeleBackendHost(
        send: (message) {
          sent.add(message);
          return true;
        },
        diagnostic: diagnostics.add,
      );
      addTearDown(() => host.shutdown(notify: false));
      final start = <String, Object?>{
        'protocolVersion': backendHostProtocolVersion,
        'kind': 'startPlugin',
        'requestId': 1,
        'pluginId': 'invalid-records',
        'generation': 'generation',
        'hostInfrastructureContext': 'infrastructure',
        'defaultConfigurationContext': 'default',
        'artifactUri': Uri.file('/nonexistent-records-fixture.aot').toString(),
        'arguments': <String>[],
        'settings': <String, Object>{},
      };
      const marker = 'private-input-do-not-echo';
      const record = <String, Object?>{
        'collection': 'providers',
        'type': 'dev.adele.fixture.provider',
        'id': 'work',
        'values': {'label': marker},
      };
      for (final fields in <Map<String, Object?>>[
        {},
        for (final value in <Object?>[null, false, {}, marker])
          {'records': value},
        for (final value in <Object?>[null, false, [], marker])
          {
            'records': [value],
          },
        for (final field in record.keys)
          {
            'records': [
              {...record}..remove(field),
            ],
          },
        for (final field in [
          'credentials',
          'reference',
          'document',
          'root',
          'handle',
          'authorization',
        ])
          {
            'records': [
              {...record, field: marker},
            ],
          },
        {
          'records': [
            {...record, 'id': 'bad/$marker'},
          ],
        },
        {
          'records': [
            {...record, 'collection': 'con'},
          ],
        },
        {
          'records': [
            {...record, 'type': marker},
          ],
        },
        for (final value in <Object?>[null, false, []])
          {
            'records': [
              {...record, 'values': value},
            ],
          },
        for (final value in <Object?>[
          null,
          1.0,
          [],
          {'nested': marker},
        ])
          {
            'records': [
              {
                ...record,
                'values': {'label': value},
              },
            ],
          },
        {
          'records': [
            {
              ...record,
              'values': {'invalid/$marker': marker},
            },
          ],
        },
        {
          'records': [
            record,
            {...record, 'type': 'dev.adele.other.provider'},
          ],
        },
        {
          'records': [
            for (var i = 0; i <= AdeleBackendRecords.maxRecords; i++)
              {...record, 'id': 'record-$i'},
          ],
        },
        {
          'records': [
            {
              ...record,
              'values': {
                for (var i = 0; i <= AdeleBackendRecords.maxFields; i++)
                  'field-$i': marker,
              },
            },
          ],
        },
        {
          'records': [
            {
              ...record,
              'values': {
                'label': 'x' * (AdeleBackendRecords.maxStringLength + 1),
              },
            },
          ],
        },
        {
          'records': [
            {
              ...record,
              'values': {
                for (var i = 0; i < 17; i++)
                  'field-$i': 'x' * AdeleBackendRecords.maxStringLength,
              },
            },
          ],
        },
      ]) {
        sent.clear();
        diagnostics.clear();
        final raw = encodeBackendHostFrame({...start, ...fields});
        final decoded = BackendHostFrameDecoder().add(raw).single;
        expect(await host.handle(decoded), isTrue);
        expect(sent, hasLength(1));
        expect(sent.single['kind'], 'error');
        final error = sent.single['error'] as Map;
        expect(error['code'], 'host_command_failed');
        expect(error['message'], startsWith('FormatException: Backend record'));
        expect((error['message'] as String).length, lessThan(128));
        expect(error['message'], isNot(contains(marker)));
        expect(diagnostics.join(), isNot(contains(marker)));
      }
      // Valid explicit emptiness reaches spawn, unlike every rejected frame above.
      sent.clear();
      await host.handle({...start, 'records': <Object?>[]});
      expect(
        (sent.single['error'] as Map)['message'],
        contains('IsolateSpawnException'),
      );
    },
  );
}
