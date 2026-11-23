import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:adele_capabilities/adele_capabilities.dart';
import 'package:adele_contract/adele_contract.dart';
import 'package:adele_desktop/core/application_plugin_bootstrap.dart';
import 'package:adele_desktop/frontend/capability_access_bridge.dart';
import 'package:adele_desktop/frontend/structured_bridge_data.dart';
import 'package:adele_plugin_api/adele_plugin_api.dart';
import 'package:contract_codegen/contract_codegen.dart';
import 'package:dart_eval/dart_eval.dart';
import 'package:dart_eval/stdlib/core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plugin_runtime/plugin_runtime.dart';

const _observed = 'test.observed';
const _callable = 'test.associated';
const _service = 'test.provider';
const _plugin = 'test.provider-plugin';
final _grant = PreparedAssociatedCapabilityAccess(
  capability: CapabilityKey(id: CapabilityId(_observed), majorVersion: 1),
  serviceId: 'observed',
  associatedCapability: CapabilityKey(
    id: CapabilityId(_callable),
    majorVersion: 1,
  ),
  associatedServiceId: _service,
);

void main() {
  late CapabilityRegistry registry;
  late ApplicationPluginBootstrap bootstrap;
  late CapabilityAccessBridge bridge;
  late PluginBackendConnection backend;

  CapabilityAccessBridge scope({
    Iterable<PreparedAssociatedCapabilityAccess>? grants,
  }) {
    final result = CapabilityAccessBridge(
      registry: registry,
      capabilities: const [],
      associatedAccess: grants ?? [_grant],
      backendForProvider: bootstrap.backendForProvider,
      isActive: () => true,
    );
    addTearDown(result.invalidate);
    return result;
  }

  setUp(() async {
    registry = CapabilityRegistry();
    bootstrap = ApplicationPluginBootstrap(registry, ExtensionRegistry());
    final root = await Directory.systemTemp.createTemp('associated-access-');
    addTearDown(() => root.delete(recursive: true));
    addTearDown(bootstrap.close);
    final installation = await Directory('${root.path}/provider').create();
    await File('${installation.path}/backend.aot').writeAsString('scripted');
    await File(
      '${installation.path}/adele_plugin.installation.json',
    ).writeAsString(
      jsonEncode({
        'manifestVersion': 1,
        'metadata': {'id': _plugin, 'version': '1', 'displayName': 'Provider'},
        'components': {
          'backend': {'artifact': 'backend.aot'},
        },
      }),
    );
    await bootstrap.start(
      installationRoot: root.path,
      dartaotruntimeExecutable:
          '${Platform.environment['FLUTTER_ROOT']!}/bin/cache/dart-sdk/bin/${Platform.isWindows ? 'dart.exe' : 'dart'}',
      hostArtifactPath: File(
        'test/core/fixtures/backend_capability_scripted_host.dart',
      ).absolute.path,
      startupArguments: {
        _plugin: [
          jsonEncode({
            'capabilityExposures': [
              _exposure('test.a', observed: true),
              _exposure('test.b', observed: true),
              _exposure('test.c', observed: true),
              _exposure('test.wrong-service', observed: true, service: 'other'),
              _exposure('test.for-a', target: 'test.a'),
              _exposure('test.for-b', target: 'test.b'),
              _exposure('test.second-b', target: 'test.b', rank: 99),
              // Matching ID, backend, name and context are not an association.
              _exposure('test.c'),
              _exposure('test.wrong-major', major: 2, target: 'test.c'),
              _exposure(
                'test.other-service',
                service: 'other',
                target: 'test.c',
              ),
            ],
          }),
        ],
      },
    );
    final activation = bootstrap.backends.single;
    expect(
      activation.state,
      InstalledBackendState.active,
      reason: '${activation.failure}',
    );
    backend = activation.connection!;
    bridge = scope();
  });

  List<Map<String, Object?>>? observe(
    CapabilityAccessBridge scope,
    bool capture,
  ) => scope.observeAssociatedProviders(
    _observed,
    1,
    'observed',
    _callable,
    1,
    _service,
    capture,
  );
  String capture() => observe(bridge, true)!.first['handle'] as String;

  test(
    'exact declaration only: no direct service, implicit discovery, or activation',
    () {
      for (final capture in [true, false]) {
        expect(observe(scope(grants: []), capture), isNull);
        for (final (id, major, service, peer, peerMajor, peerService) in [
          (_callable, 1, _service, _observed, 1, 'observed'),
          (_observed, 2, 'observed', _callable, 1, _service),
          (_observed, 1, 'observed', _callable, 2, _service),
          (_observed, 1, 'other', _callable, 1, _service),
          (_observed, 1, 'observed', _callable, 1, 'private'),
        ]) {
          expect(
            bridge.observeAssociatedProviders(
              id,
              major,
              service,
              peer,
              peerMajor,
              peerService,
              capture,
            ),
            isNull,
          );
        }
      }
      for (final (id, service) in [
        (_observed, 'observed'),
        (_callable, _service),
      ]) {
        expect(bridge.discover(id, 1), isNull);
        expect(bridge.resolve(id, 1, service, null), isNull);
      }
    },
  );

  test(
    'observations retain nothing; ambiguous and absent pairs expose no channel',
    () async {
      final expected = [
        for (final id in ['test.a', 'test.b', 'test.c'])
          {'providerId': id, 'displayName': 'Same label'},
      ];
      final grants = [_grant];
      final editor = scope(grants: grants);
      grants.clear();
      for (var i = 0; i <= CapabilityAccessBridge.maxHandles; i++) {
        expect(observe(editor, false), expected);
      }
      final handles = <String>[];
      for (var i = 0; i < CapabilityAccessBridge.maxHandles; i++) {
        final entries = observe(editor, true)!;
        final handle = entries.first['handle'] as String;
        expect(entries, [
          {...expected[0], 'status': 'ready', 'handle': handle},
          {...expected[1], 'status': 'ambiguous'},
          {...expected[2], 'status': 'missing'},
        ]);
        handles.add(handle);
      }
      expect(observe(editor, true)!.first, {...expected[0], 'status': 'limit'});
      expect(observe(editor, false), expected);
      expect(await backend.request('fixture.calls', {}), isEmpty);
      expect(bridge.release(handles.first), isFalse);
      expect(bridge.isCapabilityProviderCurrent(handles.first), isFalse);
      expect(editor.release(handles.first), isTrue);
      final fresh = observe(editor, true)!.first['handle'] as String;
      expect(handles, isNot(contains(fresh)));
      expect(editor.isCapabilityProviderCurrent(handles.first), isFalse);
      expect(editor.isCapabilityProviderCurrent(fresh), isTrue);
    },
  );

  test('metadata bounds preserve exact identity and healthy providers', () {
    final registrations = CapabilityRegistrationGroup();
    addTearDown(registrations.close);
    final original = registry.resolveExact(
      _grant.capability,
      ProviderId('test.a'),
    );
    final endpoint = original.endpointAs<CapabilityEndpoint>();
    void add(String id, String label) => registrations.add(
      registry.register(
        provider: ProviderDescriptor(
          id: ProviderId(id),
          capability: _grant.capability,
          pluginId: _plugin,
          displayName: label,
          serviceId: 'observed',
        ),
        endpoint: endpoint,
      ),
    );
    final huge = 'x' * (CapabilityAccessBridge.maxMetadataLength + 1);
    add('test.long-label', huge);
    add('test.$huge', 'must not truncate an identity');
    final entries = observe(bridge, false)!;
    expect(entries, hasLength(4));
    expect(entries.last, {
      'providerId': 'test.long-label',
      'displayName': 'test.long-label',
    });
    for (
      var i = entries.length;
      i <= CapabilityAccessBridge.maxObservedProviders;
      i++
    ) {
      add('test.extra$i', 'Extra');
    }
    expect(observe(bridge, false), isNull);
    expect(observe(bridge, true), isNull);
  });

  test('only a fresh capture can use a previously ambiguous pair', () async {
    final before = observe(bridge, true)!;
    final a = before.first['handle'] as String;
    expect(before[1]['status'], 'ambiguous');
    expect(before[1], isNot(containsPair('handle', anything)));
    final duplicate = registry.resolveExact(
      _grant.associatedCapability,
      ProviderId('test.second-b'),
    );
    await bootstrap.backendForProvider(duplicate)!.retireProvider(duplicate);
    final b = observe(bridge, true)![1]['handle'] as String;
    expect(a, isNot(b));
    expect(bridge.isCapabilityProviderCurrent(a), isTrue);
    expect(bridge.isCapabilityProviderCurrent(b), isTrue);
    final first = registry.resolveExact(
      _grant.associatedCapability,
      ProviderId('test.for-b'),
    );
    await bootstrap.backendForProvider(first)!.retireProvider(first);
    expect(bridge.isCapabilityProviderCurrent(a), isTrue);
    expect(bridge.isCapabilityProviderCurrent(b), isFalse);
    expect(await backend.request('fixture.calls', {}), isEmpty);
  });

  test(
    'only valid unary methods in the captured associated service are invoked',
    () async {
      final handle = capture();
      for (final method in [
        'shutdown',
        'observed.read',
        'test.private.echo',
        '$_service..read',
      ]) {
        await expectLater(
          bridge.request(handle, method, {}),
          throwsA(anything),
        );
      }
      await expectLater(
        bridge.stream(handle, '$_service.watch', {}),
        emitsError(isA<StateError>()),
      );
      expect(await backend.request('fixture.calls', {}), isEmpty);
      final payload = {
        'serviceId': 'observed',
        'configurationContext': 'elsewhere',
        'hostInvocationContext': 'invented',
      };
      expect(await bridge.request(handle, '$_service.echo', payload), {
        'pluginId': _plugin,
        'configurationContext': 'shared',
        'serviceId': _service,
        'payload': payload,
        'hasHostInvocationContext': false,
      });
    },
  );

  for (final retire in [
    'observed',
    'callable',
    'release',
    'editor',
    'backend',
  ]) {
    test(
      '$retire fences pending publication and confirmation without migration',
      () async {
        final handle = capture();
        final check = expectLater(
          bridge.request(handle, '$_service.hold', {'gate': 'hold'}),
          throwsA(anything),
        );
        await backend.request('fixture.waitHeld', {'gate': 'hold'});
        if (retire == 'observed' || retire == 'callable') {
          final observed = retire == 'observed';
          final binding = registry.resolveExact(
            observed ? _grant.capability : _grant.associatedCapability,
            ProviderId(observed ? 'test.a' : 'test.for-a'),
          );
          final endpoint = binding.endpointAs<AdeleRequestChannelEndpoint>();
          await bootstrap.backendForProvider(binding)!.retireProvider(binding);
          final impostor = registry.register(
            provider: binding.provider,
            endpoint: endpoint,
          );
          addTearDown(impostor.close);
          expect(impostor.binding.isSameRegistration(binding), isFalse);
          expect(observe(bridge, true)!.first['status'], 'missing');
        } else if (retire == 'release') {
          expect(bridge.release(handle), isTrue);
        } else if (retire == 'editor') {
          bridge.invalidate();
        } else {
          await backend.close();
        }
        if (retire != 'backend') {
          await backend.request('fixture.finishHeld', {'gate': 'hold'});
        }
        await check;
        expect(bridge.isCapabilityProviderCurrent(handle), isFalse);
        await expectLater(
          bridge.request(handle, '$_service.echo', {}),
          throwsStateError,
        );
      },
    );
  }

  test(
    'released in-flight requests keep their slots until backend settlement',
    () async {
      final checks = <Future<void>>[];
      for (var i = 0; i < CapabilityAccessBridge.maxAssociatedPending; i++) {
        final handle = capture();
        checks.add(
          expectLater(
            bridge.request(handle, '$_service.hold', {'gate': '$i'}),
            throwsStateError,
          ),
        );
        expect(bridge.release(handle), isTrue);
      }
      final fresh = capture();
      await expectLater(
        bridge.request(fresh, '$_service.echo', {}),
        throwsStateError,
      );
      expect(
        await backend.request('fixture.calls', {}),
        hasLength(checks.length),
      );
      for (var i = 0; i < checks.length; i++) {
        await backend.request('fixture.finishHeld', {'gate': '$i'});
        await checks[i];
      }
      expect(
        await bridge.request(fresh, '$_service.echo', {}),
        isA<Map<String, Object?>>(),
      );
    },
  );

  test(
    'EVC settlement matches only caller-known declared failures, never diagnostics',
    () async {
      const lib = 'package:probe/consumer.dart';
      final compiler = Compiler()
        ..addPlugin(const CapabilityAccessDeclarations())
        ..entrypoints.add(lib);
      final program = compiler.compile({
        'adele_ui': {
          'capability_bridge.dart': await File(
            '../packages/ui/lib/capability_bridge.dart',
          ).readAsString(),
        },
        'adele_contract': {'adele_contract.dart': evalContractSupportSource},
        'probe': {
          'consumer.dart': '''
import 'package:adele_ui/capability_bridge.dart';
Future<List<dynamic>> probe(String handle, String method, String type, String code) {
  return settleCapabilityOperation(CapabilityRequestChannel(handle).request(method, {}), type, code);
}
Future<List<dynamic>> ordinary(String handle) {
  return settleCapabilityOperation(CapabilityRequestChannel(handle).request('test.provider.declaredFailure', {}));
}
''',
        },
      });
      final runtime = Runtime(ByteData.sublistView(program.write()))
        ..addPlugin(bridge);
      final handle = $String(capture());
      for (final (method, type, code, expected) in [
        ('declaredFailure', 'test.ProviderFailure', 'denied', 'denied'),
        ('declaredFailure', 'other.failure', 'denied', null),
        ('declaredFailure', 'test.ProviderFailure', 'other', null),
        ('unexpectedFailure', 'test.ProviderFailure', 'internal_error', null),
      ]) {
        final settled = await runtime.executeLib(lib, 'probe', [
          handle,
          $String('$_service.$method'),
          $String(type),
          $String(code),
        ]);
        expect(copyStructuredBridgeData(settled), [false, expected]);
      }
      expect(
        copyStructuredBridgeData(
          await runtime.executeLib(lib, 'ordinary', [handle]),
        ),
        [false, null],
      );
    },
  );
}

Map<String, Object?> _exposure(
  String id, {
  bool observed = false,
  String? target,
  int major = 1,
  String? service,
  int rank = 0,
}) => AdeleCapabilityExposure(
  capabilityId: observed ? _observed : _callable,
  capabilityMajorVersion: major,
  providerId: id,
  serviceId: service ?? (observed ? 'observed' : _service),
  configurationContext: 'shared',
  displayName: 'Same label',
  rank: rank,
  association: target == null
      ? null
      : AdeleProviderAssociation(
          capabilityId: _observed,
          capabilityMajorVersion: 1,
          providerId: target,
        ),
).toMap();
