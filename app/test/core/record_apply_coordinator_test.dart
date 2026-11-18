import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:adele_capabilities/adele_capabilities.dart';
import 'package:adele_desktop/core/application_plugin_bootstrap.dart';
import 'package:adele_desktop/core/prepared_records.dart';
import 'package:adele_desktop/core/prepared_settings.dart';
import 'package:adele_desktop/core/record_apply_coordinator.dart';
import 'package:adele_plugin_api/adele_plugin_api.dart';
import 'package:adele_settings/adele_settings.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plugin_runtime/plugin_runtime.dart';

const _owner = 'test.records';
const _peer = '$_owner.child';
const _unknown = 'publication_outcome_unknown';
const _private = '/private/example/account-token';

RecordApplyKey _key({String owner = _owner, String id = 'work'}) => (
  collection: RecordCollectionId('jobs'),
  type: RecordTypeId('$owner.record'),
  id: ConfigurationRecordId(id),
);

Map<String, Object> _result(
  String status,
  String code, {
  bool pending = false,
}) => {'status': status, 'code': code, 'cleanupPending': pending};

void main() {
  final key = _key();
  final peerKey = _key(owner: _peer);

  test('routes only the exact declared type to its installation', () async {
    final f = await _Fixture.start();
    final apply = f.apply;
    for (final unsupported in <RecordApplyKey>[
      (collection: RecordCollectionId('other'), type: key.type, id: key.id),
      (
        collection: key.collection,
        type: RecordTypeId('$_owner.passive'),
        id: key.id,
      ),
    ]) {
      expect(apply.supports(unsupported), isFalse);
      apply.saved(unsupported);
      apply.retry(unsupported);
      expect(apply.outcome(unsupported), isNull);
    }
    expect(await f.count(), 0);

    // Even a matching collection and record ID cannot select another type's owner.
    for (final (index, target, owner) in [
      (0, key, _owner),
      (1, peerKey, _peer),
    ]) {
      expect(apply.supports(target), isTrue);
      expect(apply.outcome(target), isNull);
      apply.saved(target);
      final request = await f.call(index);
      expect(request['pluginId'], owner);
      expect(request['configurationContext'], 'default');
      expect(request['serviceId'], '$owner.apply');
      expect(request['method'], _method(owner));
      expect(request['payload'], {'recordId': target.id.value});
      expect(request.containsKey('hostInvocationContext'), isFalse);
      expect(apply.outcome(target)!.status, RecordApplyStatus.applying);
      await f.reply(index, _result('applied', 'replaced', pending: true));
      final outcome = await f.status(target, RecordApplyStatus.applied);
      expect(outcome.code, 'replaced');
      expect(outcome.cleanupPending, isTrue);
      apply.retry(target); // Pending cleanup is not a reason to publish again.
    }
    expect(await f.count(), 2);
  });

  test(
    'a declared but unavailable owner never falls back to a sibling',
    () async {
      final f = await _Fixture.start(failOwner: true);
      expect(f.apply.supports(key), isTrue);
      f.apply.saved(key);
      await f.status(key, RecordApplyStatus.unavailable);
      f.apply.retry(key);
      await f.status(key, RecordApplyStatus.unavailable);
      expect(await f.count(), 0);
    },
  );

  test(
    'malformed results and remote exceptions expose no backend diagnostic',
    () async {
      final f = await _Fixture.start();
      final good = _result('applied', 'added');
      final malformed = <Object?>[
        _private,
        {...good, 'status': _private},
        {...good, 'code': _private},
        {...good, 'code': 'a' * 65},
        {...good, 'cleanupPending': 'true'},
        {...good, 'detail': _private},
        {'status': 'applied', 'code': 'added'},
      ];
      for (final (i, response) in malformed.indexed) {
        f.apply.saved(key);
        await f.call(i);
        await f.reply(i, response);
        final result = await f.status(key, RecordApplyStatus.failed);
        expect(result.code, 'invalid_result');
        expect(result.cleanupPending, isFalse);
      }

      f.apply.retry(key);
      final i = malformed.length;
      await f.call(i);
      await f.reply(
        i,
        null,
        error: {
          'code': 'private_account_token',
          'message': _private,
          'details': {'stack': _private},
        },
      );
      final rejected = await f.status(key, RecordApplyStatus.failed);
      expect(rejected.code, 'apply_failed');
      expect(rejected.cleanupPending, isFalse);
      expect(await f.count(), i + 1);
    },
  );

  test(
    'new saves coalesce behind the held attempt without publishing stale results',
    () async {
      final f = await _Fixture.start();
      f.apply.saved(key);
      await f.call(0);
      final observed = <RecordApplyStatus>[];
      f.apply.addListener(() => observed.add(f.apply.outcome(key)!.status));
      f.apply.saved(key);
      f.apply.saved(key, deleted: true);
      expect(f.apply.recentDeletion(key.collection), key);
      expect(await f.count(), 1);

      await f.reply(0, _result('failed', 'invalid_configuration'));
      final latest = await f.call(1);
      expect(latest['payload'], {'recordId': key.id.value});
      expect(f.apply.outcome(key)!.status, RecordApplyStatus.applying);
      await f.reply(1, _result('noChange', 'already_absent'));
      final result = await f.status(key, RecordApplyStatus.noChange);
      expect(result.code, 'already_absent');
      expect(result.cleanupPending, isFalse);
      expect(f.apply.recentDeletion(key.collection), key);
      expect(observed, isNot(contains(RecordApplyStatus.failed)));
      expect(await f.count(), 2);
    },
  );

  test(
    'reconciliation is not an acknowledgement and needs explicit retry',
    () async {
      final f = await _Fixture.start();
      f.apply.saved(key);
      await f.call(0);
      f.apply.reconciled(key);
      await f.status(key, RecordApplyStatus.notApplied);
      await f.reply(0, _result('applied', 'added'));
      expect(await f.count(), 1);
      expect(f.apply.outcome(key)!.status, RecordApplyStatus.notApplied);
      f.apply.retry(key);
      await f.call(1);
      await f.reply(1, _result('unavailable', 'refresh_capacity'));
      final retryable = await f.status(key, RecordApplyStatus.unavailable);
      expect(retryable.code, 'refresh_capacity');
      expect(await f.count(), 2);
      f.apply.retry(key);
      await f.call(2);
      await f.reply(2, _result('applied', 'replaced'));
      await f.status(key, RecordApplyStatus.applied);
      expect(await f.count(), 3);
    },
  );

  test(
    'unconfirmed persistence suppresses late results without a new call',
    () async {
      final f = await _Fixture.start();
      f.apply.saved(key);
      await f.call(0);
      f.apply.unconfirmed(key);
      await f.reply(0, _result('applied', 'replaced'));
      expect(f.apply.outcome(key), isNull);
      f.apply.retry(key);
      expect(await f.count(), 1);
    },
  );

  test(
    'bounded admission preserves pending records during status eviction',
    () async {
      final f = await _Fixture.start();
      for (var i = 0; i < 16; i++) {
        f.apply.saved(_key(id: 'held-$i'));
      }
      await f.call(15);
      final oldest = _key(id: 'overflow-0');
      f.apply.saved(oldest, deleted: true);
      expect(f.apply.outcome(oldest)!.code, 'apply_capacity');
      for (var i = 1; i <= 128; i++) {
        f.apply.saved(_key(id: 'overflow-$i'));
      }
      expect(f.apply.outcome(oldest), isNull);
      expect(f.apply.recentDeletion(oldest.collection), isNull);
      expect(await f.count(), 16);
      await f.reply(0, _result('applied', 'added'));
      await f.status(_key(id: 'held-0'), RecordApplyStatus.applied);
      final newest = _key(id: 'overflow-128');
      f.apply.retry(newest);
      expect((await f.call(16))['payload'], {'recordId': 'overflow-128'});
      await f.reply(16, _result('applied', 'added'));
      await f.status(newest, RecordApplyStatus.applied);
    },
  );

  test(
    'unknown publication fences even a dirty key and other keys of that generation',
    () async {
      final f = await _Fixture.start();
      f.apply.saved(key);
      await f.call(0);
      final held = _key(id: 'held');
      f.apply.saved(held);
      await f.call(1);
      final recovered = _key(id: 'recovered');
      f.apply.reconciled(recovered);
      f.apply.saved(key);
      await f.reply(0, _result('unavailable', _unknown));
      final unknown = await f.status(key, RecordApplyStatus.restartRequired);
      expect(unknown.code, _unknown);
      expect(
        f.apply.outcome(recovered)!.status,
        RecordApplyStatus.restartRequired,
      );
      await f.reply(1, _result('applied', 'added'));
      await f.status(held, RecordApplyStatus.restartRequired);
      f.apply.retry(key);
      f.apply.saved(key);
      final other = _key(id: 'other');
      f.apply.saved(other);
      await f.status(other, RecordApplyStatus.restartRequired);
      f.apply.retry(other);
      expect(await f.count(), 2);
      expect(f.apply.outcome(key)!.status, RecordApplyStatus.restartRequired);

      f.apply.saved(peerKey);
      expect((await f.call(2))['pluginId'], _peer);
      await f.reply(2, _result('applied', 'added'));
      await f.status(peerKey, RecordApplyStatus.applied);
      expect(await f.count(), 3);
    },
  );

  for (final retire in [true, false]) {
    test(
      '${retire ? 'retirement' : 'shutdown'} discards pending and late apply results',
      () async {
        final f = await _Fixture.start();
        f.apply.saved(key);
        await f.call(0);
        f.apply.saved(key);
        if (retire) {
          await f.backend(_owner).connection!.close();
        } else {
          f.apply.close();
        }
        await f.status(key, RecordApplyStatus.unavailable);
        // The independent peer still has a live connection to the scripted host.
        await f.reply(0, _result('applied', 'replaced', pending: true));
        f.apply.retry(key);
        expect(await f.count(), 1);
        final outcome = f.apply.outcome(key)!;
        expect(outcome.status, RecordApplyStatus.unavailable);
        expect(outcome.cleanupPending, isFalse);
      },
    );
  }
}

