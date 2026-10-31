import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:adele_desktop/core/backend_credential_host.dart';
import 'package:adele_desktop/core/prepared_records.dart';
import 'package:adele_plugin_backend_support/adele_backend_credentials.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plugin_runtime/plugin_runtime.dart';

const _secret = 'distinctive-host-credential-secret';
const _plugin = 'test.credentials';
const _type = 'test.credentials.account';
const _selection = {
  'collection': 'accounts',
  'recordType': _type,
  'recordId': 'work',
  'slot': 'key',
};

void main() {
  late Directory temporary;
  late PreparedPluginCatalog catalog;
  late PreparedPluginInstallation installation;
  late PluginBackendHost transport;
  late _Reader reader;
  late BackendCredentialHost host;
  late PluginBackendConnection connection;

  StartupRecordsView capture() => StartupRecordsView.fromProjection(
    catalog,
    installation,
    records: [
      for (final id in ['work', 'personal'])
        {
          'collection': 'accounts',
          'type': _type,
          'id': id,
          'values': {'name': id},
        },
    ],
  );

  Future<Map<String, Object?>> request(
    Map<String, Object?> payload, {
    String method = 'readCredential',
  }) => host.dispatch({
    'kind': 'request',
    'requestId': 1,
    'method': method,
    'payload': payload,
  });

  setUp(() async {
    temporary = await Directory.systemTemp.createTemp('credential-host-');
    final installed = await Directory('${temporary.path}/owner').create();
    await File('${installed.path}/backend.aot').writeAsString('scripted');
    await File('${installed.path}/records.json').writeAsString(
      jsonEncode({
        'schemaVersion': 1,
        'recordTypes': [
          {
            'id': _type,
            'collection': 'accounts',
            'collectionLabel': 'Accounts',
            'label': 'Account',
            'fields': [
              {
                'id': 'name',
                'label': 'Name',
                'type': 'string',
                'required': true,
              },
            ],
            'credentialSlots': [
              for (final id in ['key', 'unconsumed'])
                {'id': id, 'label': id, 'kind': 'secret-text'},
            ],
          },
        ],
      }),
    );
    await File(
      '${installed.path}/adele_plugin.installation.json',
    ).writeAsString(
      jsonEncode({
        'manifestVersion': 1,
        'metadata': {'id': _plugin, 'version': '1', 'displayName': 'Fixture'},
        'recordsSchema': 'records.json',
        'components': {
          'backend': {
            'artifact': 'backend.aot',
            'consumesRecordTypes': [_type],
            'consumesCredentialSlots': [
              {
                'recordType': _type,
                'slots': ['key'],
              },
            ],
          },
        },
      }),
    );
    catalog = await PreparedPluginCatalog.discover(temporary.path);
    expect(catalog.issues, isEmpty);
    installation = catalog.installations.single;
    transport = await PluginBackendHost.start(
      dartaotruntimeExecutable:
          '${Platform.environment['FLUTTER_ROOT']!}/bin/cache/dart-sdk/bin/dart',
      hostArtifactPath: File(
        'test/core/fixtures/backend_capability_scripted_host.dart',
      ).absolute.path,
    );
    reader = _Reader();
    connection = await transport.startPlugin(
      pluginId: _plugin,
      artifactUri: installation.backendArtifactUri!,
      arguments: [
        jsonEncode({'capabilityExposures': <Object>[]}),
      ],
      createInfrastructureServices: (connection) {
        host = BackendCredentialHost(
          connection: connection,
          catalog: catalog,
          installation: installation,
          records: capture(),
          associations: reader,
        );
        return {backendCredentialServiceId: host};
      },
    );
  });

  tearDown(() async {
    reader.release?.complete();
    await host.close();
    await transport.close();
    await temporary.delete(recursive: true);
  });

  test('exact captured members and declared slot reach the reader', () async {
    expect(reader.calls, isEmpty);
    for (final id in ['work', 'personal']) {
      final response = await request({..._selection, 'recordId': id});
      expect(response, {
        'kind': 'response',
        'requestId': 1,
        'ok': true,
        'payload': {'secret': _secret},
      });
      expect(reader.calls.last, {..._selection, 'recordId': id});
    }
    expect(reader.calls, hasLength(2));
    expect(connection.capabilityExposures, isEmpty);
  });

  test(
    'undeclared selectors and unexpected fields never reach storage',
    () async {
      for (final payload in <Map<String, Object?>>[
        {},
        {..._selection, 'collection': 'other'},
        {..._selection, 'recordType': 'test.credentials.child.account'},
        {..._selection, 'recordId': 'unknown'},
        {..._selection, 'slot': 'unconsumed'},
        {
          ..._selection,
          'slot': ['key'],
        },
        for (final field in [
          'reference',
          'storageKey',
          'owner',
          'path',
          'generation',
          'serviceId',
          'configurationContext',
          'providerOptions',
        ])
          {..._selection, field: _secret},
      ]) {
        final response = await request(payload);
        expect(response['payload'], {'failure': 'notAuthorized'});
        expect(jsonEncode(response), isNot(contains(_secret)));
      }
      expect((await request(_selection, method: 'readAll'))['payload'], {
        'failure': 'notAuthorized',
      });
      expect(reader.calls, isEmpty);
    },
  );

  test('malformed envelopes cannot reflect an untrusted request ID', () async {
    final response = await host.dispatch({
      'kind': 'request',
      'requestId': _secret,
      'method': 'readCredential',
      'payload': _selection,
    });
    expect(response['requestId'], isNull);
    expect(jsonEncode(response), isNot(contains(_secret)));
    expect(reader.calls, isEmpty);
  });

  test('fixed failures survive and raw exceptions are redacted', () async {
    for (final kind in AdeleCredentialFailureKind.values) {
      reader.failure = AdeleCredentialFailure(kind);
      final response = await request(_selection);
      expect(response['payload'], {'failure': kind.name});
      expect(jsonEncode(response), isNot(contains(_secret)));
    }
    reader.failure = FormatException('native $_secret', _secret);
    expect((await request(_selection))['payload'], {
      'failure': 'credentialAccessFailed',
    });
  });

  test('invalid or oversized reader values never cross transport', () async {
    for (final value in ['', '\x00', '\ud800', 'x' * 2561]) {
      reader.value = value;
      final response = await request(_selection);
      expect(response['payload'], {'failure': 'credentialAccessFailed'});
    }
  });

  test('retirement fences new and in-flight delivery synchronously', () async {
    reader.entered = Completer<void>();
    reader.release = Completer<void>();
    final pending = request(_selection);
    await reader.entered!.future;
    connection.revokeInfrastructureContext();
    expect((await request(_selection))['payload'], {
      'failure': 'generationUnavailable',
    });
    expect(reader.calls, hasLength(1));
    reader.release!.complete();
    reader.release = null;
    final response = await pending;
    expect(response['payload'], {'failure': 'generationUnavailable'});
    expect(jsonEncode(response), isNot(contains(_secret)));
    await host.close();
    expect(reader.releases, 1);
  });

  test('a captured scope cannot be adopted by another generation', () async {
    final captured = capture();
    final first = BackendCredentialHost(
      connection: connection,
      catalog: catalog,
      installation: installation,
      records: captured,
      associations: reader,
    );
    await first.close();
    await connection.close();
    final next = await transport.startPlugin(
      pluginId: _plugin,
      artifactUri: installation.backendArtifactUri!,
      arguments: [
        jsonEncode({'capabilityExposures': <Object>[]}),
      ],
    );
    expect(
      () => BackendCredentialHost(
        connection: next,
        catalog: catalog,
        installation: installation,
        records: captured,
        associations: reader,
      ),
      throwsA(isA<AdeleCredentialFailure>()),
    );
    final fresh = BackendCredentialHost(
      connection: next,
      catalog: catalog,
      installation: installation,
      records: capture(),
      associations: reader,
    );
    final response = await fresh.dispatch({
      'kind': 'request',
      'requestId': 2,
      'method': 'readCredential',
      'payload': _selection,
    });
    expect(response['payload'], {'secret': _secret});
    await fresh.close();
  });

  test('connection identity must match exact installation ownership', () async {
    final other = await transport.startPlugin(
      pluginId: 'test.credentials.child',
      artifactUri: installation.backendArtifactUri!,
      arguments: [
        jsonEncode({'capabilityExposures': <Object>[]}),
      ],
    );
    expect(
      () => BackendCredentialHost(
        connection: other,
        catalog: catalog,
        installation: installation,
        records: capture(),
        associations: reader,
      ),
      throwsA(isA<AdeleCredentialFailure>()),
    );
    expect(reader.calls, isEmpty);
  });
}

final class _Reader implements StartupCredentialReader {
  final calls = <Map<String, String>>[];
  Object? failure;
  String value = _secret;
  Completer<void>? entered;
  Completer<void>? release;
  int releases = 0;

  @override
  Future<String> readStartupCredential(
    StartupRecordsView snapshot, {
    required String collection,
    required String recordType,
    required String recordId,
    required String slot,
    required void Function() validateGeneration,
  }) async {
    validateGeneration();
    calls.add({
      'collection': collection,
      'recordType': recordType,
      'recordId': recordId,
      'slot': slot,
    });
    entered?.complete();
    await release?.future;
    if (failure case final error?) throw error;
    // Intentionally do not validate here: the dispatcher must independently
    // fence late publication even if its trusted adapter neglects the callback.
    return value;
  }

  @override
  Future<void> releaseStartupRecords(StartupRecordsView snapshot) async {
    releases++;
  }
}
