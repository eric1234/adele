import 'dart:convert';
import 'dart:io';

import 'package:adele_capabilities/adele_capabilities.dart';
import 'package:adele_contract/adele_contract.dart';
import 'package:plugin_runtime/plugin_runtime.dart';
import 'package:test/test.dart';

void main() {
  final capability = CapabilityKey(
    id: CapabilityId('dev.adele.resource.inspect'),
    majorVersion: 1,
  );
  const firstExposure = <String, Object?>{
    'providerId': 'dev.adele.provider.first',
    'capabilityId': 'dev.adele.resource.inspect',
    'capabilityMajorVersion': 1,
    'serviceId': 'resourceInspector',
    'displayName': 'First provider',
    'configurationContext': 'opaque-first',
    'pluginId': 'dev.adele.spoofed',
  };
  final secondExposure = <String, Object?>{
    ...firstExposure,
    'providerId': 'dev.adele.provider.second',
    'configurationContext': 'opaque-second',
    'serviceId': 'otherService',
    'rank': 3,
  };
  final environment = CapabilityKey(
    id: CapabilityId('dev.adele.environment'),
    majorVersion: 1,
  );
  const environmentA = <String, Object?>{
    'providerId': 'dev.adele.environment.a',
    'capabilityId': 'dev.adele.environment',
    'capabilityMajorVersion': 1,
    'serviceId': 'environmentService',
    'displayName': 'Environment A',
    'configurationContext': 'shared',
  };
  const associationA = <String, Object?>{
    'capabilityId': 'dev.adele.environment',
    'capabilityMajorVersion': 1,
    'providerId': 'dev.adele.environment.a',
  };
  final associatedExposure = <String, Object?>{
    ...firstExposure,
    'configurationContext': 'shared',
    'association': associationA,
  };

  for (final advertised in [false, true]) {
    test(
      'exact sibling selection ignores shared routes and global rank, advertised=$advertised',
      () async {
        final fake = _FakeHost.create(
          contextEcho: true,
          readyFields: {
            'capabilityExposures': [
              for (final (id, rank) in [
                ('a-low', 0),
                ('a-second', 10),
                ('a-first', 10),
              ])
                {
                  ...associatedExposure,
                  'providerId': 'dev.adele.provider.$id',
                  'rank': rank,
                },
              {
                ...associatedExposure,
                'providerId': 'dev.adele.provider.b-top',
                'rank': 100,
                'association': {
                  ...associationA,
                  'providerId': 'dev.adele.environment.b',
                },
              },
              environmentA,
              {...environmentA, 'providerId': 'dev.adele.environment.b'},
              {...firstExposure, 'configurationContext': 'shared', 'rank': 200},
            ],
          },
        );
        addTearDown(fake.dispose);
        final host = await fake.start();
        addTearDown(host.close);
        final connection = await host.startPlugin(
          pluginId: 'dev.adele.provider',
          artifactUri: Uri.file('/unused.aot'),
        );
        final registry = CapabilityRegistry();
        final activation = advertised
            ? await PluginCapabilityActivation.registerAdvertised(
                connection: connection,
                registry: registry,
              )
            : await PluginCapabilityActivation.register(
                connection: connection,
                registry: registry,
                exposures: connection.capabilityExposures.map(
                  (exposure) => PluginCapabilityExposure(
                    provider: _provider(
                      CapabilityKey(
                        id: CapabilityId(exposure.capabilityId),
                        majorVersion: exposure.capabilityMajorVersion,
                      ),
                      exposure.providerId,
                      serviceId: exposure.serviceId,
                      rank: exposure.rank,
                    ),
                    configurationContext: connection.configurationContext(
                      exposure.configurationContext,
                    ),
                    association: exposure.association,
                  ),
                ),
              );
        final a = registry.resolve(
          environment,
          providerId: ProviderId('dev.adele.environment.a'),
        );
        final b = registry.resolve(
          environment,
          providerId: ProviderId('dev.adele.environment.b'),
        );
        final selected = activation.resolveAssociatedProvider(
          capability,
          associatedWith: a,
        );
        expect(selected.provider.id.value, 'dev.adele.provider.a-first');
        expect(
          activation.associationFor(selected)!.isSameRegistration(a),
          isTrue,
        );
        expect(activation.associationFor(a), isNull);
        expect(activation.associationFor(registry.resolve(capability)), isNull);
        expect(
          registry.resolve(capability).provider.id.value,
          firstExposure['providerId'],
          reason: 'Context-free selection still chooses the global default.',
        );
        expect(
          activation
              .resolveAssociatedProvider(capability, associatedWith: b)
              .provider
              .id
              .value,
          'dev.adele.provider.b-top',
        );
        expect(
          activation
              .resolveAssociatedProvider(
                capability,
                associatedWith: a,
                providerId: ProviderId('dev.adele.provider.a-low'),
              )
              .provider
              .id
              .value,
          'dev.adele.provider.a-low',
        );
        for (final id in [
          'dev.adele.provider.b-top',
          firstExposure['providerId']! as String,
          'dev.adele.provider.missing',
        ]) {
          expect(
            () => activation.resolveAssociatedProvider(
              capability,
              associatedWith: a,
              providerId: ProviderId(id),
            ),
            throwsA(
              isA<ProviderUnavailable>().having(
                (error) => error.availableProviderIds,
                'eligible providers',
                [
                  ProviderId('dev.adele.provider.a-first'),
                  ProviderId('dev.adele.provider.a-second'),
                  ProviderId('dev.adele.provider.a-low'),
                ],
              ),
            ),
          );
        }
        final otherMajor = CapabilityKey(id: capability.id, majorVersion: 2);
        expect(
          () => activation.resolveAssociatedProvider(
            otherMajor,
            associatedWith: a,
          ),
          throwsA(isA<CapabilityUnavailable>()),
        );
        expect(
          () => activation.resolveAssociatedProvider(
            otherMajor,
            associatedWith: a,
            providerId: selected.provider.id,
          ),
          throwsA(isA<ProviderUnavailable>()),
        );
        final foreign = CapabilityRegistry();
        for (final binding in [a, selected]) {
          foreign.register(
            provider: binding.provider,
            endpoint: binding.endpointAs<AdeleRequestChannelEndpoint>(),
          );
        }
        expect(activation.associationFor(foreign.resolve(capability)), isNull);
        expect(
          () => activation.resolveAssociatedProvider(
            capability,
            associatedWith: foreign.resolve(environment),
          ),
          throwsA(isA<InvalidProviderRegistration>()),
        );
        expect(await selected.requestChannel.request('inspect', const {}), {
          'configurationContext': 'shared',
          'serviceId': 'resourceInspector',
          'payload': <String, Object?>{},
        });
        await activation.close();
      },
    );
  }

  test(
    'invalid associations roll back only their lazy registration attempt',
    () async {
      final fake = _FakeHost.create();
      addTearDown(fake.dispose);
      final host = await fake.start();
      addTearDown(host.close);
      final connection = await host.startPlugin(
        pluginId: 'dev.adele.provider',
        artifactUri: Uri.file('/unused.aot'),
      );
      final registry = CapabilityRegistry();
      final retained = await PluginCapabilityActivation.register(
        connection: connection,
        registry: registry,
        exposures: [
          PluginCapabilityExposure(
            provider: _provider(environment, 'dev.adele.environment.foreign'),
            configurationContext: connection.defaultConfigurationContext,
          ),
        ],
      );
      final foreign = registry.resolve(environment);
      for (final invalid in [
        'missing',
        'major',
        'foreign',
        'self',
        'chain',
        'cycle',
      ]) {
        final target = AdeleProviderAssociation(
          capabilityId: invalid == 'self'
              ? capability.id.value
              : environment.id.value,
          capabilityMajorVersion: invalid == 'major' ? 2 : 1,
          providerId: switch (invalid) {
            'missing' => 'dev.adele.environment.missing',
            'foreign' => foreign.provider.id.value,
            'self' => 'dev.adele.provider.attempt',
            _ => 'dev.adele.environment.a',
          },
        );
        final visited = <String>[];
        Iterable<PluginCapabilityExposure> exposures() sync* {
          for (final exposure in [
            PluginCapabilityExposure(
              provider: _provider(capability, 'dev.adele.provider.attempt'),
              configurationContext: connection.defaultConfigurationContext,
              association: target,
            ),
            PluginCapabilityExposure(
              provider: _provider(environment, 'dev.adele.environment.a'),
              configurationContext: connection.defaultConfigurationContext,
              association: invalid == 'chain' || invalid == 'cycle'
                  ? AdeleProviderAssociation(
                      capabilityId: invalid == 'cycle'
                          ? capability.id.value
                          : environment.id.value,
                      capabilityMajorVersion: 1,
                      providerId: invalid == 'cycle'
                          ? 'dev.adele.provider.attempt'
                          : 'dev.adele.environment.b',
                    )
                  : null,
            ),
            PluginCapabilityExposure(
              provider: _provider(environment, 'dev.adele.environment.b'),
              configurationContext: connection.defaultConfigurationContext,
            ),
          ]) {
            yield exposure;
            registry
                .resolve(
                  exposure.provider.capability,
                  providerId: exposure.provider.id,
                )
                .onRetire(() => visited.add(exposure.provider.id.value));
          }
        }

        await expectLater(
          PluginCapabilityActivation.register(
            connection: connection,
            registry: registry,
            exposures: exposures(),
          ),
          throwsA(isA<InvalidProviderRegistration>()),
          reason: invalid,
        );
        expect(visited, [
          'dev.adele.environment.b',
          'dev.adele.environment.a',
          'dev.adele.provider.attempt',
        ]);
        expect(registry.providersFor(capability), isEmpty);
        expect(
          registry.resolve(environment).isSameRegistration(foreign),
          isTrue,
        );
        expect(connection.validateInfrastructureContext, returnsNormally);
      }
      await retained.close();
    },
  );

  test(
    'individual retirement uses exact registration ownership, not endpoint health',
    () async {
      final fake = _FakeHost.create(
        contextEcho: true,
        readyFields: {
          'capabilityExposures': [firstExposure],
        },
      );
      addTearDown(fake.dispose);
      final host = await fake.start();
      addTearDown(host.close);
      final connection = await host.startPlugin(
        pluginId: 'dev.adele.provider',
        artifactUri: Uri.file('/unused.aot'),
      );
      final registry = CapabilityRegistry();
      final activation = await PluginCapabilityActivation.registerAdvertised(
        connection: connection,
        registry: registry,
      );
      addTearDown(activation.close);
      final sibling = registry.resolve(capability);
      final provider = _provider(capability, 'dev.adele.provider.dynamic');
      var available = true;
      final endpoint = AdeleRequestChannelEndpoint(
        channel: sibling.requestChannel,
        serviceId: provider.serviceId,
        isAvailable: () => available,
      );
      final registration = registry.register(
        provider: provider,
        endpoint: endpoint,
      );
      // Advertised endpoints track connection closure. Adopt a dynamic endpoint
      // through the existing public owner group, without a production testing seam.
      activation.registrations.add(registration);
      final binding = registry.resolve(capability, providerId: provider.id);
      final foreignRegistry = CapabilityRegistry();
      final foreign = foreignRegistry.register(
        provider: provider,
        endpoint: endpoint,
      );
      addTearDown(foreign.close);
      final foreignBinding = foreignRegistry.resolve(capability);
      final stale = isA<ProviderUnavailable>().having(
        (error) => error.stale,
        'stale',
        isTrue,
      );
      var retirements = 0;
      var siblingRetirements = 0;
      sibling.onRetire(() => siblingRetirements++);
      binding.onRetire(() {
        retirements++;
        expect(registration.isClosed, isTrue);
        expect(() => activation.retireProvider(binding), throwsA(stale));
      });
      expect(activation.owns(binding), isTrue);

      available = false;
      expect(registration.isClosed, isFalse);
      expect(retirements, 0);
      expect(
        () => binding.requestChannel,
        throwsA(isA<ProviderEndpointUnavailable>()),
      );
      expect(
        () => activation.owns(binding),
        throwsA(isA<ProviderEndpointUnavailable>()),
      );
      expect(
        () => registry.resolve(capability, providerId: provider.id),
        throwsA(isA<ProviderUnavailable>()),
      );
      expect(
        () => activation.retireProvider(foreignBinding),
        throwsA(isA<InvalidProviderRegistration>()),
      );
      expect(foreign.isClosed, isFalse);

      final retiring = activation.retireProvider(binding);
      expect(registration.isClosed, isTrue);
      expect(retirements, 1);
      expect(siblingRetirements, 0);
      expect(() => binding.requestChannel, throwsA(stale));
      expect(activation.owns(sibling), isTrue);
      expect(connection.isClosed, isFalse);
      expect(connection.validateInfrastructureContext, returnsNormally);
      await retiring;
      expect(await sibling.requestChannel.request('inspect', const {}), {
        'configurationContext': 'opaque-first',
        'serviceId': 'resourceInspector',
        'payload': <String, Object?>{},
      });

      final replacement = registry.register(
        provider: provider,
        endpoint: sibling.endpointAs<AdeleRequestChannelEndpoint>(),
      );
      addTearDown(replacement.close);
      final fresh = registry.resolve(capability, providerId: provider.id);
      expect(fresh.isSameRegistration(binding), isFalse);
      expect(() => activation.retireProvider(binding), throwsA(stale));
      expect(
        () => activation.retireProvider(fresh),
        throwsA(isA<InvalidProviderRegistration>()),
      );
      expect(replacement.isClosed, isFalse);
      expect(retirements, 1);
      expect(siblingRetirements, 0);
      await activation.registrations.close();
      expect(
        () => activation.retireProvider(sibling),
        throwsA(isA<InvalidProviderRegistration>()),
      );
      expect(replacement.isClosed, isFalse);
      expect(connection.isClosed, isFalse);
    },
  );

  test(
    'individual retirement rejects a closing backend with a live registration',
    () async {
      final fake = _FakeHost.create(
        readyFields: {
          'capabilityExposures': [firstExposure],
        },
      );
      addTearDown(fake.dispose);
      final host = await fake.start();
      addTearDown(host.close);
      final connection = await host.startPlugin(
        pluginId: 'dev.adele.provider',
        artifactUri: Uri.file('/unused.aot'),
      );
      final registry = CapabilityRegistry();
      final activation = await PluginCapabilityActivation.registerAdvertised(
        connection: connection,
        registry: registry,
      );
      addTearDown(activation.close);
      final binding = registry.resolve(capability);
      var retirements = 0;
      binding.onRetire(() => retirements++);
      final closing = connection.close();
      expect(connection.isClosed, isTrue);
      expect(retirements, 0);
      final detach = binding.onRetire(() {});
      detach();
      expect(
        () => activation.retireProvider(binding),
        throwsA(isA<InvalidProviderRegistration>()),
      );
      expect(retirements, 0);
      await closing;
      await activation.retire();
      expect(retirements, 1);
    },
  );

  for (final closeConnection in [false, true]) {
    test(
      'retirement fences reentrant association selection, close=$closeConnection',
      () async {
        final fake = _FakeHost.create(
          contextEcho: true,
          readyFields: {
            'capabilityExposures': [
              associatedExposure,
              environmentA,
              secondExposure,
            ],
          },
        );
        addTearDown(fake.dispose);
        final host = await fake.start();
        addTearDown(host.close);
        final connection = await host.startPlugin(
          pluginId: 'dev.adele.provider',
          artifactUri: Uri.file('/unused.aot'),
        );
        final registry = CapabilityRegistry();
        final activation = await PluginCapabilityActivation.registerAdvertised(
          connection: connection,
          registry: registry,
        );
        final peerConnection = await host.startPlugin(
          pluginId: 'dev.adele.peer',
          artifactUri: Uri.file('/unused.aot'),
        );
        final peer = await PluginCapabilityActivation.register(
          connection: peerConnection,
          registry: registry,
          exposures: [
            PluginCapabilityExposure(
              provider: _provider(
                capability,
                'dev.adele.provider.peer',
                pluginId: peerConnection.pluginId,
              ),
              configurationContext: peerConnection.defaultConfigurationContext,
            ),
          ],
        );
        final target = registry.resolve(environment);
        final source = activation.resolveAssociatedProvider(
          capability,
          associatedWith: target,
        );
        final unrelated = registry.resolve(
          capability,
          providerId: ProviderId(secondExposure['providerId']! as String),
        );
        final peerBinding = registry.resolve(
          capability,
          providerId: ProviderId('dev.adele.provider.peer'),
        );
        final admitted = source.requestChannel.request('admitted', const {});
        Future<void>? reentrant;
        var visits = 0;
        unrelated.onRetire(() {
          visits++;
          // S and T are still registered when unrelated U retires first.
          expect(() => source.requestChannel, returnsNormally);
          expect(() => target.requestChannel, returnsNormally);
          expect(activation.owns(source), isFalse);
          expect(activation.owns(target), isFalse);
          expect(
            () => activation.retireProvider(source),
            throwsA(isA<InvalidProviderRegistration>()),
          );
          expect(activation.associationFor(source), isNull);
          expect(
            () => activation.resolveAssociatedProvider(
              capability,
              associatedWith: target,
            ),
            throwsA(isA<InvalidProviderRegistration>()),
          );
          reentrant = activation.retire();
          expect(activation.retire(), same(reentrant));
          expect(peer.owns(peerBinding), isTrue);
        });
        final stopping = closeConnection
            ? activation.close()
            : activation.retire();
        expect(visits, 1);
        expect(activation.retire(), same(reentrant));
        if (!closeConnection) expect(stopping, same(reentrant));
        await stopping;
        expect(await admitted, {
          'configurationContext': 'shared',
          'serviceId': 'resourceInspector',
          'payload': <String, Object?>{},
        });
        expect(activation.retire(), same(reentrant));
        expect(visits, 1);
        expect(peer.owns(peerBinding), isTrue);
        expect(() => peerBinding.requestChannel, returnsNormally);
        expect(peerConnection.isClosed, isFalse);
        await activation.close();
        await peer.close();
      },
    );
  }

  test(
    'target retirement and same-ID replacement never revive associations',
    () async {
      final fake = _FakeHost.create(
        contextEcho: true,
        readyFields: {
          'capabilityExposures': [associatedExposure, environmentA],
        },
      );
      addTearDown(fake.dispose);
      final host = await fake.start();
      addTearDown(host.close);
      final connection = await host.startPlugin(
        pluginId: 'dev.adele.provider',
        artifactUri: Uri.file('/unused.aot'),
      );
      final registry = CapabilityRegistry();
      final activation = await PluginCapabilityActivation.registerAdvertised(
        connection: connection,
        registry: registry,
      );
      final source = registry.resolve(capability);
      final target = registry.resolve(environment);
      final endpoint = target.endpointAs<AdeleRequestChannelEndpoint>();
      Future<Object?>? admitted;
      CapabilityRegistration? replacement;
      target.onRetire(() {
        // Group retirement fences the last registered target before the source.
        expect(activation.owns(source), isTrue);
        expect(() => source.requestChannel, returnsNormally);
        expect(
          () => activation.associationFor(source),
          throwsA(isA<ProviderUnavailable>()),
        );
        expect(
          () => activation.resolveAssociatedProvider(
            capability,
            associatedWith: target,
          ),
          throwsA(isA<ProviderUnavailable>()),
        );
        replacement = registry.register(
          provider: target.provider,
          endpoint: endpoint,
        );
        expect(
          () => activation.associationFor(source),
          throwsA(isA<ProviderUnavailable>()),
        );
        expect(
          () => activation.resolveAssociatedProvider(
            capability,
            associatedWith: registry.resolve(environment),
          ),
          throwsA(isA<InvalidProviderRegistration>()),
        );
        admitted = source.requestChannel.request(
          'still-context-free',
          const {},
        );
      });
      await activation.registrations.close();
      expect(await admitted, isA<Map<String, Object?>>());
      expect(replacement!.isClosed, isFalse);
      expect(
        () => activation.associationFor(source),
        throwsA(isA<ProviderUnavailable>()),
      );
      await activation.retire();
      expect(replacement!.isClosed, isFalse);
      await replacement!.close();
      await activation.close();
    },
  );

  test(
    'association retirement is isolated across backend generations',
    () async {
      final fake = _FakeHost.create(failOnRequest: true);
      addTearDown(fake.dispose);
      final host = await fake.start();
      addTearDown(host.close);
      final registry = CapabilityRegistry();
      final activations = <PluginCapabilityActivation>[];
      for (final name in ['a', 'b']) {
        final connection = await host.startPlugin(
          pluginId: 'dev.adele.provider.$name',
          artifactUri: Uri.file('/unused.aot'),
        );
        activations.add(
          await PluginCapabilityActivation.register(
            connection: connection,
            registry: registry,
            exposures: [
              PluginCapabilityExposure(
                provider: _provider(
                  capability,
                  'dev.adele.provider.$name',
                  pluginId: connection.pluginId,
                ),
                configurationContext: connection.defaultConfigurationContext,
                association: AdeleProviderAssociation(
                  capabilityId: environment.id.value,
                  capabilityMajorVersion: 1,
                  providerId: 'dev.adele.environment.$name',
                ),
              ),
              PluginCapabilityExposure(
                provider: _provider(
                  environment,
                  'dev.adele.environment.$name',
                  pluginId: connection.pluginId,
                ),
                configurationContext: connection.defaultConfigurationContext,
              ),
            ],
          ),
        );
      }
      final oldSource = registry.resolve(
        capability,
        providerId: ProviderId('dev.adele.provider.a'),
      );
      final other = registry.resolve(
        capability,
        providerId: ProviderId('dev.adele.provider.b'),
      );
      final oldTarget = activations.first.associationFor(oldSource)!;
      final otherTarget = activations.last.associationFor(other)!;
      await expectLater(
        oldSource.requestChannel.request('crash', const {}),
        throwsA(isA<PluginRemoteFailure>()),
      );
      await activations.first.connection.terminated;
      await activations.first.retire();
      expect(
        activations.last.associationFor(other)!.isSameRegistration(otherTarget),
        isTrue,
      );
      expect(
        activations.last
            .resolveAssociatedProvider(capability, associatedWith: otherTarget)
            .isSameRegistration(other),
        isTrue,
      );
      final replacementConnection = await host.startPlugin(
        pluginId: activations.first.connection.pluginId,
        artifactUri: Uri.file('/unused.aot'),
      );
      final next = await PluginCapabilityActivation.register(
        connection: replacementConnection,
        registry: registry,
        exposures: [
          PluginCapabilityExposure(
            provider: oldTarget.provider,
            configurationContext:
                replacementConnection.defaultConfigurationContext,
          ),
          PluginCapabilityExposure(
            provider: oldSource.provider,
            configurationContext:
                replacementConnection.defaultConfigurationContext,
            association: AdeleProviderAssociation(
              capabilityId: environment.id.value,
              capabilityMajorVersion: 1,
              providerId: oldTarget.provider.id.value,
            ),
          ),
        ],
      );
      expect(
        () => activations.first.associationFor(oldSource),
        throwsA(isA<ProviderUnavailable>()),
      );
      expect(
        () => next.resolveAssociatedProvider(
          capability,
          associatedWith: oldTarget,
        ),
        throwsA(isA<ProviderUnavailable>()),
      );
      final fresh = registry.resolve(
        capability,
        providerId: oldSource.provider.id,
      );
      expect(
        next.associationFor(fresh)!.isSameRegistration(oldTarget),
        isFalse,
      );
      await activations.first.close();
      expect(next.owns(fresh), isTrue);
      expect(activations.last.owns(other), isTrue);
      await next.close();
      await activations.last.close();
    },
  );

  test(
    'advertised registration supports missing, zero, one and multiple contexts',
    () async {
      for (final fields in <Map<String, Object?>>[
        {},
        {'capabilityExposures': []},
        {
          'capabilityExposures': [firstExposure],
        },
        {
          'capabilityExposures': [firstExposure, secondExposure],
        },
      ]) {
        final fake = _FakeHost.create(contextEcho: true, readyFields: fields);
        addTearDown(fake.dispose);
        final host = await fake.start();
        addTearDown(host.close);
        final connection = await host.startPlugin(
          pluginId: 'dev.adele.actual',
          artifactUri: Uri.file('/unused.aot'),
        );
        final registry = CapabilityRegistry();
        expect(registry.providersFor(capability), isEmpty);
        final activation = await PluginCapabilityActivation.registerAdvertised(
          connection: connection,
          registry: registry,
        );
        final providers = registry.providersFor(capability);
        expect(providers, hasLength(connection.capabilityExposures.length));
        for (final exposure in connection.capabilityExposures) {
          final binding = registry.resolve(
            capability,
            providerId: ProviderId(exposure.providerId),
          );
          expect(binding.provider.pluginId, connection.pluginId);
          expect(activation.owns(binding), isTrue);
          final unrelated = CapabilityRegistry();
          unrelated.register(
            provider: binding.provider,
            endpoint: binding.endpointAs<AdeleRequestChannelEndpoint>(),
          );
          expect(
            activation.owns(unrelated.resolve(capability)),
            isFalse,
            reason: 'Even the same descriptor and endpoint are not ownership.',
          );
          expect(binding.provider.displayName, exposure.displayName);
          expect(binding.provider.rank, exposure.rank);
          final channel = binding.requestChannel;
          expect(
            await channel.request('inspect', {
              'configurationContext': 'spoofed',
            }),
            {
              'configurationContext': exposure.configurationContext,
              'serviceId': exposure.serviceId,
              'payload': {'configurationContext': 'spoofed'},
            },
          );
        }
        if (providers.length == 2) {
          expect(
            registry.resolve(capability).provider.id.value,
            secondExposure['providerId'],
          );
        }
        await activation.close();
        expect(registry.providersFor(capability), isEmpty);
        await host.close();
      }
    },
    timeout: const Timeout(Duration(minutes: 1)),
  );

  test(
    'advertised registration rolls back only newly registered providers',
    () async {
      final fake = _FakeHost.create(
        readyFields: {
          'capabilityExposures': [firstExposure, secondExposure],
        },
      );
      addTearDown(fake.dispose);
      final host = await fake.start();
      addTearDown(host.close);
      final connection = await host.startPlugin(
        pluginId: 'dev.adele.provider',
        artifactUri: Uri.file('/unused.aot'),
      );
      final registry = CapabilityRegistry();
      final existing = await PluginCapabilityActivation.register(
        connection: connection,
        registry: registry,
        exposures: [
          PluginCapabilityExposure(
            provider: _provider(
              capability,
              secondExposure['providerId']! as String,
            ),
            configurationContext: connection.defaultConfigurationContext,
          ),
        ],
      );
      final retained = registry.resolve(capability);
      expect(connection.validateInfrastructureContext, returnsNormally);
      await expectLater(
        PluginCapabilityActivation.registerAdvertised(
          connection: connection,
          registry: registry,
        ),
        throwsA(isA<DuplicateProviderRegistration>()),
      );
      expect(registry.providersFor(capability).map((provider) => provider.id), [
        retained.provider.id,
      ]);
      expect(() => retained.requestChannel, returnsNormally);
      expect(connection.validateInfrastructureContext, returnsNormally);
      await existing.retire();
      expect(connection.validateInfrastructureContext, returnsNormally);
      await existing.close();
    },
  );

  test(
    'standalone close revokes before queued infrastructure service entry',
    () async {
      final fake = _FakeHost.create(
        readyFields: {
          'capabilityExposures': [firstExposure, secondExposure],
        },
      );
      addTearDown(fake.dispose);
      final host = await fake.start();
      addTearDown(host.close);
      final connection = await host.startPlugin(
        pluginId: 'dev.adele.provider',
        artifactUri: Uri.file('/unused.aot'),
      );
      final activation = await PluginCapabilityActivation.registerAdvertised(
        connection: connection,
        registry: CapabilityRegistry(),
      );
      var effects = 0;
      // Already-admitted service work can enter before asynchronous retirement ends.
      final queued = Future<void>.microtask(() {
        connection.validateInfrastructureContext();
        effects++;
      });
      final rejected = expectLater(
        queued,
        throwsA(isA<PluginConnectionClosed>()),
      );
      final closing = activation.close();
      expect(connection.isClosed, isFalse);
      expect(
        connection.validateInfrastructureContext,
        throwsA(isA<PluginConnectionClosed>()),
      );
      await rejected;
      expect(effects, 0);
      await closing;
    },
  );

  test(
    'rollback retires all owned bindings and retains the activation error',
    () async {
      final fake = _FakeHost.create();
      addTearDown(fake.dispose);
      final host = await fake.start();
      addTearDown(host.close);
      final connection = await host.startPlugin(
        pluginId: 'dev.adele.provider',
        artifactUri: Uri.file('/unused.aot'),
      );
      final registry = CapabilityRegistry();
      final retained = await PluginCapabilityActivation.register(
        connection: connection,
        registry: registry,
        exposures: [
          PluginCapabilityExposure(
            provider: _provider(capability, 'dev.adele.provider.retained'),
            configurationContext: connection.defaultConfigurationContext,
          ),
        ],
      );
      final unrelated = registry.resolve(capability);
      final bindings = <ProviderBinding>[];
      final visited = <int>[];
      final error = StateError('Exposure iteration failed.');
      final stack = StackTrace.fromString('original exposure iterator stack');
      Iterable<PluginCapabilityExposure> exposures() sync* {
        for (var index = 0; index < 3; index++) {
          final provider = _provider(
            capability,
            'dev.adele.provider.attempt-$index',
          );
          yield PluginCapabilityExposure(
            provider: provider,
            configurationContext: connection.defaultConfigurationContext,
          );
          final binding = registry.resolve(capability, providerId: provider.id);
          bindings.add(binding);
          binding.onRetire(() {
            visited.add(index);
            if (index == 2) {
              throw StateError('Secondary rollback observer error.');
            }
          });
        }
        Error.throwWithStackTrace(error, stack);
      }

      try {
        await PluginCapabilityActivation.register(
          connection: connection,
          registry: registry,
          exposures: exposures(),
          beforeRollback: () {
            expect(visited, isEmpty);
            throw StateError('Secondary rollback hook failure.');
          },
        );
        fail('Activation must fail.');
      } catch (caught, caughtStack) {
        expect(caught, same(error));
        expect(caughtStack.toString(), stack.toString());
      }
      expect(visited, [2, 1, 0]);
      for (final binding in bindings) {
        expect(
          () => binding.requestChannel,
          throwsA(isA<ProviderUnavailable>()),
        );
      }
      expect(registry.providersFor(capability).map((provider) => provider.id), [
        unrelated.provider.id,
      ]);
      expect(() => unrelated.requestChannel, returnsNormally);
      expect(connection.isClosed, isFalse);
      expect(connection.validateInfrastructureContext, returnsNormally);
      await retained.close();
    },
  );

  for (final observerFails in [false, true]) {
    test(
      'explicit close preserves first failure when stop fails, observer=$observerFails',
      () async {
        final fake = _FakeHost.create(
          failOnStop: true,
          readyFields: {
            'capabilityExposures': [firstExposure],
          },
        );
        addTearDown(fake.dispose);
        final host = await fake.start();
        addTearDown(host.close);
        final connection = await host.startPlugin(
          pluginId: 'dev.adele.provider',
          artifactUri: Uri.file('/unused.aot'),
        );
        final registry = CapabilityRegistry();
        final activation = await PluginCapabilityActivation.registerAdvertised(
          connection: connection,
          registry: registry,
        );
        final error = StateError('Observer failure before stop failure.');
        final stack = StackTrace.fromString(
          'observer before failed stop stack',
        );
        var visits = 0;
        registry.resolve(capability).onRetire(() {
          visits++;
          if (observerFails) Error.throwWithStackTrace(error, stack);
        });
        try {
          await activation.close();
          fail('Stop failure must be reported if retirement succeeds.');
        } catch (caught, caughtStack) {
          if (observerFails) {
            expect(caught, same(error));
            expect(caughtStack.toString(), stack.toString());
          } else {
            expect(
              caught,
              isA<PluginRemoteFailure>().having(
                (failure) => failure.code,
                'code',
                'stop_failed',
              ),
            );
          }
        }
        expect(visits, 1);
        expect(connection.isClosed, isTrue);
        expect(registry.providersFor(capability), isEmpty);
        if (observerFails) {
          await expectLater(activation.close(), throwsA(same(error)));
        } else {
          await activation.close();
        }
        expect(visits, 1);
      },
    );
  }

  test(
    'explicit close shuts down connection despite retirement observer errors',
    () async {
      final fake = _FakeHost.create(
        readyFields: {
          'capabilityExposures': [firstExposure, secondExposure],
        },
      );
      addTearDown(fake.dispose);
      final host = await fake.start();
      addTearDown(host.close);
      final connection = await host.startPlugin(
        pluginId: 'dev.adele.provider',
        artifactUri: Uri.file('/unused.aot'),
      );
      final registry = CapabilityRegistry();
      final activation = await PluginCapabilityActivation.registerAdvertised(
        connection: connection,
        registry: registry,
      );
      final first = registry.resolve(
        capability,
        providerId: ProviderId(firstExposure['providerId']! as String),
      );
      final second = registry.resolve(
        capability,
        providerId: ProviderId(secondExposure['providerId']! as String),
      );
      final visited = <String>[];
      final error = StateError('Retirement observer failed.');
      final stack = StackTrace.fromString('original activation observer stack');
      first.onRetire(() => visited.add('first'));
      second.onRetire(() {
        visited.add('second');
        Error.throwWithStackTrace(error, stack);
      });
      try {
        await activation.close();
        fail('Expected retirement failure after backend cleanup.');
      } catch (caught, caughtStack) {
        expect(caught, same(error));
        expect(caughtStack.toString(), stack.toString());
        expect(visited, ['second', 'first']);
        expect(registry.providersFor(capability), isEmpty);
        expect(connection.isClosed, isTrue);
      }
      // The stop acknowledgement releases the exact PluginId for a replacement.
      final replacement = await host.startPlugin(
        pluginId: connection.pluginId,
        artifactUri: Uri.file('/unused.aot'),
      );
      final next = await PluginCapabilityActivation.registerAdvertised(
        connection: replacement,
        registry: registry,
      );
      await expectLater(activation.close(), throwsA(same(error)));
      expect(visited, ['second', 'first']);
      for (final binding in [first, second]) {
        expect(
          () => binding.requestChannel,
          throwsA(
            isA<ProviderUnavailable>().having(
              (error) => error.stale,
              'stale',
              isTrue,
            ),
          ),
        );
      }
      expect(replacement.isClosed, isFalse);
      expect(next.owns(registry.resolve(capability)), isTrue);
      await next.close();
    },
  );

  test(
    'advertised bindings retire on termination and cannot migrate to replacement',
    () async {
      final fake = _FakeHost.create(
        failOnRequest: true,
        readyFields: {
          'capabilityExposures': [firstExposure, secondExposure],
        },
      );
      addTearDown(fake.dispose);
      final host = await fake.start();
      addTearDown(host.close);
      final registry = CapabilityRegistry();
      final first = await host.startPlugin(
        pluginId: 'dev.adele.provider',
        artifactUri: Uri.file('/unused.aot'),
      );
      final firstActivation =
          await PluginCapabilityActivation.registerAdvertised(
            connection: first,
            registry: registry,
          );
      final oldBinding = registry.resolve(capability);
      expect(firstActivation.owns(oldBinding), isTrue);
      final oldChannel = oldBinding.requestChannel;
      final oldContext = first.configurationContext('opaque-first');
      await expectLater(
        oldChannel.request('crash', const {}),
        throwsA(isA<PluginRemoteFailure>()),
      );
      await first.terminated;
      await Future<void>.delayed(Duration.zero);
      expect(registry.providersFor(capability), isEmpty);
      final replacement = await host.startPlugin(
        pluginId: 'dev.adele.provider',
        artifactUri: Uri.file('/unused.aot'),
      );
      final replacementActivation =
          await PluginCapabilityActivation.registerAdvertised(
            connection: replacement,
            registry: registry,
          );
      await firstActivation.close();
      expect(firstActivation.owns(registry.resolve(capability)), isFalse);
      expect(replacementActivation.owns(registry.resolve(capability)), isTrue);
      expect(replacement.isClosed, isFalse);
      expect(registry.providersFor(capability), hasLength(2));
      expect(
        () => oldBinding.requestChannel,
        throwsA(isA<ProviderUnavailable>()),
      );
      await expectLater(
        oldChannel.request('after-replacement', const {}),
        throwsA(isA<PluginConnectionClosed>()),
      );
      expect(
        () => replacement.channelFor(oldContext, 'resourceInspector'),
        throwsArgumentError,
      );
      expect(
        () => registry.resolve(capability).requestChannel,
        returnsNormally,
      );
      await expectLater(
        PluginCapabilityActivation.registerAdvertised(
          connection: first,
          registry: registry,
        ),
        throwsA(isA<InvalidProviderRegistration>()),
      );
      await replacementActivation.close();
    },
  );

  test(
    'concurrent advertised retirement joins termination cleanup before identity reuse',
    () async {
      final advertisements = [
        for (int index = 0; index < 20; index++)
          {
            ...firstExposure,
            'providerId': 'dev.adele.provider.instance-$index',
            'configurationContext': 'context-$index',
          },
      ];
      final fake = _FakeHost.create(
        failOnRequest: true,
        readyFields: {'capabilityExposures': advertisements},
      );
      addTearDown(fake.dispose);
      final host = await fake.start();
      addTearDown(host.close);
      final connection = await host.startPlugin(
        pluginId: 'dev.adele.original',
        artifactUri: Uri.file('/unused.aot'),
      );
      // A ready replacement avoids a process round trip masking partial cleanup.
      final replacement = await host.startPlugin(
        pluginId: 'dev.adele.replacement',
        artifactUri: Uri.file('/unused.aot'),
      );
      final registry = CapabilityRegistry();
      final activation = await PluginCapabilityActivation.registerAdvertised(
        connection: connection,
        registry: registry,
      );
      final bindings = [
        for (final provider in registry.providersFor(capability))
          registry.resolve(capability, providerId: provider.id),
      ];
      final replaced = connection.terminated.then((_) async {
        final retiring = activation.retire();
        final alsoRetiring = activation.retire();
        await Future.wait<void>([retiring, alsoRetiring, activation.close()]);
        final next = await PluginCapabilityActivation.registerAdvertised(
          connection: replacement,
          registry: registry,
        );
        expect(alsoRetiring, same(retiring));
        expect(activation.retire(), same(retiring));
        for (final binding in bindings) {
          expect(
            () => binding.requestChannel,
            throwsA(isA<ProviderUnavailable>()),
          );
        }
        await activation.close();
        expect(replacement.isClosed, isFalse);
        expect(registry.providersFor(capability), hasLength(20));
        await next.close();
      });
      await Future.wait<void>([
        replaced,
        expectLater(
          connection.request('crash', const {}),
          throwsA(isA<PluginRemoteFailure>()),
        ),
      ]);
    },
  );

  test(
    'publishes only ready connections and retires before shutdown',
    () async {
      final _FakeHost fake = _FakeHost.create();
      addTearDown(fake.dispose);
      final PluginBackendHost host = await fake.start();
      final CapabilityRegistry registry = CapabilityRegistry();
      final CapabilityKey capability = CapabilityKey(
        id: CapabilityId('dev.adele.resource.inspect'),
        majorVersion: 1,
      );
      expect(registry.providersFor(capability), isEmpty);
      final PluginBackendConnection connection = await host.startPlugin(
        pluginId: 'dev.adele.provider',
        artifactUri: Uri.file('/unused.aot'),
      );
      final PluginCapabilityActivation activation =
          await PluginCapabilityActivation.register(
            connection: connection,
            registry: registry,
            exposures: <PluginCapabilityExposure>[
              PluginCapabilityExposure(
                provider: _provider(capability, 'dev.adele.provider.inspector'),
                configurationContext: connection.defaultConfigurationContext,
              ),
            ],
          );
      expect(registry.providersFor(capability), hasLength(1));

      final ProviderBinding binding = registry.resolve(capability);
      await activation.close();
      expect(registry.providersFor(capability), isEmpty);
      expect(() => binding.requestChannel, throwsA(isA<ProviderUnavailable>()));
      await host.close();
    },
  );

  test(
    'backend failure retires all registrations for the generation',
    () async {
      final _FakeHost fake = _FakeHost.create(failOnRequest: true);
      addTearDown(fake.dispose);
      final PluginBackendHost host = await fake.start();
      final CapabilityRegistry registry = CapabilityRegistry();
      final CapabilityKey first = CapabilityKey(
        id: CapabilityId('dev.adele.resource.inspect'),
        majorVersion: 1,
      );
      final CapabilityKey second = CapabilityKey(
        id: CapabilityId('dev.adele.resource.summarize'),
        majorVersion: 1,
      );
      final PluginBackendConnection connection = await host.startPlugin(
        pluginId: 'dev.adele.provider',
        artifactUri: Uri.file('/unused.aot'),
      );
      await PluginCapabilityActivation.register(
        connection: connection,
        registry: registry,
        exposures: <PluginCapabilityExposure>[
          PluginCapabilityExposure(
            provider: _provider(first, 'dev.adele.provider.inspector'),
            configurationContext: connection.defaultConfigurationContext,
          ),
          PluginCapabilityExposure(
            provider: _provider(second, 'dev.adele.provider.summarizer'),
            configurationContext: connection.defaultConfigurationContext,
          ),
        ],
      );
      await expectLater(
        connection.request('crash', const <String, Object?>{}),
        throwsA(isA<PluginRemoteFailure>()),
      );
      await connection.terminated;
      await Future<void>.delayed(Duration.zero);
      expect(registry.providersFor(first), isEmpty);
      expect(registry.providersFor(second), isEmpty);
      await host.close();
    },
  );

  test('bindings own explicit shared configuration contexts', () async {
    final _FakeHost fake = _FakeHost.create(contextEcho: true);
    addTearDown(fake.dispose);
    final PluginBackendHost host = await fake.start();
    final CapabilityRegistry registry = CapabilityRegistry();
    final CapabilityKey capability = CapabilityKey(
      id: CapabilityId('dev.adele.resource.inspect'),
      majorVersion: 1,
    );
    final ProviderId contextAFirstId = ProviderId(
      'dev.adele.provider.context-a-first',
    );
    final ProviderId contextASecondId = ProviderId(
      'dev.adele.provider.context-a-second',
    );
    final ProviderId contextBId = ProviderId(
      'dev.adele.provider.context-b-first',
    );
    final PluginBackendConnection connection = await host.startPlugin(
      pluginId: 'dev.adele.provider',
      artifactUri: Uri.file('/unused.aot'),
    );
    final PluginCapabilityActivation activation =
        await PluginCapabilityActivation.register(
          connection: connection,
          registry: registry,
          exposures: <PluginCapabilityExposure>[
            PluginCapabilityExposure(
              provider: _provider(capability, contextAFirstId.value),
              configurationContext: connection.defaultConfigurationContext,
            ),
            PluginCapabilityExposure(
              provider: _provider(
                capability,
                contextASecondId.value,
                serviceId: 'resourceSummarizer',
              ),
              configurationContext: connection.defaultConfigurationContext,
            ),
            PluginCapabilityExposure(
              provider: _provider(capability, contextBId.value),
              configurationContext: connection.configurationContext(
                'configuration-b',
              ),
            ),
          ],
        );
    final Map<String, Object?> semanticPayload = <String, Object?>{
      'configurationContext': 'configuration-b',
      'serviceId': 'spoofedService',
      'value': 'same semantic request',
    };
    final ProviderBinding contextAFirst = registry.resolve(
      capability,
      providerId: contextAFirstId,
    );
    final ProviderBinding contextASecond = registry.resolve(
      capability,
      providerId: contextASecondId,
    );
    final ProviderBinding contextB = registry.resolve(
      capability,
      providerId: contextBId,
    );

    final Object? firstResult = await contextAFirst.requestChannel.request(
      'resourceInspector.inspect',
      semanticPayload,
    );
    final Object? secondResult = await contextASecond.requestChannel.request(
      'resourceInspector.inspect',
      semanticPayload,
    );
    final Object? contextBResult = await contextB.requestChannel.request(
      'resourceInspector.inspect',
      semanticPayload,
    );
    expect(firstResult, isA<Map<String, Object?>>());
    expect(secondResult, isA<Map<String, Object?>>());
    expect(contextBResult, isA<Map<String, Object?>>());
    final Map<String, Object?> firstMap = firstResult! as Map<String, Object?>;
    final Map<String, Object?> secondMap =
        secondResult! as Map<String, Object?>;
    final Map<String, Object?> contextBMap =
        contextBResult! as Map<String, Object?>;
    expect(firstMap['configurationContext'], secondMap['configurationContext']);
    expect(firstMap['serviceId'], 'resourceInspector');
    expect(secondMap['serviceId'], 'resourceSummarizer');
    expect(
      firstMap['configurationContext'],
      isNot(contextBMap['configurationContext']),
    );
    expect(firstMap['payload'], semanticPayload);
    expect(
      await contextB.streamChannel
          .stream('resourceInspector.watch', semanticPayload)
          .toList(),
      <Object?>[contextBResult],
    );

    await activation.close();
    await host.close();
  });

  test('configuration contexts cannot cross plugin generations', () async {
    final _FakeHost fake = _FakeHost.create();
    addTearDown(fake.dispose);
    final PluginBackendHost host = await fake.start();
    final PluginBackendConnection first = await host.startPlugin(
      pluginId: 'dev.adele.provider.first',
      artifactUri: Uri.file('/unused.aot'),
    );
    final PluginBackendConnection second = await host.startPlugin(
      pluginId: 'dev.adele.provider.second',
      artifactUri: Uri.file('/unused.aot'),
    );

    expect(
      () => second.channelFor(
        first.defaultConfigurationContext,
        'resourceInspector',
      ),
      throwsArgumentError,
    );

    await first.close();
    await second.close();
    await host.close();
  });

  test('partial activation mismatch rolls back previous providers', () async {
    final _FakeHost fake = _FakeHost.create();
    addTearDown(fake.dispose);
    final PluginBackendHost host = await fake.start();
    final CapabilityRegistry registry = CapabilityRegistry();
    final CapabilityKey capability = CapabilityKey(
      id: CapabilityId('dev.adele.resource.inspect'),
      majorVersion: 1,
    );
    final PluginBackendConnection connection = await host.startPlugin(
      pluginId: 'dev.adele.provider',
      artifactUri: Uri.file('/unused.aot'),
    );
    await expectLater(
      PluginCapabilityActivation.register(
        connection: connection,
        registry: registry,
        exposures: <PluginCapabilityExposure>[
          PluginCapabilityExposure(
            provider: _provider(capability, 'dev.adele.provider.first'),
            configurationContext: connection.defaultConfigurationContext,
          ),
          PluginCapabilityExposure(
            provider: _provider(
              capability,
              'dev.adele.provider.second',
              pluginId: 'dev.adele.other',
            ),
            configurationContext: connection.defaultConfigurationContext,
          ),
        ],
      ),
      throwsA(isA<InvalidProviderRegistration>()),
    );
    expect(registry.providersFor(capability), isEmpty);
    await connection.close();
    await host.close();
  });
}

