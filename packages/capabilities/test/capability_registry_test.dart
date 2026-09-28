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

  test(
    'ownership uses exact registrations across discovery and replacement',
    () async {
      final registry = CapabilityRegistry();
      final provider = _provider(capability, 'dev.adele.inspector.alpha');
      final endpoint = _Endpoint();
      final group = CapabilityRegistrationGroup();
      final registration = registry.register(
        provider: provider,
        endpoint: endpoint,
      );
      group.add(registration);
      final first = registry.resolve(capability);
      final second = registry.resolve(capability);
      expect(first.isSameRegistration(second), isTrue);
      expect(registration.owns(second), isTrue);
      expect(group.owns(second), isTrue);
      final foreign = CapabilityRegistry()
        ..register(provider: provider, endpoint: endpoint);
      expect(registration.owns(foreign.resolve(capability)), isFalse);
      await registration.close();
      final replacement = registry.register(
        provider: provider,
        endpoint: endpoint,
      );
      final fresh = registry.resolve(capability);
      expect(first.isSameRegistration(fresh), isFalse);
      expect(registration.owns(first), isTrue);
      expect(replacement.owns(first), isFalse);
      expect(group.owns(fresh), isFalse);
      expect(
        () => first.endpointAs<CapabilityEndpoint>(),
        throwsA(isA<ProviderUnavailable>()),
      );
    },
  );

  test('ProviderId validates the public identifier grammar', () {
    expect(
      ProviderId('dev.adele.inspector.basic').value,
      'dev.adele.inspector.basic',
    );
    expect(
      () => ProviderId('dev.adele.inspector_basic'),
      throwsA(isA<InvalidCapabilityIdentity>()),
    );
  });

  test(
    'retirement observers fence synchronously and stay generation-local',
    () async {
      final registry = CapabilityRegistry();
      final descriptor = _provider(capability, 'dev.adele.inspector.alpha');
      final registration = registry.register(
        provider: descriptor,
        endpoint: _Endpoint(),
      );
      final binding = registry.resolve(capability);
      var retired = 0;
      final detach = binding.onRetire(() => fail('Detached observer called.'));
      detach();
      detach();
      binding.onRetire(() {
        expect(registration.isClosed, isTrue);
        expect(registry.providersFor(capability), isEmpty);
        expect(
          () => binding.endpointAs<CapabilityEndpoint>(),
          throwsA(isA<ProviderUnavailable>()),
        );
        retired++;
      });
      final closing = registration.close();
      expect(retired, 1);
      await closing;
      final replacement = registry.register(
        provider: descriptor,
        endpoint: _Endpoint(),
      );
      var replacementRetired = false;
      registry.resolve(capability).onRetire(() => replacementRetired = true);
      await registration.close();
      expect(retired, 1);
      expect(replacementRetired, isFalse);
      expect(
        () => binding.onRetire(() {}),
        throwsA(isA<ProviderUnavailable>()),
      );
      await replacement.close();
      expect(replacementRetired, isTrue);
    },
  );

  test('throwing retirement observer does not skip sibling fences', () async {
    final registry = CapabilityRegistry();
    final registration = registry.register(
      provider: _provider(capability, 'dev.adele.inspector.alpha'),
      endpoint: _Endpoint(),
    );
    final binding = registry.resolve(capability);
    binding.onRetire(() => throw StateError('Observer failed.'));
    var fenced = false;
    binding.onRetire(() => fenced = true);
    final closing = registration.close();
    expect(fenced, isTrue);
    expect(registration.isClosed, isTrue);
    await expectLater(closing, throwsStateError);
    await registration.close();
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

  test('distinguishes missing capability and unavailable major version', () {
    final CapabilityRegistry registry = CapabilityRegistry();
    registry.register(
      provider: _provider(capability, 'dev.adele.inspector.alpha'),
      endpoint: _Endpoint(),
    );
    expect(
      () => registry.resolve(CapabilityKey(id: capability.id, majorVersion: 2)),
      throwsA(
        isA<CapabilityVersionUnavailable>()
            .having(
              (CapabilityVersionUnavailable value) =>
                  value.requestedMajorVersion,
              'requestedMajorVersion',
              2,
            )
            .having(
              (CapabilityVersionUnavailable value) =>
                  value.availableMajorVersions,
              'availableMajorVersions',
              <int>[1],
            ),
      ),
    );
    expect(
      () => registry.resolve(
        CapabilityKey(id: capability.id, majorVersion: 2),
        providerId: ProviderId('dev.adele.inspector.alpha'),
      ),
      throwsA(
        isA<CapabilityVersionUnavailable>().having(
          (CapabilityVersionUnavailable value) => value.availableMajorVersions,
          'availableMajorVersions',
          <int>[1],
        ),
      ),
    );
    expect(
      () => registry.resolve(
        CapabilityKey(
          id: CapabilityId('dev.adele.resource.nonexistent'),
          majorVersion: 1,
        ),
      ),
      throwsA(isA<CapabilityUnavailable>()),
    );
    expect(
      () => registry.resolve(
        CapabilityKey(
          id: CapabilityId('dev.adele.resource.nonexistent'),
          majorVersion: 2,
        ),
        providerId: ProviderId('dev.adele.inspector.alpha'),
      ),
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

  test(
    'group retires every registration before reporting observer failure',
    () async {
      final registry = CapabilityRegistry();
      final group = CapabilityRegistrationGroup();
      final bindings = <ProviderBinding>[];
      final visited = <int>[];
      final error = StateError('Last registered observer failed.');
      final stack = StackTrace.fromString('original retirement observer stack');
      for (var index = 0; index < 3; index++) {
        final provider = _provider(
          capability,
          'dev.adele.inspector.instance-$index',
        );
        group.add(registry.register(provider: provider, endpoint: _Endpoint()));
        final binding = registry.resolve(capability, providerId: provider.id);
        bindings.add(binding);
        binding.onRetire(() {
          visited.add(index);
          if (index == 2) Error.throwWithStackTrace(error, stack);
          if (index == 1) {
            throw StateError('A later failure must not mask the first.');
          }
        });
      }
      try {
        await group.close();
        fail('The first observer error must remain observable.');
      } catch (caught, caughtStack) {
        expect(caught, same(error));
        expect(caughtStack.toString(), stack.toString());
        expect(visited, [2, 1, 0]);
        expect(registry.providersFor(capability), isEmpty);
        for (final binding in bindings) {
          expect(
            () => binding.endpointAs<CapabilityEndpoint>(),
            throwsA(
              isA<ProviderUnavailable>().having(
                (error) => error.stale,
                'stale',
                isTrue,
              ),
            ),
          );
        }
      }
      final replacement = registry.register(
        provider: bindings.last.provider,
        endpoint: _Endpoint(),
      );
      registry
          .resolve(capability)
          .onRetire(() => fail('Replacement was retired.'));
      await group.close();
      expect(visited, [2, 1, 0]);
      expect(replacement.isClosed, isFalse);
      expect(
        () => registry.resolve(capability).endpointAs<CapabilityEndpoint>(),
        returnsNormally,
      );
    },
  );

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
