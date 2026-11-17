import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:adele_desktop/core/backend_credential_host.dart';
import 'package:adele_desktop/core/prepared_records.dart';
import 'package:adele_plugin_backend_support/adele_backend_credentials.dart';
import 'package:adele_settings/adele_settings.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plugin_runtime/plugin_runtime.dart';

const _secret = 'distinctive-host-credential-secret';
const _nativeDiagnostic = '/private/native/credential-storage-diagnostic';
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
  late StartupRecordsView startup;

  StartupRecordsView capture({
    List<String> ids = const ['work', 'personal'],
    bool complete = true,
  }) => StartupRecordsView.fromProjection(
    catalog,
    installation,
    records: [
      for (final id in ids)
        {
          'collection': 'accounts',
          'type': _type,
          'id': id,
          'values': {'name': id},
        },
    ],
    diagnostics: [
      if (!complete)
        RecordDiagnosticView(
          collection: RecordCollectionId('accounts'),
          fileName: _nativeDiagnostic,
          recordId: ConfigurationRecordId('broken'),
          message: 'Native failure: $_secret $_nativeDiagnostic',
        ),
    ],
  );

  Future<Map<String, Object?>> request(
    Object? payload, {
    String method = 'readCredential',
    BackendCredentialHost? target,
  }) => (target ?? host).dispatch({
    'kind': 'request',
    'requestId': 1,
    'method': method,
    'payload': payload,
  });

  Future<Map<String, Object?>> liveCapture({
    BackendCredentialHost? target,
  }) async {
    final response = await request(
      <String, Object?>{},
      method: 'captureCurrentConfiguration',
      target: target,
    );
    expect(
      response.keys,
      unorderedEquals(['kind', 'requestId', 'ok', 'payload']),
    );
    expect(response['kind'], 'response');
    expect(response['requestId'], 1);
    expect(response['ok'], isTrue);
    final payload = response['payload']! as Map<String, Object?>;
    expect(payload.keys, unorderedEquals(['capture', 'records', 'isComplete']));
    expect(payload['capture'], matches(RegExp(r'^[0-9a-f]{32}-[0-9a-f]{16}$')));
    expect(
      int.parse((payload['capture']! as String).substring(33), radix: 16),
      greaterThan(0),
    );
    expect(jsonEncode(payload), isNot(contains(_secret)));
    expect(jsonEncode(payload), isNot(contains(_nativeDiagnostic)));
    return payload;
  }

  void expectFailure(Map<String, Object?> response, String kind) {
    expect(response['payload'], {'failure': kind});
    expect(jsonEncode(response), isNot(contains(_secret)));
    expect(jsonEncode(response), isNot(contains(_nativeDiagnostic)));
  }

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
    reader = _Reader(capture);
    startup = capture();
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
          records: startup,
          associations: reader,
        );
        return {backendCredentialServiceId: host};
      },
    );
  });

  tearDown(() async {
    for (final gate in [
      reader.release,
      reader.captureGate,
      reader.cleanupGate,
    ]) {
      if (gate != null && !gate.isCompleted) gate.complete();
    }
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

  group('live captures', () {
    test(
      'fresh exact-installation scopes do not replace startup or each other',
      () async {
        expect(reader.captureCalls, isEmpty);
        final first = await liveCapture();
        final firstView = reader.captured.single;
        expect(first['records'], startup.records);
        expect(first['isComplete'], isTrue);
        expect(identical(first['records'], firstView.records), isFalse);
        expect(
          identical((first['records']! as List).first, firstView.records.first),
          isFalse,
        );
        expect(reader.calls, isEmpty);
        expect(reader.captureCalls.single.$1, same(catalog));
        expect(reader.captureCalls.single.$2, same(installation));

        reader.captureResult = capture(ids: ['later']);
        final second = await liveCapture();
        expect(second['records'], reader.captureResult!.records);
        expect(first['records'], startup.records);
        expect(first['capture'], isNot(second['capture']));
        expect(
          (first['capture']! as String).substring(0, 33),
          (second['capture']! as String).substring(0, 33),
        );
        expect((first['capture']! as String).substring(33), '0000000000000001');
        expect(
          (second['capture']! as String).substring(33),
          '0000000000000002',
        );

        for (final (handle, id, view) in [
          (first['capture'], 'work', firstView),
          (second['capture'], 'later', reader.captureResult!),
        ]) {
          expect(
            (await request({
              ..._selection,
              'recordId': id,
              'capture': handle,
            }, method: 'readCapturedCredential'))['payload'],
            {'secret': _secret},
          );
          expect(reader.readSnapshots.last, same(view));
        }
        expectFailure(
          await request({..._selection, 'recordId': 'later'}),
          'notAuthorized',
        );
        expectFailure(
          await request({
            ..._selection,
            'capture': first['capture'],
            'recordId': 'later',
          }, method: 'readCapturedCredential'),
          'notAuthorized',
        );
        expectFailure(
          await request({
            ..._selection,
            'capture': second['capture'],
          }, method: 'readCapturedCredential'),
          'notAuthorized',
        );
        expect((await request(_selection))['payload'], {'secret': _secret});
        expect(reader.readSnapshots.last, same(startup));
        expect(connection.capabilityExposures, isEmpty);
      },
    );

    test(
      'partial and empty captures expose completeness but no diagnostics',
      () async {
        for (final ids in [
          <String>['work'],
          <String>[],
        ]) {
          for (final complete in [true, false]) {
            reader.captureResult = capture(ids: ids, complete: complete);
            final result = await liveCapture();
            expect(result['records'], reader.captureResult!.records);
            expect(result['isComplete'], complete);
          }
        }
        expect(reader.calls, isEmpty);
      },
    );

    test(
      'methods and payloads reject missing, extra and mistyped fields',
      () async {
        final captured = await liveCapture();
        final handle = captured['capture'];
        final readPayload = {..._selection, 'capture': handle};
        for (final (method, valid) in <(String, Map<String, Object?>)>[
          ('captureCurrentConfiguration', {}),
          ('readCapturedCredential', readPayload),
          ('releaseCapture', {'capture': handle}),
        ]) {
          for (final invalid in <Object?>[
            null,
            [],
            _secret,
            for (final field in valid.keys) {...valid}..remove(field),
            for (final field in valid.keys) {...valid, field: null},
            for (final field in valid.keys) {...valid, field: <Object>[]},
            for (final field in [
              'pluginId',
              'reference',
              'storageKey',
              'owner',
              'path',
              'generation',
              'serviceId',
              'configurationContext',
              'providerOptions',
              'records',
            ])
              {...valid, field: _secret},
          ]) {
            expectFailure(
              await request(invalid, method: method),
              'notAuthorized',
            );
          }
        }
        for (final field in _selection.keys) {
          expectFailure(
            await request({
              ...readPayload,
              field: _nativeDiagnostic,
            }, method: 'readCapturedCredential'),
            'notAuthorized',
          );
          expectFailure(
            await request({
              field: _secret,
            }, method: 'captureCurrentConfiguration'),
            'notAuthorized',
          );
        }
        for (final method in [
          'capture',
          'currentRecords',
          'release',
          'readCaptured',
          'readAll',
          'replaceCredential',
          'captureCurrentConfiguration ',
        ]) {
          expectFailure(await request({}, method: method), 'notAuthorized');
        }
        expectFailure(await request(readPayload), 'notAuthorized');
        expect(reader.captureCalls, hasLength(1));
        expect(reader.calls, isEmpty);
        expect(reader.releases, 0);
      },
    );

    test(
      'malformed live envelopes never reflect private fields or request IDs',
      () async {
        for (final method in [
          'captureCurrentConfiguration',
          'readCapturedCredential',
          'releaseCapture',
        ]) {
          final envelope = <String, Object?>{
            'kind': 'request',
            'requestId': 1,
            'method': method,
            'payload': <String, Object?>{},
          };
          for (final invalid in <Map<String, Object?>>[
            for (final field in envelope.keys) {...envelope}..remove(field),
            {...envelope, 'extra': _secret},
            {...envelope, 'kind': 'command'},
            {...envelope, 'requestId': -1},
            {...envelope, 'requestId': 1.0},
            {...envelope, 'requestId': _secret},
            {
              ...envelope,
              'method': [_nativeDiagnostic],
            },
          ]) {
            final response = await host.dispatch(invalid);
            expectFailure(response, 'notAuthorized');
            if (invalid['requestId'] is! int ||
                (invalid['requestId']! as int) < 0) {
              expect(response['requestId'], isNull);
            }
          }
        }
        expect(reader.captureCalls, isEmpty);
        expect(reader.calls, isEmpty);
        expect(reader.releases, 0);
      },
    );

    test(
      'valid records cannot authorize malformed, forged or copied handles',
      () async {
        final captured = await liveCapture();
        final handle = captured['capture']! as String;
        final prefix = handle.substring(0, 32);
        final foreignPrefix =
            '${prefix[0] == '0' ? '1' : '0'}${prefix.substring(1)}';
        final copied = jsonDecode(jsonEncode(captured)) as Map;
        ((copied['records'] as List).first as Map)['id'] = 'forged';
        for (final invalid in <Object?>[
          null,
          true,
          1,
          '',
          _secret,
          [],
          {},
          captured,
          copied,
          copied['records'],
          (copied['records'] as List).first,
          '$prefix-0000000000000000',
          '$prefix-0000000000000002',
          '$prefix-ffffffffffffffff',
          '$foreignPrefix-0000000000000001',
          '${'A' * 32}-0000000000000001',
          '$prefix-000000000000000A',
          '$prefix+0000000000000001',
          '$prefix-000000000000001',
          '$prefix-00000000000000001',
          '$handle\n',
          ' $handle',
          '$handle ',
        ]) {
          expectFailure(
            await request({
              ..._selection,
              'capture': invalid,
            }, method: 'readCapturedCredential'),
            'notAuthorized',
          );
          expectFailure(
            await request({'capture': invalid}, method: 'releaseCapture'),
            'notAuthorized',
          );
        }
        expectFailure(
          await request({
            ..._selection,
            'capture': handle,
            'records': copied['records'],
          }, method: 'readCapturedCredential'),
          'notAuthorized',
        );
        expectFailure(
          await request({
            ..._selection,
            'capture': handle,
            'slot': 'unconsumed',
          }, method: 'readCapturedCredential'),
          'notAuthorized',
        );
        expectFailure(
          await request({
            ..._selection,
            'capture': handle,
            'recordId': 'forged',
          }, method: 'readCapturedCredential'),
          'notAuthorized',
        );
        expect(reader.captured.single.records, startup.records);
        expect(reader.calls, isEmpty);
        expect(reader.releases, 0);
        expect(
          (await request({
            ..._selection,
            'capture': handle,
          }, method: 'readCapturedCredential'))['payload'],
          {'secret': _secret},
        );
      },
    );

    test(
      'issued release is idempotent and revoked handles are never reused',
      () async {
        final first = await liveCapture();
        final firstView = reader.captured.single;
        for (var attempt = 0; attempt < 3; attempt++) {
          expect(
            (await request({
              'capture': first['capture'],
            }, method: 'releaseCapture'))['payload'],
            {'released': true},
          );
          expectFailure(
            await request({
              ..._selection,
              'capture': first['capture'],
            }, method: 'readCapturedCredential'),
            'staleConfiguration',
          );
        }
        expect(reader.releasedSnapshots, [firstView]);
        final second = await liveCapture();
        expect(
          (second['capture']! as String).substring(33),
          '0000000000000002',
        );
        expect(
          (await request({
            'capture': first['capture'],
          }, method: 'releaseCapture'))['payload'],
          {'released': true},
        );
        expect(
          (await request({
            ..._selection,
            'capture': second['capture'],
          }, method: 'readCapturedCredential'))['payload'],
          {'secret': _secret},
        );
        expect((await request(_selection))['payload'], {'secret': _secret});
        expect(reader.releasedSnapshots, [firstView]);
      },
    );

    test('a claimed startup or live snapshot cannot be issued again', () async {
      reader.captureResult = startup;
      expectFailure(
        await request({}, method: 'captureCurrentConfiguration'),
        'notAuthorized',
      );
      expect(reader.releases, 0);
      reader.captureResult = capture();
      final first = await liveCapture();
      final firstView = reader.captureResult!;
      expectFailure(
        await request({}, method: 'captureCurrentConfiguration'),
        'notAuthorized',
      );
      expect(reader.releases, 0);
      expect(
        (await request({
          ..._selection,
          'capture': first['capture'],
        }, method: 'readCapturedCredential'))['payload'],
        {'secret': _secret},
      );
      await request({'capture': first['capture']}, method: 'releaseCapture');
      expectFailure(
        await request({}, method: 'captureCurrentConfiguration'),
        'notAuthorized',
      );
      expect(reader.releasedSnapshots, [firstView]);
      reader.captureResult = null;
      for (var i = 0; i < BackendCredentialHost.maxCaptures; i++) {
        await liveCapture();
      }
    });

    test(
      'different hosts on one connection cannot exchange handles or snapshots',
      () async {
        final other = BackendCredentialHost(
          connection: connection,
          catalog: catalog,
          installation: installation,
          records: capture(),
          associations: reader,
        );
        addTearDown(other.close);
        final first = await liveCapture();
        final firstView = reader.captured.single;
        final second = await liveCapture(target: other);
        expect(
          (first['capture']! as String).substring(0, 32),
          isNot((second['capture']! as String).substring(0, 32)),
        );
        expect(
          (second['capture']! as String).substring(33),
          '0000000000000001',
        );
        for (final (target, handle) in [
          (host, second['capture']),
          (other, first['capture']),
        ]) {
          expectFailure(
            await request(
              {..._selection, 'capture': handle},
              method: 'readCapturedCredential',
              target: target,
            ),
            'notAuthorized',
          );
          expectFailure(
            await request(
              {'capture': handle},
              method: 'releaseCapture',
              target: target,
            ),
            'notAuthorized',
          );
        }
        reader.captureResult = firstView;
        expectFailure(
          await request(
            {},
            method: 'captureCurrentConfiguration',
            target: other,
          ),
          'notAuthorized',
        );
        expect(reader.calls, isEmpty);
        expect(reader.releases, 0);
        expect(
          (await request({
            ..._selection,
            'capture': first['capture'],
          }, method: 'readCapturedCredential'))['payload'],
          {'secret': _secret},
        );
      },
    );

    test(
      'new generations reject old handles even for matching records',
      () async {
        final old = await liveCapture();
        final oldView = reader.captured.single;
        await connection.close();
        await host.close();
        final next = await transport.startPlugin(
          pluginId: _plugin,
          artifactUri: installation.backendArtifactUri!,
          arguments: [
            jsonEncode({'capabilityExposures': <Object>[]}),
          ],
        );
        final fresh = BackendCredentialHost(
          connection: next,
          catalog: catalog,
          installation: installation,
          records: capture(),
          associations: reader,
        );
        addTearDown(fresh.close);
        final current = await liveCapture(target: fresh);
        expect(current['records'], old['records']);
        expect(current['capture'], isNot(old['capture']));
        expect(
          (current['capture']! as String).substring(33),
          '0000000000000001',
        );
        expectFailure(
          await request(
            {..._selection, 'capture': old['capture']},
            method: 'readCapturedCredential',
            target: fresh,
          ),
          'notAuthorized',
        );
        expectFailure(
          await request(
            {'capture': old['capture']},
            method: 'releaseCapture',
            target: fresh,
          ),
          'notAuthorized',
        );
        reader.captureResult = oldView;
        expectFailure(
          await request(
            {},
            method: 'captureCurrentConfiguration',
            target: fresh,
          ),
          'notAuthorized',
        );
        expectFailure(
          await request({
            ..._selection,
            'capture': old['capture'],
          }, method: 'readCapturedCredential'),
          'generationUnavailable',
        );
        expect(
          (await request(
            {..._selection, 'capture': current['capture']},
            method: 'readCapturedCredential',
            target: fresh,
          ))['payload'],
          {'secret': _secret},
        );
      },
    );

    test(
      'capacity is eight live captures, independent of the startup scope',
      () async {
        expect(BackendCredentialHost.maxCaptures, 8);
        final captures = [
          for (var i = 0; i < BackendCredentialHost.maxCaptures; i++)
            await liveCapture(),
        ];
        expectFailure(
          await request({}, method: 'captureCurrentConfiguration'),
          'credentialAccessFailed',
        );
        expect(
          reader.captureCalls,
          hasLength(BackendCredentialHost.maxCaptures),
        );
        expect((await request(_selection))['payload'], {'secret': _secret});
        await request({
          'capture': captures.first['capture'],
        }, method: 'releaseCapture');
        await pumpEventQueue();
        final next = await liveCapture();
        expect((next['capture']! as String).substring(33), '0000000000000009');
        expectFailure(
          await request({}, method: 'captureCurrentConfiguration'),
          'credentialAccessFailed',
        );
      },
    );

    test(
      'concurrent pending captures reserve capacity before completion',
      () async {
        reader.captureGate = Completer<void>();
        reader.captureEntered = Completer<void>();
        final pending = [
          for (var i = 0; i < BackendCredentialHost.maxCaptures; i++)
            request({}, method: 'captureCurrentConfiguration'),
        ];
        await reader.captureEntered!.future;
        expect(
          reader.captureCalls,
          hasLength(BackendCredentialHost.maxCaptures),
        );
        expect(reader.captured, isEmpty);
        expectFailure(
          await request({}, method: 'captureCurrentConfiguration'),
          'credentialAccessFailed',
        );
        expect(
          reader.captureCalls,
          hasLength(BackendCredentialHost.maxCaptures),
        );
        reader.captureGate!.complete();
        final responses = await Future.wait(pending);
        final handles = [
          for (final response in responses)
            (response['payload']! as Map)['capture']! as String,
        ];
        expect(handles.toSet(), hasLength(BackendCredentialHost.maxCaptures));
        expect(
          handles.map((handle) => int.parse(handle.substring(33), radix: 16)),
          orderedEquals(
            List.generate(BackendCredentialHost.maxCaptures, (i) => i + 1),
          ),
        );
        expect(
          handles.map((handle) => handle.substring(0, 32)).toSet(),
          hasLength(1),
        );
        expectFailure(
          await request({}, method: 'captureCurrentConfiguration'),
          'credentialAccessFailed',
        );
      },
    );

    test(
      'failed pending capture frees only its reservation and preserves prior scopes',
      () async {
        final existing = [
          for (var i = 1; i < BackendCredentialHost.maxCaptures; i++)
            await liveCapture(),
        ];
        reader.captureGate = Completer<void>();
        reader.captureEntered = Completer<void>();
        reader.captureFailure = FormatException(
          '$_nativeDiagnostic $_secret',
          _secret,
        );
        final pending = request({}, method: 'captureCurrentConfiguration');
        await reader.captureEntered!.future;
        expectFailure(
          await request({}, method: 'captureCurrentConfiguration'),
          'credentialAccessFailed',
        );
        reader.captureGate!.complete();
        expectFailure(await pending, 'credentialAccessFailed');
        reader.captureFailure = null;
        final fresh = await liveCapture();
        expect((fresh['capture']! as String).substring(33), '0000000000000008');
        for (final scope in existing) {
          expect(
            (await request({
              ..._selection,
              'capture': scope['capture'],
            }, method: 'readCapturedCredential'))['payload'],
            {'secret': _secret},
          );
        }
        expect(reader.releases, 0);
        expectFailure(
          await request({}, method: 'captureCurrentConfiguration'),
          'credentialAccessFailed',
        );
      },
    );

    test(
      'wrong-installation projection cleanup holds capacity until drained',
      () async {
        final existing = [
          for (var i = 1; i < BackendCredentialHost.maxCaptures; i++)
            await liveCapture(),
        ];
        final rediscovered = await PreparedPluginCatalog.discover(
          temporary.path,
        );
        final invalid = StartupRecordsView.fromProjection(
          rediscovered,
          rediscovered.installations.single,
          records: startup.records,
        );
        reader.captureResult = invalid;
        reader.cleanupGate = Completer<void>();
        expectFailure(
          await request({}, method: 'captureCurrentConfiguration'),
          'credentialAccessFailed',
        );
        expect(reader.releasedSnapshots, [invalid]);
        reader.captureResult = null;
        expectFailure(
          await request({}, method: 'captureCurrentConfiguration'),
          'credentialAccessFailed',
        );
        expect(
          (await request({
            ..._selection,
            'capture': existing.first['capture'],
          }, method: 'readCapturedCredential'))['payload'],
          {'secret': _secret},
        );
        reader.cleanupGate!.complete();
        await pumpEventQueue();
        final next = await liveCapture();
        expect((next['capture']! as String).substring(33), '0000000000000008');
      },
    );

    for (final validateAfterRead in [false, true]) {
      test(
        'release fences reads and retains draining capacity (reader validates=$validateAfterRead)',
        () async {
          final captures = [
            for (var i = 0; i < BackendCredentialHost.maxCaptures; i++)
              await liveCapture(),
          ];
          final firstView = reader.captured.first;
          final handle = captures.first['capture'];
          reader.validateAfterRead = validateAfterRead;
          reader.entered = Completer<void>();
          reader.release = Completer<void>();
          reader.cleanupGate = Completer<void>();
          final pending = request({
            ..._selection,
            'capture': handle,
          }, method: 'readCapturedCredential');
          await reader.entered!.future;
          final released = await request({
            'capture': handle,
          }, method: 'releaseCapture').timeout(const Duration(seconds: 2));
          expect(released['payload'], {'released': true});
          expect(reader.release!.isCompleted, isFalse);
          expect(reader.releasedSnapshots, [firstView]);
          expectFailure(
            await request({
              ..._selection,
              'capture': handle,
            }, method: 'readCapturedCredential'),
            'staleConfiguration',
          );
          expect(reader.calls, hasLength(1));
          expectFailure(
            await request({}, method: 'captureCurrentConfiguration'),
            'credentialAccessFailed',
          );
          expect(
            (await request({
              'capture': handle,
            }, method: 'releaseCapture'))['payload'],
            {'released': true},
          );
          expect(reader.releases, 1);
          reader.release!.complete();
          expectFailure(await pending, 'staleConfiguration');
          expectFailure(
            await request({}, method: 'captureCurrentConfiguration'),
            'credentialAccessFailed',
          );
          reader.cleanupGate!.complete();
          await pumpEventQueue();
          await liveCapture();
          expectFailure(
            await request({
              ..._selection,
              'capture': handle,
            }, method: 'readCapturedCredential'),
            'staleConfiguration',
          );
        },
      );
    }

    test(
      'failed release is redacted and conservatively retains capacity',
      () async {
        final captures = [
          for (var i = 0; i < BackendCredentialHost.maxCaptures; i++)
            await liveCapture(),
        ];
        reader.cleanupFailure = FileSystemException(
          '$_secret $_nativeDiagnostic',
          _nativeDiagnostic,
        );
        final handle = captures.first['capture'];
        expect(
          (await request({
            'capture': handle,
          }, method: 'releaseCapture'))['payload'],
          {'released': true},
        );
        await pumpEventQueue();
        expectFailure(
          await request({}, method: 'captureCurrentConfiguration'),
          'credentialAccessFailed',
        );
        expectFailure(
          await request({
            ..._selection,
            'capture': handle,
          }, method: 'readCapturedCredential'),
          'staleConfiguration',
        );
        reader.cleanupFailure = null;
        expect(
          (await request({
            'capture': handle,
          }, method: 'releaseCapture'))['payload'],
          {'released': true},
        );
        expect(reader.releases, 1);
        expectFailure(
          await request({}, method: 'captureCurrentConfiguration'),
          'credentialAccessFailed',
        );
        expect(
          (await request({
            ..._selection,
            'capture': captures.last['capture'],
          }, method: 'readCapturedCredential'))['payload'],
          {'secret': _secret},
        );
        await host.close();
        expect(reader.releases, BackendCredentialHost.maxCaptures + 1);
      },
    );

    test(
      'close joins already released cleanup without releasing it twice',
      () async {
        final captured = await liveCapture();
        final view = reader.captured.single;
        reader.cleanupGate = Completer<void>();
        expect(
          (await request(
            {'capture': captured['capture']},
            method: 'releaseCapture',
          ).timeout(const Duration(seconds: 2)))['payload'],
          {'released': true},
        );
        final closing = host.close();
        var closed = false;
        unawaited(closing.then((_) => closed = true));
        expect(reader.releasedSnapshots, [view, startup]);
        await pumpEventQueue();
        expect(closed, isFalse);
        expectFailure(
          await request({
            'capture': captured['capture'],
          }, method: 'releaseCapture'),
          'generationUnavailable',
        );
        reader.cleanupGate!.complete();
        await closing;
        expect(closed, isTrue);
        expect(reader.releasedSnapshots, [view, startup]);
      },
    );

    test(
      'captured reads preserve fixed failures and redact raw errors',
      () async {
        expect(AdeleCredentialFailureKind.values.map((kind) => kind.name), [
          'notAuthorized',
          'notConfigured',
          'missingLocally',
          'storageUnavailable',
          'invalidCredentialBinding',
          'reconciliationRequired',
          'staleConfiguration',
          'generationUnavailable',
          'credentialAccessFailed',
        ]);
        final captured = await liveCapture();
        final payload = {..._selection, 'capture': captured['capture']};
        for (final kind in AdeleCredentialFailureKind.values) {
          reader.failure = AdeleCredentialFailure(kind);
          expectFailure(
            await request(payload, method: 'readCapturedCredential'),
            kind.name,
          );
        }
        reader.failure = StateError('$_secret $_nativeDiagnostic');
        expectFailure(
          await request(payload, method: 'readCapturedCredential'),
          'credentialAccessFailed',
        );
        reader.failure = null;
        for (final value in ['', '\x00', '\ud800', 'x' * 2561]) {
          reader.value = value;
          expectFailure(
            await request(payload, method: 'readCapturedCredential'),
            'credentialAccessFailed',
          );
        }
      },
    );

    for (final retireConnection in [false, true]) {
      test(
        'retirement=$retireConnection drains pending capture and late cleanup',
        () async {
          reader.captureEntered = Completer<void>();
          reader.captureGate = Completer<void>();
          final pending = request({}, method: 'captureCurrentConfiguration');
          await reader.captureEntered!.future;
          if (retireConnection) connection.revokeInfrastructureContext();
          final closing = host.close();
          expect(host.close(), same(closing));
          var closed = false;
          unawaited(closing.then((_) => closed = true));
          expectFailure(
            await request({}, method: 'captureCurrentConfiguration'),
            'generationUnavailable',
          );
          expectFailure(await request(_selection), 'generationUnavailable');
          expect(reader.captureCalls, hasLength(1));
          expect(reader.releasedSnapshots, [startup]);
          await pumpEventQueue();
          expect(closed, isFalse);
          reader.cleanupGate = Completer<void>();
          reader.captureGate!.complete();
          expectFailure(await pending, 'generationUnavailable');
          expect(reader.releasedSnapshots, [startup, reader.captured.single]);
          await pumpEventQueue();
          expect(closed, isFalse);
          reader.cleanupGate!.complete();
          await closing;
          expect(closed, isTrue);
          expect(reader.releases, 2);
          expect(reader.calls, isEmpty);
        },
      );

      test(
        'retirement=$retireConnection fences and drains pending captured reads',
        () async {
          final captured = await liveCapture();
          reader.entered = Completer<void>();
          reader.release = Completer<void>();
          final pending = request({
            ..._selection,
            'capture': captured['capture'],
          }, method: 'readCapturedCredential');
          await reader.entered!.future;
          if (retireConnection) connection.revokeInfrastructureContext();
          final closing = host.close();
          var closed = false;
          unawaited(closing.then((_) => closed = true));
          expectFailure(
            await request({
              ..._selection,
              'capture': captured['capture'],
            }, method: 'readCapturedCredential'),
            'generationUnavailable',
          );
          expectFailure(
            await request({
              'capture': captured['capture'],
            }, method: 'releaseCapture'),
            'generationUnavailable',
          );
          expectFailure(
            await request({}, method: 'captureCurrentConfiguration'),
            'generationUnavailable',
          );
          expect(reader.calls, hasLength(1));
          expect(reader.captureCalls, hasLength(1));
          expect(
            reader.releasedSnapshots,
            containsAll([startup, reader.captured.single]),
          );
          await pumpEventQueue();
          expect(closed, isFalse);
          reader.release!.complete();
          expectFailure(await pending, 'generationUnavailable');
          await closing;
          expect(closed, isTrue);
          expect(reader.releases, 2);
        },
      );
    }
  });
}

final class _Reader implements StartupCredentialReader {
  _Reader(this.project);

  final StartupRecordsView Function() project;
  final calls = <Map<String, String>>[];
  final captureCalls = <(PreparedPluginCatalog, PreparedPluginInstallation)>[];
  final captured = <StartupRecordsView>[];
  final readSnapshots = <StartupRecordsView>[];
  final releasedSnapshots = <StartupRecordsView>[];
  final _reads = <StartupRecordsView, Set<Future<void>>>{};
  StartupRecordsView? captureResult;
  Object? captureFailure;
  Object? cleanupFailure;
  Object? failure;
  String value = _secret;
  bool validateAfterRead = false;
  Completer<void>? entered;
  Completer<void>? release;
  Completer<void>? captureEntered;
  Completer<void>? captureGate;
  Completer<void>? cleanupGate;
  int releases = 0;

  @override
  Future<StartupRecordsView> captureCurrentConfiguration(
    PreparedPluginCatalog catalog,
    PreparedPluginInstallation installation,
  ) async {
    captureCalls.add((catalog, installation));
    if (captureEntered case final entered? when !entered.isCompleted) {
      entered.complete();
    }
    await captureGate?.future;
    if (captureFailure case final error?) throw error;
    final snapshot = captureResult ?? project();
    captured.add(snapshot);
    return snapshot;
  }

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
    readSnapshots.add(snapshot);
    final settled = Completer<void>();
    final reads = _reads.putIfAbsent(snapshot, () => {});
    reads.add(settled.future);
    try {
      if (entered case final entered? when !entered.isCompleted) {
        entered.complete();
      }
      await release?.future;
      if (failure case final error?) throw error;
      // Normally omit the callback so the host must fence late publication
      // independently. Some tests also exercise a cooperative adapter.
      if (validateAfterRead) validateGeneration();
      return value;
    } finally {
      settled.complete();
      reads.remove(settled.future);
      if (reads.isEmpty) _reads.remove(snapshot);
    }
  }

  @override
  Future<void> releaseStartupRecords(StartupRecordsView snapshot) async {
    releases++;
    releasedSnapshots.add(snapshot);
    await Future.wait(_reads[snapshot]?.toList() ?? <Future<void>>[]);
    await cleanupGate?.future;
    if (cleanupFailure case final error?) throw error;
  }
}