ProviderDescriptor _provider(
  CapabilityKey capability,
  String id, {
  String pluginId = 'dev.adele.provider',
  String serviceId = 'resourceInspector',
  int rank = 0,
}) => ProviderDescriptor(
  id: ProviderId(id),
  capability: capability,
  pluginId: pluginId,
  displayName: id,
  serviceId: serviceId,
  rank: rank,
);

final class _FakeHost {
  _FakeHost._(this.directory, this.script);

  factory _FakeHost.create({
    bool failOnRequest = false,
    bool failOnStop = false,
    bool contextEcho = false,
    Map<String, Object?> readyFields = const {},
  }) {
    final Directory directory = Directory(
      '${Directory.current.path}/.dart_tool/capability-runtime/'
      '${DateTime.now().microsecondsSinceEpoch}',
    )..createSync(recursive: true);
    final File script = File('${directory.path}/host.dart')
      ..writeAsStringSync('''
import 'dart:io';
import 'package:plugin_runtime/plugin_runtime.dart';
void main() {
  stdout.add(encodeBackendHostFrame({'protocolVersion': backendHostProtocolVersion, 'kind': 'hostHello'}));
  final decoder = BackendHostFrameDecoder();
  final streams = <int, Map<String, Object?>>{};
  stdin.listen((bytes) {
    for (final message in decoder.add(bytes)) {
      if (message['kind'] == 'startPlugin') {
        stdout.add(encodeBackendHostFrame({'protocolVersion': backendHostProtocolVersion, 'kind': 'pluginReady', 'requestId': message['requestId'], 'pluginId': message['pluginId'], ...${jsonEncode(readyFields)}}));
      } else if (message['kind'] == 'stopPlugin') {
        stdout.add(encodeBackendHostFrame({'protocolVersion': backendHostProtocolVersion, 'kind': '${failOnStop ? 'response' : 'pluginStopped'}', 'requestId': message['requestId'], 'pluginId': message['pluginId'], ${failOnStop ? "'ok': false, 'error': {'code': 'stop_failed', 'message': 'Stop failed.'}" : ''}}));
      } else if (message['kind'] == 'request') {
        ${failOnRequest
          ? "stdout.add(encodeBackendHostFrame({'protocolVersion': backendHostProtocolVersion, 'kind': 'pluginFailed', 'pluginId': message['pluginId'], 'requestIds': [message['requestId']], 'error': {'code': 'plugin_exited', 'message': 'failed'}}));"
          : contextEcho
          ? "stdout.add(encodeBackendHostFrame({'protocolVersion': backendHostProtocolVersion, 'kind': 'response', 'requestId': message['requestId'], 'pluginId': message['pluginId'], 'ok': true, 'payload': {'configurationContext': message['configurationContext'], 'serviceId': message['serviceId'], 'payload': message['payload']}}));"
          : "stdout.add(encodeBackendHostFrame({'protocolVersion': backendHostProtocolVersion, 'kind': 'response', 'requestId': message['requestId'], 'pluginId': message['pluginId'], 'ok': true, 'payload': {}}));"}
      } else if (message['kind'] == 'streamOpen') {
        streams[message['requestId'] as int] = message;
      } else if (message['kind'] == 'streamCredit') {
        final open = streams.remove(message['requestId']);
        if (open != null) {
          stdout.add(encodeBackendHostFrame({'protocolVersion': backendHostProtocolVersion, 'kind': 'streamItem', 'requestId': message['requestId'], 'pluginId': message['pluginId'], 'payload': {'configurationContext': open['configurationContext'], 'serviceId': open['serviceId'], 'payload': open['payload']}}));
          stdout.add(encodeBackendHostFrame({'protocolVersion': backendHostProtocolVersion, 'kind': 'streamDone', 'requestId': message['requestId'], 'pluginId': message['pluginId']}));
        }
      } else if (message['kind'] == 'shutdownHost') {
        stdout.add(encodeBackendHostFrame({'protocolVersion': backendHostProtocolVersion, 'kind': 'hostStopped', 'requestId': message['requestId']}));
        exit(0);
      }
    }
  });
}
''');
    return _FakeHost._(directory, script);
  }

  final Directory directory;
  final File script;

  Future<PluginBackendHost> start() async {
    final String dart = Platform.resolvedExecutable;
    final String dartaotruntime = '${File(dart).parent.path}/dartaotruntime';
    final File snapshot = File('${directory.path}/host.aot');
    final ProcessResult snapshotResult = await Process.run(dart, <String>[
      'compile',
      'aot-snapshot',
      script.path,
      '-o',
      snapshot.path,
    ], workingDirectory: Directory.current.path);
    if (snapshotResult.exitCode != 0) {
      throw StateError(snapshotResult.stderr.toString());
    }
    return PluginBackendHost.start(
      dartaotruntimeExecutable: dartaotruntime,
      hostArtifactPath: snapshot.path,
    );
  }

  Future<void> dispose() async {
    if (directory.existsSync()) directory.deleteSync(recursive: true);
  }
}
