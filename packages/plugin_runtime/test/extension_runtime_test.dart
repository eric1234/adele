import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:adele_capabilities/adele_capabilities.dart';
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
          send({'kind': 'pluginReady', ...route, ...jsonDecode(message['arguments'][0]) as Map<String,dynamic>});
        case 'stopPlugin':
          send({'kind': 'pluginStopped', ...route});
        case 'request':
          send({'kind': 'response', ...route, 'ok': true, 'payload': {'configurationContext': message['configurationContext'], 'serviceId': message['serviceId']}});
        case 'shutdownHost':
          send({'kind': 'hostStopped', 'requestId': message['requestId']});
          exit(0);
      }
    }
  });
}
''';