String _method(String owner) => owner == _owner ? 'refresh' : 'applyChange';

final class _Fixture {
  _Fixture(this.bootstrap)
    : apply = RecordApplyCoordinator(bootstrap, bootstrap.catalog!);

  final ApplicationPluginBootstrap bootstrap;
  final RecordApplyCoordinator apply;

  static Future<_Fixture> start({bool failOwner = false}) async {
    final temp = await Directory.systemTemp.createTemp('record-apply-');
    addTearDown(() => temp.delete(recursive: true));
    final root = await Directory('${temp.path}/installations').create();
    for (final owner in [_owner, _peer]) {
      final dir = await Directory('${root.path}/$owner').create();
      await File('${dir.path}/backend.aot').writeAsString('unused');
      await File('${dir.path}/records.json').writeAsString(
        jsonEncode({
          'schemaVersion': 1,
          'recordTypes': [
            for (final type in ['record', 'passive'])
              {
                'id': '$owner.$type',
                'collection': 'jobs',
                'collectionLabel': 'Jobs',
                'label': type,
                'fields': <Object?>[],
              },
          ],
        }),
      );
      await File('${dir.path}/adele_plugin.installation.json').writeAsString(
        jsonEncode({
          'manifestVersion': 1,
          'metadata': {'id': owner, 'version': '1', 'displayName': owner},
          'recordsSchema': 'records.json',
          'components': {
            'backend': {
              'artifact': 'backend.aot',
              'consumesRecordTypes': ['$owner.record', '$owner.passive'],
              'appliesRecordTypes': [
                {
                  'recordType': '$owner.record',
                  'serviceId': '$owner.apply',
                  'method': _method(owner),
                },
              ],
            },
          },
        }),
      );
    }
    final script = await File(
      '${temp.path}/host.dart',
    ).writeAsString(_hostScript);
    final bootstrap = ApplicationPluginBootstrap(
      CapabilityRegistry(),
      ExtensionRegistry(),
      loadSettings: (catalog) async =>
          PreparedSettingsSnapshot.resolve(catalog),
      loadRecords: (catalog, installation) async =>
          StartupRecordsView.fromProjection(
            catalog,
            installation,
            records: const [],
          ),
    );
    addTearDown(bootstrap.close);
    await bootstrap.start(
      installationRoot: root.path,
      dartaotruntimeExecutable:
          '${Platform.environment['FLUTTER_ROOT']!}/bin/cache/dart-sdk/bin/${Platform.isWindows ? 'dart.exe' : 'dart'}',
      hostArtifactPath: script.path,
      startupArguments: {
        if (failOwner) _owner: ['fail'],
      },
    );
    expect(bootstrap.state, ApplicationPluginState.ready);
    expect(bootstrap.catalog!.issues, isEmpty);
    final f = _Fixture(bootstrap);
    addTearDown(f.apply.close);
    expect(f.backend(_peer).state, InstalledBackendState.active);
    expect(
      f.backend(_owner).state,
      failOwner ? InstalledBackendState.failed : InstalledBackendState.active,
    );
    return f;
  }

