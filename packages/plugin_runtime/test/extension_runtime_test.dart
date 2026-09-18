import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:adele_capabilities/adele_capabilities.dart';
import 'package:adele_contract/adele_contract.dart';
import 'package:adele_plugin_api/adele_plugin_api.dart';
import 'package:plugin_runtime/plugin_runtime.dart';
import 'package:test/test.dart';

final _point = ExtensionPoint<_Contribution>('dev.adele.test.extensions');
final _capability = CapabilityKey(
  id: CapabilityId('dev.adele.test.capability'),
  majorVersion: 1,
);

void main() {
  late Directory directory;
  late PluginBackendHost host;
  late ExtensionRegistry extensions;
  late CapabilityRegistry capabilities;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp(
      'adele-extension-runtime-',
    );
    final script = File('${directory.path}/host.dart');
    await script.writeAsString(_hostScript);
    host = await PluginBackendHost.start(
      dartaotruntimeExecutable: Platform.resolvedExecutable,
      hostArtifactPath: script.path,
    );
    extensions = ExtensionRegistry();
    capabilities = CapabilityRegistry();
  });
  tearDown(() async {
    await host.close();
    await directory.delete(recursive: true);
  });

  Future<PluginBackendConnection> connect(
    Map<String, Object?> ready, {
    String pluginId = 'dev.adele.test.plugin',
  }) => host.startPlugin(
    pluginId: pluginId,
    artifactUri: Uri.file('/unused.aot'),
    arguments: [jsonEncode(ready)],
  );

  Future<PluginBackendActivation> activate(
    PluginBackendConnection connection,
  ) => PluginBackendActivation.registerAdvertised(
    connection: connection,
    capabilities: capabilities,
    extensions: extensions,
    adapters: RemoteExtensionAdapterRegistry([_Adapter()]),
  );

  test('omitted advertisements activate no extensions', () async {
    final connection = await connect({});
    final activation = await activate(connection);
    expect(connection.extensionExposures, isEmpty);
    expect(extensions.discover(_point), isEmpty);
    await activation.close();
  });

  test(
    'one generation can own capabilities and several remote extensions',
    () async {
      final connection = await connect({
        'capabilityExposures': [_capabilityExposure],
        'extensionExposures': [
          _exposure('first', 'one'),
          _exposure('second', 'two'),
        ],
      });
      final activation = await activate(connection);
      final provider = capabilities.resolve(_capability);
      final bindings = extensions.discover(_point);
      expect(provider.provider.pluginId, connection.pluginId);
      expect(bindings, hasLength(2));
      expect(await provider.requestChannel.request('echo', {}), {
        'configurationContext': 'default',
        'serviceId': 'testService',
      });
      expect(await bindings.last.value.call(), {
        'configurationContext': 'two',
        'serviceId': 'testService',
      });
      final retiring = activation.retire();
      expect(activation.retire(), same(retiring));
      await retiring;
      expect(capabilities.providersFor(_capability), isEmpty);
      expect(extensions.discover(_point), isEmpty);
      expect(
        () => provider.requestChannel,
        throwsA(isA<ProviderUnavailable>()),
      );
      for (final binding in bindings) {
        expect(binding.validate, throwsA(isA<StaleExtensionBinding>()));
      }
      expect(connection.isClosed, isFalse);
      await activation.close();
    },
  );

  test(
    'several exposures preserve order, data, and exact configured routes',
    () async {
      final first = _exposure('first', 'one');
      final second = _exposure('second', 'two');
      final connection = await connect({
        'extensionExposures': [first, second],
      });
      final activation = await activate(connection);
      expect(connection.extensionExposures.map((e) => e.toMap()), [
        first,
        second,
      ]);
      final bindings = extensions.discover(_point);
      expect(bindings.map((b) => b.id.value), [
        first['extensionId'],
        second['extensionId'],
      ]);
      expect(await bindings.last.value.call(), {
        'configurationContext': 'two',
        'serviceId': 'testService',
      });
      expect(
        () => connection.extensionExposures.first.metadata['label'] = 'changed',
        throwsUnsupportedError,
      );
      await activation.close();
    },
  );

  test(
    'unknown adapters and invalid point metadata roll back capabilities and extensions',
    () async {
      for (final invalid in [
        {
          ..._exposure('bad', 'default'),
          'extensionPointId': 'dev.adele.unknown.point',
        },
        {
          ..._exposure('bad', 'default'),
          'metadata': {'failureMode': 'invented'},
        },
        _exposure('first', 'default'),
      ]) {
        final connection = await connect({
          'capabilityExposures': [_capabilityExposure],
          'extensionExposures': [_exposure('first', 'default'), invalid],
        });
        await expectLater(
          activate(connection),
          throwsA(
            anyOf(
              isA<ExtensionContractException>(),
              isA<ExtensionRegistrationException>(),
            ),
          ),
        );
        expect(connection.isClosed, isTrue);
        expect(extensions.discover(_point), isEmpty);
        expect(capabilities.providersFor(_capability), isEmpty);
        expect(host.isClosed, isFalse);
      }
      final healthy = await connect({
        'extensionExposures': [_exposure('healthy', 'default')],
      });
      await (await activate(healthy)).close();
    },
  );

  test('duplicate registration never retires an existing generation', () async {
    final first = await connect({
      'extensionExposures': [_exposure('first', 'default')],
    });
    final firstActivation = await activate(first);
    final retained = extensions.discover(_point).single;
    final second = await connect({
      'capabilityExposures': [_capabilityExposure],
      'extensionExposures': [
        _exposure('new', 'default'),
        _exposure('first', 'default'),
      ],
    }, pluginId: 'dev.adele.test.other');
    await expectLater(
      activate(second),
      throwsA(isA<ExtensionRegistrationException>()),
    );
    expect(extensions.discover(_point).single.id, retained.id);
    expect(retained.validate, returnsNormally);
    expect(await retained.value.call(), isA<Map<String, Object?>>());
    expect(capabilities.providersFor(_capability), isEmpty);
    await firstActivation.close();
  });

  test(
    'retirement stales exact binding and captured proxy without replacement retargeting',
    () async {
      final ready = {
        'extensionExposures': [_exposure('first', 'default')],
      };
      final first = await connect(ready);
      final activation = await activate(first);
      final old = extensions.discover(_point).single;
      final proxy = old.value;
      final settled = Completer<void>();
      final pending = proxy.hold(settled.future);
      final failed = expectLater(
        pending,
        throwsA(isA<StaleExtensionBinding>()),
      );
      await activation.retire();
      settled.complete();
      await failed;
      expect(old.validate, throwsA(isA<StaleExtensionBinding>()));
      await expectLater(proxy.call(), throwsA(isA<StaleExtensionBinding>()));
      await first.close();
      final replacement = await connect(ready);
      final next = await activate(replacement);
      await activation.close();
      expect(replacement.isClosed, isFalse);
      expect(old.validate, throwsA(isA<StaleExtensionBinding>()));
      expect(extensions.discover(_point).single.validate, returnsNormally);
      await next.close();
    },
  );

  test('connection termination retires registered extensions', () async {
    final connection = await connect({
      'extensionExposures': [_exposure('first', 'default')],
    });
    final activation = await activate(connection);
    final binding = extensions.discover(_point).single;
    await connection.close();
    await activation.retire();
    expect(binding.validate, throwsA(isA<StaleExtensionBinding>()));
    expect(extensions.discover(_point), isEmpty);
  });

  group('stream-scoped host invocations', () {
    late PluginBackendConnection connection;
    late PluginBackendActivation activation;
    late RemoteExtensionContext context;

    setUp(() async {
      connection = await connect({
        'extensionExposures': [_exposure('first', 'configured')],
      });
      activation = await activate(connection);
      context = extensions.discover(_point).single.value.context;
    });

    Future<Map<Object?, Object?>> reverse(
      PluginHostInvocation invocation, {
      PluginBackendConnection? caller,
      String service = 'fixture',
    }) async =>
        await (caller ?? connection).request('reverse', {
              'context': invocation.id,
              'service': service,
            })
            as Map<Object?, Object?>;

    void expectRevoked(Map<Object?, Object?> response) {
      expect(response['ok'], isFalse);
      expect((response['error'] as Map)['code'], 'host_invocation_unavailable');
    }

    test(
      'listen opens fresh authority for nested unary calls and exact route',
      () async {
        final dispatcher = _HostDispatcher(() async => 'host value');
        final invocations = <PluginHostInvocation>[];
        Stream<Object?> stream() =>
            context.invokeStream({'fixture': dispatcher}, (invocation) {
              invocations.add(invocation);
              return (context.channel as AdeleStreamChannel).stream('events', {
                'context': invocation.id,
                'count': 2,
              });
            });
        final retained = stream();
        expect(invocations, isEmpty);
        expect(dispatcher.calls, 0);
        final items = await retained.toList();
        expect(items, [
          for (var index = 0; index < 2; index++)
            {
              'value': 'host value',
              'configurationContext': 'configured',
              'serviceId': 'testService',
            },
        ]);
        expect(dispatcher.calls, 2);
        expect(invocations.single.isClosed, isTrue);
        expectRevoked(await reverse(invocations.single));
        expect(() => retained.listen((_) {}), throwsStateError);
        await stream().drain<void>();
        expect(invocations.last.id, isNot(invocations.first.id));
        expect(invocations.every((invocation) => invocation.isClosed), isTrue);
        expect(dispatcher.closed, isFalse);
      },
    );

    test(
      'retained subscription forwards pause and resume without losing authority',
      () async {
        final dispatcher = _HostDispatcher(() async => 'value');
        late PluginHostInvocation invocation;
        final source = StreamController<int>(sync: true);
        final events = <int>[];
        final done = Completer<void>();
        final subscription = context
            .invokeStream({'fixture': dispatcher}, (opened) {
              invocation = opened;
              return source.stream;
            })
            .listen(events.add, onDone: done.complete);
        source.add(1);
        subscription.pause();
        expect(source.isPaused, isTrue);
        source.add(2);
        expect(events, [1]);
        expect(invocation.isClosed, isFalse);
        expect((await reverse(invocation))['payload'], 'value');
        final denied = await reverse(invocation, service: 'unapproved');
        expect((denied['error'] as Map)['code'], 'service_unavailable');
        subscription.resume();
        await source.close();
        await done.future;
        expect(events, [1, 2]);
        expect(invocation.isClosed, isTrue);
        expectRevoked(await reverse(invocation));
      },
    );

    test(
      'pausing the consumer preserves transport credit backpressure',
      () async {
        final dispatcher = _HostDispatcher(() async => 'item');
        final first = Completer<void>();
        final done = Completer<void>();
        final events = <Object?>[];
        late PluginHostInvocation invocation;
        late StreamSubscription<Object?> subscription;
        subscription = context
            .invokeStream({'fixture': dispatcher}, (opened) {
              invocation = opened;
              return (context.channel as AdeleStreamChannel).stream('events', {
                'context': opened.id,
                'count': 3,
              });
            })
            .listen((item) {
              events.add(item);
              if (events.length == 1) {
                subscription.pause();
                first.complete();
              }
            }, onDone: done.complete);
        await first.future;
        // A round trip drains any already-sent credit without a timing assumption.
        await connection.request('echo', {});
        expect(dispatcher.calls, 1);
        expect(events, hasLength(1));
        expect(invocation.isClosed, isFalse);
        subscription.resume();
        await done.future;
        expect(events, hasLength(3));
        expect(dispatcher.calls, 3);
        expect(invocation.isClosed, isTrue);
      },
    );

    for (final cancelOnError in [false, true]) {
      test(
        'first error revokes and cancels with cancelOnError=$cancelOnError',
        () async {
          late PluginHostInvocation invocation;
          final primary = StateError('stream failed');
          final trace = StackTrace.current;
          var cancellations = 0;
          final source = StreamController<int>(
            sync: true,
            onCancel: () {
              expect(invocation.isClosed, isTrue);
              cancellations++;
            },
          );
          final errors = <Object>[];
          final traces = <StackTrace>[];
          final events = <int>[];
          final failed = Completer<void>();
          final subscription = context
              .invokeStream<int>({}, (opened) {
                invocation = opened;
                return source.stream;
              })
              .listen(
                events.add,
                onError: (Object error, StackTrace stack) {
                  errors.add(error);
                  traces.add(stack);
                  expect(invocation.isClosed, isTrue);
                  failed.complete();
                },
                cancelOnError: cancelOnError,
              );
          source.addError(primary, trace);
          source.add(99);
          await failed.future;
          await subscription.cancel();
          await source.close();
          expect(errors, [same(primary)]);
          expect(traces.single, same(trace));
          expect(events, isEmpty);
          expect(cancellations, 1);
          expectRevoked(await reverse(invocation));
        },
      );
    }

    test(
      'operation and listen setup failures revoke minted authority',
      () async {
        for (final listenFails in [false, true]) {
          late PluginHostInvocation invocation;
          final failure = StateError('setup failed');
          final stream = context.invokeStream<int>({}, (opened) {
            invocation = opened;
            if (!listenFails) throw failure;
            return AdeleLazyStream<int>((_, _, _, _) => throw failure);
          });
          await expectLater(
            stream,
            emitsInOrder([emitsError(same(failure)), emitsDone]),
          );
          expect(invocation.isClosed, isTrue);
          expectRevoked(await reverse(invocation));
        }
      },
    );

    test(
      'cleanup failure does not replace the terminal stream error',
      () async {
        late PluginHostInvocation invocation;
        final failure = StateError('primary failure');
        final source = StreamController<int>(
          onCancel: () => Future<void>.error(StateError('cleanup failed')),
        );
        final check = expectLater(
          context.invokeStream<int>({}, (opened) {
            invocation = opened;
            return source.stream;
          }),
          emitsInOrder([emitsError(same(failure)), emitsDone]),
        );
        source.addError(failure);
        await check;
        expect(invocation.isClosed, isTrue);
        await source.close();
      },
    );

    test(
      'explicit cancellation reports cleanup failure after revocation',
      () async {
        late PluginHostInvocation invocation;
        final failure = StateError('cleanup failed');
        final source = StreamController<int>(
          onCancel: () => Future<void>.error(failure),
        );
        final subscription = context
            .invokeStream<int>({}, (opened) {
              invocation = opened;
              return source.stream;
            })
            .listen((_) {});
        final cancelling = subscription.cancel();
        expect(invocation.isClosed, isTrue);
        await expectLater(cancelling, throwsA(same(failure)));
        expectRevoked(await reverse(invocation));
        await source.close();
      },
    );

    test(
      'hanging nested cleanup is bounded and preserves the primary failure',
      () async {
        for (final fails in [false, true]) {
          late PluginHostInvocation invocation;
          final cleanup = Completer<void>();
          final source = StreamController<int>(
            sync: true,
            onCancel: () => cleanup.future,
          );
          final primary = StateError('primary');
          final errors = <Object>[];
          final subscription = context
              .invokeStream<int>({}, (opened) {
                invocation = opened;
                return source.stream;
              })
              .listen((_) {}, onError: (Object error) => errors.add(error));
          if (fails) source.addError(primary);
          final cancelling = subscription.cancel();
          expect(invocation.isClosed, isTrue);
          if (fails) {
            await cancelling.timeout(const Duration(seconds: 3));
            expect(errors, [same(primary)]);
          } else {
            await expectLater(
              cancelling.timeout(const Duration(seconds: 3)),
              throwsA(isA<TimeoutException>()),
            );
          }
          cleanup.completeError(StateError('late cleanup error'));
          await source.close();
        }
      },
    );

    for (final lateFailure in [false, true]) {
      test(
        'cancellation settles pending unary before producer cleanup (late error=$lateFailure)',
        () async {
          final result = Completer<Object?>();
          final dispatcher = _HostDispatcher(() => result.future);
          late PluginHostInvocation invocation;
          final events = <Object?>[];
          final subscription = context
              .invokeStream({'fixture': dispatcher}, (opened) {
                invocation = opened;
                return (context.channel as AdeleStreamChannel).stream(
                  'events',
                  {'context': opened.id, 'count': 2},
                );
              })
              .listen(events.add);
          await dispatcher.entered.future;
          final cancelling = subscription.cancel();
          expect(invocation.isClosed, isTrue);
          await cancelling.timeout(const Duration(seconds: 1));
          expect(result.isCompleted, isFalse);
          expectRevoked(await reverse(invocation));
          final responses = await connection.request('hostResponseCount', {});
          if (lateFailure) {
            result.completeError(StateError('late host failure'));
          } else {
            result.complete('late host value');
          }
          await dispatcher.settled.future;
          expect(await connection.request('hostResponseCount', {}), responses);
          expect(events, isEmpty);
          expect(dispatcher.calls, 1);
          expect(dispatcher.closed, isFalse);
          expect(connection.isClosed, isFalse);
          expect(host.isClosed, isFalse);
        },
      );
    }

    for (final failStream in [false, true]) {
      test(
        'terminal settlement releases pending unary calls (error=$failStream)',
        () async {
          final result = Completer<Object?>();
          final dispatcher = _HostDispatcher(() => result.future);
          late PluginHostInvocation invocation;
          final source = StreamController<int>();
          final failure = StateError('stream failed');
          final check = expectLater(
            context.invokeStream({'fixture': dispatcher}, (opened) {
              invocation = opened;
              return source.stream;
            }),
            emitsInOrder([
              if (failStream) emitsError(same(failure)),
              emitsDone,
            ]),
          );
          final pending = reverse(invocation);
          await dispatcher.entered.future;
          if (failStream) source.addError(failure);
          await source.close();
          await check;
          expect(invocation.isClosed, isTrue);
          expectRevoked(await pending.timeout(const Duration(seconds: 1)));
          expect(result.isCompleted, isFalse);
          result.completeError(StateError('late host failure'));
          await dispatcher.settled.future;
          expect(connection.isClosed, isFalse);
        },
      );
    }

    test(
      'cancelling one scope preserves another scope and unrelated connection',
      () async {
        final other = await connect({
          'extensionExposures': [_exposure('other', 'other-route')],
        }, pluginId: 'dev.adele.test.other');
        await activate(other);
        final otherContext = extensions.discover(_point).last.value.context;
        final dispatcher = _HostDispatcher(() async => 'live');
        final invocations = <PluginHostInvocation>[];
        final sources = <StreamController<int>>[];
        final subscriptions = <StreamSubscription<int>>[];
        for (final owner in [context, context, otherContext]) {
          final source = StreamController<int>();
          sources.add(source);
          subscriptions.add(
            owner
                .invokeStream({'fixture': dispatcher}, (opened) {
                  invocations.add(opened);
                  return source.stream;
                })
                .listen((_) {}),
          );
        }
        expectRevoked(await reverse(invocations.first, caller: other));
        await subscriptions.first.cancel();
        expectRevoked(await reverse(invocations.first));
        expect((await reverse(invocations[1]))['payload'], 'live');
        expect(
          (await reverse(invocations[2], caller: other))['payload'],
          'live',
        );
        for (final subscription in subscriptions) {
          await subscription.cancel();
        }
        for (final source in sources) {
          await source.close();
        }
        expect(connection.isClosed, isFalse);
        expect(other.isClosed, isFalse);
      },
    );

    test(
      'retirement fails a paused retained subscription and cannot retarget replacement',
      () async {
        final pendingResult = Completer<Object?>();
        final dispatcher = _HostDispatcher(() => pendingResult.future);
        late PluginHostInvocation invocation;
        var cancellations = 0;
        final source = StreamController<int>(
          sync: true,
          onCancel: () {
            expect(invocation.isClosed, isTrue);
            cancellations++;
          },
        );
        final errors = <Object>[];
        final events = <int>[];
        final done = Completer<void>();
        final subscription = context
            .invokeStream({'fixture': dispatcher}, (opened) {
              invocation = opened;
              return source.stream;
            })
            .listen(events.add, onError: errors.add, onDone: done.complete);
        subscription.pause();
        final pending = reverse(invocation);
        await dispatcher.entered.future;
        final retiring = activation.retire();
        expect(invocation.isClosed, isTrue);
        expectRevoked(await pending.timeout(const Duration(seconds: 1)));
        await retiring;
        expect(cancellations, 1);
        expect(errors, isEmpty);
        final replacement = await activate(connection);
        final next = extensions.discover(_point).single.value.context;
        expect(next, isNot(same(context)));
        source.add(99);
        subscription.resume();
        await done.future;
        expect(events, isEmpty);
        expect(errors, [isA<StaleExtensionBinding>()]);
        expectRevoked(await reverse(invocation));
        await expectLater(
          context.invokeStream({}, (_) => Stream.value(1)),
          emitsError(isA<StaleExtensionBinding>()),
        );
        expect(await next.invokeStream({}, (_) => Stream.value(2)).single, 2);
        pendingResult.complete('too late');
        await dispatcher.settled.future;
        await subscription.cancel();
        await source.close();
        await replacement.retire();
      },
    );

    test(
      'unlistened stale streams mint nothing with or without a replacement',
      () async {
        var operations = 0;
        Stream<int> retained() => context.invokeStream({}, (_) {
          operations++;
          return Stream.value(1);
        });
        final first = retained();
        final second = retained();
        await activation.close();
        await expectLater(first, emitsError(isA<StaleExtensionBinding>()));
        final replacement = await connect({
          'extensionExposures': [_exposure('first', 'configured')],
        });
        await activate(replacement);
        await expectLater(second, emitsError(isA<StaleExtensionBinding>()));
        expect(operations, 0);
        final next = extensions.discover(_point).single.value.context;
        expect(await next.invokeStream({}, (_) => Stream.value(2)).single, 2);
        await activation.close();
        expect(replacement.isClosed, isFalse);
      },
    );

    test(
      'retirement from onData revokes before deferred terminal delivery',
      () async {
        late PluginHostInvocation invocation;
        late Future<void> retiring;
        final source = StreamController<int>(sync: true);
        final errors = <Object>[];
        final done = Completer<void>();
        context
            .invokeStream<int>({}, (opened) {
              invocation = opened;
              return source.stream;
            })
            .listen(
              (_) {
                retiring = activation.retire();
                expect(invocation.isClosed, isTrue);
                expect(errors, isEmpty);
              },
              onError: errors.add,
              onDone: done.complete,
            );
        source.add(1);
        await retiring;
        await done.future;
        expect(errors, [isA<StaleExtensionBinding>()]);
        expect(extensions.discover(_point), isEmpty);
        expect(source.hasListener, isFalse);
        await source.close();
      },
    );

    for (final termination in [
      'connection close',
      'plugin failure',
      'host exit',
    ]) {
      test(
        '$termination revokes idle stream without waiting for source events',
        () async {
          late PluginHostInvocation invocation;
          final source = StreamController<int>();
          final stream = context.invokeStream<int>({}, (opened) {
            invocation = opened;
            return source.stream;
          });
          final check = expectLater(
            stream,
            emitsInOrder([emitsError(isA<StaleExtensionBinding>()), emitsDone]),
          );
          switch (termination) {
            case 'connection close':
              await connection.close();
            case 'plugin failure':
              await expectLater(
                connection.request('terminate', {}),
                throwsA(isA<PluginRemoteFailure>()),
              );
            case 'host exit':
              await host.close(graceful: false);
          }
          await check;
          expect(invocation.isClosed, isTrue);
          expect(source.hasListener, isFalse);
          await source.close();
        },
      );
    }
  });
}

