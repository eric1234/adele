import 'dart:async';
import 'dart:io';

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
        'method': 'long',
        'payload': <String, Object?>{},
      });
      send(<String, Object?>{
        'protocolVersion': backendHostProtocolVersion,
        'kind': 'streamCredit',
        'requestId': 2,
        'pluginId': 'invalid-credit',
        'credit': 1,
      });
      send(<String, Object?>{
        'protocolVersion': backendHostProtocolVersion,
        'kind': 'streamCredit',
        'requestId': 2,
        'pluginId': 'invalid-credit',
        'credit': 1,
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
        'artifactUri': pluginKernel.uri.toString(),
        'arguments': <String>['wait'],
      });
      await host.handle(<String, Object?>{
        'protocolVersion': backendHostProtocolVersion,
        'kind': 'startPlugin',
        'requestId': 2,
        'pluginId': 'healthy-peer',
        'artifactUri': pluginKernel.uri.toString(),
        'arguments': <String>['wait'],
      });
      await host.handle(<String, Object?>{
        'protocolVersion': backendHostProtocolVersion,
        'kind': 'streamOpen',
        'requestId': 3,
        'pluginId': 'double-send-failure',
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
      'artifactUri': pluginKernel.uri.toString(),
      'arguments': <String>['wait'],
    });
    await host.handle(<String, Object?>{
      'protocolVersion': backendHostProtocolVersion,
      'kind': 'streamOpen',
      'requestId': 31,
      'pluginId': 'cancel-forwarding',
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
        'artifactUri': pluginKernel.uri.toString(),
        'arguments': <String>['wait'],
      });
      await host.handle(<String, Object?>{
        'protocolVersion': backendHostProtocolVersion,
        'kind': 'streamOpen',
        'requestId': 41,
        'pluginId': 'ingress-cancel',
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
}

Future<PluginBackendHost> _startHost(String dartaotruntime, File hostArtifact) {
  return PluginBackendHost.start(
    dartaotruntimeExecutable: dartaotruntime,
    hostArtifactPath: hostArtifact.path,
  );
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