  InstalledBackendActivation backend(String id) => bootstrap.backends
      .singleWhere((b) => b.installation.metadata.id.value == id);

  PluginBackendConnection get _control => backend(_peer).connection!;
  Future<int> count() async {
    // Let any queued coordinator dispatch reach the transport before this barrier.
    await Future<void>.value();
    return (await _control.request('fixture.count', {}))! as int;
  }

  Future<Map<String, Object?>> call(int index) async =>
      (await _control
              .request('fixture.call', {'index': index})
              .timeout(const Duration(seconds: 5)))!
          as Map<String, Object?>;
  Future<void> reply(
    int index,
    Object? payload, {
    Map<String, Object?>? error,
  }) async {
    await _control.request('fixture.reply', {
      'index': index,
      'payload': payload,
      'error': ?error,
    });
  }

  Future<RecordApplyOutcome> status(
    RecordApplyKey key,
    RecordApplyStatus expected,
  ) async {
    final done = Completer<RecordApplyOutcome>();
    void check() {
      final current = apply.outcome(key);
      if (!done.isCompleted &&
          current != null &&
          current.status != RecordApplyStatus.applying) {
        done.complete(current);
      }
    }

    check();
    if (!done.isCompleted) {
      apply.addListener(check);
      try {
        await done.future.timeout(const Duration(seconds: 5));
      } finally {
        apply.removeListener(check);
      }
    }
    final result = await done.future;
    expect(result.status, expected, reason: '${key.id.value}: ${result.code}');
    return result;
  }
}