Map<String, Object?> _exposure(String id, String context) => {
  'extensionPointId': _point.value,
  'extensionId': 'dev.adele.test.$id',
  'serviceId': 'testService',
  'configurationContext': context,
  'metadata': {'label': id},
};

const _capabilityExposure = {
  'providerId': 'dev.adele.test.provider',
  'capabilityId': 'dev.adele.test.capability',
  'capabilityMajorVersion': 1,
  'serviceId': 'testService',
  'displayName': 'Test',
  'configurationContext': 'default',
};

final class _Adapter implements RemoteExtensionAdapter<_Contribution> {
  @override
  ExtensionPoint<_Contribution> get point => _point;

  @override
  _Contribution createContribution(RemoteExtensionContext context) {
    if (context.exposure.metadata['label'] is! String ||
        context.exposure.metadata.length != 1) {
      throw const ExtensionContractException('Invalid test metadata.');
    }
    return _Contribution(context);
  }
}

final class _Contribution {
  _Contribution(this.context);
  final RemoteExtensionContext context;
  Future<Object?> call() async => context.channel.request('echo', {});
  Future<void> hold(Future<void> pending) => context.invoke({}, (_) => pending);
}

final class _HostDispatcher implements AdeleBackendDispatcher {
  _HostDispatcher(this.operation);

