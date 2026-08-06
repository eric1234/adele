import 'package:adele_capabilities/adele_capabilities.dart';
import 'package:test/test.dart';

void main() {
  final CapabilityKey capability = CapabilityKey(
    id: CapabilityId('dev.adele.resource.inspect'),
    majorVersion: 1,
  );

  test('requires a positive major version', () {
    expect(
      () => CapabilityKey(
        id: CapabilityId('dev.adele.resource.inspect'),
        majorVersion: 0,
      ),
      throwsA(isA<InvalidCapabilityVersion>()),
    );
  });

  test('ProviderId validates the public identifier grammar', () {
    expect(
      ProviderId('dev.adele.inspector.basic').value,
      'dev.adele.inspector.basic',
    );
    expect(
      () => ProviderId('dev.adele.inspector-basic'),
      throwsA(isA<InvalidCapabilityIdentity>()),
    );
  });

  test('discovers zero, one, and many providers immutably', () async {
    final CapabilityRegistry registry = CapabilityRegistry();
    expect(registry.providersFor(capability), isEmpty);

    final CapabilityRegistration first = registry.register(
      provider: _provider(capability, 'dev.adele.inspector.zulu'),
      endpoint: _Endpoint(),
    );
    final List<ProviderDescriptor> snapshot = registry.providersFor(capability);
    registry.register(
      provider: _provider(capability, 'dev.adele.inspector.alpha'),
      endpoint: _Endpoint(),
    );

    expect(snapshot.map((ProviderDescriptor value) => value.id.value), <String>[
      'dev.adele.inspector.zulu',
    ]);
    expect(
      () => snapshot.add(_provider(capability, 'dev.adele.inspector.extra')),
      throwsUnsupportedError,
    );
    expect(
      registry
          .providersFor(capability)
          .map((ProviderDescriptor value) => value.id.value),
      <String>['dev.adele.inspector.alpha', 'dev.adele.inspector.zulu'],
    );
    await first.close();
    await first.close();
    expect(first.isClosed, isTrue);
  });

  test('orders by descending rank then lexical provider ID', () {
    final CapabilityRegistry registry = CapabilityRegistry();
    for (final ProviderDescriptor provider in <ProviderDescriptor>[
      _provider(capability, 'dev.adele.inspector.zulu', rank: 10),
      _provider(capability, 'dev.adele.inspector.beta', rank: 20),
      _provider(capability, 'dev.adele.inspector.alpha', rank: 20),
    ]) {
      registry.register(provider: provider, endpoint: _Endpoint());
    }
    expect(
      registry
          .providersFor(capability)
          .map((ProviderDescriptor value) => value.id.value),
      <String>[
        'dev.adele.inspector.alpha',
        'dev.adele.inspector.beta',
        'dev.adele.inspector.zulu',
      ],
    );
    expect(
      registry.resolve(capability).provider.id.value,
      'dev.adele.inspector.alpha',
    );
  });

  test('default ordering is independent of registration order', () {
    List<String> discover(List<String> ids) {
      final CapabilityRegistry registry = CapabilityRegistry();
      for (final String id in ids) {
        registry.register(
          provider: _provider(capability, id),
          endpoint: _Endpoint(),
        );
      }
      return registry
          .providersFor(capability)
          .map((ProviderDescriptor value) => value.id.value)
          .toList();
    }

    expect(
      discover(<String>[
        'dev.adele.inspector.zulu',
        'dev.adele.inspector.alpha',
      ]),
      discover(<String>[
        'dev.adele.inspector.alpha',
        'dev.adele.inspector.zulu',
      ]),
    );
  });

  test('supports explicit resolution without fallback', () {
    final CapabilityRegistry registry = CapabilityRegistry();
    registry.register(
      provider: _provider(capability, 'dev.adele.inspector.alpha'),
      endpoint: _Endpoint(),
    );
    expect(
      registry
          .resolve(
            capability,
            providerId: ProviderId('dev.adele.inspector.alpha'),
          )
          .provider
          .id
          .value,
      'dev.adele.inspector.alpha',
    );
    expect(
      () => registry.resolve(
        capability,
        providerId: ProviderId('dev.adele.inspector.missing'),
      ),
      throwsA(
        isA<ProviderUnavailable>().having(
          (ProviderUnavailable value) => value.availableProviderIds,
          'availableProviderIds',
          <Object>[ProviderId('dev.adele.inspector.alpha')],
        ),
      ),
    );
  });

  test('distinguishes no provider and exact major mismatch', () {
    final CapabilityRegistry registry = CapabilityRegistry();
    registry.register(
      provider: _provider(capability, 'dev.adele.inspector.alpha'),
      endpoint: _Endpoint(),
    );
    expect(
      () => registry.resolve(CapabilityKey(id: capability.id, majorVersion: 2)),
      throwsA(isA<CapabilityUnavailable>()),
    );
  });

  test('rejects duplicate providers and service mismatch', () {
    final CapabilityRegistry registry = CapabilityRegistry();
    final ProviderDescriptor provider = _provider(
      capability,
      'dev.adele.inspector.alpha',
    );
    registry.register(provider: provider, endpoint: _Endpoint());
    expect(
      () => registry.register(provider: provider, endpoint: _Endpoint()),
      throwsA(isA<DuplicateProviderRegistration>()),
    );
    expect(
      () => CapabilityRegistry().register(
        provider: provider,
        endpoint: _Endpoint(serviceId: 'wrong'),
      ),
      throwsA(isA<CapabilityContractMismatch>()),
    );
  });

  test('registration groups roll back partial activation', () async {
    final CapabilityRegistry registry = CapabilityRegistry();
    final CapabilityRegistrationGroup group = CapabilityRegistrationGroup();
    group.add(
      registry.register(
        provider: _provider(capability, 'dev.adele.inspector.alpha'),
        endpoint: _Endpoint(),
      ),
    );
    try {
      group.add(
        registry.register(
          provider: _provider(capability, 'dev.adele.inspector.alpha'),
          endpoint: _Endpoint(),
        ),
      );
      fail('Duplicate registration should fail.');
    } on DuplicateProviderRegistration {
      await group.close();
    }
    expect(registry.providersFor(capability), isEmpty);
  });

  test('stale binding cannot target a restarted provider', () async {
    final CapabilityRegistry registry = CapabilityRegistry();
    final ProviderDescriptor provider = _provider(
      capability,
      'dev.adele.inspector.alpha',
    );
    final _Endpoint firstEndpoint = _Endpoint();
    final CapabilityRegistration first = registry.register(
      provider: provider,
      endpoint: firstEndpoint,
    );
    final ProviderBinding stale = registry.resolve(capability);
    await first.close();
    final _Endpoint secondEndpoint = _Endpoint();
    registry.register(provider: provider, endpoint: secondEndpoint);

    expect(
      () => stale.endpointAs<_Endpoint>(),
      throwsA(
        isA<ProviderUnavailable>().having(
          (ProviderUnavailable value) => value.stale,
          'stale',
          isTrue,
        ),
      ),
    );
    expect(
      registry.resolve(capability).endpointAs<_Endpoint>(),
      secondEndpoint,
    );
  });
}

ProviderDescriptor _provider(
  CapabilityKey capability,
  String id, {
  int rank = 0,
}) => ProviderDescriptor(
  id: ProviderId(id),
  capability: capability,
  pluginId: 'dev.adele.plugin',
  displayName: id,
  serviceId: 'resourceInspector',
  rank: rank,
);

final class _Endpoint implements CapabilityEndpoint {
  _Endpoint({this.serviceId = 'resourceInspector'});

  @override
  final String serviceId;

  @override
  bool get isAvailable => true;
}
