import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:adele_contract/adele_contract.dart';
import 'package:plugin_backend_host/plugin_backend_host.dart';
import 'package:plugin_runtime/plugin_runtime.dart';
import 'package:test/test.dart';

void main() {
  late Directory artifacts;
  late File hostArtifact;
  late File pluginArtifact;
  late File pluginKernel;
  late String dartaotruntime;

  setUpAll(() async {
    final String repository = Directory.current.parent.parent.path;
    artifacts = Directory(
      '$repository/.dart_tool/adele/development-runtime/termination-test',
    )..createSync(recursive: true);
    hostArtifact = File('${artifacts.path}/host.aot');
    pluginArtifact = File('${artifacts.path}/plugin.aot');
    pluginKernel = File('${artifacts.path}/plugin.dill');
    final String dart = Platform.resolvedExecutable;
    dartaotruntime = '${File(dart).parent.path}/dartaotruntime';
    await _compile(
      dart,
      '$repository/packages/plugin_backend_host/bin/adele_backend_host.dart',
      hostArtifact.path,
      repository,
    );
    final ProcessResult kernelResult = await Process.run(dart, <String>[
      'compile',
      'kernel',
      '$repository/packages/plugin_backend_host/test/fixtures/crashing_backend.dart',
      '-o',
      pluginKernel.path,
    ], workingDirectory: repository);
    if (kernelResult.exitCode != 0) {
      throw StateError(kernelResult.stderr.toString());
    }
    await _compile(
      dart,
      '$repository/packages/plugin_backend_host/test/fixtures/crashing_backend.dart',
      pluginArtifact.path,
      repository,
    );
  });

  const Map<String, Object?> exposure = {
    'providerId': 'dev.adele.fixture.provider',
    'capabilityId': 'dev.adele.fixture.capability',
    'capabilityMajorVersion': 1,
    'serviceId': 'fixtureService',
    'displayName': 'Fixture',
    'configurationContext': 'opaque-context',
    'pluginId': 'dev.adele.spoofed',
  };

  const extension = <String, Object?>{
    'extensionPointId': 'dev.adele.fixture.point',
    'extensionId': 'dev.adele.fixture.extension',
    'serviceId': 'fixtureService',
    'configurationContext': 'fixture-context',
    'metadata': <String, Object?>{
      'label': 'Fixture',
      'nested': <Object?>[
        true,
        <String, Object?>{
          'child': <Object?>[null, 7, 2.5, 'text', false],
        },
      ],
    },
  };

  test(
    'nested reverse streams preserve order, credit, allowlists and failures',
    () async {
      final host = await _startHost(dartaotruntime, hostArtifact);
      addTearDown(host.close);
      final plugin = await host.startPlugin(
        pluginId: 'reverse-stream',
        artifactUri: pluginArtifact.uri,
        arguments: ['reverse-streams'],
      );
      final peer = await host.startPlugin(
        pluginId: 'reverse-peer',
        artifactUri: pluginArtifact.uri,
        arguments: ['reverse-streams'],
      );
      final dispatcher = _StreamHostDispatcher((method) async* {
        yield 0;
        yield 1;
        if (method == 'failure') {
          throw const PluginRemoteFailure(
            code: 'declared',
            message: 'Exact failure',
            declaredFailureType: 'fixture.failure',
            details: {'value': 42},
          );
        }
        yield 2;
      });
      final invocation = plugin.openHostInvocation({
        'fixtureService': dispatcher,
      });
      final values = <Object?>[];
      final first = Completer<void>();
      final done = Completer<void>();
      late StreamSubscription<Object?> subscription;
      subscription = plugin.stream('nested', {'context': invocation.id}).listen(
        (value) {
          values.add(value);
          if (values.length == 1) {
            subscription.pause();
            first.complete();
          }
        },
        onDone: done.complete,
      );
      await first.future;
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(values, [0]);
      expect(dispatcher.advances, lessThanOrEqualTo(2));
      final advances = dispatcher.advances;
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(dispatcher.advances, advances);
      subscription.resume();
      await done.future.timeout(const Duration(seconds: 1));
      expect(values, [0, 1, 2]);
      expect(invocation.isClosed, isFalse);
      await expectLater(
        plugin.stream('nested', {
          'context': invocation.id,
          'method': 'failure',
        }),
        emitsInOrder([
          0,
          1,
          emitsError(
            isA<PluginRemoteFailure>()
                .having((e) => e.code, 'code', 'declared')
                .having((e) => e.details, 'details', {'value': 42}),
          ),
          emitsDone,
        ]),
      );
      for (final attempt in [
        (
          connection: peer,
          context: invocation.id,
          service: 'fixtureService',
          code: 'host_invocation_unavailable',
        ),
        (
          connection: plugin,
          context: 'unknown',
          service: 'fixtureService',
          code: 'host_invocation_unavailable',
        ),
        (
          connection: plugin,
          context: invocation.id,
          service: 'denied',
          code: 'service_unavailable',
        ),
      ]) {
        await expectLater(
          attempt.connection.stream('nested', {
            'context': attempt.context,
            'service': attempt.service,
          }),
          emitsError(
            isA<PluginRemoteFailure>().having(
              (e) => e.code,
              'code',
              attempt.code,
            ),
          ),
        );
      }
      expect(dispatcher.opens, 2);
      expect(await peer.request('ping', {}), 'alive');
    },
  );

  for (final action in ['cancel', 'revoke', 'close', 'crash', 'host-close']) {
    test(
      'reverse stream $action settles independently of hanging producer cleanup',
      () async {
        final host = await _startHost(dartaotruntime, hostArtifact);
        addTearDown(host.close);
        final plugin = await host.startPlugin(
          pluginId: 'reverse-stream',
          artifactUri: pluginArtifact.uri,
          arguments: ['reverse-streams'],
        );
        final peer = await host.startPlugin(
          pluginId: 'reverse-peer',
          artifactUri: pluginArtifact.uri,
          arguments: ['reverse-streams'],
        );
        final cancellation = Completer<void>();
        final cleanup = Completer<void>();
        late StreamController<Object?> producer;
        producer = StreamController<Object?>(
          onListen: () => producer.add('first'),
          onCancel: () {
            cancellation.complete();
            return cleanup.future;
          },
        );
        final dispatcher = _StreamHostDispatcher((_) => producer.stream);
        final invocation = plugin.openHostInvocation({
          'fixtureService': dispatcher,
        });
        final first = Completer<void>();
        final settled = Completer<void>();
        final errors = <Object>[];
        final subscription = plugin
            .stream('nested', {'context': invocation.id})
            .listen(
              (_) {
                if (!first.isCompleted) first.complete();
              },
              onError: (Object error) => errors.add(error),
              onDone: settled.complete,
            );
        await first.future;
        if (action == 'cancel') {
          await subscription.cancel().timeout(const Duration(seconds: 1));
        } else if (action == 'revoke') {
          invocation.close();
          expect(invocation.isClosed, isTrue);
          await settled.future.timeout(const Duration(seconds: 1));
          expect(
            errors.single,
            isA<PluginRemoteFailure>().having(
              (e) => e.code,
              'code',
              'host_invocation_unavailable',
            ),
          );
        } else if (action == 'close') {
          await plugin.close().timeout(const Duration(seconds: 3));
        } else if (action == 'crash') {
          await expectLater(
            plugin.request('crash', {}),
            throwsA(isA<PluginRemoteFailure>()),
          );
        } else {
          await host.close().timeout(const Duration(seconds: 3));
        }
        await cancellation.future.timeout(const Duration(seconds: 1));
        expect(dispatcher.cancels, 1);
        expect(cleanup.isCompleted, isFalse);
        if (action != 'host-close') {
          expect(await peer.request('ping', {}), 'alive');
        }
        if (action == 'cancel') {
          expect(invocation.isClosed, isFalse);
          expect(await plugin.request('ping', {}), 'alive');
          invocation.close();
        }
        if (action == 'revoke' || action == 'close') {
          await plugin.close();
          final replacement = await host.startPlugin(
            pluginId: 'reverse-stream',
            artifactUri: pluginArtifact.uri,
            arguments: ['reverse-streams'],
          );
          final fresh = replacement.openHostInvocation({
            'fixtureService': _StreamHostDispatcher(
              (_) => Stream.value('fresh'),
            ),
          });
          await expectLater(
            replacement.stream('nested', {'context': invocation.id}),
            emitsError(isA<PluginRemoteFailure>()),
          );
          expect(
            await replacement.stream('nested', {'context': fresh.id}).single,
            'fresh',
          );
        }
        cleanup.complete();
      },
    );
  }

  test(
    'malformed reverse controls and replay are contained to their plugin',
    () async {
      final host = await _startHost(dartaotruntime, hostArtifact);
      addTearDown(host.close);
      final peer = await host.startPlugin(
        pluginId: 'reverse-peer',
        artifactUri: pluginArtifact.uri,
        arguments: ['reverse-streams'],
      );
      for (final frame in <Map<String, Object?>>[
        {'kind': 'hostStreamCredit', 'requestId': 999, 'credit': 1},
        {'kind': 'hostStreamCancel', 'requestId': 999},
        {'kind': 'hostStreamAck', 'requestId': 999},
        {'kind': 'hostStreamCredit', 'requestId': 0, 'credit': 2},
        {'kind': 'hostStreamUnknown', 'requestId': 0},
        {
          'kind': 'hostStreamOpen',
          'requestId': 0,
          'hostInvocationContext': 'scope',
          'serviceId': 'fixtureService',
          'method': 'watch',
          'payload': {},
        },
        {
          'kind': 'hostStreamOpen',
          'requestId': 1,
          'hostInvocationContext': 'scope',
          'serviceId': 'fixtureService',
          'method': 'watch',
          'payload': {},
          'pluginId': 'reverse-peer',
        },
      ]) {
        final plugin = await host.startPlugin(
          pluginId: 'reverse-bad',
          artifactUri: pluginArtifact.uri,
          arguments: ['reverse-streams'],
        );
        final invocation = plugin.openHostInvocation({
          'fixtureService': _StreamHostDispatcher((_) => Stream.value('value')),
        });
        expect(
          await plugin.stream('nested', {'context': invocation.id}).single,
          'value',
        );
        await expectLater(
          plugin.request('raw', frame),
          throwsA(isA<PluginRemoteFailure>()),
        );
        expect(host.isClosed, isFalse);
        expect(await peer.request('ping', {}), 'alive');
      }
    },
  );

  test(
    'oversize and malformed host stream output fail locally without late output',
    () async {
      final host = await _startHost(dartaotruntime, hostArtifact);
      addTearDown(host.close);
      final plugin = await host.startPlugin(
        pluginId: 'reverse-output',
        artifactUri: pluginArtifact.uri,
        arguments: ['reverse-streams'],
      );
      for (final value in [
        Object(),
        'x' * (maximumBackendHostFrameLength + 1),
      ]) {
        final dispatcher = _StreamHostDispatcher((_) => Stream.value(value));
        final invocation = plugin.openHostInvocation({
          'fixtureService': dispatcher,
        });
        await expectLater(
          plugin.stream('nested', {'context': invocation.id}),
          emitsError(
            isA<PluginRemoteFailure>().having(
              (e) => e.code,
              'code',
              'internal_error',
            ),
          ),
        );
        expect(dispatcher.cancels, 1);
        expect(await plugin.request('ping', {}), 'alive');
        invocation.close();
      }
    },
  );

  test(
    'reverse stream request limits and missing terminal receipt stay plugin-local',
    () async {
      final host = await _startHost(dartaotruntime, hostArtifact);
      addTearDown(host.close);
      final plugin = await host.startPlugin(
        pluginId: 'reverse-limits',
        artifactUri: pluginArtifact.uri,
        arguments: ['reverse-streams'],
      );
      final peer = await host.startPlugin(
        pluginId: 'reverse-peer',
        artifactUri: pluginArtifact.uri,
        arguments: ['reverse-streams'],
      );
      final dispatcher = _StreamHostDispatcher((_) => Stream.value('value'));
      final invocation = plugin.openHostInvocation({
        'fixtureService': dispatcher,
      });
      await expectLater(
        plugin.stream('nested', {'context': invocation.id, 'oversize': true}),
        emitsError(
          isA<PluginRemoteFailure>().having(
            (e) => e.code,
            'code',
            'host_request_encoding_failed',
          ),
        ),
      );
      expect(dispatcher.opens, 0);
      expect(await plugin.request('ping', {}), 'alive');
      await expectLater(
        plugin.stream('nested', {'context': invocation.id, 'compactDag': true}),
        emitsError(isA<PluginRemoteFailure>()),
      );
      expect(invocation.isClosed, isTrue);
      final replacement = await host.startPlugin(
        pluginId: 'reverse-limits',
        artifactUri: pluginArtifact.uri,
        arguments: ['reverse-streams'],
      );
      // This raw opening has no consumer to acknowledge the failure terminal.
      await expectLater(
        replacement
            .request('raw', {
              'kind': 'hostStreamOpen',
              'requestId': 0,
              'hostInvocationContext': 'unknown',
              'serviceId': 'fixtureService',
              'method': 'watch',
              'payload': {},
            })
            .timeout(const Duration(seconds: 4)),
        throwsA(isA<PluginRemoteFailure>()),
      );
      expect(await peer.request('ping', {}), 'alive');
      expect(host.isClosed, isFalse);
    },
  );

  test('extension readiness reaches only its exact connection', () async {
    final host = await _startHost(dartaotruntime, hostArtifact);
    addTearDown(host.close);
    final peer = await host.startPlugin(
      pluginId: 'extension-peer',
      artifactUri: pluginArtifact.uri,
      arguments: ['wait'],
    );
    expect(peer.extensionExposures, isEmpty);
    for (final advertisements in [
      <Object?>[],
      [extension],
      [
        extension,
        {...extension, 'extensionId': 'dev.adele.fixture.second'},
      ],
    ]) {
      for (final mode in ['extensions', 'extensions-serialized']) {
        final connection = await host.startPlugin(
          pluginId: 'extensions',
          artifactUri: pluginArtifact.uri,
          arguments: [mode, jsonEncode(advertisements)],
        );
        expect(
          connection.extensionExposures.map((value) => value.toMap()).toList(),
          advertisements,
        );
        expect(
          () => connection.extensionExposures.clear(),
          throwsUnsupportedError,
        );
        await connection.close();
      }
    }
    for (final invalid in <Object?>[
      null,
      {},
      [
        {...extension, 'pluginId': 'spoofed'},
      ],
      [
        {...extension, 'extra': true},
      ],
      [
        {...extension, 'metadata': <Object?>[]},
      ],
    ]) {
      await expectLater(
        host.startPlugin(
          pluginId: 'extensions',
          artifactUri: pluginArtifact.uri,
          arguments: ['extensions', jsonEncode(invalid)],
        ),
        throwsA(isA<PluginRemoteFailure>()),
      );
      expect(await peer.request('ping', const {}), {'alive': true});
    }
  });

  test(
    'reverse requests preserve envelopes, domain failures and invocation allowlists',
    () async {
      final host = await _startHost(dartaotruntime, hostArtifact);
      addTearDown(host.close);
      final plugin = await host.startPlugin(
        pluginId: 'reverse',
        artifactUri: pluginArtifact.uri,
        arguments: ['wait'],
      );
      final peer = await host.startPlugin(
        pluginId: 'reverse-peer',
        artifactUri: pluginArtifact.uri,
        arguments: ['wait'],
      );
      final dispatcher = _HostDispatcher((request) async {
        expect(request.keys.toSet(), {
          'kind',
          'requestId',
          'method',
          'payload',
        });
        expect(request['kind'], 'request');
        return {
          'kind': 'response',
          'requestId': request['requestId'],
          if (request['method'] == 'fixture.failure') ...{
            'ok': false,
            'error': {
              'code': 'not_found',
              'message': 'Missing file',
              'declaredFailureType': 'fixture.failure',
              'details': {'path': 'missing.txt'},
            },
          } else ...{
            'ok': true,
            'payload': request['payload'],
          },
        };
      });
      final services = <String, AdeleBackendDispatcher>{
        'fixtureService': dispatcher,
      };
      final invocation = plugin.openHostInvocation(services);
      services.clear();
      expect(invocation.id, matches(RegExp(r'^[0-9a-f]{64}$')));
      final other = plugin.openHostInvocation({});
      expect(other.id, isNot(invocation.id));
      final result =
          await plugin.request('reverse', {
                'context': invocation.id,
                'payload': {'value': 17},
              })
              as Map;
      expect(result['kind'], 'hostResponse');
      expect(result['ok'], isTrue);
      expect(result['payload'], {'value': 17});
      expect(result.keys.toSet(), {'kind', 'requestId', 'ok', 'payload'});
      final failure =
          await plugin.request('reverse', {
                'context': invocation.id,
                'method': 'fixture.failure',
              })
              as Map;
      expect(failure['error'], {
        'code': 'not_found',
        'message': 'Missing file',
        'declaredFailureType': 'fixture.failure',
        'details': {'path': 'missing.txt'},
      });
      for (final attempt in [
        (
          connection: plugin,
          context: 'unknown',
          service: 'fixtureService',
          code: 'host_invocation_unavailable',
        ),
        (
          connection: peer,
          context: invocation.id,
          service: 'fixtureService',
          code: 'host_invocation_unavailable',
        ),
        (
          connection: plugin,
          context: invocation.id,
          service: 'unapproved',
          code: 'service_unavailable',
        ),
        (
          connection: plugin,
          context: other.id,
          service: 'fixtureService',
          code: 'service_unavailable',
        ),
      ]) {
        final response =
            await attempt.connection.request('reverse', {
                  'context': attempt.context,
                  'service': attempt.service,
                })
                as Map;
        expect((response['error'] as Map)['code'], attempt.code);
      }
      expect(dispatcher.calls, 2);
      invocation.close();
      invocation.close();
      expect(invocation.isClosed, isTrue);
      final replay =
          await plugin.request('reverse', {'context': invocation.id}) as Map;
      expect((replay['error'] as Map)['code'], 'host_invocation_unavailable');
      await plugin.close();
      expect(other.isClosed, isTrue);
      expect(
        () => plugin.openHostInvocation({}),
        throwsA(isA<PluginConnectionClosed>()),
      );
      final replacement = await host.startPlugin(
        pluginId: 'reverse',
        artifactUri: pluginArtifact.uri,
        arguments: ['wait'],
      );
      final stale =
          await replacement.request('reverse', {'context': invocation.id})
              as Map;
      expect((stale['error'] as Map)['code'], 'host_invocation_unavailable');
      expect(dispatcher.calls, 2);
    },
  );

  test(
    'revocation settles pending reverse calls without awaiting host code',
    () async {
      final host = await _startHost(dartaotruntime, hostArtifact);
      addTearDown(host.close);
      final plugin = await host.startPlugin(
        pluginId: 'pending-reverse',
        artifactUri: pluginArtifact.uri,
        arguments: ['wait'],
      );
      final entered = Completer<void>();
      final release = Completer<void>();
      final dispatcher = _HostDispatcher((request) async {
        entered.complete();
        await release.future;
        return {
          'kind': 'response',
          'requestId': request['requestId'],
          'ok': true,
          'payload': 'late',
        };
      });
      final invocation = plugin.openHostInvocation({
        'fixtureService': dispatcher,
      });
      final pending = plugin.request('reverse', {'context': invocation.id});
      await entered.future;
      invocation.close();
      final response = await pending.timeout(const Duration(seconds: 1)) as Map;
      expect((response['error'] as Map)['code'], 'host_invocation_unavailable');
      expect(invocation.isClosed, isTrue);
      release.complete();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(await plugin.request('unexpected-host-responses', const {}), 0);
      expect(await plugin.request('ping', const {}), {'alive': true});
    },
  );

  for (final termination in ['close', 'crash', 'host-close']) {
    test(
      '$termination revokes pending host invocations without dispatcher cleanup',
      () async {
        final host = await _startHost(dartaotruntime, hostArtifact);
        addTearDown(host.close);
        final plugin = await host.startPlugin(
          pluginId: 'retiring-reverse',
          artifactUri: pluginArtifact.uri,
          arguments: ['wait'],
        );
        final entered = Completer<void>();
        final dispatcher = _HostDispatcher((request) {
          entered.complete();
          return Completer<Map<String, Object?>>().future;
        });
        final invocation = plugin.openHostInvocation({
          'fixtureService': dispatcher,
        });
        final pending = plugin.request('reverse', {'context': invocation.id});
        final settled = pending.then<void>((_) {}, onError: (Object _) {});
        await entered.future;
        if (termination == 'close') {
          final stopping = plugin.close();
          expect(invocation.isClosed, isTrue);
          await stopping.timeout(const Duration(seconds: 3));
        } else if (termination == 'crash') {
          await expectLater(
            plugin.request('crash', const {}),
            throwsA(isA<PluginRemoteFailure>()),
          );
        } else {
          final stopping = host.close();
          expect(invocation.isClosed, isTrue);
          await stopping.timeout(const Duration(seconds: 3));
        }
        await settled.timeout(const Duration(seconds: 1));
        expect(invocation.isClosed, isTrue);
        expect(dispatcher.closes, 0);
      },
    );
  }

  test('malformed reverse framing retires only its plugin', () async {
    final host = await _startHost(dartaotruntime, hostArtifact);
    addTearDown(host.close);
    final peer = await host.startPlugin(
      pluginId: 'malformed-peer',
      artifactUri: pluginArtifact.uri,
      arguments: ['wait'],
    );
    final dispatcher = _HostDispatcher(
      (_) => throw StateError('Must not dispatch'),
    );
    for (final malformed in <Map<String, Object?>>[
      for (final field in [
        'requestId',
        'hostInvocationContext',
        'serviceId',
        'method',
        'payload',
      ])
        {'omit': field},
      {
        'extra': {'pluginId': 'malformed-peer'},
      },
      {
        'extra': {'generation': 'spoofed'},
      },
      {
        'extra': {'unknown': true},
      },
      {
        'extra': {'requestId': 'invalid'},
      },
      {
        'extra': {'payload': <Object?>[]},
      },
      {
        'extra': {'method': ''},
      },
      {
        'extra': {'serviceId': 'bad/service'},
      },
    ]) {
      final plugin = await host.startPlugin(
        pluginId: 'malformed-reverse',
        artifactUri: pluginArtifact.uri,
        arguments: ['wait'],
      );
      final invocation = plugin.openHostInvocation({
        'fixtureService': dispatcher,
      });
      await expectLater(
        plugin
            .request('reverse', {'context': invocation.id, ...malformed})
            .timeout(const Duration(seconds: 3)),
        throwsA(isA<PluginRemoteFailure>()),
      );
      expect(invocation.isClosed, isTrue);
      expect(await peer.request('ping', const {}), {'alive': true});
    }
    expect(dispatcher.calls, 0);
  });

  test(
    'compact DAG metadata and reverse payload fail only their generation',
    () async {
      final host = await _startHost(dartaotruntime, hostArtifact);
      addTearDown(host.close);
      final peer = await host.startPlugin(
        pluginId: 'dag-peer',
        artifactUri: pluginArtifact.uri,
        arguments: ['wait'],
      );
      await expectLater(
        host
            .startPlugin(
              pluginId: 'dag-plugin',
              artifactUri: pluginArtifact.uri,
              arguments: [
                'extensions-dag',
                jsonEncode([extension]),
              ],
            )
            .timeout(const Duration(seconds: 3)),
        throwsA(
          isA<PluginRemoteFailure>().having(
            (error) => error.message,
            'message',
            contains('node budget'),
          ),
        ),
      );
      expect(
        await peer
            .request('ping', const {})
            .timeout(const Duration(seconds: 1)),
        {'alive': true},
      );
      final plugin = await host.startPlugin(
        pluginId: 'dag-plugin',
        artifactUri: pluginArtifact.uri,
        arguments: ['wait'],
      );
      final dispatcher = _HostDispatcher(
        (_) => throw StateError('Must not dispatch'),
      );
      final invocation = plugin.openHostInvocation({
        'fixtureService': dispatcher,
      });
      await expectLater(
        plugin
            .request('reverse', {'context': invocation.id, 'compactDag': true})
            .timeout(const Duration(seconds: 3)),
        throwsA(isA<PluginRemoteFailure>()),
      );
      expect(dispatcher.calls, 0);
      expect(invocation.isClosed, isTrue);
      expect(
        await peer
            .request('ping', const {})
            .timeout(const Duration(seconds: 1)),
        {'alive': true},
      );
      final replacement = await host.startPlugin(
        pluginId: 'dag-plugin',
        artifactUri: pluginArtifact.uri,
        arguments: ['wait'],
      );
      expect(await replacement.request('ping', const {}), {'alive': true});
    },
  );

  test(
    'shared host stamps generations and never replies to replacement isolates',
    () async {
      final events = StreamController<Map<String, Object?>>();
      final host = AdeleBackendHost(
        send: (message) {
          events.add(message);
          return true;
        },
        diagnostic: (_) {},
      );
      final iterator = StreamIterator(events.stream);
      addTearDown(() async {
        await host.shutdown(notify: false);
        await iterator.cancel();
        await events.close();
      });
      Future<Map<String, Object?>> next(String kind) async {
        while (await iterator.moveNext().timeout(const Duration(seconds: 3))) {
          if (iterator.current['kind'] == kind) return iterator.current;
        }
        throw StateError('Missing $kind');
      }

      Future<void> start(String generation) async {
        await host.handle({
          'protocolVersion': backendHostProtocolVersion,
          'kind': 'startPlugin',
          'requestId': 1,
          'pluginId': 'captured',
          'generation': generation,
          'defaultConfigurationContext': 'default',
          'artifactUri': pluginKernel.uri.toString(),
          'arguments': ['wait'],
        });
        await next('pluginReady');
      }

      Future<Map<String, Object?>> reverse() async {
        await host.handle({
          'protocolVersion': backendHostProtocolVersion,
          'kind': 'request',
          'requestId': 2,
          'pluginId': 'captured',
          'configurationContext': 'default',
          'serviceId': 'fixture',
          'method': 'reverse',
          'payload': {'context': 'opaque'},
        });
        return next('hostRequest');
      }

      await start('generation-one');
      final first = await reverse();
      expect(first['pluginId'], 'captured');
      expect(first['generation'], 'generation-one');
      Map<String, Object?> response(Map<String, Object?> request) => {
        'protocolVersion': backendHostProtocolVersion,
        'kind': 'hostResponse',
        'requestId': request['requestId'],
        'pluginId': request['pluginId'],
        'generation': request['generation'],
        'ok': true,
        'payload': 'result',
      };
      await host.handle({...response(first), 'generation': 'wrong-generation'});
      await host.handle({...response(first), 'pluginId': 'wrong-owner'});
      await host.handle(response(first));
      expect(((await next('response'))['payload'] as Map)['payload'], 'result');
      final stale = await reverse();
      await host.handle({
        'protocolVersion': backendHostProtocolVersion,
        'kind': 'stopPlugin',
        'requestId': 3,
        'pluginId': 'captured',
      });
      await next('pluginStopped');
      await start('generation-two');
      final current = await reverse();
      expect(current['generation'], 'generation-two');
      expect(current['requestId'], isNot(stale['requestId']));
      await host.handle(response(stale));
      await host.handle(response(current));
      expect(((await next('response'))['payload'] as Map)['payload'], 'result');
      await host.handle({
        'protocolVersion': backendHostProtocolVersion,
        'kind': 'request',
        'requestId': 4,
        'pluginId': 'captured',
        'configurationContext': 'default',
        'serviceId': 'fixture',
        'method': 'unexpected-host-responses',
        'payload': {},
      });
      expect((await next('response'))['payload'], 0);
    },
  );

  for (final scenario in [
    (name: 'negative ID', accepted: <int>[], rejected: -1),
    (name: 'settled replay', accepted: [0, 4], rejected: 4),
    (name: 'earlier replay', accepted: [0, 4], rejected: 0),
    (name: 'unseen out-of-order ID', accepted: [0, 4], rejected: 2),
  ]) {
    test('reverse ${scenario.name} rejection is generation-local', () async {
      final host = await _startHost(dartaotruntime, hostArtifact);
      addTearDown(host.close);
      final plugin = await host.startPlugin(
        pluginId: 'ordered-reverse',
        artifactUri: pluginArtifact.uri,
        arguments: ['wait'],
      );
      final peer = await host.startPlugin(
        pluginId: 'ordered-peer',
        artifactUri: pluginArtifact.uri,
        arguments: ['wait'],
      );
      final dispatcher = _HostDispatcher(
        (request) async => {
          'kind': 'response',
          'requestId': request['requestId'],
          'ok': true,
          'payload': 'accepted',
        },
      );
      final invocation = plugin.openHostInvocation({
        'fixtureService': dispatcher,
      });
      final peerInvocation = peer.openHostInvocation({
        'fixtureService': dispatcher,
      });
      for (final id in scenario.accepted) {
        final response =
            await plugin.request('reverse', {
                  'context': invocation.id,
                  'hostRequestId': id,
                })
                as Map;
        expect(response['payload'], 'accepted');
      }
      await expectLater(
        plugin
            .request('reverse', {
              'context': invocation.id,
              'hostRequestId': scenario.rejected,
            })
            .timeout(const Duration(seconds: 3)),
        throwsA(isA<PluginRemoteFailure>()),
      );
      expect(dispatcher.calls, scenario.accepted.length);
      expect(plugin.isClosed, isTrue);
      expect(invocation.isClosed, isTrue);
      final peerResponse =
          await peer.request('reverse', {
                'context': peerInvocation.id,
                'hostRequestId': 0,
              })
              as Map;
      expect(peerResponse['payload'], 'accepted');
      expect(peerInvocation.isClosed, isFalse);
      final replacement = await host.startPlugin(
        pluginId: 'ordered-reverse',
        artifactUri: pluginArtifact.uri,
        arguments: ['wait'],
      );
      final replacementInvocation = replacement.openHostInvocation({
        'fixtureService': dispatcher,
      });
      final replacementResponse =
          await replacement.request('reverse', {
                'context': replacementInvocation.id,
                'hostRequestId': 0,
              })
              as Map;
      expect(replacementResponse['payload'], 'accepted');
    });
  }

  test(
    'reverse response demux bypasses another plugin lifecycle wait',
    () async {
      final host = await _startHost(dartaotruntime, hostArtifact);
      addTearDown(host.close);
      final blocked = await host.startPlugin(
        pluginId: 'lifecycle-wait',
        artifactUri: pluginArtifact.uri,
        arguments: ['acknowledge-hang'],
      );
      final caller = await host.startPlugin(
        pluginId: 'lifecycle-caller',
        artifactUri: pluginArtifact.uri,
        arguments: ['wait'],
      );
      final entered = Completer<void>();
      final release = Completer<void>();
      final invocation = caller.openHostInvocation({
        'fixtureService': _HostDispatcher((request) async {
          entered.complete();
          await release.future;
          return {
            'kind': 'response',
            'requestId': request['requestId'],
            'ok': true,
            'payload': 'unblocked',
          };
        }),
      });
      final pending = caller.request('reverse', {'context': invocation.id});
      await entered.future;
      bool stopped = false;
      final stopping = blocked.close().then((_) => stopped = true);
      // The host is waiting for an isolate which acknowledges but does not exit.
      await Future<void>.delayed(const Duration(milliseconds: 100));
      release.complete();
      final response = await pending.timeout(const Duration(seconds: 1)) as Map;
      expect(response['payload'], 'unblocked');
      expect(stopped, isFalse);
      await stopping;
    },
  );

  test(
    'host dispatcher failures remain structured and preserve sibling calls',
    () async {
      final host = await _startHost(dartaotruntime, hostArtifact);
      addTearDown(host.close);
      final plugin = await host.startPlugin(
        pluginId: 'host-failures',
        artifactUri: pluginArtifact.uri,
        arguments: ['wait'],
      );
      final invocation = plugin.openHostInvocation({
        'fixtureService': _HostDispatcher((request) async {
          if (request['method'] == 'throw') {
            throw StateError('private host details');
          }
          if (request['method'] == 'malformed') return {'ok': true};
          return {
            'kind': 'response',
            'requestId': request['requestId'],
            'ok': true,
            'payload': Object(),
          };
        }),
      });
      for (final method in ['throw', 'malformed', 'unencodable']) {
        final result =
            await plugin.request('reverse', {
                  'context': invocation.id,
                  'method': method,
                })
                as Map;
        expect(
          (result['error'] as Map)['code'],
          method == 'unencodable'
              ? 'response_encoding_failed'
              : 'internal_error',
        );
        expect(result.toString(), isNot(contains('private host details')));
      }
      expect(await plugin.request('ping', const {}), {'alive': true});
    },
  );

  test('forwards zero, one and multiple validated advertisements', () async {
    final host = await _startHost(dartaotruntime, hostArtifact);
    addTearDown(host.close);
    for (final advertised in [
      <Object?>[],
      <Object?>[exposure],
      <Object?>[
        exposure,
        {
          ...exposure,
          'providerId': 'dev.adele.fixture.second',
          'configurationContext': 'second',
          'rank': 5,
        },
      ],
    ]) {
      final connection = await host.startPlugin(
        pluginId: 'dev.adele.actual',
        artifactUri: pluginArtifact.uri,
        arguments: ['wait', jsonEncode(advertised)],
      );
      expect(connection.pluginId, 'dev.adele.actual');
      expect(connection.capabilityExposures, hasLength(advertised.length));
      for (final value in connection.capabilityExposures) {
        expect(value.toMap(), isNot(contains('pluginId')));
      }
      if (advertised.isNotEmpty) {
        expect(connection.capabilityExposures.first.rank, 0);
      }
      if (advertised.length == 2) {
        expect(connection.capabilityExposures.last.rank, 5);
      }
      await connection.close();
    }
  });

  test(
    'forwards generic startup argument mode without changing legacy defaults',
    () async {
      final host = await _startHost(dartaotruntime, hostArtifact);
      addTearDown(host.close);
      final legacy = await host.startPlugin(
        pluginId: 'legacy',
        artifactUri: pluginArtifact.uri,
        arguments: ['wait'],
      );
      expect(await legacy.request('startup-mode', const {}), isFalse);
      await legacy.close();
      final prepared = await host.startPlugin(
        pluginId: 'prepared',
        artifactUri: pluginArtifact.uri,
        arguments: ['wait'],
        startupArgumentsOnly: true,
      );
      expect(await prepared.request('startup-mode', const {}), isTrue);
      await prepared.close();
    },
  );

  test('rejects non-boolean startup argument mode before spawning', () async {
    final emitted = <Map<String, Object?>>[];
    final host = AdeleBackendHost(
      send: (message) {
        emitted.add(message);
        return true;
      },
      diagnostic: (_) {},
    );
    addTearDown(() => host.shutdown(notify: false));
    for (final mode in <Object?>[null, 'true', 1]) {
      await host.handle({
        'protocolVersion': backendHostProtocolVersion,
        'kind': 'startPlugin',
        'requestId': 1,
        'pluginId': 'invalid-startup-mode',
        'generation': 'test-generation',
        'defaultConfigurationContext': 'default',
        'artifactUri': pluginKernel.uri.toString(),
        'arguments': ['wait'],
        'startupArgumentsOnly': mode,
      });
      expect(emitted.last['kind'], 'error');
      expect(
        (emitted.last['error']! as Map)['message'],
        contains('must be a boolean'),
      );
    }
  });

  test(
    'invalid advertisement reaps resources before failure and permits replacement',
    () async {
      final host = await _startHost(dartaotruntime, hostArtifact);
      addTearDown(host.close);
      final peer = await host.startPlugin(
        pluginId: 'healthy-peer',
        artifactUri: pluginArtifact.uri,
        arguments: ['wait'],
      );
      for (final scenario in [
        for (final advertised in <Object?>[
          null,
          {},
          [
            {...exposure, 'providerId': 'invalid_provider'},
          ],
          [
            {...exposure, 'capabilityId': 'invalid_capability'},
          ],
          [
            {...exposure, 'capabilityMajorVersion': 0},
          ],
          [
            {...exposure, 'serviceId': 'bad/service'},
          ],
          [
            {...exposure, 'configurationContext': 'bad\ncontext'},
          ],
        ])
          (mode: 'wait', advertised: advertised),
        for (final field in ['providerId', 'capabilityId'])
          (mode: 'oversized-$field', advertised: <Object?>[exposure]),
      ]) {
        final reservation = await ServerSocket.bind(
          InternetAddress.loopbackIPv4,
          0,
        );
        final port = reservation.port;
        await reservation.close();
        await expectLater(
          host
              .startPlugin(
                pluginId: 'invalid-advertisement',
                artifactUri: pluginArtifact.uri,
                arguments: [
                  scenario.mode,
                  jsonEncode(scenario.advertised),
                  '$port',
                ],
              )
              .timeout(const Duration(seconds: 10)),
          throwsA(
            isA<PluginRemoteFailure>().having(
              (error) => error.message.length,
              'bounded validation error',
              lessThan(512),
            ),
          ),
        );
        final reclaimed = await ServerSocket.bind(
          InternetAddress.loopbackIPv4,
          port,
        );
        await reclaimed.close();
        final replacement = await host.startPlugin(
          pluginId: 'invalid-advertisement',
          artifactUri: pluginArtifact.uri,
          arguments: ['wait'],
        );
        expect(await replacement.request('ping', const {}), {'alive': true});
        await replacement.close();
        expect(await peer.request('ping', const {}), {'alive': true});
      }
    },
  );

  test(
    'failed readiness send closes the started generation before reporting error',
    () async {
      final emitted = <Map<String, Object?>>[];
      bool rejectReady = true;
      final host = AdeleBackendHost(
        send: (message) {
          if (message['kind'] == 'pluginReady' && rejectReady) return false;
          emitted.add(message);
          return true;
        },
      );
      addTearDown(() => host.shutdown(notify: false));
      final reservation = await ServerSocket.bind(
        InternetAddress.loopbackIPv4,
        0,
      );
      final port = reservation.port;
      await reservation.close();
      final start = <String, Object?>{
        'protocolVersion': backendHostProtocolVersion,
        'kind': 'startPlugin',
        'requestId': 1,
        'pluginId': 'send-failure',
        'generation': 'test-generation',
        'defaultConfigurationContext': 'default',
        'artifactUri': pluginKernel.uri.toString(),
        'arguments': ['wait', '[]', '$port'],
      };
      await host.handle(start);
      expect(emitted.single['kind'], 'error');
      final reclaimed = await ServerSocket.bind(
        InternetAddress.loopbackIPv4,
        port,
      );
      await reclaimed.close();
      rejectReady = false;
      await host.handle({...start, 'requestId': 2});
      expect(emitted.last['kind'], 'pluginReady');
    },
  );

  test('rejects plugin with incompatible backend handshake', () async {
    final PluginBackendHost host = await PluginBackendHost.start(
      dartaotruntimeExecutable: dartaotruntime,
      hostArtifactPath: hostArtifact.path,
    );
    addTearDown(() async {
      if (!host.isClosed) await host.close(graceful: false);
    });

    await expectLater(
      host.startPlugin(
        pluginId: 'incompatible-backend-plugin',
        artifactUri: pluginArtifact.uri,
        arguments: const <String>['incompatible-handshake'],
      ),
      throwsA(
        isA<PluginRemoteFailure>().having(
          (PluginRemoteFailure failure) => failure.code,
          'code',
          'host_command_failed',
        ),
      ),
    );
    await host.close();
  });

  test(
    'fails pending request and restarts same plugin ID after exit',
    () async {
      final PluginBackendHost host = await PluginBackendHost.start(
        dartaotruntimeExecutable: dartaotruntime,
        hostArtifactPath: hostArtifact.path,
      );
      addTearDown(() async {
        if (!host.isClosed) await host.close(graceful: false);
      });
      final PluginBackendConnection first = await host.startPlugin(
        pluginId: 'crashing',
        artifactUri: pluginArtifact.uri,
        arguments: const <String>['wait'],
      );
      await expectLater(
        first.request('crash', const <String, Object?>{}),
        throwsA(
          isA<PluginRemoteFailure>().having(
            (PluginRemoteFailure value) => value.code,
            'code',
            'plugin_exited',
          ),
        ),
      );
      expect(first.isClosed, isTrue);
      await expectLater(
        first.request('after-exit', const <String, Object?>{}),
        throwsA(isA<PluginConnectionClosed>()),
      );
      final PluginBackendConnection restarted = await host.startPlugin(
        pluginId: 'crashing',
        artifactUri: pluginArtifact.uri,
        arguments: const <String>['wait'],
      );
      expect(
        await restarted.request('ping', const <String, Object?>{}),
        <String, Object?>{'alive': true},
      );
      await restarted.close();
      await host.close();
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test(
    'removes plugin that exits without pending requests',
    () async {
      final PluginBackendHost host = await PluginBackendHost.start(
        dartaotruntimeExecutable: dartaotruntime,
        hostArtifactPath: hostArtifact.path,
      );
      addTearDown(() async {
        if (!host.isClosed) await host.close(graceful: false);
      });
      final PluginBackendConnection first = await host.startPlugin(
        pluginId: 'crashing',
        artifactUri: pluginArtifact.uri,
        arguments: const <String>['exit-immediately'],
      );
      for (int attempt = 0; attempt < 50 && !first.isClosed; attempt++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      expect(first.isClosed, isTrue);
      final PluginBackendConnection restarted = await host.startPlugin(
        pluginId: 'crashing',
        artifactUri: pluginArtifact.uri,
        arguments: const <String>['wait'],
      );
      await restarted.close();
      await host.close();
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test(
    'fails pending request when plugin is stopped and keeps host usable',
    () async {
      final PluginBackendHost host = await _startHost(
        dartaotruntime,
        hostArtifact,
      );
      addTearDown(() async {
        if (!host.isClosed) await host.close(graceful: false);
      });
      final PluginBackendConnection plugin = await host.startPlugin(
        pluginId: 'stoppable',
        artifactUri: pluginArtifact.uri,
        arguments: const <String>['wait'],
      );
      final Future<Object?> pending = plugin.request(
        'pending',
        const <String, Object?>{},
      );
      final Future<void> expectation = expectLater(
        pending.timeout(const Duration(seconds: 5)),
        throwsA(isA<PluginConnectionClosed>()),
      );
      await plugin.close();
      await expectation;
      final PluginBackendConnection restarted = await host.startPlugin(
        pluginId: 'stoppable',
        artifactUri: pluginArtifact.uri,
        arguments: const <String>['wait'],
      );
      expect(
        await restarted.request('ping', const <String, Object?>{}),
        <String, Object?>{'alive': true},
      );
      await restarted.close();
      await host.close();
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test(
    'kills plugin that acknowledges shutdown without exiting and restarts it',
    () async {
      final PluginBackendHost host = await _startHost(
        dartaotruntime,
        hostArtifact,
      );
      addTearDown(() async {
        if (!host.isClosed) await host.close(graceful: false);
      });
      final PluginBackendConnection hanging = await host.startPlugin(
        pluginId: 'hanging',
        artifactUri: pluginArtifact.uri,
        arguments: const <String>['acknowledge-hang'],
      );
      await hanging.close().timeout(const Duration(seconds: 6));
      final PluginBackendConnection restarted = await host.startPlugin(
        pluginId: 'hanging',
        artifactUri: pluginArtifact.uri,
        arguments: const <String>['wait'],
      );
      expect(
        await restarted.request('ping', const <String, Object?>{}),
        <String, Object?>{'alive': true},
      );
      await restarted.close();
      await host.close();
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test(
    'contains oversized responses and keeps plugin and host usable',
    () async {
      final PluginBackendHost host = await _startHost(
        dartaotruntime,
        hostArtifact,
      );
      addTearDown(() async {
        if (!host.isClosed) await host.close(graceful: false);
      });
      final PluginBackendConnection plugin = await host.startPlugin(
        pluginId: 'large',
        artifactUri: pluginArtifact.uri,
        arguments: const <String>['wait'],
      );
      final Object? below = await plugin.request(
        'large-below',
        const <String, Object?>{},
      );
      expect((below! as String).length, 8 * 1024 * 1024 - 2048);
      await expectLater(
        plugin.request('large-above', const <String, Object?>{}),
        throwsA(
          isA<PluginRemoteFailure>().having(
            (PluginRemoteFailure value) => value.code,
            'code',
            'response_too_large',
          ),
        ),
      );
      expect(
        await plugin.request('ping', const <String, Object?>{}),
        <String, Object?>{'alive': true},
      );
      await plugin.close();
      await host.close();
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test(
    'contains unencodable responses per request and keeps plugins usable',
    () async {
      final PluginBackendHost host = await _startHost(
        dartaotruntime,
        hostArtifact,
      );
      addTearDown(() async {
        if (!host.isClosed) await host.close(graceful: false);
      });
      final PluginBackendConnection broken = await host.startPlugin(
        pluginId: 'broken-response',
        artifactUri: pluginArtifact.uri,
        arguments: const <String>['wait'],
      );
      final PluginBackendConnection healthy = await host.startPlugin(
        pluginId: 'healthy',
        artifactUri: pluginArtifact.uri,
        arguments: const <String>['wait'],
      );
      for (final String method in <String>['unencodable', 'non-finite']) {
        await expectLater(
          broken.request(method, const <String, Object?>{}),
          throwsA(
            isA<PluginRemoteFailure>().having(
              (PluginRemoteFailure value) => value.code,
              'code',
              'response_encoding_failed',
            ),
          ),
        );
      }
      expect(
        await broken.request('ping', const <String, Object?>{}),
        <String, Object?>{'alive': true},
      );
      expect(
        await healthy.request('ping', const <String, Object?>{}),
        <String, Object?>{'alive': true},
      );
      await broken.close();
      await healthy.close();
      await host.close();
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test(
    'multiplexes streams and unary requests independently',
    () async {
      final host = await _startHost(dartaotruntime, hostArtifact);
      addTearDown(() async {
        if (!host.isClosed) await host.close(graceful: false);
      });
      final plugin = await host.startPlugin(
        pluginId: 'multiplexed',
        artifactUri: pluginArtifact.uri,
        arguments: const <String>['wait'],
      );
      final left = <int>[];
      final right = <int>[];
      late StreamSubscription<Object?> leftSubscription;
      late StreamSubscription<Object?> rightSubscription;
      final leftFirst = Completer<void>();
      final rightFirst = Completer<void>();
      leftSubscription = plugin.stream('left', const {}).listen((value) {
        left.add((value! as Map)['sequence']! as int);
        if (!leftFirst.isCompleted) {
          leftSubscription.pause();
          leftFirst.complete();
        }
      });
      rightSubscription = plugin.stream('right', const {}).listen((value) {
        right.add((value! as Map)['sequence']! as int);
        if (!rightFirst.isCompleted) {
          rightSubscription.pause();
          rightFirst.complete();
        }
      });
      await Future.wait<void>(<Future<void>>[
        leftFirst.future,
        rightFirst.future,
      ]);
      expect(left, <int>[0]);
      expect(right, <int>[0]);
      expect(
        await plugin.request('ping', const <String, Object?>{}),
        <String, Object?>{'alive': true},
      );
      await leftSubscription.cancel();
      rightSubscription.resume();
      while (right.length < 2) {
        await Future<void>.delayed(Duration.zero);
      }
      expect(right, <int>[0, 1]);
      await rightSubscription.cancel();
      await plugin.close();
      await host.close();
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  for (final entry in <String, String>{
    'stream-large-item': 'response_too_large',
    'stream-large-terminal': 'response_too_large',
    'stream-malformed': 'stream_protocol_violation',
  }.entries) {
    test(
      'contains ${entry.key} to one stream',
      () async {
        final host = await _startHost(dartaotruntime, hostArtifact);
        addTearDown(() async {
          if (!host.isClosed) await host.close(graceful: false);
        });
        final plugin = await host.startPlugin(
          pluginId: entry.key,
          artifactUri: pluginArtifact.uri,
          arguments: const <String>['wait'],
        );
        await expectLater(
          plugin.stream(entry.key, const <String, Object?>{}),
          emitsError(
            isA<PluginRemoteFailure>().having(
              (failure) => failure.code,
              'code',
              entry.value,
            ),
          ),
        );
        expect(
          await plugin.request('ping', const <String, Object?>{}),
          <String, Object?>{'alive': true},
        );
        await plugin.close();
        await host.close();
      },
      timeout: const Timeout(Duration(minutes: 2)),
    );
  }

  for (final method in <String>[
    'stream-item-missing-payload',
    'stream-item-extra-field',
  ]) {
    test(
      'contains malformed item envelope $method',
      () async {
        final host = await _startHost(dartaotruntime, hostArtifact);
        addTearDown(() async {
          if (!host.isClosed) await host.close(graceful: false);
        });
        final plugin = await host.startPlugin(
          pluginId: method,
          artifactUri: pluginArtifact.uri,
          arguments: const <String>['wait'],
        );
        await expectLater(
          plugin.stream(method, const {}),
          emitsError(
            isA<PluginRemoteFailure>().having(
              (failure) => failure.code,
              'code',
              'stream_protocol_violation',
            ),
          ),
        );
        expect(await plugin.request('stream-cancel-count', const {}), 1);
        expect(await plugin.request('ping', const {}), <String, Object?>{
          'alive': true,
        });
        await plugin.close();
        await host.close();
      },
      timeout: const Timeout(Duration(minutes: 2)),
    );
  }

  test(
    'contains non-stream response for active plugin stream',
    () async {
      final host = await _startHost(dartaotruntime, hostArtifact);
      addTearDown(() async {
        if (!host.isClosed) await host.close(graceful: false);
      });
      final plugin = await host.startPlugin(
        pluginId: 'active-stream-wrong-kind',
        artifactUri: pluginArtifact.uri,
        arguments: const <String>['wait'],
      );
      final peer = await host.startPlugin(
        pluginId: 'active-stream-peer',
        artifactUri: pluginArtifact.uri,
        arguments: const <String>['wait'],
      );
      await expectLater(
        plugin.stream('stream-malformed', const {}),
        emitsError(
          isA<PluginRemoteFailure>().having(
            (failure) => failure.code,
            'code',
            'stream_protocol_violation',
          ),
        ),
      );
      expect(await plugin.request('ping', const {}), <String, Object?>{
        'alive': true,
      });
      expect(await peer.request('ping', const {}), <String, Object?>{
        'alive': true,
      });
      await plugin.close();
      await peer.close();
      await host.close();
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  for (final method in <String>[
    'stream-failure-null-declared',
    'stream-failure-declared-no-details',
    'stream-failure-null-details',
  ]) {
    test(
      'contains malformed stream failure metadata $method',
      () async {
        final host = await _startHost(dartaotruntime, hostArtifact);
        addTearDown(() async {
          if (!host.isClosed) await host.close(graceful: false);
        });
        final plugin = await host.startPlugin(
          pluginId: method,
          artifactUri: pluginArtifact.uri,
          arguments: const <String>['wait'],
        );
        final peer = await host.startPlugin(
          pluginId: '$method-peer',
          artifactUri: pluginArtifact.uri,
          arguments: const <String>['wait'],
        );
        await expectLater(
          plugin.stream(method, const {}),
          emitsError(
            isA<PluginRemoteFailure>().having(
              (failure) => failure.code,
              'code',
              'stream_protocol_violation',
            ),
          ),
        );
        expect(await plugin.request('ping', const {}), <String, Object?>{
          'alive': true,
        });
        expect(await peer.request('ping', const {}), <String, Object?>{
          'alive': true,
        });
        await plugin.close();
        await peer.close();
        await host.close();
      },
      timeout: const Timeout(Duration(minutes: 2)),
    );
  }

  for (final method in <String>[
    'stream-failure-compact',
    'stream-failure-declared',
  ]) {
    test(
      'accepts valid stream failure metadata $method',
      () async {
        final host = await _startHost(dartaotruntime, hostArtifact);
        addTearDown(() async {
          if (!host.isClosed) await host.close(graceful: false);
        });
        final plugin = await host.startPlugin(
          pluginId: method,
          artifactUri: pluginArtifact.uri,
          arguments: const <String>['wait'],
        );
        await expectLater(
          plugin.stream(method, const {}),
          emitsError(
            isA<PluginRemoteFailure>().having(
              (failure) => failure.code,
              'code',
              'fixture_failure',
            ),
          ),
        );
        expect(await plugin.request('ping', const {}), <String, Object?>{
          'alive': true,
        });
        await plugin.close();
        await host.close();
      },
      timeout: const Timeout(Duration(minutes: 2)),
    );
  }

  test(
    'retires plugin for stream frame without request ID',
    () async {
      final host = await _startHost(dartaotruntime, hostArtifact);
      addTearDown(() async {
        if (!host.isClosed) await host.close(graceful: false);
      });
      final broken = await host.startPlugin(
        pluginId: 'uncorrelatable-stream',
        artifactUri: pluginArtifact.uri,
        arguments: const <String>['wait'],
      );
      final peer = await host.startPlugin(
        pluginId: 'uncorrelatable-peer',
        artifactUri: pluginArtifact.uri,
        arguments: const <String>['wait'],
      );
      await expectLater(
        broken.stream('stream-item-missing-request-id', const {}),
        emitsError(isA<PluginRemoteFailure>()),
      );
      await broken.terminated.timeout(const Duration(seconds: 5));
      expect(broken.isClosed, isTrue);
      expect(await peer.request('ping', const {}), <String, Object?>{
        'alive': true,
      });
      final replacement = await host.startPlugin(
        pluginId: 'uncorrelatable-stream',
        artifactUri: pluginArtifact.uri,
        arguments: const <String>['wait'],
      );
      expect(await replacement.request('ping', const {}), <String, Object?>{
        'alive': true,
      });
      await replacement.close();
      await peer.close();
      await host.close();
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test(
    'retires plugin for stream frame with wrong integer ID',
    () async {
      final host = await _startHost(dartaotruntime, hostArtifact);
      addTearDown(() async {
        if (!host.isClosed) await host.close(graceful: false);
      });
      final broken = await host.startPlugin(
        pluginId: 'wrong-stream-id',
        artifactUri: pluginArtifact.uri,
        arguments: const <String>['wait'],
      );
      final peer = await host.startPlugin(
        pluginId: 'wrong-stream-id-peer',
        artifactUri: pluginArtifact.uri,
        arguments: const <String>['wait'],
      );
      await expectLater(
        broken.stream('stream-item-wrong-request-id', const {}),
        emitsError(isA<PluginRemoteFailure>()),
      );
      await broken.terminated.timeout(const Duration(seconds: 5));
      expect(await peer.request('ping', const {}), <String, Object?>{
        'alive': true,
      });
      await peer.close();
      await host.close();
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test(
    'stops an active stream and restarts same ID in the same host',
    () async {
      final diagnostics = <String>[];
      final host = await PluginBackendHost.start(
        dartaotruntimeExecutable: dartaotruntime,
        hostArtifactPath: hostArtifact.path,
        onDiagnostic: diagnostics.add,
      );
      addTearDown(() async {
        if (!host.isClosed) await host.close(graceful: false);
      });
      final first = await host.startPlugin(
        pluginId: 'stream-restart',
        artifactUri: pluginArtifact.uri,
        arguments: const <String>['wait'],
      );
      final firstItem = Completer<void>();
      late final StreamSubscription<Object?> subscription;
      subscription = first.stream('long', const {}).listen((_) {
        subscription.pause();
        if (!firstItem.isCompleted) firstItem.complete();
      });
      await firstItem.future;
      await first.close();
      expect(first.isClosed, isTrue);
      expect(
        diagnostics.where((message) => message.contains('protocol_violation')),
        isEmpty,
      );
      final replacement = await host.startPlugin(
        pluginId: 'stream-restart',
        artifactUri: pluginArtifact.uri,
        arguments: const <String>['wait'],
      );
      expect(
        await replacement.request('ping', const <String, Object?>{}),
        <String, Object?>{'alive': true},
      );
      await first.close();
      expect(replacement.isClosed, isFalse);
      await replacement.close();
      await host.close();
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test(
    'retires only a generation that ignores host-abort cancellation',
    () async {
      final host = await _startHost(dartaotruntime, hostArtifact);
      addTearDown(() async {
        if (!host.isClosed) await host.close(graceful: false);
      });
      final broken = await host.startPlugin(
        pluginId: 'abort-no-ack',
        artifactUri: pluginArtifact.uri,
        arguments: const <String>['wait'],
      );
      final healthy = await host.startPlugin(
        pluginId: 'abort-healthy',
        artifactUri: pluginArtifact.uri,
        arguments: const <String>['wait'],
      );
      await expectLater(
        broken.stream('stream-large-item-no-ack', const {}),
        emitsError(
          isA<PluginRemoteFailure>().having(
            (failure) => failure.code,
            'code',
            'response_too_large',
          ),
        ),
      );
      await broken.terminated.timeout(const Duration(seconds: 5));
      expect(broken.isClosed, isTrue);
      expect(
        await healthy.request('ping', const <String, Object?>{}),
        <String, Object?>{'alive': true},
      );
      final replacement = await host.startPlugin(
        pluginId: 'abort-no-ack',
        artifactUri: pluginArtifact.uri,
        arguments: const <String>['wait'],
      );
      expect(
        await replacement.request('ping', const <String, Object?>{}),
        <String, Object?>{'alive': true},
      );
      await replacement.close();
      await healthy.close();
      await host.close();
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  for (final method in <String>[
    'stream-large-item-then-done',
    'stream-large-item-then-failure',
  ]) {
    test(
      'host abort remains the only client terminal for $method',
      () async {
        final host = await _startHost(dartaotruntime, hostArtifact);
        addTearDown(() async {
          if (!host.isClosed) await host.close(graceful: false);
        });
        final plugin = await host.startPlugin(
          pluginId: method,
          artifactUri: pluginArtifact.uri,
          arguments: const <String>['wait'],
        );
        final errors = <Object>[];
        int done = 0;
        final terminal = Completer<void>();
        plugin
            .stream(method, const {})
            .listen(
              (_) {},
              onError: (Object error) {
                errors.add(error);
                if (!terminal.isCompleted) terminal.complete();
              },
              onDone: () {
                done++;
                if (!terminal.isCompleted) terminal.complete();
              },
            );
        await terminal.future;
        expect(errors, hasLength(1));
        expect(
          errors.single,
          isA<PluginRemoteFailure>().having(
            (failure) => failure.code,
            'code',
            'response_too_large',
          ),
        );
        expect(done, lessThanOrEqualTo(1));
        expect(await plugin.request('stream-cancel-count', const {}), 1);
        expect(
          await plugin.request('ping', const <String, Object?>{}),
          <String, Object?>{'alive': true},
        );
        await plugin.close();
        await host.close();
      },
      timeout: const Timeout(Duration(minutes: 2)),
    );
  }

  test(
    'invalid credit fails the stream and cancels the producer',
    () async {
      final process = await Process.start(dartaotruntime, <String>[
        hostArtifact.path,
      ]);
      addTearDown(() async {
        process.kill();
        await process.exitCode;
      });
      final decoder = BackendHostFrameDecoder();
      final messages = StreamController<Map<String, Object?>>();
      process.stdout.listen((bytes) {
        for (final message in decoder.add(bytes)) {
          messages.add(message);
        }
      });
      final iterator = StreamIterator<Map<String, Object?>>(messages.stream);
      expect(await iterator.moveNext(), isTrue);
      expect(iterator.current['kind'], 'hostHello');
      void send(Map<String, Object?> message) =>
          process.stdin.add(encodeBackendHostFrame(message));
      send(<String, Object?>{
        'protocolVersion': backendHostProtocolVersion,
        'kind': 'startPlugin',
        'requestId': 1,
        'pluginId': 'invalid-credit',
        'generation': 'test-generation',
        'defaultConfigurationContext': 'default',
        'artifactUri': pluginArtifact.uri.toString(),
        'arguments': <String>['wait'],
      });
      expect(await iterator.moveNext(), isTrue);
      expect(iterator.current['kind'], 'pluginReady');
      send(<String, Object?>{
        'protocolVersion': backendHostProtocolVersion,
        'kind': 'streamOpen',
        'requestId': 2,
        'pluginId': 'invalid-credit',
        'configurationContext': 'default',
        'serviceId': 'fixture',
        'method': 'long',
        'payload': <String, Object?>{},
      });
      send(<String, Object?>{
        'protocolVersion': backendHostProtocolVersion,
        'kind': 'streamCredit',
        'requestId': 2,
        'pluginId': 'invalid-credit',
        'credit': backendHostStreamWindow + 1,
      });
      Map<String, Object?>? failure;
      while (failure == null) {
        expect(await iterator.moveNext(), isTrue);
        if (iterator.current['kind'] == 'streamFailure') {
          failure = iterator.current;
        }
      }
      expect((failure['error']! as Map)['code'], 'stream_protocol_violation');
      send(<String, Object?>{
        'protocolVersion': backendHostProtocolVersion,
        'kind': 'request',
        'requestId': 3,
        'pluginId': 'invalid-credit',
        'configurationContext': 'default',
        'serviceId': 'fixture',
        'method': 'stream-cancel-count',
        'payload': <String, Object?>{},
      });
      Map<String, Object?>? response;
      while (response == null) {
        expect(await iterator.moveNext(), isTrue);
        if (iterator.current['kind'] == 'response' &&
            iterator.current['requestId'] == 3) {
          response = iterator.current;
        }
      }
      expect(response['payload'], 1);
      send(<String, Object?>{
        'protocolVersion': backendHostProtocolVersion,
        'kind': 'stopPlugin',
        'requestId': 4,
        'pluginId': 'invalid-credit',
      });
      while (iterator.current['kind'] != 'pluginStopped') {
        expect(await iterator.moveNext(), isTrue);
      }
      await iterator.cancel();
      await messages.close();
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test(
    'retires plugin when preferred and fallback terminals cannot send',
    () async {
      final emitted = <Map<String, Object?>>[];
      bool rejectTerminals = true;
      final host = AdeleBackendHost(
        send: (message) {
          if (rejectTerminals &&
              message['pluginId'] == 'double-send-failure' &&
              (message['kind'] == 'streamDone' ||
                  message['kind'] == 'streamFailure')) {
            return false;
          }
          emitted.add(message);
          return true;
        },
      );
      addTearDown(() => host.shutdown(notify: false));
      await host.handle(<String, Object?>{
        'protocolVersion': backendHostProtocolVersion,
        'kind': 'startPlugin',
        'requestId': 1,
        'pluginId': 'double-send-failure',
        'generation': 'test-generation',
        'defaultConfigurationContext': 'default',
        'artifactUri': pluginKernel.uri.toString(),
        'arguments': <String>['wait'],
      });
      await host.handle(<String, Object?>{
        'protocolVersion': backendHostProtocolVersion,
        'kind': 'startPlugin',
        'requestId': 2,
        'pluginId': 'healthy-peer',
        'generation': 'test-generation',
        'defaultConfigurationContext': 'default',
        'artifactUri': pluginKernel.uri.toString(),
        'arguments': <String>['wait'],
      });
      await host.handle(<String, Object?>{
        'protocolVersion': backendHostProtocolVersion,
        'kind': 'streamOpen',
        'requestId': 3,
        'pluginId': 'double-send-failure',
        'configurationContext': 'default',
        'serviceId': 'fixture',
        'method': 'stream-large-terminal',
        'payload': <String, Object?>{},
      });
      await host.handle(<String, Object?>{
        'protocolVersion': backendHostProtocolVersion,
        'kind': 'streamCredit',
        'requestId': 3,
        'pluginId': 'double-send-failure',
        'credit': 1,
      });
      while (!emitted.any(
        (message) =>
            message['kind'] == 'pluginFailed' &&
            message['pluginId'] == 'double-send-failure',
      )) {
        await Future<void>.delayed(Duration.zero);
      }
      rejectTerminals = false;
      await host.handle(<String, Object?>{
        'protocolVersion': backendHostProtocolVersion,
        'kind': 'request',
        'requestId': 4,
        'pluginId': 'healthy-peer',
        'configurationContext': 'default',
        'serviceId': 'fixture',
        'method': 'ping',
        'payload': <String, Object?>{},
      });
      while (!emitted.any(
        (message) => message['kind'] == 'response' && message['requestId'] == 4,
      )) {
        await Future<void>.delayed(Duration.zero);
      }
      expect(
        emitted.singleWhere((message) => message['requestId'] == 4)['payload'],
        <String, Object?>{'alive': true},
      );
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  for (final settles in <bool>[true, false]) {
    test(
      'consumer cancellation containment ${settles ? 'waits for settlement' : 'retires stuck generation'}',
      () async {
        final host = await _startHost(dartaotruntime, hostArtifact);
        addTearDown(() async {
          if (!host.isClosed) await host.close(graceful: false);
        });
        final plugin = await host.startPlugin(
          pluginId: 'consumer-containment-$settles',
          artifactUri: pluginArtifact.uri,
          arguments: const <String>['wait'],
        );
        final peer = await host.startPlugin(
          pluginId: 'consumer-containment-peer-$settles',
          artifactUri: pluginArtifact.uri,
          arguments: const <String>['wait'],
        );
        final subscription = plugin
            .stream(
              settles
                  ? 'stream-cancel-malformed-settle'
                  : 'stream-cancel-malformed-stuck',
              const {},
            )
            .listen((_) {});
        final cancelling = subscription.cancel();
        if (settles) {
          await cancelling.timeout(const Duration(seconds: 2));
          expect(plugin.isClosed, isFalse);
          expect(await plugin.request('ping', const {}), <String, Object?>{
            'alive': true,
          });
          await plugin.close();
        } else {
          await plugin.terminated.timeout(const Duration(seconds: 5));
          await cancelling.timeout(const Duration(seconds: 1));
          expect(plugin.isClosed, isTrue);
        }
        expect(await peer.request('ping', const {}), <String, Object?>{
          'alive': true,
        });
        await peer.close();
        await host.close();
      },
      timeout: const Timeout(Duration(minutes: 2)),
    );
  }

  test('emits forwarding acknowledgement after plugin cancel send', () async {
    final emitted = <Map<String, Object?>>[];
    final host = AdeleBackendHost(
      send: (message) {
        emitted.add(message);
        return true;
      },
    );
    addTearDown(() => host.shutdown(notify: false));
    await host.handle(<String, Object?>{
      'protocolVersion': backendHostProtocolVersion,
      'kind': 'startPlugin',
      'requestId': 30,
      'pluginId': 'cancel-forwarding',
      'generation': 'test-generation',
      'defaultConfigurationContext': 'default',
      'artifactUri': pluginKernel.uri.toString(),
      'arguments': <String>['wait'],
    });
    await host.handle(<String, Object?>{
      'protocolVersion': backendHostProtocolVersion,
      'kind': 'streamOpen',
      'requestId': 31,
      'pluginId': 'cancel-forwarding',
      'configurationContext': 'default',
      'serviceId': 'fixture',
      'method': 'long',
      'payload': <String, Object?>{},
    });
    await host.handle(<String, Object?>{
      'protocolVersion': backendHostProtocolVersion,
      'kind': 'streamCancel',
      'requestId': 31,
      'pluginId': 'cancel-forwarding',
    });
    expect(
      emitted.any(
        (message) =>
            message['kind'] == 'streamCancelForwarded' &&
            message['requestId'] == 31,
      ),
      isTrue,
    );
    await host.handle(<String, Object?>{
      'protocolVersion': backendHostProtocolVersion,
      'kind': 'request',
      'requestId': 32,
      'pluginId': 'cancel-forwarding',
      'configurationContext': 'default',
      'serviceId': 'fixture',
      'method': 'stream-cancel-count',
      'payload': <String, Object?>{},
    });
    while (!emitted.any(
      (message) => message['kind'] == 'response' && message['requestId'] == 32,
    )) {
      await Future<void>.delayed(Duration.zero);
    }
    expect(
      emitted.singleWhere((message) => message['requestId'] == 32)['payload'],
      1,
    );
  });

  test(
    'ingress cancellation intent survives pre-forward containment',
    () async {
      final emitted = <Map<String, Object?>>[];
      final host = AdeleBackendHost(
        send: (message) {
          emitted.add(message);
          return true;
        },
      );
      addTearDown(() => host.shutdown(notify: false));
      await host.handle(<String, Object?>{
        'protocolVersion': backendHostProtocolVersion,
        'kind': 'startPlugin',
        'requestId': 40,
        'pluginId': 'ingress-cancel',
        'generation': 'test-generation',
        'defaultConfigurationContext': 'default',
        'artifactUri': pluginKernel.uri.toString(),
        'arguments': <String>['wait'],
      });
      await host.handle(<String, Object?>{
        'protocolVersion': backendHostProtocolVersion,
        'kind': 'streamOpen',
        'requestId': 41,
        'pluginId': 'ingress-cancel',
        'configurationContext': 'default',
        'serviceId': 'fixture',
        'method': 'stream-malformed',
        'payload': <String, Object?>{},
      });
      final cancel = <String, Object?>{
        'protocolVersion': backendHostProtocolVersion,
        'kind': 'streamCancel',
        'requestId': 41,
        'pluginId': 'ingress-cancel',
      };
      host.noteStreamCancelRequested(cancel);
      await host.handle(<String, Object?>{
        'protocolVersion': backendHostProtocolVersion,
        'kind': 'streamCredit',
        'requestId': 41,
        'pluginId': 'ingress-cancel',
        'credit': 1,
      });
      while (!emitted.any(
        (message) =>
            message['kind'] == 'streamCancelled' && message['requestId'] == 41,
      )) {
        await Future<void>.delayed(Duration.zero);
      }
      await host.handle(cancel);
      expect(
        emitted.where(
          (message) =>
              message['kind'] == 'streamCancelForwarded' &&
              message['requestId'] == 41,
        ),
        hasLength(1),
      );
      expect(
        emitted.where(
          (message) =>
              message['kind'] == 'streamFailure' && message['requestId'] == 41,
        ),
        isEmpty,
      );
      expect(
        emitted.where(
          (message) =>
              message['kind'] == 'streamCancelled' &&
              message['requestId'] == 41,
        ),
        hasLength(1),
      );
    },
  );

  test('ingress cancellation intent survives stream admission', () async {
    final emitted = <Map<String, Object?>>[];
    final host = AdeleBackendHost(
      send: (message) {
        emitted.add(message);
        return true;
      },
    );
    addTearDown(() => host.shutdown(notify: false));
    await host.handle(<String, Object?>{
      'protocolVersion': backendHostProtocolVersion,
      'kind': 'startPlugin',
      'requestId': 50,
      'pluginId': 'pre-admission-cancel',
      'generation': 'test-generation',
      'defaultConfigurationContext': 'default',
      'artifactUri': pluginKernel.uri.toString(),
      'arguments': <String>['wait'],
    });
    final cancel = <String, Object?>{
      'protocolVersion': backendHostProtocolVersion,
      'kind': 'streamCancel',
      'requestId': 51,
      'pluginId': 'pre-admission-cancel',
    };
    host.noteStreamCancelRequested(cancel);
    await host.handle(<String, Object?>{
      'protocolVersion': backendHostProtocolVersion,
      'kind': 'streamOpen',
      'requestId': 51,
      'pluginId': 'pre-admission-cancel',
      'configurationContext': 'default',
      'serviceId': 'fixture',
      'method': 'stream-malformed',
      'payload': <String, Object?>{},
    });
    await host.handle(<String, Object?>{
      'protocolVersion': backendHostProtocolVersion,
      'kind': 'streamCredit',
      'requestId': 51,
      'pluginId': 'pre-admission-cancel',
      'credit': 1,
    });
    while (!emitted.any(
      (message) =>
          message['kind'] == 'streamCancelled' && message['requestId'] == 51,
    )) {
      await Future<void>.delayed(Duration.zero);
    }
    await host.handle(cancel);
    expect(
      emitted.where(
        (message) =>
            message['kind'] == 'streamFailure' && message['requestId'] == 51,
      ),
      isEmpty,
    );
    expect(
      emitted.where(
        (message) =>
            message['kind'] == 'streamCancelForwarded' &&
            message['requestId'] == 51,
      ),
      hasLength(1),
    );
    await host.handle(<String, Object?>{
      'protocolVersion': backendHostProtocolVersion,
      'kind': 'request',
      'requestId': 52,
      'pluginId': 'pre-admission-cancel',
      'configurationContext': 'default',
      'serviceId': 'fixture',
      'method': 'stream-cancel-count',
      'payload': <String, Object?>{},
    });
    await host.handle(<String, Object?>{
      'protocolVersion': backendHostProtocolVersion,
      'kind': 'request',
      'requestId': 53,
      'pluginId': 'pre-admission-cancel',
      'configurationContext': 'default',
      'serviceId': 'fixture',
      'method': 'ping',
      'payload': <String, Object?>{},
    });
    while (!emitted.any(
      (message) => message['kind'] == 'response' && message['requestId'] == 53,
    )) {
      await Future<void>.delayed(Duration.zero);
    }
    expect(
      emitted.singleWhere((message) => message['requestId'] == 52)['payload'],
      1,
    );
    expect(
      emitted.singleWhere((message) => message['requestId'] == 53)['payload'],
      <String, Object?>{'alive': true},
    );
  });

  test('unmatched ingress cancellation intent is discarded', () async {
    final emitted = <Map<String, Object?>>[];
    final host = AdeleBackendHost(
      send: (message) {
        emitted.add(message);
        return true;
      },
    );
    addTearDown(() => host.shutdown(notify: false));
    await host.handle(<String, Object?>{
      'protocolVersion': backendHostProtocolVersion,
      'kind': 'startPlugin',
      'requestId': 60,
      'pluginId': 'discard-cancel',
      'generation': 'test-generation',
      'defaultConfigurationContext': 'default',
      'artifactUri': pluginKernel.uri.toString(),
      'arguments': <String>['wait'],
    });
    final cancel = <String, Object?>{
      'protocolVersion': backendHostProtocolVersion,
      'kind': 'streamCancel',
      'requestId': 61,
      'pluginId': 'discard-cancel',
    };
    host.noteStreamCancelRequested(cancel);
    await host.handle(cancel);
    await host.handle(<String, Object?>{
      'protocolVersion': backendHostProtocolVersion,
      'kind': 'streamOpen',
      'requestId': 61,
      'pluginId': 'discard-cancel',
      'configurationContext': 'default',
      'serviceId': 'fixture',
      'method': 'stream-malformed',
      'payload': <String, Object?>{},
    });
    await host.handle(<String, Object?>{
      'protocolVersion': backendHostProtocolVersion,
      'kind': 'streamCredit',
      'requestId': 61,
      'pluginId': 'discard-cancel',
      'credit': 1,
    });
    while (!emitted.any(
      (message) =>
          message['kind'] == 'streamFailure' && message['requestId'] == 61,
    )) {
      await Future<void>.delayed(Duration.zero);
    }
    expect(
      emitted.where(
        (message) =>
            message['kind'] == 'streamFailure' && message['requestId'] == 61,
      ),
      hasLength(1),
    );
    expect(
      emitted.where(
        (message) =>
            message['kind'] == 'streamCancelForwarded' &&
            message['requestId'] == 61,
      ),
      isEmpty,
    );
  });
}

Future<PluginBackendHost> _startHost(String dartaotruntime, File hostArtifact) {
  return PluginBackendHost.start(
    dartaotruntimeExecutable: dartaotruntime,
    hostArtifactPath: hostArtifact.path,
  );
}

final class _HostDispatcher implements AdeleBackendDispatcher {
  _HostDispatcher(this._dispatch);
  final Future<Map<String, Object?>> Function(Map<Object?, Object?>) _dispatch;
  int calls = 0;
  int closes = 0;

  @override
  Future<Map<String, Object?>> dispatch(Map<Object?, Object?> request) {
    calls++;
    return _dispatch(request);
  }

  @override
  Future<void> handle(
    Map<Object?, Object?> command,
    void Function(Map<String, Object?>) send,
  ) => throw StateError('Reverse unary requests must use dispatch.');

  @override
  Future<void> close() async {
    closes++;
  }
}

final class _StreamHostDispatcher implements AdeleBackendDispatcher {
  _StreamHostDispatcher(this.source);
  final Stream<Object?> Function(String method) source;
  final Map<int, StreamIterator<Object?>> _streams = {};
  int opens = 0;
  int advances = 0;
  int cancels = 0;

  @override
  Future<void> handle(
    Map<Object?, Object?> command,
    void Function(Map<String, Object?>) send,
  ) async {
    final id = command['requestId'] as int;
    if (command['kind'] == 'streamOpen') {
      opens++;
      _streams[id] = StreamIterator(source(command['method'] as String));
    } else if (command['kind'] == 'streamCancel') {
      cancels++;
      await _streams.remove(id)?.cancel();
      send({'kind': 'streamCancelled', 'requestId': id});
    } else if (command['kind'] == 'streamCredit') {
      final iterator = _streams[id]!;
      advances++;
      try {
        final next = await iterator.moveNext();
        if (_streams[id] != iterator) return;
        send({
          'kind': next ? 'streamItem' : 'streamDone',
          'requestId': id,
          if (next) 'payload': iterator.current,
        });
        if (!next) _streams.remove(id);
      } on PluginRemoteFailure catch (error) {
        _streams.remove(id);
        send({
          'kind': 'streamFailure',
          'requestId': id,
          'error': {
            'code': error.code,
            'message': error.message,
            if (error.declaredFailureType != null)
              'declaredFailureType': error.declaredFailureType,
            'details': error.details,
          },
        });
      }
    }
  }

  @override
  Future<Map<String, Object?>> dispatch(Map<Object?, Object?> request) =>
      throw StateError('Not unary.');

  @override
  Future<void> close() => throw StateError('Dispatchers remain caller-owned.');
}

Future<void> _compile(
  String dart,
  String entrypoint,
  String output,
  String workingDirectory,
) async {
  final ProcessResult result = await Process.run(dart, <String>[
    'compile',
    'aot-snapshot',
    entrypoint,
    '-o',
    output,
  ], workingDirectory: workingDirectory);
  if (result.exitCode != 0) throw StateError(result.stderr.toString());
}