  final Future<Object?> Function() operation;
  final entered = Completer<void>();
  final settled = Completer<void>();
  var calls = 0;
  var closed = false;

  @override
  Future<Map<String, Object?>> dispatch(Map<Object?, Object?> request) async {
    calls++;
    if (!entered.isCompleted) entered.complete();
    try {
      return {
        'kind': 'response',
        'requestId': request['requestId'],
        'ok': true,
        'payload': await operation(),
      };
    } finally {
      if (!settled.isCompleted) settled.complete();
    }
  }

  @override
  Future<void> handle(
    Map<Object?, Object?> command,
    void Function(Map<String, Object?>) send,
  ) async => send(await dispatch(command));

  @override
  Future<void> close() async => closed = true;
}

// Self-contained framed host: generic activation tests do not need AOT compilation.
final _hostScript =
    '''
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
void send(Map<String, Object?> message) {
  final bytes = utf8.encode(jsonEncode({'protocolVersion': $backendHostProtocolVersion, ...message}));
  final length = ByteData(4)..setUint32(0, bytes.length);
  stdout.add([...length.buffer.asUint8List(), ...bytes]);
}
void main() {
  send({'kind': 'hostHello'});
  var buffer = <int>[];
  final generations = <String, String>{};
  final pending = <int, Map<String, dynamic>>{};
  final streams = <int, Map<String, dynamic>>{};
  var nextHostRequest = 0;
  var hostResponses = 0;
  void reverse(Map<String, dynamic> message) {
    final id = nextHostRequest++;
    pending[id] = message;
    send({'kind': 'hostRequest', 'requestId': id, 'pluginId': message['pluginId'],
      'generation': generations[message['pluginId']],
      'hostInvocationContext': message['payload']['context'],
      'serviceId': message['payload']['service'] ?? 'fixture', 'method': 'fixture.read', 'payload': {}});
  }
  void cancel(Map<String, dynamic> stream) {
    if (stream['pending'] == true) return;
    streams.remove(stream['requestId']);
    send({'kind': 'streamCancelled', 'requestId': stream['requestId'], 'pluginId': stream['pluginId']});
  }
  stdin.listen((bytes) {
    buffer.addAll(bytes);
    while (buffer.length >= 4) {
      final length = ByteData.sublistView(Uint8List.fromList(buffer), 0, 4).getUint32(0);
      if (buffer.length < length + 4) break;
      final message = jsonDecode(utf8.decode(buffer.sublist(4, 4 + length))) as Map<String, dynamic>;
      buffer = buffer.sublist(4 + length);
      final route = {'requestId': message['requestId'], 'pluginId': message['pluginId'], 'generation': message['generation']};
      switch (message['kind']) {
        case 'startPlugin':
          generations[message['pluginId']] = message['generation'];
          send({'kind': 'pluginReady', ...route, ...jsonDecode(message['arguments'][0]) as Map<String,dynamic>});
        case 'stopPlugin':
          send({'kind': 'pluginStopped', ...route});
        case 'request':
          if (message['method'] == 'reverse') {
            reverse(message);
          } else if (message['method'] == 'terminate') {
            send({'kind': 'pluginFailed', 'pluginId': message['pluginId'], 'error': {'code': 'plugin_exited', 'message': 'Fixture terminated'}});
          } else {
            send({'kind': 'response', ...route, 'ok': true, 'payload': message['method'] == 'hostResponseCount' ? hostResponses : {'configurationContext': message['configurationContext'], 'serviceId': message['serviceId']}});
          }
        case 'streamOpen':
          streams[message['requestId']] = message..['remaining'] = message['payload']['count'];
        case 'streamCredit':
          final stream = streams[message['requestId']];
          if (stream == null || stream['cancelled'] == true) continue;
          if (stream['remaining'] == 0) {
            streams.remove(message['requestId']);
            send({'kind': 'streamDone', 'requestId': message['requestId'], 'pluginId': message['pluginId']});
          } else {
            stream['remaining']--;
            stream['pending'] = true;
            reverse(stream);
          }
        case 'streamCancel':
          send({'kind': 'streamCancelForwarded', 'requestId': message['requestId'], 'pluginId': message['pluginId']});
          final stream = streams[message['requestId']];
          if (stream != null) {
            stream['cancelled'] = true;
            cancel(stream);
          }
        case 'hostResponse':
          hostResponses++;
          final original = pending.remove(message['requestId']);
          if (original == null) continue;
          if (original['kind'] == 'request') {
            send({'kind': 'response', 'requestId': original['requestId'], 'pluginId': original['pluginId'], 'ok': true, 'payload': message});
          } else {
            original['pending'] = false;
            if (original['cancelled'] == true) {
              cancel(original);
            } else if (message['ok'] == true) {
              send({'kind': 'streamItem', 'requestId': original['requestId'], 'pluginId': original['pluginId'], 'payload': {
                'value': message['payload'], 'configurationContext': original['configurationContext'], 'serviceId': original['serviceId']}});
            }
          }
        case 'shutdownHost':
          send({'kind': 'hostStopped', 'requestId': message['requestId']});
          exit(0);
      }
    }
  });
}
''';
