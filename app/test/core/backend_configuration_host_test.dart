import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:adele_desktop/core/backend_configuration_host.dart';
import 'package:adele_desktop/core/prepared_records.dart';
import 'package:adele_plugin_backend_support/adele_backend_configuration.dart';
import 'package:adele_settings/adele_settings.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plugin_runtime/plugin_runtime.dart';

const _plugin = 'test.configuration';
const _private =
    '/private/config/cred1_01234567890123456789012345678901-secret';

void main() {
  late Directory temporary;
  late PreparedPluginCatalog catalog;
  late PreparedPluginInstallation installation;
  late PluginBackendHost transport;
  late PluginBackendConnection connection;
  late BackendConfigurationHost host;
  late Future<StartupRecordsView> Function() read;
  var reads = 0;

  StartupRecordsView capture({bool complete = true}) =>
      StartupRecordsView.fromProjection(
        catalog,
        installation,
        records: [
          {
            'collection': 'accounts',
            'type': '$_plugin.account',
            'id': 'work',
            'values': {'name': 'Work'},
          },
        ],
        diagnostics: [
          if (!complete)
            RecordDiagnosticView(
              collection: RecordCollectionId('accounts'),
              fileName: _private,
              recordId: ConfigurationRecordId('broken'),
              message: 'Native failure: $_private',
            ),
        ],
      );

  Future<Map<String, Object?>> request({
    Object? payload = const <String, Object?>{},
    String method = 'currentRecords',
  }) => host.dispatch({
    'kind': 'request',
    'requestId': 1,
    'method': method,
    'payload': payload,
  });

  setUp(() async {
    reads = 0;
    temporary = await Directory.systemTemp.createTemp('configuration-host-');
    for (final plugin in [_plugin, 'test.foreign', 'test.no-access']) {
      final installed = await Directory('${temporary.path}/$plugin').create();
      await File('${installed.path}/backend.aot').writeAsString('scripted');
      await File('${installed.path}/records.json').writeAsString(
        jsonEncode({
          'schemaVersion': 1,
          'recordTypes': [
            {
              'id': '$plugin.account',
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
            },
          ],
        }),
      );
      await File(
        '${installed.path}/adele_plugin.installation.json',
      ).writeAsString(
        jsonEncode({
          'manifestVersion': 1,
          'metadata': {'id': plugin, 'version': '1', 'displayName': plugin},
          'recordsSchema': 'records.json',
          'components': {
            'backend': {
              'artifact': 'backend.aot',
              if (plugin != 'test.no-access')
                'consumesRecordTypes': ['$plugin.account'],
            },
          },
        }),
      );
    }
    catalog = await PreparedPluginCatalog.discover(temporary.path);
    expect(catalog.issues, isEmpty);
    installation = catalog.installations.singleWhere(
      (entry) => entry.metadata.id.value == _plugin,
    );
    transport = await PluginBackendHost.start(
      dartaotruntimeExecutable:
          '${Platform.environment['FLUTTER_ROOT']!}/bin/cache/dart-sdk/bin/dart',
      hostArtifactPath: File(
        'test/core/fixtures/backend_capability_scripted_host.dart',
      ).absolute.path,
    );
    read = () async => capture();
    connection = await transport.startPlugin(
      pluginId: _plugin,
      artifactUri: installation.backendArtifactUri!,
      arguments: [
        jsonEncode({'capabilityExposures': <Object>[]}),
      ],
      createInfrastructureServices: (connection) {
        host = BackendConfigurationHost(
          connection: connection,
          catalog: catalog,
          installation: installation,
          loadRecords: (actualCatalog, actualInstallation) {
            expect(identical(actualCatalog, catalog), isTrue);
            expect(identical(actualInstallation, installation), isTrue);
            reads++;
            return read();
          },
        );
        return {backendConfigurationServiceId: host};
      },
    );
  });

  tearDown(() async {
    await host.close();
    await transport.close();
    await temporary.delete(recursive: true);
  });

  test(
    'every request observes exact host scope and strips diagnostics',
    () async {
      final first = await request();
      expect(first['payload'], {
        'records': capture().records,
        'isComplete': true,
      });
      read = () async => capture(complete: false);
      final partial = await request();
      expect(partial['payload'], {
        'records': capture().records,
        'isComplete': false,
      });
      expect(jsonEncode(partial), isNot(contains(_private)));
      expect((first['payload'] as Map)['isComplete'], isTrue);
      expect(reads, 2);
      expect(connection.capabilityExposures, isEmpty);
    },
  );

  test(
    'selectors, mutation methods and malformed payloads never read',
    () async {
      for (final payload in <Object?>[
        null,
        [],
        _private,
        for (final selector in [
          'owner',
          'pluginId',
          'collection',
          'recordType',
          'recordId',
          'slot',
          'reference',
          'path',
          'generation',
          'configurationContext',
        ])
          {selector: _private},
      ]) {
        expect((await request(payload: payload))['payload'], {
          'failure': 'notAuthorized',
        });
      }
      for (final method in ['updateRecord', 'readCredential', 'subscribe']) {
        expect((await request(method: method))['payload'], {
          'failure': 'notAuthorized',
        });
      }
      final malformed = await host.dispatch({
        'kind': 'request',
        'requestId': _private,
        'method': 'currentRecords',
        'payload': <String, Object?>{},
      });
      expect(malformed['requestId'], isNull);
      expect(jsonEncode(malformed), isNot(contains(_private)));
      expect(reads, 0);
    },
  );

  test(
    'unavailable and wrong-snapshot reads never become empty success',
    () async {
      read = () async => throw FileSystemException(_private, _private);
      expect((await request())['payload'], {
        'failure': 'configurationUnavailable',
      });
      final foreign = catalog.installations.singleWhere(
        (entry) => entry.metadata.id.value == 'test.foreign',
      );
      read = () async => StartupRecordsView.fromProjection(
        catalog,
        foreign,
        records: const [],
      );
      expect((await request())['payload'], {
        'failure': 'configurationUnavailable',
      });
    },
  );

  test(
    'foreign connection, rediscovered identity and absent opt-in denied',
    () async {
      final rediscovered = await PreparedPluginCatalog.discover(temporary.path);
      for (final target in [
        ...catalog.installations.where(
          (entry) => !identical(entry, installation),
        ),
        rediscovered.installations.singleWhere(
          (entry) => entry.metadata.id.value == _plugin,
        ),
      ]) {
        expect(
          () => BackendConfigurationHost(
            connection: connection,
            catalog: catalog,
            installation: target,
            loadRecords: (_, _) => read(),
          ),
          throwsA(isA<AdeleConfigurationFailure>()),
        );
      }
      final noAccess = catalog.installations.singleWhere(
        (entry) => entry.metadata.id.value == 'test.no-access',
      );
      final otherConnection = await transport.startPlugin(
        pluginId: noAccess.metadata.id.value,
        artifactUri: noAccess.backendArtifactUri!,
        arguments: [
          jsonEncode({'capabilityExposures': <Object>[]}),
        ],
      );
      expect(
        () => BackendConfigurationHost(
          connection: otherConnection,
          catalog: catalog,
          installation: noAccess,
          loadRecords: (_, _) => read(),
        ),
        throwsA(isA<AdeleConfigurationFailure>()),
      );
      expect(reads, 0);
    },
  );

  for (final retireConnection in [true, false]) {
    test(
      'retirement=$retireConnection fences admission and late results',
      () async {
        final entered = Completer<void>();
        final release = Completer<void>();
        read = () async {
          entered.complete();
          await release.future;
          return capture();
        };
        final pending = request();
        await entered.future;
        if (retireConnection) {
          connection.revokeInfrastructureContext();
        } else {
          await host.close();
        }
        expect((await request())['payload'], {
          'failure': 'generationUnavailable',
        });
        expect(reads, 1);
        release.complete();
        expect((await pending)['payload'], {
          'failure': 'generationUnavailable',
        });
      },
    );
  }
}