// Like _exactHostScript in application_plugin_bootstrap_test, only the child is
// synthetic. Every apply is held; fixture commands observe and settle its real
// transport request ID, including after the owning activation has retired.
const _hostScript = r'''
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

void main() {
  final calls = <Map<String, dynamic>>[];
  final waiters = <int, Map<String, dynamic>>{};
  var buffer = <int>[];
  void send(Map<String, dynamic> message) {
    final body = utf8.encode(jsonEncode({'protocolVersion': 1, ...message}));
    final header = ByteData(4)..setUint32(0, body.length);
    stdout.add([...header.buffer.asUint8List(), ...body]);
  }
  void reply(Map request, Object? payload, {Object? error}) => send({
    'kind': 'response', 'requestId': request['requestId'],
    'pluginId': request['pluginId'], 'ok': error == null,
    if (error == null) 'payload': payload else 'error': error,
  });
  send({'kind': 'hostHello'});
  stdin.listen((bytes) {
    buffer.addAll(bytes);
    while (buffer.length >= 4) {
      final length = ByteData.sublistView(Uint8List.fromList(buffer), 0, 4).getUint32(0);
      if (buffer.length < 4 + length) break;
      final m = jsonDecode(utf8.decode(buffer.sublist(4, 4 + length))) as Map<String, dynamic>;
      buffer = buffer.sublist(4 + length);
      final route = {'requestId': m['requestId'], 'pluginId': m['pluginId']};
      switch (m['kind']) {
        case 'startPlugin':
          if ((m['arguments'] as List).contains('fail')) {
            send({'kind': 'pluginFailed', ...route, 'error': {'code': 'failed', 'message': 'private startup failure'}});
          } else {
            send({'kind': 'pluginReady', ...route});
          }
        case 'stopPlugin':
          send({'kind': 'pluginStopped', ...route});
        case 'request':
          final p = m['payload'] as Map;
          switch (m['method']) {
            case 'fixture.count': reply(m, calls.length);
            case 'fixture.call':
              final i = p['index'] as int;
              if (i < calls.length) { reply(m, calls[i]); } else { waiters[i] = m; }
            case 'fixture.reply':
              reply(calls[p['index'] as int], p['payload'], error: p['error']);
              reply(m, null);
            default:
              final waiter = waiters.remove(calls.length);
              calls.add(m);
              if (waiter != null) reply(waiter, m);
          }
        case 'shutdownHost':
          send({'kind': 'hostStopped', ...route});
          exit(0);
      }
    }
  });
}
''';
